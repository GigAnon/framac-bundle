#!/usr/bin/env python3
"""
bundle_libs.py APPDIR [--patchelf PATH]

For every dynamically-linked ELF executable under APPDIR (excluding the
libraries it copies itself), copy all non-glibc shared-library dependencies
(as reported by ldd, i.e. the full transitive closure) into APPDIR/usr/lib,
then set a relative RUNPATH:
    executables : $ORIGIN/<relative path to APPDIR/usr/lib>
    libraries   : $ORIGIN
glibc itself (libc, libm, libpthread, libdl, librt, ld-linux, ...) is never
bundled: it is the one thing taken from the host.  Statically linked
binaries are left untouched.
"""
import os
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


def file_info(path):
    return subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout


def ldd(path):
    r = subprocess.run(["ldd", path], capture_output=True, text=True)
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
        # relative RUNPATH to usr/lib (libraries living in usr/lib get $ORIGIN)
        rel = os.path.relpath(libdir, os.path.dirname(p))
        rpath = "$ORIGIN" if rel == "." else "$ORIGIN/" + rel
        subprocess.run([patchelf, "--set-rpath", rpath, p], check=True)
        print("bundle_libs: RUNPATH %-22s %s" % (rpath, os.path.relpath(p, appdir)))

    for name in sorted(copied):
        dst = os.path.join(libdir, name)
        subprocess.run([patchelf, "--set-rpath", "$ORIGIN", dst], check=True)
        print("bundle_libs: bundled %s  (from %s)" % (name, copied[name]))

    # final check: every ELF resolves all its deps inside APPDIR or glibc
    bad = False
    for root, _dirs, files in os.walk(appdir):
        for fn in files:
            p = os.path.join(root, fn)
            if os.path.islink(p) or not is_elf(p):
                continue
            info = file_info(p)
            if "dynamically linked" not in info and "shared object" not in info:
                continue
            for name, target in ldd(p):
                if name in GLIBC or os.path.basename(target) in GLIBC:
                    continue
                if not os.path.realpath(target).startswith(appdir + os.sep):
                    print("bundle_libs: LEAK %s -> %s" % (os.path.relpath(p, appdir), target))
                    bad = True
    if bad:
        sys.exit("bundle_libs: some dependencies still resolve outside the AppDir")


if __name__ == "__main__":
    main()
