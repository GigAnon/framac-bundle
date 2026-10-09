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
4. Once the build is green, the owner copies `dist/frama-c-33.0-1.0-offline-x86_64.tar` to the offline target and runs `./run-tests.sh` there. The `fcai-test-report-*.txt` comes back.

**Messages to the owner.** Keep them short: what failed, the cause, what changed, what to run, what to send back. The owner is technical. Be precise; skip the tutorials.

**Real builds can be tested by the agent.** The owner publishes the delivery tar as a GitHub release of `GigAnon/framac-bundle`, a public repo, e.g. `gh release create build-<date> dist/frama-c-33.0-1.0-offline-x86_64.tar`. The agent downloads it (release assets are reachable), checks `SHA256SUMS`, and runs the shipped `run-tests.sh` in its workspace. That workspace is Ubuntu 24.04 with glibc 2.39, where FUSE, unprivileged `unshare` and Xvfb all worked on 2026-10-08, so it covers what the build container SKIPs.

**The agent's workspace network may be restricted.** In the first session opam.ocaml.org, frama-c.com, git.frama-c.com and nodejs.org were blocked, while GitHub release assets were reachable. A real build was therefore impossible there, which is why the mock exists. Check what is reachable before relying on it. Never try to get around a proxy refusal.

## Pipeline (`build.sh`)

Each step is stamped in `$BUILD_ROOT/stamps`; `FORCE=step` or `FORCE=all` reruns.

| # | Step | Notes |
|---|---|---|
| 0 | system-packages | apt inside the container (not stamped there). Electron runtime libraries + Xvfb when `WITH_IVETTE=1`. |
| 1 | opam binary (pinned SHA256), `opam-init`, `opam-switch` (OCaml 4.14.2, plain), `opam-deps` | `OCAML_FLAMBDA=1` (opt-in, **failed on the real build**, see below) uses `ocaml-variants.4.14.2+options` + `ocaml-option-flambda`, which must report `flambda: true`, then exports `OCAMLPARAM=_,O3=1` (`OCAML_O3`) for the opam deps, Frama-C and why3; a probe checks it. `stamps/ocaml-conf` records the compiler configuration; a change rebuilds the switch, deps, Frama-C (`_build` removed) and why3. Installs `ALTERGO_PKG` first, then `--deps-only frama-c.33.0`. |
| 2 | `framac-source` | `opam source frama-c.33.0`. |
| 2b | vendoring (not stamped) | `EXTRA_PLUGINS` (MetAcsl) is copied into `src/plugins/fcai-extra-<pkg>/` with `opam source`. The `.fcai-<pkg>` marker forces a rebuild when the list changes. |
| 3 | `framac-build` | With flambda, first the dune `-O3` probe. Then `dune build --release @install`. Checks that each vendored plug-in registered a dune-site plug-in META. |
| 4 | `framac-static` | `lib/gen_static_exe.py` finds the `frama-c` executable stanza, reads the plug-in libraries from `_build/install/default/lib/frama-c/plugins/*/META`, and writes `src/init/boot/fcai_static/dune`. It then builds and runs `dune install --release --relocatable --prefix $STAGE`. |
| 4b | `why3-reloc` | Relocatable why3 CLI: `opam source why3.<ver>`, `./configure --enable-relocation --prefix=$BUILD_ROOT/why3-reloc`, `make`, `make install`. Its `bin/why3` and `lib/why3/{commands,plugins}` are what the AppDir ships. |
| 5 | downloads | Z3 4.13.0 (glibc-2.31 build), CVC4 1.8 (static, CVC4-archived repo), cvc5 1.2.1 (static), appimagetool 1.9.0, type2 runtime 20251108. All pinned by SHA256. |
| 6 | AppDir | The static `frama-c`, `frama-c-script` (patched by `lib/patch_script.py`: each `$(... -print-share-path/-print-lib-path)` keeps its first line; original and patch report in `logs/`) + its helpers `usr/lib/frama-c/lib` (analysis-scripts, make_machdep), `share/`, empty plug-in site dirs, Why3 data and helper programs, provers, the gcc preprocessor (`gcc-real` + a `-nostdinc` wrapper + `cc1`), **strip** (`STRIP=1`: `frama-c`, `why3`, `alt-ergo`, the why3 helpers with `strip`, the `.cmxs` with `--strip-unneeded`; before `bundle_libs`; sizes in `logs/strip.txt`), `bundle_libs.py` (pinned static patchelf 0.18.0; executables get a relative DT_RPATH, copied libraries are **not modified**, every patched file is checked for PT_LOAD alignment, and `ldd` errors fail the build), and the `usr$STAGE → usr` symlink. |
| 7 | relocation check | Writes `usr/share/fcai/dune-dir-locations`. Moves a copy; **every** `-print-share-path` entry must exist and contain `libc/`. Parses a C file with `#include`s while the original AppDir is moved away. Runs `-plugins`. |
| 8 | why3.conf template | `why3 config detect` against the bundled provers (`PATH=usr/bin` only). The AppDir path is replaced by `@APPDIR@`, and `datadir`/`libdir` lines are dropped. |
| 8c | Python | `WITH_PYTHON=1`: python-build-standalone CPython 3.12 into `usr/lib/fcai-python` (for `frama-c-script`), plus pure-Python PyYAML 6.0.3 (git tag, commit-pinned), trimmed and smoke-tested. |
| 8d | completion | `lib/gen_completion.py` runs the bundled `frama-c -plugins`, `-kernel-h` and each `-<x>-h`, `-machdep help` and `frama-c-script help`, and fills `lib/completion.bash.in` into `usr/share/fcai/completion/frama-c.bash`. Raw outputs go to `logs/completion-src/`. |
| 8b | Ivette | Node 22.22.2 (checked against nodejs.org SHASUMS) + corepack/yarn 1. Runs `make -C ivette api` then `make -C ivette dist`. The resulting `dist/linux-unpacked` is imported; `IVETTE_PREBUILT` overrides. `lib/asar_prune.py` then removes `*.map` from `resources/app.asar` (`IVETTE_PRUNE_MAPS=1`) and verifies every remaining file (log `ivette-asar-prune.txt`). |
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
- **Why3 runs provers through `$WHY3LIB/why3server`.** It is ENOENT if not shipped. `WHY3DATA`/`WHY3LIB` env vars override Why3's `Config`. The prover config is a template, filled in per location.
- **The `why3` CLI** (owner, 2026-10-08: "add why3 to bin/") is shipped as `usr/bin/why3` and gets an RPATH from `bundle_libs`.
  - **It must be the relocatable build (step 4b, `why3-reloc`).** `src/tools/main.ml` reads sub-commands from `Filename.concat Config.libdir "commands"`. That libdir is a compile-time constant; only the library (`whyconf.ml`) reads `WHY3LIB`.
    - The first bundle shipped the **opam** binary. It passed every test in the build container, because `/fcai-build/opam/fcai/lib/why3/commands` exists there: a silent build-tree dependency.
    - On the agent's machine, with the real 2026-10-08 release, `why3 config list-provers` failed with `anomaly: Sys_error("/fcai-build/opam/fcai/lib/why3/commands: No such file or directory")`.
    - Fix: `opam source why3.<ver>`, then `./configure --enable-relocation --prefix=$BUILD_ROOT/why3-reloc` (IDE, Coq, PVS and Isabelle disabled), `make`, and `make install` (= install-bin + install-data, no findlib). In config.sh.in, relocation gives `libdir = <exe>/../../lib/why3` and `datadir = …/share/why3`, which is exactly the AppDir layout.
    - Its `bin/why3` and `lib/why3/{commands,plugins}` are bundled; they must come from the same build, as the `.cmxs` are dynlinked into it. The helpers (`why3server`, …) still come from opam's libdir. Logs: `why3-reloc-configure.log`, `why3-reloc-build.log`.
    - `strace-leaks` now also traces `why3 prove`; test inputs under `$TESTS` are exempt from the host-path patterns, because `why3_ok.why` matched `/why3`. With the old binary, the mock fails it on `<build root>/opam/fcai/lib/why3/commands/why3prove.cmxs`.
  - The list of shipped files goes to `logs/why3-files.txt`, and the build dies if `commands/` is empty.
  - `AppRun why3` runs it with `setup_env`, and `install.sh` links it.
  - Test `<mode>-why3`: `--version`, `config list-provers`, and `why3 prove -P <first bundled prover> tests/why3_ok.why` must say Valid.
  - **2026-10-08 build:** `why3 prove -P z3` proved the goal in the container, but only through the build tree (see above). The opam libdir holds 14 commands (`why3bench`, `why3config`, …, `why3wc`, `why3webserver`, named `why3<cmd>.cmxs`), parser plugins (`cfg`, `coma`, `dimacs`, `forward_propagation`, `genequlin`, `hypothesis_selection`, `microc`, `python`, `tptp`; `.cma` + `.cmxs`) and the helpers `why3-call-pvs`, `why3cpulimit` and `why3server`.
- **`WHY3CONFIG` from the environment is honoured** (a colleague's request, 2026-10-08). `setup_env` used to always replace it with the generated configuration. Now `FCAI_WHY3CONFIG` wins first, then a non-empty `WHY3CONFIG` (with a warning if it is unreadable), then the generated one. Ivette's inner frama-c inherits the outer choice.
  - Test `<mode>-why3config`: a copy of the generated configuration keeping only the first prover must be all that `why3 config list-provers` sees, and WP must run with that prover.
    - **Real `list-provers` prints each prover's variants**, e.g. "Alt-Ergo 2.6.2", "… (BV)", "… (counterexamples)". The first version of the test required exactly one line and FAILed on the 2026-10-08 build, although the variable *was* honoured: only Alt-Ergo lines appeared.
    - The test now requires every listed line to name that prover, and the mock's `list-provers` prints variants too. The mock frama-c now requires the prover to be declared in `WHY3CONFIG`, as real WP does, and the old AppRun fails this test.
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
  - **What it completes:** options, `-no-` opposites, `-machdep` values, comma lists for `-wp-prover`, file arguments, C sources, `frama-c-script` commands, and `why3` commands (from the shipped `commands/*.cmxs`), `-P` provers and `.why`/`.mlw` files.
  - **Delivery** (owner: "install.sh must not copy it into the user's home, the install user is often root"):
    - `install.sh` writes nothing outside DIR/BIN. It stores `DIR/frama-c-completion.bash` (from `--fcai-completion`) and `DIR/setup_completion.sh`, and links the latter into BIN.
    - Each user runs `setup_completion.sh`, which finds the file next to itself through `readlink -f`. It symlinks it into `${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/frama-c`, plus `frama-c-script` and `ivette` → `frama-c`. Without bash-completion it adds a marked source line to `~/.bashrc` (`--no-bashrc` skips this).
    - Its other modes are `--system` (root, the system completions directory), `--uninstall` and `--print`.
    - As root, `install.sh` now defaults to `/opt/frama-c-VERSION` and `/usr/local/bin`.
  - **Test:** `completion` drives `_fcai_frama_c` / `_fcai_frama_c_script` with `COMP_WORDS`.
  - **Verified on the 2026-10-08 build:** 1035 options (404 with an argument, 80 with a file argument), 34 plug-in help options, 11 machdeps, 15 `frama-c-script` commands and 14 `why3` commands. The help format assumptions hold.
  - **Compared with upstream `autocomplete_frama-c`** (supplied by the owner):
    - Upstream runs frama-c on every TAB: `-autocomplete @all` for options, `-wp-list-provers` for `-wp-prover` (bracketed names separated by `|`), and `<opt> help` for `-wp-msg-key`, `-kernel-msg-key` and `-kernel-warn-key`. It also globally removes `:` from `COMP_WORDBREAKS`, and registers `frama-c` and `frama-c-gui`.
    - Ours now takes all of these at build time: options from `-autocomplete @all`, prover names from `-wp-list-provers`, and the keys of **every** `-*-msg-key` and `-*-warn-key` option. The values sit in a bash associative array, `_fcai_optvals`, and are completed as comma-separated lists.
    - Words are taken from `COMP_LINE`, and the part before the last `:` is trimmed from candidates, so `native:alt-ergo` and `annot:missing-spec` complete without touching `COMP_WORDBREAKS`. `frama-c-gui` is registered too.
    - **`frama-c -autocomplete @all` (real 33.0 output, supplied by the owner)**: under each "Plugin: <name>" header there is one line per option, `  -opt: <type>` with `<type>` being `bool`, `string` or `int`. A parenthesised list follows for enumerated strings (`-wp-cache: string (none, update, cleanup, replay, rebuild, offline)`, `-std: string (c11, c17, c23, c2y)`) and for int ranges (`-eva-precision: int (-1, 11)`).
      - It is now parsed line by line. Any non-`bool` option takes an argument, and an enumerated string's values go into `_fcai_optvals`.
      - The first parser grabbed every `-word` token and would have taken `-1` as an option.
      - The mock serves an excerpt of the real file (`dev/mock/help/autocomplete-all.txt`), and the test checks `-wp-cache upd` and `-std c1`.
    - **Verified on build-20261008-1818:** `-wp-list-provers` gives `Alt-Ergo:2.6.2 CVC4:1.8 CVC5:1.2.1 Z3:4.13.0` (plus our short names), and every `-*-msg-key`/`-*-warn-key` gets its categories, including `:` sub-keys (`annot:missing-spec`, `memdebug:alias`). 40 options carry value lists.
- **Size reductions (owner, 2026-10-09: "strip extra, keep the locales").** Measured on the real build-20261008-1818 files in the agent workspace:
  - **Ivette `app.asar`** is 242 MB: `out/` (the electron-vite bundle) is 11 MB, the rest is `node_modules`, including 604 `*.map` files (63.9 MB). Every one of its 38 687 entries carries a SHA256 `integrity` (hash + 4 MiB blocks).
    - `asar_prune.py` rewrote it to 178 MB in 1.4 s, and all 38 083 remaining files verified.
    - The real Ivette with that archive, under Xvfb, starts its frama-c server and renders the full UI: views list, AST with the Eva alarm, source, inspector (screenshot checked).
    - Pruning `node_modules` itself is *not* done: the main process `require`s `lodash`, `yaku` and `@electron-toolkit/*`, and the renderer may load packages such as `@hpcc-js/wasm` at run time, so it would need GUI-level testing.
    - The 55 locales stay (owner).
  - **strip:** `strip -s` on `frama-c` (84 → 63 MB), `why3` (22 → 15 MB), `alt-ergo` (23 → 17 MB), plus the why3 helpers and `.cmxs`: about 35 MB unpacked. After stripping the real files: WP 50/50, Eva, `why3 prove` with all four provers (so the `.cmxs` still load), `why3 wc`/`show`, `frama-c-script` and alt-ergo all work. Z3, CVC4 and cvc5 have no debug info.
  - **Compression:** the AppImage is squashfs/zstd (296 MB for 855 MB unpacked). With xz (rough per-part sizes): Electron binary 60 MB, `app.asar` 44 MB, locales 8 MB, Python 19 MB, `usr/bin` 48 MB.
- **flambda (owner, 2026-10-09: "add flambda; build time is not an issue") — FAILED, default back to `OCAML_FLAMBDA=0`.**
  - **Real build 2026-10-09:** the switch and both `-O3` probes passed ("flambda -O3 confirmed through dune"). Then, after hours, `framac-build` died: `ocamlopt.opt ... -c -impl src/plugins/eva/src/parameters.pp.ml` → `Fatal error: exception Stack overflow`. The owner also saw the machine run out of memory.
  - flambda `-O3` blows up on big generated modules, which is probably also why `frama-c.33.0` conflicts with the flambda variants (see below).
  - Untried fallbacks: flambda without `-O3` (`OCAML_O3=0`), `ulimit -s unlimited`, and `JOBS=1` for memory. None is worth it without a measured speed-up.
  - Switching back is automatic: the owner's volume has `ocaml-conf` = `flambda=1 o3=1`, so the next default build rebuilds the plain switch (mock scenario).
  - The switch is `ocaml-variants.4.14.2+options` + `ocaml-option-flambda`, and `OCAMLPARAM=_,O3=1` is exported after the switch is created. That applies `-O3` everywhere without editing any dune file; command-line flags still win, because they replace `_`.
  - **Probes:** with `-O3`, flambda runs 3 rounds, and `-inlining-report` writes `<prefix>.<round>.inlining.org` per round.
    - `o3-probe` compiles one file with `ocamlopt` directly.
    - `o3-probe-dune` does the same through dune, at the start of `framac-build`.
    - Both require `*.2.inlining.org` and die otherwise; the file list is in `logs/o3-probe.txt`.
    - Not yet seen on a real build: if the file naming differs, the build dies early with the list.
  - **Caveat, from opam-repository:** `frama-c.33.0`'s opam file (and not 32.0 or earlier) lists `ocaml-variants` `4.14.{0..5}+flambda` and `+flambda-fp` as conflicts. Those legacy package names no longer exist in the repository, and our `+options` route is not covered. No reason is documented. So results must be compared with the non-flambda build: WP counts (Z3 49/50, CVC4/cvc5 44/50, Alt-Ergo 50/50, all 50/50, negative 3/4) and Eva's alarm.
- **Versioning (owner, 2026-10-09).** The bundle version is `<Frama-C version>-<bundle revision>`: `BUNDLE_REV=1.0` gives `33.0-1.0`. It appears in the tar and directory name (`frama-c-33.0-1.0-offline-x86_64`), in the AppImage name (`Frama-C-33.0-1.0-x86_64.AppImage`), in the default install dir (`frama-c-33.0-1.0`), and in build-info (`BUNDLE_VERSION`, plus `BUNDLE_COMMIT` = the repo commit, `-dirty` if modified). `--fcai-version` prints it.
  - The v33.0-1.0 release says `BUNDLE_COMMIT=unknown`: in the container, git refuses `/fcai-src` (owned by the host user, read-only: "dubious ownership"). `build-in-container.sh` now computes it on the host and passes `FCAI_COMMIT`. Bump `BUNDLE_REV` for bundle-only changes; a new Frama-C version restarts it at 1.0. Git tag: `v33.0-1.0`.
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

`run-mock.sh [WORKDIR]` stamps steps 0–4 as done (with the default `ocaml-conf`), installs a fake `opam`, and fakes:
- the stage (`frama-c-static.in`: mimics `-print-share-path` with the baked second entry, `DUNE_DIR_LOCATIONS` handling, libc taken from the *baked* entry, the why3server requirement, prover calls through `PATH`);
- the Why3 CLI (`why3.in`), like the real one:
  - sub-commands come from `Config.libdir/commands/why3<cmd>.cmxs` **without** looking at `WHY3LIB`;
  - `Config.libdir` is baked, or `<exe>/../lib/why3` when built relocatable (`@RELOC@`);
  - the library side (`why3server`, drivers) honours `WHY3LIB`/`WHY3DATA`;
  - `prove` resolves the prover through `WHY3CONFIG`;
  - the opam libdir lives under the build root (`$R/opam/fcai/lib/why3`), as on the real build;
  - the fake `opam source why3.*` gives `dev/mock/why3-src` (a `configure` with `--prefix`/`--enable-relocation`, and a `Makefile` whose `install` lays out bin/lib/share), and the `why3-reloc` step always runs;
- `alt-ergo`;
- Ivette (`mock-ivette.c`: an ELF that starts `frama-c -server-socket` from `PATH`; `IVETTE_MOCK=bad` gives one that never does);
- `frama-c-script`: the real 33.0 script; `-print-lib-path` prints the baked entry, and `stage/lib/frama-c/lib/analysis-scripts/find_fun.py` is a mock that must be shipped (it uses 3.10-only syntax), and so is `make_machdep/make_machdep.py`, which imports `yaml`. A final scenario runs `run-tests.sh --quick` with a host `python3` stub that reports 3.8 and exits 99 if asked to run a script, and expects `*-script` PASS "(python: bundled)";
- help output for completion: the mock frama-c answers `-plugins` with the real 33.0 list, `-<x>-h` from `dev/mock/help/*.txt` (written in Frama-C's format), and `-machdep help`;
- `why3server`: an ELF depending on `libfcaiold.so.1` → `libfcaiold2.so.1`, both linked old-style (2 MiB `p_align`, no separate-code, like focal's libmpc), with an absolute RUNPATH into the build root. The mock frama-c runs it and requires `why3server-ok`, so library loading is exercised in every relocation test and under strace. The old library patching gives misaligned PT_LOADs on these files, which the new check rejects.

Flambda, strip and asar in the mock:
- `ocamlopt` (`dev/mock/ocamlopt`) answers `-config` with `flambda: true`, and writes one inlining report per round: 3 when `OCAMLPARAM` has `O3=1`, else 1. It is exercised by the opt-in scenario `OCAML_FLAMBDA=1 STOP_AFTER=o3-probe`.
- `stamps/ocaml-conf` is pre-written with the default (`flambda=0 o3=0`), and the main build checks that build-info says plain `4.14.2` and that no probe ran.
- `why3cpulimit` is a `-g` ELF that must come out without `.symtab`/`.debug_*` but with its RPATH.
- Ivette's `app.asar` comes from `make_asar.py` (`.map` files, integrity hashes) and must come out without maps and verified.
- A final scenario runs `build.sh STOP_AFTER=ocaml-conf` on a copy of the stamps whose `ocaml-conf` says flambda `-O3` (the owner's volume after the failed build): the switch/deps/Frama-C/why3 stamps and `_build` must go, `framac-source` must stay, and an unchanged configuration must keep everything.

The mock bundles the workspace's own gcc, so its `GLIBC_REQUIRED` follows the workspace glibc (2.38 in the agent workspace); it passes `GLIBC_MAX=<host glibc>` to the build. After the target run it also runs the **glibc scenarios**: with `FCAI_HOST_GLIBC=2.17`, `AppRun`, `run-tests.sh` and `install.sh` must refuse clearly, and a build with `GLIBC_MAX=2.17` must die and list the offending files.

The last scenarios check that `install.sh` leaves the installer's `$HOME` empty, and that another user's `setup_completion.sh` installs links that complete, then uninstalls them.

It then runs the real `build.sh` and `run-tests.sh` on the untarred AppImage, with real Z3/CVC4/cvc5, real gcc relocation and real appimagetool. Expect: build passes, ~116 PASS on the target run, no FAIL, then `glibc scenarios: all ok`. **When a real build reveals a new behaviour, encode it in the mock first.**

## Open items / next steps

1. **Release build-20261008-1818, run by the agent** (Ubuntu 24.04, glibc 2.39): **110 PASS, 0 FAIL**, 1 WARN (`reloc-spaces`, expected). The relocatable `why3` works: `why3`/`why3config` PASS in both modes, and `strace-leaks` (now also tracing `why3 prove`) PASSes.
   - Also PASS: FUSE mount, extraction, relocation, `offline` (`unshare -rn`), all Ivette tests (Xvfb), `completion` (1185 options).
   - Earlier release build-20261008-1759 failed only `why3`/`why3config` (opam why3 using the build tree; see above).
   - **Owner, 2026-10-09, on RHEL 9.8:** Frama-C, `frama-c-script`, bash completion and Ivette (with a real display) confirmed working.
   - `PLUGINS=` in build-info was garbled (first word of each help line, including continuation lines); it now lists the full names, comma-separated.
2. **Release build-20261009-1959, run by the agent:** 110 PASS, 0 FAIL, 1 WARN (`reloc-spaces`), the same as 1818. The delivery tar is 296.3 → 254.9 MB (−41 MB, −14%) from strip and the removed `.map` files. OCaml is plain 4.14.2, `STRIPPED=yes`. The WP counts are identical (Z3 49/50, CVC4/cvc5 44/50, Alt-Ergo 50/50, all 50/50, negative 3/4), and so are the Eva alarm, Ivette under Xvfb, strace and completion.
3. **Release v33.0-1.0 (2026-10-09), published by the owner, run by the agent:** 110 PASS, 0 FAIL, 1 WARN (`reloc-spaces`). The tar is 254.9 MB, `--fcai-version` gives `33.0-1.0`, and `install.sh --dir/--bin` installs all 9 commands (`frama-c -version` and `why3 --version` work) without touching `$HOME`. One flaw: `BUNDLE_COMMIT=unknown` (fixed for the next build, see Versioning). Notes: `RELEASE-NOTES.md`.
4. **Possible improvements, not requested:**
   - SWI-Prolog for MetAcsl deduction (`conf-swi-prolog`);
   - shrinking the AppImage (Ivette is ~520 MB unpacked);
   - quoting the libc path upstream.
