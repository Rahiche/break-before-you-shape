// Rich text: corpus paragraphs cut into one to four spans (at any position,
// inside words too) in several fonts, sizes and height multipliers, some spans
// differing only in colour, against Flutter's own layout of the same spans.
//
// RICH_FONTS: font:certificate:no-ligature certificate triples, ';' between
// fonts, used besides the bundled Roboto. Or RICH_MANIFEST (font_census.py's
// manifest) and RICH_NAMES, faces from it (default Arial, Times New Roman,
// Georgia).
// RICH_SAMPLE: paragraphs per corpus (default 200). RICH_OUT: results JSON.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart' show corpora, flutterLineStarts, loadCorpus;
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
  final manifest = env['RICH_MANIFEST'], spec = env['RICH_FONTS'];
  testWidgets('rich text', (tester) async {
    await tester.runAsync(() async {
      final fonts = <BreakFirst>[
        await _load('RichRoboto', File('assets/Roboto-Regular.ttf').readAsBytesSync(),
            File('assets/roboto.cert').readAsStringSync(), File('assets/roboto.nolig.cert').readAsStringSync()),
      ];
      if (spec != null) {
        for (final triple in spec.split(';')) {
          final [font, cert, nolig] = triple.split(':');
          fonts.add(await _load('Rich${fonts.length}', File(font).readAsBytesSync(), File(cert).readAsStringSync(),
              File(nolig).readAsStringSync()));
        }
      } else {
        final names = (env['RICH_NAMES'] ?? 'Arial,Times New Roman,Georgia').split(',');
        for (final row in (jsonDecode(File(manifest!).readAsStringSync()) as List).cast<Map<String, dynamic>>()) {
          if (!names.contains(row['name']) || row['cert'] == null) continue;
          fonts.add(await _load('Rich${fonts.length}', File(row['font'] as String).readAsBytesSync(),
              File(row['cert'] as String).readAsStringSync(), File(row['nolig'] as String).readAsStringSync()));
        }
      }
      // Styles: (font, size, height). Index 0 repeats as a colour-only change.
      final styles = <(BreakFirst, double, double?)>[
        (fonts[0], 16, null),
        (fonts[0], 21, null),
        (fonts[0], 13, 1.4),
        for (var f = 1; f < fonts.length; f++) ...[(fonts[f], 16, null), (fonts[f], 12.5, 1.2)],
      ];
      final sample = int.parse(env['RICH_SAMPLE'] ?? '200');
      final rnd = Random(7);
      final texts = <String>[];
      for (final name in corpora) {
        final all = await loadCorpus(name);
        if (all.isEmpty) continue;
        texts.addAll([for (var i = 0; i < sample && i < all.length; i++) all[(i * all.length) ~/ sample.clamp(1, all.length)]]);
      }
      final out = <String, Object?>{'paragraphs': texts.length, 'fonts': fonts.map((f) => f.model.name).toList()};
      final examples = <String>[];
      for (final (label, ls, ws) in [('rich', 0.0, 0.0), ('rich, letterSpacing 0.5, wordSpacing 1', 0.5, 1.0)]) {
        var same = 0, diff = 0, deferred = 0, heights = 0, colourOnly = 0;
        for (final t in texts) {
          // Cut points, then a style per span; a colour-only change repeats the
          // previous span's style with another colour.
          final n = 1 + rnd.nextInt(4);
          final cuts = ({for (var k = 1; k < n; k++) 1 + rnd.nextInt(max(1, t.length - 1))}.toList()..sort());
          final bounds = [0, ...cuts.where((c) => c < t.length), t.length];
          final spans = <(String, int, bool)>[]; // text, style, colour change
          for (var k = 0; k + 1 < bounds.length; k++) {
            final recolour = k > 0 && rnd.nextInt(4) == 0;
            spans.add((t.substring(bounds[k], bounds[k + 1]), recolour ? spans.last.$2 : rnd.nextInt(styles.length), recolour));
          }
          if (spans.any((s) => s.$3)) colourOnly++;
          final rich = RichParagraph.prepare([
            for (final (s, k, _) in spans) RichSpan(s, styles[k].$1, styles[k].$2, height: styles[k].$3),
          ], letterSpacing: ls, wordSpacing: ws);
          for (final w in [120.0, 180.0, 260.0, 400.0, 640.0]) {
            final ours = rich?.lineStarts(w);
            if (ours == null) {
              deferred++;
              continue;
            }
            final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr));
            for (final (s, k, recolour) in spans) {
              final (f, size, h) = styles[k];
              b
                ..pushStyle(ui.TextStyle(fontFamily: f.fontFamily, fontSize: size, height: h,
                    letterSpacing: ls == 0 ? null : ls, wordSpacing: ws == 0 ? null : ws,
                    color: recolour ? const ui.Color(0xFFCC0000) : const ui.Color(0xFF000000)))
                ..addText(s)
                ..pop();
            }
            final p = b.build()..layout(ui.ParagraphConstraints(width: w));
            final theirs = flutterLineStarts(p, t);
            if (_same(ours, theirs)) {
              same++;
              final h = rich!.height(w)!;
              if ((h - p.height).abs() < 1e-3) {
                heights++;
              } else if (examples.length < 12) {
                examples.add('$label height w=$w ours=$h flutter=${p.height} '
                    '${jsonEncode([for (final s in spans) [s.$1, s.$2]])}');
              }
            } else {
              diff++;
              if (examples.length < 12) {
                examples.add('$label w=$w ours=$ours flutter=$theirs ${jsonEncode([for (final s in spans) [s.$1, s.$2]])}');
              }
            }
            p.dispose();
          }
        }
        out[label] = {'identical': same, 'different': diff, 'deferred': deferred, 'heightsEqual': heights,
            'paragraphsWithColourOnlyChange': colourOnly};
        print('RICH $label: ${jsonEncode(out[label])}');
      }
      out['examples'] = examples;
      File(env['RICH_OUT'] ?? 'results/rich.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, skip: manifest == null && spec == null, timeout: const Timeout(Duration(hours: 2)));
}
