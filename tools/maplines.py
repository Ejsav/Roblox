#!/usr/bin/env python3
"""Translates bundle.luau line references in test output back to real source files."""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP = os.path.join(ROOT, "tests", ".out", "linemap.txt")

entries = []
if os.path.exists(MAP):
    with open(MAP) as handle:
        for line in handle:
            bundle_line, path, source_line = line.rstrip("\n").split("\t")
            entries.append((int(bundle_line), path, int(source_line)))
entries.sort()

pattern = re.compile(r"bundle\.luau:(\d+)")


def translate(match):
    target = int(match.group(1))
    best = None
    for bundle_line, path, source_line in entries:
        if bundle_line <= target:
            best = (bundle_line, path, source_line)
        else:
            break
    if not best:
        return match.group(0)
    bundle_line, path, source_line = best
    return "%s:%d" % (path, source_line + (target - bundle_line))


for line in sys.stdin:
    sys.stdout.write(pattern.sub(translate, line))
