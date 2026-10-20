#!/usr/bin/env python3
"""Regenerate the generated tables in README.md and EVALUATION.md.

A generated block looks like this, and everything between the two markers is replaced by the
output of the named script:

    <!-- BEGIN check-routing.py --markdown -->
    ...
    <!-- END check-routing.py --markdown -->

Only the scripts in ALLOWED can be named. A script that fails leaves the file untouched.

  scripts/update-docs.py [FILE...]      (default: README.md EVALUATION.md)
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWED = {"check-routing.py", "measure.sh"}
BLOCK = re.compile(r"(<!-- BEGIN (\S+)((?: [^>]*?)?) -->\n)(.*?)(<!-- END \2\3 -->)", re.S)


def render(match):
    script, args = match.group(2), match.group(3).split()
    if script not in ALLOWED:
        sys.exit(f"update-docs.py: {script} is not an allowed generator")
    r = subprocess.run([str(ROOT / "scripts" / script), *args], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"update-docs.py: {script} {' '.join(args)} failed:\n{r.stderr}")
    return match.group(1) + r.stdout + match.group(5)


def main():
    files = sys.argv[1:] or ["README.md", "EVALUATION.md"]
    for name in files:
        path = ROOT / name
        if not path.exists():
            continue
        text = path.read_text()
        new = BLOCK.sub(render, text)
        if new != text:
            path.write_text(new)
            print(f"updated {name}")


if __name__ == "__main__":
    main()
