import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'engine.dart';
import 'width_model.dart';

/// Style options the breaker models, each measured against Flutter: letter and
/// word spacing (px), the height multiplier, and maxLines.
class LineOptions {
  const LineOptions({this.letterSpacing = 0, this.wordSpacing = 0, this.height, this.maxLines});
  final double letterSpacing, wordSpacing;
  final double? height;
  final int? maxLines;

  static const plain = LineOptions();
}

/// Exact line breaks and heights for single-style paragraphs in one font, from
/// the font's sidecar, without shaping.
///
/// The predictions describe text laid out with [style]: one style, left to
/// right, with the [LineOptions] given (letter and word spacing, height
/// multiplier, maxLines) and hard line breaks (\n, U+2028, U+2029), but no font
/// features. A paragraph the breaker cannot decide exactly (a character outside
/// the certificate, a word wider than the line, a fit decision within float
/// error) gets null from [prepare] and [lineStarts], and [height] lays it out
/// with Flutter instead.
class BreakFirst {
  BreakFirst._(this.model, this.fontFamily, this.canaryErrorPx);

  final WidthModel model;
  final String fontFamily;

  /// Largest canary error on this device, px at 16 px.
  final double canaryErrorPx;

  /// Decodes [sidecar] and checks it against this engine: calibrates the
  /// engine's conventions (font-size rounding, kerning before a hard break) and
  /// measures the canary strings. Returns null
  /// when the canary fails, that is when the sidecar does not describe the font
  /// loaded under [fontFamily] on this device; then lay everything out with
  /// Flutter.
  static BreakFirst? load(Uint8List sidecar, {required String fontFamily}) {
    final md = WidthModel.decode(sidecar);
    calibrateEngine(md, fontFamily);
    final err = canaryError(md, fontFamily);
    return err < 1e-3 ? BreakFirst._(md, fontFamily, err) : null;
  }

  /// The style whose layout this object predicts.
  TextStyle style(double fontSize, [LineOptions options = LineOptions.plain]) => TextStyle(
    inherit: false,
    fontFamily: fontFamily,
    fontSize: fontSize,
    letterSpacing: options.letterSpacing == 0 ? null : options.letterSpacing,
    wordSpacing: options.wordSpacing == 0 ? null : options.wordSpacing,
    height: options.height,
  );

  /// Height of one line at [fontSize], in px.
  double lineHeight(double fontSize, [LineOptions options = LineOptions.plain]) =>
      lineHeightPx(model, fontSize, height: options.height);

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
      flutterHeight(text, fontSize: fontSize, maxWidth: maxWidth, options: options);

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
    return n < 0 ? null : options.maxLines != null && n > options.maxLines!;
  }

  /// Height in px, or null when Flutter must decide at this width.
  double? height({required double fontSize, required double maxWidth}) {
    final n = lineCount(fontSize: fontSize, maxWidth: maxWidth);
    return n == null ? null : n * lineHeightPx(_bf.model, fontSize, height: options.height);
  }
}
