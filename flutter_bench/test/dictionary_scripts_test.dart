// Thai, Lao, Khmer and Burmese from the device's fallback fonts, with ICU's
// dictionary breaks: texts alone and as words inside English strings, in the bundled Roboto
// (which has none of them), against Flutter's own layout with the platform's
// fonts. SEA_CORPUS: corpus files, ':'-separated. SEA_OUT: results JSON.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart' show flutterLineStarts, loadCorpus;
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

void main() {
  final env = Platform.environment;
  final corpus = env['SEA_CORPUS'];
  testWidgets('dictionary scripts', (tester) async {
    await tester.runAsync(() async {
      const family = 'SeaRoboto';
      final font = File('assets/Roboto-Regular.ttf').readAsBytesSync();
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
      final md = buildSidecar(fontFamily: family, font: font, certificate: File('assets/roboto.cert').readAsStringSync(),
          noLigaCertificate: File('assets/roboto.nolig.cert').readAsStringSync());
      final bf = BreakFirst.load(md.encode(), fontFamily: family)!;
      await loadBundledDictionaries((k) async => ByteData.sublistView(File('../packages/break_first/$k').readAsBytesSync()));
      final en = await loadCorpus('ui_en');
      final out = <String, Object?>{};
      final examples = <String>[];
      for (final path in corpus!.split(':')) {
        final lines = File(path).readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList();
        final name = path.split('/').last.replaceAll('.txt', '');
        final mixed = [
          for (var i = 0; i < lines.length; i++)
            () {
              final w = en[(i * 7919) % en.length].split(' ');
              final x = lines[i].split(' ');
              w.insert(w.length ~/ 2, x.sublist(0, x.length.clamp(0, 2)).join(' '));
              return w.join(' ');
            }(),
        ];
        for (final (label, texts) in [(name, lines), ('$name inside English', mixed)]) {
          var same = 0, diff = 0, deferred = 0, heights = 0;
          for (final size in [13.0, 16.0, 20.0]) {
            for (final t in texts) {
              final rich = RichParagraph.prepare([RichSpan(t, bf, size)]);
              for (final w in [120.0, 200.0, 320.0]) {
                final ours = rich?.lineStarts(w);
                if (ours == null) {
                  deferred++;
                  continue;
                }
                final p = (ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr))
                      ..pushStyle(ui.TextStyle(fontFamily: family, fontSize: size))
                      ..addText(t))
                    .build()
                  ..layout(ui.ParagraphConstraints(width: w));
                final theirs = flutterLineStarts(p, t);
                if (_same(ours, theirs)) {
                  same++;
                  final h = rich!.height(w)!;
                  if ((h - p.height).abs() < 1e-3) {
                    heights++;
                  } else if (examples.length < 12) {
                    examples.add('$label height size=$size w=$w ours=$h flutter=${p.height} ${jsonEncode(t)}');
                  }
                } else {
                  diff++;
                  if (examples.length < 12) examples.add('$label size=$size w=$w ours=$ours flutter=$theirs ${jsonEncode(t)}');
                }
                p.dispose();
              }
            }
          }
          out[label] = {'texts': texts.length, 'identical': same, 'different': diff, 'deferred': deferred, 'heightsEqual': heights};
          print('SEA $label: ${jsonEncode(out[label])}');
        }
      }
      out['examples'] = examples;
      File(env['SEA_OUT'] ?? 'results/dictionary_scripts.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, skip: corpus == null, timeout: const Timeout(Duration(hours: 1)));
}
