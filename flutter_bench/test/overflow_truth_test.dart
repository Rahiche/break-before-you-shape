// Ground truth for tool/overflow_check.dart: Flutter's TextPainter, configured as
// a Text with the slot's size and maxLines at the text scale, for every case,
// compared with the check's answers. OVERFLOW_TRANSLATIONS: the strings,
// OVERFLOW_PREDICTED: the check's .bin, OVERFLOW_OUT: results JSON.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:break_first/break_first.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/overflow_check.dart' as check;

void main() {
  testWidgets('overflow check against TextPainter', (tester) async {
    await tester.runAsync(() async {
      final font = await loadFont();
      final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
      BreakFirst.load(bytes, fontFamily: family, font: font)!;
      final env = Platform.environment;
      final rows = (jsonDecode(File(env['OVERFLOW_TRANSLATIONS']!).readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      final predicted = File(env['OVERFLOW_PREDICTED']!).readAsBytesSync();
      var k = 0, same = 0, different = 0, decidedByFlutter = 0, cutAmongFlutterDecided = 0;
      var wideWord = 0, wideWordCut = 0, wideWordSplitShown = 0;
      final md = BreakFirst.registered(family)?.model ?? WidthModel.decode(bytes);
      final examples = <Object>[];
      // cut[lang][slot][scale]: strings Flutter cuts.
      final cut = {
        for (final l in check.langs) l: {for (final s in check.slots) s.$1: List.filled(check.scales.length, 0)},
      };
      final sw = Stopwatch()..start();
      for (final row in rows) {
        for (final lang in check.langs) {
          final t = row[lang] as String;
          for (final (name, size, width, maxLines) in check.slots) {
            for (var si = 0; si < check.scales.length; si++) {
              final tp = TextPainter(
                text: TextSpan(text: t, style: TextStyle(fontFamily: family, fontSize: size)),
                textDirection: TextDirection.ltr,
                textScaler: TextScaler.linear(check.scales[si]),
                maxLines: maxLines,
              )..layout(maxWidth: width);
              final truth = tp.didExceedMaxLines;
              final p = predicted[k++];
              // A word wider than the box: Flutter cuts the text, or breaks the
              // word inside on a line it shows (a line start that is no break
              // opportunity of the text).
              var splitShown = false;
              if (p == 3) {
                final r = buildRecords(md, t)!;
                final opportunities = {0, for (var j = 0; j < r.count; j++) r.nexts[j]};
                final lines = tp.computeLineMetrics();
                for (var i = 1; i < lines.length; i++) {
                  final lm = lines[i];
                  final o = tp.getPositionForOffset(Offset(0, lm.baseline - lm.ascent / 2)).offset;
                  if (!opportunities.contains(o)) splitShown = true;
                }
              }
              tp.dispose();
              if (truth) cut[lang]![name]![si]++;
              if (p == 3) {
                wideWord++;
                if (truth) wideWordCut++;
                if (splitShown) wideWordSplitShown++;
                if (truth || splitShown) {
                  same++;
                } else {
                  different++;
                  if (examples.length < 10) {
                    examples.add({'text': t, 'lang': lang, 'slot': name, 'scale': check.scales[si], 'wideWord': true});
                  }
                }
              } else if (p == 2) {
                decidedByFlutter++;
                if (truth) cutAmongFlutterDecided++;
              } else if ((p == 1) == truth) {
                same++;
              } else {
                different++;
                if (examples.length < 10) {
                  examples.add({'text': t, 'lang': lang, 'slot': name, 'scale': check.scales[si], 'flutter': truth});
                }
              }
            }
          }
        }
      }
      final out = {
        'flags': {'fontSizeQuantized': quantizeFontSize, 'hardBreakKerns': hardBreakKerns},
        'cases': k, 'checkedCases': predicted.length, 'sameAsFlutter': same, 'different': different,
        'flutterDecides': decidedByFlutter, 'cutAmongFlutterDecided': cutAmongFlutterDecided,
        'wordWiderThanBox': {'cases': wideWord, 'cut': wideWordCut, 'wordBrokenOnAShownLine': wideWordSplitShown},
        'textPainterSeconds': sw.elapsedMilliseconds / 1000, 'cutByFlutter': cut, 'examples': examples,
      };
      File(env['OVERFLOW_OUT'] ?? 'build/overflow_truth.json').writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert(out),
      );
      // ignore: avoid_print
      print(jsonEncode({for (final e in out.entries) if (e.key != 'cutByFlutter') e.key: e.value}));
      expect(k, predicted.length);
      expect(different, 0);
    });
  }, timeout: const Timeout(Duration(minutes: 60)));
}
