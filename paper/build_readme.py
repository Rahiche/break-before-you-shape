"""Fills the README's results and use-case tables from numbers.json (make_figures.py),
between the <!-- results --> and <!-- usecases --> markers, so the README states
the paper's numbers."""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
README = os.path.join(os.path.dirname(HERE), "README.md")
N = json.load(open(os.path.join(HERE, "numbers.json")))


def i(k):
    return f"{N[k]:,}"


def x(v):
    return f"{v:.1f}×"


results = [
    (f"Font census (HarfBuzz): {N['census_faces']} local font faces",
     f"{i('census_certified')} of {i('census_lines')} lines certified ({N['census_certified_share']:.0f}%), "
     f"**{N['census_wrong']} wrong**; {N['census_ge99']} faces certify ≥ 99% of lines"),
    (f"Font census (Flutter): {N['fcensus_checked']} faces, each sidecar built through Flutter",
     f"**{N['fcensus_identical']:,}** decided layouts identical, {N['fcensus_different']} different"),
    ("Flutter, macOS release: line breaks and heights vs Flutter's own layout",
     f"**{i('mac_identical')} of {N['mac_identical'] + N['mac_different']:,}** paragraph layouts identical "
     f"({i('mac_lines')} lines; {N['w_corpora']} corpora, {N['w_languages']} languages, {N['w_sizes']} font sizes, "
     f"{N['w_widths']} widths); {N['mac_deferredPct']:.2f}% handed back to Flutter"),
    ("Same sidecar on the iOS simulator / Android emulator",
     f"{i('ios_identical')} of {N['ios_identical'] + N['ios_different']:,} / "
     f"{i('android_identical')} of {N['android_identical'] + N['android_different']:,} identical"),
    (f"On GitHub Actions: Linux, macOS, iOS simulator, Android emulator "
     f"([run](flutter_bench/results/ci/run-{N['ci_run']}))",
     f"**{i('ci_identical')}** layouts identical, 0 different"),
    ("Flutter web (" + N["web_renderers"] + ", Chrome)",
     f"**{i('web_canvaskit_identical')}** layouts identical, {N['web_canvaskit_different']} different"),
    ("Letter and word spacing, height multiplier, `maxLines`, hard line breaks (macOS release)",
     f"**{i('styles_identical')}** layouts identical, 0 different"),
    ("Hebrew and Arabic (alone and mixed with Latin), Japanese, Chinese, Korean",
     f"**{i('scripts_identical')}** layouts identical, 0 different; the other "
     f"{N['scripts_layouts'] - N['scripts_identical']:,} handed to Flutter"),
    (f"{N['beyond_rows']} further checks: struts, font features, rich text, fallback fonts, combining marks, pointed "
     "Hebrew, vowelled Arabic, emoji, Indic, Thai, Lao, Khmer, Burmese",
     f"**{i('beyond_identical')}** layouts identical, {N['beyond_different']} different"),
    ("Speed vs `TextPainter` (macOS release, median of 3 runs)",
     f"**{x(N['t_docs_speedup_tp'])}** (docs), **{x(N['t_chat_speedup_tp'])}** (chat); re-wrap at a new width "
     f"{x(N['t_docs_speedup_relayout'])} / {x(N['t_chat_speedup_relayout'])}"),
    ("Speed on GitHub Actions (docs / chat)",
     f"{x(N['ci_macos_docs_speedup'])} / {x(N['ci_macos_chat_speedup'])} macOS (virtual M1), "
     f"{x(N['ci_linux_docs_speedup'])} / {x(N['ci_linux_chat_speedup'])} Linux, "
     f"{x(N['ci_android_docs_speedup'])} / {x(N['ci_android_chat_speedup'])} Android emulator"),
    ("C port of the breaker through `dart:ffi`",
     f"same line starts in all {i('native_checked')} checks; {x(N['native_docs_speedup'])} / "
     f"{x(N['native_chat_speedup'])} faster than the Dart breaker, so the package stays in Dart"),
    ("Sidecar for Roboto (Latin, Greek, Cyrillic)",
     f"{i('build_bytes')} bytes, {i('build_gzipBytes')} gzipped, one file for every font size and style option"),
    ("Today's shortcuts vs exact ground truth (HarfBuzz)",
     f"shape once then break: up to {100 - N['c_shapefirst_min']:.1f}% of paragraphs wrong; per-word cache: up to "
     f"{100 - N['c_wordcache_min']:.1f}%"),
]


def md_table(head, rows):
    return "\n".join(["| " + " | ".join(head) + " |", "|" + "---|" * len(head)] +
                     ["| " + " | ".join(r) + " |" for r in rows])


def from_html(html):
    """The rows of make_figures.py's HTML use-case table, as markdown cells."""
    rows = re.findall(r"<tr>(.*?)</tr>", html, re.S)
    cells = [re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", r, re.S) for r in rows]
    clean = lambda c: re.sub(r"</?b>", "**", re.sub(r"<(?!/?b>)[^>]+>", "", c))
    return [clean(c) for c in cells[0]], [[clean(c) for c in r] for r in cells[1:]]


demo = (f"A chat list of {N['demo_messages']:,} messages on the Android emulator, release build "
        "([video](media/list_extents_android.mp4)).\n"
        f"The stock `ListView` asked for #{N['demo_stock_to']:,} lands on #{N['demo_stock_at']:,}, in a "
        f"{N['demo_stock_ms']:.0f} ms frame. With break-first extents it lands on #{N['demo_bf_at']:,}\n"
        f"in a {N['demo_bf_ms']:.0f} ms frame. All {N['demo_equal']:,} extents equal `TextPainter`'s "
        "([measured log](media/list_extents_android_measured.txt)).")


def fill(path, marker, body):
    text = open(path).read()
    text, n = re.subn(rf"(<!-- {marker} -->\n).*?(<!-- /{marker} -->)", lambda m: m[1] + body + "\n" + m[2], text,
                      flags=re.S)
    assert n == 1, (path, marker)
    open(path, "w").write(text)


head, rows = from_html(N["uc_table"])
fill(README, "results", md_table(["", ""], results))
fill(README, "usecases", md_table(head, rows))
fill(README, "demo", demo)

# native/README.md: the C port against the Dart breaker (macOS: median of runs).
FR = os.path.join(os.path.dirname(HERE), "flutter_bench", "results")
mac = json.load(open(os.path.join(FR, "native_macos.json")))["runs"]
emu = json.load(open(os.path.join(FR, "native_android_emu.json")))["runs"]
med = lambda xs: sorted(xs)[len(xs) // 2]


def col(runs, key, f):
    return med([f(r[key]) for r in runs])


def row(label, f):
    return [label] + [f(r) for r in (mac, emu)]


def dart_c(runs, key, a="dartMs", b="cBatchMs"):
    return (f"{col(runs, key, lambda d: d[a]):.1f} → {col(runs, key, lambda d: d[b]):.1f} ms "
            f"({col(runs, key, lambda d: d[a] / d[b]):.1f}×)")


d0, c0 = mac[0]["docs"], mac[0]["chat"]
saved = [col(r, "chat", lambda d: d["endToEndDartMs"] - d["endToEndCMs"]) for r in (mac, emu)]
native = "\n".join([
    f"Exactness: the line starts match the Dart breaker in {mac[0]['exactness']['checked']:,} of "
    f"{mac[0]['exactness']['checked']:,} checks (9 corpora, 6 sizes, 12 widths) on macOS, and in "
    f"{emu[0]['exactness']['checked']:,} of {emu[0]['exactness']['checked']:,} on the Android emulator. CI repeats the "
    "check on Linux and macOS (`test/native_exact_test.dart`).",
    "",
    f"Speed: macOS is the median of {len(mac)} runs on an Apple M3 "
    "([native_macos.json](../flutter_bench/results/native_macos.json)). The Android emulator (arm64, on the same Mac) is "
    f"{len(emu)} run ([native_android_emu.json](../flutter_bench/results/native_android_emu.json)).",
    "",
    md_table(["", "macOS: Dart → C", "Android emulator: Dart → C"], [
        row(f"Breaker, docs ({d0['paragraphs']:,} paragraphs)", lambda r: dart_c(r, "docs")),
        row(f"Breaker, chat ({c0['paragraphs']:,} messages)", lambda r: dart_c(r, "chat")),
        row("Re-wrap at a new width, docs / chat", lambda r: " / ".join(
            f"{col(r, k, lambda d: d['rewrapDartMs'] / d['rewrapCMs']):.1f}×" for k in ("docs", "chat"))),
        row("Heights end to end, chat (fallbacks to Flutter included)",
            lambda r: f"{col(r, 'chat', lambda d: d['endToEndDartMs'] / d['endToEndCMs']):.1f}×"),
        row("TextPainter for the same chat heights", lambda r: f"{col(r, 'chat', lambda d: d['textPainterMs']):,.0f} ms"),
    ]),
    "",
    f"Per code unit on the Mac, the Dart breaker takes {col(mac, 'chat', lambda d: d['dartNsPerCodeUnit']):.1f} ns and C "
    f"{col(mac, 'chat', lambda d: d['cBatchNsPerCodeUnit']):.1f} ns (chat), copying the text into native memory "
    f"included ({col(mac, 'chat', lambda d: d['cCopyMs'] * 1e6 / d['codeUnits']):.1f} ns). One call per paragraph costs "
    f"{col(mac, 'chat', lambda d: d['cPerCallMs']):.1f} ms against {col(mac, 'chat', lambda d: d['cBatchMs']):.1f} ms "
    "batched.",
    "",
    "## Verdict",
    "",
    f"C is {col(mac, 'docs', lambda d: d['dartMs'] / d['cBatchMs']):.1f}× (docs) and "
    f"{col(mac, 'chat', lambda d: d['dartMs'] / d['cBatchMs']):.1f}× (chat) faster than the Dart breaker on the Mac, "
    f"and exact. The Dart breaker is itself {col(mac, 'docs', lambda d: d['textPainterMs'] / d['dartMs']):.0f}× (docs) "
    f"and {col(mac, 'chat', lambda d: d['textPainterMs'] / d['dartMs']):.0f}× (chat) cheaper than `TextPainter` on the "
    f"same work; for {c0['paragraphs']:,} chat messages, C saves another {saved[0]:.0f} ms on the Mac and "
    f"{saved[1]:.0f} ms on the emulator. The package keeps the Dart breaker, which runs on the web (no `dart:ffi` there) "
    "and in any isolate with no native build per platform. This port stays as a measured, exactness-checked option.",
])
assert all(r["exactness"]["mismatched"] == 0 for r in mac + emu)
fill(os.path.join(os.path.dirname(HERE), "native", "README.md"), "native", native)
print("README tables written")
