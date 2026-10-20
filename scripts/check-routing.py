#!/usr/bin/env python3
"""CLAUDE.md §3 acceptance: every command routes to exactly the expected filter.

For each case three things are checked:
  1. `rtk rewrite` rewrites it (or, for negative cases, does not rewrite it into one of ours);
  2. hook form  - the filters whose match_command matches the command segment rtk tests (quotes kept);
  3. exec form  - the filters matching what `rtk <cmd>` looks up: basename(argv[0]) + argv joined by spaces.
Both 2 and 3 must be exactly {expected}. Regexes are run with ripgrep, i.e. the same Rust regex
engine rtk uses.

  scripts/check-routing.py [--markdown] [path/to/filters.toml]

--markdown prints the routing table for README.md instead (and fails if any case fails).
"""
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MARKDOWN = "--markdown" in sys.argv[1:]
_paths = [a for a in sys.argv[1:] if a != "--markdown"]
TOML = pathlib.Path(_paths[0]) if _paths else ROOT / ".rtk" / "filters.toml"
# ripgrep ships as `rg`, some systems name it `ripgrep`; RG= overrides (aliases are invisible here).
RG = os.environ.get("RG") or shutil.which("rg") or shutil.which("ripgrep")

# (command, expected filter or None, how `rtk rewrite` must behave: "ours" | "none" | "builtin")
CASES = [
    ("bitbake core-image-minimal", "bitbake-build", "ours"),
    ("source oe-init-build-env build && bitbake core-image-minimal", "bitbake-build", "ours"),
    ("podman run --rm -v $PWD:/work rpi-ref-yocto:scarthgap bitbake core-image-minimal", "bitbake-build", "ours"),
    ('podman exec yocto bash -c "cd /work/build && bitbake core-image-minimal"', "bitbake-build", "ours"),
    ("apptainer exec --bind $PWD:/work yocto.sif bitbake core-image-minimal", "bitbake-build", "ours"),
    ("singularity run yocto.sif bitbake core-image-minimal", "bitbake-build", "ours"),
    ("./scripts/ctr.sh yocto bitbake core-image-minimal", "bitbake-build", "ours"),
    ("./dk.sh bitbake core-image-minimal", "bitbake-build", "ours"),               # any *.sh name
    ("CTR_RUNTIME=docker ./scripts/ctr.sh br make", "buildroot-make", "ours"),
    ("bitbake -k core-image-minimal rtk-fail-compile", "bitbake-build", "ours"),
    ("bitbake -c compile -f busybox", "bitbake-build", "ours"),
    ("bitbake -c cleansstate busybox && bitbake busybox", "bitbake-build", "ours"),
    ("bitbake virtual/kernel", "bitbake-build", "ours"),
    ("bitbake core-image-minimal:do_populate_sdk", "bitbake-build", "ours"),
    ("bitbake -e core-image-minimal", "bitbake-e", "ours"),
    ("bitbake busybox -e", "bitbake-e", "ours"),
    ("./scripts/ctr.sh yocto bitbake -e busybox", "bitbake-e", "ours"),
    ("bitbake -s", "bitbake-s", "ours"),
    ("bitbake --show-versions", "bitbake-s", "ours"),
    ("bitbake -c listtasks busybox", "bitbake-listtasks", "ours"),
    ("bitbake -c do_listtasks busybox", "bitbake-listtasks", "ours"),
    ("bitbake -g core-image-minimal", "bitbake-g", "ours"),
    ("bitbake-layers show-layers", "bitbake-layers", "ours"),
    ("bitbake-layers show-recipes", "bitbake-layers", "ours"),
    ("bitbake-layers show-appends", "bitbake-layers", "ours"),
    ("./scripts/ctr.sh yocto bitbake-layers show-layers", "bitbake-layers", "ours"),
    ("bitbake-getvar -r busybox SRC_URI", "bitbake-getvar", "ours"),
    ("make", "buildroot-make", "ours"),
    ("make raspberrypi4_64_defconfig", "buildroot-make", "ours"),
    ("podman run --rm rpi-ref-buildroot:2026.02 make raspberrypi4_64_defconfig", "buildroot-make", "ours"),
    ("./scripts/ctr.sh br make", "buildroot-make", "ours"),
    ("cd output && make -j16 V=1", "buildroot-make", "ours"),
    ("make -C /src/buildroot O=/work/output raspberrypi4_64_defconfig", "buildroot-make", "ours"),
    ("make rtk-fail-compile", "buildroot-make", "ours"),
    ("make busybox-rebuild", "buildroot-make", "ours"),
    ("make host-gcc-final-dirclean", "buildroot-make", "ours"),
    ("make printvars VARS='BUSYBOX_%'", "buildroot-printvars", "ours"),
    ("./scripts/ctr.sh br make -s printvars VARS='LINUX_VERSION BUSYBOX_VERSION'", "buildroot-printvars", "ours"),
    ("make show-targets", "buildroot-show-targets", "ours"),
    ("make list-defconfigs", "buildroot-show-targets", "ours"),
    ("make help", "buildroot-show-targets", "ours"),
    ("make external-deps", "buildroot-show-targets", "ours"),
    ("make busybox-show-version", "buildroot-printvars", "ours"),
    ("make busybox-show-info", "buildroot-printvars", "ours"),
    ("make toolchain-external-bootlin-rebuild", "buildroot-make", "ours"),
    ("make linux-rebuild rtk-fail-compile", "buildroot-make", "ours"),
    ("make busybox-show-depends", "buildroot-depends", "ours"),
    ("make busybox-show-recursive-rdepends", "buildroot-depends", "ours"),
    ("make graph-depends", "buildroot-depends", "ours"),
    ("make busybox-graph-depends", "buildroot-depends", "ours"),
    ("make legal-info", "buildroot-legal-info", "ours"),
    ("./scripts/ctr.sh br make legal-info", "buildroot-legal-info", "ours"),
    # negative: never ours
    ("which bitbake", None, "none"),
    ("bitbake --version", None, "none"),
    ("bitbake -e busybox | grep ^S=", None, "builtin"),  # only the last stage is rewritten (rtk grep)
    ("grep bitbake log.txt", None, "builtin"),
    ("cat bitbake.log", None, "builtin"),
    ("docker run --rm rpi-ref-yocto:scarthgap bitbake core-image-minimal", None, "builtin"),
    ("cmake ..", None, "none"),
    ("makepkg -si", None, "none"),
]
# rtk itself leaves these alone (rtk 0.48.0), whatever the filters say: `rtk rewrite` must print
# nothing. Listed so a change in rtk shows up here and the README table stays true.
NOT_REWRITTEN = [
    ("bitbake core-image-minimal 2>&1 | tail -50", "pipeline: only the last stage is ever rewritten"),
    ("bitbake core-image-minimal | tee build.log", "pipeline: only the last stage is ever rewritten"),
    ('echo "$(date)"; bitbake core-image-minimal', "command substitution anywhere disables the rewrite"),
    ("echo `date`; bitbake core-image-minimal", "command substitution anywhere disables the rewrite"),
    ("echo start >/tmp/log; bitbake core-image-minimal", "a file redirect in another segment disables the rewrite"),
    ("bash -c 'bitbake core-image-minimal'", "bash -c is not rewritten"),
    ("docker run --rm img bitbake core-image-minimal 2>&1 | ./scripts/rg-fallback.sh bitbake-build",
     "pipeline (the ripgrep fallback runs as-is)"),
]

# Hook-form regex hit, but rtk classifies `echo` as ignored and never rewrites it (rtk 0.48).
KNOWN_HOOK_ONLY = {('echo "bitbake done"', "bitbake-build")}
CASES.append(('echo "bitbake done"', None, "none"))


def segments(cmd):
    """Split on unquoted && || ; | & the way rtk's lexer does; return (segment, is_last_pipeline_stage)."""
    out, cur, quote, i = [], "", None, 0
    while i < len(cmd):
        c = cmd[i]
        if quote:
            cur += c
            if c == quote:
                quote = None
        elif c in "'\"":
            quote, cur = c, cur + c
        elif cmd.startswith(("&&", "||"), i):
            out.append((cur.strip(), "op")); cur = ""; i += 1
        elif c == "&" and (cur.endswith(">") or cmd.startswith(">", i + 1)):
            cur += c                       # 2>&1, &>file: a redirect, not a separator
        elif c in ";&":
            out.append((cur.strip(), "op")); cur = ""
        elif c == "|":
            out.append((cur.strip(), "pipe")); cur = ""
        else:
            cur += c
        i += 1
    out.append((cur.strip(), "end"))
    # A segment followed by a pipe is a pipeline producer: rtk never rewrites it.
    return [s for s, nxt in out if s and nxt != "pipe"]


def exec_form(seg):
    argv = shlex.split(seg)
    return " ".join([os.path.basename(argv[0])] + argv[1:])


def matching(filters, strings):
    """{index: set(filter names)} using rg, one call per filter."""
    hits = {i: set() for i in range(len(strings))}
    data = "".join(s.replace("\n", " ") + "\n" for s in strings).encode()
    for name, flt in filters.items():
        r = subprocess.run([RG, "--no-config", "-n", "-e", flt["match_command"]],
                           input=data, capture_output=True)
        if r.returncode == 2:
            sys.exit(f"rg rejected match_command of {name}: {r.stderr.decode()}")
        for line in r.stdout.decode().splitlines():
            hits[int(line.split(":", 1)[0]) - 1].add(name)
    return hits


def main():
    if not RG:
        sys.exit("check-routing.py: ripgrep not found (looked for rg and ripgrep; set RG=)")
    filters = tomllib.loads(TOML.read_text())["filters"]
    hook, exe, owner = [], [], []
    for ci, (cmd, _, _) in enumerate(CASES):
        for seg in segments(cmd):
            hook.append(seg); exe.append(exec_form(seg)); owner.append(ci)
    hook_hits, exe_hits = matching(filters, hook), matching(filters, exe)

    failed, rows = 0, []
    out = sys.stderr if MARKDOWN else sys.stdout
    for ci, (cmd, expected, mode) in enumerate(CASES):
        idx = [k for k, o in enumerate(owner) if o == ci]
        h = set().union(*(hook_hits[k] for k in idx)) if idx else set()
        e = set().union(*(exe_hits[k] for k in idx)) if idx else set()
        rw = subprocess.run(["rtk", "rewrite", cmd], capture_output=True, text=True).stdout.strip()
        want = {expected} if expected else set()
        problems = []
        known = {f for (c, f) in KNOWN_HOOK_ONLY if c == cmd}
        if h - known != want:
            problems.append(f"hook form matches {sorted(h) or '-'}")
        if e != want:
            problems.append(f"exec form matches {sorted(e) or '-'}")
        if mode == "ours" and "rtk " not in rw:
            problems.append("rtk rewrite: no rewrite")
        if mode == "none" and rw:
            problems.append(f"rtk rewrite: unexpected '{rw}'")
        if mode == "builtin" and not rw:
            problems.append("rtk rewrite: expected a built-in rewrite")
        status = "FAIL" if problems else "ok"
        failed += bool(problems)
        rows.append((cmd, expected, rw))
        if MARKDOWN and not problems:
            continue
        print(f"{status:4} {expected or '(none)':24} {cmd}", file=out)
        if known and h & known:
            print(f"     note: hook form also matches {sorted(h & known)} (known harmless, exec form clean)", file=out)
        for p in problems:
            print(f"     {p}", file=out)
        if rw and (problems or mode != "ours"):
            print(f"     rewrite: {rw}", file=out)
    for cmd, why in NOT_REWRITTEN:
        rw = subprocess.run(["rtk", "rewrite", cmd], capture_output=True, text=True).stdout.strip()
        if rw:
            failed += 1
            print(f"FAIL (not rewritten)          {cmd}\n     rtk now rewrites it: {rw}", file=out)
        elif not MARKDOWN:
            print(f"ok   (not rewritten)          {cmd}", file=out)
    total = len(CASES) + len(NOT_REWRITTEN)
    print(f"\n{total - failed}/{total} cases ok", file=out)
    if MARKDOWN and not failed:
        def cell(t):
            return "`" + t.replace("|", "\\|") + "`" if t else "-"
        print("| The agent runs | Filter | `rtk rewrite` turns it into |")
        print("|---|---|---|")
        for cmd, expected, rw in rows:
            print(f"| {cell(cmd)} | {cell(expected or '')} | {cell(rw) if rw else '(unchanged)'} |")
        print()
        print("rtk leaves these commands untouched, so no filter runs, whatever `.rtk/filters.toml` says:")
        print()
        print("| The agent runs | Why rtk does not filter it |")
        print("|---|---|")
        for cmd, why in NOT_REWRITTEN:
            print(f"| {cell(cmd)} | {why} |")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
