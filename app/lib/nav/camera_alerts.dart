import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

import '../geo/geo.dart';

/// A speed camera beside the road, facing one direction of travel.
class SpeedCamera {
  const SpeedCamera(this.id, this.p, this.bearing, this.limit);
  final int id;
  final Vec p;

  /// Direction of travel it checks (compass degrees), null when not known.
  final double? bearing;

  /// Speed limit it checks, km/h (0 = not known).
  final int limit;
}

class CameraAlert {
  const CameraAlert(this.camera, this.distance, {required this.isNew});
  final SpeedCamera camera;

  /// Metres ahead along the travel direction.
  final double distance;

  /// True the first time this camera is announced (sound and vibration then).
  final bool isNew;
}

/// Warns about speed cameras ahead: the nearest camera in front of the car,
/// close to its line of travel, facing its direction, within about 20 seconds
/// of driving (at least 300 m, at most 800 m).
class CameraAlerts {
  CameraAlerts(this.cameras);

  final List<SpeedCamera> cameras;
  final _announced = <int>{};

  static Future<CameraAlerts> load() async {
    final j = jsonDecode(await rootBundle.loadString('assets/data/signs.json')) as Map<String, dynamic>;
    final out = <SpeedCamera>[];
    for (final f in (j['signs']['features'] as List)) {
      final p = f['properties'] as Map;
      if (p['k'] != 'camera') continue;
      final c = f['geometry']['coordinates'] as List;
      out.add(SpeedCamera(out.length, Geo.toXY((c[0] as num).toDouble(), (c[1] as num).toDouble()),
          (p['b'] as num?)?.toDouble(), (p['ms'] as num?)?.toInt() ?? 0));
    }
    return CameraAlerts(out);
  }

  /// The camera to warn about now, or null.
  CameraAlert? update(Vec pos, double heading, double speedMps) {
    final ahead = (speedMps * 20).clamp(300.0, 800.0);
    final r = heading * math.pi / 180;
    final ux = math.sin(r), uy = math.cos(r);
    SpeedCamera? best;
    var bestAlong = double.infinity;
    for (final c in cameras) {
      final dx = c.p.x - pos.x, dy = c.p.y - pos.y;
      if (dx.abs() > ahead + 50 || dy.abs() > ahead + 50) continue;
      final along = dx * ux + dy * uy;
      final across = (dx * uy - dy * ux).abs();
      if (along < -5 || along > ahead) continue;
      // close to the line of travel (wider far away: the road may bend a little)
      if (across > 25 + along * 0.08) continue;
      if (c.bearing != null && Geo.angleDiff(c.bearing!, heading) > 50) continue;
      if (along < bestAlong) {
        bestAlong = along;
        best = c;
      }
    }
    if (best == null) return null;
    final isNew = _announced.add(best.id);
    if (_announced.length > 200) _announced.remove(_announced.first);
    return CameraAlert(best, math.max(0, bestAlong), isNew: isNew);
  }
}
