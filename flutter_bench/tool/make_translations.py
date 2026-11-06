"""Parallel UI translations from macOS localizations, for the build-time overflow
check: every string key that a .strings file has in English and in each of the
other languages, with all its translations.

usage: python3 tool/make_translations.py out.json
"""
import glob
import json
import os
import subprocess
import sys

LANGS = ["en", "de", "fr", "ru", "uk", "el"]
NAMES = {"en": ["en", "English", "Base"], "de": ["de", "German"], "fr": ["fr", "French"]}


def strings(path):
    try:
        js = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True,
                            timeout=10).stdout
        d = json.loads(js) if js.strip().startswith("{") else {}
    except Exception:
        return {}
    return {k: v for k, v in d.items() if isinstance(v, str) and v.strip()}


out, seen = [], set()
roots = glob.glob("/System/Library/CoreServices/**/en.lproj", recursive=True) + \
    glob.glob("/System/Library/PrivateFrameworks/*.framework/Versions/A/Resources/en.lproj")
for en_dir in sorted(roots):
    parent = os.path.dirname(en_dir)
    for en_file in sorted(glob.glob(f"{en_dir}/*.strings")):
        name = os.path.basename(en_file)
        tables = {}
        for lang in LANGS:
            for d in NAMES.get(lang, [lang]):
                p = f"{parent}/{d}.lproj/{name}"
                if os.path.exists(p):
                    tables[lang] = strings(p)
                    break
        if len(tables) < len(LANGS):
            continue
        for k, en in tables["en"].items():
            row = {lang: tables[lang].get(k) for lang in LANGS}
            if any(v is None for v in row.values()) or len(en) > 200:
                continue
            sig = tuple(row[lang] for lang in LANGS)
            if sig in seen:
                continue
            seen.add(sig)
            out.append({"key": f"{name}:{k}", **row})
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False)
print(len(out), "strings in", len(LANGS), "languages")
