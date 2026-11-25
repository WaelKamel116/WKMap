import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cairo_nav/geo/geo.dart';
import 'package:cairo_nav/nav/level_detector.dart';
import 'package:cairo_nav/nav/match_data.dart';
import 'package:cairo_nav/nav/route_data.dart';
import 'package:flutter_test/flutter_test.dart';

const hpaPerMetre = 1 / 8.4;

/// A flyover running east, 7 m high in the middle, directly above a ground road.
MatchData stacked() {
  final pts = [const Vec(-300, 0), const Vec(-150, 0), const Vec(150, 0), const Vec(300, 0)];
  return MatchData([
    MatchLine('Test Flyover', true, true, pts, [0, 7, 7, 0]),
    MatchLine('Ground Road', true, false, [const Vec(-300, -6), const Vec(300, -6)], [0, 0]),
    MatchLine('Side Street', false, false, [const Vec(-1000, 500), const Vec(-600, 500)], [0, 0]),
  ]);
}

List<double> ll(double x, double y) => Geo.toLonLat(Vec(x, y));

/// Learn ground pressure on a street with no flyover nearby.
void learnBaseline(LevelDetector d, double groundHpa) {
  for (var i = 0; i < 30; i++) {
    d.addPressure(groundHpa);
    final p = ll(-800, 500);
    d.update(p[0], p[1], heading: 90, speed: 10, accuracy: 5);
  }
}

LevelEstimate drive(LevelDetector d, double x, double y, double hPa) {
  for (var i = 0; i < 10; i++) {
    d.addPressure(hPa);
  }
  final p = ll(x, y);
  return d.update(p[0], p[1], heading: 90, speed: 14, accuracy: 6);
}

void main() {
  group('stacked roads, synthetic', () {
    test('no flyover nearby means ground, and the ground pressure is learned', () {
      final d = LevelDetector(stacked());
      learnBaseline(d, 1012.0);
      expect(d.hasBaseline, isTrue);
      final p = ll(-800, 500);
      expect(d.update(p[0], p[1], heading: 90, speed: 10).level, RoadLevel.ground);
    });

    test('barometer 7 m up between the stacked roads means on the flyover', () {
      final d = LevelDetector(stacked());
      learnBaseline(d, 1012.0);
      final e = drive(d, 0, -3, 1012.0 - 7 * hpaPerMetre);
      expect(e.level, RoadLevel.upper);
      expect(e.roadName, 'Test Flyover');
      // the pressure filter lags by design (about 1 s to reach ~90%), so allow 1 m
      expect(e.baroHeight!, closeTo(7, 1.0));
    });

    test('barometer at ground level between the stacked roads means underneath', () {
      final d = LevelDetector(stacked());
      learnBaseline(d, 1012.0);
      final e = drive(d, 0, -3, 1012.0);
      expect(e.level, RoadLevel.ground);
      expect(e.roadName, 'Ground Road');
    });

    test('small pressure noise does not flip the level (hysteresis)', () {
      final d = LevelDetector(stacked());
      learnBaseline(d, 1012.0);
      final rnd = math.Random(1);
      var flips = 0;
      RoadLevel? last;
      for (var i = 0; i < 200; i++) {
        final e = drive(d, -100 + i.toDouble(), -3, 1012.0 - 7 * hpaPerMetre + (rnd.nextDouble() - .5) * 0.1);
        if (last != null && e.level != last) flips++;
        last = e.level;
      }
      expect(flips, lessThanOrEqualTo(1));
      expect(last, RoadLevel.upper);
    });

    test('without a barometer the previous level is kept, with low confidence', () {
      final d = LevelDetector(stacked());
      final p = ll(0, -3);
      final e = d.update(p[0], p[1], heading: 90, speed: 14, accuracy: 6);
      expect(e.level, RoadLevel.ground);
      expect(e.confidence, lessThan(0.6));
    });
  });

  group('real Nasr City data', () {
    late MatchData match;
    late RouteData route;
    setUpAll(() {
      match = MatchData.fromJson(jsonDecode(File('assets/data/match.json').readAsStringSync()) as Map<String, dynamic>);
      route = RouteData.fromJson(jsonDecode(File('assets/data/route.json').readAsStringSync()) as Map<String, dynamic>);
    });

    test('a simulated drive over both flyovers is classified correctly almost everywhere', () {
      final d = LevelDetector(match);
      final rnd = math.Random(3);
      double gauss() => math.sqrt(-2 * math.log(1 - rnd.nextDouble())) * math.cos(2 * math.pi * rnd.nextDouble());
      var right = 0, total = 0;
      final wrongAt = <int>[];
      for (var s = 0.0; s < route.distance; s += 1.5) {
        final p = route.sample(s);
        d.addPressure(1012.6 - p.height * hpaPerMetre + gauss() * 0.03);
        if ((s / 1.5).round() % 10 != 0) continue; // GPS at 1 Hz-ish, barometer 10x faster
        final e = d.update(p.lon + gauss() * 4 / 96400, p.lat + gauss() * 4 / 110540,
            heading: p.heading + gauss() * 3, speed: 15, accuracy: 5);
        final truthUp = p.height > 2.5;
        if (p.height > 0.8 && p.height < 2.5) continue; // ramps: either answer is acceptable
        total++;
        if (e.onFlyover == truthUp) {
          right++;
        } else {
          wrongAt.add(s.round());
        }
      }
      // ignore: avoid_print
      print('correct $right / $total, wrong at metres $wrongAt');
      expect(right / total, greaterThan(0.95));
    });

    test('on the Ganzoury flyover with ground-level pressure, the car is on the road below', () {
      final d = LevelDetector(match);
      // learn the ground pressure at the start of the route (no flyover there)
      for (var s = 0.0; s < 300; s += 15) {
        final p = route.sample(s);
        d.addPressure(1012.6);
        d.update(p.lon, p.lat, heading: p.heading, speed: 15, accuracy: 5);
      }
      // GPS says "on the flyover" but the barometer says ground: e.g. driving the service road under it
      LevelEstimate? e;
      for (var s = 850.0; s < 950; s += 15) {
        final p = route.sample(s);
        for (var i = 0; i < 10; i++) {
          d.addPressure(1012.6);
        }
        e = d.update(p.lon, p.lat, heading: p.heading, speed: 15, accuracy: 12);
      }
      expect(e!.level, RoadLevel.ground);
    });
  });
}
