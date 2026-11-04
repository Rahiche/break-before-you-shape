// Probes how Flutter lays out rich text (several styles in one paragraph), for
// the breaker's model of it: kerning across a style boundary, widths of spans
// in different fonts and sizes, and line heights of lines that mix sizes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

double _w(List<(String, ui.TextStyle)> spans, {double width = 1e5}) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr));
  for (final (t, s) in spans) {
    b
      ..pushStyle(s)
      ..addText(t)
      ..pop();
  }
  final p = b.build()..layout(ui.ParagraphConstraints(width: width));
  final w = p.computeLineMetrics().first.width;
  p.dispose();
  return w;
}

ui.Paragraph _p(List<(String, ui.TextStyle)> spans, double width) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr));
  for (final (t, s) in spans) {
    b
      ..pushStyle(s)
      ..addText(t)
      ..pop();
  }
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

void main() {
  testWidgets('rich text probe', (tester) async {
    await tester.runAsync(() async {
      for (final (fam, path) in [('R', 'assets/Roboto-Regular.ttf'), ('A', '/System/Library/Fonts/Supplemental/Arial.ttf')]) {
        await (FontLoader(fam)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())))).load();
      }
      final r16 = ui.TextStyle(fontFamily: 'R', fontSize: 16);
      final r16red = ui.TextStyle(fontFamily: 'R', fontSize: 16, color: const ui.Color(0xFFFF0000));
      final r16b = ui.TextStyle(fontFamily: 'R', fontSize: 16, background: ui.Paint()..color = const ui.Color(0xFF00FF00));
      final r16d = ui.TextStyle(fontFamily: 'R', fontSize: 16, decoration: ui.TextDecoration.underline);
      final r24 = ui.TextStyle(fontFamily: 'R', fontSize: 24);
      final a16 = ui.TextStyle(fontFamily: 'A', fontSize: 16);
      final r16ls = ui.TextStyle(fontFamily: 'R', fontSize: 16, letterSpacing: 1);
      final r16h = ui.TextStyle(fontFamily: 'R', fontSize: 16, height: 1.5);
      print('PROBE AV one style ${_w([('AV', r16)])}');
      print('PROBE A|V colour   ${_w([('A', r16), ('V', r16red)])}');
      print('PROBE A|V backgr   ${_w([('A', r16), ('V', r16b)])}');
      print('PROBE A|V underl   ${_w([('A', r16), ('V', r16d)])}');
      print('PROBE A|V 16|24    ${_w([('A', r16), ('V', r24)])}  A16=${_w([('A', r16)])} V24=${_w([('V', r24)])}');
      print('PROBE A|V R|Arial  ${_w([('A', r16), ('V', a16)])}  A16=${_w([('A', r16)])} V(Arial)=${_w([('V', a16)])}');
      print('PROBE A|V ls       ${_w([('A', r16), ('V', r16ls)])}  V(ls)=${_w([('V', r16ls)])}');
      print('PROBE fi one style ${_w([('fi', r16)])} f|i colour ${_w([('f', r16), ('i', r16red)])}');
      // Line heights: one style per line, and lines mixing sizes, fonts, height.
      for (final (label, spans) in [
        ('r16', [('Hg Hg Hg', r16)]),
        ('r24', [('Hg Hg Hg', r24)]),
        ('a16', [('Hg Hg Hg', a16)]),
        ('r16h', [('Hg Hg Hg', r16h)]),
        ('r16+r24', [('Hg ', r16), ('Hg ', r24), ('Hg', r16)]),
        ('r16+a16', [('Hg ', r16), ('Hg', a16)]),
        ('r16h+r24', [('Hg ', r16h), ('Hg', r24)]),
        ('two lines r16 | r24', [('Hg Hg\n', r16), ('Hg Hg', r24)]),
      ]) {
        final p = _p(spans, 1e5);
        final ms = p.computeLineMetrics();
        print('LINES $label height=${p.height} ${[for (final m in ms) 'h=${m.height} a=${m.ascent} d=${m.descent} base=${m.baseline}'].join(' ; ')}');
        p.dispose();
      }
    });
  });
}
