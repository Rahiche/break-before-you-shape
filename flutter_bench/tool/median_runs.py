"""Joins separate app runs (BF_OUT files) into one result: the median of every number
across runs, other values required equal, and for each case timed both ways the
spread of the speedup across runs ((max - min) / median of TextPainter / break-first).

usage: median_runs.py key out.json run1.json run2.json ...
  key: the part of each run to join ("timing" or "useCases")
"""
import json
import statistics
import sys

key, out, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
runs = [json.load(open(p))[key] for p in paths]


def join(vals, path):
    first = vals[0]
    if isinstance(first, bool) or isinstance(first, str) or first is None:
        if any(v != first for v in vals):
            raise SystemExit(f"{path}: differs between runs: {vals}")
        return first
    if isinstance(first, (int, float)):
        return statistics.median(vals)
    if isinstance(first, dict):
        return {k: join([v[k] for v in vals], f"{path}/{k}") for k in first}
    if any(v != first for v in vals):
        raise SystemExit(f"{path}: differs between runs")
    return first


def spreads(rs, prefix=""):
    """(max - min) / median of textPainterMs / breakFirstMs, per case that has both."""
    out = {}
    for k, v in rs[0].items():
        if isinstance(v, dict):
            if "textPainterMs" in v and "breakFirstMs" in v:
                s = [r[k]["textPainterMs"] / r[k]["breakFirstMs"] for r in rs]
                out[prefix + k] = (max(s) - min(s)) / statistics.median(s)
            else:
                out.update(spreads([r[k] for r in rs], f"{prefix}{k}/"))
    return out


result = {
    "mode": key, "runs": len(runs), key: join(runs, key), "perRun": runs,
    "speedupSpreadAcrossRuns": spreads(runs),
    "note": f"median of {len(runs)} app runs; each run reports the median of its passes per method",
}
json.dump(result, open(out, "w"), indent=1)
print(out, {k: round(v, 3) for k, v in result["speedupSpreadAcrossRuns"].items()})
