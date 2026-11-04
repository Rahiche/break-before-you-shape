// What the sidecar is measured against and checked against: Flutter's own text
// stack (dart:ui, SkParagraph and HarfBuzz underneath).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'width_model.dart';

final _ps = ui.ParagraphStyle(textDirection: ui.TextDirection.ltr);

/// A laid-out paragraph of [text] in [fontFamily] at [fontSize], [width] wide,
/// in the style the sidecar describes. The caller disposes it. [context] follows
/// the text in the same style: a letter the font lacks, so a fallback font draws
/// it (no kerning or ligature with the text), whose script a text of Common
/// characters then takes (measured: in a run of another size it would not).
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
  ui.StrutStyle? strut,
  ui.TextHeightBehavior? textHeightBehavior,
  List<ui.FontFeature>? fontFeatures,
  String? context,
}) {
  final b =
      ui.ParagraphBuilder(
          maxLines == null && !rtl && strut == null && textHeightBehavior == null
              ? _ps
              : ui.ParagraphStyle(
                  textDirection: rtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
                  maxLines: maxLines,
                  strutStyle: strut,
                  textHeightBehavior: textHeightBehavior,
                ),
        )
        ..pushStyle(
          ui.TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            letterSpacing: letterSpacing == 0 ? null : letterSpacing,
            wordSpacing: wordSpacing == 0 ? null : wordSpacing,
            height: height,
            fontFeatures: fontFeatures,
          ),
        )
        ..addText(text);
  if (context != null) b.addText(context);
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

/// Heights of a paragraph's lines in one style, from Flutter: with one font,
/// every line has the same metrics, so only the first line (and with
/// TextHeightBehavior, the last) can differ from the others.
class LineHeights {
  const LineHeights(this.one, this.two, this.three);

  /// Heights of paragraphs of one, two and three lines.
  final double one, two, three;

  /// Height of a paragraph of [lines] lines (an empty one has one line).
  double of(int lines) => lines <= 1 ? one : two + (lines - 2) * (three - two);
}

/// [LineHeights] for one style: three layouts of one to three lines. For styles
/// whose heights [lineHeightPx] does not model (struts, TextHeightBehavior).
LineHeights probeLineHeights({
  required String fontFamily,
  required double fontSize,
  double? height,
  ui.StrutStyle? strut,
  ui.TextHeightBehavior? textHeightBehavior,
}) {
  double h(String t) {
    final p = layoutParagraph(t, fontFamily: fontFamily, fontSize: fontSize, height: height, strut: strut,
        textHeightBehavior: textHeightBehavior);
    final v = p.height;
    p.dispose();
    return v;
  }

  return LineHeights(h('Hg'), h('Hg\nHg'), h('Hg\nHg\nHg'));
}

/// Ascent and descent, px, of a line in one style (font metrics, so the same for
/// any text in the font): what rich-text lines take the maximum of.
(double, double) probeAscentDescent({
  required String fontFamily,
  required double fontSize,
  double? height,
  List<ui.FontFeature>? fontFeatures,
}) {
  final p = layoutParagraph('Hg', fontFamily: fontFamily, fontSize: fontSize, height: height, fontFeatures: fontFeatures);
  final m = p.computeLineMetrics().first;
  p.dispose();
  return (m.ascent, m.descent);
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
  List<ui.FontFeature>? fontFeatures,
  String? context,
}) {
  final p = layoutParagraph(
    text,
    fontFamily: fontFamily,
    fontSize: fontSize,
    letterSpacing: letterSpacing,
    rtl: rtl,
    fontFeatures: fontFeatures,
    context: context,
    // Just wide enough: float32 coordinates near 1e6 px are only good to 1/16 px.
    width: rtl ? fontSize * (text.length + 2 * (context?.length ?? 0) + 2) * 8 : double.infinity,
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
  List<ui.FontFeature>? fontFeatures,
  String? context,
}) {
  final p = layoutParagraph(
    text,
    fontFamily: fontFamily,
    fontSize: fontSize,
    rtl: rtl,
    letterSpacing: letterSpacing,
    fontFeatures: fontFeatures,
    context: context,
    width: rtl ? fontSize * (text.length + 2 * (context?.length ?? 0) + 2) * 8 : double.infinity,
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

/// The characters [font] maps, from its cmap (format 12, else format 4), as
/// sorted inclusive [first, last] pairs.
List<int> cmapRanges(Uint8List font) {
  final bd = ByteData.sublistView(font);
  final n = bd.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < n; i++) {
    final rec = 12 + 16 * i;
    if (String.fromCharCodes(font.sublist(rec, rec + 4)) == 'cmap') cmap = bd.getUint32(rec + 8);
  }
  if (cmap < 0) throw StateError('no cmap table');
  int? f12, f4;
  for (var i = 0; i < bd.getUint16(cmap + 2); i++) {
    final r = cmap + 4 + 8 * i, platform = bd.getUint16(r), encoding = bd.getUint16(r + 2);
    final sub = cmap + bd.getUint32(r + 4), format = bd.getUint16(sub);
    final unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
    if (!unicode) continue;
    if (format == 12) f12 ??= sub;
    if (format == 4) f4 ??= sub;
  }
  final ranges = <int>[];
  void add(int a, int b) {
    if (ranges.isNotEmpty && a <= ranges.last + 1) {
      if (b > ranges.last) ranges.last = b;
    } else {
      ranges.addAll([a, b]);
    }
  }

  if (f12 != null) {
    final groups = <(int, int)>[];
    for (var g = 0; g < bd.getUint32(f12 + 12); g++) {
      final r = f12 + 16 + 12 * g;
      if (bd.getUint32(r + 8) != 0) groups.add((bd.getUint32(r), bd.getUint32(r + 4))); // glyph 0 is .notdef
    }
    groups.sort((x, y) => x.$1.compareTo(y.$1));
    for (final (a, b) in groups) {
      add(a, b);
    }
  } else if (f4 != null) {
    final segX2 = bd.getUint16(f4 + 6);
    final ends = f4 + 14, starts = ends + segX2 + 2, deltas = starts + segX2, offs = deltas + segX2;
    for (var k = 0; k < segX2 ~/ 2; k++) {
      final end = bd.getUint16(ends + 2 * k), start = bd.getUint16(starts + 2 * k);
      final delta = bd.getUint16(deltas + 2 * k), ro = bd.getUint16(offs + 2 * k);
      for (var c = start; c <= end && c != 0xFFFF; c++) {
        final glyph = ro == 0
            ? (c + delta) & 0xFFFF
            : () {
                final at = offs + 2 * k + ro + 2 * (c - start);
                final g = bd.getUint16(at);
                return g == 0 ? 0 : (g + delta) & 0xFFFF;
              }();
        if (glyph != 0) add(c, c);
      }
    }
  }
  return ranges;
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
///
/// With [fontFeatures], the sidecar describes text with those features: certify
/// the font with the same features (CERTIFY_FEATURES_ON / CERTIFY_FEATURES_OFF),
/// and load the sidecar with them.
WidthModel buildSidecar({
  required String fontFamily,
  required Uint8List font,
  required String certificate,
  String? noLigaCertificate,
  void Function(String text, double units)? measured,
  bool rtl = false,
  List<ui.FontFeature>? fontFeatures,
}) {
  final upem = upemOf(font);
  final size = upem.toDouble();
  final ff = fontFeatures;
  // When the font's lookups for a run of Common characters alone (DFLT) differ
  // from the main script's (certify.py's "# script DFLT" line), a string of
  // Common characters is measured before a letter of the main script, whose run
  // it then belongs to.
  final cmap = cmapRanges(font);
  bool has(int cp) => [for (var i = 0; i + 1 < cmap.length; i += 2) cmap[i] <= cp && cp <= cmap[i + 1]].contains(true);
  final candidates = !rtl
      ? const [0x0250, 0x0252, 0x0258, 0x025E, 0xA7B5, 0xA7C1, 0xA7D1, 0xAB30, 0xAB31, 0x1D6B]
      : RegExp(r'^05[DE][0-9A-F] ', multiLine: true).hasMatch(certificate)
      ? const [0x05EF, 0xFB1F, 0xFB21]
      : const [0x08A0, 0x08A1, 0x0870, 0x08B5];
  final missing = candidates.where((c) => !has(c));
  final mainLetter = !certificate.contains('\n# script DFLT ')
      ? null
      : missing.isEmpty
      ? throw StateError('the font has every context letter; Common characters cannot be measured in its main script')
      : String.fromCharCode(missing.first);
  String? ctx(String s) => mainLetter != null && s.codeUnits.every((c) => scriptOf(c) == scCommon) ? mainLetter : null;
  final hg = layoutParagraph('Hg', fontFamily: fontFamily, fontSize: size, fontFeatures: ff);
  final lineHeight = hg.height;
  hg.dispose();
  const spacing = 64.0;
  final md = WidthModel.distill(
    certificate,
    (s) {
      final w = measureText(s, fontFamily: fontFamily, fontSize: size, rtl: rtl, fontFeatures: ff, context: ctx(s));
      measured?.call(s, w);
      return w;
    },
    upem,
    lineHeight,
    rtl: rtl,
    measurePrefix: (s, k) =>
        measurePrefixText(s, k, fontFamily: fontFamily, fontSize: size, rtl: rtl, fontFeatures: ff, context: ctx(s)),
    measurePrefixNoLiga: (s, k) =>
        measurePrefixText(s, k, fontFamily: fontFamily, fontSize: size, rtl: rtl, letterSpacing: spacing,
            fontFeatures: ff, context: ctx(s)) -
        (k + 0.5) * spacing,
    noLigaCertText: noLigaCertificate,
    measureNoLiga: (s) =>
        measureText(s, fontFamily: fontFamily, fontSize: size, letterSpacing: spacing, rtl: rtl, fontFeatures: ff,
            context: ctx(s)) -
        (s.length + 0.5) * spacing,
    // Negative spacing keeps ligatures: each glyph cluster gains it once, plus half
    // of it before the first.
    clustersOf: (s) =>
        ((measureText(s, fontFamily: fontFamily, fontSize: size, letterSpacing: -spacing, rtl: rtl, fontFeatures: ff,
                            context: ctx(s)) -
                        measureText(s, fontFamily: fontFamily, fontSize: size, rtl: rtl, fontFeatures: ff,
                            context: ctx(s))) /
                    -spacing -
                0.5)
            .round(),
  );
  md.coverage = cmapRanges(font);
  return md;
}

/// Calibrates this engine's conventions that differ between platforms (font
/// size rounding, kerning before a hard break), for the font loaded under
/// [fontFamily].
void calibrateEngine(WidthModel md, String fontFamily, {List<ui.FontFeature>? fontFeatures}) {
  calibrateFontSize(
    md,
    (s, size) => measureText(s, fontFamily: fontFamily, fontSize: size, rtl: md.rtl, fontFeatures: fontFeatures),
  );
  calibrateHardBreak(md, (s) {
    final p = layoutParagraph(
      s,
      fontFamily: fontFamily,
      fontSize: md.upem.toDouble(),
      rtl: md.rtl,
      width: 1e5,
      fontFeatures: fontFeatures,
    );
    final w = p.computeLineMetrics().first.width;
    p.dispose();
    return w;
  });
}

/// Largest difference, in px at 16 px, between the canary widths stored in the
/// sidecar and this engine's widths for the font loaded under [fontFamily].
double canaryError(WidthModel md, String fontFamily, {List<ui.FontFeature>? fontFeatures}) {
  var maxErr = 0.0;
  for (final e in md.probes.entries) {
    final engine =
        measureText(e.key, fontFamily: fontFamily, fontSize: 16.0, rtl: md.rtl, fontFeatures: fontFeatures) /
        (16.0 / md.upem);
    final err = (engine - e.value).abs() * 16.0 / md.upem;
    if (err > maxErr) maxErr = err;
  }
  return maxErr;
}
