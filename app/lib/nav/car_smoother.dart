import 'dart:math' as math;

import '../geo/geo.dart';
import 'match_data.dart';

/// Makes the car glide instead of jumping once a second, and keeps it moving
/// sensibly when GPS is poor or missing.
///
/// * On a matched road (see MapMatcher): the car is placed on the road
///   centreline and, between fixes, moves along the road's own curve at the
///   last speed. If GPS drops out (under a flyover, between tall buildings) it
///   keeps following the road for up to 8 s.
/// * Off the mapped roads: the car moves along its heading, and the heading
///   between fixes comes from the gyroscope (see [GyroHeading]) instead of
///   staying frozen until the next fix.
/// * Drawn position, heading and height ease towards the prediction, so
///   corrections slide in instead of jumping.
class CarSmoother {
  Vec? _fix;
  double _speed = 0, _height = 0;
  DateTime _fixAt = DateTime.now();
  double _drHeading = 0; // dead-reckoning heading (gyro between fixes)

  MatchLine? _line;
  double _s = 0;
  int _dir = 1; // +1 along the line's drawing direction, -1 against it

  final gyro = GyroHeading();

  Vec? pos;
  double heading = 0, height = 0;

  bool get ready => pos != null;
  bool get onRoad => _line != null;

  /// New GPS fix. [match] is the road from the map matcher (null off the mapped roads).
  void addFix(Vec p, {required double speed, required double gpsHeading, required double deckHeight, Candidate? match}) {
    gyro.onFix(gpsHeading, speed);
    var target = p;
    if (match != null) {
      target = match.point;
      final sameLine = identical(match.line, _line);
      if (match.line.oneway) {
        _dir = 1;
      } else if (speed > 2 || !sameLine) {
        _dir = Geo.angleDiff(match.bearing, gpsHeading) <= 90 ? 1 : -1;
      }
      _line = match.line;
      _s = match.s;
    } else {
      _line = null;
    }
    if (speed > 3) {
      // GPS course is good when moving; with a calibrated gyro, blend instead of replacing
      final d = ((gpsHeading - _drHeading + 540) % 360) - 180;
      _drHeading = (_drHeading + d * (gyro.trusted ? 0.35 : 1.0) + 360) % 360;
    }
    if (pos == null || (target - pos!).length > 120) {
      // first fix, or a jump (simulation restarted, GPS reacquired): no easing
      pos = target;
      heading = _drHeading = match == null ? gpsHeading : _roadHeading(match.s);
      height = deckHeight;
    }
    _fix = target;
    _speed = speed < 0.8 ? 0 : speed; // standing still: no creeping
    _height = deckHeight;
    _fixAt = DateTime.now();
  }

  /// Gyroscope turn rate, degrees per second clockwise (compass direction).
  void addYaw(double rateDps, double dt) => gyro.add(rateDps, dt);

  double _roadHeading(double s) {
    final (_, b) = _line!.at(s);
    return _dir > 0 ? b : (b + 180) % 360;
  }

  /// Advance the drawn car by [dt] seconds.
  void step(double dt) {
    final f = _fix, p = pos;
    if (f == null || p == null) return;
    final age = math.min(DateTime.now().difference(_fixAt).inMilliseconds / 1000.0, _line != null ? 8.0 : 1.5);
    Vec predicted;
    double targetHeading;
    final line = _line;
    if (line != null) {
      final s = _s + _dir * _speed * age;
      if (s >= 0 && s <= line.length) {
        final (pt, b) = line.at(s);
        predicted = pt;
        targetHeading = _dir > 0 ? b : (b + 180) % 360;
      } else {
        // past the end of this road piece: carry on straight until the matcher picks the next one
        final end = s < 0 ? 0.0 : line.length;
        final (pt, b) = line.at(end);
        targetHeading = _dir > 0 ? b : (b + 180) % 360;
        final r = targetHeading * math.pi / 180;
        predicted = pt + Vec(math.sin(r), math.cos(r)) * (s < 0 ? -s : s - line.length);
      }
      _drHeading = targetHeading;
    } else {
      if (gyro.trusted && _speed > 0) _drHeading = (_drHeading + gyro.rate * dt + 360) % 360;
      targetHeading = _drHeading;
      final r = _drHeading * math.pi / 180;
      predicted = f + Vec(math.sin(r), math.cos(r)) * (_speed * age);
    }
    final k = 1 - math.exp(-dt * 3.5);
    pos = p + (predicted - p) * k;
    final d = ((targetHeading - heading + 540) % 360) - 180;
    heading = (heading + d * (1 - math.exp(-dt * 4)) + 360) % 360;
    height += (_height - height) * (1 - math.exp(-dt * 2.5));
  }

  void reset() {
    _fix = null;
    _line = null;
    pos = null;
  }
}

/// Turn rate from the gyroscope, checked against GPS before it is trusted.
///
/// The phone can sit at any angle in its mount, so the source turns the
/// gyroscope reading into a turn rate about the vertical (using gravity from
/// the accelerometer). Here: the sensor's small constant offset (bias) is
/// learned while the car stands still, and the sign is confirmed by comparing
/// a few turns with the change in GPS course. Until then it is not used.
class GyroHeading {
  double bias = 0;
  int sign = 1;
  bool trusted = false;

  /// Latest calibrated turn rate, degrees per second clockwise.
  double rate = 0;

  double _sinceFix = 0, _rawSum = 0, _rawTime = 0;
  double? _lastGpsHeading;
  double _lastSpeed = 0;
  double _agree = 0;
  int _turns = 0;

  void add(double rawDps, double dt) {
    rate = sign * (rawDps - bias);
    _sinceFix += (rawDps - bias) * dt;
    _rawSum += rawDps * dt;
    _rawTime += dt;
  }

  void onFix(double gpsHeading, double speed) {
    if (speed < 0.3 && _lastSpeed < 0.3 && _rawTime > 0.5) {
      // standing still: whatever the gyro reads is its offset
      bias += 0.2 * (_rawSum / _rawTime - bias);
    } else if (speed > 5 && _lastSpeed > 5 && _lastGpsHeading != null && _rawTime > 0.3) {
      final gpsTurn = ((gpsHeading - _lastGpsHeading! + 540) % 360) - 180;
      if (gpsTurn.abs() > 3 && gpsTurn.abs() < 60 && _sinceFix.abs() > 1) {
        _agree += gpsTurn * _sinceFix;
        _turns++;
        if (_turns >= 3) {
          sign = _agree >= 0 ? 1 : -1;
          trusted = true;
        }
      }
    }
    _lastGpsHeading = speed > 2 ? gpsHeading : _lastGpsHeading;
    _lastSpeed = speed;
    _sinceFix = 0;
    _rawSum = 0;
    _rawTime = 0;
  }
}
