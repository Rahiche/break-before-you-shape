"""Figures and numbers for "Shape the Line, Not the Paragraph", from result files only.

Reads ../../flutter_bench/results/ideas_*.json and ideas_machine.txt. Writes fig_*.svg
and numbers.json. Every number in the paper comes from numbers.json, and every claim
the text makes about them is asserted here.
"""
import json
import os
import statistics

import matplotlib

matplotlib.use("svg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
FR = os.path.join(HERE, "..", "..", "flutter_bench", "results")
INK, MUTED, GRID = "#1f2328", "#6e7781", "#d8dee4"
C_WHOLE, C_PARA, C_LINE = "#8c959f", "#d4a72c", "#0969da"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 8.5, "axes.edgecolor": MUTED, "axes.labelcolor": INK,
    "xtick.color": INK, "ytick.color": INK, "axes.spines.top": False, "axes.spines.right": False,
    "svg.fonttype": "path", "figure.constrained_layout.use": True,
    "axes.titlesize": 9, "axes.titleweight": "bold", "axes.titlelocation": "left",
})
N = {}


def load(name):
    with open(os.path.join(FR, name)) as fp:
        return json.load(fp)


def save(fig, name):
    fig.savefig(os.path.join(HERE, name), bbox_inches="tight", transparent=True)
    plt.close(fig)


# Machine.
for line in open(os.path.join(FR, "ideas_machine.txt")):
    k, v = line.split(":", 1)
    if k == "flutter" and "flutter_version" not in N:
        N["flutter_version"] = v.split("•")[0].strip().replace("Flutter ", "")
    elif k in ("cpu", "os", "android_emulator"):
        N[k] = v.strip()

# Same pixels: one result file per renderer.
renderers = [
    ("px", "ideas_pixels_macos.json", "macOS, Impeller (Metal)"),
    ("skia", "ideas_pixels_macos_skia.json", "macOS, Skia"),
    ("emu", "ideas_pixels_android_emu.json", "Android emulator, Impeller (OpenGL ES)"),
]
rows = []
for key, f, label in renderers:
    p = load(f)["pixels"]
    N[f"{key}_cases"], N[f"{key}_identical"] = p["cases"], p["identical"]
    N[f"{key}_different"] = p["different"]
    N[f"{key}_share"] = 100 * p["identical"] / p["cases"]
    N[f"{key}_controls"] = p["controlEighthPxShift"]["cases"]
    N[f"{key}_controls_seen"] = p["controlEighthPxShift"]["seenAsDifferent"]
    assert N[f"{key}_controls"] == N[f"{key}_controls_seen"], f"{key}: the control was not seen every time"
    assert p["sidecarStartsDifferFromFlutter"] == 0 and p["heightsDiffer"] == 0 and p["lineWrappedWhenAlone"] == 0
    # Differing cases per size (each counted once, at its first differing line).
    by = {}
    for k, v in p["firstDifferentLineByDistance"].items():
        size = k.split("px")[0]
        by[size] = by.get(size, 0) + v
    sizes = sorted({k.split("px")[0] for k in p["linesByDistanceAlongShapedLine"]}, key=float)
    N[f"{key}_sizes"] = ", ".join(f"{float(s):g}" for s in sizes)
    for s in sizes:
        N[f"{key}_diff_{float(s):g}".replace(".", "_")] = by.get(s, 0)
    assert by.get("16.0", 0) == 0, f"{key}: a case differs at 16 px"
    # Where differing comparisons start along the shaped line: the nearest bucket.
    order = ["<2048", "2048-4096", "4096-8192", "8192+"]
    words = {"<2048": "under 2,048", "2048-4096": "beyond 2,048", "4096-8192": "beyond 4,096", "8192+": "beyond 8,192"}
    for s_ in sizes:
        bs = [k.split(" ", 1)[1] for k in p["firstDifferentLineByDistance"] if k.split("px")[0] == s_]
        N[f"{key}_far_{float(s_):g}".replace(".", "_")] = words[min(bs, key=order.index)] if bs else "none differ"
    if "perSize" in p:
        for s, v in p["perSize"].items():
            t = f"{float(s):g}".replace(".", "_")
            N[f"{key}_cases_{t}"], N[f"{key}_identical_{t}"] = v["cases"], v["identical"]
    N[f"{key}_lines"] = p["linesPerConfig"]
    rows.append((label, p))
N["px_max_channel"] = load("ideas_pixels_macos.json")["pixels"]["maxChannelDiff"]
N["px_configs"] = len(load("ideas_pixels_macos.json")["pixels"]["perConfig"])
cb = load("ideas_pixels_macos.json")["pixels"]["characterBoxes"]
N["px_probed_identical"] = sum(cb["identicalImages"].values())
N["px_probed_identical_boxes_differ"] = sum(v for k, v in cb["identicalImages"].items() if k != "zero")
N["px_probed_different"] = sum(cb["differentImages"].values())
N["px_probed_different_boxes_same"] = cb["differentImages"].get("zero", 0)

# Drift: each line's largest position error, in its paragraph and alone, per size.
d = load("ideas_drift_macos.json")["drift"]
N["drift_width"], N["drift_paragraphs"] = d["width"], d["paragraphs"]
for size in ("12.0", "14.0", "16.0", "18.4"):
    v, t = d[size], f"drift_{float(size):g}".replace(".", "_")
    for f in ("lines", "farthestLineStartPx", "maxWholeErrPx", "maxAloneErrPx", "linesWithWholeErr", "linesWithAloneErr"):
        N[f"{t}_{f}"] = v[f]
    assert v["maxAloneErrPx"] <= v["maxWholeErrPx"]
for size in ("12", "14", "16"):
    assert N[f"drift_{size}_maxWholeErrPx"] == 0 and N[f"drift_{size}_maxAloneErrPx"] == 0, f"{size} px positions not exact"
assert N["drift_18_4_maxAloneErrPx"] < N["drift_18_4_maxWholeErrPx"] / 10
v = d["18.4"]
fig, ax = plt.subplots(figsize=(6.6, 2.6))
floor = 1e-6
ax.scatter([max(x, 1) for x in v["alongPx"]], [max(w, floor) for w in v["wholeErrPx"]], s=4, color=C_WHOLE,
           label="in its paragraph (Flutter's layout)", alpha=0.7, linewidths=0)
ax.scatter([max(x, 1) for x in v["alongPx"]], [max(w, floor) for w in v["aloneErrPx"]], s=4, color=C_LINE,
           label="drawn alone (one-line paragraph)", alpha=0.7, linewidths=0)
xs = [2 ** e for e in range(4, 15)]
ax.step(xs, [2.0 ** (e - 23) for e in range(4, 15)], where="post", color=INK, lw=0.8, ls="--",
        label="float32 step at that distance")
ax.set_xscale("log")
ax.set_yscale("log")
ax.set_ylim(floor * 0.7, 1e-2)
ax.set_xlabel("where the line starts along the paragraph's one shaped line (px)")
ax.set_ylabel("largest error of a\ncharacter's position (px)")
ax.set_title(f"Position error per line, 18.4 px text, {v['lines']:,} lines (errors below 1e-6 px drawn at 1e-6)")
ax.grid(True, color=GRID, lw=0.5)
ax.legend(frameon=False, fontsize=7.5, loc="upper left")
save(fig, "fig_drift.svg")

# Long text: line breaks against Flutter, and the first frame.
lt = load("ideas_long_macos.json")["long"]
N["long_viewport"], N["long_visible"] = lt["viewportPx"], lt["linesInViewport"]
N["long_size"], N["long_width"] = lt["fontSize"], lt["width"]
over = []
for n in ("10000", "50000", "200000"):
    v = lt[n]
    k = f"long_{int(n) // 1000}k"
    for f in ("chars", "lines", "paragraphs", "paragraphsHandedBack", "paragraphsSameAsFlutterAlone",
              "paragraphsWhereTheWholeTextBreaksDifferently", "ofWhichFlutterAloneAgreesWithTheSidecar",
              "firstFrameWholeMs", "firstFrameLineByLineMs", "ofWhichBreakingMs", "firstFrameSpeedup",
              "jumpToMiddleWholeMs", "jumpToMiddleLineByLineMs", "wholeTextPxAlong"):
        N[f"{k}_{f}"] = v[f]
    assert v["paragraphsSameAsFlutterAlone"] == v["paragraphs"], f"{n}: a paragraph differs from Flutter alone"
    assert v["ofWhichFlutterAloneAgreesWithTheSidecar"] == v["paragraphsWhereTheWholeTextBreaksDifferently"]
    over += v["whereTheWholeTextDiffers"]
N["long_paragraphs_all"] = sum(lt[n]["paragraphs"] for n in ("10000", "50000", "200000"))
N["long_10k_same"] = lt["10000"]["lineStartsSameAsWholeText"]
assert N["long_10k_same"] and lt["10000"]["paragraphsWhereTheWholeTextBreaksDifferently"] == 0
# The 200,000-character text starts with the shorter ones: its paragraphs alone.
over = lt["200000"]["whereTheWholeTextDiffers"]
assert len(over) == lt["200000"]["paragraphsWhereTheWholeTextBreaksDifferently"]
measured = [o for o in over if "handedBack" not in o]
N["long_differs_handed_back"] = len(over) - len(measured)
N["long_differs_measured"] = len(measured)
N["long_differs_nearest"] = min(o["lineStartsPxAlong"] for o in measured)
assert N["long_differs_nearest"] > 100000, "a paragraph near the start breaks differently"
first = min(measured, key=lambda o: o["lineStartsPxAlong"])
N["long_first_excess"], N["long_first_step"] = first["exactWidthPx"] - first["boxPx"], first["float32StepThere"]
N["long_first_step_inv"] = 1 / first["float32StepThere"]
assert 0 < N["long_first_excess"] <= N["long_first_step"], "the first difference is not a line one step too wide"
wide = [o for o in measured if o["exactWidthPx"] > o["boxPx"]]
short = [o for o in measured if o["exactWidthPx"] < o["boxPx"]]
N["long_wide"], N["long_short"] = len(wide), len(short)
N["long_wide_max"] = max(o["exactWidthPx"] - o["boxPx"] for o in wide)
N["long_short_max"] = max(o["boxPx"] - o["exactWidthPx"] for o in short)
N["long_short_nearest"] = min(o["lineStartsPxAlong"] for o in short)
far = [o for o in measured if o["lineStartsPxAlong"] >= 1e6]
N["long_far"] = len(far)
assert far and all(o["exactWidthPx"] < o["boxPx"] - 10 for o in far), "past 1,000,000 px a line is not short by over 10 px"
N["long_far_short_min"] = min(o["boxPx"] - o["exactWidthPx"] for o in far)
N["long_200k_heightSame"] = lt["200000"]["heightSameAsWholeText"]
fig, ax = plt.subplots(figsize=(3.3, 2.3))
labels = [f"{lt[n]['chars'] / 1000:.0f}k" for n in ("10000", "50000", "200000")]
x = range(3)
ax.bar([i - 0.2 for i in x], [lt[n]["firstFrameWholeMs"] for n in ("10000", "50000", "200000")], 0.38,
       color=C_WHOLE, label="one Text")
ax.bar([i + 0.2 for i in x], [lt[n]["firstFrameLineByLineMs"] for n in ("10000", "50000", "200000")], 0.38,
       color=C_LINE, label="line by line")
ax.set_xticks(list(x), [f"{l} chars" for l in labels])
ax.set_ylabel("first frame (ms)")
ax.set_title("A long text's first frame")
ax.legend(frameon=False, fontsize=7.5)
ax.grid(True, axis="y", color=GRID, lw=0.5)
save(fig, "fig_long.svg")

# Streaming.
s = load("ideas_streaming_macos.json")["streaming"]
e = s["exactness"]
for f in ("answers", "characters", "steps", "sameLineStarts", "heightsEqual", "stepsFlutterDecided"):
    N[f"stream_{f}"] = e[f]
assert e["different"] == 0 and e["heightsEqual"] == e["steps"]
N["stream_size"], N["stream_width"] = s["fontSize"], s["width"]
T = s["timing"]
for name, k in (("docs 500", "s500"), ("docs 2000", "s2000"), ("docs 8000", "s8000"), ("one paragraph", "sone")):
    v = T[name]
    N[f"{k}_chars"], N[f"{k}_tokens"], N[f"{k}_answers"] = v["meanChars"], v["tokens"], v["answers"]
    N[f"{k}_para_chars"] = v["meanParagraphChars"]
    for m in ("wholeText", "perParagraph", "lineByLine"):
        N[f"{k}_{m}_us"] = v[m]["usPerToken"]
        N[f"{k}_{m}_late_us"] = v[m]["usPerTokenInLastTenth"]
        N[f"{k}_{m}_ms"] = v[m]["streamMs"]
    N[f"{k}_x_whole"], N[f"{k}_x_para"] = v["speedupOverWholeText"], v["speedupOverPerParagraph"]
lates = [N[f"{k}_lineByLine_late_us"] for k in ("s500", "s2000", "s8000", "sone")]
N["stream_line_late_min"], N["stream_line_late_max"] = min(lates), max(lates)
assert N["s8000_wholeText_late_us"] > 10 * N["s8000_lineByLine_late_us"]
assert N["s8000_x_para"] < 2 and N["sone_x_para"] > 4
fig, ax = plt.subplots(figsize=(3.3, 2.3))
lens = [N[f"{k}_chars"] for k in ("s500", "s2000", "s8000")]
for m, c, lab in (("wholeText", C_WHOLE, "one Text"), ("perParagraph", C_PARA, "one Text per paragraph"),
                  ("lineByLine", C_LINE, "line by line")):
    ax.plot(lens, [N[f"{k}_{m}_late_us"] for k in ("s500", "s2000", "s8000")], marker="o", ms=3.5, color=c, label=lab)
ax.set_xscale("log")
ax.set_yscale("log")
ax.set_xlabel("answer length (characters)")
ax.set_ylabel("µs per token, last tenth")
ax.set_title("Streaming an answer")
ax.legend(frameon=False, fontsize=7.5)
ax.grid(True, color=GRID, lw=0.5)
save(fig, "fig_stream.svg")

json.dump(N, open(os.path.join(HERE, "numbers.json"), "w"), indent=1, sort_keys=True)
print(len(N), "numbers")
