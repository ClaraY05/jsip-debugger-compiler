#include "caml/mlvalues.h"
#include "caml/memory.h"
#include <stdio.h>

// takes in a ptr to a c string and prints it out to stdout
static void my_existing_function(const char *msg)
{
    fprintf(stdout, "[wire] %s\n", msg);
    fflush(stdout);
}

// defines a callable from ocaml
CAMLprim value caml_wire_emit(value v_msg)
{
    CAMLparam1(v_msg);
    my_existing_function(String_val(v_msg));
    CAMLreturn(Val_unit);
}