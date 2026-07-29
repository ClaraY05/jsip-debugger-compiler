#include "caml/mlvalues.h"
#include "caml/memory.h"
#include "caml/alloc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ------------------------------------------------------------------ *
 * Visual-replay heap snapshot walker.
 *
 * OCaml side (see vreplay/vreplay.ml):
 *   type field = Cell of int        (* -> index of an internal cell in this shape *)
 *              | Edge of int        (* -> stable id of a separately-tracked object *)
 *              | Ptr  of nativeint  (* opaque / boundary pointer, address only     *)
 *              | Leaf of string     (* decoded scalar                              *)
 *   type cell  = { addr : nativeint; tag : int; size : int; fields : field array }
 *   external traverse :
 *     (Obj.t * int) array -> Obj.t -> int -> cell array = "caml_wire_traverse"
 *
 * Given [known] (every currently-tracked object paired with its stable id), a
 * [root] to walk, and a pointer [mask] describing which fields of the data
 * structure's node/cell type are structural pointers to follow, we BFS the
 * in-memory representation reachable from [root] and return it as a flat array
 * of cells (index 0 is the root).  For each field we decide, per the rule:
 *
 *   - not a block            -> Leaf (decoded scalar)
 *   - block, in [known]      -> Edge id, STOP (walked at its own event)
 *   - block, no-scan tag     -> Leaf (string/float/opaque bytes)
 *   - block, mask bit set    -> Cell idx (an internal cell of this DS: recurse)
 *   - block, mask bit clear  -> Ptr addr (opaque/boundary pointer, don't follow)
 *
 * GC discipline: the BFS allocates NO OCaml value, so nothing moves during the
 * walk and the raw [value]s cached in [seen] stay valid.  Everything the walk
 * records is plain C data (addresses, ids, decoded strings).  Only afterwards
 * do we build the OCaml result, and that build holds no walked [value]s, so it
 * cannot dangle anything and needs no root bookkeeping.
 * ------------------------------------------------------------------ */

/* ---- a tiny growable array of OCaml [value]s (BFS queue + visited set) ---- */
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
 * tree between tracked boundaries).  Swap for a pointer hash if it ever hurts. */
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

/* Decode a leaf value into a freshly malloc'd C string (freed after the build).
 * Same cases as before: immediates, strings, boxed floats, else structural. */
static char *describe_cstr(value v)
{
    char buf[256];
    if (Is_long(v)) {
        snprintf(buf, sizeof buf, "int:%ld", (long)Long_val(v));
    } else {
        tag_t tag = Tag_val(v);
        if (tag == String_tag)
            snprintf(buf, sizeof buf, "string:%s", String_val(v));
        else if (tag == Double_tag)
            snprintf(buf, sizeof buf, "float:%g", Double_val(v));
        else
            snprintf(buf, sizeof buf, "block(tag=%d,size=%lu)",
                     (int)tag, (unsigned long)Wosize_val(v));
    }
    return strdup(buf);
}

/* ---- C-side record of one cell, filled during the (non-allocating) walk ---- */
enum fkind { F_CELL, F_EDGE, F_PTR, F_LEAF };
typedef struct {
    enum fkind k;
    long   idx;   /* F_CELL / F_EDGE */
    uintnat ptr;  /* F_PTR */
    char  *leaf;  /* F_LEAF (owned) */
} cfield;
typedef struct {
    uintnat addr;
    int     tag;
    mlsize_t size;
    cfield *fields;   /* owned; length nfields */
    mlsize_t nfields;
} ccell;

/* external traverse : (Obj.t * int) array -> Obj.t -> int -> cell array
 *                   = "caml_wire_traverse" */
CAMLprim value caml_wire_traverse(value v_known, value v_root, value v_mask)
{
    CAMLparam3(v_known, v_root, v_mask);
    CAMLlocal4(res, cellv, fldarr, boxed);

    uintnat mask = (uintnat)Long_val(v_mask);

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

    /* An immediate root has no heap cell to walk: return [||]. */
    if (!Is_block(v_root)) {
        free(known);
        CAMLreturn(Atom(0));
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
        c.tag  = (int)Tag_val(v);
        c.size = Wosize_val(v);
        c.fields = NULL;
        c.nfields = 0;

        if (Tag_val(v) < No_scan_tag) {
            mlsize_t n = Wosize_val(v);
            c.nfields = n;
            c.fields = malloc(sizeof(cfield) * (n ? n : 1));
            for (mlsize_t i = 0; i < n; i++) {
                value f = Field(v, i);
                cfield fl;
                if (!Is_block(f)) {
                    fl.k = F_LEAF; fl.leaf = describe_cstr(f);
                } else {
                    long id = known_lookup(known, nk, (uintnat)f);
                    if (id >= 0) {
                        fl.k = F_EDGE; fl.idx = id;
                    } else if (Tag_val(f) >= No_scan_tag) {
                        fl.k = F_LEAF; fl.leaf = describe_cstr(f);
                    } else if (i < sizeof(mask) * 8 && ((mask >> i) & 1u)) {
                        long idx = vec_index_of(&seen, f);
                        if (idx < 0) { idx = (long)seen.len; vec_push(&seen, f); }
                        fl.k = F_CELL; fl.idx = idx;
                    } else {
                        fl.k = F_PTR; fl.ptr = (uintnat)f;
                    }
                }
                c.fields[i] = fl;
            }
        }

        if (ncells == ccap) {
            ccap = ccap ? ccap * 2 : 16;
            cells = realloc(cells, sizeof(ccell) * ccap);
        }
        cells[ncells++] = c;
    }

    /* ---- phase 2: build the OCaml result from pure C data (GC-safe) ---- */
    res = caml_alloc(ncells, 0);
    for (size_t i = 0; i < ncells; i++) {
        ccell *c = &cells[i];
        fldarr = caml_alloc(c->nfields, 0);
        for (mlsize_t j = 0; j < c->nfields; j++) {
            cfield *fl = &c->fields[j];
            switch (fl->k) {
            case F_CELL:
                boxed = caml_alloc(1, 0); Store_field(boxed, 0, Val_long(fl->idx)); break;
            case F_EDGE:
                boxed = caml_alloc(1, 1); Store_field(boxed, 0, Val_long(fl->idx)); break;
            case F_PTR:
                boxed = caml_alloc(1, 2);
                Store_field(boxed, 0, caml_copy_nativeint((intnat)fl->ptr)); break;
            default: /* F_LEAF */
                boxed = caml_alloc(1, 3);
                Store_field(boxed, 0, caml_copy_string(fl->leaf)); break;
            }
            Store_field(fldarr, j, boxed);
        }
        cellv = caml_alloc(4, 0);
        Store_field(cellv, 0, caml_copy_nativeint((intnat)c->addr));
        Store_field(cellv, 1, Val_int(c->tag));
        Store_field(cellv, 2, Val_int((int)c->size));
        Store_field(cellv, 3, fldarr);
        Store_field(res, i, cellv);
    }

    /* ---- cleanup ---- */
    for (size_t i = 0; i < ncells; i++) {
        for (mlsize_t j = 0; j < cells[i].nfields; j++)
            if (cells[i].fields[j].k == F_LEAF) free(cells[i].fields[j].leaf);
        free(cells[i].fields);
    }
    free(cells);
    free(seen.data);
    free(known);

    CAMLreturn(res);
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
