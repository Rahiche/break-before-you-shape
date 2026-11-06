"""Builds paper.html (and paper.pdf with Chrome) from paper.template.html.

Placeholders, filled from numbers.json (written by make_numbers.py from result files):
  {{key}} or {{key:fmt}}      a number, with an optional Python format spec
  {{=expr}} or {{=expr:fmt}}  an expression over the numbers
  {{svg:file}}                an inlined figure
  {{style}}                   the companion paper's stylesheet
The build fails if any placeholder is left unfilled.
"""
import datetime
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
N = json.load(open(os.path.join(HERE, "numbers.json")))
N["date"] = datetime.date.today().isoformat()
main = open(os.path.join(HERE, "..", "paper.template.html"), encoding="utf-8").read()
STYLE = main[main.index("<style>"):main.index("</style>") + len("</style>")]
FMT = re.compile(r"^[,.\d]*[dfeg%]?$")


def fill(m):
    body = m.group(1).strip()
    if body.startswith("svg:"):
        svg = open(os.path.join(HERE, body[4:]), encoding="utf-8").read()
        return svg[svg.index("<svg"):]
    if body == "style":
        return STYLE
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
html = html.replace("<table>", '<div class="scroll"><table>').replace("</table>", "</table></div>")
with open(os.path.join(HERE, "paper.html"), "w", encoding="utf-8") as fp:
    fp.write(html)
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
pdf = os.path.join(HERE, "paper.pdf")
subprocess.run([chrome, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", f"--print-to-pdf={pdf}",
                "file://" + os.path.join(HERE, "paper.html")],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
print("paper.html", len(html), "bytes;", "paper.pdf", os.path.getsize(pdf) if os.path.exists(pdf) else "missing")
