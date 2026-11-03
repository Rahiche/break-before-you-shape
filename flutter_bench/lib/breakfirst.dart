/// Break-first line breaking for Flutter: line breaks from a precompiled width
/// model (the "sidecar"), without shaping.
///
/// The sidecar is built once per font, at build time, by measuring Flutter's own
/// text stack at a font size equal to the font's units per em, so every value is
/// in font units: every character, every pair of characters, and every ligature
/// island (a run of P/K characters from the static certificate, certify.py) next
/// to each safe neighbour. Flutter's widths are linear in font size, so one file
/// serves every size.
///
/// Widths follow SkParagraph's convention: it shapes the whole paragraph once and
/// breaks on the shaped cluster advances, so a pair adjustment belongs to the left
/// glyph of the pair. A line from character s to character e measures
/// `prefix[e] - prefix[s]`.
library;

import 'dart:convert';
import 'dart:typed_data';

typedef Measure = double Function(String text);

// Certificate classes from certify.py.
const int certS = 0, certK = 1, certP = 2, certU = 3;

/// SkParagraph's line-fit test, emulated in float32: a line fits when its width,
/// floored to 1/100 px (1/10 px from 10,000 px), is not greater than the box width.
/// Measured first as "+0.01 px" with box widths that are multiples of 0.1 px,
/// where the two agree; arbitrary box widths showed the floor.
final Float32List _f32 = Float32List(1);
double _toF32(double x) {
  _f32[0] = x;
  return _f32[0];
}

final double _hundredth = _toF32(1.0 / 100), _tenth = _toF32(1.0 / 10);
bool fitsLine(double widthPx, double maxWidthF32) {
  final w = _toF32(widthPx);
  final v = w.abs();
  final double rounded;
  if (v < 10000) {
    rounded = _toF32(_toF32(w * 100).floorToDouble() * _hundredth);
  } else if (v < 100000) {
    rounded = _toF32(_toF32(w * 10).floorToDouble() * _tenth);
  } else {
    rounded = w.floorToDouble();
  }
  return !(rounded > maxWidthF32);
}

/// The font size the engine actually lays out at. Measured: macOS and iOS use the
/// requested size; Android truncates it to 1/64 px (FreeType's 26.6 fixed point).
/// Set once at startup by [calibrateFontSize].
bool quantizeFontSize = false;
double effectiveFontSize(double size) => quantizeFontSize ? (size * 64).floorToDouble() / 64 : size;

/// One layout tells whether this engine quantizes font sizes: at 16.01 px a
/// quantizing engine lays out at 16.0 px.
void calibrateFontSize(WidthModel md, double Function(String, double) measure) {
  final probe = md.probes.keys.first;
  const size = 16.01;
  final effective = measure(probe, size) / md.probes[probe]! * md.upem;
  quantizeFontSize = (effective - (size * 64).floorToDouble() / 64).abs() < (effective - size).abs();
}

/// Flutter's height of one line at [size] for a default style: the font's line
/// height in pixels, rounded to a whole pixel (measured at 12, 14, 16, 18.4, 24 px).
double lineHeightPx(WidthModel md, double size) => (md.lineHeight * effectiveFontSize(size) / md.upem).roundToDouble();

/// Pixels per font unit at [size].
double scaleFor(WidthModel md, double size) => effectiveFontSize(size) / md.upem;

class WidthModel {
  WidthModel._(this.name, this.upem, this.m, this.lineHeight, this.cps, this.cert, this.adv, this.fc, this.sc, this.nS,
      this.cls, this.islandChars, this.islandOfKey, this.islandW, this.islandL, this.islandR, this.probes) {
    n1 = cps.length;
    idOf = Uint16List(0x10000);
    islandDigit = Int8List(n1)..fillRange(0, n1, -1);
    for (var id = 1; id < n1; id++) {
      idOf[cps[id]] = id;
    }
    for (var d = 0; d < islandChars.length; d++) {
      islandDigit[islandChars[d]] = d;
    }
    keyBase = islandChars.length + 1;
    islandCount = islandW.length;
  }

  final String name;
  final int upem, m;
  final double lineHeight;     // one line's height, in units
  final Int32List cps;         // id -> codepoint (id 0 = not in the model)
  final Uint8List cert;        // id -> certificate class
  final Float64List adv;       // id -> advance alone (units)
  final Int32List fc, sc;      // id -> first-position row offset (class * nS), second-position class
  final int nS;
  final Float64List cls;       // pair class matrix: width(ab) - adv(a) - adv(b)
  final Int32List islandChars; // island digit -> id (P/K characters)
  final Int32List islandOfKey; // island key -> island index, or -1
  final Float64List islandW;   // island -> width alone
  final Float64List islandL;   // island * n1 + x -> width(xI) - adv(x) - width(I)
  final Float64List islandR;   // island * n1 + y -> width(Iy) - width(I) - adv(y)
  final Map<String, double> probes; // canary strings -> expected width (units)
  late final int n1, keyBase, islandCount;
  late final Uint16List idOf;
  late final Int8List islandDigit;

  double pair(int a, int b) => cls[fc[a] + sc[b]];

  /// Builds the tables by measuring with [measure] at font size = units per em.
  static WidthModel distill(String certText, Measure measure, int upem, double lineHeight) {
    var name = 'font', m = 0;
    final cps = <int>[0], cl = <int>[certU];
    for (final line in certText.split('\n')) {
      if (line.startsWith('#')) {
        final mm = RegExp(r'm=(\d+)').firstMatch(line);
        if (mm != null) m = int.parse(mm.group(1)!);
        name = line.substring(1).split(' m=').first.trim();
        continue;
      }
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 3) continue;
      final cp = int.parse(parts[0], radix: 16);
      final c = const {'S': certS, 'K': certK, 'P': certP, 'U': certU}[parts[2]]!;
      if (c == certU || cp >= 0x10000 || (cp >= 0xD800 && cp < 0xE000)) continue;
      cps.add(cp);
      cl.add(c);
    }
    final n1 = cps.length;
    final str = [for (final cp in cps) String.fromCharCode(cp)];
    final adv = Float64List(n1);
    for (var id = 1; id < n1; id++) {
      adv[id] = measure(str[id]);
    }
    final dense = Float64List(n1 * n1);
    for (var a = 1; a < n1; a++) {
      for (var b = 1; b < n1; b++) {
        dense[a * n1 + b] = measure(str[a] + str[b]) - adv[a] - adv[b];
      }
    }
    // Compress: identical rows share a first-position class, identical columns a
    // second-position class.
    final rowClass = Int32List(n1), colClass = Int32List(n1);
    final rowKeys = <String, int>{}, colKeys = <String, int>{};
    for (var a = 0; a < n1; a++) {
      final k = String.fromCharCodes([for (var b = 0; b < n1; b++) (dense[a * n1 + b] * 4).round() + 0x8000]);
      rowClass[a] = rowKeys.putIfAbsent(k, () => rowKeys.length);
    }
    for (var b = 0; b < n1; b++) {
      final k = String.fromCharCodes([for (var a = 0; a < n1; a++) (dense[a * n1 + b] * 4).round() + 0x8000]);
      colClass[b] = colKeys.putIfAbsent(k, () => colKeys.length);
    }
    final nF = rowKeys.length, nS = colKeys.length;
    final cls = Float64List(nF * nS);
    for (var a = 0; a < n1; a++) {
      for (var b = 0; b < n1; b++) {
        cls[rowClass[a] * nS + colClass[b]] = dense[a * n1 + b];
      }
    }
    final fc = Int32List.fromList([for (var a = 0; a < n1; a++) rowClass[a] * nS]);
    // Islands: every P/K string of length <= m that contains a primer.
    final ik = [for (var id = 1; id < n1; id++) if (cl[id] != certS) id];
    final safe = [for (var id = 1; id < n1; id++) if (cl[id] == certS) id];
    final base = ik.length + 1;
    var keys = 1;
    for (var i = 0; i <= m; i++) {
      keys *= base;
    }
    final islandOfKey = Int32List(keys)..fillRange(0, keys, -1);
    final w = <double>[], l = <double>[], r = <double>[];
    void visit(String s, int key, int len, bool primer) {
      if (len > 0 && primer) {
        islandOfKey[key] = w.length;
        final wi = measure(s);
        w.add(wi);
        final lrow = List<double>.filled(n1, double.nan), rrow = List<double>.filled(n1, double.nan);
        for (final x in safe) {
          lrow[x] = measure(str[x] + s) - adv[x] - wi;
          rrow[x] = measure(s + str[x]) - wi - adv[x];
        }
        l.addAll(lrow);
        r.addAll(rrow);
      }
      if (len == m) return;
      for (var d = 0; d < ik.length; d++) {
        visit(s + str[ik[d]], key * base + d + 1, len + 1, primer || cl[ik[d]] == certP);
      }
    }

    visit('', 0, 0, false);
    // Canary probes: ordinary text whose width must match after shipping.
    const probeTexts = [
      'The quick brown fox jumps over the lazy dog.', 'AVAWATAY To Te Wa fi fl ffi office', 'Hello, world! 12,345.67',
      'Съешь же ещё этих мягких французских булок', 'Ξεσκεπάζω την ψυχοφθόρα βδελυγμία',
    ];
    final probes = <String, double>{for (final p in probeTexts) p: measure(p)};
    return WidthModel._(name, upem, m, lineHeight, Int32List.fromList(cps), Uint8List.fromList(cl), adv, fc,
        colClass, nS, cls, Int32List.fromList(ik), islandOfKey, Float64List.fromList(w), Float64List.fromList(l),
        Float64List.fromList(r), probes);
  }

  /// The sidecar file. Values are font units (stored as float32).
  Uint8List encode() {
    final meta = utf8.encode(jsonEncode({
      'name': name, 'upem': upem, 'm': m, 'lineHeight': lineHeight, 'n1': n1, 'nS': nS, 'nF': cls.length ~/ nS,
      'islands': islandCount, 'islandChars': islandChars.length, 'keys': islandOfKey.length, 'probes': probes,
    }));
    final b = BytesBuilder()
      ..add((ByteData(8)
            ..setUint32(0, 0x42465732) // "BFW2"
            ..setUint32(4, meta.length))
          .buffer
          .asUint8List())
      ..add(meta);
    void pad() {
      while (b.length % 4 != 0) {
        b.addByte(0);
      }
    }

    pad();
    b.add(Int32List.fromList(cps).buffer.asUint8List());
    b.add(cert);
    pad();
    b.add(Float32List.fromList(adv).buffer.asUint8List());
    b.add(Int32List.fromList([for (final v in fc) v ~/ nS]).buffer.asUint8List());
    b.add(sc.buffer.asUint8List());
    b.add(Float32List.fromList(cls).buffer.asUint8List());
    b.add(Int32List.fromList(islandChars).buffer.asUint8List());
    b.add(islandOfKey.buffer.asUint8List());
    b.add(Float32List.fromList(islandW).buffer.asUint8List());
    // Only S neighbours have island terms; store them densely by safe index.
    final safe = [for (var id = 1; id < n1; id++) if (cert[id] == certS) id];
    final lr = Float32List(islandCount * safe.length * 2);
    var o = 0;
    for (var i = 0; i < islandCount; i++) {
      for (final x in safe) {
        lr[o++] = islandL[i * n1 + x];
        lr[o++] = islandR[i * n1 + x];
      }
    }
    b.add(lr.buffer.asUint8List());
    return b.toBytes();
  }

  static WidthModel decode(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0) != 0x42465732) throw const FormatException('not a BFW2 sidecar');
    final metaLen = bd.getUint32(4);
    final meta = jsonDecode(utf8.decode(bytes.sublist(8, 8 + metaLen))) as Map<String, dynamic>;
    var off = 8 + metaLen;
    off = (off + 3) & ~3;
    final n1 = meta['n1'] as int, nS = meta['nS'] as int, nF = meta['nF'] as int;
    final nI = meta['islandChars'] as int, keys = meta['keys'] as int, islands = meta['islands'] as int;
    final copy = Uint8List.fromList(bytes); // aligned buffer
    Int32List i32(int n) {
      final v = Int32List.fromList(copy.buffer.asInt32List(off, n));
      off += 4 * n;
      return v;
    }

    Float64List f32(int n) {
      final v = Float64List.fromList(copy.buffer.asFloat32List(off, n));
      off += 4 * n;
      return v;
    }

    final cps = i32(n1);
    final cert = Uint8List.fromList(copy.sublist(off, off + n1));
    off = (off + n1 + 3) & ~3;
    final adv = f32(n1);
    final fcls = i32(n1), sc = i32(n1);
    final cls = f32(nF * nS);
    final islandChars = i32(nI), islandOfKey = i32(keys), islandW = f32(islands);
    final safe = [for (var id = 1; id < n1; id++) if (cert[id] == certS) id];
    final lr = f32(islands * safe.length * 2);
    final islandL = Float64List(islands * n1)..fillRange(0, islands * n1, double.nan);
    final islandR = Float64List(islands * n1)..fillRange(0, islands * n1, double.nan);
    var o = 0;
    for (var i = 0; i < islands; i++) {
      for (final x in safe) {
        islandL[i * n1 + x] = lr[o++];
        islandR[i * n1 + x] = lr[o++];
      }
    }
    return WidthModel._(meta['name'] as String, meta['upem'] as int, meta['m'] as int,
        (meta['lineHeight'] as num).toDouble(), cps, cert, adv, Int32List.fromList([for (final v in fcls) v * nS]), sc,
        nS, cls, islandChars, islandOfKey, islandW, islandL, islandR,
        (meta['probes'] as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble())));
  }

  /// Model width of [text] on one line, in units (for canaries and checks).
  double widthOf(String text) {
    final r = buildRecords(this, text);
    return r == null ? double.nan : r.prefix[text.length];
  }

  String describe() => '$name: ${n1 - 1} characters, pair classes ${cls.length ~/ nS}x$nS, '
      '$islandCount islands up to m=$m';
}

// ---------------------------------------------------------------------------
// Line-break classes (UAX #14) for the characters this breaker handles. Anything
// else sends its paragraph to Flutter.
const int lbAL = 0, lbNU = 1, lbSP = 2, lbBA = 3, lbHY = 4, lbIS = 5, lbEX = 6, lbOP = 7, lbCL = 8, lbCP = 9,
    lbQU = 10, lbSY = 11, lbPR = 12, lbPO = 13, lbIN = 14, lbB2 = 15, lbGL = 16, lbBB = 17, lbXX = 18;
const int nLB = 19;
const int _lbMax = 0x2200;
final Uint8List _lb = () {
  final t = Uint8List(_lbMax)..fillRange(0, _lbMax, lbXX);
  for (var c = 0x21; c < 0x7F; c++) {
    t[c] = lbAL;
  }
  for (var c = 0x30; c <= 0x39; c++) {
    t[c] = lbNU;
  }
  const special = {
    0x20: lbSP, 0x21: lbEX, 0x22: lbQU, 0x24: lbPR, 0x25: lbPO, 0x27: lbQU, 0x28: lbOP, 0x29: lbCP, 0x2B: lbPR,
    0x2C: lbIS, 0x2D: lbHY, 0x2E: lbIS, 0x2F: lbSY, 0x3A: lbIS, 0x3B: lbIS, 0x3F: lbEX, 0x5B: lbOP, 0x5C: lbPR,
    0x5D: lbCP, 0x7B: lbOP, 0x7C: lbBA, 0x7D: lbCL,
    // Latin-1 and general punctuation that UI text uses.
    0xA0: lbGL, 0xA9: lbAL, 0xAE: lbAL, 0xB0: lbPO, 0xB7: lbAL, 0xAB: lbQU, 0xBB: lbQU,
    0x2013: lbBA, 0x2014: lbB2, 0x2018: lbQU, 0x2019: lbQU, 0x201C: lbQU, 0x201D: lbQU, 0x2026: lbIN,
    0x2022: lbAL, 0x20AC: lbPR, 0x2122: lbAL,
    0x201A: lbOP, 0x201E: lbOP, // low-9 quotation marks (German opening quotes)
    0x2010: lbBA, 0x2011: lbGL, 0xB4: lbBB,
  };
  for (var c = 0x2B0; c < 0x300; c++) {
    t[c] = lbAL; // spacing modifier letters (e.g. the Ukrainian apostrophe U+02BC)
  }
  t[0x2C8] = t[0x2CC] = t[0x2DF] = lbBB;
  special.forEach((k, v) => t[k] = v);
  for (var c = 0xC0; c < 0x250; c++) {
    if (c != 0xD7 && c != 0xF7) t[c] = lbAL; // Latin letters
  }
  for (var c = 0x386; c < 0x3FF; c++) {
    t[c] = lbAL; // Greek letters
  }
  t[0x387] = lbXX;
  for (var c = 0x400; c < 0x500; c++) {
    if (c < 0x483 || c > 0x489) t[c] = lbAL; // Cyrillic letters
  }
  return t;
}();

int lbClass(int codeUnit) => codeUnit < _lbMax ? _lb[codeUnit] : lbXX;

// Scripts, for run boundaries: Flutter shapes each script run separately, so no
// pair adjustment crosses a change of script. Spaces, digits and punctuation are
// Common: they join the run of the preceding letter (or the first letter of the
// paragraph when none precedes them).
const int scCommon = 0, scLatin = 1, scGreek = 2, scCyrillic = 3;
int scriptOf(int cu) {
  if ((cu | 0x20) >= 0x61 && (cu | 0x20) <= 0x7A) return scLatin;
  if (cu < 0xC0) return cu == 0xAA || cu == 0xBA ? scLatin : scCommon;
  if (cu < 0x250) return cu == 0xD7 || cu == 0xF7 ? scCommon : scLatin;
  if (cu >= 0x370 && cu < 0x400) {
    return cu == 0x374 || cu == 0x37E || cu == 0x385 || cu == 0x387 ? scCommon : scGreek;
  }
  if (cu >= 0x400 && cu < 0x500) return scCyrillic;
  return scCommon;
}
bool _isPi(int cu) => cu == 0xAB || cu == 0x2018 || cu == 0x201C;
bool _isPf(int cu) => cu == 0xBB || cu == 0x2019 || cu == 0x201D;

// Direct boundaries (no space between): true = no break allowed.
final List<bool> _noBreak = () {
  final t = List<bool>.filled(nLB * nLB, false);
  void no(int a, int x) => t[a * nLB + x] = true;
  for (var a = 0; a < nLB; a++) {
    for (final x in [lbCL, lbCP, lbEX, lbIS, lbSY]) {
      no(a, x); // LB13
    }
    no(lbOP, a); // LB14
    no(a, lbQU); // LB19 (with LB19a, quotes in non-East-Asian text)
    no(lbQU, a);
    no(a, lbGL); // LB12a, LB12
    no(lbGL, a);
    no(a, lbBA); // LB21
    no(a, lbHY);
    no(a, lbIN); // LB22
    no(lbBB, a); // LB21: no break after BB
  }
  no(lbB2, lbB2); // LB17
  no(lbAL, lbNU);
  no(lbNU, lbAL); // LB23
  for (final p in [lbPR, lbPO]) {
    no(p, lbAL);
    no(lbAL, p); // LB24
  }
  for (final a in [lbPR, lbPO, lbOP, lbHY, lbIS]) {
    no(a, lbNU); // LB25, context-free part
  }
  no(lbAL, lbAL); // LB28
  no(lbIS, lbAL); // LB29
  no(lbAL, lbOP);
  no(lbNU, lbOP);
  no(lbCP, lbAL);
  no(lbCP, lbNU); // LB30
  return t;
}();

// After-space boundaries, [class of last non-space * nLB + class of next].
// UAX #14: LB13 (none before CL CP EX IS SY), LB14 (none after OP), LB17 (B2 SP* × B2).
final List<bool> defaultSpaceRules = () {
  final t = List<bool>.filled(nLB * nLB, true);
  for (var b = 0; b < nLB; b++) {
    for (final x in [lbCL, lbCP, lbEX, lbIS, lbSY]) {
      t[b * nLB + x] = false;
    }
    if (b == lbOP) {
      for (var x = 0; x < nLB; x++) {
        t[b * nLB + x] = false;
      }
    }
  }
  t[lbB2 * nLB + lbB2] = false;
  return t;
}();
final List<bool> permissiveSpaceRules = List<bool>.filled(nLB * nLB, true);

// ---------------------------------------------------------------------------

/// Flutter accumulates glyph positions across a paragraph in float32. They are
/// exact when the scale is a short binary fraction and the paragraph is short
/// enough (12, 16, 24 px for Roboto: measured drift 0). Otherwise they drift by up
/// to 1.14e-5 of the x position (measured at 13, 17, 18.4, 21.3, 33.7 px); the
/// breaker then refuses any decision this margin could flip.
const double driftPerPx = 2.5e-5;

bool exactPositions(double scale, double paragraphPx) {
  for (var bits = 0; bits <= 16; bits++) {
    final v = scale * (1 << bits);
    if (v == v.roundToDouble()) return paragraphPx * (1 << bits) < (1 << 24);
  }
  return false;
}

/// Width-independent records for one paragraph: the width prefix (units) and the
/// break opportunities. Built once; re-wrapping at any width uses [lineStarts].
class Records {
  Records(this.prefix, this.ends, this.nexts, this.count, this.riskyEnds, this.riskyNexts);
  final Float64List prefix;
  final Int32List ends, nexts; // line would end at ends[j]; next line starts at nexts[j]
  final int count; // the last record is the end of the paragraph
  // Spaces where UAX #14 forbids a break but SkParagraph sometimes breaks anyway
  // (inside an unbreakable segment). When one could end the line, the breaker
  // does not guess.
  final Int32List riskyEnds, riskyNexts;

  /// Greedy first-fit line starts for a box [maxWidth] px wide at [scale] px per
  /// unit, or null when Flutter must decide: a word wider than the line, an
  /// ambiguous space that could end it, or a fit decision within float drift.
  Int32List? lineStarts(double maxWidth, double scale) {
    final maxF = _toF32(maxWidth);
    final rel = exactPositions(scale, prefix[prefix.length - 1] * scale) ? 0.0 : driftPerPx;
    var unsure = false;
    // 1 = fits, 0 = does not. Far from the edge: compare in units.
    bool fits(double startUnits, double endUnits) {
      final w = (endUnits - startUnits) * scale;
      final margin = 0.02 + rel * 2 * endUnits * scale;
      if (w <= maxWidth - margin) return true;
      if (w >= maxWidth + margin) return false;
      final f = fitsLine(w, maxF);
      if (rel > 0) {
        final d = rel * 2 * endUnits * scale + 1e-4;
        if (fitsLine(w - d, maxF) != fitsLine(w + d, maxF)) unsure = true;
      }
      return f;
    }

    final out = <int>[0];
    var s = 0, k = 0;
    for (;;) {
      var best = -1;
      final p0 = prefix[s];
      for (var j = k; j < count; j++) {
        if (fits(p0, prefix[ends[j]])) {
          best = j;
        } else {
          break;
        }
      }
      if (best < 0 || unsure) return null;
      if (riskyEnds.isNotEmpty) {
        final from = nexts[best], to = best + 1 < count ? nexts[best + 1] : 1 << 30;
        for (var q = 0; q < riskyEnds.length; q++) {
          if (riskyNexts[q] > from && riskyNexts[q] < to && fits(p0, prefix[riskyEnds[q]])) return null;
        }
        if (unsure) return null;
      }
      if (best == count - 1) return Int32List.fromList(out);
      s = nexts[best];
      out.add(s);
      k = best + 1;
    }
  }

  int lineCount(double maxWidth, double scale) => lineStarts(maxWidth, scale)?.length ?? -1;
}

// Scratch buffers shared by all calls (the breaker runs on one isolate).
Int32List _ends = Int32List(1024), _nexts = Int32List(1024), _rEnds = Int32List(256), _rNexts = Int32List(256);

/// Break opportunities only (pass B), into the scratch buffers. Returns
/// (count, riskyCount), or null when a character is outside the line-break table.
(int, int)? _opportunities(String t) {
  final len = t.length;
  if (_ends.length < len + 2) {
    _ends = Int32List(len * 2 + 2);
    _nexts = Int32List(len * 2 + 2);
  }
  var n = 0, nr = 0;
  var spaceStart = -1, lastNonSpace = -1;
  // LB25 context: is t[i-1] inside NU (NU|SY|IS)*, and was the character before a
  // closing bracket inside one?
  var inNumber = false, closedNumber = false;
  var ca = len > 0 ? lbClass(t.codeUnitAt(0)) : lbSP;
  if (ca == lbXX) return null;
  for (var i = 1; i < len; i++) {
    final x = t.codeUnitAt(i);
    final cx = lbClass(x);
    if (cx == lbXX) return null;
    final wasNumber = inNumber;
    inNumber = ca == lbNU || (inNumber && (ca == lbSY || ca == lbIS));
    closedNumber = wasNumber && (ca == lbCL || ca == lbCP);
    if (ca != lbSP) lastNonSpace = i - 1;
    if (cx == lbSP) {
      if (ca != lbSP) spaceStart = i;
      ca = cx;
      continue; // LB7
    }
    if (ca == lbSP) {
      if (lastNonSpace >= 0) {
        final b = t.codeUnitAt(lastNonSpace);
        var ok = defaultSpaceRules[lbClass(b) * nLB + cx];
        // LB15a: an opening quote in opening position (start, space, OP, QU, GL
        // before it), then spaces.
        if (_isPi(b)) {
          final pb = lastNonSpace > 0 ? lbClass(t.codeUnitAt(lastNonSpace - 1)) : lbSP;
          if (pb == lbSP || pb == lbOP || pb == lbQU || pb == lbGL) ok = false;
        }
        if (_isPf(x)) {
          final nx = i + 1 < len ? lbClass(t.codeUnitAt(i + 1)) : lbSP;
          if (nx == lbSP || nx == lbCL || nx == lbCP || nx == lbEX || nx == lbIS || nx == lbSY || nx == lbQU) {
            ok = false; // LB15b: a closing quote, then space or punctuation
          }
        }
        if (ok) {
          _ends[n] = spaceStart;
          _nexts[n++] = i;
        } else {
          if (nr == _rEnds.length) {
            _rEnds = Int32List(nr * 2)..setRange(0, nr, _rEnds);
            _rNexts = Int32List(nr * 2)..setRange(0, nr, _rNexts);
          }
          _rEnds[nr] = spaceStart;
          _rNexts[nr++] = i;
        }
      }
      ca = cx;
      continue;
    }
    var allowed = !_noBreak[ca * nLB + cx];
    // LB20a: no break after a word-initial hyphen or dash (measured: Flutter treats
    // the en dash like the hyphen here).
    if (allowed && (ca == lbHY || ca == lbBA) && cx == lbAL && (i < 2 || t.codeUnitAt(i - 2) == 0x20)) {
      allowed = false;
    }
    if (allowed) {
      // LB25 (Unicode 15.1): (PR|PO) × (OP|HY) NU; NU (NU|SY|IS)* × (NU|SY|IS|CL|CP);
      // NU (NU|SY|IS)* (CL|CP)? × (PO|PR).
      final nx = i + 1 < len ? lbClass(t.codeUnitAt(i + 1)) : lbXX;
      if ((ca == lbPR || ca == lbPO) && (cx == lbOP || cx == lbHY) && nx == lbNU) allowed = false;
      if (inNumber && (cx == lbNU || cx == lbSY || cx == lbIS || cx == lbCL || cx == lbCP)) allowed = false;
      if ((inNumber || closedNumber) && (cx == lbPO || cx == lbPR)) allowed = false;
    }
    if (allowed) {
      _ends[n] = i;
      _nexts[n++] = i;
    }
    ca = cx;
  }
  var end = len;
  while (end > 0 && t.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  _ends[n] = end;
  _nexts[n++] = len;
  return (n, nr);
}

/// Break opportunities of [t] (for the word-cache baseline), or null.
(Int32List, Int32List)? breakOpportunities(String t) {
  final r = _opportunities(t);
  if (r == null) return null;
  return (Int32List.sublistView(_ends, 0, r.$1), Int32List.sublistView(_nexts, 0, r.$1));
}

/// Passes A and B: width prefix and break opportunities. Null when the paragraph
/// has a character the model, the certificate or the line-break table does not
/// cover, or an island longer than m: such paragraphs are laid out by Flutter.
Records? buildRecords(WidthModel md, String t) {
  final len = t.length;
  final prefix = Float64List(len + 1);
  final idOf = md.idOf, cert = md.cert, adv = md.adv, fc = md.fc, sc = md.sc, cls = md.cls, n1 = md.n1;
  final digit = md.islandDigit, base = md.keyBase, ofKey = md.islandOfKey, m = md.m;
  var p = 0.0;
  var prevId = 0, prevIsland = -1;
  var run = scCommon; // script of the current run
  for (var q = 0; q < len && run == scCommon; q++) {
    run = scriptOf(t.codeUnitAt(q));
  }
  var i = 0;
  while (i < len) {
    final cu = t.codeUnitAt(i);
    final id = idOf[cu];
    if (id == 0) return null;
    final c = cert[id];
    if (c == certU) return null;
    final s = scriptOf(cu);
    if (s != scCommon && s != run) {
      run = s; // a new script run: no pair adjustment across it
      prevId = 0;
      prevIsland = -1;
    }
    if (c != certS) {
      // A P/K run: find its end, and whether it has a primer.
      var j = i, key = 0, primer = false;
      while (j < len) {
        final q = idOf[t.codeUnitAt(j)];
        final dj = digit[q];
        if (q == 0 || dj < 0) break;
        primer = primer || cert[q] == certP;
        if (j - i < m) key = key * base + dj + 1;
        j++;
      }
      if (primer) {
        if (j - i > m) return null;
        final isl = ofKey[key];
        if (isl < 0) return null;
        if (prevId != 0) p += md.islandL[isl * n1 + prevId];
        prefix[i] = p;
        for (var q = i + 1; q < j; q++) {
          prefix[q] = double.nan; // never a break position
        }
        p += md.islandW[isl];
        prevId = 0;
        prevIsland = isl;
        i = j;
        continue;
      }
      // No primer: substitution leaves these characters alone.
      for (; i < j; i++) {
        final q = idOf[t.codeUnitAt(i)];
        if (prevId != 0) {
          p += cls[fc[prevId] + sc[q]];
        } else if (prevIsland >= 0) {
          p += md.islandR[prevIsland * n1 + q];
        }
        prefix[i] = p;
        p += adv[q];
        prevId = q;
        prevIsland = -1;
      }
      continue;
    }
    if (prevId != 0) {
      p += cls[fc[prevId] + sc[id]];
    } else if (prevIsland >= 0) {
      p += md.islandR[prevIsland * n1 + id];
    }
    prefix[i] = p;
    p += adv[id];
    prevId = id;
    prevIsland = -1;
    i++;
  }
  prefix[len] = p;

  final o = _opportunities(t);
  if (o == null) return null;
  final (n, nr) = o;
  for (var j = 0; j < n; j++) {
    if (prefix[_ends[j]].isNaN || prefix[_nexts[j]].isNaN) return null; // a break inside an island
  }
  return Records(prefix, Int32List.fromList(Int32List.sublistView(_ends, 0, n)),
      Int32List.fromList(Int32List.sublistView(_nexts, 0, n)), n, Int32List.fromList(Int32List.sublistView(_rEnds, 0, nr)),
      Int32List.fromList(Int32List.sublistView(_rNexts, 0, nr)));
}
