## 0.3.0

- `LineOptions.strutStyle` and `textHeightBehavior` (heights from three probe layouts per style).
- Font features: `fontFeatures` in `buildSidecar` and `BreakFirst.load`, with certify.py's `CERTIFY_FEATURES_ON`.
- Rich text: `RichParagraph` and `RichSpan`, spans in several fonts and sizes, with bundled fallback fonts
  (sidecars now record the font's cmap).
- Combining marks: compositions, zero-width marks and kerning across them, from the certificate (class M).
- Emoji and Brahmic scripts from the device's fallback fonts, measured once per run; `height` uses this before
  laying a paragraph out with Flutter.
- Thai, Lao, Khmer and Burmese: ICU's dictionary line breaks ported to Dart (`dictionaryBreaks`, the dictionaries
  ship as package assets); runs from the device's fonts are measured once, like Brahmic text.
- The sidecar build bounds its island tables: when the islands times the safe characters pass 2.5 million
  measurements (`WidthModel.distill(islandBudget:)`), the island bound drops below the certificate's, and longer runs
  of island characters go to Flutter. Script faces with many ligatures built for hours before.
- Fixes: the hard-break calibration probes the character with the largest kern against a space; font-size calibration
  works without canary strings.

## 0.2.0

- Hard line breaks, letter spacing (both signs), word spacing, the height multiplier and `maxLines` (`LineOptions`),
  each measured against Flutter and tested.
- The sidecar optionally carries tables for text without ligatures (`buildSidecar(noLigaCertificate: ...)`).
- LB20a applies to the hyphen and en dash only (Flutter breaks after a word-initial `|`).

## 0.1.0

- First version: `BreakFirst` (load, height, lineStarts, prepare), `buildSidecar`, the width model and line-break tables.
