import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../capture/road_capture.dart';
import '../geo/geo.dart';
import '../map/city_tiles.dart';
import '../map/map_layers.dart';
import '../nav/car_smoother.dart';
import '../nav/level_detector.dart';
import '../nav/match_data.dart';
import '../nav/route_data.dart';
import '../nav/routing.dart';
import '../nav/search.dart';
import '../sensors/drive_source.dart';
import '../sensors/trip_logger.dart';
import 'search_screen.dart';

/// How the camera follows the car: zoom, tilt, and how far ahead of the car
/// the camera looks (metres; the car sits lower on screen the further ahead).
enum CamView {
  follow3d('3D', Icons.threed_rotation, 'Standard driving view', 17.2, 60, 0),
  chase('Close', Icons.directions_car, 'Game camera just behind the car', 18.4, 60, 0),
  street('Street', Icons.location_city, 'Very low and close: buildings tower over the car', 19.3, 60, 14),
  lookAhead('Look ahead', Icons.visibility_outlined, 'Car at the bottom, long view up the road', 17.5, 60, 110),
  heli('Helicopter', Icons.flight, 'High and wide, follows from above', 16.2, 42, 50),
  auto('Auto zoom', Icons.speed, 'Close when slow, wider and further ahead when fast', 18.6, 60, 0),
  overview('Overview', Icons.zoom_out_map, 'Flat, heading up, a few km around', 14.8, 0, 180),
  top('Top-down', Icons.map_outlined, 'Flat, north up', 16.3, 0, 0);

  const CamView(this.label, this.icon, this.hint, this.zoom, this.tilt, this.aheadM);
  final String label, hint;
  final IconData icon;
  final double zoom, tilt, aheadM;
}

/// Milestone 1 screen: 3D map, live or simulated position, the flyover level
/// indicator, search and routing, and a recorder for real test drives.
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with WidgetsBindingObserver {
  MapLibreMapController? _map;
  bool _styleReady = false;
  RouteData? _route; // the route being driven (demo route until the driver plans one)
  RouteData? _demoRoute;
  LevelDetector? _detector;
  DriveSource? _source;
  StreamSubscription<DriveSample>? _sub;
  final _logger = TripLogger();
  final _capture = RoadCapture();
  Timer? _captureTick;

  bool _live = false;
  bool _follow = true;
  LevelEstimate? _est;
  PositionSample? _lastPos;
  double? _lastPressure;
  String? _message;

  // smooth car: snapped to the road and moved 20 times a second
  final _smooth = CarSmoother();
  Timer? _frame;
  DateTime _lastFrame = DateTime.now();
  bool _frameBusy = false;

  // map display options
  static final _initialStyle = baseStyle();
  MapTheme _theme = MapTheme.night;
  CamView _view = CamView.follow3d;
  bool _showBuildings = true, _showSignals = true, _showSigns = true;
  bool _cameraPlaced = false;
  List<List<double>> _signalPts = const [];
  Timer? _signalTimer;
  int _tick = 0;
  Position? _me;

  // search and routing
  final _search = PlaceSearch();
  final _tiles = CityTiles();
  SignSet? _signs;
  bool _tilesBusy = false;

  // camera eased towards the chosen view, so switching views glides
  double _camZoom = 17.2, _camTilt = 60, _camAhead = 0;
  Place? _dest;
  RoutePrefs _prefs = const RoutePrefs();
  List<RouteOption>? _options; // shown while the driver picks a route
  List<RouteData>? _optionData;
  int _chosen = 0;
  bool _routing = false;
  RouteOption? _active; // the route being navigated
  double _progress = 0; // metres along _route
  int _progIdx = 0, _offRoute = 0;
  DateTime _lastReroute = DateTime(2000);

  MatchData get _match => _detector!.data;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _signalTimer = Timer.periodic(const Duration(seconds: 1), (_) => _animateSignals());
    _frame = Timer.periodic(const Duration(milliseconds: 50), (_) => _drawFrame());
    _load();
  }

  Future<void> _load() async {
    final route = RouteData.fromJson(jsonDecode(await rootBundle.loadString('assets/data/route.json')) as Map<String, dynamic>);
    final match = MatchData.fromJson(jsonDecode(await rootBundle.loadString('assets/data/match.json')) as Map<String, dynamic>);
    await _tiles.init();
    setState(() {
      _route = _demoRoute = route;
      _detector = LevelDetector(match);
    });
    await _useSource(live: false);
  }

  Future<void> _useSource({required bool live}) async {
    await _sub?.cancel();
    await _source?.stop();
    final detector = _route == null ? null : LevelDetector(_detector!.data);
    final source = live ? LiveSource() : SimulatedSource(_route!);
    _smooth.reset();
    setState(() {
      _live = live;
      _source = source;
      _detector = detector;
      _est = null;
      _message = null;
    });
    _sub = source.samples.listen(_onSample);
    await source.start();
    if (source is LiveSource && source.problem != null) setState(() => _message = source.problem);
  }

  void _onSample(DriveSample s) {
    final d = _detector;
    if (d == null) return;
    _logger.sample(s);
    switch (s) {
      case PressureSample b:
        d.addPressure(b.hPa, at: b.time);
        _lastPressure = b.hPa;
      case PositionSample p:
        final e = d.update(p.lon, p.lat, heading: p.heading, speed: p.speed, accuracy: p.accuracy);
        _logger.decision(p.time, e);
        _lastPos = p;
        final xy = Geo.toXY(p.lon, p.lat);
        final snap = CarSmoother.snapTarget(d.data, xy, p.accuracy, p.speed, p.heading, e.onFlyover);
        _smooth.addFix(xy, speed: p.speed, gpsHeading: p.heading, deckHeight: e.onFlyover ? (e.mapHeight ?? 0) : 0, snap: snap);
        _trackProgress(snap?.point ?? xy);
        setState(() => _est = e);
    }
  }

  /// Draws the car and moves the camera, 20 times a second.
  Future<void> _drawFrame() async {
    final c = _map;
    final now = DateTime.now();
    final dt = now.difference(_lastFrame).inMilliseconds / 1000.0;
    _lastFrame = now;
    if (c == null || !_styleReady || !_smooth.ready || _frameBusy) return;
    _frameBusy = true;
    try {
      _smooth.step(math.min(dt, 0.2));
      final ll = Geo.toLonLat(_smooth.pos!);
      await c.setGeoJsonSource('puck', puckGeoJson(ll[0], ll[1], _smooth.heading, _smooth.height, theme: _theme));
      if (_follow) {
        await c.moveCamera(CameraUpdate.newCameraPosition(_cameraAt(ll[1], ll[0], _smooth.heading, dt: math.min(dt, 0.2))));
        _updateTiles(ll[0], ll[1]);
      }
    } catch (_) {
      // style reloading
    } finally {
      _frameBusy = false;
    }
  }

  /// Camera for the chosen view. With [dt] the zoom, tilt and look-ahead ease
  /// towards the view (about half a second), otherwise they jump there.
  CameraPosition _cameraAt(double lat, double lon, double heading, {double? dt}) {
    final v = _view;
    var zoom = v.zoom, tilt = v.tilt, ahead = v.aheadM;
    if (v == CamView.auto) {
      // 0 km/h: close behind the car; 100+ km/h: two zoom levels wider, looking 3 s ahead
      final f = (((_lastPos?.speed ?? 0) * 3.6) / 100).clamp(0.0, 1.0);
      zoom -= 2.2 * f;
      tilt -= 12 * f;
      ahead = (_lastPos?.speed ?? 0) * 3;
    }
    if (dt == null) {
      _camZoom = zoom;
      _camTilt = tilt;
      _camAhead = ahead;
    } else {
      final k = 1 - math.exp(-dt * (v == CamView.auto ? 1.2 : 4));
      _camZoom += (zoom - _camZoom) * k;
      _camTilt += (tilt - _camTilt) * k;
      _camAhead += (ahead - _camAhead) * k;
    }
    final bearing = v == CamView.top ? 0.0 : heading;
    var target = [lon, lat];
    if (_camAhead.abs() > 0.5) {
      final r = bearing * math.pi / 180;
      target = Geo.toLonLat(Geo.toXY(lon, lat) + Vec(math.sin(r), math.cos(r)) * _camAhead);
    }
    return CameraPosition(target: LatLng(target[1], target[0]), zoom: _camZoom, tilt: _camTilt, bearing: bearing);
  }

  /// Swap in the buildings, small streets and parks around (lon, lat) when the
  /// car (or the map centre) has moved into another tile.
  Future<void> _updateTiles(double lon, double lat) async {
    final c = _map;
    if (c == null || !_styleReady || _tilesBusy || !_tiles.needsUpdate(lon, lat)) return;
    _tilesBusy = true;
    try {
      final t = await _tiles.around(lon, lat);
      await c.setGeoJsonSource('buildings', t['b']!);
      await c.setGeoJsonSource('roads-local', t['r']!);
      await c.setGeoJsonSource('areas', t['a']!);
      final box = _tiles.shownBox, signs = _signs;
      if (box != null && signs != null) await drawNamePlates(c, signs, box);
    } catch (_) {
      _tiles.reset(); // style was reloading; try again next frame
    } finally {
      _tilesBusy = false;
    }
  }

  Future<void> _onStyleLoaded() async {
    final c = _map, r = _route;
    if (r == null || c == null) return;
    final theme = _theme;
    _styleReady = false;
    try {
      _signalPts = await addCityLayers(c, r, theme: theme);
    } catch (_) {
      return; // the look was changed again while loading; the next load redraws
    }
    if (theme != _theme) return;
    _styleReady = true;
    _signs = null;
    _tiles.reset();
    final centre = _smooth.ready ? Geo.toLonLat(_smooth.pos!) : [r.sample(0).lon, r.sample(0).lat];
    await _updateTiles(centre[0], centre[1]);
    await _applyVisibility();
    await _showMe();
    if (_options != null) {
      await _previewChoice(fit: false);
    } else if (_active != null) {
      await showRoute(c, r, traffic: _active!.traffic);
    }
    if (!_cameraPlaced && !_smooth.ready) {
      // start the view at the beginning of the planned route (City Stars)
      final p0 = r.sample(0), p1 = r.sample(60);
      await c.moveCamera(CameraUpdate.newCameraPosition(CameraPosition(
          target: LatLng(p0.lat, p0.lon), zoom: 16.5, tilt: 55, bearing: p1.heading)));
    }
    _cameraPlaced = true;
    // road signs last: drawing the street-name plates takes a few seconds
    try {
      final signs = await addSignLayers(c, theme);
      if (theme != _theme) return;
      _signs = signs;
      final box = _tiles.shownBox;
      if (box != null) await drawNamePlates(c, signs, box);
      await _applyVisibility();
    } catch (_) {}
  }

  Future<void> _setTheme(MapTheme t) async {
    if (t == _theme) return;
    setState(() {
      _theme = t;
      if (t.arcade && _view == CamView.follow3d) _view = CamView.chase;
      if (!t.arcade && _view == CamView.chase) _view = CamView.follow3d;
    });
    _styleReady = false;
    await _map?.setStyle(baseStyle(t)); // reloads the style; _onStyleLoaded draws the new look
  }

  Future<void> _setView(CamView v) async {
    setState(() {
      _view = v;
      _follow = true;
    });
  }

  Future<void> _applyVisibility() async {
    final c = _map;
    if (c == null || !_styleReady) return;
    Future<void> vis(String id, bool on) async {
      try {
        await c.setLayerVisibility(id, on);
      } catch (_) {} // that layer is not part of this look
    }

    await vis('buildings', _showBuildings);
    for (final id in signalLayers) {
      await vis(id, _showSignals);
    }
    for (final id in signLayers) {
      await vis(id, _showSigns);
    }
  }

  /// Game look: step every traffic light through green, amber and red.
  Future<void> _animateSignals() async {
    final c = _map;
    if (c == null || !_styleReady || !_theme.arcade || _signalPts.isEmpty || !_showSignals) return;
    _tick++;
    try {
      await c.setGeoJsonSource('signal-pts', signalGlowGeoJson(_signalPts, _tick));
      await c.setGeoJsonSource('signal-3d', signals3dGeoJson(_signalPts, _tick));
    } catch (_) {}
  }

  Future<void> _showMe() async {
    final c = _map, p = _me;
    if (c == null || p == null || !_styleReady) return;
    await c.setGeoJsonSource('me', meGeoJson(p.longitude, p.latitude, p.accuracy, 17));
  }

  /// "Move to my location". With live GPS the car is you, so this follows the
  /// car again. In simulated mode it finds the phone's position, shows it as a
  /// blue dot and moves the map there.
  Future<void> _goToMe() async {
    if (_live) {
      setState(() => _follow = true);
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _message = 'Location is turned off. Turn it on in the phone settings.');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => _message = 'Location permission was refused. Allow it in the phone settings.');
      return;
    }
    setState(() => _message = 'Finding your location…');
    Position? p;
    try {
      p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)));
    } catch (_) {
      p = await Geolocator.getLastKnownPosition();
    }
    if (!mounted) return;
    if (p == null) {
      setState(() => _message = 'Could not get a GPS fix. Try again near a window or outside.');
      return;
    }
    final r = _demoRoute!;
    var w = 180.0, e = -180.0, s = 90.0, n = -90.0;
    for (final c in r.coords) {
      w = math.min(w, c[0]);
      e = math.max(e, c[0]);
      s = math.min(s, c[1]);
      n = math.max(n, c[1]);
    }
    const pad = 0.03; // about 3 km: main roads are mapped well beyond the route
    final inside = p.longitude > w - pad && p.longitude < e + pad && p.latitude > s - pad && p.latitude < n + pad;
    setState(() {
      _me = p;
      _follow = false; // keep the simulated car from pulling the map back
      _message = inside ? null : 'You are outside the mapped area (Nasr City to New Cairo), so the 3D map around you is empty.';
    });
    await _showMe();
    final bearing = _map?.cameraPosition?.bearing ?? 0;
    await _map?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(p.latitude, p.longitude), zoom: 17, tilt: 50, bearing: bearing)),
        duration: const Duration(milliseconds: 900));
  }

  // ------------------------------------------------------------ search and routing

  /// Where a new route starts: the car (real or simulated), else the phone, else the demo start.
  List<double> _origin() {
    if (_smooth.ready) return Geo.toLonLat(_smooth.pos!);
    if (_me != null) return [_me!.longitude, _me!.latitude];
    final p = _route!.sample(0);
    return [p.lon, p.lat];
  }

  Future<void> _openSearch() async {
    final o = _origin();
    final place = await Navigator.of(context).push<Place>(
        MaterialPageRoute(builder: (_) => SearchScreen(search: _search, lon: o[0], lat: o[1])));
    if (place != null) await _planTo(place);
  }

  Future<void> _planTo(Place place, {bool silentReroute = false}) async {
    setState(() {
      _dest = place;
      _routing = true;
      if (!silentReroute) _message = null;
    });
    try {
      final opts = await fetchRoutes(_origin(), [place.lon, place.lat], _prefs);
      if (!mounted) return;
      final data = [for (final o in opts) o.toRouteData(_match)];
      if (silentReroute) {
        setState(() => _routing = false);
        await _start(opts.first, data.first, rerouted: true);
        return;
      }
      setState(() {
        _options = opts;
        _optionData = data;
        _chosen = 0;
        _routing = false;
        _follow = false;
      });
      await _previewChoice();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _routing = false;
        _message = 'Could not get a route: $e';
      });
    }
  }

  Future<void> _previewChoice({bool fit = true}) async {
    final c = _map, opts = _options, data = _optionData;
    if (c == null || opts == null || data == null || !_styleReady) return;
    await showRoute(c, data[_chosen],
        traffic: opts[_chosen].traffic, alternatives: [for (var i = 0; i < opts.length; i++) if (i != _chosen) opts[i].coords]);
    if (!fit) return;
    var w = 180.0, e = -180.0, s = 90.0, n = -90.0;
    for (final o in opts) {
      for (final p in o.coords) {
        w = math.min(w, p[0]);
        e = math.max(e, p[0]);
        s = math.min(s, p[1]);
        n = math.max(n, p[1]);
      }
    }
    await c.animateCamera(
        CameraUpdate.newLatLngBounds(LatLngBounds(southwest: LatLng(s, w), northeast: LatLng(n, e)), left: 40, top: 160, right: 40, bottom: 360),
        duration: const Duration(milliseconds: 900));
  }

  Future<void> _start(RouteOption opt, RouteData data, {bool rerouted = false}) async {
    setState(() {
      _active = opt;
      _route = data;
      _options = null;
      _optionData = null;
      _progress = 0;
      _progIdx = 0;
      _offRoute = 0;
      _follow = true;
      if (rerouted) _message = 'New route: ${_fmtMin(opt.duration)}, ${(opt.distance / 1000).toStringAsFixed(1)} km';
    });
    if (_map != null && _styleReady) await showRoute(_map!, data, traffic: opt.traffic);
    if (!_live) await _useSource(live: false); // the simulator now drives the new route
  }

  Future<void> _endRoute() async {
    setState(() {
      _active = null;
      _options = null;
      _optionData = null;
      _dest = null;
      _route = _demoRoute;
      _follow = true;
    });
    if (_map != null && _styleReady) await showRoute(_map!, _demoRoute!);
    if (!_live) await _useSource(live: false);
  }

  /// Progress along the active route, arrival, and re-routing when off it.
  void _trackProgress(Vec p) {
    final r = _route, opt = _active;
    if (r == null || opt == null) return;
    var best = double.infinity, bi = _progIdx;
    final from = math.max(0, _progIdx - 30), to = math.min(r.coords.length - 1, _progIdx + 400);
    for (var i = from; i <= to; i++) {
      final d = (Geo.toXY(r.coords[i][0], r.coords[i][1]) - p).length;
      if (d < best) {
        best = d;
        bi = i;
      }
    }
    _progIdx = bi;
    _progress = r.cum[bi];
    if (r.distance - _progress < 30 && best < 40) {
      setState(() => _message = 'You have arrived at ${_dest?.name ?? 'your destination'}.');
      _active = null;
      return;
    }
    _offRoute = best > 60 ? _offRoute + 1 : 0;
    if (_offRoute >= 5 && _dest != null && DateTime.now().difference(_lastReroute).inSeconds > 20) {
      _lastReroute = DateTime.now();
      _offRoute = 0;
      _planTo(_dest!, silentReroute: true);
    }
  }

  static String _fmtMin(double s) {
    final m = (s / 60).round();
    return m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min';
  }

  /// Test tools: data source, sensor log, road capture and live sensor readings.
  void _openTools() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF17202A),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ToolsSheet(host: this),
    );
  }

  void _openOptions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF17202A),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => _OptionsSheet(
          theme: _theme,
          view: _view,
          buildings: _showBuildings,
          signals: _showSignals,
          signs: _showSigns,
          onTheme: (t) {
            _setTheme(t);
            setSheet(() {});
          },
          onView: (v) {
            _setView(v);
            setSheet(() {});
          },
          onBuildings: (on) {
            setState(() => _showBuildings = on);
            setSheet(() {});
            _applyVisibility();
          },
          onSignals: (on) {
            setState(() => _showSignals = on);
            setSheet(() {});
            _applyVisibility();
          },
          onSigns: (on) {
            setState(() => _showSigns = on);
            setSheet(() {});
            _applyVisibility();
          },
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phones do not allow the camera in the background: save the clip and stop.
    if (state == AppLifecycleState.paused && _capture.active) _toggleCapture();
  }

  /// Road capture: video from the back camera plus the sensor log, both in one
  /// folder per drive. Internal test use only (see README).
  Future<void> _toggleCapture() async {
    if (_capture.active) {
      _captureTick?.cancel();
      await _capture.stop();
      await _logger.stop();
      final mb = (_capture.bytes / 1e6).toStringAsFixed(0);
      setState(() => _message = _capture.error ??
          'Saved ${_capture.clips} video clips ($mb MB) and the sensor log to ${_capture.lastFolder?.path}');
      return;
    }
    final dir = await _capture.start();
    if (dir == null) {
      setState(() => _message = _capture.error ?? 'Could not start the camera.');
      return;
    }
    if (_logger.recording) await _logger.stop();
    await _logger.start('${_source?.label ?? ''} + road capture', dir: dir);
    _captureTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() => _message = 'Road capture on. Mount the phone facing the road, camera clear of the wipers.');
  }

  Future<void> _toggleRecording() async {
    if (_capture.active) return; // the sensor log belongs to the capture until it stops
    if (_logger.recording) {
      await _logger.stop();
      setState(() => _message = 'Saved ${_logger.rows} rows to ${_logger.file?.path}');
    } else {
      await _logger.start(_source?.label ?? '');
      setState(() => _message = 'Recording to ${_logger.file?.path}');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _captureTick?.cancel();
    _signalTimer?.cancel();
    _frame?.cancel();
    _capture.dispose();
    _sub?.cancel();
    _source?.stop();
    _logger.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speedKmh = (_lastPos?.speed ?? 0) * 3.6;
    final opt = _active;
    Maneuver? next;
    if (opt != null) {
      for (final m in opt.maneuvers) {
        if (m.offset > _progress + 5) {
          next = m;
          break;
        }
      }
    }
    return Scaffold(
      backgroundColor: Color(MapPalette.of(_theme).ui),
      body: Stack(children: [
        // any touch on the map stops the camera following, so the map can be moved freely
        Listener(
          onPointerDown: (_) {
            if (_follow) setState(() => _follow = false);
          },
          child: MapLibreMap(
            styleString: _initialStyle,
            initialCameraPosition: const CameraPosition(target: LatLng(30.0725, 31.3460), zoom: 16.5, tilt: 55, bearing: 180),
            compassEnabled: false,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: true,
            onMapCreated: (c) => _map = c,
            onStyleLoadedCallback: _onStyleLoaded,
            trackCameraPosition: true,
            onCameraIdle: () {
              // map moved by hand: load the tiles around the middle of the screen
              final cam = _map?.cameraPosition;
              if (!_follow && cam != null) _updateTiles(cam.target.longitude, cam.target.latitude);
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              if (opt != null) ...[
                _TurnBanner(next: next, toNext: next == null ? _route!.distance - _progress : next.offset - _progress),
                const SizedBox(height: 6),
              ],
              _LevelPill(est: _est),
              const Spacer(),
              if (_options == null) _MapButtons(onMe: _goToMe, onOptions: _openOptions, onTools: _openTools, theme: _theme),
              if (_capture.camera != null) _CapturePreview(capture: _capture),
              if (_message != null) _Note(text: _message!, onClose: () => setState(() => _message = null)),
              if (_options != null)
                _RouteChooser(
                  dest: _dest!,
                  options: _options!,
                  chosen: _chosen,
                  prefs: _prefs,
                  busy: _routing,
                  onChoose: (i) {
                    setState(() => _chosen = i);
                    _previewChoice(fit: false);
                  },
                  onPrefs: (p) {
                    setState(() => _prefs = p);
                    _planTo(_dest!);
                  },
                  onCancel: () async {
                    setState(() {
                      _options = null;
                      _optionData = null;
                      _follow = true;
                    });
                    if (_map != null && _styleReady) await showRoute(_map!, _route!, traffic: _active?.traffic ?? const []);
                  },
                  onGo: () => _start(_options![_chosen], _optionData![_chosen]),
                )
              else
                _DriveBar(
                  speedKmh: speedKmh,
                  follow: _follow,
                  routing: _routing,
                  recording: _logger.recording || _capture.active,
                  remaining: opt == null ? null : _route!.distance - _progress,
                  eta: opt == null ? null : opt.duration * ((_route!.distance - _progress) / _route!.distance).clamp(0, 1),
                  trafficDelay: opt?.trafficDelay,
                  onSearch: _openSearch,
                  onEnd: _endRoute,
                  onFollow: () => setState(() => _follow = true),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Next turn and the distance to it (time and distance left are in the bottom bar).
class _TurnBanner extends StatelessWidget {
  const _TurnBanner({required this.next, required this.toNext});
  final Maneuver? next;
  final double toNext;

  static IconData icon(String kind) => switch (kind) {
        'left' => Icons.turn_left,
        'right' => Icons.turn_right,
        'slight_left' => Icons.turn_slight_left,
        'slight_right' => Icons.turn_slight_right,
        'sharp_left' => Icons.turn_sharp_left,
        'sharp_right' => Icons.turn_sharp_right,
        'uturn' => Icons.u_turn_left,
        'roundabout' => Icons.roundabout_right,
        'ramp' => Icons.ramp_right,
        'merge' => Icons.merge,
        'arrive' => Icons.flag,
        _ => Icons.straight,
      };

  static String dist(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${(m / 10).round() * 10} m';

  @override
  Widget build(BuildContext context) {
    final n = next;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
      decoration: BoxDecoration(color: const Color(0xF00F6B3A), borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(icon(n?.kind ?? 'arrive'), color: Colors.white, size: 36),
        const SizedBox(width: 10),
        Text(dist(math.max(0, toNext)), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(n?.text ?? 'Destination', maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.2)),
        ),
      ]),
    );
  }
}

/// Route choices for a destination: options, fastest/shortest, avoid highways.
class _RouteChooser extends StatelessWidget {
  const _RouteChooser({
    required this.dest,
    required this.options,
    required this.chosen,
    required this.prefs,
    required this.busy,
    required this.onChoose,
    required this.onPrefs,
    required this.onCancel,
    required this.onGo,
  });
  final Place dest;
  final List<RouteOption> options;
  final int chosen;
  final RoutePrefs prefs;
  final bool busy;
  final ValueChanged<int> onChoose;
  final ValueChanged<RoutePrefs> onPrefs;
  final VoidCallback onCancel, onGo;

  @override
  Widget build(BuildContext context) {
    final fastest = options.map((o) => o.duration).reduce(math.min);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF17202A), borderRadius: BorderRadius.circular(18)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.flag_outlined, color: Colors.white70, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(dest.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700))),
          if (busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          ChoiceChip(label: const Text('Fastest'), selected: !prefs.shortest, onSelected: (_) => onPrefs(prefs.copyWith(shortest: false))),
          ChoiceChip(label: const Text('Shortest'), selected: prefs.shortest, onSelected: (_) => onPrefs(prefs.copyWith(shortest: true))),
          FilterChip(label: const Text('Avoid highways'), selected: prefs.avoidHighways, onSelected: (v) => onPrefs(prefs.copyWith(avoidHighways: v))),
        ]),
        const SizedBox(height: 6),
        for (var i = 0; i < options.length; i++)
          InkWell(
            onTap: () => onChoose(i),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: i == chosen ? const Color(0xFF223A63) : const Color(0xFF1E2833),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: i == chosen ? const Color(0xFF5C8CFF) : Colors.transparent, width: 1.5),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(options[i].label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    Text(
                      options[i].trafficDelay == null
                          ? 'No live traffic data'
                          : options[i].trafficDelay! < 60
                              ? 'Traffic is light'
                              : '+${(options[i].trafficDelay! / 60).round()} min because of traffic',
                      style: TextStyle(color: (options[i].trafficDelay ?? 0) >= 300 ? const Color(0xFFFF8A65) : Colors.white54, fontSize: 12),
                    ),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(_DriveScreenState._fmtMin(options[i].duration),
                      style: TextStyle(
                          color: options[i].duration == fastest ? const Color(0xFF7CE38B) : Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                  Text('${(options[i].distance / 1000).toStringAsFixed(1)} km', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ]),
            ),
          ),
        const SizedBox(height: 4),
        Text(options[chosen].source, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 8),
        Row(children: [
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
          const Spacer(),
          FilledButton.icon(onPressed: busy ? null : onGo, icon: const Icon(Icons.navigation), label: const Text('Start')),
        ]),
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.onClose});
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        decoration: BoxDecoration(color: const Color(0xFF1F2A36), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13))),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close, color: Colors.white60, size: 18)),
        ]),
      );
}

/// Small live camera view with a REC badge, clip count and size.
class _CapturePreview extends StatelessWidget {
  const _CapturePreview({required this.capture});
  final RoadCapture capture;

  @override
  Widget build(BuildContext context) {
    final c = capture.camera!;
    final t = capture.elapsed;
    final mm = t.inMinutes.toString().padLeft(2, '0'), ss = (t.inSeconds % 60).toString().padLeft(2, '0');
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 132,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF17202A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFD7262E), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (c.value.isInitialized) CameraPreview(c),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(children: [
              const Icon(Icons.fiber_manual_record, color: Color(0xFFFF4D55), size: 12),
              const SizedBox(width: 4),
              Text('$mm:$ss', style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
              const Spacer(),
              Text('${capture.clips} · ${(capture.bytes / 1e6).toStringAsFixed(0)} MB',
                  style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Bottom sheet: map look, camera and which layers to show.
class _OptionsSheet extends StatelessWidget {
  const _OptionsSheet({
    required this.theme,
    required this.view,
    required this.buildings,
    required this.signals,
    required this.signs,
    required this.onTheme,
    required this.onView,
    required this.onBuildings,
    required this.onSignals,
    required this.onSigns,
  });
  final MapTheme theme;
  final CamView view;
  final bool buildings, signals, signs;
  final ValueChanged<MapTheme> onTheme;
  final ValueChanged<CamView> onView;
  final ValueChanged<bool> onBuildings, onSignals, onSigns;

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 0.8, fontWeight: FontWeight.w600);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('MAP LOOK', style: head),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final t in MapTheme.values)
              ChoiceChip(
                avatar: Icon(_themeIcon(t), size: 18),
                label: Text(t.label),
                selected: t == theme,
                onSelected: (_) => onTheme(t),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_themeHint(theme), style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          const SizedBox(height: 18),
          const Text('CAMERA', style: head),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final v in CamView.values)
              ChoiceChip(avatar: Icon(v.icon, size: 18), label: Text(v.label), selected: v == view, onSelected: (_) => onView(v)),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(view.hint, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: buildings,
            onChanged: onBuildings,
            title: const Text('3D buildings', style: TextStyle(color: Colors.white)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: signals,
            onChanged: onSignals,
            title: const Text('Traffic lights', style: TextStyle(color: Colors.white)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: signs,
            onChanged: onSigns,
            title: const Text('Road signs and street names', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Speed limits, speed cameras, crossings, street-name plates',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
        ]),
      ),
    );
  }
}

/// One-line status at the top: ground or flyover, and the road name.
class _LevelPill extends StatelessWidget {
  const _LevelPill({required this.est});
  final LevelEstimate? est;

  @override
  Widget build(BuildContext context) {
    final e = est;
    final up = e?.onFlyover ?? false;
    final color = up ? const Color(0xFFF2B233) : const Color(0xFF8FB0FF);
    final level = e == null
        ? 'Waiting for GPS…'
        : switch (e.level) {
            RoadLevel.upper => 'ON FLYOVER',
            RoadLevel.ramp => 'RAMP',
            RoadLevel.ground => 'GROUND',
          };
    final road = e?.roadName ?? '';
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
        decoration: BoxDecoration(
          color: up ? const Color(0xE63A2E12) : const Color(0xD9101820),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(up ? Icons.alt_route : Icons.straight, color: color, size: 16),
          const SizedBox(width: 6),
          Text(level, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.6)),
          if (road.isNotEmpty) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(road, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Bottom bar for driving: speed, then either "Where to?" or the time and
/// distance left on the route, and re-centre when the map was moved.
class _DriveBar extends StatelessWidget {
  const _DriveBar({
    required this.speedKmh,
    required this.follow,
    required this.routing,
    required this.recording,
    required this.remaining,
    required this.eta,
    required this.trafficDelay,
    required this.onSearch,
    required this.onEnd,
    required this.onFollow,
  });
  final double speedKmh;
  final bool follow, routing, recording;
  final double? remaining, eta, trafficDelay;
  final VoidCallback onSearch, onEnd, onFollow;

  @override
  Widget build(BuildContext context) {
    final navigating = remaining != null;
    Widget middle;
    if (navigating) {
      final mins = (eta! / 60).round();
      final arrive = DateTime.now().add(Duration(seconds: eta!.round()));
      final hhmm = '${arrive.hour.toString().padLeft(2, '0')}:${arrive.minute.toString().padLeft(2, '0')}';
      final delay = trafficDelay == null ? null : trafficDelay! < 60 ? 'light traffic' : '+${(trafficDelay! / 60).round()} min traffic';
      middle = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(mins < 60 ? '$mins min' : '${mins ~/ 60} h ${mins % 60} min',
            style: const TextStyle(color: Color(0xFF7CE38B), fontSize: 20, fontWeight: FontWeight.w800)),
        Text('${_TurnBanner.dist(remaining!)} · arrive $hhmm${delay == null ? '' : ' · $delay'}',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ]);
    } else {
      middle = InkWell(
        onTap: routing ? null : onSearch,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: const Color(0xFF243140), borderRadius: BorderRadius.circular(24)),
          child: Row(children: [
            routing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                : const Icon(Icons.search, color: Colors.white70, size: 20),
            const SizedBox(width: 10),
            Text(routing ? 'Finding routes…' : 'Where to?', style: const TextStyle(color: Colors.white70, fontSize: 16)),
          ]),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xF217202A),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: Row(children: [
        // speed
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF0E141B),
            border: Border.all(color: recording ? const Color(0xFFD7262E) : const Color(0xFF3A4656), width: 2.5),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(speedKmh.round().toString(),
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, height: 1.0, fontFeatures: [FontFeature.tabularFigures()])),
            const Text('km/h', style: TextStyle(color: Colors.white54, fontSize: 9)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(child: middle),
        if (!follow) ...[
          const SizedBox(width: 6),
          IconButton.filledTonal(onPressed: onFollow, icon: const Icon(Icons.navigation), tooltip: 'Follow car'),
        ],
        if (navigating) ...[
          const SizedBox(width: 6),
          IconButton.filled(
            onPressed: onEnd,
            tooltip: 'End route',
            style: IconButton.styleFrom(backgroundColor: const Color(0xFF8B1E24)),
            icon: const Icon(Icons.close),
          ),
        ],
      ]),
    );
  }
}

/// Round buttons on the right edge: map options, test tools, my location.
class _MapButtons extends StatelessWidget {
  const _MapButtons({required this.onMe, required this.onOptions, required this.onTools, required this.theme});
  final VoidCallback onMe, onOptions, onTools;
  final MapTheme theme;

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      backgroundColor: const Color(0xE617202A),
      foregroundColor: Colors.white,
      fixedSize: const Size(46, 46),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            onPressed: onOptions,
            style: style,
            tooltip: 'Map options',
            icon: Icon(theme.arcade ? Icons.sports_esports : Icons.layers_outlined),
          ),
          const SizedBox(height: 8),
          IconButton(onPressed: onTools, style: style, tooltip: 'Test tools', icon: const Icon(Icons.science_outlined)),
          const SizedBox(height: 8),
          IconButton(onPressed: onMe, style: style, tooltip: 'Move to my location', icon: const Icon(Icons.my_location)),
        ]),
      ),
    );
  }
}

/// Test tools: simulated or live position, sensor log, road capture, and the
/// detector's live readings (what the old bottom bar and level card showed).
class _ToolsSheet extends StatefulWidget {
  const _ToolsSheet({required this.host});
  final _DriveScreenState host;

  @override
  State<_ToolsSheet> createState() => _ToolsSheetState();
}

class _ToolsSheetState extends State<_ToolsSheet> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    await f();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    final e = h._est;
    const head = TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 0.8, fontWeight: FontWeight.w600);
    const label = TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 0.6);
    const value = TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);
    Widget stat(String v, String l) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(v, style: value), Text(l, style: label)]);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('POSITION', style: head),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Simulated'), icon: Icon(Icons.play_circle_outline)),
                ButtonSegment(value: true, label: Text('Live GPS'), icon: Icon(Icons.gps_fixed)),
              ],
              selected: {h._live},
              onSelectionChanged: (s) => _run(() => h._useSource(live: s.first)),
            ),
          ),
          const SizedBox(height: 16),
          const Text('RECORD', style: head),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: h._capture.active ? null : () => _run(h._toggleRecording),
                style: FilledButton.styleFrom(backgroundColor: h._logger.recording ? const Color(0xFFD7262E) : const Color(0xFF2E5BFF)),
                icon: Icon(h._logger.recording ? Icons.stop : Icons.fiber_manual_record),
                label: Text(h._logger.recording ? 'Stop sensor log' : 'Sensor log'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _run(h._toggleCapture),
                style: FilledButton.styleFrom(backgroundColor: h._capture.active ? const Color(0xFFD7262E) : const Color(0xFF3A4656)),
                icon: Icon(h._capture.active ? Icons.videocam_off : Icons.videocam),
                label: Text(h._capture.active ? 'Stop capture' : 'Road capture'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('SENSORS AND DETECTOR', style: head),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: stat(h._lastPos == null ? '—' : '±${h._lastPos!.accuracy.round()} m', 'GPS')),
            Expanded(child: stat(h._lastPressure == null ? 'none' : h._lastPressure!.toStringAsFixed(2), 'HPA')),
            Expanded(child: stat(e?.baroHeight == null ? '—' : '${e!.baroHeight!.toStringAsFixed(1)} m', 'BARO HEIGHT')),
            Expanded(child: stat(e == null ? '—' : '${(e.confidence * 100).round()}%', 'CONFIDENCE')),
          ]),
          const SizedBox(height: 8),
          Text(
            e == null ? 'Waiting for position' : '${e.reason}${(h._detector?.hasBaseline ?? false) ? '' : ' · learning ground pressure'}',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ]),
      ),
    );
  }
}

IconData _themeIcon(MapTheme t) => switch (t) {
      MapTheme.night => Icons.dark_mode_outlined,
      MapTheme.day => Icons.light_mode_outlined,
      MapTheme.game => Icons.sports_esports_outlined,
      MapTheme.neon => Icons.blur_on,
      MapTheme.toy => Icons.toys_outlined,
    };

String _themeHint(MapTheme t) => switch (t) {
      MapTheme.night => 'Dark, calm colours for driving at night.',
      MapTheme.day => 'Light map for daytime.',
      MapTheme.game => 'Bright city, 3D car and working 3D traffic lights.',
      MapTheme.neon => 'Dark city with glowing road edges and a neon route; 3D car and lights.',
      MapTheme.toy => 'Soft toy-town colours, pastel buildings; 3D car and lights.',
    };
