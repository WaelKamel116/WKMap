import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// A place the driver can route to.
class Place {
  const Place(this.name, this.detail, this.lon, this.lat, {this.online = false});
  final String name, detail;
  final double lon, lat;
  final bool online;
}

/// Finds places by name: first the offline index built into the app
/// (shops, malls, clinics and main roads along the mapped area, from Overture
/// and OpenStreetMap), then the free Photon geocoder (OpenStreetMap, all of
/// Egypt) when there is internet.
class PlaceSearch {
  List<List<dynamic>>? _index;

  Future<void> _load() async {
    if (_index != null) return;
    final j = jsonDecode(await rootBundle.loadString('assets/data/places.json')) as Map<String, dynamic>;
    _index = (j['places'] as List).cast<List<dynamic>>();
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Offline matches, best first: whole-name prefix, then word prefix, then anywhere.
  Future<List<Place>> local(String query, {int limit = 15}) async {
    await _load();
    final q = _norm(query);
    if (q.isEmpty) return const [];
    final words = q.split(' ');
    final scored = <(int, Place)>[];
    for (final r in _index!) {
      final n = _norm(r[0] as String);
      if (!words.every(n.contains)) continue;
      final score = n.startsWith(q) ? 0 : n.split(' ').any((w) => w.startsWith(words.first)) ? 1 : 2;
      final cat = (r[1] as String).replaceAll('_', ' ');
      scored.add((score * 1000 + n.length, Place(r[0] as String, cat, (r[2] as num).toDouble(), (r[3] as num).toDouble())));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final s in scored.take(limit)) s.$2];
  }

  /// Online matches near Cairo (Photon, OpenStreetMap data). Empty without internet.
  Future<List<Place>> online(String query, {double lon = 31.37, double lat = 30.05}) async {
    if (query.trim().length < 3) return const [];
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.https('photon.komoot.io', '/api/', {
        'q': query, 'lat': '$lat', 'lon': '$lon', 'limit': '8',
        'bbox': '30.9,29.7,32.0,30.4', // Greater Cairo
      }));
      req.headers.set(HttpHeaders.userAgentHeader, 'CairoNav-test/0.1');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      return [
        for (final f in j['features'] as List)
          if ((f['properties']['name'] as String?)?.isNotEmpty == true)
            Place(
              f['properties']['name'] as String,
              [f['properties']['street'], f['properties']['district'], f['properties']['city']].whereType<String>().join(', '),
              ((f['geometry']['coordinates'] as List)[0] as num).toDouble(),
              ((f['geometry']['coordinates'] as List)[1] as num).toDouble(),
              online: true,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
