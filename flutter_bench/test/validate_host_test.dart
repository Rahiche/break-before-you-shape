// Exactness under flutter_tester with the shipped sidecar.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('validate on host', (tester) async {
    await tester.runAsync(() async {
      final r = await runApp(mode: 'validate', sample: int.parse(Platform.environment['BF_SAMPLE'] ?? '100000'));
      File('results/host_validate.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(r));
      print('HOST ${jsonEncode(r['canary'])}');
    });
  }, timeout: const Timeout(Duration(hours: 2)));
}
