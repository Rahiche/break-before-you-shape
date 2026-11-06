// The ideas experiments (lib/ideas.dart), one per run.
//
// flutter build macos --release -t lib/ideas_main.dart --dart-define=IDEA=pixels   (or streaming)
// BF_OUT=$PWD/results/ideas_pixels_macos.json build/macos/Build/Products/Release/bf_bench.app/Contents/MacOS/bf_bench
import 'dart:convert';
import 'dart:io';

import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bench.dart' as bench;
import 'ideas.dart';

const idea = String.fromEnvironment('IDEA', defaultValue: 'pixels');

Future<void> main() async {
  try {
    await _run();
  } catch (e, st) {
    // A failed experiment must not leave the app running with no result.
    stderr.writeln('$e\n$st');
    exit(1);
  }
}

Future<void> _run() async {
  WidgetsFlutterBinding.ensureInitialized();
  final out = <String, Object?>{'platform': Platform.operatingSystem, 'idea': idea};
  final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
  final sw = Stopwatch()..start();
  if (idea == 'fontlate') {
    // The font is not loaded yet: Flutter lays out in a fallback font meanwhile.
    final apple = Platform.isMacOS || Platform.isIOS;
    out[idea] = await fontLate(bytes, () => bench.loadFont(), quantize: !apple, hardKerns: apple);
    await _finish(out, sw);
    return;
  }
  final font = await bench.loadFont();
  final bf = BreakFirst.load(bytes, fontFamily: bench.family, font: font)!;
  out['flags'] = {'fontSizeQuantized': quantizeFontSize, 'hardBreakKerns': hardBreakKerns};
  out[idea] = switch (idea) {
    'pixels' => await pixelCheck(bf, perCorpus: const int.fromEnvironment('PER_CORPUS', defaultValue: 200),
        sizes: [for (final x in const String.fromEnvironment('SIZES', defaultValue: '14,16').split(',')) double.parse(x)]),
    'streaming' => await streaming(bf),
    'long' => await longText(bf),
    'drift' => await drift(bf),
    _ => throw ArgumentError('IDEA: $idea'),
  };
  await _finish(out, sw);
}

Future<void> _finish(Map<String, Object?> out, Stopwatch sw) async {
  out['seconds'] = sw.elapsedMilliseconds / 1000;
  final json = const JsonEncoder.withIndent(' ').convert(out);
  final path = Platform.environment['BF_OUT'] ?? '${Directory.systemTemp.path}/bf_results.json';
  File(path).writeAsStringSync(json);
  // Also in paced, numbered chunks for logcat (tool/run_android.sh), as main.dart.
  final compact = jsonEncode(out);
  final n = (compact.length + 599) ~/ 600;
  for (var i = 0; i < n; i++) {
    // ignore: avoid_print
    print('BFJSON:$i/$n:${compact.substring(i * 600, ((i + 1) * 600).clamp(0, compact.length))}');
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  // ignore: avoid_print
  print('BFDONE $path');
  exit(0);
}
