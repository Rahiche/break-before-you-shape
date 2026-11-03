// The C port (native/break_first.c) must give the Dart breaker's answers. Needs
// BF_NATIVE_LIB (the compiled library) and the corpora; skipped without the library.
import 'dart:convert';
import 'dart:io';

import 'package:bf_bench/bench.dart';
import 'package:bf_bench/native.dart';
import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['BF_NATIVE_LIB'];
  testWidgets('C port gives the Dart answers', (tester) async {
    await tester.runAsync(() async {
      await loadFont();
      final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
      final md = WidthModel.decode(bytes);
      final r = await nativeExactness(md, NativeBreaker(lib!, bytes), sample: 200);
      print('NATIVE ${jsonEncode(r)}');
      expect(r['mismatched'], 0);
      expect(r['checked'] as int, greaterThan(10000));
    });
  }, skip: lib == null, timeout: const Timeout(Duration(minutes: 20)));
}
