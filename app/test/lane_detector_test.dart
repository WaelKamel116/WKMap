import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cairo_nav/vision/lane_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// A made-up dash-camera picture: sky and buildings that change from frame to
/// frame, grey road with dashed lane lines running to a vanishing point at
/// (135, 200), and a still bonnet from row 330 down.
Uint8List frame(int n, List<double> linesU, math.Random rnd, {double vx = 100, double vy = 250}) {
  const w = LaneDetector.w, h = LaneDetector.h;
  final g = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int v;
      if (y >= 330) {
        v = 40 + (x ~/ 30) % 3 * 6; // bonnet: never changes
      } else if (y < vy + 8) {
        v = 120 + rnd.nextInt(90); // sky and buildings, changing
      } else {
        v = 85 + rnd.nextInt(14); // asphalt with grain
      }
      g[y * w + x] = v;
    }
  }
  for (final u in linesU) {
    for (var y = (vy + 12).round(); y < 330; y++) {
      // dashes 3 m painted / 6 m gap, moving towards the car as it drives
      final z = 1.25 * 400 / (y - vy); // rough distance ahead, metres
      if (((z + n * 1.7) % 9) > 3) continue;
      final x = vx + u * (y - vy);
      final half = math.max(1.0, 0.12 / 1.25 * (y - vy) / 2);
      for (var xx = (x - half).round(); xx <= (x + half).round(); xx++) {
        if (xx >= 0 && xx < w) g[y * w + xx] = 200;
      }
    }
  }
  return g;
}

void main() {
  test('finds the bonnet, the vanishing point and the lanes in a synthetic road', () {
    final rnd = math.Random(3);
    final d = LaneDetector();
    // the two lines of the car's lane, 2.7 u apart, the car a bit right of its centre
    // (lines further out are only in view near the horizon; reading() covers several lanes)
    const lines = [-1.2, 1.5];
    LaneReading? r;
    var t = DateTime(2026);
    for (var n = 0; n < 60; n++) {
      t = t.add(const Duration(milliseconds: 330));
      r = d.addFrame(frame(n, lines, rnd), t) ?? r;
    }
    // ignore: avoid_print
    print('hood ${d.hoodRow}, segments ${d.segmentCount}, vanishing point ${d.vp}, lane width ${d.laneWidthU.toStringAsFixed(2)} u, $r');
    expect(d.hoodRow, inInclusiveRange(316, 340));
    expect(d.vp!.$1, closeTo(100, 8));
    expect(d.vp!.$2, closeTo(250, 10));
    expect(r, isNotNull);
    expect(r!.lanes, 1);
    expect(r.lane, 1);
    expect(r.offsetM, closeTo(-0.15 * 1.25, 0.35));
  });

  test('lane reading from line positions', () {
    final t = DateTime(2026);
    // four lines, car in the third lane
    final r = LaneDetector.reading([-6.7, -4.0, -1.3, 1.4], 2.7, t, 1.25)!;
    expect(r.lanes, 3);
    expect(r.lane, 3);
    // only one side seen: no reading
    expect(LaneDetector.reading([-1.3, -4.0], 2.7, t, 1.25), isNull);
  });
}
