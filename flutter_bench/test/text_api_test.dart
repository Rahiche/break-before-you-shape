// `Text(...).width`, `height`, `lineCount` and `canFit` against the sizes Flutter
// gives the same Text widgets: built in a tree (in a Material app, with
// MediaQuery overrides, locales) and without a BuildContext. Every answer must
// equal the widget's. TEXT_API_OUT: results JSON.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bf_bench/bench.dart';
import 'package:break_first/break_first.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = ValueKey('texts');

/// A way of building the Texts: the widget tree around them, and whether the
/// answers get its BuildContext.
class _Tree {
  const _Tree(this.name, this.wrap, {this.context = true});
  final String name;
  final Widget Function(Widget column) wrap;
  final bool context;
}

class _Case {
  const _Case(this.name, this.text, this.widths, {this.maxHeight = double.infinity});
  final String name;
  final Text Function(String s) text;
  final List<double> widths;
  final double maxHeight;
}

void main() {
  testWidgets('Text(...).width and friends equal the widget\'s size', (tester) async {
    final out = <String, Object?>{};
    var different = 0;
    late List<String> texts;
    await tester.runAsync(() async {
      final font = await loadFont();
      final bytes = (await rootBundle.load('assets/roboto.bfw')).buffer.asUint8List();
      BreakFirst.load(bytes, fontFamily: family, font: font)!.register(asDefault: true);
      texts = <String>[for (final c in corpora) ...(await loadCorpus(c)).take(300)];
      final joined = <String>[];
      for (var i = 0; i + 2 < 900 && i + 2 < texts.length; i += 3) {
        joined.add('${texts[i]}\n${texts[i + 1]} \n${texts[i + 2]}');
      }
      texts.addAll(joined);
    });

    Widget bare(Widget c) => Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(style: BreakFirst.defaultTextStyle, child: c),
    );
    Widget material(Widget c) => MaterialApp(
      theme: ThemeData(fontFamily: family),
      home: Material(child: c),
    );
    Widget scaled(Widget c) => material(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.15)),
          child: c,
        ),
      ),
    );
    Widget bold(Widget c) => material(
      Builder(
        builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(boldText: true), child: c),
      ),
    );
    Widget spacedOverride(Widget c) => material(
      Builder(
        builder: (context) => MediaQuery(
          data: const MediaQueryData(letterSpacingOverride: 0.5, lineHeightScaleFactorOverride: 1.5),
          child: c,
        ),
      ),
    );

    const ws = [double.infinity, 120.0, 280.0];
    final trees = [
      (const _Tree('no context', _noWrap, context: false), [
        for (final size in [12.0, 14.0, 16.0, 24.0, 13.0, 18.4])
          _Case('$size px', (s) => Text(s, style: TextStyle(fontSize: size)), ws, maxHeight: 60),
        _Case('maxLines 2', (s) => Text(s, maxLines: 2, style: const TextStyle(fontSize: 16)), ws, maxHeight: 60),
        _Case('softWrap false', (s) => Text(s, softWrap: false, style: const TextStyle(fontSize: 16)), ws),
        _Case('textScaler 1.3', (s) => Text(s, textScaler: const TextScaler.linear(1.3), style: const TextStyle(fontSize: 16)), ws),
        _Case('letterSpacing 0.5, wordSpacing 1', (s) => Text(s, style: const TextStyle(fontSize: 16, letterSpacing: 0.5, wordSpacing: 1)), ws),
        _Case('height 1.3', (s) => Text(s, style: const TextStyle(fontSize: 16, height: 1.3)), ws, maxHeight: 80),
        _Case('ellipsis, maxLines 3', (s) => Text(s, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)), ws),
        for (final lang in sameLayoutLocales)
          _Case('locale $lang', (s) => Text(s, locale: Locale(lang), style: const TextStyle(fontSize: 16)), ws),
      ]),
      (_Tree('bare tree', bare), [
        _Case('16 px', (s) => Text(s, style: const TextStyle(fontSize: 16)), ws),
      ]),
      (_Tree('Material app (bodyMedium)', material), [
        _Case('theme style', (s) => Text(s), ws, maxHeight: 60),
        _Case('theme style, 16 px, maxLines 3', (s) => Text(s, maxLines: 3, style: const TextStyle(fontSize: 16)), ws, maxHeight: 60),
        _Case('inherit: false, 16 px', (s) => Text(s, style: const TextStyle(inherit: false, fontFamily: family, fontSize: 16)), ws),
      ]),
      (_Tree('Material app, text scaled 1.15', scaled), [
        _Case('theme style', (s) => Text(s), ws),
      ]),
      (_Tree('Material app, bold text', bold), [
        _Case('theme style', (s) => Text(s), ws),
      ]),
      (_Tree('Material app, spacing overrides', spacedOverride), [
        _Case('theme style', (s) => Text(s), ws),
      ]),
    ];

    final only = Platform.environment['TEXT_API_ONLY'];
    for (final (tree, cases) in trees) {
      if (only != null && !tree.name.contains(only)) continue;
      for (final c in cases) {
        for (final w in c.widths) {
          var n = 0, widthEq = 0, heightEq = 0, fitEq = 0, linesEq = 0, widthSide = 0, linesSide = 0;
          final examples = <Object>[];
          for (var b = 0; b < texts.length; b += 300) {
            final batch = [for (final s in texts.sublist(b, math.min(b + 300, texts.length))) c.text(s)];
            final column = OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: w,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Column(key: _key, crossAxisAlignment: CrossAxisAlignment.start, children: batch),
            );
            await tester.pumpWidget(tree.wrap(column));
            final ctx = tester.element(find.byKey(_key));
            final rps = tester
                .renderObjectList<RenderParagraph>(find.descendant(of: find.byKey(_key), matching: find.byType(RichText)))
                .toList();
            expect(rps.length, batch.length);
            for (var i = 0; i < batch.length; i++) {
              final rp = rps[i], m = batch[i].measure(tree.context ? ctx : null);
              n++;
              final h = m.height(w);
              final fits = m.canFit(w, maxHeight: c.maxHeight);
              final realFits = !rp.didExceedMaxLines && rp.size.height <= c.maxHeight && rp.textSize.width <= w;
              final lines = m.lineCount(w);
              final realLines = _lineCount(rp);
              final okW = w.isFinite || m.width == rp.size.width;
              if (okW) widthEq++;
              if (h == rp.size.height) heightEq++;
              if (fits == realFits) fitEq++;
              if (lines == realLines) linesEq++;
              if (w.isInfinite && m.widthFromSidecar) widthSide++;
              if (m.linesFromSidecar(w)) linesSide++;
              if ((!okW || h != rp.size.height || fits != realFits || lines != realLines) && examples.length < 4) {
                examples.add({
                  'text': batch[i].data!.length > 60 ? batch[i].data!.substring(0, 60) : batch[i].data,
                  'width': [m.width, rp.size.width],
                  'height': [h, rp.size.height],
                  'canFit': [fits, realFits],
                  'lines': [lines, realLines],
                });
              }
            }
          }
          final key = '${tree.name} / ${c.name} / ${w.isFinite ? '$w px' : 'unbounded'}';
          final bad = n * 4 - widthEq - heightEq - fitEq - linesEq;
          different += bad;
          out[key] = {
            'texts': n,
            if (w.isInfinite) 'widthEqual': widthEq,
            'heightEqual': heightEq,
            'canFitEqual': fitEq,
            'lineCountEqual': linesEq,
            if (w.isInfinite) 'widthFromSidecar': widthSide,
            'linesFromSidecar': linesSide,
            if (examples.isNotEmpty) 'examples': examples,
          };
          // ignore: avoid_print
          print('$key: ${jsonEncode(out[key])}');
        }
      }
    }
    out['different'] = different;
    File(Platform.environment['TEXT_API_OUT'] ?? 'results/text_api.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    expect(different, 0);
  }, timeout: const Timeout(Duration(minutes: 40)));
}

Widget _noWrap(Widget c) => Directionality(
  textDirection: TextDirection.ltr,
  child: DefaultTextStyle(style: BreakFirst.defaultTextStyle, child: c),
);

/// The widget's own line count: its TextPainter's lines, read back through the
/// render object's caret boxes (one per line start).
int _lineCount(RenderParagraph rp) {
  final boxes = rp.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: rp.text.toPlainText().length));
  final tops = <double>{for (final b in boxes) b.top};
  return tops.isEmpty ? 1 : tops.length;
}
