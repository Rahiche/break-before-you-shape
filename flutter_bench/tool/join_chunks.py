"""Rebuilds the bench app's JSON result from the numbered chunks it prints
(BFJSON:i/n:...), as captured from logcat or a console.

usage: join_chunks.py log out.json
"""
import json
import re
import sys

chunks, total = {}, None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.search(r"BFJSON:(\d+)/(\d+):(.*?)\r?$", line)
    if m:
        chunks[int(m[1])] = m[3]
        total = int(m[2])
if total is None or len(chunks) != total:
    sys.exit(f"incomplete: {len(chunks)} of {total} chunks")
result = json.loads("".join(chunks[i] for i in range(total)))
with open(sys.argv[2], "w") as fp:
    json.dump(result, fp, indent=1)
print("wrote", sys.argv[2])
