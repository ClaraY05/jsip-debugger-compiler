#include <stdio.h>
#include "caml/memory.h"
#include "caml/mlvalues.h"

/* takes in a ptr to a c string and writes it to stdout verbatim

   Verbatim matters: no "[wire] " prefix and no added newline. Framing is the
   caller's job (see [frame_open] / [frame_close] in
   typing/vreplay_instrumentation.ml), because the reader expects a record's
   frame markers to sit on the same line as the record itself, and the record
   terminates itself.

   The write is flushed immediately, and that is what makes ordering well
   defined. Anything reaching the dump through OCaml's own buffered stdout
   channel instead would only appear when that channel is flushed -- for a
   program that never flushes, at exit, long after every record written here.

   Caveat: this takes a NUL-terminated string, so a record containing an
   embedded NUL would be truncated. Not reachable today (records are printed
   source text), but it needs a length parameter if that ever changes. */
static void my_existing_function(const char *msg)
{
    fputs(msg, stdout);
    fflush(stdout);
}

/* defines a callable from ocaml */
CAMLprim value caml_wire_emit(value v_msg)
{
    CAMLparam1(v_msg);
    my_existing_function(String_val(v_msg));
    CAMLreturn(Val_unit);
}
