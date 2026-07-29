#include <stdio.h>
#include "caml/memory.h"
#include "caml/mlvalues.h"

/* takes in a ptr to a c string and writes it out to stdout verbatim

   No prefix, no newline -- framing is the caller's job, and it needs a
   record's {} markers on the same line as the record. Flushed every call so
   the dump stays in order.

   Keep msg in an argument position, never the format position: records will
   eventually be printed source text, which can contain '%'. Note this also
   stops at the first NUL, so a record must not contain one. */
static void my_existing_function(const char *msg)
{
    fprintf(stdout, "%s", msg);
    fflush(stdout);
}

/* defines a callable from ocaml */
CAMLprim value caml_wire_emit(value v_msg)
{
    CAMLparam1(v_msg);
    my_existing_function(String_val(v_msg));
    CAMLreturn(Val_unit);
}
