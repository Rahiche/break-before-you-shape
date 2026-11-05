# compose_bench: break-first against Jetpack Compose

The same method as the Flutter package, tested against another framework's own text layout: a sidecar distilled
from Compose's widths, and line breaks predicted before any shaping, compared with what Compose lays out for the
same text. Compose lays text out with Android's `StaticLayout` (Minikin), not SkParagraph, so the line-fit rules are
Minikin's.

| Path | What |
|---|---|
| `app/` | Android harness: runs a job from its files dir through Compose's `TextMeasurer` (which lays text out as the `Text` composable does) and writes the answer. Jobs: `info`, `measure` (widths of one-line strings), `layout` (line starts and heights), `time` |
| `lib/minikin.dart` | Minikin's greedy line breaker (Compose's default) over break-first's width prefix, with the rules below |
| `tool/job.sh` | Runs one job on the connected emulator |
| `tool/compose_check.dart` | Exactness: distils a sidecar per pixel size from Compose's widths, then checks every line break of the corpora |
| `tool/speed.sh`, `tool/compose_speed.dart`, `speed_app/` | Timing on the emulator: Compose's `TextMeasurer` against break-first for the heights of a chat list |
| `results/` | `compose_exactness.json`, `compose_speed.json` |

## What Compose does, as measured here

Android 15 emulator (API 35, arm64), Compose BOM 2026.09.00 (ui-text 1.12.1), Roboto from the app's assets.

- **Line breaking** is greedy: `TextStyle.Default.lineBreak` is unspecified, which resolves to `LineBreak.Simple`, and
  hyphenation is off.
- **Text is hinted.** Every advance is a whole pixel and every kern a multiple of 1/256 px, in all 1,636,020 widths
  measured at six sizes. Widths are therefore not linear in the font size, and a Compose sidecar holds one pixel size.
  At 64 units per pixel it stores both exactly. A line's width is a sum of such values, exact in float32 below
  2^24 / 256 = 65,536 px.
- **No kerning across a space.** Minikin shapes the text word by word, splitting at spaces. The sidecar measures that
  through Compose, so it needs no special case.
- **A kern belongs to the first character of its pair**, in Minikin's per-character widths as in break-first's prefix.
  A break with no space at it (after a slash) therefore needs no correction.
- **No break after a hyphen-minus or an en dash inside a word** ("invalid-|operation", "1983–|2025"), where UAX #14
  and Flutter allow one. Minikin keeps those breaks for hyphenation, which is off. Text with Minikin's other
  line-breaking hyphens goes back to Compose: they are not measured.
- **Email addresses and URLs** (an `@`, or `://`) get Minikin's own break rules. Such text goes back to Compose.
- **A line fits** when its width, without trailing spaces, is not greater than the box, which is a whole number of
  pixels (`ceil(maxWidth)`).
- **Height** is lines × one line's height (19 px at 16 px). A line with a character from a fallback font is taller,
  and break-first hands back text the sidecar's font does not have.

## Reproduce

```sh
cd compose_bench
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleRelease && adb install -r app/build/outputs/apk/release/app-release.apk
flutter pub get
CACHE_DIR=/tmp/compose_widths dart run tool/compose_check.dart results/compose_exactness.json 1000
CACHE_DIR=/tmp/compose_widths tool/speed.sh 42.0 735
```

The corpora come from `flutter_bench/tool/prepare_assets.sh`, as for the Flutter benchmarks.
