# The `jsip-vreplay` opam switch

How to get an opam switch whose compiler **is this fork** — so `ocamlc
-visual-replay` works as an ordinary installed compiler, and Base / Core /
ppx_jane are built against it (matching CMI magic by construction).

Bytecode-only by design: this tree does not build `ocamlopt`, and
`-visual-replay` only links its runtime into bytecode executables anyway.

## Prerequisites

- opam >= 2.1, initialized (`opam init`), repository reasonably fresh
  (`opam update`).
- This repo cloned, on branch `vreplay-main`, including at least commit
  `b3dd6d23a1` ("build: install the vreplay library; make the opam pin
  buildable") — earlier states of the branch cannot complete the pin's
  install step.

## Steps

From the repo root:

```sh
# 1. An empty switch; the compiler comes from the pin, not a release.
opam switch create jsip-vreplay --empty

# 2. Register the pin WITHOUT building yet (-n), so step 3 resolves
#    ocaml-variants to this repo instead of a stock release.
opam pin add --switch=jsip-vreplay -n ocaml-variants.5.5.1+trunk .

# 3. Build the fork as the switch's compiler, bytecode-only.
#    ~15-30 min. The ocaml-option-bytecode-only marker makes configure
#    pass --disable-native-compiler.
opam install --switch=jsip-vreplay -y ocaml-option-bytecode-only ocaml-variants

# 4. The Jane Street stack + dune, built by the fork. ~30-60 min.
opam install --switch=jsip-vreplay -y core stdio ppx_jane dune
```

Use it per-shell (do not make it the global default if other work relies
on another switch):

```sh
eval $(opam env --switch=jsip-vreplay)
```

## Verify

```sh
ocamlc -version          # 5.5.1+dev0-2026-06-19
ls $(opam var lib)/ocaml/vreplay    # data_structure/sexp/vreplay cmi+mli, vreplay.cma

cat > /tmp/smoke.ml <<'EOF'
module M = Map.Make (String)
let () =
  let m = M.empty in
  let m = M.add "a" 1 m in
  let m = M.add "b" 2 m in
  ignore (M.remove "a" m)
EOF
ocamlc -visual-replay -o /tmp/smoke.out /tmp/smoke.ml
VREPLAY_FILE=/tmp/smoke.dump /tmp/smoke.out
wc -l /tmp/smoke.dump    # 3 events; registry entries carry variable names
```

Note there is no `-I vreplay` / `-nostdlib` / `-use-runtime` anywhere: the
installed compiler resolves `+vreplay` from its own lib dir (that is what
commit `b3dd6d23a1`'s install rules provide).

## Core programs (`test/core_test`)

`test/core_test` (sibling of this repo) builds with the switch:

```sh
cd ../test/core_test
eval $(opam env --switch=jsip-vreplay)
dune build --profile vreplay     # profile adds -visual-replay (see its dune file)
VREPLAY_FILE=/tmp/core.dump ./_build/default/main.exe
# (profiles share _build/default; the binary is bytecode with the vreplay
#  runtime linked in -- `strings ... | grep caml_wire_emit` proves it)
```

Expectations, so nobody debugs a non-bug:

- The program compiles, links and **runs correctly** — that is the point
  of the switch (CMI magic `Caml1999I037` end to end).
- Its **dump is empty**: the instrumentation classifies calls by declaring
  unit (`Stdlib__Map`/`Set`/`Queue`/`Hashtbl`), and the walker only knows
  stdlib layouts. Core's `Map`/`Hashtbl` live in `Base__*` units with
  different representations — support for them is future work (ds_table +
  `Data_structure` catalogue + per-tag walker layouts).
- Stdlib-structure programs compiled in this switch produce full dumps
  (see Verify above), including under dune.

## Caveats

- No `ocamlopt` in this switch; dune's `.exe` targets are bytecode
  executables. Do not install packages that hard-require native.
- The switch is per-machine state (`~/.opam/jsip-vreplay`); redo these
  steps on each machine. Rebuild after compiler changes with
  `opam upgrade --switch=jsip-vreplay ocaml-variants` (rebuilds the stack
  on top automatically).
