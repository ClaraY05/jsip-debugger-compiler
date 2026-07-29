#include <stdio.h>
#include "caml/memory.h"
#include "caml/mlvalues.h"

/* The single write path for a -visual-replay dump.

   Everything the instrumentation produces -- the {} frame markers as well as
   the record payloads -- is pushed through here, and the whole string is
   written verbatim: no prefix, no added newline. Framing is the caller's job
   (see [frame_open] / [frame_close] in typing/vreplay_instrumentation.ml),
   because the reader expects a line's frame markers to sit on the same line
   as the payload they belong to.

   The write is flushed immediately. That is what makes the ordering well
   defined: anything that reached the dump through OCaml's own buffered
   stdout channel instead would only appear when that channel is flushed,
   which for a program that never flushes is at exit -- long after every
   record written here.

   [caml_string_length] rather than [strlen]: an OCaml string may contain a
   NUL, and truncating a record at one would silently corrupt the dump. */
CAMLprim value caml_wire_emit(value v_msg)
{
  CAMLparam1(v_msg);
  fwrite(String_val(v_msg), 1, caml_string_length(v_msg), stdout);
  fflush(stdout);
  CAMLreturn(Val_unit);
}
