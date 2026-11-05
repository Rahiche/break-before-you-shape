// Paragraph heights from the sidecar in a plain Dart program, no Flutter: what a
// server would run to send heights with the messages. Compile with
// `dart compile exe tool/heights_cli.dart`; test/use_cases_test.dart compares the
// output with Flutter's own heights (SERVER_HEIGHTS).
//
// usage: heights_cli sidecar.bfw out.json size width [--quantize] [--no-break-kerns] corpus.txt...
// (--quantize and --no-break-kerns: the engine settings of Linux and Android.)
import 'dart:convert';
import 'dart:io';

import 'package:break_first/model.dart';

void main(List<String> args) {
  final [sidecar, out, size, width, ...rest] = args;
  quantizeFontSize = rest.contains('--quantize');
  hardBreakKerns = !rest.contains('--no-break-kerns');
  final texts = [
    for (final path in rest.where((a) => !a.startsWith('--')))
      ...File(path).readAsLinesSync().where((l) => l.isNotEmpty),
  ];
  final sw = Stopwatch()..start();
  final md = WidthModel.decode(File(sidecar).readAsBytesSync());
  final loadMs = sw.elapsedMicroseconds / 1000;
  final s = double.parse(size), w = double.parse(width);
  final times = <double>[];
  late List<double?> heights;
  for (var k = 0; k < 5; k++) {
    sw.reset();
    final scale = scaleFor(md, s), lh = lineHeightPx(md, s);
    heights = [
      for (final t in texts)
        () {
          final n = buildRecords(md, t)?.lineCount(w, scale) ?? -1;
          return n >= 0 ? n * lh : null; // null: the client lays it out
        }()
    ];
    times.add(sw.elapsedMicroseconds / 1000);
  }
  times.sort();
  File(out).writeAsStringSync(jsonEncode({
    'texts': texts.length, 'size': s, 'width': w, 'loadMs': loadMs, 'medianMs': times[2],
    'decided': heights.where((h) => h != null).length, 'heights': heights,
  }));
  stdout.writeln('${texts.length} texts, ${heights.where((h) => h != null).length} decided, '
      'median ${times[2].toStringAsFixed(1)} ms');
}
