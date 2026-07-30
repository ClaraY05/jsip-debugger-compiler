#!/bin/sh
# Golden-dump tests for -visual-replay.
#
#   testing/run_tests.sh              run every case
#   testing/run_tests.sh map_basic    run selected cases
#   testing/run_tests.sh --promote    rewrite expected/ from current output
#
# Each testing/cases/<name>.ml is compiled with -visual-replay (from the
# repo root, so the loc strings in the dump are stable relative paths),
# run, and its dump is (a) validated by check_dump -- every line parses,
# every snapshot round-trips, depth returns to 0 -- and (b) compared
# against testing/expected/<name>.dump.
#
# expected/ holds the VERBATIM dump of a real run -- byte-for-byte what
# the interface's reader will be fed; nothing in it is rewritten.  Since
# raw heap addresses differ run to run, the comparison (not the files)
# canonicalizes both sides the same way -- each distinct address becomes
# 0xA<n> in order of first appearance -- which makes the diff exactly
# "equal up to a consistent address bijection".

set -u
cd "$(dirname "$0")/.." || exit 2

if [ ! -f ocamlc ] || [ ! -x runtime/ocamlrun ]; then
    echo "error: build the tree first (make world)" >&2
    exit 2
fi

# config-independent invocation: this clone's configured prefix does not
# exist, so drive ocamlc under the in-tree runtime and point everything
# at the in-tree stdlib and vreplay library (see TEST.README.md)
OCAMLC="runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay \
    -use-runtime $PWD/runtime/ocamlrun"

TMP=$(mktemp -d) || exit 2
cleanup() {
    rm -rf "$TMP"
    rm -f testing/cases/*.cmi testing/cases/*.cmo \
        testing/check_dump.cmi testing/check_dump.cmo
}
trap cleanup EXIT INT TERM

promote=0
if [ "${1-}" = "--promote" ]; then promote=1; shift; fi

if [ $# -gt 0 ]; then
    cases=""
    for a in "$@"; do cases="$cases testing/cases/$a.ml"; done
else
    cases=$(ls testing/cases/*.ml)
fi

$OCAMLC vreplay/vreplay.cma -o "$TMP/check_dump" testing/check_dump.ml \
    || { echo "error: cannot build check_dump" >&2; exit 2; }

pass=0; failed=0
for src in $cases; do
    name=$(basename "$src" .ml)
    if ! $OCAMLC -visual-replay -o "$TMP/$name.exe" "$src" \
        > "$TMP/$name.compile" 2>&1; then
        echo "FAIL $name (compile)"; cat "$TMP/$name.compile"
        failed=$((failed + 1)); continue
    fi
    if ! "$TMP/$name.exe" > "$TMP/$name.dump" 2> "$TMP/$name.err"; then
        echo "FAIL $name (run)"; cat "$TMP/$name.err"
        failed=$((failed + 1)); continue
    fi
    if ! "$TMP/check_dump" "$TMP/$name.dump" > "$TMP/$name.check" 2>&1
    then
        echo "FAIL $name (check_dump)"; cat "$TMP/$name.check"
        failed=$((failed + 1)); continue
    fi
    if [ $promote -eq 1 ]; then
        cp "$TMP/$name.dump" "testing/expected/$name.dump"
        echo "PROMOTED $name ($(cat "$TMP/$name.check"))"
        pass=$((pass + 1)); continue
    fi
    if [ ! -f "testing/expected/$name.dump" ]; then
        echo "FAIL $name (no expected dump; run with --promote)"
        failed=$((failed + 1)); continue
    fi
    canon() {
        awk '{
            line = $0; out = ""
            while (match(line, /0x[0-9a-f]+/)) {
                a = substr(line, RSTART, RLENGTH)
                if (!(a in seen)) seen[a] = "0xA" ++n
                out = out substr(line, 1, RSTART - 1) seen[a]
                line = substr(line, RSTART + RLENGTH)
            }
            print out line
        }' "$1"
    }
    canon "testing/expected/$name.dump" > "$TMP/$name.expcanon"
    canon "$TMP/$name.dump" > "$TMP/$name.actcanon"
    if diff -u "$TMP/$name.expcanon" "$TMP/$name.actcanon" \
        > "$TMP/$name.diff"; then
        echo "PASS $name ($(cat "$TMP/$name.check"))"
        pass=$((pass + 1))
    else
        echo "FAIL $name (dump mismatch; diff shown with canonicalized" \
            "addresses)"
        cat "$TMP/$name.diff"
        failed=$((failed + 1))
    fi
done

echo "----"
echo "$pass passed, $failed failed"
[ $failed -eq 0 ]
