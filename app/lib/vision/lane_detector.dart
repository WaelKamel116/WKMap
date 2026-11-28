import 'dart:math' as math;
import 'dart:typed_data';

/// What the camera sees: lane lines across the road in front of the car.
class LaneReading {
  const LaneReading(this.time, this.lanes, this.lane, this.offsetM, this.lines);
  final DateTime time;

  /// Lanes seen (between the outermost lines found).
  final int lanes;

  /// The car's lane, 1 = leftmost seen.
  final int lane;

  /// How far the car is right (+) or left (-) of its lane's centre, metres
  /// (assuming the phone is about 1.25 m above the road).
  final double offsetM;

  /// Line positions, sideways offset / camera height (negative = left).
  final List<double> lines;

  @override
  String toString() => 'lane $lane of $lanes, ${offsetM >= 0 ? '+' : ''}${offsetM.toStringAsFixed(1)} m';
}

/// Finds painted lane lines in the phone's camera picture while driving: the
/// same method as tools/lanes_from_video.py, sized for a phone (pictures
/// shrunk to 270 x 480, a few frames a second).
///
///  1. The bonnet and dashboard do not change between frames: the rows that
///     stay the same mark where the road ends at the bottom of the picture.
///  2. Paint marks are found row by row (brighter than both sides) and joined
///     into short straight pieces. All road lines run to one point on the
///     horizon (the vanishing point), found by letting the pieces vote.
///  3. Each mark's sideways offset is u = (x - vanishing x) / (y - vanishing y)
///     (lateral distance / camera height on a flat road). Over about a second
///     of frames the marks of one line pile up at one u; the peaks are the lines.
class LaneDetector {
  LaneDetector({this.cameraHeight = 1.25});

  static const w = 270, h = 480;
  final double cameraHeight;

  // bonnet: per-pixel change over frames, on a coarse grid
  static const _gw = 45, _gh = 120;
  final _mean = Float64List(_gw * _gh), _m2 = Float64List(_gw * _gh);
  int _frames = 0;
  int? _hood;

  final _segs = <List<double>>[]; // x1, y1, x2, y2 (most recent last)
  (double, double)? vp;
  final _recentU = <List<double>>[];
  final _spacing = <double>[];
  double laneWidthU = 2.7;
  LaneReading? last;

  int? get hoodRow => _hood;
  int get segmentCount => _segs.length;
  bool get ready => _hood != null && vp != null;

  /// Adds one grey picture (portrait, [w] x [h], one byte per pixel).
  /// Returns a reading when lines were found on both sides of the car.
  LaneReading? addFrame(Uint8List g, DateTime t) {
    assert(g.length == w * h);
    _frames++;
    _learnHood(g);
    final hood = _hood;
    if (hood == null) return null;
    final y1 = hood - 5, y0 = y1 - 65;
    if (y0 < 20) return null;
    final pts = _markPoints(g, y0, y1);
    _addSegments(pts, y0);
    if (vp == null || _frames % 30 == 0) _findVp(y0);
    final v = vp;
    if (v == null) return null;
    final us = <double>[for (final p in pts) if (p.$2 > y0 + 15 && p.$2 - v.$2 > 3) (p.$1 - v.$1) / (p.$2 - v.$2)];
    _recentU.add(us);
    if (_recentU.length > 4) _recentU.removeAt(0);
    final lines = linePeaks([for (final u in _recentU) ...u]);
    for (var i = 1; i < lines.length; i++) {
      final d = lines[i] - lines[i - 1];
      if (d >= 1.8 && d <= 3.8) {
        _spacing.add(d);
        if (_spacing.length > 200) _spacing.removeAt(0);
      }
    }
    if (_spacing.length >= 10) {
      final s = [..._spacing]..sort();
      laneWidthU = s[s.length ~/ 2];
    }
    final r = reading(lines, laneWidthU, t, cameraHeight);
    if (r != null) last = r;
    return r;
  }

  /// Lanes and the car's lane from line positions (u) and the lane width (u).
  static LaneReading? reading(List<double> lines, double uw, DateTime t, double cameraHeight) {
    final u = [for (final x in lines) if (x.abs() < 3.5 * uw) x];
    final left = [for (final x in u) if (x < -0.15 * uw) x], right = [for (final x in u) if (x > 0.15 * uw) x];
    if (left.isEmpty || right.isEmpty) return null;
    final l = left.reduce(math.max), r = right.reduce(math.min);
    if (r - l < 0.7 * uw || r - l > 1.35 * uw) return null;
    final lo = u.reduce(math.min), hi = u.reduce(math.max);
    final lanes = math.max(1, ((hi - lo) / uw).round());
    final lane = 1 + ((l - lo) / uw).round();
    return LaneReading(t, lanes, lane, -(l + r) / 2 * cameraHeight, u);
  }

  void _learnHood(Uint8List g) {
    if (_hood != null && _frames % 300 != 0) return;
    // Welford running mean / variance per grid pixel
    for (var gy = 0; gy < _gh; gy++) {
      final row = gy * 4 * w;
      for (var gx = 0; gx < _gw; gx++) {
        final v = g[row + gx * 6].toDouble();
        final i = gy * _gw + gx;
        // running mean and variance that forget slowly, so a moved phone is relearned
        final a = 1 / math.min(_frames, 60);
        final d = v - _mean[i];
        _mean[i] += a * d;
        _m2[i] = (1 - a) * (_m2[i] + a * d * d);
      }
    }
    if (_frames < 25) return;
    final sd = List<double>.generate(_gh, (gy) {
      var s = 0.0;
      for (var gx = 0; gx < _gw; gx++) {
        s += math.sqrt(math.max(0, _m2[gy * _gw + gx]));
      }
      return s / _gw;
    });
    // the calmest rows in the lower middle of the picture are the bonnet
    var best = double.infinity, at = 0;
    for (var gy = (_gh * 0.5).round(); gy < (_gh * 0.75).round(); gy++) {
      var s = 0.0;
      for (var k = -2; k <= 2; k++) {
        s += sd[(gy + k).clamp(0, _gh - 1)];
      }
      if (s < best) {
        best = s;
        at = gy;
      }
    }
    _hood = at * 4;
  }

  /// Centres of bright paint marks, row by row.
  static List<(double, double)> _markPoints(Uint8List g, int y0, int y1) {
    final pts = <(double, double)>[];
    final c = Float64List(w + 1);
    final r = Float64List(w);
    for (var y = y0; y < y1; y++) {
      final base = y * w;
      for (var x = 0; x < w; x++) {
        c[x + 1] = c[x] + g[base + x];
      }
      final k = 2 + (5 * (y - y0) / (y1 - y0)).round();
      final hk = k ~/ 2;
      var n = 0;
      for (var x = 3 * k; x < w - 3 * k; x++) {
        final left = (c[x - k] - c[x - 3 * k]) / (2 * k);
        final right = (c[x + 3 * k] - c[x + k]) / (2 * k);
        final mid = (c[x + hk + 1] - c[x - hk]) / (2 * hk + 1);
        r[x] = mid - math.max(left, right);
        n++;
      }
      if (n < 10) continue;
      final sorted = Float64List.sublistView(r, 3 * k, w - 3 * k).toList()..sort();
      final thr = math.max(9.0, sorted[(sorted.length * 0.97).floor()]);
      for (var x = 3 * k + 1; x < w - 3 * k - 1; x++) {
        if (r[x] > thr && r[x] >= r[x - 1] && r[x] >= r[x + 1]) pts.add((x.toDouble(), y.toDouble()));
      }
    }
    return pts;
  }

  /// Joins marks on neighbouring rows into short straight pieces.
  void _addSegments(List<(double, double)> pts, int y0) {
    // startX, startY, lastX, lastY, count, step (x change per row)
    final open = <List<double>>[];
    for (final (x, y) in pts) {
      List<double>? hit;
      var bestErr = double.infinity;
      for (final ch in open) {
        final dy = y - ch[3];
        if (dy < 1 || dy > 2) continue;
        // a line keeps its slope: after two marks, the next must continue it
        final err = ch[4] < 2 ? (x - ch[2]).abs() / 3 : (x - (ch[2] + ch[5] * dy)).abs();
        if (err <= (ch[4] < 2 ? 2 : 1.5) && err < bestErr) {
          bestErr = err;
          hit = ch;
        }
      }
      if (hit != null) {
        final step = (x - hit[2]) / (y - hit[3]);
        hit[5] = hit[4] < 2 ? step : hit[5] * 0.7 + step * 0.3;
        hit[2] = x;
        hit[3] = y;
        hit[4]++;
      } else {
        open.add([x, y, x, y, 1, 0]);
      }
    }
    for (final ch in open) {
      if (ch[4] < 6) continue;
      final dx = ch[2] - ch[0], dy = ch[3] - ch[1];
      final ang = math.atan2(dy.abs(), dx.abs()) * 180 / math.pi;
      if (ang > 15 && ang < 85) _segs.add([ch[0], ch[1], ch[2], ch[3]]);
    }
    if (_segs.length > 1500) _segs.removeRange(0, _segs.length - 1500);
  }

  void _findVp(int y0) {
    if (_segs.length < 40) return;
    var best = 0.0, total = 0.0;
    (double, double)? at;
    for (final s in _segs) {
      total += math.sqrt(math.pow(s[2] - s[0], 2) + math.pow(s[3] - s[1], 2));
    }
    for (var vy = y0 - 150; vy < y0 - 3; vy += 3) {
      final score = Float64List(w ~/ 3 + 1);
      for (final s in _segs) {
        final dy = s[3] - s[1];
        if (dy == 0) continue;
        final xv = s[0] + (s[2] - s[0]) * (vy - s[1]) / dy;
        final tol = 2 + 0.02 * (vy - s[1]).abs();
        final len = math.sqrt(math.pow(s[2] - s[0], 2) + dy * dy);
        final lo = math.max(0, ((xv - tol) / 3).ceil()), hi = math.min(w ~/ 3, ((xv + tol) / 3).floor());
        for (var i = lo; i <= hi; i++) {
          score[i] += len;
        }
      }
      for (var i = 0; i < score.length; i++) {
        if (score[i] > best) {
          best = score[i];
          at = (i * 3.0, vy.toDouble());
        }
      }
    }
    if (at != null && best / total >= 0.08) vp = at;
  }

  /// Lane-line positions (u) from a pile of mark offsets.
  static List<double> linePeaks(List<double> us) {
    const bins = 160;
    final hist = Float64List(bins);
    for (final u in us) {
      final i = ((u + 8) / 16 * bins).floor();
      if (i >= 0 && i < bins) hist[i]++;
    }
    final hs = Float64List(bins);
    const k = [1, 2, 3, 2, 1];
    var top = 0.0;
    for (var i = 0; i < bins; i++) {
      for (var j = -2; j <= 2; j++) {
        if (i + j >= 0 && i + j < bins) hs[i] += hist[i + j] * k[j + 2];
      }
      top = math.max(top, hs[i]);
    }
    if (top < 20) return const [];
    final cand = [
      for (var i = 1; i < bins - 1; i++)
        if (hs[i] >= hs[i - 1] && hs[i] > hs[i + 1] && hs[i] > math.max(20, 0.3 * top)) i,
    ]..sort((a, b) => hs[b].compareTo(hs[a]));
    final keep = <int>[];
    for (final i in cand) {
      if (keep.every((j) => (i - j).abs() >= 9)) keep.add(i);
    }
    return [for (final i in keep..sort()) (i + 0.5) / bins * 16 - 8];
  }
}
