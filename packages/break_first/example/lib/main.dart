// Exact list extents for a chat list. Left: a stock ListView, which learns item
// heights only by laying items out, so it can only estimate where message #N is
// and must lay out every message between here and a far scroll position. Right:
// the same list with item extents from break-first, computed before any layout.
//
// Every number on screen is measured live, and every bubble the right-hand list
// lays out is checked against the height break-first predicted for it.
// --dart-define=AUTOPLAY=true runs a scripted tour (used to record the video).
import 'dart:async';

import 'package:break_first/break_first.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'messages.dart';

const family = 'RobotoSidecar';
const autoplay = bool.fromEnvironment('AUTOPLAY');
const count = 10000;
const padH = 10.0, padV = 8.0, gap = 6.0, listPad = 8.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final data = await rootBundle.load('assets/roboto.bfw');
  final font = await rootBundle.load('assets/Roboto-Regular.ttf'); // the font behind [family]
  final bf = BreakFirst.load(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      fontFamily: family, font: font.buffer.asUint8List(font.offsetInBytes, font.lengthInBytes));
  runApp(DemoApp(demo: Demo(bf, chatMessages(count))));
}

/// Numbers also go to the log, so a recording run reports them (logcat, CI).
void _log(String line) => debugPrint('DEMO $line');

String _n(num v) => v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
String _ms(double v) => v < 10 ? v.toStringAsFixed(1) : _n(v);

/// Messages, text size, and break-first's extents for the current text width.
class Demo extends ChangeNotifier {
  Demo(this.bf, this.messages);

  final BreakFirst? bf;
  final List<String> messages;
  double fontSize = 15;
  String caption = '';
  String result = '';
  int? target; // the message the last jump asked for

  List<PreparedParagraph?>? _prepared;
  double _width = -1, _size = -1;
  late List<double> extents, offsets; // offsets[i]: top of item i in the list
  double extentsMs = 0, flutterMs = 0; // break-first's part, and the paragraphs it hands to Flutter
  bool firstPass = true;
  int toFlutter = 0;

  TextStyle get style => bf?.style(fontSize) ?? TextStyle(inherit: false, fontFamily: family, fontSize: fontSize);

  double _flutterHeight(String m, double w) {
    final p = layoutParagraph(m, fontFamily: family, fontSize: fontSize, width: w);
    final h = p.height;
    p.dispose();
    return h;
  }

  /// Extents for text [width] px wide: one pass over each message the first
  /// time, then only the greedy wrap.
  void ensureExtents(double width) {
    if (width == _width && fontSize == _size) return;
    final sw = Stopwatch()..start(), fl = Stopwatch();
    firstPass = _prepared == null;
    final prepared = _prepared ??= [for (final m in messages) bf?.prepare(m)];
    extents = List<double>.filled(messages.length, 0);
    offsets = List<double>.filled(messages.length + 1, 0);
    toFlutter = 0;
    for (var i = 0; i < messages.length; i++) {
      var h = prepared[i]?.height(fontSize: fontSize, maxWidth: width);
      if (h == null) {
        toFlutter++;
        fl.start();
        h = _flutterHeight(messages[i], width);
        fl.stop();
      }
      extents[i] = h + 2 * padV + gap;
      offsets[i + 1] = offsets[i] + extents[i];
    }
    flutterMs = fl.elapsedMicroseconds / 1000;
    extentsMs = sw.elapsedMicroseconds / 1000 - flutterMs;
    _log(
      'extents ${firstPass ? 'first' : 're-wrap'} size=$fontSize width=$width breakFirstMs=$extentsMs '
      'flutterMs=$flutterMs toFlutter=$toFlutter',
    );
    _width = width;
    _size = fontSize;
  }

  double get width => _width;

  void say(String text) {
    caption = text;
    notifyListeners();
  }

  void setFontSize(double size) {
    fontSize = size;
    notifyListeners();
  }

  /// Every extent against TextPainter, configured as the Text widget is.
  void verify(Locale? locale) {
    final sw = Stopwatch()..start();
    var equal = 0;
    for (var i = 0; i < messages.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: messages[i], style: style),
        textDirection: TextDirection.ltr,
        locale: locale,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: _width);
      if ((tp.height + 2 * padV + gap - extents[i]).abs() < 1e-6) equal++;
      tp.dispose();
    }
    final tpMs = sw.elapsedMicroseconds / 1000;
    result =
        '${_n(equal)} of ${_n(messages.length)} heights equal to TextPainter\'s. '
        'TextPainter: ${_ms(tpMs)} ms for all; break-first: ${_ms(extentsMs + flutterMs)} ms.';
    _log('verify size=$fontSize equal=$equal of ${messages.length} textPainterMs=$tpMs');
    notifyListeners();
  }
}

/// One list: its controller, the probes of its laid-out bubbles, and its labels.
class Side {
  Side(this.exact);
  final bool exact;
  final controller = ScrollController();
  final probes = <_RenderProbe>{};
  final listKey = GlobalKey();
  int checked = 0, wrong = 0;
  String status = '';
  bool? landed; // whether the last jump put the asked-for message at the top

  /// Index of the first message visible at the top of the list.
  int? firstVisible() {
    final box = listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    int? best;
    for (final p in probes) {
      if (!p.attached || !p.hasSize) continue;
      final top = p.localToGlobal(Offset.zero, ancestor: box).dy;
      if (top + p.size.height > 1 && top < box.size.height && (best == null || p.index < best)) best = p.index;
    }
    return best;
  }
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key, required this.demo});
  final Demo demo;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF3B6EA5)),
    home: DemoPage(demo: demo),
  );
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key, required this.demo});
  final Demo demo;

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final stock = Side(false), exact = Side(true);
  Demo get demo => widget.demo;

  @override
  void initState() {
    super.initState();
    demo.addListener(_changed);
    if (autoplay) SchedulerBinding.instance.addPostFrameCallback((_) => _tour());
  }

  @override
  void dispose() {
    demo.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  /// Runs [action] and returns the build, layout and paint time of the frame
  /// that follows it.
  Future<double> _timedFrame(VoidCallback action) {
    final done = Completer<double>();
    final sw = Stopwatch();
    SchedulerBinding.instance.scheduleFrameCallback((_) => sw.start());
    action();
    SchedulerBinding.instance.addPostFrameCallback((_) => done.complete(sw.elapsedMicroseconds / 1000));
    SchedulerBinding.instance.scheduleFrame();
    return done.future;
  }

  Future<void> _jump(Side side, int index) async {
    final pos = side.controller.position;
    // The stock list can only estimate: its scroll extent is an average of the
    // heights it has laid out so far.
    final target = side.exact
        ? listPad + demo.offsets[index]
        : (pos.maxScrollExtent + pos.viewportDimension) * index / count;
    demo.target = index;
    final ms = await _timedFrame(() => side.controller.jumpTo(target.clamp(0.0, pos.maxScrollExtent)));
    await SchedulerBinding.instance.endOfFrame;
    final at = side.firstVisible();
    setState(() {
      side.landed = at == index;
      side.status =
          'Asked #${_n(index)}, top is #${at == null ? '?' : _n(at)} ${at == index ? '✓' : '✗'}\n'
          'Jump frame: ${_ms(ms)} ms';
    });
    _log('jump ${side.exact ? 'breakFirst' : 'stock'} to=$index at=$at frameMs=$ms');
  }

  Future<void> _tour() async {
    Future<void> wait(double s) => Future.delayed(Duration(milliseconds: (s * 1000).round()));
    await wait(1.5);
    demo.say('The same 10,000 messages on both sides.');
    await wait(2.5);
    demo.say('Scrolling: both are smooth.');
    await Future.wait([
      for (final s in [stock, exact])
        s.controller.animateTo(4000, duration: const Duration(milliseconds: 1800), curve: Curves.easeInOut),
    ]);
    await wait(1.0);
    demo.say('Tap a reply: jump to the quoted message, #2,500.');
    await wait(1.5);
    await _jump(stock, 2500);
    await wait(1.2);
    await _jump(exact, 2500);
    await wait(3.0);
    demo.say('Jump back to message #300.');
    await wait(1.5);
    await _jump(stock, 300);
    await wait(1.2);
    await _jump(exact, 300);
    await wait(3.0);
    demo.say('Text size 15 → 18 px: every extent is re-wrapped.');
    await wait(1.0);
    demo.setFontSize(18);
    await wait(3.5);
    demo.say('Check: every right-hand extent against TextPainter.');
    await wait(1.0);
    if (mounted) demo.verify(Localizations.maybeLocaleOf(context));
    await wait(5.0);
    demo.say('Exact extents, before layout, from one sidecar file.');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Exact list extents'),
        actions: [
          IconButton(
            tooltip: 'Jump to #2,500',
            icon: const Icon(Icons.reply),
            onPressed: () async {
              await _jump(stock, 2500);
              await _jump(exact, 2500);
            },
          ),
          IconButton(
            tooltip: 'Text size',
            icon: const Icon(Icons.text_increase),
            onPressed: () => demo.setFontSize(demo.fontSize >= 22 ? 14 : demo.fontSize + 1),
          ),
          IconButton(
            tooltip: 'Check against TextPainter',
            icon: const Icon(Icons.fact_check),
            onPressed: () => demo.verify(Localizations.maybeLocaleOf(context)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final col = (box.maxWidth - 1) / 2;
                final textWidth = ((col - 2 * listPad) * 0.86).floorToDouble() - 2 * padH;
                if (textWidth < 40) return const SizedBox.expand(); // the window has no size yet
                demo.ensureExtents(textWidth);
                return Row(
                  children: [
                    SizedBox(width: col, child: _column(stock, textWidth, scheme)),
                    Container(width: 1, color: scheme.outlineVariant),
                    SizedBox(width: col, child: _column(exact, textWidth, scheme)),
                  ],
                );
              },
            ),
          ),
          _footer(scheme),
        ],
      ),
    );
  }

  Widget _footer(ColorScheme scheme) {
    final lines = [if (demo.caption.isNotEmpty) demo.caption, if (demo.result.isNotEmpty) demo.result];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xFF1B1B1F),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Text(lines.join('\n'), style: const TextStyle(color: Colors.white, fontSize: 17, height: 1.35)),
    );
  }

  Widget _column(Side side, double textWidth, ColorScheme scheme) {
    final style = demo.style;
    Widget bubble(BuildContext context, int i) {
      final mine = i % 3 == 0;
      final isTarget = i == demo.target;
      // The message number sits beside the bubble, positioned, so it takes no
      // part in the layout whose height is predicted.
      return Padding(
        padding: const EdgeInsets.only(bottom: gap),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Align(
              alignment: mine ? Alignment.topRight : Alignment.topLeft,
              child: _Probe(
                index: i,
                side: side,
                expected: side.exact ? demo.extents[i] - gap : null,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: textWidth + 2 * padH),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      // Drawn over the bubble's edge, outside layout.
                      boxShadow: isTarget ? const [BoxShadow(color: Color(0xFFE8710A), spreadRadius: 3)] : null,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: padH, vertical: padV),
                      child: Text(
                        demo.messages[i],
                        style: style.copyWith(color: scheme.onSurface),
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 2,
              left: mine ? 0 : null,
              right: mine ? null : 0,
              child: Text(
                '#${_n(i)}',
                style: TextStyle(
                  fontSize: 10,
                  color: isTarget ? const Color(0xFFE8710A) : scheme.outline,
                  fontWeight: isTarget ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // The break-first side also tells the list its exact total height; a stock
    // delegate leaves the list to extrapolate it from the children laid out so far
    // (even with itemExtentBuilder).
    final list = side.exact
        ? ListView.custom(
            key: side.listKey,
            controller: side.controller,
            padding: const EdgeInsets.all(listPad),
            itemExtentBuilder: (i, _) => i < count ? demo.extents[i] : null,
            childrenDelegate: _ExactDelegate(bubble, childCount: count, total: demo.offsets[count]),
          )
        : ListView.builder(
            key: side.listKey,
            controller: side.controller,
            padding: const EdgeInsets.all(listPad),
            itemCount: count,
            itemBuilder: bubble,
          );
    final title = side.exact ? 'break-first extents' : 'Stock ListView';
    final total = side.exact ? listPad * 2 + demo.offsets[count] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: side.exact ? scheme.primaryContainer.withValues(alpha: 0.5) : scheme.surfaceContainer,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: DefaultTextStyle(
            style: TextStyle(fontSize: 12.5, color: scheme.onSurface, height: 1.3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                _ExtentLabel(side: side, exactTotal: total),
                Text(
                  side.exact
                      ? 'Extents${demo.firstPass ? '' : ' (re-wrap)'}: ${_ms(demo.extentsMs)} ms, '
                            '+ ${_ms(demo.flutterMs)} ms for ${_n(demo.toFlutter)} sent to Flutter'
                      : 'Extents: unknown until laid out',
                ),
                if (side.exact) Text('Bubbles laid out and checked: ${_n(side.checked)}, wrong: ${side.wrong}'),
                Text(
                  side.status.isEmpty ? ' \n ' : side.status,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: side.landed == null
                        ? null
                        : side.landed!
                        ? const Color(0xFF1E8E3E)
                        : const Color(0xFFC5221F),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Scrollbar(controller: side.controller, thumbVisibility: true, thickness: 6, child: list),
        ),
      ],
    );
  }
}

class _ExactDelegate extends SliverChildBuilderDelegate {
  _ExactDelegate(super.builder, {required super.childCount, required this.total});
  final double total;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => total;

  @override
  bool shouldRebuild(_ExactDelegate oldDelegate) => true;
}

/// The list's total scroll extent, as the list itself currently believes it.
class _ExtentLabel extends StatefulWidget {
  const _ExtentLabel({required this.side, required this.exactTotal});
  final Side side;
  final double? exactTotal;

  @override
  State<_ExtentLabel> createState() => _ExtentLabelState();
}

class _ExtentLabelState extends State<_ExtentLabel> {
  double? _extent;

  @override
  void initState() {
    super.initState();
    widget.side.controller.addListener(_update);
    SchedulerBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    widget.side.controller.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted || !widget.side.controller.hasClients) return;
    final p = widget.side.controller.position;
    if (!p.hasContentDimensions) return;
    final e = p.maxScrollExtent + p.viewportDimension;
    if (e != _extent) setState(() => _extent = e);
  }

  @override
  Widget build(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback((_) => _update());
    final e = _extent;
    if (e == null) return const Text(' ');
    return Text(
      widget.exactTotal != null ? 'Total height: ${_n(e)} px, exact' : 'Total height: ${_n(e)} px, estimated',
    );
  }
}

/// Wraps a bubble: registers it with its side, and on the break-first side
/// checks its laid-out height against the predicted one.
class _Probe extends SingleChildRenderObjectWidget {
  const _Probe({required this.index, required this.side, required this.expected, super.child});
  final int index;
  final Side side;
  final double? expected;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderProbe(index, side, expected);

  @override
  void updateRenderObject(BuildContext context, _RenderProbe r) => r
    ..index = index
    ..side = side
    ..expected = expected;
}

class _RenderProbe extends RenderProxyBox {
  _RenderProbe(this.index, this.side, this.expected);
  int index;
  Side side;
  double? expected;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    side.probes.add(this);
  }

  @override
  void detach() {
    side.probes.remove(this);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    final e = expected;
    if (e == null) return;
    side.checked++;
    if ((size.height - e).abs() > 1e-6) side.wrong++;
  }
}
