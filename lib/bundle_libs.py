#!/usr/bin/env python3
"""
bundle_libs.py APPDIR [--patchelf PATH]

For every dynamically-linked ELF under APPDIR, copy all non-glibc
shared-library dependencies (as reported by ldd, i.e. the full transitive
closure) into APPDIR/usr/lib.  Then:
    executables : DT_RPATH = $ORIGIN/<relative path to APPDIR/usr/lib>
    libraries   : NOT modified (an RPATH/RUNPATH they bring is removed)
DT_RPATH (not DT_RUNPATH) on the executable is also searched for the
dependencies of its libraries, so libraries need no RUNPATH of their own.

Why libraries are left alone: adding a RUNPATH makes patchelf append a
PT_LOAD segment.  On libraries linked by old binutils (2 MiB p_align, no
separate-code; e.g. libmpc.so.3 on ubuntu:20.04) patchelf 0.18 aligns it to
4 KiB only, and glibc 2.31 then refuses the library ("ELF load command
address/offset not properly aligned").  Every file patchelf touches is
checked for that, and retried with --page-size = its largest p_align.

glibc itself (libc, libm, libpthread, libdl, librt, ld-linux, ...) is never
bundled: it is the one thing taken from the host.  Statically linked
binaries are left untouched.
"""
import os
import shutil
import struct
import subprocess
import sys

GLIBC = {
    "linux-vdso.so.1", "linux-gate.so.1", "ld-linux-x86-64.so.2", "ld-linux.so.2",
    "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
    "libutil.so.1", "libresolv.so.2", "libnsl.so.1", "libanl.so.1",
    "libBrokenLocale.so.1", "libmvec.so.1", "libcrypt.so.1", "libnss_files.so.2",
    "libnss_dns.so.2", "libthread_db.so.1", "libc_malloc_debug.so.0",
}


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def phdrs(path):
    """program headers of a 64-bit little-endian ELF: [(type, offset, vaddr, align)]"""
    with open(path, "rb") as f:
        h = f.read(64)
        if h[:4] != b"\x7fELF" or h[4] != 2 or h[5] != 1:
            return []
        phoff, = struct.unpack_from("<Q", h, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", h, 0x36)
        f.seek(phoff)
        data = f.read(phentsize * phnum)
    out = []
    for i in range(phnum):
        t, _fl, off, va, _pa, _fs, _ms, al = struct.unpack_from("<IIQQQQQQ", data, i * phentsize)
        out.append((t, off, va, al))
    return out


def misaligned(path):
    """PT_LOAD segments whose offset and vaddr disagree modulo p_align (or the page)"""
    bad = []
    for t, off, va, al in phdrs(path):
        if t == 1 and ((al > 1 and off % al != va % al) or (off - va) % 4096):
            bad.append("offset=%#x vaddr=%#x align=%#x" % (off, va, al))
    return bad


def is_executable(path):
    """has a PT_INTERP: a program, not a library (PIE included)"""
    return any(t == 3 for t, _o, _v, _a in phdrs(path))


def dyn_paths(path):
    """(RPATH, RUNPATH) values of the dynamic section, None if absent"""
    out = subprocess.run(["readelf", "-dW", path], capture_output=True, text=True).stdout
    rp = rn = None
    for line in out.splitlines():
        if "(RPATH)" in line:
            rp = line.split("[", 1)[1].rsplit("]", 1)[0]
        elif "(RUNPATH)" in line:
            rn = line.split("[", 1)[1].rsplit("]", 1)[0]
    return rp, rn


def patch(patchelf, path, *args):
    """run patchelf on PATH; if the result has misaligned PT_LOADs, redo it
    with --page-size = the file's largest p_align; die if still misaligned"""
    backup = path + ".fcai-orig"
    shutil.copy2(path, backup)
    try:
        subprocess.run([patchelf] + list(args) + [path], check=True)
        bad = misaligned(path)
        if bad:
            page = max([al for t, _o, _v, al in phdrs(backup) if t == 1] + [4096])
            print("bundle_libs: %s: misaligned after patchelf (%s); retrying with --page-size %d"
                  % (path, "; ".join(bad), page))
            shutil.copy2(backup, path)
            subprocess.run([patchelf, "--page-size", str(page)] + list(args) + [path], check=True)
            bad = misaligned(path)
            if bad:
                sys.exit("bundle_libs: %s: patchelf produced misaligned PT_LOAD segments: %s"
                         % (path, "; ".join(bad)))
    finally:
        os.unlink(backup)


def file_info(path):
    return subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout


def ldd(path, strict=False, libdir=None):
    """dependencies as resolved by the loader.  LIBDIR simulates the RPATH of
    the executable that loads a library (libraries carry no path of their own)"""
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)
    if libdir:
        env["LD_LIBRARY_PATH"] = libdir
    r = subprocess.run(["ldd", path], capture_output=True, text=True, env=env)
    if strict and (r.returncode != 0 or "error" in r.stderr.lower()):
        sys.exit("bundle_libs: ldd %s failed (rc=%d): %s" % (path, r.returncode, r.stderr.strip()))
    deps = []
    for line in r.stdout.splitlines():
        line = line.strip()
        if "=>" in line:
            name, rest = line.split("=>", 1)
            name = name.strip()
            target = rest.strip().split(" (")[0].strip()
            if target == "not found":
                sys.exit("bundle_libs: %s: dependency %s NOT FOUND" % (path, name))
            deps.append((name, target))
    return deps


def main():
    appdir = os.path.abspath(sys.argv[1])
    patchelf = "patchelf"
    if "--patchelf" in sys.argv:
        patchelf = sys.argv[sys.argv.index("--patchelf") + 1]
    libdir = os.path.join(appdir, "usr", "lib")
    os.makedirs(libdir, exist_ok=True)

    # collect candidate ELF files (executables and non-bundled libs)
    elves = []
    for root, _dirs, files in os.walk(appdir):
        for fn in files:
            p = os.path.join(root, fn)
            if os.path.islink(p) or not is_elf(p):
                continue
            elves.append(p)

    copied = {}
    for p in elves:
        info = file_info(p)
        if "statically linked" in info or "static-pie" in info:
            print("bundle_libs: static, untouched: %s" % os.path.relpath(p, appdir))
            continue
        if "dynamically linked" not in info and "shared object" not in info:
            continue
        for name, target in ldd(p):
            if name in GLIBC or os.path.basename(target) in GLIBC:
                continue
            if name not in copied:
                dst = os.path.join(libdir, name)
                if not os.path.exists(dst):
                    subprocess.run(["cp", "-L", target, dst], check=True)
                    os.chmod(dst, 0o755)
                copied[name] = target
        if not is_executable(p):
            continue            # libraries are never modified (see top)
        rel = os.path.relpath(libdir, os.path.dirname(p))
        rpath = "$ORIGIN" if rel == "." else "$ORIGIN/" + rel
        patch(patchelf, p, "--force-rpath", "--set-rpath", rpath)
        print("bundle_libs: RPATH %-22s %s" % (rpath, os.path.relpath(p, appdir)))

    for name in sorted(copied):
        dst = os.path.join(libdir, name)
        rp, rn = dyn_paths(dst)
        if rp is not None or rn is not None:
            # a RUNPATH would hide the executable's RPATH from this library's
            # dependencies, an RPATH could point into the build machine
            patch(patchelf, dst, "--remove-rpath")
            print("bundle_libs: bundled %s  (from %s; removed RPATH=%s RUNPATH=%s)" % (name, copied[name], rp, rn))
        else:
            print("bundle_libs: bundled %s  (from %s; unmodified)" % (name, copied[name]))

    # final check: every ELF resolves all its deps inside APPDIR or glibc
    bad = False
    for root, _dirs, files in os.walk(appdir):
        for fn in files:
            p = os.path.join(root, fn)
            if os.path.islink(p) or not is_elf(p):
                continue
            bad_al = misaligned(p)
            if bad_al:
                print("bundle_libs: MISALIGNED %s: %s" % (os.path.relpath(p, appdir), "; ".join(bad_al)))
                bad = True
            info = file_info(p)
            if "dynamically linked" not in info and "shared object" not in info:
                continue
            if is_executable(p) and dyn_paths(p)[1] is not None:
                print("bundle_libs: %s has a RUNPATH (an RPATH is required)" % os.path.relpath(p, appdir))
                bad = True
            for name, target in ldd(p, strict=True, libdir=None if is_executable(p) else libdir):
                if name in GLIBC or os.path.basename(target) in GLIBC:
                    continue
                if not os.path.realpath(target).startswith(appdir + os.sep):
                    print("bundle_libs: LEAK %s -> %s" % (os.path.relpath(p, appdir), target))
                    bad = True
    if bad:
        sys.exit("bundle_libs: some ELF files are broken or resolve dependencies outside the AppDir")


if __name__ == "__main__":
    main()
