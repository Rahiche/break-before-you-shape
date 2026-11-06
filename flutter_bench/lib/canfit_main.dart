// What Text(caption, maxLines: 3).canFit(240) costs: every chat message asked
// once, against a TextPainter configured as the widget configures its own.
//
// flutter build macos --release -t lib/canfit_main.dart
// BF_OUT=$PWD/results/canfit_macos.json build/macos/Build/Products/Release/bf_bench.app/Contents/MacOS/bf_bench
import 'dart:convert';
import 'dart:io';

import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bench.dart' as bench;

const reps = 15;
const maxWidth = 240.0, maxLines = 3;

double _median(List<double> xs) => (xs.toList()..sort())[xs.length ~/ 2];

/// Without break-first: lay the caption out as RenderParagraph would and ask.
bool painterFits(String c, double w) {
  final p = TextPainter(
    text: TextSpan(style: BreakFirst.defaultTextStyle, text: c),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
  )..layout(maxWidth: w);
  final ok = !p.didExceedMaxLines && p.width <= w;
  p.dispose();
  return ok;
}

bool canFit(String c, double w) => Text(c, maxLines: maxLines).canFit(w);

/// Median over [reps] of the time to answer every caption, both ways interleaved.
Map<String, Object?> compare(List<String> xs) {
  final a = List.filled(xs.length, false), b = List.filled(xs.length, false);
  final tp = <double>[], bf = <double>[];
  for (var k = 0; k < reps; k++) {
    var sw = Stopwatch()..start();
    for (var i = 0; i < xs.length; i++) {
      a[i] = painterFits(xs[i], maxWidth);
    }
    tp.add(sw.elapsedMicroseconds / 1000);
    sw = Stopwatch()..start();
    for (var i = 0; i < xs.length; i++) {
      b[i] = canFit(xs[i], maxWidth);
    }
    bf.add(sw.elapsedMicroseconds / 1000);
  }
  var different = 0;
  for (var i = 0; i < xs.length; i++) {
    if (a[i] != b[i]) different++;
  }
  final tpMs = _median(tp), bfMs = _median(bf);
  return {
    'captions': xs.length,
    'meanChars': xs.isEmpty ? 0 : xs.fold<int>(0, (s, c) => s + c.length) / xs.length,
    'textPainterMs': tpMs, 'canFitMs': bfMs,
    'textPainterUsPerCall': tpMs * 1000 / xs.length, 'canFitUsPerCall': bfMs * 1000 / xs.length,
    'speedup': tpMs / bfMs, 'different': different,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final font = await bench.loadFont();
  final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();

  // One-time: decode the sidecar, calibrate it and check its canary on this device.
  final rss0 = ProcessInfo.currentRss;
  var sw = Stopwatch()..start();
  final bf = BreakFirst.load(bytes, fontFamily: bench.family, font: font)!;
  final firstLoadMs = sw.elapsedMicroseconds / 1000;
  final rss1 = ProcessInfo.currentRss;
  final loads = <double>[];
  for (var k = 0; k < reps; k++) {
    sw = Stopwatch()..start();
    BreakFirst.load(bytes, fontFamily: bench.family, font: font);
    loads.add(sw.elapsedMicroseconds / 1000);
  }
  bf.register(asDefault: true);

  final captions = [for (final c in bench.chatCorpora) ...await bench.loadCorpus(c)];
  final decided = [for (final c in captions) if (Text(c, maxLines: maxLines).measure().linesFromSidecar(maxWidth)) c];
  final handedBack = [for (final c in captions) if (!Text(c, maxLines: maxLines).measure().linesFromSidecar(maxWidth)) c];

  final out = <String, Object?>{
    'platform': Platform.operatingSystem,
    'call': 'Text(caption, maxLines: $maxLines).canFit($maxWidth)',
    'style': 'Roboto 14 px (kDefaultFontSize), no context',
    'reps': reps,
    'sidecar': {
      'bytes': bytes.length, 'firstLoadMs': firstLoadMs, 'loadMsMedian': _median(loads),
      'rssGrowthBytesOnFirstLoad': rss1 - rss0,
    },
    'all': compare(captions),
    'decidedBySidecar': compare(decided),
    'handedBackToFlutter': compare(handedBack),
    'byLength': {
      for (final (name, lo, hi) in [('1-40', 1, 40), ('41-120', 41, 120), ('121+', 121, 1 << 30)])
        name: compare([for (final c in captions) if (c.length >= lo && c.length <= hi) c]),
    },
  };

  // Asking again: one measure() per caption, prepared by a first canFit, then
  // canFit at another width, against a TextPainter kept laid out and laid out again.
  {
    final ms = [for (final c in decided) Text(c, maxLines: maxLines).measure()];
    for (final m in ms) {
      m.canFit(maxWidth);
    }
    final painters = [
      for (final c in decided)
        TextPainter(text: TextSpan(style: BreakFirst.defaultTextStyle, text: c), textDirection: TextDirection.ltr,
            maxLines: maxLines)
          ..layout(maxWidth: maxWidth),
    ];
    final r = List.filled(ms.length, false);
    final again = <double>[], relayout = <double>[];
    for (var k = 0; k < reps; k++) {
      final w = k.isEven ? 200.0 : maxWidth;
      sw = Stopwatch()..start();
      for (var i = 0; i < painters.length; i++) {
        r[i] = !(painters[i]..layout(maxWidth: w)).didExceedMaxLines;
      }
      relayout.add(sw.elapsedMicroseconds / 1000);
      sw = Stopwatch()..start();
      for (var i = 0; i < ms.length; i++) {
        r[i] = ms[i].canFit(w);
      }
      again.add(sw.elapsedMicroseconds / 1000);
    }
    for (final p in painters) {
      p.dispose();
    }
    final a = _median(again), t = _median(relayout);
    out['askAgain'] = {
      'captions': ms.length, 'widths': [200.0, maxWidth],
      'textPainterRelayoutUsPerCall': t * 1000 / ms.length, 'canFitUsPerCall': a * 1000 / ms.length, 'speedup': t / a,
    };
  }

  final json = const JsonEncoder.withIndent(' ').convert(out);
  File(Platform.environment['BF_OUT'] ?? '${Directory.systemTemp.path}/bf_canfit.json').writeAsStringSync(json);
  // ignore: avoid_print
  print(json);
  exit(0);
}
