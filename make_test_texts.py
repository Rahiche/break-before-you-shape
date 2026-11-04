"""Test texts derived from the UI corpora (run make_corpora.py first), written
next to them in corpora/:

  ui_xx_nfd.txt      French, German, Greek, Russian, Ukrainian strings in NFD
                     ("é" as "e" + U+0301): combining marks HarfBuzz recomposes
  ui_ar_vowelled.txt Arabic strings in NFD with random harakat (and shadda)
  ui_he_pointed.txt  Hebrew strings with random niqqud (and dagesh)
  ui_hi/bn/ta.txt    Hindi, Bengali and Tamil UI strings from macOS localizations

usage: make_test_texts.py [corpora dir]
"""
import glob
import json
import os
import random
import subprocess
import sys
import unicodedata

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpora")
rnd = random.Random(11)


def lines(name):
    return [l.rstrip("\n") for l in open(os.path.join(out, f"{name}.txt"), encoding="utf-8") if l.strip()]


def write(name, rows):
    with open(os.path.join(out, f"{name}.txt"), "w", encoding="utf-8") as fp:
        fp.write("\n".join(rows) + "\n")
    print(name, len(rows))


for name in ["ui_fr", "ui_de", "ui_el", "ui_ru", "ui_uk"]:
    nfd = [unicodedata.normalize("NFD", l) for l in lines(name)]
    write(f"{name}_nfd", [l for l in nfd if any(unicodedata.combining(c) for c in l)][:3000])

harakat = ["َ", "ُ", "ِ", "ْ", "ً", "ٌ", "ٍ"]
rows = []
for l in lines("ui_ar"):
    s = ""
    for ch in unicodedata.normalize("NFD", l):
        s += ch
        if 0x628 <= ord(ch) <= 0x64A and rnd.random() < 0.5:
            s += ("ّ" if rnd.random() < 0.15 else "") + rnd.choice(harakat)
    rows.append(s)
write("ui_ar_vowelled", rows)

points = ["ְ", "ִ", "ַ", "ָ", "ּ", "ֹ", "ֶ", "ֵ"]
rows = []
for l in lines("ui_he"):
    s = ""
    for ch in l:
        s += ch
        if 0x5D0 <= ord(ch) <= 0x5EA and rnd.random() < 0.6:
            s += ("ּ" if rnd.random() < 0.2 else "") + rnd.choice(points)
    rows.append(s)
write("ui_he_pointed", rows)

for lang in ["hi", "bn", "ta"]:
    files = glob.glob(f"/System/Library/CoreServices/**/{lang}.lproj/*.strings", recursive=True)
    files += glob.glob(f"/System/Library/PrivateFrameworks/*.framework/Versions/A/Resources/{lang}.lproj/*.strings")
    paras = []
    for path in sorted(set(files)):
        try:
            js = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True,
                                timeout=10).stdout
            values = json.loads(js).values() if js.strip().startswith("{") else []
        except Exception:
            continue
        paras += [v.strip() for v in values if isinstance(v, str) and len(v.split()) >= 4 and "\n" not in v
                  and any(0x900 <= ord(c) < 0xE00 for c in v)]
        if len(paras) > 20000:
            break
    paras = sorted(set(paras))
    random.Random(5).shuffle(paras)
    write(f"ui_{lang}", paras[:3000])
