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

import 'dictionary_break.dart';

typedef Measure = double Function(String text);

// Virtual characters of certify.py: _vBase + 4 * letter + joining form (0 isolated,
// 1 initial, 2 medial, 3 final) for Arabic letters.
const int _vBase = 0x100000;

/// Unicode joining type of the Arabic letters certify.py models by their forms:
/// 2 dual-joining, 1 right-joining, 0 anything else.
int _joining(int cu) {
  if (cu < 0x622 || cu > 0x6FF) return 0;
  const r = [
    0x622,
    0x623,
    0x624,
    0x625,
    0x627,
    0x629,
    0x62F,
    0x630,
    0x631,
    0x632,
    0x648,
    0x671,
    0x672,
    0x673,
    0x675,
    0x676,
    0x677,
    0x6C0,
    0x6CD,
    0x6CF,
    0x6D2,
    0x6D3,
    0x6D5,
    0x6EE,
    0x6EF,
  ];
  if (r.contains(cu) || (cu >= 0x688 && cu <= 0x699) || (cu >= 0x6C3 && cu <= 0x6CB)) return 1;
  final d =
      cu == 0x626 ||
      cu == 0x628 ||
      (cu >= 0x62A && cu <= 0x62E) ||
      (cu >= 0x633 && cu <= 0x63F) ||
      (cu >= 0x641 && cu <= 0x647) ||
      cu == 0x649 ||
      cu == 0x64A ||
      cu == 0x66E ||
      cu == 0x66F ||
      cu == 0x678 ||
      (cu >= 0x679 && cu <= 0x687) ||
      (cu >= 0x69A && cu <= 0x6BF) ||
      cu == 0x6C1 ||
      cu == 0x6C2 ||
      cu == 0x6CC ||
      cu == 0x6CE ||
      cu == 0x6D0 ||
      cu == 0x6D1 ||
      (cu >= 0x6FA && cu <= 0x6FC) ||
      cu == 0x6FF ||
      cu == 0x640; // tatweel is join-causing: HarfBuzz joins it like a dual-joining letter
  return d ? 2 : 0;
}

/// Id of the joining letter at [i] in the form HarfBuzz's Arabic shaper gives it
/// from its neighbours' joining types, or 0 when the sidecar has no such form.
int _formId(WidthModel md, String t, int i, [int? cu]) {
  cu ??= t.codeUnitAt(i);
  // Combining marks are transparent to joining (Unicode joining type T): the
  // neighbours are the nearest characters that are not marks. HarfBuzz composes
  // first, but every composition of an Arabic letter keeps its joining type.
  var a = i - 1, b = i + 1;
  while (a >= 0 && isCombiningMark(t.codeUnitAt(a))) {
    a--;
  }
  while (b < t.length && isCombiningMark(t.codeUnitAt(b))) {
    b++;
  }
  final jp = a >= 0 && _joining(t.codeUnitAt(a)) == 2;
  final jn = _joining(cu) == 2 && b < t.length && _joining(t.codeUnitAt(b)) > 0;
  return md.formIdOf[(cu - 0x600) * 4 + (jp ? (jn ? 2 : 3) : (jn ? 1 : 0))];
}

// Certificate classes from certify.py.
const int certS = 0, certK = 1, certP = 2, certU = 3;

/// A combining mark the font zeroes (GDEF mark): no width when left uncomposed.
const int certM = 4;

/// SkParagraph's line-fit test, emulated in float32: a line fits when its width,
/// floored to 1/100 px (1/10 px from 10,000 px), is not greater than the box width.
/// A key for a pair of code points: arithmetic, not shifts, because shifts
/// truncate to 32 bits on the web.
const _pairBase = 0x200000;
int pairKey(int a, int b) => a * _pairBase + b;

/// A fingerprint of a font file: its length and two 32-bit FNV-1a hashes of its
/// bytes (32-bit arithmetic only, so the web gives the same digest). A sidecar
/// records the digest of the font it was built from.
String fontDigest(Uint8List font) {
  var a = 0x811C9DC5, b = 0x050C5D1F;
  for (final x in font) {
    a ^= x;
    a = (((a << 24) & 0xFFFFFFFF) + a * 0x193) & 0xFFFFFFFF;
    b ^= x ^ 0x5A;
    b = (((b << 24) & 0xFFFFFFFF) + b * 0x193) & 0xFFFFFFFF;
  }
  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${font.length}:${hex(a)}${hex(b)}';
}

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
  // A canary string, or else any certified character with a width.
  var probe = md.probes.keys.firstOrNull, units = probe == null ? 0.0 : md.probes[probe]!;
  if (probe == null) {
    for (var id = 1; id < md.n1 && probe == null; id++) {
      if (md.cert[id] == certS && md.cps[id] < 0x10000 && md.adv[id] > 0) {
        probe = String.fromCharCode(md.cps[id]);
        units = md.adv[id];
      }
    }
    if (probe == null) return;
  }
  const size = 16.01;
  final effective = measure(probe, size) / units * md.upem;
  quantizeFontSize = (effective - (size * 64).floorToDouble() / 64).abs() < (effective - size).abs();
}

/// Whether a hard line break kerns with the character before it as a space does.
/// Measured: it does on macOS (Roboto's T loses its T-space kern before \n), not
/// on Linux, where the engine's font backend does not give \n the space glyph.
/// Set once at startup by [calibrateHardBreak].
bool hardBreakKerns = true;

/// One layout tells whether this engine kerns a hard break like a space: line 0
/// of "a\nb" for the character a whose kern with a space is largest (a tiny one,
/// a float artifact, could not tell). [lineWidth] gives the width of a text's
/// first line, in font units.
void calibrateHardBreak(WidthModel md, double Function(String) lineWidth) {
  final sp = md.idOf[0x20];
  if (sp == 0) return;
  var best = 0, bestKern = 0.0;
  for (var a = 1; a < md.n1; a++) {
    final v = md.pair(a, sp) - (md.clsRight?[md.fc[a] + md.sc[sp]] ?? 0);
    if (md.cert[a] != certS || lbClass(md.cps[a]) == lbXX || md.cps[a] == 0x20) continue;
    if (v.abs() > bestKern.abs()) {
      best = a;
      bestKern = v;
    }
  }
  if (bestKern.abs() < 1) return; // no kern with a space to tell by: nothing to model
  final w = lineWidth('${String.fromCharCode(md.cps[best])}\nx');
  hardBreakKerns = (w - (md.adv[best] + bestKern)).abs() < (w - md.adv[best]).abs();
}

/// Flutter's height of one line at [size]. Default style: the font's line height
/// in pixels, rounded to a whole pixel (measured at 12, 14, 16, 18.4, 24 px). With a
/// height multiplier: size × height, rounded, with both in float32 and the product
/// in double (measured: 15 × 1.3 gives 19, 13 × 1.5 gives 20, 10 × 1.15 gives 11).
double lineHeightPx(WidthModel md, double size, {double? height}) => height == null
    ? (md.lineHeight * effectiveFontSize(size) / md.upem).roundToDouble()
    : (_toF32(size) * _toF32(height)).roundToDouble();

/// Pixels per font unit at [size].
double scaleFor(WidthModel md, double size) => effectiveFontSize(size) / md.upem;

/// A certificate's rows as [WidthModel.distill] reads them: the characters it
/// models (U and unsupported code points left out), with id 0 for "none".
class _CertRows {
  String name = 'font';
  int m = 0;
  // The certificate proves that no positioning depends on a neighbour: every
  // pair term is zero and none is measured (CJK fonts).
  bool pairsNone = false;
  final cps = <int>[0], cl = <int>[certU];
  // Fourth column: whether the character can be the first (f) or second (s)
  // glyph of a pair adjustment. Without it, both.
  final canFirst = <bool>[false], canSecond = <bool>[false];
  // Marks (class M): code point -> (combining class, kerning stops at it,
  // characters next to which it must not be left uncomposed).
  final marks = <int, (int, bool, Set<int>)>{};
  // HarfBuzz's compositions the font has: pairKey(base, mark) -> composite.
  final compose = <int, int>{};
  // Scripts whose lookups differ from the main script's on Common characters:
  // breaker script -> (characters, pairs as pairKey(a, b)).
  final scriptVariant = <int, (Set<int>, Set<int>)>{};

  _CertRows(String certText) {
    for (final line in certText.split('\n')) {
      if (line.startsWith('# compose ')) {
        final x = line.substring(10).trim().split(' ').map((h) => int.parse(h, radix: 16)).toList();
        compose[pairKey(x[0], x[1])] = x[2];
        continue;
      }
      if (line.startsWith('# script ')) {
        // # script <tag> chars <cp>... pairs <a:b>... ('-' for none)
        final w = line.substring(9).trim().split(' ');
        final at = w.indexOf('pairs');
        final cs = {for (final h in w.sublist(2, at)) if (h != '-') int.parse(h, radix: 16)};
        final ps = {
          for (final h in w.sublist(at + 1))
            if (h != '-') pairKey(int.parse(h.split(':')[0], radix: 16), int.parse(h.split(':')[1], radix: 16)),
        };
        for (final sc in _scriptsOfTag[w[0]] ?? const <int>[]) {
          scriptVariant[sc] = (cs, ps);
        }
        continue;
      }
      if (line.startsWith('#')) {
        if (!line.contains(' m=')) continue;
        final mm = RegExp(r'm=(\d+)').firstMatch(line);
        if (mm != null) m = int.parse(mm.group(1)!);
        pairsNone = line.contains(' pairs=none');
        name = line.substring(1).split(' m=').first.trim();
        continue;
      }
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      final cp = int.parse(parts[0], radix: 16);
      final c = const {'S': certS, 'K': certK, 'P': certP, 'U': certU, 'M': certM}[parts[2]]!;
      if (c == certU || (cp >= 0x10000 && cp < _vBase) || (cp >= 0xD800 && cp < 0xE000)) continue;
      if (c == certM) {
        if (parts.length != 6) continue;
        marks[cp] = (
          int.parse(parts[3]),
          parts[4] == 'break',
          parts[5] == '-' ? <int>{} : {for (final h in parts[5].split(',')) int.parse(h, radix: 16)},
        );
      } else if (parts.length != 3 && parts.length != 4) {
        continue;
      }
      cps.add(cp);
      cl.add(c);
      final roles = c == certM ? '-' : (parts.length == 4 ? parts[3] : 'fs');
      canFirst.add(roles.contains('f'));
      canSecond.add(roles.contains('s'));
    }
  }
}

/// What distilling [certText] costs: the characters it models, and the pairs
/// measured (first-capable × second-capable characters; none with pairs=none),
/// one layout each. A build step can refuse a font over its budget up front.
({int characters, int pairs}) certificateSize(String certText) {
  final r = _CertRows(certText);
  final firsts = r.canFirst.where((x) => x).length, seconds = r.canSecond.where((x) => x).length;
  return (characters: r.cps.length - 1, pairs: r.pairsNone ? 0 : firsts * seconds);
}

class WidthModel {
  WidthModel._(
    this.name,
    this.upem,
    this.m,
    this.lineHeight,
    this.cps,
    this.cert,
    this.adv,
    this.fc,
    this.sc,
    this.nS,
    this.cls,
    this.islandChars,
    this.islandOfKey,
    this.islandW,
    this.islandL,
    this.islandR,
    this.probes,
  ) {
    n1 = cps.length;
    idOf = Uint16List(0x10000);
    formIdOf = Uint16List(0x400);
    islandDigit = Int32List(n1)..fillRange(0, n1, -1);
    for (var id = 1; id < n1; id++) {
      final v = cps[id] - _vBase;
      if (v < 0) {
        idOf[cps[id]] = id;
      } else if (v >> 2 >= 0x600 && v >> 2 < 0x700) {
        formIdOf[((v >> 2) - 0x600) * 4 + (v & 3)] = id;
      }
    }
    for (var d = 0; d < islandChars.length; d++) {
      islandDigit[islandChars[d]] = d;
    }
    keyBase = islandChars.length + 1;
    islandCount = islandW.length;
  }

  final String name;

  /// Paragraph direction the sidecar was distilled in. A right-to-left sidecar
  /// describes right-to-left paragraphs whose strong characters are all
  /// right-to-left; a left-to-right one, paragraphs with no right-to-left
  /// characters. Mixed-direction paragraphs go to Flutter.
  bool rtl = false;

  /// Combining marks the certificate models: code point -> (combining class,
  /// kerning stops at it rather than skipping it, characters next to which it
  /// must not be left uncomposed). Empty for sidecars without marks.
  Map<int, (int, bool, Set<int>)> marks = const {};

  /// HarfBuzz's compositions of a base and a mark that the font has:
  /// pairKey(base, mark) -> composite.
  Map<int, int> compose = const {};

  /// Common characters (spaces, digits, punctuation) take the script of their run,
  /// and some fonts give a script lookups of its own over them. The sidecar holds
  /// their widths under the main script (Latin, or Hebrew or Arabic for a
  /// right-to-left one); for every other script whose lookups can change them
  /// (certify.py): the characters, and the pairs (pairKey(a, b)), that the breaker
  /// hands to Flutter in a run of that script ([scCommon]: a run of Common
  /// characters alone).
  Map<int, (Set<int>, Set<int>)> scriptVariant = const {};

  /// Every character the font maps (its cmap), as inclusive [first, last] pairs,
  /// certified or not: Flutter's font fallback picks the first font that has a
  /// character. Null for sidecars built without it.
  List<int>? coverage;

  /// [fontDigest] of the font file the sidecar was built from, or null for
  /// sidecars built without it.
  String? fontDigest;

  /// Whether the font has [cp], or null when the sidecar does not say.
  bool? hasCodePoint(int cp) {
    final c = coverage;
    if (c == null) return null;
    var lo = 0, hi = c.length ~/ 2 - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cp < c[2 * mid]) {
        hi = mid - 1;
      } else if (cp > c[2 * mid + 1]) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }
  final int upem, m;
  final double lineHeight; // one line's height, in units
  final Int32List cps; // id -> codepoint (id 0 = not in the model)
  final Uint8List cert; // id -> certificate class
  final Float64List adv; // id -> advance alone (units)
  final Int32List fc, sc; // id -> first-position row offset (class * nS), second-position class
  final int nS;
  final Float64List cls; // pair class matrix: width(ab) - adv(a) - adv(b)
  final Int32List islandChars; // island digit -> id (P/K characters)
  final Int32List islandOfKey; // island key -> island index, or -1
  final Float64List islandW; // island -> width alone
  final Float64List islandL; // island * n1 + x -> width(xI) - adv(x) - width(I)
  final Float64List islandR; // island * n1 + y -> width(Iy) - width(I) - adv(y)
  final Map<String, double> probes; // canary strings -> expected width (units)
  late final int n1, keyBase, islandCount;
  late final Uint16List idOf;
  // (Arabic letter - 0x600) * 4 + joining form -> id (certify.py's virtual characters).
  late final Uint16List formIdOf;
  late final Int32List islandDigit; // id -> island digit, or -1

  // Text the engine shapes without ligatures (letter spacing switches them off):
  // each character's class under a certificate computed with liga, clig and calt
  // off, and pair values involving the default P/K characters, measured that way.
  // Null when the sidecar has none, or when such text would still need islands.
  Uint8List? noLigaCert;
  Float64List? noLigaRow; // digit * n1 + b -> width(ab) - adv(a) - adv(b), a = islandChars[digit]
  Float64List? noLigaCol; // digit * n1 + a -> width(ab) - adv(a) - adv(b), b = islandChars[digit]
  // Glyph clusters each island shapes to (negative letter spacing keeps ligatures
  // and spaces glyphs, not characters: measured).
  Uint8List? islandClusters;

  // Kerning from a legacy kern or kerx table is split between the two glyphs
  // (HarfBuzz's kern machine puts half on each advance; measured: Times New
  // Roman's space-A kern), so a line that starts at the right glyph carries its
  // share. These are the right glyph's shares, laid out like cls, islandL and
  // islandR; null when every share is on the left glyph (GPOS pair positioning).
  Float64List? clsRight, islandLRight, islandRRight;
  // The same for text without ligatures, for the pairs noLigaRow and noLigaCol hold.
  Float64List? noLigaRowRight, noLigaColRight;

  /// Right glyph's share of pair (a, b) without ligatures (split kerning only).
  double rightNoLiga(int a, int b) {
    final da = islandDigit[a];
    if (da >= 0) return noLigaRowRight![da * n1 + b];
    final db = islandDigit[b];
    if (db >= 0) return noLigaColRight![db * n1 + a];
    return clsRight![fc[a] + sc[b]];
  }

  double pair(int a, int b) => cls[fc[a] + sc[b]];

  double pairNoLiga(int a, int b) {
    final da = islandDigit[a];
    if (da >= 0) return noLigaRow![da * n1 + b];
    final db = islandDigit[b];
    if (db >= 0) return noLigaCol![db * n1 + a];
    return cls[fc[a] + sc[b]];
  }

  static Map<int, int> _classes(String certText) => {
    for (final line in certText.split('\n'))
      if (!line.startsWith('#') && line.trim().split(RegExp(r'\s+')).length >= 3)
        int.parse(line.trim().split(RegExp(r'\s+'))[0], radix: 16): const {
          'S': certS,
          'K': certK,
          'P': certP,
          'U': certU,
          'M': certM,
        }[line.trim().split(RegExp(r'\s+'))[2]]!,
  };

  void _distillNoLiga(
    String certText,
    Measure measure,
    int Function(String) clusters,
    double Function(String text, int k)? measurePrefix,
  ) {
    final classes = _classes(certText);
    final c = Uint8List(n1)..[0] = certU;
    for (var id = 1; id < n1; id++) {
      c[id] = cps[id] >= _vBase ? certU : classes[cps[id]] ?? certU;
    }
    // Characters that still need islands without ligatures (some other feature
    // substitutes them) are not modelled for letter-spaced text.
    for (var id = 1; id < n1; id++) {
      if (c[id] == certP || c[id] == certK) c[id] = certU;
    }
    final str = [for (final cp in cps) String.fromCharCode(cp)];
    final nI = islandChars.length;
    final row = Float64List(nI * n1), col = Float64List(nI * n1);
    final split = clsRight != null && measurePrefix != null;
    final rowR = split ? Float64List(nI * n1) : null, colR = split ? Float64List(nI * n1) : null;
    for (var d = 0; d < nI; d++) {
      final a = islandChars[d];
      if (measure(str[a]) != adv[a]) c[a] = certU; // its advance alone must not change
      for (var b = 1; b < n1; b++) {
        final ab = str[a] + str[b], ba = str[b] + str[a];
        row[d * n1 + b] = measure(ab) - adv[a] - adv[b];
        col[d * n1 + b] = measure(ba) - adv[b] - adv[a];
        if (split && lbClass(cps[a]) != lbXX && lbClass(cps[b]) != lbXX) {
          if (row[d * n1 + b] != 0) rowR![d * n1 + b] = row[d * n1 + b] - (measurePrefix(ab, 1) - adv[a]);
          if (col[d * n1 + b] != 0) colR![d * n1 + b] = col[d * n1 + b] - (measurePrefix(ba, 1) - adv[b]);
        }
      }
    }
    noLigaRowRight = rowR;
    noLigaColRight = colR;
    noLigaCert = c;
    noLigaRow = row;
    noLigaCol = col;
    final ic = Uint8List(islandCount);
    void visit(String s, int key, int len) {
      if (key > 0 && islandOfKey[key] >= 0) ic[islandOfKey[key]] = clusters(s);
      if (len == m) return;
      for (var d = 0; d < islandChars.length; d++) {
        visit(s + str[islandChars[d]], key * keyBase + d + 1, len + 1);
      }
    }

    visit('', 0, 0);
    islandClusters = ic;
  }

  /// Builds the tables by measuring with [measure] at font size = units per em.
  /// With [noLigaCertText] (certify.py with CERTIFY_FEATURES_OFF=liga,clig,calt)
  /// and [measureNoLiga] (the engine's widths without ligatures), also the tables
  /// for letter-spaced text. The island bound shrinks below the certificate's
  /// until the islands times the safe characters (the island measurements) fit
  /// [islandBudget]; a longer run of island characters is handed to Flutter.
  static WidthModel distill(
    String certText,
    Measure measure,
    int upem,
    double lineHeight, {
    String? noLigaCertText,
    Measure? measureNoLiga,
    int Function(String)? clustersOf,
    bool rtl = false,
    double Function(String text, int k)? measurePrefix,
    double Function(String text, int k)? measurePrefixNoLiga,
    int islandBudget = 2500000,
  }) {
    final rows = _CertRows(certText);
    final name = rows.name, pairsNone = rows.pairsNone;
    var m = rows.m;
    final cps = rows.cps, cl = rows.cl, canFirst = rows.canFirst, canSecond = rows.canSecond;
    final n1 = cps.length;
    // A joining form is measured in its context: a zero-width joiner before a
    // form that joins the previous letter, and after one that joins the next.
    final str = [for (final cp in cps) String.fromCharCode(cp < _vBase ? cp : (cp - _vBase) >> 2)];
    final jp = [for (final cp in cps) cp >= _vBase && (cp - _vBase) & 3 >= 2];
    final jn = [for (final cp in cps) cp >= _vBase && ((cp - _vBase) & 3 == 1 || (cp - _vBase) & 3 == 2)];
    String realize(String core, int first, int last) => '${jp[first] ? '\u200D' : ''}$core${jn[last] ? '\u200D' : ''}';
    final adv = Float64List(n1);
    for (var id = 1; id < n1; id++) {
      if (cl[id] == certM) {
        // A mark: HarfBuzz zeroes a GDEF mark's advance. Checked after a base it
        // neither composes with nor is excluded next to; otherwise not modelled.
        final info = rows.marks[cps[id]]!;
        final base = [0x30, 0x78, 0x71].firstWhere(
          (b) => rows.compose[pairKey(b, cps[id])] == null && !info.$3.contains(b),
          orElse: () => -1,
        );
        final b = String.fromCharCode(base);
        if (base < 0 || (measure(b + str[id]) - measure(b)).abs() > 1e-9) cl[id] = certU;
        continue;
      }
      adv[id] = measure(realize(str[id], id, id));
    }
    // Pairs measured: first-capable × second-capable characters; every other pair
    // is zero by the certificate (and with pairs=none, every pair).
    final k1 = <int>[], k2 = <int>[];
    final pos1 = Int32List(n1)..fillRange(0, n1, -1), pos2 = Int32List(n1)..fillRange(0, n1, -1);
    for (var id = 1; id < n1 && !pairsNone; id++) {
      if (canFirst[id]) {
        pos1[id] = k1.length;
        k1.add(id);
      }
      if (canSecond[id]) {
        pos2[id] = k2.length;
        k2.add(id);
      }
    }
    final n2 = k2.length;
    final dense = Float64List(k1.length * n2);
    // Right-glyph shares of kerned pairs: the pair minus the first glyph's cluster
    // growth ([measurePrefix] gives the width of the first k code units' clusters).
    Float64List? right;
    for (var x = 0; x < k1.length; x++) {
      final a = k1[x];
      for (var y = 0; y < n2; y++) {
        final b = k2[y];
        if (jn[a] != jp[b]) continue; // forms that cannot be neighbours
        final ab = realize(str[a] + str[b], a, b);
        final v = dense[x * n2 + y] = measure(ab) - adv[a] - adv[b];
        // A pair with a primer may ligate, and a combining mark joins the cluster
        // before it: their boxes then split a ligature or a cluster, not a kern.
        // Characters outside the line-break table never reach the breaker.
        final ligates = cl[a] != certS && cl[b] != certS && (cl[a] == certP || cl[b] == certP);
        final used = lbClass(cps[a]) != lbXX && lbClass(cps[b]) != lbXX;
        if (v != 0 && measurePrefix != null && !ligates && used) {
          final rs = v - (measurePrefix(ab, jp[a] ? 2 : 1) - adv[a]);
          if (rs != 0) (right ??= Float64List(k1.length * n2))[x * n2 + y] = rs;
        }
      }
    }
    int code(Float64List? m, int a, int b) =>
        m == null || pos1[a] < 0 || pos2[b] < 0 ? 0x8000 : (m[pos1[a] * n2 + pos2[b]] * 4).round() + 0x8000;
    // Compress: identical rows share a first-position class, identical columns a
    // second-position class.
    final rowClass = Int32List(n1), colClass = Int32List(n1);
    final rowKeys = <String, int>{}, colKeys = <String, int>{};
    for (var a = 0; a < n1; a++) {
      final key = String.fromCharCodes([
        for (final b in k2) ...[code(dense, a, b), if (right != null) code(right, a, b)],
      ]);
      rowClass[a] = rowKeys.putIfAbsent(key, () => rowKeys.length);
    }
    for (var b = 0; b < n1; b++) {
      final key = String.fromCharCodes([
        for (final a in k1) ...[code(dense, a, b), if (right != null) code(right, a, b)],
      ]);
      colClass[b] = colKeys.putIfAbsent(key, () => colKeys.length);
    }
    final nF = rowKeys.length, nS = colKeys.length;
    final cls = Float64List(nF * nS);
    final clsRight = right == null ? null : Float64List(nF * nS);
    for (var x = 0; x < k1.length; x++) {
      for (var y = 0; y < n2; y++) {
        cls[rowClass[k1[x]] * nS + colClass[k2[y]]] = dense[x * n2 + y];
        if (clsRight != null) clsRight[rowClass[k1[x]] * nS + colClass[k2[y]]] = right![x * n2 + y];
      }
    }
    final fc = Int32List.fromList([for (var a = 0; a < n1; a++) rowClass[a] * nS]);
    // Islands: every P/K string of length <= m that contains a primer.
    final ik = [
      for (var id = 1; id < n1; id++)
        if (cl[id] == certK || cl[id] == certP) id,
    ];
    final safe = [
      for (var id = 1; id < n1; id++)
        if (cl[id] == certS) id,
    ];
    // Islands of each length, counted by (has a primer, last joins the next).
    var count = <(bool, bool), int>{(false, false): 1}, islands = 0;
    for (var len = 1; len <= m; len++) {
      final next = <(bool, bool), int>{};
      for (final e in count.entries) {
        for (final id in ik) {
          if (len > 1 && e.key.$2 != jp[id]) continue;
          final k = (e.key.$1 || cl[id] == certP, jn[id]);
          next[k] = (next[k] ?? 0) + e.value;
        }
      }
      count = next;
      islands += (count[(true, false)] ?? 0) + (count[(true, true)] ?? 0);
      if (islands * safe.length > islandBudget) {
        m = len - 1;
        break;
      }
    }
    final base = ik.length + 1;
    var keys = 1;
    for (var i = 0; i <= m; i++) {
      keys *= base;
    }
    final islandOfKey = Int32List(keys)..fillRange(0, keys, -1);
    final w = <double>[], l = <double>[], r = <double>[], lRight = <double>[], rRight = <double>[];
    var splitIslands = false;
    void visit(String s, int key, int len, bool primer, int first, int last) {
      if (len > 0 && primer) {
        islandOfKey[key] = w.length;
        final wi = measure(realize(s, first, last));
        w.add(wi);
        final lrow = List<double>.filled(n1, double.nan), rrow = List<double>.filled(n1, double.nan);
        final lr = List<double>.filled(n1, 0), rr = List<double>.filled(n1, 0);
        for (final x in safe) {
          if (jn[x] == jp[first]) {
            final xs = realize(str[x] + s, x, last);
            lrow[x] = measure(xs) - adv[x] - wi;
            if (measurePrefix != null && lrow[x] != 0) lr[x] = lrow[x] - (measurePrefix(xs, jp[x] ? 2 : 1) - adv[x]);
          }
          if (jn[last] == jp[x]) {
            final sx = realize(s + str[x], first, x);
            rrow[x] = measure(sx) - wi - adv[x];
            if (measurePrefix != null && rrow[x] != 0) {
              rr[x] = rrow[x] - (measurePrefix(sx, (jp[first] ? 1 : 0) + s.length) - wi);
            }
          }
          splitIslands = splitIslands || lr[x] != 0 || rr[x] != 0;
        }
        l.addAll(lrow);
        r.addAll(rrow);
        lRight.addAll(lr);
        rRight.addAll(rr);
      }
      if (len == m) return;
      for (var d = 0; d < ik.length; d++) {
        if (len > 0 && jn[last] != jp[ik[d]]) continue; // forms that cannot be neighbours
        visit(
          s + str[ik[d]],
          key * base + d + 1,
          len + 1,
          primer || cl[ik[d]] == certP,
          len == 0 ? ik[d] : first,
          ik[d],
        );
      }
    }

    visit('', 0, 0, false, 0, 0);
    // Canary probes: ordinary text whose width must match after shipping.
    final probeTexts = rtl
        ? [
            for (final p in const [
              'שלום עולם, מה שלומך היום?',
              'אבגדהוזחטיכלמנסעפצקרשת ךםןףץ',
              'ספר, עט ומחברת.',
              'مرحبا بالعالم، كيف حالك اليوم؟',
              'نص عربي للتجربة',
            ])
              // Only text the font covers: other glyphs come from fallback fonts,
              // which differ between devices.
              if (p.codeUnits.every(
                (c) => c == 0x20 || c == 0x60C || c == 0x61F || cps.contains(c) || cps.contains(_vBase + 4 * c),
              ))
                p,
          ]
        : const [
            'The quick brown fox jumps over the lazy dog.',
            'AVAWATAY To Te Wa fi fl ffi office',
            'Hello, world! 12,345.67',
            'Съешь же ещё этих мягких французских булок',
            'Ξεσκεπάζω την ψυχοφθόρα βδελυγμία',
          ];
    final probes = <String, double>{for (final p in probeTexts) p: measure(p)};
    final md = WidthModel._(
      name,
      upem,
      m,
      lineHeight,
      Int32List.fromList(cps),
      Uint8List.fromList(cl),
      adv,
      fc,
      colClass,
      nS,
      cls,
      Int32List.fromList(ik),
      islandOfKey,
      Float64List.fromList(w),
      Float64List.fromList(l),
      Float64List.fromList(r),
      probes,
    );
    md.rtl = rtl;
    md.marks = {
      for (final e in rows.marks.entries)
        if (cl[cps.indexOf(e.key)] == certM) e.key: e.value,
    };
    md.compose = rows.compose;
    md.scriptVariant = rows.scriptVariant;
    if (clsRight != null || splitIslands) {
      md.clsRight = clsRight ?? Float64List(nF * nS);
      md.islandLRight = Float64List.fromList(lRight);
      md.islandRRight = Float64List.fromList(rRight);
    }
    if (noLigaCertText != null && measureNoLiga != null && clustersOf != null) {
      md._distillNoLiga(noLigaCertText, measureNoLiga, clustersOf, measurePrefixNoLiga);
    }
    return md;
  }

  /// The sidecar file. Values are font units (stored as float32).
  Uint8List encode() {
    final meta = utf8.encode(
      jsonEncode({
        'name': name,
        'upem': upem,
        'm': m,
        'lineHeight': lineHeight,
        'n1': n1,
        'nS': nS,
        'nF': cls.length ~/ nS,
        'islands': islandCount,
        'islandChars': islandChars.length,
        'keys': islandOfKey.length,
        'probes': probes,
        if (rtl) 'direction': 'rtl',
        if (clsRight != null) 'split': true,
        if (noLigaRowRight != null) 'splitNoLiga': true,
        if (noLigaCert != null) 'noLiga': true,
        if (coverage != null) 'coverage': coverage,
        if (fontDigest != null) 'font': fontDigest,
        if (marks.isNotEmpty)
          'marks': [
            for (final e in marks.entries) [e.key, e.value.$1, e.value.$2 ? 1 : 0, e.value.$3.toList()..sort()],
          ],
        if (compose.isNotEmpty) 'compose': [for (final e in compose.entries) ...[e.key ~/ _pairBase, e.key % _pairBase, e.value]],
        if (scriptVariant.isNotEmpty)
          'scripts': [
            for (final e in scriptVariant.entries) [e.key, e.value.$1.toList()..sort(), e.value.$2.toList()..sort()],
          ],
      }),
    );
    final b = BytesBuilder()
      ..add(
        (ByteData(8)
              ..setUint32(0, 0x42465732) // "BFW2"
              ..setUint32(4, meta.length))
            .buffer
            .asUint8List(),
      )
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
    final safe = [
      for (var id = 1; id < n1; id++)
        if (cert[id] == certS) id,
    ];
    final lr = Float32List(islandCount * safe.length * 2);
    var o = 0;
    for (var i = 0; i < islandCount; i++) {
      for (final x in safe) {
        lr[o++] = islandL[i * n1 + x];
        lr[o++] = islandR[i * n1 + x];
      }
    }
    b.add(lr.buffer.asUint8List());
    if (noLigaCert != null) {
      b.add(noLigaCert!);
      pad();
      b.add(Float32List.fromList(noLigaRow!).buffer.asUint8List());
      b.add(Float32List.fromList(noLigaCol!).buffer.asUint8List());
      b.add(islandClusters!);
      pad();
    }
    if (clsRight != null) {
      b.add(Float32List.fromList(clsRight!).buffer.asUint8List());
      final rs = Float32List(islandCount * safe.length * 2);
      var o2 = 0;
      for (var i = 0; i < islandCount; i++) {
        for (final x in safe) {
          rs[o2++] = islandLRight![i * n1 + x];
          rs[o2++] = islandRRight![i * n1 + x];
        }
      }
      b.add(rs.buffer.asUint8List());
    }
    if (noLigaRowRight != null) {
      b.add(Float32List.fromList(noLigaRowRight!).buffer.asUint8List());
      b.add(Float32List.fromList(noLigaColRight!).buffer.asUint8List());
    }
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
    final safe = [
      for (var id = 1; id < n1; id++)
        if (cert[id] == certS) id,
    ];
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
    final md = WidthModel._(
      meta['name'] as String,
      meta['upem'] as int,
      meta['m'] as int,
      (meta['lineHeight'] as num).toDouble(),
      cps,
      cert,
      adv,
      Int32List.fromList([for (final v in fcls) v * nS]),
      sc,
      nS,
      cls,
      islandChars,
      islandOfKey,
      islandW,
      islandL,
      islandR,
      (meta['probes'] as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
    );
    md.rtl = meta['direction'] == 'rtl';
    if (meta['coverage'] != null) md.coverage = (meta['coverage'] as List).cast<int>();
    md.fontDigest = meta['font'] as String?;
    if (meta['marks'] != null) {
      md.marks = {
        for (final e in (meta['marks'] as List).cast<List>())
          e[0] as int: (e[1] as int, e[2] == 1, (e[3] as List).cast<int>().toSet()),
      };
    }
    if (meta['compose'] != null) {
      final c = (meta['compose'] as List).cast<int>();
      md.compose = {for (var i = 0; i + 2 < c.length; i += 3) pairKey(c[i], c[i + 1]): c[i + 2]};
    }
    if (meta['scripts'] != null) {
      md.scriptVariant = {
        for (final e in (meta['scripts'] as List).cast<List>())
          e[0] as int: ((e[1] as List).cast<int>().toSet(), (e[2] as List).cast<int>().toSet()),
      };
    }
    if (meta['noLiga'] == true) {
      md.noLigaCert = Uint8List.fromList(copy.sublist(off, off + n1));
      off = (off + n1 + 3) & ~3;
      md.noLigaRow = f32(nI * n1);
      md.noLigaCol = f32(nI * n1);
      md.islandClusters = Uint8List.fromList(copy.sublist(off, off + islands));
      off = (off + islands + 3) & ~3;
    }
    if (meta['split'] == true) {
      md.clsRight = f32(nF * nS);
      final rs = f32(islands * safe.length * 2);
      final lr = Float64List(islands * n1), rr = Float64List(islands * n1);
      var o2 = 0;
      for (var i = 0; i < islands; i++) {
        for (final x in safe) {
          lr[i * n1 + x] = rs[o2++];
          rr[i * n1 + x] = rs[o2++];
        }
      }
      md.islandLRight = lr;
      md.islandRRight = rr;
    }
    if (meta['splitNoLiga'] == true) {
      md.noLigaRowRight = f32(nI * n1);
      md.noLigaColRight = f32(nI * n1);
    }
    return md;
  }

  /// Model width of [text] on one line, in units (for canaries and checks).
  double widthOf(String text) {
    final r = buildRecords(this, text);
    return r == null ? double.nan : r.prefix[text.length];
  }

  String describe() =>
      '$name: ${n1 - 1} characters, pair classes ${cls.length ~/ nS}x$nS, '
      '$islandCount islands up to m=$m';
}

// ---------------------------------------------------------------------------
// Line-break classes (UAX #14) for the characters this breaker handles. Anything
// else sends its paragraph to Flutter.
const int lbAL = 0,
    lbNU = 1,
    lbSP = 2,
    lbBA = 3,
    lbHY = 4,
    lbIS = 5,
    lbEX = 6,
    lbOP = 7,
    lbCL = 8,
    lbCP = 9,
    lbQU = 10,
    lbSY = 11,
    lbPR = 12,
    lbPO = 13,
    lbIN = 14,
    lbB2 = 15,
    lbGL = 16,
    lbBB = 17,
    lbXX = 18,
    lbID = 19,
    lbNS = 20;
const int nLB = 21;
const int _lbMax = 0x10000;
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
  for (var c = 0x5D0; c <= 0x5F4; c++) {
    if (c <= 0x5EA || c >= 0x5EF) t[c] = lbAL; // Hebrew letters (HL), geresh, gershayim
  }
  t[0x5BE] = lbBA; // maqaf
  for (var c = 0x620; c < 0x700; c++) {
    if ((c >= 0x620 && c <= 0x64A) ||
        (c >= 0x66E && c <= 0x6D3) ||
        c == 0x6D5 ||
        c == 0x6EE ||
        c == 0x6EF ||
        c >= 0x6FA) {
      t[c] = lbAL; // Arabic letters
    } else if ((c >= 0x660 && c <= 0x669) || c == 0x66B || c == 0x66C || (c >= 0x6F0 && c <= 0x6F9)) {
      t[c] = lbNU;
    }
  }
  t[0x60C] = lbIS; // Arabic comma
  t[0x964] = t[0x965] = lbBA; // danda, double danda
  t[0x61B] = t[0x61F] = t[0x6D4] = lbEX; // semicolon, question mark, full stop
  // CJK: ideographs, kana and Hangul syllables are ID (a break between any two),
  // and so are small kana (CJ); iteration marks are NS; brackets OP and CL; the
  // ideographic space BA.
  void range(int a, int b, int c) {
    for (var x = a; x <= b; x++) {
      t[x] = c;
    }
  }

  range(0x3041, 0x3096, lbID);
  range(0x30A1, 0x30FA, lbID);
  range(0x3400, 0x4DBF, lbID);
  range(0x4E00, 0x9FFF, lbID);
  range(0xAC00, 0xD7A3, lbID);
  range(0xF900, 0xFAFF, lbID);
  for (final c in [
    0x3041,
    0x3043,
    0x3045,
    0x3047,
    0x3049,
    0x3063,
    0x3083,
    0x3085,
    0x3087,
    0x308E,
    0x3095,
    0x3096,
    0x30A1,
    0x30A3,
    0x30A5,
    0x30A7,
    0x30A9,
    0x30C3,
    0x30E3,
    0x30E5,
    0x30E7,
    0x30EE,
    0x30F5,
    0x30F6,
    0x30FC,
  ]) {
    t[c] = lbID; // small kana and the prolonged sound mark (CJ): measured, Flutter breaks before them
  }
  for (final c in [
    0x3005,
    0x301C,
    0x303B,
    0x303C,
    0x309B,
    0x309C,
    0x309D,
    0x309E,
    0x30A0,
    0x30FB,
    0x30FD,
    0x30FE,
    0xFF1A,
    0xFF1B,
    0xFF65,
  ]) {
    t[c] = lbNS;
  }
  for (final c in [0x3006, 0x3007, 0x3012, 0x3013, 0x3020, 0x3030, 0x303D, 0x303E, 0x303F, 0x309F, 0x30FF]) {
    t[c] = lbID;
  }
  range(0x3021, 0x3029, lbID);
  range(0x3031, 0x3034, lbID);
  range(0x3036, 0x303A, lbID);
  t[0x3000] = lbBA;
  for (final c in [
    0x3001,
    0x3002,
    0x3009,
    0x300B,
    0x300D,
    0x300F,
    0x3011,
    0x3015,
    0x3017,
    0x3019,
    0x301B,
    0x301E,
    0x301F,
    0xFF09,
    0xFF0C,
    0xFF0E,
    0xFF3D,
    0xFF5D,
    0xFF60,
    0xFF61,
    0xFF63,
    0xFF64,
  ]) {
    t[c] = lbCL;
  }
  for (final c in [
    0x3008,
    0x300A,
    0x300C,
    0x300E,
    0x3010,
    0x3014,
    0x3016,
    0x3018,
    0x301A,
    0x301D,
    0xFF08,
    0xFF3B,
    0xFF5B,
    0xFF5F,
    0xFF62,
  ]) {
    t[c] = lbOP;
  }
  t[0xFF01] = t[0xFF1F] = lbEX;
  t[0xFF04] = lbPR;
  t[0xFF05] = lbPO;
  for (final c in [
    0xFF02,
    0xFF03,
    0xFF06,
    0xFF07,
    0xFF0A,
    0xFF0B,
    0xFF0D,
    0xFF0F,
    0xFF1C,
    0xFF1D,
    0xFF1E,
    0xFF20,
    0xFF3C,
    0xFF3E,
    0xFF3F,
    0xFF40,
    0xFF5C,
    0xFF5E,
  ]) {
    t[c] = lbID;
  }
  range(0xFF10, 0xFF19, lbID);
  range(0xFF21, 0xFF3A, lbID);
  range(0xFF41, 0xFF5A, lbID);
  return t;
}();

bool _isHL(int cu) => (cu >= 0x5D0 && cu <= 0x5EA) || (cu >= 0x5EF && cu <= 0x5F2);

int lbClass(int codeUnit) => codeUnit < _lbMax ? _lb[codeUnit] : lbXX;

// Scripts, for run boundaries: Flutter shapes each script run separately, so no
// pair adjustment crosses a change of script. Spaces, digits and punctuation are
// Common: they join the run of the preceding letter (or the first letter of the
// paragraph when none precedes them).
const int scCommon = 0,
    scLatin = 1,
    scGreek = 2,
    scCyrillic = 3,
    scHebrew = 4,
    scHan = 5,
    scHiragana = 6,
    scHangul = 7,
    scKatakana = 8,
    scArabic = 9,
    // Any other script (a run measured through Flutter, e.g. Devanagari).
    scOther = 10;
// OpenType script tags (certify.py's "# script" lines) -> breaker scripts. DFLT is
// a run of Common characters alone.
const _scriptsOfTag = {
  'DFLT': [scCommon],
  'latn': [scLatin],
  'grek': [scGreek],
  'cyrl': [scCyrillic],
  'hebr': [scHebrew],
  'arab': [scArabic],
  'hani': [scHan],
  'kana': [scHiragana, scKatakana],
  'hang': [scHangul],
};
int scriptOf(int cu) {
  if ((cu | 0x20) >= 0x61 && (cu | 0x20) <= 0x7A) return scLatin;
  if (cu < 0xC0) return cu == 0xAA || cu == 0xBA ? scLatin : scCommon;
  if (cu < 0x250) return cu == 0xD7 || cu == 0xF7 ? scCommon : scLatin;
  if (cu >= 0x370 && cu < 0x400) {
    return cu == 0x374 || cu == 0x37E || cu == 0x385 || cu == 0x387 ? scCommon : scGreek;
  }
  if (cu >= 0x400 && cu < 0x500) return scCyrillic;
  if (cu >= 0x590 && cu < 0x600) return scHebrew;
  if (cu >= 0x600 && cu < 0x700) return cu == 0x60C || cu == 0x61B || cu == 0x61F || cu == 0x640 ? scCommon : scArabic;
  if (cu >= 0x3041 && cu <= 0x309A) return scHiragana;
  if (cu >= 0x30A1 && cu <= 0x30FA) return scKatakana;
  if (cu == 0x3005 ||
      cu == 0x3007 ||
      (cu >= 0x3021 && cu <= 0x3029) ||
      (cu >= 0x3400 && cu <= 0x9FFF) ||
      (cu >= 0xF900 && cu <= 0xFAFF)) {
    return scHan;
  }
  if (cu >= 0xAC00 && cu <= 0xD7A3) return scHangul;
  return scCommon;
}

// Bidi classes, coarsely, for the characters this breaker handles: strong
// right-to-left (Hebrew, Arabic), strong left-to-right (the letters of Latin,
// Greek and Cyrillic, spacing modifier letters) and numbers. Everything else it
// handles is neutral (spaces, punctuation, symbols).
bool _strongR(int cu) => (cu >= 0x590 && cu < 0x900) || (cu >= 0xFB1D && cu < 0xFE00) || (cu >= 0xFE70 && cu < 0xFF00);
// UAX #9 classes for [bidiLevels].
const int _bL = 0, _bR = 1, _bEN = 2, _bES = 3, _bET = 4, _bCS = 5, _bWS = 6, _bON = 7, _bB = 8, _bAL = 9, _bAN = 10;

/// The bidi class of [cu], or -1 where the implicit algorithm here does not
/// apply: combining marks (NSM), explicit formatting characters, and characters
/// this breaker does not handle anyway.
int _bidiClass(int cu) {
  if (cu == 0x0A || cu == 0x2029) return _bB;
  if (cu == 0x20 || cu == 0x2028 || (cu >= 0x2000 && cu <= 0x200A)) return _bWS;
  if (cu >= 0x30 && cu <= 0x39) return _bEN;
  if ((cu | 0x20) >= 0x61 && (cu | 0x20) <= 0x7A) return _bL;
  if (cu < 0x80) {
    if (cu == 0x2B || cu == 0x2D) return _bES;
    if (cu >= 0x23 && cu <= 0x25) return _bET;
    if (cu == 0x2C || cu == 0x2E || cu == 0x2F || cu == 0x3A) return _bCS;
    return cu >= 0x21 ? _bON : -1;
  }
  if (cu < 0xC0) {
    if (cu == 0xA0) return _bCS;
    if ((cu >= 0xA2 && cu <= 0xA5) || cu == 0xB0 || cu == 0xB1) return _bET;
    if (cu == 0xB2 || cu == 0xB3 || cu == 0xB9) return _bEN;
    if (cu == 0xAA || cu == 0xB5 || cu == 0xBA) return _bL;
    return _bON;
  }
  if (cu < 0x250) return cu == 0xD7 || cu == 0xF7 ? _bON : _bL;
  if (cu >= 0x2B0 && cu < 0x300) {
    final l =
        cu <= 0x2B8 ||
        (cu >= 0x2BB && cu <= 0x2C1) ||
        cu == 0x2D0 ||
        cu == 0x2D1 ||
        (cu >= 0x2E0 && cu <= 0x2E4) ||
        cu == 0x2EE;
    return l ? _bL : _bON;
  }
  if (cu >= 0x370 && cu < 0x400) {
    return cu == 0x374 || cu == 0x375 || cu == 0x37E || cu == 0x384 || cu == 0x385 || cu == 0x387 || cu == 0x3F6
        ? _bON
        : _bL;
  }
  if (cu >= 0x400 && cu < 0x500) return cu >= 0x483 && cu <= 0x489 ? -1 : _bL;
  if (cu == 0x5BE ||
      cu == 0x5C0 ||
      cu == 0x5C3 ||
      cu == 0x5C6 ||
      (cu >= 0x5D0 && cu <= 0x5EA) ||
      (cu >= 0x5EF && cu <= 0x5F4)) {
    return _bR;
  }
  if (cu >= 0x600 && cu < 0x700) {
    if (cu >= 0x660 && cu <= 0x66C && cu != 0x66A) return _bAN; // Arabic-Indic digits and separators
    if (cu == 0x66A) return _bET;
    if (cu >= 0x6F0 && cu <= 0x6F9) return _bEN; // extended Arabic-Indic digits
    if (cu == 0x60C) return _bCS;
    if (_joining(cu) > 0 || cu == 0x61B || cu == 0x61F || cu == 0x6D4 || cu == 0x621) return _bAL;
    return -1; // marks and the rest
  }
  if (cu >= 0x590 && cu < 0x900) return -1; // Hebrew marks, other scripts
  if (cu == 0x202F || cu == 0x2044) return _bCS;
  if ((cu >= 0x2030 && cu <= 0x2034) || (cu >= 0x20A0 && cu <= 0x20CF)) return _bET;
  if (cu == 0x200E || cu == 0x200F || (cu >= 0x202A && cu <= 0x202E) || (cu >= 0x2066 && cu <= 0x2069)) return -1;
  if (cu >= 0x2010 && cu < 0x2200) return _bON;
  return -1;
}

/// Embedding levels of [t] by the Unicode bidi algorithm's implicit rules (W1-W7,
/// N1-N2, I1-I2), each paragraph (split at \n and U+2029) at level 1 when
/// [rtlParagraph], else 0. Null when a character has no class here (see
/// [_bidiClass]): those paragraphs go to Flutter.
Uint8List? bidiLevels(String t, {required bool rtlParagraph}) {
  final len = t.length;
  final types = Uint8List(len), levels = Uint8List(len);
  for (var i = 0; i < len; i++) {
    final c = _bidiClass(t.codeUnitAt(i));
    if (c < 0) return null;
    types[i] = c;
  }
  final e = rtlParagraph ? 1 : 0, eDir = rtlParagraph ? _bR : _bL;
  var s = 0;
  while (s < len) {
    var end = s;
    while (end < len && types[end] != _bB) {
      end++;
    }
    // W2: a European number after Arabic letters is an Arabic number. W3: Arabic
    // letters are right-to-left.
    var last = eDir;
    for (var i = s; i < end; i++) {
      final c = types[i];
      if (c == _bL || c == _bR || c == _bAL) {
        last = c;
      } else if (c == _bEN && last == _bAL) {
        types[i] = _bAN;
      }
    }
    for (var i = s; i < end; i++) {
      if (types[i] == _bAL) types[i] = _bR;
    }
    // W4: a single separator between two numbers joins them (only a common
    // separator between two Arabic numbers).
    for (var i = s + 1; i + 1 < end; i++) {
      if ((types[i] == _bES || types[i] == _bCS) && types[i - 1] == _bEN && types[i + 1] == _bEN) types[i] = _bEN;
      if (types[i] == _bCS && types[i - 1] == _bAN && types[i + 1] == _bAN) types[i] = _bAN;
    }
    // W5: terminators next to a number are part of it.
    for (var i = s; i < end; i++) {
      if (types[i] != _bET) continue;
      var j = i;
      while (j < end && types[j] == _bET) {
        j++;
      }
      final num = (i > s && types[i - 1] == _bEN) || (j < end && types[j] == _bEN);
      for (var k = i; k < j; k++) {
        types[k] = num ? _bEN : _bON;
      }
      i = j - 1;
    }
    // W6: remaining separators and terminators are neutral.
    for (var i = s; i < end; i++) {
      if (types[i] == _bES || types[i] == _bCS || types[i] == _bET) types[i] = _bON;
    }
    // W7: a number after left-to-right text (or at the start of a left-to-right
    // paragraph) is left-to-right.
    var strong = eDir;
    for (var i = s; i < end; i++) {
      if (types[i] == _bL || types[i] == _bR) {
        strong = types[i];
      } else if (types[i] == _bEN && strong == _bL) {
        types[i] = _bL;
      }
    }
    // N1, N2: neutrals between two of the same direction (numbers count as
    // right-to-left) take it; others take the paragraph's.
    for (var i = s; i < end; i++) {
      if (types[i] != _bWS && types[i] != _bON) continue;
      var j = i;
      while (j < end && (types[j] == _bWS || types[j] == _bON)) {
        j++;
      }
      final before = i == s ? eDir : (types[i - 1] == _bL ? _bL : _bR);
      final after = j == end ? eDir : (types[j] == _bL ? _bL : _bR);
      final dir = before == after ? before : eDir;
      for (var k = i; k < j; k++) {
        types[k] = dir;
      }
      i = j - 1;
    }
    // I1, I2.
    for (var i = s; i < end; i++) {
      final c = types[i];
      levels[i] = e == 0
          ? (c == _bR
                ? 1
                : c == _bEN || c == _bAN
                ? 2
                : 0)
          : (c == _bR ? 1 : 2);
    }
    if (end < len) levels[end] = e; // the paragraph separator
    s = end + 1;
  }
  return levels;
}

bool _strongLOrNumber(int cu) =>
    (scriptOf(cu) != scCommon && scriptOf(cu) != scHebrew && scriptOf(cu) != scArabic) ||
    (cu >= 0x2B0 && cu < 0x300) ||
    (cu >= 0x30 && cu <= 0x39) ||
    cu == 0xB2 ||
    cu == 0xB3 ||
    cu == 0xB9 ||
    (cu >= 0x660 && cu <= 0x669) ||
    (cu >= 0x6F0 && cu <= 0x6F9);

bool _isPi(int cu) => cu == 0xAB || cu == 0x2018 || cu == 0x201C;

/// East Asian Width F, W or H (for LB19a).
bool _isEA(int cu) =>
    (cu >= 0x1100 && cu <= 0x115F) ||
    (cu >= 0x2E80 && cu <= 0x303E) ||
    (cu >= 0x3041 && cu <= 0x33FF) ||
    (cu >= 0x3400 && cu <= 0x4DBF) ||
    (cu >= 0x4E00 && cu <= 0x9FFF) ||
    (cu >= 0xA000 && cu <= 0xA4CF) ||
    (cu >= 0xAC00 && cu <= 0xD7A3) ||
    (cu >= 0xF900 && cu <= 0xFAFF) ||
    (cu >= 0xFE30 && cu <= 0xFE4F) ||
    (cu >= 0xFF00 && cu <= 0xFFE6);
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
  for (var a = 0; a < nLB; a++) {
    no(a, lbNS); // LB21: × NS
  }
  no(lbPR, lbID);
  no(lbID, lbPO); // LB23a
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
  t[lbCL * nLB + lbNS] = false; // LB16: (CL | CP) SP* × NS
  t[lbCP * nLB + lbNS] = false;
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

bool exactPositions(double scale, double paragraphPx, [double letterSpacing = 0, double wordSpacing = 0]) {
  for (var bits = 0; bits <= 16; bits++) {
    final v = scale * (1 << bits), l = letterSpacing * (1 << bits), w = wordSpacing * (1 << bits);
    if (v == v.roundToDouble() && l == l.roundToDouble() && w == w.roundToDouble()) {
      return paragraphPx * (1 << bits) < (1 << 24);
    }
  }
  return false;
}

/// Width-independent records for one paragraph: the width prefix (units) and the
/// break opportunities. Built once; re-wrapping at any width uses [lineStarts].
class Records {
  Records(
    this.prefix,
    this.ends,
    this.nexts,
    this.count,
    this.riskyEnds,
    this.riskyNexts,
    this.mandatory,
    this.spaceCount,
    this.clusterLoss,
  );

  /// Word spacing is unknown for this paragraph: it has a space on a bidi run
  /// boundary (measured: Flutter spaces some of those and not others).
  bool wordSpacingUnsure = false;

  /// Widths are px from runs at several scales ([buildRichRecords]): always
  /// allow for float drift.
  bool inexact = false;
  final Float64List prefix;
  final Int32List ends, nexts; // line would end at ends[j]; next line starts at nexts[j]
  final int count; // the last record is the end of the paragraph
  // Spaces where UAX #14 forbids a break but SkParagraph sometimes breaks anyway
  // (inside an unbreakable segment). When one could end the line, the breaker
  // does not guess.
  final Int32List riskyEnds, riskyNexts;
  // Nonzero where the record is a hard line break (\n, U+2028, U+2029): the line
  // ends there. Bit 2: the next line starts with word-spaced spaces.
  final Uint8List mandatory;
  // Word spacing goes on the last space of every run of spaces that is a break
  // opportunity (measured): spaceCount[j] counts those among records 0..j-1.
  final Int32List spaceCount;
  // Characters before position i that share a glyph cluster with an earlier one
  // (ligatures): letter spacing counts clusters. Null when there are none.
  final Int32List? clusterLoss;

  int _clusters(int s, int e) => clusterLoss == null ? e - s : e - s - (clusterLoss![e] - clusterLoss![s]);

  /// Greedy first-fit line starts for a box [maxWidth] px wide at [scale] px per
  /// unit, or null when Flutter must decide: a word as wide as the line, an
  /// ambiguous space that could end it, or a fit decision within float drift.
  /// [letterSpacing] is added to every glyph cluster of a line (measured:
  /// SkParagraph adds it to each glyph's advance; build the records with the same
  /// spacing's sign), [wordSpacing] at every space break inside it.
  Int32List? lineStarts(double maxWidth, double scale, {double letterSpacing = 0, double wordSpacing = 0}) {
    if (wordSpacing != 0 && wordSpacingUnsure) return null;
    final maxF = _toF32(maxWidth);
    final ls = letterSpacing, ws = wordSpacing;
    final len = prefix.length - 1;
    final rel =
        !inexact && exactPositions(scale, prefix[len] * scale + ls.abs() * len + ws.abs() * spaceCount[count], ls, ws)
        ? 0.0
        : driftPerPx;
    var unsure = false;
    // Far from the edge: decide in doubles. Near it: SkParagraph's float32 test,
    // and with drift, refuse decisions the margin could flip. [extraW] is the
    // spacing in the line, [extraX] the spacing before its end (for the margin).
    bool fits(double startUnits, double endUnits, double extraW, double extraX) {
      final w = (endUnits - startUnits) * scale + extraW;
      final margin = 0.02 + rel * 2 * endUnits * scale + rel * 2 * extraX;
      if (w <= maxWidth - margin) return true;
      if (w >= maxWidth + margin) return false;
      final f = fitsLine(w, maxF);
      if (rel > 0) {
        final d = rel * 2 * endUnits * scale + rel * 2 * extraX + 1e-4;
        if (fitsLine(w - d, maxF) != fitsLine(w + d, maxF)) unsure = true;
      }
      return f;
    }

    final spaced = ls != 0 || ws != 0;
    final out = <int>[0];
    var s = 0, k = 0;
    for (;;) {
      var best = -1;
      final p0 = prefix[s];
      final lead = k > 0 && mandatory[k - 1] & 2 != 0 ? ws : 0.0;
      for (var j = k; j < count; j++) {
        final e = ends[j];
        final ok = spaced
            ? fits(
                p0,
                prefix[e],
                ls * _clusters(s, e) + ws * (spaceCount[j] - spaceCount[k]) + lead,
                ls.abs() * e + ws.abs() * spaceCount[j],
              )
            : fits(p0, prefix[e], 0, 0);
        if (!ok) break;
        best = j;
        if (mandatory[j] != 0) break;
      }
      if (best < 0 || unsure) return null;
      if (riskyEnds.isNotEmpty && mandatory[best] == 0) {
        final from = nexts[best], to = best + 1 < count ? nexts[best + 1] : 1 << 30;
        for (var q = 0; q < riskyEnds.length; q++) {
          final e = riskyEnds[q];
          if (riskyNexts[q] > from &&
              riskyNexts[q] < to &&
              (spaced
                  ? fits(
                      p0,
                      prefix[e],
                      ls * _clusters(s, e) + ws * (spaceCount[best + 1] - spaceCount[k]) + lead,
                      ls.abs() * e + ws.abs() * spaceCount[best + 1],
                    )
                  : fits(p0, prefix[e], 0, 0))) {
            return null;
          }
        }
        if (unsure) return null;
      }
      if (best == count - 1) return Int32List.fromList(out);
      // A word wider than the box by less than the 1/100 px floor fits a line of
      // its own, but SkParagraph tests a word for "too long" without the floor
      // and then breaks it inside, on this line (measured): Flutter decides.
      if (mandatory[best] == 0) {
        final a = nexts[best], b = ends[best + 1];
        final word = (prefix[b] - prefix[a]) * scale + ls * _clusters(a, b);
        if (word > maxF - 1e-4 - rel * 2 * (prefix[b] * scale + ls.abs() * b)) return null;
      }
      s = nexts[best];
      out.add(s);
      k = best + 1;
    }
  }

  int lineCount(double maxWidth, double scale, {double letterSpacing = 0, double wordSpacing = 0}) =>
      lineStarts(maxWidth, scale, letterSpacing: letterSpacing, wordSpacing: wordSpacing)?.length ?? -1;
}

// Scratch buffers shared by all calls (the breaker runs on one isolate).
Int32List _ends = Int32List(1024), _nexts = Int32List(1024), _rEnds = Int32List(256), _rNexts = Int32List(256);
Uint8List _mand = Uint8List(1024);

/// Hard line breaks (measured: \n, U+2028 and U+2029 end a line; a lone \r does not).
bool isHardBreak(int cu) => cu == 0x0A || cu == 0x2028 || cu == 0x2029;

/// Break opportunities only (pass B), into the scratch buffers. Returns
/// (count, riskyCount), or null when a character is outside the line-break table.
/// The text splits at hard breaks into segments (UAX #14 LB4, LB6: always break
/// after one, never before); each segment's last record ends its line there.
/// Letters, marks and digits of the Brahmic scripts (Devanagari to Sinhala, and
/// the Vedic extensions), not the danda: UAX #14 never breaks inside a run of
/// them (LB28a, Unicode 15.1), so the breaker treats a run as one AL character
/// and measures it through Flutter.
bool isBrahmic(int cu) =>
    ((cu >= 0x900 && cu <= 0xDFF) && cu != 0x964 && cu != 0x965) ||
    (cu >= 0x1CD0 && cu <= 0x1CFF) ||
    (cu >= 0xA8E0 && cu <= 0xA8FF);

int _cpAt(String t, int i) {
  final cu = t.codeUnitAt(i);
  if (cu >= 0xD800 && cu < 0xDC00 && i + 1 < t.length) {
    final lo = t.codeUnitAt(i + 1);
    if (lo >= 0xDC00 && lo < 0xE000) return 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00);
  }
  return cu;
}

/// Supplementary-plane emoji the breaker handles: pictographs (UAX #14 class
/// ID or EB), not modifiers or regional indicators.
bool _isEmojiPictograph(int cp) =>
    cp >= 0x1F000 && cp <= 0x1FAFF && !(cp >= 0x1F1E6 && cp <= 0x1F1FF) && !(cp >= 0x1F3FB && cp <= 0x1F3FF);

/// End of the emoji cluster starting at [i] (a pictograph with an optional
/// VS16 and skin-tone modifier, joined to more by ZWJ; or a pair of regional
/// indicators), or [i] when none starts there.
int emojiClusterEnd(String t, int i) {
  final cp = _cpAt(t, i);
  if (cp >= 0x1F1E6 && cp <= 0x1F1FF) {
    return i + 2 < t.length && (_cpAt(t, i + 2) >= 0x1F1E6 && _cpAt(t, i + 2) <= 0x1F1FF) ? i + 4 : i;
  }
  if (!_isEmojiPictograph(cp)) return i;
  var j = i + 2;
  for (;;) {
    if (j < t.length && t.codeUnitAt(j) == 0xFE0F) j++;
    if (j + 1 < t.length && _cpAt(t, j) >= 0x1F3FB && _cpAt(t, j) <= 0x1F3FF) j += 2;
    if (j + 2 < t.length && t.codeUnitAt(j) == 0x200D && _isEmojiPictograph(_cpAt(t, j + 1))) {
      j += 3;
      continue;
    }
    return j;
  }
}

/// Combining marks (UAX #14 class CM) of the scripts the breaker handles.
bool isCombiningMark(int cu) => cu < 0x3000 ? _markBelow3000[cu] == 1 : _isCombiningMark(cu);

// Characters that take the slower path of [_opportunities]: marks, surrogates, ZWJ,
// VS16, and the scripts measured as runs. [_specialBelow3000]: the same as a table.
bool _special(int cu) =>
    isCombiningMark(cu) ||
    (cu >= 0xD800 && cu < 0xDC00) ||
    cu == 0x200D ||
    cu == 0xFE0F ||
    isBrahmic(cu) ||
    isComplexContext(cu);

final Uint8List _specialBelow3000 = () {
  final m = Uint8List(0x3000);
  for (var c = 0; c < 0x3000; c++) {
    if (_special(c)) m[c] = 1;
  }
  return m;
}();

// [_isCombiningMark] as a table below U+3000, where it is asked about nearly every character.
final Uint8List _markBelow3000 = () {
  final m = Uint8List(0x3000);
  for (var c = 0x300; c < 0x3000; c++) {
    if (_isCombiningMark(c)) m[c] = 1;
  }
  return m;
}();

bool _isCombiningMark(int cu) =>
    cu >= 0x300 &&
    ((cu <= 0x36F) ||
    (cu >= 0x483 && cu <= 0x489) ||
    (cu >= 0x591 && cu <= 0x5BD) ||
    cu == 0x5BF ||
    cu == 0x5C1 ||
    cu == 0x5C2 ||
    cu == 0x5C4 ||
    cu == 0x5C5 ||
    cu == 0x5C7 ||
    (cu >= 0x610 && cu <= 0x61A) ||
    (cu >= 0x64B && cu <= 0x65F) ||
    cu == 0x670 ||
    (cu >= 0x6D6 && cu <= 0x6DC) ||
    (cu >= 0x6DF && cu <= 0x6E4) ||
    cu == 0x6E7 ||
    cu == 0x6E8 ||
    (cu >= 0x6EA && cu <= 0x6ED) ||
    (cu >= 0x1AB0 && cu <= 0x1AFF) ||
    (cu >= 0x1DC0 && cu <= 0x1DFF) ||
    (cu >= 0x20D0 && cu <= 0x20FF) ||
    (cu >= 0xFE20 && cu <= 0xFE2F));

/// Break opportunities with combining marks: LB9 (X CM* is X) is UAX #14 on the
/// text without its marks, positions mapped back; a mark after a space, a hard
/// break or nothing (LB10) sends the paragraph to Flutter.
(int, int)? _opportunities(String t) {
  var marks = false;
  for (var i = 0; i < t.length && !marks; i++) {
    final cu = t.codeUnitAt(i);
    marks = cu < 0x3000 ? _specialBelow3000[cu] == 1 : _special(cu);
  }
  if (!marks) return _opportunitiesNoMarks(t);
  final b = StringBuffer(), at = <int>[], extra = <int>[];
  for (var i = 0; i < t.length; i++) {
    final cu = t.codeUnitAt(i);
    // A run of Thai, Lao, Khmer or Burmese (UAX #14 class SA): one AL character
    // for the rules around it, and inside it the breaks ICU's dictionaries find
    // (dictionary_break.dart). A run that starts with a mark, or whose break could
    // fall inside a grapheme (the font's clusters decide), goes to Flutter.
    if (isComplexContext(cu)) {
      var j = i + 1;
      while (j < t.length && isComplexContext(t.codeUnitAt(j))) {
        j++;
      }
      // Thai and Lao AM join the character before them too (GB9a; HarfBuzz moves
      // AM's nikhahit onto it): a space before AM is in its cluster (measured:
      // Flutter starts the line at that space).
      if (isComplexContextMark(cu) || cu == 0x0E33 || cu == 0x0EB3) return null;
      final br = dictionaryBreaks(t, i, j);
      if (br == null || br.any((p) => breakMayBeInsideGrapheme(t, p))) return null;
      extra.addAll(br);
      at.add(i);
      b.writeCharCode(0x61);
      i = j - 1;
      continue;
    }
    if (isCombiningMark(cu) || cu == 0xFE0F) {
      if (i == 0 || t.codeUnitAt(i - 1) == 0x20 || isHardBreak(t.codeUnitAt(i - 1))) return null;
      continue;
    }
    // An emoji cluster (UAX #29: pictograph, modifiers, ZWJ sequences; a pair of
    // regional indicators) is one ID character for UAX #14 (LB8a, LB9, LB30a/b).
    final e = emojiClusterEnd(t, i);
    if (e > i) {
      at.add(i);
      b.writeCharCode(0x4E00);
      i = e - 1;
      continue;
    }
    if (isBrahmic(cu)) {
      var j = i + 1;
      while (j < t.length && (isBrahmic(t.codeUnitAt(j)) || t.codeUnitAt(j) == 0x200C || t.codeUnitAt(j) == 0x200D)) {
        j++;
      }
      at.add(i);
      b.writeCharCode(0x61); // one AL character
      i = j - 1;
      continue;
    }
    if (cu >= 0xD800 && cu < 0xE000) return null; // other supplementary characters
    if (cu == 0x200D) return null;
    at.add(i);
    b.writeCharCode(cu);
  }
  at.add(t.length);
  final r = _opportunitiesNoMarks(b.toString());
  if (r == null) return null;
  final (n, nr) = r;
  for (var j = 0; j < n; j++) {
    _ends[j] = at[_ends[j]];
    _nexts[j] = at[_nexts[j]];
  }
  for (var j = 0; j < nr; j++) {
    _rEnds[j] = at[_rEnds[j]];
    _rNexts[j] = at[_rNexts[j]];
  }
  if (extra.isEmpty) return r;
  // The dictionary breaks, among the records in order of position.
  final ends = <int>[], nexts = <int>[], mand = <int>[];
  var x = 0;
  for (var j = 0; j < n; j++) {
    while (x < extra.length && extra[x] < _nexts[j]) {
      ends.add(extra[x]);
      nexts.add(extra[x++]);
      mand.add(0);
    }
    ends.add(_ends[j]);
    nexts.add(_nexts[j]);
    mand.add(_mand[j]);
  }
  if (_ends.length < ends.length + 2) {
    _ends = Int32List(ends.length * 2 + 2);
    _nexts = Int32List(ends.length * 2 + 2);
    _mand = Uint8List(ends.length * 2 + 2);
  }
  for (var j = 0; j < ends.length; j++) {
    _ends[j] = ends[j];
    _nexts[j] = nexts[j];
    _mand[j] = mand[j];
  }
  return (ends.length, nr);
}

(int, int)? _opportunitiesNoMarks(String t) {
  final len = t.length;
  if (_ends.length < len + 2) {
    _ends = Int32List(len * 2 + 2);
    _nexts = Int32List(len * 2 + 2);
    _mand = Uint8List(len * 2 + 2);
  }
  var n = 0, nr = 0, start = 0;
  for (;;) {
    var end = start;
    while (end < len && !isHardBreak(t.codeUnitAt(end))) {
      end++;
    }
    final r = _segment(t, start, end, n, nr);
    if (r == null) return null;
    (n, nr) = r;
    if (end == len) return (n, nr);
    _nexts[n - 1] = end + 1;
    // Bit 2: the next segment starts with spaces before a word. Measured: word
    // spacing goes there too (but not on spaces that start the paragraph).
    var q = end + 1;
    while (q < len && t.codeUnitAt(q) == 0x20) {
      q++;
    }
    _mand[n - 1] = q > end + 1 && q < len && !isHardBreak(t.codeUnitAt(q)) ? 3 : 1;
    start = end + 1;
  }
}

/// The records of t[start, end), a text without hard breaks, appended at n.
(int, int)? _segment(String t, int start, int len, int n, int nr) {
  var spaceStart = -1, lastNonSpace = -1;
  // LB25 context: is t[i-1] inside NU (NU|SY|IS)*, and was the character before a
  // closing bracket inside one?
  var inNumber = false, closedNumber = false;
  var ca = start < len ? lbClass(t.codeUnitAt(start)) : lbSP;
  if (ca == lbXX) return null;
  for (var i = start + 1; i < len; i++) {
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
      if (lastNonSpace >= start) {
        final b = t.codeUnitAt(lastNonSpace);
        var ok = defaultSpaceRules[lbClass(b) * nLB + cx];
        // LB15c (Unicode 15.1): SP ÷ IS NU, as in "e.g., .1" (measured: Flutter puts
        // word spacing there, so it is a break). LB14 (OP SP* ×) comes first.
        if (cx == lbIS && i + 1 < len && lbClass(t.codeUnitAt(i + 1)) == lbNU && lbClass(b) != lbOP) ok = true;
        // LB15a: an opening quote in opening position (start, space, OP, QU, GL
        // before it), then spaces.
        if (_isPi(b)) {
          final pb = lastNonSpace > start ? lbClass(t.codeUnitAt(lastNonSpace - 1)) : lbSP;
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
          _mand[n] = 0;
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
    // LB30 (Unicode 15.1) keeps letters and digits with an opening bracket only if
    // it is not East Asian: a fullwidth （ allows a break (measured: "Format|（PDF）").
    if (!allowed && cx == lbOP && (ca == lbAL || ca == lbNU) && _isEA(x)) allowed = true;
    // LB19, LB19a (Unicode 15.1): no break before a quotation mark unless it opens
    // (Pi) between East Asian characters, none after one unless it closes (Pf)
    // between them (measured: Flutter breaks around “某地” in Chinese).
    if (allowed &&
        cx == lbQU &&
        !(_isPi(x) && _isEA(t.codeUnitAt(i - 1)) && i + 1 < len && _isEA(t.codeUnitAt(i + 1)))) {
      allowed = false;
    }
    if (allowed && ca == lbQU) {
      final q = t.codeUnitAt(i - 1);
      if (!(_isPf(q) && _isEA(x) && i - 2 >= start && _isEA(t.codeUnitAt(i - 2)))) allowed = false;
    }
    // LB20a: no break after a word-initial hyphen (HY, U+2010) or en dash (measured:
    // Flutter treats the en dash like the hyphen here, but not other BA, e.g. "|").
    final dash = ca == lbHY || t.codeUnitAt(i - 1) == 0x2010 || t.codeUnitAt(i - 1) == 0x2013;
    // LB21b: SY × HL (measured: Flutter keeps "ולהסתיר/להציג" together).
    if (allowed && ca == lbSY && _isHL(x)) allowed = false;
    // LB21a: HL (HY | BA) × [^HL].
    if (allowed && (ca == lbHY || ca == lbBA) && i - start >= 2 && _isHL(t.codeUnitAt(i - 2)) && !_isHL(x)) {
      allowed = false;
    }
    if (allowed && dash && cx == lbAL && (i - start < 2 || t.codeUnitAt(i - 2) == 0x20)) {
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
      _mand[n] = 0;
      _nexts[n++] = i;
    }
    ca = cx;
  }
  var end = len;
  while (end > start && t.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  _ends[n] = end;
  _mand[n] = 0;
  _nexts[n++] = len;
  return (n, nr);
}

/// Break opportunities of [t] (for the word-cache baseline), or null.
(Int32List, Int32List)? breakOpportunities(String t) {
  final r = _opportunities(t);
  if (r == null) return null;
  return (Int32List.sublistView(_ends, 0, r.$1), Int32List.sublistView(_nexts, 0, r.$1));
}

/// State of pass A across the ranges it runs over.
class _Pass {
  _Pass(this.prefix, this.ligatures, this.clusters);
  final Float64List prefix;
  final bool ligatures, clusters;
  double p = 0;
  int run = scCommon; // script of the current run
  List<int>? lossEnds, lossDelta;
}

/// Pass A over t[start, end) with [md], continuing [pass]: the width prefix. False
/// when a character is not covered. Pair adjustments start fresh at [start]. With
/// [gate], a character of the other direction than [md]'s fails the paragraph.
bool _widths(WidthModel md, String t, int start, int end, _Pass pass, {bool gate = true}) {
  final ligatures = pass.ligatures, clusters = pass.clusters, prefix = pass.prefix;
  final cert = ligatures ? md.cert : md.noLigaCert;
  if (cert == null) return false;
  final idOf = md.idOf, adv = md.adv, fc = md.fc, sc = md.sc, cls = md.cls, n1 = md.n1;
  final digit = md.islandDigit, base = md.keyBase, ofKey = md.islandOfKey, m = md.m;
  var p = pass.p, run = pass.run;
  var lossEnds = pass.lossEnds, lossDelta = pass.lossDelta;
  // Split kerning: the right glyph's share of a pair starts its cluster, so the
  // boundary before it (prefix) excludes that share.
  final cr = md.clsRight, lr = md.islandLRight, rr = md.islandRRight;
  if (cr != null && !ligatures && md.noLigaRowRight == null) return false; // no split tables without ligatures
  var prevId = 0, prevIsland = -1;
  final rtl = md.rtl, markT = _markBelow3000;
  // The run's script's own lookups over Common characters, looked up per run.
  final variants = md.scriptVariant;
  var sv = variants.isEmpty ? null : variants[run];
  var i = start;
  while (i < end) {
    final cu = t.codeUnitAt(i);
    if (isHardBreak(cu)) {
      // Takes no width in either line, but kerns with the characters on both sides
      // as a space does (measured: T before \n loses Roboto's T-space kern, and
      // with split kerning the next line's first glyph keeps its share of the
      // space-A kern). The script run continues (itemization is over the whole
      // text).
      final sp = idOf[0x20];
      var rs = 0.0;
      if (!hardBreakKerns) {
        // No pair adjustment with a hard break on this engine.
      } else if (prevId != 0) {
        p += ligatures ? cls[fc[prevId] + sc[sp]] : md.pairNoLiga(prevId, sp);
        if (cr != null) rs = ligatures ? cr[fc[prevId] + sc[sp]] : md.rightNoLiga(prevId, sp);
      } else if (prevIsland >= 0) {
        p += md.islandR[prevIsland * n1 + sp];
        if (rr != null) rs = rr[prevIsland * n1 + sp];
      }
      prefix[i] = p - rs;
      prevId = hardBreakKerns ? sp : 0;
      prevIsland = -1;
      i++;
      continue;
    }
    if (gate && (rtl ? _strongLOrNumber(cu) : _strongR(cu))) return false; // a mixed-direction paragraph
    var id = _joining(cu) > 0 ? _formId(md, t, i) : idOf[cu];
    if (id == 0) return false;
    var c = cert[id];
    if (c == certU || c == certM) return false; // a mark here has no base (LB10)
    // A base and its combining marks: HarfBuzz composes them (marks sorted by
    // combining class, each composing with the base unless blocked by a kept mark
    // of the same or a higher class) into the composite the font has, which is
    // then the character here; marks left over take no width, and kerning either
    // skips them or stops at them.
    var mEnd = i + 1;
    for (;;) {
      if (mEnd >= end) break;
      final nx = t.codeUnitAt(mEnd);
      if (nx < 0x3000 ? markT[nx] == 0 : !_isCombiningMark(nx)) break; // isCombiningMark, inlined
      mEnd++;
    }
    var keptMarks = 0, stops = false;
    if (mEnd > i + 1) {
      if (c != certS || mEnd - i > 32) return false;
      final ms = [for (var k = i + 1; k < mEnd; k++) t.codeUnitAt(k)];
      final info = [for (final x in ms) md.marks[x]];
      if (info.any((x) => x == null || x.$1 == 0)) return false;
      // HarfBuzz's Arabic shaper moves modifier marks (hamza above and below, and
      // a few more) ahead of the others, which can change what composes.
      if (ms.length > 1 && ms.any((x) => const {0x654, 0x655, 0x658, 0x6DC, 0x6E3, 0x6E7, 0x6E8}.contains(x))) {
        return false;
      }
      final order = List.generate(ms.length, (k) => k)..sort((a, b) {
        final d = info[a]!.$1 - info[b]!.$1;
        return d != 0 ? d : a - b;
      });
      var starter = cu, lastKept = -1, composed = 0;
      final kept = <int>[];
      for (final k in order) {
        final cc = info[k]!.$1;
        final comp = md.compose[pairKey(starter, ms[k])];
        if (comp != null && (kept.isEmpty || lastKept < cc)) {
          starter = comp;
          composed++;
          continue;
        }
        kept.add(k);
        lastKept = cc;
      }
      if (starter >= 0x10000) return false;
      id = _joining(starter) > 0 ? _formId(md, t, i, starter) : idOf[starter];
      if (id == 0 || cert[id] != certS) return false;
      c = certS;
      final next = mEnd < end ? t.codeUnitAt(mEnd) : -1;
      for (final k in kept) {
        final x = info[k]!;
        if (x.$3.contains(starter) || x.$3.contains(next)) return false; // a rule could fire on it
        stops = stops || x.$2;
      }
      keptMarks = kept.length;
      if (clusters && keptMarks > 0) return false; // negative spacing: clusters not measured with marks
      if (composed > 0) {
        (lossEnds ??= []).add(mEnd); // composed marks are no glyphs of their own
        (lossDelta ??= []).add(composed);
      }
    }
    final s = scriptOf(cu);
    if (s != scCommon && s != run) {
      run = s; // a new script run: no pair adjustment across it
      prevId = 0;
      prevIsland = -1;
      sv = variants.isEmpty ? null : variants[run];
    }
    if (sv != null) {
      // This run's script has lookups of its own over some Common characters.
      var q = i - 1;
      while (q >= start && isCombiningMark(t.codeUnitAt(q))) {
        q--;
      }
      var before = q >= start ? t.codeUnitAt(q) : -1;
      if (before >= 0 && isHardBreak(before)) before = hardBreakKerns ? 0x20 : -1;
      if (s == scCommon && (sv.$1.contains(cu) || (before >= 0 && sv.$2.contains(pairKey(before, cu))))) return false;
      for (var k = i + 1; k < mEnd; k++) {
        if (sv.$1.contains(t.codeUnitAt(k))) return false;
      }
    }
    if (c != certS) {
      // A P/K run: find its end, and whether it has a primer.
      var j = i, key = 0, primer = false;
      while (j < end) {
        final cj = t.codeUnitAt(j);
        final q = _joining(cj) > 0 ? _formId(md, t, j) : idOf[cj];
        final dj = digit[q];
        if (q == 0 || dj < 0) break;
        primer = primer || cert[q] == certP;
        if (j - i < m) key = key * base + dj + 1;
        j++;
      }
      if (j == i) return false; // not in the island alphabet
      if (primer) {
        if (j - i > m) return false;
        final isl = ofKey[key];
        if (isl < 0) return false;
        var rs = 0.0;
        if (prevId != 0) {
          p += md.islandL[isl * n1 + prevId];
          if (lr != null) rs = lr[isl * n1 + prevId];
        }
        prefix[i] = p - rs;
        for (var q = i + 1; q < j; q++) {
          prefix[q] = double.nan; // never a break position
        }
        p += md.islandW[isl];
        if (clusters) {
          final ic = md.islandClusters;
          if (ic == null) return false;
          (lossEnds ??= []).add(j);
          (lossDelta ??= []).add(j - i - ic[isl]);
        }
        prevId = 0;
        prevIsland = isl;
        i = j;
        continue;
      }
      // No primer: substitution leaves these characters alone.
      for (; i < j; i++) {
        final ci = t.codeUnitAt(i);
        final q = _joining(ci) > 0 ? _formId(md, t, i) : idOf[ci];
        var rs = 0.0;
        if (prevId != 0) {
          p += cls[fc[prevId] + sc[q]];
          if (cr != null) rs = cr[fc[prevId] + sc[q]];
        } else if (prevIsland >= 0) {
          p += md.islandR[prevIsland * n1 + q];
          if (rr != null) rs = rr[prevIsland * n1 + q];
        }
        prefix[i] = p - rs;
        p += adv[q];
        prevId = q;
        prevIsland = -1;
      }
      continue;
    }
    var rs = 0.0;
    if (prevId != 0) {
      p += ligatures ? cls[fc[prevId] + sc[id]] : md.pairNoLiga(prevId, id);
      if (cr != null) rs = ligatures ? cr[fc[prevId] + sc[id]] : md.rightNoLiga(prevId, id);
    } else if (prevIsland >= 0) {
      p += md.islandR[prevIsland * n1 + id];
      if (rr != null) rs = rr[prevIsland * n1 + id];
    }
    prefix[i] = p - rs;
    p += adv[id];
    prevId = id;
    prevIsland = -1;
    i++;
    if (mEnd > i) {
      for (; i < mEnd; i++) {
        prefix[i] = double.nan; // inside the cluster: never a break position
      }
      if (keptMarks > 0 && stops) prevId = 0; // the next pair adjustment stops at a mark
    }
  }
  pass.p = p;
  pass.run = run;
  pass.lossEnds = lossEnds;
  pass.lossDelta = lossDelta;
  return true;
}

_Pass _start(String t, double letterSpacing) {
  final pass = _Pass(Float64List(t.length + 1), letterSpacing <= 0, letterSpacing < 0);
  for (var q = 0; q < t.length && pass.run == scCommon; q++) {
    pass.run = scriptOf(t.codeUnitAt(q));
  }
  return pass;
}

/// Passes A and B: width prefix and break opportunities. Null when the paragraph
/// has a character the model, the certificate or the line-break table does not
/// cover, or an island longer than m: such paragraphs are laid out by Flutter.
///
/// Only the sign of [letterSpacing] matters here (measured): positive spacing
/// makes the engine shape without ligatures; negative spacing keeps them and
/// spaces glyph clusters. Null when the sidecar has no tables for the case.
Records? buildRecords(WidthModel md, String t, {double letterSpacing = 0}) {
  final pass = _start(t, letterSpacing);
  if (!_widths(md, t, 0, t.length, pass)) return null;
  return _finish(t, pass);
}

/// Mixed-direction paragraphs. [ltr] and [rtl] are sidecars of one font distilled
/// in left-to-right and right-to-left paragraphs (either may be null). Each
/// character's bidi level ([bidiLevels]) picks the sidecar measured in its
/// direction, and a change of level ends a shaping run, so no pair adjustment
/// crosses it. Null where [bidiLevels] is, or when a needed sidecar is missing.
Records? buildBidiRecords(
  WidthModel? ltr,
  WidthModel? rtl,
  String t, {
  required bool rtlParagraph,
  double letterSpacing = 0,
}) {
  final levels = bidiLevels(t, rtlParagraph: rtlParagraph);
  if (levels == null) return null;
  final pass = _start(t, letterSpacing);
  var a = 0;
  while (a < t.length) {
    var b = a + 1;
    while (b < t.length && levels[b] == levels[a]) {
      b++;
    }
    final md = levels[a].isOdd ? rtl : ltr;
    // Measured: Flutter itemizes scripts within each bidi run, so neutrals at the
    // start of a run take the script of its first letter.
    pass.run = scCommon;
    for (var q = a; q < b && pass.run == scCommon; q++) {
      pass.run = scriptOf(t.codeUnitAt(q));
    }
    if (md == null || !_widths(md, t, a, b, pass, gate: false)) return null;
    a = b;
  }
  final r = _finish(t, pass);
  if (r != null) {
    for (var i = 0; i < t.length; i++) {
      if (t.codeUnitAt(i) == 0x20 &&
          ((i > 0 && levels[i - 1] != levels[i]) || (i + 1 < t.length && levels[i + 1] != levels[i]))) {
        r.wordSpacingUnsure = true;
        break;
      }
    }
  }
  return r;
}

/// Rich text, left to right: [runs] are shaping runs (start, end, sidecar, px per
/// unit) that cover [t] in order. A change of font or size starts a new run
/// (measured: no pair adjustment crosses it, and widths add up); spans that
/// differ only in colour or decoration belong to one run. The prefix is in px,
/// so lines are broken at scale 1.
///
/// [measured] holds runs measured through Flutter instead (emoji from the
/// device's fallback font): run start -> px offsets of every code unit from the
/// run's start (NaN inside a cluster), and the run's width last.
///
/// [blockStarts]: where a span of another style begins (font, size or height;
/// not colour). Flutter itemizes scripts within each such block, across its
/// fallback fonts (measured: Common characters next to a letter in another
/// size keep script Common).
Records? buildRichRecords(
  String t,
  List<(int, int, WidthModel?, double)> runs, {
  double letterSpacing = 0,
  Map<int, Float64List> measured = const {},
  Set<int> scriptRuns = const {},
  Set<int> blockStarts = const {},
}) {
  final pass = _start(t, letterSpacing), px = pass.prefix;
  var offset = 0.0, at = 0, script = scCommon, blockEnd = 0;
  for (final (a, b, md, scale) in runs) {
    if (a != at || b <= a || b > t.length) return null;
    if (a >= blockEnd) {
      // A new block: its script is that of its first letter.
      script = scCommon;
      blockEnd = t.length;
      for (final x in blockStarts) {
        if (x > a && x < blockEnd) blockEnd = x;
      }
    }
    if (md == null) {
      final m = measured[a];
      if (m == null || m.length != b - a + 1) return null;
      for (var i = a; i < b; i++) {
        px[i] = offset + m[i - a];
      }
      offset += m[b - a];
      at = b;
      // Emoji are Common: the script run continues. Letters of another script end
      // it: no pair adjustment between a space after them and a Latin letter.
      if (scriptRuns.contains(a)) script = scOther;
      continue;
    }
    final sub = _start(t, letterSpacing);
    // Within a block, scripts are itemized across font changes: neutrals at the
    // start of a run continue the script before them (measured: a space in Roboto
    // after Chinese text does not kern with the Latin letter after it).
    for (var q = a; q < blockEnd && script == scCommon; q++) {
      script = scriptOf(t.codeUnitAt(q));
    }
    sub.run = script;
    if (!_widths(md, t, a, b, sub)) return null;
    script = sub.run;
    for (var i = a; i < b; i++) {
      px[i] = offset + sub.prefix[i] * scale; // NaN inside islands stays NaN
    }
    offset += sub.p * scale;
    if (sub.lossEnds != null) {
      (pass.lossEnds ??= []).addAll(sub.lossEnds!);
      (pass.lossDelta ??= []).addAll(sub.lossDelta!);
    }
    at = b;
  }
  if (at != t.length) return null;
  pass.p = offset;
  return _finish(t, pass)?..inexact = true;
}

Records? _finish(String t, _Pass pass) {
  final len = t.length, prefix = pass.prefix, lossEnds = pass.lossEnds, lossDelta = pass.lossDelta;
  prefix[len] = pass.p;

  final o = _opportunities(t);
  if (o == null) return null;
  final (n, nr) = o;
  for (var j = 0; j < n; j++) {
    if (prefix[_ends[j]].isNaN || prefix[_nexts[j]].isNaN) return null; // a break inside an island
  }
  Int32List? clusterLoss;
  if (lossEnds != null) {
    clusterLoss = Int32List(len + 1);
    var q = 0, loss = 0;
    for (var x = 0; x <= len; x++) {
      while (q < lossEnds.length && lossEnds[q] <= x) {
        loss += lossDelta![q++];
      }
      clusterLoss[x] = loss;
    }
  }
  final spaceCount = Int32List(n + 1);
  for (var j = 0; j < n; j++) {
    spaceCount[j + 1] = spaceCount[j] + (_ends[j] < _nexts[j] && _mand[j] == 0 && j < n - 1 ? 1 : 0);
  }
  return Records(
    prefix,
    Int32List.fromList(Int32List.sublistView(_ends, 0, n)),
    Int32List.fromList(Int32List.sublistView(_nexts, 0, n)),
    n,
    Int32List.fromList(Int32List.sublistView(_rEnds, 0, nr)),
    Int32List.fromList(Int32List.sublistView(_rNexts, 0, nr)),
    Uint8List.fromList(Uint8List.sublistView(_mand, 0, n)),
    spaceCount,
    clusterLoss,
  );
}
