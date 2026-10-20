# rtk-embedded-linux

Filters that let [rtk](https://github.com/rtk-ai/rtk) (Rust Token Killer) shrink what an AI coding agent reads
from **Yocto/BitBake** and **Buildroot** commands, without hiding errors, warnings or where a build failed.
It also includes a measured evaluation of rtk on this workload: savings, losses, defects, and the cases where
rtk does not run at all.

**One file, every runtime.** [`.rtk/filters.toml`](.rtk/filters.toml) works unchanged whether the agent runs
`bitbake`/`make` on the host, inside a container, through `podman run|exec`, through `apptainer`/`singularity run|exec`,
or through any `*.sh` wrapper script. Docker works through a wrapper; [here is why](#docker-why-docker-run--bitbake-is-not-filtered-and-what-to-do-instead).

Measured on a Raspberry Pi 4 reference build ([details](#effectiveness-measured)):

- a full Yocto `core-image-minimal` build: **946 742 → 496 bytes (−99.94%)**, with every WARNING and both
  summaries kept;
- `bitbake -e`: **2.17 MB → 4.9 KB (−99.77%)**, with the rest saved to a file the agent can grep;
- a full Buildroot build: **5.36 MB → `buildroot: OK` (−99.99%)**. A failing Buildroot build keeps the error, the
  source excerpt and the `make: ***` lines (541 KB → 1.1 KB);
- 21 real agent runs through the rtk hook, as counted by rtk: **622 977 → 20 290 tokens (−96.74%)**.

## Requirements

- **rtk ≥ 0.48.0**. All measurements were made with 0.48.0. The filters rely on its `^`-anchored
  `match_command` rule.
- **rtk's agent hook**, installed with `rtk init -g`. Without it nothing is rewritten.
- *Optional:* **ripgrep**, as `rg` or `ripgrep` on `PATH` (or `RG=/path`), for `scripts/rg-fallback.sh` and
  `scripts/check-routing.py`. Python ≥ 3.11 for the scripts in `scripts/`.
- *Only to rebuild the samples:* Podman, Apptainer or Docker, and disk space. After all builds this checkout
  holds 19 GB: Yocto downloads 7.2 GB, sstate 3.4 GB, `tmp/` restored from sstate 3.2 GB, Buildroot 5.2 GB. The
  first Yocto build's `tmp/` (built from scratch) is larger and was not measured.

## Install

```bash
# 1. rtk itself (see https://github.com/rtk-ai/rtk for other install methods), then the agent hook
rtk --version                  # must print 0.48.0 or newer
rtk init -g                    # installs the hook for Claude Code (and other supported agents)

# 2a. per project (recommended): put the file in your Yocto/Buildroot project and trust it there
mkdir -p .rtk && curl -fsSL -o .rtk/filters.toml \
  https://raw.githubusercontent.com/FPGArtktic/rtk-embedded-linux/master/.rtk/filters.toml
rtk trust                      # shows the 12 filters and asks to confirm; `rtk trust --yes` in scripts

# 2b. or for every project of this user
curl -fsSL -o ~/.config/rtk/filters.toml \
  https://raw.githubusercontent.com/FPGArtktic/rtk-embedded-linux/master/.rtk/filters.toml
rtk trust

# 3. smoke test: each must print an `rtk …` line
rtk rewrite 'bitbake core-image-minimal'
rtk rewrite 'podman exec yocto bash -c "cd build && bitbake core-image-minimal"'
rtk rewrite './build.sh make'
```

Then **restart the agent** so the hook picks up the change. If your builds run in a container, especially under
Docker, add a wrapper script. [A prompt that makes your agent write one](#your-own-wrapper-script-generated-by-your-agent)
is below. Three things to know:

- **`rtk trust` again after every edit** of the file. Trust is a hash of the file contents, and a changed,
  untrusted file is skipped *silently*.
- **User-global install (2b):** `buildroot-make` then claims every `make` on the machine, not only Buildroot's.
  Its output rules are written for Buildroot, so the per-project install is the safer default.
- **Already have a `filters.toml`?** Merge the `[filters.*]` and `[[tests.*]]` tables into it. Keep
  `schema_version = 1` at the top.

## Supported runtimes

rtk matches a filter against the command the agent typed. A runtime works when rtk can see the build tool in that
command:

| How the agent runs the build | Example | Filtered? |
|---|---|---|
| on the host | `bitbake core-image-minimal`, `source oe-init-build-env && bitbake …`, `make` | yes |
| agent inside the build container | same as the host (rtk + filters installed in the container) | yes |
| Podman | `podman run … IMAGE bitbake X`, `podman exec CTR bash -c "… && bitbake X"` | yes |
| Apptainer / Singularity | `apptainer exec\|run … image.sif bitbake X` | yes (Apptainer tested; Singularity not tested) |
| any `*.sh` wrapper | `./scripts/ctr.sh yocto bitbake X`, `./build.sh make` | yes |
| Docker | `docker run … bitbake X` | **no**, see [Docker](#docker-why-docker-run--bitbake-is-not-filtered-and-what-to-do-instead); use a `*.sh` wrapper |

Tested end to end through the hook: `scripts/ctr.sh` with rootless Podman 6.1.3, Docker 29.9.0 and Apptainer
1.5.4, and direct `apptainer run …`. Every other form in the table is checked by `rtk rewrite` in
`scripts/check-routing.py`.

**rtk only filters plain commands.** It leaves these alone whatever the filters say:

- pipelines (`bitbake X 2>&1 | tail -50`);
- a compound command that contains `$(…)`, backticks or a file redirect in any segment;
- `bash -c '…'`.

Ask the agent to run the bare build command. The complete list is at the end of the routing table below.

## Your own wrapper script, generated by your agent

A wrapper like [`scripts/ctr.sh`](scripts/ctr.sh) is the most portable way to run builds. It works with every
runtime, including Docker, and the filters see the build command through it. You do not need this repository's
wrapper. Any script works if it follows six rules, which were all checked against rtk 0.48.0:

1. **The file name ends in `.sh`, and the script is executable and run directly** (`./name.sh …`, `name.sh …`
   on `PATH`, `/path/name.sh …`). `bash name.sh …` and `sh name.sh …` are **not** rewritten by rtk, and neither
   is a script without the `.sh` suffix.
2. **The build tool and its arguments come last, as separate words**:
   `./name.sh [own options] bitbake core-image-minimal`. The script's own options must not contain `;`, `&` or
   `|`.
3. **It passes the arguments through unchanged** (`"$@"`) and **exits with the tool's exit status**
   (`exec …`). rtk shows a failure, and saves the full log, only when the exit status is non-zero.
4. **It does not allocate a TTY when stdout is not a terminal.** Use `-t` only when `[ -t 1 ]`. When BitBake
   sees a terminal it draws progress bars, which no line filter can clean up.
5. **It prints nothing of its own on stdout.** Status messages go to stderr, so the filter sees only the tool's
   output.
6. **The tool runs ready to use.** For Yocto, `oe-init-build-env` is sourced inside the container. For
   Buildroot, `make` runs in the output directory or with `O=`. A wrapper that pipes the tool through `tail` or
   `grep` would hide output from rtk, so it must not do that.

Paste this prompt into your coding agent (Claude Code, etc.) and fill in the three placeholders:

```text
Write an executable POSIX/bash script named ./ctr.sh that runs a build command inside my build container,
so that the rtk filters from https://github.com/FPGArtktic/rtk-embedded-linux keep working.

My setup:
- container runtime(s): <podman | docker | apptainer — list the ones I have; if several, pick the first one
  installed, overridable with CTR_RUNTIME=>
- image(s): <e.g. my-yocto-image:latest for Yocto, my-br-image:latest for Buildroot, or a .sif file>
- source tree and build directory: <e.g. this checkout mounted at /work; Yocto build dir /work/build;
  Buildroot output dir /work/output>

Interface: ./ctr.sh <yocto|br> <command...>   e.g.  ./ctr.sh yocto bitbake core-image-minimal
                                                    ./ctr.sh br make raspberrypi4_64_defconfig

Hard requirements (the rtk filters depend on them):
1. The command words are passed through unchanged with "$@" and the script ends with `exec`, so the exit
   status is the build tool's. Never pipe the tool's output (no | tail, | tee, | grep) inside the script.
2. Allocate a TTY only when stdout is a terminal ([ -t 1 ] -> -t; [ -t 0 ] -> -i). Never pass -t otherwise.
3. Print nothing on stdout yourself; any message goes to stderr.
4. Inside the container the tool must work as typed: for Yocto, `source oe-init-build-env <build dir>` before
   running the command; for Buildroot, run in the output directory (or pass O=).
5. Run as my user: podman `--userns=keep-id`, docker `--user "$(id -u):$(id -g)"`, apptainer `run`
   (with `--no-eval` so arguments are not shell-evaluated). BitBake refuses to run as root.
6. Use the same mount points in every runtime, so build paths in logs are identical.
7. Keep the name ending in .sh, chmod +x it, and tell me to call it as ./ctr.sh (never `bash ctr.sh`).

When done, verify:
  rtk rewrite './ctr.sh yocto bitbake core-image-minimal'   # must print a line starting with: rtk ./ctr.sh
  rtk rewrite './ctr.sh br make'                            # same
  ./ctr.sh yocto bitbake --version                          # bitbake runs inside the container
  RTK_TOML_DEBUG=1 rtk ./ctr.sh yocto bitbake -s 2>&1 | grep rtk:toml   # must say: matched filter 'bitbake-s'
and show me the output.
```

The same prompt works for a script with another name, as long as the name still ends in `.sh`. Change the
name in the prompt and in the commands you give the agent.

## What gets filtered

| Command | Filter | What the agent gets |
|---|---|---|
| `bitbake <target>` (also `-k`, `-f`, `-c <task>`, `virtual/…`, `mc:…`) | `bitbake-build` | every `ERROR`/`WARNING`, the failed task's log (`\| ` lines), its log path and both summaries. Dropped: per-task `NOTE` progress, cache/parse chatter, the Build Configuration block |
| `bitbake -e [<recipe>]` | `bitbake-e` | the first 100 lines without history comments, plus rtk's `tail -n +101 <file>` pointer to the rest |
| `bitbake -s` | `bitbake-s` | the full recipe/version table, with padding trimmed |
| `bitbake -c listtasks <recipe>` | `bitbake-listtasks` | the `do_*` task table and the summary |
| `bitbake -g <target>` | `bitbake-g` | the names of the written `.dot`/buildlist files |
| `bitbake-layers show-layers\|show-recipes\|show-appends` | `bitbake-layers` | the tables, with column padding collapsed |
| `bitbake-getvar [-r <recipe>] VAR` | `bitbake-getvar` | the value and every operation that set it (file:line + value) |
| `make`, `make <defconfig>`, `make <pkg>[-rebuild\|-reconfigure\|…]` | `buildroot-make` | success: `buildroot: OK`. Failure: build steps (`>>>`), errors with source excerpt, `make: ***` lines (last 200 lines) |
| `make printvars`, `show-vars`, `<pkg>-show-info\|-show-version` | `buildroot-printvars` | everything, unchanged |
| `make show-targets`, `list-defconfigs`, `help`, `external-deps` | `buildroot-show-targets` | everything; `list-defconfigs` without the redundant "- Build for *name*" |
| `make <pkg>-show-[recursive-][r]depends`, `graph-depends` | `buildroot-depends` | everything, unchanged |
| `make [<pkg>-]legal-info` | `buildroot-legal-info` | `>>>` steps, `ERROR`/`WARNING` lines, the summary; the per-file `OK (sha256: …)` checks are dropped |

The pass-through filters are needed too. Without them rtk's built-in `make` filter would take those commands,
keep only their first 50 lines and drop every `make[N]:` line.

## Effectiveness (measured)

Every sample in [`samples/`](samples/) is a real capture from building
[`examples/rpi`](https://github.com/FPGArtktic/rpi-yocto-buildroot-ref), replayed through rtk 0.48.0. "Agent
sees" counts every byte rtk printed, including its own hint line. † marks a sample trimmed for the repository;
its raw size is the size of the full capture. This table is generated by `scripts/measure.sh --markdown`, the
same as in [EVALUATION.md](EVALUATION.md):

<!-- BEGIN measure.sh --markdown -->
| Sample | Command (as the agent ran it, minus the wrapper) | Filter | Exit | Raw bytes | Agent sees | Reduction | ~Tokens saved |
|---|---|---|---|---:|---:|---:|---:|
| `buildroot/buildroot-depends-graph.log` | `make graph-depends` | `buildroot-depends` | 0 | 123 | 123 | 0.00% | 0 |
| `buildroot/buildroot-depends.log` | `make busybox-show-depends` | `buildroot-depends` | 0 | 38 | 38 | 0.00% | 0 |
| `buildroot/buildroot-legal-info.log` | `make legal-info` | `buildroot-legal-info` | 0 | 7947 | 2334 | 70.63% | 1403 |
| `buildroot/buildroot-make-defconfig.log` | `make raspberrypi4_64_defconfig` | `buildroot-make` | 0 | 1305 | 83 | 93.63% | 305 |
| `buildroot/buildroot-make-fail-compile.log` | `make rtk-fail-compile` | `buildroot-make` | 2 | 1175 | 798 | 32.08% | 94 |
| `buildroot/buildroot-make-fail-compile-long.log` | `make linux-rebuild rtk-fail-compile` | `buildroot-make` | 2 | 541030 | 1121 | 99.79% | 134977 |
| `buildroot/buildroot-make-ok.log` † | `make` | `buildroot-make` | 0 | 5361811 | 72 | 99.99% | 1340434 |
| `buildroot/buildroot-make-rebuild.log` | `make busybox-rebuild` | `buildroot-make` | 0 | 18462 | 88 | 99.52% | 4593 |
| `buildroot/buildroot-printvars.log` | `make printvars VARS=BUSYBOX_%` | `buildroot-printvars` | 0 | 18586 | 18586 | 0.00% | 0 |
| `buildroot/buildroot-show-targets-list-defconfigs.log` | `make list-defconfigs` | `buildroot-show-targets` | 0 | 20781 | 9008 | 56.65% | 2943 |
| `buildroot/buildroot-show-targets.log` | `make show-targets` | `buildroot-show-targets` | 0 | 493 | 493 | 0.00% | 0 |
| `yocto/bitbake-build-fail-compile.log` | `bitbake rtk-fail-compile` | `bitbake-build` | 1 | 4596 | 1333 | 70.99% | 815 |
| `yocto/bitbake-build-fetch-fail.log` | `bitbake rtk-fetch-fail` | `bitbake-build` | 1 | 3271 | 2180 | 33.35% | 272 |
| `yocto/bitbake-build-ok.log` | `bitbake core-image-minimal` | `bitbake-build` | 0 | 946742 | 496 | 99.94% | 236561 |
| `yocto/bitbake-build-sstate-hit.log` | `bitbake core-image-minimal` | `bitbake-build` | 0 | 383260 | 99 | 99.97% | 95790 |
| `yocto/bitbake-e.log` † | `bitbake -e core-image-minimal` | `bitbake-e` | 0 | 2171070 | 4939 | 99.77% | 541532 |
| `yocto/bitbake-getvar.log` | `bitbake-getvar -r busybox SRC_URI` | `bitbake-getvar` | 0 | 10058 | 6405 | 36.31% | 913 |
| `yocto/bitbake-g.log` | `bitbake -g core-image-minimal` | `bitbake-g` | 0 | 213 | 96 | 54.92% | 29 |
| `yocto/bitbake-layers.log` | `bitbake-layers show-layers` | `bitbake-layers` | 0 | 722 | 322 | 55.40% | 100 |
| `yocto/bitbake-layers-show-appends.log` | `bitbake-layers show-appends` | `bitbake-layers` | 0 | 4010 | 3912 | 2.44% | 24 |
| `yocto/bitbake-layers-show-recipes.log` | `bitbake-layers show-recipes` | `bitbake-layers` | 0 | 47448 | 32455 | 31.59% | 3748 |
| `yocto/bitbake-listtasks.log` | `bitbake -c listtasks busybox` | `bitbake-listtasks` | 0 | 5063 | 4086 | 19.29% | 244 |
| `yocto/bitbake-s.log` | `bitbake -s` | `bitbake-s` | 0 | 210581 | 51091 | 75.73% | 39872 |
| **all samples** | | | | **9758785** | **140158** | **98.56%** | **2404656** |
<!-- END measure.sh --markdown -->

**What rtk counted in real use.** In 21 commands that an agent ran in a Claude Code session, the hook rewrote
each to `rtk …`, and rtk recorded **622 977 → 20 290 tokens (−96.74%)**. The per-command list is in
[EVALUATION.md → Real hook runs](EVALUATION.md#real-hook-runs-as-rtk-counted-them).

How to read these numbers:

- **For full builds the main gain is information, not tokens.** Claude Code already shortens huge tool output.
  In our session a 61.9 KB result became a 2 KB preview plus a file path. Without rtk the agent would read the
  first 2 KB of a build log, which is progress lines, not the error at the end. With these filters it reads the
  error.
- **Mid-size outputs** (failures, `bitbake -s`, `bitbake-getvar`, `legal-info`, listings) save the tokens
  shown.
- **Pass-through rows save 0% by design.** The agent asked for that output.
- **What is lost and how to get it back** is listed in
  [EVALUATION.md → Lossy cases](EVALUATION.md#lossy-cases). Examples: `bitbake -e` variable history, and
  upstream compiler warnings of a *successful* Buildroot build.

## How the filters work, with examples

Each filter in [`.rtk/filters.toml`](.rtk/filters.toml) has two parts. `match_command` is a regex that decides
which commands the filter takes. The output rules (`strip_lines_matching`, `match_output`, …) decide what the
agent gets to see from that command's output.

### 1. Which command goes to which filter

rtk tests `match_command` against the command the agent typed. The hook tests one segment of a compound
command (`a && b` is tested as `a`, then as `b`) with quotes kept. When the command runs, rtk tests the program
name plus its arguments, joined by spaces, with quotes removed. Every `match_command` here is the same prefix
**P** followed by a tool-specific tail. P is what makes one file work on the host, in Podman, in Apptainer and
behind wrappers:

```
^.*?(?: ^ | [;&|'"]\s* | (?:podman|apptainer|singularity)\s+(?:run|exec)\b[^;&|]*[\s'"] | \S+\.sh\b[^;&|]*[\s'"] ) bitbake …
```

| Part of P | Lets the tool appear… | Matched example (the tool is in **bold**) |
|---|---|---|
| `^` | at the start of the segment | **`bitbake`**` core-image-minimal` |
| `[;&\|'"]\s*` | after a shell separator or an opening quote | `podman exec yocto bash -c "cd /work/build && `**`bitbake`**` core-image-minimal"` |
| `(?:podman\|apptainer\|singularity)\s+(?:run\|exec)\b…` | after a container runtime and its options | `apptainer exec --bind $PWD:/work yocto.sif `**`bitbake`**` core-image-minimal` |
| `\S+\.sh\b…` | after any `*.sh` wrapper (the Docker workaround) | `./scripts/ctr.sh yocto `**`make`** |
| leading `^.*?` | anywhere. rtk 0.48 silently ignores a `match_command` that does not start with `^`, and `.*?` keeps the search unanchored | |

Two tricks keep the filters **mutually exclusive**. That matters because rtk sorts filters by name, so their
order in the file cannot settle an overlap.

- **Tool names end in whitespace, not `\b`.** `bitbake\b` would also match `bitbake-layers` and
  `bitbake-getvar`, so every tool name is followed by `\s` or the end of the command.
- **Reserved words are spelled out.** Rust's regex engine has no lookahead, so *"any make target except
  `printvars`"* cannot be written as `(?!printvars)`. Instead, `buildroot-make` accepts a target only if none of
  its hyphen-separated parts is `show`, `graph`, `legal`, `list`, `printvars`, `help` or `deps`. The regex for
  that is generated by `scripts/complement-regex.py`:

  | Command | Target parts | Filter |
  |---|---|---|
  | `make busybox-rebuild` | `busybox` · `rebuild` | `buildroot-make` |
  | `make host-gcc-final-dirclean` | `host` · `gcc` · `final` · `dirclean` | `buildroot-make` |
  | `make busybox-show-depends` | `busybox` · **`show`** · `depends` | `buildroot-depends` |
  | `make list-defconfigs` | **`list`** · `defconfigs` | `buildroot-show-targets` |
  | `make printvars VARS='BUSYBOX_%'` | **`printvars`** | `buildroot-printvars` |

  `bitbake-build` uses the same idea for `-c <task>`: any task except `listtasks`, which belongs to
  `bitbake-listtasks`.

The full routing table below is generated by `scripts/check-routing.py --markdown` from the same cases the test
checks (`scripts/check-routing.py` with no option fails if any command lands in the wrong filter):

<details><summary>Routing table: every tested command form</summary>

<!-- BEGIN check-routing.py --markdown -->
| The agent runs | Filter | `rtk rewrite` turns it into |
|---|---|---|
| `bitbake core-image-minimal` | `bitbake-build` | `rtk bitbake core-image-minimal` |
| `source oe-init-build-env build && bitbake core-image-minimal` | `bitbake-build` | `source oe-init-build-env build && rtk bitbake core-image-minimal` |
| `podman run --rm -v $PWD:/work rpi-ref-yocto:scarthgap bitbake core-image-minimal` | `bitbake-build` | `rtk podman run --rm -v $PWD:/work rpi-ref-yocto:scarthgap bitbake core-image-minimal` |
| `podman exec yocto bash -c "cd /work/build && bitbake core-image-minimal"` | `bitbake-build` | `rtk podman exec yocto bash -c "cd /work/build && bitbake core-image-minimal"` |
| `apptainer exec --bind $PWD:/work yocto.sif bitbake core-image-minimal` | `bitbake-build` | `rtk apptainer exec --bind $PWD:/work yocto.sif bitbake core-image-minimal` |
| `singularity run yocto.sif bitbake core-image-minimal` | `bitbake-build` | `rtk singularity run yocto.sif bitbake core-image-minimal` |
| `./scripts/ctr.sh yocto bitbake core-image-minimal` | `bitbake-build` | `rtk ./scripts/ctr.sh yocto bitbake core-image-minimal` |
| `./dk.sh bitbake core-image-minimal` | `bitbake-build` | `rtk ./dk.sh bitbake core-image-minimal` |
| `CTR_RUNTIME=docker ./scripts/ctr.sh br make` | `buildroot-make` | `CTR_RUNTIME=docker rtk ./scripts/ctr.sh br make` |
| `bitbake -k core-image-minimal rtk-fail-compile` | `bitbake-build` | `rtk bitbake -k core-image-minimal rtk-fail-compile` |
| `bitbake -c compile -f busybox` | `bitbake-build` | `rtk bitbake -c compile -f busybox` |
| `bitbake -c cleansstate busybox && bitbake busybox` | `bitbake-build` | `rtk bitbake -c cleansstate busybox && rtk bitbake busybox` |
| `bitbake virtual/kernel` | `bitbake-build` | `rtk bitbake virtual/kernel` |
| `bitbake core-image-minimal:do_populate_sdk` | `bitbake-build` | `rtk bitbake core-image-minimal:do_populate_sdk` |
| `bitbake -e core-image-minimal` | `bitbake-e` | `rtk bitbake -e core-image-minimal` |
| `bitbake busybox -e` | `bitbake-e` | `rtk bitbake busybox -e` |
| `./scripts/ctr.sh yocto bitbake -e busybox` | `bitbake-e` | `rtk ./scripts/ctr.sh yocto bitbake -e busybox` |
| `bitbake -s` | `bitbake-s` | `rtk bitbake -s` |
| `bitbake --show-versions` | `bitbake-s` | `rtk bitbake --show-versions` |
| `bitbake -c listtasks busybox` | `bitbake-listtasks` | `rtk bitbake -c listtasks busybox` |
| `bitbake -c do_listtasks busybox` | `bitbake-listtasks` | `rtk bitbake -c do_listtasks busybox` |
| `bitbake -g core-image-minimal` | `bitbake-g` | `rtk bitbake -g core-image-minimal` |
| `bitbake-layers show-layers` | `bitbake-layers` | `rtk bitbake-layers show-layers` |
| `bitbake-layers show-recipes` | `bitbake-layers` | `rtk bitbake-layers show-recipes` |
| `bitbake-layers show-appends` | `bitbake-layers` | `rtk bitbake-layers show-appends` |
| `./scripts/ctr.sh yocto bitbake-layers show-layers` | `bitbake-layers` | `rtk ./scripts/ctr.sh yocto bitbake-layers show-layers` |
| `bitbake-getvar -r busybox SRC_URI` | `bitbake-getvar` | `rtk bitbake-getvar -r busybox SRC_URI` |
| `make` | `buildroot-make` | `rtk make` |
| `make raspberrypi4_64_defconfig` | `buildroot-make` | `rtk make raspberrypi4_64_defconfig` |
| `podman run --rm rpi-ref-buildroot:2026.02 make raspberrypi4_64_defconfig` | `buildroot-make` | `rtk podman run --rm rpi-ref-buildroot:2026.02 make raspberrypi4_64_defconfig` |
| `./scripts/ctr.sh br make` | `buildroot-make` | `rtk ./scripts/ctr.sh br make` |
| `cd output && make -j16 V=1` | `buildroot-make` | `cd output && rtk make -j16 V=1` |
| `make -C /src/buildroot O=/work/output raspberrypi4_64_defconfig` | `buildroot-make` | `rtk make -C /src/buildroot O=/work/output raspberrypi4_64_defconfig` |
| `make rtk-fail-compile` | `buildroot-make` | `rtk make rtk-fail-compile` |
| `make busybox-rebuild` | `buildroot-make` | `rtk make busybox-rebuild` |
| `make host-gcc-final-dirclean` | `buildroot-make` | `rtk make host-gcc-final-dirclean` |
| `make printvars VARS='BUSYBOX_%'` | `buildroot-printvars` | `rtk make printvars VARS='BUSYBOX_%'` |
| `./scripts/ctr.sh br make -s printvars VARS='LINUX_VERSION BUSYBOX_VERSION'` | `buildroot-printvars` | `rtk ./scripts/ctr.sh br make -s printvars VARS='LINUX_VERSION BUSYBOX_VERSION'` |
| `make show-targets` | `buildroot-show-targets` | `rtk make show-targets` |
| `make list-defconfigs` | `buildroot-show-targets` | `rtk make list-defconfigs` |
| `make help` | `buildroot-show-targets` | `rtk make help` |
| `make external-deps` | `buildroot-show-targets` | `rtk make external-deps` |
| `make busybox-show-version` | `buildroot-printvars` | `rtk make busybox-show-version` |
| `make busybox-show-info` | `buildroot-printvars` | `rtk make busybox-show-info` |
| `make toolchain-external-bootlin-rebuild` | `buildroot-make` | `rtk make toolchain-external-bootlin-rebuild` |
| `make linux-rebuild rtk-fail-compile` | `buildroot-make` | `rtk make linux-rebuild rtk-fail-compile` |
| `make busybox-show-depends` | `buildroot-depends` | `rtk make busybox-show-depends` |
| `make busybox-show-recursive-rdepends` | `buildroot-depends` | `rtk make busybox-show-recursive-rdepends` |
| `make graph-depends` | `buildroot-depends` | `rtk make graph-depends` |
| `make busybox-graph-depends` | `buildroot-depends` | `rtk make busybox-graph-depends` |
| `make legal-info` | `buildroot-legal-info` | `rtk make legal-info` |
| `./scripts/ctr.sh br make legal-info` | `buildroot-legal-info` | `rtk ./scripts/ctr.sh br make legal-info` |
| `which bitbake` | - | (unchanged) |
| `bitbake --version` | - | (unchanged) |
| `bitbake -e busybox \| grep ^S=` | - | `bitbake -e busybox \| rtk grep ^S=` |
| `grep bitbake log.txt` | - | `rtk grep bitbake log.txt` |
| `cat bitbake.log` | - | `rtk read bitbake.log` |
| `docker run --rm rpi-ref-yocto:scarthgap bitbake core-image-minimal` | - | `rtk docker run --rm rpi-ref-yocto:scarthgap bitbake core-image-minimal` |
| `cmake ..` | - | (unchanged) |
| `makepkg -si` | - | (unchanged) |
| `echo "bitbake done"` | - | (unchanged) |

rtk leaves these commands untouched, so no filter runs, whatever `.rtk/filters.toml` says:

| The agent runs | Why rtk does not filter it |
|---|---|
| `bitbake core-image-minimal 2>&1 \| tail -50` | pipeline: only the last stage is ever rewritten |
| `bitbake core-image-minimal \| tee build.log` | pipeline: only the last stage is ever rewritten |
| `echo "$(date)"; bitbake core-image-minimal` | command substitution anywhere disables the rewrite |
| `echo `date`; bitbake core-image-minimal` | command substitution anywhere disables the rewrite |
| `echo start >/tmp/log; bitbake core-image-minimal` | a file redirect in another segment disables the rewrite |
| `bash -c 'bitbake core-image-minimal'` | bash -c is not rewritten |
| `docker run --rm img bitbake core-image-minimal 2>&1 \| ./scripts/rg-fallback.sh bitbake-build` | pipeline (the ripgrep fallback runs as-is) |
<!-- END check-routing.py --markdown -->

</details>

### 2. What the filters do to the output

Every example below is an excerpt of a real capture in [`samples/`](samples/), replayed through rtk with
`scripts/measure.sh`. The "agent sees" side is rtk's actual output.

**Buildroot, a compile error** (`make rtk-fail-compile`, exit 2). The filter keeps the build steps, the error
with file, line and column, the source excerpt and both `make: ***` lines. It drops only the echoed
`rsync` and compiler command lines:

```text
raw (12 lines, 1 175 bytes)                        agent sees (9 lines + rtk's tee path)
>>> rtk-fail-compile 1.0 Syncing from source dir … >>> rtk-fail-compile 1.0 Syncing from source dir …
rsync -au --chmod=u=rwX,go=rX … /work/output/…    
>>> rtk-fail-compile 1.0 Configuring               >>> rtk-fail-compile 1.0 Configuring
>>> rtk-fail-compile 1.0 Building                  >>> rtk-fail-compile 1.0 Building
/work/output/host/bin/aarch64-linux-gcc -D_LARG…  
…/rtk-fail-compile.c: In function ‘main’:          …/rtk-fail-compile.c: In function ‘main’:
…/rtk-fail-compile.c:7:9: error: ‘count’ undecl…   …/rtk-fail-compile.c:7:9: error: ‘count’ undecl…
    7 |         count += i;                            7 |         count += i;
      |         ^~~~~                                    |         ^~~~~
…/rtk-fail-compile.c:7:9: note: each undeclared…   …/rtk-fail-compile.c:7:9: note: each undeclared…
make[1]: *** [package/pkg-generic.mk:273: …] Err…  make[1]: *** [package/pkg-generic.mk:273: …] Err…
make: *** [Makefile:23: _all] Error 2              make: *** [Makefile:23: _all] Error 2
                                                   [full output: ~/.local/share/rtk/tee/…_make_rtk-fail-compile.log]
```

**Buildroot, a clean full build** (`make`, exit 0, 49 746 lines, 5 361 811 bytes). It contains `>>>` build
steps and no failure marker (`make: ***`, `error:`, `undefined reference`, `WARNING:` at line start), so
`match_output` reports it as a single line. rtk saves the raw log and prints its path:

```text
buildroot: OK
[full output: ~/.local/share/rtk/tee/…_make.log]
```

The path is a convenience, not a guarantee. rtk's tee file keeps only the **first 1 MiB** by default
(`[tee] max_file_size`), so the end of a 5 MB log is not in it.

**Buildroot, `make legal-info`.** The per-file `OK (sha256: …)` checks are dropped. The `>>>` step lines stay,
because an `ERROR:` is useless without the package it belongs to:

```text
raw                                                  agent sees
boot/LICENCE.broadcom: OK (sha256: c7283ff5…)
>>> urandom-scripts  Collecting legal info           >>> urandom-scripts  Collecting legal info
>>> linux custom Collecting legal info               >>> linux custom Collecting legal info
ERROR: No hash found for COPYING                     ERROR: No hash found for COPYING
ERROR: No hash found for LICENSES/preferred/GPL-2.0  ERROR: No hash found for LICENSES/preferred/GPL-2.0
>>> host-bison 3.8.2 Collecting legal info           >>> host-bison 3.8.2 Collecting legal info
COPYING: OK (sha256: 3972dc97…)
```

**Buildroot, `make list-defconfigs`.** All 308 built-in defconfigs are described as "Build for *their own
name*". `replace` removes that suffix and nothing else. A defconfig with any other description keeps it:

```text
raw                                                                   agent sees
Built-in configs:                                                     Built-in configs:
  aarch64_efi_defconfig               - Build for aarch64_efi           aarch64_efi_defconfig
  acmesystems_acqua_a5_256mb_defconfig - Build for acmesystems_acqua…   acmesystems_acqua_a5_256mb_defconfig
```

**`make printvars`, `make show-targets`, `make <pkg>-show-depends`, `make graph-depends`** pass through
unchanged. These filters exist only so that rtk's built-in `make` filter cannot take the command. That filter
drops `make[N]:` lines and keeps only the first 50 lines, which would cut `list-defconfigs` (310 lines) and
long `printvars` output.

**Yocto, a clean full build** (`bitbake core-image-minimal`, exit 0, 11 186 lines, 946 742 bytes). The
agent sees four lines:

```text
WARNING: squashfs-tools-native-4.6.1-r0 do_fetch: Failed to fetch URL git://github.com/plougher/squashfs-tools.git;protocol=https;branch=v6.1.1, attempting MIRRORS if available
WARNING: init-system-helpers-1.66-r0 do_fetch: Failed to fetch URL git://salsa.debian.org/debian/init-system-helpers.git;protocol=https;branch=master, attempting MIRRORS if available
NOTE: Tasks Summary: Attempted 3729 tasks of which 0 didn't need to be rerun and all succeeded.
Summary: There were 2 WARNING messages.
```

The 11 182 lines that are gone look like this: `NOTE: Running task 1426 of 3729 (…libcap_2.69.bb:do_configure)`,
`NOTE: recipe libcap-native-2.69-r0: task do_configure: Started` / `Succeeded`, `Loading cache...done.`, and
the `Build Configuration:` block.

**Yocto, a compile error** (`bitbake rtk-fail-compile`, exit 1). Everything that locates the failure stays:

```text
ERROR: rtk-fail-compile-1.0-r0 do_compile: ExecutionError('/work/build/tmp/work/cortexa72-poky-linux/rtk-fail-compile/1.0/temp/run.do_compile.288', 1, None, None)
ERROR: Logfile of failure stored in: /work/build/tmp/work/cortexa72-poky-linux/rtk-fail-compile/1.0/temp/log.do_compile.288
Log data follows:
| DEBUG: Executing shell function do_compile
| rtk-fail-compile.c: In function 'main':
| rtk-fail-compile.c:7:9: error: 'count' undeclared (first use in this function)
|     7 |         count += i;
|       |         ^~~~~
| rtk-fail-compile.c:7:9: note: each undeclared identifier is reported only once for each function it appears in
| WARNING: exit code 1 from a shell command.
NOTE: recipe rtk-fail-compile-1.0-r0: task do_compile: Failed
ERROR: Task (/ref/yocto/poky/../meta-rpi-ref/recipes-test/rtk-fail-compile/rtk-fail-compile.bb:do_compile) failed with exit code '1'
NOTE: Tasks Summary: Attempted 834 tasks of which 824 didn't need to be rerun and 1 failed.
Summary: 1 task failed:
  /ref/yocto/poky/../meta-rpi-ref/recipes-test/rtk-fail-compile/rtk-fail-compile.bb:do_compile
    log: /work/build/tmp/work/cortexa72-poky-linux/rtk-fail-compile/1.0/temp/log.do_compile.288
Summary: There was 1 ERROR message, returning a non-zero exit code.
[full output: ~/.local/share/rtk/tee/…_bitbake_rtk-fail-compile.log]
```

The line `NOTE: … task do_compile: Failed` survives because the filter only removes NOTE lines it knows to be
noise: `Started`/`Succeeded`, never `Failed`.

**Yocto, `bitbake -e`** (2 171 070 bytes, 53% of them history comments). The agent gets the first 100
`VAR="value"` lines and a pointer to the rest:

```text
7ZIP_COMPRESSION_LEVEL="9"
7ZIP_COMPRESSION_METHOD="BZip2"
…
ARMPKGARCH:tune-armv7athf-neon="armv7a"
... (13504 lines truncated)
[see remaining: tail -n +101 ~/.local/share/rtk/tee/…_bitbake__351d57.log]
```

The file holds the whole comment-free environment (1 018 416 bytes), so `grep '^MACHINE=' <file>` answers
without running `bitbake -e` again. `bitbake -e X | grep ^VAR=` is a pipeline, so rtk never touches it.

**Yocto, `bitbake-getvar -r busybox SRC_URI`.** The documentation string, the varflag operations and the
unexpanded copy of the value are dropped. Every operation that set the variable stays, with its file:line and
value. That is usually why one runs `bitbake-getvar`. Values are cut at 100 characters here, not by the filter:

```text
# $SRC_URI [7 operations]
#   append /ref/yocto/poky/meta/conf/bitbake.conf:734
#   set /ref/yocto/poky/meta/conf/bitbake.conf:745
#     ""
#   set /ref/yocto/poky/meta/conf/documentation.conf:394
#   set /ref/yocto/poky/meta/recipes-core/busybox/busybox_1.36.1.bb:70
#     "https://busybox.net/downloads/busybox-${PV}.tar.bz2;name=tarball            file://0001-depmod-Ig…
#   :append[libc-musl] /ref/yocto/poky/meta/recipes-core/busybox/busybox_1.36.1.bb:71
#     " file://musl.cfg "
…
SRC_URI="https://busybox.net/downloads/busybox-1.36.1.tar.bz2;name=tarball            file://0001-depmod…
```

**Yocto, `bitbake -s`.** Trailing padding and the gap after the recipe name go. The remaining columns keep
their alignment, so an empty "Preferred Version" is still recognisable:

```text
raw                                                                         agent sees
acl                                                 :2.3.2-r0          ↦    acl :2.3.2-r0
acl-native                                          :2.3.2-r0          ↦    acl-native :2.3.2-r0
```

## Docker: why `docker run … bitbake` is not filtered, and what to do instead

**Short version.** When an agent runs `docker run … bitbake …`, `docker exec … make …` or `docker compose run …`,
rtk passes the full, unfiltered output through. That is how rtk itself works. It is not a defect in these
filters, and no TOML file can change it. rtk handles `docker` with its own built-in code, and that code never
reads TOML filters. **Workaround:** start the container through a `*.sh` wrapper, for example
`CTR_RUNTIME=docker ./scripts/ctr.sh yocto bitbake core-image-minimal`. Docker still runs the build, and the
filters apply.

Everything below was checked against **rtk 0.48.0**. Links point to the rtk source at tag `v0.48.0`.

### What happens, step by step

1. **The hook rewrites the command, but to rtk's own Docker module.** Claude Code's hook asks `rtk rewrite` how
   to run each command. rtk supports `docker` natively, so `docker run … bitbake X` becomes
   `rtk docker run … bitbake X`. Custom TOML filters are consulted only for commands that rtk does *not* support
   natively ([`src/discover/registry.rs` L1435–L1452](https://github.com/rtk-ai/rtk/blob/v0.48.0/src/discover/registry.rs#L1435-L1452)).
2. **`rtk docker run` is a passthrough.** rtk parses `docker` as one of its own subcommands. `ps`, `images`,
   `logs` and parts of `compose` get dedicated compact output. Every other subcommand, including `run` and
   `exec`, lands in `DockerCommands::Other` and goes to `run_docker_passthrough`, which prints the output
   unchanged ([`src/main.rs` L2109](https://github.com/rtk-ai/rtk/blob/v0.48.0/src/main.rs#L2109); for
   `docker compose …` see [L2105](https://github.com/rtk-ai/rtk/blob/v0.48.0/src/main.rs#L2105)).
3. **TOML filters are never reached.** Filters from `.rtk/filters.toml` are applied in `run_fallback`, which runs
   only when rtk's argument parser does *not* recognise the command
   ([`src/main.rs` L1459](https://github.com/rtk-ai/rtk/blob/v0.48.0/src/main.rs#L1459)). rtk always recognises
   `docker`. rtk states this in its own source, where `docker` is listed in `RUST_HANDLED_COMMANDS`: *"A TOML
   filter whose match_command matches one of these will never activate"*
   ([`src/core/toml_filter.rs` L256–L310](https://github.com/rtk-ai/rtk/blob/v0.48.0/src/core/toml_filter.rs#L256-L310)).
   Upstream issue: [rtk-ai/rtk#821](https://github.com/rtk-ai/rtk/issues/821), *"Allow user TOML filters to
   customize built-in command output"*.

Podman, Apptainer and Singularity are filtered because rtk has no built-in module for them, so they reach
`run_fallback`, and the filters here match the build tool after `podman|apptainer|singularity run|exec …`.

### Who is affected

| The agent runs | Filtered? |
|---|---|
| `docker run … bitbake X`, `docker exec … make`, `docker compose run …` | **no**: full raw output |
| the same on a host where `docker` is Podman's `podman-docker` alias | **no**: rtk decides by the word `docker` |
| `podman run\|exec … bitbake X` | yes |
| `apptainer\|singularity run\|exec … bitbake X` | yes |
| `./scripts/ctr.sh yocto bitbake X`, with any `CTR_RUNTIME`, Docker included | yes |
| any `./name.sh … bitbake X` (the script name does not matter) | yes |
| an agent running *inside* the build container: `bitbake X` | yes, if rtk and these filters are installed there |

All of the above apply to `make` (Buildroot) exactly as to `bitbake`.

### Check it yourself

```bash
rtk rewrite 'docker run --rm IMAGE bitbake core-image-minimal'
# rtk docker run --rm IMAGE bitbake core-image-minimal        <- rtk's docker module: passthrough
rtk rewrite 'podman run --rm IMAGE bitbake core-image-minimal'
# rtk podman run --rm IMAGE bitbake core-image-minimal        <- goes to the TOML filters

I=docker.io/fpgartktic/rpi-ref-yocto:scarthgap
RTK_TOML_DEBUG=1 rtk docker run --rm --entrypoint true $I bitbake core-image-minimal 2>&1 | grep rtk:toml
# (no output: the TOML engine is never asked)
RTK_TOML_DEBUG=1 rtk podman run --rm --entrypoint true $I bitbake core-image-minimal 2>&1 | grep rtk:toml
# [rtk:toml] matched filter: 'bitbake-build'
```

### Workarounds, best first

**1. Run Docker through a `*.sh` wrapper. Recommended and tested.**

```bash
CTR_RUNTIME=docker ./scripts/ctr.sh yocto bitbake core-image-minimal
CTR_RUNTIME=docker ./scripts/ctr.sh br make
```

Docker still runs the container, as `--user $(id -u):$(id -g)` with the same mounts as every other runtime.
rtk does not know the command `ctr.sh`, so it sends it to the TOML filters, and they match the build tool after
any `*.sh`. Your own wrapper works the same way, because the filters do not care about the script's name:

```bash
#!/bin/sh
# dk.sh - run a command in a Docker build container
exec docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" -w /work my-yocto-image "$@"
```

`./dk.sh bitbake core-image-minimal` is then filtered. `scripts/check-routing.py` checks this case, along with
`ctr.sh` and every other form in the table above. To make the agent use the wrapper, write it into the
project's agent instructions (`CLAUDE.md`, `AGENTS.md`), e.g. *"never run `docker run … bitbake`; use
`./scripts/ctr.sh yocto bitbake …`"*. Tested with `RTK_TOML_DEBUG=1` and Docker 29.9.0:
`run.sh yocto bitbake -n busybox` → `matched filter: 'bitbake-build'`.

**2. Run the agent inside the build container.** If Claude Code, rtk and these filters (`rtk trust`) are
installed in the image, the agent types plain `bitbake X` and no `docker` word ever reaches rtk. The images built
by `examples/rpi` do not contain rtk, so this path is not tested here.

**3. `transparent_prefixes`. Advanced and limited.** rtk can strip a literal wrapper prefix and rewrite only
the command behind it. In `~/.config/rtk/config.toml`:

```toml
[hooks]
transparent_prefixes = ["docker exec yocto"]
```

With that, `docker exec yocto bitbake X` becomes `docker exec yocto rtk bitbake X`. The rewrite was verified
here with rtk 0.48.0. Three limits apply:

- rtk then runs **inside** the container, so the container needs rtk and the trusted filters (see 2).
- The prefix is matched literally. `docker run --rm -v …:/work IMAGE bitbake X` with any flag not written in the
  prefix falls back to `rtk docker …` and is unfiltered.
- `docker exec yocto bash -c "bitbake X"` is not rewritten at all.

**4. ripgrep fallback. Last resort.**

```bash
docker run --rm … bitbake core-image-minimal 2>&1 | ./scripts/rg-fallback.sh bitbake-build
```

`scripts/rg-fallback.sh` reads `strip_ansi`, `strip_lines_matching` and `keep_lines_matching` of the named
filter from `.rtk/filters.toml` and applies them with ripgrep. ripgrep uses the same regex engine as rtk.
The script finds ripgrep as `rg` or as `ripgrep` on `PATH`; set `RG=/path/to/binary` if you only have a shell
alias. Compared to rtk, it does **not** apply `replace`, `match_output`, `max_lines`/`tail_lines` or
`on_empty`. It writes no `rtk gain` statistics and no tee file for recovery. It also works only when the agent
remembers to pipe. rtk leaves this whole pipeline alone: `rtk rewrite` returns nothing for it, so the agent sees
exactly what the script prints.

### What this project deliberately does not do

- **No TOML filter for `docker …`.** By rtk's design it would never activate (see step 3).
- **No `alias docker=…` trick.** The agent's command string still starts with `docker`, and that word alone
  decides rtk's routing (step 1).

## Development

The filters are developed against real captures. The ground truth is in `samples/`, and no build is needed to
change a regex:

```bash
git clone --recursive https://github.com/FPGArtktic/rtk-embedded-linux.git && cd rtk-embedded-linux
rtk trust                                  # after every edit of .rtk/filters.toml
rtk verify --filter buildroot-make         # inline tests ([[tests.*]] in the same file)
scripts/check-routing.py                   # every command form -> exactly one filter, + rtk rewrite
scripts/measure.sh                         # replay all samples through rtk, bytes before/after
scripts/update-docs.py                     # regenerate the tables in README.md and EVALUATION.md

# replay one sample through the real command string (the shim prints the sample instead of building)
PATH="$PWD/scripts/shim:$PATH" RTK_SAMPLE=samples/yocto/bitbake-build-fail-compile.log RTK_SAMPLE_EXIT=1 \
  rtk bitbake rtk-fail-compile
```

To capture a new sample, run the real command in the reference design (`examples/rpi`, a submodule) with
`scripts/capture.sh <yocto|buildroot> <row-id>[-<scenario>] ./scripts/ctr.sh <yocto|br> <command…>`.
`scripts/ctr.sh` runs it in the build container under Podman, Apptainer or Docker (`CTR_RUNTIME=`). The image is
pulled from Docker Hub or built from `examples/rpi/containers/`. A first full Yocto build takes hours, and a
Buildroot build about an hour.

`rtk` has no lookahead in its regex engine, so "any target except …" is generated with
`scripts/complement-regex.py`. The comments in `.rtk/filters.toml` say where.

## License

GPL-3.0-only, see [LICENSE](LICENSE). The reference design in `examples/rpi` is a separate repository with its
own license, and its submodules (Poky, meta-raspberrypi, Buildroot) are under theirs.
