// Flutter's own line starts for compose_bench/tool/diff_check.dart: every text of
// DIFF_DIR/diff_input.json at its size and widths, into DIFF_DIR/flutter_truth.json.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Flutter line starts', (tester) async {
    await tester.runAsync(() async {
      await loadFont();
      final dir = Platform.environment['DIFF_DIR']!;
      final input = jsonDecode(File('$dir/diff_input.json').readAsStringSync()) as Map<String, dynamic>;
      final texts = (input['texts'] as List).cast<String>();
      final size = (input['size'] as num).toDouble();
      final out = [
        for (final w in input['widths'] as List)
          [
            for (final t in texts)
              () {
                final p = paragraph(t, (w as num).toDouble(), size);
                final s = flutterLineStarts(p, t);
                p.dispose();
                return s;
              }(),
          ],
      ];
      File('$dir/flutter_truth.json').writeAsStringSync(jsonEncode(out));
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}
