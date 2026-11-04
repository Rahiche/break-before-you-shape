// Dictionary line breaks (Thai, Lao, Khmer, Burmese) against Flutter itself.
//
//  1. The bundled dictionaries are the bytes of the engine's icudtl.dat.
//  2. Word iterator: on every run of SA characters, the word boundaries Flutter
//     reports (ui.Paragraph.getWordBoundary) equal dictionaryWordBreaks.
//  3. Acceptance, line breaking: texts made only of SA characters, spaces, ASCII
//     letters and digits and U+200B (whose other opportunities are simple: after
//     a run of spaces, after U+200B) are laid out at several sizes and widths. A
//     greedy first fit over our opportunities, with widths that Flutter itself
//     measured (grapheme bounds of the paragraph laid out on one line), must give
//     Flutter's line starts. Not compared, but counted: layouts with a word wider
//     than the line (Flutter then breaks inside it), and fit decisions within
//     0.002 px of the edge or depending on a position inside a grapheme (whose x
//     dart:ui does not report).
//     SkParagraph only breaks between its glyph clusters (HarfBuzz clusters,
//     monotone characters), which are not graphemes: an opportunity inside a
//     grapheme may or may not be taken. When the greedy result depends on such
//     opportunities, it is run both ways; the layout counts as identical if
//     Flutter matches either (reported separately). Every dictionary opportunity
//     inside a grapheme must be flagged by breakMayBeInsideGrapheme.
//  4. All texts, any characters: every line start Flutter puts strictly inside a
//     run of SA characters must be one of ours, unless the word around it is wider
//     than the line (a forced break inside a word).
//
// Corpora: DICT_CORPORA (default ../corpora, from `make_corpora.py ../corpora
// sea`): ui_th, names_*, vocab_*. Fonts: macOS system fonts. Results: DICT_OUT
// (default results/dictionary_break.json). DICT_LIMIT caps texts per corpus.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart' show fitsLine;
import 'package:break_first/src/dictionary_break.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _fonts = {
  'th': ['/System/Library/Fonts/Supplemental/Tahoma.ttf'],
  'lo': ['/System/Library/Fonts/Supplemental/Lao Sangam MN.ttf'],
  'km': ['/System/Library/Fonts/Supplemental/Khmer Sangam MN.ttf'],
  'my': ['/System/Library/Fonts/NotoSansMyanmar.ttc', '/System/Library/Fonts/Supplemental/Myanmar Sangam MN.ttc'],
};

ui.Paragraph _layout(String text, String family, double size, double width) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: family, fontSize: size))
    ..pushStyle(ui.TextStyle(fontFamily: family, fontSize: size))
    ..addText(text);
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

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

/// Maximal runs of SA characters.
List<(int, int)> _saRuns(String t) {
  final runs = <(int, int)>[];
  var i = 0;
  while (i < t.length) {
    if (!isComplexContext(t.codeUnitAt(i))) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < t.length && isComplexContext(t.codeUnitAt(j))) {
      j++;
    }
    runs.add((i, j));
    i = j;
  }
  return runs;
}

bool _simple(String t) {
  for (var i = 0; i < t.length; i++) {
    final c = t.codeUnitAt(i);
    final ok = dictionaryScriptOf(c) != null ||
        c == 0x20 ||
        c == 0x200B ||
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A);
    if (!ok) return false;
  }
  return t.isNotEmpty && t.codeUnitAt(0) != 0x20 && t.codeUnitAt(t.length - 1) != 0x20;
}

/// x of every position of [t] laid out on one line, as bounds: positions inside a
/// grapheme get the bounds of that grapheme. Null when not left to right.
(Float64List, Float64List)? _positions(String t, String family, double size) {
  final p = _layout(t, family, size, 1e7);
  final lo = Float64List(t.length + 1)..fillRange(0, t.length + 1, double.nan);
  final hi = Float64List(t.length + 1)..fillRange(0, t.length + 1, double.nan);
  var i = 0;
  var ok = true;
  while (i < t.length) {
    final g = p.getGlyphInfoAt(i);
    if (g == null || g.writingDirection != ui.TextDirection.ltr) {
      ok = false;
      break;
    }
    final r = g.graphemeClusterCodeUnitRange, b = g.graphemeClusterLayoutBounds;
    if (r.start != i || r.end <= i) {
      ok = false;
      break;
    }
    lo[r.start] = hi[r.start] = b.left;
    lo[r.end] = hi[r.end] = b.right;
    for (var k = r.start + 1; k < r.end; k++) {
      lo[k] = b.left;
      hi[k] = b.right;
    }
    i = r.end;
  }
  p.dispose();
  return ok ? (lo, hi) : null;
}

class _Stats {
  int texts = 0, layouts = 0, same = 0, different = 0, deferredLong = 0, deferredEdge = 0;
  int opportunities = 0, insideGrapheme = 0, insideTaken = 0, insideIgnored = 0, noPositions = 0;
  int flagged = 0, insideNotFlagged = 0;
  final examples = <String>[], insideExamples = <String>[];
  Map<String, Object> toJson() => {
    'texts': texts,
    'layouts': layouts,
    'identical': same,
    'different': different,
    'identicalTakingBreaksInsideGraphemes': insideTaken,
    'identicalIgnoringBreaksInsideGraphemes': insideIgnored,
    'deferredWordWiderThanLine': deferredLong,
    'deferredEdgeOrInsideGrapheme': deferredEdge,
    'sizesWithoutPositions': noPositions,
    'flaggedByBreakMayBeInsideGrapheme': flagged,
    'insideGraphemeNotFlagged': insideNotFlagged,
    'dictionaryOpportunities': opportunities,
    'dictionaryOpportunitiesInsideGraphemes': insideGrapheme,
    'insideGraphemeExamples': insideExamples,
    'examples': examples,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final corpusDir = env['DICT_CORPORA'] ?? '../corpora';
  final limit = int.tryParse(env['DICT_LIMIT'] ?? '') ?? 1 << 30;
  final outPath = env['DICT_OUT'] ?? 'results/dictionary_break.json';
  final results = <String, Object>{};

  setUpAll(() async {
    unloadDictionaries();
    await loadBundledDictionaries((k) => rootBundle.load('packages/break_first/$k'));
  });

  tearDownAll(() {
    File(outPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(results));
  });

  test('bundled dictionaries are the bytes of icudtl.dat', () async {
    final flutter = env['FLUTTER_ROOT'] ?? '${env['HOME']}/development/flutter';
    final dat = File('$flutter/bin/cache/artifacts/engine/darwin-x64/icudtl.dat');
    if (!dat.existsSync()) {
      markTestSkipped('no icudtl.dat at ${dat.path}');
      return;
    }
    final bytes = dat.readAsBytesSync();
    for (final asset in dictionaryAssets.values) {
      final ours = (await rootBundle.load('packages/break_first/$asset')).buffer.asUint8List();
      final name = asset.split('/').last;
      final at = _indexOf(bytes, ours);
      expect(at, greaterThan(0), reason: '$name not found in icudtl.dat');
      results['asset $name'] = {'bytes': ours.length, 'offsetInIcudtl': at};
    }
    for (final s in DictionaryScript.values) {
      expect(hasDictionary(s), isTrue);
    }
  });

  test('examples, and the edges of the API', () async {
    String seg(String t) {
      final b = dictionaryBreaks(t, 0, t.length)!;
      return [for (var i = 0; i <= b.length; i++) t.substring(i == 0 ? 0 : b[i - 1], i == b.length ? t.length : b[i])]
          .join('|');
    }

    expect(seg('ภาษาไทยเป็นภาษาที่สวยงาม'), 'ภาษา|ไทย|เป็น|ภาษา|ที่|สวยงาม');
    expect(seg('ไปๆมาๆ'), 'ไปๆ|มาๆ'); // MAI YAMOK joins the word before it
    expect(seg('ไทย'), 'ไทย'); // Thai: under 5 code points, never split
    // Lao, Khmer, Burmese: under 4 native units. Line iterator (UTF-8): 2
    // characters are enough; word iterator (UTF-16): 4 are needed.
    const lao = 'ກິນເຂົ້າ';
    expect(dictionaryBreaks(lao, 0, lao.length), isNotNull);
    // The run must be maximal.
    const t = 'ภาษาไทย ภาษาไทย';
    expect(dictionaryBreaks(t, 0, 7), [4]);
    expect(dictionaryBreaks(t, 0, 5), isNull);
    expect(dictionaryBreaks(t, 1, 7), isNull);
    // No break where the script changes inside one run; none for SA scripts
    // without a dictionary.
    const mixed = 'ภาษาไทยເຂົ້າໜຽວ';
    expect(dictionaryBreaks(mixed, 0, mixed.length)!.contains(7), isFalse);
    expect(dictionaryBreaks('ᨠᨡᨣᨤᨥᨦ', 0, 6), isEmpty);
    // Hard line breaks: SkParagraph takes them from the text, so dictionary breaks
    // in the rule segment that ends with one stay soft.
    final family = await _loadFont('th');
    const h = 'ภาษาไทยเป็นภาษาที่สวยงาม\nภาษาไทย';
    final p = _layout(h, family!, 16, 1e5);
    expect(_starts(p, h.length), [0, 25]);
  });

  test('word boundaries: dictionaryWordBreaks on every SA run', () async {
    final out = <String, Object>{};
    for (final lang in _fonts.keys) {
      final family = await _loadFont(lang);
      if (family == null) continue;
      for (final f in _corpora(corpusDir, lang)) {
        final texts = _read(f, limit);
        var runs = 0, chars = 0, diff = 0, skipped = 0;
        final ex = <String>[];
        for (final t in texts) {
          final saRuns = _saRuns(t);
          if (saRuns.isEmpty) continue;
          final p = _layout(t, family, 16, 1e6);
          final w = <int>{};
          for (var i = 0; i < t.length;) {
            final r = p.getWordBoundary(TextPosition(offset: i));
            w
              ..add(r.start)
              ..add(r.end);
            i = r.end > i ? r.end : i + 1;
          }
          p.dispose();
          for (final (a, b) in saRuns) {
            final ours = dictionaryWordBreaks(t, a, b);
            if (ours == null) {
              skipped++;
              continue;
            }
            final theirs = [for (final x in w.toList()..sort()) if (x > a && x < b) x];
            runs++;
            chars += b - a;
            if (!_eq(ours, theirs)) {
              diff++;
              if (ex.length < 10) ex.add('ours=$ours flutter=$theirs ${jsonEncode(t.substring(a, b))}');
            }
          }
        }
        final name = f.split('/').last;
        out[name] = {'runs': runs, 'characters': chars, 'different': diff, 'skipped': skipped, 'examples': ex};
        // ignore: avoid_print
        print('word $name: $runs runs, $chars characters, $diff different, $skipped skipped');
      }
    }
    results['wordBoundaries'] = out;
    expect(out.values.every((v) => (v as Map)['different'] == 0), isTrue, reason: jsonEncode(out));
  }, timeout: const Timeout(Duration(minutes: 60)));

  test('line breaks: greedy fit over our opportunities gives Flutter\'s lines', () async {
    final out = <String, Object>{};
    for (final lang in _fonts.keys) {
      final family = await _loadFont(lang);
      if (family == null) continue;
      for (final f in _corpora(corpusDir, lang)) {
        final st = _Stats();
        for (final t in _read(f, limit).where(_simple)) {
          st.texts++;
          // Opportunities: (line content end, next line start).
          final ops = <(int, int)>[];
          var spaceRun = -1;
          for (var i = 0; i < t.length; i++) {
            final c = t.codeUnitAt(i);
            if (c == 0x20) {
              if (spaceRun < 0) spaceRun = i;
              continue;
            }
            if (spaceRun >= 0) {
              final zw = spaceRun > 0 && t.codeUnitAt(spaceRun - 1) == 0x200B;
              if (!zw) ops.add((spaceRun, i)); // SP ÷ (LB18)
              spaceRun = -1;
            }
            if (c == 0x200B) {
              var j = i + 1;
              while (j < t.length && t.codeUnitAt(j) == 0x20) {
                j++;
              }
              if (j < t.length) ops.add((i + 1, j)); // ZW SP* ÷ (LB8)
            }
          }
          final dict = <int>[];
          for (final (a, b) in _saRuns(t)) {
            dict.addAll(dictionaryBreaks(t, a, b)!);
          }
          ops
            ..addAll([for (final d in dict) (d, d)])
            ..sort((p, q) => p.$2.compareTo(q.$2))
            ..add((t.length, t.length));
          for (final size in [13.0, 16.0, 21.3]) {
            final pos = _positions(t, family, size);
            if (pos == null) {
              st.noPositions++;
              continue;
            }
            final (lo, hi) = pos;
            bool inside(int i) => lo[i] != hi[i];
            if (size == 16.0) {
              st.opportunities += dict.length;
              for (final d in dict) {
                if (breakMayBeInsideGrapheme(t, d)) st.flagged++;
                if (!inside(d)) continue;
                st.insideGrapheme++;
                if (!breakMayBeInsideGrapheme(t, d)) st.insideNotFlagged++;
                if (st.insideExamples.length < 6) {
                  final a = d - 6 < 0 ? 0 : d - 6, b = d + 6 > t.length ? t.length : d + 6;
                  st.insideExamples.add(jsonEncode('${t.substring(a, d)}|${t.substring(d, b)}'));
                }
              }
            }
            final outside = [
              for (final o in ops)
                if (!inside(o.$1) && !inside(o.$2)) o,
            ];
            for (var k = 0; k < 6; k++) {
              final width = size * (6.0 + k * 5.0);
              st.layouts++;
              final all = _greedy(ops, lo, hi, width);
              final some = outside.length == ops.length ? all : _greedy(outside, lo, hi, width);
              if (all == null && some == null) {
                st.deferredLong++;
                continue;
              }
              if (all == null || some == null || all.isEmpty || some.isEmpty) {
                st.deferredEdge++;
                continue;
              }
              final p = _layout(t, family, size, width);
              final theirs = _starts(p, t.length);
              p.dispose();
              final takeAll = _eq(all, theirs), takeSome = _eq(some, theirs);
              if (takeAll && takeSome) {
                st.same++;
              } else if (takeAll || takeSome) {
                st.same++;
                if (takeAll) st.insideTaken++;
                if (takeSome) st.insideIgnored++;
              } else {
                st.different++;
                if (st.examples.length < 10) {
                  st.examples.add('size=$size w=$width ours=$all ($some) flutter=$theirs ${jsonEncode(t)}');
                }
              }
            }
          }
        }
        final name = f.split('/').last;
        out[name] = st.toJson();
        // ignore: avoid_print
        print('lines $name: ${st.texts} texts, ${st.layouts} layouts, ${st.same} identical '
            '(${st.insideTaken} taking, ${st.insideIgnored} ignoring breaks inside graphemes), ${st.different} '
            'different, ${st.deferredLong} + ${st.deferredEdge} deferred; ${st.opportunities} dictionary '
            'opportunities, ${st.insideGrapheme} inside graphemes');
      }
    }
    results['lineBreaks'] = out;
    expect(out.values.every((v) => (v as Map)['different'] == 0), isTrue, reason: jsonEncode(out));
    expect(out.values.every((v) => (v as Map)['insideGraphemeNotFlagged'] == 0), isTrue, reason: jsonEncode(out));
  }, timeout: const Timeout(Duration(minutes: 120)));

  test('line starts inside SA runs, any text', () async {
    final out = <String, Object>{};
    for (final lang in _fonts.keys) {
      final family = await _loadFont(lang);
      if (family == null) continue;
      for (final f in _corpora(corpusDir, lang)) {
        var texts = 0, layouts = 0, inside = 0, ok = 0, forced = 0, bad = 0;
        final ex = <String>[];
        for (final t in _read(f, limit)) {
          final runs = _saRuns(t);
          if (runs.isEmpty) continue;
          texts++;
          final dict = <int, (int, int, List<int>)>{};
          for (final (a, b) in runs) {
            final d = dictionaryBreaks(t, a, b)!;
            for (var i = a + 1; i < b; i++) {
              dict[i] = (a, b, d);
            }
          }
          for (final size in [13.0, 16.0]) {
            (Float64List, Float64List)? pos;
            for (var k = 0; k < 6; k++) {
              final width = size * (4.0 + k * 5.0);
              final p = _layout(t, family, size, width);
              final starts = _starts(p, t.length);
              p.dispose();
              layouts++;
              for (final s in starts) {
                final r = dict[s];
                if (r == null) continue;
                inside++;
                final (a, b, d) = r;
                if (d.contains(s)) {
                  ok++;
                  continue;
                }
                // A forced break inside a word: the word around s must be wider
                // than the line. It is at least the dictionary segment around s;
                // at the run's ends it may go on (no break between SA and most
                // punctuation, digits or Latin), and across spaces before closing
                // punctuation or after opening punctuation (LB13, LB14).
                pos ??= _positions(t, family, size);
                var lo = [a, ...d.where((v) => v < s)].last;
                var hi = [...d.where((v) => v > s), b].first;
                if (lo == a) lo = _wordStart(t, lo);
                if (hi == b) hi = _wordEnd(t, hi);
                final wseg = pos == null ? double.infinity : pos.$2[hi] - pos.$1[lo];
                if (wseg > width) {
                  forced++;
                } else {
                  bad++;
                  if (ex.length < 10) ex.add('size=$size w=$width s=$s ours=$d flutter=$starts ${jsonEncode(t)}');
                }
              }
            }
          }
        }
        final name = f.split('/').last;
        out[name] = {
          'texts': texts,
          'layouts': layouts,
          'lineStartsInsideSA': inside,
          'atOurOpportunities': ok,
          'forcedInsideWord': forced,
          'unexplained': bad,
          'examples': ex,
        };
        // ignore: avoid_print
        print('starts $name: $texts texts, $layouts layouts, $inside line starts inside SA runs: $ok ours, '
            '$forced forced, $bad unexplained');
      }
    }
    results['lineStartsInsideRuns'] = out;
    expect(out.values.every((v) => (v as Map)['unexplained'] == 0), isTrue, reason: jsonEncode(out));
  }, timeout: const Timeout(Duration(minutes: 120)));
}

const _closing = ')]}!?,.:;/%';
const _opening = '([{';

int _wordStart(String t, int i) {
  for (;;) {
    while (i > 0 && t.codeUnitAt(i - 1) != 0x20 && t.codeUnitAt(i - 1) != 0x200B) {
      i--;
    }
    var j = i;
    while (j > 0 && t.codeUnitAt(j - 1) == 0x20) {
      j--;
    }
    if (j == i || j == 0) return i;
    if (_closing.contains(t[i]) || _opening.contains(t[j - 1])) {
      i = j;
      continue;
    }
    return i;
  }
}

int _wordEnd(String t, int i) {
  for (;;) {
    while (i < t.length && t.codeUnitAt(i) != 0x20 && t.codeUnitAt(i) != 0x200B) {
      i++;
    }
    var j = i;
    while (j < t.length && t.codeUnitAt(j) == 0x20) {
      j++;
    }
    if (j == i || j == t.length) return i;
    if (_closing.contains(t[j]) || (i > 0 && _opening.contains(t[i - 1]))) {
      i = j;
      continue;
    }
    return i;
  }
}

/// Greedy first fit, SkParagraph style: a line takes opportunities while its
/// width (to the opportunity's content end) fits. Widths are bounds ([lo], [hi]
/// differ inside graphemes). Null: a segment between two opportunities is wider
/// than the line (Flutter breaks inside it). Empty: a decision within 0.002 px
/// of the edge, or one the bounds do not settle.
List<int>? _greedy(List<(int, int)> ops, Float64List lo, Float64List hi, double width) {
  final maxF = Float32List.fromList([width])[0];
  // 1: fits, 0: does not, -1: undecided.
  int fits(int s, int e) {
    final wMin = lo[e] - hi[s], wMax = hi[e] - lo[s];
    if (fitsLine(wMax + 0.002, maxF)) return 1;
    if (!fitsLine(wMin - 0.002, maxF)) return 0;
    return -1;
  }

  var prevNext = 0;
  for (final (e, n) in ops) {
    if (e > prevNext) {
      final f = fits(prevNext, e);
      if (f == 0) return null;
      if (f < 0) return const [];
    }
    prevNext = n;
  }
  final starts = <int>[0];
  var s = 0, k = 0;
  while (true) {
    var best = -1;
    for (var j = k; j < ops.length; j++) {
      final (e, _) = ops[j];
      if (e <= s) continue;
      final f = fits(s, e);
      if (f < 0) return const [];
      if (f == 0) break;
      best = j;
    }
    if (best < 0) return null;
    if (best == ops.length - 1) return starts;
    s = ops[best].$2;
    starts.add(s);
    k = best + 1;
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _indexOf(Uint8List hay, Uint8List needle) {
  final first = needle[0];
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    if (hay[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

final _loaded = <String, String?>{};
Future<String?> _loadFont(String lang) async {
  if (_loaded.containsKey(lang)) return _loaded[lang];
  for (final path in _fonts[lang]!) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final family = 'BF_$lang';
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())))).load();
    return _loaded[lang] = family;
  }
  return _loaded[lang] = null;
}

List<String> _corpora(String dir, String lang) => [
  for (final n in ['ui_$lang', 'names_$lang', 'vocab_$lang'])
    if (File('$dir/$n.txt').existsSync()) '$dir/$n.txt',
];

List<String> _read(String path, int limit) =>
    File(path).readAsStringSync().split('\n').where((l) => l.isNotEmpty).take(limit).toList();
