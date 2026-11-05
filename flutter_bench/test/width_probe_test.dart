// Probe: what Flutter's maxIntrinsicWidth (a Text's unconstrained width) is in
// the model's terms. WIDTH_PROBE_OUT: results JSON.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('maxIntrinsicWidth from the model', (tester) async {
    await tester.runAsync(() async {
      await loadFont();
      final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
      final md = WidthModel.decode(bytes);
      calibrateEngine(md, family);
      final texts = <String>[for (final c in corpora) ...(await loadCorpus(c)).take(1500)];
      // Hard breaks: three messages joined.
      for (var i = 0; i + 2 < 3000 && i + 2 < texts.length; i += 3) {
        texts.add('${texts[i]}\n${texts[i + 1]} \n${texts[i + 2]}');
      }
      final out = <String, Object?>{};
      for (final size in [12.0, 14.0, 16.0, 24.0, 13.0, 18.4]) {
        final scale = scaleFor(md, size);
        var n = 0, a = 0, b = 0, bitA = 0, maxErr = 0.0, skipped = 0;
        final examples = <Object>[];
        for (final t in texts) {
          final r = buildRecords(md, t);
          if (r == null) {
            skipped++;
            continue;
          }
          final p = paragraph(t, 1e5, size);
          final flutter = p.maxIntrinsicWidth;
          p.dispose();
          // A: widest segment between hard breaks, trailing spaces included.
          var best = 0.0, s = 0;
          for (var i = 0; i <= t.length; i++) {
            if (i == t.length || isHardBreak(t.codeUnitAt(i))) {
              final w = (r.prefix[i] - r.prefix[s]) * scale;
              if (w > best) best = w;
              s = i + 1;
            }
          }
          n++;
          final err = (best - flutter).abs();
          if (err > maxErr) maxErr = err;
          if (err < 1e-3) a++;
          if (best == flutter) bitA++;
          if (err >= 1e-3 && examples.length < 5) examples.add({'text': t.length > 80 ? t.substring(0, 80) : t, 'flutter': flutter, 'model': best});
          if ((best.ceilToDouble() - flutter.ceilToDouble()).abs() < 1e-9) b++;
        }
        out['$size'] = {'texts': n, 'skipped': skipped, 'within1e-3': a, 'bitEqual': bitA, 'ceilEqual': b, 'maxErr': maxErr,
            'exactScale': exactPositions(scale, 2000), 'examples': examples};
        // ignore: avoid_print
        print('size $size: ${jsonEncode(out['$size'])}');
      }
      (File(Platform.environment['WIDTH_PROBE_OUT'] ?? 'build/width_probe.json')..parent.createSync(recursive: true))
          .writeAsStringSync(jsonEncode(out));
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
