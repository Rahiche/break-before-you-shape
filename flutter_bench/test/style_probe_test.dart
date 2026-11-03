// Measures how Flutter applies style options the breaker must model: hard line
// breaks, letter and word spacing, the height multiplier and maxLines. Prints
// what it sees; the rules in width_model.dart come from these numbers.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart';
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Paragraph lay(String s, double size, {double width = double.infinity, double? ls, double? ws, double? h, int? maxLines}) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr, maxLines: maxLines))
    ..pushStyle(ui.TextStyle(fontFamily: family, fontSize: size, letterSpacing: ls, wordSpacing: ws, height: h))
    ..addText(s);
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

double right(ui.Paragraph p, int n) {
  var r = 0.0;
  for (final b in p.getBoxesForRange(0, n)) {
    if (b.right > r) r = b.right;
  }
  return r;
}

void main() {
  testWidgets('style probe', (tester) async {
    await tester.runAsync(() async {
      await loadFont();
      final md = WidthModel.decode((await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List());
      final out = <String, Object?>{};
      const size = 16.0;
      final scale = size / md.upem;
      // 1. Hard line breaks.
      for (final s in ['ab\ncd', 'ab\n', '\nab', 'ab\n\ncd', 'ab\r\ncd', 'ab\rcd', 'ab cd', 'ab cd', 'ab\u0085cd']) {
        final p = lay(s, size, width: 500);
        out['newline ${jsonEncode(s)}'] = {
          'lines': p.computeLineMetrics().length, 'height': p.height,
          'starts': [for (final l in p.computeLineMetrics()) p.getPositionForOffset(ui.Offset(0, l.baseline - l.ascent / 2)).offset],
        };
      }
      // 2. Letter spacing: width with spacing minus without, per text.
      for (final s in ['abc', 'office', 'fi', 'To', 'a b', 'AV', 'ab ', 'x']) {
        final base = right(lay(s, size), s.length);
        final sp = right(lay(s, size, ls: 1.5), s.length);
        out['letterSpacing ${jsonEncode(s)}'] = {'base': base, 'spaced': sp, 'perUnit': (sp - base) / 1.5,
            'model': md.widthOf(s) * scale};
      }
      // Letter spacing at a line end: does the trailing spacing count for the fit?
      {
        const s = 'aaaa aaaa';
        final w4 = right(lay('aaaa', size, ls: 2), 4);
        out['letterSpacing fit'] = {
          'w4': w4,
          for (final d in [-0.5, -0.01, 0.0, 0.01, 0.5])
            'linesAt w4${d >= 0 ? '+' : ''}$d': lay(s, size, width: w4 + d, ls: 2).computeLineMetrics().length,
          'linesAt w4-2+0.01': lay(s, size, width: w4 - 2 + 0.01, ls: 2).computeLineMetrics().length,
        };
      }
      // 3. Word spacing.
      for (final s in ['a b', 'a  b', 'a b', 'ab ', 'a b c']) {
        final base = right(lay(s, size), s.length);
        final sp = right(lay(s, size, ws: 3), s.length);
        out['wordSpacing ${jsonEncode(s)}'] = {'base': base, 'spaced': sp, 'perUnit': (sp - base) / 3};
      }
      // 4. Height multiplier: line heights and paragraph height.
      final heights = <String, Object?>{};
      for (final sz in [12.0, 13.0, 16.0, 18.4, 21.3, 24.0]) {
        for (final h in [0.8, 1.0, 1.2, 1.43, 1.5, 2.0]) {
          final p = lay('one two three four five six seven eight nine ten', sz, width: sz * 8, h: h);
          final lms = p.computeLineMetrics();
          heights['$sz x $h'] = {'lines': lms.length, 'height': p.height,
              'lineHeights': {for (final l in lms) l.height}.toList(), 'sizeTimesH': sz * h};
        }
      }
      out['height'] = heights;
      // 5. maxLines.
      for (final m in [1, 2, 3]) {
        final p = lay('one two three four five six seven eight nine ten', size, width: 80, maxLines: m);
        out['maxLines $m'] = {'lines': p.computeLineMetrics().length, 'height': p.height, 'exceeded': p.didExceedMaxLines};
      }
      Directory('results').createSync();
      File('results/style_probe.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  });
}
