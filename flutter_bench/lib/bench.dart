// Experiments for the paper, run against Flutter's own text stack: building the
// sidecar, exactness (line breaks and heights) across corpora, sizes and widths,
// and timing against TextPainter, ui.Paragraph and a per-word cache. Every
// result goes into one JSON map.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart';
import 'package:break_first/break_first.dart' as pkg;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'native.dart';

const family = 'BFRoboto';
const corpora = ['en_docs', 'en_man', 'en_legal', 'ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el'];
const chatCorpora = ['ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el'];

ui.Paragraph paragraph(String s, double width, double size) =>
    layoutParagraph(s, fontFamily: family, fontSize: size, width: width);

/// Width of [s] on one line, trailing spaces included (cluster advances).
double measure(String s, double size) => measureText(s, fontFamily: family, fontSize: size);

/// Flutter's line starts, one query per line: the text position at the left edge
/// of each line. [flutterLineStartsSlow] asks every character for its line and is
/// used to check this one.
List<int> flutterLineStarts(ui.Paragraph p, String s) {
  final starts = <int>[0];
  final lines = p.computeLineMetrics();
  for (var i = 1; i < lines.length; i++) {
    final lm = lines[i];
    starts.add(p.getPositionForOffset(ui.Offset(0, lm.baseline - lm.ascent / 2)).offset);
  }
  return starts;
}

List<int> flutterLineStartsSlow(ui.Paragraph p, String s) {
  final starts = <int>[0];
  var last = p.getLineNumberAt(0) ?? 0;
  for (var i = 1; i < s.length; i++) {
    final ln = p.getLineNumberAt(i);
    if (ln != null && ln != last) {
      starts.add(i);
      last = ln;
    }
  }
  return starts;
}

Future<Uint8List> loadFont() async {
  final data = await rootBundle.load('assets/Roboto-Regular.ttf');
  await (FontLoader(family)..addFont(Future.value(data))).load();
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// A corpus, one paragraph per line; empty when this machine could not generate
/// it (tool/prepare_assets.sh).
Future<List<String>> loadCorpus(String name) async {
  try {
    return (await rootBundle.loadString('assets/$name.txt')).split('\n').where((p) => p.isNotEmpty).toList();
  } on FlutterError {
    return const [];
  }
}

/// Build step (run on the host, under flutter_tester): measure Flutter at
/// size = units per em and return the sidecar plus build statistics.
Future<(WidthModel, Map<String, Object?>)> buildSidecar() async {
  final font = await loadFont();
  final upem = upemOf(font);
  final cert = await rootBundle.loadString('assets/roboto.cert');
  final sw = Stopwatch()..start();
  var calls = 0, nonIntegral = 0;
  final noLiga = await rootBundle.loadString('assets/roboto.nolig.cert');
  final model = pkg.buildSidecar(fontFamily: family, font: font, certificate: cert, noLigaCertificate: noLiga,
      measured: (_, w) {
    calls++;
    if ((w - w.roundToDouble()).abs() > 1e-3) nonIntegral++;
  });
  final ms = sw.elapsedMilliseconds;
  final bytes = model.encode();
  return (
    model,
    {
      'font': model.name, 'upem': upem, 'characters': model.n1 - 1, 'pairClasses': [model.cls.length ~/ model.nS, model.nS],
      'islands': model.islandCount, 'm': model.m, 'layouts': calls, 'buildMs': ms, 'nonIntegralMeasurements': nonIntegral,
      'bytes': bytes.length, 'gzipBytes': gzip.encode(bytes).length, 'lineHeightUnits': model.lineHeight,
    }
  );
}

/// Canary: the shipped sidecar must reproduce Flutter's widths on this device.
Map<String, Object?> canary(WidthModel md) {
  final maxErr = canaryError(md, family);
  return {'probes': md.probes.length, 'maxErrPx': maxErr, 'pass': maxErr < 1e-3};
}

/// Exactness of line breaks and heights against Flutter's layout.
Future<Map<String, Object?>> validate(WidthModel md, {int sample = 100000, List<double>? sizes, int widthSteps = 12}) async {
  sizes ??= [12.0, 13.0, 16.0, 18.4, 21.3, 24.0];
  final out = <String, Object?>{};
  var examples = <String>[];
  var startsChecked = 0, startsDisagree = 0;
  for (final name in corpora) {
    final all = await loadCorpus(name);
    if (all.isEmpty) continue;
    final paras = all.length > sample ? [for (var i = 0; i < sample; i++) all[(i * all.length) ~/ sample]] : all;
    final records = [for (final p in paras) buildRecords(md, p)];
    var same = 0, diff = 0, deferred = 0, lines = 0, heightSame = 0, heightChecked = 0;
    final perSize = <String, List<int>>{}; // size -> [identical, different, deferred]
    var maxHeightErr = 0.0, maxWidthErr = 0.0;
    for (final size in sizes) {
      final scale = scaleFor(md, size);
      for (var k = 0; k < widthSteps; k++) {
        // Line widths from about 9 to 45 em, as a list item or column would be.
        final w = size * (9.0 + k * 36.0 / (widthSteps - 1));
        for (var i = 0; i < paras.length; i++) {
          final r = records[i];
          if (r == null) continue;
          final ours = r.lineStarts(w, scale);
          final ps = perSize.putIfAbsent('$size', () => [0, 0, 0]);
          if (ours == null) {
            deferred++;
            ps[2]++;
            continue;
          }
          final p = paragraph(paras[i], w, size);
          final theirs = flutterLineStarts(p, paras[i]);
          if (i < 150 && k % 4 == 0) {
            final slow = flutterLineStartsSlow(p, paras[i]);
            startsChecked++;
            if (slow.length != theirs.length || [for (var j = 0; j < slow.length; j++) slow[j] == theirs[j]].contains(false)) {
              startsDisagree++;
            }
          }
          lines += theirs.length;
          var eq = ours.length == theirs.length;
          for (var j = 0; eq && j < ours.length; j++) {
            eq = ours[j] == theirs[j];
          }
          if (eq) {
            same++;
            ps[0]++;
            heightChecked++;
            final hErr = (ours.length * lineHeightPx(md, size) - p.height).abs();
            if (hErr < 1e-3) heightSame++;
            if (hErr > maxHeightErr) maxHeightErr = hErr;
          } else {
            diff++;
            ps[1]++;
            if (examples.length < 10) {
              examples.add('$name size=$size w=${w.toStringAsFixed(1)} para=$i ours=$ours flutter=$theirs | '
                  '${paras[i].substring(0, paras[i].length.clamp(0, 140))}');
            }
          }
          p.dispose();
        }
      }
    }
    // Single-line widths at 16 px against Flutter.
    for (var i = 0; i < paras.length && i < 400; i++) {
      final r = records[i];
      if (r == null) continue;
      final e = (r.prefix[paras[i].length] * 16.0 / md.upem - measure(paras[i], 16.0)).abs();
      if (e > maxWidthErr) maxWidthErr = e;
    }
    final covered = records.where((r) => r != null).length;
    out[name] = {
      'paragraphs': paras.length, 'covered': covered, 'identical': same, 'different': diff, 'deferred': deferred,
      'lines': lines, 'heightIdentical': heightSame, 'heightChecked': heightChecked, 'maxHeightErrPx': maxHeightErr,
      'maxSingleLineWidthErrPx': maxWidthErr, 'perSize': perSize,
    };
  }
  out['sizes'] = sizes;
  out['widthSteps'] = widthSteps;
  out['lineStartMethodCheck'] = {'checked': startsChecked, 'disagree': startsDisagree};
  out['mismatchExamples'] = examples;
  return out;
}

/// Style options validated by [validateStyles].
const styleConfigs = {
  'hard breaks': LineOptions(),
  'letterSpacing 0.5': LineOptions(letterSpacing: 0.5),
  'letterSpacing -0.3': LineOptions(letterSpacing: -0.3),
  'wordSpacing 2': LineOptions(wordSpacing: 2),
  'height 1.3': LineOptions(height: 1.3),
  'maxLines 3': LineOptions(maxLines: 3),
  'combined': LineOptions(letterSpacing: 0.7, wordSpacing: 1.5, height: 1.2, maxLines: 4),
};

/// Exactness with style options and hard line breaks: every corpus, its
/// paragraphs joined 1 to 4 at a time with \n (multi-line messages), at 6 sizes
/// and 8 widths, against Flutter laid out with the same options.
Future<Map<String, Object?>> validateStyles(WidthModel md, {int sample = 2000}) async {
  const sizes = [12.0, 13.0, 15.0, 16.0, 18.4, 24.0];
  final out = <String, Object?>{};
  final examples = <String>[];
  final texts = <String, List<String>>{};
  for (final name in corpora) {
    final all = await loadCorpus(name);
    if (all.isEmpty) continue;
    final joined = <String>[];
    for (var i = 0, k = 0; i < all.length; k++) {
      final n = 1 + k % 4;
      joined.add(all.sublist(i, (i + n).clamp(0, all.length)).join('\n'));
      i += n;
    }
    texts[name] = joined.length > sample ? [for (var i = 0; i < sample; i++) joined[(i * joined.length) ~/ sample]] : joined;
  }
  for (final c in styleConfigs.entries) {
    final o = c.value;
    var same = 0, diff = 0, deferred = 0, heightSame = 0, checked = 0, lines = 0;
    for (final e in texts.entries) {
      final records = [for (final t in e.value) buildRecords(md, t, letterSpacing: o.letterSpacing)];
      for (final size in sizes) {
        final scale = scaleFor(md, size);
        final lh = lineHeightPx(md, size, height: o.height);
        for (var k = 0; k < 8; k++) {
          final w = size * (9.0 + k * 36.0 / 7);
          for (var i = 0; i < e.value.length; i++) {
            final t = e.value[i];
            var ours = records[i]?.lineStarts(w, scale, letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing);
            if (ours == null) {
              deferred++;
              continue;
            }
            if (o.maxLines != null && ours.length > o.maxLines!) ours = ours.sublist(0, o.maxLines!);
            final p = layoutParagraph(t, fontFamily: family, fontSize: size, width: w, letterSpacing: o.letterSpacing,
                wordSpacing: o.wordSpacing, height: o.height, maxLines: o.maxLines);
            final theirs = flutterLineStarts(p, t);
            lines += theirs.length;
            var eq = ours.length == theirs.length;
            for (var j = 0; eq && j < ours.length; j++) {
              eq = ours[j] == theirs[j];
            }
            if (eq) {
              same++;
              checked++;
              if ((ours.length * lh - p.height).abs() < 1e-3) {
                heightSame++;
              } else if (examples.where((x) => x.startsWith(c.key)).length < 3) {
                examples.add('${c.key} ${e.key} height size=$size ours=${ours.length * lh} flutter=${p.height}');
              }
            } else {
              diff++;
              if (examples.where((x) => x.startsWith(c.key)).length < 3) {
                examples.add('${c.key} ${e.key} size=$size w=${w.toStringAsFixed(1)} ours=$ours flutter=$theirs | '
                    '${t.substring(0, t.length.clamp(0, 160))}');
              }
            }
            p.dispose();
          }
        }
      }
    }
    out[c.key] = {'identical': same, 'different': diff, 'deferred': deferred, 'lines': lines,
        'heightIdentical': heightSame, 'heightChecked': checked};
  }
  out['texts'] = {for (final e in texts.entries) e.key: e.value.length};
  out['examples'] = examples;
  return out;
}

/// A per-word cache in the style of Pretext or Minikin: each word measured once
/// with ui.Paragraph, lines from cached word widths plus space widths.
class WordCache {
  WordCache(this.size);
  final double size;
  final Map<String, double> cache = {};
  late final double space = measure(' ', size);

  double word(String w) => cache[w] ??= measure(w, size);

  /// Line count, with the same break opportunities as break-first (found here,
  /// per call, as a word cache's segmentation step would).
  int lineCount(String t, double maxWidth) {
    final o = breakOpportunities(t);
    if (o == null) return -1;
    final (ends, nexts) = o;
    final count = ends.length;
    final segW = Float64List(count);
    for (var j = 0; j < count; j++) {
      segW[j] = word(t.substring(j == 0 ? 0 : nexts[j - 1], ends[j]));
    }
    var n = 1, k = 0;
    for (;;) {
      var best = -1;
      var w = 0.0;
      for (var j = k; j < count; j++) {
        if (j > k) w += (nexts[j - 1] - ends[j - 1]) * space;
        w += segW[j];
        if (fitsLine(w, maxWidth)) {
          best = j;
        } else {
          break;
        }
      }
      if (best < 0) best = k;
      if (best == count - 1) return n;
      k = best + 1;
      n++;
    }
  }
}

double _median(List<double> xs) => (xs.toList()..sort())[xs.length ~/ 2];

/// Timing: every method lays out every paragraph at one width and reports line
/// counts and heights, as a list computing item extents would.
Future<Map<String, Object?>> timing(WidthModel md, {int reps = 5}) async {
  final out = <String, Object?>{};
  Future<void> runOn(String label, List<String> all, double size, double w) async {
    final scale = scaleFor(md, size);
    final style = TextStyle(fontFamily: family, fontSize: size);
    final w2s = [w * 0.75, w * 1.25];
    // Speed is compared on the paragraphs break-first decides itself (at w and at
    // both re-wrap widths), so every method does the same work. End-to-end times
    // over all paragraphs, fallbacks included, are reported separately.
    final paras = [
      for (final p in all)
        if (() {
          final r = buildRecords(md, p);
          return r != null && r.lineCount(w, scale) >= 0 && w2s.every((x) => r.lineCount(x, scale) >= 0);
        }())
          p
    ];
    final units = paras.fold<int>(0, (a, p) => a + p.length);
    double textPainter(List<String> ps) {
      final sw = Stopwatch()..start();
      var h = 0.0;
      for (final p in ps) {
        final tp = TextPainter(text: TextSpan(text: p, style: style), textDirection: TextDirection.ltr)
          ..layout(maxWidth: w);
        h += tp.height;
        tp.dispose();
      }
      if (h < 0) stdout.writeln(h);
      return sw.elapsedMicroseconds / 1000;
    }

    double uiParagraph() {
      final sw = Stopwatch()..start();
      var h = 0.0;
      for (final p in paras) {
        final para = paragraph(p, w, size);
        h += para.height;
        para.dispose();
      }
      if (h < 0) stdout.writeln(h);
      return sw.elapsedMicroseconds / 1000;
    }

    double breakFirst(List<String> ps) {
      final sw = Stopwatch()..start();
      var h = 0.0;
      for (final p in ps) {
        final c = buildRecords(md, p)?.lineCount(w, scale) ?? -1;
        if (c >= 0) {
          h += c * lineHeightPx(md, size);
        } else {
          final para = paragraph(p, w, size); // not decided: Flutter lays it out
          h += para.height;
          para.dispose();
        }
      }
      if (h < 0) stdout.writeln(h);
      return sw.elapsedMicroseconds / 1000;
    }

    double wordCache(WordCache wc) {
      final sw = Stopwatch()..start();
      var n = 0;
      for (final p in paras) {
        n += wc.lineCount(p, w);
      }
      if (n < 0) stdout.writeln(n);
      return sw.elapsedMicroseconds / 1000;
    }

    textPainter(paras); // warm-up
    breakFirst(paras);
    final tp = _median([for (var k = 0; k < reps; k++) textPainter(paras)]);
    final up = _median([for (var k = 0; k < reps; k++) uiParagraph()]);
    final bf = _median([for (var k = 0; k < reps; k++) breakFirst(paras)]);
    final wcCold = wordCache(WordCache(size));
    final warm = WordCache(size);
    wordCache(warm);
    final wcWarm = _median([for (var k = 0; k < reps; k++) wordCache(warm)]);
    final tpAll = _median([for (var k = 0; k < reps; k++) textPainter(all)]);
    final bfAll = _median([for (var k = 0; k < reps; k++) breakFirst(all)]);
    // Word cache exactness.
    var wcSame = 0;
    for (final s in paras) {
      final p = paragraph(s, w, size);
      final flutter = p.computeLineMetrics().length;
      p.dispose();
      if (warm.lineCount(s, w) == flutter) wcSame++;
    }
    // Re-wrap at a new width: Flutter re-lays out existing paragraphs (no
    // reshaping); break-first re-runs only the greedy pass over its records; the
    // word cache re-runs its greedy pass over cached segment widths.
    final laid = [for (final p in paras) paragraph(p, w, size)];
    final recs = [for (final p in paras) buildRecords(md, p)!];
    final segs = [
      for (final p in paras)
        () {
          final (ends, nexts) = breakOpportunities(p)!;
          final sw = Float64List(ends.length), gap = Float64List(ends.length);
          for (var j = 0; j < ends.length; j++) {
            sw[j] = warm.word(p.substring(j == 0 ? 0 : nexts[j - 1], ends[j]));
            gap[j] = (nexts[j] - ends[j]) * warm.space;
          }
          return (sw, gap);
        }()
    ];
    double relayoutFlutter(double w2) {
      final sw = Stopwatch()..start();
      var h = 0.0;
      for (final p in laid) {
        p.layout(ui.ParagraphConstraints(width: w2));
        h += p.height;
      }
      if (h < 0) stdout.writeln(h);
      return sw.elapsedMicroseconds / 1000;
    }

    double relayoutBF(double w2) {
      final sw = Stopwatch()..start();
      var h = 0.0;
      for (final r in recs) {
        h += r.lineCount(w2, scale) * lineHeightPx(md, size);
      }
      if (h < 0) stdout.writeln(h);
      return sw.elapsedMicroseconds / 1000;
    }

    double relayoutWC(double w2) {
      final sw = Stopwatch()..start();
      var n = 0;
      for (final (segW, gap) in segs) {
        var lines = 1, k = 0;
        for (;;) {
          var best = -1;
          var x = 0.0;
          for (var j = k; j < segW.length; j++) {
            if (j > k) x += gap[j - 1];
            x += segW[j];
            if (fitsLine(x, w2)) {
              best = j;
            } else {
              break;
            }
          }
          if (best < 0) best = k;
          if (best == segW.length - 1) break;
          k = best + 1;
          lines++;
        }
        n += lines;
      }
      if (n < 0) stdout.writeln(n);
      return sw.elapsedMicroseconds / 1000;
    }

    final rf = _median([for (var k = 0; k < reps; k++) relayoutFlutter(w2s[k % 2])]);
    final rb = _median([for (var k = 0; k < reps; k++) relayoutBF(w2s[k % 2])]);
    final rw = _median([for (var k = 0; k < reps; k++) relayoutWC(w2s[k % 2])]);
    for (final p in laid) {
      p.dispose();
    }
    out[label] = {
      'paragraphsAll': all.length, 'paragraphs': paras.length, 'codeUnits': units, 'size': size, 'width': w,
      'textPainterMs': tp, 'uiParagraphMs': up, 'breakFirstMs': bf, 'wordCacheColdMs': wcCold, 'wordCacheWarmMs': wcWarm,
      'wordCacheIdentical': wcSame, 'wordCacheChecked': paras.length,
      'textPainterAllMs': tpAll, 'breakFirstAllMs': bfAll,
      'relayoutFlutterMs': rf, 'relayoutBreakFirstMs': rb, 'relayoutWordCacheMs': rw,
      'breakFirstNsPerCodeUnit': 1e6 * bf / units,
    };
  }

  await runOn('docs', await loadCorpus('en_docs'), 16.0, 400.0);
  final chat = <String>[for (final c in chatCorpora) ...await loadCorpus(c)];
  if (chat.isEmpty) return out;
  await runOn('chat', chat, 16.0, 280.0);

  // Exact item extents for a long chat list: every height, both ways.
  final scale = scaleFor(md, 16.0);
  final sw = Stopwatch()..start();
  final ours = [
    for (final m in chat)
      () {
        final c = buildRecords(md, m)?.lineCount(280.0, scale) ?? -1;
        if (c >= 0) return c * lineHeightPx(md, 16.0);
        final p = paragraph(m, 280.0, 16.0);
        final h = p.height;
        p.dispose();
        return h;
      }()
  ];
  final bfMs = sw.elapsedMicroseconds / 1000;
  sw.reset();
  final style = TextStyle(fontFamily: family, fontSize: 16.0);
  final theirs = [
    for (final m in chat)
      () {
        final tp = TextPainter(text: TextSpan(text: m, style: style), textDirection: TextDirection.ltr)
          ..layout(maxWidth: 280.0);
        final h = tp.height;
        tp.dispose();
        return h;
      }()
  ];
  final tpMs = sw.elapsedMicroseconds / 1000;
  var equal = 0;
  var offsetErr = 0.0, a = 0.0, b = 0.0;
  for (var i = 0; i < chat.length; i++) {
    if ((ours[i] - theirs[i]).abs() < 1e-3) equal++;
    a += ours[i];
    b += theirs[i];
    if ((a - b).abs() > offsetErr) offsetErr = (a - b).abs();
  }
  out['listExtents'] = {
    'messages': chat.length, 'breakFirstMs': bfMs, 'textPainterMs': tpMs, 'heightsEqual': equal,
    'maxScrollOffsetErrPx': offsetErr, 'totalExtentPx': b,
  };
  return out;
}

/// The FFI experiment: the C port of the breaker against the Dart one, in the
/// same release build. First every answer must match (line starts at 6 sizes and
/// 12 widths); then the same work is timed both ways. The C timings include
/// copying the paragraphs into native memory.
Future<Map<String, Object?>> nativeBench(WidthModel md, Uint8List sidecar, String libraryPath,
    {int sample = 100000, int reps = 5}) async {
  final nb = NativeBreaker(libraryPath, sidecar);
  final out = <String, Object?>{'exactness': await nativeExactness(md, nb, sample: sample)};
  await _nativeTiming(md, nb, out, reps);
  return out;
}

/// Line starts from the C port against the Dart breaker, for every paragraph (up
/// to [sample] per corpus) at 6 sizes and 12 widths.
Future<Map<String, Object?>> nativeExactness(WidthModel md, NativeBreaker nb, {int sample = 100000}) async {
  var checked = 0, mismatched = 0;
  final examples = <String>[];
  for (final name in corpora) {
    final all = await loadCorpus(name);
    if (all.isEmpty) continue;
    final paras = all.length > sample ? [for (var i = 0; i < sample; i++) all[(i * all.length) ~/ sample]] : all;
    nb.load(paras);
    final records = [for (final p in paras) buildRecords(md, p)];
    for (final size in [12.0, 13.0, 16.0, 18.4, 21.3, 24.0]) {
      final scale = scaleFor(md, size);
      for (var k = 0; k < 12; k++) {
        final w = size * (9.0 + k * 36.0 / 11);
        for (var i = 0; i < paras.length; i++) {
          final dart = records[i]?.lineStarts(w, scale);
          final c = nb.lineStarts(i, w, scale);
          checked++;
          final same = dart == null ? c == null : c != null && c.length == dart.length &&
              [for (var j = 0; j < c.length; j++) c[j] == dart[j]].every((x) => x);
          if (!same) {
            mismatched++;
            if (examples.length < 5) examples.add('$name size=$size w=$w i=$i dart=$dart c=$c');
          }
        }
      }
    }
  }
  return {'checked': checked, 'mismatched': mismatched, 'examples': examples};
}

Future<void> _nativeTiming(WidthModel md, NativeBreaker nb, Map<String, Object?> out, int reps) async {
  Future<void> runOn(String label, List<String> paras, double size, double w) async {
    final scale = scaleFor(md, size);
    final units = paras.fold<int>(0, (a, p) => a + p.length);
    double time(void Function() f) {
      f(); // warm-up
      final ms = <double>[];
      for (var k = 0; k < reps; k++) {
        final sw = Stopwatch()..start();
        f();
        ms.add(sw.elapsedMicroseconds / 1000);
      }
      return _median(ms);
    }

    var sink = 0;
    final dartMs = time(() {
      for (final p in paras) {
        sink += buildRecords(md, p)?.lineCount(w, scale) ?? -1;
      }
    });
    final copyMs = time(() => nb.load(paras));
    final batchMs = time(() {
      nb.load(paras);
      final o = nb.lineCounts(paras.length, w, scale);
      sink += o[0];
    });
    final perCallMs = time(() {
      for (final p in paras) {
        sink += nb.lineCount(p, w, scale);
      }
    });
    // Re-wrap at a new width from kept records.
    final recs = [for (final p in paras) buildRecords(md, p)];
    nb.load(paras);
    nb.prepare(paras.length);
    final w2 = w * 1.25;
    final rewrapDartMs = time(() {
      for (final r in recs) {
        sink += r?.lineCount(w2, scale) ?? -1;
      }
    });
    final rewrapCMs = time(() => sink += nb.rewrap(w2, scale)[0]);
    // The same answers both ways at this width (counts).
    nb.load(paras);
    final cCounts = Int32List.fromList(nb.lineCounts(paras.length, w, scale).sublist(0, paras.length));
    var agree = 0;
    for (var i = 0; i < paras.length; i++) {
      if ((buildRecords(md, paras[i])?.lineCount(w, scale) ?? -1) == cCounts[i]) agree++;
    }
    // End to end, as a list computing item heights: paragraphs the breaker does not
    // decide go to Flutter in both cases.
    final style = TextStyle(fontFamily: family, fontSize: size);
    final lh = lineHeightPx(md, size);
    double flutterHeight(String p) {
      final para = paragraph(p, w, size);
      final h = para.height;
      para.dispose();
      return h;
    }

    final e2eDartMs = time(() {
      var h = 0.0;
      for (final p in paras) {
        final c = buildRecords(md, p)?.lineCount(w, scale) ?? -1;
        h += c >= 0 ? c * lh : flutterHeight(p);
      }
      sink += h.toInt();
    });
    final e2eCMs = time(() {
      nb.load(paras);
      final o = nb.lineCounts(paras.length, w, scale);
      var h = 0.0;
      for (var i = 0; i < paras.length; i++) {
        h += o[i] >= 0 ? o[i] * lh : flutterHeight(paras[i]);
      }
      sink += h.toInt();
    });
    final tpMs = time(() {
      var h = 0.0;
      for (final p in paras) {
        final tp = TextPainter(text: TextSpan(text: p, style: style), textDirection: TextDirection.ltr)..layout(maxWidth: w);
        h += tp.height;
        tp.dispose();
      }
      sink += h.toInt();
    });
    if (sink == 42) stdout.writeln(sink);
    out[label] = {
      'paragraphs': paras.length, 'codeUnits': units, 'size': size, 'width': w, 'countsAgree': agree,
      'dartMs': dartMs, 'cCopyMs': copyMs, 'cBatchMs': batchMs, 'cPerCallMs': perCallMs,
      'rewrapDartMs': rewrapDartMs, 'rewrapCMs': rewrapCMs,
      'endToEndDartMs': e2eDartMs, 'endToEndCMs': e2eCMs, 'textPainterMs': tpMs,
      'dartNsPerCodeUnit': 1e6 * dartMs / units, 'cBatchNsPerCodeUnit': 1e6 * batchMs / units,
    };
  }

  await runOn('docs', await loadCorpus('en_docs'), 16.0, 400.0);
  final chat = <String>[for (final c in chatCorpora) ...await loadCorpus(c)];
  if (chat.isNotEmpty) await runOn('chat', chat, 16.0, 280.0);
}

Future<Map<String, Object?>> runApp({String mode = 'all', int sample = 100000}) async {
  final result = <String, Object?>{'platform': Platform.operatingSystem, 'mode': mode};
  await loadFont();
  final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
  final sw = Stopwatch()..start();
  final md = WidthModel.decode(bytes);
  result['sidecar'] = {'bytes': bytes.length, 'loadMs': sw.elapsedMicroseconds / 1000, 'describe': md.describe()};
  calibrateFontSize(md, measure);
  result['fontSizeQuantized'] = quantizeFontSize;
  result['canary'] = canary(md);
  if (mode == 'sizes') result['sizes'] = await sizeProbe(md);
  if (mode == 'all' || mode == 'validate') result['validate'] = await validate(md, sample: sample);
  if (mode == 'all' || mode == 'timing') result['timing'] = await timing(md);
  if (mode == 'styles') result['styles'] = await validateStyles(md, sample: sample);
  if (mode == 'native') {
    // On Android the library ships in the APK (jniLibs) and opens by name.
    final lib = Platform.environment['BF_NATIVE_LIB'] ?? (Platform.isAndroid ? 'libbreak_first.so' : null);
    if (lib == null) throw StateError('BF_NATIVE_LIB: path to the compiled native/break_first.c');
    result['native'] = await nativeBench(md, bytes, lib, sample: sample);
  }
  return result;
}

/// How Flutter's widths at a font size compare with the model's linear scaling:
/// the effective size each measurement implies.
Future<Map<String, Object?>> sizeProbe(WidthModel md) async {
  final texts = (await loadCorpus('en_docs')).take(40).toList();
  final out = <String, Object?>{};
  for (final size in [12.0, 13.0, 16.0, 17.5, 18.4, 21.3, 24.0, 15.7]) {
    final eff = <double>[];
    for (final t in texts) {
      final r = buildRecords(md, t);
      if (r == null) continue;
      eff.add(measure(t, size) / r.prefix[t.length] * md.upem);
    }
    eff.sort();
    out['$size'] = {'minEffectiveSize': eff.first, 'maxEffectiveSize': eff.last};
  }
  return out;
}
