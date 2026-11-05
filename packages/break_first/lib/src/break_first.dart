import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'dictionary_break.dart';
import 'engine.dart';
import 'width_model.dart';

/// Style options the breaker models, each measured against Flutter: letter and
/// word spacing (px), the height multiplier, maxLines, and the paragraph's strut
/// and TextHeightBehavior (pass the same to the Text widget).
class LineOptions {
  const LineOptions({
    this.letterSpacing = 0,
    this.wordSpacing = 0,
    this.height,
    this.maxLines,
    this.strutStyle,
    this.textHeightBehavior,
  });
  final double letterSpacing, wordSpacing;
  final double? height;
  final int? maxLines;

  /// Only line heights depend on these, not line breaks. With either set,
  /// heights come from three Flutter layouts per style (see [probeLineHeights]).
  final StrutStyle? strutStyle;
  final TextHeightBehavior? textHeightBehavior;

  static const plain = LineOptions();

  bool get _probed => strutStyle != null || textHeightBehavior != null;

  /// [strutStyle] as the engine takes it.
  ui.StrutStyle? get uiStrutStyle {
    final s = strutStyle;
    return s == null
        ? null
        : ui.StrutStyle(
            fontFamily: s.fontFamily,
            fontFamilyFallback: s.fontFamilyFallback,
            fontSize: s.fontSize,
            height: s.height,
            leadingDistribution: s.leadingDistribution,
            leading: s.leading,
            fontWeight: s.fontWeight,
            fontStyle: s.fontStyle,
            forceStrutHeight: s.forceStrutHeight,
          );
  }
}

/// Exact line breaks and heights for single-style paragraphs in one font, from
/// the font's sidecar, without shaping.
///
/// The predictions describe text laid out with [style]: one style, left to
/// right, with the [LineOptions] given (letter and word spacing, height
/// multiplier, maxLines, strut) and hard line breaks (\n, U+2028, U+2029), and
/// the [fontFeatures] the sidecar was built with. A paragraph the breaker cannot decide exactly (a character outside
/// the certificate, a word wider than the line, a fit decision within float
/// error) gets null from [prepare] and [lineStarts], and [height] lays it out
/// with Flutter instead.
class BreakFirst {
  BreakFirst._(this.model, this.fontFamily, this.canaryErrorPx, this.fontFeatures);

  final WidthModel model;
  final String fontFamily;

  /// The font features the sidecar was built and certified with.
  final List<FontFeature>? fontFeatures;

  /// Largest canary error on this device, px at 16 px.
  final double canaryErrorPx;

  static final _registered = <String, BreakFirst>{};

  /// The DefaultTextStyle a [Text] is measured under without a BuildContext
  /// (`Text(...).width`): by default none, as for a Text built outside any theme.
  static TextStyle defaultTextStyle = const TextStyle();

  /// Lets `Text(...).width`, `height`, `lineCount` and `canFit` answer from this
  /// sidecar for text in [fontFamily]. With [asDefault], a Text measured without
  /// a BuildContext and without a font family is measured in this font, as under
  /// a theme with this font family.
  void register({bool asDefault = false}) {
    _registered[fontFamily] = this;
    if (asDefault) defaultTextStyle = defaultTextStyle.copyWith(fontFamily: fontFamily);
  }

  /// The sidecar registered for [fontFamily], if any.
  static BreakFirst? registered(String? fontFamily) => _registered[fontFamily];

  /// Decodes [sidecar] and checks it against this engine: calibrates the
  /// engine's conventions (font-size rounding, kerning before a hard break) and
  /// measures the canary strings. Returns null
  /// when the canary fails, that is when the sidecar does not describe the font
  /// loaded under [fontFamily] on this device; then lay everything out with
  /// Flutter. A sidecar built with font features is loaded with the same
  /// [fontFeatures]; the canary is measured with them. With [font], the bytes
  /// loaded under [fontFamily], it also returns null when they are not the font
  /// the sidecar was built from (a font updated without rebuilding its sidecar,
  /// which the canary strings may not show).
  static BreakFirst? load(Uint8List sidecar,
      {required String fontFamily, List<FontFeature>? fontFeatures, Uint8List? font}) {
    final md = WidthModel.decode(sidecar);
    if (font != null && md.fontDigest != null && md.fontDigest != fontDigest(font)) return null;
    calibrateEngine(md, fontFamily, fontFeatures: fontFeatures);
    final err = canaryError(md, fontFamily, fontFeatures: fontFeatures);
    return err < 1e-3 ? BreakFirst._(md, fontFamily, err, fontFeatures) : null;
  }

  /// The style whose layout this object predicts.
  TextStyle style(double fontSize, [LineOptions options = LineOptions.plain]) => TextStyle(
    inherit: false,
    fontFamily: fontFamily,
    fontSize: fontSize,
    letterSpacing: options.letterSpacing == 0 ? null : options.letterSpacing,
    wordSpacing: options.wordSpacing == 0 ? null : options.wordSpacing,
    height: options.height,
    fontFeatures: fontFeatures,
  );

  /// Height of one line at [fontSize], in px (with a strut or
  /// TextHeightBehavior, of a line other than the first and last).
  double lineHeight(double fontSize, [LineOptions options = LineOptions.plain]) => options._probed
      ? _probe(fontSize, options).three - _probe(fontSize, options).two
      : lineHeightPx(model, fontSize, height: options.height);

  /// Height of a paragraph of [lines] lines at [fontSize], in px.
  double heightOfLines(int lines, double fontSize, [LineOptions options = LineOptions.plain]) => options._probed
      ? _probe(fontSize, options).of(lines)
      : lines * lineHeightPx(model, fontSize, height: options.height);

  final _probes = <(double, double?, StrutStyle?, TextHeightBehavior?), LineHeights>{};
  LineHeights _probe(double fontSize, LineOptions o) =>
      _probes[(fontSize, o.height, o.strutStyle, o.textHeightBehavior)] ??= probeLineHeights(
        fontFamily: fontFamily,
        fontSize: fontSize,
        height: o.height,
        strut: o.uiStrutStyle,
        textHeightBehavior: o.textHeightBehavior,
      );

  /// One pass over [text] that makes re-wrapping at any width and size cheap, or
  /// null when Flutter must lay this paragraph out. Letter-spaced text needs its
  /// own preparation (with positive spacing the engine shapes without ligatures).
  PreparedParagraph? prepare(String text, [LineOptions options = LineOptions.plain]) {
    final r = buildRecords(model, text, letterSpacing: options.letterSpacing);
    return r == null ? null : PreparedParagraph._(this, text, r, options);
  }

  /// Offsets where Flutter starts each line of [text], or null when Flutter must
  /// lay it out. With maxLines, only the lines Flutter shows.
  List<int>? lineStarts(
    String text, {
    required double fontSize,
    required double maxWidth,
    LineOptions options = LineOptions.plain,
  }) => prepare(text, options)?.lineStarts(fontSize: fontSize, maxWidth: maxWidth);

  /// Height of [text] in px, equal to Flutter's: from the sidecar when it
  /// decides, otherwise from Flutter's layout.
  double height(
    String text, {
    required double fontSize,
    required double maxWidth,
    LineOptions options = LineOptions.plain,
  }) =>
      prepare(text, options)?.height(fontSize: fontSize, maxWidth: maxWidth) ??
      _richHeight(text, fontSize, maxWidth, options) ??
      flutterHeight(text, fontSize: fontSize, maxWidth: maxWidth, options: options);

  /// Text the plain path leaves to Flutter that the rich path decides: emoji and
  /// Brahmic letters from the device's fallback font (measured once each).
  double? _richHeight(String text, double fontSize, double maxWidth, LineOptions o) {
    if (o.maxLines != null || o._probed || model.rtl) return null;
    return RichParagraph.prepare([
      RichSpan(text, this, fontSize, height: o.height),
    ], letterSpacing: o.letterSpacing, wordSpacing: o.wordSpacing)?.height(maxWidth);
  }

  /// Height of [text] from Flutter's own layout.
  double flutterHeight(
    String text, {
    required double fontSize,
    required double maxWidth,
    LineOptions options = LineOptions.plain,
  }) {
    final p = layoutParagraph(
      text,
      fontFamily: fontFamily,
      fontSize: fontSize,
      width: maxWidth,
      letterSpacing: options.letterSpacing,
      wordSpacing: options.wordSpacing,
      height: options.height,
      maxLines: options.maxLines,
      rtl: model.rtl,
      strut: options.uiStrutStyle,
      textHeightBehavior: options.textHeightBehavior,
      fontFeatures: fontFeatures,
    );
    final h = p.height;
    p.dispose();
    return h;
  }
}

/// A paragraph's width prefix and break opportunities, for wrapping at any width.
class PreparedParagraph {
  PreparedParagraph._(this._bf, this.text, this.records, this.options);

  final BreakFirst _bf;
  final String text;
  final Records records;
  final LineOptions options;

  /// Line starts (with maxLines, of the lines shown), or null when Flutter must
  /// decide at this width.
  List<int>? lineStarts({required double fontSize, required double maxWidth}) {
    final starts = records.lineStarts(
      maxWidth,
      scaleFor(_bf.model, fontSize),
      letterSpacing: options.letterSpacing,
      wordSpacing: options.wordSpacing,
    );
    final m = options.maxLines;
    return starts == null || m == null || starts.length <= m ? starts : starts.sublist(0, m);
  }

  /// Number of lines shown, or null when Flutter must decide at this width.
  int? lineCount({required double fontSize, required double maxWidth}) =>
      lineStarts(fontSize: fontSize, maxWidth: maxWidth)?.length;

  /// Whether the text has more lines than maxLines allows (Flutter's
  /// didExceedMaxLines), or null when Flutter must decide.
  bool? exceedsMaxLines({required double fontSize, required double maxWidth}) {
    final n = records.lineCount(
      maxWidth,
      scaleFor(_bf.model, fontSize),
      letterSpacing: options.letterSpacing,
      wordSpacing: options.wordSpacing,
    );
    return n < 0 ? null : exceedsLines(text, n, options.maxLines);
  }

  /// Height in px, or null when Flutter must decide at this width.
  double? height({required double fontSize, required double maxWidth}) {
    final n = lineCount(fontSize: fontSize, maxWidth: maxWidth);
    return n == null ? null : _bf.heightOfLines(n, fontSize, options);
  }
}

/// Flutter's didExceedMaxLines for a paragraph of [lines] lines: more than
/// [maxLines], except that the empty line after a final hard break is not cut
/// (measured: "a\nb\n" in 2 lines does not exceed). Null when the cut lines would
/// be empty lines only after more hard breaks, which is not measured.
bool? exceedsLines(String text, int lines, int? maxLines) {
  if (maxLines == null || lines <= maxLines) return false;
  if (text.isEmpty || !isHardBreak(text.codeUnitAt(text.length - 1))) return true;
  if (lines > maxLines + 1) return true;
  return text.length >= 2 && isHardBreak(text.codeUnitAt(text.length - 2)) ? null : false;
}

/// One span of a rich paragraph: [text] in [font] (a loaded sidecar) at
/// [fontSize], with an optional height multiplier. Colour, background and
/// decoration do not change layout (measured: shaping runs across them), so
/// spans that differ only in those can be given as one.
///
/// [fallback] are the span's fontFamilyFallback fonts, bundled with the app and
/// each with its sidecar: a character goes to the first of [font] and [fallback]
/// whose font has it, as Flutter resolves fonts. A character none of them has
/// would come from the device's own fallback fonts, so such a paragraph goes to
/// Flutter.
class RichSpan {
  const RichSpan(this.text, this.font, this.fontSize, {this.height, this.fallback = const []});
  final String text;
  final BreakFirst font;
  final double fontSize;
  final double? height;
  final List<BreakFirst> fallback;

  /// The style Flutter lays this span out with.
  TextStyle get style => TextStyle(
    inherit: false,
    fontFamily: font.fontFamily,
    fontSize: fontSize,
    height: height,
    fontFeatures: font.fontFeatures,
    fontFamilyFallback: fallback.isEmpty ? null : [for (final f in fallback) f.fontFamily],
  );
}

/// Exact line breaks and heights for rich text: left-to-right spans in several
/// fonts and sizes, with one letter and word spacing for the whole paragraph.
/// A change of font or size starts a new shaping run (no kerning across it); a
/// line is as high as round(largest ascent + largest descent) of the styles on it
/// (measured).
///
/// Emoji that no sidecar's font has come from the device's fallback font, which
/// differs between devices: each run of emoji clusters is measured once through
/// Flutter on this device (widths and line metrics, cached), which is exact
/// because the font change makes it a shaping run of its own. Not with letter
/// spacing.
class RichParagraph {
  RichParagraph._(this.text, this.records, this.letterSpacing, this.wordSpacing, this._styleOf, this._metrics);

  final String text;
  final Records records;
  final double letterSpacing, wordSpacing;
  final Int32List _styleOf; // per code unit: index into _metrics
  final List<(double, double)> _metrics; // ascent, descent per style

  /// Null when Flutter must lay the paragraph out (a character outside a
  /// certificate, a right-to-left sidecar).
  static RichParagraph? prepare(List<RichSpan> spans, {double letterSpacing = 0, double wordSpacing = 0}) {
    final text = spans.map((s) => s.text).join();
    if (text.isEmpty || spans.any((s) => s.font.model.rtl || s.fallback.any((f) => f.model.rtl))) return null;
    final runs = <(int, int, WidthModel?, double)>[];
    final styleOf = Int32List(text.length);
    final styles = <(BreakFirst, double, double?)>[];
    var at = 0;
    BreakFirst? current;
    final device = <(int, int, RichSpan)>[]; // runs from the device's fallback font
    final scriptRuns = <int>{}; // those of letters (not emoji), by start
    final blockStarts = <int>{}; // spans of another style than the one before
    RichSpan? before;
    for (final s in spans) {
      if (s.text.isEmpty) continue;
      if (before != null &&
          (!identical(before.font, s.font) ||
              before.fontSize != s.fontSize ||
              before.height != s.height ||
              before.fallback.length != s.fallback.length ||
              [for (var k = 0; k < s.fallback.length; k++) identical(before.fallback[k], s.fallback[k])].contains(false))) {
        blockStarts.add(at);
      }
      before = s;
      final fonts = [s.font, ...s.fallback];
      current = null;
      for (var i = 0; i < s.text.length;) {
        final cu = s.text.codeUnitAt(i);
        // An emoji cluster, or a run of Brahmic letters, no bundled font has: the
        // device's fallback font.
        var e = emojiClusterEnd(s.text, i);
        // The danda (U+0964, U+0965) comes from the same fallback font. Thai, Lao,
        // Khmer and Burmese (class SA) runs are measured the same way, with
        // offsets at their dictionary breaks.
        final sa = e == i && isComplexContext(cu);
        bool inRun(int x) => sa ? isComplexContext(x) : isBrahmic(x) || x == 0x964 || x == 0x965;
        final brahmic = e == i && (sa || inRun(cu));
        if (brahmic) {
          e = i + 1;
          while (e < s.text.length) {
            final x = s.text.codeUnitAt(e);
            if (!inRun(x) && x != 0x200C && x != 0x200D) break;
            // A joiner the bundled font has would split Flutter's fallback run.
            if ((x == 0x200C || x == 0x200D) && fonts.any((c) => c.model.hasCodePoint(x) != false)) return null;
            e++;
          }
        }
        if (e > i &&
            fonts.every((c) => c.model.hasCodePoint(_cp(s.text, i)) == false) &&
            (!brahmic ||
                [for (var k = i; k < e; k++) s.text.codeUnitAt(k)]
                    .where((x) => x != 0x200C && x != 0x200D)
                    .every((x) => fonts.every((c) => c.model.hasCodePoint(x) == false)))) {
          if (letterSpacing != 0) return null;
          final start = at + i, end = at + e;
          final last = device.isEmpty ? null : device.last;
          if (last != null && last.$2 == start && identical(last.$3, s) && !brahmic && !scriptRuns.contains(last.$1)) {
            device[device.length - 1] = (last.$1, end, s);
            runs[runs.length - 1] = (runs.last.$1, end, null, 0);
          } else {
            device.add((start, end, s));
            runs.add((start, end, null, 0));
            if (brahmic) scriptRuns.add(start);
          }
          current = null;
          i = e;
          continue;
        }
        final pair = cu >= 0xD800 && cu < 0xDC00 && i + 1 < s.text.length;
        final cp = pair ? 0x10000 + ((cu - 0xD800) << 10) + (s.text.codeUnitAt(i + 1) - 0xDC00) : cu;
        final n = pair ? 2 : 1;
        // Font fallback: the first font that has the character. Controls (hard
        // breaks among them) stay in the current font.
        BreakFirst? f;
        if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0) || isHardBreak(cp)) {
          f = current ?? s.font;
        } else {
          for (final c in fonts) {
            final has = c.model.hasCodePoint(cp) ?? (cp < 0x10000 && c.model.idOf[cp] != 0 ? true : null);
            if (has == null) return null; // a sidecar without coverage cannot rule its font out
            if (has) {
              f = c;
              break;
            }
          }
        }
        if (f == null) return null; // the device's fallback fonts
        current = f;
        final start = at + i, end = start + n;
        final scale = scaleFor(f.model, s.fontSize);
        final last = runs.isEmpty ? null : runs.last;
        if (last != null && last.$2 == start && last.$3 != null && identical(last.$3, f.model) && last.$4 == scale) {
          runs[runs.length - 1] = (last.$1, end, last.$3, scale); // same font and size: one shaping run
        } else {
          runs.add((start, end, f.model, scale));
        }
        final key = (f, s.fontSize, s.height);
        var k = styles.indexOf(key);
        if (k < 0) {
          k = styles.length;
          styles.add(key);
        }
        styleOf.fillRange(start, end, k);
        i += n;
      }
      at += s.text.length;
    }
    final measured = <int, Float64List>{};
    final metrics = [
      for (final (f, size, h) in styles)
        probeAscentDescent(fontFamily: f.fontFamily, fontSize: size, height: h, fontFeatures: f.fontFeatures),
    ];
    for (final (a, b, span) in device) {
      final (offsets, ascent, descent) = _measureDevice(text.substring(a, b), span);
      measured[a] = offsets;
      styleOf.fillRange(a, b, metrics.length);
      metrics.add((ascent, descent));
    }
    final r = buildRichRecords(text, runs,
        letterSpacing: letterSpacing, measured: measured, scriptRuns: scriptRuns, blockStarts: blockStarts);
    if (r == null) return null;
    return RichParagraph._(text, r, letterSpacing, wordSpacing, styleOf, metrics);
  }

  static int _cp(String t, int i) {
    final cu = t.codeUnitAt(i);
    return cu >= 0xD800 && cu < 0xDC00 && i + 1 < t.length
        ? 0x10000 + ((cu - 0xD800) << 10) + (t.codeUnitAt(i + 1) - 0xDC00)
        : cu;
  }

  static final _device = <String, (Float64List, double, double)>{};

  /// A run of emoji clusters laid out alone by Flutter in [span]'s style: the px
  /// offset of every code unit (NaN inside a cluster), the run's width last, and
  /// the line's ascent and descent. Cached per run and style.
  static (Float64List, double, double) _measureDevice(String run, RichSpan span) {
    final key = [run, span.font.fontFamily, ...span.fallback.map((f) => f.fontFamily), span.fontSize, span.height]
        .join('\u0000');
    final hit = _device[key];
    if (hit != null) return hit;
    final b = ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: ui.TextDirection.ltr))
      ..pushStyle(span.style.getTextStyle())
      ..addText(run);
    final p = b.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
    final offsets = Float64List(run.length + 1)..fillRange(0, run.length, double.nan);
    offsets[0] = 0;
    for (var i = 0; i < run.length;) {
      final e = emojiClusterEnd(run, i);
      if (e == i) {
        // Letters: no break inside a Brahmic run (LB28a) but after a danda; in a
        // Thai, Lao, Khmer or Burmese run, at the dictionary breaks.
        final at = isComplexContext(run.codeUnitAt(0))
            ? (dictionaryBreaks(run, 0, run.length) ?? const <int>[])
            : [for (var k = 1; k < run.length; k++) if (const {0x964, 0x965}.contains(run.codeUnitAt(k - 1))) k];
        for (final k in at) {
          final boxes = p.getBoxesForRange(0, k);
          offsets[k] = boxes.isEmpty ? 0 : boxes.map((x) => x.right).reduce((x, y) => x > y ? x : y);
        }
        offsets[run.length] = p.computeLineMetrics().first.width;
        break;
      }
      final boxes = p.getBoxesForRange(0, e);
      offsets[e] = boxes.isEmpty ? 0 : boxes.map((x) => x.right).reduce((x, y) => x > y ? x : y);
      i = e;
    }
    final m = p.computeLineMetrics().first;
    p.dispose();
    return _device[key] = (offsets, m.ascent, m.descent);
  }

  /// Line starts in a box [maxWidth] px wide, or null when Flutter must decide.
  List<int>? lineStarts(double maxWidth) =>
      records.lineStarts(maxWidth, 1.0, letterSpacing: letterSpacing, wordSpacing: wordSpacing);

  /// Height in px, or null when Flutter must decide.
  double? height(double maxWidth) {
    final starts = lineStarts(maxWidth);
    if (starts == null) return null;
    var h = 0.0;
    for (var l = 0; l < starts.length; l++) {
      final end = l + 1 < starts.length ? starts[l + 1] : text.length;
      var a = 0.0, d = 0.0;
      for (var i = starts[l]; i < end; i++) {
        final m = _metrics[_styleOf[i]];
        if (m.$1 > a) a = m.$1;
        if (m.$2 > d) d = m.$2;
      }
      h += (a + d).roundToDouble();
    }
    return h;
  }
}
