# Break-first layout: line breaks before shaping

**Idea in one sentence:** compile the shaper's behaviour for a font into a tiny, exact, *local* width model ahead of time ("distillation"). Line breaking then needs no shaping at all: one SIMD-friendly pass over the text gives every candidate line's width in O(1), with a per-decision error bound that tells you when (rarely) you must shape. Shaping and glyph positioning move *after* breaking, run once per line, and can be lazy.

```
today:        itemize → SHAPE paragraph → break on shaped advances → RESHAPE lines at breaks → position
break-first:  itemize → BREAK (model only, ~2 ns/char) → shape each line once, only when it's drawn → position
```

Prototype: [bfl.c](bfl.c) (C + HarfBuzz 15 + NEON, about 930 lines). Raw results: [results.txt](results.txt). Tables: [table.py](table.py).

---

## 1. Why this is normally considered impossible

Line breaking needs widths. Widths come from shaping: kerning, ligatures and contextual forms make `width(A+B) != width(A)+width(B)`. In the general case shaping is Turing-complete, so a line's width "can be any function" of its text (Raph Levien, *Text layout is a loose hierarchy of segmentation*). Engines therefore shape first and then either:

- break on the shaped advances and accept small errors where context is cut at a line boundary (Firefox has shipped bugs from this),
- reshape around each break, which HarfBuzz's `UNSAFE_TO_CONCAT` flag is designed to make cheaper, or
- measure per word and lose cross-word context (Android/Minikin, Pretext, most JS text measurers).

## 2. The observation that makes it possible

For real fonts and real text, shaping is **local in width**. Even when it changes glyphs, a width effect almost never reaches beyond a window of 2–4 characters. That gives the width a simple exact form:

```
width(text) = Σ adv(cᵢ)                       unigram advance
            + Σ d(cᵢ₋₁, cᵢ)                   pair delta: kerning, 2-char ligatures
            + Σ r₃(cᵢ₋₂..cᵢ), r₄(cᵢ₋₃..cᵢ)    sparse residuals, only around glyph-changing pairs
```

Measured, not assumed: in 14 of the 15 macOS fonts tested, this form reproduced HarfBuzz's shaped width **to the font unit** on every line, about 2 million lines in all.

## 3. The method

### 3.1 Distillation: use the shaper as a black-box oracle (once per font, offline)

Don't parse GSUB/GPOS/morx/kerx. Ask the shaper:

1. Shape every character in the repertoire alone → `adv(c)`.
2. Shape every pair → `d(a,b) = W(ab) − adv(a) − adv(b)`. Mark the pair *glyph-changing* if the glyphs differ from the singles (a ligature or contextual form).
3. Around each glyph-changing pair, shape all 3-grams `x a b` and `a b x` → residual `r₃`. Do the same for 4-grams where two glyph-changing pairs interact (`f f i`). Store only nonzero values.
4. Probe for anything the model still misses: 300K random 3-grams, 150K random 4-grams, and every dictionary word (`/usr/share/dict/words` plus punctuated variants, about 295K probes). Every miss sets an **error bound** `eps` on each pair inside the probe.
5. Compress the pair matrix. Rows and columns that are identical (delta, glyph-changing flag, eps) collapse into first- and second-position classes. This recovers the font's own kerning classes even from a black box. Each codepoint then packs into a 64-bit record: `adv | id | second-class | first-class row offset | break category`.

Because the oracle *is* the shaper, the model inherits whatever the shaper does: OpenType, AAT, `kern` tables, feature defaults, even shaper quirks. Swap HarfBuzz for CoreText or DirectWrite and you distill that one instead.

### 3.2 Break: three passes, no shaping

- **Pass A, width prefix:** `P[i] = model width of t[0..i)`. Per character it does one record load, one pair-matrix load and a few ALU ops, with no branches or calls on the common path. All-ASCII 16-byte blocks run at a fixed stride, so the loop never waits on a byte load to know where the next character starts. Rare events are queued as *patches* and folded in later: glyph-changing pairs, pairs with a nonzero `eps`, and characters outside the model.
- **Pass B, break opportunities:** found 64 bytes at a time with NEON bitmasks. Each opportunity becomes a record `{lineEnd, P(lineEnd), nextStart, Pstart(nextStart)}`. Here `Pstart` is the width origin for a line that starts at that point. It is `P(next)` minus every term that straddles the line start (the pair delta and residuals reaching back across it). Width is therefore a monoid with boundary correction, and **any candidate line's width is `P(end) − Pstart(start)`, O(1), exactly as if that line had been shaped on its own.** Context lost at a line start is modelled; there is nothing to reshape.
- **Pass C, decisions:** greedy (Knuth–Plass would use the same O(1) widths). Each decision carries an interval `[w − u, w + u]`, where `u` is the sum of the `eps` values in the line. If `W` is outside the interval, the decision is **certified**. If not, *hybrid* mode shapes just that one candidate line.

Passes A and B don't depend on the line width. Keep their records and a **resize only reruns pass C**.

## 4. Results

Corpus: 5,170 English prose paragraphs (0.9 MB, docstrings from the Python standard library), at six line widths from 9.5 to 41 em. **Ground truth** is exact greedy breaking that reshapes every candidate line with HarfBuzz (direct, no cache), using the same break-opportunity rules for every method. Machine: Apple M3, one core.

**Accuracy** (share of paragraphs whose breaks equal ground truth)

| Font | glyph-changing pairs / width residuals | model KB | distill s | model widths exact | break-first | hybrid (decisions shaped) | shape-first | word cache |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| Helvetica | 2 / 2 | 6.8 | 0.43 | 100% | 100% | 100% (0.000%) | 99.932% | 99.268% |
| Helvetica Neue | 3 / 4 | 7.2 | 0.40 | 100% | 100% | 100% (0.000%) | 100% | 100% |
| System Font | 13294 / 275 | 81.4 | 12.02 | 100% | 100% | 100% (0.004%) | 99.468% | 96.441% |
| New York | 15 / 0 | 21.8 | 0.56 | 100% | 100% | 100% (0.000%) | 99.994% | 99.965% |
| Avenir Next Bold | 2 / 0 | 23.4 | 0.42 | 100% | 100% | 100% (0.000%) | 99.458% | 97.682% |
| Palatino | 2 / 2 | 5.9 | 0.42 | 100% | 100% | 100% (0.000%) | 99.987% | 99.684% |
| Georgia | 0 / 0 | 3.6 | 0.23 | 100% | 100% | 100% (0.000%) | 100% | 100% |
| Times New Roman | 0 / 0 | 6.9 | 0.41 | 100% | 100% | 100% (0.004%) | 99.939% | 99.31% |
| Baskerville | 2 / 3 | 16.5 | 0.67 | 100% | 100% | 100% (0.000%) | 99.626% | 94.61% |
| Hoefler Text | 14 / 109 | 15.1 | 0.52 | 100% | 100% | 100% (0.000%) | 99.894% | 98.897% |
| Charter Roman | 0 / 0 | 7.5 | 0.29 | 100% | 100% | 100% (0.000%) | 100% | 99.987% |
| Didot | 2 / 0 | 9.7 | 0.50 | 100% | 100% | 100% (0.000%) | 99.594% | 94.72% |
| Gill Sans | 2 / 2 | 9.1 | 0.39 | 100% | 100% | 100% (0.000%) | 98.839% | 90.358% |
| Futura Medium | 2 / 14 | 29.6 | 0.48 | 100% | 100% | 100% (0.052%) | 100% | 99.994% |
| Zapfino | 31 / 579 | 30.0 | 1.15 | 77.2688% | 85.048% | 99.994% (13.473%) | 97.927% | 85.048% |

**Speed** (ns per byte of UTF-8 input, one M3 core)

| Font | break-first | shape-first (no reshape) | warm word cache | rewrap (pass C only) | vs shape-first |
|---|--:|--:|--:|--:|--:|
| Helvetica | 1.89 | 56.0 | 4.0 | 0.265 | 30x |
| Helvetica Neue | 1.96 | 51.9 | 4.1 | 0.267 | 26x |
| System Font | 1.72 | 87.4 | 4.1 | 0.301 | 51x |
| New York | 1.64 | 59.8 | 4.0 | 0.249 | 36x |
| Avenir Next Bold | 1.90 | 52.9 | 4.0 | 0.282 | 28x |
| Palatino | 1.94 | 57.4 | 4.0 | 0.263 | 30x |
| Georgia | 1.62 | 16.3 | 4.1 | 0.263 | 10x |
| Times New Roman | 1.75 | 32.0 | 4.0 | 0.264 | 18x |
| Baskerville | 1.87 | 92.0 | 4.0 | 0.248 | 49x |
| Hoefler Text | 1.93 | 81.2 | 4.0 | 0.271 | 42x |
| Charter Roman | 1.68 | 21.9 | 4.1 | 0.264 | 13x |
| Didot | 1.89 | 73.8 | 4.1 | 0.281 | 39x |
| Gill Sans | 1.89 | 56.0 | 4.0 | 0.251 | 30x |
| Futura Medium | 2.60 | 65.8 | 4.3 | 0.596 | 25x |
| Zapfino | 191.32 | 199.5 | 4.1 | 197.258 | 1x |

Reading the tables:

- **Exactness.** In 14 of 15 fonts the pure model's line widths equal HarfBuzz's to the font unit on every line checked, about 2.1 million in all. Its breaks equal ground truth on 100% of paragraphs. That is *more* accurate than the usual shape-once-then-break path (98.8–100%), which carries line-boundary context errors. It is also more accurate than a per-word cache (90–100%), which drops kerning across spaces. None of the decisions the model certified in these fonts was wrong.
- **Zapfino** is the adversarial case: AAT `morx` with long contextual swashes. Only 77% of the pure model's line widths are exact, and its breaks match on 85% of paragraphs. Dictionary probes catch this: 234 of 295K words mismatch, which leaves nearly every common pair with a nonzero error bound. Hybrid mode then shapes 13.5% of decisions, matches ground truth on 99.994% of paragraphs, and runs at about shaping speed. The method degrades into shaping instead of being silently wrong.
- **Speed.** 1.6–2.6 ns per byte (380–620 MB/s), against 16–92 ns for shape-first. That is 10–51x faster, and the shape-first figure is already a lower bound: it skips the reshape a correct engine needs, and HarfBuzz is cheap on Georgia and Charter only because it applies no kerning there. A warm per-word cache costs about 4 ns and needs every word shaped once beforehand.
- **Resize.** Records don't depend on the width, so **rewrapping at a new width costs 0.25–0.3 ns per byte: about 0.25 ms for the whole 0.9 MB corpus.** Futura is slower (0.6 ns) because a quarter of its lines carry an error bound.
- **Cost.** Distillation takes 0.2–1.2 s per font. San Francisco takes about 12 s because 13,294 pairs change glyphs (only 275 of those need a width residual). Models are 4–81 KB and are computed once per font file, so they can be cached or shipped with the font.

## 5. What is new, and what is not

Prior art, honestly:

| Work | What it does | Difference |
|---|---|---|
| TeX TFM lig/kern programs (1980s) | Per-font automaton giving kerns and ligatures between character pairs; widths without a shaper | Hand-authored or converted from AFM; no contextual forms; no error bounds. The closest ancestor: this is "TFM, automatically distilled from a modern shaper" |
| AFM width + KPX pairs (PDF libraries) | Sum advances plus pair kerns | Pair-only; ignores GSUB/morx entirely |
| WebKit simple text path | Skips the complex shaper for "simple" text | Only valid when kerning and ligatures are *off* |
| Minikin LayoutCache, Pretext | Shape or measure each word once, cache it, break with arithmetic | Still shapes every unique word; drops cross-word context; needs warm-up |
| HarfBuzz `UNSAFE_TO_CONCAT` | Makes reshaping after breaking cheaper | Still shape → break → partial reshape |
| `typeset` (2026) | Advances + pair kerning from font tables, prefix sums, HarfBuzz fallback for ligatures and complex scripts | Table-parsing, pair-only; no contextual residuals, no line-start correction, no per-decision certificate |

What I did **not** find anywhere, and what this prototype adds:

1. **Distilling the shaper itself** (black-box queries) into an exact k-gram width model that covers ligatures and contextual forms. It is format-agnostic and matches the target shaper by construction.
2. **Line-start-corrected prefix widths**, so every candidate line costs O(1) and equals that line shaped on its own. No reshaping, and more accurate than shape-once.
3. **Certified break decisions.** A static analysis of the font's layout tables proves the model exact on almost every line (§6). The shaper runs only on lines the proof does not cover, not on whole paragraphs or whole fonts.
4. **Pipeline inversion.** Break before shaping, then shape lazily per line. Width-independent records make resizing almost free.

## 6. A provable certificate

The error bounds in §4 come from probing, and probing can miss a context. With random n-gram probes alone, Zapfino had 41,802 wrongly "certified" lines ([results_random_probes_only.txt](results_random_probes_only.txt)). Even with dictionary probes, one certified line was wrong. So the error bounds are replaced by a certificate derived from the font's tables.

### The claim

[certify.py](certify.py) reads GSUB/GPOS/GDEF, `morx`, `kern` and `kerx` and sorts each repertoire character into one of four classes:

- **S**: safe;
- **P**: a primer, which can start a substitution;
- **K**: passive, which can only be consumed by one;
- **U**: unsafe.

[bfl.c](bfl.c) then picks the largest island bound m that passes an exhaustive check (below).

> **Theorem.** Let w be a string with no U character, in which every maximal P/K run that contains a P has at most m characters. Then HarfBuzz's shaped width of w equals the distilled model's width of w, exactly.

### Why it holds

1. **S glyphs are never substituted, and every P/K run is closed** (its output glyphs depend only on the run).
   - *OpenType.* A single, multiple or alternate lookup can fire only at its coverage glyphs, so those characters are U. A contextual rule can fire only if *every* position matches a glyph that can actually occur. A rule with an impossible position is dropped. For any other rule, the characters at its cheapest position (weighted by English letter frequency) become U, so the rule cannot match on any certified line. Ligatures start only at P and consume only P/K glyphs. A ligature counts only if all of its components can occur.
   - *AAT `morx`.* The analyzer explores every state reachable over the alphabet. A subtable whose actions are unreachable is the identity; this removes, for example, composition machines that wait for combining marks. In the remaining subtables, from every reachable state an S class performs no substitution and returns to a start state, either directly or by a pure `DontAdvance` reset. The two start states agree on island classes and on end of text. End of text never acts after an island. A bounded exhaustive check over every run of up to m island glyphs shows that no ligature action pops a component, and no contextual action uses a mark, that was set before the run. Context-free noncontextual substitutions are tracked as a per-character glyph map.
2. **Positioning is pair-additive** on every glyph that can occur. That means SinglePos, PairPos with ValueFormat2 = 0 (a nonzero second value makes HarfBuzz skip the next pair), or `kern` format 0. Cursive, mark and contextual positioning, and lookups that skip base glyphs or ligatures, make the affected characters U.
3. By 1 and 2, the shaped width is a sum of advances and pair adjustments over the output glyph string. In that string, S characters keep their glyphs and each run is replaced by its own output. So the width splits into terms over windows `{c}`, `{c c'}`, `I`, `xI` and `Iy`. Each window holds at most one run plus its immediate S neighbours.
4. The model splits the same way. bfl checks that no residual term reaches across an S character into a second run, spans a run with S on both sides, or lives on S characters alone. Unigram and pair terms equal HarfBuzz by construction (every pair was shaped). For every island I with |I| ≤ m and every S neighbour x and y, bfl shapes I, xI and Iy and compares each with the model. If any check fails, m shrinks. ∎

### What the proof trusts

- That HarfBuzz implements these OpenType and AAT semantics: coverage-gated lookups, the ValueFormat2 skip, and the AAT driver's end-of-text and `DontAdvance` rules.
- That fontTools parses the tables correctly.
- About 600 lines of analyzer and checker code, which are tested but not machine-verified.
- In the default `hb` mode, that HarfBuzz selects lookups as assumed: script `latn`, language `ENG` or the default language system, default variation coordinates, and the AAT selectors for `rlig`/`liga`/`clig`/`calt`. The strict `all` mode drops this assumption by taking every script, language system, feature variation and ligature selector.

### Results

Same corpus and widths as §4. Hybrid mode now certifies with the static certificate only, and every certified line's width is compared with HarfBuzz directly.

| Font | S / P / K / U | islands checked (m, shapes) | lines certified | certified but wrong | hybrid breaks = truth (decisions shaped) | ns/char |
|---|--:|--:|--:|--:|--:|--:|
| Helvetica | 557 / 1 / 2 / 1 | 4 (100,350) | 99.98% | 0 | 100.000% (0.019%) | 2.57 |
| Helvetica Neue | 559 / 1 / 2 / 1 | 3 (29,094) | 99.86% | 0 | 100.000% (0.128%) | 2.99 |
| System Font | 460 / 1 / 0 / 20 | 4 (3,684) | 96.12% | 0 | 100.000% (3.160%) | 20.20 |
| New York | 451 / 0 / 0 / 3 | 4 (0) | 95.99% | 0 | 100.000% (3.268%) | 14.21 |
| Avenir Next Bold | 435 / 1 / 2 / 1 | 4 (78,390) | 99.98% | 0 | 100.000% (0.016%) | 2.70 |
| Palatino | 457 / 1 / 2 / 1 | 4 (82,350) | 99.98% | 0 | 100.000% (0.019%) | 2.58 |
| Georgia | 453 / 0 / 0 / 1 | 4 (0) | 100.00% | 0 | 100.000% (0.000%) | 2.11 |
| Times New Roman | 556 / 0 / 0 / 1 | 4 (0) | 100.00% | 0 | 100.000% (0.000%) | 2.24 |
| Baskerville | 567 / 1 / 2 / 1 | 4 (102,150) | 99.98% | 0 | 100.000% (0.021%) | 2.54 |
| Hoefler Text | 300 / 2 / 7 / 1 | 3 (484,406) | 99.24% | 0 | 100.000% (0.673%) | 5.92 |
| Charter Roman | 424 / 0 / 0 / 0 | 4 (0) | 100.00% | 0 | 100.000% (0.000%) | 2.23 |
| Didot | 345 / 1 / 2 / 1 | 4 (62,190) | 99.98% | 0 | 100.000% (0.019%) | 2.56 |
| Gill Sans | 230 / 1 / 2 / 1 | 4 (41,490) | 99.98% | 0 | 100.000% (0.021%) | 2.54 |
| Futura Medium | 335 / 1 / 2 / 1 | 4 (60,390) | 99.98% | 0 | 100.000% (0.019%) | 2.56 |
| Zapfino | 0 / 0 / 0 / 342 | 4 (0) | 0.00% | 0 | 100.000% (100.000%) | 776.70 |

- **No certified line is wrong in any font:** about 2.2 million lines, six widths, 15 fonts. With the shaper as fallback, breaks match ground truth on 100% of paragraphs in every font, Zapfino included.
- **Coverage.** 99.2–100% of lines are certified in 12 fonts with no empirical bound at all. SF and New York reach 96%: their contextual alternates make `:` unsafe, and these docstrings are full of colons. Zapfino gets no certificate (end of text acts after its islands), so every decision is shaped. It is correct, but slower than shape-first, because the prototype reshapes each candidate line. A paragraph-level fallback to shape-once would fix that.
- **Cost.** The analysis takes about 1 s per font. The island check takes under 0.4 s and at most about 0.5M shapes in default mode (about 5M in strict mode). Where coverage is about 100%, the breaker runs at 2.1–3.0 ns/char in proven mode.

Strict mode (no lookup-selection assumption), on the 7 fonts whose certificate changes:

| Font | S / P / K / U | islands checked (m, shapes) | lines certified | certified but wrong | hybrid breaks = truth (decisions shaped) | ns/char |
|---|--:|--:|--:|--:|--:|--:|
| System Font | 453 / 1 / 0 / 27 | 4 (3,628) | 18.37% | 0 | 100.000% (73.587%) | 607.00 |
| New York | 445 / 0 / 0 / 9 | 4 (0) | 95.99% | 0 | 100.000% (3.268%) | 14.25 |
| Avenir Next Bold | 428 / 4 / 4 / 3 | 4 (3,719,380) | 99.76% | 0 | 100.000% (0.223%) | 3.29 |
| Georgia | 450 / 0 / 0 / 4 | 4 (0) | 100.00% | 0 | 100.000% (0.000%) | 2.31 |
| Times New Roman | 555 / 0 / 0 / 2 | 4 (0) | 100.00% | 0 | 100.000% (0.000%) | 2.39 |
| Baskerville | 562 / 4 / 4 / 1 | 4 (4,882,500) | 98.54% | 0 | 100.000% (1.173%) | 11.01 |
| Hoefler Text | 298 / 4 / 7 / 1 | 3 (635,208) | 84.13% | 0 | 100.000% (13.541%) | 69.70 |

Strict mode stays sound: no certified line is wrong there either. It costs coverage where the assumption matters. For SF, other language systems' `locl` substitutions touch common lowercase letters, which drops coverage to 18%. Hoefler and its rare-ligature selectors drop to 84%. The other five fonts barely change.

## 7. Inside Flutter

Does it hold in a real app, against Flutter's own text stack? [flutter_bench/](flutter_bench/) is a macOS Flutter app (Flutter 3.47.5, release build, Apple M3) using Roboto Regular at 16 px on the same 5,170-paragraph corpus.

- **The sidecar is built through Flutter.** [width_model.dart](packages/break_first/lib/src/width_model.dart) measures every character, every pair and every certificate island (with each safe neighbour) using `ui.Paragraph`. That takes 198K layouts and 2.6 s, once per font and size. The tables therefore match Flutter's bundled HarfBuzz by construction. The file is 800 KB of dense float32 (11 KB gzipped).
- **It follows Flutter's conventions, which were measured rather than assumed.** SkParagraph shapes once and breaks on the shaped advances, so kerning belongs to the left glyph. It fits lines up to **+0.01 px** over the width: accepted +0.0094, rejected +0.0109. Break opportunities follow UAX #14 for ASCII, with Unicode 15.1's LB25 number rules plus IS × NU. These were checked class by class against 417K Flutter lines.
- **One behaviour stays deferred.** Inside an unbreakable segment, SkParagraph sometimes breaks at a space that UAX #14 forbids, such as before `!=` or `/path`. When such a space could end a line, the breaker hands the paragraph to Flutter instead of guessing. So do words wider than the line, which Flutter splits mid-word.

| Check (25 widths, 150–671 px) | Result |
|---|---|
| Single-line width, model vs Flutter | **0.0 px** maximum difference |
| Line breaks identical to Flutter's | **127,440 / 127,440** paragraph layouts (535,338 lines) |
| Deferred to Flutter | 1.27% (mostly at 150 px: words wider than the line) |

| Release timing, all 5,170 paragraphs | Flutter | break-first (fallbacks included) | Speedup |
|---|---|---|---|
| Layout to line counts at 400 px (`TextPainter`) | 296.7 ms | 14.2 ms | **20.9x** |
| Same, against bare `ui.Paragraph` | 288.3 ms | 14.2 ms | **20.3x** |
| Re-wrap at a new width (paragraphs already laid out) | 91.3 ms | 2.0 ms | **45.8x** |

This covers layout only: the line breaks and heights a list or a measurement needs. Painting is unchanged, and visible lines still go through Flutter to be drawn. The Dart breaker runs at 16 ns per code unit, against 2 ns for the C version, so there is headroom. It covers one font, one size, ASCII/Latin English, plain styles, LTR, on macOS.

## 8. Limitations and next steps

- **The certificate covers what the analyzer understands.** Unsupported `morx` subtable types (rearrangement, insertion), `kerx`, and `kern` formats other than 0 make characters U. None of these fonts needed them. A larger font survey would show how often they appear in practice.
- **Scope of the prototype.** Latin only, a simplified UAX #14 (spaces and hyphens), and no font fallback, bidi, variable-font axes or hinting. How each would extend:
  - *Full UAX #14:* table-driven, so it fuses into pass B.
  - *Font fallback:* it is decided by cmap, so it is pre-shaping too; fold the font choice into the codepoint record.
  - *Bidi:* breaking happens in logical order before reordering, as UAX #9 already specifies.
  - *Variable fonts:* advances and GPOS values are linear blends of master deltas, so distill per master and blend.
  - *Hinting:* distill at the target ppem.
- **Other scripts.** Arabic joining is deterministic from Unicode `Joining_Type`, so it is still local: distill per joining form. Indic needs syllable-level entries (orthographic syllables are bounded and repeat heavily). CJK is mostly fixed-advance. Thai, Lao and Khmer need dictionary segmentation for *opportunities*, but their widths stay local.
- **Where it pays off most:** heights for virtualized lists and chat UIs without shaping anything off-screen, live re-wrap on resize, server-side and PDF layout, and JS text measurement that is exact without `measureText`.

## 9. Reproduce

```bash
python3 make_corpus.py corpus.txt
clang -O3 -mcpu=apple-m3 -I/opt/homebrew/opt/harfbuzz/include/harfbuzz -L/opt/homebrew/opt/harfbuzz/lib -lharfbuzz bfl.c -o bfl
./bfl corpus.txt /System/Library/Fonts/Helvetica.ttc:0 "/System/Library/Fonts/Supplemental/Zapfino.ttf"
# Flutter: exactness under flutter_tester, then timing in a release build
(cd flutter_bench && flutter test test/exactness_test.dart)
(cd flutter_bench && flutter build macos --release && BF_OUT=$PWD/results_release.txt build/macos/Build/Products/Release/bf_bench.app/Contents/MacOS/bf_bench)
# provable mode: needs fontTools for the analyzer
python3 certify.py /System/Library/Fonts/Helvetica.ttc:0 helvetica.cert 4 hb    # or "all" for strict
./bfl corpus.txt "/System/Library/Fonts/Helvetica.ttc:0@helvetica.cert"
```
