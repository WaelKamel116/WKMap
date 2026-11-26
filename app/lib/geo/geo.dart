import 'dart:math' as math;

/// Small geometry helpers on a local flat projection.
/// Accurate to well under a metre across Greater Cairo, which is all the
/// map-matching needs.
class Geo {
  static const double originLon = 31.34;
  static const double originLat = 30.07;
  static final double mPerDegLon = 111320 * math.cos(originLat * math.pi / 180);
  static const double mPerDegLat = 110540;

  /// [lon, lat] -> local metres (x east, y north)
  static Vec toXY(double lon, double lat) =>
      Vec((lon - originLon) * mPerDegLon, (lat - originLat) * mPerDegLat);

  static List<double> toLonLat(Vec v) =>
      [originLon + v.x / mPerDegLon, originLat + v.y / mPerDegLat];

  /// Compass bearing (0 = north, clockwise) from a to b.
  static double bearing(Vec a, Vec b) {
    final d = math.atan2(b.x - a.x, b.y - a.y) * 180 / math.pi;
    return (d + 360) % 360;
  }

  /// Smallest absolute difference between two bearings, 0..180.
  static double angleDiff(double a, double b) {
    final d = ((b - a + 540) % 360) - 180;
    return d.abs();
  }
}

class Vec {
  final double x, y;
  const Vec(this.x, this.y);
  Vec operator -(Vec o) => Vec(x - o.x, y - o.y);
  Vec operator +(Vec o) => Vec(x + o.x, y + o.y);
  Vec operator *(double k) => Vec(x * k, y * k);
  double dot(Vec o) => x * o.x + y * o.y;
  double get length => math.sqrt(x * x + y * y);
}

/// Result of projecting a point onto a segment.
class SegmentHit {
  final double distance; // metres from the point to the segment
  final double t; // 0..1 position along the segment
  final double bearing; // segment direction
  final Vec point; // closest point on the segment
  const SegmentHit(this.distance, this.t, this.bearing, this.point);
}

SegmentHit projectOnSegment(Vec p, Vec a, Vec b) {
  final ab = b - a;
  final len2 = ab.dot(ab);
  var t = len2 == 0 ? 0.0 : (p - a).dot(ab) / len2;
  t = t.clamp(0.0, 1.0);
  final q = a + ab * t;
  return SegmentHit((p - q).length, t, Geo.bearing(a, b), q);
}
