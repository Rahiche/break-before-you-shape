// Second style probe: which features letter spacing switches off, and where
// word spacing goes.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Paragraph lay(String s, double size, {double? ls, double? ws, List<ui.FontFeature>? ff, double width = double.infinity}) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr))
    ..pushStyle(ui.TextStyle(fontFamily: family, fontSize: size, letterSpacing: ls, wordSpacing: ws, fontFeatures: ff))
    ..addText(s);
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

double right(ui.Paragraph p, int a, int b) {
  var r = 0.0;
  for (final x in p.getBoxesForRange(a, b)) {
    if (x.right > r) r = x.right;
  }
  return r;
}

double left(ui.Paragraph p, int a, int b) => p.getBoxesForRange(a, b).first.left;

void main() {
  testWidgets('style probe 2', (tester) async {
    await tester.runAsync(() async {
      await loadFont();
      const size = 2048.0; // font units
      final out = <String, Object?>{};
      for (final s in ['office', 'fi', 'fl', 'ffl', 'affirm', 'To', 'AV']) {
        final n = s.length;
        final spaced = right(lay(s, size, ls: 100), 0, n) - (n + 0.5) * 100;
        out[s] = {
          'spacedMinusSpacing': spaced,
          'default': right(lay(s, size), 0, n),
          'ligaOff': right(lay(s, size, ff: [const ui.FontFeature.disable('liga')]), 0, n),
          'ligaCligCaltOff': right(lay(s, size, ff: [const ui.FontFeature.disable('liga'), const ui.FontFeature.disable('clig'),
              const ui.FontFeature.disable('calt')]), 0, n),
          'perCharSum': [for (var i = 0; i < n; i++) right(lay(s[i], size), 0, 1)].reduce((a, b) => a + b),
        };
      }
      // Letter spacing positions: left edge of each character.
      final p = lay('abc', size, ls: 100);
      out['ls lefts abc'] = [for (var i = 0; i < 3; i++) left(p, i, i + 1)];
      out['nols lefts abc'] = [for (var i = 0; i < 3; i++) left(lay('abc', size), i, i + 1)];
      // Word spacing: where it goes in a run of spaces, and which boundaries get it.
      for (final s in ['a b', 'a  b', 'a   b', 'a - b', 'a, b', 'a. B', '1 2', '( a )', 'a  b', 'a b ', ' a']) {
        final base = lay(s, size), sp = lay(s, size, ws: 100);
        out['ws ${jsonEncode(s)}'] = {
          'lefts': [for (var i = 0; i < s.length; i++) left(sp, i, i + 1) - left(base, i, i + 1)],
        };
      }
      // Line fit with word spacing: "aaaa bbbb" breaks where?
      final w9 = right(lay('aaaa bbbb', 16, ws: 4), 0, 9);
      out['ws fit'] = {
        'w9': w9,
        for (final d in [-0.01, 0.0, 0.01]) 'lines at w9${d >= 0 ? '+' : ''}$d': lay('aaaa bbbb', 16, ws: 4, width: w9 + d).computeLineMetrics().length,
      };
      print('PROBE2 ${const JsonEncoder.withIndent(' ').convert(out)}');
    });
  });
}
