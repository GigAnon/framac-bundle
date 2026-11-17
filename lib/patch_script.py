#!/usr/bin/env python3
"""patch_script.py SRC DST [--list-functions] -- copy frama-c-script, making
every command substitution that calls -print-share-path keep only its first
line (in the bundle, frama-c prints the DUNE_DIR_LOCATIONS entry, then the
baked one).

--list-functions: 'list-functions' runs frama-c with
    -load-module instantiate,frama-c.analysis-scripts
which the bundle's frama-c cannot do (nothing is loaded dynamically; it
failed with "Failed to load plug-in instantiate" in 33.0-1.0/1.1).  Its
library is linked statically instead, guarded by -list-functions
(lib/patch_sources.py), so that is what the command now passes.

Any other -load-module left in the script is reported (it cannot work).
Prints what it changed, and every line mentioning the share dir or frama-c,
so the build log shows how the script finds its files."""
import re
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
list_functions = "--list-functions" in sys.argv
src, dst = args[0], args[1]
text = open(src).read()
out, changed = [], 0
LOADMOD = "-load-module instantiate,frama-c.analysis-scripts"
loadmod_left = []
pat = re.compile(r"(-print-(?:share|lib)-path)(?!\s*\|\s*head)(?=[\s\"')`])")
for n, line in enumerate(text.splitlines(True), 1):
    if re.search(r"-print-(share|lib)-path", line) and ("$(" in line or "`" in line) and not line.lstrip().startswith("#"):
        new = pat.sub(r"\1 | head -n 1", line)
        if new != line:
            changed += 1
            print("patched %d: %s" % (n, new.rstrip()))
        line = new
    elif list_functions and LOADMOD in line and not line.lstrip().startswith("#"):
        line = line.replace(LOADMOD, "-list-functions")
        changed += 1
        print("patched %d: %s" % (n, line.rstrip()))
    elif re.search(r"share|frama-c\b|FRAMAC|python|BASH_SOURCE|dirname", line):
        print("      %d: %s" % (n, line.rstrip()))
    if "-load-module" in line and not line.lstrip().startswith("#"):
        loadmod_left.append(n)
    out.append(line)
open(dst, "w").write("".join(out))
print("frama-c-script: %d substitution(s) patched" % changed)
for n in loadmod_left:
    print("WARNING: frama-c-script line %d still uses -load-module, which the bundle's frama-c cannot do" % n)
