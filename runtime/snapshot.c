#include "caml/mlvalues.h"
#include "caml/memory.h"
#include "caml/alloc.h"
#include "caml/custom.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ------------------------------------------------------------------ *
 * Visual-replay heap snapshot walker.
 *
 * OCaml side (see vreplay/sexp.ml, re-exported by vreplay.ml --
 * constructor and field ORDER are the contract):
 *   type block =
 *     | Int of int | Float of float | String of string
 *     | Int32 of int32 | Int64 of int64 | Nativeint of nativeint
 *     | Float_array of float list | Address of nativeint
 *   type node  = { virtual_address : nativeint
 *                ; block : (string * block) list; children : node list }
 *   external traverse :
 *     Obj.t -> (Obj.t * int) array -> string array -> int -> node
 *     = "caml_wire_traverse"
 * The DS type itself stays on the OCaml side ([Vreplay.t] pairs it with
 * the root node once); the walker doesn't need it.
 *
 * Given a [root] to walk, [known] (every currently-tracked
 * object paired with its stable id, from the weak registry), and the DS's
 * field [labels] + [mask] (which fields carry meaningful information: the
 * child pointers and the key/value positions), we BFS the in-memory
 * representation reachable from [root] and return it as a tree of [node]s,
 * each node pointing at its children.  Unmasked fields are dropped.  A
 * masked field becomes, per the rule:
 *
 *   - not a block            -> Int (unboxed int/char/bool/constant ctor)
 *   - block, in [known]      -> Address, STOP (walked at its own events)
 *   - block, no-scan tag     -> a leaf, decoded per the manual's
 *                               "Representation of OCaml data types":
 *                               Double_tag -> Float, String_tag -> String,
 *                               Custom_tag -> Int32/Int64/Nativeint,
 *                               Double_array_tag -> Float_array,
 *                               anything else -> Address (opaque)
 *   - block otherwise        -> a child node: BFS into it
 *     (tuples, records and non-constant constructors land here -- they
 *     are zero-tagged scannable blocks)
 *
 * GC discipline: the BFS allocates NO OCaml value, so nothing moves during
 * the walk and the raw [value]s cached in [seen] stay valid.  Everything
 * the walk records is plain C data (addresses, decoded leaves, label
 * copies).  Only afterwards do we build the OCaml nodes, and that build
 * holds no walked [value]s, so it cannot dangle anything.  A shared block
 * is discovered once (one node, several parents); the OCaml printer copes
 * with the resulting DAG.
 * ------------------------------------------------------------------ */

/* ---- tiny growable array of OCaml [value]s: BFS queue + visited set ---- */
typedef struct { value *data; size_t len, cap; } vec;

static void vec_push(vec *v, value x)
{
    if (v->len == v->cap) {
        v->cap = v->cap ? v->cap * 2 : 16;
        v->data = realloc(v->data, v->cap * sizeof(value));
    }
    v->data[v->len++] = x;
}

/* Discovery order in [seen] IS a cell's intra-snapshot index.  Linear scan;
 * fine for the modestly-sized internal representations we walk (a persistent
 * tree between tracked boundaries).  Swap for a hash if it ever hurts. */
static long vec_index_of(const vec *v, value x)
{
    for (size_t i = 0; i < v->len; i++)
        if (v->data[i] == x) return (long)i;
    return -1;
}

/* ---- pointer -> stable id lookup, built once from [known] ---- */
typedef struct { uintnat ptr; long id; } known_ent;

static int known_cmp(const void *a, const void *b)
{
    uintnat pa = ((const known_ent *)a)->ptr, pb = ((const known_ent *)b)->ptr;
    return (pa < pb) ? -1 : (pa > pb) ? 1 : 0;
}

/* Binary search the sorted [arr]; return the id for pointer [p], or -1. */
static long known_lookup(const known_ent *arr, size_t n, uintnat p)
{
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (arr[mid].ptr < p) lo = mid + 1; else hi = mid;
    }
    if (lo < n && arr[lo].ptr == p) return arr[lo].id;
    return -1;
}

/* Label for field [i]: the DS labels when this cell's size matches the label
 * count (i.e. it IS the DS's internal node), else the field index -- masked
 * value positions can lead into other block shapes (lists, tuples) whose
 * fields the DS labels don't describe.  Copied to C during the walk so the
 * result build can't be reading a string the GC just moved. */
static char *label_for(value v_labels, mlsize_t nlabels, mlsize_t cell_size,
                       mlsize_t i)
{
    if (cell_size == nlabels && i < nlabels)
        return strdup(String_val(Field(v_labels, i)));
    else {
        char buf[32];
        snprintf(buf, sizeof buf, "%lu", (unsigned long)i);
        return strdup(buf);
    }
}

/* ---- C-side record of one retained (masked) field ---- */
enum fkind {
    F_CHILD, F_INT, F_FLOAT, F_STRING, F_INT32, F_INT64,
    F_NATIVEINT, F_FLOAT_ARRAY, F_ADDR
};
typedef struct {
    enum fkind k;
    long     idx;    /* F_CHILD: index of the child cell */
    intnat   ival;   /* F_INT */
    double   dval;   /* F_FLOAT */
    char    *sval;   /* F_STRING (owned; may contain NULs) */
    size_t   slen;
    int32_t  i32;    /* F_INT32 */
    int64_t  i64;    /* F_INT64 */
    intnat   inat;   /* F_NATIVEINT */
    double  *farr;   /* F_FLOAT_ARRAY (owned) */
    size_t   flen;
    uintnat  ptr;    /* F_ADDR */
    char    *label;  /* owned */
} cfield;
typedef struct {
    uintnat addr;
    cfield *fields;    /* owned; only the masked fields, in field order */
    mlsize_t nfields;
} ccell;

/* Decode one leaf (non-child, non-boundary) field into plain C data, per
 * the manual's representation tables.  Runs during the walk: allocates no
 * OCaml value.  Immediates -- int, char, bool, unit, constant
 * constructors -- share one representation and all land in F_INT. */
static void capture_leaf(cfield *fl, value f)
{
    if (Is_long(f)) { fl->k = F_INT; fl->ival = Long_val(f); return; }
    switch (Tag_val(f)) {
    case Double_tag:
        fl->k = F_FLOAT; fl->dval = Double_val(f); return;
    case String_tag: {                     /* string and bytes alike */
        mlsize_t len = caml_string_length(f);
        fl->k = F_STRING;
        fl->slen = len;
        fl->sval = malloc(len ? len : 1);
        memcpy(fl->sval, Bytes_val(f), len);
        return;
    }
    case Double_array_tag: {               /* float array / float record */
        mlsize_t n = Wosize_val(f) / Double_wosize;
        fl->k = F_FLOAT_ARRAY;
        fl->flen = n;
        fl->farr = malloc(sizeof(double) * (n ? n : 1));
        for (mlsize_t i = 0; i < n; i++)
            fl->farr[i] = Double_flat_field(f, i);
        return;
    }
    case Custom_tag: {
        /* int32/int64/nativeint carry the runtime's own custom ops; their
         * identifiers ("_i"/"_j"/"_n") are stable, they're the marshalling
         * format's names for these types. */
        const char *id = Custom_ops_val(f)->identifier;
        if (strcmp(id, "_i") == 0) {
            fl->k = F_INT32; fl->i32 = Int32_val(f); return;
        }
        if (strcmp(id, "_j") == 0) {
            fl->k = F_INT64; fl->i64 = Int64_val(f); return;
        }
        if (strcmp(id, "_n") == 0) {
            fl->k = F_NATIVEINT; fl->inat = Nativeint_val(f); return;
        }
        break;                             /* unknown custom: opaque */
    }
    default:
        break;                             /* Abstract_tag etc.: opaque */
    }
    fl->k = F_ADDR;
    fl->ptr = (uintnat)f;
}

/* Allocate the OCaml [block] value for one captured field.  Constructor
 * numbering follows sexp.ml's declaration order: Int=0 Float=1 String=2
 * Int32=3 Int64=4 Nativeint=5 Float_array=6 Address=7. */
static value alloc_block(const cfield *fl)
{
    CAMLparam0();
    CAMLlocal3(bx, lst, cell);
    switch (fl->k) {
    case F_INT:
        bx = caml_alloc(1, 0);
        Store_field(bx, 0, Val_long(fl->ival));
        break;
    case F_FLOAT:
        bx = caml_alloc(1, 1);
        Store_field(bx, 0, caml_copy_double(fl->dval));
        break;
    case F_STRING:
        bx = caml_alloc(1, 2);
        Store_field(bx, 0,
                    caml_alloc_initialized_string(fl->slen, fl->sval));
        break;
    case F_INT32:
        bx = caml_alloc(1, 3);
        Store_field(bx, 0, caml_copy_int32(fl->i32));
        break;
    case F_INT64:
        bx = caml_alloc(1, 4);
        Store_field(bx, 0, caml_copy_int64(fl->i64));
        break;
    case F_NATIVEINT:
        bx = caml_alloc(1, 5);
        Store_field(bx, 0, caml_copy_nativeint(fl->inat));
        break;
    case F_FLOAT_ARRAY:
        lst = Val_emptylist;
        for (size_t i = fl->flen; i-- > 0; ) {
            cell = caml_alloc(2, 0);
            Store_field(cell, 0, caml_copy_double(fl->farr[i]));
            Store_field(cell, 1, lst);
            lst = cell;
        }
        bx = caml_alloc(1, 6);
        Store_field(bx, 0, lst);
        break;
    default:                               /* F_ADDR */
        bx = caml_alloc(1, 7);
        Store_field(bx, 0, caml_copy_nativeint((intnat)fl->ptr));
        break;
    }
    CAMLreturnT(value, bx);
}

/* external traverse :
 *   Obj.t -> (Obj.t * int) array -> string array -> int -> node
 *   = "caml_wire_traverse" */
CAMLprim value caml_wire_traverse(value v_root, value v_known,
                                  value v_labels, value v_mask)
{
    CAMLparam4(v_root, v_known, v_labels, v_mask);
    CAMLlocal5(nodes, nodev, lst, ent, bx);
    CAMLlocal1(cons);

    uintnat mask = (uintnat)Long_val(v_mask);
    mlsize_t nlabels = Wosize_val(v_labels);

    /* Build the sorted pointer->id table from [known].  Reads raw pointers of
     * the known objects; no allocation, so they can't move. */
    mlsize_t nk = Is_block(v_known) ? Wosize_val(v_known) : 0;
    known_ent *known = nk ? malloc(sizeof(known_ent) * nk) : NULL;
    for (mlsize_t k = 0; k < nk; k++) {
        value pair = Field(v_known, k);
        known[k].ptr = (uintnat)Field(pair, 0);
        known[k].id  = (long)Long_val(Field(pair, 1));
    }
    if (nk) qsort(known, nk, sizeof(known_ent), known_cmp);

    /* An immediate root has no heap cell to walk.  Not reachable from
     * vreplay.ml (it skips immediates); return a lone leaf node anyway
     * rather than crash. */
    if (!Is_block(v_root)) {
        cfield fl = {0};
        capture_leaf(&fl, v_root);         /* immediate -> F_INT */
        bx = alloc_block(&fl);
        ent = caml_alloc(2, 0);            /* ("0", Int _) */
        Store_field(ent, 0, caml_copy_string("0"));
        Store_field(ent, 1, bx);
        cons = caml_alloc(2, 0);
        Store_field(cons, 0, ent);
        Store_field(cons, 1, Val_emptylist);
        nodev = caml_alloc(3, 0);
        Store_field(nodev, 0, caml_copy_nativeint(0));
        Store_field(nodev, 1, cons);
        Store_field(nodev, 2, Val_emptylist);
        free(known);
        CAMLreturn(nodev);
    }

    /* ---- phase 1: BFS, no OCaml allocation ---- */
    vec seen = {0};
    ccell *cells = NULL;
    size_t ncells = 0, ccap = 0;

    vec_push(&seen, v_root);   /* root is cell 0 */
    for (size_t head = 0; head < seen.len; head++) {
        value v = seen.data[head];
        ccell c;
        c.addr = (uintnat)v;
        c.fields = NULL;
        c.nfields = 0;

        if (Tag_val(v) < No_scan_tag) {
            mlsize_t n = Wosize_val(v);
            c.fields = malloc(sizeof(cfield) * (n ? n : 1));
            for (mlsize_t i = 0; i < n; i++) {
                if (!(i < sizeof(mask) * 8 && ((mask >> i) & 1u)))
                    continue;                     /* unmasked: dropped */
                value f = Field(v, i);
                cfield fl = {0};
                fl.label = label_for(v_labels, nlabels, n, i);
                if (!Is_block(f)) {
                    capture_leaf(&fl, f);
                } else {
                    long id = known_lookup(known, nk, (uintnat)f);
                    if (id >= 0) {
                        fl.k = F_ADDR;            /* registry boundary */
                        fl.ptr = (uintnat)f;
                    } else if (Tag_val(f) >= No_scan_tag) {
                        capture_leaf(&fl, f);
                    } else {
                        long idx = vec_index_of(&seen, f);
                        if (idx < 0) {
                            idx = (long)seen.len;
                            vec_push(&seen, f);
                        }
                        fl.k = F_CHILD;
                        fl.idx = idx;
                    }
                }
                c.fields[c.nfields++] = fl;
            }
        }

        if (ncells == ccap) {
            ccap = ccap ? ccap * 2 : 16;
            cells = realloc(cells, sizeof(ccell) * ccap);
        }
        cells[ncells++] = c;
    }

    /* ---- phase 2: build the OCaml nodes from pure C data (GC-safe).
     * Pass A allocates every node with children = [] into [nodes] (an OCaml
     * array, so they stay rooted); pass B backpatches each children list
     * with Store_field.  Child indices can point anywhere in [cells] (a
     * shared block is discovered once), so patching after all nodes exist
     * handles any DAG. ---- */
    nodes = caml_alloc(ncells, 0);
    for (size_t i = 0; i < ncells; i++) {
        ccell *c = &cells[i];
        /* block list, built back to front so it reads in field order */
        lst = Val_emptylist;
        for (mlsize_t j = c->nfields; j-- > 0; ) {
            cfield *fl = &c->fields[j];
            if (fl->k == F_CHILD) continue;
            bx = alloc_block(fl);
            ent = caml_alloc(2, 0);
            Store_field(ent, 0, caml_copy_string(fl->label));
            Store_field(ent, 1, bx);
            cons = caml_alloc(2, 0);
            Store_field(cons, 0, ent);
            Store_field(cons, 1, lst);
            lst = cons;
        }
        nodev = caml_alloc(3, 0);
        Store_field(nodev, 0, caml_copy_nativeint((intnat)c->addr));
        Store_field(nodev, 1, lst);               /* block */
        Store_field(nodev, 2, Val_emptylist);     /* children: pass B */
        Store_field(nodes, i, nodev);
    }
    for (size_t i = 0; i < ncells; i++) {
        ccell *c = &cells[i];
        lst = Val_emptylist;
        for (mlsize_t j = c->nfields; j-- > 0; ) {
            cfield *fl = &c->fields[j];
            if (fl->k != F_CHILD) continue;
            cons = caml_alloc(2, 0);
            Store_field(cons, 0, Field(nodes, fl->idx));
            Store_field(cons, 1, lst);
            lst = cons;
        }
        Store_field(Field(nodes, i), 2, lst);
    }

    /* ---- cleanup ---- */
    for (size_t i = 0; i < ncells; i++) {
        for (mlsize_t j = 0; j < cells[i].nfields; j++) {
            cfield *fl = &cells[i].fields[j];
            if (fl->k == F_STRING) free(fl->sval);
            if (fl->k == F_FLOAT_ARRAY) free(fl->farr);
            free(fl->label);
        }
        free(cells[i].fields);
    }
    free(cells);
    free(seen.data);
    free(known);

    CAMLreturn(Field(nodes, 0));
}

/* ------------------------------------------------------------------ *
 * Frame markers.  The instrumentation brackets every event with "{" / "}"
 * via [__wire_emit] (see typing/vreplay_instrumentation.ml); the reader sums
 * them to recover call depth.
 *
 * Writes [msg] verbatim -- no prefix, no newline -- since framing is the
 * caller's job and a record's {} markers must land on the same line as the
 * record.  Flushed every call so the dump stays in order.
 *
 * Keep msg in an argument position, never the format position: records may be
 * printed source text containing '%'.  This also stops at the first NUL, so a
 * record must not contain one.
 * ------------------------------------------------------------------ */
static void my_existing_function(const char *msg)
{
    fprintf(stdout, "%s", msg);
    fflush(stdout);
}

/* external __wire_emit : string -> unit = "caml_wire_emit" */
CAMLprim value caml_wire_emit(value v_msg)
{
    CAMLparam1(v_msg);
    my_existing_function(String_val(v_msg));
    CAMLreturn(Val_unit);
}
