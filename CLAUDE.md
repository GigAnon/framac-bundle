# CLAUDE.md: maintainer and agent notes

Read this before changing anything. `README.md` is the user-facing overview, and `delivery/README-offline.md` ships in the archive. This file holds the *why*, the facts learned from real builds, and the working process.

## Goal and constraints (from the owner)

- **Goal.** Frama-C, Why3 and the provers Z3 and CVC4 (plus cvc5, Alt-Ergo, the MetAcsl plug-in and the Ivette GUI) packaged as a **standalone, fully offline, path-independent** AppImage, with an extractable directory form.
- **Path independence.** The bundle must work from any directory, after being copied or renamed, and with the build machine's paths absent. The owner's warning: opam bakes absolute paths into everything, and that is the whole reason for this project.
- **Option A was chosen.** Frama-C is **one executable with every plug-in statically linked** (`-linkall`, `-no-autoload-plugins`). There is no dynlink, findlib or `OCAMLPATH` at run time.
- **Build machine.** Online. The owner's machine runs Debian 13 and has Docker. A Docker build is fine (`build-in-container.sh`, default `ubuntu:20.04` → glibc ≥ 2.31 on targets).
- **Known target: RHEL 9 (9.8), glibc 2.34.** The bundle must never need a newer glibc: `build.sh` fails if any bundled ELF needs more than `GLIBC_MAX` (default 2.34).
- **Target machine.** Offline, **no Docker**, no root, distro unknown. Installing must be trivial: `./install.sh`.
- **Ivette is required.** The GTK GUI is gone in Frama-C 33. Ivette is built from `ivette/` in the Frama-C sources.
- **MetAcsl is required.** `frama-c-metacsl.0.11`, built inside the Frama-C tree.
- **E-ACSL is not needed.** It is excluded from the static link.
- **Logs are cleared at the start of each build**, at the owner's request. `KEEP_LOGS=1` keeps them.

## How work is done (the loop)

1. The agent edits scripts **and runs `dev/mock/run-mock.sh`**. All of it must pass before anything is handed over.
2. The owner runs `./build-in-container.sh` on the build machine. On failure, everything needed is in `dist/logs/` (build log, test report, `ivette-*.log`, `plugins.txt`, `why3-provers.txt`, `relo-parse.txt`, `embedded-build-paths.txt`). The owner pastes the console tail or attaches files.
3. The agent diagnoses from the logs, fixes the cause, extends the mock so it **reproduces** the observed failure, re-runs the mock, and hands over.
4. Once the build is green, the owner copies `dist/frama-c-33.0-offline-x86_64.tar` to the offline target and runs `./run-tests.sh` there. The `fcai-test-report-*.txt` comes back.

**Messages to the owner.** Keep them short: what failed, the cause, what changed, what to run, what to send back. The owner is technical. Be precise; skip the tutorials.

**The agent's workspace network may be restricted.** In the first session opam.ocaml.org, frama-c.com, git.frama-c.com and nodejs.org were blocked, while GitHub release assets were reachable. A real build was therefore impossible there, which is why the mock exists. Check what is reachable before relying on it. Never try to get around a proxy refusal.

## Pipeline (`build.sh`)

Each step is stamped in `$BUILD_ROOT/stamps`; `FORCE=step` or `FORCE=all` reruns.

| # | Step | Notes |
|---|---|---|
| 0 | system-packages | apt inside the container (not stamped there). Electron runtime libraries + Xvfb when `WITH_IVETTE=1`. |
| 1 | opam binary (pinned SHA256), `opam-init`, `opam-switch` (OCaml 4.14.2), `opam-deps` | Installs `ALTERGO_PKG` first, then `--deps-only frama-c.33.0`. |
| 2 | `framac-source` | `opam source frama-c.33.0`. |
| 2b | vendoring (not stamped) | `EXTRA_PLUGINS` (MetAcsl) is copied into `src/plugins/fcai-extra-<pkg>/` with `opam source`. The `.fcai-<pkg>` marker forces a rebuild when the list changes. |
| 3 | `framac-build` | `dune build --release @install`. Checks that each vendored plug-in registered a dune-site plug-in META. |
| 4 | `framac-static` | `lib/gen_static_exe.py` finds the `frama-c` executable stanza, reads the plug-in libraries from `_build/install/default/lib/frama-c/plugins/*/META`, and writes `src/init/boot/fcai_static/dune`. It then builds and runs `dune install --release --relocatable --prefix $STAGE`. |
| 5 | downloads | Z3 4.13.0 (glibc-2.31 build), CVC4 1.8 (static, CVC4-archived repo), cvc5 1.2.1 (static), appimagetool 1.9.0, type2 runtime 20251108. All pinned by SHA256. |
| 6 | AppDir | The static `frama-c`, `frama-c-script` (patched by `lib/patch_script.py`: each `$(... -print-share-path/-print-lib-path)` keeps its first line; original and patch report in `logs/`) + its helpers `usr/lib/frama-c/lib` (analysis-scripts, make_machdep), `share/`, empty plug-in site dirs, Why3 data and helper programs, provers, the gcc preprocessor (`gcc-real` + a `-nostdinc` wrapper + `cc1`), `bundle_libs.py` (pinned static patchelf 0.18.0; executables get a relative DT_RPATH, copied libraries are **not modified**, every patched file is checked for PT_LOAD alignment, and `ldd` errors fail the build), and the `usr$STAGE → usr` symlink. |
| 7 | relocation check | Writes `usr/share/fcai/dune-dir-locations`. Moves a copy; **every** `-print-share-path` entry must exist and contain `libc/`. Parses a C file with `#include`s while the original AppDir is moved away. Runs `-plugins`. |
| 8 | why3.conf template | `why3 config detect` against the bundled provers (`PATH=usr/bin` only). The AppDir path is replaced by `@APPDIR@`, and `datadir`/`libdir` lines are dropped. |
| 8c | Python | `WITH_PYTHON=1`: python-build-standalone CPython 3.12 into `usr/lib/fcai-python` (for `frama-c-script`), plus pure-Python PyYAML 6.0.3 (git tag, commit-pinned), trimmed and smoke-tested. |
| 8d | completion | `lib/gen_completion.py` runs the bundled `frama-c -plugins`, `-kernel-h` and each `-<x>-h`, `-machdep help` and `frama-c-script help`, and fills `lib/completion.bash.in` into `usr/share/fcai/completion/frama-c.bash`. Raw outputs go to `logs/completion-src/`. |
| 8b | Ivette | Node 22.22.2 (checked against nodejs.org SHASUMS) + corepack/yarn 1. Runs `make -C ivette api` then `make -C ivette dist`. The resulting `dist/linux-unpacked` is imported; `IVETTE_PREBUILT` overrides. |
| 9 | build-info | Versions, `GLIBC_REQUIRED` (+ `_IVETTE`), `BUILD_ROOTS` (used by the strace test), and a strings scan of embedded build paths (informational only). **Dies** if a `GLIBC_REQUIRED*` > `GLIBC_MAX`, listing the files in `logs/glibc-too-new.txt`. |
| 10 | self-test | `run-tests.sh` on the AppDir, using a clean `PATH`, from `/tmp`. If only `ivette-*` tests fail, the build still packages, with a warning. |
| 11–12 | AppImage + delivery tar | The tar contains: AppImage, `install.sh`, `run-tests.sh`, `tests/`, `README.md`, `build-info.txt`, `SHA256SUMS`. |

## Real-build facts (verified on the owner's machine, Frama-C 33.0)

Do not "fix" these back. Each one was observed in a real log.

- **opam resolution.** It picks dune 3.24.2, why3 1.8.2 and alt-ergo 2.6.2. It downgrades ppxlib to 0.35 for Frama-C (fine).
- **The `frama-c` executable stanza** is in `src/init/boot/dune`: `(executable (name empty_file) (public_name frama-c) (modes byte (best exe)) (modules empty_file) (flags :standard -open Frama_c_kernel -linkall) (libraries frama-c.kernel frama-c.init frama-c.boot))`.
  - `empty_file.ml` is **generated by a rule**, so `gen_static_exe.py` copies it from `_build/default/src/init/boot/`.
  - The main program is the `frama-c.boot` library, so the plug-in libraries are inserted **before** `frama-c.boot`.
- **Plug-ins linked statically.** ACSL importer, Alias, Aorai, Callgraph, Dive, Eva, From, Impact, Inout, Instantiate, Loop, Markdown report, MetAcsl, Metrics, Mthread, Nonterm, Obfuscator, Occurrence, Pdg, Reduction, Region, Report, RteGen, Scope, Security-slicing, Semantic Constant Folding, Server, Server TypeScript API, Slicing, Sparecode, Studia, Volatile, WP.
- **`dune install --relocatable` does NOT produce relative paths.** It bakes `<exe>/../` + the absolute `--prefix` path (`/fcai-build/stage/share/frama-c`), so `-print-share-path` prints two lines. Hence:
  - `DUNE_DIR_LOCATIONS` (always set by `AppRun`, searched first);
  - the symlink alias `usr/fcai-build/stage → ..`, because Frama-C builds the libc `-I` path from the *baked* entry (it failed until the alias was added).
- **`DUNE_DIR_LOCATIONS` format.** `pkg:section:dir` triples joined by `:`, so bundle paths cannot contain `:`. dune-site prepends env entries before the encoded one. An unset `DUNE_OCAML_HARDCODED` is only a problem if plug-ins are dynlinked, which they never are here.
- **Why3 runs provers through `$WHY3LIB/why3server`.** It is ENOENT if not shipped. `WHY3DATA`/`WHY3LIB` env vars override Why3's `Config`. The `why3` CLI is **not** shipped: its subcommands are dynlinked `.cmxs` files from the absolute opam `Config.libdir`. The prover config is a template instead.
- **`why3 config detect`** lists Alt-Ergo 2.6.2, CVC4 1.8, CVC5 1.2.1 and Z3 4.13.0 (plus their variants).
- **`-wp-detect` does not exist in Frama-C 33.** The test SKIPs it.
- **WP on `delivery/tests/wp_ok.c`, run with `-wp-rte`:**
  - Alt-Ergo: 50/50.
  - Z3: 49/50 (one timeout on `array_max` loop invariant 2).
  - CVC4/cvc5: 44/50 (Unknown on the quantified/`\exists` goals).
  - All provers together: 50/50.
  - So the per-prover pass rule is "proved ≥ 1 non-Qed goal, no prover error", and `wp-all` must be complete.
- **Frama-C does not quote its own libc `-I` path** in the cpp command. A bundle *directory* whose path contains spaces breaks preprocessing; this is a WARN, documented, and the AppImage mount path never has spaces. `install.sh` warns about spaces too.
- **The preprocessor read `/usr/include/stdc-predef.h`** until the `-nostdinc` wrapper was added. The strace test catches this.
- **Ivette 33:**
  - `ivette/api.sh` uses `../bin/frama-c` unless `DUNE_WS` is set; our `$BUILD_ROOT/wrap/frama-c` → AppRun is on `PATH` and works.
  - `make -C ivette dist` → `electron-builder --dir` (electron 40.0.0, downloaded from GitHub) → `dist/linux-unpacked/frama-c-gui` (~520 MB).
  - The tarball **lacks** `src/frama-c/plugins/region/api`, which `make api` generates.
  - At run time Ivette starts `frama-c -server-socket /tmp/ivette.frama-c.<pid>.io -then <args>` from `PATH`, so the bundle wrapper `usr/lib/fcai-wrappers/frama-c` comes first.
  - Its config goes to `~/.config/Frama-C GUI/`. D-Bus errors under Xvfb are harmless.
- **`AppRun` must `unset ARGV0`** after reading it. Otherwise Ivette → wrapper → AppRun re-dispatches to `ivette` (an infinite GUI loop).
- **In the container:** no FUSE, no unprivileged `unshare`. Those tests SKIP in the self-test and run on the target.
- **Never add a RUNPATH to a bundled library.** First `ubuntu:20.04` build: the relocation check failed with `cc1: error while loading shared libraries: libmpc.so.3: ELF load command address/offset not properly aligned`. Focal's `libmpc.so.3` was linked by old binutils (2 MiB `p_align`, no separate-code). Adding a RUNPATH makes patchelf 0.18 append a PT_LOAD aligned to 4 KiB only (reproduced: `offset=0x201000 vaddr=0x600000 align=0x200000`). glibc 2.31 refuses that; glibc 2.39 tolerates it. The 22.04 build never hit this. Hence:
  - executables get **DT_RPATH** (`--force-rpath`), which glibc also searches for their libraries' dependencies, so libraries need no path of their own;
  - copied libraries stay byte-identical, except that an RPATH/RUNPATH they bring is removed;
  - `patch()` checks alignment after each patchelf run and retries with `--page-size = max p_align`;
  - the final check fails on misaligned PT_LOADs, on `ldd` errors (stderr/rc were ignored before, which let the broken library through), and on executables that still have a RUNPATH. Libraries are checked with `LD_LIBRARY_PATH=usr/lib`, which simulates the RPATH of the executable that loads them.
- **First green `ubuntu:20.04` self-test (2026-10-05).** It reports `GLIBC_REQUIRED=2.29` and `GLIBC_REQUIRED_IVETTE=2.25`, so RHEL 9 (2.34) is covered. Node 22 / electron-builder and the gcc 9.4 preprocessor work on focal. WP gives the same counts as on 22.04 (Z3 49/50, CVC4/cvc5 44/50, Alt-Ergo 50/50, all 50/50) and `wp-negative` gives 3/4. The only WARN is `reloc-spaces`, which is expected. `offline` SKIPs in the container.
- **glibc floor = the build image's glibc.** The first delivered bundle was built on `ubuntu:22.04`; on RHEL 9.8 (glibc 2.34) it failed with `GLIBC_2.35 not found`. The files built in the image (`frama-c`, `gcc-real`/`cc1`, `why3server`, the copied libgmp/libstdc++) carry its glibc. Z3 (glibc-2.31 build) and CVC4/cvc5 (static) do not. So the default is now `ubuntu:20.04`, and three guards exist: the build-time `GLIBC_MAX` check, plus a clear refusal in `AppRun` (`check_glibc`), `run-tests.sh` (test `glibc`, stops early) and `install.sh`. `FCAI_SKIP_GLIBC_CHECK=1` bypasses them; `FCAI_HOST_GLIBC=X.Y` fakes the host version for tests.

- **`frama-c-script` (33.0)** is `#!/bin/bash -eu`, `DIR=$(dirname "$0")`, and sets:
  - `FRAMAC_LIB=$("$DIR/frama-c" -print-lib-path)`, which prints **one** line, the *baked* `<stage>/lib/frama-c/lib`;
  - `FRAMAC_SHARE=$("$DIR/frama-c" -print-share-path)`, which prints two lines.
  - Its commands run `$FRAMAC_LIB/analysis-scripts/*.py` directly (python3 from the host), plus `$FRAMAC_LIB/make_machdep/` and `$FRAMAC_SHARE/libc` / `machdeps`.
  - First real build with it: `find-fun` failed, `.../usr//fcai-build/stage/lib/frama-c/lib/analysis-scripts/find_fun.py: No such file`. Only empty plug-in dirs had been copied from `stage/lib`.
  - Now `stage/lib/frama-c/lib` is copied to `usr/lib/frama-c/lib`, where the `usr/<stage> → usr` alias makes the baked path valid, and `patch_script.py` takes the first line of both `-print-share-path` and `-print-lib-path`.
  - Second real build: the helpers were found, but `function_finder.py` failed on focal's python 3.8 (`list[str]`).
  - Third real build, with python3.9: it failed on `def get_first_line_after(...) -> int | None` → `TypeError: unsupported operand type(s) for |`. **The 33.0 analysis scripts need Python ≥ 3.10.** RHEL 9's python3 is 3.9, and an offline no-root user cannot install another.
    - Hence the **bundled CPython** (python-build-standalone 3.12.14, tag 20260924, pinned SHA256, needs glibc ≥ 2.17) in `usr/lib/fcai-python`, trimmed to about 76 MB. It is installed *after* `bundle_libs` because it carries its own `$ORIGIN/../lib` RPATH.
    - `AppRun frama-c-script` puts its `bin` first on PATH and unsets `PYTHON*`. `WITH_PYTHON=0` falls back to the host python3, and the test then requires ≥ 3.10 or WARNs.
    - **PyYAML** (needed by `make-machdep` and others, owner 2026-10-08) is baked into the bundled Python's `site-packages`. It is the pure-Python package only (`lib/yaml` of tag 6.0.3, cloned with git and pinned by commit `49790e7…`), with no libyaml C extension, so `yaml.CLoader` is absent and loading is slower but path- and glibc-neutral. PyPI and GitHub archive downloads were refused in the agent workspace, but `git clone` worked. Test: `<mode>-script-yaml` = `frama-c-script make-machdep --help`.
    - The same build FAILed `strace-leaks` on `/fcai-build/py39`: the python3.9 shim dir lived under the build root. The shim is gone.
  - Tests: `<mode>-script` (`help` + `find-fun main tests/`). The mock uses the real 33.0 script (`dev/mock/frama-c-script`, LGPL).

- **Bash completion** (owner, 2026-10-08: "use autocomplete_frama-c from outside the AppImage, or make an improved one"). The upstream `share/autocomplete_frama-c` still ships, unused; ours is generated.
  - **Self-contained:** everything is baked in, so completing never starts frama-c (an AppImage mount per TAB) and the file works outside the AppImage.
  - **What it completes:** options, `-no-` opposites, `-machdep` values, comma lists for `-wp-prover`, file arguments, C sources, and `frama-c-script` commands.
  - **Delivery:** `AppRun --fcai-completion` prints it. `install.sh` writes it to `${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/frama-c`, with `frama-c-script` and `ivette` symlinked to it; `--no-completion` skips this, and `--uninstall` removes only files marked `# fcai-completion`.
  - **Test:** `completion` drives `_fcai_frama_c` / `_fcai_frama_c_script` with `COMP_WORDS`.
  - **Not yet verified on a real build:** the parser assumes Frama-C's help format ("-opt <arg>" at column 0, "(opposite option is -no-x)", `-plugins` lines ending in "(-x-h)"). Check `logs/completion-src/` and `completion.txt` (option counts) from the next build.
- **Logs on success.** `dist/logs/` was only filled on failure; `export_logs` now also runs at the end of a green build.

## Design invariants

- **Nothing at run time may point into the build machine.** The checks are:
  - `run-tests.sh`'s strace check FAILs on *successful* accesses to `BUILD_ROOTS`, a host gcc/cpp/include or host provers/why3/frama-c;
  - accesses to ancestors of the bundle root are allowed;
  - the strings scan is informational only: `frama-c`, `alt-ergo`, `why3server`, `why3cpulimit` and `Makefile.config` still contain build paths that are never used.
- **Only glibc comes from the host** for the CLI tools. Ivette/Electron takes the desktop libraries (GTK, NSS, …) from the host, like any Electron app.
- **Checks must be strict.** "Starts with the bundle root" is not proof: check that the path exists and has the expected content. A prefix-only check once hid the broken share path.
- **Test pass criteria** must test that a component *works*, not prover strength.
- **All downloads are pinned** (SHA256, or nodejs.org's SHASUMS). New versions: update the version and the hash together.

## Mock harness (`dev/mock/`)

`run-mock.sh [WORKDIR]` stamps steps 0–4 as done, installs a fake `opam`, and fakes:
- the stage (`frama-c-static.in`: mimics `-print-share-path` with the baked second entry, `DUNE_DIR_LOCATIONS` handling, libc taken from the *baked* entry, the why3server requirement, prover calls through `PATH`);
- the Why3 CLI (`why3.in`);
- `alt-ergo`;
- Ivette (`mock-ivette.c`: an ELF that starts `frama-c -server-socket` from `PATH`; `IVETTE_MOCK=bad` gives one that never does);
- `frama-c-script`: the real 33.0 script; `-print-lib-path` prints the baked entry, and `stage/lib/frama-c/lib/analysis-scripts/find_fun.py` is a mock that must be shipped (it uses 3.10-only syntax), and so is `make_machdep/make_machdep.py`, which imports `yaml`. A final scenario runs `run-tests.sh --quick` with a host `python3` stub that reports 3.8 and exits 99 if asked to run a script, and expects `*-script` PASS "(python: bundled)";
- help output for completion: the mock frama-c answers `-plugins` with the real 33.0 list, `-<x>-h` from `dev/mock/help/*.txt` (written in Frama-C's format), and `-machdep help`;
- `why3server`: an ELF depending on `libfcaiold.so.1` → `libfcaiold2.so.1`, both linked old-style (2 MiB `p_align`, no separate-code, like focal's libmpc), with an absolute RUNPATH into the build root. The mock frama-c runs it and requires `why3server-ok`, so library loading is exercised in every relocation test and under strace. The old library patching gives misaligned PT_LOADs on these files, which the new check rejects.

The mock bundles the workspace's own gcc, so its `GLIBC_REQUIRED` follows the workspace glibc (2.38 in the agent workspace); it passes `GLIBC_MAX=<host glibc>` to the build. After the target run it also runs the **glibc scenarios**: with `FCAI_HOST_GLIBC=2.17`, `AppRun`, `run-tests.sh` and `install.sh` must refuse clearly, and a build with `GLIBC_MAX=2.17` must die and list the offending files.

It then runs the real `build.sh` and `run-tests.sh` on the untarred AppImage, with real Z3/CVC4/cvc5, real gcc relocation and real appimagetool. Expect: build passes, ~108 PASS on the target run, no FAIL, then `glibc scenarios: all ok`. **When a real build reveals a new behaviour, encode it in the mock first.**

## Open items / next steps

1. **The `ubuntu:20.04` build is green** (self-test: 0 FAIL, 1 expected WARN). `frama-c-script`: the helpers are now found (real build); the bundled Python is validated by the mock only. Next: a rebuild, expecting `dir-script` PASS "(python: bundled)", `dir-script-yaml` PASS, `strace-leaks` PASS and `completion` PASS (check `logs/completion-src/`), then `run-tests.sh` on RHEL 9.8.
2. **Target-side checks not yet run on a real offline machine:** FUSE mount, `unshare -rn`, Ivette with a real display. The target is RHEL 9.8 (glibc 2.34); the 22.04 build failed there on glibc.
3. **Possible improvements, not requested:**
   - flambda (`OCAML_FLAMBDA=1`);
   - SWI-Prolog for MetAcsl deduction (`conf-swi-prolog`);
   - shrinking the AppImage (Ivette is ~520 MB unpacked);
   - quoting the libc path upstream.
