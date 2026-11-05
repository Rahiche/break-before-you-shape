# Break-first inside the engine: what would change in Flutter, Android, Chrome and Apple text pipelines

> **What this is.** A reading of the text engines' source code and specs, made to answer one question: what would change
> if an engine broke lines *before* shaping, inside its own pipeline? Labels: **[C]** is read in source or a spec (file
> and function cited), **[H]** is a hypothesis to be measured. There are no timings here. Section 9 lists the
> experiments that would measure the hypotheses.
>
> **Measured since** (`compose_bench/`, paper §5.8). Three of the Compose hypotheses below are now measurements:
> - Compose's default line breaking is greedy (`LineBreak.Simple`).
> - With hinting on, every advance is a whole pixel and every kern a multiple of 1/256 px, so a Compose sidecar holds one
>   pixel size.
> - Minikin never kerns across a space, and a model distilled through Compose's own widths captures that with no special
>   case.
>
> With those rules, and Minikin's no-break-after-hyphen and email/URL rules, break-first matched Compose in all 301,420
> layouts it decided.


Research report, 2026-11-05. It is grounded in source code and specs. It contains no performance numbers of its own.

## 0. Method, versions, labels

**Labels used throughout**

- **[C]**: confirmed in source code or a spec. A file/function or spec section is cited next to it.
- **[C-3p]**: confirmed only by a third-party report (a blog post or forum thread). It is weaker than [C].
- **[H]**: hypothesis, to be measured. Every performance claim in this report is [H] unless a source states it qualitatively. When a source does, the claim is labeled [C] and quoted. Where this report shows numbers, they are constants read from source code (cache sizes, line limits) or from specs. None of them is a timing.

**Source snapshots read** (raw files fetched on 2026-11-05):

| Repo | Ref | Commit |
|---|---|---|
| google/skia (`modules/skparagraph`, `modules/skshaper`, `src/ports`) | `main` | `7a5d888b0449` |
| flutter/flutter (framework + `engine/src/flutter`) | `master` | `53bff0892986` |
| androidx/androidx (Compose ui-text, foundation, material3) | `androidx-main` | `a6a6dfbfb81d` |
| AOSP `platform/frameworks/minikin` | `main` | `05a978c36b4c` (public snapshot dated 2025-03-08) |
| AOSP `platform/frameworks/base` | `main` | `1cdfff555f4a` (public snapshot dated 2025-03-26) |
| chromium/src (Blink) | `main` | `c89ebf719d4a` |

Caveat: the shipped Flutter stable, the Compose BOM and the Android emulator image will lag these heads. The AOSP public `main` is older than the other repos. Check the exact versions on the test devices before relying on a line-level detail.

**What break-first is** (given by the project, treated as fact): a per-font width model, plus a certificate (S/P/K/U classes from `certify.py`) that proves on which lines the model width equals the shaped width. Line breaks and heights then come from prefix sums before any shaping. Uncertified text is handed back to the engine.

---

## 1. Ranked summary of candidate gains

The ranking is the author's judgement of likely value. It is a hypothesis.

| Rank | Gain | Verdict after reading source | Engines where it matters most |
|---|---|---|---|
| 1 | Shape only visible lines (lazy shaping), plus exact sizes for content the engine skips | **Confirmed as a real opportunity.** Every engine studied shapes the whole paragraph (or every word) before or during line breaking. Viewport and skip mechanisms exist but use *estimated* sizes. | Flutter (whole paragraph shaped in `layout()`, every line painted), Blink (`content-visibility`), TextKit 2 |
| 2 | Faster relayout on text-scale / font-size change, and auto-fit | **Refined.** Resize (width only) is already cheap in SkParagraph. A font-size change invalidates shaping everywhere. | Flutter (`ParagraphCache` key includes style), Compose `TextAutoSize`, Minikin (`LayoutCacheKey.mSize`) |
| 3 | Cheap optimal or balanced breaking over prefix sums | **Refined.** Minikin and Blink already run the DP over prefix positions. What costs them is producing the positions (shaping, re-running `LineBreaker`). Chrome caps `pretty` at 4 lines and `balance` at 6. | Blink (lift caps), Flutter (no optimal breaking today) |
| 4 | Correct layout before a web font downloads | **Plausible, but blocked by the spec.** The font-display timeline requires fallback metrics. `size-adjust` is only a uniform multiplier. A model sidecar would need a new platform mechanism. | Chrome / web |
| 5 | Incremental layout while editing | **Refined.** Blink reuses `ShapeResult`s per inline item. Flutter re-creates and reshapes the paragraph on every text change. | Flutter `EditableText`, Blink `contenteditable` |
| 6 | No reshaping at line ends | **Engine-specific.** Only Blink reshapes at line edges. SkParagraph never does. Minikin avoids the need by splitting at spaces. | Blink |
| 7 | Shape lines in parallel once breaks are known | **Possible, but limited by engine threading.** There are no engine hooks today. Flutter's `dart:ui` text is root-isolate only. | All (an engine-internal change) |
| 8 | Replace word caches with a certified model | **Partial.** It only removes the measuring path. Drawing still needs glyphs, so `LayoutCache` stays. | Android/Minikin |

Added gains found while reading (detailed in §7): exact intrinsic widths (min/max-content) without shaping, exact line-count estimates (Blink already *estimates* them with the `ch` unit), and layout off the UI thread for Flutter.

---

## 2. Flutter: SkParagraph, `TextPainter`, `RenderParagraph`

### 2.1 Where shaping happens relative to line breaking

`ParagraphImpl::layout(SkScalar rawWidth)` (`modules/skparagraph/src/ParagraphImpl.cpp`) is a state machine: `kUnknown → kIndexed → kShaped → kLineBroken → kFormatted`.

1. **[C]** If `fState < kShaped`, it first asks `ParagraphCache::findParagraph(this)`. On a miss it runs `computeCodeUnitProperties()`, which computes bidi regions, ICU line-break, grapheme and whitespace flags (`SkUnicode::getBidiRegions`, `computeCodeUnitFlags`). It then runs `shapeTextIntoEndlessLine()`.
2. **[C]** `shapeTextIntoEndlessLine()` builds a `OneLineShaper` and calls `OneLineShaper::shape()`. That function iterates over shaping regions (`iterateThroughShapingRegions`: placeholders × bidi regions) and font-style blocks (`iterateThroughFontStyles`). It calls `SkShapers::HB::ShapeDontWrapOrReorder(...)->shape(..., {.width = limitlessWidth}, this)`, so the whole text is shaped as one endless line. Font fallback is handled by `matchResolvedFonts`, which tries each typeface from `FontCollection::findTypefaces`, then `defaultFallback(...)`, and reshapes the still-unresolved blocks with each one. `applySpacingAndBuildClusterTable()` then builds the cluster table.
3. **[C]** Only then does `breakShapedTextIntoLines(floorWidth)` run. It has a single-run, single-line fast path. Otherwise `TextWrapper::breakTextIntoLines` runs a greedy `lookAhead` that sums `cluster->width()` over the endless-line clusters. Comparisons go through `LineBreakerWithLittleRounding::breakLine` (±0.25 window, then rounding to 0.01).
4. **[C]** `formatLines` aligns and justifies (`TextLine::justify` shifts clusters, with no reshaping).
5. **[C]** Paint: `ParagraphImpl::paint` loops over **all** `fLines` and calls `TextLine::paint`. That calls `ensureTextBlobCachePopulated()`, which builds `SkTextBlob`s lazily *from the already-shaped runs*. No reshaping happens at paint, and lines are not culled at this level. Ellipsis and rendered soft hyphens are the only extra shaping: `TextLine::shapeEllipsis` → `TextLine::ShapeString`, plus `softHyphenWidth()` in `TextWrapper.cpp`.
6. **[C]** SkParagraph does **not** reshape at line ends. HarfBuzz unsafe-to-break flags are read in `SkShaper_harfbuzz.cpp` (`glyph.fUnsafeToBreak = info[i].mask & HB_GLYPH_FLAG_UNSAFE_TO_BREAK`), but nothing in `skparagraph/src` uses them. Line widths are sums of clusters from the paragraph-wide shaping.

**Consequence for exactness [C]:** SkParagraph's line width is "paragraph shaping, sliced at cluster boundaries". This is why a model of advances plus in-line pair kerning matches SkParagraph on certified lines. Kerning that the paragraph shaping applies across a break stays attached to the glyph before the break, usually a trailing space, which is a "ghost".

### 2.2 What is cached

- **[C]** `ParagraphCache` (`ParagraphCache.cpp`): an `SkLRUCache` with `kMaxEntries = 128`, guarded by `fParagraphMutex`. It is keyed by the whole paragraph text plus styles (`ParagraphCacheKey::computeHash`). The value stores `fRuns`, `fClusters` and `fClustersIndexFromCodeUnit`, which is the shaping result, independent of width.
- **[C]** Per-instance stages (`ParagraphImpl.h` member comments): `fRuns // kShaped`; `fClusters // (cached: text, word spacing, letter spacing, resolved fonts)`; `fLines // kFormatted (cached: width, max lines, ellipsis, text align)`. A width change on the same paragraph drops back to `kShaped`: "We can use the results from SkShaper but have to do EVERYTHING ELSE again". `updateFontSize` drops back to `kIndexed`, which means a reshape. `updateTextAlign` keeps `kLineBroken`.
- **[C]** Flutter's `TextPainter.layout` (`packages/flutter/lib/src/painting/text_painter.dart`) reuses the `ui.Paragraph` while only constraints change (`_resizeToFit`, then `paragraph.layout(...)` again). The source comment on the second layout reads: *"This is not as expensive as it seems, line breaking is relatively cheap as compared to shaping."* This is a qualitative [C]. It is the engine authors' own statement that shaping dominates.
- **[C]** Any layout-affecting change (`text`, `textScaler`, style) calls `markNeedsLayout()`, which disposes the paragraph. The next `layout()` calls `_createParagraph`, so the `ParagraphCache` is the only thing that saves a reshape. Even paint-only changes rebuild and relayout the paragraph: *"Unfortunately even if we know that there is only paint changes, there's no API to only make those updates so the paragraph has to be recreated and re-laid out."*
- **[C]** `RenderParagraph` (`rendering/paragraph.dart`) keeps a second `TextPainter` (`_textIntrinsics`) for `computeMinIntrinsicWidth`, `computeMaxIntrinsicWidth`, `computeDryLayout` and `computeDryBaseline`. That is a second `ui.Paragraph` for the same text, which relies on a `ParagraphCache` hit.
- **[C]** Font defaults: `TextStyle` defaults are `fSubpixel = true` and `fHinting = SkFontHinting::kSlight` (`include/TextStyle.h`). The Flutter engine calls `skia.turnHintingOff()`, `setReplaceTabCharacters(true)` and `setApplyRoundingHack(false)` (`engine/src/flutter/txt/src/skia/paragraph_builder_skia.cc`). `hintingIsOn()` is not read anywhere in `skparagraph/src`. On FreeType (Android/Linux), `kSlight` forces `linearMetrics = true` (`SkFontHost_FreeType.cpp`, the `case SkFontHinting::kSlight` branch), so advances are unhinted there.
- **[C]** HarfBuzz scale: `hb_font_set_scale(skFont.get(), scale, scale)` with `scale = skhb_position(font.getSize())`, which is `round(size * 65536)`. Advances are also converted to 16.16 (`SkShaper_harfbuzz.cpp`). Advances therefore scale with size up to 1/65536 px rounding. Whether that rounding ever flips a break is **[H]** (see E4).

### 2.3 What break-first inside SkParagraph would change

- **Layout without shaping [H]:** For a certified paragraph, `layout()` could compute `fLines` (ranges, widths, heights, intrinsic widths) from the model. It would skip `OneLineShaper::shape()` entirely. Line heights need per-run metrics (ascent/descent/strut), which are per-font constants that a model can carry. Placeholders already have explicit sizes.
- **Paint shapes only lines that are painted [H]:** `TextLine::ensureTextBlobCachePopulated` is already lazy per line. Under break-first it would shape the line's range at that point. Today `ParagraphImpl::paint` paints every line, so the gain also needs **culling against the canvas clip** in `ParagraphImpl::paint`, which is not done today [C]. Flutter records display lists that may be re-rastered across frames (scrolling a long `Text` in a `SingleChildScrollView`). There is a trade-off: shaping a line once on first paint versus keeping glyphs for off-screen lines [H].
- **Pixel parity risk [H]:** Shaping per line instead of per paragraph can change glyph positions wherever the paragraph shaping applied context across the break: a pair kern on the last glyph before a trailing space, contextual alternates, CJK break points inside kerned text. Lines that are certified S/P should be unaffected if the per-line shaping includes the trailing spaces. HarfBuzz pre/post-context does not position glyphs outside the item. This must be checked with a screenshot diff (E2).
- **APIs that need glyphs [C for the API list]:** `getRectsForRange` / `getBoxesForRange`, `getGlyphPositionAtCoordinate`, `getWordBoundary`, `getLineMetrics` with per-run style metrics, and caret/selection in `EditableText`. Each would trigger shaping of the affected lines. The `Cluster`/`Run` tables these APIs read (`TextLine::iterateThroughVisualRuns`, `measureTextInsideOneRun`) assume paragraph-wide runs, so the change is not local to `layout()`.
- **Off-UI-thread layout [C/H]:** `dart:ui` `ParagraphBuilder` throws on non-root isolates (`engine/src/flutter/lib/ui/text/paragraph_builder.cc` → `UIDartState::ThrowIfUIOperationsProhibited()`, message *"UI actions are only available on root isolate."*). A Dart-side model is the only way to compute Flutter-exact text heights on a background isolate today [C]. Inside the engine, layout could move to a worker thread, but that is an engine design decision [H].

---

## 3. Android: Minikin, `StaticLayout`, Jetpack Compose

### 3.1 Minikin already measures per word with a cache

- **[C]** `MeasuredText::measure` (`libs/minikin/MeasuredText.cpp`) calls `StyleRun::getMetrics` for each run. That splits each bidi run with `LayoutSplitter` and calls `LayoutCache::getInstance().getOrCreate(textBuf.substr(context), piece - context.getStart(), paint, isRtl, NO_EDIT, NO_EDIT, ...)` per piece. The result is a per-code-unit `widths[]` array, which is effectively the advance array whose prefix sums the breakers use.
- **[C]** `LayoutSplitter` (`libs/minikin/LayoutSplitter.h`) "basically splits the text before and after space characters". Its boundaries come from `getPrevWordBreakForCache` / `getNextWordBreakForCache` (`libs/minikin/LayoutUtils.cpp`). `isWordBreakAfter` returns true for U+0020, U+2000–U+200A, U+3000 and bidi controls. `isWordBreakBefore` additionally returns true for CJK ideographs U+3400–U+9FFF ("kana is not included, as sophisticated fonts may kern kana"). The source says plainly that this is a heuristic: *"a word break is a boundary with no kerning or complex script processing. This is necessarily a heuristic, but should be accurate most of the time."*
- **[C]** `LayoutCache` (`include/minikin/LayoutCache.h`) is a global `android::LruCache` with `kMaxEntries = 5000`, guarded by a `std::mutex`. Pieces of `CHAR_LIMIT_FOR_CACHE = 128` or more code units (`include/minikin/Constants.h`) bypass the cache. The key (`LayoutCacheKey`) includes the context characters, the piece range, `paint.fontFlags` (hinting, subpixel, linear, embolden...), the font collection id, style, size, scaleX, skewX, letter and word spacing, locale list, vertical text, family variant, start/end hyphen edit, direction, font feature settings and variation settings.
- **[C]** Drawing uses the same splitting. `Layout::doLayoutRunCached` (`libs/minikin/Layout.cpp`) iterates `LayoutSplitter` and calls `doLayoutWord` → `LayoutCache::getOrCreate`. Minikin's measured width therefore equals its drawn width for ordinary word breaks, by construction.

**When Minikin's per-word measurement is exact [C].** It is exact against Minikin's own drawing. It is not exact against whole-paragraph shaping:

- kerning or contextual lookups across a space, or between two CJK ideographs, are never applied, because each side is a separate piece;
- uncached pieces of 128 code units or more are still shaped the same way, just not cached;
- hyphenated breaks are measured separately with hyphen edits (`StyleRun::measureHyphenPiece`, called from `GreedyLineBreaker::tryLineBreakWithHyphenation` and from the candidate population in `OptimalLineBreaker.cpp`), so their width includes the inserted hyphen glyph's shaping;
- desperate mid-word breaks (`GreedyLineBreaker::doLineBreakWithGraphemeBounds`) use per-code-unit `widths[]`, so a split inside a kerned or ligated word may not equal the drawn width of the half-word [H].

**Implication for the model [H, important for the Compose exactness test]:** to match Android, the model must *drop* kerning pairs that involve a space, and pairs between two CJK ideographs, because Minikin never applies them. A model distilled from SkParagraph would keep them. `certify.py` should flag fonts with space-involving GPOS/kern pairs as needing an Android-specific variant.

### 3.2 Line breaking over sums

- **[C]** `breakIntoLines` (`libs/minikin/LineBreaker.cpp`) picks `breakLineGreedy` if the strategy is Greedy **or the text contains a tab**, and `breakLineOptimal` otherwise.
- **[C]** `GreedyLineBreaker` accumulates `mSumOfCharWidths` and `mLineWidth` from `mMeasuredText.widths[]` (`updateLineWidth`). Trailing line-end spaces do not count (`isLineEndSpace`). `isWidthExceeded()` subtracts an estimated letter spacing (the average of the line-start and current letter spacing) and documents that this approximation exists to avoid an O(n²) cost.
- **[C]** `OptimalLineBreaker` is already prefix-sum based. `struct Candidate` holds `preBreak` and `postBreak` (*"The line width between two line break candidates i and j is calculated as postBreak(j) - preBreak(i)."*). `LineBreakOptimizer::computeBreaks` runs a DP with an `active` pruning window and penalty constants (`LINE_PENALTY_MULTIPLIER = 2`, `LAST_LINE_PENALTY_MULTIPLIER = 4`, `SHRINKABILITY = 1/3` when justified). `breakLineOptimal` may run twice: a retry with phrase-based word breaking under the "auto" word style, guarded by `LBW_AUTO_HEURISTICS_LINE_COUNT`.
- **[C]** `StaticLayout.generate` (`frameworks/base/core/java/android/text/StaticLayout.java`) measures each paragraph with `PrecomputedText.createMeasuredParagraphs(source, param, ..., false /* computeLayout */, ...)` *unless* the source is a usable `PrecomputedText`, then calls `LineBreaker.computeLineBreaks`. A plain `CharSequence` is re-measured on every `StaticLayout` build. Cached words are hits; others are shaped. `PrecomputedText`'s javadoc shows creating it on a background executor [C].

### 3.3 Compose text pipeline

- **[C]** `TextMeasurer.measure` (`compose/ui/ui-text/.../TextMeasurer.kt`) has an LRU `TextLayoutCache` with `DefaultCacheSize = 8`. It builds `MultiParagraphIntrinsics`, then `MultiParagraph`, then one `AndroidParagraph` per paragraph-style range.
- **[C]** `AndroidParagraph` → `constructTextLayout` → `TextLayout(...)` (`.../android/TextLayout.android.kt`). It uses `BoringLayoutFactory.create` when `boringMetrics != null && maxIntrinsicWidth <= width && !hasBaselineShiftSpans`, and `StaticLayoutFactory.create` otherwise. The width passed to both is **`ceil(width).toInt()`**.
- **[C]** `StaticLayoutFactory23.create` (`.../android/StaticLayoutFactory.android.kt`) sets direction, alignment, maxLines, ellipsize, line spacing, `setIncludePad`, `setBreakStrategy`, `setHyphenationFrequency`, indents, `setJustificationMode` (API 26+), `setUseLineSpacingFromFallbacks` (API 28+) and `setLineBreakConfig` (API 33+). On API 35+ it forces `setUseBoundsForWidth(false)` (comment: b/391378120).
- **[C]** `LayoutIntrinsics` (`.../android/LayoutIntrinsics.android.kt`) computes `maxIntrinsicWidth` with `Layout.getDesiredWidth` and `minIntrinsicWidth` from longest-word candidates. This is another measuring pass over the text.
- **[C]** `TextAutoSize.StepBased` (`compose/foundation/.../text/TextAutoSize.kt`) binary-searches font size and calls `performLayout(constraints, text, size)` at every probe. Each probe is a full layout at a new size, and `LayoutCacheKey.mSize` differs, so the words are re-shaped at each size [C for the loop, H for the cost share].

### 3.4 What break-first inside Minikin/Compose would change

- **[H]** For certified text, `MeasuredText::measure` could fill `widths[]` from the model instead of `LayoutCache` lookups and HarfBuzz on misses. Line breaking (greedy and optimal) would not change, because it already consumes sums. The gains: no hashing and locking per word, no shaping on misses, and no cache pollution from layouts that are never drawn (intrinsics, auto-size probes, `TextMeasurer` measurements).
- **[C/H]** Drawing still needs `LayoutPiece`s, so `LayoutCache` stays [C: `Layout::doLayoutRunCached`]. The model replaces the measuring path only.
- **[H]** The size dependence matters more on Android than in Flutter. With Compose's default `TextMotion.Static`, advances are *hinted* (see §8). The width table then cannot be one linear table: it would need one table per (font, pixel size) or a hinting-aware model.

---

## 4. Chromium Blink: LayoutNG inline layout

### 4.1 Where shaping happens relative to line breaking

1. **[C]** `InlineNode::PrepareLayout` → `CollectInlines`, `SegmentText` (script, font orientation, bidi), then `ShapeTextIncludingFirstLine` → `InlineNode::ShapeText` (`core/layout/inline/inline_node.cc`). It shapes **all** text items of the inline formatting context (IFC) up front. The comment reads *"Provide full context of the entire node to the shaper."* `ShapeTextForFirstLineIfNeeded` reshapes for `::first-line` styles when needed.
2. **[C]** `LineBreaker::NextLine` / `HandleText` / `BreakText` (`core/layout/inline/line_breaker.cc`) use the item's `ShapeResult` through `ShapingLineBreaker::ShapeLine` (`platform/fonts/shaping/shaping_line_breaker.cc`). The class comment says it finds the break from "the shape results for the entire paragraph" and that *"Unless the break opportunity is at a safe-to-break boundary (as identified by HarfBuzz) the beginning and/or end of the line is reshaped"*. It also says this is done for *"significantly faster and more efficient line breaking by only reshaping when absolutely necessarily"* (qualitative [C]).
   - Line start: `FirstSafeOffset(start)`. If it is not safe, it calls `Shape(start, first_safe.offset, {.is_line_start = true, .han_kerning_start = ...})` and adjusts the available space by the width difference.
   - Line end: it reshapes from `CachedPreviousSafeToBreakOffset(candidate_break)` to the break.
   - `LineBreaker::BreakText` calls `breaker.SetDontReshapeEndIfAtSpace()` unless `NeedsAccurateEndPosition`, which is true only for box decorations or text decorations on the line-end item. The comment reads *"kerning between trailing spaces is not visible"*.
   - `LineBreaker::TruncateLineEndResult` reshapes from `PreviousSafeToBreakOffset(end)` when an accurate end position is needed.
3. **[C]** `ShapeResult` (`platform/fonts/shaping/shape_result.h`) exposes `NextSafeToBreakOffset`/`PreviousSafeToBreakOffset`, their cached variants, and `EnsurePositionData()`. *"Line breaking performance relies on high-performance x-position to character offset lookup"* (`shaping_line_breaker.cc`). Line breaking is already a prefix-position search over a shaped paragraph.
4. **[C]** Fragments hold `ShapeResultView`s, and paint uses them, so painting does not reshape.

### 4.2 What is cached

- **[C]** `NGShapeCache` (`platform/fonts/shaping/ng_shape_cache.h`): `kMaxTextLengthOfEntries = 30`, `kMaxSize = 2048` per primary font. A comment there notes "footprint under 10MB". It is only allowed when `InlineNode::IsNGShapeCacheAllowed` holds: a single text run matching the text content, no atomic inlines or bidi controls or ruby, `HasSimpleFontFeatures()`, and no letter or word spacing. In practice it serves short labels, not paragraphs.
- **[C]** Incremental text change: `InlineNode::SetTextWithOffset` → `ShapeTextIncludingFirstLine(data, &previous_text, &previous_items)` → `ReusingTextShaper`. It reuses previous `ShapeResult`s per inline item when the text, font and direction match and the item is not `IsUnsafeToReuseShapeResult()`. Items ending inside a ligature are marked unsafe: *"We should not reuse `ShapeResult` ends with ligature glyph"*, crbug.com/1409702. Reshaping is needed for the changed range and is joined with reused copies.
- **[C]** `text-wrap: pretty` and `balance`. `ScoreLineBreaker` (`core/layout/inline/score_line_breaker.h`) is *"similar to the Knuth's TeX algorithm"* and *"based on Android's `LineBreak.Strategy.HighQuality`"*. It first runs the greedy `LineBreaker`, computes candidates with `pos_no_break` / `pos_if_break` (`line_break_candidate.h`), then scores them. The limits are in `score_line_break_context.h`: `kMaxLinesForOptimal = 4` and `kMaxLinesForBalance = 6`. `OptimalBreakPoints` returns without optimizing once `line_info_list.Size() >= max_lines`, which makes optimization apply to the *last* 4 lines of a paragraph. The Intent to Ship states the reason: *"To balance between the typographic benefits and the performance impacts, it adjusts the last 4 lines of paragraphs that meet certain conditions"* (Koji Ishii, blink-dev, 2023-06-21).
- **[C]** Balance: `ParagraphLineBreaker::AttemptParagraphBalancing` (`paragraph_line_breaker.cc`) first *estimates* the line count with `EstimateNumLines`, which divides the text length by the number of `ch` (space width) that fit, *"without running the line breaker"*. It then runs `BisectAvailableWidth`, which calls `BreakLines(middle, ...)` (a full `LineBreaker` pass) per bisection step, until the width resolves to `epsilon = ceil(zoom)` CSS px.
- **[C]** Spec: CSS Text 4 §5.4 lets UAs *"treat this value [balance] as auto if there are more than ten lines to balance"*. It describes `pretty` as *"bias for better layout over speed"* and warns *"The necessary computations may be expensive"*.

### 4.3 Web fonts and layout shift

- **[C]** CSS Fonts 4 §3.2 (font display timeline): during the block period, text renders with an *invisible fallback font face* "with the same metrics as the selected font face", i.e. the fallback's metrics. §4.9: `block` recommends a 3 s block period, `swap` 100 ms or less. Any line breaking done before the web font loads therefore uses the fallback's widths.
- **[C]** CSS Fonts 5 §4.4 `size-adjust` is one multiplier for all glyph metrics and advances of a face. It can match the *average* width of a fallback to the web font, but not per-glyph or per-pair widths. `ascent-override`, `descent-override` and `line-gap-override` fix vertical metrics only.
- **[C]** web.dev "Optimize CLS": FOUT and FOIT *"Both approaches can cause layout shifts."* It recommends `font-display: optional`, metric overrides and preload.

### 4.4 Skipped content

- **[C]** CSS Contain 2 (`content-visibility: auto`): skipped elements get size containment, and *"the layout of the page (or at least, the scrollbar position) can 'jump around' as elements go off-screen and start skipping"*. The fix is to set an estimated `contain-intrinsic-size` or to use `auto`, which keeps the last remembered size. CSS Sizing 4 says `auto` uses the *last remembered size*, so elements that were never rendered fall back to the author's estimate.

### 4.5 What break-first inside Blink would change

- **[H]** The IFC-wide `ShapeText` in `PrepareLayout` could be deferred for certified items. Line boxes (break offsets, inline sizes, block sizes) would come from model prefix sums. Lines would be shaped on demand: at paint for lines in the cull rect, and for hit testing, `getClientRects`, selection, find-in-page and accessibility.
- **[H]** The edge reshaping in `ShapingLineBreaker::ShapeLine` could become arithmetic for P-class text: line width = prefix difference − kern(pair across break). Blink's per-line semantics (shape the line substring) match "pairs fully inside the line", so the certificate maps naturally onto Blink. That is a better fit than SkParagraph's paragraph-wide semantics.
- **[H]** `ParagraphLineBreaker`'s bisection and `ScoreLineBreaker`'s greedy pre-pass would each become cheap when every `BreakLines` call is a prefix-sum pass. That could justify raising `kMaxLinesForOptimal` and `kMaxLinesForBalance`. `EstimateNumLines` could be exact.
- **[H]** `contain-intrinsic-size` for text-only skipped blocks could be computed exactly from the model with no layout. This would remove the "jump around" case for never-rendered elements.
- **Blink-specific exactness risks [C for existence]:** `LayoutUnit` fixed-point snapping (`ShapeResult::SnappedWidth`, `AvailableWidthToFit` → `AddEpsilon()` "Match `LineBreaker`"); `text-spacing-trim` / han kerning at line start (`FirstSafeOffset` → `han_kerning`); `text-autospace` (`TextAutoSpace auto_space(*data)` disables the shape cache); letter and word spacing (`ShapeResultSpacing`); `::first-line`; `NeedsAccurateEndPosition` for decorations; inline boxes with padding/border; `text-transform`; `white-space` modes; `hyphens: auto`; and bidi isolates.

---

## 5. Apple: Core Text and TextKit 2 (brief)

- **[C]** `CTTypesetter`: *"A typesetter which performs line layout."* *"The typesetter performs character-to-glyph encoding, glyph ordering, and positional operations, such as kerning, tracking, and baseline adjustments. If multiline layout is needed, it is performed by a CTFramesetter object, which calls into the typesetter to generate the typeset lines."* `CTTypesetterSuggestLineBreak` *"Suggests a contextual line breakpoint based on the width provided"*, and the result feeds `CTTypesetterCreateLine`. Apple does not document whether the typesetter shapes the whole string when created or lazily per suggested line [H, E12].
- **[C]** TextKit 1 `NSLayoutManager` "Noncontiguous Layout": *"Previously, both glyph generation and layout were always performed, in order, from the beginning to the end of the document. When noncontiguous layout is turned on, however, the layout manager gains the option of performing glyph generation or layout for one portion of the document without having done so for previous sections."* It is opt-in (`allowsNonContiguousLayout`).
- **[C]** TextKit 2 `NSTextViewportLayoutController`: *"The viewport defines the active area where the framework lays out text fragments."* `usageBoundsForTextContainer` is KVO-observable so views can resize.
- **[C-3p]** In viewport-based layout, the document height is an estimate that changes as the user scrolls, which makes the scroller jump (Krzyżanowski, "TextKit 2 – the promised land", 2025; Apple Developer Forums thread 795657, FB19433976).
- **What break-first would change [H]:** exact `usageBounds` without laying out off-viewport fragments; it is the TextKit 2 analogue of Blink's `content-visibility` gain. Risks [H]: Core Text applies `trak` tracking and optical-size (`opsz`) behaviour for system fonts per point size, so a model would be per size. AAT `morx`/`kerx` must be certified (the project's `certify.py` already reads them).

---

## 6. Candidate gains, one by one

Each gain lists status, engine notes, the certificate's limits, memory, and where shaping is still needed.

### G1. Shape only visible lines (lazy shaping of long or off-screen text)

- **Status:** **Confirmed opportunity.** In all three open engines, layout does the shaping (SkParagraph `OneLineShaper::shape`, Blink `InlineNode::ShapeText`, Minikin `MeasuredText::measure`). Lines are produced from shaped data [C]. SkParagraph additionally builds blobs for every line at paint [C].
- **Per engine:**
  - Flutter: largest headroom [H]. The whole paragraph is shaped in `layout()`, and `ParagraphImpl::paint` touches every line [C].
  - Blink: paint already culls, but layout shapes the whole IFC [C].
  - Android: measuring is per word (cache-backed). Drawing per line re-runs `LayoutCache` per word [C]. The gain is the measure pass for undrawn text [H].
  - TextKit 2: already lazy, but heights are estimated [C/C-3p]. Break-first turns that into "lazy and exact".
- **Limits:** uncertified lines (K/U classes, fallback-font runs, emoji ZWJ sequences, complex scripts) are shaped at layout as today. Any API that queries glyph geometry forces shaping of the lines it touches. Pixel parity with paragraph-wide shaping must be verified (§2.3).
- **Memory [H]:** glyph arrays are retained only for shaped lines, against today's whole-paragraph `fRuns`/`fClusters`, `ShapeResult` and `LayoutPieces`. The model's in-memory size has not been measured. Only its gzipped size is known (~12 KB for Roboto).

### G2. Shape lines in parallel once breaks are known

- **Status:** **Hypothesis, constrained.** Once breaks are known, lines are independent shaping jobs as far as certified text is concerned [H].
- **Constraints [C]:** Flutter `dart:ui` text APIs are root-isolate only (`ThrowIfUIOperationsProhibited`). `ParagraphCache` and `LayoutCache` take a mutex per lookup. HarfBuzz documents that its object-lifecycle APIs are thread-safe and that some objects become safe to use from many threads after setup (`make_immutable`). Per-type guarantees for `hb_font_t` must be checked (HarfBuzz "Object model: lifecycle").
- **Limits [H]:** glyph and strike caches (Skia `SkStrikeCache`, Blink font caches) need to be thread-safe. Blink's layout runs on the main thread, so parallel shaping would be a new threading model. The benefit is bounded by how much of a frame is spent shaping visible lines, which is small after G1. Most of the value is for *full-document* shaping (export, print, PDF, server-side).

### G3. No reshaping at line ends

- **Status:** **Engine-specific.**
  - Blink reshapes line starts and ends at unsafe-to-break offsets [C], skipping it at spaces when no decoration needs an accurate end [C].
  - SkParagraph never reshapes [C], so there is nothing to remove.
  - Minikin splits words at spaces, so space breaks never need reshaping [C]. Hyphenated breaks are shaped with hyphen edits [C].
- **Break-first effect [H]:** in Blink, P-class edges become `prefix(b) − prefix(a) − kern(a−1, a) − kern(b−1, b)` corrections. The HarfBuzz docs describe the reshaping procedure that `UNSAFE_TO_CONCAT` exists to optimise ("avoiding re-shaping of each line after line-breaking") [C].
- **Limits:** han kerning and `text-spacing-trim` at line start (Blink `FirstSafeOffset`), hyphen glyphs (`HyphenationType` in Minikin `Hyphenator.h`: insert hyphen, Armenian hyphen, maqaf, UCAS hyphen, replace with hyphen for Catalan "l·l", repeat at next line for Polish/Slovenian, ZWJ+hyphen for Arabic) [C], and ellipsis glyphs (`TextLine::createEllipsis`) [C]. Each is shaped context the model must carry as extra entries, or else hand back.

### G4. Cheap optimal or balanced breaking (Knuth–Plass) over prefix sums

- **Status:** **Refined.** Minikin's `OptimalLineBreaker` and Blink's `ScoreLineBreaker` already compute over prefix positions (`preBreak`/`postBreak`, `pos_no_break`/`pos_if_break`) [C]. The new part is that **producing** those positions needs no shaping. In Blink, the greedy pre-pass and every bisection step also become cheap [H].
- **Per engine:**
  - Chrome: `pretty` applies to the last 4 lines and `balance` to 6 or fewer, explicitly for performance [C]. Whole-paragraph `pretty` becomes plausible [H].
  - Flutter: SkParagraph's `TextWrapper` has no optimal mode [C: greedy `lookAhead` only]. Optimal breaking could be added as a break-first feature [H].
  - Compose `LineBreak.Paragraph` / `Heading` already use Minikin's optimal breaker [C].
- **Limits [H]:** exactness against Android requires reproducing Minikin's penalties, its `active` pruning, the phrase-retry heuristic, hyphen penalties and the justified shrink exactly. Against Chrome it requires `ScoreLineBreaker` parameters (`SetupParameters`, `kLastLinePenaltyMultiplier`) and the 4/6-line windows. Reference: D. E. Knuth and M. F. Plass, "Breaking Paragraphs into Lines", *Software: Practice and Experience* 11(11), 1981.

### G5. Correct layout before a web font has downloaded (no layout shift)

- **Status:** **Plausible, but needs a platform change.** The spec's invisible-fallback and fallback rendering both use the *fallback's* metrics [C]. `size-adjust` is uniform [C]. A per-font model (~12 KB gzipped, which is small next to the font files themselves [H]) could give the web font's exact line breaks and heights before the font arrives [H].
- **How [H]:** either (a) a userland prototype that sets per-paragraph heights from the model (E8), or (b) a UA feature such as a "metrics-only" font source that lays out with the model and draws the fallback glyphs inside the predicted line boxes.
- **Limits:** the fallback glyphs will not fit the predicted line widths, so lines over- or under-fill during the swap period. Positioning fallback glyphs at the web font's advances is a rendering choice not covered by any spec [H]. It also needs: the model for *every* face and weight used; matching `unicode-range` subsets; font-feature settings and `font-variation-settings` instances; and fallback for characters outside the web font (still unknown before download). Security and privacy review would be needed for a new resource type [H].

### G6. Faster relayout on resize or text-scale change

- **Resize:**
  - SkParagraph reuses shaping on width change (`fState = kShaped`) [C], so the remaining cost is the cluster walk in `TextWrapper` plus formatting. Break-first gains little here [H].
  - Minikin re-measures on every `StaticLayout` build for plain `CharSequence` [C], so the model saves the measure pass [H].
  - Blink re-runs `LineBreaker` with edge reshapes [C]. The model saves the reshapes [H].
- **Text-scale / font-size change:**
  - Flutter: `textScaler` change → `markNeedsLayout` → new `ui.Paragraph` with a different font size → `ParagraphCache` miss → full reshape of every visible paragraph [C for the path, H for the cost share].
  - Minikin's `LayoutCacheKey` includes `mSize` [C], so all words miss.
  - Compose `TextAutoSize` probes many sizes [C].
  - With a model that scales linearly (Flutter: subpixel, unhinted on FreeType, 16.16 HarfBuzz scale), new breaks are arithmetic [H].
- **Limits:** linearity must be measured (E4). Hinted advances (Compose default, §8) and Core Text `trak`/`opsz` break linearity [H]. Variable-font `opsz` auto-application differs by engine [H].

### G7. Incremental layout while editing

- **Status:** **Refined.**
  - Blink already reuses `ShapeResult`s for unchanged items and reshapes the edited range (`ReusingTextShaper`) [C].
  - Flutter has no incremental path. A text change disposes and recreates the paragraph, and the `ParagraphCache` key is the full text, so a keystroke reshapes the whole paragraph [C for path, H for cost].
  - Compose `BasicTextField`/`TextField`: the cost is not measured here. StaticLayout re-measures, but unchanged words hit `LayoutCache` [C].
- **Break-first [H]:** keep model prefix sums in a Fenwick or segment tree. An edit updates O(edit) entries. Re-break from the line before the edit until two consecutive breaks coincide with the old ones. Shape only the edited line(s) for paint. CSS's `text-wrap-style: stable` (*"content on subsequent lines should not be considered ... so that when editing text any content before the cursor remains stable"*) is the spec hook for this behaviour [C].
- **Limits:** IME composing spans and underline styles, bidi re-resolution across the paragraph (an edit can change paragraph direction under first-strong), and caret geometry (glyph data for the caret line).

### G8. Replace word caches with a certified model

- **Status:** **Partial.** In Minikin the model can replace the *measuring* uses of `LayoutCache` for certified text [H]. Drawing still needs `LayoutPiece`s [C], and so do bounds (`calculateBounds`) when `setUseBoundsForWidth` or `computeBounds` is on.
- **Memory [H]:** the model is per (font, flags, size if hinted). `LayoutCache` is 5000 entries shared across the app [C]. The trade depends on how many fonts and sizes an app uses. It must be measured (E10, E11).
- **Limits:** the model must replicate Minikin's own approximations, not "true" shaping (§3.1): no space kerning, ideograph pieces, letter-spacing edge estimation.

---

## 7. Additional gains found

- **Exact intrinsic widths without shaping [H]:** max-content is the sum per hard line, and min-content is the longest unbreakable segment. Today Flutter lays out at infinite width or uses `_textIntrinsics` [C]. Compose calls `Layout.getDesiredWidth` [C]. Blink has `LineBreakerMode::kMinContent` and `HandleTextForFastMinContent` ("Break the text at every break opportunity and measure each word") [C].
- **Exact line-count estimates [H]:** Blink's `EstimateNumLines` (`ch`-based) decides whether to attempt balancing [C]. A model makes that decision exact.
- **Exact scroll extents for virtualized text lists [H]:** Flutter's `SliverChildDelegate` extrapolates unbuilt children by average extent (`_extrapolateMaxScrollOffset` in `widgets/sliver.dart`) [C]. This is a framework-level use the project already targets. It sits beside the engine-level gains above.
- **Layout off the UI thread for Flutter [C]:** the engine forbids `dart:ui` text on background isolates, so a pure-Dart model is the only Flutter-exact option there.

---

## 8. What the certificate cannot cover (cross-cutting)

| Feature | Why it escapes the certificate | Where the engine must still shape |
|---|---|---|
| Fallback fonts | Font itemization (SkParagraph `matchResolvedFonts`; Minikin `FontCollection::itemize`; Blink `SegmentText`) chooses per character. Compose sets `fallbackLineSpacing = true`, so line *heights* depend on which fallback fonts appear on each line [C]. | Runs in non-modelled fonts. Line heights for lines containing them. |
| Font features | `font-feature-settings`, `liga`/`calt` toggles, `font-variant-*` change GSUB/GPOS. Blink's shape cache requires `HasSimpleFontFeatures()` [C]. | Any run with non-default features, unless distilled per feature set. |
| Bidi | Breaking is logical-order, but shaping runs split at bidi boundaries, and Arabic joining is contextual (U class) [H]. SkParagraph shapes per bidi region [C]. | RTL complex scripts; mixed runs at boundaries. |
| Hyphenation | Hyphen edits are shaped (`measureHyphenPiece`), and edit types vary by language [C]. | Hyphenated line ends, unless the hyphen glyph and edge pairs are in the model. |
| Justification | Applied after breaking in SkParagraph (`TextLine::justify`) and Blink [C]. Minikin's optimal breaker uses `SHRINKABILITY` when justified [C], so the model breaker must replicate it. | None for breaking; glyph positions at paint. |
| Variable fonts | Advances depend on axis values (HVAR/gvar). Minikin keys on `mVariationSettings` [C]. Each instance needs its own model [H]. | Animated axes. |
| Emoji | Usually a fallback font. ZWJ, flag and modifier sequences are ligature islands [H]. | Emoji sequences, unless the emoji font is also modelled. |
| Hinting / subpixel | Compose default: hinting on, no subpixel, no linear metrics → FreeType hinted advances [C]. The model becomes per pixel size [H]. | No shaping needed, but more model tables. |
| Letter / word spacing | Minikin adjusts break edges by half letter-spacing [C]. Blink disables its shape cache with spacing [C]. | Representable in the model. Exactness must be measured. |
| Rounding | SkParagraph `LineBreakerWithLittleRounding`, Blink `LayoutUnit` snapping, Compose `ceil(width).toInt()` [C]. | None, but the model must replicate each one bit-for-bit. |
| Ellipsis, placeholders, inline boxes | Ellipsis is shaped (`ShapeString`) [C]. Blink inline padding/border affects `NeedsAccurateEndPosition` [C]. | Ellipsized last line. |
| Locale-dependent break rules | Compose maps `Strictness` and `WordBreak` to `LineBreakConfig` [C]. Phrase breaking and auto retry (Minikin) [C]. | No shaping, but the break-opportunity engine must match ICU tailoring. |

---

## 9. Experiments to run locally (Mac + Flutter, Android emulator, Chrome)

### 9.1 Rules for every experiment

- **Exactness first.** Every timing run is paired with an exactness check of the same layout: break offsets and heights compared against the engine. A speed-up only counts if the mismatch rate on that corpus is zero, or is reported alongside.
- **Report distributions.** Give median and p95 over at least 30 runs after warm-up, in release/profile builds. Record the machine state and build IDs, plus the engine versions from §0.
- **Corpus (shared across platforms).**
  - Public-domain English prose (e.g. Project Gutenberg, *Pride and Prejudice*), split into paragraphs.
  - Lengths bucketed at 50, 200, 1 000, 5 000 and 20 000+ chars.
  - German (long compounds, hyphenation), French (NBSP before punctuation), Japanese (CJK breaks, kana kerning), Arabic and Hebrew (expected hand-off), emoji-heavy chat lines, URLs/code (long unbreakable runs).
  - A kerning stress set: "AVAWAY To Ty Wa", "ffi fl", and any font pairs involving space.
- **Fonts and sizes.** Roboto as a bundled asset (Flutter, Chrome via `@font-face`, Android via `res/font`). Sizes 12–32 px or sp. Widths swept 120–1200 px in 1 px steps, plus random fractional widths to exercise rounding.
- **Counters.** Count how many lines are certified (S/P) versus handed back. A gain only applies to the certified share.

### 9.2 Experiment list

**E1. Flutter: how much of `layout()` is shaping? (supports G1, G6)**

- *Setup:* `flutter run --profile -d macos`, repeated on the Android emulator (Flutter-on-Android uses the FreeType path).
- *What to time:*
  - (A) `ParagraphBuilder.build()` + first `layout(w)`, using more than 128 distinct paragraphs so `ParagraphCache` misses (keyed by text, 128 entries).
  - (B) `layout(w2)` on the same paragraph with `w2 ≠ w` (reuses `kShaped`, so breaking + formatting only).
  - (C) model breaking at `w2` in Dart.
  - (D) `PictureRecorder` + `drawParagraph` + `endRecording` (blob building for all lines).
- *Baseline:* A. A − B estimates the shaping and indexing share [H]. C − B estimates what the model saves on top of reuse.
- *Instruments:* `Stopwatch` loops; `dart:developer` `Timeline.startSync` around each phase; DevTools CPU profiler with native frames.

**E2. Flutter: lazy visible-line shaping prototype (G1)**

- *Setup:* text of about 100k chars inside a `SingleChildScrollView`. Baseline is one `Text`. The variant is a custom `RenderBox` that computes its height from model breaks and, at paint, builds a `ui.Paragraph` only for lines intersecting the viewport (one line per paragraph, with its trailing spaces, `maxLines: 1`).
- *Time:* first-frame build and raster (`SchedulerBinding.addTimingsCallback` → `FrameTiming`), scroll frame times (integration_test `traceAction` + timeline summary), and RSS (`ProcessInfo.currentRss`).
- *Exactness:* golden screenshot diff, full paragraph against line-wise, counting lines with any pixel difference. Also compare per-character `getBoxesForRange` x positions. This measures the per-line versus paragraph-wide parity risk in §2.3.

**E3. Shaper-level parallel shaping upper bound (G2)**

- *Setup:* a small C or C++ program on the Mac linking HarfBuzz (`brew install harfbuzz`) with the same Roboto TTF.
- *Runs:* (a) shape each paragraph whole; (b) shape model-determined lines sequentially; (c) shape lines on k = 1…8 threads, each thread with its own `hb_buffer_t` and a shared, immutable `hb_font_t`.
- *Time:* wall time and CPU time.
- *Verify:* glyph IDs and advances of (b) and (c) are identical to each other, and compared against (a) sliced per line, with differences counted.
- *Caveat:* this is an upper bound. Engines add fallback, cluster tables and blob creation.

**E4. Scale linearity and the text-scale relayout cost (G6)**

- *Linearity:* for sizes 10–40 px in 0.25 steps, compare breaks from `model(16 px) × s/16` against SkParagraph at size s, across the corpus and width sweep. Count mismatches.
  - Repeat on Android/Compose at each sp × density with the default `TextMotion.Static` (hinted) and with `TextMotion.Animated` (linear + subpixel). Read per-glyph advances with `Paint.getTextWidths` to see whether they are pixel-quantized [H].
- *Cost (Flutter):* a screen of 200 paragraphs. Time relayout after `MediaQuery` `textScaler` changes 1.0 → 1.15 → 1.3. Baseline is the stock widgets. The variant computes heights from the model and shapes only visible lines.

**E5. Optimal and balanced breaking (G4)**

- (a) Port Minikin's `OptimalLineBreaker` (penalties, `active` window, phrase retry) to Kotlin and Dart over model sums.
  - Exactness against Compose `LineBreak.Paragraph` (HighQuality) and `LineBreak.Heading` (Balanced) on the emulator: compare `TextLayoutResult.getLineEnd`.
  - Time against `StaticLayout.Builder.build()` with those strategies, using Jetpack Microbenchmark on the emulator. The library raises an `EMULATOR` error that must be suppressed with `androidx.benchmark.suppressErrors=EMULATOR` [C: developer.android.com/topic/performance/benchmarking/microbenchmark-instrumentation-args]. Treat emulator timings as relative comparisons only.
- (b) Chrome: 1 000 paragraphs, `text-wrap: auto | pretty | balance`.
  - Change the container width, force layout (`el.offsetHeight`), and time with `performance.now()` over 30 runs.
  - Record a Perfetto/DevTools trace with the `blink` category to attribute time to `LineBreaker` and `ScoreLineBreaker`. Check that `InlineNode::ShapeTextIncludingFirstLine` appears (it has a `TRACE_EVENT0`).
- (c) A JS whole-paragraph Knuth–Plass over the model. Compare its time with `pretty` (last 4 lines only) and compare the visual results.

**E6. Resize relayout (G6)**

- *Chrome:* animate the container width 300 → 900 px in 1 px steps with `requestAnimationFrame` over a 200-paragraph article. Measure per-frame layout time from the trace ("Layout" events) against the JS model re-break time for the same widths.
- *Compose:* `TextMeasurer.measure(..., skipCache = true)` across the width sweep (Microbenchmark) against the Kotlin model.
- *Flutter:* `ui.Paragraph.layout` at swept widths (already shaped) against the Dart model.
- *Expectation [H]:* the smallest gain is in Flutter, because shaping is already reused.

**E7. Editing (G7)**

- *Flutter:* an `EditableText` with 2k, 10k and 50k chars in one paragraph. Insert characters programmatically (`TextEditingController.value` per char) and measure frame build times (timeline summary). Baseline is stock. The variant is a model-incremental re-break (Fenwick tree) with only the edited lines shaped.
- *Chrome:* a `contenteditable` with a 10k-char paragraph. Insert with `document.execCommand('insertText')` or synthetic input. Measure Event Timing (`PerformanceObserver({type: 'event'})`) durations and, per keystroke, the count and duration of `InlineNode::ShapeTextIncludingFirstLine` in Perfetto. Compare a single text node against many `<span>`s to see `ReusingTextShaper`'s item granularity.

**E8. Web-font layout shift (G5)**

- *Setup:* a local server that delays the Roboto `woff2` by a fixed, configurable time. A page with 50 paragraphs.
- *Variants:*
  1. `font-display: swap` with the default fallback (baseline);
  2. swap with `size-adjust`/`ascent-override`/`descent-override` tuned from Roboto against the fallback;
  3. `font-display: optional`;
  4. a prototype that inlines the model (~12 KB gzipped), computes each paragraph's height at the container width before the font loads, sets `min-height` (or `contain-intrinsic-size` on `content-visibility: auto` blocks), then removes it after `document.fonts.ready`.
- *Measure:* CLS (`PerformanceObserver({type: 'layout-shift'})`, summing entries without `hadRecentInput`), per-paragraph height error (model against final), and screenshots during the swap period (fallback over- or under-fill).

**E9. Exact sizes for skipped or viewport content (§7, G1)**

- *Chrome:* 2 000 paragraphs with `content-visibility: auto`, comparing `contain-intrinsic-size: auto 200px` against `auto <modelHeight>px` per element. Scroll programmatically top to bottom. Record `scrollHeight` at each step (drift), layout-shift entries and scroll frame durations.
- *TextKit 2 (Mac):* `NSTextView(usingTextLayoutManager: true)` with 1–5 MB of text.
  - Observe `usageBoundsForTextContainer.height` via KVO while scrolling.
  - Compare against `ensureLayout(for: documentRange)` (exact, slow), against the TextKit 1 full-layout height, and against the model height.
  - Time `ensureLayout`.
- *Flutter:* a `ListView.builder` of variable-height text items. Compare the extrapolated `maxScrollExtent` (`_extrapolateMaxScrollOffset`) with the exact model sum, and log scrollbar-thumb jumps.

**E10. Android word cache against the model (G8)**

- *Microbenchmark:* `StaticLayout.Builder.build()` on the corpus with (a) a warm cache; (b) a cold cache, forced with unique words or optionally by clearing caches via hidden API on a debuggable image; (c) the Kotlin model breaker. Include `Layout.getDesiredWidth`.
- *Exactness:* compare against Compose's default configuration (§10) at the width sweep.
- *Memory:* native heap deltas (`Debug.getNativeHeapAllocatedSize`, `dumpsys meminfo`) after filling `LayoutCache`, against the model's footprint.

**E11. Memory of retained shaping data (G1, G8)**

- *Flutter:* RSS and a DevTools memory snapshot for a long-text screen, stock against lazy-line.
- *Chrome:* Task Manager memory footprint, or memory-infra in a trace, for a long article, stock against userland lazy rendering.

**E12. Core Text shaping granularity (§5)**

- *Setup:* in a Swift command-line tool, time `CTTypesetterCreateWithAttributedString` against string length, and per-line `CTTypesetterSuggestLineBreak` + `CTTypesetterCreateLine`.
- *Question:* if creation time grows with the whole string, Core Text shapes up front; if per-line calls dominate, it shapes lazily [H].
- *Exactness:* compare the model against `CTTypesetterSuggestLineBreak` breaks for the corpus at several point sizes (this tests the `trak`/`opsz` per-size hypothesis).

---

## 10. Jetpack Compose default line-breaking configuration (for the parallel exactness test)

All of this is from `androidx-main` @ `a6a6dfbfb81d` unless noted. Check it against your Compose BOM.

| Setting | Default and source |
|---|---|
| LineBreak strategy | `resolveParagraphStyleDefaults` (`compose/ui/ui-text/src/commonMain/.../ParagraphStyle.kt`): `lineBreak == LineBreak.Unspecified` → **`LineBreak.Simple`**. `LineBreak.Simple` = `packBytes(Strategy.Simple, Strictness.Normal, WordBreak.Default)` (`.../androidMain/.../style/LineBreak.android.kt`). `AndroidParagraph.android.kt` maps these to **`BREAK_STRATEGY_SIMPLE`**, **`LINE_BREAK_STYLE_NORMAL`** (note: `Strictness.Default` would map to `LINE_BREAK_STYLE_NONE`, but `Simple` uses `Normal`) and **`LINE_BREAK_WORD_STYLE_NONE`**. `LineBreakConfig` is only applied on API 33+ (`StaticLayoutFactory33.setLineBreakConfig`). Minikin also forces greedy when the text has a tab (`LineBreaker.cpp`). |
| Hyphenation | `hyphens == Hyphens.Unspecified` → **`Hyphens.None`** (same function) → **`HYPHENATION_FREQUENCY_NONE`** (`toLayoutHyphenationFrequency`). For reference, `Hyphens.Auto` → `FULL` on API ≤ 32 and `FULL_FAST` on API ≥ 33. |
| includeFontPadding | **false**. `DefaultIncludeFontPadding = false` (`.../androidMain/.../AndroidTextStyle.android.kt`); read by `TextStyle.isIncludeFontPaddingEnabled()` (`platform/AndroidParagraphHelper.android.kt`) and passed to `setIncludePad`. Material3 and Material2 `DefaultPlatformTextStyle` also set `false` (`material3/.../internal/DefaultPlatformTextStyle.android.kt`; `material/.../DefaultPlatformTextStyle.android.kt`). |
| Fallback line spacing | **true**, hard-coded in `AndroidParagraph.constructTextLayout` (`fallbackLineSpacing = true`) → `setUseLineSpacingFromFallbacks(true)` on API 28+. Line heights grow when fallback fonts appear on a line. |
| TextPaint flags | `AndroidTextPaint(Paint.ANTI_ALIAS_FLAG, density)` (`ParagraphIntrinsics.android.kt`). Then `textPaint.setTextMotion(style.textMotion)`, where null → **`TextMotion.Static`** = `TextMotion(Linearity.FontHinting, subpixelTextPositioning = false)` (`style/TextMotion.android.kt`). `setTextMotion` (`platform/extensions/TextPaintExtensions.android.kt`) **clears `SUBPIXEL_TEXT_FLAG`**, **clears `LINEAR_TEXT_FLAG`** and sets **`hinting = HINTING_ON`**. `TextMotion.Animated` instead sets `LINEAR_TEXT_FLAG`, `HINTING_OFF` and subpixel. |
| What HINTING_ON means natively | `PaintGlue::setHinting` (`frameworks/base/libs/hwui/jni/Paint.cpp`) maps a non-zero mode to **`SkFontHinting::kNormal`**. In Skia's FreeType backend (`src/ports/SkFontHost_FreeType.cpp`), `kNormal` → `FT_LOAD_TARGET_NORMAL`. Linear metrics stay off unless `LINEAR_TEXT_FLAG` is set, so the advance is the **hinted** `glyph->advance.x`, not `linearHoriAdvance`. These flags are part of Minikin's cache key (`LayoutCacheKey.mFontFlags`, packed by `MinikinFontSkia::packFontFlags`). Whether Roboto's hinted advances are integer pixels on the emulator is **[H]**: check with `Paint.getTextWidths`. |
| Width passed to the breaker | **`ceil(width).toInt()`** for both `BoringLayout` and `StaticLayout` (`TextLayout.android.kt`). |
| BoringLayout path | Used when `boringMetrics != null && maxIntrinsicWidth <= width && !hasBaselineShiftSpans` (`TextLayout.android.kt`). |
| useBoundsForWidth | Forced **false** on API 35+ (`StaticLayoutFactory35.disableUseBoundsForWidth`, b/391378120). |
| Justification | `JUSTIFICATION_MODE_NONE` unless `TextAlign.Justify` → `JUSTIFICATION_MODE_INTER_WORD`. |
| Line spacing | `lineSpacingMultiplier = 1.0f`; `lineSpacingExtra` default `0f` (`LayoutCompat.android.kt`, `TextLayout.android.kt`). |
| Line height style | Material3 `DefaultTextStyle` = `TextStyle.Default.copy(platformStyle = defaultPlatformTextStyle(), lineHeightStyle = LineHeightStyle(Alignment.Center, Trim.None))` (`material3/.../tokens/TypographyTokens.kt`). Each type scale (e.g. `BodyLarge`) sets its own `lineHeight`. When `includeFontPadding` is false, `LineHeightStyleSpan` uses `lineHeightStyle ?: LineHeightStyle.Default` (Proportional, Trim.Both, Mode.Fixed) (`AndroidParagraphHelper.android.kt`). There is a single-line optimization that applies the line height in `AndroidParagraph.calculateLineHeight` instead of a span. |
| Minikin semantics to mirror | No kerning across spaces, and none between CJK ideographs (`LayoutSplitter` / `LayoutUtils.cpp`). Trailing line-end spaces are excluded from line width (`isLineEndSpace`). Letter spacing at line edges is estimated (`GreedyLineBreaker::isWidthExceeded`). |

---

## 11. References

**Skia / Flutter**

- `ParagraphImpl.cpp` (`layout`, `shapeTextIntoEndlessLine`, `breakShapedTextIntoLines`, `paint`): https://github.com/google/skia/blob/main/modules/skparagraph/src/ParagraphImpl.cpp
- `ParagraphImpl.h`: https://github.com/google/skia/blob/main/modules/skparagraph/src/ParagraphImpl.h
- `OneLineShaper.cpp`: https://github.com/google/skia/blob/main/modules/skparagraph/src/OneLineShaper.cpp
- `TextWrapper.cpp`: https://github.com/google/skia/blob/main/modules/skparagraph/src/TextWrapper.cpp
- `TextLine.cpp`: https://github.com/google/skia/blob/main/modules/skparagraph/src/TextLine.cpp
- `ParagraphCache.cpp`: https://github.com/google/skia/blob/main/modules/skparagraph/src/ParagraphCache.cpp
- `TextStyle.h`: https://github.com/google/skia/blob/main/modules/skparagraph/include/TextStyle.h
- `SkShaper_harfbuzz.cpp`: https://github.com/google/skia/blob/main/modules/skshaper/src/SkShaper_harfbuzz.cpp
- `SkFontHost_FreeType.cpp`: https://github.com/google/skia/blob/main/src/ports/SkFontHost_FreeType.cpp
- `text_painter.dart`: https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/painting/text_painter.dart
- `rendering/paragraph.dart`: https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/rendering/paragraph.dart
- `widgets/sliver.dart`: https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/widgets/sliver.dart
- `paragraph_builder_skia.cc`: https://github.com/flutter/flutter/blob/master/engine/src/flutter/txt/src/skia/paragraph_builder_skia.cc
- `lib/ui/text/paragraph_builder.cc`: https://github.com/flutter/flutter/blob/master/engine/src/flutter/lib/ui/text/paragraph_builder.cc
- `lib/ui/ui_dart_state.cc`: https://github.com/flutter/flutter/blob/master/engine/src/flutter/lib/ui/ui_dart_state.cc

**Android**

- Minikin source tree (`LayoutSplitter.h`, `LayoutUtils.cpp`, `MeasuredText.cpp`, `Layout.cpp`, `GreedyLineBreaker.cpp`, `OptimalLineBreaker.cpp`, `LineBreaker.cpp`, `Hyphenator.h`; `include/minikin/LayoutCache.h`, `Constants.h`): https://android.googlesource.com/platform/frameworks/minikin/+/refs/heads/main/libs/minikin/
- `StaticLayout.java`: https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/text/StaticLayout.java
- `PrecomputedText.java`: https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/text/PrecomputedText.java
- hwui `jni/Paint.cpp`: https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/libs/hwui/jni/Paint.cpp
- hwui `MinikinSkia.cpp`: https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/libs/hwui/hwui/MinikinSkia.cpp

**Compose**

- ui-text android sources (`AndroidParagraph.android.kt`, `ParagraphIntrinsics.android.kt`, `AndroidTextStyle.android.kt`, `android/TextLayout.android.kt`, `android/StaticLayoutFactory.android.kt`, `android/LayoutCompat.android.kt`, `android/LayoutIntrinsics.android.kt`, `platform/extensions/TextPaintExtensions.android.kt`, `platform/AndroidParagraphHelper.android.kt`, `style/LineBreak.android.kt`, `style/TextMotion.android.kt`): https://github.com/androidx/androidx/tree/androidx-main/compose/ui/ui-text/src/androidMain/kotlin/androidx/compose/ui/text
- ui-text common sources (`ParagraphStyle.kt`, `TextMeasurer.kt`, `MultiParagraph.kt`, `style/LineHeightStyle.kt`): https://github.com/androidx/androidx/tree/androidx-main/compose/ui/ui-text/src/commonMain/kotlin/androidx/compose/ui/text
- `TextAutoSize.kt`: https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/TextAutoSize.kt
- Material3 `TypographyTokens.kt`: https://github.com/androidx/androidx/blob/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/tokens/TypographyTokens.kt
- Material3 `DefaultPlatformTextStyle.android.kt`: https://github.com/androidx/androidx/blob/androidx-main/compose/material3/material3/src/androidMain/kotlin/androidx/compose/material3/internal/DefaultPlatformTextStyle.android.kt

**Blink**

- Inline layout sources (`inline_node.cc`, `line_breaker.cc`, `score_line_breaker.h/.cc`, `score_line_break_context.h`, `line_break_candidate.h`, `paragraph_line_breaker.cc`): https://chromium.googlesource.com/chromium/src/+/refs/heads/main/third_party/blink/renderer/core/layout/inline/
- Shaping sources (`shaping_line_breaker.h/.cc`, `shape_result.h`, `ng_shape_cache.h`): https://chromium.googlesource.com/chromium/src/+/refs/heads/main/third_party/blink/renderer/platform/fonts/shaping/
- Intent to Ship: CSS `text-wrap: pretty` (blink-dev): https://groups.google.com/a/chromium.org/g/blink-dev/c/rwBWqqOB_ag

**Specs**

- CSS Text 4 §5.4 `text-wrap-style`: https://drafts.csswg.org/css-text-4/#text-wrap-style
- CSS Fonts 4 §3.2, Font Display Timeline: https://drafts.csswg.org/css-fonts-4/#font-display-timeline
- CSS Fonts 4 §4.9, `font-display`: https://drafts.csswg.org/css-fonts-4/#font-display-desc
- CSS Fonts 5 §4.4, `size-adjust`: https://drafts.csswg.org/css-fonts-5/#size-adjust-desc
- CSS Contain 2, `content-visibility`: https://drafts.csswg.org/css-contain-2/
- CSS Sizing 4, `contain-intrinsic-size` / last remembered size: https://drafts.csswg.org/css-sizing-4/

**Other**

- web.dev, "Optimize Cumulative Layout Shift": https://web.dev/articles/optimize-cls
- HarfBuzz `hb_glyph_flags_t` (`UNSAFE_TO_BREAK`, `UNSAFE_TO_CONCAT`): https://harfbuzz.github.io/harfbuzz-hb-buffer.html
- HarfBuzz, "Object model: lifecycle": https://harfbuzz.github.io/object-model-lifecycle.html
- Apple, `CTTypesetter`: https://developer.apple.com/documentation/coretext/cttypesetter
- Apple, `CTTypesetterSuggestLineBreak`: https://developer.apple.com/documentation/coretext/cttypesettersuggestlinebreak(_:_:_:)
- Apple, `CTFramesetter`: https://developer.apple.com/documentation/coretext/ctframesetter
- Apple, `NSLayoutManager` (Noncontiguous Layout): https://developer.apple.com/documentation/appkit/nslayoutmanager
- Apple, `NSTextViewportLayoutController`: https://developer.apple.com/documentation/uikit/nstextviewportlayoutcontroller
- Apple, `usageBoundsForTextContainer`: https://developer.apple.com/documentation/uikit/nstextlayoutmanager/usageboundsfortextcontainer
- [C-3p] M. Krzyżanowski, "TextKit 2 – the promised land" (2025): https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/
- [C-3p] Apple Developer Forums 795657: https://developer.apple.com/forums/thread/795657
- D. E. Knuth and M. F. Plass, "Breaking Paragraphs into Lines", *Software: Practice and Experience* 11(11):1119–1184, 1981.
