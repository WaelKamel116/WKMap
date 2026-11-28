import 'package:cairo_nav/geo/geo.dart';
import 'package:cairo_nav/nav/camera_alerts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('warns once about a camera ahead on the road, facing the car', () {
    final a = CameraAlerts([
      const SpeedCamera(0, Vec(6, 400), 0, 60), // ahead, beside the road, facing north-bound cars
      const SpeedCamera(1, Vec(-6, 250), 180, 60), // other carriageway, facing south-bound cars
      const SpeedCamera(2, Vec(300, 200), null, 0), // on a side street far off the line
    ]);
    // far away: nothing yet (15 m/s -> looks 300 m ahead)
    expect(a.update(const Vec(0, 0), 0, 15), isNull);
    final first = a.update(const Vec(0, 120), 0, 15)!;
    expect(first.camera.id, 0);
    expect(first.isNew, isTrue);
    expect(first.distance, closeTo(280, 1));
    final again = a.update(const Vec(0, 200), 0, 15)!;
    expect(again.isNew, isFalse); // sound and vibration only once
    expect(a.update(const Vec(0, 420), 0, 15), isNull); // passed it
    // driving south: only the south-facing camera counts
    final south = a.update(const Vec(-4, 500), 180, 15)!;
    expect(south.camera.id, 1);
  });
}
