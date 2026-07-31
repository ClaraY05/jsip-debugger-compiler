#!/bin/sh
# Component tests for the vreplay runtime pieces, complementing the
# golden end-to-end dumps of run_tests.sh:
#
#   testing/run_unit_tests.sh             run everything
#   testing/run_unit_tests.sh walker      run testing/unit/test_walker.ml only
#
# Each testing/unit/test_<name>.ml is a standalone assertion program
# (TAP-ish "ok"/"not ok" lines, nonzero exit on any failure) compiled
# WITHOUT -visual-replay: the tests drive Vreplay, Sexp and the C walker
# directly, and instrumenting them would pollute their own dumps.
# testing/unit/raise_unbalanced.ml is the exception -- it IS compiled
# with -visual-replay, to pin the known unbalanced-frame behavior of a
# raising instrumented call (bug 5 in testing/README.md).

set -u
cd "$(dirname "$0")/.." || exit 2

if [ ! -f ocamlc ] || [ ! -x runtime/ocamlrun ]; then
    echo "error: build the tree first (make world)" >&2
    exit 2
fi

OCAMLC="runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay \
    -use-runtime $PWD/runtime/ocamlrun"

TMP=$(mktemp -d) || exit 2
cleanup() {
    rm -rf "$TMP"
    rm -f testing/unit/*.cmi testing/unit/*.cmo
}
trap cleanup EXIT INT TERM

run_raise=1
if [ $# -gt 0 ]; then
    tests=""
    run_raise=0
    for a in "$@"; do
        if [ "$a" = raise_unbalanced ]; then run_raise=1
        else tests="$tests testing/unit/test_$a.ml"; fi
    done
else
    tests=$(ls testing/unit/test_*.ml)
fi

pass=0; failed=0
for src in $tests; do
    name=$(basename "$src" .ml)
    if ! $OCAMLC vreplay/vreplay.cma -I testing/unit \
        testing/unit/tap.ml "$src" -o "$TMP/$name" \
        > "$TMP/$name.compile" 2>&1; then
        echo "FAIL $name (compile)"; cat "$TMP/$name.compile"
        failed=$((failed + 1)); continue
    fi
    : > "$TMP/$name.dump"
    if VREPLAY_FILE="$TMP/$name.dump" "$TMP/$name" \
        > "$TMP/$name.out" 2>&1; then
        echo "PASS $name ($(grep -c '^ok' "$TMP/$name.out") checks)"
        pass=$((pass + 1))
    else
        echo "FAIL $name"; cat "$TMP/$name.out"
        failed=$((failed + 1))
    fi
done

# ---- pin: a raising instrumented call leaves its frame open (bug 5).
# The program must exit 0 (it catches the exception); the dump must be
# exactly one dangling "{" -- no record, no closing marker. ----
if [ $run_raise = 1 ]; then
    name=raise_unbalanced
    if ! $OCAMLC -visual-replay -o "$TMP/$name.exe" \
        testing/unit/raise_unbalanced.ml > "$TMP/$name.compile" 2>&1; then
        echo "FAIL $name (compile)"; cat "$TMP/$name.compile"
        failed=$((failed + 1))
    else
        : > "$TMP/$name.dump"
        if VREPLAY_FILE="$TMP/$name.dump" "$TMP/$name.exe" \
            > "$TMP/$name.out" 2> "$TMP/$name.err" \
            && [ "$(cat "$TMP/$name.out")" = "caught" ] \
            && [ "$(cat "$TMP/$name.dump")" = "{" ]; then
            echo "PASS $name (dump is one dangling '{' -- bug 5 unchanged)"
            pass=$((pass + 1))
        else
            echo "FAIL $name (expected stdout 'caught', dump '{')"
            echo "  stdout: [$(cat "$TMP/$name.out")]"
            echo "  dump:   [$(cat "$TMP/$name.dump")]"
            failed=$((failed + 1))
        fi
    fi
fi

# ---- pin: sink selection falls back.  A VREPLAY_SOCK nobody listens on
# must warn on stderr and fall through to the VREPLAY_FILE sink -- the
# program neither dies nor loses its dump. ----
if [ $# -eq 0 ]; then
    name=sink_fallback
    if ! $OCAMLC -visual-replay -o "$TMP/$name.exe" \
        testing/cases/queue_basic.ml > "$TMP/$name.compile" 2>&1; then
        echo "FAIL $name (compile)"; cat "$TMP/$name.compile"
        failed=$((failed + 1))
    else
        if VREPLAY_SOCK="$TMP/no-listener.sock" \
            VREPLAY_FILE="$TMP/$name.dump" "$TMP/$name.exe" \
            > /dev/null 2> "$TMP/$name.err" \
            && [ -s "$TMP/$name.dump" ] \
            && grep -q "cannot connect" "$TMP/$name.err"; then
            echo "PASS $name (dead socket warns, file sink takes over)"
            pass=$((pass + 1))
        else
            echo "FAIL $name (expected a warning and a non-empty file dump)"
            cat "$TMP/$name.err" 2>/dev/null
            failed=$((failed + 1))
        fi
    fi
fi

echo "----"
echo "$pass passed, $failed failed"
[ $failed -eq 0 ]
