import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../geo/geo.dart';
import '../nav/route_data.dart';
import '../nav/routing.dart';
import 'sign_icons.dart';

/// Map looks the driver can switch between.
enum MapTheme {
  night('Night'),
  day('Day'),
  game('Game'),
  neon('Neon'),
  toy('Toy');

  const MapTheme(this.label);
  final String label;

  /// Game-style looks: 3D car, working 3D traffic lights, glowing route.
  bool get arcade => this == game || this == neon || this == toy;
}

/// Colours for one map look. [night] is the original in-car style.
class MapPalette {
  const MapPalette({
    required this.ground, required this.green, required this.pitch, required this.paved, required this.bare, required this.water,
    required this.minor, required this.casing, required this.major, required this.majorCasing, required this.lane,
    required this.bldgLo, required this.bldgHi, required this.deck, required this.pillar, required this.shopLo, required this.shopHi,
    required this.signal, required this.signalRing, required this.route, required this.routeCasing, required this.ring,
    this.bldgMix, this.car = '#FF3B30', this.ui = 0xFF0E141B,
  });

  final String ground, green, pitch, paved, bare, water;
  final String minor, casing, major, majorCasing, lane;
  final String bldgLo, bldgHi, deck, pillar, shopLo, shopHi; // shop = buildings with shops/offices (Overture places)
  final String signal, signalRing, route, routeCasing, ring, car;
  /// Game look: every building gets one of these colours instead of a height gradient.
  final List<String>? bldgMix;
  final int ui; // screen background behind the map

  static const night = MapPalette(
    ground: '#0E141B', green: '#13261C', pitch: '#173022', paved: '#1A222B', bare: '#1B1D1F', water: '#0D2638',
    minor: '#2A3644', casing: '#18212B', major: '#3B3527', majorCasing: '#262117', lane: '#75684A',
    bldgLo: '#1C2632', bldgHi: '#2F4054', deck: '#3D4A5A', pillar: '#26303B', shopLo: '#3A2E24', shopHi: '#5A4632',
    signal: '#FF4D55', signalRing: '#1A0B0C', route: '#5C8CFF', routeCasing: '#2346C7', ring: '#E8EEF5',
  );

  static const day = MapPalette(
    ground: '#EDEFF2', green: '#CDE7C6', pitch: '#BCE2B0', paved: '#E0E1E6', bare: '#EAE2D2', water: '#A7D2F0',
    minor: '#FFFFFF', casing: '#CDD1D8', major: '#FFE6A3', majorCasing: '#DDB55A', lane: '#B8963E',
    bldgLo: '#DADDE2', bldgHi: '#B4BCC7', deck: '#C7CCD4', pillar: '#A6ACB5', shopLo: '#EBD3B6', shopHi: '#D6B089',
    signal: '#E5252E', signalRing: '#FFFFFF', route: '#2F6BFF', routeCasing: '#1C46B8', ring: '#FFFFFF', ui: 0xFFEDEFF2,
  );

  /// Bright arcade look: saturated buildings, white lane paint, yellow kerbs,
  /// glowing route, a 3D car and working 3D traffic lights.
  static const game = MapPalette(
    ground: '#3E3A52', green: '#3FAE55', pitch: '#52C46A', paved: '#5C5872', bare: '#C9A66B', water: '#2EC4E6',
    minor: '#4B4A5C', casing: '#E9E6F2', major: '#34333F', majorCasing: '#FFD23F', lane: '#FFFFFF',
    bldgLo: '#7A6FA0', bldgHi: '#B9A8F0', deck: '#9A9EB8', pillar: '#6E7290', shopLo: '#FF6F91', shopHi: '#FF9DB5',
    signal: '#FF3B30', signalRing: '#120A14', route: '#FF3DA8', routeCasing: '#8A0F55', ring: '#FFFFFF', car: '#FF3B30',
    bldgMix: ['#FF8A5B', '#FFC857', '#6CD4FF', '#B892FF', '#7CE38B', '#F2EFE6', '#5E8BFF', '#FFB4A2'],
    ui: 0xFF3E3A52,
  );

  /// Dark city with glowing cyan and magenta road edges and a neon-green route.
  static const neon = MapPalette(
    ground: '#05060B', green: '#0B1F16', pitch: '#0E2A1C', paved: '#10121C', bare: '#14121A', water: '#061A2E',
    minor: '#151826', casing: '#00B8D4', major: '#0C0E18', majorCasing: '#FF2BD6', lane: '#00E5FF',
    bldgLo: '#1A1238', bldgHi: '#5B2BB5', deck: '#1E2240', pillar: '#2A2F55', shopLo: '#3A0F4A', shopHi: '#B01FD0',
    signal: '#FF2B55', signalRing: '#000000', route: '#39FF14', routeCasing: '#0B5E00', ring: '#00E5FF', car: '#00E5FF',
    ui: 0xFF05060B,
  );

  /// Soft toy-town colours: mint ground, white streets, pastel buildings, orange route.
  static const toy = MapPalette(
    ground: '#E3F1DA', green: '#9EDB8C', pitch: '#86D17A', paved: '#D9D4C7', bare: '#F1DDB0', water: '#7FD3F7',
    minor: '#FFFFFF', casing: '#C2C9B8', major: '#5B6173', majorCasing: '#FFFFFF', lane: '#FFFFFF',
    bldgLo: '#F4E9DC', bldgHi: '#E9D8C4', deck: '#C3C8D6', pillar: '#A5ABBC', shopLo: '#FF8FA3', shopHi: '#FFB3C1',
    signal: '#FF3B30', signalRing: '#FFFFFF', route: '#FF7A00', routeCasing: '#B34700', ring: '#FFFFFF', car: '#2F80ED',
    bldgMix: ['#FFB3BA', '#FFDFBA', '#FFF5BA', '#BAFFC9', '#BAE1FF', '#D7BAFF', '#FFFFFF', '#F6C6A8'],
    ui: 0xFFE3F1DA,
  );

  static MapPalette of(MapTheme t) => switch (t) {
        MapTheme.night => night,
        MapTheme.day => day,
        MapTheme.game => game,
        MapTheme.neon => neon,
        MapTheme.toy => toy,
      };
}

/// The style starts with only a background; everything else is our own data.
String baseStyle([MapTheme theme = MapTheme.night]) =>
    '{"version":8,"sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"${MapPalette.of(theme).ground}"}}]}';

/// Width in metres that stays true to scale at every zoom.
/// MapLibre tiles are 512 px, so one screen pixel at zoom z covers
/// 78271.5 * cos(lat) / 2^z metres.
dynamic metres(dynamic m) {
  final mpp = 78271.517 * math.cos(30.07 * math.pi / 180);
  return [
    'interpolate', ['exponential', 2], ['zoom'],
    12, ['*', m, 4096 / mpp],
    21, ['*', m, 2097152 / mpp],
  ];
}

/// Carriageway width in metres: 3.3 m per lane plus edges (l = lanes from
/// OSM, or a default per road class; same rule as tools/build_area.py).
const _roadW = [
  'max',
  ['+', ['*', ['get', 'l'], 3.3], ['case', ['==', ['get', 'ow'], 1], 0.8, 1.6]],
  ['match', ['get', 'c'], 'minor', 5.0, 'link', 4.5, 'service', 3.5, 6.0],
];

/// Layers that the "Traffic lights" switch shows and hides.
const signalLayers = ['signals', 'signal-glow', 'signal-3d'];

/// Layers that the "Road signs" switch shows and hides.
const signLayers = ['road-signs', 'street-names'];

Future<Map<String, dynamic>> _asset(String name) async =>
    jsonDecode(await rootBundle.loadString('assets/data/$name')) as Map<String, dynamic>;

List<List<double>> _quad(List<double> a, List<double> b, double half) {
  final p = Geo.toXY(a[0], a[1]), q = Geo.toXY(b[0], b[1]);
  final d = q - p, len = d.length == 0 ? 1.0 : d.length;
  final n = Vec(-d.y / len * half, d.x / len * half);
  return [Geo.toLonLat(p + n), Geo.toLonLat(q + n), Geo.toLonLat(q - n), Geo.toLonLat(p - n), Geo.toLonLat(p + n)];
}

/// Rectangle (x0..x1 across, y0..y1 along) rotated to [heading] around (lon, lat), metres.
List<List<double>> _box(Vec c, double t, double x0, double y0, double x1, double y1) {
  List<double> pt(double x, double y) => Geo.toLonLat(Vec(c.x + x * math.cos(t) + y * math.sin(t), c.y - x * math.sin(t) + y * math.cos(t)));
  return [pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1), pt(x0, y0)];
}

Map<String, dynamic> _ext(List<List<double>> ring, double b, double t, String color) =>
    {'type': 'Feature', 'properties': {'b': b, 't': t, 'c': color}, 'geometry': {'type': 'Polygon', 'coordinates': [ring]}};

/// Adds the city in the chosen look: main streets with lane markings, flyover
/// decks and pillars, traffic lights, the route and the car. Buildings, small
/// streets and parks start empty and are filled from tiles around the car
/// (see CityTiles). Road signs are added afterwards by [addSignLayers].
/// Returns the traffic-light positions (the game looks animate them).
Future<List<List<double>>> addCityLayers(MapLibreMapController c, RouteData route, {MapTheme theme = MapTheme.night}) async {
  final pal = MapPalette.of(theme);
  final game = theme.arcade;
  final ground = await _asset('ground.json');
  final bridges = await _asset('bridges.json');
  final signalPts = [
    for (final f in (ground['signals']['features'] as List))
      [((f['geometry']['coordinates'] as List)[0] as num).toDouble(), ((f['geometry']['coordinates'] as List)[1] as num).toDouble()],
  ];
  await c.addGeoJsonSource('areas', _empty);
  await c.addGeoJsonSource('roads-local', _empty);
  await c.addGeoJsonSource('roads', ground['roads'] as Map<String, dynamic>);
  await c.addGeoJsonSource('decks', bridges['decks'] as Map<String, dynamic>);
  await c.addGeoJsonSource('pillars', bridges['pillars'] as Map<String, dynamic>);
  await c.addGeoJsonSource('buildings', _empty);
  await c.addGeoJsonSource('signals', ground['signals'] as Map<String, dynamic>);
  await c.addGeoJsonSource('route-ground', routeGroundGeoJson(route));
  await c.addGeoJsonSource('route-ribbon', routeRibbonGeoJson(route));
  await c.addGeoJsonSource('route-alts', _empty);
  await c.addGeoJsonSource('route-traffic', _empty);
  await c.addGeoJsonSource('me', _empty);
  await c.addGeoJsonSource('puck', _empty);
  if (game) {
    await c.addGeoJsonSource('signal-pts', signalGlowGeoJson(signalPts, 0));
    await c.addGeoJsonSource('signal-3d', signals3dGeoJson(signalPts, 0));
  }

  await c.addFillLayer('areas', 'areas', FillLayerProperties(fillColor: [
    'match', ['get', 'k'], 'pitch', pal.pitch, 'paved', pal.paved, 'bare', pal.bare, 'water', pal.water, pal.green,
  ]));
  // small streets from the tiles around the car, under the main roads
  await c.addLineLayer('roads-local', 'local-casing', LineLayerProperties(
    lineColor: pal.casing, lineWidth: metres(['+', _roadW, game ? 1.2 : 1.6]), lineCap: 'round', lineJoin: 'round',
  ), filter: ['!=', ['get', 'c'], 'service']);
  await c.addLineLayer('roads-local', 'local-road', LineLayerProperties(
    lineColor: pal.minor, lineWidth: metres(_roadW), lineCap: 'round', lineJoin: 'round',
  ), filter: ['!=', ['get', 'c'], 'service']);
  await c.addLineLayer('roads', 'road-casing', LineLayerProperties(
    lineColor: ['match', ['get', 'c'], ['major', 'medium', 'link'], pal.majorCasing, pal.casing],
    lineWidth: metres(['+', _roadW, game ? 1.2 : 1.6]), lineCap: 'round', lineJoin: 'round',
  ), filter: ['!=', ['get', 'c'], 'service']);
  await c.addLineLayer('roads', 'road', LineLayerProperties(
    lineColor: ['match', ['get', 'c'], ['major', 'medium', 'link'], pal.major, pal.minor],
    lineWidth: metres(_roadW), lineCap: 'round', lineJoin: 'round',
  ), filter: ['!=', ['get', 'c'], 'service']);
  for (var k = 1; k <= 4; k++) {
    await c.addLineLayer('roads', 'lane-$k', LineLayerProperties(
      lineColor: pal.lane, lineDasharray: const [3, 4], lineWidth: metres(game ? 0.35 : 0.25),
      lineOffset: metres(['*', ['-', k, ['/', ['get', 'l'], 2]], 3.3]),
    ), minzoom: 15.5, filter: ['all', ['==', ['get', 'ow'], 1], ['>', ['get', 'l'], k], ['in', ['get', 'c'], ['literal', ['major', 'medium']]]]);
  }
  if (hasTraffic) {
    // live traffic speed on every road (TomTom tiles, green = free flow .. red = jammed)
    await c.addSource('traffic-flow', RasterSourceProperties(tiles: [trafficTileUrl], tileSize: 256));
    await c.addRasterLayer('traffic-flow', 'traffic-flow', const RasterLayerProperties(rasterOpacity: 0.8), minzoom: 11);
  }
  // other route choices while the driver picks one
  await c.addLineLayer('route-alts', 'route-alts', LineLayerProperties(
      lineColor: theme == MapTheme.day || theme == MapTheme.toy ? '#8E9AAD' : '#7D8AA0', lineWidth: metres(5), lineOpacity: 0.75, lineCap: 'round', lineJoin: 'round'));
  if (game) {
    await c.addLineLayer('route-ground', 'route-glow', LineLayerProperties(
        lineColor: pal.route, lineWidth: metres(16), lineBlur: metres(8), lineOpacity: 0.45, lineCap: 'round', lineJoin: 'round'));
  }
  await c.addLineLayer('route-ground', 'route-casing', LineLayerProperties(
      lineColor: pal.routeCasing, lineWidth: metres(6.4), lineCap: 'round', lineJoin: 'round'));
  await c.addLineLayer('route-ground', 'route', LineLayerProperties(
      lineColor: pal.route, lineWidth: metres(4.6), lineCap: 'round', lineJoin: 'round'));
  // slow stretches on the chosen route (only with live traffic)
  await c.addLineLayer('route-traffic', 'route-traffic', LineLayerProperties(
      lineColor: const ['match', ['get', 'm'], 1, '#FFB020', 2, '#FF7A1A', 3, '#E8262B', '#8B0F14'],
      lineWidth: metres(4.6), lineCap: 'round', lineJoin: 'round'));
  if (game) {
    // glow of each traffic light on the road surface, in its current colour
    await c.addCircleLayer('signal-pts', 'signal-glow', const CircleLayerProperties(
      circleColor: ['get', 'c'], circleRadius: ['interpolate', ['linear'], ['zoom'], 15, 6, 19, 40],
      circleBlur: 1, circleOpacity: 0.55, circlePitchAlignment: 'map',
    ), minzoom: 15);
  }
  await c.addFillExtrusionLayer('pillars', 'pillars', FillExtrusionLayerProperties(
      fillExtrusionColor: pal.pillar, fillExtrusionHeight: ['get', 'h'], fillExtrusionBase: 0));
  await c.addFillExtrusionLayer('decks', 'decks', FillExtrusionLayerProperties(
      fillExtrusionColor: pal.deck, fillExtrusionHeight: ['get', 'h'], fillExtrusionBase: ['get', 'b'], fillExtrusionVerticalGradient: false));
  await c.addFillExtrusionLayer('route-ribbon', 'route-ribbon', FillExtrusionLayerProperties(
      fillExtrusionColor: pal.route, fillExtrusionHeight: ['get', 't'], fillExtrusionBase: ['get', 'b'], fillExtrusionVerticalGradient: false));
  final mix = pal.bldgMix;
  await c.addFillExtrusionLayer('buildings', 'buildings', FillExtrusionLayerProperties(
    fillExtrusionColor: [
      'case',
      ['==', ['get', 'com'], 1], ['interpolate', ['linear'], ['get', 'h'], 4, pal.shopLo, 40, pal.shopHi],
      if (mix != null) ['match', ['get', 'v'], for (var i = 0; i < mix.length; i++) ...[i, mix[i]], mix.first]
      else ['interpolate', ['linear'], ['get', 'h'], 4, pal.bldgLo, 40, pal.bldgHi],
    ],
    fillExtrusionHeight: ['get', 'h'], fillExtrusionBase: 0, fillExtrusionOpacity: game ? 0.97 : 0.9,
  ));
  if (game) {
    // 3D traffic lights: pole, housing and a lamp that cycles green, amber, red
    await c.addFillExtrusionLayer('signal-3d', 'signal-3d', const FillExtrusionLayerProperties(
        fillExtrusionColor: ['get', 'c'], fillExtrusionHeight: ['get', 't'], fillExtrusionBase: ['get', 'b'], fillExtrusionVerticalGradient: false),
        minzoom: 14.5);
  } else {
    // traffic lights mapped in OpenStreetMap (incomplete in Cairo; road capture will fill the gaps)
    await c.addCircleLayer('signals', 'signals', CircleLayerProperties(
      circleColor: pal.signal, circleRadius: const ['interpolate', ['linear'], ['zoom'], 14, 2.5, 18, 7],
      circleStrokeColor: pal.signalRing, circleStrokeWidth: 1.5, circlePitchAlignment: 'map',
    ), minzoom: 14);
  }
  // "my location" dot (used when the car on screen is the simulation)
  await c.addCircleLayer('me', 'me-acc', const CircleLayerProperties(
      circleColor: '#4C8DFF', circleOpacity: 0.18, circleRadius: ['max', 10, ['get', 'r']], circlePitchAlignment: 'map'));
  await c.addCircleLayer('me', 'me', const CircleLayerProperties(
      circleColor: '#4C8DFF', circleRadius: 8, circleStrokeColor: '#FFFFFF', circleStrokeWidth: 3, circlePitchAlignment: 'map'));
  await c.addFillExtrusionLayer('puck', 'puck', const FillExtrusionLayerProperties(
      fillExtrusionColor: ['get', 'c'], fillExtrusionHeight: ['get', 't'], fillExtrusionBase: ['get', 'b'], fillExtrusionVerticalGradient: false));
  return signalPts;
}

const _empty = {'type': 'FeatureCollection', 'features': <dynamic>[]};

/// The road signs on the map, and which street-name plates have been drawn.
class SignSet {
  SignSet(this.feats, this.names);
  final List<dynamic> feats;
  final List<dynamic> names;
  final Set<int> drawn = {};
}

/// Road signs standing beside the road (they always face the camera). Called
/// after the map is showing. Street-name plates are drawn only for the streets
/// around the car ([drawNamePlates]): all 500+ at once would take seconds and
/// about 100 MB of graphics memory.
Future<SignSet> addSignLayers(MapLibreMapController c, MapTheme theme) async {
  final signs = await _asset('signs.json');
  await c.addGeoJsonSource('signs', signs['signs'] as Map<String, dynamic>);
  final feats = (signs['signs']['features'] as List);
  final kinds = <String>{for (final f in feats) f['properties']['k'] as String};
  for (final k in kinds) {
    if (k == 'name') continue;
    final png = k.startsWith('speed-')
        ? await SignIcons.speed(k.substring(6))
        : switch (k) {
            'camera' => await SignIcons.camera(),
            'crossing' => await SignIcons.crossing(),
            'signal' => await SignIcons.signal(),
            'stop' => await SignIcons.stop(),
            'give_way' => await SignIcons.giveWay(),
            _ => null,
          };
    if (png != null) await c.addImage(k, png);
  }
  const size = ['interpolate', ['linear'], ['zoom'], 15, 0.32, 17, 0.5, 19, 0.8];
  await c.addSymbolLayer('signs', 'road-signs', SymbolLayerProperties(
    iconImage: const ['get', 'k'], iconSize: size, iconAnchor: 'bottom', iconAllowOverlap: true, iconIgnorePlacement: true,
  ), minzoom: 15, belowLayerId: 'me-acc', filter: [
    'all', ['!=', ['get', 'k'], 'name'],
    if (theme.arcade) ['!=', ['get', 'k'], 'signal'] else true, // game looks have 3D lights
  ]);
  await c.addSymbolLayer('signs', 'street-names', const SymbolLayerProperties(
    iconImage: ['concat', 'name-', ['to-string', ['get', 'ni']]], iconSize: size, iconAnchor: 'bottom', iconPadding: 4,
  ), minzoom: 15.5, belowLayerId: 'me-acc', filter: ['==', ['get', 'k'], 'name']);
  return SignSet(feats, signs['names'] as List);
}

/// Draws the street-name plates for streets inside [box] (west, south, east, north).
Future<void> drawNamePlates(MapLibreMapController c, SignSet s, List<double> box) async {
  for (final f in s.feats) {
    final p = f['properties'] as Map;
    if (p['k'] != 'name') continue;
    final i = (p['ni'] as num).toInt();
    if (s.drawn.contains(i)) continue;
    final xy = f['geometry']['coordinates'] as List;
    final lon = (xy[0] as num).toDouble(), lat = (xy[1] as num).toDouble();
    if (lon < box[0] || lat < box[1] || lon > box[2] || lat > box[3]) continue;
    s.drawn.add(i);
    await c.addImage('name-$i', await SignIcons.name(i, s.names[i][0] as String, s.names[i][1] as String));
  }
}

/// The planned route on the ground (flat line).
Map<String, dynamic> routeGroundGeoJson(RouteData route) => {
      'type': 'Feature', 'properties': {},
      'geometry': {'type': 'MultiLineString', 'coordinates': route.groundParts()},
    };

/// The planned route where it runs up on a flyover (raised ribbon).
Map<String, dynamic> routeRibbonGeoJson(RouteData route) {
  final ribbon = <Map<String, dynamic>>[];
  for (var i = 0; i < route.coords.length - 1; i++) {
    if (math.max(route.elev[i], route.elev[i + 1]) < 0.5) continue;
    final h = (route.elev[i] + route.elev[i + 1]) / 2;
    ribbon.add({
      'type': 'Feature', 'properties': {'b': math.max(h - 0.02, 0), 't': h + 0.22},
      'geometry': {'type': 'Polygon', 'coordinates': [_quad(route.coords[i], route.coords[i + 1], 2.6)]},
    });
  }
  return {'type': 'FeatureCollection', 'features': ribbon};
}

/// Shows [route] as the active route, with its slow stretches when known,
/// and [alternatives] in grey (pass none once the driver has chosen).
Future<void> showRoute(MapLibreMapController c, RouteData route,
    {List<TrafficStretch> traffic = const [], List<List<List<double>>> alternatives = const []}) async {
  await c.setGeoJsonSource('route-ground', routeGroundGeoJson(route));
  await c.setGeoJsonSource('route-ribbon', routeRibbonGeoJson(route));
  await c.setGeoJsonSource('route-alts', {
    'type': 'FeatureCollection',
    'features': [for (final a in alternatives) {'type': 'Feature', 'properties': {}, 'geometry': {'type': 'LineString', 'coordinates': a}}],
  });
  final slow = <Map<String, dynamic>>[];
  for (final t in traffic) {
    final pts = <List<double>>[];
    for (var i = 0; i < route.coords.length; i++) {
      if (route.cum[i] >= t.from && route.cum[i] <= t.to) pts.add(route.coords[i]);
    }
    if (pts.length > 1) slow.add({'type': 'Feature', 'properties': {'m': t.level}, 'geometry': {'type': 'LineString', 'coordinates': pts}});
  }
  await c.setGeoJsonSource('route-traffic', {'type': 'FeatureCollection', 'features': slow});
}

/// Light state for signal [i] at second [tick]: each runs its own 30 s cycle.
String _lamp(int i, int tick) {
  final s = (tick + i * 11) % 30;
  return s < 14 ? '#3DFF6E' : s < 17 ? '#FFC21A' : '#FF3B30';
}

Map<String, dynamic> signalGlowGeoJson(List<List<double>> pts, int tick) => {
      'type': 'FeatureCollection',
      'features': [
        for (var i = 0; i < pts.length; i++)
          {'type': 'Feature', 'properties': {'c': _lamp(i, tick)}, 'geometry': {'type': 'Point', 'coordinates': pts[i]}},
      ],
    };

/// Each traffic light as a pole, a dark housing and a coloured lamp block,
/// drawn about 1.5x real size so it reads at driving zoom.
Map<String, dynamic> signals3dGeoJson(List<List<double>> pts, int tick) {
  final f = <Map<String, dynamic>>[];
  for (var i = 0; i < pts.length; i++) {
    final c = Geo.toXY(pts[i][0], pts[i][1]);
    f.add(_ext(_box(c, 0, -0.35, -0.35, 0.35, 0.35), 0, 7.0, '#2A2833'));
    f.add(_ext(_box(c, 0, -0.8, -0.8, 0.8, 0.8), 7.0, 9.6, '#15141B'));
    f.add(_ext(_box(c, 0, -0.95, -0.95, 0.95, 0.95), 8.0, 8.9, _lamp(i, tick)));
    f.add(_ext(_box(c, 0, -1.0, -1.0, 1.0, 1.0), 9.6, 9.8, '#15141B')); // visor
  }
  return {'type': 'FeatureCollection', 'features': f};
}

/// Car marker raised onto the flyover deck when the detector says we are up
/// there: a disc with an arrow, or in the game look a small 3D car.
Map<String, dynamic> puckGeoJson(double lon, double lat, double heading, double height, {MapTheme theme = MapTheme.night, bool hidden = false}) {
  if (hidden) return _empty;
  final pal = MapPalette.of(theme);
  final c = Geo.toXY(lon, lat);
  final t = heading * math.pi / 180;
  List<List<double>> ring(List<List<double>> pts) {
    final r = pts.map((p) => Geo.toLonLat(Vec(c.x + p[0] * math.cos(t) + p[1] * math.sin(t), c.y - p[0] * math.sin(t) + p[1] * math.cos(t)))).toList();
    r.add(r.first);
    return r;
  }

  final base = height > 0.3 ? height + 0.25 : 0.05;
  if (theme.arcade) {
    // about 1.8x real size: body, glass cabin, roof, wheels, headlights, tail lights
    const k = 1.8;
    List<List<double>> b(double x0, double y0, double x1, double y1) => _box(c, t, x0 * k, y0 * k, x1 * k, y1 * k);
    return {
      'type': 'FeatureCollection',
      'features': [
        for (final x in [-0.95, 0.75]) for (final y in [-1.65, 1.15]) _ext(b(x, y, x + 0.2, y + 0.6), base, base + 0.65 * k, '#111111'),
        _ext(b(-0.9, -2.25, 0.9, 2.25), base + 0.25 * k, base + 0.95 * k, pal.car),
        _ext(b(-0.78, -1.2, 0.78, 0.9), base + 0.95 * k, base + 1.45 * k, '#1B2A3A'),
        _ext(b(-0.72, -1.1, 0.72, 0.75), base + 1.45 * k, base + 1.55 * k, pal.car),
        _ext(b(-0.8, 2.2, -0.4, 2.3), base + 0.55 * k, base + 0.8 * k, '#FFF6C2'),
        _ext(b(0.4, 2.2, 0.8, 2.3), base + 0.55 * k, base + 0.8 * k, '#FFF6C2'),
        _ext(b(-0.8, -2.3, -0.4, -2.2), base + 0.6 * k, base + 0.8 * k, '#FF1A1A'),
        _ext(b(0.4, -2.3, 0.8, -2.2), base + 0.6 * k, base + 0.8 * k, '#FF1A1A'),
      ],
    };
  }
  final disc = List.generate(24, (k) => [math.cos(k / 24 * 2 * math.pi) * 8.5, math.sin(k / 24 * 2 * math.pi) * 8.5]);
  return {
    'type': 'FeatureCollection',
    'features': [
      {'type': 'Feature', 'properties': {'b': base, 't': base + 0.35, 'c': pal.ring}, 'geometry': {'type': 'Polygon', 'coordinates': [ring(disc)]}},
      {'type': 'Feature', 'properties': {'b': base + 0.35, 't': base + 1.6, 'c': pal.route},
        'geometry': {'type': 'Polygon', 'coordinates': [ring([[0, 7.5], [5.2, -5.5], [0, -2.6], [-5.2, -5.5]])]}},
    ],
  };
}

/// "My location" dot with its accuracy circle (radius in pixels at the current zoom is approximate).
Map<String, dynamic> meGeoJson(double lon, double lat, double accuracyM, double zoom) {
  final mpp = 78271.517 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
  return {
    'type': 'FeatureCollection',
    'features': [
      {'type': 'Feature', 'properties': {'r': accuracyM / mpp}, 'geometry': {'type': 'Point', 'coordinates': [lon, lat]}},
    ],
  };
}
