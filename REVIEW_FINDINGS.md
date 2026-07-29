# Review findings — `-visual-replay` instrumentation

Audit of the files this fork actually added (see the table in `CLAUDE.md`), not
of upstream OCaml. Everything marked **reproduced** was confirmed by building
the compiler and running an instrumented program, not just by reading.

Status key: **fixed** here · **open** · **accepted** (deliberate, left alone).

---

## Correctness

### 1. Nested calls were silently dropped — **fixed**

`typing/vreplay_instrumentation.ml`, `inject_expression`.

`recurse_down = super.expr self exp` was computed and then discarded in the
instrumented branch: `inject_then_run_node exp` re-wrapped the **original,
un-mapped** expression. Any application inside an instrumented application's
function or arguments was therefore never instrumented.

Reproduced with:

```ocaml
let g x = x + 1
let f x = x + 2
let () = ignore (f (g 1))
```

Five applications execute (`ignore`, `f`, `g`, and the two `+`); only three
were logged. Fixed by wrapping `recurse_down` instead of `exp`.

### 2. Frame markers and payloads came out in unrelated orders — **fixed**

The `{` / `}` markers went through OCaml's `Printf.printf`, i.e. into the
OCaml stdout *channel buffer*, which a program that never flushes only empties
at exit. The payload went through `caml_wire_emit` → C `fprintf(stdout)` +
`fflush`, i.e. immediately. Two buffers, one fd, no ordering relationship.

Reproduced — every payload in the run arrived before every marker:

```
[wire] meow
[wire] meow
[wire] meow
{{}{}}
```

Depth was completely decoupled from the records it was supposed to annotate,
which made the dump unparseable regardless of wire format.

Fixed by giving the dump a single write path:

- `typing/vreplay_instrumentation.ml` no longer uses `Printf.printf` at all.
  `print_string_node` is gone; `inject_then_run_node` takes an `~emit`
  callback and pushes the markers through `caml_wire_emit` like the payload.
- `runtime/snapshot.c` now writes its argument **verbatim** — no `[wire] `
  prefix, no injected newline — and the OCaml side owns all framing. It also
  uses `caml_string_length` rather than relying on NUL termination.

The output is now ordered, and it happens to land on exactly the shape
`dump_reader.ml` already parses (frame-marker prefix, then the payload, one
record per line):

```
{meow
{meow
}{meow
}}
```

Side benefit: instrumented programs no longer depend on `Printf` being in
scope and unshadowed.

### 3. A raised exception strands the depth counter — **open**, see recommendation

`}` is emitted as a *following* let-binding, so a call that raises never
closes its frame. Reproduced — the dump ends at depth 2:

```
{{{CAUGHT}
```

Per `dump_reader.ml`, a dump that does not return to depth 0 makes the reader
raise, so any program using exceptions for control flow (`Not_found`, `Exit`,
`End_of_file`, …) produces an unreadable dump.

**Recommendation: carry depth as an explicit field and stop emitting closing
markers at all.**

This is already step 3 of the sexp migration in `CLAUDE.md` ("Decide how depth
is carried"), and it dissolves the problem rather than patching it. If every
record states its own depth, then:

- a dump truncated mid-call is still well formed — the trace just stops, and
  the reader renders a partial replay instead of raising;
- an exception unwind is simply the next record's depth jumping backwards
  (depth 5 → depth 2 means three frames unwound), so there is nothing to emit
  on the unwind path and nothing to lose when a call raises;
- the entire class of "unbalanced markers" bugs disappears, including the ones
  `exit`, `Stdlib.exit` and an uncaught exception would otherwise cause.

Two alternatives considered and not recommended as the primary fix:

- *Wrap the call in `Texp_try` and re-raise.* Faithful, and it would let you
  mark abnormal exits distinctly, but it is real Typedtree plumbing and a
  naive `raise e` **corrupts the user program's backtraces** — you would need
  `Printexc.raise_with_backtrace` to avoid changing observable behaviour of
  the program under debug. Worth doing later, once the format can express an
  "unwound" event; not worth it just to balance braces.
- *Track depth in C and close open frames from an `atexit` handler.* About ten
  lines and guarantees a parseable dump, but it fabricates returns that never
  happened. Acceptable as a stopgap, wrong as an answer.

### 4. `format_arg` discarded the argument expression — **fixed**

`format_arg` destructured `(arg_label, _arg)` and threw the argument away, so
`argument_list` could only ever hold `("NO_LABEL", "")` or
`("LABELLED", name)`. The `(string * string) list` never carried any argument
data at all.

Latent rather than live, because `format_function_call` still has no callers —
but it also **could not have been called**: the `.mli` declared the argument
list as `(arg_label * Typedtree.expression) list`, while `Texp_apply` actually
carries `(arg_label * Typedtree.apply_arg) list`.

Fixed both: the signature now matches `Texp_apply`, and each pair is
`(label, argument)` where the label keeps its kind *and* name
(`"LABELLED:foo"`) and the argument is the printed expression. `Omitted`
arguments — the labelled-partial-application case — print as `"OMITTED"`.
The hand-rolled `format_args` + `reverse` pair was replaced by `List.map`.

---

## Structure

### 5. `parsing/snapshot.ml` — **accepted** (kept deliberately)

Recorded here only so the reasoning is not re-litigated. The module is
`external emit : string -> unit = "caml_wire_emit"`, nothing in the tree
references `Snapshot.`, and it is compiled into `compilerlibs/ocamlcommon.cma`
and hence into `ocamlc` itself — so the *compiler* now carries a dependency on
a project-specific runtime primitive and can no longer run under a stock
`ocamlrun`.

Worth knowing: what actually makes `caml_wire_emit` available to *instrumented
user programs* is `runtime/snapshot.c` being listed in
`runtime_COMMON_C_SOURCES` (`Makefile:1251`), which puts the symbol in
`runtime/primitives`. `vreplay_instrumentation` splices its own `external`
declaration into each unit it instruments, so the feature does not read
`Snapshot.emit`. Keeping the module is fine; just don't rely on it being what
registers the primitive.

### 6. `[@@deriving sexp]` is a silent no-op — **open**

`vreplay_instrumentation.ml` and its `.mli`. Without ppx_sexp_conv the
attribute is simply ignored — there is no `sexp_of_t` (zero occurrences in the
`.cmi`). It reads as though serialization exists. Either drop it until the
hand-written s-expression printer lands, or replace it with an explicit
`val to_string : t -> string` so the gap is visible.

### 7. `module Wire` is exported but unused — **open**

`format_function_call` has no callers; `print_call_node` is still commented
out. The only cross-module reference to this file anywhere in the tree is
`compile_common.ml:117`. Fixing #4 makes `Wire` *correct*, not *live* — the
payload is still the literal `"meow"`.

### 8. `vreplay/` breaks the dune build — **open**

`vreplay.ml` and `vreplay.c` are 0 bytes. `vreplay.mli` is prose, and it is a
confirmed syntax error:

```
$ ./ocamlc -stop-after parsing vreplay/vreplay.mli
File "vreplay/vreplay.mli", line 3, characters 12-13:
Error: Syntax error
```

It is nonetheless listed in the root `dune` under "manual update: mli only
files", so `dune build` cannot succeed. Meanwhile `vreplay_instrumentation` —
the file that is actually edited — appears in **no** dune file, so Merlin
cannot see it. For a tree where dune exists only as a Merlin helper, that is
exactly backwards. Also note the `moduel_name` typo in the prose.

### 9. Committed `.depend` is stale — **open**

`HEAD:.depend` has seven entries for `parsing/vreplay.{cmo,cmx,cmi}`, a module
that stopped existing in `a39aa82fb` when injection moved to the typing layer.

`.depend` is `include`d by the Makefile, so make will remake it whenever it
considers it out of date with respect to `$(DEP_FILES)` — and it then shows up
modified in `git status`. This is mtime-dependent rather than universal: in the
main checkout `make -n ocamlc` was enough to regenerate it, while in a fresh
worktree a full `make world` left it alone. Either way it is committed stale;
run `make depend` and commit the result once.

### 10. `test_programs/map_test.ml` — **open**

Cannot compile in this tree (`open! Base`), is not wired into any test runner,
and its `| Add a, p ->` pattern does not match its own `action` type — the
`(* this is wrong but it's fine *)` comment is accurate. Currently it reads as
a decoy for anyone orienting in the repo. Delete it or fix and wire it up.

---

## Design issues worth deciding on

### 11. The dump shares stdout with the program under debug — **open**

`caml_wire_emit` writes to `stdout`, which is also where the instrumented
program's own output goes. This is visible in the #3 repro above: the
program's `CAUGHT` lands in the middle of the dump. Any program that prints
corrupts its own trace.

Writing the dump to a dedicated fd or to a file (path from an environment
variable, in the style of `OCAMLRUNPARAM`) would fix this and is probably a
prerequisite for the TUI reading a live program. Note `dump_reader.ml` already
reads a *file path*, never stdin.

### 12. Every application is instrumented — **open**

`filter_func` returns `true` unconditionally, so `+` and `^` are traced along
with everything else. Intended behaviour, per `vreplay/README.md`, is to fire
only on data-structure creation and manipulation. Until then the dumps are far
larger than they need to be, and now that every marker is an unbuffered
flushing write, this costs real time.

### 13. Wire-format mismatches with the interface — **open**

- `format_function_call` emits capitalized `"Function_name"` / `"Unnamed"`;
  `dump_reader.ml` only accepts lowercase.
- The payload is still the hardcoded literal `"meow"` — `print_call_node` is
  blocked on #6.

---

## Style and hygiene

### 14. `tools/check-typo` failures — **partly fixed**

The files touched here (`typing/vreplay_instrumentation.{ml,mli}`,
`runtime/snapshot.c`) had trailing whitespace, lines over 80 (and over 132)
columns, and missing newlines at EOF; those are fixed.

**Still failing on `missing-header`.** Every file this project added lacks the
standard 14-line licence block. That is deliberately left open because it is
an attribution decision, not a mechanical one: copying the block verbatim from
`typing/typecore.ml` — as `CLAUDE.md` currently instructs — would credit
"Xavier Leroy, projet Cristal, INRIA Rocquencourt, Copyright 1996" on files
written by this project in 2026. `tools/check-typo`'s header automaton accepts
any author text and any four-digit year, so the block can carry this project's
own attribution and still pass. Someone needs to pick the wording once, then
it can be applied to all five files at once:
`typing/vreplay_instrumentation.{ml,mli}`, `runtime/snapshot.c`,
`parsing/snapshot.{ml,mli}`.

Still failing elsewhere, untouched here: `driver/main_args.ml:698` (trailing
whitespace), `vreplay/vreplay.mli`, `test_programs/map_test.ml`.

### 15. Mangled `-visual-replay` help text — **open**

`driver/main_args.ml:698-700` has a literal newline inside the doc string, so
`ocamlc -help` prints it across two lines with stray indentation.

### 16. Synthesized nodes inherit the parent's attributes — **open**

`mk_exp` copies the parent's `exp_attributes` onto every node it builds, and
each synthesized `vb_pat` / `vb_attributes` does the same. A user attribute
such as `[@inline]` is therefore replicated onto roughly five synthetic nodes
per instrumented call. Synthesized nodes should carry `[]`.

### 17. `-visual-replay` is a silent no-op in the toplevel — **open**

The flag is registered in all four frontends (`Make_bytecomp_options`,
`Make_bytetop_options`, `Make_optcomp_options`, `Make_opttop_options`), but
`toplevel/` never goes through `compile_common` — it types phrases via
`Typemod.type_toplevel_phrase` (`toplevel/topcommon.ml:210`). So
`ocaml -visual-replay` accepts the flag and does nothing.

### 18. Accidental upstream edits, still uncommitted-to-cleanup — **open**

Already listed under "Repo hygiene" in `CLAUDE.md`, repeated here because they
are still in the tree and will show up in any review of this fork's diff:

- `runtime/caml/mlvalues.h` — 507-line pure reformat, no token changed.
- `parsing/parsetree.mli` — one-line change that corrupts the licence header
  (`projet` → `project`) and breaks its column alignment.
- `parsing/ast_helper.ml` — three added lines that are *only* whitespace.
- `lambda/matching.cmt4e44c0.tmp` — tracked 0-byte compiler temp file.
- root `dune`, `parsing/dune`, `dune-project` — ~99% `dune fmt` noise.

---

## Verified working — do not re-investigate

- **Prepending the `Tstr_primitive` does not break module coercion.** Tested a
  module with an `.mli` hiding a value, compiled with `-visual-replay`, linked
  against a second unit and ran it: correct output. The comment in
  `inject_instrumentation` about `str_type` staying valid is accurate.
- `CLAUDE.md`'s "Known broken #1" (`Makefile:92` pointing at a non-existent
  `parsing/snapshot.ml`) and "#2" (`wire_external` unreachable) are both
  **fixed** as of `e6b9433cb`. The check `CLAUDE.md` documents —
  `strings compilerlibs/ocamlcommon.cma | grep -c '^Snapshot$'` — still
  returns 0, but that is a **false negative**; use
  `./tools/ocamlobjinfo compilerlibs/ocamlcommon.cma | grep Snapshot`, which
  shows `Unit name: Snapshot`.
