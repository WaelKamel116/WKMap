import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../sensors/trip_logger.dart';

/// Internal test capture: records forward-facing road video while driving.
///
/// Video (not single photos) because at 60 km/h a photo every few metres is
/// faster than phone cameras can shoot, and photo capture plays a shutter sound
/// on iPhone. Each clip's start and end time is written to `videos.csv`; the
/// sensor log `trip.csv` in the same folder has the GPS track, so
/// `tools/extract_frames.py` can later cut a geotagged frame every N metres.
///
/// Everything stays on the phone (no upload). Footage shows people and number
/// plates: internal use only, blur before sharing (see README).
///
/// Folder: trips/capture_YYYYMMDD_HHMMSS/ { trip.csv, videos.csv, clip_001.mp4, ... }
class RoadCapture extends ChangeNotifier {
  RoadCapture({this.clipLength = const Duration(minutes: 3)});

  /// Clips are closed and a new one started at this interval, so a crash or a
  /// full disk loses at most one clip, and files stay easy to copy.
  final Duration clipLength;

  CameraController? camera;
  Directory? folder;

  /// The folder of the last finished capture, to tell the user where it is.
  Directory? lastFolder;
  String? error;
  int clips = 0;
  int bytes = 0;
  DateTime? startedAt;

  IOSink? _index;
  Timer? _rotate;
  int _clipStartMs = 0;
  bool _busy = false;

  bool get active => folder != null;
  Duration get elapsed => startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  /// Opens the back camera and starts recording into a new folder.
  /// Returns the folder, which the caller also uses for the sensor log.
  Future<Directory?> start() async {
    if (active || _busy) return folder;
    _busy = true;
    error = null;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('no_camera', 'This phone has no camera.');
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      // 1080p at 30 fps, ~8 Mbit/s: sharp enough to read signs and lane arrows,
      // about 180 MB per 3-minute clip.
      final c = CameraController(back, ResolutionPreset.veryHigh,
          enableAudio: false, fps: 30, videoBitrate: 8000000);
      await c.initialize();
      try {
        await c.setFlashMode(FlashMode.off);
        await c.setFocusMode(FocusMode.auto);
      } on CameraException {
        // optional features; ignore if the phone does not support them
      }
      if (Platform.isIOS) await c.prepareForVideoRecording();
      camera = c;

      final dir = Directory('${(await TripLogger.tripsDir()).path}/capture_${TripLogger.stamp()}');
      await dir.create(recursive: true);
      folder = dir;
      _index = File('${dir.path}/videos.csv').openWrite()
        ..writeln('# start/end are phone clock ms (same clock as trip.csv); start is the midpoint of the start call')
        ..writeln('file,start_ms,end_ms,width,height,orientation');
      clips = 0;
      bytes = 0;
      startedAt = DateTime.now();
      await _startClip();
      _rotate = Timer.periodic(clipLength, (_) => _nextClip());
    } on CameraException catch (e) {
      error = e.code == 'CameraAccessDenied' || e.code == 'CameraAccessDeniedWithoutPrompt'
          ? 'Camera permission was refused. Allow it in the phone settings to use road capture.'
          : 'Camera error: ${e.description ?? e.code}';
      await _teardown();
    } catch (e) {
      error = 'Camera error: $e';
      await _teardown();
    } finally {
      _busy = false;
      notifyListeners();
    }
    return folder;
  }

  Future<void> _startClip() async {
    final before = DateTime.now().millisecondsSinceEpoch;
    await camera!.startVideoRecording();
    final after = DateTime.now().millisecondsSinceEpoch;
    _clipStartMs = (before + after) ~/ 2;
  }

  /// Closes the current clip, moves it into the capture folder and logs it.
  Future<void> _finishClip() async {
    final c = camera;
    if (c == null || !c.value.isRecordingVideo) return;
    final x = await c.stopVideoRecording();
    final end = DateTime.now().millisecondsSinceEpoch;
    clips++;
    final name = 'clip_${clips.toString().padLeft(3, '0')}.mp4';
    final dest = File('${folder!.path}/$name');
    final src = File(x.path);
    try {
      await src.rename(dest.path);
    } on FileSystemException {
      // camera writes to the cache folder, which can be on a different disk
      await src.copy(dest.path);
      await src.delete();
    }
    bytes += await dest.length();
    final size = c.value.previewSize; // landscape sensor size, e.g. 1920x1080
    final orient = c.value.recordingOrientation?.name ?? c.value.deviceOrientation.name;
    _index?.writeln('$name,$_clipStartMs,$end,${size?.width.round() ?? ''},${size?.height.round() ?? ''},$orient');
    await _index?.flush();
  }

  Future<void> _nextClip() async {
    if (_busy || !active) return;
    _busy = true;
    try {
      await _finishClip();
      await _startClip();
    } catch (e) {
      error = 'Camera error: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Stops recording and saves the last clip.
  Future<void> stop() async {
    if (!active) return;
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _busy = true;
    _rotate?.cancel();
    try {
      await _finishClip();
    } catch (e) {
      error = 'Camera error while saving: $e';
    }
    await _teardown();
    _busy = false;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _rotate?.cancel();
    _rotate = null;
    await _index?.flush();
    await _index?.close();
    _index = null;
    await camera?.dispose();
    camera = null;
    if (folder != null) lastFolder = folder;
    folder = null;
    startedAt = null;
  }

  @override
  void dispose() {
    _rotate?.cancel();
    _index?.close();
    camera?.dispose();
    super.dispose();
  }
}
