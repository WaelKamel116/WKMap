import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../geo/geo.dart';
import 'match_data.dart';
import 'route_data.dart';

/// TomTom key for live traffic, given at build time:
///   flutter build apk --dart-define=TOMTOM_KEY=...
/// Without it, routes come from the free Valhalla server (no live traffic).
const tomtomKey = String.fromEnvironment('TOMTOM_KEY');
bool get hasTraffic => tomtomKey.isNotEmpty;

/// What kind of route the driver wants.
class RoutePrefs {
  const RoutePrefs({this.shortest = false, this.avoidHighways = false});
  final bool shortest, avoidHighways;
  RoutePrefs copyWith({bool? shortest, bool? avoidHighways}) =>
      RoutePrefs(shortest: shortest ?? this.shortest, avoidHighways: avoidHighways ?? this.avoidHighways);
}

/// One turn instruction, [offset] metres from the start of the route.
class Maneuver {
  const Maneuver(this.offset, this.text, this.kind);
  final double offset;
  final String text;

  /// left, right, slight_left, slight_right, sharp_left, sharp_right, uturn,
  /// roundabout, straight, merge, ramp, arrive, depart
  final String kind;
}

/// A stretch of the route slowed by traffic: from/to in metres, level 1 (slow) .. 4 (blocked).
class TrafficStretch {
  const TrafficStretch(this.from, this.to, this.level);
  final double from, to;
  final int level;
}

class RouteOption {
  RouteOption({
    required this.coords,
    required this.distance,
    required this.duration,
    required this.maneuvers,
    this.trafficDelay,
    this.traffic = const [],
    required this.source,
  });
  final List<List<double>> coords; // [lon, lat]
  final double distance; // m
  final double duration; // s, including traffic when known
  final double? trafficDelay; // s, null when there is no traffic data
  final List<Maneuver> maneuvers;
  final List<TrafficStretch> traffic;
  final String source;
  String label = '';

  /// Turns the route into the app's route model, with flyover deck heights
  /// taken from the map wherever the route runs along a flyover.
  RouteData toRouteData(MatchData match) {
    final pts = <List<double>>[];
    for (var i = 0; i < coords.length - 1; i++) {
      final a = Geo.toXY(coords[i][0], coords[i][1]), b = Geo.toXY(coords[i + 1][0], coords[i + 1][1]);
      final n = math.max(1, ((b - a).length / 8).ceil()); // a point every 8 m or less
      for (var k = 0; k < n; k++) {
        pts.add(Geo.toLonLat(a + (b - a) * (k / n)));
      }
    }
    pts.add(coords.last);
    final xy = pts.map((c) => Geo.toXY(c[0], c[1])).toList();
    final cum = <double>[0];
    for (var i = 1; i < xy.length; i++) {
      cum.add(cum.last + (xy[i] - xy[i - 1]).length);
    }
    final elev = List<double>.filled(xy.length, 0);
    for (var i = 0; i < xy.length; i++) {
      final hdg = Geo.bearing(xy[math.max(0, i - 1)], xy[math.min(xy.length - 1, i + 1)]);
      final c = match.candidates(xy[i], 3, hdg, maxAngle: 25);
      if (c.isNotEmpty && c.first.line.isBridge) elev[i] = c.first.height;
    }
    return RouteData(pts, elev, cum, cum.last);
  }
}

class RoutingError implements Exception {
  RoutingError(this.message);
  final String message;
  @override
  String toString() => message;
}

final _http = HttpClient()..connectionTimeout = const Duration(seconds: 12);

Future<dynamic> _getJson(Uri uri) async {
  final req = await _http.getUrl(uri);
  req.headers.set(HttpHeaders.userAgentHeader, 'CairoNav-test/0.1');
  final res = await req.close().timeout(const Duration(seconds: 25));
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode != 200) throw RoutingError('Route server answered ${res.statusCode}');
  return jsonDecode(body);
}

/// Up to three routes from [from] to [to] ([lon, lat]), best first.
Future<List<RouteOption>> fetchRoutes(List<double> from, List<double> to, RoutePrefs prefs) async {
  try {
    final out = hasTraffic ? await _tomtom(from, to, prefs) : await _valhalla(from, to, prefs);
    if (out.isEmpty) throw RoutingError('No route found');
    out.sort((a, b) => prefs.shortest ? a.distance.compareTo(b.distance) : a.duration.compareTo(b.duration));
    for (var i = 0; i < out.length; i++) {
      out[i].label = i == 0 ? (prefs.shortest ? 'Shortest' : 'Fastest') : 'Option ${i + 1}';
    }
    return out;
  } on SocketException {
    throw RoutingError('No internet connection. Route search needs mobile data.');
  } on HandshakeException {
    throw RoutingError('Secure connection to the route server failed.');
  }
}

// ---------------------------------------------------------------- Valhalla (free, no traffic)

Future<List<RouteOption>> _valhalla(List<double> from, List<double> to, RoutePrefs prefs) async {
  final q = {
    'locations': [
      {'lon': from[0], 'lat': from[1]},
      {'lon': to[0], 'lat': to[1]},
    ],
    'costing': 'auto',
    'costing_options': {
      'auto': {if (prefs.shortest) 'shortest': true, if (prefs.avoidHighways) 'use_highways': 0.0},
    },
    'alternates': 2,
    'units': 'kilometers',
    'language': 'en-US',
  };
  final j = await _getJson(Uri.https('valhalla1.openstreetmap.de', '/route', {'json': jsonEncode(q)})) as Map<String, dynamic>;
  final trips = [j['trip'], ...((j['alternates'] as List?) ?? const []).map((a) => a['trip'])];
  return [for (final t in trips) if (t != null) _valhallaTrip(t as Map<String, dynamic>)];
}

RouteOption _valhallaTrip(Map<String, dynamic> t) {
  final coords = <List<double>>[];
  final man = <Maneuver>[];
  for (final leg in t['legs'] as List) {
    final shape = decodePolyline(leg['shape'] as String, 6);
    final base = coords.length;
    coords.addAll(shape);
    final cum = _cum(coords);
    for (final m in leg['maneuvers'] as List) {
      final idx = base + (m['begin_shape_index'] as num).toInt();
      man.add(Maneuver(cum[math.min(idx, cum.length - 1)], m['instruction'] as String? ?? '', _valhallaKind((m['type'] as num).toInt())));
    }
  }
  final s = t['summary'] as Map<String, dynamic>;
  return RouteOption(
    coords: coords,
    distance: (s['length'] as num).toDouble() * 1000,
    duration: (s['time'] as num).toDouble(),
    maneuvers: man,
    source: 'Valhalla (OpenStreetMap), no live traffic',
  );
}

String _valhallaKind(int t) => switch (t) {
      1 || 2 || 3 => 'depart',
      4 || 5 || 6 => 'arrive',
      9 || 23 => 'slight_right',
      10 => 'right',
      11 => 'sharp_right',
      12 || 13 => 'uturn',
      14 => 'sharp_left',
      15 => 'left',
      16 || 24 => 'slight_left',
      18 || 19 || 20 || 21 => 'ramp',
      25 || 37 || 38 => 'merge',
      26 || 27 => 'roundabout',
      _ => 'straight',
    };

// ---------------------------------------------------------------- TomTom (live traffic, needs key)

Future<List<RouteOption>> _tomtom(List<double> from, List<double> to, RoutePrefs prefs) async {
  final uri = Uri.https('api.tomtom.com', '/routing/1/calculateRoute/${from[1]},${from[0]}:${to[1]},${to[0]}/json', {
    'key': tomtomKey,
    'traffic': 'true',
    'travelMode': 'car',
    'routeType': prefs.shortest ? 'shortest' : 'fastest',
    if (prefs.avoidHighways) 'avoid': 'motorways',
    'maxAlternatives': '2',
    'instructionsType': 'text',
    'sectionType': 'traffic',
    'language': 'en-GB',
  });
  final j = await _getJson(uri) as Map<String, dynamic>;
  final out = <RouteOption>[];
  for (final r in (j['routes'] as List? ?? const [])) {
    final coords = <List<double>>[
      for (final leg in r['legs'] as List)
        for (final p in leg['points'] as List) [(p['longitude'] as num).toDouble(), (p['latitude'] as num).toDouble()],
    ];
    final cum = _cum(coords);
    final s = r['summary'] as Map<String, dynamic>;
    final man = <Maneuver>[
      for (final ins in ((r['guidance']?['instructions']) as List? ?? const []))
        Maneuver((ins['routeOffsetInMeters'] as num).toDouble(), ins['message'] as String? ?? '', _tomtomKind(ins['maneuver'] as String? ?? '')),
    ];
    final traffic = <TrafficStretch>[
      for (final sec in (r['sections'] as List? ?? const []))
        if (sec['sectionType'] == 'TRAFFIC')
          TrafficStretch(cum[math.min((sec['startPointIndex'] as num).toInt(), cum.length - 1)],
              cum[math.min((sec['endPointIndex'] as num).toInt(), cum.length - 1)], ((sec['magnitudeOfDelay'] as num?) ?? 1).toInt().clamp(1, 4)),
    ];
    out.add(RouteOption(
      coords: coords,
      distance: (s['lengthInMeters'] as num).toDouble(),
      duration: (s['travelTimeInSeconds'] as num).toDouble(),
      trafficDelay: ((s['trafficDelayInSeconds'] as num?) ?? 0).toDouble(),
      maneuvers: man,
      traffic: traffic,
      source: 'TomTom, live traffic',
    ));
  }
  return out;
}

String _tomtomKind(String m) {
  if (m.contains('ROUNDABOUT')) return 'roundabout';
  if (m.contains('MOTORWAY') || m.contains('EXIT') || m.contains('RAMP')) return 'ramp';
  if (m.startsWith('MAKE_UTURN')) return 'uturn';
  if (m.startsWith('ARRIVE')) return 'arrive';
  if (m.startsWith('DEPART')) return 'depart';
  if (m == 'SHARP_LEFT') return 'sharp_left';
  if (m == 'SHARP_RIGHT') return 'sharp_right';
  if (m == 'BEAR_LEFT' || m == 'KEEP_LEFT') return 'slight_left';
  if (m == 'BEAR_RIGHT' || m == 'KEEP_RIGHT') return 'slight_right';
  if (m == 'TURN_LEFT') return 'left';
  if (m == 'TURN_RIGHT') return 'right';
  return 'straight';
}

/// Raster tiles of live traffic speed (green..red), shown over the roads when a key is set.
String get trafficTileUrl =>
    'https://api.tomtom.com/traffic/map/4/tile/flow/relative0/{z}/{x}/{y}.png?key=$tomtomKey&tileSize=256&thickness=8';

// ---------------------------------------------------------------- helpers

List<double> _cum(List<List<double>> coords) {
  final out = <double>[0];
  for (var i = 1; i < coords.length; i++) {
    out.add(out.last + (Geo.toXY(coords[i][0], coords[i][1]) - Geo.toXY(coords[i - 1][0], coords[i - 1][1])).length);
  }
  return out;
}

/// Google-style encoded polyline (precision 5 or 6) to [lon, lat] pairs.
List<List<double>> decodePolyline(String s, int precision) {
  final f = math.pow(10, precision).toDouble();
  final out = <List<double>>[];
  var i = 0, lat = 0, lon = 0;
  int next() {
    var shift = 0, result = 0, b = 0;
    do {
      b = s.codeUnitAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (i < s.length) {
    lat += next();
    lon += next();
    out.add([lon / f, lat / f]);
  }
  return out;
}
