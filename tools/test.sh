#!/usr/bin/env bash
# Bundles source + harness + specs into one Luau chunk and runs the suite.
# Bundle line numbers in any output are translated back to real source locations.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 tools/bundle.py || exit 1
set -o pipefail
luau tests/.out/bundle.luau "$@" 2>&1 | python3 tools/maplines.py
exit "${PIPESTATUS[0]}"
