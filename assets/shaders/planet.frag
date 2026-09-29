#version 460 core

// ATLANHIX PLANET — cinematic dark-planet shader (reference: brand sheet).
// One fullscreen quad per frame; ALL surface detail is procedural so the
// asset budget stays zero-texture and mobile-friendly.
//
// The Dart side supplies iResolution (pixels), uTime (seconds), uYaw,
// uPitch (radians), uLand (land-mask sampler, equirectangular), uAtmos,
// uError (0/1) and uLit (light direction in VIEW space).
#include <flutter/runtime_effect.glsl>

uniform vec2 iResolution;
uniform float uTime;
uniform float uYaw;   // planet yaw (radians)
uniform float uPitch; // camera tilt (radians)
uniform float uAtmos;      // 0..1 atmosphere/rim intensity
uniform float uError;      // 0 normal, 1 error tint
uniform vec2 uLit;         // light direction (view space xy)
// NOTE: sampler uniforms MUST be declared after every numeric uniform
// (Flutter fragment-shader indexing rule) — uLand is intentionally last.
uniform sampler2D uLand;   // r = land, g = night-lights, b = spare

out vec4 fragColor;

const float PI = 3.14159265;

// ── Hash / noise kit (value noise + fbm) ─────────────────────────────
float hash21(vec2 p) {
  p = fract(p * vec2(234.34, 435.345));
  p += dot(p, p + 34.23);
  return fract(p.x * p.y);
}
float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(
      mix(hash21(i), hash21(i + vec2(1, 0)), u.x),
      mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(11.7, 5.3);
    a *= 0.5;
  }
  return v;
}

// Land dots: the SAME lookup the point-cloud painters do, per-pixel, with
// a small glow so lit coastlines read like the reference's night side.
float landSample(vec2 uv) {
  return texture(uLand, vec2(uv.x, clamp(uv.y, 0.001, 0.999))).r;
}
float lightsSample(vec2 uv) {
  return texture(uLand, vec2(uv.x, clamp(uv.y, 0.001, 0.999))).g;
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  // Planet center: slightly below mid-height (art composition).
  float R = min(iResolution.x * 0.46, iResolution.y * 0.42);
  vec2 center = vec2(iResolution.x * 0.5, iResolution.y * 0.46);
  vec2 p = fc - center;
  float r = length(p);

  // ── Space + star field (outside the disc) ──────────────────────────
  float starCell = hash21(floor(fc * 0.7));
  float star = smoothstep(0.9975, 1.0, starCell) *
      (0.5 + 0.5 * sin(uTime * 1.4 + starCell * 60.0));

  // ── Sphere intersection ────────────────────────────────────────────
  float disc = 1.0 - step(R, r);
  if (disc < 0.5 && star < 0.004) {
    fragColor = vec4(0, 0, 0, 0);
    return;
  }

  float z2 = R * R - r * r;
  float z = sqrt(max(z2, 0.0));
  // View-space normal (toward camera = +z out of the screen).
  vec3 n = vec3(p.x / R, p.y / R, z / R);

  // Yaw around the planet axis, then pitch tilt.
  float cy = cos(uYaw), sy = sin(uYaw);
  float cp = cos(uPitch), sp = sin(uPitch);
  // Screen y grows downward; flip for the math frame.
  vec3 nv = vec3(n.x, -n.y, n.z);
  // Yaw: rotate xz.
  vec3 a = vec3(nv.x * cy + nv.z * sy, nv.y, -nv.x * sy + nv.z * cy);
  // Pitch: rotate yz.
  vec3 b = vec3(a.x, a.y * cp - a.z * sp, a.y * sp + a.z * cp);
  vec3 unit = normalize(b);

  // Equirectangular UV. Seam at ±180°: the land texture wraps (REPEAT) so
  // the only artifact is a possible 1px column — texture REPEAT handles it.
  float lon = atan(unit.x, unit.z);
  float lat = asin(clamp(unit.y, -1.0, 1.0));
  vec2 uv = vec2(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI);

  float land = landSample(uv);
  float lights = lightsSample(uv);

  // ── Procedural rocky relief (the dark terrain) ──────────────────────
  float f1 = fbm(uv * vec2(9.0, 5.0) + vec2(3.1, 7.7));
  float f2 = fbm(uv * vec2(22.0, 11.0) + vec2(13.7, 1.9));
  float relief = f1 * 0.65 + f2 * 0.35;

  // ── Lighting ────────────────────────────────────────────────────────
  // Light dir from uLit (view space); default upper-left-front.
  vec3 L = normalize(vec3(uLit, 0.55));
  float diff = max(dot(n, L), 0.0);
  // Terminator: pow keeps most of the disc dark (night side dominant).
  float day = pow(diff, 1.35);
  // Rim: grazing angles glow cool-white (the reference's limb light).
  float rim = pow(1.0 - max(dot(n, vec3(0, 0, 1)), 0.0), 2.6);

  // ── Surface shading ─────────────────────────────────────────────────
  vec3 deepNavy = vec3(0.024, 0.031, 0.042);   // #06080B
  vec3 charcoal = vec3(0.066, 0.078, 0.092);   // #11141A-ish
  vec3 rockHi = vec3(0.345, 0.376, 0.42);      // #57606B
  vec3 ink = vec3(0.039, 0.043, 0.051);        // #0A0B0D

  vec3 col = mix(deepNavy, charcoal, relief);
  col = mix(col, rockHi * 0.55, land * 0.35 * day);
  // Ocean vs land albedo: land slightly lighter on the day side.
  col += rockHi * 0.22 * land * day;
  col += vec3(0.9, 0.93, 1.0) * rim * (0.55 + 0.45 * uAtmos) * 0.85;
  col += charcoal * day * 0.35;
  // Night-side city lights (from the baked mask) — warm-cold mix, subtle.
  float lightsPulse = lights * (0.65 + 0.35 * sin(uTime * 0.7 + uv.x * 40.0));
  col += vec3(0.92, 0.90, 0.80) * lightsPulse * (1.0 - day) * 0.85;
  col = mix(col, ink, 0.18); // cinematic crush

  // ── Land dot grid (hairline ink dots over the lit mask) ─────────────
  float dotGrid = 0.0;
  if (land > 0.5) {
    // Local planar grid on the sphere, dot cells sized by zoom-invariant
    // frequency so they read as the point cloud even at rest.
    vec2 g = fract(uv * vec2(180.0, 90.0)) - 0.5;
    dotGrid = smoothstep(0.18, 0.06, length(g)) * 0.55;
  }
  col += vec3(0.75, 0.78, 0.84) * dotGrid * (0.30 + 0.40 * day);

  // ── Atmosphere: limb ring + soft halo just outside the disc ────────
  vec3 atmos = vec3(0.0);
  // Outer halo (adds glow on empty pixels too — keep when disc==0).
  float halo = exp(-max(r - R, 0.0) / (R * 0.16)) * (0.30 + 0.55 * uAtmos);
  vec3 haloCol = vec3(0.62, 0.68, 0.78);
  atmos += haloCol * halo * 0.9;

  // ── Error tint: a slow red breath on the rim, nothing garish ───────
  float errBreath = uError * (0.5 + 0.5 * sin(uTime * 2.2));
  vec3 errCol = vec3(0.91, 0.42, 0.42);
  col = mix(col, col * 0.85 + errCol * 0.15 * errBreath, uError);

  // Compose: inside the disc use the surface, outside use atmosphere/star.
  vec3 space = vec3(0.0);
  space += vec3(star) * vec3(0.8, 0.85, 0.95);
  vec3 outCol = mix(space + atmos, col + atmos * 0.6, disc);
  float alpha = max(disc, max(halo, star));

  fragColor = vec4(outCol, alpha);
}
