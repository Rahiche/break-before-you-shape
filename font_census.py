"""Prepares the Flutter font census: every local face that covers basic Latin is
written to a scratch folder as a single-face font file (faces of collections are
extracted with fontTools), certified twice (default features, and without
ligatures for letter-spaced text), and listed in a manifest that
flutter_bench/test/font_census_test.dart reads. Nothing here is redistributed:
the fonts stay in the scratch folder.

usage: font_census.py <scratch dir> [max faces]
Font folders: CENSUS_ROOTS (colon-separated), default the macOS system folders.
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from fontTools.ttLib import TTCollection, TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census  # noqa: E402  (faces(), covers_latin())

if os.environ.get("CENSUS_ROOTS"):
    census.ROOTS = os.environ["CENSUS_ROOTS"].split(":")
out = os.path.abspath(sys.argv[1])
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10 ** 9
os.makedirs(out, exist_ok=True)
freq = ":".join(p for p in [os.path.join(HERE, "corpus.txt")] + [os.path.join(HERE, "corpora", f) for f in
                sorted(os.listdir(os.path.join(HERE, "corpora")))] if os.path.exists(p)) \
    if os.path.isdir(os.path.join(HERE, "corpora")) else ""
freq = ":".join(p for p in freq.split(":") if not any(x in p for x in ("ui_he", "ui_ar", "ui_ja", "ui_zh", "ui_ko")))

jobs, seen = [], set()
for path, i in census.faces():
    ok, name = census.covers_latin(path, i)
    if not ok or name in seen:
        continue
    seen.add(name)
    jobs.append((path, i, name, len(jobs)))
    if len(jobs) >= limit:
        break


def prepare(job):
    path, i, name, k = job
    font = os.path.join(out, f"f{k}.ttf")
    try:
        if path.lower().endswith(".ttc"):
            TTCollection(path)[i].save(font)
        else:
            TTFont(path).save(font)
    except Exception as e:
        return {"name": name, "source": f"{path}:{i}", "error": f"extract: {e}"}
    row = {"name": name, "source": f"{path}:{i}", "font": font}
    for key, off in (("cert", ""), ("nolig", "liga,clig,calt")):
        cert = os.path.join(out, f"f{k}.{key}")
        env = dict(os.environ, CERTIFY_SCRIPTS="latin+greek+cyrillic", CERTIFY_FREQ_FILES=freq, CERTIFY_FEATURES_OFF=off)
        r = subprocess.run([sys.executable, os.path.join(HERE, "certify.py"), font, cert, "4"], env=env,
                           capture_output=True, text=True, timeout=3600)
        if r.returncode or not os.path.exists(cert):
            row["error"] = f"certify {key}: {r.stderr.strip().splitlines()[-1:] or r.returncode}"
            return row
        row[key] = cert
    return row


with ThreadPoolExecutor(int(os.environ.get("CENSUS_WORKERS", "6"))) as ex:
    rows = list(ex.map(prepare, jobs))
with open(os.path.join(out, "manifest.json"), "w") as fp:
    json.dump(rows, fp, indent=1)
print(f"{sum('cert' in r and 'error' not in r for r in rows)} of {len(rows)} faces ready in {out}")
