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
  'en': 'The office staff will file the fluffy reports before Tuesday, and nobody knows why. AVATAR To Te Wa Ty LT '
      'quickly affirm "quoted" (parenthetical) 12,345.67 \$40 100% well-known re-run e-mail it\'s first; efficient '
      'Yacht WAVE coffee — waffle shuffle traffic 3.14 1990–2024 left/right',
  'de': 'Straße Größe „Anführung“ Fußgänger Öffnung Schifffahrt über äußerst Häuser Brücke Zürich Würfel öffentlich '
      'Grüße 1.234,56 € Ärzte',
  'fr': 'l’été « guillemets » déjà œuvre naïve façade où ça français Noël cœur bientôt éléphant C’est qu’il',
  'ru': 'Съешь же ещё этих мягких французских булок, да выпей чаю. Москва объявление «ёлка» подъезд Тверь',
  'uk': 'Київ ґанок їжак м’ята п’ять Україна Львів щастя ґудзик єнот',
  'el': 'Αθήνα Ξεσκεπάζω την ψυχοφθόρα βδελυγμία ελληνικά; Ελλάδα ΑΥΤΟ Τα Ψ άλλο οδός',
};

List<String> generate(int count, int seed) {
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
            }()
        ].join(rnd.nextInt(20) == 0 ? '  ' : ' ');
      }()
  ];
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
    final md = buildSidecar(fontFamily: family, font: font, certificate: cert, measured: (_, _) => layouts++);
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
            if (ours.length == theirs.length && [for (var j = 0; j < ours.length; j++) ours[j] == theirs[j]].every((x) => x)) {
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
    report['generated'] = {'layouts': heights, 'identical': same, 'different': different, 'deferred': deferred,
        'heightsEqual': heightsEqual, 'examples': examples};
    expect(examples, isEmpty);
    expect(heightsEqual, heights);
    expect(same, greaterThan(heights * 0.8)); // the breaker decides most of them itself
  });
}

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
