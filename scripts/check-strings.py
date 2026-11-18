#!/usr/bin/env python3
"""Checks that every L("...") key in the sources exists in every Resources/*.lproj/Localizable.strings,
and reports keys that are no longer used. Run from the project root: python3 scripts/check-strings.py"""
import pathlib, re, sys

INT_VARS = {"d", "model.remaining", "minutes"}  # interpolations formatted as integers (%lld)

def source_keys():
    keys = set()
    for f in pathlib.Path("Sources").rglob("*.swift"):
        for m in re.finditer(r'L\("((?:[^"\\]|\\.)*)"\)', f.read_text()):
            keys.add(re.sub(r'\\\(([^()]*(?:\([^()]*\))?[^()]*)\)',
                            lambda e: "%lld" if e.group(1) in INT_VARS else "%@", m.group(1)))
    return keys

def table_keys(path):
    text = path.read_text(encoding="utf-8")
    return {m.group(1).replace('\\"', '"').replace("\\\\", "\\")
            for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M)}

used = source_keys()
ok = True
for table in sorted(pathlib.Path("Resources").glob("*.lproj/Localizable.strings")):
    have = table_keys(table)
    missing, unused = used - have, have - used
    for k in sorted(missing): print(f"{table.parent.name}: missing {k!r}"); ok = False
    for k in sorted(unused): print(f"{table.parent.name}: unused {k!r}")
print(f"{len(used)} keys checked" if ok else "Missing translations found")
sys.exit(0 if ok else 1)
