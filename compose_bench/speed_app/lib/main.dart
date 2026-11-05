// Break-first's line breaking for Compose, timed on the Android emulator. Dart
// cannot build a plain Android executable on macOS, so the same code as
// ../tool/compose_check.dart runs in this minimal Flutter release app, compiled
// ahead of time as a Flutter release app runs Dart. The sidecar is distilled at
// start from Compose's widths (the build step, not timed); then the line count of
// every message at one width, as the heights of a list need it. Prints
// "BFSPEED {json}" to the log.
import 'dart:convert';

import 'package:break_first/model.dart';
import 'package:compose_check/minikin.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

final size = double.parse(const String.fromEnvironment('SIZE', defaultValue: '42'));
const width = int.fromEnvironment('WIDTH', defaultValue: 735);
const corpora = ['ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el'];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox());
  hardBreakKerns = false;
  final cert = await rootBundle.loadString('assets/roboto.cert');
  final widths = jsonDecode(await rootBundle.loadString('assets/widths.json')) as Map<String, dynamic>;
  final md = composeSidecar(cert, size, (s) => (widths[s] as num).toDouble());
  final texts = <String>[
    for (final c in corpora) ...(await rootBundle.loadString('assets/$c.txt')).split('\n').where((l) => l.isNotEmpty),
  ];
  final ms = <double>[];
  var lines = 0, decided = 0;
  for (var rep = 0; rep < 15; rep++) {
    lines = 0;
    decided = 0;
    final sw = Stopwatch()..start();
    for (final t in texts) {
      final (starts, _) = composeLineStarts(md, t, width);
      if (starts != null) {
        lines += starts.length;
        decided++;
      }
    }
    ms.add(sw.elapsedMicroseconds / 1000);
  }
  final sorted = [...ms]..sort();
  // ignore: avoid_print
  print('BFSPEED ${jsonEncode({'size': size, 'width': width, 'texts': texts.length, 'decided': decided, 'lines': lines, 'ms': ms, 'medianMs': sorted[7]})}');
}
