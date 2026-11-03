import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'bench.dart' as bench;

// BF_MODE: all | validate | timing | sizes | native (BF_NATIVE_LIB: the compiled native/break_first.c).
// BF_SAMPLE: paragraphs per corpus for validation.
const mode = String.fromEnvironment('BF_MODE', defaultValue: 'all');
const sample = int.fromEnvironment('BF_SAMPLE', defaultValue: 100000);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final result = await bench.runApp(mode: mode, sample: sample);
  final json = const JsonEncoder.withIndent(' ').convert(result);
  final path = Platform.environment['BF_OUT'] ?? '${Directory.systemTemp.path}/bf_results.json';
  File(path).writeAsStringSync(json);
  // Also print in chunks, for devices where the file is hard to reach (logcat).
  // Paced, numbered chunks: logcat drops lines that arrive too fast.
  final compact = jsonEncode(result);
  final n = (compact.length + 599) ~/ 600;
  for (var i = 0; i < n; i++) {
    print('BFJSON:$i/$n:${compact.substring(i * 600, ((i + 1) * 600).clamp(0, compact.length))}');
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  print('BFDONE $path');
  exit(0);
}
