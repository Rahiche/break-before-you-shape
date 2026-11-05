# Break Before You Shape

Exact line breaking from a precompiled, certified width model: line breaks and paragraph heights computed **before**
any text shaping, and identical to what the text engine produces.

Paper: [paper/paper.pdf](paper/paper.pdf) ([HTML](paper/paper.html)). Longer research notes: [RESEARCH.md](RESEARCH.md);
what an engine could gain by breaking first inside its own pipeline: [research/ENGINE.md](research/ENGINE.md).
Flutter package: [packages/break_first](packages/break_first) ([pub.dev](https://pub.dev/packages/break_first)). The same
method against Jetpack Compose: [compose_bench](compose_bench).

What if you could ask a `Text` its size before it is laid out?

```dart
Text('hello', style: style).width          // the width Flutter will give it
Text(caption, maxLines: 3).canFit(240)     // does all of it show in 240 px?
```

![Jumping to message #2,500 in a 10,000-message chat list: stock ListView vs break-first extents](media/list_extents_jump.gif)

<!-- demo -->
A chat list of 10,000 messages on the Android emulator, release build ([video](media/list_extents_android.mp4)).
The stock `ListView` asked for #2,500 lands on #1,969, in a 570 ms frame. With break-first extents it lands on #2,500
in a 17 ms frame. All 10,000 extents equal `TextPainter`'s ([measured log](media/list_extents_android_measured.txt)).
<!-- /demo -->

## The idea

Text engines shape a paragraph (HarfBuzz) before they can break it into lines. This project compiles a font's shaping
behaviour into a small per-font model by **measuring the shaper as a black box**: every character, every pair, every
ligature island next to each safe neighbour. A **static analysis of the font's layout tables** (GSUB, GPOS, GDEF, `morx`,
`kern`, `kerx`) proves on which lines the model's width equals the shaped width. Lines are then broken from the model
alone. Anything the breaker cannot certify goes back to the engine.

## Results

Measured on one Apple M3 machine (macOS, an iOS 17.5 simulator, an Android API 35 emulator) and on GitHub Actions.
Every number in the paper is generated from the files in `results/`, `census/`, `flutter_bench/results/` and
`compose_bench/results/`.

<!-- results -->
|  |  |
|---|---|
| Font census (HarfBuzz): 449 local font faces | 5,342,060 of 5,560,372 lines certified (96%), **0 wrong**; 410 faces certify ≥ 99% of lines |
| Font census (Flutter): 447 faces, each sidecar built through Flutter | **3,869,528** decided layouts identical, 0 different |
| Flutter, macOS release: line breaks and heights vs Flutter's own layout | **2,524,906 of 2,524,906** paragraph layouts identical (7,201,350 lines; nine corpora, six languages, six font sizes, twelve widths); 0.87% handed back to Flutter |
| Same sidecar on the iOS simulator / Android emulator | 192,193 of 192,193 / 192,175 of 192,175 identical |
| On GitHub Actions: Linux, macOS, iOS simulator, Android emulator ([run](flutter_bench/results/ci/run-42050188094)) | **5,529,281** layouts identical, 0 different |
| Flutter web (CanvasKit and skwasm (WebAssembly), Chrome) | **47,946** layouts identical, 0 different |
| Letter and word spacing, height multiplier, `maxLines`, hard line breaks (macOS release) | **4,575,628** layouts identical, 0 different |
| Hebrew and Arabic (alone and mixed with Latin), Japanese, Chinese, Korean | **914,316** layouts identical, 0 different; the other 705,648 handed to Flutter |
| 15 further checks: struts, font features, rich text, fallback fonts, combining marks, pointed Hebrew, vowelled Arabic, emoji, Indic, Thai, Lao, Khmer, Burmese | **2,498,638** layouts identical, 0 different |
| `Text('hello').width`, `.height(w)`, `.lineCount(w)`, `.canFit(w)` against the widgets themselves | **870,000** answers for 261,000 `Text` widgets in 87 configurations, 0 different |
| Jetpack Compose: line breaks and heights vs Compose's own layout ([compose_bench](compose_bench), Android 15 emulator (API 35)) | **301,420** decided layouts identical, 0 different; a chat list's heights 6.0× faster than `TextMeasurer` |
| Speed vs `TextPainter` (macOS release, median of 3 runs) | **17.0×** (docs), **26.7×** (chat); re-wrap at a new width 13.0× / 15.2× |
| Speed on GitHub Actions (docs / chat) | 23.4× / 31.7× macOS (virtual M1), 19.1× / 26.7× Linux, 41.5× / 37.1× Android emulator |
| C port of the breaker through `dart:ffi` | same line starts in all 2,552,760 checks; 2.0× / 2.1× faster than the Dart breaker, so the package stays in Dart |
| Sidecar for Roboto (Latin, Greek, Cyrillic) | 593,684 bytes, 12,319 gzipped, one file for every font size and style option |
| Today's shortcuts vs exact ground truth (HarfBuzz) | shape once then break: up to 1.2% of paragraphs wrong; per-word cache: up to 9.6% |
<!-- /results -->

## Where it pays

Break-first does not make drawing cheaper: a line that is painted is still shaped. It pays wherever an app must know how
text lays out without drawing it. Each case is timed against what a Flutter app does today and checked answer for answer
(macOS release build; `BF_MODE=usecases`, `flutter_bench/test/use_cases_test.dart`):

<!-- usecases -->
| Use case | Flutter today | Break-first | Faster | Same answers |
|---|---|---|---|---|
| Exact extents for a 24,000-message chat list | TextPainter: 563 ms | 28 ms | **20.4×** | 24,000 / 24,000 heights |
| Re-wrap 5,089 laid-out paragraphs at a new width (resize, rotation) | re-layout: 17 ms | 1.3 ms | **13.0×** | Table 2 |
| Text scale 16 → 20.8 px: every height again (24,000 messages) | TextPainter: 568 ms | 13 ms | **44.9×** | 24,000 / 24,000 heights |
| Auto-fit: the largest of 41 sizes that keeps a message in 3 lines (3,000 messages) | TextPainter: 419 ms | 6.9 ms | **60.9×** | 3,000 / 3,000 sizes |
| Paginate 6,455 paragraphs into 994 pages | TextPainter: 426 ms | 30 ms | **14.2×** | every page break |
| Re-paginate at 18 px (1,230 pages) | TextPainter: 436 ms | 9.0 ms | **48.5×** | every page break |
| Every height in a background isolate (24,000 messages) | not possible | 65 ms off the UI isolate, 4.8 ms on it | — | 24,000 / 24,000 heights |
| Heights on a server, no Flutter (24,000 messages) | not possible | 22 ms, native executable | — | 23,878 / 23,878 decided |
| Flutter web (CanvasKit): chat-list extents | TextPainter: 1,139 ms | 49 ms | **23.0×** | 24,000 / 24,000 heights |
| Flutter web (CanvasKit): auto-fit | TextPainter: 683 ms | 13 ms | **51.5×** | 3,000 / 3,000 sizes |
| Flutter web (skwasm): chat-list extents | TextPainter: 962 ms | 38 ms | **25.5×** | 24,000 / 24,000 heights |
| Flutter web (skwasm): auto-fit | TextPainter: 741 ms | 13 ms | **55.5×** | 3,000 / 3,000 sizes |
<!-- /usecases -->

Flutter's own text layout fails outside the root isolate; the breaker is plain Dart (`package:break_first/model.dart`),
so it runs in a background isolate, on a server or in a command-line tool. It gains nothing for text laid out once and
drawn at once.

## Layout

| Path | What |
|---|---|
| `certify.py` | Static certificate: classifies every character S / P / K / U from the font's tables (fontTools) |
| `bfl.c` | C prototype: distillation, breaker, island-table checker, HarfBuzz baselines |
| `census.py`, `census_reasons.py` | Census over every local font face, and what blocks the rest |
| `font_census.py` | Prepares the Flutter font census (`flutter_bench/test/font_census_test.dart`) |
| `make_corpus.py`, `make_corpora.py` | Corpora from local files (not shipped: see below) |
| `packages/break_first/` | The Flutter package: breaker and width model, sidecar build step, tests, and the list-extents example |
| `flutter_bench/` | Benchmark app on the package: sidecar build (`test/build_sidecar_test.dart`), validation and timing harness (`lib/bench.dart`), right-to-left and CJK checks (`test/rtl_test.dart`, `test/script_test.dart`, `tool/*_check.sh`) |
| `native/` | C port of the breaker, called through `dart:ffi` in the benchmark (`flutter_bench/lib/native.dart`) |
| `compose_bench/` | Break-first against Jetpack Compose: an Android harness app on Compose's `TextMeasurer`, Minikin's line fit, the exactness and timing tools |
| `research/ENGINE.md` | What breaking first inside an engine's pipeline could change (Flutter, Android, Chrome, Apple), from their source code, with experiments to measure it |
| `.github/workflows/` | `ci.yml` (tests on every push), `bench.yml` (the benchmarks on Linux, macOS, iOS simulator and Android emulator) |
| `media/` | The list-extents demo video, and the numbers it measured |
| `paper/` | `make_figures.py` (figures and every number), `build_paper.py` (fills the template, prints the PDF) |
| `results*.txt`, `census/`, `flutter_bench/results/` | Raw results |

## Reproduce

```sh
# C prototype and census (needs HarfBuzz and fontTools)
clang -O3 -I$(brew --prefix harfbuzz)/include/harfbuzz -L$(brew --prefix harfbuzz)/lib -lharfbuzz bfl.c -o bfl
python3 census.py 6

# Flutter: corpora, sidecar, exactness, timing
cd flutter_bench
tool/prepare_assets.sh
flutter test test/build_sidecar_test.dart
flutter test test/validate_host_test.dart
flutter build macos --release --dart-define=BF_MODE=all
BF_OUT=$PWD/results/macos_release.json build/macos/Build/Products/Release/bf_bench.app/Contents/MacOS/bf_bench

# Use cases (Table 7 of the paper)
flutter build macos --release --dart-define=BF_MODE=usecases

# Jetpack Compose (compose_bench/README.md): exactness, then timing on the emulator
cd ../compose_bench && CACHE_DIR=/tmp/compose_widths dart run tool/compose_check.dart results/compose_exactness.json 2000
CACHE_DIR=/tmp/compose_widths tool/speed.sh 42.0 735 && cd ../flutter_bench

# Paper and the README's tables
cd ../paper && python3 make_figures.py && python3 build_paper.py && python3 build_readme.py
```

The benchmarks also run on GitHub Actions, free on a public repository:

```sh
gh workflow run bench.yml
```

## Notes

- The corpora are extracted from this machine's files: Python docstrings, macOS man pages, licence texts and macOS
  localized UI strings (on Linux runners: gettext catalogs, man pages and licences). They are not redistributed here; `flutter_bench/tool/prepare_assets.sh` regenerates them.
  System fonts are not included either. The census reads them in place.
- `flutter_bench/assets/Roboto-Regular.ttf` is Roboto, under the Apache License 2.0 (`Roboto_LICENSE.txt`).
- The macOS benchmark app has the app sandbox disabled, so it can write its results file.
- Scope: Latin, Greek, Cyrillic, Hebrew, Arabic, Chinese, Japanese and Korean from a bundled font, in either direction,
  in plain and rich text; emoji, Indic, Thai, Lao, Khmer and Burmese from the device's fonts. Characters no font has,
  letter-spaced Arabic, most Arabic with harakat and Hebrew with points, and Indic or Southeast Asian text in a bundled
  font go to Flutter. Mobile timings come from simulators and emulators, not phones.
- Exactness is measured, not proved, and measurement has caught the breaker once: GitHub's Linux runner, on Greek strings
  that are not this machine's, found 2 letter-spaced layouts different, each a word less than 1/100 px wider than the
  box ([run 41953508573](flutter_bench/results/ci/run-41953508573)). SkParagraph floors a line's width before the fit
  test but not before its "too long word" test; the breaker now hands such paragraphs to Flutter, the same runner finds
  none different on the fix ([run 41971344191](flutter_bench/results/ci/run-41971344191)), and every number above was
  measured again after the fix.
