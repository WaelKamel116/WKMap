import 'dart:math' as math;

import '../geo/geo.dart';
import 'match_data.dart';

/// Picks the road the car is on from its recent path, not just the nearest
/// road to each GPS fix (a hidden Markov model, after Newson and Krumm 2009).
///
/// For every fix, each nearby road gets a score:
///  * how close the fix is to it (GPS error is roughly Gaussian),
///  * whether its direction fits the travel direction,
///  * whether its level fits the flyover detector (deck vs road below),
///  * how plausibly the car got there from each road it might have been on a
///    second ago: driving distance through the network (along the road, or
///    through a junction shared with it) should match the straight-line
///    distance between the fixes; going the wrong way up a one-way road or
///    hopping to a road that is not connected scores very low.
/// The best-scoring road wins. A noisy fix that lands nearer the service road
/// or the road under a flyover no longer pulls the car across, because the
/// car could not have got there.
class MapMatcher {
  MapMatcher(this.data);

  final MatchData data;
  Map<int, _State> _states = {};
  Vec? _lastP;

  /// The road the car is matched to, or null when no mapped road is within GPS
  /// error (small streets are not in the matching data).
  Candidate? current;

  void reset() {
    _states = {};
    _lastP = null;
    current = null;
  }

  static const _beta = 6.0; // metres: how much driving and straight-line distance may differ
  static final _notConnected = math.log(1e-4);

  Candidate? update(Vec p, {required double accuracy, required double speed, required double heading, bool? onFlyover}) {
    // wide enough that one noisy fix never drops the true road from the running
    final radius = math.max(25.0, math.min(accuracy * 4, 50.0));
    final moving = speed > 2;
    final all = data.candidates(p, radius, moving ? heading : null, maxAngle: 60);
    // nearest point per road
    final byLine = <int, Candidate>{};
    for (final c in all) {
      final had = byLine[c.lineIndex];
      if (had == null || c.distance < had.distance) byLine[c.lineIndex] = c;
    }
    if (byLine.isEmpty) {
      reset();
      _lastP = p;
      return null;
    }
    final sigma = math.max(accuracy, 4.0);
    final straight = _lastP == null ? 0.0 : (p - _lastP!).length;
    final next = <int, _State>{};
    for (final b in byLine.values) {
      var emit = -0.5 * math.pow(b.distance / sigma, 2);
      if (moving) {
        final d = b.line.oneway
            ? Geo.angleDiff(b.bearing, heading)
            : math.min(Geo.angleDiff(b.bearing, heading), Geo.angleDiff((b.bearing + 180) % 360, heading));
        emit += -0.5 * math.pow(d / 25, 2);
      }
      if (onFlyover != null) {
        final up = b.line.isBridge && b.height > 0.5;
        if (up != onFlyover) emit += math.log(0.15);
      }
      var best = _states.isEmpty ? 0.0 : double.negativeInfinity;
      for (final a in _states.values) {
        final rd = _drivingDistance(a.c, b);
        final t = rd == null ? _notConnected - straight / 20 : -(rd - straight).abs() / _beta;
        if (a.score + t > best) best = a.score + t;
      }
      next[b.lineIndex] = _State(b, best + emit);
    }
    // normalise and keep the 12 best
    final top = next.values.map((s) => s.score).reduce(math.max);
    final kept = next.values.toList()..sort((x, y) => y.score.compareTo(x.score));
    _states = {for (final s in kept.take(12)) s.c.lineIndex: _State(s.c, s.score - top)};
    _lastP = p;
    // The search is wide so the path is never lost, but only place the car on the
    // road when the fix is within GPS error of it: small side streets are not in
    // the matching data, and a car on one must not be pulled onto the main road.
    final best = kept.first.c;
    return current = best.distance <= math.max(15.0, accuracy * 2.5) ? best : null;
  }

  /// Driving distance from a to b: along one road, or through one or two
  /// junctions. Null when b cannot be reached that way (or only by going the
  /// wrong way on a one-way road).
  double? _drivingDistance(Candidate a, Candidate b) {
    const slack = -5.0; // GPS noise can put the car a few metres "behind" itself
    if (a.lineIndex == b.lineIndex) {
      final d = b.s - a.s;
      if (a.line.oneway && d < slack) return null;
      return d.abs();
    }
    double? best;
    void consider(double d) {
      if (best == null || d < best!) best = d;
    }

    for (final j in data.junctions[a.lineIndex]) {
      final d1 = j.sThis - a.s;
      if (a.line.oneway && d1 < slack) continue;
      if (j.other == b.lineIndex) {
        final d2 = b.s - j.sOther;
        if (b.line.oneway && d2 < slack) continue;
        consider(d1.abs() + d2.abs());
        continue;
      }
      // one short road in between (OpenStreetMap often splits a road into small pieces)
      final mid = data.lines[j.other];
      if (mid.length > 300) continue;
      for (final k in data.junctions[j.other]) {
        if (k.other != b.lineIndex) continue;
        final dm = k.sThis - j.sOther;
        if (mid.oneway && dm < slack) continue;
        final d2 = b.s - k.sOther;
        if (b.line.oneway && d2 < slack) continue;
        consider(d1.abs() + dm.abs() + d2.abs());
      }
    }
    return best;
  }
}

class _State {
  const _State(this.c, this.score);
  final Candidate c;
  final double score; // log probability, best = 0
}
