import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Buildings, small streets and parks come in 0.01 degree tiles (about
/// 1 km, built by tools/build_area.py). The whole of Nasr City, Heliopolis
/// and New Cairo is far too much to hand to the map at once, so only the
/// 3 x 3 tiles around the car (or the middle of the screen) are shown, and
/// they are swapped as the car moves on.
class CityTiles {
  double _size = 0.01;
  Set<String> _available = const {};
  final _cache = <String, Map<String, dynamic>>{}; // insertion-ordered: least recently used first
  static const _keep = 40;
  String _shownKey = '';

  Future<void> init() async {
    final j = jsonDecode(await rootBundle.loadString('assets/data/tiles/index.json')) as Map<String, dynamic>;
    _size = (j['size'] as num).toDouble();
    _available = (j['tiles'] as Map<String, dynamic>).keys.toSet();
  }

  bool get ready => _available.isNotEmpty;

  List<String> _around(double lon, double lat) {
    final ix = (lon / _size).floor(), iy = (lat / _size).floor();
    return [
      for (var dx = -1; dx <= 1; dx++)
        for (var dy = -1; dy <= 1; dy++)
          if (_available.contains('${ix + dx}_${iy + dy}')) '${ix + dx}_${iy + dy}',
    ];
  }

  /// True when the tiles around (lon, lat) differ from what is on the map.
  bool needsUpdate(double lon, double lat) => ready && _around(lon, lat).join(',') != _shownKey;

  /// West, south, east, north of the tiles on the map (null before the first load).
  List<double>? get shownBox {
    if (_shownKey.isEmpty) return null;
    var w = 999.0, s = 999.0, e = -999.0, n = -999.0;
    for (final k in _shownKey.split(',')) {
      final ix = int.parse(k.split('_')[0]), iy = int.parse(k.split('_')[1]);
      if (ix * _size < w) w = ix * _size;
      if (iy * _size < s) s = iy * _size;
      if ((ix + 1) * _size > e) e = (ix + 1) * _size;
      if ((iy + 1) * _size > n) n = (iy + 1) * _size;
    }
    return [w, s, e, n];
  }

  /// Forget what is on the map (after the style was reloaded).
  void reset() => _shownKey = '';

  Future<Map<String, dynamic>> _tile(String k) async {
    final hit = _cache.remove(k);
    if (hit != null) {
      _cache[k] = hit;
      return hit;
    }
    final t = jsonDecode(await rootBundle.loadString('assets/data/tiles/$k.json')) as Map<String, dynamic>;
    // colour variant for the game looks, fixed per building so it never changes as tiles swap
    for (final f in t['b'] as List) {
      final c = (f['geometry']['coordinates'] as List)[0][0] as List;
      (f['properties'] as Map)['v'] = (((c[0] as num) * 1e5).round() + ((c[1] as num) * 1e5).round() * 7).abs() % 8;
    }
    _cache[k] = t;
    while (_cache.length > _keep) {
      _cache.remove(_cache.keys.first);
    }
    return t;
  }

  /// Buildings ('b'), small streets ('r') and parks ('a') around (lon, lat), as
  /// feature collections, and remembers them as shown.
  Future<Map<String, Map<String, dynamic>>> around(double lon, double lat) async {
    final keys = _around(lon, lat);
    final out = {'b': <dynamic>[], 'r': <dynamic>[], 'a': <dynamic>[]};
    for (final k in keys) {
      final t = await _tile(k);
      for (final part in out.keys) {
        out[part]!.addAll(t[part] as List);
      }
    }
    _shownKey = keys.join(',');
    return {for (final e in out.entries) e.key: {'type': 'FeatureCollection', 'features': e.value}};
  }
}
