// Exactness under flutter_tester with the shipped sidecar.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('validate on host', (tester) async {
    await tester.runAsync(() async {
      // BF_MODE: validate (default) or styles.
      final mode = Platform.environment['BF_MODE'] ?? 'validate';
      final r = await runApp(mode: mode, sample: int.parse(Platform.environment['BF_SAMPLE'] ?? '100000'));
      File('results/host_$mode.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(r));
      print('HOST ${jsonEncode(r['canary'])}');
    });
  }, timeout: const Timeout(Duration(hours: 2)));
}
