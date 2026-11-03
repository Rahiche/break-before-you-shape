"""Turn bfl's results.txt into the markdown table used in RESEARCH.md."""
import re
import sys

text = open(sys.argv[1] if len(sys.argv) > 1 else "results.txt").read()
rows = []
for block in text.split("\n== ")[1:]:
    name = block.split(" (upem")[0].lstrip(".")
    g = lambda pat: re.search(pat, block).group(1)
    rows.append([
        name,
        f"{g(r'glyph-changing pairs (\d+)')} / {g(r'residuals (\d+)')}",
        g(r"model ([\d.]+) KB"),
        g(r"distill ([\d.]+)s"),
        g(r"model width exact ([\d.]+)%").rstrip("0").rstrip(".") + "%",
        g(r"model v1 [\d.]+% v2 ([\d.]+)%").rstrip("0").rstrip(".") + "%",
        g(r"hybrid ([\d.]+)%").rstrip("0").rstrip(".") + "% (" + g(r"shaped ([\d.]+)% of decisions") + "%)",
        g(r"shape-first ([\d.]+)% \|").rstrip("0").rstrip(".") + "%",
        g(r"word-cache ([\d.]+)%\n").rstrip("0").rstrip(".") + "%",
        g(r"break-first v2 ([\d.]+) ns/char"),
        g(r"\| shape-first ([\d.]+) ns/char"),
        g(r"warm word-cache ([\d.]+) ns/char"),
        g(r"pass C only\): ([\d.]+) ns/char"),
    ])

def table(head, cols):
    print("| " + " | ".join(head) + " |")
    print("|" + "|".join("---" if i == 0 else "--:" for i in range(len(head))) + "|")
    for r in rows:
        print("| " + " | ".join(r[c] for c in cols) + " |")

print("**Accuracy** (share of paragraphs whose breaks equal ground truth)\n")
table(["Font", "glyph-changing pairs / width residuals", "model KB", "distill s", "model widths exact",
       "break-first", "hybrid (decisions shaped)", "shape-first", "word cache"], [0, 1, 2, 3, 4, 5, 6, 7, 8])
print("\n**Speed** (ns per byte of UTF-8 input, one M3 core)\n")
for r in rows:
    r.append(f"{float(r[10]) / float(r[9]):.0f}x")
table(["Font", "break-first", "shape-first (no reshape)", "warm word cache", "rewrap (pass C only)",
       "vs shape-first"], [0, 9, 10, 11, 12, 13])
