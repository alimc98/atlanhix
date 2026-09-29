#!/usr/bin/env node
/*
 * One-shot generator (v0.5.2 §globe): decodes the world-atlas land-110m
 * TopoJSON (Natural Earth 1:110m land) into an equal-area ring sample and
 * writes lib/presentation/globe/land_points.dart.
 *
 * Re-run only when regenerating the asset:
 *   node tools/extract_land_points.js <path-to-land-110m.json>
 * Source: https://cdn.jsdelivr.net/npm/world-atlas@2/land-110m.json
 */
'use strict';
const fs = require('fs');

const file = process.argv[2] || '/tmp/land-110m.json';
const topo = JSON.parse(fs.readFileSync(file, 'utf8'));

// --- TopoJSON decode: quantized arcs → absolute [lon,lat] rings -------------
const arcsRaw = topo.arcs.map((arc) => {
  let x = 0, y = 0;
  return arc.map(([dx, dy]) => {
    x += dx; y += dy;
    return [x, y];
  });
});

function ringCoords(arcIdxList) {
  const pts = [];
  for (const ai of arcIdxList) {
    let a = ai;
    let rev = false;
    if (a < 0) { a = ~a; rev = true; }
    const arc = arcsRaw[a];
    if (rev) for (const p of arc.slice().reverse()) pts.push(p);
    else for (const p of arc) pts.push(p);
  }
  return pts;
}

// --- Per-polygon planar PNPoly on a gnomonic-like chart ---------------------
// Each polygon's lon span here is < 180°, so the flat chart
// X = (lon - lon0)·cos(midLat), Y = lat is monotone and faithful for
// containment at our 0.5°-ish sampling pitch.
const land = topo.objects.land;
const polys = []; // { x0, k, pts: [[x,y],…] }
for (const geom of land.geometries) {
  const multi =
    geom.type === 'Polygon' ? [geom.arcs] :
    geom.type === 'MultiPolygon' ? geom.arcs : [];
  for (const rings of multi) {
    const lons = [], lats = [];
    const ringPts = rings.map((r) => ringCoords(r));
    for (const pts of ringPts) {
      for (const [lo, la] of pts) { lons.push(lo); lats.push(la); }
    }
    const lon0 = Math.min(...lons);
    const lonSpan = Math.max(...lons) - lon0;
    const midLat = (Math.min(...lats) + Math.max(...lats)) / 2;
    const k = Math.cos(midLat * Math.PI / 180);
    // Small ring far from the chart anchor → skip (nothing lands there).
    if (k <= 0.02) continue;
    const x0 = lon0 + lonSpan / 2;
    const pts = ringPts.map((pts) =>
      pts.map(([lo, la]) => [(lo - x0) * k, la]));
    polys.push({ x0, k, pts });
  }
}

// --- Equal-area acceptance grid (Fibonacci sphere) ---------------------------
// ~0.9 rings/deg² → ~62k accepted points. Deterministic (fixed golden-angle
// order); no RNG so regenerations are byte-stable.
const N = 62000;
const golden = Math.PI * (3 - Math.sqrt(5));
const R = 4 / Math.sqrt(N); // acceptance radius in chart units

function inside(poly, x, y) {
  let inr = false;
  for (const ring of poly.pts) {
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const [xi, yi] = ring[i];
      const [xj, yj] = ring[j];
      if ((yi > y) !== (yj > y) &&
          x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) {
        inr = !inr;
      }
    }
  }
  return inr;
}

const out = [];
for (let i = 0; i < N; i++) {
  const z = 1 - (2 * (i + 0.5)) / N;           // [1..-1]
  const lat = Math.asin(z) * 180 / Math.PI;
  const lon0 = ((i * golden) % (2 * Math.PI)) - Math.PI; // [-π..π)
  const lon = lon0 * 180 / Math.PI;
  let hit = false;
  for (const poly of polys) {
    const dx = lon - poly.x0;
    if (dx < -180 || dx > 180) continue;
    const x = dx * poly.k;
    // Broad-phase: cheap AABB from the polygon bounds.
    if (x < poly.minX || x > poly.maxX || lat < poly.minY || lat > poly.maxY) continue;
    if (inside(poly, x, lat)) { hit = true; break; }
  }
  if (hit) out.push([lat, lon]);
}

// Fill the accepted set with nearest neighbors so every land cell is covered
// (rejection on the sphere, no projection distortion).
const R2 = R * R;
const cells = new Map(); // quantized unit-sphere key → [lat,lon]
const key = (lat, lon) => {
  const cl = Math.cos(lat * Math.PI / 180);
  return [
    Math.round(cl * Math.cos(lon * Math.PI / 180) * 40),
    Math.round(cl * Math.sin(lon * Math.PI / 180) * 40),
    Math.round(Math.sin(lat * Math.PI / 180) * 40),
  ].join(',');
};
for (const p of out) cells.set(key(p[0], p[1]), p);

const accepted = [];
const seen = new Set();
for (let i = 0; i < N * 4 && accepted.length < 62000; i++) {
  const z = 1 - (2 * (i + 0.5)) / (N * 4);
  const lat = Math.asin(z) * 180 / Math.PI;
  const lon = (((i * golden) % (2 * Math.PI)) - Math.PI) * 180 / Math.PI;
  const kk = key(lat, lon);
  if (cells.has(kk) && !seen.has(kk)) { seen.add(kk); accepted.push(cells.get(kk)); continue; }
  if (cells.size === 0) break;
  // nearest neighbor via coarse scan of the map (N=62k → fine at build time)
  const cl = Math.cos(lat * Math.PI / 180);
  const vx = cl * Math.cos(lon * Math.PI / 180), vy = cl * Math.sin(lon * Math.PI / 180), vz = Math.sin(lat * Math.PI / 180);
  let best = null, bd = Infinity;
  for (const p of cells.values()) {
    const pcl = Math.cos(p[0] * Math.PI / 180);
    const px = pcl * Math.cos(p[1] * Math.PI / 180), py = pcl * Math.sin(p[1] * Math.PI / 180), pz = Math.sin(p[0] * Math.PI / 180);
    const d = (px - vx) ** 2 + (py - vy) ** 2 + (pz - vz) ** 2;
    if (d < bd) { bd = d; best = p; }
  }
  if (bd <= R2) { const k2 = key(best[0], best[1]); if (!seen.has(k2)) { seen.add(k2); accepted.push(best); } }
}

// Emit as Dart: two Float32List with interleaved (lat, lon).
const lats = accepted.map((p) => Math.round(p[0] * 100) / 100);
const lons = accepted.map((p) => Math.round(p[1] * 100) / 100);

const header = `// GENERATED FILE — do not edit by hand.
// Regenerate: node tools/extract_land_points.js <land-110m.json>
// Source: world-atlas 2.x land-110m (Natural Earth 1:110m land), decoded to
// an equal-area ring sample by tools/extract_land_points.js.
//
// v0.5.2 §globe: the dashboard globe samples this point cloud directly —
// no asset loading, no parsing, no geometry library at runtime.

part of 'globe_painter.dart';
`;

// Chunk the literals to keep lines manageable.
function chunk(arr, per) {
  const lines = [];
  for (let i = 0; i < arr.length; i += per) {
    lines.push('  ' + arr.slice(i, i + per).join(', ') + ',');
  }
  return lines.join('\n');
}

const dart = `${header}
// ignore_for_file: lines_longer_than_80_chars

const int kLandPointCount = ${accepted.length};

const List<double> kLandLats = <double>[
${chunk(lats.map((v) => v.toFixed(2)), 10)}
];

const List<double> kLandLons = <double>[
${chunk(lons.map((v) => v.toFixed(2)), 10)}
];
`;

fs.mkdirSync('lib/presentation/globe', { recursive: true });
fs.writeFileSync('lib/presentation/globe/land_points.dart', dart);
console.log('points:', accepted.length, '→ lib/presentation/globe/land_points.dart');
