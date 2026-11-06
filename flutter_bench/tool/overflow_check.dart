// Build-time overflow check: every translation of every UI string, in every
// slot of a layout and at every text scale, without Flutter or a device. Plain
// Dart: the sidecar and the breaker (package:break_first/model.dart).
//
// dart compile exe tool/overflow_check.dart -o build/overflow_check
// build/overflow_check assets/roboto.bfw build/translations.json apple build/overflow_apple
//
// Writes <out>.bin (one byte per case: 0 fits, 1 cut by maxLines, 2 Flutter must
// decide, 3 a word wider than the box, which Flutter breaks inside) and
// <out>.json (counts and timing). Platform: apple (macOS, iOS) or
// android (Android, Linux), the engine flags calibrateEngine finds there.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:break_first/model.dart';

/// Text slots of a layout: font size, box width (logical px) and maxLines.
const slots = [
  ('button', 14.0, 112.0, 1),
  ('tab', 14.0, 90.0, 1),
  ('listTitle', 16.0, 280.0, 1),
  ('listSubtitle', 14.0, 280.0, 2),
  ('dialogTitle', 24.0, 280.0, 2),
  ('cardBody', 14.0, 320.0, 3),
];
const scales = [1.0, 1.15, 1.3, 1.5, 1.8, 2.0];
const langs = ['en', 'de', 'fr', 'ru', 'uk', 'el'];

/// As Flutter's didExceedMaxLines: the empty line after a final hard break does
/// not count (break_first's exceedsLines). Null: Flutter decides.
bool? exceeds(String text, int lines, int maxLines) {
  if (lines <= maxLines) return false;
  if (text.isEmpty || !isHardBreak(text.codeUnitAt(text.length - 1))) return true;
  if (lines > maxLines + 1) return true;
  return text.length >= 2 && isHardBreak(text.codeUnitAt(text.length - 2)) ? null : false;
}

/// Whether a word of [r] (a run between break opportunities, without its
/// trailing spaces) is wider than [width] at [scale]. Flutter floors a line's
/// width to 1/100 px before the test (measured: a word up to 0.0096 px wider
/// than the box fits), so only a word wider by more than that and float drift.
bool wordWiderThan(Records r, double width, double scale) {
  var widest = r.prefix[r.ends[0]];
  for (var j = 0; j + 1 < r.count; j++) {
    final w = r.prefix[r.ends[j + 1]] - r.prefix[r.nexts[j]];
    if (w > widest) widest = w;
  }
  return widest * scale > width + 0.011;
}

void main(List<String> args) {
  final md = WidthModel.decode(File(args[0]).readAsBytesSync());
  final rows = (jsonDecode(File(args[1]).readAsStringSync()) as List).cast<Map<String, dynamic>>();
  final android = args[2] == 'android';
  quantizeFontSize = android;
  hardBreakKerns = !android;
  final out = Uint8List(rows.length * langs.length * slots.length * scales.length);
  final sw = Stopwatch()..start();
  var k = 0;
  for (final row in rows) {
    for (final lang in langs) {
      final t = row[lang] as String;
      final r = buildRecords(md, t);
      for (final (_, size, width, maxLines) in slots) {
        for (final s in scales) {
          final scale = scaleFor(md, size * s);
          final n = r?.lineCount(width, scale) ?? -1;
          final e = n < 0 ? null : exceeds(t, n, maxLines);
          out[k++] = e != null ? (e ? 1 : 0) : (r != null && wordWiderThan(r, width, scale) ? 3 : 2);
        }
      }
    }
  }
  final ms = sw.elapsedMicroseconds / 1000;
  File('${args[3]}.bin').writeAsBytesSync(out);
  final counts = [0, 0, 0, 0];
  for (final b in out) {
    counts[b]++;
  }
  final summary = {
    'platform': args[2], 'strings': rows.length, 'languages': langs, 'slots': [for (final s in slots) s.$1],
    'scales': scales, 'cases': out.length, 'fits': counts[0], 'cut': counts[1], 'wordWiderThanBox': counts[3],
    'flutterDecides': counts[2],
    'ms': ms, 'usPerCase': ms * 1000 / out.length,
  };
  File('${args[3]}.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary));
  stdout.writeln(jsonEncode(summary));
}
