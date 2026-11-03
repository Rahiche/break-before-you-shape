import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'engine.dart';
import 'width_model.dart';

/// Exact line breaks and heights for plain paragraphs in one font, from the
/// font's sidecar, without shaping.
///
/// The predictions describe text laid out with [style]: a single style with no
/// letter or word spacing, no height multiplier and no font features, left to
/// right, without maxLines. A paragraph the breaker cannot decide exactly (a
/// character outside the certificate, a word wider than the line, a fit decision
/// within float error) gets null from [prepare] and [lineStarts], and [height]
/// lays it out with Flutter instead.
class BreakFirst {
  BreakFirst._(this.model, this.fontFamily, this.canaryErrorPx);

  final WidthModel model;
  final String fontFamily;

  /// Largest canary error on this device, px at 16 px.
  final double canaryErrorPx;

  /// Decodes [sidecar] and checks it against this engine: calibrates the
  /// engine's font-size rounding and measures the canary strings. Returns null
  /// when the canary fails, that is when the sidecar does not describe the font
  /// loaded under [fontFamily] on this device; then lay everything out with
  /// Flutter.
  static BreakFirst? load(Uint8List sidecar, {required String fontFamily}) {
    final md = WidthModel.decode(sidecar);
    calibrateFontSize(md, (s, size) => measureText(s, fontFamily: fontFamily, fontSize: size));
    final err = canaryError(md, fontFamily);
    return err < 1e-3 ? BreakFirst._(md, fontFamily, err) : null;
  }

  /// The style whose layout this object predicts.
  TextStyle style(double fontSize) => TextStyle(inherit: false, fontFamily: fontFamily, fontSize: fontSize);

  /// Height of one line at [fontSize], in px.
  double lineHeight(double fontSize) => lineHeightPx(model, fontSize);

  /// One pass over [text] that makes re-wrapping at any width and size cheap, or
  /// null when Flutter must lay this paragraph out.
  PreparedParagraph? prepare(String text) {
    final r = buildRecords(model, text);
    return r == null ? null : PreparedParagraph._(this, text, r);
  }

  /// Offsets where Flutter starts each line of [text], or null when Flutter must
  /// lay it out.
  List<int>? lineStarts(String text, {required double fontSize, required double maxWidth}) =>
      prepare(text)?.lineStarts(fontSize: fontSize, maxWidth: maxWidth);

  /// Height of [text] in px, equal to Flutter's: from the sidecar when it
  /// decides, otherwise from Flutter's layout.
  double height(String text, {required double fontSize, required double maxWidth}) =>
      prepare(text)?.height(fontSize: fontSize, maxWidth: maxWidth) ?? flutterHeight(text, fontSize: fontSize, maxWidth: maxWidth);

  /// Height of [text] from Flutter's own layout.
  double flutterHeight(String text, {required double fontSize, required double maxWidth}) {
    final p = layoutParagraph(text, fontFamily: fontFamily, fontSize: fontSize, width: maxWidth);
    final h = p.height;
    p.dispose();
    return h;
  }
}

/// A paragraph's width prefix and break opportunities, for wrapping at any width.
class PreparedParagraph {
  PreparedParagraph._(this._bf, this.text, this.records);

  final BreakFirst _bf;
  final String text;
  final Records records;

  /// Line starts, or null when Flutter must decide at this width.
  List<int>? lineStarts({required double fontSize, required double maxWidth}) =>
      records.lineStarts(maxWidth, scaleFor(_bf.model, fontSize));

  /// Number of lines, or null when Flutter must decide at this width.
  int? lineCount({required double fontSize, required double maxWidth}) {
    final n = records.lineCount(maxWidth, scaleFor(_bf.model, fontSize));
    return n < 0 ? null : n;
  }

  /// Height in px, or null when Flutter must decide at this width.
  double? height({required double fontSize, required double maxWidth}) {
    final n = lineCount(fontSize: fontSize, maxWidth: maxWidth);
    return n == null ? null : n * lineHeightPx(_bf.model, fontSize);
  }
}
