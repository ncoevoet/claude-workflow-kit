#!/usr/bin/env python3
"""compare.py A.jsonl B.jsonl — per-task pass rate, mean cost and duration, and the tasks that flipped.

A task "flipped" when its pass count differs between the variants; with 3 runs per task, a 1-run
difference is noise-level and is labelled as such, not as a regression.
"""
import json, statistics, sys
from collections import defaultdict


def load(path):
    rows = defaultdict(list)
    for line in open(path):
        if line.strip():
            r = json.loads(line)
            rows[r["task"]].append(r)
    return rows


def mean(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.mean(xs) if xs else float("nan")


a, b = load(sys.argv[1]), load(sys.argv[2])
print(f"{'task':22} {'pass A':>7} {'pass B':>7} {'$ A':>7} {'$ B':>7} {'s A':>6} {'s B':>6}  flip")
tot = defaultdict(float)
for t in sorted(set(a) | set(b)):
    ra, rb = a.get(t, []), b.get(t, [])
    pa, pb = sum(r["pass"] for r in ra), sum(r["pass"] for r in rb)
    ca, cb = mean(r.get("cost_usd") for r in ra), mean(r.get("cost_usd") for r in rb)
    da, db = mean(r.get("duration_ms") for r in ra) / 1000, mean(r.get("duration_ms") for r in rb) / 1000
    flip = "" if pa == pb else ("noise" if abs(pa - pb) == 1 else ("B worse" if pb < pa else "B better"))
    print(f"{t:22} {pa:>3}/{len(ra):<3} {pb:>3}/{len(rb):<3} {ca:7.3f} {cb:7.3f} {da:6.0f} {db:6.0f}  {flip}")
    tot["pa"] += pa; tot["pb"] += pb; tot["na"] += len(ra); tot["nb"] += len(rb)
print(f"{'TOTAL':22} {int(tot['pa']):>3}/{int(tot['na']):<3} {int(tot['pb']):>3}/{int(tot['nb']):<3}")
