# Relocatable, offline Frama-C bundle (AppImage)

These scripts build Frama-C, with its plug-ins statically linked into one executable, together with Ivette (the Electron GUI, built from the Frama-C sources), `frama-c-script` with a bundled Python 3.12 for its helpers, Why3, Z3 4.13.0, CVC4 1.8, cvc5 1.2.1, Alt-Ergo 2.6.2 and a C preprocessor. The result is a single AppImage that:

* runs from any directory,
* needs no network access,
* reads nothing from the machine it was built on,
* needs nothing on the target except glibc and `/bin/sh`.

## Build (online machine)

```sh
./build-in-container.sh          # docker or podman; recommended
# or natively, on Debian/Ubuntu, with the packages listed in build.sh:
./build.sh
```

Output: `dist/frama-c-33.0-offline-x86_64.tar`, plus the build log and `selftest-report.txt`.

* **First run.** Takes about 30–60 minutes: OCaml, the opam dependencies and Frama-C are all built from source.
* **Later runs.** Incremental, because opam and the sources are kept in the `fcai-build-*` docker volume. `FORCE=framac-static ./build-in-container.sh` redoes one step, and `FORCE=all` redoes all of them.
* **Minimum glibc on targets.** Set by the build image: `ubuntu:20.04` (the default) gives glibc 2.31, which covers RHEL 9 (2.34), Debian 11+ and Ubuntu 20.04+. The build fails if any bundled binary needs a glibc newer than `GLIBC_MAX` (default 2.34). On an older host, the bundle stops with a clear message instead of the loader's `GLIBC_x.y not found`.
* **Ivette.** Built with `make -C ivette dist` using Node.js 22.22.2 (override with `NODE_VERSION`), which is downloaded and checked against nodejs.org's SHA256SUMS. To use an existing Ivette AppImage or unpacked app instead, set `IVETTE_PREBUILT=<file|dir>`. `WITH_IVETTE=0` leaves Ivette out. The self-test starts Ivette under Xvfb and checks that it runs the bundled `frama-c` as its server.
* **Alt-Ergo licence.** Alt-Ergo 2.6 is under the OCamlPro non-commercial licence. `ALTERGO_PKG=alt-ergo-free.2.4.3` uses the free version instead, and `ALTERGO_PKG=` leaves Alt-Ergo out.

## Install and test (offline machine)

```sh
tar xf frama-c-33.0-offline-x86_64.tar && cd frama-c-33.0-offline-x86_64
./run-tests.sh          # -> fcai-test-report-<host>-<date>.txt
./install.sh            # ~/.local/opt + symlinks in ~/.local/bin
```

`README.md` inside the archive has the details: `--dir`, `--bin`, `--extract` for machines without FUSE, and `--uninstall`.

## How path-independence is achieved (and checked)

| Component | Problem | Solution |
|---|---|---|
| Frama-C plug-ins | loaded with dynlink through findlib, `OCAMLPATH` and absolute paths | `lib/gen_static_exe.py` generates a second executable stanza in the Frama-C source tree. It links the same libraries as `frama-c`, plus every plug-in library the normal build produced, with `-linkall`. It is run with `-no-autoload-plugins`. |
| Frama-C `share/` | dune-site paths are fixed at install time, and `dune install --relocatable` bakes in `<exe>/../` + the *absolute* stage path | `AppRun` always passes the bundle-relative dune-site locations through `DUNE_DIR_LOCATIONS`, which dune-site searches first. Because parts of Frama-C (for example the libc `-I` path) use the baked entry, a relative symlink `usr/<stage path> → usr` makes that entry valid too. The build checks that every `-print-share-path` entry of a moved copy exists, and parses a C file with `#include`s. |
| Why3 data | `Config.datadir` and `Config.libdir` point into the opam tree | `WHY3DATA` and `WHY3LIB` are set by `AppRun`. `usr/lib/why3` holds Why3's helper programs (`why3server`, `why3cpulimit`): Why3 runs every prover through `why3server`. |
| Prover config | `why3.conf` stores absolute prover paths | At build time, `why3 config detect` is run against the bundled provers and saved as a template. `AppRun` fills it in for the current mount point, per location, and points `WHY3CONFIG` at it. |
| C preprocessor | Frama-C runs `gcc -E` from `PATH` | The `gcc` driver (as `gcc-real`) and `cc1` are bundled with the same relative layout. gcc finds `cc1` relative to itself. `gcc` is a wrapper that always adds `-nostdinc`, so the host's `/usr/include` is never searched. |
| Ivette → frama-c | Ivette starts `frama-c` from `PATH` | `usr/lib/fcai-wrappers/frama-c` comes first on `PATH` and runs `AppRun frama-c`. `AppRun` removes `ARGV0` after using it, so this inner call doesn't start Ivette again. Electron's own desktop libraries (GTK, NSS) come from the host, as with any Electron app. |
| Shared libraries | libgmp, libstdc++ (for Z3), libisl and libmpfr (for cc1) | They are copied, unmodified, into `usr/lib`. Executables get a relative `RPATH` (`$ORIGIN/...`), which also serves their libraries' dependencies. Only glibc comes from the host. |

`run-tests.sh` checks all of this. It runs WP with each prover (each must prove something Qed can't), all provers together (every goal must be proved), a negative proof that must fail, and Eva with the libc headers. It runs the bundle mounted, extracted, copied, renamed, from a path containing spaces, and with the original deleted. It also runs a concurrent job, a job without network access (`unshare -rn`), and an `strace` of every file touched, which fails if anything under the build paths, or a host compiler, prover or why3/frama-c install, is used.

## Files

```
build.sh                  the build (steps are stamped and resumable)
build-in-container.sh     runs build.sh in ubuntu:20.04 via docker/podman
lib/gen_static_exe.py     generates the statically linked frama-c stanza
lib/patch_script.py       makes frama-c-script use the first -print-share-path line
lib/bundle_libs.py        copies shared libraries, sets relative RUNPATHs
appdir/AppRun             multi-call entry point (frama-c, frama-c-script, ivette, z3, cvc4, cvc5, alt-ergo)
appdir/fcai-wrappers/     'frama-c' as seen by Ivette
delivery/install.sh       offline installer
delivery/run-tests.sh     offline acceptance tests
delivery/tests/*.c        WP / Eva samples
dev/mock/run-mock.sh      runs the whole pipeline with a mocked Frama-C (no opam, minutes)
CLAUDE.md                 design notes, real-build facts and workflow, for maintainers/agents
```

## Developing without a full build

`dev/mock/run-mock.sh [WORKDIR]` fakes only the network-bound parts: opam, the Frama-C build, the Why3 CLI, Alt-Ergo and Ivette. It then runs the real `build.sh` from the prover downloads onwards, followed by `run-tests.sh` on the delivered AppImage. It takes a few minutes and needs GitHub access, gcc and python3. Run it before handing changes over for a real build.
