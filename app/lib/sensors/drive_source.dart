import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../nav/route_data.dart';

/// One reading from the phone (real or simulated).
sealed class DriveSample {
  final DateTime time;
  const DriveSample(this.time);
}

class PositionSample extends DriveSample {
  final double lon, lat, accuracy, speed, heading, altitude;
  const PositionSample(super.time, this.lon, this.lat, this.accuracy, this.speed, this.heading, this.altitude);
}

class PressureSample extends DriveSample {
  final double hPa;
  const PressureSample(super.time, this.hPa);
}

/// Turn rate about the vertical, degrees per second, clockwise like a compass,
/// averaged over [dt] seconds (from the gyroscope, whatever way the phone is mounted).
class YawSample extends DriveSample {
  final double dps, dt;
  const YawSample(super.time, this.dps, this.dt);
}

/// Something that produces drive samples: live sensors or the simulator.
abstract class DriveSource {
  Stream<DriveSample> get samples;
  Future<void> start();
  Future<void> stop();
  String get label;
}

/// Real GPS (1 Hz, keeps running with the screen off thanks to a foreground
/// notification) and the barometer.
class LiveSource implements DriveSource {
  final _ctrl = StreamController<DriveSample>.broadcast();
  StreamSubscription<Position>? _gps;
  StreamSubscription<BarometerEvent>? _baro;
  StreamSubscription<AccelerometerEvent>? _acc;
  StreamSubscription<GyroscopeEvent>? _gyro;
  bool barometerAvailable = true;

  // gravity direction (low-pass accelerometer) and the yaw rate collected for the next sample
  double _gx = 0, _gy = 0, _gz = 9.8;
  double _yawSum = 0;
  DateTime? _gyroAt, _yawFrom;
  String? problem;

  @override
  String get label => 'Live GPS';

  @override
  Stream<DriveSample> get samples => _ctrl.stream;

  @override
  Future<void> start() async {
    problem = null;
    if (!await Geolocator.isLocationServiceEnabled()) {
      problem = 'Location is turned off. Turn it on in the phone settings.';
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      problem = 'Location permission was refused. Allow it in the phone settings to use live GPS.';
      return;
    }
    final LocationSettings settings = Platform.isIOS
        ? AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            activityType: ActivityType.automotiveNavigation,
            pauseLocationUpdatesAutomatically: false,
            allowBackgroundLocationUpdates: true,
            showBackgroundLocationIndicator: true,
          )
        : AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 1),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Cairo Nav is using your location',
              notificationText: 'Recording the drive for flyover detection',
              enableWakeLock: true,
            ),
          );
    _gps = Geolocator.getPositionStream(locationSettings: settings).listen((p) {
      _ctrl.add(PositionSample(p.timestamp, p.longitude, p.latitude, p.accuracy, p.speed, p.heading, p.altitude));
    }, onError: (Object e) => problem = 'GPS error: $e');
    _baro = barometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
      (e) => _ctrl.add(PressureSample(e.timestamp, e.pressure)),
      onError: (Object e) {
        barometerAvailable = false;
      },
      cancelOnError: true,
    );
    // gyroscope turn rate about the vertical: the phone can be mounted at any angle, so
    // project the rotation onto the gravity direction (accelerometer, low-pass filtered)
    _acc = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
      _gx += 0.05 * (e.x - _gx);
      _gy += 0.05 * (e.y - _gy);
      _gz += 0.05 * (e.z - _gz);
    }, onError: (Object _) {}, cancelOnError: true);
    _gyro = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
      final now = e.timestamp;
      final last = _gyroAt;
      _gyroAt = now;
      _yawFrom ??= now;
      if (last == null) return;
      final dt = now.difference(last).inMicroseconds / 1e6;
      if (dt <= 0 || dt > 0.5) return;
      final g = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
      if (g < 5) return;
      // accelerometer points up at rest; rotation counter-clockwise about "up" is positive,
      // compass heading turns clockwise, hence the minus
      final ccw = (e.x * _gx + e.y * _gy + e.z * _gz) / g;
      _yawSum += -ccw * 180 / math.pi * dt;
      final span = now.difference(_yawFrom!).inMicroseconds / 1e6;
      if (span >= 0.1) {
        _ctrl.add(YawSample(now, _yawSum / span, span));
        _yawSum = 0;
        _yawFrom = now;
      }
    }, onError: (Object _) {}, cancelOnError: true);
  }

  @override
  Future<void> stop() async {
    await _gps?.cancel();
    await _baro?.cancel();
    await _acc?.cancel();
    await _gyro?.cancel();
    _gps = null;
    _baro = null;
    _acc = null;
    _gyro = null;
    _gyroAt = null;
    _yawFrom = null;
  }
}

/// Drives the demo route at a steady speed and fakes the sensors, including
/// realistic GPS noise and barometer noise, so the detector can be tested at a desk.
class SimulatedSource implements DriveSource {
  SimulatedSource(this.route, {this.speedKmh = 55, this.timeScale = 1});

  final RouteData route;
  double speedKmh;
  double timeScale;
  double distance = 0;
  final _ctrl = StreamController<DriveSample>.broadcast();
  Timer? _timer;
  final _rnd = math.Random(7);
  int _tick = 0;
  double? _lastHeading;

  @override
  String get label => 'Simulated drive';

  @override
  Stream<DriveSample> get samples => _ctrl.stream;

  double _gauss() {
    final u = 1 - _rnd.nextDouble(), v = _rnd.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  @override
  Future<void> start() async {
    _timer?.cancel();
    const step = Duration(milliseconds: 100); // barometer at 10 Hz, GPS every 10th tick
    _timer = Timer.periodic(step, (_) {
      distance += speedKmh / 3.6 * 0.1 * timeScale;
      if (distance >= route.distance) distance = 0;
      final p = route.sample(distance);
      final now = DateTime.now();
      // weather drift is ignored over a few minutes; sensor noise ~0.03 hPa (about 25 cm)
      _ctrl.add(PressureSample(now, 1012.6 - p.height / 8.4 + _gauss() * 0.03));
      // gyroscope: true turn rate plus noise and a small constant offset, like a real sensor
      final h = p.heading;
      if (_lastHeading != null) {
        final turn = ((h - _lastHeading! + 540) % 360) - 180;
        _ctrl.add(YawSample(now, turn / 0.1 + _gauss() * 0.4 + 0.6, 0.1));
      }
      _lastHeading = h;
      if (_tick++ % 10 == 0) {
        // GPS: 3-5 m horizontal error, which is why it cannot tell the levels apart on its own
        final eLon = _gauss() * 4 / 96400, eLat = _gauss() * 4 / 110540;
        _ctrl.add(PositionSample(now, p.lon + eLon, p.lat + eLat, 4.5, speedKmh / 3.6, p.heading + _gauss() * 3, 30 + p.height));
      }
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }
}
