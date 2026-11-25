import '../geo/geo.dart';
import 'match_data.dart';

enum RoadLevel { ground, ramp, upper }

class LevelEstimate {
  final RoadLevel level;

  /// 0..1, how sure the detector is.
  final double confidence;
  final String roadName;

  /// Height above the learned ground level, from the barometer (null until a
  /// ground baseline has been learned, or when the phone has no barometer).
  final double? baroHeight;

  /// Deck height of the matched flyover at this point (0 on the ground).
  final double? mapHeight;
  final String reason;

  const LevelEstimate(this.level, this.confidence, this.roadName, this.baroHeight, this.mapHeight, this.reason);

  bool get onFlyover => level != RoadLevel.ground;
}

/// Decides whether the car is up on a flyover or on the road underneath.
///
/// 1. Map matching: which road segments fit the GPS position and heading?
///    If no flyover fits, the car is on the ground, and the detector uses that
///    moment to learn the ground-level air pressure.
/// 2. If only a flyover fits, the car is on it.
/// 3. If both a flyover and the road below fit (GPS cannot separate roads
///    stacked a few metres apart), the barometer decides: compare the measured
///    height above ground with the flyover's deck height.
///    Hysteresis stops the answer flickering.
class LevelDetector {
  LevelDetector(this.data, {this.metresPerHpa = 8.4});

  final MatchData data;

  /// Near sea level, 1 hPa of pressure is about 8.4 m of height.
  final double metresPerHpa;

  double? _pressure; // low-pass filtered, hPa
  double? _baseline; // pressure at ground level, hPa
  RoadLevel _level = RoadLevel.ground;

  bool get hasBaseline => _baseline != null;

  void addPressure(double hPa) {
    _pressure = _pressure == null ? hPa : _pressure! + 0.2 * (hPa - _pressure!);
  }

  double? get baroHeight =>
      (_pressure == null || _baseline == null) ? null : (_baseline! - _pressure!) * metresPerHpa;

  LevelEstimate update(double lon, double lat, {double? heading, double speed = 0, double accuracy = 10}) {
    final p = Geo.toXY(lon, lat);
    final radius = (accuracy * 1.5).clamp(8.0, 30.0);
    final hdg = speed > 2 ? heading : null; // heading is noise when stopped
    final cands = data.candidates(p, radius, hdg);
    final flyovers = cands.where((c) => c.line.isBridge && c.height > 0.5).toList();
    final grounds = cands.where((c) => !c.line.isBridge || c.height <= 0.5).toList();

    if (flyovers.isEmpty) {
      // No flyover can explain this position: we are on the ground. Learn the ground pressure.
      if (_pressure != null) {
        _baseline = _baseline == null ? _pressure : _baseline! + 0.05 * (_pressure! - _baseline!);
      }
      _level = RoadLevel.ground;
      final name = grounds.isNotEmpty ? grounds.first.line.name : '';
      return LevelEstimate(RoadLevel.ground, grounds.isEmpty ? 0.6 : 0.95, name, baroHeight, 0, 'No flyover nearby');
    }

    final fly = flyovers.first;
    final flyLevel = fly.height > 4 ? RoadLevel.upper : RoadLevel.ramp;

    if (grounds.isEmpty) {
      _level = flyLevel;
      return LevelEstimate(_level, 0.85, fly.line.name, baroHeight, fly.height, 'Only the flyover fits position and direction');
    }

    // Ambiguous: the flyover and the road below both fit.
    final bh = baroHeight;
    if (bh == null) {
      final up = _level != RoadLevel.ground;
      return LevelEstimate(_level, 0.5, up ? fly.line.name : grounds.first.line.name, null, fly.height,
          'No barometer reading yet: kept the previous level');
    }
    final dUp = (bh - fly.height).abs();
    final dDown = bh.abs();
    const margin = 1.2; // metres of evidence needed to switch level
    if (_level == RoadLevel.ground) {
      if (dUp + margin < dDown) _level = flyLevel;
    } else {
      _level = (dDown + margin < dUp) ? RoadLevel.ground : flyLevel;
    }
    final up = _level != RoadLevel.ground;
    final separation = (dUp - dDown).abs();
    final conf = (0.55 + separation / (fly.height + 1) * 0.45).clamp(0.55, 0.98);
    return LevelEstimate(_level, conf, up ? fly.line.name : grounds.first.line.name, bh, fly.height,
        'Barometer ${bh.toStringAsFixed(1)} m vs deck ${fly.height.toStringAsFixed(1)} m');
  }
}
