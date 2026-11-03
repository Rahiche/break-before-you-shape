// The demo's claims under flutter_tester: every extent equals TextPainter's, the
// break-first list knows its exact total height, and a jump lands on the message.
import 'dart:io';

import 'package:break_first/break_first.dart';
import 'package:break_first_example/main.dart';
import 'package:break_first_example/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<BreakFirst> _load() async {
  final font = File('assets/Roboto-Regular.ttf').readAsBytesSync();
  await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(font)))).load();
  return BreakFirst.load(File('assets/roboto.bfw').readAsBytesSync(), fontFamily: family)!;
}

void main() {
  testWidgets('extents equal TextPainter for every message', (tester) async {
    final bf = (await tester.runAsync(_load))!;
    final demo = Demo(bf, chatMessages(count));
    for (final size in [15.0, 18.0]) {
      demo.setFontSize(size);
      demo.ensureExtents(142);
      demo.verify(null);
      expect(demo.result, startsWith('10,000 of 10,000 heights equal'));
    }
  });

  testWidgets('the break-first list has its exact height and jumps exactly', (tester) async {
    final bf = (await tester.runAsync(_load))!;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final demo = Demo(bf, chatMessages(count));
    await tester.pumpWidget(DemoApp(demo: demo));
    await tester.pump();
    final positions = [for (final s in tester.stateList<ScrollableState>(find.byType(Scrollable))) s.position];
    final exact = positions.last;
    expect(exact.maxScrollExtent + exact.viewportDimension, closeTo(2 * listPad + demo.offsets[count], 1e-6));
    exact.jumpTo(listPad + demo.offsets[2500]);
    await tester.pump();
    final top = tester.getTopLeft(find.byType(Scrollable).last).dy;
    expect(tester.getTopLeft(find.text('#2,500')).dy, closeTo(top + 2, 1e-6)); // the number sits 2 px into its item
  });
}
