// Font fallback with bundled fonts: text in the bundled Roboto mixed with
// Japanese, Chinese and Korean that Roboto lacks, with fontFamilyFallback set to
// two bundled CJK fonts (each with its sidecar), against Flutter's own layout
// with the same fallback list.
//
// FALLBACK_FONTS: font:certificate pairs, ':'-separated within a pair and ';'
// between fonts, in fallback order. FALLBACK_SAMPLE: texts per language pair
// (default 400). FALLBACK_OUT: results JSON.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart' show flutterLineStarts, loadCorpus;
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

Future<BreakFirst> _load(String family, Uint8List font, String cert, String? nolig) async {
  await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
  final md = buildSidecar(fontFamily: family, font: font, certificate: cert, noLigaCertificate: nolig);
  return BreakFirst.load(md.encode(), fontFamily: family)!;
}

void main() {
  final env = Platform.environment;
  final spec = env['FALLBACK_FONTS'];
  testWidgets('font fallback', (tester) async {
    await tester.runAsync(() async {
      final roboto = await _load('FbRoboto', File('assets/Roboto-Regular.ttf').readAsBytesSync(),
          File('assets/roboto.cert').readAsStringSync(), File('assets/roboto.nolig.cert').readAsStringSync());
      final fallback = <BreakFirst>[];
      for (final pair in spec!.split(';')) {
        final i = pair.lastIndexOf(':');
        fallback.add(await _load('Fb${fallback.length}', File(pair.substring(0, i)).readAsBytesSync(),
            File(pair.substring(i + 1)).readAsStringSync(), null));
      }
      final sample = int.parse(env['FALLBACK_SAMPLE'] ?? '400');
      final texts = <String>[];
      for (final (a, b) in [('ui_en', 'ui_ja'), ('ui_de', 'ui_zh_CN'), ('ui_ru', 'ui_ko'), ('ui_fr', 'ui_ja')]) {
        final x = await loadCorpus(a), y = await loadCorpus(b);
        if (x.isEmpty || y.isEmpty) continue;
        for (var i = 0; i < sample; i++) {
          final p = x[(i * 7919) % x.length], q = y[(i * 104729) % y.length];
          // Alternately: one after the other, and the second inside the first.
          final sp = p.indexOf(' ', p.length ~/ 2);
          texts.add(i.isEven || sp < 0 ? '$p $q' : '${p.substring(0, sp)} $q${p.substring(sp)}');
        }
      }
      final out = <String, Object?>{'texts': texts.length, 'fallback': fallback.map((f) => f.model.name).toList()};
      final examples = <String>[];
      var same = 0, diff = 0, deferred = 0, heights = 0;
      for (final size in [13.0, 16.0, 20.0]) {
        final family = [for (final f in fallback) f.fontFamily];
        for (final t in texts) {
          final rich = RichParagraph.prepare([RichSpan(t, roboto, size, fallback: fallback)]);
          for (final w in [100.0, 160.0, 240.0, 360.0, 560.0]) {
            final ours = rich?.lineStarts(w);
            if (ours == null) {
              deferred++;
              continue;
            }
            final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr))
              ..pushStyle(ui.TextStyle(fontFamily: roboto.fontFamily, fontFamilyFallback: family, fontSize: size))
              ..addText(t);
            final p = b.build()..layout(ui.ParagraphConstraints(width: w));
            final theirs = flutterLineStarts(p, t);
            if (_same(ours, theirs)) {
              same++;
              final h = rich!.height(w)!;
              if ((h - p.height).abs() < 1e-3) {
                heights++;
              } else if (examples.length < 12) {
                examples.add('height size=$size w=$w ours=$h flutter=${p.height} ${jsonEncode(t)}');
              }
            } else {
              diff++;
              if (examples.length < 12) examples.add('size=$size w=$w ours=$ours flutter=$theirs ${jsonEncode(t)}');
            }
            p.dispose();
          }
        }
      }
      out['fallback'] = {'identical': same, 'different': diff, 'deferred': deferred, 'heightsEqual': heights};
      out['examples'] = examples;
      print('FALLBACK ${jsonEncode(out['fallback'])}');
      File(env['FALLBACK_OUT'] ?? 'results/fallback.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, skip: spec == null, timeout: const Timeout(Duration(hours: 2)));
}
