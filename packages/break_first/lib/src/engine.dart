// What the sidecar is measured against and checked against: Flutter's own text
// stack (dart:ui, SkParagraph and HarfBuzz underneath).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'width_model.dart';

final _ps = ui.ParagraphStyle(textDirection: ui.TextDirection.ltr);

/// A laid-out paragraph of [text] in [fontFamily] at [fontSize], [width] wide,
/// in the style the sidecar describes. The caller disposes it.
ui.Paragraph layoutParagraph(
  String text, {
  required String fontFamily,
  required double fontSize,
  double width = double.infinity,
  double letterSpacing = 0,
  double wordSpacing = 0,
  double? height,
  int? maxLines,
  bool rtl = false,
}) {
  final b =
      ui.ParagraphBuilder(
          maxLines == null && !rtl
              ? _ps
              : ui.ParagraphStyle(textDirection: rtl ? ui.TextDirection.rtl : ui.TextDirection.ltr, maxLines: maxLines),
        )
        ..pushStyle(
          ui.TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            letterSpacing: letterSpacing == 0 ? null : letterSpacing,
            wordSpacing: wordSpacing == 0 ? null : wordSpacing,
            height: height,
          ),
        )
        ..addText(text);
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

/// Width of [text] on one line, trailing spaces included (cluster advances). A
/// right-to-left paragraph is laid out in a finite box wider than the text and
/// measured from the leftmost to the rightmost box.
double measureText(
  String text, {
  required String fontFamily,
  required double fontSize,
  double letterSpacing = 0,
  bool rtl = false,
}) {
  final p = layoutParagraph(
    text,
    fontFamily: fontFamily,
    fontSize: fontSize,
    letterSpacing: letterSpacing,
    rtl: rtl,
    // Just wide enough: float32 coordinates near 1e6 px are only good to 1/16 px.
    width: rtl ? fontSize * (text.length + 2) * 8 : double.infinity,
  );
  var r = 0.0, l = double.infinity;
  for (final b in p.getBoxesForRange(0, text.length)) {
    if (b.right > r) r = b.right;
    if (b.left < l) l = b.left;
  }
  p.dispose();
  return rtl ? r - l : r;
}

/// Width of the clusters of the first [k] code units of [text], laid out on one
/// line: with [measureText] of the whole, the split of a pair's kerning between
/// its two glyphs.
double measurePrefixText(
  String text,
  int k, {
  required String fontFamily,
  required double fontSize,
  bool rtl = false,
  double letterSpacing = 0,
}) {
  final p = layoutParagraph(
    text,
    fontFamily: fontFamily,
    fontSize: fontSize,
    rtl: rtl,
    letterSpacing: letterSpacing,
    width: rtl ? fontSize * (text.length + 2) * 8 : double.infinity,
  );
  var r = 0.0, l = double.infinity;
  for (final b in p.getBoxesForRange(0, k)) {
    if (b.right > r) r = b.right;
    if (b.left < l) l = b.left;
  }
  p.dispose();
  return rtl ? r - l : r;
}

/// Units per em, from the font file's head table.
int upemOf(Uint8List font) {
  final bd = ByteData.sublistView(font);
  final n = bd.getUint16(4);
  for (var i = 0; i < n; i++) {
    final rec = 12 + 16 * i;
    if (String.fromCharCodes(font.sublist(rec, rec + 4)) == 'head') return bd.getUint16(bd.getUint32(rec + 8) + 18);
  }
  throw StateError('no head table');
}

/// The build step: distils the sidecar for [font] from its certificate (written
/// by certify.py) by measuring this engine at a font size equal to the font's
/// units per em. The font must already be loaded under [fontFamily]. Run it on
/// the host under `flutter test` and ship `encode()` as an asset; [measured], when
/// given, sees every measurement.
///
/// With [noLigaCertificate] (certify.py with CERTIFY_FEATURES_OFF=liga,clig,calt)
/// the sidecar also covers letter-spaced text. Those widths are measured the way
/// the engine produces them: with letter spacing, minus the spacing itself
/// (measured: each character gains the spacing, plus half of it before the first).
WidthModel buildSidecar({
  required String fontFamily,
  required Uint8List font,
  required String certificate,
  String? noLigaCertificate,
  void Function(String text, double units)? measured,
  bool rtl = false,
}) {
  final upem = upemOf(font);
  final size = upem.toDouble();
  final hg = layoutParagraph('Hg', fontFamily: fontFamily, fontSize: size);
  final lineHeight = hg.height;
  hg.dispose();
  const spacing = 64.0;
  return WidthModel.distill(
    certificate,
    (s) {
      final w = measureText(s, fontFamily: fontFamily, fontSize: size, rtl: rtl);
      measured?.call(s, w);
      return w;
    },
    upem,
    lineHeight,
    rtl: rtl,
    measurePrefix: (s, k) => measurePrefixText(s, k, fontFamily: fontFamily, fontSize: size, rtl: rtl),
    measurePrefixNoLiga: (s, k) =>
        measurePrefixText(s, k, fontFamily: fontFamily, fontSize: size, rtl: rtl, letterSpacing: spacing) -
        (k + 0.5) * spacing,
    noLigaCertText: noLigaCertificate,
    measureNoLiga: (s) =>
        measureText(s, fontFamily: fontFamily, fontSize: size, letterSpacing: spacing, rtl: rtl) -
        (s.length + 0.5) * spacing,
    // Negative spacing keeps ligatures: each glyph cluster gains it once, plus half
    // of it before the first.
    clustersOf: (s) =>
        ((measureText(s, fontFamily: fontFamily, fontSize: size, letterSpacing: -spacing, rtl: rtl) -
                        measureText(s, fontFamily: fontFamily, fontSize: size, rtl: rtl)) /
                    -spacing -
                0.5)
            .round(),
  );
}

/// Calibrates this engine's conventions that differ between platforms (font
/// size rounding, kerning before a hard break), for the font loaded under
/// [fontFamily].
void calibrateEngine(WidthModel md, String fontFamily) {
  calibrateFontSize(md, (s, size) => measureText(s, fontFamily: fontFamily, fontSize: size, rtl: md.rtl));
  calibrateHardBreak(md, (s) {
    final p = layoutParagraph(s, fontFamily: fontFamily, fontSize: md.upem.toDouble(), rtl: md.rtl, width: 1e5);
    final w = p.computeLineMetrics().first.width;
    p.dispose();
    return w;
  });
}

/// Largest difference, in px at 16 px, between the canary widths stored in the
/// sidecar and this engine's widths for the font loaded under [fontFamily].
double canaryError(WidthModel md, String fontFamily) {
  var maxErr = 0.0;
  for (final e in md.probes.entries) {
    final engine = measureText(e.key, fontFamily: fontFamily, fontSize: 16.0, rtl: md.rtl) / (16.0 / md.upem);
    final err = (engine - e.value).abs() * 16.0 / md.upem;
    if (err > maxErr) maxErr = err;
  }
  return maxErr;
}
