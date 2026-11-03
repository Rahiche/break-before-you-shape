"""Turn bfl's proven-mode output (results_proven.txt) into the markdown table in RESEARCH.md."""
import re
import sys

text = open(sys.argv[1] if len(sys.argv) > 1 else "results_proven.txt").read()
print("| Font | S / P / K / U | islands checked (m, shapes) | lines certified | certified but wrong "
      "| hybrid breaks = truth (decisions shaped) | ns/char |")
print("|---|--:|--:|--:|--:|--:|--:|")
parts = text.split("\n== ")[1:]
# Each font prints a "[proven]" certificate block followed by its regular stats block.
for head, body in zip(parts[0::2], parts[1::2]):
    block = head + body
    name = head.split(" [proven]")[0].lstrip(".")
    g = lambda pat: re.search(pat, block).group(1)
    s, p, k, u = (g(rf"{c} (\d+)") for c in ("S", "P", "K", "U"))
    print(f"| {name} | {s} / {p} / {k} / {u} | {g(r'islands up to m=(\d+)')} ({int(g(r'(\d+) shapes')):,}) "
          f"| {g(r'certified\) lines ([\d.]+)%')}% | {g(r'of which wrong (\d+)')} "
          f"| {g(r'hybrid ([\d.]+)%')}% ({g(r'shaped ([\d.]+)% of decisions')}%) "
          f"| {g(r'break-first v2 ([\d.]+) ns/char')} |")
