## 0.2.0

- Hard line breaks, letter spacing (both signs), word spacing, the height multiplier and `maxLines` (`LineOptions`),
  each measured against Flutter and tested.
- The sidecar optionally carries tables for text without ligatures (`buildSidecar(noLigaCertificate: ...)`).
- LB20a applies to the hyphen and en dash only (Flutter breaks after a word-initial `|`).

## 0.1.0

- First version: `BreakFirst` (load, height, lineStarts, prepare), `buildSidecar`, the width model and line-break tables.
