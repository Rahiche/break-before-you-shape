// The build step: measure Flutter (flutter_tester, same text stack as the
// engine) and write the sidecar the app ships, plus build statistics.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('build sidecar', (tester) async {
    await tester.runAsync(() async {
      final (model, stats) = await buildSidecar();
      File('assets/roboto.bfw').writeAsBytesSync(model.encode());
      File('results/build_stats.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(stats));
      print('BUILD ${jsonEncode(stats)}');
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}
