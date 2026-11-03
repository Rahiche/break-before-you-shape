"""For every census face certified on fewer than 99% of lines, the reason behind its
most frequent unsafe character, grouped into categories. Writes census/reasons.json.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
CATEGORIES = [
    (r"kerx", "kerx state machine"),
    (r"kern format|kern subtable", "kern state machine"),
    (r"morx type [05]", "AAT insertion / rearrangement"),
    (r"morx|mort|island lemma|end of text|DontAdvance", "AAT contextual / ligature (unprovable)"),
    (r"GSUB contextual|GPOS contextual", "contextual lookup on common letters"),
    (r"single/multiple|alternate", "substitution on common letters"),
    (r"PairPos|cursive|mark attachment|ignores", "non-pair positioning"),
    (r"GDEF mark", "letters classed as marks"),
    (r"fraction", "fraction slash"),
]


def category(reason):
    for pat, name in CATEGORIES:
        if re.search(pat, reason):
            return name
    return "other"


def run(row):
    with tempfile.NamedTemporaryFile(suffix=".cert") as tmp:
        out = subprocess.run([sys.executable, os.path.join(HERE, "certify.py"), f"{row['path']}:{row['index']}",
                              tmp.name, "4", "hb"], capture_output=True, text=True, timeout=1800).stdout
    m = re.search(r"top unsafe: U\+\w+ (.*)", out)
    return f"{row['name']} ({os.path.basename(row['path'])}:{row['index']})", category(m[1] if m else "")


rows = [json.loads(l) for l in open(os.path.join(HERE, "census", "results.jsonl"))]
low = [r for r in rows if r["certifiedPct"] < 99]
with ThreadPoolExecutor(6) as ex:
    reasons = dict(ex.map(run, low))
json.dump(reasons, open(os.path.join(HERE, "census", "reasons.json"), "w"), indent=1)
from collections import Counter
print(len(reasons), Counter(reasons.values()).most_common())
