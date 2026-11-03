// Checks the package against the engine running the tests (flutter_tester): the
// shipped sidecar, the build step, and line breaks and heights on generated
// multilingual text. Results also go to build/break_first_test.json, so CI
// reports what each platform measured.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const family = 'BFTestRoboto';
final font = File('example/assets/Roboto-Regular.ttf').readAsBytesSync();
final sidecar = File('example/assets/roboto.bfw').readAsBytesSync();
final report = <String, Object?>{'os': Platform.operatingSystem};

// Words chosen for what they exercise: f-ligatures, kerning pairs, quotes,
// numbers, hyphens and dashes, and the six languages of the paper's corpora.
const words = {
  'en':
      'The office staff will file the fluffy reports before Tuesday, and nobody knows why. AVATAR To Te Wa Ty LT '
      'quickly affirm "quoted" (parenthetical) 12,345.67 \$40 100% well-known re-run e-mail it\'s first; efficient '
      'Yacht WAVE coffee — waffle shuffle traffic 3.14 1990–2024 left/right',
  'de':
      'Straße Größe „Anführung“ Fußgänger Öffnung Schifffahrt über äußerst Häuser Brücke Zürich Würfel öffentlich '
      'Grüße 1.234,56 € Ärzte',
  'fr': 'l’été « guillemets » déjà œuvre naïve façade où ça français Noël cœur bientôt éléphant C’est qu’il',
  'ru': 'Съешь же ещё этих мягких французских булок, да выпей чаю. Москва объявление «ёлка» подъезд Тверь',
  'uk': 'Київ ґанок їжак м’ята п’ять Україна Львів щастя ґудзик єнот',
  'el': 'Αθήνα Ξεσκεπάζω την ψυχοφθόρα βδελυγμία ελληνικά; Ελλάδα ΑΥΤΟ Τα Ψ άλλο οδός',
};

List<String> generate(int count, int seed, {bool newlines = false}) {
  final rnd = Random(seed);
  final langs = words.keys.toList();
  final vocab = {for (final e in words.entries) e.key: e.value.split(' ')};
  return [
    for (var i = 0; i < count; i++)
      () {
        final lang = langs[rnd.nextInt(langs.length)];
        final n = 2 + rnd.nextInt(rnd.nextBool() ? 12 : 70);
        return [
          for (var k = 0; k < n; k++)
            () {
              // Mostly one language, sometimes a word from another script.
              final pool = rnd.nextInt(10) == 0 ? vocab[langs[rnd.nextInt(langs.length)]]! : vocab[lang]!;
              return pool[rnd.nextInt(pool.length)];
            }(),
        ].join(rnd.nextInt(20) == 0 ? '  ' : ' ');
      }(),
  ].map((t) {
    if (!newlines) return t;
    // Hard breaks between words, now and then doubled or at the end.
    final w = t.split(' ');
    final rnd2 = Random(t.length);
    return [
          for (var k = 0; k < w.length; k++)
            w[k] + (k == w.length - 1 ? '' : (rnd2.nextInt(6) == 0 ? (rnd2.nextInt(4) == 0 ? '\n\n' : '\n') : ' ')),
        ].join() +
        (rnd2.nextInt(8) == 0 ? '\n' : '');
  }).toList();
}

/// Flutter's line starts: the text position at the left edge of each line.
List<int> flutterLineStarts(ui.Paragraph p) {
  final starts = <int>[0];
  final lines = p.computeLineMetrics();
  for (var i = 1; i < lines.length; i++) {
    final lm = lines[i];
    starts.add(p.getPositionForOffset(ui.Offset(0, lm.baseline - lm.ascent / 2)).offset);
  }
  return starts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
  });

  tearDownAll(() {
    Directory('build').createSync(recursive: true);
    File('build/break_first_test.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));
  });

  test('sidecar decodes and re-encodes to the same bytes', () {
    expect(WidthModel.decode(sidecar).encode(), sidecar);
  });

  test('line fit floors widths to 1/100 px in float32', () {
    double f32(double x) => (Float32List(1)..[0] = x)[0]; // box widths are float32 in the engine
    expect(fitsLine(100.009, f32(100.0)), isTrue);
    expect(fitsLine(100.01, f32(100.0)), isFalse);
    expect(fitsLine(99.99, f32(99.99)), isTrue);
    expect(fitsLine(250.0099, f32(250.0)), isTrue); // floored, not rounded
    expect(fitsLine(250.0101, f32(250.0)), isFalse);
  });

  test('break opportunities follow UAX #14 as Flutter does', () {
    List<int> nexts(String t) => breakOpportunities(t)!.$2.toList();
    expect(nexts('re-run it'), [3, 7, 9]); // after the hyphen, after the space, end
    expect(nexts('-5 apples'), [3, 9]); // no break after a word-initial hyphen
    expect(nexts('(a) b'), [4, 5]);
    expect(nexts('12,345.67 x'), [10, 11]); // inside a number
    expect(breakOpportunities('tab\there'), isNull); // outside the table: Flutter decides
  });

  test('sidecar passes the canary on this engine', () {
    final bf = BreakFirst.load(sidecar, fontFamily: family);
    report['canaryErrorPx'] = bf?.canaryErrorPx;
    report['fontSizeQuantized'] = quantizeFontSize;
    expect(bf, isNotNull);
  });

  test('building the sidecar on this engine gives the shipped bytes', () {
    final cert = File('example/assets/roboto.cert').readAsStringSync();
    var layouts = 0;
    final sw = Stopwatch()..start();
    final noLiga = File('example/assets/roboto.nolig.cert').readAsStringSync();
    final md = buildSidecar(
      fontFamily: family,
      font: font,
      certificate: cert,
      noLigaCertificate: noLiga,
      measured: (_, _) => layouts++,
    );
    final bytes = md.encode();
    report['build'] = {'layouts': layouts, 'ms': sw.elapsedMilliseconds, 'identicalToShipped': _same(bytes, sidecar)};
    expect(bytes, sidecar);
  });

  test('line breaks and heights equal Flutter on generated text', () {
    final bf = BreakFirst.load(sidecar, fontFamily: family)!;
    final paras = generate(600, 7);
    var same = 0, different = 0, deferred = 0, heights = 0, heightsEqual = 0;
    final examples = <String>[];
    for (final size in [12.0, 13.0, 16.0, 18.4, 21.3, 24.0]) {
      for (var k = 0; k < 12; k++) {
        final w = size * (9.0 + k * 36.0 / 11);
        for (final t in paras) {
          final p = layoutParagraph(t, fontFamily: family, fontSize: size, width: w);
          heights++;
          if ((bf.height(t, fontSize: size, maxWidth: w) - p.height).abs() < 1e-3) heightsEqual++;
          final ours = bf.lineStarts(t, fontSize: size, maxWidth: w);
          if (ours == null) {
            deferred++;
          } else {
            final theirs = flutterLineStarts(p);
            if (ours.length == theirs.length &&
                [for (var j = 0; j < ours.length; j++) ours[j] == theirs[j]].every((x) => x)) {
              same++;
            } else {
              different++;
              if (examples.length < 5) examples.add('size=$size w=$w ours=$ours flutter=$theirs | $t');
            }
          }
          p.dispose();
        }
      }
    }
    report['generated'] = {
      'layouts': heights,
      'identical': same,
      'different': different,
      'deferred': deferred,
      'heightsEqual': heightsEqual,
      'examples': examples,
    };
    expect(examples, isEmpty);
    expect(heightsEqual, heights);
    expect(same, greaterThan(heights * 0.8)); // the breaker decides most of them itself
  });

  test('style options and hard breaks equal Flutter on generated text', () {
    final bf = BreakFirst.load(sidecar, fontFamily: family)!;
    final paras = generate(150, 11, newlines: true);
    final configs = {
      'hard breaks': const LineOptions(),
      'letterSpacing 0.5': const LineOptions(letterSpacing: 0.5),
      'letterSpacing 1.25': const LineOptions(letterSpacing: 1.25),
      'letterSpacing -0.3': const LineOptions(letterSpacing: -0.3),
      'wordSpacing 2': const LineOptions(wordSpacing: 2),
      'wordSpacing 3.7': const LineOptions(wordSpacing: 3.7),
      'height 1.3': const LineOptions(height: 1.3),
      'height 1.43': const LineOptions(height: 1.43),
      'maxLines 2': const LineOptions(maxLines: 2),
      'all at once': const LineOptions(letterSpacing: 0.7, wordSpacing: 1.5, height: 1.2, maxLines: 3),
    };
    final examples = <String>[];
    final results = <String, Object?>{};
    for (final e in configs.entries) {
      final r = _compare(bf, paras, e.value, examples);
      results[e.key] = {'identical': r[0], 'different': r[1], 'deferred': r[2], 'heightsEqual': r[3], 'layouts': r[4]};
    }
    report['styles'] = {...results, 'examples': examples};
    expect(examples, isEmpty);
    for (final r in results.values) {
      final m = r as Map;
      expect(m['identical'] as int, greaterThan((m['layouts'] as int) * 0.7));
    }
  });
}

/// Line breaks and heights with style options, against Flutter laid out with the
/// same options: [identical, different, deferred, heights equal, layouts].
List<int> _compare(BreakFirst bf, List<String> paras, LineOptions o, List<String> examples) {
  var same = 0, different = 0, deferred = 0, heightsEqual = 0, layouts = 0;
  for (final size in [12.0, 13.0, 15.0, 16.0, 18.4, 21.3, 24.0]) {
    for (var k = 0; k < 8; k++) {
      final w = size * (9.0 + k * 36.0 / 7);
      for (final t in paras) {
        final p = layoutParagraph(
          t,
          fontFamily: family,
          fontSize: size,
          width: w,
          letterSpacing: o.letterSpacing,
          wordSpacing: o.wordSpacing,
          height: o.height,
          maxLines: o.maxLines,
        );
        layouts++;
        if ((bf.height(t, fontSize: size, maxWidth: w, options: o) - p.height).abs() < 1e-3) {
          heightsEqual++;
        } else if (examples.length < 8) {
          examples.add(
            'height size=$size w=$w ${o.letterSpacing}/${o.wordSpacing}/${o.height}/${o.maxLines} '
            'ours=${bf.height(t, fontSize: size, maxWidth: w, options: o)} flutter=${p.height} | ${jsonEncode(t)}',
          );
        }
        final ours = bf.lineStarts(t, fontSize: size, maxWidth: w, options: o);
        if (ours == null) {
          deferred++;
        } else {
          final theirs = flutterLineStarts(p);
          if (_same(ours, theirs)) {
            same++;
          } else {
            different++;
            if (examples.length < 8) {
              examples.add(
                'breaks size=$size w=$w ${o.letterSpacing}/${o.wordSpacing}/${o.height}/${o.maxLines} '
                'ours=$ours flutter=$theirs | ${jsonEncode(t)}',
              );
            }
          }
        }
        p.dispose();
      }
    }
  }
  return [same, different, deferred, heightsEqual, layouts];
}

bool _same(List<int> a, List<int> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
