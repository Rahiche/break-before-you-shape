// Break-first against Jetpack Compose. A sidecar is distilled from Compose's own
// widths (the compose_bench app on an Android emulator, through TextMeasurer),
// one per pixel size because Compose's text is hinted (whole-pixel advances); the
// check also verifies that every width measured is a multiple of 1/256 px.
// Then every line break of the corpora is predicted with Minikin's greedy line
// breaker (Compose's default, LineBreak.Simple) over the width prefix, and
// compared with the line starts Compose gives the same text.
//
// usage: dart run tool/compose_check.dart <out.json> [texts per corpus]
// Needs the app installed (compose_bench/README.md) and one emulator connected.
import 'dart:convert';
import 'dart:io';

import 'package:break_first/model.dart';
import 'package:compose_check/minikin.dart';

final _tool = File.fromUri(Platform.script).parent.path;
final _repo = Directory('$_tool/../..').absolute.path;
final _tmp = Directory.systemTemp.createTempSync('compose_check');

/// One harness job on the emulator (tool/job.sh).
Map<String, dynamic> job(Map<String, Object?> j) {
  final inF = File('${_tmp.path}/job.json')..writeAsStringSync(jsonEncode(j));
  final out = '${_tmp.path}/out.json';
  final r = Process.runSync('$_tool/job.sh', [inF.path, out]);
  if (r.exitCode != 0) throw StateError('job ${j['kind']} failed: ${r.stdout}\n${r.stderr}');
  return jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
}

/// The sidecar at [size] px: WidthModel.distill with Compose's widths, in rounds.
/// A round runs the distillation on the widths measured so far and collects the
/// strings it still needs; the emulator measures them; until none is missing.
(WidthModel, int) distillCompose(String cert, double size, Map<String, double> cache) {
  for (var round = 1;; round++) {
    final misses = <String>{};
    double measure(String s) {
      final px = cache[s];
      if (px == null) misses.add(s);
      return px ?? s.length * 8.0;
    }

    final md = composeSidecar(cert, size, measure);
    stderr.writeln('  size $size round $round: ${misses.length} new strings');
    if (misses.isEmpty) return (md, cache.length);
    final list = misses.toList();
    for (var i = 0; i < list.length; i += 50000) {
      final chunk = list.sublist(i, i + 50000 > list.length ? list.length : i + 50000);
      final w = (job({'kind': 'measure', 'fontSize': size, 'strings': chunk})['widths'] as List).cast<num>();
      for (var k = 0; k < chunk.length; k++) {
        cache[chunk[k]] = w[k].toDouble();
      }
    }
  }
}

void main(List<String> args) {
  final out = args[0];
  final perCorpus = args.length > 1 ? int.parse(args[1]) : 1000;
  hardBreakKerns = false; // Minikin lays out each paragraph between hard breaks alone
  final cert = File('$_repo/flutter_bench/assets/roboto.cert').readAsStringSync();
  const corpora = ['en_docs', 'en_man', 'en_legal', 'ui_en', 'ui_de', 'ui_fr', 'ui_ru', 'ui_uk', 'ui_el'];
  final texts = <String>[];
  final corpusOf = <String>[];
  for (final c in corpora) {
    final f = File('$_repo/flutter_bench/assets/$c.txt');
    if (!f.existsSync()) continue;
    final lines = f.readAsLinesSync().where((l) => l.isNotEmpty).take(perCorpus).toList();
    texts.addAll(lines);
    corpusOf.addAll([for (final _ in lines) c]);
  }
  // Hard breaks: messages joined by \n.
  final chat = [for (var i = 0; i < texts.length; i++) if (corpusOf[i].startsWith('ui_')) texts[i]];
  for (var i = 0; i + 2 < chat.length && i < 1500; i += 3) {
    texts.add('${chat[i]}\n${chat[i + 1]}\n${chat[i + 2]}');
    corpusOf.add('chat joined');
  }
  final info = job({'kind': 'info'});
  final result = <String, Object?>{'device': info, 'texts': texts.length};
  var totalSame = 0, totalDiff = 0, totalLayouts = 0;
  // 16 and 14 sp at density 1, 2.625 (a 420 dpi phone: 42 and 36.75 px), and others.
  final sizes = Platform.environment['SIZES']?.split(',').map(double.parse) ?? [16.0, 14.0, 12.0, 24.0, 42.0, 36.75];
  for (final size in sizes) {
    final sw = Stopwatch()..start();
    // CACHE_DIR keeps Compose's widths per size (for compose_speed.dart, and re-runs).
    final cacheDir = Platform.environment['CACHE_DIR'];
    final cacheFile = cacheDir == null ? null : File('$cacheDir/widths_$size.json');
    final cache = cacheFile != null && cacheFile.existsSync()
        ? (jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()))
        : <String, double>{};
    final (md, measured) = distillCompose(cert, size, cache);
    cacheFile?.writeAsStringSync(jsonEncode(cache));
    final buildMs = sw.elapsedMilliseconds;
    // Every width Compose gave is a multiple of the quantum (the sidecar is exact).
    final offQuantum = cache.values.where((v) => v / quantum != (v / quantum).roundToDouble()).length;
    final widths = [for (final f in [8, 15, 25]) (size * f).ceil()];
    final compose = (job({'kind': 'layout', 'fontSize': size, 'widths': widths, 'texts': texts})['layouts'] as List);
    // One line's height: the most common height of Compose's one-line layouts
    // (a line with a fallback font's character is taller).
    final oneLine = <double, int>{};
    for (final per in compose) {
      for (final e in per as List) {
        if ((e as List)[0] == 1) oneLine.update((e[1] as num).toDouble(), (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final lineH = (oneLine.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
    final perWidth = <String, Object?>{};
    for (var wi = 0; wi < widths.length; wi++) {
      final w = widths[wi];
      final c = compose[wi] as List;
      var same = 0, diff = 0, heightSame = 0;
      final deferred = <String, int>{};
      final examples = <Object>[];
      for (var i = 0; i < texts.length; i++) {
        final t = texts[i];
        final [lines as int, height as num, _, starts as List] = c[i] as List;
        final (mine, why) = composeLineStarts(md, t, w);
        if (mine == null) {
          deferred[why] = (deferred[why] ?? 0) + 1;
          continue;
        }
        final theirs = [0, ...starts.cast<int>()];
        if (mine.length == lines && _eq(mine, theirs)) {
          same++;
          if (height == lines * lineH) heightSame++;
        } else {
          diff++;
          if (examples.length < 40) {
            var k = 0;
            while (k < mine.length && k < theirs.length && mine[k] == theirs[k]) {
              k++;
            }
            String around(int? at) => at == null ? '' : t.substring((at - 12).clamp(0, t.length), (at + 4).clamp(0, t.length));
            examples.add({
              'corpus': corpusOf[i],
              'breakFirst': k < mine.length ? around(mine[k]) : 'end',
              'compose': k < theirs.length ? around(theirs[k]) : 'end',
              'text': t.length > 120 ? t.substring(0, 120) : t,
            });
          }
        }
      }
      totalSame += same;
      totalDiff += diff;
      totalLayouts += texts.length;
      perWidth['$w px'] = {
        'layouts': texts.length,
        'identical': same,
        'different': diff,
        'deferred': deferred,
        'heightsEqual': heightSame,
        if (examples.isNotEmpty) 'examples': examples,
      };
      stderr.writeln('size $size width $w: identical $same different $diff deferred $deferred heights $heightSame');
    }
    result['$size px'] = {
      'measurements': measured,
      'offQuantum': offQuantum,
      'buildMs': buildMs,
      'lineHeightPx': lineH,
      'oneLineHeights': {for (final e in oneLine.entries) '${e.key}': e.value},
      'widths': perWidth,
    };
    File(out).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(result));
  }
  result['layouts'] = totalLayouts;
  result['identical'] = totalSame;
  result['different'] = totalDiff;

  File(out).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(result));
  stderr.writeln('all: $totalLayouts layouts, $totalSame identical, $totalDiff different');
  // A width off the quantum would make the sidecar inexact: fail like a difference.
  if (totalDiff != 0 || result.values.any((v) => v is Map && (v['offQuantum'] ?? 0) != 0)) exitCode = 1;
  _tmp.deleteSync(recursive: true);
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
