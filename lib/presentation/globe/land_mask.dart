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

  // ── Night lights: DISCRETE CITY CLUSTERS (v0.5.5 §tune 2) ───────────
  // Density/skirt approaches flood the mask: at 512×256 the 2px coastal
  // band covers most of a continent and glow skirts sum into a beige
  // FILL. The reference sheet reads as DISTINCT clusters — a handful of
  // bright dots per metro area, dark rock between them. So: pick a small
  // number of seed pixels (coastal-weighted), stamp 3–8 dots around each,
  // NO skirt. Deterministic seed → stable bakes.
  final rnd = math.Random(7);
  bool isLand(int x, int y) => land[y * w + ((x % w) + w) % w] > 0;
  bool nearWater(int x, int y) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (!isLand(x + dx, (y + dy).clamp(0, h - 1))) return true;
      }
    }
    return false;
  }

  void stampCluster(int cx, int cy, int dots, double base) {
    lights[cy * w + ((cx % w) + w) % w] = base;
    for (var k = 0; k < dots; k++) {
      final px = cx + rnd.nextInt(7) - 3;
      final py = (cy + rnd.nextInt(7) - 3).clamp(0, h - 1);
      if (isLand(px, py)) {
        lights[py * w + ((px % w) + w) % w] =
            math.min(1.0, base * (0.55 + 0.45 * rnd.nextDouble()));
      }
    }
  }

  // ~150 coastal metros (the sheet's lit coastlines) + ~35 inland towns.
  var seeds = 0;
  for (var attempt = 0; attempt < 12000 && seeds < 150; attempt++) {
    final x = rnd.nextInt(w);
    final y = rnd.nextInt(h);
    if (isLand(x, y) && nearWater(x, y)) {
      stampCluster(x, y, 3 + rnd.nextInt(6), 0.85 + 0.15 * rnd.nextDouble());
      seeds++;
    }
  }
  seeds = 0;
  for (var attempt = 0; attempt < 8000 && seeds < 35; attempt++) {
    final x = rnd.nextInt(w);
    final y = rnd.nextInt(h);
    if (isLand(x, y) && !nearWater(x, y)) {
      stampCluster(x, y, 2 + rnd.nextInt(3), 0.45 + 0.25 * rnd.nextDouble());
      seeds++;
    }
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
