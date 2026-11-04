// Combining marks: text in decomposed form (NFD: "é" as "e" + U+0301), which
// HarfBuzz recomposes where the font has the composite and otherwise draws with
// zero-width marks, against Flutter's own layout. Default style, and letter and
// word spacing with hard breaks.
//
// MARKS_FONTS: font:certificate:no-ligature certificate triples, ';' between
// fonts (certificates from the current certify.py). MARKS_CORPUS: corpus files,
// ':'-separated. MARKS_OUT: results JSON.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart' show flutterLineStarts;
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

void main() {
  final env = Platform.environment;
  final spec = env['MARKS_FONTS'];
  testWidgets('combining marks', (tester) async {
    await tester.runAsync(() async {
      final out = <String, Object?>{};
      final examples = <String>[];
      final corpora = {
        for (final path in env['MARKS_CORPUS']!.split(':'))
          path.split('/').last.replaceAll('.txt', ''):
              File(path).readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList(),
      };
      var k = 0;
      for (final triple in spec!.split(';')) {
        final [fontPath, certPath, noligPath] = triple.split(':');
        final family = 'Marks${k++}';
        final font = File(fontPath).readAsBytesSync();
        await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
        final md = buildSidecar(fontFamily: family, font: font, certificate: File(certPath).readAsStringSync(),
            noLigaCertificate: File(noligPath).readAsStringSync());
        calibrateEngine(md, family);
        final row = <String, Object?>{'marks': md.marks.length, 'compositions': md.compose.length,
            'canaryErrPx': canaryError(md, family)};
        for (final e in corpora.entries) {
          final joined = [for (var i = 0; i + 3 <= e.value.length; i += 3) e.value.sublist(i, i + 3).join('\n')];
          for (final (label, texts, o) in [
            ('${e.key}', e.value, LineOptions.plain),
            ('${e.key}, letterSpacing 0.5, wordSpacing 1, hard breaks', joined, const LineOptions(letterSpacing: 0.5, wordSpacing: 1)),
          ]) {
            var same = 0, diff = 0, deferred = 0, heights = 0;
            final recs = [for (final t in texts) buildRecords(md, t, letterSpacing: o.letterSpacing)];
            for (final size in [12.0, 16.0, 21.3]) {
              final scale = scaleFor(md, size), lh = lineHeightPx(md, size);
              for (var w = 0; w < 6; w++) {
                final width = size * (6.0 + w * 30.0 / 5);
                for (var i = 0; i < texts.length; i++) {
                  final ours = recs[i]?.lineStarts(width, scale, letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
                  if (ours == null) {
                    deferred++;
                    continue;
                  }
                  final p = layoutParagraph(texts[i], fontFamily: family, fontSize: size, width: width,
                      letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
                  final theirs = flutterLineStarts(p, texts[i]);
                  if (_same(ours, theirs)) {
                    same++;
                    if ((ours.length * lh - p.height).abs() < 1e-3) heights++;
                  } else {
                    diff++;
                    if (examples.length < 16) {
                      examples.add('${md.name} $label size=$size w=$width ours=$ours flutter=$theirs | ${jsonEncode(texts[i])}');
                    }
                  }
                  p.dispose();
                }
              }
            }
            row[label] = {'texts': texts.length, 'identical': same, 'different': diff, 'deferred': deferred,
                'heightsEqual': heights};
          }
        }
        out[md.name] = row;
        print('MARKS ${md.name}: ${jsonEncode(row)}');
      }
      out['examples'] = examples;
      File(env['MARKS_OUT'] ?? 'results/marks.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, skip: spec == null, timeout: const Timeout(Duration(hours: 2)));
}
