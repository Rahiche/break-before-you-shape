// The use cases of bench.dart (auto-fit, text-scale change, pagination, a
// background isolate) under flutter_tester: every answer must equal Flutter's.
// Timings here are from a debug build; the paper's come from the release app
// (BF_MODE=usecases). USECASES_OUT: results JSON.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('use cases give Flutter\'s answers', (tester) async {
    await tester.runAsync(() async {
      await loadFont();
      final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
      final md = WidthModel.decode(bytes);
      calibrateEngine(md, family);
      final r = await useCases(md, bytes, reps: 1);
      File(Platform.environment['USECASES_OUT'] ?? 'results/use_cases_host.json')
          .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(r));
      final fit = r['autoFit'] as Map, scale = r['textScale'] as Map, pages = r['pagination'] as Map;
      final bg = r['backgroundIsolate'] as Map;
      expect(fit['sameSize'], fit['messages']);
      expect(scale['heightsEqual'], scale['messages']);
      expect((pages['at16'] as Map)['samePageBreaks'], isTrue);
      expect((pages['at18'] as Map)['samePageBreaks'], isTrue);
      expect(bg['heightsEqual'], bg['messages']);
      // SERVER_HEIGHTS: tool/heights_cli.dart's output for the chat corpora at
      // 16 px and 280 px, computed with no Flutter; each decided height must be
      // Flutter's.
      final server = Platform.environment['SERVER_HEIGHTS'];
      if (server != null) {
        final cli = jsonDecode(File(server).readAsStringSync()) as Map<String, dynamic>;
        final heights = (cli['heights'] as List).cast<num?>();
        final chat = <String>[for (final c in chatCorpora) ...await loadCorpus(c)];
        expect(heights.length, chat.length);
        var equal = 0, decided = 0;
        for (var i = 0; i < chat.length; i++) {
          if (heights[i] == null) continue;
          decided++;
          final p = paragraph(chat[i], 280, 16);
          if ((p.height - heights[i]!).abs() < 1e-3) equal++;
          p.dispose();
        }
        r['server'] = {'texts': chat.length, 'decided': decided, 'heightsEqual': equal,
            'cliMedianMs': cli['medianMs'], 'cliLoadMs': cli['loadMs']};
        File(Platform.environment['USECASES_OUT'] ?? 'results/use_cases_host.json')
            .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(r));
        expect(equal, decided);
      }
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}
