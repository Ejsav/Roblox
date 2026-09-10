#!/usr/bin/env bash
# Bundles source + harness + specs into one Luau chunk and runs the suite, then
# runs the static wiring checks the suite cannot make.
#
# Wiring runs after the specs rather than before: a failing spec is the more
# useful signal, and seeing it first is worth more than failing fast on a lint.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 tools/bundle.py || exit 1

set -o pipefail
luau tests/.out/bundle.luau "$@" 2>&1 | python3 tools/maplines.py
suite_status="${PIPESTATUS[0]}"

python3 tools/checkwiring.py
wiring_status=$?

if [ "$suite_status" -ne 0 ]; then
	exit "$suite_status"
fi
exit "$wiring_status"
