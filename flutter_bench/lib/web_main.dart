// The benchmark on Flutter web (bench.dart needs dart:io): the shipped sidecar
// against Flutter's layout in the browser (CanvasKit, or skwasm with --wasm), then
// heights for a chat list and auto-fit sizes, timed against TextPainter. The
// result goes to the console as BFWEB lines.
//
// flutter build web --release -t lib/web_main.dart --no-web-resources-cdn
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const family = 'BFRoboto';
const corpora = ['en_docs', 'en_man', 'en_legal', 'ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el'];
const chatCorpora = ['ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el'];
const sample = int.fromEnvironment('BF_SAMPLE', defaultValue: 300);

Future<List<String>> _corpus(String name) async {
  try {
    return (await rootBundle.loadString('assets/$name.txt')).split('\n').where((p) => p.isNotEmpty).toList();
  } on FlutterError {
    return const [];
  }
}

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

double _median(List<double> xs) => (xs.toList()..sort())[xs.length ~/ 2];

Future<Map<String, Object?>> run() async {
  final out = <String, Object?>{};
  final fontData = await rootBundle.load('assets/Roboto-Regular.ttf');
  await (FontLoader(family)..addFont(Future.value(fontData))).load();
  final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
  final md = WidthModel.decode(bytes);
  calibrateEngine(md, family);
  out['fontSizeQuantized'] = quantizeFontSize;
  out['hardBreakKerns'] = hardBreakKerns;
  out['canaryErrPx'] = canaryError(md, family);
  ui.Paragraph para(String s, double w, double size) => layoutParagraph(s, fontFamily: family, fontSize: size, width: w);

  // Exactness: every corpus, 3 sizes x 6 widths, line starts and heights.
  var same = 0, diff = 0, deferred = 0, heights = 0;
  final examples = <String>[];
  for (final name in corpora) {
    final all = await _corpus(name);
    final texts = [for (var i = 0; i < sample && i < all.length; i++) all[(i * all.length) ~/ sample.clamp(1, all.length)]];
    final recs = [for (final t in texts) buildRecords(md, t)];
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
          final p = para(texts[i], w, size);
          if (_same(ours, _starts(p))) {
            same++;
            if ((ours.length * lh - p.height).abs() < 1e-3) heights++;
          } else {
            diff++;
            if (examples.length < 5) examples.add('$name size=$size w=$w ours=$ours flutter=${_starts(p)}');
          }
          p.dispose();
        }
      }
    }
  }
  out['validate'] = {'identical': same, 'different': diff, 'deferred': deferred, 'heightsEqual': heights,
      'examples': examples};

  // Heights for a chat list (16 px, 280 px), and auto-fit (largest size from 10
  // to 30 px in 0.5 px steps that keeps a message within 3 lines).
  final chat = <String>[for (final c in chatCorpora) ...await _corpus(c)];
  const w = 280.0;
  final style = const TextStyle(fontFamily: family, fontSize: 16);
  final scale = scaleFor(md, 16), lh = lineHeightPx(md, 16);
  final tpRuns = <double>[], bfRuns = <double>[];
  late List<double> tpH, bfH;
  for (var k = 0; k < 3; k++) {
    final sw = Stopwatch()..start();
    tpH = [
      for (final m in chat)
        () {
          final tp = TextPainter(text: TextSpan(text: m, style: style), textDirection: TextDirection.ltr)
            ..layout(maxWidth: w);
          final h = tp.height;
          tp.dispose();
          return h;
        }()
    ];
    tpRuns.add(sw.elapsedMicroseconds / 1000);
    sw.reset();
    bfH = [
      for (final m in chat)
        () {
          final n = buildRecords(md, m)?.lineCount(w, scale) ?? -1;
          if (n >= 0) return n * lh;
          final p = para(m, w, 16);
          final h = p.height;
          p.dispose();
          return h;
        }()
    ];
    bfRuns.add(sw.elapsedMicroseconds / 1000);
  }
  var equal = 0;
  for (var i = 0; i < chat.length; i++) {
    if ((tpH[i] - bfH[i]).abs() < 1e-3) equal++;
  }
  out['listExtents'] = {'messages': chat.length, 'textPainterMs': _median(tpRuns), 'breakFirstMs': _median(bfRuns),
      'heightsEqual': equal};

  final sizes = [for (var k = 0; k <= 40; k++) 10 + k * 0.5];
  final msgs = [for (var i = 0; i < chat.length; i += 8) chat[i]];
  double fit(bool Function(double) fits) {
    var lo = 0, hi = sizes.length - 1;
    if (!fits(sizes[lo])) return sizes[lo];
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (fits(sizes[mid])) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return sizes[lo];
  }

  bool tpFits(String m, double s) {
    final tp = TextPainter(text: TextSpan(text: m, style: TextStyle(fontFamily: family, fontSize: s)),
        textDirection: TextDirection.ltr, maxLines: 3)
      ..layout(maxWidth: w);
    final ok = !tp.didExceedMaxLines;
    tp.dispose();
    return ok;
  }

  final sw = Stopwatch()..start();
  final tpSizes = [for (final m in msgs) fit((s) => tpFits(m, s))];
  final tpMs = sw.elapsedMicroseconds / 1000;
  sw.reset();
  final bfSizes = [
    for (final m in msgs)
      () {
        final r = buildRecords(md, m);
        return fit((s) {
          final n = r?.lineCount(w, scaleFor(md, s)) ?? -1;
          return n >= 0 ? n <= 3 : tpFits(m, s);
        });
      }()
  ];
  final bfMs = sw.elapsedMicroseconds / 1000;
  var sameSize = 0;
  for (var i = 0; i < msgs.length; i++) {
    if (tpSizes[i] == bfSizes[i]) sameSize++;
  }
  out['autoFit'] = {'messages': msgs.length, 'textPainterMs': tpMs, 'breakFirstMs': bfMs, 'sameSize': sameSize};
  return out;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Directionality(textDirection: TextDirection.ltr, child: Center(child: Text('running'))));
  final result = await run();
  final json = jsonEncode(result);
  for (var i = 0; i < json.length; i += 800) {
    print('BFWEB:${i ~/ 800}:${json.substring(i, (i + 800).clamp(0, json.length))}');
  }
  print('BFWEBDONE');
  runApp(const Directionality(textDirection: TextDirection.ltr, child: Center(child: Text('done'))));
}
