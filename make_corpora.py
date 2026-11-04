"""Extra corpora from local files only (one paragraph per line, whitespace collapsed).

  en_man    paragraphs of rendered man pages (technical prose)
  en_legal  paragraphs of license texts found on disk (legal prose)
  ui_xx     user-interface strings from macOS localizations (on Linux, from
            gettext catalogues): short, chat-like messages in English, German,
            French, Russian, Ukrainian and Greek
  sea_*     Thai, Lao, Khmer and Burmese (macOS only; see sea_corpora below)

usage: make_corpora.py outdir [sea]   ("sea": only the Thai/Lao/Khmer/Burmese ones)
"""
import gettext
import glob
import json
import os
import plistlib
import random
import re
import shutil
import subprocess
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def _native(s, lo, hi):
    return sum(1 for c in s if lo <= ord(c) <= hi)


def sea_corpora():
    """Corpora for the dictionary line breaker (Thai, Lao, Khmer, Burmese).

      ui_th      Thai UI strings: th.lproj/*.strings and the "th" entries of
                 *.loctable under /System/Library and /Applications
      names_xx   locale display names (languages, regions, currencies, months)
                 in th, lo, km, my, from the system's CLDR data through
                 Foundation (needs swift)
      vocab_xx   CoreEmoji's search vocabulary words in th, lo, km, my, joined
                 2 to 7 at a time without spaces (a seeded pseudo-random order),
                 a few such runs per line separated by spaces: long runs that
                 exercise the engines' lookahead

    macOS has no Lao, Khmer or Burmese UI localization (km/lo/my.lproj only in
    CoreEmoji, mostly untranslated), hence the names and vocabularies."""
    blocks = {"th": (0x0E00, 0x0E7F), "lo": (0x0E80, 0x0EFF), "km": (0x1780, 0x17FF), "my": (0x1000, 0x109F)}

    def write_sea(name, paras, cap):
        write(name, [p.replace("\n", " ") for p in paras], cap)

    # Thai UI strings.
    files = []
    for pat in ["/System/Library/**/th.lproj/*.strings", "/Applications/*.app/Contents/Resources/th.lproj/*.strings",
                "/Applications/*.app/Contents/Frameworks/*.framework/Versions/A/Resources/th.lproj/*.strings"]:
        files += glob.glob(pat, recursive=True)
    paras = []
    for path in sorted(set(files)):
        try:
            js = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True,
                                timeout=10).stdout
            values = json.loads(js).values() if js.strip().startswith("{") else []
        except Exception:
            continue
        paras += [v for v in values if isinstance(v, str) and _native(v, *blocks["th"]) >= 8]
    for path in sorted(glob.glob("/System/Library/**/*.loctable", recursive=True)):
        try:
            with open(path, "rb") as fp:
                table = plistlib.load(fp).get("th", {})
        except Exception:
            continue
        paras += [v for v in table.values() if isinstance(v, str) and _native(v, *blocks["th"]) >= 8]
    write_sea("ui_th", paras, 8000)

    # Locale display names, through Foundation.
    if shutil.which("swift"):
        src = os.path.join(out, "_names.swift")
        with open(src, "w") as fp:
            fp.write(_NAMES_SWIFT)
        res = subprocess.run(["swift", src] + list(blocks), capture_output=True, text=True, timeout=600).stdout
        os.remove(src)
        names = {l: [] for l in blocks}
        for line in res.splitlines():
            lang, _, s = line.partition("\t")
            if lang in names and _native(s, *blocks[lang]) >= 4:
                names[lang].append(s)
        for lang, paras in names.items():
            write_sea(f"names_{lang}", paras, 4000)

    # Vocabulary runs.
    root = "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources"
    for lang, (lo, hi) in blocks.items():
        try:
            with open(f"{root}/{lang}.lproj/vocabulary.plist", "rb") as fp:
                vocab = plistlib.load(fp)
        except Exception:
            continue
        words = sorted({w.replace("​", "") for w in vocab if isinstance(w, str) and _native(w, lo, hi) >= 1})
        if not words:
            continue
        rng = random.Random(f"vocab_{lang}")
        paras = []
        for _ in range(3000):
            runs = ["".join(rng.choice(words) for _ in range(rng.randint(2, 7))) for _ in range(rng.randint(1, 4))]
            paras.append(" ".join(runs))
        write_sea(f"vocab_{lang}", paras, 3000)


_NAMES_SWIFT = r"""
import Foundation
for lang in CommandLine.arguments.dropFirst() {
    let loc = Locale(identifier: lang)
    var out = Set<String>()
    for c in Locale.LanguageCode.isoLanguageCodes { if let s = loc.localizedString(forLanguageCode: c.identifier) { out.insert(s) } }
    for c in Locale.Region.isoRegions { if let s = loc.localizedString(forRegionCode: c.identifier) { out.insert(s) } }
    for c in Locale.Currency.isoCurrencies { if let s = loc.localizedString(forCurrencyCode: c.identifier) { out.insert(s) } }
    for id in Locale.availableIdentifiers { if let s = loc.localizedString(forIdentifier: id) { out.insert(s) } }
    let f = DateFormatter()
    f.locale = loc
    for a in [f.monthSymbols, f.weekdaySymbols, f.standaloneMonthSymbols, f.quarterSymbols, f.eraSymbols] {
        for s in a ?? [] { out.insert(s) }
    }
    for s in out.sorted() { print("\(lang)\t\(s)") }
}
"""


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


if sys.argv[2:] == ["sea"]:
    sea_corpora()
    sys.exit(0)


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

if sys.platform == "darwin":
    sea_corpora()
