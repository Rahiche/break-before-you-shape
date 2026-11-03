"""Summarises a benchmark run's result files as a Markdown table, and writes
them all into one JSON file.

usage: ci_summary.py <dir with downloaded artifacts> <combined.json>

Validation files hold a "validate" map (one entry per corpus); timing files hold
"timing". Timing runs of one platform (*_timing_run*.json) are combined by
median.
"""
import glob
import json
import os
import statistics
import sys

root, combined_path = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
combined, rows, timing = {}, [], {}

for path in files:
    name = os.path.splitext(os.path.basename(path))[0]
    try:
        d = json.load(open(path))
    except Exception:
        continue
    combined[name] = d
    if "validate" in d:
        v = [c for c in d["validate"].values() if isinstance(c, dict) and "identical" in c]
        s = {k: sum(c[k] for c in v) for k in ("identical", "different", "deferred", "lines", "heightIdentical", "heightChecked")}
        rows.append((name, d.get("platform", "?"), s, d.get("canary", {}), d.get("fontSizeQuantized"), len(v)))
    if "timing" in d:
        timing.setdefault(name.split("_timing_run")[0], []).append(d["timing"])


def n(x):
    return f"{x:,}"


out = ["## Exactness: line breaks and heights vs Flutter's own layout", "",
       "| Run | Platform | Corpora | Identical | Different | Deferred | Lines | Heights equal | Canary | Size quantized |",
       "|---|---|---|---|---|---|---|---|---|---|"]
for name, platform, s, canary, quant, corpora in rows:
    out.append(f"| {name} | {platform} | {corpora} | {n(s['identical'])} | **{n(s['different'])}** | {n(s['deferred'])} | "
               f"{n(s['lines'])} | {n(s['heightIdentical'])} of {n(s['heightChecked'])} | "
               f"{'pass' if canary.get('pass') else 'FAIL'} ({canary.get('maxErrPx', 0):.2g} px) | {quant} |")

styles = [(n, d) for n, d in combined.items() if "styles" in d]
if styles:
    out += ["", "## Style options and hard line breaks: line breaks and heights vs Flutter", "",
            "| Run | Option | Identical | Different | Deferred | Heights equal |", "|---|---|---|---|---|---|"]
    for name, d in sorted(styles):
        for opt, r in d["styles"].items():
            if isinstance(r, dict) and "identical" in r:
                heights = r.get("heightIdentical", r.get("heightsEqual", 0))
                checked = r.get("heightChecked", r.get("layouts", 0))
                out.append(f"| {name} | {opt} | {n(r['identical'])} | **{n(r['different'])}** | {n(r['deferred'])} | "
                           f"{n(heights)} of {n(checked)} |")

rtl = [(n, d) for n, d in combined.items() if "font" in d and "pairClasses" in d or "font" in d and any(k.startswith("mixed") for k in d)]
if rtl:
    out += ["", "## Right-to-left, mixed-direction and CJK paragraphs (UI strings)", "",
            "| Run | Case | Identical | Different | Deferred | Heights equal |", "|---|---|---|---|---|---|"]
    for name, d in sorted(rtl):
        for case, r in d.items():
            if isinstance(r, dict) and "identical" in r:
                out.append(f"| {name} | {case} | {n(r['identical'])} | **{n(r['different'])}** | {n(r['deferred'])} | "
                           f"{n(r['heightsEqual'])} |")

if timing:
    out += ["", "## Speed vs TextPainter (median over runs)", "",
            "| Platform | Runs | Docs | Chat | Re-wrap docs | Re-wrap chat | List extents (break-first / TextPainter) |",
            "|---|---|---|---|---|---|---|"]
    for platform, runs in sorted(timing.items()):
        def med(f):
            vals = [f(t) for t in runs if f(t) is not None]
            return statistics.median(vals) if vals else None

        def speed(label, a, b):
            return med(lambda t: t[label][a] / t[label][b] if label in t else None)

        docs, chat = speed("docs", "textPainterMs", "breakFirstMs"), speed("chat", "textPainterMs", "breakFirstMs")
        rdocs = speed("docs", "relayoutFlutterMs", "relayoutBreakFirstMs")
        rchat = speed("chat", "relayoutFlutterMs", "relayoutBreakFirstMs")
        bf = med(lambda t: t.get("listExtents", {}).get("breakFirstMs"))
        tp = med(lambda t: t.get("listExtents", {}).get("textPainterMs"))
        fmt = lambda x: "—" if x is None else f"{x:.1f}×"
        lst = "—" if bf is None else f"{bf:.0f} ms / {tp:.0f} ms ({tp / bf:.1f}×)"
        out.append(f"| {platform} | {len(runs)} | {fmt(docs)} | {fmt(chat)} | {fmt(rdocs)} | {fmt(rchat)} | {lst} |")

for path in files:
    if os.path.basename(path) == "break_first_test.json":
        d = json.load(open(path))
        g = d.get("generated", {})
        out += ["", f"Package tests on {d.get('os')}: sidecar rebuilt identical: {d.get('build', {}).get('identicalToShipped')}; "
                    f"generated text: {n(g.get('identical', 0))} identical, {n(g.get('different', 0))} different, "
                    f"{n(g.get('deferred', 0))} deferred."]

text = "\n".join(out)
print(text)
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as fp:
        fp.write(text + "\n")
with open(combined_path, "w") as fp:
    json.dump(combined, fp, indent=1)
