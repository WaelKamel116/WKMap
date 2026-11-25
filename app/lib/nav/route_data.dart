import 'dart:math' as math;

import '../geo/geo.dart';

class RoutePoint {
  final double lon, lat, height, heading;
  const RoutePoint(this.lon, this.lat, this.height, this.heading);
}

/// The demo route (route.json from tools/build_data.py): dense coordinates
/// with cumulative distance and deck height along the way.
class RouteData {
  final List<List<double>> coords;
  final List<double> elev, cum;
  final double distance;
  final List<Vec> _xy;

  RouteData(this.coords, this.elev, this.cum, this.distance)
      : _xy = coords.map((c) => Geo.toXY(c[0], c[1])).toList();

  factory RouteData.fromJson(Map<String, dynamic> j) => RouteData(
        (j['coords'] as List).map((c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()]).toList(),
        (j['elev'] as List).map((v) => (v as num).toDouble()).toList(),
        (j['cum'] as List).map((v) => (v as num).toDouble()).toList(),
        (j['distance'] as num).toDouble(),
      );

  int _index(double s) {
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final m = (lo + hi) >> 1;
      if (cum[m] <= s) {
        lo = m;
      } else {
        hi = m;
      }
    }
    return lo;
  }

  RoutePoint sample(double s) {
    s = s.clamp(0, distance);
    final i = _index(s), j = math.min(i + 1, coords.length - 1);
    final t = j == i ? 0.0 : (s - cum[i]) / (cum[j] - cum[i]);
    final a = _xy[i], b = _xy[j];
    final p = a + (b - a) * t;
    final ll = Geo.toLonLat(p);
    final ahead = _xy[_index(math.min(distance, s + 15))];
    final behind = _xy[_index(math.max(0, s - 5))];
    return RoutePoint(ll[0], ll[1], elev[i] + (elev[j] - elev[i]) * t, Geo.bearing(behind, ahead));
  }

  /// Route split into the parts on the ground (drawn as a flat line) and the
  /// parts up on a flyover (drawn as a raised ribbon).
  List<List<List<double>>> groundParts() {
    final parts = <List<List<double>>>[];
    List<List<double>>? cur;
    for (var i = 0; i < coords.length; i++) {
      if (elev[i] < 0.5) {
        (cur ??= []).add(coords[i]);
      } else if (cur != null) {
        if (cur.length > 1) parts.add(cur);
        cur = null;
      }
    }
    if (cur != null && cur.length > 1) parts.add(cur);
    return parts;
  }
}
