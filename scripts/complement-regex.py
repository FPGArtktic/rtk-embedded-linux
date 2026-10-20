#!/usr/bin/env python3
"""Print a Rust-regex fragment matching one word over CLASS that is NOT one of WORDS.

rtk compiles match_command with the Rust `regex` crate, which has no lookahead, so "any target
except printvars" has to be spelled out as the complement of a trie. This prints that fragment;
paste it into .rtk/filters.toml where a comment says it was generated here.

  scripts/complement-regex.py [--class 'A-Za-z0-9_.+'] WORD...

Examples (the two used in .rtk/filters.toml):
  scripts/complement-regex.py show graph legal list printvars        # buildroot-make segment
  scripts/complement-regex.py --class 'A-Za-z0-9_' listtasks do_listtasks   # bitbake-build -c task
"""
import argparse


def build(words, cls, depth=0):
    alts = []
    firsts = sorted({w[0] for w in words if w})
    excl = "".join(firsts)
    # a first character that leaves the trie: anything may follow
    alts.append(f"[{cls}--[{excl}]][{cls}]*" if excl else f"[{cls}]+")
    for ch in firsts:
        rest = [w[1:] for w in words if w and w[0] == ch]
        alts.append(ch + "(?:" + build(rest, cls, depth + 1) + ")")
    if "" not in words and depth > 0:
        alts.append("")  # a proper prefix of a reserved word is an ordinary word
    return "|".join(alts)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--class", dest="cls", default="A-Za-z0-9_.+",
                    help="characters a word may contain (regex class body, no brackets)")
    ap.add_argument("words", nargs="+")
    a = ap.parse_args()
    print("(?:" + build(a.words, a.cls) + ")")


if __name__ == "__main__":
    main()
