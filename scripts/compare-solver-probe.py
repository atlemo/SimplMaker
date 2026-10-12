#!/usr/bin/env python3
"""Compares two SolverCorpusProbe outputs (see Tests/CADCoreTests/SolverCorpusProbe.swift): same status, and how far the solved
points moved between the two runs.   scripts/compare-solver-probe.py before.json after.json"""
import json, sys
a = {(r["file"], r["sketch"], r["scenario"]): r for r in json.load(open(sys.argv[1]))}
b = {(r["file"], r["sketch"], r["scenario"]): r for r in json.load(open(sys.argv[2]))}
worst, status_changes, missing = 0.0, 0, 0
for k, ra in a.items():
    rb = b.get(k)
    if rb is None: missing += 1; continue
    if ra["status"] != rb["status"]: status_changes += 1; print("STATUS", k, ra["status"], "->", rb["status"])
    d = max((max(abs(p[0] - rb["points"][i][0]), abs(p[1] - rb["points"][i][1])) for i, p in ra["points"].items() if i in rb["points"]), default=0)
    if d > 0: print(f"{k[0][:26]:26} {k[1][:16]:16} {k[2]:7} moved {d:.3e} mm   iterations {ra['iterations']} -> {rb['iterations']}")
    worst = max(worst, d)
ta, tb = sum(r["seconds"] for r in a.values()), sum(r["seconds"] for r in b.values())
print(f"{len(a)} solves, {missing} missing, {status_changes} status changes, largest move {worst:.3e} mm, time {ta:.2f} s -> {tb:.2f} s")
