// What the sidecar is measured against and checked against: Flutter's own text
// stack (dart:ui, SkParagraph and HarfBuzz underneath).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'width_model.dart';

final _ps = ui.ParagraphStyle(textDirection: ui.TextDirection.ltr);

/// A laid-out paragraph of [text] in [fontFamily] at [fontSize], [width] wide,
/// in the style the sidecar describes. The caller disposes it.
ui.Paragraph layoutParagraph(String text, {required String fontFamily, required double fontSize, double width = double.infinity}) {
  final b = ui.ParagraphBuilder(_ps)
    ..pushStyle(ui.TextStyle(fontFamily: fontFamily, fontSize: fontSize))
    ..addText(text);
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

/// Width of [text] on one line, trailing spaces included (cluster advances).
double measureText(String text, {required String fontFamily, required double fontSize}) {
  final p = layoutParagraph(text, fontFamily: fontFamily, fontSize: fontSize);
  var r = 0.0;
  for (final b in p.getBoxesForRange(0, text.length)) {
    if (b.right > r) r = b.right;
  }
  p.dispose();
  return r;
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
WidthModel buildSidecar({required String fontFamily, required Uint8List font, required String certificate,
    void Function(String text, double units)? measured}) {
  final upem = upemOf(font);
  final size = upem.toDouble();
  final hg = layoutParagraph('Hg', fontFamily: fontFamily, fontSize: size);
  final lineHeight = hg.height;
  hg.dispose();
  return WidthModel.distill(certificate, (s) {
    final w = measureText(s, fontFamily: fontFamily, fontSize: size);
    measured?.call(s, w);
    return w;
  }, upem, lineHeight);
}

/// Largest difference, in px at 16 px, between the canary widths stored in the
/// sidecar and this engine's widths for the font loaded under [fontFamily].
double canaryError(WidthModel md, String fontFamily) {
  var maxErr = 0.0;
  for (final e in md.probes.entries) {
    final engine = measureText(e.key, fontFamily: fontFamily, fontSize: 16.0) / (16.0 / md.upem);
    final err = (engine - e.value).abs() * 16.0 / md.upem;
    if (err > maxErr) maxErr = err;
  }
  return maxErr;
}
