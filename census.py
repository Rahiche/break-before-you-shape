"""Certificate census over every local font face that covers basic Latin.

For each face: run certify.py (static certificate), then bfl in proven mode on a
corpus sample (1,000 paragraphs, 3 widths), which checks every certified
ground-truth line against HarfBuzz with the island tables. One JSON line per face
goes to census/results.jsonl.

usage: census.py [workers]
"""
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from fontTools.ttLib import TTCollection, TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "census")
ROOTS = ["/System/Library/Fonts", "/Library/Fonts"]
LATIN = [ord(c) for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:!?'\"()-"]
ENV = dict(os.environ, BFL_LIMIT="1000", BFL_WIDTHS="14,26,41", BFL_NOPROBE="1", BFL_NOBENCH="1")


def faces():
    for root in ROOTS:
        for dirpath, _, files in os.walk(root):
            for f in sorted(files):
                if not f.lower().endswith((".ttf", ".otf", ".ttc")):
                    continue
                path = os.path.join(dirpath, f)
                try:
                    if f.lower().endswith(".ttc"):
                        n = len(TTCollection(path, lazy=True).fonts)
                    else:
                        n = 1
                except Exception:
                    continue
                for i in range(n):
                    yield path, i


def covers_latin(path, i):
    try:
        font = TTFont(path, fontNumber=i, lazy=True)
        cmap = font.getBestCmap() or {}
        return all(c in cmap for c in LATIN), font["name"].getDebugName(4) or os.path.basename(path)
    except Exception:
        return False, None


def run(job):
    path, i, name, k = job
    cert = os.path.join(OUT, "certs", f"{k}.cert")
    row = {"path": path, "index": i, "name": name}
    c = subprocess.run([sys.executable, os.path.join(HERE, "certify.py"), f"{path}:{i}", cert, "4", "hb"],
                       capture_output=True, text=True, timeout=1800)
    first = next((l for l in c.stdout.splitlines() if re.search(r": S \d+", l)), None)
    if c.returncode or not first:
        row["error"] = "certify: " + (c.stderr.strip().splitlines() or ["no output"])[-1][:200]
        return row
    m = re.search(r"S (\d+)\s+P (\d+)\s+K (\d+)\s+U (\d+).*?~([\d.]+)%", first)
    row.update(S=int(m[1]), P=int(m[2]), K=int(m[3]), U=int(m[4]), textShare=float(m[5]))
    reasons = re.findall(r"\[(.+)\]", c.stdout)
    row["uReasons"] = reasons[-1] if reasons else ""
    b = subprocess.run([os.path.join(HERE, "bfl"), os.path.join(HERE, "corpus.txt"), f"{path}:{i}@{cert}"],
                       capture_output=True, text=True, timeout=3600, env=ENV)
    out = b.stdout
    g = re.search(r"islands up to m=(\d+) verified: (\d+) islands, (\d+) shapes", out)
    t = re.search(r"island-table certified lines (\d+)/(\d+) \(([\d.]+)%\), of which wrong (\d+), max err (\d+)", out)
    d = re.search(r"distill ([\d.]+)s \| repertoire (\d+) \| glyph-changing pairs (\d+) \| residuals (\d+)", out)
    e = re.search(r"model width exact ([\d.]+)%", out)
    if not (g and t and d):
        row["error"] = "bfl: " + (b.stderr.strip().splitlines() or ["no output"])[-1][:200]
        return row
    row.update(m=int(g[1]), islands=int(g[2]), islandShapes=int(g[3]), lines=int(t[2]), certified=int(t[1]),
               certifiedPct=float(t[3]), wrong=int(t[4]), maxErr=int(t[5]), distillSec=float(d[1]),
               repertoire=int(d[2]), glyphChangingPairs=int(d[3]), residuals=int(d[4]),
               empiricalExactPct=float(e[1]) if e else None)
    return row


def main():
    workers = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    os.makedirs(os.path.join(OUT, "certs"), exist_ok=True)
    jobs, seen = [], 0
    for path, i in faces():
        seen += 1
        ok, name = covers_latin(path, i)
        if ok:
            jobs.append((path, i, name, len(jobs)))
    print(f"{seen} faces found, {len(jobs)} cover basic Latin", flush=True)
    done = 0
    with open(os.path.join(OUT, "results.jsonl"), "w") as fp, ThreadPoolExecutor(workers) as ex:
        for row in ex.map(run, jobs):
            fp.write(json.dumps(row) + "\n")
            fp.flush()
            done += 1
            if done % 25 == 0:
                print(f"{done}/{len(jobs)}", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
