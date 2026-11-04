// Right-to-left paragraphs: a right-to-left sidecar for a Hebrew font, built
// through Flutter, against Flutter's own right-to-left layout of UI strings (and
// of them joined with hard breaks), in the default style and with spacing.
//
// RTL_FONT: a font file with Hebrew. RTL_CERT: its certificate (certify.py with
// CERTIFY_SCRIPTS=latin+hebrew CERTIFY_DIRECTION=rtl), and RTL_NOLIG the same with
// CERTIFY_FEATURES_OFF=liga,clig,calt. RTL_CORPUS: one message per line. RTL_OUT:
// results JSON (default results/rtl.json). RTL_SAMPLE: at most this many messages
// (spread over the corpus). Skipped without them.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Logical line starts, from each character's line number (x = 0 is the end of
/// a right-to-left line, so the offset-at-left-edge query does not apply).
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
  final ready = env['RTL_FONT'] != null && env['RTL_CERT'] != null && env['RTL_CORPUS'] != null;
  testWidgets('right-to-left paragraphs', (tester) async {
    await tester.runAsync(() async {
      const family = 'BFRtl';
      final font = File(env['RTL_FONT']!).readAsBytesSync();
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
      final sw = Stopwatch()..start();
      final md = buildSidecar(fontFamily: family, font: font, certificate: File(env['RTL_CERT']!).readAsStringSync(),
          noLigaCertificate: env['RTL_NOLIG'] == null ? null : File(env['RTL_NOLIG']!).readAsStringSync(), rtl: true);
      final buildMs = sw.elapsedMilliseconds;
      // With RTL_LTR_CERT, also the left-to-right sidecar, for mixed-direction paragraphs.
      final ltrMd = env['RTL_LTR_CERT'] == null
          ? null
          : buildSidecar(fontFamily: family, font: font, certificate: File(env['RTL_LTR_CERT']!).readAsStringSync(),
              noLigaCertificate: env['RTL_LTR_NOLIG'] == null ? null : File(env['RTL_LTR_NOLIG']!).readAsStringSync());
      calibrateEngine(md, family);
      final canary = canaryError(md, family);
      final lines = File(env['RTL_CORPUS']!).readAsStringSync().split('\n').where((p) => p.isNotEmpty).toList();
      final sample = int.tryParse(env['RTL_SAMPLE'] ?? '') ?? lines.length;
      final all = lines.length <= sample
          ? lines
          : [for (var i = 0; i < sample; i++) lines[(i * lines.length) ~/ sample]];
      final joined = [for (var i = 0; i + 3 <= all.length; i += 3) all.sublist(i, i + 3).join('\n')];
      final out = <String, Object?>{'font': env['RTL_FONT'], 'characters': md.n1 - 1, 'buildMs': buildMs,
          'canaryErrPx': canary, 'quantized': quantizeFontSize};
      final examples = <String>[];
      const spaced = LineOptions(letterSpacing: 0.5, wordSpacing: 1);
      for (final (label, texts, o, bidi, rtl) in [
        ('messages', all, LineOptions.plain, false, true),
        ('messages joined with hard breaks', joined, LineOptions.plain, false, true),
        ('letterSpacing 0.5, wordSpacing 1', all, spaced, false, true),
        if (ltrMd != null) ...[
          ('mixed: RTL paragraphs', all, LineOptions.plain, true, true),
          ('mixed: RTL paragraphs with hard breaks', joined, LineOptions.plain, true, true),
          ('mixed: RTL paragraphs, spaced', all, spaced, true, true),
          ('mixed: LTR paragraphs', all, LineOptions.plain, true, false),
        ],
      ]) {
        var same = 0, diff = 0, deferred = 0, heights = 0;
        final recs = [
          for (final t in texts)
            bidi
                ? buildBidiRecords(ltrMd, md, t, rtlParagraph: rtl, letterSpacing: o.letterSpacing)
                : buildRecords(md, t, letterSpacing: o.letterSpacing),
        ];
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
              final p = layoutParagraph(texts[i], fontFamily: family, fontSize: size, width: w, rtl: rtl,
                  letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
              final lines = p.computeLineMetrics().length;
              final theirs = _starts(p, texts[i].length);
              // The empty last line after a trailing hard break has no character, so
              // per-character line numbers cannot show its start.
              final len = texts[i].length;
              final oursCmp = ours.length > 1 && ours.last == len ? ours.sublist(0, ours.length - 1) : ours;
              final ok = ours.length == lines &&
                  oursCmp.length == theirs.length &&
                  [for (var j = 0; j < theirs.length; j++) oursCmp[j] == theirs[j]].every((x) => x);
              if (ok) {
                same++;
                if ((ours.length * lh - p.height).abs() < 1e-3) heights++;
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
      out['examples'] = examples;
      File(env['RTL_OUT'] ?? 'results/rtl.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
      print('RTL ${jsonEncode(out..remove('examples'))}');
    });
  }, skip: !ready, timeout: const Timeout(Duration(minutes: 30)));
}
