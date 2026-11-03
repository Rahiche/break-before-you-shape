// The Flutter font census: for every face prepared by font_census.py, build its
// sidecar through Flutter, check the canary, and compare line breaks and heights
// with Flutter's own layout, in the default style and with letter and word
// spacing plus hard line breaks. One JSON line per face goes to FONT_OUT.
//
// FONT_MANIFEST: manifest.json from font_census.py. FONT_SAMPLE: paragraphs per
// corpus (default 60). FONT_OUT: results (default results/font_census.jsonl).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart' show corpora, loadCorpus;
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _starts(ui.Paragraph p) {
  final starts = <int>[0];
  final lines = p.computeLineMetrics();
  for (var i = 1; i < lines.length; i++) {
    final lm = lines[i];
    starts.add(p.getPositionForOffset(ui.Offset(0, lm.baseline - lm.ascent / 2)).offset);
  }
  return starts;
}

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

void main() {
  final manifest = Platform.environment['FONT_MANIFEST'];
  testWidgets('font census', (tester) async {
    await tester.runAsync(() async {
      final sample = int.parse(Platform.environment['FONT_SAMPLE'] ?? '60');
      final outPath = Platform.environment['FONT_OUT'] ?? 'results/font_census.jsonl';
      final rows = (jsonDecode(File(manifest!).readAsStringSync()) as List).cast<Map<String, dynamic>>();
      final texts = <String>[], joined = <String>[];
      for (final name in corpora) {
        final all = await loadCorpus(name);
        if (all.isEmpty) continue;
        texts.addAll([for (var i = 0; i < sample && i < all.length; i++) all[(i * all.length) ~/ sample.clamp(1, all.length)]]);
        for (var i = 0; i + 3 <= all.length && i < sample * 3; i += 3) {
          joined.add(all.sublist(i, i + 3).join('\n'));
        }
      }
      final out = File(outPath).openWrite();
      for (var k = 0; k < rows.length; k++) {
        final row = rows[k];
        final result = <String, Object?>{'name': row['name'], 'source': row['source']};
        if (row['error'] != null || row['cert'] == null) {
          result['error'] = row['error'] ?? 'no certificate';
          out.writeln(jsonEncode(result));
          continue;
        }
        final cert = File(row['cert'] as String).readAsStringSync();
        final n1 = cert.split('\n').where((l) => RegExp(r'^[0-9A-F]+ \d+ [SPK]$').hasMatch(l)).length;
        result['characters'] = n1;
        if (n1 * n1 > 6000000) {
          result['error'] = 'skipped: $n1 characters (pair table over the build budget)';
          out.writeln(jsonEncode(result));
          continue;
        }
        final family = 'BFCensus$k';
        final font = File(row['font'] as String).readAsBytesSync();
        await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
        final sw = Stopwatch()..start();
        WidthModel md;
        try {
          md = buildSidecar(fontFamily: family, font: font, certificate: cert,
              noLigaCertificate: File(row['nolig'] as String).readAsStringSync());
        } catch (e) {
          result['error'] = 'build: $e';
          out.writeln(jsonEncode(result));
          continue;
        }
        result['buildMs'] = sw.elapsedMilliseconds;
        result['sidecarBytes'] = md.encode().length;
        result['noLiga'] = md.noLigaCert != null;
        calibrateFontSize(md, (s, size) => measureText(s, fontFamily: family, fontSize: size));
        final canary = canaryError(md, family);
        result['canaryErrPx'] = canary;
        // Default style.
        var same = 0, diff = 0, deferred = 0, heights = 0, covered = 0;
        final examples = <String>[];
        final recs = [for (final t in texts) buildRecords(md, t)];
        covered = recs.where((r) => r != null).length;
        for (final size in [12.0, 16.0, 21.3]) {
          final scale = scaleFor(md, size), lh = lineHeightPx(md, size);
          for (var j = 0; j < 6; j++) {
            final w = size * (9.0 + j * 36.0 / 5);
            for (var i = 0; i < texts.length; i++) {
              final ours = recs[i]?.lineStarts(w, scale);
              if (ours == null) {
                deferred++;
                continue;
              }
              final p = layoutParagraph(texts[i], fontFamily: family, fontSize: size, width: w);
              final theirs = _starts(p);
              if (_same(ours, theirs)) {
                same++;
                if ((ours.length * lh - p.height).abs() < 1e-3) {
                  heights++;
                } else if (examples.length < 3) {
                  examples.add('height size=$size ours=${ours.length * lh} flutter=${p.height}');
                }
              } else {
                diff++;
                if (examples.length < 3) examples.add('size=$size w=$w ours=$ours flutter=$theirs | ${texts[i]}');
              }
              p.dispose();
            }
          }
        }
        result['default'] = {'paragraphs': texts.length, 'covered': covered, 'identical': same, 'different': diff,
            'deferred': deferred, 'heightsEqual': heights};
        // Letter and word spacing with hard line breaks.
        const o = LineOptions(letterSpacing: 0.5, wordSpacing: 1);
        var sSame = 0, sDiff = 0, sDeferred = 0, sHeights = 0;
        final sRecs = [for (final t in joined) buildRecords(md, t, letterSpacing: o.letterSpacing)];
        for (final w in [180.0, 260.0, 340.0, 520.0]) {
          final scale = scaleFor(md, 16), lh = lineHeightPx(md, 16);
          for (var i = 0; i < joined.length; i++) {
            final ours = sRecs[i]?.lineStarts(w, scale, letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
            if (ours == null) {
              sDeferred++;
              continue;
            }
            final p = layoutParagraph(joined[i], fontFamily: family, fontSize: 16, width: w,
                letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
            if (_same(ours, _starts(p))) {
              sSame++;
              if ((ours.length * lh - p.height).abs() < 1e-3) sHeights++;
            } else {
              sDiff++;
              if (examples.length < 6) examples.add('spaced w=$w ours=$ours flutter=${_starts(p)} | ${jsonEncode(joined[i])}');
            }
            p.dispose();
          }
        }
        result['spacedWithBreaks'] = {'texts': joined.length, 'identical': sSame, 'different': sDiff,
            'deferred': sDeferred, 'heightsEqual': sHeights};
        result['examples'] = examples;
        out.writeln(jsonEncode(result));
        print('FONT ${row['name']}: default $same/${same + diff} same, $deferred deferred, heights $heights; '
            'spaced $sSame/${sSame + sDiff}; canary ${canary.toStringAsExponential(1)}');
      }
      await out.close();
    });
  }, skip: manifest == null, timeout: const Timeout(Duration(hours: 6)));
}
