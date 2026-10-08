#!/usr/bin/env python3
"""
gen_completion.py APPRUN OUT.bash [--provers "z3 cvc4 ..."] [--dump-dir DIR]

Generate a self-contained bash completion script for the bundle's frama-c,
ivette and frama-c-script, from the bundled frama-c's own help:
    frama-c -plugins          -> plug-ins and their "-<x>-h" help options
    frama-c -kernel-h, -<x>-h -> every option, "<arg>" and "-no-" opposites
    frama-c -machdep help     -> machdeps
    frama-c-script help       -> sub-commands
Everything is baked into the script: completing never starts frama-c (an
AppImage would be mounted on every TAB), and the script works outside the
AppImage.  The raw outputs go to DUMP_DIR for inspection.
"""
import os
import re
import subprocess
import sys

OPT_LINE = re.compile(r"^\s{0,2}(-[A-Za-z0-9][\w-]*(?:\s*,\s*-[A-Za-z0-9][\w-]*)*)(?:\s+<([^>]*)>)?")
OPPOSITE = re.compile(r"opposite\s+option\s+is\s+(-[A-Za-z0-9][\w-]*)")
HELP_OPT = re.compile(r"\((-[A-Za-z0-9][\w-]*-h)\)")
FILE_ARG = re.compile(r"file|dir|path|\.c\b|\.json|\.sav|out\b", re.I)


def run(cmd, dump_dir, name):
    env = dict(os.environ, LC_ALL="C")
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
    out = r.stdout + r.stderr
    if dump_dir:
        with open(os.path.join(dump_dir, name + ".txt"), "w") as f:
            f.write("$ %s\n[rc=%d]\n%s" % (" ".join(cmd), r.returncode, out))
    return out


def parse_help(text, opts, argopts, fileopts):
    for line in text.splitlines():
        m = OPT_LINE.match(line)
        if m:
            names = [n.strip() for n in m.group(1).split(",")]
            for n in names:
                opts.add(n)
                if m.group(2) is not None:
                    argopts.add(n)
                    if FILE_ARG.search(m.group(2)):
                        fileopts.add(n)
    for n in OPPOSITE.findall(re.sub(r"\s+", " ", text)):
        opts.add(n)


def words(s):
    return " ".join(sorted(s))


def main():
    apprun, out = sys.argv[1], sys.argv[2]
    provers = "alt-ergo z3 cvc4 cvc5"
    dump_dir = None
    if "--provers" in sys.argv:
        provers = sys.argv[sys.argv.index("--provers") + 1]
    if "--dump-dir" in sys.argv:
        dump_dir = sys.argv[sys.argv.index("--dump-dir") + 1]
        os.makedirs(dump_dir, exist_ok=True)

    fc = [apprun, "frama-c"]
    plugins = run(fc + ["-plugins"], dump_dir, "plugins")
    help_opts = ["-kernel-h"] + sorted(set(HELP_OPT.findall(plugins)))
    opts, argopts, fileopts = set(), set(), set()
    for h in help_opts:
        parse_help(run(fc + [h], dump_dir, "help" + h), opts, argopts, fileopts)
    opts.update(help_opts)

    mtext = run(fc + ["-machdep", "help"], dump_dir, "machdep-help")
    machdeps = {w for w in re.findall(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b", mtext)
                if re.search(r"x86|ppc|arm|aarch|riscv|msvc|gcc|mips|avr|sparc", w)}

    stext = run([apprun, "frama-c-script", "help"], dump_dir, "script-help")
    script_cmds = set(re.findall(r"^\s+-\s+([a-z][a-z0-9-]*)", stext, re.M))

    wp_provers = set(provers.split()) | {"native:alt-ergo", "script", "tip", "none"}

    vals = {
        "OPTS": words(opts), "ARGOPTS": words(argopts), "FILEOPTS": words(fileopts),
        "MACHDEPS": words(machdeps), "PROVERS": words(wp_provers), "SCRIPT_CMDS": words(script_cmds),
    }
    for k, v in vals.items():
        assert "'" not in v, k
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "completion.bash.in")) as f:
        tpl = f.read()
    for k, v in vals.items():
        tpl = tpl.replace("@%s@" % k, v)
    with open(out, "w") as f:
        f.write(tpl)
    print("completion: %d options (%d with an argument, %d with a file argument), "
          "%d plug-in help options, %d machdeps, %d frama-c-script commands"
          % (len(opts), len(argopts), len(fileopts), len(help_opts), len(machdeps), len(script_cmds)))


if __name__ == "__main__":
    main()
