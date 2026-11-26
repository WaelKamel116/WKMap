import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Draws the road-sign pictures the map stands up beside the road: each sign
/// on a grey pole, anchored at the foot of the pole. Drawn on the phone so
/// Arabic street names are shaped correctly and nothing is downloaded.
class SignIcons {
  static final Map<String, Uint8List> _cache = {};

  static const _pole = Color(0xFF8A9099);
  static const _red = Color(0xFFD7262E);
  static const _blue = Color(0xFF1C4FA8);

  static Future<Uint8List> _draw(String key, double w, double h, void Function(Canvas c) paint) async {
    final hit = _cache[key];
    if (hit != null) return hit;
    final rec = ui.PictureRecorder();
    paint(Canvas(rec));
    final img = await rec.endRecording().toImage(w.ceil(), h.ceil());
    final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    img.dispose();
    return _cache[key] = png;
  }

  static void _poleAt(Canvas c, double x, double top, double bottom) {
    c.drawRRect(RRect.fromLTRBR(x - 3, top, x + 3, bottom, const Radius.circular(2)), Paint()..color = _pole);
  }

  static void _text(Canvas c, String s, Offset center, double size, Color color,
      {FontWeight weight = FontWeight.w800, String? family, TextDirection dir = TextDirection.ltr, double? maxWidth}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight, fontFamily: family, height: 1.0)),
      textDirection: dir,
      maxLines: 1,
      ellipsis: maxWidth == null ? null : '…',
    )..layout(maxWidth: maxWidth ?? double.infinity);
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  static void _icon(Canvas c, IconData icon, Offset center, double size, Color color) {
    _text(c, String.fromCharCode(icon.codePoint), center, size, color, weight: FontWeight.w400, family: icon.fontFamily);
  }

  /// Speed limit: white disc, red ring, number.
  static Future<Uint8List> speed(String v) => _draw('speed-$v', 96, 170, (c) {
        _poleAt(c, 48, 80, 170);
        c.drawCircle(const Offset(48, 46), 44, Paint()..color = Colors.white);
        c.drawCircle(const Offset(48, 46), 38, Paint()
          ..color = _red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11);
        _text(c, v, const Offset(48, 47), v.length > 2 ? 30 : 36, Colors.black);
      });

  /// Speed camera: blue square with a camera.
  static Future<Uint8List> camera() => _draw('camera', 90, 160, (c) {
        _poleAt(c, 45, 80, 160);
        c.drawRRect(RRect.fromLTRBR(4, 4, 86, 86, const Radius.circular(10)), Paint()..color = Colors.white);
        c.drawRRect(RRect.fromLTRBR(9, 9, 81, 81, const Radius.circular(7)), Paint()..color = _blue);
        _icon(c, Icons.photo_camera, const Offset(45, 45), 50, Colors.white);
      });

  /// Pedestrian crossing: blue square, white triangle, walking figure.
  static Future<Uint8List> crossing() => _draw('crossing', 90, 160, (c) {
        _poleAt(c, 45, 80, 160);
        c.drawRRect(RRect.fromLTRBR(4, 4, 86, 86, const Radius.circular(10)), Paint()..color = Colors.white);
        c.drawRRect(RRect.fromLTRBR(9, 9, 81, 81, const Radius.circular(7)), Paint()..color = _blue);
        c.drawPath(Path()..moveTo(45, 15)..lineTo(77, 74)..lineTo(13, 74)..close(), Paint()..color = Colors.white);
        _icon(c, Icons.directions_walk, const Offset(45, 53), 34, Colors.black);
      });

  /// Traffic light on a pole.
  static Future<Uint8List> signal() => _draw('signal', 70, 190, (c) {
        _poleAt(c, 35, 100, 190);
        c.drawRRect(RRect.fromLTRBR(8, 4, 62, 106, const Radius.circular(12)), Paint()..color = const Color(0xFF15161B));
        c.drawRRect(RRect.fromLTRBR(8, 4, 62, 106, const Radius.circular(12)), Paint()
          ..color = const Color(0xFFFFC21A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
        c.drawCircle(const Offset(35, 24), 11, Paint()..color = const Color(0xFFFF3B30));
        c.drawCircle(const Offset(35, 55), 11, Paint()..color = const Color(0x55FFC21A));
        c.drawCircle(const Offset(35, 86), 11, Paint()..color = const Color(0x553DFF6E));
      });

  static Future<Uint8List> stop() => _draw('stop', 96, 170, (c) {
        _poleAt(c, 48, 80, 170);
        Path octagon(double r) {
          final p = Path();
          for (var i = 0; i < 8; i++) {
            final a = (i * 45 + 22.5) * math.pi / 180;
            final pt = Offset(48 + r * math.cos(a), 46 + r * math.sin(a));
            i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
          }
          return p..close();
        }

        c.drawPath(octagon(44), Paint()..color = Colors.white);
        c.drawPath(octagon(38), Paint()..color = _red);
        _text(c, 'قف', const Offset(48, 36), 24, Colors.white, dir: TextDirection.rtl);
        _text(c, 'STOP', const Offset(48, 60), 18, Colors.white);
      });

  static Future<Uint8List> giveWay() => _draw('give_way', 100, 160, (c) {
        _poleAt(c, 50, 70, 160);
        c.drawPath(Path()..moveTo(4, 6)..lineTo(96, 6)..lineTo(50, 86)..close(), Paint()..color = _red);
        c.drawPath(Path()..moveTo(22, 17)..lineTo(78, 17)..lineTo(50, 66)..close(), Paint()..color = Colors.white);
      });

  /// Street-name plate: blue, white border, Arabic name above the English one.
  static Future<Uint8List> name(int index, String en, String ar) {
    const w = 300.0;
    final two = en.isNotEmpty && ar.isNotEmpty;
    final plateH = two ? 84.0 : 54.0;
    return _draw('name-$index', w, plateH + 70, (c) {
      _poleAt(c, 40, plateH - 4, plateH + 70);
      _poleAt(c, w - 40, plateH - 4, plateH + 70);
      c.drawRRect(RRect.fromLTRBR(2, 2, w - 2, plateH, const Radius.circular(9)), Paint()..color = Colors.white);
      c.drawRRect(RRect.fromLTRBR(6, 6, w - 6, plateH - 4, const Radius.circular(6)), Paint()..color = _blue);
      if (two) {
        _text(c, ar, const Offset(w / 2, 26), 26, Colors.white, weight: FontWeight.w700, dir: TextDirection.rtl, maxWidth: w - 24);
        _text(c, en, const Offset(w / 2, 60), 20, Colors.white, weight: FontWeight.w600, maxWidth: w - 24);
      } else {
        final s = en.isNotEmpty ? en : ar;
        _text(c, s, Offset(w / 2, plateH / 2), 24, Colors.white,
            weight: FontWeight.w700, dir: en.isNotEmpty ? TextDirection.ltr : TextDirection.rtl, maxWidth: w - 24);
      }
    });
  }
}
