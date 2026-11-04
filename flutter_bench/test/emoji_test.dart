// Emoji from the device's fallback font: UI strings with emoji (single, with
// skin tones, ZWJ sequences, flags, VS16) in the bundled Roboto, which has none,
// against Flutter's own layout with the platform's emoji font.
//
// EMOJI_OUT: results JSON (default results/emoji.json). EMOJI_SAMPLE: texts per
// corpus (default 600).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:bf_bench/bench.dart' show flutterLineStarts, loadCorpus;
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

const _emoji = [
  '😀', '😂', '🎉', '🔥', '🙏', '🚀', '🤖', '🧑‍💻', '👍', '👍🏽', '👋🏻', '🙌🏿', '👨‍👩‍👧‍👦', '👩‍❤️‍👨',
  '🏳️‍🌈', '🇫🇷', '🇯🇵', '🇺🇸', '❤️‍🔥', '🫶', '🥳', '🍕', '📦', '✍🏼',
];

void main() {
  final env = Platform.environment;
  testWidgets('emoji', (tester) async {
    await tester.runAsync(() async {
      const family = 'EmojiRoboto';
      final font = File('assets/Roboto-Regular.ttf').readAsBytesSync();
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
      final md = buildSidecar(fontFamily: family, font: font, certificate: File('assets/roboto.cert').readAsStringSync(),
          noLigaCertificate: File('assets/roboto.nolig.cert').readAsStringSync());
      final bf = BreakFirst.load(md.encode(), fontFamily: family)!;
      final rnd = Random(3);
      final sample = int.parse(env['EMOJI_SAMPLE'] ?? '600');
      final texts = <String>[];
      for (final name in ['ui_en', 'ui_de', 'ui_fr', 'ui_ru']) {
        final all = await loadCorpus(name);
        for (var i = 0; i < sample && all.isNotEmpty; i++) {
          final words = all[(i * 7919) % all.length].split(' ');
          final n = 1 + rnd.nextInt(3);
          for (var k = 0; k < n; k++) {
            final e = List.generate(1 + rnd.nextInt(3), (_) => _emoji[rnd.nextInt(_emoji.length)]).join();
            final at = rnd.nextInt(words.length + 1);
            if (rnd.nextInt(3) == 0 && at > 0) {
              words[at - 1] = '${words[at - 1]}$e'; // right after a word, no space
            } else {
              words.insert(at, e);
            }
          }
          texts.add(words.join(' '));
        }
      }
      var same = 0, diff = 0, deferred = 0, heights = 0;
      final examples = <String>[];
      for (final size in [13.0, 16.0, 20.0]) {
        for (final t in texts) {
          final rich = RichParagraph.prepare([RichSpan(t, bf, size)]);
          for (final w in [90.0, 150.0, 240.0, 380.0]) {
            final ours = rich?.lineStarts(w);
            if (ours == null) {
              deferred++;
              continue;
            }
            final p = (ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr))
                  ..pushStyle(ui.TextStyle(fontFamily: family, fontSize: size))
                  ..addText(t))
                .build()
              ..layout(ui.ParagraphConstraints(width: w));
            final theirs = flutterLineStarts(p, t);
            if (_same(ours, theirs)) {
              same++;
              final h = rich!.height(w)!;
              if ((h - p.height).abs() < 1e-3) {
                heights++;
              } else if (examples.length < 12) {
                examples.add('height size=$size w=$w ours=$h flutter=${p.height} ${jsonEncode(t)}');
              }
            } else {
              diff++;
              if (examples.length < 12) examples.add('size=$size w=$w ours=$ours flutter=$theirs ${jsonEncode(t)}');
            }
            p.dispose();
          }
        }
      }
      final out = {'texts': texts.length, 'identical': same, 'different': diff, 'deferred': deferred,
          'heightsEqual': heights, 'examples': examples};
      print('EMOJI ${jsonEncode({...out}..remove('examples'))}');
      File(env['EMOJI_OUT'] ?? 'results/emoji.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    });
  }, timeout: const Timeout(Duration(hours: 1)));
}
