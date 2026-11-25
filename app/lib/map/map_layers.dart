import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../geo/geo.dart';
import '../nav/route_data.dart';

/// Night palette for in-car use (same look as the web demo's night mode).
class MapPalette {
  static const ground = '#0E141B', green = '#13261C', pitch = '#173022', paved = '#1A222B', bare = '#1B1D1F', water = '#0D2638';
  static const minor = '#2A3644', casing = '#18212B', major = '#3B3527', majorCasing = '#262117', lane = '#75684A';
  static const bldgLo = '#1C2632', bldgHi = '#2F4054', deck = '#3D4A5A', pillar = '#26303B';
  static const shopLo = '#3A2E24', shopHi = '#5A4632'; // buildings with shops/offices (Overture places)
  static const signal = '#FF4D55', signalRing = '#1A0B0C';
  static const route = '#5C8CFF', routeCasing = '#2346C7', ring = '#E8EEF5';
}

/// The style starts with only a background; everything else is our own data.
const String baseStyle = '{"version":8,"sources":{},"layers":[{"id":"bg","type":"background","paint":{"background-color":"${MapPalette.ground}"}}]}';

/// Width in metres that stays true to scale at every zoom.
dynamic metres(dynamic m) {
  final mpp = 156543.03 * math.cos(30.07 * math.pi / 180);
  return [
    'interpolate', ['exponential', 2], ['zoom'],
    12, ['*', m, 4096 / mpp],
    21, ['*', m, 2097152 / mpp],
  ];
}

const _roadW = [
  'case',
  ['==', ['get', 'c'], 'minor'], 7,
  ['==', ['get', 'c'], 'link'], ['max', ['*', ['get', 'l'], 3.4], 4.5],
  ['==', ['get', 'ow'], 1], ['+', ['*', ['get', 'l'], 3.4], 0.6],
  ['max', ['*', ['get', 'l'], 3.4], 7],
];

Future<Map<String, dynamic>> _asset(String name) async =>
    jsonDecode(await rootBundle.loadString('assets/data/$name')) as Map<String, dynamic>;

List<List<double>> _quad(List<double> a, List<double> b, double half) {
  final p = Geo.toXY(a[0], a[1]), q = Geo.toXY(b[0], b[1]);
  final d = q - p, len = d.length == 0 ? 1.0 : d.length;
  final n = Vec(-d.y / len * half, d.x / len * half);
  return [Geo.toLonLat(p + n), Geo.toLonLat(q + n), Geo.toLonLat(q - n), Geo.toLonLat(p - n), Geo.toLonLat(p + n)];
}

/// Adds the whole city: parks, streets with lane markings, flyover decks and
/// pillars, 3D buildings, the route and the car puck.
Future<void> addCityLayers(MapLibreMapController c, RouteData route) async {
  final ground = await _asset('ground.json');
  final bridges = await _asset('bridges.json');
  final buildings = await _asset('buildings.json');

  await c.addGeoJsonSource('areas', ground['areas'] as Map<String, dynamic>);
  await c.addGeoJsonSource('roads', ground['roads'] as Map<String, dynamic>);
  await c.addGeoJsonSource('decks', bridges['decks'] as Map<String, dynamic>);
  await c.addGeoJsonSource('pillars', bridges['pillars'] as Map<String, dynamic>);
  await c.addGeoJsonSource('buildings', buildings);
  await c.addGeoJsonSource('signals', ground['signals'] as Map<String, dynamic>);
  await c.addGeoJsonSource('route-ground', {
    'type': 'Feature', 'properties': {},
    'geometry': {'type': 'MultiLineString', 'coordinates': route.groundParts()},
  });
  final ribbon = <Map<String, dynamic>>[];
  for (var i = 0; i < route.coords.length - 1; i++) {
    if (math.max(route.elev[i], route.elev[i + 1]) < 0.5) continue;
    final h = (route.elev[i] + route.elev[i + 1]) / 2;
    ribbon.add({
      'type': 'Feature', 'properties': {'b': math.max(h - 0.02, 0), 't': h + 0.22},
      'geometry': {'type': 'Polygon', 'coordinates': [_quad(route.coords[i], route.coords[i + 1], 2.6)]},
    });
  }
  await c.addGeoJsonSource('route-ribbon', {'type': 'FeatureCollection', 'features': ribbon});
  await c.addGeoJsonSource('puck', {'type': 'FeatureCollection', 'features': <dynamic>[]});

  await c.addFillLayer('areas', 'areas', const FillLayerProperties(fillColor: [
    'match', ['get', 'k'], 'pitch', MapPalette.pitch, 'paved', MapPalette.paved, 'bare', MapPalette.bare, 'water', MapPalette.water, MapPalette.green,
  ]));
  await c.addLineLayer('roads', 'road-casing', LineLayerProperties(
    lineColor: const ['match', ['get', 'c'], ['major', 'medium', 'link'], MapPalette.majorCasing, MapPalette.casing],
    lineWidth: metres(['+', _roadW, 1.6]), lineCap: 'round', lineJoin: 'round',
  ), filter: ['!=', ['get', 'c'], 'service']);
  await c.addLineLayer('roads', 'road', LineLayerProperties(
    lineColor: const ['match', ['get', 'c'], ['major', 'medium', 'link'], MapPalette.major, MapPalette.minor],
    lineWidth: metres(_roadW), lineCap: 'round', lineJoin: 'round',
  ), filter: ['!=', ['get', 'c'], 'service']);
  for (var k = 1; k <= 4; k++) {
    await c.addLineLayer('roads', 'lane-$k', LineLayerProperties(
      lineColor: MapPalette.lane, lineDasharray: const [3, 4], lineWidth: metres(0.25),
      lineOffset: metres(['*', ['-', k, ['/', ['get', 'l'], 2]], 3.4]),
    ), minzoom: 15.5, filter: ['all', ['==', ['get', 'ow'], 1], ['>', ['get', 'l'], k], ['in', ['get', 'c'], ['literal', ['major', 'medium']]]]);
  }
  await c.addLineLayer('route-ground', 'route-casing', LineLayerProperties(
      lineColor: MapPalette.routeCasing, lineWidth: metres(6.4), lineCap: 'round', lineJoin: 'round'));
  await c.addLineLayer('route-ground', 'route', LineLayerProperties(
      lineColor: MapPalette.route, lineWidth: metres(4.6), lineCap: 'round', lineJoin: 'round'));
  await c.addFillExtrusionLayer('pillars', 'pillars', const FillExtrusionLayerProperties(
      fillExtrusionColor: MapPalette.pillar, fillExtrusionHeight: ['get', 'h'], fillExtrusionBase: 0));
  await c.addFillExtrusionLayer('decks', 'decks', const FillExtrusionLayerProperties(
      fillExtrusionColor: MapPalette.deck, fillExtrusionHeight: ['get', 'h'], fillExtrusionBase: ['get', 'b'], fillExtrusionVerticalGradient: false));
  await c.addFillExtrusionLayer('route-ribbon', 'route-ribbon', const FillExtrusionLayerProperties(
      fillExtrusionColor: MapPalette.route, fillExtrusionHeight: ['get', 't'], fillExtrusionBase: ['get', 'b'], fillExtrusionVerticalGradient: false));
  await c.addFillExtrusionLayer('buildings', 'buildings', const FillExtrusionLayerProperties(
    fillExtrusionColor: [
      'case',
      ['==', ['get', 'com'], 1], ['interpolate', ['linear'], ['get', 'h'], 4, MapPalette.shopLo, 40, MapPalette.shopHi],
      ['interpolate', ['linear'], ['get', 'h'], 4, MapPalette.bldgLo, 40, MapPalette.bldgHi],
    ],
    fillExtrusionHeight: ['get', 'h'], fillExtrusionBase: 0, fillExtrusionOpacity: 0.9,
  ));
  // traffic lights mapped in OpenStreetMap (incomplete in Cairo; road capture will fill the gaps)
  await c.addCircleLayer('signals', 'signals', const CircleLayerProperties(
    circleColor: MapPalette.signal, circleRadius: ['interpolate', ['linear'], ['zoom'], 14, 2.5, 18, 7],
    circleStrokeColor: MapPalette.signalRing, circleStrokeWidth: 1.5, circlePitchAlignment: 'map',
  ), minzoom: 14);
  await c.addFillExtrusionLayer('puck', 'puck', const FillExtrusionLayerProperties(
      fillExtrusionColor: ['get', 'c'], fillExtrusionHeight: ['get', 't'], fillExtrusionBase: ['get', 'b'], fillExtrusionVerticalGradient: false));
}

/// Car marker: a white disc with a blue arrow, raised onto the flyover deck
/// when the detector says we are up there.
Map<String, dynamic> puckGeoJson(double lon, double lat, double heading, double height, {String color = MapPalette.route}) {
  final c = Geo.toXY(lon, lat);
  final t = heading * math.pi / 180;
  List<List<double>> ring(List<List<double>> pts) {
    final r = pts.map((p) => Geo.toLonLat(Vec(c.x + p[0] * math.cos(t) + p[1] * math.sin(t), c.y - p[0] * math.sin(t) + p[1] * math.cos(t)))).toList();
    r.add(r.first);
    return r;
  }

  final disc = List.generate(24, (k) => [math.cos(k / 24 * 2 * math.pi) * 8.5, math.sin(k / 24 * 2 * math.pi) * 8.5]);
  final base = height > 0.3 ? height + 0.25 : 0.05;
  return {
    'type': 'FeatureCollection',
    'features': [
      {'type': 'Feature', 'properties': {'b': base, 't': base + 0.35, 'c': MapPalette.ring}, 'geometry': {'type': 'Polygon', 'coordinates': [ring(disc)]}},
      {'type': 'Feature', 'properties': {'b': base + 0.35, 't': base + 1.6, 'c': color},
        'geometry': {'type': 'Polygon', 'coordinates': [ring([[0, 7.5], [5.2, -5.5], [0, -2.6], [-5.2, -5.5]])]}},
    ],
  };
}
