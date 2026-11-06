# Four ideas beyond line breaking, tested

Four uses of the sidecar outside answering a size, each tested against the framework's own layout on this machine
(Apple M3, macOS 26.3 (25D5087f), Flutter 3.47.5; Android results from an emulator, sdk_gphone64_arm64, API 35, arm64-v8a). Idea 1 became a paper (`paper/lines/paper.html`); the other three are recorded here. Every number below is
read from the result file named with it.

| Idea | Result | Verdict |
|---|---|---|
| 1. Draw text line by line: streaming, long text | Same pixels as Flutter in 98.9% of 105,775 comparisons, and in every one at 16 px; streaming at 26–42 µs per token at any length tested; Flutter's own long-text breaks found to degrade | Paper: `paper/lines/` |
| 2. Layout before the font arrives | 98.7% of layouts decided before the font loads; every line break, height and line width equal to Flutter's once it has | Works; a section of a paper, not a paper |
| 3. Why Flutter and Compose wrap differently | Both sidecars predicted exactly which 3,732 of 100,133 layouts wrap differently (0 wrongly flagged, 0 missed), and why | A diagnostic tool |
| 4. Overflow caught at build time | 2,875,608 checks in 0.33 s of plain Dart; 0 different from Flutter where decided (99.8%) | A practical tool |

## 1. Drawing line by line

Full write-up: `paper/lines/paper.html` (*Shape the Line, Not the Paragraph*). In short:

- **Pixels.** Each line laid out as its own one-line paragraph, at the line height the sidecar gives, against Flutter's
  paragraph, byte for byte: 104,600 of 105,775 identical on macOS with Impeller, 38,994 of
  39,530 with Skia, 39,130 of 39,500 on the Android emulator; at 16 px, every comparison under all
  three. A control (the lines moved 1/8 px) was caught every time.
- **Where they differ, the paragraph is off.** At 18.4 px a line drawn alone is within 0.00007 px of the exact
  positions; the same line in its paragraph drifts with its distance along the paragraph's one shaped line, up to
  0.0021 px.
- **Flutter's long-text breaks degrade.** In a 200,133-character `Text`, 21 of 578
  paragraphs break differently from the same paragraph laid out alone. The first, 166,346 px along, is a line
  1/64 px too wide; past 1,000,000 px, Flutter starts lines 18.3 to 65.7 px before a 330 px box is full. Line by
  line, all 748 paragraphs tested match Flutter's layout of the paragraph alone.
- **Streaming.** Exact at all 57,699 steps of 86 answers. Per token at the end of an answer:
  26, 33 and 42 µs line by line for 651, 2,088 and 8,241 characters, against
  129, 386 and 1,509 µs for one `Text`. Against one `Text` per paragraph (a Markdown view), only
  1.3× to 1.4× faster with this corpus's 152-character paragraphs, and 8.0× with 2,449-character ones.
- **Long text.** First frame 1.7×, 2.2× and 3.6× faster for 10, 50 and 200 thousand characters
  (only the viewport's lines laid out; the breaks themselves are a pass over the whole text).

**Why this one is the paper.** It is the only idea of the four that changes the rendering pipeline rather than using
exact widths; its correctness result holds across three renderers; it found a defect in Flutter's own layout of long
text; and for streaming it changes how the cost grows, not just its constant. Not done: a widget (selection, caret,
semantics, justification, ellipsis), raster-time measurements, a phone.

## 2. Layout before the font arrives

**Question.** When a font loads late (web fonts, Google Fonts at run time, fonts downloaded on demand), text is laid
out in a fallback font first, then again in the real one, and it moves. Can the sidecar, which is the font's layout
without its glyphs, give the final layout before the font is there?

**Test** (`flutter_bench/lib/ideas.dart`, `fontLate`; `IDEA=fontlate`; macOS release). The app starts without
Roboto loaded. It computes every line start, height and line width from the sidecar alone, with the engine flags this
platform is known to have, and lets Flutter lay the same texts out in the fallback font it uses meanwhile. Then it
loads the font, calibrates (confirming the flags it assumed) and lays everything out again in Roboto. 2,700 paragraphs
of the 9 corpora, at 14 and 16 px and 150, 240 and 330 px: 16,200 layouts.

**Result** (`flutter_bench/results/ideas_fontlate_macos.json`).
- Today: when the font arrives, 8,174 of the 16,200 layouts change their line breaks and 4,112 their height, by
  5.8 px on average and up to 551 px. A column of all 2,700 paragraphs moves its bottom by 7,954 to 28,367 px.
- From the sidecar, before the font: 15,982 layouts decided (98.7%). All 15,982 have Flutter's line starts and height
  once the font has loaded, and all 72,087 of their lines have Flutter's `LineMetrics.width`, bit for bit, so a
  placeholder could draw each line's exact width. The flags assumed before loading were the ones calibration found;
  the canary error is 0 px.

**Limits.** One platform's fallback font; Flutter, not a browser (CSS font loading has its own rules,
`research/ENGINE.md` §4.3). The sidecar must match the font file that will arrive (its digest is checked once it has).

## 3. Why the same text wraps differently in Flutter and in Jetpack Compose

**Question.** With the same font file at the same pixel size, Flutter and Compose do not always break a text at the
same places. Two sidecars, one distilled from each framework, each reproduce their own framework; does comparing them
predict exactly which texts wrap differently, and say why?

**Test** (`compose_bench/tool/diff_check.dart`, `flutter_bench/test/flutter_starts_test.dart`). Roboto Regular (the same
file in both apps) at 42 px (16 sp at density 2.625), boxes of 336, 630, 735 and 1050 px; the 24,000 macOS interface
strings and 3,000 document paragraphs. Compose's sidecar is distilled from its own widths on the Android emulator, and
its line starts come from `TextMeasurer` there; Flutter's come from Flutter's layout. Texts that either sidecar hands
back are left out.

**Result** (`compose_bench/results/flutter_vs_compose.json`).
- 108,000 layouts, 100,133 decided by both sidecars. Each sidecar's prediction equals its framework's layout in all
  100,133.
- The sidecars predicted 3,732 layouts (3.7%) to wrap differently; exactly those 3,732 do: 0 false positives, 0 false
  negatives.
- Why, at the first line that differs: Flutter breaks after a hyphen or an en dash inside a word, which Compose never
  does (1,176); Flutter measures the deciding line wider (2,122); Compose measures it wider (434). The median line is
  2.07 px narrower in Compose.
- Per character: of 275 characters in both sidecars, 1 has the same advance at 42 px. Compose's hinted advances are
  whole pixels; the two differ by 0.25 px on average and by at most 0.50 px.

**Limits.** One font, one size, one emulator; texts with hard breaks left out.

## 4. Overflow caught at build time

**Question.** Truncated buttons and labels split mid-word are found by testers on devices, per language and per text
size. Can every string, translation, slot and text scale be checked in CI, without Flutter or a device?

**Test.** `flutter_bench/tool/make_translations.py` extracts every string key that macOS has in English, German,
French, Russian, Ukrainian and Greek: 13,313 strings, each in all six languages (English median 21 characters).
`flutter_bench/tool/overflow_check.dart` is plain Dart (`package:break_first/model.dart`, compiled with
`dart compile exe`): for each string, language, slot (button 112 px and tab 90 px at one line; list title 280 px at one
line; subtitle 280 px at two lines; dialog title 24 px at two lines; card body 320 px at three lines) and text scale
(1.0, 1.15, 1.3, 1.5, 1.8, 2.0), it answers *fits*, *cut by maxLines*, *a word wider than the box* (Flutter breaks it
inside), or *Flutter must decide*. `flutter_bench/test/overflow_truth_test.dart` lays every case out with a
`TextPainter` configured as a `Text`, and compares.

**Result** (`flutter_bench/results/ideas_overflow_truth_macos.json`, `ideas_overflow_check_apple.json`).
- 2,875,608 cases in 327 ms of plain Dart (0.11 µs per case).
- 2,869,810 decided (99.8%), 0 different from Flutter. The other 5,798 go back to Flutter: words within 0.011 px of
  the box (Flutter floors widths to 1/100 px), and strings with characters the sidecar does not certify.
- 489,018 cases have a word wider than the box; in every one Flutter cuts the text (480,804) or breaks the word on a
  line it shows (25,520 cases; some do both).
- The first run found 3 differences: words 0.008 to 0.0096 px wider than the box, which Flutter's 1/100 px floor lets
  fit. The margin was raised from 0.001 to 0.011 px and the check rerun.

**Limits.** Each string is tried in every slot, so the cut rates are not those of a real app. Predictions are for
Apple platforms (Android and Linux quantize font sizes; the check has a flag for them, not tested against an Android
layout here). Plain text, one font.
