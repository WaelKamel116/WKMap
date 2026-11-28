// Replays a real drive (trip.csv from the app) through the level detector.
// Not part of the normal test run: drive logs hold the tester's track, so they
// stay out of the repo. Run with
//   flutter test test/replay_trip_test.dart --dart-define=TRIP_CSV=C:/path/trip.csv
import 'dart:convert';
import 'dart:io';

import 'package:cairo_nav/geo/geo.dart';
import 'package:cairo_nav/nav/level_detector.dart';
import 'package:cairo_nav/nav/map_matcher.dart';
import 'package:cairo_nav/nav/match_data.dart';
import 'package:flutter_test/flutter_test.dart';

const _path = String.fromEnvironment('TRIP_CSV');

void main() {
  test('replay $_path', () {
    final match = MatchData.fromJson(jsonDecode(File('assets/data/match.json').readAsStringSync()) as Map<String, dynamic>);
    final d = LevelDetector(match);
    final mm = MapMatcher(match);
    String? lastHmm, lastNear;
    var hmmSwitches = 0, nearSwitches = 0, matched = 0;
    final lines = File(_path).readAsLinesSync().where((l) => !l.startsWith('#')).toList();
    final head = lines.first.split(',');
    int col(String n) => head.indexOf(n);
    int? t0;
    var maxGap = 0.0, upFixes = 0, fixes = 0;
    String? segStart;
    double peak = 0, deck = 0;
    for (final l in lines.skip(1)) {
      final c = l.split(',');
      final t = int.parse(c[col('t_ms')]);
      t0 ??= t;
      final s = (t - t0) / 1000;
      if (c[col('kind')] == 'baro') d.addPressure(double.parse(c[col('pressure_hpa')]), at: DateTime.fromMillisecondsSinceEpoch(t));
      if (c[col('kind')] != 'gps') continue;
      final e = d.update(double.parse(c[col('lon')]), double.parse(c[col('lat')]),
          heading: double.parse(c[col('heading_deg')]), speed: double.parse(c[col('speed_mps')]), accuracy: double.parse(c[col('accuracy_m')]));
      fixes++;
      final p = Geo.toXY(double.parse(c[col('lon')]), double.parse(c[col('lat')]));
      final spd = double.parse(c[col('speed_mps')]), hdg = double.parse(c[col('heading_deg')]);
      final a = mm.update(p, accuracy: double.parse(c[col('accuracy_m')]), speed: spd, heading: hdg, onFlyover: e.onFlyover);
      final nc = match.candidates(p, 20, spd > 2 ? hdg : null, maxAngle: 35);
      final b = nc.isEmpty ? null : nc.first;
      if (a != null) matched++;
      // a "switch" = the matched road changes to a differently named road and back within 10 s counts twice
      final an = a == null ? null : '${a.line.name}|${a.line.isBridge}';
      final bn = b == null ? null : '${b.line.name}|${b.line.isBridge}';
      if (an != null && lastHmm != null && an != lastHmm) hmmSwitches++;
      if (bn != null && lastNear != null && bn != lastNear) nearSwitches++;
      lastHmm = an ?? lastHmm;
      lastNear = bn ?? lastNear;
      final bh = e.baroHeight;
      if (e.onFlyover) {
        upFixes++;
        segStart ??= s.toStringAsFixed(0);
        if (bh != null && bh > peak) peak = bh;
        deck = e.mapHeight ?? deck;
      } else {
        if (segStart != null) {
          // ignore: avoid_print
          print('UP ${segStart}s-${s.toStringAsFixed(0)}s  baro peak ${peak.toStringAsFixed(1)} m, map deck ${deck.toStringAsFixed(1)} m');
          segStart = null;
          peak = 0;
        }
        if (bh != null && bh.abs() > maxGap) maxGap = bh.abs();
      }
    }
    // ignore: avoid_print
    print('$fixes fixes, $upFixes up; largest baro height while on the ground: ${maxGap.toStringAsFixed(1)} m');
    // ignore: avoid_print
    print('road changes: path matching $hmmSwitches, nearest road $nearSwitches ($matched fixes on mapped main roads)');
  }, skip: _path.isEmpty ? 'set --dart-define=TRIP_CSV=path/to/trip.csv' : null);
}
