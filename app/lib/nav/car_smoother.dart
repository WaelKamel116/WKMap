import 'dart:math' as math;

import '../geo/geo.dart';
import 'match_data.dart';

/// Makes the car glide instead of jumping once a second.
///
/// 1. Snap: each GPS fix is moved onto the centreline of the road the map
///    matcher picked (the flyover when the level detector says we are up
///    there), as long as that road is within the GPS error. The heading is
///    taken from the road, so the car points along the street.
/// 2. Predict: between fixes the car keeps moving at the last speed along
///    the last heading (dead reckoning, capped at 1.5 s).
/// 3. Ease: the drawn position, heading and height chase the prediction with
///    a short time constant, so corrections slide in instead of jumping.
class CarSmoother {
  Vec? _fix;
  double _speed = 0, _heading = 0, _height = 0;
  DateTime _fixAt = DateTime.now();

  Vec? pos;
  double heading = 0, height = 0;

  bool get ready => pos != null;

  /// Picks the road point to snap to. [onFlyover] prefers flyover decks.
  static Candidate? snapTarget(MatchData data, Vec p, double accuracy, double speed, double heading, bool onFlyover) {
    final radius = math.max(8.0, math.min(accuracy * 1.3, 20.0));
    final c = data.candidates(p, radius, speed > 2 ? heading : null, maxAngle: 35);
    if (c.isEmpty) return null;
    final want = c.where((x) => (x.line.isBridge && x.height > 0.5) == onFlyover);
    return want.isNotEmpty ? want.first : c.first;
  }

  void addFix(Vec p, {required double speed, required double gpsHeading, required double deckHeight, Candidate? snap}) {
    var target = p, hdg = gpsHeading;
    if (snap != null) {
      target = snap.point;
      // follow the road's direction, picking the way that matches travel
      final along = snap.bearing, back = (snap.bearing + 180) % 360;
      if (speed > 2) hdg = Geo.angleDiff(along, gpsHeading) <= Geo.angleDiff(back, gpsHeading) ? along : back;
    }
    if (pos == null || (target - pos!).length > 120) {
      // first fix, or a jump (simulation restarted, GPS reacquired): no easing
      pos = target;
      heading = _heading = hdg;
      height = deckHeight;
    }
    _fix = target;
    _speed = speed < 0.8 ? 0 : speed; // standing still: no creeping
    if (speed > 1.5) _heading = hdg; // GPS heading is noise when slow
    _height = deckHeight;
    _fixAt = DateTime.now();
  }

  /// Advance the drawn car by [dt] seconds.
  void step(double dt) {
    final f = _fix, p = pos;
    if (f == null || p == null) return;
    final age = math.min(DateTime.now().difference(_fixAt).inMilliseconds / 1000.0, 1.5);
    final r = _heading * math.pi / 180;
    final predicted = f + Vec(math.sin(r), math.cos(r)) * (_speed * age);
    final k = 1 - math.exp(-dt * 3.5);
    pos = p + (predicted - p) * k;
    final d = ((_heading - heading + 540) % 360) - 180;
    heading = (heading + d * (1 - math.exp(-dt * 4)) + 360) % 360;
    height += (_height - height) * (1 - math.exp(-dt * 2.5));
  }

  void reset() {
    _fix = null;
    pos = null;
  }
}
