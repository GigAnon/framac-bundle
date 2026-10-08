#!/usr/bin/env python3
"""patch_script.py SRC DST -- copy frama-c-script, making every command
substitution that calls -print-share-path keep only its first line (in the
bundle, frama-c prints the DUNE_DIR_LOCATIONS entry, then the baked one).
Prints what it changed, and every line mentioning the share dir or frama-c,
so the build log shows how the script finds its files."""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
out, changed = [], 0
pat = re.compile(r"(-print-(?:share|lib)-path)(?!\s*\|\s*head)(?=[\s\"')`])")
for n, line in enumerate(text.splitlines(True), 1):
    if re.search(r"-print-(share|lib)-path", line) and ("$(" in line or "`" in line) and not line.lstrip().startswith("#"):
        new = pat.sub(r"\1 | head -n 1", line)
        if new != line:
            changed += 1
            print("patched %d: %s" % (n, new.rstrip()))
        line = new
    elif re.search(r"share|frama-c\b|FRAMAC|python|BASH_SOURCE|dirname", line):
        print("      %d: %s" % (n, line.rstrip()))
    out.append(line)
open(dst, "w").write("".join(out))
print("frama-c-script: %d -print-share/lib-path substitution(s) patched" % changed)
