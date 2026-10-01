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
  // Key light from uLit (view space). v0.5.5 §tune3: uLit stays in SCREEN
  // coords (y grows down — the painter's (-0.35,-0.25) means upper-left)
  // and the crescent math below works in the same screen space, so NO y
  // flip anywhere in the light path. (The old flip put the sheet's upper-
  // left crescent at the LOWER-left.) z is NEGATIVE — the light sits
  // BEHIND the upper-left limb, so the lit band is a thin CRESCENT.
  // v0.5.6 §globe-fix: `L` has z = -0.30, so it points AWAY from the camera.
  // That makes `diff = dot(n, L)` at most ~0.28 across the whole disc and
  // ~0 over the entire facing hemisphere — so `day` was ~0 almost
  // everywhere and the terrain/key-rim had nothing to light. The sheet's
  // planet is lit from the UPPER-LEFT with a broad soft terminator, not
  // from behind the camera. Put the light slightly IN FRONT of the sphere
  // (z > 0) so the upper-left quadrant actually receives light and the
  // lower-right falls into night.
  vec3 L = normalize(vec3(uLit.x, uLit.y, 0.42));
  float diff = max(dot(n, L), 0.0);
  float day = pow(diff, 0.85);
  // Rim: grazing angles glow cool-white (the reference's limb light).
  float rim = pow(1.0 - max(dot(n, vec3(0, 0, 1)), 0.0), 2.6);
  // v0.5.6 §globe-fix: keep a THIN cool edge all the way round so the
  // planet still reads as a sphere against black even where the key
  // light is absent — but strictly at the grazing edge, not as a fog
  // spilling inward across the disc.
  rim *= 1.0 - smoothstep(0.86, 1.0, length(p) / R);
  // KEY RIM (v0.5.5 §tune3): a GEOGRAPHIC crescent — glow measured by how
  // close the DISC POINT (p/R) sits to the light's limb direction, times
  // grazing-ness. Dot-product-with-L lobes came out invisible on the
  // dark base; this guarantees a bright, tight band exactly where the
  // sheet puts it (the upper-left limb arc).
  // §tune5: the painter's uLit is a gentle (-0.35,-0.25) — nearly
  // horizontal — so the crescent hugged the LEFT extreme of the limb.
  // Rotate the direction 35° toward the top: in screen y-down space the
  // upper-left diagonal sits at ~215°, and +35° carries (-0.83,-0.59)
  // (144°... the normalize gives atan2 ≈ -144°) up to ≈ -179°+wrap →
  // verified by probe: max lands at the upper-left diagonal.
  vec2 ld = normalize(uLit);
  const float ROT = 35.0 * 3.14159265 / 180.0;
  vec2 limbDir = vec2(ld.x * cos(ROT) - ld.y * sin(ROT),
                      ld.x * sin(ROT) + ld.y * cos(ROT));
  float limbFacing = max(dot(p / R, limbDir), 0.0);
  // §tune4/8: the sheet's crescent is a BOLD, TIGHT white ridge sitting
  // right ON the limb — bright from ~0.80 of the radius outward, gone by
  // ~2/3 in (the wash must NOT fog the upper-left quadrant).
  // v0.5.6 §globe-fix: the band reached 34% of the radius INWARD
  // (0.66..0.90) and peaked at 1.45, which read as a broad wash flooding
  // the upper-left quadrant. The sheet's crescent is a NARROW ridge right
  // on the limb — it starts at ~0.88 of the radius and the falloff is
  // steep, so the lit rock is a band you could cover with a thumb.
  float band = smoothstep(0.88, 0.985, length(p) / R) * limbFacing;
  float rimKey = pow(band, 2.2) * 1.25;
  // Terrain shading: cheap normal perturbation from the relief field so
  // the light rakes across the rock (the close-up's craters/ridges).
  vec3 bumpN = normalize(n + vec3(
      (fbm(wuv * vec2(24.0, 12.0) + vec2(5.2, 1.3)) - 0.5) * 0.55,
      (fbm(wuv * vec2(24.0, 12.0) + vec2(9.8, 4.4)) - 0.5) * 0.55,
      0.0));
  float bumpDiff = max(dot(bumpN, L), 0.0);

  // ── Surface shading ─────────────────────────────────────────────────
  vec3 deepNavy = vec3(0.014, 0.018, 0.026);   // near-black ocean floor
  vec3 charcoal = vec3(0.046, 0.055, 0.068);   // dark rock
  vec3 rockHi = vec3(0.400, 0.435, 0.485);     // lit rock crest
  vec3 ink = vec3(0.028, 0.032, 0.040);

  // v0.5.6 §globe-fix: the ocean is NOT flat. Real bathymetry gives the
  // sea floor faint structure; a completely uniform `deepNavy` made the
  // water read as a hole cut in the planet. Modulate it with the same
  // relief field (at lower contrast) so the disc has material all the
  // way out, while staying far darker than the rock.
  vec3 col = mix(deepNavy, charcoal, relief * 0.85 + 0.06);
  // Raked-light terrain: the bump term sculpts the crescent band.
  // v0.5.6 §globe-fix: steepened so the raking light sculpts relief on the
  // lit limb instead of washing a flat gray across the whole day side.
  col += rockHi * (bumpDiff - diff * 0.55) * 0.85 * pow(day, 1.5);
  // Land albedo lift. v0.5.6 §globe-fix: this used to be gated on `day`,
  // but the new front-lit `day` sits around 0.3–0.6 over most of the lit
  // hemisphere, so continents came out as a flat, evenly-lit cutout that
  // erased the terminator. Land must follow the LIGHTING curve much more
  // steeply than the ocean does — rock catches the raking light, water
  // barely does — which is what makes the coastlines read as terrain.
  float landDay = pow(day, 1.9);
  col += rockHi * 0.30 * land * landDay;
  // KEY RIM — the signature white crescent (upper-left). Full white
  // saturation: the sheet's ridge is the brightest thing in the frame.
  // v0.5.6 §globe-fix: rimKey is a LIGHTING term, so it obeys the day side.
  // It used to be added raw, stamping a white crescent onto the DARK
  // hemisphere as well and flattening the terminator the composition
  // depends on. `day` already encodes the terminator; a small floor keeps
  // the limb ridge faintly alive right at the boundary instead of
  // snapping off.
  float rimGate = 0.06 + 0.94 * day;
  col += vec3(1.0, 1.0, 1.0) * rimKey * rimGate *
      (0.70 + 0.45 * uAtmos) * 2.20;
  // Soft full-limb rim underneath (cool, slight blue) — kept SUBTLE so
  // the right/lower limb stays dark like the sheet.
  col += vec3(0.80, 0.86, 0.96) * rim * (0.50 + 0.45 * uAtmos) * 0.22;
  // v0.5.6 §globe-fix: the ambient term was strong enough to lift the whole
  // night side into visible gray. Atlanhix is an ALMOST-BLACK planet —
// keep this as the faintest sheen so the unlit hemisphere genuinely falls
  // to black and the terminator stays dramatic.
  col += charcoal * day * 0.16;
  // Night-side city lights — the baked G channel holds SCATTERED golden
  // dots (coastal-weighted, see land_mask.dart). Add a per-dot shimmer;
  // no thresholding needed anymore — the mask IS the city structure.
  // v0.5.9 §dark-fix ("کره توی نسخه دارک اصلا واضح نیست"): the app runs
  // DARK-FIRST (background #0A0B0E vs the planet's near-black base — the
  // disc blends INTO the page). The old 1.30 gain left the dots at ~15%
  // luminance after the crush below; 2.4× with a higher floor keeps the
  // night side ALIVE — visible cities + readable terrain against the
  // page black, while the lit crescent stays the brightest element.
  float lightsPulse = lights * (0.55 + 0.45 * sin(uTime * 0.7 + uv.x * 40.0));
  col += vec3(1.00, 0.90, 0.68) * lightsPulse * (1.0 - day) * 2.40;
  // Faint rock texture on the night side so it is not a flat silhouette.
  // v0.5.9 §dark-fix: doubled — with the old 0.50 the unlit hemisphere
  // read as a flat black hole even where continents crossed it.
  col += vec3(0.042, 0.047, 0.056) * relief * (1.0 - day) * 0.95;
  // v0.5.9 §dark-fix: the crush went 0.22 → 0.10. The heavy mix pulled
  // EVERYTHING (terrain, lights, the terminator gradient) toward flat
  // ink — on a dark page that is self-erasure. 0.10 keeps cinematic
  // blacks in the oceans without swallowing the night-side detail.
  col = mix(col, ink, 0.10); // cinematic crush — the sheet's deep blacks

  // ── Land dot grid ───────────────────────────────────────────────────
  // v0.5.6 §globe-fix: this grid was a leftover from the point-cloud era
  // and reads as a mechanical mesh printed over the continents — exactly
  // the "technical wireframe" texture the brief rules out. The land now
  // reads through relief + albedo instead. Kept only as a whisper on the
  // lit crescent (where the sheet does show fine surface grain).
  // v0.5.6 §globe-fix: REMOVED the point-cloud dot grid entirely. Even at
  // 16% it printed a visible regular lattice across every landmass (the
  // earlier screenshots showed it clearly over North/South America) —
  // a wireframe read, not rocky terrain. The relief + albedo now carry
  // the surface on their own.

  // ── Atmosphere: limb ring + soft halo just outside the disc ────────
  vec3 atmos = vec3(0.0);
  // Outer halo: a skirt OUTSIDE the limb only (see §globe-fix below).
  // Tight core, short tail — a glow, not a fog bank. Biased to the LIGHT
  // side (the sheet's halo is brightest above the crescent).
  float lightBias = 0.55 + 0.45 * max(dot(normalize(vec3(p, 0.0)),
      normalize(vec3(uLit, 0.0))), 0.0);
  // v0.5.6 §globe-fix: `exp(-max(r - R, 0) / (R*0.10))` is EXACTLY 1.0
  // for every pixel inside the disc (max() clamps the offset to 0), so the
  // halo used to add a full-strength cool wash over the WHOLE planet —
  // that is the "pale ghost ball" look, not an atmosphere. Gate it to the
  // region it is supposed to occupy: a decaying skirt OUTSIDE the limb.
  // `outside` is 1 beyond R and fades over ~4% of R at the boundary so
  // there is no hard seam.
  float outside = smoothstep(R * 0.96, R * 1.02, r);
  float halo = exp(-max(r - R, 0.0) / (R * 0.09)) *
      (0.30 + 0.55 * uAtmos) * lightBias * outside;
  vec3 haloCol = vec3(0.62, 0.68, 0.78);
  atmos += haloCol * halo * 0.95;
  // Inner atmosphere ring: light-scatter hugging the limb from inside,
  // strongest near the crescent.
  // v0.5.6 §globe-fix: hug the limb only (was 0.88 → 12% of the radius of
  // inward scatter, which combined with the fixed halo washed the disc).
  float inner = smoothstep(R * 0.955, R, r) *
      (0.10 + 0.34 * uAtmos) * (0.20 + 0.80 * day);
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
