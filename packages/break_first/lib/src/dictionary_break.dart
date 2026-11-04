// Line-break opportunities inside runs of Thai, Lao, Khmer and Burmese text
// (UAX #14 class SA, "complex context"), as Flutter's ICU finds them.
//
// SkParagraph takes line breaks from ICU's line BreakIterator. Its rules treat
// SA as AL (marks as CM), so they never break inside a run of SA characters;
// RuleBasedBreakIterator::DictionaryCache then hands each run to a language
// break engine (dictbe.cpp: ThaiBreakEngine, LaoBreakEngine, KhmerBreakEngine,
// BurmeseBreakEngine), which subdivides it with a word dictionary (a BytesTrie
// from icudtl.dat: brkitr/thaidict.dict, laodict.dict, khmerdict.dict,
// burmesedict.dict). This file is a port of those engines, of
// BytesDictionaryMatcher::matches (dictionarydata.cpp) and of BytesTrie
// (bytestrie.cpp), from the ICU Flutter builds: Chromium's ICU 78.2
// (chromium/deps/icu d578f2e8, pinned by Flutter 3.47's DEPS), which patches
// KhmerBreakEngine's thresholds (patches/khmer-dictbe.patch) and ships abridged
// Khmer and Lao dictionaries. Character sets are from Unicode 17 (ICU 78).
//
// What ICU passes the engine. RuleBasedBreakIterator::handleNext finds the next
// rule boundary; when the rule segment [a, b) contains dictionary characters
// (SA), DictionaryCache::populateDictionary(a, b) scans it for SA characters and
// gives each engine the maximal run of characters in its set
// ([[:Thai:]&[:LineBreak=SA:]] etc.) inside [a, b). The engine returns breaks
// strictly inside that span (it drops one at the span's end), and the cache adds
// a and b. As the rules never break between two SA characters, an engine span is
// a maximal run of one script's SA characters, and nothing outside it is read:
// spaces, punctuation, digits or Latin around the run only delimit it. Within a
// run of SA characters of several scripts, there is no break where the script
// changes (each engine drops its end, the next never breaks at its start); SA
// characters of scripts without a dictionary (Tai Tham, Tai Viet, New Tai Lue,
// Tai Le, Ahom) get no breaks at all (ICU's UnhandledEngine skips them).
//
// The one encoding dependence: Lao, Khmer and Burmese skip spans shorter than
// four native units, and SkParagraph runs the line iterator on UTF-8 (3 bytes per
// character here, so 2 characters suffice) but its word iterator on UTF-16 (4
// characters needed). Thai counts code points (5 needed) either way.
import 'dart:typed_data';

/// The dictionary-backed scripts.
enum DictionaryScript { thai, lao, khmer, burmese }

/// Asset paths of the bundled dictionaries, relative to the package (declared in
/// pubspec.yaml; from an app, prefix 'packages/break_first/').
const Map<DictionaryScript, String> dictionaryAssets = {
  DictionaryScript.thai: 'assets/dictionaries/thaidict.dict',
  DictionaryScript.lao: 'assets/dictionaries/laodict.dict',
  DictionaryScript.khmer: 'assets/dictionaries/khmerdict.dict',
  DictionaryScript.burmese: 'assets/dictionaries/burmesedict.dict',
};

final Map<DictionaryScript, _Dictionary> _dictionaries = {};

/// Loads one ICU dictionary data item (an ICU .dict file as stored in
/// icudtl.dat: generic data header, then the dictionary). The script is read
/// from the dictionary's transform. Returns it.
DictionaryScript loadDictionary(Uint8List icuDict) {
  final d = _Dictionary.parse(icuDict);
  _dictionaries[d.script] = d;
  return d.script;
}

/// Loads the four bundled dictionaries with [load], e.g.
/// `loadBundledDictionaries((k) => rootBundle.load('packages/break_first/$k'))`.
Future<void> loadBundledDictionaries(Future<ByteData> Function(String asset) load) async {
  for (final path in dictionaryAssets.values) {
    loadDictionary(Uint8List.sublistView(await load(path)));
  }
}

/// Forgets the loaded dictionaries (tests).
void unloadDictionaries() => _dictionaries.clear();

/// Whether the dictionary for [script] is loaded.
bool hasDictionary(DictionaryScript script) => _dictionaries.containsKey(script);

/// Line-break opportunities strictly inside text[start, end) that Flutter's ICU
/// line iterator finds there, ascending, as UTF-16 offsets into [text].
///
/// [start, end) must be a maximal run of UAX #14 class SA characters
/// ([isComplexContext]): text[start - 1] and text[end] must not be SA
/// characters of a dictionary script. Returns null, so that the paragraph goes
/// to Flutter, when a needed dictionary is not loaded or the range cuts a run
/// that ICU would see whole. Inside the run these are the only line-break
/// opportunities; at its ends, UAX #14 applies with SA resolved to AL, or CM for
/// [isComplexContextMark] (LB1). The characters around the run do not change
/// the result.
///
/// SkParagraph only breaks between its glyph clusters (HarfBuzz clusters at the
/// monotone-characters level, not graphemes). A few opportunities fall inside a
/// grapheme ([breakMayBeInsideGrapheme]): whether Flutter takes them depends on
/// the font's clusters (measured: taken before Thai SARA AM in Tahoma, not
/// taken after a Myanmar virama, which stacks the next consonant).
List<int>? dictionaryBreaks(String text, int start, int end) => _breaks(text, start, end, 3);

/// Whether a break at [i] may fall inside a grapheme cluster: before Thai or Lao
/// AM (U+0E33, U+0EB3: GB9a), or after a Myanmar virama or Khmer coeng (U+1039,
/// U+17D2), possibly followed by marks (GB9c conjuncts). Conservative: all
/// dictionary breaks inside graphemes in the validation corpora are flagged.
bool breakMayBeInsideGrapheme(String text, int i) {
  if (i <= 0 || i >= text.length) return false;
  final c = text.codeUnitAt(i);
  if (c == 0x0E33 || c == 0x0EB3) return true;
  for (var j = i - 1; j >= 0; j--) {
    final p = text.codeUnitAt(j);
    if (p == 0x1039 || p == 0x17D2) return true;
    if (!isComplexContextMark(p)) return false;
  }
  return false;
}

/// The same for Flutter's word iterator (ui.Paragraph.getWordBoundary), which
/// runs on UTF-16: the engines' minimum span for Lao, Khmer and Burmese differs.
/// Null for a run that starts with a combining mark: the word rules attach it to
/// the character before (WB4) and break after it, so the engine sees the run
/// without it.
List<int>? dictionaryWordBreaks(String text, int start, int end) =>
    start < end && isComplexContextMark(text.codeUnitAt(start)) ? null : _breaks(text, start, end, 1);

/// UAX #14 class SA (LineBreak=Complex_Context), Unicode 17.
bool isComplexContext(int cp) => _inRanges(_sa, cp);

/// SA characters with General_Category Mn or Mc: CM for the line rules (LB1).
bool isComplexContextMark(int cp) => _inRanges(_saMarks, cp);

/// The dictionary script whose engine handles [cp], or null.
DictionaryScript? dictionaryScriptOf(int cp) {
  for (final e in _engines) {
    if (e.inSet(cp)) return e.script;
  }
  return null;
}

// ---------------------------------------------------------------------------

List<int>? _breaks(String text, int start, int end, int nativePerChar) {
  final out = <int>[];
  var i = start;
  while (i < end) {
    final c = text.codeUnitAt(i);
    final e = _engineFor(c);
    if (e == null) {
      i++; // not a dictionary character, or UnhandledEngine: no breaks
      continue;
    }
    var j = i + 1;
    while (j < end && e.inSet(text.codeUnitAt(j))) {
      j++;
    }
    // ICU's span is maximal: the caller must not cut it.
    if ((i == start && start > 0 && e.inSet(text.codeUnitAt(start - 1))) ||
        (j == end && end < text.length && e.inSet(text.codeUnitAt(end)))) {
      return null;
    }
    final dict = _dictionaries[e.script];
    if (dict == null) return null;
    final n = j - i;
    final cps = Int32List(n);
    for (var k = 0; k < n; k++) {
      cps[k] = text.codeUnitAt(i + k); // all engine characters are in the BMP
    }
    for (final b in e.divide(cps, dict, nativePerChar)) {
      out.add(i + b);
    }
    i = j;
  }
  return out;
}

_Engine? _engineFor(int c) {
  if (c < 0x0E01 || c > 0xAA7F) return null;
  for (final e in _engines) {
    if (e.inSet(c)) return e;
  }
  return null;
}

bool _inRanges(List<int> r, int cp) {
  var lo = 0, hi = r.length ~/ 2 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (cp < r[2 * mid]) {
      hi = mid - 1;
    } else if (cp > r[2 * mid + 1]) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

bool _in(int c, int a, int b) => c >= a && c <= b;

// LineBreak=SA, Unicode 17 (LineBreak-17.0.0.txt), inclusive ranges.
const List<int> _sa = [
  0x0E01, 0x0E3A, 0x0E40, 0x0E4E, 0x0E81, 0x0E82, 0x0E84, 0x0E84, 0x0E86, 0x0E8A, 0x0E8C, 0x0EA3, 0x0EA5, 0x0EA5, //
  0x0EA7, 0x0EBD, 0x0EC0, 0x0EC4, 0x0EC6, 0x0EC6, 0x0EC8, 0x0ECE, 0x0EDC, 0x0EDF, 0x1000, 0x103F, 0x1050, 0x108F, //
  0x109A, 0x109F, 0x1780, 0x17D3, 0x17D7, 0x17D7, 0x17DC, 0x17DD, 0x1950, 0x196D, 0x1970, 0x1974, 0x1980, 0x19AB, //
  0x19B0, 0x19C9, 0x19DE, 0x19DF, 0x1A20, 0x1A5E, 0x1A60, 0x1A7C, 0x1AA0, 0x1AAD, 0xA9E0, 0xA9EF, 0xA9FA, 0xA9FE, //
  0xAA60, 0xAAC2, 0xAADB, 0xAADF, 0x11700, 0x1171A, 0x1171D, 0x1172B, 0x1173A, 0x1173B, 0x1173F, 0x11746,
];

// SA with General_Category Mn or Mc (there is no Me).
const List<int> _saMarks = [
  0x0E31, 0x0E31, 0x0E34, 0x0E3A, 0x0E47, 0x0E4E, 0x0EB1, 0x0EB1, 0x0EB4, 0x0EBC, 0x0EC8, 0x0ECE, 0x102B, 0x103E, //
  0x1056, 0x1059, 0x105E, 0x1060, 0x1062, 0x1064, 0x1067, 0x106D, 0x1071, 0x1074, 0x1082, 0x108D, 0x108F, 0x108F, //
  0x109A, 0x109D, 0x17B4, 0x17D3, 0x17DD, 0x17DD, 0x1A55, 0x1A5E, 0x1A60, 0x1A7C, 0xA9E5, 0xA9E5, 0xAA7B, 0xAA7D, //
  0xAAB0, 0xAAB0, 0xAAB2, 0xAAB4, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xAAC1, 0x1171D, 0x1172B,
];

// ---------------------------------------------------------------------------
// The engines (dictbe.cpp). Sets, Unicode 17:
//   fSet      [[:Script:]&[:LineBreak=SA:]]
//   fMarkSet  [[:Script:]&[:LineBreak=SA:]&[:M:]] plus U+0020
//   fEndWordSet, fBeginWordSet as in each constructor.

final List<_Engine> _engines = [
  _Engine(
    DictionaryScript.thai,
    inSet: (c) => _in(c, 0x0E01, 0x0E3A) || _in(c, 0x0E40, 0x0E4E),
    isMark: (c) => c == 0x20 || c == 0x0E31 || _in(c, 0x0E34, 0x0E3A) || _in(c, 0x0E47, 0x0E4E),
    // fEndWordSet = fSet - U+0E31 (MAI HAN-AKAT) - U+0E40..U+0E44 (SARA E..SARA AI MAIMALAI)
    isEndWord: (c) => (_in(c, 0x0E01, 0x0E3A) && c != 0x0E31) || _in(c, 0x0E45, 0x0E4E),
    // KO KAI..HO NOKHUK, SARA E..SARA AI MAIMALAI
    isBeginWord: (c) => _in(c, 0x0E01, 0x0E2E) || _in(c, 0x0E40, 0x0E44),
    rootCombineThreshold: 3,
    prefixCombineThreshold: 3,
    thai: true,
  ),
  _Engine(
    DictionaryScript.lao,
    inSet: _isLaoSA,
    isMark: (c) => c == 0x20 || c == 0x0EB1 || _in(c, 0x0EB4, 0x0EBC) || _in(c, 0x0EC8, 0x0ECE),
    isEndWord: (c) => _isLaoSA(c) && !_in(c, 0x0EC0, 0x0EC4), // minus the prefix vowels
    isBeginWord: (c) => _in(c, 0x0E81, 0x0EAE) || _in(c, 0x0EDC, 0x0EDD) || _in(c, 0x0EC0, 0x0EC4),
    rootCombineThreshold: 3,
    prefixCombineThreshold: 3,
  ),
  _Engine(
    DictionaryScript.burmese,
    inSet: _isMyanmarSA,
    isMark: (c) =>
        c == 0x20 ||
        _in(c, 0x102B, 0x103E) ||
        _in(c, 0x1056, 0x1059) ||
        _in(c, 0x105E, 0x1060) ||
        _in(c, 0x1062, 0x1064) ||
        _in(c, 0x1067, 0x106D) ||
        _in(c, 0x1071, 0x1074) ||
        _in(c, 0x1082, 0x108D) ||
        c == 0x108F ||
        _in(c, 0x109A, 0x109D) ||
        c == 0xA9E5 ||
        _in(c, 0xAA7B, 0xAA7D),
    isEndWord: _isMyanmarSA,
    isBeginWord: (c) => _in(c, 0x1000, 0x102A), // basic consonants and independent vowels
    rootCombineThreshold: 3,
    prefixCombineThreshold: 3,
  ),
  _Engine(
    DictionaryScript.khmer,
    inSet: _isKhmerSA,
    isMark: (c) => c == 0x20 || _in(c, 0x17B4, 0x17D3) || c == 0x17DD,
    isEndWord: (c) => _isKhmerSA(c) && c != 0x17D2, // minus KHMER SIGN COENG
    isBeginWord: (c) => _in(c, 0x1780, 0x17B3),
    // Chromium's khmer-dictbe.patch (upstream ICU: 3 and 3), for its abridged dictionary.
    rootCombineThreshold: 10,
    prefixCombineThreshold: 5,
  ),
];

bool _isLaoSA(int c) =>
    _in(c, 0x0E81, 0x0E82) ||
    c == 0x0E84 ||
    _in(c, 0x0E86, 0x0E8A) ||
    _in(c, 0x0E8C, 0x0EA3) ||
    c == 0x0EA5 ||
    _in(c, 0x0EA7, 0x0EBD) ||
    _in(c, 0x0EC0, 0x0EC4) ||
    c == 0x0EC6 ||
    _in(c, 0x0EC8, 0x0ECE) ||
    _in(c, 0x0EDC, 0x0EDF);

bool _isMyanmarSA(int c) =>
    _in(c, 0x1000, 0x103F) ||
    _in(c, 0x1050, 0x108F) ||
    _in(c, 0x109A, 0x109F) ||
    _in(c, 0xA9E0, 0xA9EF) ||
    _in(c, 0xA9FA, 0xA9FE) ||
    _in(c, 0xAA60, 0xAA7F);

bool _isKhmerSA(int c) => _in(c, 0x1780, 0x17D3) || c == 0x17D7 || _in(c, 0x17DC, 0x17DD);

const int _thaiPaiyannoi = 0x0E2F; // elision character
const int _thaiMaiyamok = 0x0E46; // repeat character
const int _lookahead = 3; // THAI_LOOKAHEAD etc.: how many words in a row are "good enough"
const int _minWordSpan = 4; // *_MIN_WORD * 2

/// A cursor over one engine span, standing in for ICU's UText: positions are
/// code points (all engine characters are BMP), reads past the span return
/// U_SENTINEL (-1). The engines never read past their span except where the
/// result cannot depend on it (see [_Engine.divide]).
class _Text {
  _Text(this.cps);
  final Int32List cps;
  int pos = 0;

  int current32() => pos < cps.length ? cps[pos] : -1;
  int next32() => pos < cps.length ? cps[pos++] : -1;
  int previous32() => pos > 0 ? cps[--pos] : -1;
}

/// dictbe.cpp PossibleWord: the candidate words at one position.
class _PossibleWord {
  static const int listMax = 20; // POSSIBLE_WORD_LIST_MAX
  int count = 0; // candidates found
  int prefix = 0; // longest match with a dictionary word (code points)
  int offset = -1; // text position of these candidates
  int mark = 0; // the preferred candidate
  int current = 0; // the candidate being looked at
  final Int32List cuLengths = Int32List(listMax), cpLengths = Int32List(listMax);

  int candidates(_Text text, _Dictionary dict, int rangeEnd) {
    final start = text.pos;
    if (start != offset) {
      offset = start;
      count = dict.matches(text, rangeEnd - start, listMax, cuLengths, cpLengths, this);
      // The dictionary leaves the text after the longest prefix, not the longest word.
      if (count <= 0) text.pos = start;
    }
    if (count > 0) text.pos = start + cuLengths[count - 1];
    current = count - 1;
    mark = current;
    return count;
  }

  int acceptMarked(_Text text) {
    text.pos = offset + cuLengths[mark];
    return cuLengths[mark];
  }

  bool backUp(_Text text) {
    if (current > 0) {
      text.pos = offset + cuLengths[--current];
      return true;
    }
    return false;
  }

  void markCurrent() => mark = current;
  int markedCPLength() => cpLengths[mark];
}

class _Engine {
  _Engine(
    this.script, {
    required this.inSet,
    required this.isMark,
    required this.isEndWord,
    required this.isBeginWord,
    required this.rootCombineThreshold,
    required this.prefixCombineThreshold,
    this.thai = false,
  });

  final DictionaryScript script;
  final bool Function(int) inSet, isMark, isEndWord, isBeginWord;

  /// Will not combine a non-word with a preceding dictionary word longer than this.
  final int rootCombineThreshold;

  /// Will not combine a non-word that shares at least this much prefix with a
  /// dictionary word with a preceding word.
  final int prefixCombineThreshold;

  /// ThaiBreakEngine: the minimum span counts code points, and PAIYANNOI and
  /// MAI YAMOK attach to the preceding word.
  final bool thai;

  bool isSuffix(int c) => thai && (c == _thaiPaiyannoi || c == _thaiMaiyamok);

  /// divideUpDictionaryRange over one span: the breaks it pushes, relative to
  /// the span, without one at its end. [nativePerChar]: UText native units per
  /// character (UTF-8: 3, UTF-16: 1).
  List<int> divide(Int32List cps, _Dictionary dict, int nativePerChar) {
    final rangeEnd = cps.length;
    final text = _Text(cps);
    if (thai) {
      // utext_moveIndex32(text, THAI_MIN_WORD_SPAN) >= rangeEnd
      if (rangeEnd <= _minWordSpan) return const [];
    } else if (rangeEnd * nativePerChar < _minWordSpan) {
      return const []; // (rangeEnd - rangeStart) < *_MIN_WORD_SPAN, native units
    }
    final foundBreaks = <int>[];
    var wordsFound = 0;
    final words = List<_PossibleWord>.generate(_lookahead, (_) => _PossibleWord());
    int current;
    while ((current = text.pos) < rangeEnd) {
      var cpWordLength = 0; // word length in code points
      var cuWordLength = 0; // word length in native units (here: code points too)

      // Look for candidate words at the current position.
      final candidates = words[wordsFound % _lookahead].candidates(text, dict, rangeEnd);
      if (candidates == 1) {
        // Exactly one: use it.
        cuWordLength = words[wordsFound % _lookahead].acceptMarked(text);
        cpWordLength = words[wordsFound % _lookahead].markedCPLength();
        wordsFound += 1;
      } else if (candidates > 1) {
        // More than one: see which one can take us forward the most words.
        foundBest:
        {
          if (text.pos >= rangeEnd) break foundBest; // already at the end of the range
          do {
            if (words[(wordsFound + 1) % _lookahead].candidates(text, dict, rangeEnd) > 0) {
              // Followed by another dictionary word; mark the first word as a good candidate.
              words[wordsFound % _lookahead].markCurrent();
              if (text.pos >= rangeEnd) break foundBest;
              // See if any of the possible second words is followed by a third word.
              do {
                // If we find a third word, stop right away.
                if (words[(wordsFound + 2) % _lookahead].candidates(text, dict, rangeEnd) != 0) {
                  words[wordsFound % _lookahead].markCurrent();
                  break foundBest;
                }
              } while (words[(wordsFound + 1) % _lookahead].backUp(text));
            }
          } while (words[wordsFound % _lookahead].backUp(text));
        }
        // Set the position after the accepted word.
        cuWordLength = words[wordsFound % _lookahead].acceptMarked(text);
        cpWordLength = words[wordsFound % _lookahead].markedCPLength();
        wordsFound += 1;
      }

      // Having found a word or not, look ahead to the next one. If it is not a
      // dictionary word, combine it with the word just found (if any), unless
      // that word exceeds the threshold.
      var uc = 0; // ThaiBreakEngine declares it here; the suffix test may reuse it
      if (text.pos < rangeEnd && cpWordLength < rootCombineThreshold) {
        // If it is a dictionary word, do nothing. If it isn't, then if there is no
        // preceding word, or the non-word shares less than the minimum threshold
        // of characters with a dictionary word, scan to resynchronize.
        if (words[wordsFound % _lookahead].candidates(text, dict, rangeEnd) <= 0 &&
            (cuWordLength == 0 || words[wordsFound % _lookahead].prefix < prefixCombineThreshold)) {
          // Look for a plausible word boundary.
          var remaining = rangeEnd - (current + cuWordLength);
          var chars = 0;
          for (;;) {
            final pcIndex = text.pos;
            final pc = text.next32();
            final pcSize = text.pos - pcIndex;
            chars += pcSize;
            remaining -= pcSize;
            if (remaining <= 0) break;
            uc = text.current32();
            if (isEndWord(pc) && isBeginWord(uc)) {
              // Maybe. See if it's in the dictionary.
              final numCandidates = words[(wordsFound + 1) % _lookahead].candidates(text, dict, rangeEnd);
              text.pos = current + cuWordLength + chars;
              if (numCandidates > 0) break;
            }
          }
          // Bump the word count if there wasn't already one.
          if (cuWordLength <= 0) wordsFound += 1;
          // Update the length with the passed-over characters.
          cuWordLength += chars;
        } else {
          // Back up to where we were for the next iteration.
          text.pos = current + cuWordLength;
        }
      }

      // Never stop before a combining mark.
      int currPos;
      while ((currPos = text.pos) < rangeEnd && isMark(text.current32())) {
        text.next32();
        cuWordLength += text.pos - currPos;
      }

      // Thai: look ahead for possible suffixes if a dictionary word does not
      // follow. (Not applicable to Lao, Khmer or Burmese.)
      if (thai && text.pos < rangeEnd && cuWordLength > 0) {
        if (words[wordsFound % _lookahead].candidates(text, dict, rangeEnd) <= 0 &&
            isSuffix(uc = text.current32())) {
          if (uc == _thaiPaiyannoi) {
            if (!isSuffix(text.previous32())) {
              // Skip over the previous end and PAIYANNOI.
              text.next32();
              final paiyannoiIndex = text.pos;
              text.next32();
              cuWordLength += text.pos - paiyannoiIndex; // add PAIYANNOI to the word
              // Fetch the next character. At the span's end ICU reads the character
              // after it, which cannot be MAI YAMOK (an SA character would have
              // continued the span), as -1 cannot.
              uc = text.current32();
            } else {
              text.next32(); // restore the prior position
            }
          }
          if (uc == _thaiMaiyamok) {
            if (text.previous32() != _thaiMaiyamok) {
              // Skip over the previous end and MAI YAMOK.
              text.next32();
              final maiyamokIndex = text.pos;
              text.next32();
              cuWordLength += text.pos - maiyamokIndex; // add MAI YAMOK to the word
            } else {
              text.next32(); // restore the prior position
            }
          }
        } else {
          text.pos = current + cuWordLength;
        }
      }

      // Did we find a word on this iteration? If so, push it on the break stack.
      if (cuWordLength > 0) foundBreaks.add(current + cuWordLength);
    }

    // Don't return a break for the end of the dictionary range if there is one there.
    if (foundBreaks.isNotEmpty && foundBreaks.last >= rangeEnd) foundBreaks.removeLast();
    return foundBreaks;
  }
}

// ---------------------------------------------------------------------------
// The dictionary: BytesDictionaryMatcher over an ICU BytesTrie.

const int _trieTypeBytes = 0, _trieTypeMask = 7;
const int _transformTypeOffset = 0x1000000, _transformTypeMask = 0x7f000000, _transformOffsetMask = 0x1fffff;

class _Dictionary {
  _Dictionary(this.script, this.trie, this.transformConstant);

  /// Parses an ICU .dict data item: a generic ICU data header (format "Dict",
  /// version 1, little-endian), then int32 indexes (IX_STRING_TRIE_OFFSET,
  /// IX_RESERVED1_OFFSET, IX_RESERVED2_OFFSET, IX_TOTAL_SIZE, IX_TRIE_TYPE,
  /// IX_TRANSFORM, ...), then the trie.
  factory _Dictionary.parse(Uint8List file) {
    final bd = ByteData.sublistView(file);
    if (file.length < 32 || file[2] != 0xDA || file[3] != 0x27) {
      throw const FormatException('not an ICU data item');
    }
    final headerSize = bd.getUint16(0, Endian.little);
    // UDataInfo at 4: size(2) reserved(2) isBigEndian(1) charsetFamily(1)
    // sizeofUChar(1) reserved(1) dataFormat(4) formatVersion(4) dataVersion(4).
    if (file[8] != 0) throw const FormatException('big-endian dictionary');
    if (String.fromCharCodes(file, 12, 16) != 'Dict' || file[16] != 1) {
      throw const FormatException('not an ICU dictionary (format Dict 1)');
    }
    int ix(int i) => bd.getInt32(headerSize + 4 * i, Endian.little);
    final trieOffset = ix(0), totalSize = ix(3), trieType = ix(4) & _trieTypeMask, transform = ix(5);
    if (trieType != _trieTypeBytes) throw const FormatException('only BytesTrie dictionaries are supported');
    if ((transform & _transformTypeMask) != _transformTypeOffset) {
      throw const FormatException('unsupported dictionary transform');
    }
    final script = switch (transform & _transformOffsetMask) {
      0x0E00 => DictionaryScript.thai,
      0x0E80 => DictionaryScript.lao,
      0x1780 => DictionaryScript.khmer,
      0x1000 => DictionaryScript.burmese,
      final o => throw FormatException('dictionary for unknown script (offset 0x${o.toRadixString(16)})'),
    };
    final trie = Uint8List.sublistView(file, headerSize + trieOffset, headerSize + totalSize);
    return _Dictionary(script, trie, transform);
  }

  final DictionaryScript script;
  final Uint8List trie;
  final int transformConstant;

  int transform(int c) {
    if (c == 0x200D) return 0xFF;
    if (c == 0x200C) return 0xFE;
    final delta = c - (transformConstant & _transformOffsetMask);
    if (delta < 0 || 0xFD < delta) return -1; // U_SENTINEL: BytesTrie reads it as 0xFF
    return delta;
  }

  /// BytesDictionaryMatcher::matches: the dictionary words that start at the
  /// text position, up to [maxLength] units; their lengths go to [lengths] and
  /// [cpLengths], the longest prefix (code points read, including the one that
  /// failed) to [word].prefix.
  int matches(_Text text, int maxLength, int limit, Int32List lengths, Int32List cpLengths, _PossibleWord word) {
    final bt = _BytesTrie(trie);
    final startingTextIndex = text.pos;
    var wordCount = 0, codePointsMatched = 0;
    for (var c = text.next32(); c >= 0; c = text.next32()) {
      final result = codePointsMatched == 0 ? bt.first(transform(c)) : bt.next(transform(c));
      final lengthMatched = text.pos - startingTextIndex;
      codePointsMatched += 1;
      if (result >= _finalValue) {
        // USTRINGTRIE_HAS_VALUE
        if (wordCount < limit) {
          lengths[wordCount] = lengthMatched;
          cpLengths[wordCount] = codePointsMatched;
          ++wordCount;
        }
        if (result == _finalValue) break;
      } else if (result == _noMatch) {
        break;
      }
      if (lengthMatched >= maxLength) break;
    }
    word.prefix = codePointsMatched;
    return wordCount;
  }
}

// UStringTrieResult
const int _noMatch = 0, _finalValue = 2, _intermediateValue = 3;

/// ICU BytesTrie (bytestrie.cpp), the parts that matches() uses.
class _BytesTrie {
  _BytesTrie(this.bytes);
  final Uint8List bytes;
  int _pos = 0; // -1: stopped (pos_ == nullptr)
  int _remainingMatchLength = -1;

  static const int _maxBranchLinearSubNodeLength = 5;
  static const int _minLinearMatch = 0x10;
  static const int _minValueLead = 0x20;
  static const int _valueIsFinal = 1;
  static const int _minOneByteValueLead = 0x10;
  static const int _minTwoByteValueLead = 0x51;
  static const int _minThreeByteValueLead = 0x6c;
  static const int _fourByteValueLead = 0x7e;
  static const int _minTwoByteDeltaLead = 0xc0;
  static const int _minThreeByteDeltaLead = 0xf0;
  static const int _fourByteDeltaLead = 0xfe;

  static int _valueResult(int node) => _intermediateValue - (node & _valueIsFinal);

  int first(int inByte) {
    _remainingMatchLength = -1;
    if (inByte < 0) inByte += 0x100;
    return _nextImpl(0, inByte);
  }

  int next(int inByte) {
    var pos = _pos;
    if (pos < 0) return _noMatch;
    if (inByte < 0) inByte += 0x100;
    var length = _remainingMatchLength; // actual remaining match length minus 1
    if (length >= 0) {
      // Remaining part of a linear-match node.
      if (inByte == bytes[pos++]) {
        _remainingMatchLength = --length;
        _pos = pos;
        int node;
        return (length < 0 && (node = bytes[pos]) >= _minValueLead) ? _valueResult(node) : 1;
      } else {
        _pos = -1;
        return _noMatch;
      }
    }
    return _nextImpl(pos, inByte);
  }

  int _nextImpl(int pos, int inByte) {
    for (;;) {
      var node = bytes[pos++];
      if (node < _minLinearMatch) {
        return _branchNext(pos, node, inByte);
      } else if (node < _minValueLead) {
        // Match the first of length+1 bytes.
        var length = node - _minLinearMatch; // actual match length minus 1
        if (inByte == bytes[pos++]) {
          _remainingMatchLength = --length;
          _pos = pos;
          return (length < 0 && (node = bytes[pos]) >= _minValueLead) ? _valueResult(node) : 1;
        } else {
          break; // no match
        }
      } else if (node & _valueIsFinal != 0) {
        break; // no further matching bytes
      } else {
        pos = _skipValue(pos, node); // skip an intermediate value
      }
    }
    _pos = -1;
    return _noMatch;
  }

  int _branchNext(int pos, int length, int inByte) {
    // Branch according to the current byte.
    if (length == 0) length = bytes[pos++];
    ++length;
    // The length of the branch is the number of bytes to select from; the data
    // structure encodes a binary search.
    while (length > _maxBranchLinearSubNodeLength) {
      if (inByte < bytes[pos++]) {
        length >>= 1;
        pos = _jumpByDelta(pos);
      } else {
        length = length - (length >> 1);
        pos = _skipDelta(pos);
      }
    }
    // Drop down to linear search for the last few bytes.
    do {
      if (inByte == bytes[pos++]) {
        int result;
        var node = bytes[pos];
        if (node & _valueIsFinal != 0) {
          result = _finalValue; // leave the final value for getValue() to read
        } else {
          // Use the non-final value as the jump delta.
          ++pos;
          node >>= 1;
          int delta;
          if (node < _minTwoByteValueLead) {
            delta = node - _minOneByteValueLead;
          } else if (node < _minThreeByteValueLead) {
            delta = ((node - _minTwoByteValueLead) << 8) | bytes[pos++];
          } else if (node < _fourByteValueLead) {
            delta = ((node - _minThreeByteValueLead) << 16) | (bytes[pos] << 8) | bytes[pos + 1];
            pos += 2;
          } else if (node == _fourByteValueLead) {
            delta = (bytes[pos] << 16) | (bytes[pos + 1] << 8) | bytes[pos + 2];
            pos += 3;
          } else {
            delta = (bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3];
            pos += 4;
          }
          pos += delta;
          node = bytes[pos];
          result = node >= _minValueLead ? _valueResult(node) : 1;
        }
        _pos = pos;
        return result;
      }
      --length;
      pos = _skipValue(pos + 1, bytes[pos]);
    } while (length > 1);
    if (inByte == bytes[pos++]) {
      _pos = pos;
      final node = bytes[pos];
      return node >= _minValueLead ? _valueResult(node) : 1;
    } else {
      _pos = -1;
      return _noMatch;
    }
  }

  int _jumpByDelta(int pos) {
    var delta = bytes[pos++];
    if (delta < _minTwoByteDeltaLead) {
      // nothing to do
    } else if (delta < _minThreeByteDeltaLead) {
      delta = ((delta - _minTwoByteDeltaLead) << 8) | bytes[pos++];
    } else if (delta < _fourByteDeltaLead) {
      delta = ((delta - _minThreeByteDeltaLead) << 16) | (bytes[pos] << 8) | bytes[pos + 1];
      pos += 2;
    } else if (delta == _fourByteDeltaLead) {
      delta = (bytes[pos] << 16) | (bytes[pos + 1] << 8) | bytes[pos + 2];
      pos += 3;
    } else {
      delta = (bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3];
      pos += 4;
    }
    return pos + delta;
  }

  static int _skipValue(int pos, int leadByte) {
    if (leadByte >= (_minTwoByteValueLead << 1)) {
      if (leadByte < (_minThreeByteValueLead << 1)) {
        ++pos;
      } else if (leadByte < (_fourByteValueLead << 1)) {
        pos += 2;
      } else {
        pos += 3 + ((leadByte >> 1) & 1);
      }
    }
    return pos;
  }

  int _skipDelta(int pos) {
    final delta = bytes[pos++];
    if (delta >= _minTwoByteDeltaLead) {
      if (delta < _minThreeByteDeltaLead) {
        ++pos;
      } else if (delta < _fourByteDeltaLead) {
        pos += 2;
      } else {
        pos += 3 + (delta & 1);
      }
    }
    return pos;
  }
}
