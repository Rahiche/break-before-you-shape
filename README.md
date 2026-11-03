# Break Before You Shape

Exact line breaking from a precompiled, certified width model: line breaks and paragraph heights computed **before**
any text shaping, and identical to what the text engine produces.

Paper: [paper/paper.pdf](paper/paper.pdf) ([HTML](paper/paper.html)). Longer research notes: [RESEARCH.md](RESEARCH.md).
Flutter package: [packages/break_first](packages/break_first).

![Jumping to message #2,500 in a 10,000-message chat list: stock ListView vs break-first extents](media/list_extents_jump.gif)

A chat list of 10,000 messages on the Android emulator, release build ([video](media/list_extents_android.mp4)).
The stock `ListView` asked for #2,500 lands on #1,969, in a 717 ms frame. With break-first extents it lands on #2,500
in a 22 ms frame. All 10,000 extents equal `TextPainter`'s ([measured log](media/list_extents_android_measured.txt)).

## The idea

Text engines shape a paragraph (HarfBuzz) before they can break it into lines. This project compiles a font's shaping
behaviour into a small per-font model by **measuring the shaper as a black box**: every character, every pair, every
ligature island next to each safe neighbour. A **static analysis of the font's layout tables** (GSUB, GPOS, GDEF, `morx`,
`kern`, `kerx`) proves on which lines the model's width equals the shaped width. Lines are then broken from the model
alone. Anything the breaker cannot certify goes back to the engine.

## Results

All measured on one Apple M3 machine (macOS), plus an iOS 17.5 simulator and an Android API 35 emulator. Every
number in the paper is generated from the files in `results/`, `census/` and `flutter_bench/results/`.

| | |
|---|---|
| Font census: 449 local font faces | 4,812,111 of 5,560,372 lines certified, **0 wrong**; 371 faces certify ≥ 99% of lines |
| Flutter, macOS release: line breaks and heights vs Flutter's own layout | **2,524,902 of 2,524,902** paragraph layouts identical (7,201,290 lines; 9 corpora, 6 languages, 6 font sizes, 12 widths); 0.87% handed back to Flutter |
| Same sidecar on the iOS simulator / Android emulator | 192,193 of 192,193 / 192,176 of 192,176 identical |
| Speed vs `TextPainter` (macOS release, median of 3 runs) | **18.5×** (docs), **25.2×** (chat); re-wrap at a new width 11.6× / 9.6× |
| Exact heights for a 24,000-message chat list | 33 ms vs 588 ms (18.0×); every height equal |
| Sidecar for Roboto (Latin, Greek, Cyrillic) | 573,104 bytes, 10,357 gzipped, one file for every font size |
| Today's shortcuts vs exact ground truth (HarfBuzz) | shape once then break: up to 1.2% of paragraphs wrong; per-word cache: up to 9.6% |

## Layout

| Path | What |
|---|---|
| `certify.py` | Static certificate: classifies every character S / P / K / U from the font's tables (fontTools) |
| `bfl.c` | C prototype: distillation, breaker, island-table checker, HarfBuzz baselines |
| `census.py`, `census_reasons.py` | Census over every local font face, and what blocks the rest |
| `make_corpus.py`, `make_corpora.py` | Corpora from local files (not shipped: see below) |
| `packages/break_first/` | The Flutter package: breaker and width model, sidecar build step, tests, and the list-extents example |
| `flutter_bench/` | Benchmark app on the package: sidecar build (`test/build_sidecar_test.dart`), validation and timing harness (`lib/bench.dart`) |
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

# Paper
cd ../paper && python3 make_figures.py && python3 build_paper.py
```

## Notes

- The corpora are extracted from this machine's files: Python docstrings, macOS man pages, licence texts and macOS
  localized UI strings. They are not redistributed here; `flutter_bench/tool/prepare_assets.sh` regenerates them.
  System fonts are not included either. The census reads them in place.
- `flutter_bench/assets/Roboto-Regular.ttf` is Roboto, under the Apache License 2.0 (`Roboto_LICENSE.txt`).
- The macOS benchmark app has the app sandbox disabled, so it can write its results file.
- Scope: Latin, Greek and Cyrillic; plain, single-style, left-to-right paragraphs. Mobile timings come from an
  emulator, not a phone.
