#version 320 es

// ATLANHIX PLANET — cinematic dark-planet shader (reference: brand sheet
// "MAIN VIEW"). v0.5.5 §user-fix: the file previously declared
// `#version 460 core` — desktop GLSL, which Flutter's FragmentProgram
// REJECTS (it compiles ES 3.20); every device fell into the CPU-fallback
// catch and the planet either never appeared or rendered ghost-pale
// under the backdrop's old 0.5 opacity. This file now compiles FOR REAL
// and the look targets the reference sheet directly:
//
//   * strong WHITE rim light anchored to the UPPER-LEFT limb,
//   * rocky fbm relief with visible dark-terrain texture,
//   * warm night-side city lights that actually glow,
//   * a tight bright limb ring + soft cool halo (atmosphere),
//   * the planet LARGE in frame, most of the disc in night.
//
// One fullscreen quad per frame; ALL surface detail is procedural so the
// asset budget stays zero-texture and mobile-friendly.
//
// The Dart side supplies iResolution (pixels), uTime (seconds), uYaw,
// uPitch (radians), uLand (land-mask sampler, equirectangular), uAtmos,
// uError (0/1) and uLit (light direction in VIEW space).
#include <flutter/runtime_effect.glsl>

// NOTE: sampler uniforms MUST be declared after every numeric uniform
// (Flutter fragment-shader indexing rule) — uLand is intentionally last.
uniform vec2 iResolution;
uniform float uTime;
uniform float uYaw;   // planet yaw (radians)
uniform float uPitch; // camera tilt (radians)
uniform float uAtmos;      // 0..1 atmosphere/rim intensity
uniform float uError;      // 0 normal, 1 error tint
uniform vec2 uLit;         // light direction (view space xy)
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
  float R = min(iResolution.x * 0.52, iResolution.y * 0.50);
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
  // v0.5.5: domain-warped fbm — the reference's craggy continents read as
  // big rock masses, not flat noise. relief is the macro shape; detail
  // adds the fine grain the close-up sheet shows.
  vec2 wuv = uv + vec2(fbm(uv * vec2(6.0, 3.0)) - 0.5) * 0.045;
  float f1 = fbm(wuv * vec2(7.0, 4.0) + vec2(3.1, 7.7));
  float f2 = fbm(wuv * vec2(19.0, 10.0) + vec2(13.7, 1.9));
  float f3 = fbm(wuv * vec2(46.0, 24.0) + vec2(27.3, 9.1));
  float relief = f1 * 0.55 + f2 * 0.30 + f3 * 0.15;

  // ── Lighting ────────────────────────────────────────────────────────
  // Key light from uLit (view space); default UPPER-LEFT-front, matching
  // the reference sheet's hard limb light position.
  vec3 L = normalize(vec3(uLit, 0.45));
  float diff = max(dot(n, L), 0.0);
  // Terminator: pow keeps most of the disc dark (night side dominant).
  float day = pow(diff, 1.25);
  // Rim: grazing angles glow cool-white (the reference's limb light).
  float rim = pow(1.0 - max(dot(n, vec3(0, 0, 1)), 0.0), 2.6);
  // KEY RIM (v0.5.5): a SECOND rim lobe biased to the light side — the
  // hard white crescent hugging the upper-left limb in the sheet. A plain
  // uniform rim ring reads as an outline; this reads as a LIGHT.
  float rimKey = pow(max(dot(n, L), 0.0), 3.5) *
      pow(1.0 - max(dot(n, vec3(0, 0, 1)), 0.0), 1.6);
  // Terrain shading: cheap normal perturbation from the relief field so
  // the light rakes across the rock (the close-up's craters/ridges).
  vec3 bumpN = normalize(n + vec3(
      (fbm(wuv * vec2(24.0, 12.0) + vec2(5.2, 1.3)) - 0.5) * 0.55,
      (fbm(wuv * vec2(24.0, 12.0) + vec2(9.8, 4.4)) - 0.5) * 0.55,
      0.0));
  float bumpDiff = max(dot(bumpN, L), 0.0);

  // ── Surface shading ─────────────────────────────────────────────────
  vec3 deepNavy = vec3(0.020, 0.026, 0.036);   // near-black ocean floor
  vec3 charcoal = vec3(0.062, 0.073, 0.088);   // #101318-ish rock  vec3 rockHi = vec3(0.400, 0.435, 0.485);   // lit rock crest
  vec3 ink = vec3(0.034, 0.038, 0.046);

  vec3 col = mix(deepNavy, charcoal, relief);
  // Raked-light terrain: the bump term sculpts the day/terminator band.
  col += rockHi * (bumpDiff - diff * 0.55) * 0.38;
  // Land albedo lift on the day side.
  col += rockHi * 0.30 * land * day;
  // KEY RIM — the signature white crescent (upper-left), stronger than
  // the old 0.85 mix: this is the line the reference sheet lives by.
  col += vec3(1.0, 1.0, 1.0) * rimKey * (0.70 + 0.45 * uAtmos) * 1.25;
  // Soft full-limb rim underneath (cool, slight blue).
  col += vec3(0.80, 0.86, 0.96) * rim * (0.50 + 0.45 * uAtmos) * 0.85;
  col += charcoal * day * 0.40;
  // Night-side city lights (from the baked mask) — brighter and warmer
  // than v0.5.4; the sheet's dark hemisphere is dotted with visible gold.
  float lightsPulse = lights * (0.80 + 0.20 * sin(uTime * 0.7 + uv.x * 40.0));
  col += vec3(1.00, 0.93, 0.74) * lightsPulse * (1.0 - day) * 1.55;
  // Faint rock texture on the night side so it is not a flat silhouette.
  col += vec3(0.05, 0.055, 0.065) * relief * (1.0 - day) * 0.55;
  col = mix(col, ink, 0.14); // cinematic crush (lighter than v0.5.4)

  // ── Land dot grid (hairline ink dots over the lit mask) ─────────────
  float dotGrid = 0.0;
  if (land > 0.5) {
    vec2 g = fract(uv * vec2(180.0, 90.0)) - 0.5;
    dotGrid = smoothstep(0.18, 0.06, length(g)) * 0.55;
  }
  col += vec3(0.75, 0.78, 0.84) * dotGrid * (0.30 + 0.40 * day);

  // ── Atmosphere: limb ring + soft halo just outside the disc ────────
  vec3 atmos = vec3(0.0);
  // Outer halo (adds glow on empty pixels too — keep when disc==0).
  // v0.5.5: tighter core, longer tail — reads as a glow, not a fog bank.
  float halo = exp(-max(r - R, 0.0) / (R * 0.13)) * (0.35 + 0.60 * uAtmos);
  vec3 haloCol = vec3(0.62, 0.68, 0.78);
  atmos += haloCol * halo * 1.05;
  // Inner atmosphere ring: light-scatter hugging the limb from inside.
  float inner = smoothstep(R * 0.86, R, r) *
      (0.20 + 0.55 * uAtmos) * (0.35 + 0.65 * day);
  atmos += vec3(0.70, 0.76, 0.86) * inner * disc;

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
