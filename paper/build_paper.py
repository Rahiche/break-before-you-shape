"""Builds paper.html (and paper.pdf with Chrome) from paper.template.html.

Placeholders, all filled from numbers.json (written by make_figures.py from
result files):
  {{key}} or {{key:fmt}}      a number, with an optional Python format spec
  {{=expr}} or {{=expr:fmt}}  an expression over the numbers
  {{svg:file}}                an inlined figure
  {{classes_sample}}          sample text coloured by Roboto's certificate classes
The build fails if any placeholder is left unfilled.
"""
import datetime
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
N = json.load(open(os.path.join(HERE, "numbers.json")))
N["date"] = datetime.date.today().isoformat()

cert = {}
for line in open(os.path.join(ROOT, "flutter_bench", "assets", "roboto.cert"), encoding="utf-8"):
    parts = line.split()
    if len(parts) == 3 and not line.startswith("#"):
        cert[int(parts[0], 16)] = parts[2]
SAMPLE = "Official staff will file the fluffy reports — Київ, Αθήνα; only ⁄, į and ј are unsafe."


def classes_sample():
    out = []
    for ch in SAMPLE:
        c = cert.get(ord(ch), "U")
        shown = "&nbsp;" if ch == " " else ch
        out.append(f'<span class="c-{c}" title="{c}">{shown}</span>')
    return "".join(out)


FMT = re.compile(r"^[,.\d]*[dfeg%]?$")


def fill(m):
    body = m.group(1).strip()
    if body.startswith("svg:"):
        svg = open(os.path.join(HERE, body[4:]), encoding="utf-8").read()
        return svg[svg.index("<svg"):]
    if body == "classes_sample":
        return classes_sample()
    if body == "date":
        return N["date"]
    fmt = ""
    if ":" in body:
        head, tail = body.rsplit(":", 1)
        if FMT.match(tail):
            body, fmt = head, tail
    value = eval(body[1:], {"len": len, "min": min, "max": max}, N) if body.startswith("=") else N[body]
    return format(value, fmt)


template = open(os.path.join(HERE, "paper.template.html"), encoding="utf-8").read()
html = re.sub(r"\{\{(.+?)\}\}", fill, template)
assert "{{" not in html, "unfilled placeholder"
with open(os.path.join(HERE, "paper.html"), "w", encoding="utf-8") as fp:
    fp.write(html)
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
pdf = os.path.join(HERE, "paper.pdf")
subprocess.run([chrome, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", f"--print-to-pdf={pdf}",
                "file://" + os.path.join(HERE, "paper.html")],
               # Not captured: Chrome's helpers can outlive it and keep a pipe open.
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
print("paper.html", len(html), "bytes;", "paper.pdf", os.path.getsize(pdf) if os.path.exists(pdf) else "missing")
