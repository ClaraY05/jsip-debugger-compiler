# CLAUDE.md — jsip_debugger

## What this repo is

A **fork of the OCaml compiler** carrying one feature: a `-visual-replay`
flag that injects instrumentation into an arbitrary OCaml program at the
**Typedtree** layer, so that running the compiled program dumps one sexp
event per observed value — each call on a catalogued container (the stdlib's
`Map`/`Set`/`Queue`/`Hashtbl`/`Stack`/`Dynarray` and Base/Core's
equivalents) and each `let` of a value of the program's own declared types —
carrying a walked snapshot of that value's in-memory shape. See "What is
tracked" for the exact rules.

The tree sits on an **OCaml 5.5 base** — `VERSION` is `5.5.1+dev0-2026-06-19`
and the upstream commit under all project work is **`466e585663`**. It did
not start there: the fork point was `511483454` (5.6.0+dev), and
`ecb3981bb1` merged a replay of the whole branch onto 5.5. Two consequences:

- **`trunk` is no longer the base.** It still points at `511483454`, so
  `git diff trunk HEAD` mixes the project's work with the entire 5.5-vs-5.6
  upstream delta. To see project work vs upstream, diff against the real
  base: `git diff 466e585663 HEAD -- <path>` (155 files, ~8k lines — all
  project work apart from three dune files; see "Repo hygiene").
- Most commits appear twice in `git log --all` — once on the 5.6 line, once
  replayed on 5.5. Only the 5.5 copies are ancestors of `vreplay-main`.

This is one half of a two-repo project:

```
jsip_debugger  (this repo)                  ~/jsip-debugger-interface
  instrumented ocamlc                         bonsai_term TUI
  ocamlc -visual-replay foo.ml                (GDB-style, steps through
  ./foo → vreplay.dump  ───────────────────→   the call stack, source,
          (one sexp event per line)            and heap shapes)
```

**You are almost always working on the compiler half.** The interface half
lives at `~/jsip-debugger-interface` (GitHub `wuad391/jsip-debugger-interface`,
branch `main`) and has its own `CLAUDE.md`.

`~/jsip-visual-debugger` (GitHub `ClaraY05/jsip-visual-debugger`) used to be
a dead scaffold and is not any more: it holds **both repos as git
submodules** — this one pinned by `vreplay-main` — and drives
`cool_name.sh`, the one-command pipeline (build the fork, compile a program
under `-visual-replay`, run it, open the TUI on the dump). It is where an
end-to-end check of a compiler change happens, and where a change to this
repo's build layout will break first. Bumping the submodule pin is how a
merged PR here reaches it.

Goal of the project: visualize allocated data and data structures as the
user steps through a replay of their program — a TUI debugger that doesn't
require knowing assembly.

---

## Orient fast: the project's own files

This tree is ~1M lines of upstream OCaml. **Everything the project actually
wrote is this list.** If you are grepping the whole tree, you are probably
lost. (Line numbers drift; the symbol names don't.)

| File | Role |
|---|---|
| `typing/vreplay_instrumentation.ml` / `.mli` | **The heart.** A `Tast_mapper` that rewrites each `Texp_apply` that `classify` marks as a DS event: frame markers, result binding, payload schemas derived from the user's type declarations, and a post-call `Vreplay.snapshot` hand-off. |
| `driver/compile_common.ml:97` | The hookpoint — one line, pipes the typed AST through the mapper. |
| `vreplay/src/snapshot.c`, `wire_sink.c` | The C stubs: `snapshot.c` defines `caml_wire_traverse`, the no-allocation BFS walker that builds each event's `node` tree; `wire_sink.c` defines `caml_wire_emit` (opens and writes the dump sink; framing is the OCaml side's job). Compiled into the library's own C-stubs archives (`libvreplay{byt,nat}.a` + the stubs DLL), **not** into the runtime — so any ABI-compatible runtime resolves the primitives. |
| `vreplay/src/` | **The runtime library** linked into instrumented programs, five units: `data_structure.{ml,mli}` (the catalogue: which DSs are walkable and their per-layer interior/payload layouts), `sexp.{ml,mli}` (sexp AST + printer/parser + **the wire schema** + `to_sexp`/`from_sexp`), `vreplay_layout.{ml,mli}` (layout flattening to the C-ready arrays — the field-order contract with the walker), `vreplay_registry.{ml,mli}` (the weak registry and member store), `vreplay.{ml,mli}` (the façade: externals, event assembly, and `snapshot`, the injected entry point). Built by `make vreplay` (part of `world`) into `vreplay/src/vreplay.cma`. |
| `bytecomp/bytelink.ml:935`, `asmcomp/asmlink.ml:349`, `driver/compmisc.ml:48` | Flag-gated linking: `vreplay.cma` / `vreplay.cmxa` is prepended after the stdlib archive, and `+vreplay` joins the load path, only under `-visual-replay`. |
| `utils/clflags.ml:253`, `.mli:221` | `let visual_replay = ref false` |
| `driver/main_args.ml:692` + 5 module lists | `-visual-replay` flag wiring. |
| `Makefile:172`, `:872` | Build wiring; `:172` puts the instrumentation in `ocamlcommon`, `:872` is the `vreplay` library block — the OCaml halves plus, via `ocamlmklib`, the C stubs archives whose `-dllib`/`-cclib` records ride inside `vreplay.cma`/`.cmxa`. |
| `vreplay/tests/` | The project's own test suite: golden dumps (49 cases), their programs, the Base/Core stubs (`core_stubs/`), and `check_dump.ml`. See `vreplay/tests/README.md`. |

**`REVIEW_FINDINGS.md` no longer exists** (deleted in `ff240449a1`), and as
of the 2026-08-05 doc cleanup nothing in the tree cites it any more; the
live summary of known issues is "Known broken" below.

---

## Build

**`make` is the live build system. Dune is not.** Dune exists here only as a
Merlin helper (`HACKING.adoc:518`) and currently cannot even configure — see
Known broken #4. Ignore `_build/`.

A **fresh worktree has no `Makefile.config`** and must be configured once
before anything else:

```sh
./configure --prefix=$PWD/_install
```

Then:

```sh
make -j4 world         # full/incremental build (bytecode). This machine has 4 cores.
```

- **Native is supported too.** `make world` is bytecode only; a follow-up
  `make -j4 opt` adds `ocamlopt`, the native runtime/libraries, and
  `vreplay/src/vreplay.cmxa`, after which `-visual-replay` links its runtime
  into native executables as well. The instrumentation itself is shared
  (`compile_common` feeds both backends), so bytecode-only work still only
  needs `make world`.
- After editing anything in `typing/`, `driver/`, `utils/`, or a `.c` in
  `runtime/`: just `make -j4 world`. `runtime/primitives` and
  `runtime/prims.c` are regenerated automatically. Only
  `rm runtime/primitives runtime/prims.c` if you **added a new primitive
  name** and hit a phantom "unavailable primitive" error. **Removing** a
  primitive name additionally needs `make partialclean` first: every
  bytecode tool embeds the full old table via `-use-prims` and dies at
  startup (`unknown C primitive`) under the shrunk runtime until relinked.
- **`make bootstrap` is not needed** for this project's kind of change.
- Adding a new `.c` file to the runtime means adding its stem to
  `runtime_COMMON_C_SOURCES` (`Makefile:1280`).

**`make -j` races on a from-scratch tree** (e.g. a fresh worktree). Once
`LINKC ocamlc` starts, a concurrent job in `debugger/` or `ocamltest/` tries
to run `./ocamlc` mid-link and dies with `the file './ocamlc' is not a
bytecode executable file`, surfacing as `Error 127`. `-j 2` hits it too. It
is transient, not a real failure — finish with a **serial `make world`**,
which is fast at that point because everything up to `ocamlc` is already
built. Incremental `-j` builds on an already-populated tree are fine.

**Always confirm the build actually relinked, and that the binary matches
the tree:**

```sh
ls -la --time-style=full-iso ocamlc driver/compile_common.cmo
# ocamlc must be NEWER than the .cmo, or your change is not in the binary
runtime/ocamlrun ./ocamlc -config | grep '^version'
# must match VERSION -- a binary reporting 5.6.0+dev predates the 5.5 rebase
```

That last check matters: a long-lived checkout can hold an `ocamlc` built
before `ecb3981bb1` while the sources are on 5.5. Rebuild before trusting it.

`.depend` is tracked and can go stale. It is `include`d by the Makefile, so
make remakes it whenever it looks out of date — even `make -n` is enough —
and it then shows up modified in `git status`. That is expected, not your
change. Run **`make alldepend`** (`depend` plus `stdlib/` and the
`otherlibs/`, which is what CI's check covers) and commit the result. It
also goes stale after **merging someone else's commit**, not just after
your own edits, so re-run it post-merge.

---

## Run the feature end to end

**Every bytecode tool in this tree must be run under `runtime/ocamlrun`.**
A bare `./ocamlc`, `./tools/ocamlobjinfo`, … dies on its shebang with
`cannot execute: required file not found`, and because that is a shell
failure rather than a tool error it usually shows up as *empty output* —
which reads as a real answer and sends you debugging the wrong thing.
Prefix everything:

```sh
runtime/ocamlrun ./ocamlc -config
runtime/ocamlrun ./tools/ocamlobjinfo compilerlibs/ocamlcommon.cma
```

For compiling, also note that depending on how the tree was configured
`standard_library` may point somewhere unpopulated, so use the
config-independent invocation (`vreplay/tests/README.md` has the
long-form version, verified in-tree):

```sh
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay/src -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay/src \
  -o /tmp/t.out /tmp/t.ml
```

`-I vreplay/src` is needed because the injected call references `Vreplay`: while
`compmisc` adds `+vreplay` to the load path, that resolves under
`standard_library`, where nothing installs the library from a plain build.
`-use-runtime` is needed only because this clone has no installed runtime
at all — the wire primitives live in the vreplay stubs DLL, not the
runtime, so any ABI-compatible `ocamlrun` works. `-dllpath` bakes that
DLL's directory into the executable; without it the program dies at
startup with `unknown C primitive caml_wire_emit` (the DLL wasn't found —
an installed compiler needs neither flag, its `stublibs/` covers it).

The native equivalent (needs `make opt` to have run; `ocamlopt` is itself
a bytecode executable, so it too runs under `runtime/ocamlrun`):

```sh
runtime/ocamlrun ./ocamlopt -nostdlib -I stdlib -I vreplay/src -visual-replay \
  -o /tmp/t.out /tmp/t.ml
```

No `-use-runtime` and no `-dllpath` here: native links the stubs
statically — `vreplay.cmxa` carries `-cclib -lvreplaynat`, and
`-I vreplay/src` doubles as `-L vreplay/src`, so `caml_wire_emit`/
`caml_wire_traverse` resolve from `libvreplaynat.a` at C link time. A
stock `libasmrun` works; the executable is fully self-contained.

`_install/` currently holds only `lib/ocaml` in both checkouts — there is no
`_install/bin` unless someone runs `make install`, and if they do, prefer
the invocation above to the installed binaries anyway (their shebangs point
at whatever path the tree was configured with).

### Where the dump goes — *not* stdout

The instrumented program picks its sink at the first event, from the
environment (`vreplay/src/vreplay.ml`):

- `VREPLAY_SOCK=<path>` — connect a Unix domain stream socket (a live
  listener, e.g. the debugger interface). A failed connect warns on stderr
  and falls through to the file sink.
- `VREPLAY_FILE=<path>` — write that file, truncated at start.
- neither — write `./vreplay.dump`.

The dump never goes to stdout, so the program's own printing cannot corrupt
it. If the sink cannot be opened, a one-line warning goes to stderr and
emission is disabled; the program keeps running.

**Everything goes through `caml_wire_emit`**, `{`/`}` markers included. Do
not reintroduce `Printf.printf` for the markers: it writes into OCaml's
stdout *channel* buffer, flushed only at exit, while `caml_wire_emit`
flushes on every call — mixing the two put every marker in the run after
every payload.

### Smoke tests

Negative — a plain-function program must produce no events. The sink is
opened lazily at the *first* event, so a clean negative leaves **no dump
file at all**, not an empty one:

```sh
printf 'let g x = x + 1\nlet f x = x + 2\nlet () = ignore (f (g 1))\n' > /tmp/neg.ml
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay/src -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay/src \
  -o /tmp/neg.out /tmp/neg.ml
rm -f /tmp/neg.dump
VREPLAY_FILE=/tmp/neg.dump /tmp/neg.out
test ! -e /tmp/neg.dump && echo "no events, as expected"
```

(`vreplay/tests/expected/neg_*.dump` are 0-byte files because `run_tests.sh`
truncates the dump into existence before the run; the runtime does not.)

Positive — a Map program. Three events fire (the two `M.add` and the
`M.remove`); `empty` is an ident not an application, `find` returns the
value not the map, and `ignore` is not a DS call:

```sh
cat > /tmp/t.ml <<'EOF'
module M = Map.Make (String)
let () =
  let m = M.empty in
  let m = M.add "a" 1 m in
  let m = M.add "b" 2 m in
  let m = M.remove "a" m in
  ignore (M.find "b" m)
EOF
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay/src -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay/src \
  -o /tmp/t.out /tmp/t.ml
VREPLAY_FILE=/tmp/t.dump /tmp/t.out && cat /tmp/t.dump
```

One event per line, prefixed by the frame markers giving its depth delta
(`{` is +1, `}` is −1). A call can emit **several** event records inside one
`{}` frame — one per root (mutated container arguments plus a structure
result). Real output, abridged and wrapped for reading:

```
{(event (id 1) (loc ((file_path /tmp/t.ml) (line_number 4) ...))
   (fn (Function_name M.add))
   (args ((No_label (expression (Unnamed "\"a\"")))
          (No_label (expression (Unnamed 1)))
          (No_label (expression (Unnamed m)))))
   (registry ((1 0x7c4dc23f2360 m)))
   (ty ((printed "int M.t") (params ((key string) (data int)))))
   (snapshot ((ds_type Map) (root_node ((id 1) (virtual_address 0x7c4d...)
     (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r (Int 0))))
     (children ()))))))
}{(event (id 2) ... (registry ((1 0x7c4dc23f2360 m) (2 0x7c4dc23ee788 m)))
   (snapshot ((ds_type Map) (root_node ((id 2) ...
     (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r Child)))
     (children (((id 3) ... (block ((l (Int 0)) (v (String b))
                                    (d (Int 2)) (r (Int 0))))
                 (children ())))))))))
}{(event (id 3) ... (fn (Function_name M.remove))
   (snapshot ((ds_type Map) (root_node ((id 3) (virtual_address 0x7c4d...)
     (block ()) (children ()))))))
}
```

That third record is the whole delta story in one line: `M.remove "a"` on
`{a; b}` returns the already-dumped `b` subtree, so instead of re-dumping it
the event collapses to a **revisit stub** — root id 3 (matching the node
event 2 defined), its current address, and empty `block`/`children`. Note
also `(r Child)` in event 2: the field is labeled in `block` and its value
is `children`'s next node.

### Tests

The project's own tests live in **`vreplay/tests/`** — golden-dump cases plus a
structural checker. Run them after any change to the instrumentation, the
vreplay library, or `vreplay/src/snapshot.c`:

```sh
vreplay/tests/run_tests.sh              # everything (needs a built tree)
vreplay/tests/run_tests.sh map_basic    # selected cases
vreplay/tests/run_tests.sh --promote    # re-bless expected/ after a deliberate change
```

`check_dump` validates structure **before** the golden diff — wrapper
fields, sexp round-trip, depth balance, and the sharing invariants — so a
`--promote` only rewrites goldens that were already well formed. Addresses
are canonicalized for the comparison only, so goldens stay verbatim run
output and double as the interface repo's parser fixtures. `vreplay/tests/README.md`
lists what the cases cover.

**When the tree has a native compiler, every case runs twice.** If `ocamlopt`
and `vreplay/src/vreplay.cmxa` exist (i.e. `make opt` has run), the suite
compiles and runs each case under both backends against the **same**
`expected/` dumps — the wire is backend-independent, so byte and native
output must agree up to the address bijection. Without them the native pass
is skipped with a printed note that is easy to miss: a bytecode-only tree
reports `51 passed` (49 cases + the catalogue round-trip check + the
socket-sink smoke test) and a full one `100 passed`, so the count is how
you tell which run you got. `--promote`
re-blesses from the bytecode run only, and the native pass then re-checks
against the freshly promoted goldens.

**`vreplay/tests/core_stubs/` is how the Base/Core cases run at all.** (Formerly
`mock/`.) This tree has no
opam switch and no Core installed, so the suite compiles miniature stand-ins
that reuse the *real unit names and representations*
(`base__Map.ml`, `core__Deque.ml`, …) into a `stubs.cma` and compiles the
`core_*` cases against it. That is enough to exercise `ds_table`'s
provenance matching and the walker's layouts in CI. It is not enough to
prove anything about the genuine Core layouts — for that, use the
`jsip-vreplay` switch below. When you add a Core entry, add its stub unit
and its case together.

The upstream testsuite has **no** `-visual-replay` coverage:

```sh
make -C testsuite parallel                  # everything, faster
make -C testsuite one DIR=tests/<area>      # one directory
```

### The `jsip-vreplay` opam switch

`README_opam_switch.md` (deleted in the doc refresh; recover it from git
history at `3a8a253c40`) set up a switch whose *compiler is this fork*, with
Base/Core/ppx_jane built against it (matching CMI magic by construction), so
`ocamlc -visual-replay` works as an ordinary installed compiler on real
Core-using programs. Bytecode-only by design. It takes ~1h to build; it is
the only way to check the Core catalogue entries against *real* Core layouts
rather than `vreplay/tests/core_stubs/`'s stand-ins. Needs at least `b3dd6d23a1` on the
branch.

**The switch installed on this machine (`~/.opam/jsip-vreplay`) is stale and
emits nothing.** Verified 2026-08-03: `vreplay/tests/cases/map_basic.ml` through
that switch produces `{}{}{}` — frames, no records — while the same case in
an in-tree build is fine, so it is the install, not the branch. Copying
fresh `vreplay/src/*.cmi *.cma` into `<switch>/lib/ocaml/vreplay/` does **not**
fix it (and overwrites the originals); it needs
`opam reinstall --switch=jsip-vreplay ocaml-variants` off current
`vreplay-main`. Until then, the cheaper way to test against real Core is to
build in-tree and drive `ocamlfind ocamlc -package core -linkpkg
-visual-replay` with `OCAMLFIND_COMMANDS=ocamlc=<wrapper>`, the wrapper
running this tree's `ocamlc` under its own `ocamlrun` against the switch's
`lib/ocaml`. Re-copy the tree's `vreplay/src/` artifacts into the switch after
every rebuild — the layouts live there, and a stale copy silently tests the
old catalogue.

---

## The wire format contract

**`vreplay/src/sexp.mli` is the spec — read it in full before changing anything
about serialization.** It is a prose specification as much as an interface:
the block-representation table, the delta/sharing rules, the registry
format, and the `ty` shape are all documented there.

Both sides derive from this one schema — no string parsing remains anywhere
— but **the interface trails the compiler by design**: a structure lands
here first, and the interface has to grow the matching `Ds_type`
constructor before it can read the newer dumps. As of 2026-08-05 this repo
emits **twenty** `ds_type` names (six stdlib containers, thirteen Core/Base
ones, and `User`) while the interface's `main` reads the seventeen that
existed at PR #15 — `Core_union_find`, `Core_map_tree` and `Core_set_tree`
are the three it cannot parse yet. Assume a freshly vendored dump needs
interface work, not that it is broken.

Every event is one line:

```
(event (id N) (loc ...) (fn ...) (args ...) (registry ...) (ty ...)
       (binder ...) (scope ...) (snapshot ...))
```

- `loc` / `fn` / `args` are rendered in the shapes `[@@deriving sexp]` gives
  the **interface repo's own types** (`Location.t`, `Function_info.t`,
  `Argument.t` in `~/jsip-debugger-interface/lib/types`), so its reader is
  derived, not hand-written — see `Sexp.sexp_of_loc/fn/args`.
- `registry` is the live weak registry: `(id address)` or `(id address name)`
  per tracked-and-alive structure, captured by the same C walk as the nodes.
  The name is the latest non-empty identifier the structure was observed
  under (a `let` binder or a mutated container argument); anonymous entries
  keep the two-atom shape. Entries appear when a structure is first tracked
  and vanish once the GC collects it.
- `ty` carries the root's static type as printed off the typedtree, plus
  role-labeled parameters (`key`/`data` for maps and hashtables, `elt` for
  sets and queues), so the interface displays types without parsing OCaml.
- `binder` and `scope` say which *binding* the root's name is, and what each
  of the unit's tracked names means at that program point —
  `(binder Map_basic.m_88)`, `(scope ((m Map_basic.m_88)))`. The name alone
  cannot separate `let m = M.add "a" 1 m`'s two versions: both stay alive
  and both are called `m`, so the registry shows two `m` entries and only
  the binder says which one the program can still reach (the interface greys
  the others out). A binder is `unit.ident_stamp`, opaque — readers compare
  it, nothing resolves it. It is omitted for a root observed under no name,
  the way an anonymous registry entry omits its name; `scope` is always
  written, so an event *without* it is an older dump rather than an empty
  scope.
- `snapshot` is `Vreplay.to_sexp` of `{ ds_type; root_node }`.

Two properties that are easy to get wrong:

1. **Dumps are deltas.** Every node carries a wire id unique across the
   dump. For immutable structures (Map/Set) a block is dumped **at most
   once**; every later occurrence is `(Id n)`, and a re-observed structure's
   whole event collapses to a **revisit stub** (root id, current address,
   empty `block` and `children`). Mutable structures (Queue/Hashtbl) re-walk
   in full each event, the root keeping its registry id while interior cells
   take fresh ids. A reader reconstructs any event by resolving `(Id n)`
   against the node that defined it earlier.
2. **Every kept field is labeled, in `block`.** A field whose value is a
   block of its own reads `Child` and stands for the next entry of
   `children`, in order. So a reader needs no layout table of its own — not
   for a user record's fields, not for which side (`l`/`r`) a map child hung
   off. Payload labels come from schemas the instrumentation derives from
   the user's own type declarations.

`Vreplay.from_sexp` + `Sexp.of_string` in this repo are the reference reader
and exact inverses of the emitters. `to_sexp`/`from_sexp` follow
`[@@deriving sexp]` conventions — records as `((field value) ...)`,
constructors as `(Name arg)` — so the interface mirrors the type definitions
with `ppx_sexp_conv`. **There is no ppx in the compiler build; never add
code that relies on one.**

On the interface side, `[@sexp.allow_extra_fields]` is set **only** on the
event wrapper, so adding a wrapper field is backward compatible while adding
a nested field is not. After any deliberate change: `run_tests.sh --promote`
here, then re-vendor `vreplay/tests/` into the interface repo.

Note `Inject.instrument_call` takes `~inject_after` as closures producing
**arbitrary already-typed expressions** and knows nothing about what they
do. Keep it that way; don't push payload assumptions back into it. It owns
only the `{}` markers.

### What is tracked

Two different things produce events, and they are classified in different
places.

**1. Catalogued container calls.** `Catalogue.table` in
`typing/vreplay_instrumentation.ml` has one row per compilation unit:
`declares` (the catalogue entry of the type the unit declares) and
`observes` (its calls' mutability and the entries they operate on) — the
old `ds_of_type_unit`/`ds_table` pair is derived from it and cannot drift.
`vreplay/src/data_structure.mli` holds the layouts. **Extend both files
together** — a unit named without a layout no-ops at runtime (now caught:
`vreplay/tests/check_catalogue.ml` holds every name the table can emit to
`Data_structure.of_name`, so a typo is a red test, not a silent no-op), and
a layout nothing maps to is dead.

| Catalogue entry | Declaring units | Root |
|---|---|---|
| `Map`, `Set` | `Stdlib__Map`, `Stdlib__Set` | immutable — the result |
| `Queue`, `Hashtbl`, `Stack`, `Dynarray` | the matching `Stdlib__*` | mutable — each structure-typed argument, read post-call (so `pop`/`peek` fire by design) |
| `Core_map`, `Core_set` | `Base__Map`, `Core__Map`, their `*_intf`, likewise for Set | immutable |
| `Core_hashtbl`, `Core_hash_set`, `Core_queue`, `Core_stack`, `Core_deque`, `Core_fdeque`, `Core_doubly_linked`, `Core_hash_queue`, `Core_union_find` | the matching `Base__*` / `Core__*` and their `*_intf` | mutable (`Core_fdeque` immutable) |
| `Core_map_tree`, `Core_set_tree` | the *qualified* `Base__Map.Tree`, `Core__Map_intf.Tree`, … | immutable |

Two modules get no entry of their own. `Core.Bag.t` **is** a
`Doubly_linked.t` — `bag.ml` includes Doubly_linked behind an ascription,
which keeps the representation and seals the type — so `Core__Bag` and
`Core__Bag_intf` map to `Core_doubly_linked`, no new catalogue entry. And
`Core.Linked_queue` is a `Stdlib.Queue.t`, so it maps to `Queue`.

Three rules worth internalizing:

- **One catalogue entry per *representation*, not per module.** `Core.Map.t`
  is an alias of `Base.Map.t`, and `Map.Poly`, `Int.Map` and every `Make`
  instance are that same type, so one entry covers them all. Conversely
  `Core.Linked_queue` *is* `Stdlib.Queue.t`, so it belongs to `Queue` — which
  is why a unit maps to a *list* of names (`Base__Queue` → `Core_queue`,
  `Queue`).
- **The `*_intf` units matter.** Base/Core declare their types in
  `Base__Map_intf` rather than `Base__Map`, so omitting the `_intf` entry
  silently tracks nothing. This has cost real time twice: `Core.Bag.t`
  resolves to `Core__Bag_intf`, not to `Core__Doubly_linked` as the
  `include` suggests, and the stubs agreed with the wrong answer.
- **An auxiliary type is *qualified*, not excluded.** A type declared beside
  a container's own `t` shares its unit, so `type_unit` returns it under the
  submodule it was reached through — `Base__Map.Tree`, not `Base__Map`. The
  catalogue then claims the qualified names it actually describes
  (`Base__Map.Tree` → `Core_map_tree`) and leaves the rest
  (`Core__Doubly_linked.Elt`, `Base__Map.Comparator`) matching nothing.
  Qualification only kicks in when the *unqualified* unit is already in
  `ds_of_type_unit`, so a user module named `Tree` is unaffected —
  `vreplay/tests/cases/user_aux_module_name.ml` is the test.

A catalogue entry's *layout* is a list of layers, root first, and the walker
tells skeleton from user data by the **edge** it arrived through, never by a
block's shape. The pieces, each documented in place in
`vreplay/src/data_structure.mli`:

- `Fixed` for a node of one exact size (`labels` + an `interior` and a
  `payload` bitmask; unmarked fields are bookkeeping and never reach the
  wire), `Cases` when a layer's blocks come in several shapes chosen by tag
  and size, `Array_elements` for a variable-size block.
- Listing several shapes in one `Cases` is **how one layout serves several
  library versions** — Base's AVL `Node` and its weight-balanced successor
  both appear. Do that rather than forking the entry.
- `window` restricts an array layer to its live slots for the structures
  that keep elements in a preallocated buffer with the bounds in the parent
  record, so a wrapped ring still reads in queue order.
- `interior_targets` is for structures that do *not* nest uniformly: a hash
  queue's elements chain through `next` on their own layer while `value`
  steps down to the key/data pair.
- `payload_roles` maps a field **label** (not position) to a `ty` role, which
  is what lets a derived schema attach to the right slot; the label matters
  because a Base map keeps its key in field 1 of a `Node` and field 0 of a
  `Leaf`, calling both `v`.

The last layer repeats once the walk steps past it, which is what makes a
`l`/`r` spine or a bucket chain work. `User` is the one entry with an empty
layout.

Classification is by **provenance**, not by name: an application is an event
iff its function *and* its result type's head constructor were declared in a
unit listed in `ds_table`, read off `val_uid`/`type_uid`, which survives
`Map.Make` application, `open`, `include` and aliasing. Functor parameters
and first-class modules fail closed.

`list`/`array` have predef type constructors and stay uncovered, on purpose.

**A mutable call's roots must be bare identifiers.** `argument_roots` only
takes arguments whose `exp_desc` is `Texp_ident` (deduplicated by path), so
`Hashtbl.set t.id_hash ~key ~data` and `Queue.enqueue t.samples n` emit
**nothing**, while `let q = t.samples in Queue.enqueue q n` emits normally.
It is skip-not-fail by design — a container argument that is a bigger
expression has its own events — but the practical consequence is worth
knowing before debugging a silent dump: a record whose fields are mutable
containers shows its immutable half (results are rooted at the result, and
`t.bids <- Map.set t.bids ~key ~data` is fine) and hides its mutable half.
Bind the field to a local if you need those events.

**2. Values of the program's own types** (`ds_type User`). A `let` whose
bound expression's head type constructor was declared outside the stdlib is
an event in its own right — `let p = { x = 3; y = 4 }` dumps `p`, with no
container call anywhere in the file. `User` is not a container: it has an
empty `layout`, and its shape comes from the schema the instrumentation
derives from the user's type declaration rather than from a hand-written
layout. Three conditions, all deliberate:

- **A named binder.** The root is the `let`'s identifier; anonymous
  subexpressions and record fields emit nothing.
- **`is_user_declared` reads the type *without* `Ctype.expand_head`.**
  Expanding would follow an alias like `type trades = trade list` down to
  predef `list` and reject exactly the declarations worth observing. A bare
  tuple is not a `Tconstr` at all, so it never qualifies.
- **The schema must actually describe the type.** If `root_schema` yields no
  roles (a variant, an abstract type) the binding is skipped — an
  unlabeled block is no better than the numbering this replaces.

So bare `list`/`array`/tuple values are *contents, not subjects*: never
events themselves, drawn only when reached from something that is.
`vreplay/tests/cases/user_types.ml` is the readable statement of all of this,
negatives included.

Because `User` is a `Data_structure.t` constructor, **the interface's
`Snapshot.Ds_type` has to grow it too** before it can read these dumps.

---

## Known broken

**1. An exception unbalances the dump.** The closing `}` is emitted as a
*following* let-binding, so a call that raises never closes its frame. The
interface's reader raises on a dump that doesn't return to depth 0, so any
program using exceptions for control flow (`Not_found`, `Exit`, …) produces
an unreadable dump. Reproduce with a `try ... with` around an instrumented
call. The recommended fix is to carry depth as an explicit event field and
drop closing markers entirely — a truncated dump is then still well formed
and an unwind is just the next record's depth jumping backwards. Re-raising
from a `Texp_try` is the wrong first move: it corrupts the user program's
backtraces. `vreplay/tests/` deliberately has no case for this.

**2. The `-visual-replay` help text is mangled.** `driver/main_args.ml:693`
has a literal newline inside the string, so `ocamlc -help` prints it across
two lines, and the text itself ("Render the txt file for JSIP debugger
tool") no longer describes what the flag does.

**3. `-visual-replay` does not work in the toplevel.** The flag is
registered in all four frontends, but `toplevel/` never goes through
`compile_common` — it types phrases via `Typemod.type_toplevel_phrase`. So
`ocaml -visual-replay` / `ocamlnat -visual-replay` accept the flag without
instrumenting anything. No longer *silent*: since PR #16, `Toploop.prepare`
warns on stderr that the flag is ignored. Actual toplevel instrumentation
remains unimplemented.

**4. `dune build` cannot succeed.** The root `dune` still lists a `vreplay`
module from the stub era (`Error: Module Vreplay doesn't exist`), and none
of the files this project actually edits — `vreplay_instrumentation`, the
`vreplay/src/` library units — appear in **any** dune file, so Merlin/ocamllsp
report "No config found" on exactly the files this project works on. Since
dune is only a Merlin helper here, that's backwards.

### Fixed — don't go looking for these

- *`ocamlc` silently stops relinking* (the `parsing_SOURCES` prefix bug).
  Two false negatives to avoid if you check whether a unit made it into the
  library: `strings` on a `.cma` misses unit names even when they are
  there, and a **bare** `./tools/ocamlobjinfo` dies on its shebang and
  prints nothing, which reads as "absent". The working form is
  `runtime/ocamlrun ./tools/ocamlobjinfo compilerlibs/ocamlcommon.cma`
  and grep for the unit (e.g. `Vreplay_instrumentation`).
- *`wire_external` unreachable.* It lives at the top level of
  `vreplay_instrumentation.ml` now.
- *The dump interleaving with the program's stdout.* Fixed by the dedicated
  sink; `vreplay/tests/cases/stdout_mixed.ml` covers it.
- *Unfiltered instrumentation.* `filter_func` (which returned `true`
  unconditionally) became `classify`, described above.

Also verified working, so don't re-derive it: prepending the
`Tstr_primitive` does **not** break module coercion when the unit has an
`.mli` — tested with a module hiding a value, linked against a second unit.

---

## Conventions

### check-typo

**Style is enforced by `tools/check-typo`**, which CI runs over every file a
PR touches. Hard rules (`CONTRIBUTING.md:119-122`): no trailing whitespace,
no lines over 80 columns, no tabs, ASCII only, newline at EOF.

License headers: new `.ml`/`.mli`/`.c` files normally need the 14-line OCaml
block (copy it from `typing/typecore.ml:1-14`), but **this project's files
are exempted instead** — `.gitattributes:28-37` lists `/vreplay/src/*` (which
covers `vreplay/src/snapshot.c`), both `vreplay_instrumentation` files,
`vreplay/tests/`'s sources and stubs, and `/.claude/*` as
`typo.missing-header=may`. A new project file — or a new project
*directory*, which is the one that gets missed — needs either the header or
a line there. `.md` files are exempt from the header, long-line and
non-ASCII checks (`.gitattributes:79,90`), and `/vreplay/tests/expected/*.dump`
additionally from the long-line and final-newline checks, since it is
byte-exact machine output.

Before committing:

```sh
./tools/check-typo-since 466e585663    # the real upstream base, not trunk
```

**Use the base sha, not `trunk`.** Since the 5.5 rebase, diffing against
`trunk` drags in upstream files the project never touched
(`runtime/caml/mlvalues.h`, `build-aux/`, `Makefile`, …) and buries real
findings under inherited ones. Against `466e585663` the tree is currently
**clean** — any output is yours.

A `make distclean` that leaves files behind will fail CI's clean-tree check.
See "Reading CI" below for the Windows/MSVC rules and the two failures that
are usually not yours.

### Pull requests

The repo was renamed on GitHub to **`ClaraY05/jsip-debugger-compiler`**. The
local `origin` still points at the old `ClaraY05/jsip_debugger.git`, so every
push prints `remote: This repository moved.` — harmless (GitHub redirects),
but use the new name in every `gh` command.

**Never open a PR against upstream `ocaml/ocaml`.** This is a fork and `gh`
will happily default to the parent. Always be explicit:

```sh
gh pr create --repo ClaraY05/jsip-debugger-compiler --base vreplay-main --draft
```

`gh pr edit` fails on a GraphQL `projectCards` deprecation. Use the API
directly instead:

```sh
gh api repos/ClaraY05/jsip-debugger-compiler/pulls/N -X PATCH -F body=@file
gh api repos/ClaraY05/jsip-debugger-compiler/issues/N/labels -X POST \
  -f 'labels[]=no-change-entry-needed'
```

**Every PR needs a `Changes` entry or the `no-change-entry-needed` label.**
The inherited `hygiene.yml` runs upstream's `check-changes-modified.sh` on
every PR, so it is enforced here even though the fork has no upstream
release notes. The label exists in the fork; applying it is usually the
right call.

**Do not modify upstream files** unless the feature genuinely requires it.
The accidental reformats this fork used to carry have now been reverted
(see "Repo hygiene"), so a stray upstream hunk in a diff is *yours*. In
particular avoid editor format-on-save in `runtime/`, `parsing/`, and the
root `dune`.

### Reading CI

The fork inherits upstream's workflows, which means a lot of jobs and a lot
of noise. Three things learned the hard way:

- **Never call a PR green off one job.** `Checks` finishing says nothing
  about the rest of the rollup. Read
  `gh pr view N --json statusCheckRollup,mergeable,mergeStateStatus` and
  wait for blank conclusions to settle before claiming anything.
- **The Windows jobs' most common failure is not yours.** They frequently
  die in *Install Cygwin* on a mirror 500 — infrastructure. Read the log
  before believing it. A genuine MSVC break looks different: one real
  compile failure plus three fail-fast cancellations, so read the first
  job. `runtime/*.c` must stay MSVC-clean (no `ssize_t`, no declarations
  after statements in the old style).
- **`.depend` goes stale after merging someone else's commit**, not only
  after your own edits. Re-run `make alldepend` post-merge and commit it,
  or the dependency check fails on a PR that changed nothing relevant.

### Work in flight

One PR is open against `vreplay-main` and worth knowing about before
starting anything adjacent:

- **#9 (open since July)** adds the component suites under `vreplay/tests/unit/`.

Commit style is informal and mixed (`feat:`/`fix:` alongside freeform).
Match whatever the surrounding history does; don't impose a convention.

### Branches

| Branch | What it is |
|---|---|
| `vreplay-main` | **The integration tip and the PR base.** Also the fork's default branch on GitHub. |
| `trunk` | Pure upstream at `511483454` (5.6.0+dev). Historical fork point only — **not** the current base; see the top of this file. |
| `feat/*`, `fix/*`, `tests/*` | One per PR. Several are open at any time. |

**A long-lived checkout is easily behind `origin/vreplay-main`.** Merged PRs
land on the remote; the local branch does not follow. `git fetch` and
compare before assuming your tree is the tip:

```sh
git rev-list --left-right --count vreplay-main...origin/vreplay-main
```

### Worktrees

Several people and agents work this repo in parallel, so worktrees are
common. Keep them in one place: **`.worktrees/<name>`**, which is already
gitignored.

```sh
git worktree add .worktrees/<name> -b <branch> origin/vreplay-main
```

**Branch from `origin/vreplay-main`, not `trunk`.** `trunk` is pure upstream
— a worktree based on it has none of the project's files, which is a
confusing five minutes if you don't expect it. A fresh worktree also needs
`./configure` before `make` (see Build).

Two caveats:

- Claude Code's own `EnterWorktree` tool creates worktrees under
  `.claude/worktrees/` instead, and that path is not configurable without
  `WorktreeCreate` hooks. Expect to see both locations; it's not a mistake.
- The git stash stack is **shared across all worktrees**. Never use bare
  `git stash` / `git stash pop` — you can pop someone else's work. Use a WIP
  commit, or `git stash push -m "<unique-tag>"` and `git stash apply <sha>`.

Run `git worktree list` before creating one, and `git worktree prune` if you
see an entry marked `prunable`.

---

## Repo hygiene — why `git status` and `git diff` look insane

- **`_install/` is `make install` output and is no longer tracked.** It was
  committed by accident in `610a1c933` — 228 files, ~43 MB, about 97% of
  this fork's diff against upstream — and has since been untracked and
  gitignored. Depending on how the tree was configured, `ocamlc -config` may
  report `_install/lib/ocaml` as its `standard_library`; if so the directory
  must exist on disk (`make install` recreates it). Never check it back in.
  It remains in git *history*, so clone size still reflects it, and a raw
  diff against a pre-cleanup commit still shows all 228 files.
- `parsing/dune`, root `dune`, `dune-project` diffs are ~99% `dune fmt`
  noise; the only real line left adds `vreplay` to a module list. These
  are the last of the accidental upstream churn.
- `.tmp_files/` is the authors' gitignored scratch area.

**Cleaned up in `5ef7e31a1e` (PR #18) — don't go looking for them.** The
507-line no-op reformat of `runtime/caml/mlvalues.h`, the 1-line license
corruption in `parsing/parsetree.mli` (`projet` → `project`), the trailing
whitespace in `parsing/ast_helper.ml`, and the committed 0-byte
`lambda/matching.cmt4e44c0.tmp` are all gone. Against `466e585663` the
non-project files this fork still touches are the three dune files above,
so `git diff 466e585663 HEAD` is now nearly all signal — 155 files, ~8k
lines, and it is worth keeping it that way.

---

## Further reading

- **`.github/README.md`** — the fork's front page: what the flag does,
  quick start, and the inventory of what changed vs upstream. It lives in
  `.github/` because GitHub picks READMEs by location (`.github/` before
  the root) — a root `README.md` loses the tie-break to upstream's
  `README.adoc`, which stays untouched at the root.
- **`vreplay/src/sexp.mli`** — the wire schema and its prose spec. The single
  most important file to read before touching serialization.
- **`vreplay/src/README.md`** — the library's own doc: the catalogue, one entry
  per representation, and the walker's layout vocabulary.
- **`vreplay/tests/README.md`** — what the golden suite checks and covers,
  plus verified end-to-end commands for running the flag by hand (absorbed
  the former `TEST.README.md`).
- `HACKING.adoc` — upstream's build/dev guide.

Deleted in the 2026-08-05 doc refresh (recover from git history at
`3a8a253c40` if their content is needed before it finds a new home):
`README_C_Contributions.md` (the C/GC contract guide — read it from history
before touching `runtime/` or `snapshot.c`), `README_opam_switch.md` (the
`jsip-vreplay` switch setup), and `README_vreplay.md` (its live half, the
dump-sink docs, now lives only in this file and `vreplay/src/vreplay.ml`).
