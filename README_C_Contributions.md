# Writing C in the OCaml Compiler Tree

A practical introduction to adding C code inside a fork of the OCaml compiler, and
making it callable from OCaml.

This describes the layout of OCaml 4.14 / 5.x. Older forks (pre-4.10) split the
runtime into `byterun/` and `asmrun/` instead of a single `runtime/`. Wherever this
guide gives a filename, check it against your own tree before trusting it — the build
system moves around between releases more than the C API does.

---

## 1. The lay of the land

```
runtime/              the C runtime: GC, allocator, bytecode interpreter, primitives
runtime/caml/*.h      headers — mlvalues.h and memory.h are the two you'll live in
stdlib/               the OCaml standard library; full of `external` declarations
                      that point at names defined in runtime/
otherlibs/            optional libraries with their own C stubs (unix, str,
                      runtime_events) — good templates for "a C library, not the runtime"
lambda/ bytecomp/     the compiler proper. All OCaml. Almost never needs C.
typing/ asmcomp/
tools/                ocamlobjinfo, ocamldep, etc.
testsuite/            where your new behaviour should get a test
```

Two useful reference points inside `runtime/`:

- `runtime/sys.c` — a plain, readable file full of ordinary primitives. Good model
  for "I want to expose a C function to OCaml."
- `runtime/ints.c` — shows boxing/unboxing and the `[@@unboxed]` conventions.

If your fork has a `HACKING.adoc` at the root, read it; it documents build targets
specific to that version.

---

## 2. Where should your C code live?

Three options, in increasing order of isolation. Pick deliberately — moving later is
annoying.

### (a) In `runtime/`

Always present, no link flags anywhere, and — importantly — automatically registered
in the bytecode primitive table. This is the right choice when your code needs to
touch GC internals, hook allocation, or be callable from *every* program the compiler
produces without the user opting in.

Cost: it's now part of the core runtime, so it must be portable (Windows too),
dependency-free, and it bloats every binary.

### (b) As a library under `otherlibs/`

A separate `.cmxa` with its own stubs, linked only by programs that ask for it. Much
cleaner if your code is optional. Copy the Makefile of a small existing one.

Cost: bytecode users need either a shared stub library (`dllfoo.so`) or `-custom`,
because your primitives are *not* in the builtin table.

### (c) Outside the tree entirely

If your C doesn't need compiler internals, don't put it in the compiler at all. A
normal stub library built with `ocamlmklib` is far less friction.

For an instrumentation/debugging project that wants to observe values as the program
runs, **(a)** is usually correct: you need to be inside the runtime to see the heap,
and you want it available unconditionally.

---

## 3. Anatomy of a primitive

The C side:

```c
#define CAML_INTERNALS            /* only if you include internal headers */

#include "caml/mlvalues.h"
#include "caml/memory.h"
#include "caml/alloc.h"
#include "caml/fail.h"

CAMLprim value caml_wire_emit(value v_payload)
{
  CAMLparam1(v_payload);

  my_existing_c_function(String_val(v_payload));

  CAMLreturn(Val_unit);
}
```

The OCaml side:

```ocaml
external wire_emit : string -> unit = "caml_wire_emit"
```

Non-negotiable conventions:

- **`CAMLprim`**, not `value`. The build scans for this literal token.
- **Name it `caml_something`**, all lowercase. See §5 — uppercase letters in the name
  will silently break bytecode linking.
- **One line.** `CAMLprim value caml_wire_emit(value v)` must have the return type and
  name on the same source line.

### Arity above 5

Native and bytecode calling conventions diverge, so you write two entry points:

```c
CAMLprim value caml_thing_native(value a, value b, value c,
                                 value d, value e, value f)
{ ... }

CAMLprim value caml_thing_bytecode(value * argv, int argn)
{
  return caml_thing_native(argv[0], argv[1], argv[2],
                           argv[3], argv[4], argv[5]);
}
```

```ocaml
external thing : ... = "caml_thing_bytecode" "caml_thing_native"
```

Both names get registered; the bytecode one is what the interpreter looks up.

---

## 4. The GC contract — read this part twice

This is where essentially all runtime bugs come from. The OCaml GC is **moving**: a
minor collection relocates young blocks. Any `value` you hold in a C local is invisible
to the GC unless you register it.

**Rule 1 — register your parameters.**

```c
CAMLparam2(v_a, v_b);      /* CAMLparam0() if there are none */
```

**Rule 2 — register your locals.**

```c
CAMLlocal2(v_result, v_tmp);
```

These go immediately after the `CAMLparam` line, before any statement.

**Rule 3 — return through the macro.**

```c
CAMLreturn(v_result);      /* CAMLreturn0 for a void C function */
```

Every exit path. A bare `return` leaves the root registry corrupted and you will get a
crash somewhere completely unrelated, minutes later.

**Rule 4 — more than five.** `CAMLparam` and `CAMLlocal` come in arities 0–5. Beyond
that, chain with `CAMLxparam*` / `CAMLxlocal*`:

```c
CAMLparam5(a, b, c, d, e);
CAMLxparam2(f, g);
```

**Rule 5 — never cache a pointer across an allocation.**

```c
/* WRONG */
const char *s = String_val(v_str);
value v_new = caml_alloc(3, 0);      /* may move v_str */
use(s);                              /* dangling */
```

Re-derive the pointer after every allocation point.

**Rule 6 — mutating a field needs a write barrier.**

```c
Store_field(v_block, 2, v_new);   /* not: Field(v_block, 2) = v_new; */
```

`Field(...) = ...` is only safe for a block you allocated with `caml_alloc_small` and
are still initialising, before any allocation can intervene. When in doubt, use
`Store_field`. For a standalone `value` location, `caml_modify(&loc, v)`.

**What counts as an allocation point?** `caml_alloc*`, `caml_copy_string`,
`caml_copy_double`, `caml_copy_int64`, raising an exception, calling back into OCaml,
and anything that calls those transitively. Assume any runtime function allocates
unless you've checked.

**The escape hatch.** If your function genuinely never allocates, never raises, and
never calls back into OCaml, you can skip the macros entirely and add `[@@noalloc]`
to the `external` declaration. This makes the call much cheaper. Be honest about it —
`[@@noalloc]` on a function that allocates is a memory-corruption bug, not a
performance hint.

---

## 5. Registering the primitive (the part that bites people)

For **native code** there's nothing to do: the linker resolves `caml_wire_emit` by
symbol out of `libasmrun.a`.

For **bytecode**, primitives are resolved *by name* through a table. The build
generates it:

1. A `sed` script scans the runtime `.c` files for lines matching roughly
   `^CAMLprim value \([a-z0-9_]*\)` and writes the names, sorted, to
   `runtime/primitives`.
2. `runtime/prims.c` is generated from that file, containing `caml_builtin_cprim[]`
   and `caml_names_of_builtin_cprim[]`.

Consequences you need to internalise:

- **The name must match `[a-z0-9_]+`.** `caml_wireEmit` will not be picked up. The
  failure mode is a link-time *"unavailable primitive"* error with no hint about why.
- **`CAMLprim value name(` must be on one line**, unindented, at the start of the line.
- **Stale `runtime/primitives` files cause phantom failures.** If you added a
  primitive and bytecode still can't find it, `rm runtime/primitives runtime/prims.c`
  and rebuild before debugging anything else.

To add a new `.c` file to the runtime, add it to the source lists in
`runtime/Makefile`. Grep for a neighbour (`sys.c`, say) to make sure you catch *every*
variable that mentions it — there are usually separate bytecode and native lists, and
missing one produces a link error only in the variant you didn't test.

---

## 6. Building

Initial setup, keeping the install out of the way of any system OCaml:

```sh
./configure --prefix="$PWD/_install"
make -j8 world.opt
```

- `make world` — bytecode compiler and stdlib
- `make world.opt` — the above plus native compiler
- `make install` — into `--prefix`

After editing runtime C, `make -j8 world.opt` again; it's incremental. If you *added*
a primitive, delete `runtime/primitives` first (§5).

**Bootstrapping.** Adding a primitive does not require a bootstrap: `boot/ocamlc` runs
on the freshly built `runtime/ocamlrun`, so the new primitive is available immediately
to compiler sources. You only need `make bootstrap` when you change the compiler in a
way that makes it depend on a *language or bytecode format* feature the old compiler
doesn't have. If your fork's version ships a prebuilt `boot/ocamlrun`, that changes —
check before assuming.

**Using your build.** Either `make install` and put `_install/bin` on `PATH`, or point
an opam switch at the tree. Don't mix your fork's `.cmi` files with a system OCaml's;
the magic numbers will catch you, but the error message won't be friendly.

---

## 7. Debugging your C

**The debug runtime is the single highest-value tool here.** It enables `CAMLassert`,
poisons freed and uninitialised memory with recognisable patterns, and validates the
root registry.

```sh
ocamlopt -runtime-variant d -o prog prog.ml
```

For bytecode, run the program under `ocamlrund` directly:

```sh
./runtime/ocamlrund ./ocamlc.byte ...
```

**Shake out missing `CAMLparam` calls by making the GC run constantly.** A tiny minor
heap turns a once-a-week heisenbug into a reliable crash:

```sh
OCAMLRUNPARAM='s=4k,v=1' ./prog
```

`s` is the minor heap size in words; `v` is GC verbosity. The full flag list is parsed
in `runtime/startup_aux.c` — read it there rather than trusting any summary.

**Under gdb**, useful things to inspect by hand:

```c
Is_block(v)      /* pointer, vs. an immediate integer */
Is_long(v)       /* immediate; the real value is Long_val(v) */
Wosize_val(v)    /* size in words, from the header */
Tag_val(v)       /* what kind of block */
Field(v, i)      /* i-th field */
```

**Tags worth memorising**, since you'll be reading them constantly:

| Tag | Meaning |
|-----|---------|
| `0`–`245` | ordinary variant / record / tuple; tag = constructor index |
| `246` `Lazy_tag` | unforced lazy |
| `247` `Closure_tag` | closure |
| `248` `Object_tag` | object |
| `249` `Infix_tag` | inner closure of a mutually-recursive set |
| `250` `Forward_tag` | forwarding pointer (forced lazy, etc.) |
| `251` `Abstract_tag` | opaque; GC does not scan |
| `252` `String_tag` | string or bytes |
| `253` `Double_tag` | boxed float |
| `254` `Double_array_tag` | flat float array |
| `255` `Custom_tag` | custom block with an operations struct |

Everything at or above `No_scan_tag` (251) is not traversed by the GC. If you're
walking the heap to visualise data structures, that boundary is the one that matters:
below it, `Field(v, i)` for `i < Wosize_val(v)` is always a valid `value`; at or above
it, the contents are raw bytes and reading them as values is a crash waiting to happen.

---

## 8. Going the other direction: C calling OCaml

Register the closure from OCaml:

```ocaml
let () = Callback.register "wire_handler" (fun s -> print_string s)
```

Look it up and call it from C:

```c
static const value * handler = NULL;

void notify(const char *msg)
{
  if (handler == NULL)
    handler = caml_named_value("wire_handler");
  if (handler != NULL)
    caml_callback(*handler, caml_copy_string(msg));
}
```

The `value *` returned by `caml_named_value` is a global root and is safe to cache
indefinitely. The `value` it points at is not — always dereference freshly.

Caveats: `caml_callback` allocates and can raise (use `caml_callback_exn` if you need
to handle that in C). On OCaml 5 the calling thread must hold the domain lock; a
foreign thread must call `caml_c_thread_register` first and wrap OCaml calls in
`caml_acquire_runtime_system` / `caml_release_runtime_system`.

Hooks are the other mechanism worth knowing: the runtime exposes function pointers
(`caml_scan_roots_hook` and friends) that you can chain onto to observe GC events.
Always save and call the previous value rather than overwriting.

---

## 9. Testing

Tests live in `testsuite/tests/<area>/`. A test is typically a `.ml` file plus a
`.reference` file holding expected stdout, with a comment block at the top declaring
how to run it.

```sh
make -C testsuite all           # everything
make -C testsuite parallel      # everything, faster
```

Running a single directory is usually `make -C testsuite one DIR=tests/<area>` — check
`testsuite/Makefile` in your fork for the exact spelling.

Add a test for anything that touches the GC. "It worked when I ran it" is not evidence
in a system with a moving collector.

---

## 10. Worked example, end to end

Goal: expose a C function `caml_wire_emit : string -> unit` to all OCaml code.

1. Create `runtime/wire.c`:

   ```c
   #define CAML_INTERNALS

   #include "caml/mlvalues.h"
   #include "caml/memory.h"

   CAMLprim value caml_wire_emit(value v_payload)
   {
     CAMLparam1(v_payload);
     fputs(String_val(v_payload), stderr);
     CAMLreturn(Val_unit);
   }
   ```

2. Add `wire.c` to the C source lists in `runtime/Makefile` — every list that mentions
   `sys.c`.

3. `rm -f runtime/primitives runtime/prims.c && make -j8 world.opt`

4. Confirm registration:

   ```sh
   grep caml_wire_emit runtime/primitives
   ```

   No output means go back to §5.

5. Declare it wherever you want it visible. For universal availability, add to a
   stdlib module:

   ```ocaml
   external wire_emit : string -> unit = "caml_wire_emit"
   ```

6. Test both backends. `ocamlopt` and `ocamlc` fail differently and a primitive that
   works native can be entirely unlinked in bytecode.

---

## 11. Pitfall checklist

Work down this list before deep-diving on any runtime crash:

- [ ] Every `value` parameter in `CAMLparam*`?
- [ ] Every `value` local in `CAMLlocal*`?
- [ ] Every return path through `CAMLreturn`?
- [ ] Any `String_val` / `Bytes_val` pointer cached across an allocation?
- [ ] Field mutation using `Store_field` / `caml_modify`?
- [ ] `[@@noalloc]` on anything that can actually allocate or raise?
- [ ] Primitive name all lowercase, `CAMLprim value ...` on one line?
- [ ] `runtime/primitives` regenerated after adding it?
- [ ] New `.c` file added to *all* the relevant Makefile variables?
- [ ] Tested under `-runtime-variant d` with `OCAMLRUNPARAM='s=4k'`?
- [ ] Tested in both bytecode and native?

---

## 12. Further reading

- `runtime/caml/mlvalues.h` — value representation, tags, accessors. The single most
  useful file in the tree.
- `runtime/caml/memory.h` — the GC macros, with the contract documented in comments.
- The OCaml manual, "Interfacing C with OCaml" — the authoritative statement of the
  rules in §4.
- `runtime/sys.c`, `runtime/ints.c` — realistic examples to imitate.
- `otherlibs/unix/` — a full example of the "library with stubs" pattern from §2(b).