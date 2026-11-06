// Ideas beyond answering sizes, tested against Flutter's own text stack: drawing
// a paragraph line by line from the sidecar's breaks, and text that streams in.
// Each experiment returns one JSON map.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart';

import 'bench.dart';

const _black = ui.Color(0xFF000000);

ui.Paragraph _para(String s, double size, double width, [ui.TextAlign align = ui.TextAlign.left]) =>
    (ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr, textAlign: align))
          ..pushStyle(ui.TextStyle(fontFamily: family, fontSize: size, color: _black))
          ..addText(s))
        .build()
      ..layout(ui.ParagraphConstraints(width: width));

/// The text of line [i] of [t] that starts at [starts], with its trailing spaces
/// and without the hard break that ends it.
String lineText(String t, List<int> starts, int i) {
  var e = i + 1 < starts.length ? starts[i + 1] : t.length;
  if (e > starts[i] && isHardBreak(t.codeUnitAt(e - 1))) e--;
  return t.substring(starts[i], e);
}

double _median(List<double> xs) => (xs.toList()..sort())[xs.length ~/ 2];

Future<Uint8List> _pixels(void Function(ui.Canvas) draw, double w, double h, double dpr) async {
  final rec = ui.PictureRecorder();
  draw(ui.Canvas(rec)..scale(dpr));
  final pic = rec.endRecording();
  final img = await pic.toImage((w * dpr).ceil(), (h * dpr).ceil());
  final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  img.dispose();
  pic.dispose();
  return bytes;
}

/// Pixel check: each paragraph drawn whole, and drawn as one one-line paragraph
/// per line (lines from the sidecar, each at line index × the model's line
/// height), compared byte for byte.
Future<Map<String, Object?>> pixelCheck(BreakFirst bf, {int perCorpus = 200, List<double> sizes = const [14, 16]}) async {
  final md = bf.model;
  const configs = [
    (ui.TextAlign.left, 1.0),
    (ui.TextAlign.center, 1.0),
    (ui.TextAlign.right, 1.0),
    (ui.TextAlign.left, 2.0),
    (ui.TextAlign.left, 3.0),
  ];
  final per = <String, List<int>>{for (final (a, d) in configs) '${a.name}@${d}x': [0, 0]};
  var cases = 0, identical = 0, deferred = 0, startsDiffer = 0, wrappedAlone = 0, heightDiffer = 0, lines = 0;
  var maxChannel = 0, controls = 0, controlsSeen = 0;
  final examples = <Object>[];
  final probedSame = <String, int>{}, probedDiff = <String, int>{};
  final linesAt = <String, int>{}, differentAt = <String, int>{};
  final perSize = <String, List<int>>{};
  for (final c in corpora) {
    final all = await loadCorpus(c);
    final step = math.max(1, all.length ~/ perCorpus);
    final texts = [for (var i = 0; i < all.length && i ~/ step < perCorpus; i += step) all[i]];
    for (final size in sizes) {
      final lh = lineHeightPx(md, size);
      for (final w in [150.0, 240.0, 330.0]) {
        for (final t in texts) {
          final starts = bf.lineStarts(t, fontSize: size, maxWidth: w);
          if (starts == null) {
            deferred++;
            continue;
          }
          final check = _para(t, size, w);
          if (flutterLineStarts(check, t).join(',') != starts.join(',')) startsDiffer++;
          if (check.height != starts.length * lh) heightDiffer++;
          check.dispose();
          lines += starts.length;
          for (final (align, dpr) in configs) {
            final whole = _para(t, size, w, align);
            final parts = [for (var i = 0; i < starts.length; i++) _para(lineText(t, starts, i), size, w, align)];
            for (final p in parts) {
              if (p.computeLineMetrics().length != 1) wrappedAlone++;
            }
            final h = math.max(whole.height, starts.length * lh);
            final a = await _pixels((cv) => cv.drawParagraph(whole, ui.Offset.zero), w, h, dpr);
            final b = await _pixels((cv) {
              for (var i = 0; i < parts.length; i++) {
                cv.drawParagraph(parts[i], ui.Offset(0, i * lh));
              }
            }, w, h, dpr);
            // Control: the same lines 1/8 px to the right. The check must see that.
            if (align == ui.TextAlign.left && dpr == 1.0 && t.trim().isNotEmpty) {
              final s = await _pixels((cv) {
                for (var i = 0; i < parts.length; i++) {
                  cv.drawParagraph(parts[i], ui.Offset(0.125, i * lh));
                }
              }, w, h, dpr);
              controls++;
              for (var k = 0; k < a.length; k++) {
                if (a[k] != s[k]) {
                  controlsSeen++;
                  break;
                }
              }
            }
            whole.dispose();
            for (final p in parts) {
              p.dispose();
            }
            cases++;
            final key = '${align.name}@${dpr}x';
            per[key]![0]++;
            var diff = 0, firstRow = -1;
            for (var k = 0; k < a.length; k++) {
              final d = (a[k] - b[k]).abs();
              if (d != 0) {
                diff++;
                if (firstRow < 0) firstRow = k ~/ 4 ~/ (w * dpr).ceil();
                if (d > maxChannel) maxChannel = d;
              }
            }
            // Where glyphs are: each character's box in the whole paragraph against
            // its box in its line alone, for every differing case and every 25th other.
            final probe = diff != 0 || cases % 25 == 0;
            var boxDiff = 0.0, deepest = 0.0;
            if (probe) {
              final wh = _para(t, size, w, align);
              for (var i = 0; i < starts.length; i++) {
                final s = lineText(t, starts, i);
                if (s.trim().isEmpty) continue;
                final al = _para(s, size, w, align);
                for (var j = 0; j < s.length; j++) {
                  final bw = wh.getBoxesForRange(starts[i] + j, starts[i] + j + 1);
                  final ba = al.getBoxesForRange(j, j + 1);
                  if (bw.isEmpty || ba.isEmpty) continue;
                  final d = (bw.first.left - ba.first.left).abs();
                  if (d > boxDiff) boxDiff = d;
                }
                al.dispose();
              }
              deepest = (bf.prepare(t)!.records.prefix[starts.last]) * scaleFor(md, size);
              wh.dispose();
              final bucket = boxDiff == 0 ? 'zero' : (boxDiff < 1e-3 ? 'below1e-3' : 'atLeast1e-3');
              final m = (diff == 0 ? probedSame : probedDiff);
              m[bucket] = (m[bucket] ?? 0) + 1;
            }
            // How far along the paragraph's one shaped line each line starts: every
            // line, and the first line that differs.
            final r = bf.prepare(t)!.records, sc = scaleFor(md, size);
            String far(double x) => x < 2048 ? '<2048' : (x < 4096 ? '2048-4096' : (x < 8192 ? '4096-8192' : '8192+'));
            for (final s in starts) {
              final b = '${size}px ${far(r.prefix[s] * sc)}';
              linesAt[b] = (linesAt[b] ?? 0) + 1;
            }
            if (diff != 0) {
              final ln = math.min(starts.length - 1, firstRow ~/ (lh * dpr));
              final b = '${size}px ${far(r.prefix[starts[ln]] * sc)}';
              differentAt[b] = (differentAt[b] ?? 0) + 1;
            }
            final bySize = perSize.putIfAbsent('$size', () => [0, 0]);
            bySize[0]++;
            if (diff == 0) bySize[1]++;
            if (diff == 0) {
              identical++;
              per[key]![1]++;
            } else if (examples.length < 30) {
              examples.add({
                'corpus': c, 'size': size, 'width': w, 'align': align.name, 'dpr': dpr, 'bytesDifferent': diff,
                'line': firstRow ~/ (lh * dpr), 'lines': starts.length, 'maxBoxDiffPx': boxDiff,
                'lastLineStartsAtPx': deepest, 'text': t.length > 120 ? t.substring(0, 120) : t,
              });
            }
          }
        }
      }
    }
  }
  return {
    'cases': cases, 'identical': identical, 'different': cases - identical, 'deferredParagraphs': deferred,
    'linesPerConfig': lines, 'sidecarStartsDifferFromFlutter': startsDiffer, 'heightsDiffer': heightDiffer,
    'lineWrappedWhenAlone': wrappedAlone, 'maxChannelDiff': maxChannel,
    'controlEighthPxShift': {'cases': controls, 'seenAsDifferent': controlsSeen},
    'characterBoxes': {'identicalImages': probedSame, 'differentImages': probedDiff},
    'linesByDistanceAlongShapedLine': linesAt, 'firstDifferentLineByDistance': differentAt,
    'perConfig': {for (final e in per.entries) e.key: {'cases': e.value[0], 'identical': e.value[1]}},
    'perSize': {for (final e in perSize.entries) e.key: {'cases': e.value[0], 'identical': e.value[1]}},
    'examples': examples,
  };
}

/// Text that grows at its end. Under greedy breaking, appending can only move
/// the breaks of the last lines: this re-breaks from the start of the
/// second-to-last line, and keeps every line before it.
class StreamedText {
  StreamedText(this.md, this.size, this.width) : scale = scaleFor(md, size);
  final WidthModel md;
  final double size, width, scale;
  String text = '';
  final List<int> starts = [0];

  /// The first line whose start or text the last [append] may have changed.
  int firstChanged = 0;
  int fallbacks = 0;

  void append(String token) {
    text += token;
    final keep = math.max(0, starts.length - 2), from = starts[keep];
    final s = buildRecords(md, text.substring(from))?.lineStarts(width, scale);
    starts.removeRange(keep, starts.length);
    firstChanged = keep;
    if (s == null) {
      // Flutter decides, as it does today: the whole text laid out.
      fallbacks++;
      final p = _para(text, size, width);
      starts
        ..clear()
        ..addAll(flutterLineStarts(p, text));
      p.dispose();
      firstChanged = 0;
      return;
    }
    for (final x in s) {
      starts.add(from + x);
    }
  }
}

/// Tokens as a language model streams them: a word's leading spaces with up to
/// four of its characters, the rest of a long word in pieces of four.
List<String> tokens(String t) => [for (final m in RegExp(r'\s*\S{1,4}|\s+$').allMatches(t)) m[0]!];

/// Answers of about [length] characters: corpus paragraphs joined by blank lines.
List<String> answers(List<String> paras, int length, int count) {
  final out = <String>[];
  var i = 0;
  while (out.length < count && i < paras.length) {
    final b = StringBuffer();
    while (b.length < length && i < paras.length) {
      if (b.isNotEmpty) b.write('\n\n');
      b.write(paras[i++]);
    }
    out.add(b.toString());
  }
  return out;
}

final _clock = Stopwatch()..start();

/// A streamed answer on screen: each token appended, then laid out and painted
/// (recorded into a picture, as a frame records it).
abstract class Streamer {
  void push(String token);
  void close();
}

/// One Text for the whole answer: every token lays out and paints all of it.
class WholeText implements Streamer {
  WholeText(this.size, this.width);
  final double size, width;
  String text = '';
  ui.Paragraph? p;
  @override
  void push(String token) {
    text += token;
    p?.dispose();
    p = _para(text, size, width);
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawParagraph(p!, ui.Offset.zero);
    rec.endRecording().dispose();
  }

  @override
  void close() => p?.dispose();
}

/// One Text per paragraph (between blank lines), as a Markdown view builds it:
/// a token lays out and paints its paragraph; the finished ones are a picture.
class PerParagraph implements Streamer {
  PerParagraph(this.size, this.width);
  final double size, width;
  String text = '';
  var done = 0; // characters in finished paragraphs
  var doneHeight = 0.0;
  ui.Picture? finished;
  ui.Paragraph? last;
  @override
  void push(String token) {
    text += token;
    final cut = text.lastIndexOf('\n\n');
    if (cut + 2 > done && cut >= 0) {
      // Paragraphs completed: lay them out once into the finished picture.
      final rec = ui.PictureRecorder(), cv = ui.Canvas(rec);
      if (finished != null) cv.drawPicture(finished!);
      for (final para in text.substring(done, cut).split('\n\n')) {
        final q = _para(para, size, width);
        cv.drawParagraph(q, ui.Offset(0, doneHeight));
        doneHeight += q.height;
        q.dispose();
      }
      finished?.dispose();
      finished = rec.endRecording();
      done = cut + 2;
    }
    last?.dispose();
    last = _para(text.substring(done), size, width);
    final rec = ui.PictureRecorder(), cv = ui.Canvas(rec);
    if (finished != null) cv.drawPicture(finished!);
    cv.drawParagraph(last!, ui.Offset(0, doneHeight));
    rec.endRecording().dispose();
  }

  @override
  void close() {
    finished?.dispose();
    last?.dispose();
  }
}

/// Line by line: the sidecar re-breaks the end of the text ([StreamedText]); a
/// token lays out the lines whose text changed and paints them; lines before the
/// second-to-last are final and go into a picture, 16 at a time.
class LineByLine implements Streamer {
  LineByLine(this.st, this.lh);
  final StreamedText st;
  final double lh;
  final shown = <ui.Paragraph>[];
  final shownText = <String>[];
  ui.Picture? finished;
  var doneLines = 0;
  @override
  void push(String token) {
    st.append(token);
    final n = st.starts.length;
    for (var i = st.firstChanged; i < math.max(n, shown.length); i++) {
      if (i >= n) {
        shown.removeLast().dispose();
        shownText.removeLast();
        continue;
      }
      final s = lineText(st.text, st.starts, i);
      if (i < shown.length) {
        if (shownText[i] == s) continue;
        if (i < doneLines) {
          // A final line changed (a text Flutter decided): drop the picture.
          finished?.dispose();
          finished = null;
          doneLines = 0;
        }
        shown[i].dispose();
        shown[i] = _para(s, st.size, st.width);
        shownText[i] = s;
      } else {
        shown.add(_para(s, st.size, st.width));
        shownText.add(s);
      }
    }
    final finalLines = math.max(0, n - 2);
    if (finalLines - doneLines >= 16) {
      final rec = ui.PictureRecorder(), cv = ui.Canvas(rec);
      if (finished != null) cv.drawPicture(finished!);
      for (var i = doneLines; i < finalLines; i++) {
        cv.drawParagraph(shown[i], ui.Offset(0, i * lh));
      }
      finished?.dispose();
      finished = rec.endRecording();
      doneLines = finalLines;
    }
    final rec = ui.PictureRecorder(), cv = ui.Canvas(rec);
    if (finished != null) cv.drawPicture(finished!);
    for (var i = doneLines; i < shown.length; i++) {
      cv.drawParagraph(shown[i], ui.Offset(0, i * lh));
    }
    rec.endRecording().dispose();
  }

  @override
  void close() {
    finished?.dispose();
    for (final p in shown) {
      p.dispose();
    }
  }
}

/// Streaming: every answer appended token by token. Exactness: at every step the
/// line starts and height equal Flutter's layout of the text so far. Timing: the
/// three [Streamer]s.
Future<Map<String, Object?>> streaming(BreakFirst bf, {int reps = 5}) async {
  final md = bf.model;
  const size = 16.0, width = 330.0;
  final lh = lineHeightPx(md, size);
  final docs = [...await loadCorpus('en_docs'), ...await loadCorpus('en_legal')];
  final chat = [for (final c in chatCorpora) ...await loadCorpus(c)];
  final out = <String, Object?>{'fontSize': size, 'width': width};

  // Exactness, at every token.
  {
    var steps = 0, same = 0, fallbacks = 0, heightSame = 0, answersN = 0, chars = 0;
    final examples = <Object>[];
    for (final (name, src, len, n) in [('docs', docs, 2000, 40), ('chat', chat, 2000, 40), ('docs', docs, 8000, 6)]) {
      for (final a in answers(src, len, n)) {
        answersN++;
        chars += a.length;
        final st = StreamedText(md, size, width);
        for (final tok in tokens(a)) {
          st.append(tok);
          final p = _para(st.text, size, width);
          final fl = flutterLineStarts(p, st.text);
          steps++;
          if (fl.join(',') == st.starts.join(',')) {
            same++;
          } else if (examples.length < 8) {
            examples.add({'corpus': name, 'chars': st.text.length, 'flutter': fl.length, 'ours': st.starts.length});
          }
          if (p.height == st.starts.length * lh) heightSame++;
          p.dispose();
        }
        fallbacks += st.fallbacks;
      }
    }
    out['exactness'] = {
      'answers': answersN, 'characters': chars, 'steps': steps, 'sameLineStarts': same, 'different': steps - same,
      'heightsEqual': heightSame, 'stepsFlutterDecided': fallbacks, 'examples': examples,
    };
  }

  // Timing, by answer length: the whole stream, and each token in the last tenth
  // of an answer (once the answer is long).
  final timing = <String, Object?>{};
  final makers = <String, Streamer Function()>{
    'wholeText': () => WholeText(size, width),
    'perParagraph': () => PerParagraph(size, width),
    'lineByLine': () => LineByLine(StreamedText(md, size, width), lh),
  };
  for (final (name, src, len, n) in [
    ('docs', docs, 500, 8),
    ('docs', docs, 2000, 8),
    ('docs', docs, 8000, 3),
    ('one paragraph', docs.where((p) => p.length >= 2000).toList(), 0, 8),
  ]) {
    final as = len == 0 ? src.take(n).toList() : answers(src, len, n);
    final toks = [for (final a in as) tokens(a)];
    final nTok = toks.fold<int>(0, (s, t) => s + t.length);
    final per = <String, Object?>{
      'answers': as.length, 'meanChars': as.fold<int>(0, (s, a) => s + a.length) / as.length, 'tokens': nTok,
      'meanParagraphChars': () {
        final ps = [for (final a in as) ...a.split('\n\n')];
        return ps.fold<int>(0, (s, p) => s + p.length) / ps.length;
      }(),
    };
    final total = {for (final k in makers.keys) k: <double>[]}, late = {for (final k in makers.keys) k: <double>[]};
    for (var k = 0; k < reps; k++) {
      for (final e in makers.entries) {
        var all = 0, end = 0, nEnd = 0;
        for (final ts in toks) {
          final s = e.value();
          final from = ts.length - ts.length ~/ 10;
          for (var i = 0; i < ts.length; i++) {
            final t0 = _clock.elapsedTicks;
            s.push(ts[i]);
            final d = _clock.elapsedTicks - t0;
            all += d;
            if (i >= from) {
              end += d;
              nEnd++;
            }
          }
          s.close();
        }
        total[e.key]!.add(all * 1e3 / _clock.frequency);
        late[e.key]!.add(end * 1e6 / _clock.frequency / nEnd);
      }
    }
    for (final k in makers.keys) {
      per[k] = {'streamMs': _median(total[k]!), 'usPerToken': _median(total[k]!) * 1000 / nTok,
          'usPerTokenInLastTenth': _median(late[k]!)};
    }
    per['speedupOverWholeText'] = _median(total['wholeText']!) / _median(total['lineByLine']!);
    per['speedupOverPerParagraph'] = _median(total['perParagraph']!) / _median(total['lineByLine']!);
    timing[len == 0 ? name : '$name $len'] = per;
  }
  out['timing'] = timing;
  return out;
}

/// Layout before the font arrives. Before the font is loaded: the sidecar's line
/// starts, heights and line widths, and Flutter's layout in the fallback font
/// it uses meanwhile. Then the font loads, and both are compared with Flutter's
/// layout in it. [quantize] and [hardKerns]: the platform's engine flags, which a
/// product would ship with the sidecar (checked once the font is there).
Future<Map<String, Object?>> fontLate(
  Uint8List sidecar,
  Future<void> Function() loadFont, {
  required bool quantize,
  required bool hardKerns,
  int perCorpus = 300,
}) async {
  final md = WidthModel.decode(sidecar);
  quantizeFontSize = quantize;
  hardBreakKerns = hardKerns;
  final texts = <String>[];
  for (final c in corpora) {
    final all = await loadCorpus(c);
    final step = math.max(1, all.length ~/ perCorpus);
    for (var i = 0; i < all.length && i ~/ step < perCorpus; i += step) {
      texts.add(all[i]);
    }
  }
  const sizes = [14.0, 16.0], widths = [150.0, 240.0, 330.0];
  // Line widths from the sidecar: without the trailing spaces and hard break.
  List<double> widthsOf(Records r, String t, List<int> starts, double scale) => [
    for (var i = 0; i < starts.length; i++)
      () {
        var e = i + 1 < starts.length ? starts[i + 1] : t.length;
        while (e > starts[i] && (isHardBreak(t.codeUnitAt(e - 1)) || t.codeUnitAt(e - 1) == 0x20)) {
          e--;
        }
        return (r.prefix[e] - r.prefix[starts[i]]) * scale;
      }(),
  ];
  final predicted = <(List<int>, double, List<double>)?>[];
  final fallback = <(List<int>, double)>[];
  final sw = Stopwatch()..start();
  for (final size in sizes) {
    final lh = lineHeightPx(md, size), scale = scaleFor(md, size);
    for (final w in widths) {
      for (final t in texts) {
        final r = buildRecords(md, t);
        final s = r?.lineStarts(w, scale);
        predicted.add(s == null ? null : (s, s.length * lh, widthsOf(r!, t, s, scale)));
      }
    }
  }
  final predictMs = sw.elapsedMicroseconds / 1000;
  for (final size in sizes) {
    for (final w in widths) {
      for (final t in texts) {
        final p = _para(t, size, w);
        fallback.add((flutterLineStarts(p, t), p.height));
        p.dispose();
      }
    }
  }
  await loadFont();
  final assumed = (quantizeFontSize, hardBreakKerns);
  calibrateEngine(md, family);
  final flagsRight = assumed == (quantizeFontSize, hardBreakKerns);
  final canary = canaryError(md, family);
  var k = 0, cases = 0, decided = 0, startsSame = 0, heightsSame = 0, lineWidthsWithin = 0, lineWidthsBitEqual = 0;
  var lineCount = 0, fallbackHeightChanged = 0, fallbackBreaksChanged = 0;
  var shiftSum = 0.0, shiftMax = 0.0, maxLineWidthErr = 0.0;
  final shiftByWidth = <String, double>{};
  for (final size in sizes) {
    for (final w in widths) {
      var column = 0.0;
      for (final t in texts) {
        final p = _para(t, size, w);
        final starts = flutterLineStarts(p, t), h = p.height;
        final lm = p.computeLineMetrics();
        p.dispose();
        cases++;
        final (fs, fh) = fallback[k];
        if (fh != h) fallbackHeightChanged++;
        if (fs.join(',') != starts.join(',')) fallbackBreaksChanged++;
        final d = (h - fh).abs();
        shiftSum += d;
        if (d > shiftMax) shiftMax = d;
        column += h - fh;
        final pr = predicted[k++];
        if (pr == null) continue;
        decided++;
        if (pr.$1.join(',') == starts.join(',')) startsSame++;
        if (pr.$2 == h) heightsSame++;
        for (var i = 0; i < lm.length && i < pr.$3.length; i++) {
          lineCount++;
          final e = (lm[i].width - pr.$3[i]).abs();
          if (e > maxLineWidthErr) maxLineWidthErr = e;
          if (e < 1e-3) lineWidthsWithin++;
          if (lm[i].width == pr.$3[i]) lineWidthsBitEqual++;
        }
      }
      // A column of every paragraph: how far its bottom moves when the font loads.
      shiftByWidth['${size}px@$w'] = column;
    }
  }
  return {
    'paragraphs': texts.length, 'cases': cases, 'predictMs': predictMs,
    'flagsAssumedRight': flagsRight, 'canaryErrorPx': canary,
    'today': {
      'heightChanged': fallbackHeightChanged, 'lineBreaksChanged': fallbackBreaksChanged,
      'meanAbsHeightShiftPx': shiftSum / cases, 'maxHeightShiftPx': shiftMax, 'columnBottomShiftPx': shiftByWidth,
    },
    'sidecar': {
      'decided': decided, 'lineStartsSame': startsSame, 'heightsSame': heightsSame, 'lines': lineCount,
      'lineWidthsWithin1e-3': lineWidthsWithin, 'lineWidthsBitEqual': lineWidthsBitEqual,
      'maxLineWidthErrPx': maxLineWidthErr,
    },
  };
}

/// The distance between float32 values at [x]: the resolution of a position there.
double _ulp(double x) {
  var e = 0;
  var v = x.abs();
  while (v >= 2) {
    v /= 2;
    e++;
  }
  return math.pow(2, e - 23).toDouble();
}

/// Flutter's ParagraphCache keeps the shaping of the last 128 paragraphs: lay
/// out others so that a timed layout shapes again.
void _flushParagraphCache() {
  for (var i = 0; i < 200; i++) {
    _para('flush $i', 10, 100).dispose();
  }
}

/// A long text split at its hard breaks: each paragraph's lines from the
/// sidecar, or, where the sidecar hands the paragraph back, laid out by Flutter.
class LongText {
  LongText(String t, WidthModel md, double size, double width) {
    final scale = scaleFor(md, size);
    // Each paragraph keeps its hard break: the character before it kerns with
    // it on some platforms (calibrateHardBreak). The empty line after it is the
    // next paragraph's first: dropped.
    var a = 0;
    for (;;) {
      final nl = t.indexOf('\n', a);
      final e = nl < 0 ? t.length : nl + 1;
      final s = t.substring(a, e);
      var starts = buildRecords(md, s)?.lineStarts(width, scale);
      if (starts != null && nl >= 0) starts = starts.sublist(0, starts.length - 1);
      final p = starts == null ? _para(s, size, width) : null;
      parts.add((a, s, starts, p));
      lines += starts?.length ?? p!.computeLineMetrics().length - (nl < 0 ? 0 : 1);
      if (nl < 0) break;
      a = e;
    }
  }

  /// (offset in the text, paragraph text, its line starts or null, Flutter's layout or null)
  final parts = <(int, String, List<int>?, ui.Paragraph?)>[];
  var lines = 0;
  int get handedBack => parts.where((p) => p.$4 != null).length;

  /// Line starts in the text: the sidecar's, and Flutter's where it laid out.
  List<int> lineStarts() => [
    for (final (a, s, st, p) in parts)
      ...[
        for (final x in st ?? flutterLineStarts(p!, s))
          if (x < s.length || s.isEmpty || !isHardBreak(s.codeUnitAt(s.length - 1))) a + x,
      ],
  ];

  /// Paints lines [first] to [first] + [count] at y = (line - first) × [lh]:
  /// one-line paragraphs laid out now, and Flutter's paragraphs as they are.
  void paint(ui.Canvas cv, int first, int count, double lh, double size, double width) {
    var line = 0;
    final made = <ui.Paragraph>[];
    for (final (_, s, st, p) in parts) {
      final hard = s.isNotEmpty && isHardBreak(s.codeUnitAt(s.length - 1));
      final n = st?.length ?? p!.computeLineMetrics().length - (hard ? 1 : 0);
      if (line + n > first && line < first + count) {
        if (st == null) {
          cv.drawParagraph(p!, ui.Offset(0, (line - first) * lh));
        } else {
          for (var i = math.max(0, first - line); i < n && line + i < first + count; i++) {
            final q = _para(lineText(s, st, i), size, width);
            cv.drawParagraph(q, ui.Offset(0, (line + i - first) * lh));
            made.add(q);
          }
        }
      }
      line += n;
      if (line >= first + count) break;
    }
    for (final q in made) {
      q.dispose();
    }
  }

  void dispose() {
    for (final p in parts) {
      p.$4?.dispose();
    }
  }
}

/// A long text on screen: Flutter shapes and lays out all of it and paints every
/// line; line by line, the sidecar gives every break and the exact height
/// (Flutter lays out the paragraphs it hands back), and Flutter lays out and
/// paints only the lines in the viewport. First frame (the top of the text),
/// then a jump to the middle. Exactness: line starts and height equal Flutter's.
/// Every timed layout misses Flutter's paragraph cache.
Future<Map<String, Object?>> longText(BreakFirst bf, {int reps = 7}) async {
  final md = bf.model;
  const size = 16.0, width = 330.0, viewport = 800.0;
  final lh = lineHeightPx(md, size);
  final visible = (viewport / lh).ceil() + 1;
  final paras = [...await loadCorpus('en_legal'), ...await loadCorpus('en_docs'), ...await loadCorpus('en_man')];
  final out = <String, Object?>{'fontSize': size, 'width': width, 'viewportPx': viewport, 'linesInViewport': visible};
  for (final len in [10000, 50000, 200000]) {
    final b = StringBuffer();
    for (var i = 0; b.length < len && i < paras.length; i++) {
      if (b.isNotEmpty) b.write('\n');
      b.write(paras[i]);
    }
    final t = b.toString();
    final full = _para(t, size, width);
    final fl = flutterLineStarts(full, t);
    final lt = LongText(t, md, size, width);
    final ours = lt.lineStarts();
    // Flutter laying out each paragraph alone, and where in the whole text its
    // breaks differ: how far along the text's one shaped line that paragraph
    // starts (px), and whether Flutter alone agrees with the sidecar.
    var aloneSame = 0, wholeDiffers = 0, wholeDiffersAloneAgrees = 0;
    final overfull = <Map<String, double>>[];
    var nearest = double.infinity;
    var along = 0.0;
    final scale = scaleFor(md, size);
    for (final (a, s, _, _) in lt.parts) {
      final e = a + s.length;
      final hard = s.isNotEmpty && isHardBreak(s.codeUnitAt(s.length - 1));
      final p = _para(s, size, width);
      final alone = [for (final x in flutterLineStarts(p, s)) if (!(hard && x == s.length)) a + x];
      p.dispose();
      final o = [for (final x in ours) if (x >= a && x < e) x];
      final w = [for (final x in fl) if (x >= a && x < e) x];
      if (o.join(',') == alone.join(',')) aloneSame++;
      if (o.join(',') != w.join(',')) {
        wholeDiffers++;
        if (o.join(',') == alone.join(',')) wholeDiffersAloneAgrees++;
        if (along < nearest) nearest = along;
        // Where the whole text first breaks differently: the exact width of the
        // line it made there (trailing spaces left out), against the box.
        var k = 0;
        while (k < o.length && k < w.length && o[k] == w[k]) {
          k++;
        }
        // A paragraph the sidecar hands back has no prefix: only where it is.
        final r = buildRecords(md, s);
        if (r == null) {
          overfull.add({'paragraphStartsPxAlong': along, 'handedBack': 1});
        } else {
          final ls = w[k - 1] - a, le0 = (k < w.length ? w[k] : e) - a;
          var le = le0;
          while (le > ls && (s.codeUnitAt(le - 1) == 0x20 || isHardBreak(s.codeUnitAt(le - 1)))) {
            le--;
          }
          final lineStartAlong = along + r.prefix[ls] * scale;
          overfull.add({'lineStartsPxAlong': lineStartAlong, 'exactWidthPx': (r.prefix[le] - r.prefix[ls]) * scale,
              'boxPx': width, 'float32StepThere': _ulp(lineStartAlong)});
        }
      }
      along += (buildRecords(md, s)?.prefix[s.length] ?? s.length * 600) * scale;
    }
    final exact = {
      'lines': fl.length, 'paragraphs': lt.parts.length, 'paragraphsHandedBack': lt.handedBack,
      'paragraphsSameAsFlutterAlone': aloneSame,
      'paragraphsWhereTheWholeTextBreaksDifferently': wholeDiffers,
      'ofWhichFlutterAloneAgreesWithTheSidecar': wholeDiffersAloneAgrees,
      'nearestSuchParagraphStartsPxAlong': wholeDiffers == 0 ? null : nearest,
      'wholeTextPxAlong': along, 'whereTheWholeTextDiffers': overfull,
      'lineStartsSameAsWholeText': ours.join(',') == fl.join(','), 'heightSameAsWholeText': lt.lines * lh == full.height,
    };
    full.dispose();
    lt.dispose();
    final wFirst = <double>[], wJump = <double>[], lFirst = <double>[], lBreak = <double>[], lJump = <double>[];
    for (var k = 0; k < reps; k++) {
      _flushParagraphCache();
      var sw = Stopwatch()..start();
      final p = _para(t, size, width);
      var rec = ui.PictureRecorder();
      (ui.Canvas(rec)..clipRect(const ui.Rect.fromLTWH(0, 0, width, viewport))).drawParagraph(p, ui.Offset.zero);
      rec.endRecording().dispose();
      wFirst.add(sw.elapsedMicroseconds / 1000);
      sw = Stopwatch()..start();
      rec = ui.PictureRecorder();
      final half = (p.height / 2 / lh).floor() * lh;
      (ui.Canvas(rec)..clipRect(const ui.Rect.fromLTWH(0, 0, width, viewport))).drawParagraph(p, ui.Offset(0, -half));
      rec.endRecording().dispose();
      wJump.add(sw.elapsedMicroseconds / 1000);
      p.dispose();
      _flushParagraphCache();
      sw = Stopwatch()..start();
      final l = LongText(t, md, size, width);
      lBreak.add(sw.elapsedMicroseconds / 1000);
      rec = ui.PictureRecorder();
      l.paint(ui.Canvas(rec), 0, visible, lh, size, width);
      rec.endRecording().dispose();
      lFirst.add(sw.elapsedMicroseconds / 1000);
      _flushParagraphCache();
      sw = Stopwatch()..start();
      rec = ui.PictureRecorder();
      l.paint(ui.Canvas(rec), l.lines ~/ 2, visible, lh, size, width);
      rec.endRecording().dispose();
      lJump.add(sw.elapsedMicroseconds / 1000);
      l.dispose();
    }
    out['$len'] = {
      'chars': t.length, ...exact,
      'firstFrameWholeMs': _median(wFirst), 'firstFrameLineByLineMs': _median(lFirst),
      'ofWhichBreakingMs': _median(lBreak), 'firstFrameSpeedup': _median(wFirst) / _median(lFirst),
      'jumpToMiddleWholeMs': _median(wJump), 'jumpToMiddleLineByLineMs': _median(lJump),
    };
  }
  return out;
}

/// Glyph positions against the exact ones (the sidecar's prefix, in doubles):
/// every line of long paragraphs, drawn in its paragraph and drawn alone, at
/// each size. Per line: how far along the paragraph's one shaped line it starts
/// (px), and the largest error of a character's left edge in each layout. Per
/// size: the nearest line start at which the paragraph's error is not zero.
Future<Map<String, Object?>> drift(BreakFirst bf, {List<double> sizes = const [12, 14, 16, 18.4], double width = 150}) async {
  final md = bf.model;
  final texts = [
    for (final c in ['en_legal', 'en_docs', 'en_man'])
      ...(await loadCorpus(c)).where((t) => t.length > 600).take(30),
  ];
  final out = <String, Object?>{'width': width, 'paragraphs': texts.length, 'characters': 'every 4th and the last of each line'};
  for (final size in sizes) {
    final sc = scaleFor(md, size);
    final along = <double>[], whole = <double>[], alone = <double>[];
    for (final t in texts) {
      final starts = bf.lineStarts(t, fontSize: size, maxWidth: width);
      if (starts == null) continue;
      final r = bf.prepare(t)!.records;
      final wh = _para(t, size, width);
      for (var i = 0; i < starts.length; i++) {
        final s = lineText(t, starts, i);
        if (s.trim().isEmpty) continue;
        final al = _para(s, size, width);
        var ew = 0.0, ea = 0.0;
        // Every 4th character and the last: a query on the whole paragraph costs
        // in proportion to its length, and the error grows along a line.
        for (var j = 0; j < s.length; j = j + 4 < s.length || j == s.length - 1 ? j + 4 : s.length - 1) {
          final bw = wh.getBoxesForRange(starts[i] + j, starts[i] + j + 1), ba = al.getBoxesForRange(j, j + 1);
          // Inside a ligature a character has no position of its own (NaN).
          if (bw.isNotEmpty && ba.isNotEmpty && !r.prefix[starts[i] + j].isNaN) {
            final exact = (r.prefix[starts[i] + j] - r.prefix[starts[i]]) * sc;
            ew = math.max(ew, (bw.first.left - exact).abs());
            ea = math.max(ea, (ba.first.left - exact).abs());
          }
        }
        al.dispose();
        along.add(r.prefix[starts[i]] * sc);
        whole.add(ew);
        alone.add(ea);
      }
      wh.dispose();
    }
    var firstNonzero = double.infinity;
    for (var i = 0; i < along.length; i++) {
      if (whole[i] > 0 && along[i] < firstNonzero) firstNonzero = along[i];
    }
    out['$size'] = {
      'lines': along.length, 'farthestLineStartPx': along.fold<double>(0, math.max),
      'maxWholeErrPx': whole.fold<double>(0, math.max), 'maxAloneErrPx': alone.fold<double>(0, math.max),
      'linesWithWholeErr': whole.where((e) => e > 0).length, 'linesWithAloneErr': alone.where((e) => e > 0).length,
      'nearestLineWithWholeErrPx': firstNonzero.isFinite ? firstNonzero : null,
      'alongPx': along, 'wholeErrPx': whole, 'aloneErrPx': alone,
    };
  }
  return out;
}
