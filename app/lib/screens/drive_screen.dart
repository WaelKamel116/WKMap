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

/// How the camera follows the car.
enum CamView {
  follow3d('3D', Icons.threed_rotation),
  chase('Close', Icons.directions_car),
  inside('Inside', Icons.airline_seat_recline_normal),
  top('Top-down', Icons.map_outlined);

  const CamView(this.label, this.icon);
  final String label;
  final IconData icon;
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
  bool _frameBusy = false, _puckHidden = false;

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
      if (_view == CamView.inside) {
        if (!_puckHidden) await c.setGeoJsonSource('puck', puckGeoJson(0, 0, 0, 0, theme: _theme, hidden: true));
        _puckHidden = true;
      } else {
        _puckHidden = false;
        await c.setGeoJsonSource('puck', puckGeoJson(ll[0], ll[1], _smooth.heading, _smooth.height, theme: _theme));
      }
      if (_follow) await c.moveCamera(CameraUpdate.newCameraPosition(_cameraAt(ll[1], ll[0], _smooth.heading)));
    } catch (_) {
      // style reloading
    } finally {
      _frameBusy = false;
    }
  }

  CameraPosition _cameraAt(double lat, double lon, double heading) {
    switch (_view) {
      case CamView.follow3d:
        return CameraPosition(target: LatLng(lat, lon), zoom: 17.2, tilt: 60, bearing: heading);
      case CamView.chase:
        return CameraPosition(target: LatLng(lat, lon), zoom: 18.4, tilt: 60, bearing: heading);
      case CamView.inside:
        // driver's seat: look down the road from just above the car (the car itself is hidden)
        final r = heading * math.pi / 180;
        final ahead = Geo.toLonLat(Geo.toXY(lon, lat) + Vec(math.sin(r), math.cos(r)) * 22);
        return CameraPosition(target: LatLng(ahead[1], ahead[0]), zoom: 19.6, tilt: 60, bearing: heading);
      case CamView.top:
        return CameraPosition(target: LatLng(lat, lon), zoom: 16.3, tilt: 0, bearing: 0);
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
    _puckHidden = false;
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
  }

  Future<void> _setTheme(MapTheme t) async {
    if (t == _theme) return;
    setState(() {
      _theme = t;
      if (t == MapTheme.game && _view == CamView.follow3d) _view = CamView.chase;
      if (t != MapTheme.game && _view == CamView.chase) _view = CamView.follow3d;
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
    if (c == null || !_styleReady || _theme != MapTheme.game || _signalPts.isEmpty || !_showSignals) return;
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
          ),
        ),
        if (_view == CamView.inside && _follow)
          Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _CockpitPainter(game: _theme == MapTheme.game, speedKmh: speedKmh)))),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              if (opt != null)
                _TurnBanner(
                  next: next,
                  toNext: next == null ? _route!.distance - _progress : next.offset - _progress,
                  remaining: _route!.distance - _progress,
                  eta: opt.duration * ((_route!.distance - _progress) / _route!.distance).clamp(0, 1),
                  trafficDelay: opt.trafficDelay,
                  onEnd: _endRoute,
                ),
              if (opt != null) const SizedBox(height: 8),
              _LevelCard(est: _est, hasBaseline: _detector?.hasBaseline ?? false, compact: opt != null),
              const Spacer(),
              if (_options == null) _MapButtons(onMe: _goToMe, onOptions: _openOptions, onSearch: _openSearch, theme: _theme, routing: _routing),
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
                _BottomBar(
                  live: _live,
                  recording: _logger.recording,
                  follow: _follow,
                  speedKmh: speedKmh,
                  accuracy: _lastPos?.accuracy,
                  pressure: _lastPressure,
                  onSource: (live) => _useSource(live: live),
                  onRecord: _toggleRecording,
                  capturing: _capture.active,
                  onCapture: _toggleCapture,
                  onFollow: () => setState(() => _follow = true),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Next turn, distance to it, and time and distance left.
class _TurnBanner extends StatelessWidget {
  const _TurnBanner({required this.next, required this.toNext, required this.remaining, required this.eta, this.trafficDelay, required this.onEnd});
  final Maneuver? next;
  final double toNext, remaining, eta;
  final double? trafficDelay;
  final VoidCallback onEnd;

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
    final mins = (eta / 60).round();
    final delay = trafficDelay == null ? 'no live traffic' : trafficDelay! < 60 ? 'traffic is light' : '+${(trafficDelay! / 60).round()} min traffic';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(color: const Color(0xFF0F6B3A), borderRadius: BorderRadius.circular(18)),
      child: Row(children: [
        Icon(icon(n?.kind ?? 'arrive'), color: Colors.white, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(dist(math.max(0, toNext)), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
            Text(n?.text ?? 'Destination', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 2),
            Text('${mins < 60 ? '$mins min' : '${mins ~/ 60} h ${mins % 60} min'} · ${dist(remaining)} left · $delay',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        ),
        IconButton(onPressed: onEnd, tooltip: 'End route', icon: const Icon(Icons.close, color: Colors.white70)),
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

/// Inside-the-car frame over the map: roof edge, windscreen pillars, dashboard
/// with a speed read-out and the top of the steering wheel.
class _CockpitPainter extends CustomPainter {
  _CockpitPainter({required this.game, required this.speedKmh});
  final bool game;
  final double speedKmh;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = Paint()..color = game ? const Color(0xFF2A1F3D) : const Color(0xFF0B0F14);
    final trim = Paint()..color = game ? const Color(0xFFFF3DA8) : const Color(0xFF2B3542);
    // roof edge and pillars
    canvas.drawPath(Path()..moveTo(0, 0)..lineTo(w, 0)..lineTo(w, h * 0.06)..quadraticBezierTo(w / 2, h * 0.11, 0, h * 0.06)..close(), body);
    canvas.drawPath(Path()..moveTo(0, 0)..lineTo(w * 0.09, 0)..lineTo(w * 0.02, h * 0.62)..lineTo(0, h * 0.64)..close(), body);
    canvas.drawPath(Path()..moveTo(w, 0)..lineTo(w * 0.91, 0)..lineTo(w * 0.98, h * 0.62)..lineTo(w, h * 0.64)..close(), body);
    // dashboard
    final dashTop = h * 0.60;
    final dash = Path()
      ..moveTo(0, dashTop + 30)
      ..quadraticBezierTo(w * 0.5, dashTop - 34, w, dashTop + 30)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(dash, body);
    canvas.drawPath(
        Path()
          ..moveTo(0, dashTop + 30)
          ..quadraticBezierTo(w * 0.5, dashTop - 34, w, dashTop + 30),
        trim
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    // top of the steering wheel
    final wheel = Paint()
      ..color = game ? const Color(0xFF15101F) : const Color(0xFF05070A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22;
    canvas.drawArc(Rect.fromCircle(center: Offset(w * 0.5, dashTop + w * 0.42), radius: w * 0.36), math.pi * 1.12, math.pi * 0.76, false, wheel);
    // speed on the dash
    final tp = TextPainter(
      text: TextSpan(children: [
        TextSpan(text: speedKmh.round().toString(), style: TextStyle(color: game ? const Color(0xFF6CD4FF) : Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
        const TextSpan(text: ' km/h', style: TextStyle(color: Colors.white60, fontSize: 13)),
      ]),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(w * 0.5 - tp.width / 2, dashTop + 6));
  }

  @override
  bool shouldRepaint(_CockpitPainter old) => old.game != game || old.speedKmh.round() != speedKmh.round();
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.est, required this.hasBaseline, this.compact = false});
  final LevelEstimate? est;
  final bool hasBaseline, compact;

  @override
  Widget build(BuildContext context) {
    final e = est;
    final up = e?.onFlyover ?? false;
    final color = up ? const Color(0xFFF2B233) : const Color(0xFF6E97FF);
    final title = e == null
        ? 'Waiting for position…'
        : switch (e.level) {
            RoadLevel.upper => 'UPPER LEVEL · ON FLYOVER',
            RoadLevel.ramp => 'ON FLYOVER RAMP',
            RoadLevel.ground => 'GROUND LEVEL',
          };
    if (compact) {
      // one line under the turn banner while navigating
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: up ? const Color(0xFF3A2E12) : const Color(0xE613263D),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.6), width: 1.2),
        ),
        child: Row(children: [
          Icon(up ? Icons.alt_route : Icons.straight, color: color, size: 18),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.6)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(e?.roadName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13))),
        ]),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: up ? const Color(0xFF3A2E12) : const Color(0xFF13263D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(up ? Icons.alt_route : Icons.straight, color: color, size: 22),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w700, letterSpacing: 0.8, fontSize: 13))),
          if (e != null) Text('${(e.confidence * 100).round()}%', style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        const SizedBox(height: 4),
        Text(e?.roadName.isNotEmpty == true ? e!.roadName : '—',
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 6),
        Text(
          e == null
              ? ''
              : '${e.reason}'
                  '${e.baroHeight != null ? ' · baro ${e.baroHeight!.toStringAsFixed(1)} m' : hasBaseline ? '' : ' · learning ground pressure'}',
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
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

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.live,
    required this.recording,
    required this.follow,
    required this.speedKmh,
    required this.accuracy,
    required this.pressure,
    required this.onSource,
    required this.onRecord,
    required this.onFollow,
    required this.capturing,
    required this.onCapture,
  });
  final bool live, recording, follow, capturing;
  final double speedKmh;
  final double? accuracy, pressure;
  final ValueChanged<bool> onSource;
  final VoidCallback onRecord, onFollow, onCapture;

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 0.6);
    const value = TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF17202A), borderRadius: BorderRadius.circular(18)),
      child: Column(children: [
        Row(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(speedKmh.round().toString(), style: value), const Text('KM/H', style: label)]),
          const SizedBox(width: 18),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(accuracy == null ? '—' : '±${accuracy!.round()} m', style: value), const Text('GPS', style: label)]),
          const SizedBox(width: 18),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pressure == null ? 'none' : pressure!.toStringAsFixed(2), style: value), const Text('HPA', style: label)]),
          const Spacer(),
          if (!follow) IconButton.filledTonal(onPressed: onFollow, icon: const Icon(Icons.navigation), tooltip: 'Follow car'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Simulated'), icon: Icon(Icons.play_circle_outline)),
                ButtonSegment(value: true, label: Text('Live GPS'), icon: Icon(Icons.gps_fixed)),
              ],
              selected: {live},
              onSelectionChanged: (s) => onSource(s.first),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: onCapture,
            tooltip: capturing ? 'Stop road capture' : 'Road capture (camera + sensor log)',
            style: IconButton.styleFrom(backgroundColor: capturing ? const Color(0xFFD7262E) : const Color(0xFF3A4656)),
            icon: Icon(capturing ? Icons.videocam_off : Icons.videocam),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: capturing ? null : onRecord,
            style: FilledButton.styleFrom(
              backgroundColor: recording ? const Color(0xFFD7262E) : const Color(0xFF2E5BFF),
              disabledBackgroundColor: const Color(0xFF6B2226),
              disabledForegroundColor: Colors.white70,
            ),
            icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record),
            label: Text(recording ? 'Stop' : 'Record'),
          ),
        ]),
      ]),
    );
  }
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

/// Round buttons on the right edge: map options and move to my location.
class _MapButtons extends StatelessWidget {
  const _MapButtons({required this.onMe, required this.onOptions, required this.onSearch, required this.theme, this.routing = false});
  final VoidCallback onMe, onOptions, onSearch;
  final MapTheme theme;
  final bool routing;

  @override
  Widget build(BuildContext context) {
    final style = IconButton.styleFrom(
      backgroundColor: const Color(0xEE17202A),
      foregroundColor: Colors.white,
      fixedSize: const Size(48, 48),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            onPressed: routing ? null : onSearch,
            style: style,
            tooltip: 'Search and route',
            icon: routing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.search),
          ),
          const SizedBox(height: 8),
          IconButton(
            onPressed: onOptions,
            style: style,
            tooltip: 'Map options',
            icon: Icon(theme == MapTheme.game ? Icons.sports_esports : Icons.layers_outlined),
          ),
          const SizedBox(height: 8),
          IconButton(onPressed: onMe, style: style, tooltip: 'Move to my location', icon: const Icon(Icons.my_location)),
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
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<MapTheme>(
              segments: const [
                ButtonSegment(value: MapTheme.night, label: Text('Night'), icon: Icon(Icons.dark_mode_outlined)),
                ButtonSegment(value: MapTheme.day, label: Text('Day'), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: MapTheme.game, label: Text('Game'), icon: Icon(Icons.sports_esports_outlined)),
              ],
              selected: {theme},
              onSelectionChanged: (s) => onTheme(s.first),
            ),
          ),
          if (theme == MapTheme.game)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Bright city, 3D car and working 3D traffic lights.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
          const SizedBox(height: 18),
          const Text('CAMERA', style: head),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<CamView>(
              segments: [for (final v in CamView.values) ButtonSegment(value: v, label: Text(v.label), icon: Icon(v.icon))],
              selected: {view},
              onSelectionChanged: (s) => onView(s.first),
            ),
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
