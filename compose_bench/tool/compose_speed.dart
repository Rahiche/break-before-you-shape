// Timing on the emulator, for the heights of a chat list: Compose's TextMeasurer
// against break-first (speed_app, the same code as compose_check.dart, compiled
// ahead of time). Break-first hands some messages back to Compose; their
// TextMeasurer time is added to break-first's. Every message break-first decides
// is checked against Compose's line count at the same width. tool/speed.sh runs
// this after speed_app.
//
// usage: dart run tool/compose_speed.dart <cache dir> <size> <width> <out.json>
import 'dart:convert';
import 'dart:io';

import 'package:break_first/model.dart';
import 'package:compose_check/minikin.dart';

final _tool = File.fromUri(Platform.script).parent.path;
final _tmp = Directory.systemTemp.createTempSync('compose_speed');

Map<String, dynamic> job(Map<String, Object?> j) {
  final inF = File('${_tmp.path}/job.json')..writeAsStringSync(jsonEncode(j));
  final out = '${_tmp.path}/out.json';
  final r = Process.runSync('$_tool/job.sh', [inF.path, out]);
  if (r.exitCode != 0) throw StateError('job ${j['kind']} failed: ${r.stdout}\n${r.stderr}');
  return jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
}

void main(List<String> args) {
  final [cache, sizeArg, widthArg, out] = args;
  final size = double.parse(sizeArg), width = int.parse(widthArg);
  hardBreakKerns = false;
  final widths = jsonDecode(File('$cache/widths_$size.json').readAsStringSync()) as Map<String, dynamic>;
  final cert = File('$_tool/../speed_app/assets/roboto.cert').readAsStringSync();
  final md = composeSidecar(cert, size, (s) => (widths[s] as num).toDouble());
  final texts = <String>[
    for (final c in ['ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el'])
      ...File('$_tool/../speed_app/assets/$c.txt').readAsLinesSync().where((l) => l.isNotEmpty),
  ];
  final mine = [for (final t in texts) composeLineStarts(md, t, width).$1];
  final deferred = [for (var i = 0; i < texts.length; i++) if (mine[i] == null) texts[i]];
  // Exactness of the timed case: Compose's line starts for every message.
  final layouts = (job({'kind': 'layout', 'fontSize': size, 'widths': [width], 'texts': texts})['layouts'] as List)[0] as List;
  var same = 0, diff = 0;
  for (var i = 0; i < texts.length; i++) {
    final m = mine[i];
    if (m == null) continue;
    final [lines as int, _, _, starts as List] = layouts[i] as List;
    final theirs = [0, ...starts.cast<int>()];
    if (m.length == lines && m.indexed.every((e) => theirs[e.$1] == e.$2)) {
      same++;
    } else {
      diff++;
    }
  }
  final all = job({'kind': 'time', 'fontSize': size, 'width': width, 'texts': texts, 'reps': 15});
  final back = job({'kind': 'time', 'fontSize': size, 'width': width, 'texts': deferred, 'reps': 15});
  final bf = jsonDecode(File('$cache/bf_speed.json').readAsStringSync()) as Map<String, dynamic>;
  final composeMs = (all['medianMs'] as num).toDouble();
  final bfMs = (bf['medianMs'] as num).toDouble(), backMs = (back['medianMs'] as num).toDouble();
  final result = {
    'device': job({'kind': 'info'}),
    'case': 'line counts (heights) of ${texts.length} chat messages, ${size}px Roboto (16 sp at 2.625), ${width}px wide (280 dp)',
    'messages': texts.length,
    'decidedByBreakFirst': texts.length - deferred.length,
    'lineStartsIdentical': same,
    'lineStartsDifferent': diff,
    'composeTextMeasurerMs': all['ms'],
    'composeMedianMs': composeMs,
    'breakFirstMs': bf['ms'],
    'breakFirstMedianMs': bfMs,
    'handedBackComposeMs': back['ms'],
    'handedBackMedianMs': backMs,
    'breakFirstTotalMs': bfMs + backMs,
    'speedup': composeMs / (bfMs + backMs),
  };
  File(out).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(result));
  stderr.writeln(jsonEncode({for (final e in result.entries) if (e.value is! List && e.value is! Map) e.key: e.value}));
  _tmp.deleteSync(recursive: true);
}
