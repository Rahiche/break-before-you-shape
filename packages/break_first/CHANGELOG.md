## 0.3.0

- `LineOptions.strutStyle` and `textHeightBehavior` (heights from three probe layouts per style).
- Font features: `fontFeatures` in `buildSidecar` and `BreakFirst.load`, with certify.py's `CERTIFY_FEATURES_ON`.
- Rich text: `RichParagraph` and `RichSpan`, spans in several fonts and sizes, with bundled fallback fonts
  (sidecars now record the font's cmap).
- Combining marks: compositions, zero-width marks and kerning across them, from the certificate (class M).
- Emoji and Brahmic scripts from the device's fallback fonts, measured once per run; `height` uses this before
  laying a paragraph out with Flutter.
- Fixes: the hard-break calibration probes the character with the largest kern against a space; font-size calibration
  works without canary strings.

## 0.2.0

- Hard line breaks, letter spacing (both signs), word spacing, the height multiplier and `maxLines` (`LineOptions`),
  each measured against Flutter and tested.
- The sidecar optionally carries tables for text without ligatures (`buildSidecar(noLigaCertificate: ...)`).
- LB20a applies to the hyphen and en dash only (Flutter breaks after a word-initial `|`).

## 0.1.0

- First version: `BreakFirst` (load, height, lineStarts, prepare), `buildSidecar`, the width model and line-break tables.
