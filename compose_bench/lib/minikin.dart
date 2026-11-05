// Minikin's greedy line breaker (Jetpack Compose's default, LineBreak.Simple)
// over break-first's width prefix, with the rules of Minikin measured against
// Compose. Used by tool/compose_check.dart (exactness), tool/compose_speed.dart
// and speed_app (timing on the device).
import 'package:break_first/model.dart';

/// Sidecar units per pixel. Measured on Compose (hinted text, Android 15): every
/// advance is a whole pixel and every kern a multiple of 1/256 px, so at 64 units
/// per px both are exact in the sidecar (kerns are stored in quarter units).
const unitsPerPx = 64;

/// Compose's quantum of widths, px (see [unitsPerPx]).
const quantum = 1 / 256;

/// The sidecar for text at [size] px, distilled from [px], Compose's width of a
/// one-line string at that size. Hinting makes widths depend on the pixel size,
/// so a Compose sidecar holds one size.
WidthModel composeSidecar(String certificate, double size, double Function(String s) px) =>
    WidthModel.distill(certificate, (s) => px(s) * unitsPerPx, (size * unitsPerPx).round(), 2400);

/// Why a text goes back to Compose, or null when break-first decides it.
String? deferReason(String t, Records? r) {
  if (_otherSpaces.hasMatch(t)) return 'spaces';
  if (_otherHyphens.hasMatch(t)) return 'hyphens';
  if (r == null) return 'characters';
  if (emailOrUrlBreaks(t, r)) return 'url';
  return null;
}

/// Line starts of [t] in a box [width] px wide, or (null, why) when Compose must
/// decide.
(List<int>?, String) composeLineStarts(WidthModel md, String t, int width) {
  final r = buildRecords(md, t);
  final why = deferReason(t, r);
  return why != null ? (null, why) : greedy(r!, t, width);
}

/// Spaces Minikin leaves out of a line's width (isLineEndSpace) besides U+0020,
/// and tabs: the prefix does not model them.
final _otherSpaces = RegExp('[\\t\\u1680\\u2000-\\u200A\\u205F\\u3000]');

/// Whether Minikin's rules for email addresses and URLs could break [t]
/// differently. Its WordBreaker scans the run of printable ASCII that starts at
/// each break boundary; a run with an '@', or with "://", is broken by its own
/// rules: at punctuation inside the run, and where the run ends (before the space,
/// or before a character that is not one). Such a run changes nothing when it has
/// no break boundary inside it, no punctuation after its first character (a
/// placeholder such as "%@"), and ends at a space, a hard break or the end. Any
/// other run goes back to Compose: Minikin's punctuation rules are not modelled.
bool emailOrUrlBreaks(String t, Records r) {
  bool printable(int c) => c > 0x20 && c <= 0x7E;
  for (var a = 0; a < t.length;) {
    if (!printable(t.codeUnitAt(a))) {
      a++;
      continue;
    }
    var b = a;
    while (b < t.length && printable(t.codeUnitAt(b))) {
      b++;
    }
    final run = t.substring(a, b);
    if (run.contains('@') || run.contains('://')) {
      for (var j = 0; j < r.count; j++) {
        if ((r.ends[j] > a && r.ends[j] < b) || (r.nexts[j] > a && r.nexts[j] < b)) return true;
      }
      for (var i = a + 1; i < b; i++) {
        final c = t.codeUnitAt(i);
        final alnum = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
        if (!alnum && c != 0x40) return true;
      }
      if (b < t.length && t.codeUnitAt(b) != 0x20 && !isHardBreak(t.codeUnitAt(b))) return true;
    }
    a = b;
  }
  return false;
}

/// Minikin's other line-breaking hyphens (Armenian hyphen, maqaf, Canadian
/// syllabics hyphen, hyphen, hyphenation point, double oblique hyphen, double
/// hyphen) are not measured: such text goes back to Compose.
final _otherHyphens = RegExp('[\\u058A\\u05BE\\u1400\\u2010\\u2027\\u2E17\\u2E40]');

/// Measured: Compose does not break after a hyphen-minus or an en dash inside a
/// word ("invalid-|operation", "1983–|2025"), which UAX #14 allows. Minikin keeps
/// breaks after its line-breaking hyphens for hyphenation, off by default
/// (Hyphens.None).
bool noBreak(Records r, String t, int j) {
  final e = r.ends[j];
  if (r.nexts[j] != e || r.mandatory[j] != 0 || e == 0 || e >= t.length) return false;
  final c = t.codeUnitAt(e - 1);
  return c == 0x2D || c == 0x2013;
}

/// Line starts by Minikin's greedy line breaker, or null when Compose must
/// decide. Minikin gives each character its glyphs' advances, a kern going to
/// the first character of the pair (as in the prefix), sums them in float32,
/// and ends a line at the last word boundary whose width, trailing spaces left
/// out, is not greater than the box ([width], a whole number of px). Widths are
/// multiples of [quantum]: the sums are exact in float32 below 2^24 quanta, and
/// each is rounded to the quantum to drop the double error of the prefix.
(List<int>?, String) greedy(Records r, String t, int width) {
  if (r.prefix[t.length] / unitsPerPx / quantum >= 1 << 24) return (null, 'sum');
  double px(int a, int b) => ((r.prefix[b] - r.prefix[a]) / unitsPerPx / quantum).roundToDouble() * quantum;
  final starts = <int>[0];
  var s = 0, k = 0;
  for (;;) {
    var best = -1;
    for (var j = k; j < r.count; j++) {
      if (noBreak(r, t, j)) continue;
      if (px(s, r.ends[j]) > width) break;
      best = j;
      if (r.mandatory[j] != 0) break;
    }
    if (best < 0) return (null, 'word'); // wider than the line: Minikin breaks inside it
    if (best == r.count - 1) return (starts, '');
    s = r.nexts[best];
    starts.add(s);
    k = best + 1;
  }
}
