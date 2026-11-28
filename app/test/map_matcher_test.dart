import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cairo_nav/geo/geo.dart';
import 'package:cairo_nav/nav/car_smoother.dart';
import 'package:cairo_nav/nav/map_matcher.dart';
import 'package:cairo_nav/nav/match_data.dart';
import 'package:cairo_nav/nav/route_data.dart';
import 'package:flutter_test/flutter_test.dart';

MatchLine line(String name, List<List<double>> xy, {bool oneway = false, double height = 0}) =>
    MatchLine(name, oneway, height > 0, [for (final p in xy) Vec(p[0], p[1])], List.filled(xy.length, height));

/// Distance across from [p] to [l] (0 when p lies on the line).
double offLine(MatchLine l, Vec p) {
  var best = double.infinity;
  for (var i = 0; i < l.pts.length - 1; i++) {
    best = math.min(best, projectOnSegment(p, l.pts[i], l.pts[i + 1]).distance);
  }
  return best;
}

/// The old way: nearest road that fits the direction.
Candidate? nearest(MatchData d, Vec p, double speed, double heading) {
  final c = d.candidates(p, 20, speed > 2 ? heading : null, maxAngle: 35);
  return c.isEmpty ? null : c.first;
}

void main() {
  final rnd = math.Random(11);
  double gauss() => math.sqrt(-2 * math.log(1 - rnd.nextDouble())) * math.cos(2 * math.pi * rnd.nextDouble());

  test('noisy GPS next to a parallel service road stays on the main road', () {
    final d = MatchData([
      line('Main Road', [[-600, 0], [600, 0]]),
      line('Service Road', [[-400, 11], [400, 11]], oneway: true),
    ]);
    final m = MapMatcher(d);
    var hmm = 0, near = 0, n = 0;
    for (var x = -550.0; x < 550; x += 14) {
      final p = Vec(x + gauss() * 6, gauss() * 6);
      final a = m.update(p, accuracy: 6, speed: 14, heading: 90);
      final b = nearest(d, p, 14, 90);
      if (x.abs() < 380) {
        n++;
        if (a?.line.name == 'Main Road') hmm++;
        if (b?.line.name == 'Main Road') near++;
      }
    }
    // ignore: avoid_print
    print('main road: path matching $hmm / $n, nearest road $near / $n');
    expect(hmm / n, greaterThan(0.95));
    expect(hmm, greaterThan(near));
  });

  test('turning at a junction moves to the side street within two fixes', () {
    final d = MatchData([
      line('East Street', [[-400, 0], [0, 0], [400, 0]]),
      line('North Street', [[0, 0], [0, 400]]),
    ]);
    final m = MapMatcher(d);
    for (var x = -300.0; x <= 0; x += 12) {
      m.update(Vec(x + gauss() * 3, gauss() * 3), accuracy: 4, speed: 12, heading: 90);
    }
    Candidate? c;
    var fixes = 0;
    for (var y = 12.0; y <= 120; y += 12) {
      c = m.update(Vec(gauss() * 3, y + gauss() * 3), accuracy: 4, speed: 12, heading: 0);
      fixes++;
      if (c?.line.name == 'North Street') break;
    }
    expect(c?.line.name, 'North Street');
    expect(fixes, lessThanOrEqualTo(2));
  });

  test('a one-way road is not matched against its direction', () {
    final d = MatchData([
      line('One Way East', [[-400, 0], [400, 0]], oneway: true),
      line('Two Way', [[-400, 9], [400, 9]]),
    ]);
    final m = MapMatcher(d);
    Candidate? c;
    for (var x = 300.0; x > -300; x -= 12) {
      c = m.update(Vec(x + gauss() * 4, 3 + gauss() * 4), accuracy: 5, speed: 12, heading: 270);
    }
    expect(c?.line.name, 'Two Way');
  });

  test('on a flyover above a road, the level decides which one', () {
    final d = MatchData([
      line('Road Below', [[-400, 0], [400, 0]]),
      line('Flyover', [[-400, 1.5], [400, 1.5]], height: 7),
    ]);
    final up = MapMatcher(d), down = MapMatcher(d);
    Candidate? a, b;
    for (var x = -300.0; x < 300; x += 14) {
      final p = Vec(x + gauss() * 5, gauss() * 5);
      a = up.update(p, accuracy: 5, speed: 14, heading: 90, onFlyover: true);
      b = down.update(p, accuracy: 5, speed: 14, heading: 90, onFlyover: false);
    }
    expect(a?.line.name, 'Flyover');
    expect(b?.line.name, 'Road Below');
  });

  test('gyroscope: offset learned while stopped, sign confirmed on turns, then trusted', () {
    final g = GyroHeading();
    // stopped for 5 s: the sensor reads a constant 0.8 deg/s offset
    for (var s = 0; s < 5; s++) {
      for (var i = 0; i < 10; i++) {
        g.add(0.8, 0.1);
      }
      g.onFix(90, 0);
    }
    expect(g.bias, closeTo(0.8, 0.4));
    expect(g.trusted, isFalse);
    // driving through bends: GPS course turns 10 deg per second, the gyro agrees
    var h = 90.0;
    for (var s = 0; s < 6; s++) {
      for (var i = 0; i < 10; i++) {
        g.add(10 + 0.8, 0.1);
      }
      h += 10;
      g.onFix(h, 12);
    }
    expect(g.trusted, isTrue);
    expect(g.rate, closeTo(10, 0.5));
  });

  group('real map', () {
    late MatchData match;
    late RouteData nasr, cfc;
    RouteData load(String p) => RouteData.fromJson(jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>);
    setUpAll(() {
      match = MatchData.fromJson(jsonDecode(File('assets/data/match.json').readAsStringSync()) as Map<String, dynamic>);
      nasr = load('test/fixtures/nasr_route.json');
      cfc = load('assets/data/route.json');
    });

    /// Drives [route] with 5 m GPS noise; counts fixes matched to a road that does
    /// not pass within 3 m of the true position (another road), for path matching and nearest road.
    (int, int, int) drive(RouteData route) {
      final m = MapMatcher(match);
      var hmmOff = 0, nearOff = 0, n = 0;
      for (var s = 0.0; s < route.distance; s += 15) {
        final t = route.sample(s);
        final truth = Geo.toXY(t.lon, t.lat);
        final p = truth + Vec(gauss() * 5, gauss() * 5);
        final hdg = t.heading + gauss() * 3;
        final a = m.update(p, accuracy: 5, speed: 15, heading: hdg, onFlyover: t.height > 2.5);
        final b = nearest(match, p, 15, hdg);
        if (a == null && b == null) continue;
        n++;
        if (a == null || offLine(a.line, truth) > 3) hmmOff++;
        if (b == null || offLine(b.line, truth) > 3) nearOff++;
      }
      // ignore: avoid_print
      print('fixes on the wrong road: path matching $hmmOff / $n, nearest road $nearOff / $n');
      return (hmmOff, nearOff, n);
    }

    test('El Nasr Road: path matching puts the car on the right road', () {
      final (hmm, near, n) = drive(nasr);
      expect(hmm / n, lessThan(0.05));
      expect(hmm, lessThanOrEqualTo(near));
    });

    test('City Stars to Cairo Festival City: path matching puts the car on the right road', () {
      final (hmm, near, n) = drive(cfc);
      expect(hmm / n, lessThan(0.05));
      expect(hmm, lessThanOrEqualTo(near));
    });
  });
}
