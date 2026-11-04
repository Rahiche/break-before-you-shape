// Font features: for each feature set, Roboto's sidecar built through Flutter with
// those features, against Flutter's own layout with the same features, in the
// default style and with letter and word spacing plus hard line breaks.
//
// FEATURE_DIR: certificates from tool/features_check.sh, <set>.cert and
// <set>.nolig per set, where <set> is the features joined with '+' and a
// leading '-' turns a feature off (e.g. tnum, onum+ss01, -liga). FEATURE_SAMPLE:
// paragraphs per corpus (default 300). FEATURE_OUT: results JSON.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart' show corpora, flutterLineStarts, loadCorpus;
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<ui.FontFeature> _features(String set) => [
  for (final f in set.split('+'))
    f.startsWith('-') ? ui.FontFeature.disable(f.substring(1)) : ui.FontFeature.enable(f),
];

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

void main() {
  final env = Platform.environment;
  final dir = env['FEATURE_DIR'];
  testWidgets('font features', (tester) async {
    await tester.runAsync(() async {
      const family = 'BFFeatures';
      final font = File('assets/Roboto-Regular.ttf').readAsBytesSync();
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
      final sample = int.parse(env['FEATURE_SAMPLE'] ?? '300');
      final texts = <String>[], joined = <String>[];
      for (final name in corpora) {
        final all = await loadCorpus(name);
        if (all.isEmpty) continue;
        texts.addAll([for (var i = 0; i < sample && i < all.length; i++) all[(i * all.length) ~/ sample.clamp(1, all.length)]]);
        for (var i = 0; i + 3 <= all.length && i < sample * 3; i += 3) {
          joined.add(all.sublist(i, i + 3).join('\n'));
        }
      }
      final sets = Directory(dir!).listSync().map((e) => e.path).where((p) => p.endsWith('.cert')).toList()..sort();
      final out = <String, Object?>{'paragraphs': texts.length, 'joined': joined.length};
      final examples = <String>[];
      for (final certPath in sets) {
        final set = certPath.split('/').last.replaceAll('.cert', '');
        final ff = _features(set);
        final md = buildSidecar(fontFamily: family, font: font, certificate: File(certPath).readAsStringSync(),
            noLigaCertificate: File(certPath.replaceAll('.cert', '.nolig')).readAsStringSync(), fontFeatures: ff);
        calibrateEngine(md, family, fontFeatures: ff);
        final canary = canaryError(md, family, fontFeatures: ff);
        final row = <String, Object?>{'canaryErrPx': canary};
        for (final (label, list, o) in [
          ('default', texts, LineOptions.plain),
          ('letterSpacing 0.5, wordSpacing 1, hard breaks', joined, const LineOptions(letterSpacing: 0.5, wordSpacing: 1)),
        ]) {
          var same = 0, diff = 0, deferred = 0, heights = 0;
          final recs = [for (final t in list) buildRecords(md, t, letterSpacing: o.letterSpacing)];
          for (final size in [12.0, 16.0, 21.3]) {
            final scale = scaleFor(md, size), lh = lineHeightPx(md, size);
            for (var k = 0; k < 6; k++) {
              final w = size * (9.0 + k * 36.0 / 5);
              for (var i = 0; i < list.length; i++) {
                final ours = recs[i]?.lineStarts(w, scale, letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
                if (ours == null) {
                  deferred++;
                  continue;
                }
                final p = layoutParagraph(list[i], fontFamily: family, fontSize: size, width: w,
                    letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing, fontFeatures: ff);
                final theirs = flutterLineStarts(p, list[i]);
                if (_same(ours, theirs)) {
                  same++;
                  if ((ours.length * lh - p.height).abs() < 1e-3) heights++;
                } else {
                  diff++;
                  if (examples.length < 12) {
                    examples.add('$set $label size=$size w=$w ours=$ours flutter=$theirs | ${jsonEncode(list[i])}');
                  }
                }
                p.dispose();
              }
            }
          }
          row[label] = {'identical': same, 'different': diff, 'deferred': deferred, 'heightsEqual': heights};
        }
        out[set] = row;
        print('FEATURES $set: ${jsonEncode(row)}');
      }
      out['examples'] = examples;
      File(env['FEATURE_OUT'] ?? 'results/features.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, skip: dir == null, timeout: const Timeout(Duration(hours: 2)));
}
