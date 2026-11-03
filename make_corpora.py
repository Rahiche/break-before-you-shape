"""Extra corpora from local files only (one paragraph per line, whitespace collapsed).

  en_man    paragraphs of rendered man pages (technical prose)
  en_legal  paragraphs of license texts found on disk (legal prose)
  ui_xx     user-interface strings from macOS localizations (on Linux, from
            gettext catalogues): short, chat-like messages in English, German,
            French, Russian, Ukrainian and Greek

usage: make_corpora.py outdir
"""
import gettext
import glob
import json
import os
import re
import subprocess
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def prose(p, min_words=8):
    words = p.split(" ")
    return len(words) >= min_words and sum(any(c.isalpha() for c in w) for w in words) >= 0.7 * len(words)


def write(name, paras, cap):
    seen, keep = set(), []
    for p in paras:
        p = " ".join(p.split())
        if p and p not in seen:
            seen.add(p)
            keep.append(p)
        if len(keep) >= cap:
            break
    with open(os.path.join(out, name + ".txt"), "w", encoding="utf-8") as fp:
        fp.write("\n".join(keep) + "\n")
    print(f"{name}: {len(keep)} paragraphs, {sum(map(len, keep))} characters")


# Man pages, rendered with mandoc to plain text.
pages = sorted(glob.glob("/usr/share/man/man1/*.1")) or sorted(glob.glob("/usr/share/man/man1/*.1.gz"))
paras = []
for page in pages:
    try:
        txt = subprocess.run(["mandoc", "-T", "utf8", "-O", "width=1000", page], capture_output=True, text=True,
                             timeout=10).stdout
    except Exception:
        continue
    txt = re.sub(r".\x08", "", txt)  # drop overstrike bold/underline
    for block in re.split(r"\n\s*\n", txt):
        lines = [l.strip() for l in block.splitlines()]
        p = " ".join(lines)
        if prose(p, 12) and not p.isupper():
            paras.append(p)
    if len(paras) > 8000:
        break
write("en_man", paras, 5000)

# License texts.
paras = []
patterns = [os.path.expanduser("~/.pub-cache/hosted/pub.dev/*/LICENSE"), "/opt/homebrew/Cellar/*/*/LICENSE*",
            "/opt/homebrew/Cellar/*/*/COPYING*", "/usr/share/doc/*/LICENSE*", "/usr/share/common-licenses/*",
            "/usr/share/doc/*/copyright"]
for pat in patterns:
    for path in sorted(glob.glob(pat)):
        try:
            txt = open(path, encoding="utf-8").read()
        except Exception:
            continue
        for block in re.split(r"\n\s*\n", txt):
            p = " ".join(l.strip() for l in block.splitlines())
            if prose(p, 10):
                paras.append(p)
write("en_legal", paras, 3000)

def gettext_strings(lang):
    """Messages from gettext catalogues (Linux): translations, or for English the
    source strings of every catalogue."""
    roots = ["/usr/share/locale", "/usr/share/locale-langpack"]
    langs = ["de", "fr", "ru", "uk", "el", "he", "ar"] if lang == "en" else [lang]
    out = []
    for root in roots:
        for l in langs:
            for path in sorted(glob.glob(f"{root}/{l}/LC_MESSAGES/*.mo")):
                try:
                    with open(path, "rb") as fp:
                        catalog = gettext.GNUTranslations(fp)._catalog
                except Exception:
                    continue
                for k, v in catalog.items():
                    if not isinstance(k, str) or not k:
                        continue
                    out.append(k.split("\x04")[-1] if lang == "en" else v)
    return out


# UI strings from macOS localizations.
CJK = {"ja", "zh_CN", "ko"}  # no spaces between words: a length test instead of a word count
for lang in ["en", "de", "fr", "ru", "uk", "el", "he", "ar", "ja", "zh_CN", "ko"]:
    dirs = [f"{lang}.lproj"] + (["English.lproj", "Base.lproj"] if lang == "en" else []) + \
        (["zh-Hans.lproj"] if lang == "zh_CN" else [])
    files = []
    for d in dirs:
        files += glob.glob(f"/System/Library/CoreServices/**/{d}/*.strings", recursive=True)
        files += glob.glob(f"/System/Library/PrivateFrameworks/*.framework/Versions/A/Resources/{d}/*.strings")
    paras = []
    for path in sorted(set(files)):
        try:
            js = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True,
                                timeout=10).stdout
            values = json.loads(js).values() if js.strip().startswith("{") else []
        except Exception:
            continue
        for v in values:
            if isinstance(v, str) and (len(v.split()) >= 4 or (lang in CJK and len(v) >= 8)):
                paras.append(v)
        if len(paras) > 20000:
            break
    if not files:
        paras = [v for v in gettext_strings(lang)
                 if isinstance(v, str) and (len(v.split()) >= 4 or (lang in CJK and len(v) >= 8))]
    write(f"ui_{lang}", paras, 4000)
