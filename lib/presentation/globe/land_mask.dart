// GENERATED-AT-RUNTIME — no external tools. Derives the land-mask data the
// planet shader needs from the SAME source the point-cloud globe uses
// (lib/presentation/globe/land_points.dart — world-atlas countries-110m).
//
// Output: a 512×256 RGBA byte image (one shot, cached forever — baking is
// ~2 ms):
//   * R = land        (1.0 on land — the shader's continents)
//   * G = night-light luminance (city clusters glow on the dark side)
//   * B/A = 0 (spare)
//
// The point cloud is an equal-area ring sample, so splatting its points
// into equirectangular cells reproduces the continents exactly at the
// resolution the shader reads them; a light blur joins the dots into
// solid coastlines.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'land_points.dart';

const int kMaskWidth = 512;
const int kMaskHeight = 256;

ui.Image? _cached;

/// The baked land/night-lights mask. ~1.3 ms first call, then free.
Future<ui.Image?> landMaskImage() async {
  if (_cached != null) return _cached;
  const w = kMaskWidth;
  const h = kMaskHeight;
  final land = Float32List(w * h);
  final lights = Float32List(w * h);

  // ── Splat the land point cloud (equal-area sample → equirect cells) ──
  const d2r = math.pi / 180;
  for (var i = 0; i < kLandPointCount; i++) {
    final lat = kLandLats[i];
    final lon = kLandLons[i];
    // Equal-area rings: high latitudes pack more points per degree of
    // longitude — normalize the splat radius so coastlines stay even.
    final cosLat = math.cos(lat * d2r).abs().clamp(0.12, 1.0);
    final rx = (1.2 / cosLat).clamp(1.0, 6.0).round();
    final x = (((lon + 180) / 360) * w).floor().clamp(0, w - 1);
    final y = (((90 - lat) / 180) * h).floor().clamp(0, h - 1);
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -rx; dx <= rx; dx++) {
        final px = (x + dx + w) % w; // equirect wrap-around
        final py = (y + dy).clamp(0, h - 1);
        land[py * w + px] = 1;
      }
    }
  }

  // ── Night lights: cluster detection on the land mask ────────────────
  // City light = land with many land-neighbors in a 9×9 window (dense
  // regions) — a cheap convolution standing in for a real lights map.
  for (var y = 2; y < h - 2; y++) {
    for (var x = 0; x < w; x++) {
      if (land[y * w + x] == 0) continue;
      var n = 0;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          if (land[(y + dy) * w + ((x + dx + w) % w)] > 0) n++;
        }
      }
      // n in [1..25]; dense cores light up, sparse coasts stay dark.
      final lum = ((n - 14) / 11).clamp(0.0, 1.0);
      if (lum > 0) lights[y * w + x] = lum;
    }
  }
  // Lights shimmer pool: a second, larger ring adds the glow skirt.
  final skirt = Float32List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 0; x < w; x++) {
      if (lights[y * w + x] > 0) continue;
      var acc = 0.0;
      for (var dy = -3; dy <= 3; dy += 2) {
        for (var dx = -3; dx <= 3; dx += 2) {
          acc += lights[(y + dy) * w + ((x + dx + w) % w)];
        }
      }
      if (acc > 0) skirt[y * w + x] = (acc / 16) * 0.5;
    }
  }
  for (var i = 0; i < lights.length; i++) {
    lights[i] = math.min(1.0, lights[i] + skirt[i]);
  }

  // ── Pack to RGBA bytes ───────────────────────────────────────────────
  final data = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    data[i * 4 + 0] = (land[i] * 255).round().clamp(0, 255);
    data[i * 4 + 1] = (lights[i] * 255).round().clamp(0, 255);
    // B: a faint latitude gradient the shader can shade with (spare).
    data[i * 4 + 2] = 0;
    data[i * 4 + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    data,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  _cached = await completer.future;
  return _cached;
}

/// Test hook: resets the cached mask (tests re-bake with fresh state).
void resetLandMaskForTest() => _cached = null;
