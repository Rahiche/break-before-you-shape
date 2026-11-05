// What the shipped sidecar does when the font is not the one it was built from
// (fonts from tool/failsafe_fonts.py): whether the start-up canary refuses it,
// whether loading with the font's bytes refuses it (the sidecar's font digest),
// whether rebuilding the sidecar (the build step's check in CI) gives other bytes,
// and how many layouts would differ from Flutter if the stale sidecar were used
// anyway. FAILSAFE_FONTS: the directory with same.ttf, wider.ttf, eacute.ttf.
// FAILSAFE_OUT: results JSON.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart' show chatCorpora, flutterLineStarts, loadCorpus;
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

void main() {
  final dir = Platform.environment['FAILSAFE_FONTS'];
  testWidgets('a stale sidecar is refused or caught by the build check', (tester) async {
    await tester.runAsync(() async {
      final shipped = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
      final cert = File('assets/roboto.cert').readAsStringSync();
      final nolig = File('assets/roboto.nolig.cert').readAsStringSync();
      final texts = <String>[for (final c in chatCorpora) ...(await loadCorpus(c)).take(1000)];
      final out = <String, Object?>{};
      var k = 0;
      for (final name in ['same', 'wider', 'eacute']) {
        final family = 'Failsafe${k++}';
        final font = File('$dir/$name.ttf').readAsBytesSync();
        await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
        final loaded = BreakFirst.load(shipped, fontFamily: family);
        final loadedWithFont = BreakFirst.load(shipped, fontFamily: family, font: font);
        final rebuilt = buildSidecar(fontFamily: family, font: font, certificate: cert, noLigaCertificate: nolig).encode();
        // The stale sidecar used anyway, against this font.
        final md = WidthModel.decode(shipped);
        calibrateEngine(md, family);
        var same = 0, diff = 0;
        for (final t in texts) {
          final r = buildRecords(md, t);
          for (final w in [180.0, 280.0, 400.0]) {
            final ours = r?.lineStarts(w, scaleFor(md, 16));
            if (ours == null) continue;
            final p = layoutParagraph(t, fontFamily: family, fontSize: 16, width: w);
            final theirs = flutterLineStarts(p, t);
            final h = p.height;
            p.dispose();
            if (_same(ours, theirs) && (ours.length * lineHeightPx(md, 16) - h).abs() < 1e-3) {
              same++;
            } else {
              diff++;
            }
          }
        }
        out[name] = {'canaryPasses': loaded != null, 'canaryErrorPx': canaryError(md, family),
            'loadsWithFontBytes': loadedWithFont != null,
            'rebuildGivesShippedBytes': _same(rebuilt, shipped), 'staleIdentical': same, 'staleDifferent': diff};
        print('FAILSAFE $name: ${jsonEncode(out[name])}');
      }
      File(Platform.environment['FAILSAFE_OUT'] ?? 'results/failsafe.json')
          .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
      final same = out['same'] as Map, wider = out['wider'] as Map, eacute = out['eacute'] as Map;
      expect(same['canaryPasses'], isTrue);
      expect(same['rebuildGivesShippedBytes'], isTrue);
      expect(wider['canaryPasses'], isFalse);
      expect(eacute['rebuildGivesShippedBytes'], isFalse);
      expect(same['loadsWithFontBytes'], isTrue);
      expect(eacute['loadsWithFontBytes'], isFalse); // the font's digest differs
      expect(wider['loadsWithFontBytes'], isFalse);
    });
  }, skip: dir == null, timeout: const Timeout(Duration(minutes: 30)));
}
