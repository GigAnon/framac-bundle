#!/usr/bin/env python3
"""
gen_static_exe.py -- generate a dune stanza for a Frama-C executable with
plug-ins linked statically (no dynlink / findlib / OCAMLPATH at runtime).

It does NOT hard-code Frama-C's internal layout. Instead it:
  1. finds the (executable ...) stanza whose public_name is `frama-c`
     in the Frama-C source tree,
  2. discovers the plug-in libraries that the regular build produced, from the
     dune-site plug-in META files in _build/install/default/lib/frama-c/plugins/,
  3. writes a new directory holding a copy of the executable's own modules
     and a stanza that links the same libraries, plus every plug-in library
     (inserted before frama-c.boot when present), with -linkall.

Usage:
  gen_static_exe.py --src SRC --out-dirname fcai_static \
      --public-name frama-c-static [--exclude e-acsl,...]
Prints the path of the generated directory (relative to SRC) on stdout.
"""
import argparse
import os
import re
import shutil
import sys

# --------------------------------------------------------------------------
# Minimal s-expression reader/writer for dune files
# --------------------------------------------------------------------------


class Atom(str):
    pass


class QStr(str):
    """A quoted string, printed back verbatim (raw text kept)."""
    def __new__(cls, raw):
        o = str.__new__(cls, raw)
        return o


def tokenize(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("#|", i):
            j = text.find("|#", i + 2)
            i = n if j < 0 else j + 2
        elif text.startswith("#;", i):
            yield ("DATUMCOMMENT", None)
            i += 2
        elif c == "(":
            yield ("(", None)
            i += 1
        elif c == ")":
            yield (")", None)
            i += 1
        elif c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            yield ("STR", text[i:j + 1])
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in " \t\r\n()\";":
                j += 1
            yield ("ATOM", text[i:j])
            i = j


def parse(text):
    stack = [[]]
    skip_next = []  # stack depth markers for #; comments
    pending_skip = 0
    for kind, val in tokenize(text):
        if kind == "DATUMCOMMENT":
            pending_skip += 1
            continue
        if kind == "(":
            stack.append([])
            skip_next.append(pending_skip)
            pending_skip = 0
            continue
        if kind == ")":
            lst = stack.pop()
            sk = skip_next.pop()
            if sk:
                continue
            stack[-1].append(lst)
            continue
        item = Atom(val) if kind == "ATOM" else QStr(val)
        if pending_skip:
            pending_skip -= 1
            continue
        stack[-1].append(item)
    if len(stack) != 1:
        raise ValueError("unbalanced parentheses")
    return stack[0]


def dump(x, indent=0):
    if isinstance(x, list):
        if not x:
            return "()"
        simple = all(not isinstance(e, list) for e in x)
        if simple:
            return "(" + " ".join(dump(e) for e in x) + ")"
        pad = "\n" + " " * (indent + 1)
        return "(" + dump(x[0], indent + 1) + "".join(
            pad + dump(e, indent + 1) for e in x[1:]) + ")"
    return str(x)


def field(stanza, name):
    for e in stanza[1:]:
        if isinstance(e, list) and e and e[0] == name:
            return e
    return None


def atoms(lst):
    return [e for e in lst if not isinstance(e, list)]


# --------------------------------------------------------------------------


def die(msg):
    sys.stderr.write("gen_static_exe: ERROR: " + msg + "\n")
    sys.exit(2)


def warn(msg):
    sys.stderr.write("gen_static_exe: warning: " + msg + "\n")


def find_frama_c_exe(src):
    hits = []
    for root, dirs, files in os.walk(src):
        # do not descend into build dirs / hidden dirs / tests
        dirs[:] = [d for d in dirs if not d.startswith(("_build", ".", "_opam"))]
        if "dune" not in files:
            continue
        path = os.path.join(root, "dune")
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        if "frama-c" not in text:
            continue
        try:
            sexps = parse(text)
        except Exception as exn:  # noqa
            warn("cannot parse %s: %s" % (path, exn))
            continue
        # executables installed under another name through an (install) stanza
        installed_as = set()
        for st in sexps:
            if isinstance(st, list) and st and st[0] == "install":
                files = field(st, "files")
                for e in (files[1:] if files else []):
                    if isinstance(e, list) and len(e) == 3 and e[1] == "as" \
                            and os.path.basename(str(e[2])) == "frama-c":
                        installed_as.add(os.path.splitext(str(e[0]))[0])
        for st in sexps:
            if not isinstance(st, list) or not st:
                continue
            if st[0] not in ("executable", "executables"):
                continue
            pn = field(st, "public_name") or field(st, "public_names")
            nm = field(st, "name") or field(st, "names")
            if pn and "frama-c" in [str(a) for a in atoms(pn[1:])]:
                hits.append((path, st, text))
            elif nm and installed_as & set(str(a) for a in atoms(nm[1:])):
                st = list(st)
                # normalise to a single public executable named frama-c
                if st[0] == "executables":
                    die("(executables ...) installed as frama-c: unsupported layout")
                st.append([Atom("public_name"), Atom("frama-c")])
                hits.append((path, st, text))
    return hits


def discover_plugins(src, exclude):
    base = os.path.join(src, "_build", "install", "default", "lib", "frama-c", "plugins")
    if not os.path.isdir(base):
        root = os.path.join(src, "_build", "install", "default", "lib")
        listing = []
        for r, d, f in os.walk(root):
            depth = os.path.relpath(r, root).count(os.sep)
            if depth <= 2:
                listing.append(os.path.relpath(r, root) + "/  " + " ".join(sorted(f))[:200])
        die("no plug-in directory %s -- did the first 'dune build @install' run?\n"
            "Contents of %s (depth<=2):\n  %s" % (base, root, "\n  ".join(listing[:200])))
    libs, names = [], []
    for name in sorted(os.listdir(base)):
        meta = os.path.join(base, name, "META")
        if not os.path.isfile(meta):
            continue
        if any(re.fullmatch(p, name) for p in exclude):
            sys.stderr.write("gen_static_exe: excluding plug-in %s\n" % name)
            continue
        with open(meta, encoding="utf-8", errors="replace") as f:
            txt = f.read()
        reqs = []
        for m in re.finditer(r'requires(?:\([^)]*\))?\s*\+?=\s*"([^"]*)"', txt):
            reqs += m.group(1).replace(",", " ").split()
        if not reqs:
            warn("plug-in %s: no 'requires' in META, skipped:\n%s" % (name, txt))
            continue
        names.append(name)
        for r in reqs:
            if r not in libs:
                libs.append(r)
    if not libs:
        die("no plug-in libraries discovered under " + base)
    return names, libs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out-dirname", default="fcai_static")
    ap.add_argument("--public-name", default="frama-c-static")
    ap.add_argument("--package", default="frama-c")
    ap.add_argument("--exclude", default="e-acsl,e_acsl,eacsl",
                    help="comma-separated regexps of plug-in names to leave out")
    args = ap.parse_args()
    src = os.path.abspath(args.src)
    exclude = [p.strip() for p in args.exclude.split(",") if p.strip()]

    hits = find_frama_c_exe(src)
    if not hits:
        die("could not find an (executable (public_name frama-c) ...) stanza")
    if len(hits) > 1:
        warn("several frama-c executable stanzas found, using the first: "
             + ", ".join(h[0] for h in hits))
    dune_path, st, _ = hits[0]
    exe_dir = os.path.dirname(dune_path)
    sys.stderr.write("gen_static_exe: frama-c executable stanza in %s:\n%s\n"
                     % (os.path.relpath(dune_path, src), dump(st)))

    if st[0] == "executables":
        names = atoms(field(st, "names")[1:])
        pnames = [str(a) for a in atoms((field(st, "public_names"))[1:])]
        main_mod = str(names[pnames.index("frama-c")])
    else:
        main_mod = str(atoms(field(st, "name")[1:])[0])

    # --- modules of the executable ----------------------------------------
    def module_files(mod, d):
        out = []
        if not os.path.isdir(d):
            return out
        for fn in os.listdir(d):
            stem, ext = os.path.splitext(fn)
            if ext in (".ml", ".mli", ".mll", ".mly", ".re", ".rei") and \
                    stem.lower() == mod.lower():
                out.append(fn)
        return out

    mods_field = field(st, "modules")
    if mods_field is not None and all(not isinstance(e, list) for e in mods_field[1:]) \
            and not any(str(a).startswith(":") or str(a) == "\\" for a in mods_field[1:]):
        modules = [str(a) for a in mods_field[1:]]
    else:
        if mods_field is not None:
            warn("complex (modules ...) field %s; copying only the main module"
                 % dump(mods_field))
        modules = [main_mod]
    if main_mod not in modules and main_mod.lower() not in [m.lower() for m in modules]:
        modules.append(main_mod)

    # --- where to put the new directory ----------------------------------
    with open(dune_path, encoding="utf-8", errors="replace") as f:
        exe_dune_text = f.read()
    if "include_subdirs" in exe_dune_text:
        out_dir = os.path.join(os.path.dirname(exe_dir), args.out_dirname)
    else:
        out_dir = os.path.join(exe_dir, args.out_dirname)
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)

    # modules generated by a rule (e.g. Frama-C's src/init/boot/empty_file.ml)
    # are taken from the first build, in _build/default/<dir>/
    built_dir = os.path.join(src, "_build", "default", os.path.relpath(exe_dir, src))
    for m in modules:
        files = module_files(m, exe_dir)
        where = exe_dir
        if not files:
            files = [f for f in module_files(m, built_dir) if os.path.splitext(f)[1] in (".ml", ".mli")]
            where = built_dir
            if files:
                sys.stderr.write("gen_static_exe: module %s is generated; using %s\n"
                                 % (m, ", ".join(os.path.join(os.path.relpath(built_dir, src), f)
                                                 for f in files)))
        if not files:
            die("source of module %s found neither in %s nor in %s" % (m, exe_dir, built_dir))
        for fn in files:
            dst = os.path.join(out_dir, fn)
            shutil.copyfile(os.path.join(where, fn), dst)
            os.chmod(dst, 0o644)   # _build files are read-only

    # --- libraries: insert plug-ins before frama-c.boot -------------------
    plugin_names, plugin_libs = discover_plugins(src, exclude)
    sys.stderr.write("gen_static_exe: plug-ins linked statically: %s\n" % " ".join(plugin_names))
    libs_field = field(st, "libraries")
    libs = list(libs_field[1:]) if libs_field else []
    existing = [str(a) for a in atoms(libs)]
    to_add = [Atom(l) for l in plugin_libs if l not in existing]
    boot_idx = None
    for i, e in enumerate(libs):
        if not isinstance(e, list) and str(e) in ("frama-c.boot", "frama-c.init.boot"):
            boot_idx = i
    if boot_idx is None:
        warn("no frama-c.boot in libraries; appending plug-ins at the end")
        libs = libs + to_add
    else:
        libs = libs[:boot_idx] + to_add + libs[boot_idx:]

    # --- link flags: make sure -linkall is there ---------------------------
    lf = field(st, "link_flags")
    if lf is None:
        link_flags = [Atom("link_flags"), [Atom(":standard"), Atom("-linkall")]]
    else:
        body = lf[1:]
        if len(body) == 1 and isinstance(body[0], list):
            inner = body[0]
            if any(isinstance(e, list) and e and e[0] == ":include" for e in inner) or \
                    (inner and inner[0] == ":include"):
                warn("link_flags uses :include, replaced by (:standard -linkall)")
                inner = [Atom(":standard")]
            if "-linkall" not in [str(a) for a in atoms(inner)]:
                inner = inner + [Atom("-linkall")]
            link_flags = [Atom("link_flags"), inner]
        else:
            flat = list(body)
            if "-linkall" not in [str(a) for a in atoms(flat)]:
                flat = flat + [Atom("-linkall")]
            link_flags = [Atom("link_flags"), flat]

    new = [Atom("executable"),
           [Atom("name"), Atom(main_mod)],
           [Atom("public_name"), Atom(args.public_name)],
           [Atom("package"), Atom(args.package)],
           [Atom("modules")] + [Atom(m) for m in modules]]
    for fname in ("flags", "ocamlopt_flags", "preprocess", "preprocessor_deps",
                  "modules_without_implementation", "ocamlc_flags"):
        fv = field(st, fname)
        if fv is not None:
            new.append(fv)
    for fname in ("link_deps", "foreign_stubs", "foreign_archives", "extra_objects"):
        if field(st, fname) is not None:
            warn("field (%s ...) not copied -- check if the link fails" % fname)
    new.append([Atom("libraries")] + libs)
    new.append(link_flags)

    text = (";; generated by gen_static_exe.py -- Frama-C with statically linked plug-ins\n"
            + dump(new) + "\n")
    with open(os.path.join(out_dir, "dune"), "w", encoding="utf-8") as f:
        f.write(text)
    sys.stderr.write("gen_static_exe: generated %s/dune:\n%s\n"
                     % (os.path.relpath(out_dir, src), text))
    print(os.path.relpath(out_dir, src) + " " + main_mod)


if __name__ == "__main__":
    main()
