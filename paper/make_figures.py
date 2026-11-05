"""Figures and numbers for the paper, from result files only.

Reads: ../census/results.jsonl, ../census/reasons.json, ../results.txt (C prototype,
HarfBuzz), ../flutter_bench/results/*.json. Writes: fig_*.svg and numbers.json.
Every number in the paper text comes from numbers.json.
"""
import json
import os
import re
from collections import Counter

import matplotlib

matplotlib.use("svg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FR = os.path.join(ROOT, "flutter_bench", "results")
INK, MUTED, GRID = "#1f2328", "#6e7781", "#d8dee4"
C_FLUTTER, C_PARA, C_COLD, C_WARM, C_BF = "#8c959f", "#afb8c1", "#d4a72c", "#bf8700", "#0969da"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 8.5, "axes.edgecolor": MUTED, "axes.labelcolor": INK,
    "xtick.color": INK, "ytick.color": INK, "axes.spines.top": False, "axes.spines.right": False,
    # Text as paths: the browser and the PDF render the charts exactly as laid out.
    "svg.fonttype": "path", "figure.constrained_layout.use": True,
    "axes.titlesize": 9, "axes.titleweight": "bold", "axes.titlelocation": "left",
})
N = {}


def save(fig, name):
    fig.savefig(os.path.join(HERE, name), bbox_inches="tight", transparent=True)
    plt.close(fig)


def load(name):
    with open(os.path.join(FR, name)) as fp:
        return json.load(fp)


# ---------------------------------------------------------------- census
# CENSUS_RESULTS: another copy of the census results (e.g. while census.py rewrites them).
rows = [json.loads(l) for l in open(os.environ.get("CENSUS_RESULTS", os.path.join(ROOT, "census", "results.jsonl")))]
reasons = json.load(open(os.path.join(ROOT, "census", "reasons.json")))
# The reason file names the most frequent unsafe character. When that is the rare
# fraction slash, coverage was lost elsewhere: islands longer than the bound m (the
# exhaustive check's budget lowered m), or characters the font lacks.
for key, cat in list(reasons.items()):
    if cat == "fraction slash":
        r0 = next(r for r in rows if key.startswith(r["name"] + " ("))
        reasons[key] = "island bound m < 4 (budget)" if r0["m"] < 4 else "characters missing from font"
pcts = [r["certifiedPct"] for r in rows]
N["census_faces"] = len(rows)
N["census_lines"] = sum(r["lines"] for r in rows)
N["census_certified"] = sum(r["certified"] for r in rows)
N["census_wrong"] = sum(r["wrong"] for r in rows)
N["census_ge99"] = sum(p >= 99 for p in pcts)
N["census_ge90"] = sum(p >= 90 for p in pcts)
N["census_zero"] = sum(p == 0 for p in pcts)
N["census_median"] = sorted(pcts)[len(pcts) // 2]
N["census_certified_share"] = 100 * N["census_certified"] / N["census_lines"]
N["census_distill_median_s"] = sorted(r["distillSec"] for r in rows)[len(rows) // 2]
# The census's sample, as census.py ran it.
census_src = open(os.path.join(ROOT, "census.py")).read()
N["census_paragraphs"] = int(re.search(r'BFL_LIMIT="(\d+)"', census_src)[1])
N["w_census_widths"] = {2: "two", 3: "three", 4: "four", 5: "five", 6: "six"}[
    len(re.search(r'BFL_WIDTHS="([\d,]+)"', census_src)[1].split(","))]

fig, (a, b) = plt.subplots(1, 2, figsize=(7.0, 2.3), gridspec_kw={"width_ratios": [1, 1.25]})
bins = [0, 1, 50, 90, 99, 100.01]
labels = ["0", "1–50", "50–90", "90–99", "≥99"]
counts = [sum(lo <= p < hi for p in pcts) for lo, hi in zip(bins, bins[1:])]
a.bar(labels, counts, color=[C_FLUTTER, C_FLUTTER, C_FLUTTER, C_BF, C_BF], width=0.7)
for i, c in enumerate(counts):
    a.text(i, c + 4, str(c), ha="center", color=INK)
a.set_ylabel("font faces")
a.set_xlabel("% of lines certified")
a.tick_params(axis="x", labelrotation=35)
a.set_title(f"(a) Lines certified per face ({len(rows)} faces)")
a.set_ylim(0, max(counts) * 1.15)
cat = Counter(reasons[k] for k in reasons)
top = cat.most_common(7)
b.barh([t[0] for t in top][::-1], [t[1] for t in top][::-1], color=C_FLUTTER, height=0.6)
for y, (k, v) in enumerate(top[::-1]):
    b.text(v + 0.5, y, str(v), va="center", color=INK)
b.set_title(f"(b) Main blocker, faces under 99% ({len(reasons)})")
b.set_xlabel("font faces")
save(fig, "fig_census.svg")
N["census_reasons"] = dict(top)
N["census_low"] = len(reasons)
N["census_low_aat"] = sum(v for k, v in cat.items() if k.startswith("AAT") or k in ("kerx state machine", "kern state machine"))
N["census_low_subst"] = cat["substitution on common letters"] + cat["contextual lookup on common letters"]
N["census_low_island"] = cat.get("island bound m < 4 (budget)", 0)
N["census_low_missing"] = cat.get("characters missing from font", 0)

# ---------------------------------------------------------------- C prototype baselines (HarfBuzz)
txt = open(os.path.join(ROOT, "results.txt")).read()
base = []
for block in txt.split("\n== ")[1:]:
    name = block.split(" (upem")[0].lstrip(".")
    sf = float(re.search(r"shape-first ([\d.]+)% \|", block)[1])
    wc = float(re.search(r"word-cache ([\d.]+)%\n", block)[1])
    bfm = float(re.search(r"model v1 [\d.]+% v2 ([\d.]+)%", block)[1])
    base.append((name, bfm, sf, wc))
base = [b for b in base if b[0] != "Zapfino"]
N["c_fonts"] = len(base)
N["c_paragraphs"] = int(re.search(r"^corpus: (\d+) paragraphs", txt, re.M)[1])
c_widths = set(re.findall(r"\(x(\d+) widths\)", txt))
assert len(c_widths) == 1, c_widths
N["c_widths"] = int(c_widths.pop())
N["c_shapefirst_min"] = min(b[2] for b in base)
N["c_wordcache_min"] = min(b[3] for b in base)
N["c_breakfirst_min"] = min(b[1] for b in base)

fig, ax = plt.subplots(figsize=(7.0, 2.2))
xs = range(len(base))
ax.scatter(xs, [100 - b[3] for b in base], color=C_COLD, s=22, label="word cache", zorder=3)
ax.scatter(xs, [100 - b[2] for b in base], color=C_FLUTTER, s=22, label="shape once, then break", zorder=3)
ax.scatter(xs, [100 - b[1] for b in base], color=C_BF, s=22, marker="D", label="break-first (model)", zorder=3)
ax.set_xticks(list(xs))
ax.set_xticklabels([b[0].replace(" Medium", "").replace(" Roman", "").replace(" Bold", "") for b in base], rotation=35,
                   ha="right")
ax.set_ylabel("% paragraphs with\nwrong line breaks")
ax.grid(axis="y", color=GRID, lw=0.6)
ax.legend(frameon=False, ncol=3, loc="upper left")
ax.set_title("Line breaks vs exact ground truth (HarfBuzz, every candidate line reshaped)")
save(fig, "fig_baselines.svg")

# ---------------------------------------------------------------- Flutter: build, exactness, platforms
build = load("build_stats.json")
mac = load("macos_release.json")
ios = load("ios_sim.json")
andr = load("android_emu.json")
N.update({f"build_{k}": v for k, v in build.items() if isinstance(v, (int, float))})
N["build_pair_classes"] = "×".join(str(x) for x in build["pairClasses"])
CORP = ["en_docs", "en_man", "en_legal", "ui_en", "ui_de", "ui_fr", "ui_ru", "ui_uk", "ui_el"]
NAMES = {"en_docs": "EN docs", "en_man": "EN man pages", "en_legal": "EN licenses", "ui_en": "EN UI", "ui_de": "DE UI",
         "ui_fr": "FR UI", "ui_ru": "RU UI", "ui_uk": "UK UI", "ui_el": "EL UI"}


def totals(r):
    v = r["validate"]
    t = dict(identical=0, different=0, deferred=0, lines=0, heights=0, heightChecked=0, paragraphs=0, covered=0)
    for c in CORP:
        x = v[c]
        t["identical"] += x["identical"]
        t["different"] += x["different"]
        t["deferred"] += x["deferred"]
        t["lines"] += x["lines"]
        t["heights"] += x["heightIdentical"]
        t["heightChecked"] += x["heightChecked"]
        t["paragraphs"] += x["paragraphs"]
        t["covered"] += x["covered"]
    t["deferredPct"] = 100 * t["deferred"] / (t["identical"] + t["different"] + t["deferred"])
    t["sizes"] = v["sizes"]
    t["widths"] = v["widthSteps"]
    return t


for key, r in (("mac", mac), ("ios", ios), ("android", andr)):
    t = totals(r)
    for k, v in t.items():
        N[f"{key}_{k}"] = v
    N[f"{key}_canary_px"] = r["canary"]["maxErrPx"]
    N[f"{key}_maxwidth_err"] = max(r["validate"][c]["maxSingleLineWidthErrPx"] for c in CORP)
N["mac_line_method_checked"] = mac["validate"]["lineStartMethodCheck"]["checked"]
N["mac_line_method_disagree"] = mac["validate"]["lineStartMethodCheck"]["disagree"]
assert build["nonIntegralMeasurements"] == 0, "§2 says every build measurement was an integer"

# The text claims zero mismatches on every platform and every size; fail loudly if not.
for key, r in (("mac", mac), ("ios", ios), ("android", andr)):
    assert N[f"{key}_different"] == 0, f"{key}: {N[key + '_different']} mismatches; the text claims 0"
    assert N[f"{key}_heights"] == N[f"{key}_heightChecked"], f"{key}: heights differ; the text claims all equal"
    assert set(CORP) <= set(r["validate"]) and r["validate"]["sizes"] == mac["validate"]["sizes"], key
# Corpus counts, from the result file's own keys.
corpora_run = [k for k, v in mac["validate"].items() if isinstance(v, dict) and "identical" in v]
assert sorted(corpora_run) == sorted(CORP), corpora_run
WORDS = {2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten",
         11: "eleven", 12: "twelve"}
N["w_corpora"] = WORDS[len(corpora_run)]
N["w_languages"] = WORDS[len({c.split("_")[1] if c.startswith("ui_") else "en" for c in corpora_run})]
N["w_sizes"] = WORDS[len(mac["validate"]["sizes"])]
N["w_widths"] = WORDS[mac["validate"]["widthSteps"]]
for key, r in (("ios", ios), ("android", andr)):
    per = {r["validate"][c]["paragraphs"] for c in CORP}
    assert len(per) == 1, (key, per)
    N[f"{key}_per_corpus"] = per.pop()

# Effective font size: Android truncates to a fixed fraction of a pixel; macOS and iOS do not.
for key, r in (("mac", mac), ("ios", ios), ("android", andr)):
    N[f"{key}_quantized"] = r["fontSizeQuantized"]
assert N["android_quantized"] and not N["mac_quantized"] and not N["ios_quantized"]
probe = load("android_sizes.json")["sizes"]


def explains(d):
    # floor(size * d) / d lies inside the measured range (float drift) for every probed size.
    return all(e["minEffectiveSize"] - 1e-4 <= int(float(s) * d) / d <= e["maxEffectiveSize"] + 1e-4
               for s, e in probe.items())


quanta = [d for d in (2 ** k for k in range(1, 13)) if explains(d)]
assert len(quanta) == 1, quanta
N["android_size_quantum"] = quanta[0]
N["android_sizes_probed"] = len(probe)
# Example: the validated size that loses the most to truncation.
ex_size = max((s for s in mac["validate"]["sizes"] if f"{s}" in probe), key=lambda s: s - int(s * quanta[0]) / quanta[0])
N["android_size_ex"] = ex_size
N["android_size_ex_eff"] = int(ex_size * quanta[0]) / quanta[0]
N["android_size_ex_measured"] = probe[f"{ex_size}"]["minEffectiveSize"]

# Heatmap: deferral rate by corpus and size (macOS, all paragraphs); every cell has 0 mismatches.
sizes = mac["validate"]["sizes"]
grid = []
for c in CORP:
    ps = mac["validate"][c]["perSize"]
    row = []
    for s in sizes:
        idn, dif, dfr = ps[str(s)]
        assert dif == 0
        row.append(100 * dfr / (idn + dif + dfr))
    grid.append(row)
fig, ax = plt.subplots(figsize=(4.6, 2.9))
im = ax.imshow(grid, cmap="Blues", vmin=0, vmax=max(max(r) for r in grid) * 1.3, aspect="auto")
ax.set_xticks(range(len(sizes)))
ax.set_xticklabels([f"{s:g}px" for s in sizes])
ax.set_yticks(range(len(CORP)))
ax.set_yticklabels([NAMES[c] for c in CORP])
for i, r in enumerate(grid):
    for j, v in enumerate(r):
        ax.text(j, i, f"{v:.1f}", ha="center", va="center", fontsize=7, color=INK)
ax.set_title("Mismatches: 0 in every cell.  Shown: % handed back to Flutter")
ax.spines[:].set_visible(False)
save(fig, "fig_exactness.svg")
N["sizes_list"] = ", ".join(f"{s:g}" for s in sizes)

# ---------------------------------------------------------------- Flutter timing (quiet macOS run + Android emulator)
quiet_file = load("macos_timing_quiet.json")
assert quiet_file["mode"] == "timing" and quiet_file["runs"] == len(quiet_file["perRun"])
quiet = quiet_file["timing"]
N["timing_runs"] = quiet_file["runs"]
N["timing_spread_pct"] = 100 * max(quiet_file["speedupSpreadAcrossRuns"].values())
# Passes per method inside one app run, as bench.dart runs them.
N["timing_reps"] = int(re.search(r"timing\(WidthModel md, \{int reps = (\d+)\}\)",
                                 open(os.path.join(ROOT, "flutter_bench", "lib", "bench.dart")).read())[1])
at = andr["timing"]
fig, axes = plt.subplots(1, 3, figsize=(7.2, 2.4), gridspec_kw={"width_ratios": [1, 1, 0.8]})
methods = [("textPainterMs", "TextPainter", C_FLUTTER), ("uiParagraphMs", "ui.Paragraph", C_PARA),
           ("wordCacheColdMs", "word cache, cold", C_COLD), ("wordCacheWarmMs", "word cache, warm", C_WARM),
           ("breakFirstMs", "break-first", C_BF)]
for ax, (label, d) in zip(axes[:2], (("docs", quiet["docs"]), ("chat", quiet["chat"]))):
    vals = [d[k] for k, _, _ in methods]
    ax.barh([m[1] for m in methods][::-1], vals[::-1], color=[m[2] for m in methods][::-1], height=0.62)
    for y, v in enumerate(vals[::-1]):
        ax.text(v * 1.02, y, f"{v:.0f} ms" if v >= 10 else f"{v:.1f} ms", va="center", color=INK, fontsize=7.5)
    ax.set_xlim(0, max(vals) * 1.32)
    ax.set_title("(a) Docs" if label == "docs" else "(b) Chat")
    ax.set_xlabel("ms, macOS release (M3)")
    if label == "chat":
        ax.set_yticklabels([])
rw = [("relayoutFlutterMs", "Flutter", C_FLUTTER), ("relayoutWordCacheMs", "word cache", C_WARM),
      ("relayoutBreakFirstMs", "break-first", C_BF)]
vals = [quiet["docs"][k] for k, _, _ in rw]
ax = axes[2]
ax.barh([m[1] for m in rw][::-1], vals[::-1], color=[m[2] for m in rw][::-1], height=0.55)
for y, v in enumerate(vals[::-1]):
    ax.text(v * 1.02, y, f"{v:.1f} ms", va="center", color=INK, fontsize=7.5)
ax.set_xlim(0, max(vals) * 1.4)
ax.set_title("(c) Re-wrap, docs")
ax.set_xlabel("ms")
save(fig, "fig_speed.svg")
for scope, d in (("docs", quiet["docs"]), ("chat", quiet["chat"])):
    for k, v in d.items():
        N[f"t_{scope}_{k}"] = v
    N[f"t_{scope}_speedup_tp"] = d["textPainterMs"] / d["breakFirstMs"]
    N[f"t_{scope}_speedup_para"] = d["uiParagraphMs"] / d["breakFirstMs"]
    N[f"t_{scope}_speedup_all"] = d["textPainterAllMs"] / d["breakFirstAllMs"]
    N[f"t_{scope}_speedup_relayout"] = d["relayoutFlutterMs"] / d["relayoutBreakFirstMs"]
    N[f"t_{scope}_wc_wrong"] = d["wordCacheChecked"] - d["wordCacheIdentical"]
for scope in ("docs", "chat"):
    d = at[scope]
    N[f"a_{scope}_speedup_tp"] = d["textPainterMs"] / d["breakFirstMs"]
    N[f"a_{scope}_textPainterMs"] = d["textPainterMs"]
    N[f"a_{scope}_breakFirstMs"] = d["breakFirstMs"]
    N[f"a_{scope}_speedup_relayout"] = d["relayoutFlutterMs"] / d["relayoutBreakFirstMs"]
le, la = quiet["listExtents"], at["listExtents"]
for k, v in le.items():
    N[f"list_{k}"] = v
N["list_speedup"] = le["textPainterMs"] / le["breakFirstMs"]
N["a_list_speedup"] = la["textPainterMs"] / la["breakFirstMs"]
N["a_list_heightsEqual"] = la["heightsEqual"]
N["a_list_maxScrollOffsetErrPx"] = la["maxScrollOffsetErrPx"]

fig, ax = plt.subplots(figsize=(3.4, 1.6))
labels = ["TextPainter", "break-first"]
ax.barh(labels[::-1], [le["breakFirstMs"], le["textPainterMs"]], color=[C_BF, C_FLUTTER], height=0.55)
for y, v in enumerate([le["breakFirstMs"], le["textPainterMs"]]):
    ax.text(v * 1.02, y, f"{v:.0f} ms", va="center", color=INK)
ax.set_xlim(0, le["textPainterMs"] * 1.3)
ax.set_xlabel("ms to compute every item height")
ax.set_title(f"{le['messages']:,} chat messages: exact extents")
save(fig, "fig_list.svg")

# ---------------------------------------------------------------- drift by size
pdata = load("paper_data.json")
dr = pdata["drift"]
# The breaker's drift margin per unit of x position, as the code ships it.
margin = float(re.search(r"const double driftPerPx = ([\d.e+-]+);",
                         open(os.path.join(ROOT, "packages", "break_first", "lib", "src", "width_model.dart")).read())[1])
N["drift_margin"] = margin
fig, ax = plt.subplots(figsize=(3.4, 2.0))
xs = [d["size"] for d in dr]
ys = [max(d["maxRel"], 1e-9) for d in dr]
ax.scatter([x for x, d in zip(xs, dr) if d["maxRel"] == 0], [1e-9] * sum(d["maxRel"] == 0 for d in dr), color=C_BF,
           marker="o", s=20, label="exact (drift 0)")
ax.scatter([x for x, d in zip(xs, dr) if d["maxRel"] > 0], [d["maxRel"] for d in dr if d["maxRel"] > 0],
           color=C_COLD, marker="^", s=22, label="drifts")
ax.axhline(margin, color=MUTED, lw=0.8, ls="--")
ax.text(xs[0], margin * 1.3, "margin the breaker uses", color=MUTED, fontsize=7)
ax.set_yscale("log")
ax.set_ylim(5e-10, 1e-4)
ax.set_yticks([1e-9, 1e-7, 1e-5])
ax.set_yticklabels(["0", "1e-7", "1e-5"])
ax.set_xlabel("font size (px)")
ax.set_ylabel("max drift / x position")
ax.legend(frameon=False, fontsize=7, loc="center right")
ax.set_title("Flutter float32 drift by size")
save(fig, "fig_drift.svg")
N["drift_max_rel"] = max(d["maxRel"] for d in dr)
N["drift_exact_sizes"] = ", ".join(f"{d['size']:g}" for d in dr if d["maxRel"] == 0)
N["drift_max_abs"] = max(d["maxAbsPx"] for d in dr)
assert N["drift_max_rel"] < margin, "measured drift exceeds the margin"

# ---------------------------------------------------------------- example decomposition
ex = pdata["example"]
N["ex_phrase"] = ex["phrase"]
N["ex_size"] = ex["size"]
N["ex_model_px"] = ex["modelPxAt16"]
N["ex_flutter_px"] = ex["flutterPxAt16"]
N["ex_sum_adv_px"] = ex["sumOfAdvancesUnits"] * ex["size"] / ex["upem"]
N["ex_terms"] = ex["terms"]

# Waterfall: the phrase's width as the sum of the model's terms (px at 16 px).
scale = 16 / ex["upem"]
fig, ax = plt.subplots(figsize=(7.0, 2.1))
x = 0.0
colors = {"advance": "#d0d7de", "pair": "#cf222e", "island": C_BF, "island-left": "#cf222e", "island-right": "#cf222e"}
for i, t in enumerate(ex["terms"]):
    w = t["units"] * scale
    if w == 0:
        continue  # a zero pair term draws nothing
    t = dict(t, text=t["text"].replace(" ", "·"))
    if t["kind"] == "advance":
        ax.barh(0, w, left=x, color=colors["advance"], edgecolor="white", height=0.5)
        ax.text(x + w / 2, 0, t["text"], ha="center", va="center", fontsize=9, color=INK)
    elif t["kind"] == "island":
        ax.barh(0, w, left=x, color=C_BF, edgecolor="white", height=0.5, alpha=0.85)
        ax.text(x + w / 2, 0, t["text"], ha="center", va="center", fontsize=9, color="white", fontweight="bold")
        sep = t["unitsIfSeparate"] * scale
        ax.annotate(f"ligature island '{t['text']}': {w:.2f} px\n(vs {sep:.2f} px as separate letters)",
                    xy=(x + w / 2, 0.25), xytext=(x + w / 2, 0.75), ha="center", fontsize=7, color=C_BF,
                    arrowprops=dict(arrowstyle="-", color=C_BF, lw=0.6))
    else:
        ax.barh(-0.55, w, left=x, color="#cf222e", height=0.22)
        ax.annotate(f"{t['text']} {w:+.2f}", xy=(x + w / 2, -0.66), xytext=(x + w / 2, -1.05),
                    ha="center", fontsize=6.5, color="#cf222e", arrowprops=dict(arrowstyle="-", color="#cf222e", lw=0.5))
    x += w
ax.axvline(ex["flutterPxAt16"], color=INK, lw=1, ls="--")
ax.text(ex["flutterPxAt16"], 0.62, f" Flutter: {ex['flutterPxAt16']:.4f} px\n model: {ex['modelPxAt16']:.4f} px",
        fontsize=7.5, color=INK, va="bottom")
ax.set_ylim(-1.3, 1.25)
ax.set_xlim(0, ex["flutterPxAt16"] * 1.18)
ax.set_yticks([])
ax.spines["left"].set_visible(False)
ax.set_xlabel("px at 16 px (Roboto): advances + pair terms + island terms")
ax.set_title(f"Width of “{ex['phrase']}” as the model's local terms")
save(fig, "fig_decomposition.svg")

# ---------------------------------------------------------------- style options, scripts, CI, C port, demo
def fmt_int(x):
    return f"{x:,}"


def table(head, rows):
    """An HTML table; numeric cells right-aligned."""
    out = ["<table><tr>" + "".join(f'<th{" class=\"n\"" if i else ""}>{h}</th>' for i, h in enumerate(head)) + "</tr>"]
    for r in rows:
        out.append("<tr>" + "".join(f'<td{" class=\"n\"" if i else ""}>{c}</td>' for i, c in enumerate(r)) + "</tr>")
    return "\n".join(out) + "</table>"


def cell_ok(different):
    return f"<b>{fmt_int(different)}</b>"


# Style options and hard breaks, macOS release, on the corpora joined into multi-line texts.
st = load("macos_styles.json")["styles"]
rows = [(k, v) for k, v in st.items() if isinstance(v, dict) and "identical" in v]
N["styles_texts"] = sum(st["texts"].values())
N["styles_configs"] = len(rows)
N["styles_identical"] = sum(v["identical"] for _, v in rows)
N["styles_different"] = sum(v["different"] for _, v in rows)
N["styles_table"] = table(["Option", "Layouts", "Identical breaks", "Different", "Heights equal", "Deferred"], [
    (k, fmt_int(v["identical"] + v["different"] + v["deferred"]), fmt_int(v["identical"]), cell_ok(v["different"]),
     f"{fmt_int(v['heightIdentical'])} / {fmt_int(v['heightChecked'])}",
     f"{100 * v['deferred'] / (v['identical'] + v['different'] + v['deferred']):.1f}%") for k, v in rows])

# Other scripts and directions (UI strings; fonts are the platform's own, not redistributed).
def cases(name, label, keep=lambda k: True):
    d = load(name)
    rs = [(k, v) for k, v in d.items() if isinstance(v, dict) and "identical" in v and keep(k)]
    return label, sum(v["identical"] for _, v in rs), sum(v["different"] for _, v in rs), \
        sum(v["identical"] + v["different"] + v["deferred"] for _, v in rs), len(rs)


script_rows = [
    cases("rtl_arial.json", "Hebrew, right-to-left paragraphs · Arial", lambda k: not k.startswith("mixed")),
    cases("rtl_arial.json", "Hebrew + Latin and digits, mixed direction · Arial", lambda k: k.startswith("mixed")),
    cases("rtl_times_new_roman.json", "Hebrew, right-to-left · Times New Roman", lambda k: not k.startswith("mixed")),
    cases("rtl_times_new_roman.json", "Hebrew + Latin and digits, mixed · Times New Roman", lambda k: k.startswith("mixed")),
    cases("rtl_arabic_arial.json", "Arabic (joining forms), right-to-left · Arial", lambda k: not k.startswith("mixed")),
    cases("rtl_arabic_arial.json", "Arabic + Latin and digits, mixed · Arial", lambda k: k.startswith("mixed")),
    cases("rtl_arabic_times_new_roman.json", "Arabic (joining forms) · Times New Roman", lambda k: not k.startswith("mixed")),
    cases("rtl_arabic_times_new_roman.json", "Arabic + Latin and digits, mixed · Times New Roman", lambda k: k.startswith("mixed")),
    cases("cjk_hiragino_sans_gb.json", "Japanese and Chinese · Hiragino Sans GB"),
    cases("cjk_apple_sd_gothic_neo.json", "Korean and Japanese · Apple SD Gothic Neo"),
]
# Beyond one plain style: each check against Flutter writes its own result file.
def cases_in(d, keep=lambda k: True, prefix=""):
    """(label, counts) for every dict with layout counts inside d."""
    for k, v in d.items():
        if isinstance(v, dict):
            label = f"{prefix}{k}"
            if "identical" in v and "different" in v:
                if keep(label):
                    yield label, v
            else:
                yield from cases_in(v, keep, f"{label}/")


def beyond(label, name, keep=lambda k: True):
    if not os.path.exists(os.path.join(FR, name)):
        return None
    d = load(name)
    cs = [d] if "identical" in d and "different" in d else [v for _, v in cases_in(d, keep)]
    if not cs:
        return None
    same = sum(v["identical"] for v in cs)
    diff = sum(v["different"] for v in cs)
    total = sum(v["identical"] + v["different"] + v["deferred"] for v in cs)
    heights = sum(v.get("heightsEqual", v.get("heightIdentical", 0)) for v in cs)
    return label, same, diff, total, heights


beyond_rows = [r for r in [
    beyond("Struts and TextHeightBehavior, 4 settings · Roboto", "host_styles.json",
           lambda k: k.startswith("styles/") and ("strut" in k or "ascent" in k or "leading" in k)),
    beyond("Font features: tnum, smcp, c2sc, onum, ss01, dlig, frac, liga off · Roboto", "features_roboto.json"),
    beyond("Rich text: 1–4 spans, 4 fonts, 3 sizes, height multipliers, colour changes", "rich.json"),
    beyond("Bundled fallback fonts: Latin-script UI text with Japanese, Chinese, Korean", "fallback_cjk.json"),
    beyond("Combining marks (NFD French, German, Greek, Russian, Ukrainian) · Roboto", "marks_nfd.json",
           lambda k: k.startswith("Roboto/")),
    beyond("Combining marks (NFD French, German, Greek, Russian, Ukrainian) · Arial", "marks_nfd.json",
           lambda k: k.startswith("Arial/")),
    beyond("Hebrew with points · Arial", "rtl_pointed_arial.json"),
    beyond("Hebrew with points · Times New Roman", "rtl_pointed_times_new_roman.json"),
    beyond("Arabic with harakat · Arial", "rtl_vowelled_arial.json"),
    beyond("Arabic with harakat · Times New Roman", "rtl_vowelled_times_new_roman.json"),
    beyond("Letter-spaced Arabic · Arial", "rtl_arabic_arial.json", lambda k: "pacing" in k or "spaced" in k),
    beyond("Letter-spaced Arabic · Times New Roman", "rtl_arabic_times_new_roman.json",
           lambda k: "pacing" in k or "spaced" in k),
    beyond("Emoji from the device's font (ZWJ sequences, skin tones, flags)", "emoji_device.json"),
    beyond("Hindi, Bengali, Tamil from the device's fonts, alone and in English", "indic_device.json"),
    beyond("Thai, Lao, Khmer, Burmese (ICU dictionaries) from the device's fonts", "dictionary_scripts.json"),
] if r]
N["beyond_identical"] = sum(r[1] for r in beyond_rows)
N["beyond_different"] = sum(r[2] for r in beyond_rows)
N["beyond_layouts"] = sum(r[3] for r in beyond_rows)
N["beyond_rows"] = len(beyond_rows)
N["beyond_table"] = table(["Check · font", "Layouts", "Identical", "Different", "Heights equal", "Decided"], [
    (label, fmt_int(total), fmt_int(same), cell_ok(diff), f"{fmt_int(heights)} / {fmt_int(same)}",
     f"{100 * (same + diff) / total:.0f}%") for label, same, diff, total, heights in beyond_rows])
# The font census in Flutter: every local face's sidecar built through Flutter and
# checked against Flutter's layout (flutter_bench/test/font_census_test.dart).
fc_path = os.path.join(FR, "font_census.jsonl")
if os.path.exists(fc_path):
    fc = [json.loads(l) for l in open(fc_path) if l.strip()]
    ok = [r for r in fc if "default" in r]
    N["fcensus_faces"] = len(fc)
    N["fcensus_checked"] = len(ok)
    N["fcensus_skipped"] = len(fc) - len(ok)
    N["fcensus_identical"] = sum(r["default"]["identical"] + r["spacedWithBreaks"]["identical"] for r in ok)
    N["fcensus_different"] = sum(r["default"]["different"] + r["spacedWithBreaks"]["different"] for r in ok)
    N["fcensus_layouts"] = sum(r["default"]["identical"] + r["default"]["different"] + r["default"]["deferred"] +
                               r["spacedWithBreaks"]["identical"] + r["spacedWithBreaks"]["different"] +
                               r["spacedWithBreaks"]["deferred"] for r in ok)
    N["fcensus_canary_fail"] = sum(r["canaryErrPx"] >= 1e-3 for r in ok)
    N["fcensus_heights"] = sum(r["default"]["heightsEqual"] + r["spacedWithBreaks"]["heightsEqual"] for r in ok)
    N["fcensus_paragraphs"] = ok[0]["default"]["paragraphs"]
    # The paper says every identical layout has Flutter's height.
    assert N["fcensus_heights"] == N["fcensus_identical"], (N["fcensus_heights"], N["fcensus_identical"])

N["scripts_identical"] = sum(r[1] for r in script_rows)
N["scripts_different"] = sum(r[2] for r in script_rows)
N["scripts_layouts"] = sum(r[3] for r in script_rows)
N["scripts_table"] = table(["Text · font", "Layouts", "Identical", "Different", "Decided"], [
    (r[0], fmt_int(r[3]), fmt_int(r[1]), cell_ok(r[2]), f"{100 * (r[1] + r[2]) / r[3]:.0f}%") for r in script_rows])
N["cjk_sdgothic_chars"] = load("cjk_apple_sd_gothic_neo.json")["characters"]
N["cjk_sdgothic_classes"] = "×".join(str(x) for x in load("cjk_apple_sd_gothic_neo.json")["pairClasses"])
N["cjk_sdgothic_bytes"] = load("cjk_apple_sd_gothic_neo.json")["sidecarBytes"]
N["cjk_hiragino_chars"] = load("cjk_hiragino_sans_gb.json")["characters"]

# CI: the same benchmarks on GitHub's machines.
CI = os.path.join(FR, "ci")
ci_run = sorted(d for d in os.listdir(CI) if d.startswith("run-"))[-1]
N["ci_run"] = ci_run[4:]


def ci(name):
    return json.load(open(os.path.join(CI, ci_run, name)))


ci_rows = []
for name, label in (("macos_release.json", "macOS 15, release (virtual Apple M1)"), ("linux_release.json", "Ubuntu 24.04, Linux desktop release"),
                    ("ios_sim.json", "iOS simulator (CI)"), ("android_emu.json", "Android 15 emulator, x86_64 (CI)"),
                    ("macos_host.json", "flutter_tester, macOS"), ("linux_host.json", "flutter_tester, Linux")):
    d = ci(name)
    t = totals(d)
    ci_rows.append((label, t, d))
N["ci_identical"] = sum(t["identical"] for _, t, _ in ci_rows)
N["ci_different"] = sum(t["different"] for _, t, _ in ci_rows)
N["ci_table"] = table(["Platform (GitHub Actions)", "Identical breaks", "Different", "Heights equal", "Size rounding"], [
    (label, fmt_int(t["identical"]), cell_ok(t["different"]), f"{fmt_int(t['heights'])} / {fmt_int(t['heightChecked'])}",
     "1/64 px" if d.get("fontSizeQuantized") else "none")
    for label, t, d in ci_rows])
ci_t = {}
for plat in ("macos", "linux"):
    runs = [ci(f"{plat}_timing_run{i}.json")["timing"] for i in (1, 2, 3)]
    ci_t[plat] = {k: sorted(r[k]["textPainterMs"] / r[k]["breakFirstMs"] for r in runs)[1] for k in ("docs", "chat")}
    ci_t[plat]["list"] = sorted(r["listExtents"]["textPainterMs"] / r["listExtents"]["breakFirstMs"] for r in runs)[1]
a_ci = ci("android_emu.json")["timing"]
ci_t["android"] = {k: a_ci[k]["textPainterMs"] / a_ci[k]["breakFirstMs"] for k in ("docs", "chat")}
ci_t["android"]["list"] = a_ci["listExtents"]["textPainterMs"] / a_ci["listExtents"]["breakFirstMs"]
for plat, v in ci_t.items():
    for k, x in v.items():
        N[f"ci_{plat}_{k}_speedup"] = x
assert N["ci_different"] == 0
for f in sorted(os.listdir(os.path.join(CI, ci_run))):
    if f.endswith("_styles.json"):
        assert all(v["different"] == 0 for v in ci(f)["styles"].values() if isinstance(v, dict) and "different" in v), f
# The mismatch GitHub's Linux runner found on 5f441fb (a word less than 1/100 px
# wider than the box), and the package test's constructed words of that kind.
N["ci_fail_run"] = 41953508573
fail = json.load(open(os.path.join(CI, f"run-{N['ci_fail_run']}", "linux_styles.json")))["styles"]["letterSpacing 0.5"]
N["ci_fail_different"], N["ci_fail_layouts"] = fail["different"], fail["identical"] + fail["different"]
N["too_long_cases"] = load("package_tests_macos.json")["tooLongWordCases"]
assert ci_run != f"run-{N['ci_fail_run']}"
# The same runner's layouts on the fix (its corpora are the same files).
fix = ci("linux_styles.json")["styles"]["letterSpacing 0.5"]
assert fix["different"] == 0 and sum(fix[k] for k in ("identical", "deferred")) == sum(
    fail[k] for k in ("identical", "different", "deferred"))
N["ci_fix_identical"], N["ci_fix_more_deferred"] = fix["identical"], fix["deferred"] - fail["deferred"]

# The C port through dart:ffi.
nat = load("native_macos.json")["runs"]
med = lambda xs: sorted(xs)[len(xs) // 2]
N["native_checked"] = nat[0]["exactness"]["checked"]
N["native_mismatched"] = sum(r["exactness"]["mismatched"] for r in nat)
N["native_docs_speedup"] = med([r["docs"]["dartMs"] / r["docs"]["cBatchMs"] for r in nat])
N["native_chat_speedup"] = med([r["chat"]["dartMs"] / r["chat"]["cBatchMs"] for r in nat])
N["native_chat_e2e_speedup"] = med([r["chat"]["endToEndDartMs"] / r["chat"]["endToEndCMs"] for r in nat])
na = load("native_android_emu.json")["runs"][0]
N["native_android_chat_speedup"] = na["chat"]["dartMs"] / na["chat"]["cBatchMs"]
N["native_android_mismatched"] = na["exactness"]["mismatched"]

# The list-extents demo (Android emulator, release).
demo = open(os.path.join(ROOT, "media", "list_extents_android_measured.txt")).read()
jumps = re.findall(r"jump (stock|breakFirst) to=(\d+) at=(\d+) frameMs=([\d.]+)", demo)
N["demo_stock_to"], N["demo_stock_at"], N["demo_stock_ms"] = int(jumps[0][1]), int(jumps[0][2]), float(jumps[0][3])
N["demo_bf_to"], N["demo_bf_at"], N["demo_bf_ms"] = int(jumps[1][1]), int(jumps[1][2]), float(jumps[1][3])
v = re.search(r"verify size=[\d.]+ equal=(\d+) of (\d+) textPainterMs=([\d.]+)", demo)
N["demo_equal"], N["demo_messages"], N["demo_tp_ms"] = int(v[1]), int(v[2]), float(v[3])

# Where it pays: use cases timed against what an app does today and checked answer
# for answer (bench.dart useCases, macOS release, median of runs), heights with no
# Flutter (tool/heights_cli.dart), Flutter web, and a stale sidecar.
uc = load("use_cases_macos.json")
U = uc["useCases"]
N["uc_runs"] = uc["runs"]
N["uc_spread_pct"] = 100 * max(uc["speedupSpreadAcrossRuns"].values())
af, ts, pg, bgi = U["autoFit"], U["textScale"], U["pagination"], U["backgroundIsolate"]
srv = load("use_cases_host.json")["server"]
for pre, d in (("uc_fit", af), ("uc_scale", ts), ("uc_page16", pg["at16"]), ("uc_page18", pg["at18"]), ("uc_bg", bgi),
               ("uc_srv", srv)):
    for k, v in d.items():
        N[f"{pre}_{k}"] = v
N["uc_page_paragraphs"] = pg["paragraphs"]
# Cases where the records are reused: auto-fit probes, a new text scale, a new page size.
reuse = [af["textPainterMs"] / af["breakFirstMs"], ts["textPainterMs"] / ts["breakFirstMs"],
         pg["at18"]["textPainterMs"] / pg["at18"]["breakFirstMs"]]
N["uc_reuse_lo"], N["uc_reuse_hi"] = min(reuse), max(reuse)
N["uc_bg_error"] = bgi["textPainterInBackgroundIsolate"].removeprefix("error: ").rstrip(".")
assert bgi["textPainterInBackgroundIsolate"].startswith("error")
assert af["sameSize"] == af["messages"] and ts["heightsEqual"] == ts["messages"]
assert pg["at16"]["samePageBreaks"] and pg["at18"]["samePageBreaks"] and bgi["heightsEqual"] == bgi["messages"]
assert srv["heightsEqual"] == srv["decided"]
web = {}
for r in ("canvaskit", "skwasm"):
    if os.path.exists(os.path.join(FR, f"web_{r}.json")):
        web[r] = load(f"web_{r}.json")
        w = web[r]
        for k in ("identical", "different", "deferred", "heightsEqual"):
            N[f"web_{r}_{k}"] = w["validate"][k]
        N[f"web_{r}_list_speedup"] = w["listExtents"]["textPainterMs"] / w["listExtents"]["breakFirstMs"]
        N[f"web_{r}_fit_speedup"] = w["autoFit"]["textPainterMs"] / w["autoFit"]["breakFirstMs"]
        assert w["listExtents"]["heightsEqual"] == w["listExtents"]["messages"]
        assert w["autoFit"]["sameSize"] == w["autoFit"]["messages"]
wc = web["canvaskit"]
N["web_calibration"] = ", ".join([
    "font sizes truncated to 1/64 px" if wc["fontSizeQuantized"] else "font sizes as given",
    "no kerning across a hard break" if not wc["hardBreakKerns"] else "kerning across a hard break",
]) + (", as on Linux and Android" if wc["fontSizeQuantized"] and not wc["hardBreakKerns"] else "")
assert all(w["fontSizeQuantized"] == wc["fontSizeQuantized"] and w["hardBreakKerns"] == wc["hardBreakKerns"]
           for w in web.values())
N["web_renderers"] = " and ".join({"canvaskit": "CanvasKit", "skwasm": "skwasm (WebAssembly)"}[r] for r in web)


def ms(x):
    return f"{x:,.0f} ms" if x >= 10 else f"{x:.1f} ms"


def fast(a, b):
    return f"<b>{a / b:.1f}×</b>"


qd = quiet["docs"]
uc_rows = [
    (f"Exact extents for a {fmt_int(le['messages'])}-message chat list", f"TextPainter: {ms(le['textPainterMs'])}",
     ms(le["breakFirstMs"]), fast(le["textPainterMs"], le["breakFirstMs"]),
     f"{fmt_int(le['heightsEqual'])} / {fmt_int(le['messages'])} heights"),
    (f"Re-wrap {fmt_int(qd['paragraphs'])} laid-out paragraphs at a new width (resize, rotation)",
     f"re-layout: {ms(qd['relayoutFlutterMs'])}", ms(qd["relayoutBreakFirstMs"]),
     fast(qd["relayoutFlutterMs"], qd["relayoutBreakFirstMs"]), "Table 2"),
    (f"Text scale {ts['fromSize']:g} → {ts['toSize']:g} px: every height again ({fmt_int(ts['messages'])} messages)",
     f"TextPainter: {ms(ts['textPainterMs'])}", ms(ts["breakFirstMs"]), fast(ts["textPainterMs"], ts["breakFirstMs"]),
     f"{fmt_int(ts['heightsEqual'])} / {fmt_int(ts['messages'])} heights"),
    (f"Auto-fit: the largest of {af['sizes']} sizes that keeps a message in {af['maxLines']} lines "
     f"({fmt_int(af['messages'])} messages)", f"TextPainter: {ms(af['textPainterMs'])}", ms(af["breakFirstMs"]),
     fast(af["textPainterMs"], af["breakFirstMs"]), f"{fmt_int(af['sameSize'])} / {fmt_int(af['messages'])} sizes"),
    (f"Paginate {fmt_int(pg['paragraphs'])} paragraphs into {fmt_int(pg['at16']['pages'])} pages",
     f"TextPainter: {ms(pg['at16']['textPainterMs'])}", ms(pg["at16"]["breakFirstMs"]),
     fast(pg["at16"]["textPainterMs"], pg["at16"]["breakFirstMs"]), "every page break"),
    (f"Re-paginate at {pg['at18']['size']:g} px ({fmt_int(pg['at18']['pages'])} pages)",
     f"TextPainter: {ms(pg['at18']['textPainterMs'])}", ms(pg["at18"]["breakFirstMs"]),
     fast(pg["at18"]["textPainterMs"], pg["at18"]["breakFirstMs"]), "every page break"),
    (f"Every height in a background isolate ({fmt_int(bgi['messages'])} messages)", "not possible",
     f"{ms(bgi['workerMs'])} off the UI isolate, {ms(bgi['uiIsolateMs'])} on it", "—",
     f"{fmt_int(bgi['heightsEqual'])} / {fmt_int(bgi['messages'])} heights"),
    (f"Heights on a server, no Flutter ({fmt_int(srv['texts'])} messages)", "not possible",
     f"{ms(srv['cliMedianMs'])}, native executable", "—",
     f"{fmt_int(srv['heightsEqual'])} / {fmt_int(srv['decided'])} decided"),
]
for r, w in web.items():
    name = {"canvaskit": "CanvasKit", "skwasm": "skwasm"}[r]
    l, f = w["listExtents"], w["autoFit"]
    uc_rows.append((f"Flutter web ({name}): chat-list extents", f"TextPainter: {ms(l['textPainterMs'])}",
                    ms(l["breakFirstMs"]), fast(l["textPainterMs"], l["breakFirstMs"]),
                    f"{fmt_int(l['heightsEqual'])} / {fmt_int(l['messages'])} heights"))
    uc_rows.append((f"Flutter web ({name}): auto-fit", f"TextPainter: {ms(f['textPainterMs'])}", ms(f["breakFirstMs"]),
                    fast(f["textPainterMs"], f["breakFirstMs"]),
                    f"{fmt_int(f['sameSize'])} / {fmt_int(f['messages'])} sizes"))
N["uc_table"] = table(["Use case", "Flutter today", "Break-first", "Faster", "Same answers"], uc_rows)
fs = load("failsafe.json")
for name, d in fs.items():
    for k, v in d.items():
        N[f"fs_{name}_{k}"] = v
assert not fs["wider"]["canaryPasses"] and fs["eacute"]["canaryPasses"] and not fs["eacute"]["loadsWithFontBytes"]
assert fs["same"]["loadsWithFontBytes"] and fs["same"]["staleDifferent"] == 0
N["fs_checked"] = fs["eacute"]["staleIdentical"] + fs["eacute"]["staleDifferent"]

# §5.6 compares a warm word cache with break-first: about as fast on docs, slower on chat.
assert N["t_docs_wordCacheWarmMs"] < N["t_docs_breakFirstMs"] * 1.1 and N["t_chat_wordCacheWarmMs"] > N["t_chat_breakFirstMs"]

# Text(...).width and friends against the widgets (flutter_bench/test/text_api_test.dart).
api = load("text_api.json")
cfg = [v for v in api.values() if isinstance(v, dict)]
N["api_configs"] = len(cfg)
N["api_texts"] = sum(v["texts"] for v in cfg)
N["api_answers"] = sum(v["heightEqual"] + v["canFitEqual"] + v["lineCountEqual"] + v.get("widthEqual", 0) for v in cfg)
N["api_different"] = api["different"]
N["api_lines_pct"] = 100 * sum(v["linesFromSidecar"] for v in cfg) / N["api_texts"]
N["api_width_pct"] = 100 * sum(v["widthFromSidecar"] for v in cfg if "widthFromSidecar" in v) / sum(
    v["texts"] for v in cfg if "widthFromSidecar" in v)
N["api_locales"] = sum(1 for k in api if " / locale " in k and k.endswith("/ unbounded"))
assert N["api_different"] == 0

# Jetpack Compose (compose_bench/).
CR = os.path.join(ROOT, "compose_bench", "results")
ce = json.load(open(os.path.join(CR, "compose_exactness.json")))
sizes = [v for k, v in ce.items() if k.endswith(" px") and isinstance(v, dict)]
N["cmp_texts"] = ce["texts"]
N["cmp_layouts"] = ce["layouts"]
N["cmp_identical"] = ce["identical"]
N["cmp_different"] = ce["different"]
N["cmp_sizes_n"] = WORDS[len(sizes)]
N["cmp_sizes"] = ", ".join(k[:-3].removesuffix(".0") for k in ce if k.endswith(" px"))
N["cmp_measurements"] = sum(v["measurements"] for v in sizes)
N["cmp_off_quantum"] = sum(v["offQuantum"] for v in sizes)
N["cmp_per_size"] = sizes[0]["measurements"]
assert all(v["measurements"] == N["cmp_per_size"] for v in sizes)
N["cmp_heights_equal"] = sum(w["heightsEqual"] for v in sizes for w in v["widths"].values())
N["cmp_device"] = f"Android {ce['device']['release']} emulator (API {ce['device']['sdk']})"
assert N["cmp_different"] == 0 and N["cmp_off_quantum"] == 0 and N["cmp_heights_equal"] == N["cmp_identical"]
cs = json.load(open(os.path.join(CR, "compose_speed.json")))
N["cmp_speed_messages"] = cs["messages"]
N["cmp_speed_decided"] = cs["decidedByBreakFirst"]
N["cmp_tm_ms"] = cs["composeMedianMs"]
N["cmp_bf_ms"] = cs["breakFirstMedianMs"]
N["cmp_back_ms"] = cs["handedBackMedianMs"]
N["cmp_speedup"] = cs["speedup"]
N["cmp_speed_reps"] = len(cs["composeTextMeasurerMs"])
assert cs["lineStartsDifferent"] == 0 and cs["lineStartsIdentical"] == cs["decidedByBreakFirst"]

with open(os.path.join(HERE, "numbers.json"), "w") as fp:
    json.dump(N, fp, indent=1, ensure_ascii=False)
print("figures and numbers written:", len(N), "numbers")
