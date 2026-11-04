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
- Common characters by script: certify.py lists, per script whose lookups differ from the main script's, the
  Common characters and pairs those lookups can change (`# script` lines); the breaker hands them to Flutter in a
  run of that script, and when a run of Common characters alone (DFLT) differs, the build measures them next to a
  letter of the main script. Euphemia UCAS's space is 1,030 units alone and 608 in Latin text.
- A hard break kerns like a space with the character after it too: with split kerning (`kern` tables), the next
  line's first glyph keeps its share (Arial Narrow, Chalkduster, Times New Roman, spaced text after `\n`).
- Rich text: scripts are itemized within each span of one style (measured: Common characters next to a letter in
  another size keep script Common), across its fallback fonts.
- Fixes: the hard-break calibration probes the character with the largest kern against a space; font-size calibration
  works without canary strings.

## 0.2.0

- Hard line breaks, letter spacing (both signs), word spacing, the height multiplier and `maxLines` (`LineOptions`),
  each measured against Flutter and tested.
- The sidecar optionally carries tables for text without ligatures (`buildSidecar(noLigaCertificate: ...)`).
- LB20a applies to the hyphen and en dash only (Flutter breaks after a word-initial `|`).

## 0.1.0

- First version: `BreakFirst` (load, height, lineStarts, prepare), `buildSidecar`, the width model and line-break tables.
