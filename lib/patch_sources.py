#!/usr/bin/env python3
"""
patch_sources.py FRAMA_C_SOURCE_TREE

Small, checked changes to the Frama-C sources that the statically linked
bundle needs.  Idempotent: an already patched file is reported and left alone.
Prints one line per file; the last line is "patched: N" (N files changed by
this run), so the build knows whether Frama-C must be rebuilt.  Exits 1 if a
file it knows about no longer has the expected text.

share/analysis-scripts/list_functions.ml (frama-c.analysis-scripts)
    frama-c-script list-functions runs
        frama-c ... -no-autoload-plugins -load-module instantiate,frama-c.analysis-scripts
    The bundle's frama-c loads nothing dynamically, so this library has to be
    linked into it; but the module ends with
        let () = Boot.Main.extend run
    which, once linked, would print the function list on *every* run.  It is
    guarded by a new boolean option -list-functions, which frama-c-script is
    patched to pass instead of -load-module (lib/patch_script.py).
"""
import os
import sys

MARK = "(* fcai: patched by framac-bundle lib/patch_sources.py *)"

LIST_FUNCTIONS_OLD = "let () = Boot.Main.extend run"
LIST_FUNCTIONS_NEW = MARK + """
(* frama-c is linked statically in the bundle, with this module always
   present: run only when asked (frama-c-script list-functions passes it) *)
module Enabled =
  Self.False
    (struct
      let option_name = "-list-functions"
      let help = "print the list of functions (used by frama-c-script \\
                  list-functions)"
    end)

let () = Boot.Main.extend (fun () -> if Enabled.get () then run ())"""


def patch_list_functions(tree):
    path = os.path.join(tree, "share", "analysis-scripts", "list_functions.ml")
    rel = os.path.relpath(path, tree)
    if not os.path.exists(path):
        print("%s: absent, nothing to do" % rel)
        return 0
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if MARK in text:
        print("%s: already patched" % rel)
        return 0
    lines = text.split("\n")
    hits = [i for i, l in enumerate(lines) if l.strip() == LIST_FUNCTIONS_OLD]
    if len(hits) != 1 or "module Self" not in text:
        sys.exit("%s: expected exactly one line '%s' and a module Self; found %d line(s) "
                 "-- Frama-C changed, update lib/patch_sources.py" % (rel, LIST_FUNCTIONS_OLD, len(hits)))
    lines[hits[0]] = LIST_FUNCTIONS_NEW
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("%s: patched (runs only with -list-functions)" % rel)
    return 1


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(sys.argv) == 2 else 2
    n = patch_list_functions(sys.argv[1])
    print("patched: %d" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
