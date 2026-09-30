// Bake the planet shader's land/night-lights mask from the Dart point cloud.
// Mirrors lib/presentation/globe/land_mask.dart exactly (512×256, R = land,
// G = night lights) so the WebGL harness previews the SAME texture the
// device shader samples. Output: tools/land_mask.json (width, height, data
// as base64 RGBA).
//
// Usage: node tools/bake_land_mask.js
'use strict';
const fs = require('fs');
const path = require('path');

// Pull the two arrays out of the generated Dart file (no Dart toolchain).
const src = fs.readFileSync(
    path.join(__dirname, '..', 'lib', 'presentation', 'globe', 'land_points.dart'),
    'utf8');

function extractArray(name) {
  const start = src.indexOf(`const List<double> ${name} = <double>[`);
  if (start < 0) throw new Error(`array ${name} not found`);
  const end = src.indexOf('];', start);
  const body = src.slice(start, end).split('[').pop();
  return body
      .replace(/<double>\[/, '')
      .split(',')
      .map((s) => parseFloat(s.trim()))
      .filter((v) => Number.isFinite(v));
}

const lats = extractArray('kLandLats');
const lons = extractArray('kLandLons');
const n = parseInt(src.match(/kLandPointCount = (\d+)/)[1], 10);
if (lats.length < n || lons.length < n) {
  throw new Error(`point count mismatch: ${lats.length}/${lons.length} vs ${n}`);
}

const W = 512, H = 256;
const land = new Float32Array(W * H);
const lights = new Float32Array(W * H);
const d2r = Math.PI / 180;

// Splat (same shape as land_mask.dart).
for (let i = 0; i < n; i++) {
  const lat = lats[i], lon = lons[i];
  const cosLat = Math.min(1.0, Math.max(0.12, Math.abs(Math.cos(lat * d2r))));
  const rx = Math.min(6, Math.max(1, Math.round(1.2 / cosLat)));
  const x = Math.min(W - 1, Math.max(0, Math.floor(((lon + 180) / 360) * W)));
  const y = Math.min(H - 1, Math.max(0, Math.floor(((90 - lat) / 180) * H)));
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -rx; dx <= rx; dx++) {
      const px = (x + dx + W) % W;
      const py = Math.min(H - 1, Math.max(0, y + dy));
      land[py * W + px] = 1;
    }
  }
}

// Night lights: DISCRETE CITY CLUSTERS (mirrors land_mask.dart v0.5.5):
// few coastal-weighted seeds, 3–8 dots each, NO skirt — the reference
// sheet's scattered gold on dark rock.
const rnd = mkRand(7);
function mkRand(seed) {
  let s = seed >>> 0;
  return () => {
    // mulberry32 — deterministic, matches the LOOK (not Dart's exact stream).
    s = (s + 0x6D2B79F5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const isLand = (x, y) => land[y * W + ((x % W) + W) % W] > 0;
const nearWater = (x, y) => {
  for (let dy = -2; dy <= 2; dy++) {
    for (let dx = -2; dx <= 2; dx++) {
      if (!isLand(x + dx, Math.min(H - 1, Math.max(0, y + dy)))) return true;
    }
  }
  return false;
};
function stampCluster(cx, cy, dots, base) {
  lights[cy * W + ((cx % W) + W) % W] = base;
  for (let k = 0; k < dots; k++) {
    const px = cx + Math.floor(rnd() * 7) - 3;
    const py = Math.min(H - 1, Math.max(0, cy + Math.floor(rnd() * 7) - 3));
    if (isLand(px, py)) {
      lights[py * W + ((px % W) + W) % W] =
          Math.min(1, base * (0.55 + 0.45 * rnd()));
    }
  }
}
let seeds = 0;
for (let a = 0; a < 12000 && seeds < 150; a++) {
  const x = Math.floor(rnd() * W), y = Math.floor(rnd() * H);
  if (isLand(x, y) && nearWater(x, y)) {
    stampCluster(x, y, 3 + Math.floor(rnd() * 6), 0.85 + 0.15 * rnd());
    seeds++;
  }
}
seeds = 0;
for (let a = 0; a < 8000 && seeds < 35; a++) {
  const x = Math.floor(rnd() * W), y = Math.floor(rnd() * H);
  if (isLand(x, y) && !nearWater(x, y)) {
    stampCluster(x, y, 2 + Math.floor(rnd() * 3), 0.45 + 0.25 * rnd());
    seeds++;
  }
}

const data = Buffer.alloc(W * H * 4);
for (let i = 0; i < W * H; i++) {
  data[i * 4 + 0] = Math.round(land[i] * 255);
  data[i * 4 + 1] = Math.round(lights[i] * 255);
  data[i * 4 + 2] = 0;
  data[i * 4 + 3] = 255;
}

const out = {
  width: W,
  height: H,
  points: n,
  data: data.toString('base64'),
};
fs.writeFileSync(path.join(__dirname, 'land_mask.json'), JSON.stringify(out));
console.log(`baked ${W}x${H} mask from ${n} points -> tools/land_mask.json`);
