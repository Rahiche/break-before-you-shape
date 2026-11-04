// Probes how Flutter (HarfBuzz) treats combining marks, for the breaker's model.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:break_first/break_first.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mark probe', (tester) async {
    await tester.runAsync(() async {
      await (FontLoader('MP')..addFont(Future.value(ByteData.sublistView(File('assets/Roboto-Regular.ttf').readAsBytesSync())))).load();
      double w(String s, [double ls = 0]) => measureText(s, fontFamily: 'MP', fontSize: 2048, letterSpacing: ls);
      String u(String s) => s.runes.map((r) => r.toRadixString(16)).join(' ');
      for (final (a, b) in [
        ('é', 'é'), ('x́', 'x'), ('ÁV', 'ÁV'), ('AV', 'AV'), ('ẠV', 'AV'),
        ('T́o', 'To'), ('To', 'To'), ('ạ́', 'ạ́'), ('ạ́', 'ạ́'),
        ('ё', 'ё'), ('й', 'й'), ('ά', 'ά'), ('i̇', 'i'),
        ('í', 'í'), ('fí', 'fí'), ('f́i', 'fi'), ('x́́', 'x'),
      ]) {
        print('MARK [${u(a)}] ${w(a)} vs [${u(b)}] ${w(b)}  diff ${w(a) - w(b)}');
      }
      for (final (a, b) in [('é', 'é'), ('x́', 'x'), ('fi', 'fi')]) {
        print('MARKLS [${u(a)}] ls64 ${w(a, 64) - w(a)} vs [${u(b)}] ${w(b, 64) - w(b)}');
      }
      final p = layoutParagraph('ab́ cd', fontFamily: 'MP', fontSize: 16, width: 1e5);
      print('MARKBOX ${[for (var i = 0; i < 6; i++) p.getBoxesForRange(i, i + 1).map((b) => '${b.left.toStringAsFixed(2)}-${b.right.toStringAsFixed(2)}').join(',')]}');
    });
  });
}
