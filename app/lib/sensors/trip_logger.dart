import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../nav/level_detector.dart';
import 'drive_source.dart';

/// Writes every sensor reading and every level decision to a CSV file, so a
/// real drive can be replayed and the detector tuned afterwards.
///
/// Files go to the app's external files folder, which you can copy over USB:
/// Android/data/com.smarttechsys.caironav/files/trips/
class TripLogger {
  IOSink? _sink;
  File? file;
  int rows = 0;

  bool get recording => _sink != null;

  Future<void> start(String source) async {
    // Android: external app folder (copy over USB). iPhone: Documents, visible in the Files app.
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory())
        : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/trips');
    await dir.create(recursive: true);
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'trip_${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.csv';
    file = File('${dir.path}/$name');
    _sink = file!.openWrite();
    _sink!.writeln('# source=$source');
    _sink!.writeln('t_ms,kind,lon,lat,accuracy_m,speed_mps,heading_deg,gps_alt_m,pressure_hpa,level,confidence,baro_h_m,deck_h_m,road');
    rows = 0;
  }

  void sample(DriveSample s) {
    final k = _sink;
    if (k == null) return;
    final t = s.time.millisecondsSinceEpoch;
    switch (s) {
      case PositionSample p:
        k.writeln('$t,gps,${p.lon.toStringAsFixed(7)},${p.lat.toStringAsFixed(7)},${p.accuracy.toStringAsFixed(1)},'
            '${p.speed.toStringAsFixed(2)},${p.heading.toStringAsFixed(1)},${p.altitude.toStringAsFixed(1)},,,,,,');
      case PressureSample b:
        k.writeln('$t,baro,,,,,,,${b.hPa.toStringAsFixed(4)},,,,,');
    }
    rows++;
  }

  void decision(DateTime time, LevelEstimate e) {
    final k = _sink;
    if (k == null) return;
    final road = e.roadName.replaceAll(',', ' ');
    k.writeln('${time.millisecondsSinceEpoch},level,,,,,,,,${e.level.name},${e.confidence.toStringAsFixed(2)},'
        '${e.baroHeight?.toStringAsFixed(2) ?? ''},${e.mapHeight?.toStringAsFixed(2) ?? ''},$road');
    rows++;
  }

  Future<void> stop() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
