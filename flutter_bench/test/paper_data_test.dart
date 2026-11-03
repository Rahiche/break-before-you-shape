// Data for the paper's figures, measured with the shipped sidecar and Flutter:
// a width decomposition of an example phrase, and float drift by font size.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:bf_bench/breakfirst.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paper data', (tester) async {
    await tester.runAsync(() async {
      await loadFont();
      final md = WidthModel.decode((await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List());

      // 1. Decomposition of an example phrase into the model's terms (units).
      const phrase = 'To office: AV', exSize = 16.0;
      final terms = <Map<String, Object?>>[];
      var i = 0, prevId = 0, prevIsl = -1;
      while (i < phrase.length) {
        final id = md.idOf[phrase.codeUnitAt(i)];
        if (md.cert[id] != certS) {
          var j = i, key = 0;
          while (j < phrase.length && md.islandDigit[md.idOf[phrase.codeUnitAt(j)]] >= 0) {
            key = key * md.keyBase + md.islandDigit[md.idOf[phrase.codeUnitAt(j)]] + 1;
            j++;
          }
          final isl = md.islandOfKey[key];
          final text = phrase.substring(i, j);
          if (prevId != 0) {
            terms.add({'kind': 'island-left', 'text': '${String.fromCharCode(md.cps[prevId])}|$text',
                'units': md.islandL[isl * md.n1 + prevId]});
          }
          terms.add({'kind': 'island', 'text': text, 'units': md.islandW[isl],
              'unitsIfSeparate': [for (final c in text.codeUnits) md.adv[md.idOf[c]]].reduce((a, b) => a + b)});
          prevId = 0;
          prevIsl = isl;
          i = j;
          continue;
        }
        if (prevId != 0) {
          final v = md.pair(prevId, id);
          if (v != 0) terms.add({'kind': 'pair', 'text': '${String.fromCharCode(md.cps[prevId])}${phrase[i]}', 'units': v});
        } else if (prevIsl >= 0) {
          final v = md.islandR[prevIsl * md.n1 + id];
          if (v != 0) terms.add({'kind': 'island-right', 'text': '…|${phrase[i]}', 'units': v});
        }
        terms.add({'kind': 'advance', 'text': phrase[i], 'units': md.adv[id]});
        prevId = id;
        prevIsl = -1;
        i++;
      }
      final modelUnits = md.widthOf(phrase);
      final flutterPx = measure(phrase, exSize);
      final sumAdvances = [for (final c in phrase.codeUnits) md.adv[md.idOf[c]]].reduce((a, b) => a + b);

      // 2. Float drift by size: single-line paragraph widths, model vs Flutter.
      final drift = <Map<String, Object?>>[];
      for (final size in [10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 18.4, 20.0, 21.3, 24.0, 28.0, 32.0, 33.7]) {
        var maxAbs = 0.0, maxRel = 0.0, maxLen = 0.0;
        for (final name in ['en_docs', 'en_man', 'ui_ru']) {
          final all = await loadCorpus(name);
          for (var k = 0; k < 300; k++) {
            final t = all[(k * all.length) ~/ 300];
            final r = buildRecords(md, t);
            if (r == null) continue;
            final mw = r.prefix[t.length] * size / md.upem, fw = measure(t, size);
            final e = (mw - fw).abs();
            if (e > maxAbs) maxAbs = e;
            if (e / fw > maxRel) maxRel = e / fw;
            if (fw > maxLen) maxLen = fw;
          }
        }
        drift.add({'size': size, 'exactPositions': exactPositions(size / md.upem, maxLen), 'maxAbsPx': maxAbs,
            'maxRel': maxRel, 'longestParagraphPx': maxLen});
      }
      File('results/paper_data.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
        'example': {'phrase': phrase, 'size': exSize, 'terms': terms, 'modelUnits': modelUnits, 'modelPxAt16': modelUnits * exSize / md.upem,
            'flutterPxAt16': flutterPx, 'sumOfAdvancesUnits': sumAdvances, 'upem': md.upem},
        'drift': drift,
      }));
      print('PAPER ok');
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}
