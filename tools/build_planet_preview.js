// Build a SELF-CONTAINED WebGL2 preview of the planet shader: inlines
// assets/shaders/planet.frag + the baked land mask, adapts the two Flutter
// bits (#include runtime_effect → gl_FragCoord), and renders the phone-hero
// composition (portrait, planet low-center). Write → open → screenshot →
// compare against the reference sheet → tune constants → re-run.
//
// Usage: node tools/build_planet_preview.js
'use strict';
const fs = require('fs');
const path = require('path');

const frag = fs
  .readFileSync(path.join(__dirname, '..', 'assets', 'shaders', 'planet.frag'), 'utf8')
  // ES 3.20 → WebGL2 (GLSL ES 3.00): drop the version line and the
  // Flutter include, expand FlutterFragCoord to gl_FragCoord.
  .replace(/^#version.*$/m, '')
  .replace(/^#include <flutter\/runtime_effect\.glsl>$/m, '')
  // FlutterFragCoord is Y-DOWN (top-left origin); WebGL's gl_FragCoord is
  // Y-UP. Mirror y so the harness matches the device composition exactly.
  .replace(/FlutterFragCoord\(\)/g,
      'vec4(gl_FragCoord.x, iResolution.y - gl_FragCoord.y, gl_FragCoord.zw)');

const mask = JSON.parse(
  fs.readFileSync(path.join(__dirname, 'land_mask.json'), 'utf8'));

const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Atlanhix planet preview (shader v0.5.5)</title>
<style>
  html, body { margin: 0; height: 100%; background: #04060a; overflow: hidden; }
  canvas { width: 100vw; height: 100vh; display: block; }
</style>
</head>
<body>
<canvas id="c"></canvas>
<script id="frag" type="x-shader">${frag.replace(/<\//g, '<\\/')}</script>
<script id="mask" type="application/json">${mask.data}</script>
<script>
const canvas = document.getElementById('c');
const gl = canvas.getContext('webgl2', { alpha: true, antialias: false, preserveDrawingBuffer: true });
if (!gl) document.title = 'FAIL: no webgl2';

const MASK_W = ${mask.width}, MASK_H = ${mask.height};
const maskBytes = Uint8Array.from(atob(document.getElementById('mask').textContent), c => c.charCodeAt(0));

function compile(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    document.title = 'SHADER ERROR';
    console.error(gl.getShaderInfoLog(s));
    throw new Error(gl.getShaderInfoLog(s));
  }
  return s;
}

const vsrc = '#version 300 es\\n' +
  'void main(){ vec2 p = vec2((gl_VertexID<<1)&2, gl_VertexID&2); ' +
  'gl_Position = vec4(p*2.0-1.0, 0.0, 1.0); }';
const fsrc = '#version 300 es\\nprecision highp float; precision highp sampler2D;\\n' +
  document.getElementById('frag').textContent;
const prog = gl.createProgram();
gl.attachShader(prog, compile(gl.VERTEX_SHADER, vsrc));
gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, fsrc));
gl.linkProgram(prog);
if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
  document.title = 'LINK ERROR';
  console.error(gl.getProgramInfoLog(prog));
  throw new Error(gl.getProgramInfoLog(prog));
}
gl.useProgram(prog);

const tex = gl.createTexture();
gl.activeTexture(gl.TEXTURE0);
gl.bindTexture(gl.TEXTURE_2D, tex);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, MASK_W, MASK_H, 0, gl.RGBA, gl.UNSIGNED_BYTE, maskBytes);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

const u = n => gl.getUniformLocation(prog, n);
gl.uniform1i(u('uLand'), 0);

function frame(tms) {
  const dpr = 2.0;
  const w = Math.floor(innerWidth * dpr), h = Math.floor(innerHeight * dpr);
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
  gl.viewport(0, 0, w, h);
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);
  // The app's uniform set (painter): uTime, uYaw, uPitch, uAtmos, uError,
  // uLit(upper-left), idle-state atmosphere 0.25.
  gl.uniform2f(u('iResolution'), w, h);
  gl.uniform1f(u('uTime'), tms / 1000.0);
  gl.uniform1f(u('uYaw'), 5.1);   // ~292° — the reference's main view longitude
  gl.uniform1f(u('uPitch'), 0.30);
  gl.uniform1f(u('uAtmos'), 0.25);
  gl.uniform1f(u('uError'), 0.0);
  gl.uniform2f(u('uLit'), -0.35, -0.25);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  if (window.__probePending) {
    window.__probePending = false;
    const W = canvas.width, H = canvas.height;
    const px = new Uint8Array(W * H * 4);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, px);
    const lum = (x, y) => { const i = (y * W + x) * 4; return (px[i] + px[i+1] + px[i+2]) / 3; };
    const cx = W / 2, cy = H * 0.54; // flip: shader's 0.46-from-top = 0.54-from-bottom
    const R = Math.min(W * 0.52, H * 0.50);
    const at = (ang, rr) => Math.round(lum(
        Math.round(cx + Math.cos(ang) * R * rr),
        Math.round(cy + Math.sin(ang) * R * rr)));
    // upper-left limb arc (canvas y-down → angle -135° = up-left)
    window.__probe = {
      W, H, R: Math.round(R),
      limbUL: at(-2.35, 0.96), limbUL2: at(-2.60, 0.96), limbUL3: at(-2.10, 0.96),
      limbLR: at(0.79, 0.96), top: at(-1.57, 0.96), left: at(3.14, 0.96),
      center: Math.round(lum(Math.round(cx), Math.round(cy))),
      globalMax: 0, gx: 0, gy: 0,
    };
    for (let y = 0; y < H; y += 5) for (let x = 0; x < W; x += 5) {
      const v = lum(x, y); if (v > window.__probe.globalMax) {
        window.__probe.globalMax = Math.round(v); window.__probe.gx = x; window.__probe.gy = y;
      }
    }
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
window.__ready = true;
</script>
</body>
</html>`;

const out = path.join(__dirname, 'planet_preview.html');
fs.writeFileSync(out, html);
console.log('wrote', out);
