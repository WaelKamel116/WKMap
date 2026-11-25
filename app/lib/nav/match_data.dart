import '../geo/geo.dart';

/// A road centreline prepared for map matching.
class MatchLine {
  final String name;
  final bool oneway;
  final bool isBridge;
  final List<Vec> pts;

  /// Deck height in metres at each vertex (all zeros for ground roads).
  final List<double> heights;

  MatchLine(this.name, this.oneway, this.isBridge, this.pts, this.heights);
}

/// Flyover and ground-road geometry, plus a coarse grid index so a lookup
/// only checks segments near the car.
class MatchData {
  final List<MatchLine> lines;
  final Map<int, List<_SegRef>> _grid = {};
  static const double cell = 60; // metres

  MatchData(this.lines) {
    for (var li = 0; li < lines.length; li++) {
      final l = lines[li];
      for (var i = 0; i < l.pts.length - 1; i++) {
        final a = l.pts[i], b = l.pts[i + 1];
        final x0 = (a.x < b.x ? a.x : b.x) ~/ cell - 1, x1 = (a.x > b.x ? a.x : b.x) ~/ cell + 1;
        final y0 = (a.y < b.y ? a.y : b.y) ~/ cell - 1, y1 = (a.y > b.y ? a.y : b.y) ~/ cell + 1;
        for (var gx = x0; gx <= x1; gx++) {
          for (var gy = y0; gy <= y1; gy++) {
            (_grid[_key(gx, gy)] ??= []).add(_SegRef(li, i));
          }
        }
      }
    }
  }

  static int _key(int gx, int gy) => (gx + 5000) * 10000 + (gy + 5000);

  /// Parses the `match.json` asset produced by tools/build_data.py.
  factory MatchData.fromJson(Map<String, dynamic> j) {
    final lines = <MatchLine>[];
    for (final b in (j['bridges'] as List)) {
      final c = (b['c'] as List).map((p) => Geo.toXY((p[0] as num).toDouble(), (p[1] as num).toDouble())).toList();
      final h = (b['h'] as List).map((v) => (v as num).toDouble()).toList();
      lines.add(MatchLine(b['name'] ?? '', b['oneway'] == 1, true, c, h));
    }
    for (final g in (j['ground'] as List)) {
      final c = (g['c'] as List).map((p) => Geo.toXY((p[0] as num).toDouble(), (p[1] as num).toDouble())).toList();
      lines.add(MatchLine(g['name'] ?? '', g['oneway'] == 1, false, c, List.filled(c.length, 0)));
    }
    return MatchData(lines);
  }

  /// All road segments within [radius] metres of [p] whose direction fits
  /// [heading] (ignored when null, e.g. when the car is stopped).
  List<Candidate> candidates(Vec p, double radius, double? heading, {double maxAngle = 40}) {
    final seen = <int>{};
    final out = <Candidate>[];
    final gx = p.x ~/ cell, gy = p.y ~/ cell;
    for (final ref in _grid[_key(gx, gy)] ?? const <_SegRef>[]) {
      if (!seen.add(ref.line * 100000 + ref.seg)) continue;
      final l = lines[ref.line];
      final hit = projectOnSegment(p, l.pts[ref.seg], l.pts[ref.seg + 1]);
      if (hit.distance > radius) continue;
      if (heading != null) {
        final d = Geo.angleDiff(hit.bearing, heading);
        final ok = l.oneway ? d <= maxAngle : (d <= maxAngle || d >= 180 - maxAngle);
        if (!ok) continue;
      }
      final h = l.heights[ref.seg] + (l.heights[ref.seg + 1] - l.heights[ref.seg]) * hit.t;
      out.add(Candidate(l, hit.distance, h));
    }
    out.sort((a, b) => a.distance.compareTo(b.distance));
    return out;
  }
}

class _SegRef {
  final int line, seg;
  const _SegRef(this.line, this.seg);
}

class Candidate {
  final MatchLine line;
  final double distance;
  final double height; // deck height at the matched point (0 on the ground)
  const Candidate(this.line, this.distance, this.height);
}
