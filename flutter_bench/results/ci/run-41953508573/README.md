# The mismatch GitHub's Linux runner found

Run [41953508573](https://github.com/Rahiche/break-before-you-shape/actions/runs/41953508573) of `bench.yml`, 2026-11-05, on 5f441fb. [linux_styles.json](linux_styles.json) has 2 different layouts with `letterSpacing 0.5`, both in the runner's Greek strings at a box 9 × the font size:

- 12 px, 108 px box: `children=PATTERN` is 108.0078 px wide. Flutter breaks it inside (`--table-and-childre|n=PATTERN`); the breaker moved it to the next line whole.
- 13 px, 117 px box: `current_schemas()` is 117.0068 px wide. Flutter: `της current_sche|mas()`; the breaker: `της |current_schemas()`.

SkParagraph floors a line's width to 1/100 px before the fit test, but tests a word for "too long" against the box without the floor. A word up to 0.01 px wider than the box fits a line of its own, yet Flutter breaks it inside, on the line before. Fixed in bfd026c: the breaker and the C port hand such paragraphs to Flutter, and `packages/break_first/test/break_first_test.dart` checks constructed words of this kind. The other jobs of this run are superseded by [run 41971344191](../run-41971344191), on the fix.
