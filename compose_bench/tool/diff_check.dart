// Why the same text wraps differently in Flutter and in Jetpack Compose, from the
// two sidecars of one font: each predicts its framework's line breaks, so their
// predictions say which texts wrap differently, where, and why. Checked against
// both frameworks' own layouts: Compose's on the emulator, Flutter's in
// flutter_bench/test/flutter_starts_test.dart.
//
// CACHE_DIR=/tmp/compose_widths dart run tool/diff_check.dart prepare <dir>
//   (cd ../flutter_bench && DIFF_DIR=<dir> flutter test test/flutter_starts_test.dart)
// dart run tool/diff_check.dart compare <dir> <out.json>
import 'dart:convert';
import 'dart:io';

import 'package:break_first/model.dart';
import 'package:compose_check/minikin.dart';

import 'compose_check.dart' as cc;

final _repo = Directory('${File.fromUri(Platform.script).parent.path}/../..').absolute.path;

/// 16 sp on a 420 dpi phone (density 2.625), and boxes of 128, 240, 280 and 400 dp.
const size = 42.0;
const widths = [336, 630, 735, 1050];

String _key(List<int>? s) => s == null ? '' : s.join(',');

WidthModel flutterModel() => WidthModel.decode(File('$_repo/flutter_bench/assets/roboto.bfw').readAsBytesSync());

WidthModel composeModel() {
  final cert = File('$_repo/flutter_bench/assets/roboto.cert').readAsStringSync();
  final cacheFile = File('${Platform.environment['CACHE_DIR'] ?? Directory.systemTemp.path}/widths_$size.json');
  final cache = cacheFile.existsSync()
      ? (jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()))
      : <String, double>{};
  final (md, _) = cc.distillCompose(cert, size, cache);
  cacheFile.writeAsStringSync(jsonEncode(cache));
  return md;
}

void main(List<String> args) {
  // Both engines on Android: font sizes quantized to 1/64 px (42 px is exact), and
  // each paragraph between hard breaks laid out alone. The texts have none.
  quantizeFontSize = true;
  hardBreakKerns = false;
  final dir = args[1];
  if (args[0] == 'prepare') return prepare(dir);
  compare(dir, args[2]);
}

void prepare(String dir) {
  final texts = <String>[];
  for (final c in ['ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el', 'en_docs', 'en_man', 'en_legal']) {
    final lines = File('$_repo/flutter_bench/assets/$c.txt').readAsLinesSync().where((l) => l.isNotEmpty);
    texts.addAll(c.startsWith('ui_') ? lines : lines.take(1000));
  }
  final cmd = composeModel(), fmd = flutterModel();
  final layouts = cc.job({'kind': 'layout', 'fontSize': size, 'widths': widths, 'texts': texts})['layouts'] as List;
  final fscale = scaleFor(fmd, size);
  final out = {
    'size': size, 'widths': widths, 'texts': texts,
    'composeTruth': [
      for (final per in layouts) [for (final e in per as List) [0, ...((e as List)[3] as List).cast<int>()]],
    ],
    'composePredicted': [
      for (final w in widths) [for (final t in texts) composeLineStarts(cmd, t, w).$1],
    ],
    'flutterPredicted': [
      for (final w in widths) [for (final t in texts) buildRecords(fmd, t)?.lineStarts(w.toDouble(), fscale)],
    ],
  };
  File('$dir/diff_input.json').writeAsStringSync(jsonEncode(out));
  stderr.writeln('${texts.length} texts, ${widths.length} widths: $dir/diff_input.json');
}

void compare(String dir, String outPath) {
  final input = jsonDecode(File('$dir/diff_input.json').readAsStringSync()) as Map<String, dynamic>;
  final flutterTruth = (jsonDecode(File('$dir/flutter_truth.json').readAsStringSync()) as List);
  final texts = (input['texts'] as List).cast<String>();
  final cmd = composeModel(), fmd = flutterModel();
  final fscale = scaleFor(fmd, size);
  List<int>? ints(Object? o) => o == null ? null : (o as List).cast<int>();
  var both = 0, flutterOk = 0, composeOk = 0, predictedDiffer = 0, actualDiffer = 0, agree = 0;
  var truePos = 0, falsePos = 0, falseNeg = 0;
  final causes = <String, int>{};
  final deltas = <double>[];
  final examples = <Object>[];
  for (var wi = 0; wi < widths.length; wi++) {
    final w = widths[wi];
    for (var i = 0; i < texts.length; i++) {
      final t = texts[i];
      final fp = ints((input['flutterPredicted'] as List)[wi][i]), cp = ints((input['composePredicted'] as List)[wi][i]);
      if (fp == null || cp == null) continue;
      both++;
      final ft = ints((flutterTruth[wi] as List)[i])!, ct = ints((input['composeTruth'] as List)[wi][i])!;
      if (_key(fp) == _key(ft)) flutterOk++;
      if (_key(cp) == _key(ct)) composeOk++;
      final pd = _key(fp) != _key(cp), ad = _key(ft) != _key(ct);
      if (pd) predictedDiffer++;
      if (ad) actualDiffer++;
      if (pd == ad) agree++;
      if (pd && ad) truePos++;
      if (pd && !ad) falsePos++;
      if (!pd && ad) falseNeg++;
      if (!pd) continue;
      // The first line that differs, and why: Flutter breaks after a hyphen or an
      // en dash inside a word, which Compose never does; or the two widths of the
      // longer line fall on either side of the box.
      var k = 0;
      while (k < fp.length && k < cp.length && fp[k] == cp[k]) {
        k++;
      }
      final s = fp[k - 1];
      final fEnd = k < fp.length ? fp[k] : t.length, cEnd = k < cp.length ? cp[k] : t.length;
      final String cause;
      bool afterDash(int e) => e > 0 && e < t.length && (t.codeUnitAt(e - 1) == 0x2D || t.codeUnitAt(e - 1) == 0x2013);
      if (afterDash(fEnd) && !afterDash(cEnd)) {
        cause = 'Flutter breaks after a hyphen or dash';
      } else {
        // The line the wider-fitting engine took, measured in both.
        var e = fEnd > cEnd ? fEnd : cEnd;
        while (e > s && (t.codeUnitAt(e - 1) == 0x20)) {
          e--;
        }
        final fr = buildRecords(fmd, t)!, cr = buildRecords(cmd, t)!;
        final fw = (fr.prefix[e] - fr.prefix[s]) * fscale;
        final cw = ((cr.prefix[e] - cr.prefix[s]) / unitsPerPx / quantum).roundToDouble() * quantum;
        deltas.add(cw - fw);
        cause = cw > fw ? 'Compose measures the line wider' : 'Flutter measures the line wider';
        if (examples.length < 12) {
          examples.add({'width': w, 'line': t.substring(s, e), 'flutterPx': fw, 'composePx': cw, 'flutterFits': fEnd > cEnd});
        }
      }
      causes[cause] = (causes[cause] ?? 0) + 1;
    }
  }
  // Characters: each character's advance at 42 px in both sidecars.
  final chars = <int>{for (final t in texts) ...t.runes};
  var nChars = 0, sameAdv = 0, composeWider = 0, flutterWider = 0;
  var sumAbs = 0.0, maxAbs = 0.0;
  for (final cp in chars) {
    final a = cp < fmd.idOf.length ? fmd.idOf[cp] : 0, b = cp < cmd.idOf.length ? cmd.idOf[cp] : 0;
    if (a == 0 || b == 0 || fmd.cert[a] != certS || cmd.cert[b] != certS) continue;
    nChars++;
    final f = fmd.adv[a] * fscale, c = cmd.adv[b] / unitsPerPx;
    final d = c - f;
    if (d.abs() < 1e-9) sameAdv++;
    if (d > 1e-9) composeWider++;
    if (d < -1e-9) flutterWider++;
    sumAbs += d.abs();
    if (d.abs() > maxAbs) maxAbs = d.abs();
  }
  deltas.sort();
  final out = {
    'fontSizePx': size, 'widthsPx': widths, 'texts': texts.length,
    'bothDecided': both, 'flutterPredictionsRight': flutterOk, 'composePredictionsRight': composeOk,
    'predictedToWrapDifferently': predictedDiffer, 'wrapDifferently': actualDiffer,
    'predictionAgreesWithTruth': agree, 'truePositives': truePos, 'falsePositives': falsePos, 'falseNegatives': falseNeg,
    'causes': causes,
    'lineWidthDeltaComposeMinusFlutterPx': deltas.isEmpty
        ? null
        : {'min': deltas.first, 'median': deltas[deltas.length ~/ 2], 'max': deltas.last},
    'characters': {
      'compared': nChars, 'sameAdvance': sameAdv, 'composeWider': composeWider, 'flutterWider': flutterWider,
      'meanAbsDiffPx': nChars == 0 ? 0 : sumAbs / nChars, 'maxAbsDiffPx': maxAbs,
    },
    'examples': examples,
  };
  File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  stdout.writeln(jsonEncode({for (final e in out.entries) if (e.key != 'examples') e.key: e.value}));
}
