#!/usr/bin/env python3
# MOCK lib/analysis-scripts/find_fun.py
import os, re, sys
def _first(lines: list[int], n: int) -> int | None: return None   # 3.10+ syntax, like the real function_finder.py
fun, dirs = sys.argv[1], sys.argv[2:] or ["."]
pat = re.compile(r"\b%s\s*\(" % re.escape(fun))
hits = [os.path.join(r, f) for d in dirs for r, _, fs in os.walk(d) for f in fs
        if f.endswith(".c") and pat.search(open(os.path.join(r, f)).read())]
print("Possible definitions for function %s:" % fun)
for h in sorted(hits): print("  " + h)
sys.exit(0 if hits else 1)
