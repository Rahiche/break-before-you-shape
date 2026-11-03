// Left-to-right scripts beyond the bundled font (CJK): a sidecar for SCRIPT_FONT,
// built through Flutter, against Flutter's own layout of UI strings, alone and
// joined with hard breaks, with and without spacing.
//
// SCRIPT_FONT: a font file. SCRIPT_CERT: its certificate (certify.py, e.g. with
// CERTIFY_SCRIPTS=latin+cjk), SCRIPT_NOLIG optionally the same with
// CERTIFY_FEATURES_OFF=liga,clig,calt. SCRIPT_CORPUS: corpus files, one message
// per line, separated by ':'. SCRIPT_OUT: results JSON. Skipped without them.
// SCRIPT_PAIR_BUDGET: the most pair layouts the sidecar build may take (default
// 5,000,000, about ten times Roboto's); a font over it is recorded as skipped.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _starts(ui.Paragraph p, int len) {
  final starts = <int>[0];
  var last = p.getLineNumberAt(0) ?? 0;
  for (var i = 1; i < len; i++) {
    final n = p.getLineNumberAt(i);
    if (n != null && n != last) {
      starts.add(i);
      last = n;
    }
  }
  return starts;
}

void main() {
  final env = Platform.environment;
  final ready = env['SCRIPT_FONT'] != null && env['SCRIPT_CERT'] != null && env['SCRIPT_CORPUS'] != null;
  testWidgets('scripts', (tester) async {
    await tester.runAsync(() async {
      const family = 'BFScript';
      final font = File(env['SCRIPT_FONT']!).readAsBytesSync();
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
      final outPath = env['SCRIPT_OUT'] ?? 'results/script.json';
      final cert = File(env['SCRIPT_CERT']!).readAsStringSync();
      final size = certificateSize(cert), budget = int.parse(env['SCRIPT_PAIR_BUDGET'] ?? '5000000');
      print('SCRIPT ${env['SCRIPT_FONT']?.split('/').last}: ${size.characters} characters, ${size.pairs} pairs to measure');
      if (size.pairs > budget) {
        File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
          'font': env['SCRIPT_FONT']?.split('/').last, 'characters': size.characters, 'pairsToMeasure': size.pairs,
          'skipped': 'pair table over the build budget (${size.pairs} pairs to measure, budget $budget)'}));
        return;
      }
      final sw = Stopwatch()..start();
      final md = buildSidecar(fontFamily: family, font: font, certificate: cert,
          noLigaCertificate: env['SCRIPT_NOLIG'] == null ? null : File(env['SCRIPT_NOLIG']!).readAsStringSync());
      final out = <String, Object?>{'font': env['SCRIPT_FONT']?.split('/').last, 'characters': md.n1 - 1,
          'pairsToMeasure': size.pairs, 'buildMs': sw.elapsedMilliseconds, 'sidecarBytes': md.encode().length,
          'pairClasses': [md.cls.length ~/ md.nS, md.nS]};
      calibrateEngine(md, family);
      out['canaryErrPx'] = canaryError(md, family);
      out['quantized'] = quantizeFontSize;
      final examples = <String>[];
      for (final path in env['SCRIPT_CORPUS']!.split(':')) {
        final all = File(path).readAsStringSync().split('\n').where((p) => p.isNotEmpty).toList();
        final joined = [for (var i = 0; i + 3 <= all.length; i += 3) all.sublist(i, i + 3).join('\n')];
        final name = path.split('/').last.replaceAll('.txt', '');
        for (final (label, texts, o) in [
          ('$name messages', all, LineOptions.plain),
          ('$name joined with hard breaks', joined, LineOptions.plain),
          ('$name letterSpacing 0.5, wordSpacing 1', all, const LineOptions(letterSpacing: 0.5, wordSpacing: 1)),
        ]) {
          var same = 0, diff = 0, deferred = 0, heights = 0;
          final recs = [for (final t in texts) buildRecords(md, t, letterSpacing: o.letterSpacing)];
          for (final size in [12.0, 16.0, 21.3]) {
            final scale = scaleFor(md, size), lh = lineHeightPx(md, size);
            for (var k = 0; k < 6; k++) {
              final w = size * (5.0 + k * 20.0 / 5);
              for (var i = 0; i < texts.length; i++) {
                final ours = recs[i]?.lineStarts(w, scale, letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
                if (ours == null) {
                  deferred++;
                  continue;
                }
                final p = layoutParagraph(texts[i], fontFamily: family, fontSize: size, width: w,
                    letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
                final lines = p.computeLineMetrics().length;
                final theirs = _starts(p, texts[i].length);
                final len = texts[i].length;
                final oursCmp = ours.length > 1 && ours.last == len ? ours.sublist(0, ours.length - 1) : ours;
                final ok = ours.length == lines &&
                    oursCmp.length == theirs.length &&
                    [for (var j = 0; j < theirs.length; j++) oursCmp[j] == theirs[j]].every((x) => x);
                if (ok) {
                  same++;
                  if ((ours.length * lh - p.height).abs() < 1e-3) {
                    heights++;
                  } else if (examples.where((x) => x.startsWith(label)).length < 3) {
                    examples.add('$label height size=$size ours=${ours.length * lh} flutter=${p.height}');
                  }
                } else {
                  diff++;
                  if (examples.where((x) => x.startsWith(label)).length < 3) {
                    examples.add('$label size=$size w=$w ours=$ours flutter=$theirs lines=$lines | ${jsonEncode(texts[i])}');
                  }
                }
                p.dispose();
              }
            }
          }
          out[label] = {'texts': texts.length, 'covered': recs.where((r) => r != null).length, 'identical': same,
              'different': diff, 'deferred': deferred, 'heightsEqual': heights};
        }
      }
      out['examples'] = examples;
      File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, skip: !ready, timeout: const Timeout(Duration(minutes: 60)));
}
