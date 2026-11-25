import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../capture/road_capture.dart';
import '../map/map_layers.dart';
import '../nav/level_detector.dart';
import '../nav/match_data.dart';
import '../nav/route_data.dart';
import '../sensors/drive_source.dart';
import '../sensors/trip_logger.dart';

/// How the camera follows the car.
enum CamView {
  follow3d('3D', Icons.threed_rotation),
  chase('Close', Icons.directions_car),
  top('Top-down', Icons.map_outlined);

  const CamView(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Milestone 1 screen: 3D Nasr City map, live or simulated position, and the
/// flyover level indicator, with a recorder for real test drives.
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with WidgetsBindingObserver {
  MapLibreMapController? _map;
  bool _styleReady = false;
  RouteData? _route;
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

  // map display options
  static final _initialStyle = baseStyle();
  MapTheme _theme = MapTheme.night;
  CamView _view = CamView.follow3d;
  bool _showBuildings = true, _showSignals = true;
  bool _cameraPlaced = false;
  List<List<double>> _signalPts = const [];
  Timer? _signalTimer;
  int _tick = 0;
  Position? _me;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _signalTimer = Timer.periodic(const Duration(seconds: 1), (_) => _animateSignals());
    _load();
  }

  Future<void> _load() async {
    final route = RouteData.fromJson(jsonDecode(await rootBundle.loadString('assets/data/route.json')) as Map<String, dynamic>);
    final match = MatchData.fromJson(jsonDecode(await rootBundle.loadString('assets/data/match.json')) as Map<String, dynamic>);
    setState(() {
      _route = route;
      _detector = LevelDetector(match);
    });
    await _useSource(live: false);
  }

  Future<void> _useSource({required bool live}) async {
    await _sub?.cancel();
    await _source?.stop();
    final detector = _route == null ? null : LevelDetector(_detector!.data);
    final source = live ? LiveSource() : SimulatedSource(_route!);
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
        d.addPressure(b.hPa);
        _lastPressure = b.hPa;
      case PositionSample p:
        final e = d.update(p.lon, p.lat, heading: p.heading, speed: p.speed, accuracy: p.accuracy);
        _logger.decision(p.time, e);
        _lastPos = p;
        setState(() => _est = e);
        _moveCar(p, e);
    }
  }

  Future<void> _moveCar(PositionSample p, LevelEstimate e) async {
    final c = _map;
    if (c == null || !_styleReady) return;
    final h = e.onFlyover ? (e.mapHeight ?? 0) : 0.0;
    await c.setGeoJsonSource('puck', puckGeoJson(p.lon, p.lat, p.heading, h, theme: _theme));
    if (_follow) {
      await c.animateCamera(
        CameraUpdate.newCameraPosition(_cameraAt(p.lat, p.lon, p.heading)),
        duration: const Duration(milliseconds: 950),
      );
    }
  }

  CameraPosition _cameraAt(double lat, double lon, double heading) => switch (_view) {
        CamView.follow3d => CameraPosition(target: LatLng(lat, lon), zoom: 17.2, tilt: 60, bearing: heading),
        CamView.chase => CameraPosition(target: LatLng(lat, lon), zoom: 18.4, tilt: 60, bearing: heading),
        CamView.top => CameraPosition(target: LatLng(lat, lon), zoom: 16.3, tilt: 0, bearing: 0),
      };

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
    await _applyVisibility();
    await _showMe();
    if (_lastPos != null && _est != null) {
      await _moveCar(_lastPos!, _est!);
    } else if (!_cameraPlaced) {
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
    setState(() => _view = v);
    final c = _map;
    if (c == null) return;
    if (_follow && _lastPos != null && _est != null) return _moveCar(_lastPos!, _est!);
    final cam = c.cameraPosition;
    if (cam == null) return;
    final next = _cameraAt(cam.target.latitude, cam.target.longitude, cam.bearing);
    await c.animateCamera(CameraUpdate.newCameraPosition(next), duration: const Duration(milliseconds: 700));
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
      if (_lastPos != null && _est != null) await _moveCar(_lastPos!, _est!);
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
    final r = _route!;
    var w = 180.0, e = -180.0, s = 90.0, n = -90.0;
    for (final c in r.coords) {
      if (c[0] < w) w = c[0];
      if (c[0] > e) e = c[0];
      if (c[1] < s) s = c[1];
      if (c[1] > n) n = c[1];
    }
    const pad = 0.03; // about 3 km: main roads are mapped well beyond the route
    final inside = p.longitude > w - pad && p.longitude < e + pad && p.latitude > s - pad && p.latitude < n + pad;
    setState(() {
      _me = p;
      _follow = false; // keep the simulated car from pulling the map back
      _message = inside ? null : 'You are outside the mapped area (Nasr City to New Cairo), so the map around you is empty.';
    });
    await _showMe();
    final bearing = _map?.cameraPosition?.bearing ?? 0;
    await _map?.animateCamera(CameraUpdate.newCameraPosition(_cameraAt(p.latitude, p.longitude, bearing)),
        duration: const Duration(milliseconds: 900));
  }

  void _openOptions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF17202A),
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => _OptionsSheet(
          theme: _theme,
          view: _view,
          buildings: _showBuildings,
          signals: _showSignals,
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
    _capture.dispose();
    _sub?.cancel();
    _source?.stop();
    _logger.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(MapPalette.of(_theme).ui),
      body: Stack(children: [
        MapLibreMap(
          styleString: _initialStyle,
          initialCameraPosition: const CameraPosition(target: LatLng(30.0725, 31.3460), zoom: 16.5, tilt: 55, bearing: 180),
          compassEnabled: false,
          rotateGesturesEnabled: true,
          tiltGesturesEnabled: true,
          onMapCreated: (c) => _map = c,
          onCameraTrackingDismissed: () => setState(() => _follow = false),
          onStyleLoadedCallback: _onStyleLoaded,
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              _LevelCard(est: _est, hasBaseline: _detector?.hasBaseline ?? false),
              const Spacer(),
              _MapButtons(onMe: _goToMe, onOptions: _openOptions, theme: _theme),
              if (_capture.camera != null) _CapturePreview(capture: _capture),
              if (_message != null) _Note(text: _message!, onClose: () => setState(() => _message = null)),
              _BottomBar(
                live: _live,
                recording: _logger.recording,
                follow: _follow,
                speedKmh: (_lastPos?.speed ?? 0) * 3.6,
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

class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.est, required this.hasBaseline});
  final LevelEstimate? est;
  final bool hasBaseline;

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
  const _MapButtons({required this.onMe, required this.onOptions, required this.theme});
  final VoidCallback onMe, onOptions;
  final MapTheme theme;

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
    required this.onTheme,
    required this.onView,
    required this.onBuildings,
    required this.onSignals,
  });
  final MapTheme theme;
  final CamView view;
  final bool buildings, signals;
  final ValueChanged<MapTheme> onTheme;
  final ValueChanged<CamView> onView;
  final ValueChanged<bool> onBuildings, onSignals;

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
        ]),
      ),
    );
  }
}
