#!/usr/bin/env python3
"""
gen_completion.py APPRUN OUT.bash [--provers "z3 cvc4 ..."] [--dump-dir DIR]

Generate a self-contained bash completion script for the bundle's frama-c,
ivette and frama-c-script, from the bundled frama-c's own help:
    frama-c -plugins          -> plug-ins and their "-<x>-h" help options
    frama-c -kernel-h, -<x>-h -> every option, "<arg>" and "-no-" opposites
    frama-c -machdep help     -> machdeps
    frama-c -autocomplete @all -> options, their type (bool: no argument) and
                              the values of enumerated string options
    frama-c -wp-list-provers  -> prover names accepted by -wp-prover
    frama-c -X-msg-key help, -X-warn-key help -> message / warning categories
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

    # upstream's own option list (share/autocomplete_frama-c relies on it).
    # Real 33.0 format, one option per line under "Plugin: <name>":
    #   "  -eva-precision: int (-1, 11)"      int range: takes an argument
    #   "  -wp-cache: string (none, update, cleanup, replay, rebuild, offline)"
    #   "  -eva-show-progress: bool"           no argument
    auto = run(fc + ["-autocomplete", "@all"], dump_dir, "autocomplete-all")
    enums = {}
    for line in auto.splitlines():
        m = re.match(r"^\s+(--?[A-Za-z0-9][\w-]*):\s*(\w+)(?:\s*\((.*)\))?\s*$", line)
        if not m:
            continue
        name, typ, extra = m.group(1), m.group(2), m.group(3)
        opts.add(name)
        if typ != "bool":
            argopts.add(name)
        if typ == "string" and extra:
            vals = [v.strip() for v in extra.split(",") if v.strip()]
            if vals and all(re.match(r"^[\w:.+-]+$", v) for v in vals):
                enums[name] = set(vals)

    # per-option value lists (comma-separated): message and warning categories
    optvals = {}
    for o in sorted(o for o in argopts if o.endswith("-msg-key") or o.endswith("-warn-key")):
        text = run(fc + [o, "help"], dump_dir, "keys" + o)
        keys = set()
        for line in text.splitlines():
            m = re.match(r"^\s{2,}([a-z][\w:-]*)(?:\s|$)", line)
            if m and not line.lstrip().startswith("*"):
                keys.add(m.group(1))
        if keys:
            optvals[o] = keys

    # WP prover names (bracketed, '|'-separated in -wp-list-provers)
    wtext = run(fc + ["-wp-list-provers"], dump_dir, "wp-list-provers")
    wp_names = set()
    for grp in re.findall(r"\[([^\]]*)\]", wtext):
        for n in grp.split("|"):
            n = n.strip()
            if n and " " not in n and n not in ("wp",):
                wp_names.add(n)

    mtext = run(fc + ["-machdep", "help"], dump_dir, "machdep-help")
    machdeps = {w for w in re.findall(r"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b", mtext)
                if re.search(r"x86|ppc|arm|aarch|riscv|msvc|gcc|mips|avr|sparc", w)}

    stext = run([apprun, "frama-c-script", "help"], dump_dir, "script-help")
    script_cmds = set(re.findall(r"^\s+-\s+([a-z][a-z0-9-]*)", stext, re.M))

    wp_provers = set(provers.split()) | wp_names | {"native:alt-ergo", "script", "tip", "none"}
    optvals.update(enums)
    optvals["-wp-prover"] = wp_provers
    optvals["-machdep"] = machdeps | {"help"}
    for o in list(optvals):
        if o not in opts:
            del optvals[o]
    optvals_bash = "\n".join("    [%s]='%s'" % (o, words(v)) for o, v in sorted(optvals.items()))

    # why3 CLI sub-commands: the .cmxs shipped in usr/lib/why3/commands
    cmd_dir = os.path.join(os.path.dirname(os.path.abspath(apprun)), "usr", "lib", "why3", "commands")
    why3_cmds = set()
    if os.path.isdir(cmd_dir):
        for f in os.listdir(cmd_dir):
            if f.endswith(".cmxs"):
                why3_cmds.add(re.sub(r"^why3", "", f[:-5]))

    vals = {
        "OPTS": words(opts), "ARGOPTS": words(argopts), "FILEOPTS": words(fileopts),
        "MACHDEPS": words(machdeps), "PROVERS": words(wp_provers), "SCRIPT_CMDS": words(script_cmds),
        "WHY3_CMDS": words(why3_cmds), "WHY3_PROVERS": words(set(provers.split())),
        "OPTVALS": optvals_bash,
    }
    for k, v in vals.items():
        assert k == "OPTVALS" or "'" not in v, k
    assert all("'" not in w for v in optvals.values() for w in v)
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "completion.bash.in")) as f:
        tpl = f.read()
    for k, v in vals.items():
        tpl = tpl.replace("@%s@" % k, v)
    with open(out, "w") as f:
        f.write(tpl)
    print("completion: %d options (%d with an argument, %d with a file argument), "
          "%d plug-in help options, %d machdeps, %d WP provers, %d options with value lists (%d values), "
          "%d frama-c-script commands, %d why3 commands"
          % (len(opts), len(argopts), len(fileopts), len(help_opts), len(machdeps), len(wp_provers), len(optvals), sum(len(v) for v in optvals.values()),
             len(script_cmds), len(why3_cmds)))


if __name__ == "__main__":
    main()
