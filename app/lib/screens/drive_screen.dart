import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
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
    await c.setGeoJsonSource('puck', puckGeoJson(p.lon, p.lat, p.heading, h));
    if (_follow) {
      await c.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: LatLng(p.lat, p.lon), zoom: 17.2, tilt: 60, bearing: p.heading)),
        duration: const Duration(milliseconds: 950),
      );
    }
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
      backgroundColor: const Color(0xFF0E141B),
      body: Stack(children: [
        MapLibreMap(
          styleString: baseStyle,
          initialCameraPosition: const CameraPosition(target: LatLng(30.0745, 31.3585), zoom: 16.5, tilt: 55, bearing: 226),
          compassEnabled: false,
          rotateGesturesEnabled: true,
          tiltGesturesEnabled: true,
          onMapCreated: (c) => _map = c,
          onCameraTrackingDismissed: () => setState(() => _follow = false),
          onStyleLoadedCallback: () async {
            if (_route == null || _map == null) return;
            await addCityLayers(_map!, _route!);
            _styleReady = true;
          },
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              _LevelCard(est: _est, hasBaseline: _detector?.hasBaseline ?? false),
              const Spacer(),
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
