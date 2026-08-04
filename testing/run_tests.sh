#!/bin/sh
# Golden-dump tests for -visual-replay.
#
#   testing/run_tests.sh              run every case
#   testing/run_tests.sh map_basic    run selected cases
#   testing/run_tests.sh --promote    rewrite expected/ from current output
#
# Each testing/cases/<name>.ml is compiled with -visual-replay (from the
# repo root, so the loc strings in the dump are stable relative paths),
# run with VREPLAY_FILE pointing at a scratch dump (program stdout is
# captured separately and never mixes with the dump), and its dump is
# (a) validated by check_dump -- every line parses, every snapshot
# round-trips, depth returns to 0 -- and (b) compared against
# testing/expected/<name>.dump.  A final smoke test streams one case
# through a VREPLAY_SOCK Unix-socket listener.
#
# When ./ocamlopt exists (make opt), every case additionally compiles
# and runs under the native compiler, against the SAME expected/ dumps:
# the wire format is backend-independent, so byte and native output must
# be equal up to the address bijection.  Without ocamlopt the native
# pass is skipped with a note.  --promote rewrites expected/ from the
# bytecode run only; the native pass then re-checks against it.
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
# -use-runtime because this clone has no installed runtime at all (any
# ABI-compatible one would do: the wire primitives live in the vreplay
# stubs DLL, not the runtime); -dllpath bakes that DLL's directory into
# the executable so the produced test binaries are self-contained
OCAMLC="runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay \
    -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay"
# native executables link the stubs statically: -I vreplay doubles as
# -L vreplay, resolving the -cclib -lvreplaynat recorded in vreplay.cmxa
OCAMLOPT="runtime/ocamlrun ./ocamlopt -nostdlib -I stdlib -I vreplay"

modes="byte"
if [ -f ocamlopt ] && [ -f vreplay/vreplay.cmxa ]; then
    modes="byte native"
else
    echo "SKIP native pass (no ocamlopt/vreplay.cmxa; build with make opt)"
fi

TMP=$(mktemp -d) || exit 2
cleanup() {
    rm -rf "$TMP"
    rm -f testing/cases/*.cmi testing/cases/*.cmo \
        testing/cases/*.cmx testing/cases/*.o \
        testing/mock/*.cmi testing/mock/*.cmo \
        testing/mock/*.cmx testing/mock/*.o \
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

# The Base/Core stand-ins: units named exactly as the real libraries'
# are, holding the real representations, so the Core cases run here and
# in CI with no opam switch and no Core installed (see testing/mock/).
# Compiled as a library and never with -visual-replay -- real Base isn't
# instrumented either -- so a case links only the units it names and
# every event still comes from the case's own calls.  Listed in
# dependency order, which is not alphabetical.
mock_units="base__Hashtbl base__Hash_set base__Map base__Set \
    base__Queue base__Stack base__Linked_queue core__Map core__Deque \
    core__Fdeque core__Doubly_linked core__Hash_queue"
mock_srcs=""
for u in $mock_units; do
    # a unit with an .mli hides its representation, as the library it
    # stands in for does; pass it explicitly or ocamlc ignores it
    if [ -f "testing/mock/$u.mli" ]; then
        mock_srcs="$mock_srcs testing/mock/$u.mli"
    fi
    mock_srcs="$mock_srcs testing/mock/$u.ml"
done
$OCAMLC -a -I testing/mock -o "$TMP/mocks.cma" $mock_srcs \
    || { echo "error: cannot build the Base/Core mocks" >&2; exit 2; }
case $modes in *native*)
    $OCAMLOPT -a -I testing/mock -o "$TMP/mocks.cmxa" $mock_srcs \
        || { echo "error: cannot build the native Base/Core mocks" >&2
             exit 2; } ;;
esac

pass=0; failed=0
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
for mode in $modes; do
  for src in $cases; do
    name=$(basename "$src" .ml)
    # both modes share expected/<name>.dump: the wire format does not
    # depend on the backend, so only the addresses may differ
    if [ "$mode" = native ]; then
        label="$name [native]"
        comp="$OCAMLOPT -visual-replay -I testing/mock $TMP/mocks.cmxa"
    else
        label=$name
        comp="$OCAMLC -visual-replay -I testing/mock $TMP/mocks.cma"
    fi
    out="$TMP/$name.$mode"
    if ! $comp -o "$out.exe" "$src" > "$out.compile" 2>&1; then
        echo "FAIL $label (compile)"; cat "$out.compile"
        failed=$((failed + 1)); continue
    fi
    # the sink opens lazily at the first event, so an event-free program
    # creates no file at all: pre-create it, making "no events" an empty
    # dump for check_dump and the golden diff
    : > "$out.dump"
    if ! VREPLAY_FILE="$out.dump" "$out.exe" \
        > "$out.stdout" 2> "$out.err"; then
        echo "FAIL $label (run)"; cat "$out.err"
        failed=$((failed + 1)); continue
    fi
    if ! "$TMP/check_dump" "$out.dump" > "$out.check" 2>&1
    then
        echo "FAIL $label (check_dump)"; cat "$out.check"
        failed=$((failed + 1)); continue
    fi
    if [ $promote -eq 1 ] && [ "$mode" = byte ]; then
        cp "$out.dump" "testing/expected/$name.dump"
        echo "PROMOTED $name ($(cat "$out.check"))"
        pass=$((pass + 1)); continue
    fi
    if [ ! -f "testing/expected/$name.dump" ]; then
        echo "FAIL $label (no expected dump; run with --promote)"
        failed=$((failed + 1)); continue
    fi
    canon "testing/expected/$name.dump" > "$out.expcanon"
    canon "$out.dump" > "$out.actcanon"
    if diff -u "$out.expcanon" "$out.actcanon" \
        > "$out.diff"; then
        echo "PASS $label ($(cat "$out.check"))"
        pass=$((pass + 1))
    else
        echo "FAIL $label (dump mismatch; diff shown with canonicalized" \
            "addresses)"
        cat "$out.diff"
        failed=$((failed + 1))
    fi
  done
done

# Socket sink smoke test: stream one case's dump through VREPLAY_SOCK
# into a listener and validate the capture with check_dump.  The dump
# must be non-empty -- an empty capture means the program fell back to
# the file sink (connect raced or failed), which is a failure here.
if [ $promote -eq 0 ] && command -v python3 >/dev/null 2>&1; then
    sockpath="$TMP/vreplay.sock"; sockdump="$TMP/socket.dump"
    python3 - "$sockpath" "$sockdump" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1]); s.listen(1)
c, _ = s.accept()
with open(sys.argv[2], "wb") as f:
    while True:
        d = c.recv(65536)
        if not d:
            break
        f.write(d)
PY
    listener=$!
    tries=0
    while [ ! -S "$sockpath" ] && [ $tries -lt 50 ]; do
        sleep 0.1; tries=$((tries + 1))
    done
    if $OCAMLC -visual-replay -o "$TMP/sock_case.exe" \
        testing/cases/queue_basic.ml > /dev/null 2>&1 \
        && VREPLAY_SOCK="$sockpath" "$TMP/sock_case.exe" \
            > /dev/null 2> "$TMP/sock.err" \
        && wait "$listener" \
        && [ -s "$sockdump" ] \
        && "$TMP/check_dump" "$sockdump" > "$TMP/sock.check" 2>&1; then
        echo "PASS socket_sink ($(cat "$TMP/sock.check"))"
        pass=$((pass + 1))
    else
        echo "FAIL socket_sink"
        cat "$TMP/sock.err" "$TMP/sock.check" 2>/dev/null
        kill "$listener" 2>/dev/null
        failed=$((failed + 1))
    fi
elif [ $promote -eq 0 ]; then
    echo "SKIP socket_sink (no python3)"
fi

echo "----"
echo "$pass passed, $failed failed"
[ $failed -eq 0 ]
