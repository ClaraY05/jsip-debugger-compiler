#include "caml/mlvalues.h"
#include "caml/memory.h"
#include "caml/alloc.h"
#include "caml/custom.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#endif

/* ------------------------------------------------------------------ *
 * Visual-replay heap snapshot walker.
 *
 * OCaml side (see vreplay/sexp.ml, re-exported by vreplay.ml --
 * constructor and field ORDER are the contract):
 *   type block =
 *     | Int of int | Float of float | String of string
 *     | Int32 of int32 | Int64 of int64 | Nativeint of nativeint
 *     | Float_array of float list | Address of nativeint | Id of int
 *     | Child
 *   type node  = { id : int; virtual_address : nativeint
 *                ; block : (string * block) list; children : node list }
 *   type flat_shape = { tag : int; labels : string array
 *                     ; interior : int; payload : int }
 *   type flat_layer = { shapes : flat_shape array; is_array : bool
 *                     ; elements_payload : bool; windowed : bool
 *                     ; win_start : int; win_start_offset : int
 *                     ; win_length : int; win_mask : int
 *                     ; win_newest_first : bool }
 *   external traverse :
 *     Obj.t -> (Obj.t * int * string) array -> (Obj.t * int) array
 *     -> int * int
 *     -> flat_layer array
 *        * (string array * int array * int) array
 *        * int array array array
 *        * int
 *     -> node * (int * nativeint * string) array * (int * int) array
 *     = "caml_wire_traverse"
 * The DS type itself stays on the OCaml side ([Vreplay.t] pairs it with
 * the root node once); the walker doesn't need it.  The second component
 * of the result echoes [known] -- the live weak registry -- as
 * (id, address, name) triples captured before any allocation, so the
 * addresses are exactly the ones the nodes record.  The name ("" =
 * anonymous) rides along verbatim: strdup'd in the same no-allocation
 * window, echoed back with its entry.
 *
 * Every dumped block carries a wire id, unique across the whole dump:
 * the root's is the fourth argument's first component (its registry
 * id), and each newly discovered cell takes the next sequential id
 * starting at the second component ([next_id]).  The third argument is
 * the MEMBER TABLE -- every block an earlier event already defined, as
 * (value, id) pairs (the OCaml side seeds it with the remembered
 * members of immutable structures plus the live registry roots).  A
 * field that hits the table becomes [Id] and the walk stops there; a
 * root that hits it collapses to a REVISIT STUB (same id, current
 * address, empty block and children).  So each block is defined at
 * most once, ever, and (Id n) means "the block defined as id n".  The
 * result's third component gives each new cell's discovery edge as a
 * (parent cell index, raw field index) pair, letting the OCaml side
 * re-reach the new blocks through Obj.field and remember them weakly
 * for later events' member tables.
 *
 * The last argument bundles what steers the walk: the DS's [layers]
 * (one flattened Data_structure.layer per entry -- see
 * data_structure.mli); the SCHEMA table describing user data, derived
 * by the instrumentation from the program's own type declarations
 * (labels, per-field entry, kind); per layer AND SHAPE the schema entry
 * each field's payload edge leads to; and the schema entry describing
 * the root block itself, -1 for a container.  Given those we BFS the
 * representation reachable from [root] and return it as a tree of
 * [node]s.
 *
 * Every BFS entry carries a MODE: a layer index, MODE_PAYLOAD (user
 * data nothing describes), or a schema entry (encoded below -1).  A
 * container root starts at layer 0; a user-declared root starts at its
 * own schema entry.  In an interior cell the layer's SHAPE for that
 * cell -- the one whose tag and field count match it -- decides each
 * field by its masks: interior fields step one layer deeper (clamped to
 * the last -- chains repeat it), payload fields take the schema for
 * that slot's role if there is one and MODE_PAYLOAD otherwise, unmarked
 * fields (bookkeeping) are dropped.  An array layer keeps every
 * element, one layer deeper or as payload per the layer; if that layer
 * is WINDOWED, only the live slots are kept -- their bounds are read
 * from the PARENT cell as the edge into the array is taken, and each
 * slot is labelled with its logical position, so a ring buffer reads in
 * queue order rather than in slot order.  In a schema cell EVERY field
 * is kept and takes its label and its child's entry from the schema --
 * an entry may point at ITSELF, which is how a list cell's tail
 * terminates.  In a plain payload cell every field is kept with a
 * numeric label.
 *
 * Both structural guards sit in FRONT of the schema: a cell that no
 * shape of its layer and no schema entry describes is demoted to
 * payload treatment rather than truncated or mislabeled, and a
 * non-walkable tag is never entered whatever any table claims.  A
 * block's mode is fixed by the first edge that discovers it, and the
 * walk stops queueing new cells at WALK_MAX_CELLS.
 *
 * A kept field becomes, per the rule:
 *
 *   - not a block            -> Int (unboxed int/char/bool/constant ctor)
 *   - block, in the member
 *     table                  -> Id (its wire id), STOP -- some earlier
 *                               event (or this event's registry) already
 *                               defines that block
 *   - block, not walkable    -> a leaf, decoded per the manual's
 *     (see [Walkable_tag])      "Representation of OCaml data types":
 *                               Double_tag -> Float, String_tag -> String,
 *                               Custom_tag -> Int32/Int64/Nativeint,
 *                               Double_array_tag -> Float_array,
 *                               anything else -> Address (opaque; incl.
 *                               closures, objects, lazy/forward blocks
 *                               and continuations, whose leading fields
 *                               are raw words, not values)
 *   - block otherwise        -> a child node: BFS into it
 *     (tuples, records and non-constant constructors land here -- they
 *     are regular scannable blocks, tags 0..Cont_tag-1)
 *
 * GC discipline: the BFS allocates NO OCaml value, so nothing moves during
 * the walk and the raw [value]s cached in [seen] stay valid.  Everything
 * the walk records is plain C data (addresses, decoded leaves, label
 * copies).  Only afterwards do we build the OCaml nodes, and that build
 * holds no walked [value]s, so it cannot dangle anything.  A block
 * revisited WITHIN the walk (sharing or a cycle) is emitted as an [Id]
 * back-reference, never a second parent: the node tree is strict.
 * ------------------------------------------------------------------ */

/* Blocks the BFS may enter: regular tuple/record/variant blocks (tags
 * 0..Cont_tag-1), whose fields are all ordinary values.  Everything from
 * Cont_tag up -- continuations, lazy/forward blocks, closures, objects,
 * infix headers -- carries raw words (code pointers, closure info) that
 * must not be read as values; [capture_leaf]'s default branch turns them
 * into opaque [Address] leaves instead. */
#define Walkable_tag(t) ((t) < Cont_tag)

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

/* ---- growable array of longs: the discovery edges, parallel to the
 * value queue ---- */
typedef struct { long *data; size_t len, cap; } lvec;

static void lvec_push(lvec *v, long x)
{
    if (v->len == v->cap) {
        v->cap = v->cap ? v->cap * 2 : 16;
        v->data = realloc(v->data, v->cap * sizeof(long));
    }
    v->data[v->len++] = x;
}

/* ---- one BFS entry's mode, parallel to the value queue ----
 * [layer] is a layer index (>= 0), MODE_PAYLOAD, or a schema entry
 * encoded below -1.  The rest is the live window of an array cell,
 * computed from its parent as the edge into it was taken; [win_len] < 0
 * means "no window", i.e. the whole block.  Only array layers ever
 * carry one. */
typedef struct {
    long layer;
    long win_start;         /* first live slot, before wrapping */
    long win_len;           /* live slots, or < 0 for the whole block */
    long win_mask;          /* wrap with this mask, or < 0 to use the
                             * block's own size */
    int  win_newest_first;  /* emit the window back to front */
} bmode;

typedef struct { bmode *data; size_t len, cap; } mvec;

static void mvec_push(mvec *v, bmode x)
{
    if (v->len == v->cap) {
        v->cap = v->cap ? v->cap * 2 : 16;
        v->data = realloc(v->data, v->cap * sizeof(bmode));
    }
    v->data[v->len++] = x;
}

/* an entry with no window: the whole block, at [layer] */
static bmode mode_at(long layer)
{
    bmode m;
    m.layer = layer;
    m.win_start = 0;
    m.win_len = -1;
    m.win_mask = -1;
    m.win_newest_first = 0;
    return m;
}

/* ---- pointer -> discovery-index hash (open addressing) ----
 * Discovery order in [seen] IS a cell's intra-snapshot index; the vec
 * keeps that order (and is the BFS queue), the table answers "seen
 * before, at which index?" in O(1) instead of the old linear rescan.
 * No OCaml allocation happens during the walk, so the raw addresses
 * used as keys cannot move.  Key 0 is the empty-slot sentinel -- heap
 * pointers are never 0. */
typedef struct { uintnat *keys; long *idxs; size_t cap, n; } itab;

static size_t itab_slot(const itab *t, uintnat p)
{
    /* pointers are word-aligned: drop the dead low bits, then mix
     * (Fibonacci hashing; the constant truncates harmlessly on 32-bit) */
    size_t i =
        (size_t)((p >> 3) * (uintnat)0x9E3779B97F4A7C15ULL)
        & (t->cap - 1);
    while (t->keys[i] && t->keys[i] != p)
        i = (i + 1) & (t->cap - 1);
    return i;
}

static void itab_grow(itab *t)
{
    size_t ocap = t->cap;
    uintnat *okeys = t->keys;
    long *oidxs = t->idxs;
    t->cap = ocap ? ocap * 2 : 64;
    t->keys = calloc(t->cap, sizeof(uintnat));
    t->idxs = malloc(t->cap * sizeof(long));
    for (size_t i = 0; i < ocap; i++)
        if (okeys[i]) {
            size_t s = itab_slot(t, okeys[i]);
            t->keys[s] = okeys[i];
            t->idxs[s] = oidxs[i];
        }
    free(okeys);
    free(oidxs);
}

static long itab_get(const itab *t, uintnat p)
{
    if (t->cap == 0) return -1;
    size_t s = itab_slot(t, p);
    return t->keys[s] ? t->idxs[s] : -1;
}

static void itab_put(itab *t, uintnat p, long idx)
{
    if (t->n * 3 >= t->cap * 2) itab_grow(t);   /* grows 0 -> 64 too */
    size_t s = itab_slot(t, p);
    if (!t->keys[s]) { t->keys[s] = p; t->n++; }
    t->idxs[s] = idx;
}

/* ---- the registry echo entries, captured from [known].  [name] is
 * strdup'd at capture ("" = anonymous); the registry-order copy [reg]
 * owns every name, freed via [registry_free].  [known] is echo-only:
 * boundary detection goes through the member table below, which the
 * OCaml side seeds with the live registry roots too. ---- */
typedef struct { uintnat ptr; long id; char *name; } known_ent;

/* ---- pointer -> wire id: every block already defined by an earlier
 * event (an immutable structure's remembered members plus the live
 * registry roots), sorted by address once per call.  A field that hits
 * this table is emitted as [Id] and the walk stops there: the dump
 * defines each block at most once, ever. ---- */
typedef struct { uintnat ptr; long id; } mem_ent;

static int mem_cmp(const void *a, const void *b)
{
    uintnat pa = ((const mem_ent *)a)->ptr, pb = ((const mem_ent *)b)->ptr;
    return (pa < pb) ? -1 : (pa > pb) ? 1 : 0;
}

/* Binary search the sorted [arr]; return the id for pointer [p], or -1. */
static long mem_lookup(const mem_ent *arr, size_t n, uintnat p)
{
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (arr[mid].ptr < p) lo = mid + 1; else hi = mid;
    }
    if (lo < n && arr[lo].ptr == p) return arr[lo].id;
    return -1;
}

/* ---- the DS layout, copied to C up front ----
 * Labels are strdup'd before the walk so nothing here can be reading a
 * string the GC later moves, and the walk itself stays allocation-free. */
typedef struct {
    int      tag;        /* the block's tag; < 0 accepts any */
    char   **labels;     /* owned; nlabels entries */
    mlsize_t nlabels;    /* the block's exact field count */
    uintnat  interior;   /* bitmask: fields one layer deeper */
    uintnat  payload;    /* bitmask: user-data fields */
} cshape;

typedef struct {
    cshape  *shapes;     /* owned; nshapes entries */
    mlsize_t nshapes;
    int      is_array;          /* variable size, every element kept */
    int      elements_payload;  /* an array's elements are user data */
    int      windowed;          /* live slots bounded by the parent */
    int      win_start;         /* parent field: first live index */
    int      win_start_offset;  /* added to it */
    int      win_length;        /* parent field: live element count */
    int      win_mask;          /* parent field: ring mask */
    int      win_newest_first;
} clayer;

/* A queued block's mode: a layer index (>= 0) for the structure's own
 * skeleton, MODE_PAYLOAD for user data nothing describes, or a schema
 * entry, encoded below -1 so the two negative cases stay distinct. */
/* An upper bound on the cells one walk may dump.  Containers were
 * bounded in practice by their own layouts; a user-declared root is
 * walked wherever its schema leads, so a big list or a wide graph
 * needs a stop.  Blocks past the bound are recorded as opaque
 * addresses, which says "something was here" without following it. */
#define WALK_MAX_CELLS 4096

#define MODE_PAYLOAD (-1L)
#define SCHEMA_MODE(i)    (-2L - (long)(i))
#define IS_SCHEMA_MODE(m) ((m) <= -2L)
#define SCHEMA_OF_MODE(m) ((mlsize_t)(-2L - (m)))

static clayer *layers_of_value(value v_layers, mlsize_t *out_n)
{
    mlsize_t n = Wosize_val(v_layers);
    clayer *ls = n ? malloc(sizeof(clayer) * n) : NULL;
    for (mlsize_t k = 0; k < n; k++) {
        value ly = Field(v_layers, k);
        value v_shapes = Field(ly, 0);
        mlsize_t ns = Wosize_val(v_shapes);
        ls[k].nshapes = ns;
        ls[k].shapes = ns ? malloc(sizeof(cshape) * ns) : NULL;
        for (mlsize_t s = 0; s < ns; s++) {
            value sh = Field(v_shapes, s);
            value v_labels = Field(sh, 1);
            cshape *cs = &ls[k].shapes[s];
            cs->tag = (int)Long_val(Field(sh, 0));
            cs->nlabels = Wosize_val(v_labels);
            cs->labels =
                cs->nlabels ? malloc(sizeof(char *) * cs->nlabels) : NULL;
            for (mlsize_t i = 0; i < cs->nlabels; i++)
                cs->labels[i] = strdup(String_val(Field(v_labels, i)));
            cs->interior = (uintnat)Long_val(Field(sh, 2));
            cs->payload  = (uintnat)Long_val(Field(sh, 3));
        }
        ls[k].is_array         = Bool_val(Field(ly, 1));
        ls[k].elements_payload = Bool_val(Field(ly, 2));
        ls[k].windowed         = Bool_val(Field(ly, 3));
        ls[k].win_start        = (int)Long_val(Field(ly, 4));
        ls[k].win_start_offset = (int)Long_val(Field(ly, 5));
        ls[k].win_length       = (int)Long_val(Field(ly, 6));
        ls[k].win_mask         = (int)Long_val(Field(ly, 7));
        ls[k].win_newest_first = Bool_val(Field(ly, 8));
    }
    *out_n = n;
    return ls;
}

static void layers_free(clayer *ls, mlsize_t n)
{
    for (mlsize_t k = 0; k < n; k++) {
        for (mlsize_t s = 0; s < ls[k].nshapes; s++) {
            cshape *cs = &ls[k].shapes[s];
            for (mlsize_t i = 0; i < cs->nlabels; i++)
                free(cs->labels[i]);
            free(cs->labels);
        }
        free(ls[k].shapes);
    }
    free(ls);
}

/* The layer's shape for a block of [size] fields tagged [tag], or NULL
 * when the layer describes none: the block is then demoted to payload
 * treatment rather than truncated or mislabeled.  First match wins, so
 * shapes are tried in the order the layout lists them.  [*out_index] is
 * where the matched shape sits, which is how its payload edges are
 * found. */
static const cshape *shape_for(const clayer *ly, int tag, mlsize_t size,
                               mlsize_t *out_index)
{
    for (mlsize_t s = 0; s < ly->nshapes; s++) {
        const cshape *cs = &ly->shapes[s];
        if ((cs->tag < 0 || cs->tag == tag) && cs->nlabels == size) {
            *out_index = s;
            return cs;
        }
    }
    return NULL;
}

/* The window an array cell inherits when the edge into it is taken from
 * [parent] (which has [n] fields): the layer names the parent's fields
 * holding the first live index, the live count and the ring mask.  A
 * field that is out of range or does not hold an immediate voids the
 * window -- the array is then walked whole, exactly as without one. */
static bmode window_from(const clayer *ly, value parent, mlsize_t n,
                         long layer)
{
    bmode m = mode_at(layer);
    long start = 0, len = -1, mask = -1;

#define WIN_FIELD(idx, out)                                             \
    do {                                                                \
        if ((idx) >= 0) {                                               \
            if ((mlsize_t)(idx) >= n                                    \
                || !Is_long(Field(parent, (idx))))                      \
                return m;                                               \
            (out) = Long_val(Field(parent, (idx)));                     \
        }                                                               \
    } while (0)

    WIN_FIELD(ly->win_start, start);
    WIN_FIELD(ly->win_length, len);
    WIN_FIELD(ly->win_mask, mask);
#undef WIN_FIELD

    /* without a live count there is no window to speak of */
    if (len < 0) return m;
    m.win_start = start + ly->win_start_offset;
    m.win_len = len;
    m.win_mask = mask;
    m.win_newest_first = ly->win_newest_first;
    return m;
}

/* ---- the user-data schema, copied to C up front ----
 * Entry i describes one payload block shape, derived by the
 * instrumentation from the user's type declarations: [labels] names
 * its fields positionally (an empty name means fall back to the field
 * index, which is how tuples stay positional), [fields] gives per
 * field the entry describing what that field points at (-1 = nothing
 * known), and [is_array] means every slot takes the single entry in
 * [fields].  An entry may refer to ITSELF -- that is how a list cell's
 * tail and a recursive record close their loop without the table
 * growing forever. */
typedef struct {
    char   **labels;     /* owned; nlabels entries */
    mlsize_t nlabels;
    long    *fields;     /* owned; nfields entries */
    mlsize_t nfields;
    int      is_array;
} cschema;

/* Per layer and SHAPE, the schema entry each field's payload edge leads
 * to -- per shape because a layer's shapes need not agree on where a
 * role sits.  An array layer has one shape of one entry: what every
 * element of it carries. */
typedef struct {
    long   **at;         /* owned; [shape][field], -1 = none */
    mlsize_t *widths;    /* owned; fields per shape */
    mlsize_t nshapes;
} cedges;

static char *index_label(mlsize_t i)
{
    char buf[32];
    snprintf(buf, sizeof buf, "%lu", (unsigned long)i);
    return strdup(buf);
}

/* Label for the field at position [k] of a cell: its shape's label in an
 * interior cell, the position itself everywhere else (payload cells,
 * arrays -- where a windowed array's position is its LOGICAL one). */
static char *field_label(const cshape *sh, mlsize_t k)
{
    if (sh != NULL && k < sh->nlabels)
        return strdup(sh->labels[k]);
    else
        return index_label(k);
}

/* Label for kept field [i] of a schema-described block: the declared
 * name when there is one, the field index otherwise. */
static char *schema_label(const cschema *sc, mlsize_t i)
{
    if (!sc->is_array && i < sc->nlabels && sc->labels[i][0] != '\0')
        return strdup(sc->labels[i]);
    else
        return index_label(i);
}

static cschema *schemas_of_value(value v_schemas, mlsize_t *out_n)
{
    mlsize_t n = Wosize_val(v_schemas);
    cschema *ss = n ? malloc(sizeof(cschema) * n) : NULL;
    for (mlsize_t k = 0; k < n; k++) {
        value tup = Field(v_schemas, k);
        value v_labels = Field(tup, 0);
        value v_fields = Field(tup, 1);
        ss[k].nlabels = Wosize_val(v_labels);
        ss[k].labels =
            ss[k].nlabels ? malloc(sizeof(char *) * ss[k].nlabels) : NULL;
        for (mlsize_t i = 0; i < ss[k].nlabels; i++)
            ss[k].labels[i] = strdup(String_val(Field(v_labels, i)));
        ss[k].nfields = Wosize_val(v_fields);
        ss[k].fields =
            ss[k].nfields ? malloc(sizeof(long) * ss[k].nfields) : NULL;
        for (mlsize_t i = 0; i < ss[k].nfields; i++)
            ss[k].fields[i] = (long)Long_val(Field(v_fields, i));
        ss[k].is_array = (Long_val(Field(tup, 2)) == 1);
    }
    *out_n = n;
    return ss;
}

static void schemas_free(cschema *ss, mlsize_t n)
{
    for (mlsize_t k = 0; k < n; k++) {
        for (mlsize_t i = 0; i < ss[k].nlabels; i++)
            free(ss[k].labels[i]);
        free(ss[k].labels);
        free(ss[k].fields);
    }
    free(ss);
}

static cedges *edges_of_value(value v_edges, mlsize_t *out_n)
{
    mlsize_t n = Wosize_val(v_edges);
    cedges *es = n ? malloc(sizeof(cedges) * n) : NULL;
    for (mlsize_t k = 0; k < n; k++) {
        value layer = Field(v_edges, k);
        mlsize_t ns = Wosize_val(layer);
        es[k].nshapes = ns;
        es[k].at = ns ? malloc(sizeof(long *) * ns) : NULL;
        es[k].widths = ns ? malloc(sizeof(mlsize_t) * ns) : NULL;
        for (mlsize_t s = 0; s < ns; s++) {
            value row = Field(layer, s);
            mlsize_t w = Wosize_val(row);
            es[k].widths[s] = w;
            es[k].at[s] = w ? malloc(sizeof(long) * w) : NULL;
            for (mlsize_t i = 0; i < w; i++)
                es[k].at[s][i] = (long)Long_val(Field(row, i));
        }
    }
    *out_n = n;
    return es;
}

static void edges_free(cedges *es, mlsize_t n)
{
    for (mlsize_t k = 0; k < n; k++) {
        for (mlsize_t s = 0; s < es[k].nshapes; s++) free(es[k].at[s]);
        free(es[k].at);
        free(es[k].widths);
    }
    free(es);
}

/* The schema entry a payload edge out of field [i] leads to: the layer
 * and shape the cell matched decide it, and an array layer's single
 * entry covers every element.  -1 when nothing describes it. */
static long payload_edge(const cedges *es, mlsize_t nedges, long layer,
                         mlsize_t shape, mlsize_t i, int is_array)
{
    if (layer < 0 || (mlsize_t)layer >= nedges) return -1L;
    const cedges *e = &es[layer];
    if (is_array) shape = 0, i = 0;
    if (shape >= e->nshapes || i >= e->widths[shape]) return -1L;
    return e->at[shape][i];
}

/* ---- C-side record of one retained (masked) field ---- */
enum fkind {
    F_CHILD, F_INT, F_FLOAT, F_STRING, F_INT32, F_INT64,
    F_NATIVEINT, F_FLOAT_ARRAY, F_ADDR, F_ID
};
typedef struct {
    enum fkind k;
    long     idx;    /* F_CHILD: index of the child cell */
    intnat   ival;   /* F_INT; F_ID: the registry id */
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

/* The registry echo: (id, address, name) triples in registry order,
 * built from data captured before any OCaml allocation. */
static value alloc_registry(const known_ent *reg, mlsize_t nk)
{
    CAMLparam0();
    CAMLlocal2(arr, entv);
    arr = caml_alloc(nk, 0);
    for (mlsize_t k = 0; k < nk; k++) {
        entv = caml_alloc(3, 0);
        Store_field(entv, 0, Val_long(reg[k].id));
        Store_field(entv, 1, caml_copy_nativeint((intnat)reg[k].ptr));
        Store_field(entv, 2, caml_copy_string(reg[k].name));
        Store_field(arr, k, entv);
    }
    CAMLreturnT(value, arr);
}

/* Free the registry-order copy and the strdup'd names it owns.  Called
 * only after [alloc_registry] has copied the names to the OCaml heap;
 * never free names through [known], whose entries alias the same
 * pointers. */
static void registry_free(known_ent *reg, mlsize_t nk)
{
    for (mlsize_t k = 0; k < nk; k++)
        free(reg[k].name);
    free(reg);
}

/* Allocate the OCaml [block] value for one captured field.  Constructor
 * numbering follows sexp.ml's declaration order: Int=0 Float=1 String=2
 * Int32=3 Int64=4 Nativeint=5 Float_array=6 Address=7 Id=8. */
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
    case F_ID:
        bx = caml_alloc(1, 8);
        Store_field(bx, 0, Val_long(fl->ival));
        break;
    case F_CHILD:
        /* [Child]: the sole CONSTANT constructor, so an immediate --
         * which is why it does not disturb the boxed tags above.  It
         * stands in [block] for the next node of [children]. */
        bx = Val_long(0);
        break;
    default:                               /* F_ADDR */
        bx = caml_alloc(1, 7);
        Store_field(bx, 0, caml_copy_nativeint((intnat)fl->ptr));
        break;
    }
    CAMLreturnT(value, bx);
}

/* external traverse :
 *   Obj.t -> (Obj.t * int * string) array -> (Obj.t * int) array
 *   -> int * int
 *   -> (string array * int * int * bool) array
 *   -> node * (int * nativeint * string) array * (int * int) array
 *   = "caml_wire_traverse" */
CAMLprim value caml_wire_traverse(value v_root, value v_known,
                                  value v_members, value v_ids,
                                  value v_layout)
{
    CAMLparam5(v_root, v_known, v_members, v_ids, v_layout);
    CAMLlocal5(nodes, nodev, lst, ent, bx);
    CAMLlocal5(cons, regarr, resv, pathsarr, pairv);

    long root_id = (long)Long_val(Field(v_ids, 0));
    long next_id = (long)Long_val(Field(v_ids, 1));

    /* Capture the registry echo from [known] and build the sorted
     * pointer->id member table from [v_members].  Reads raw pointers
     * and strdups names; no OCaml allocation, so nothing can move. */
    mlsize_t nk = Is_block(v_known) ? Wosize_val(v_known) : 0;
    known_ent *reg = nk ? malloc(sizeof(known_ent) * nk) : NULL;
    for (mlsize_t k = 0; k < nk; k++) {
        value trip = Field(v_known, k);
        reg[k].ptr  = (uintnat)Field(trip, 0);
        reg[k].id   = (long)Long_val(Field(trip, 1));
        reg[k].name = strdup(String_val(Field(trip, 2)));
    }
    mlsize_t nm = Is_block(v_members) ? Wosize_val(v_members) : 0;
    mem_ent *members = nm ? malloc(sizeof(mem_ent) * nm) : NULL;
    for (mlsize_t k = 0; k < nm; k++) {
        value pair = Field(v_members, k);
        members[k].ptr = (uintnat)Field(pair, 0);
        members[k].id  = (long)Long_val(Field(pair, 1));
    }
    if (nm) qsort(members, nm, sizeof(mem_ent), mem_cmp);

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
        nodev = caml_alloc(4, 0);
        Store_field(nodev, 0, Val_long(root_id));
        Store_field(nodev, 1, caml_copy_nativeint(0));
        Store_field(nodev, 2, cons);
        Store_field(nodev, 3, Val_emptylist);
        regarr = alloc_registry(reg, nk);
        resv = caml_alloc(3, 0);
        Store_field(resv, 0, nodev);
        Store_field(resv, 1, regarr);
        Store_field(resv, 2, Atom(0));
        free(members);
        registry_free(reg, nk);
        CAMLreturn(resv);
    }

    /* A root already in the member table was dumped in full at an
     * earlier event: emit a REVISIT STUB -- same id, current address,
     * empty block and children -- instead of walking anything.  The
     * OCaml side includes the root in [v_members] exactly when it
     * wants this collapse (an immutable structure observed again);
     * mutable structures are left out and re-walk in full. */
    long stub_id = mem_lookup(members, nm, (uintnat)v_root);
    if (stub_id >= 0) {
        uintnat raddr = (uintnat)v_root;   /* before any allocation */
        nodev = caml_alloc(4, 0);
        Store_field(nodev, 0, Val_long(stub_id));
        Store_field(nodev, 1, caml_copy_nativeint((intnat)raddr));
        Store_field(nodev, 2, Val_emptylist);
        Store_field(nodev, 3, Val_emptylist);
        regarr = alloc_registry(reg, nk);
        resv = caml_alloc(3, 0);
        Store_field(resv, 0, nodev);
        Store_field(resv, 1, regarr);
        Store_field(resv, 2, Atom(0));
        free(members);
        registry_free(reg, nk);
        CAMLreturn(resv);
    }

    /* ---- phase 1: BFS, no OCaml allocation (the layer copy strdups,
     * which is C allocation only) ---- */
    mlsize_t nlayers = 0, nschemas = 0, nedges = 0;
    clayer *layers = layers_of_value(Field(v_layout, 0), &nlayers);
    cschema *schemas = schemas_of_value(Field(v_layout, 1), &nschemas);
    cedges *edges = edges_of_value(Field(v_layout, 2), &nedges);
    long root_entry = (long)Long_val(Field(v_layout, 3));
    vec seen = {0};
    mvec modes = {0};
    itab seen_tab = {0};
    ccell *cells = NULL;
    size_t ncells = 0, ccap = 0;
    /* cell i's discovery edge, parallel to [seen]: parent cell index
     * and raw field index -- echoed back so the OCaml side can
     * re-reach the new blocks through Obj.field (coordinates stay
     * valid across the phase-2 allocations; raw addresses would not).
     * Entry 0 (the root) is a placeholder. */
    lvec par_parent = {0}, par_field = {0};

    /* root is cell 0: at the first layer for a container, or in schema
     * mode when the root block is itself user-declared data */
    vec_push(&seen, v_root);
    mvec_push(&modes,
              mode_at(root_entry >= 0 ? SCHEMA_MODE(root_entry)
                                      : (nlayers ? 0 : MODE_PAYLOAD)));
    lvec_push(&par_parent, -1);
    lvec_push(&par_field, -1);
    itab_put(&seen_tab, (uintnat)v_root, 0);
    for (size_t head = 0; head < seen.len; head++) {
        value v = seen.data[head];
        bmode mode = modes.data[head];
        ccell c;
        c.addr = (uintnat)v;
        c.fields = NULL;
        c.nfields = 0;

        if (Walkable_tag(Tag_val(v))) {
            mlsize_t n = Wosize_val(v);
            const clayer *ly = NULL;
            const cshape *sh = NULL;
            const cschema *sc = NULL;
            mlsize_t shape_index = 0;
            int payload_cell = 0;
            if (IS_SCHEMA_MODE(mode.layer)) {
                mlsize_t si = SCHEMA_OF_MODE(mode.layer);
                if (si < nschemas) {
                    sc = &schemas[si];
                    /* the block is not the shape the schema describes:
                     * whatever the type said, the bytes disagree, so
                     * treat it as plain user data rather than mislabel */
                    if (!sc->is_array && n != sc->nfields) sc = NULL;
                }
                if (sc == NULL) payload_cell = 1;
            } else if (mode.layer == MODE_PAYLOAD) {
                payload_cell = 1;
            } else {
                ly = &layers[mode.layer];
                if (!ly->is_array) {
                    sh = shape_for(ly, Tag_val(v), n, &shape_index);
                    if (sh == NULL) {
                        /* the representation didn't match any shape the
                         * layer describes: demote to payload treatment
                         * (keep everything) rather than truncate or
                         * mislabel */
                        payload_cell = 1;
                        ly = NULL;
                    }
                }
            }
            /* where interior edges out of this cell lead: one layer
             * deeper, the last layer repeating -- and, when that layer
             * takes its bounds from here, with the window this cell
             * defines */
            long deeper =
                ly == NULL ? MODE_PAYLOAD
                : (mode.layer + 1 < (long)nlayers ? mode.layer + 1
                                                  : (long)nlayers - 1);
            bmode child = mode_at(deeper);
            if (deeper >= 0 && layers[deeper].windowed)
                child = window_from(&layers[deeper], v, n, deeper);
            /* an array layer keeps its live slots, in logical order;
             * every other cell keeps (a subset of) its own fields */
            int windowed_cell =
                ly != NULL && ly->is_array && mode.win_len >= 0;
            mlsize_t count = n;
            if (windowed_cell) {
                count = (mlsize_t)mode.win_len;
                if (count > n) count = n;      /* defensive */
            }
            c.fields = malloc(sizeof(cfield) * (count ? count : 1));
            for (mlsize_t k = 0; k < count; k++) {
                int keep;
                long child_mode;   /* where a block in this field goes */
                mlsize_t i = k;    /* the field k comes from */
                if (windowed_cell) {
                    mlsize_t at = mode.win_newest_first ? count - 1 - k : k;
                    long idx = mode.win_start + (long)at;
                    if (mode.win_mask >= 0) idx &= mode.win_mask;
                    else {
                        idx %= (long)n;
                        if (idx < 0) idx += (long)n;
                    }
                    if (idx < 0 || (mlsize_t)idx >= n) continue;
                    i = (mlsize_t)idx;
                }
                if (sc != NULL) {
                    /* user data: every field is kept, and the schema
                     * says what each one points at */
                    long e = sc->is_array
                             ? (sc->nfields ? sc->fields[0] : -1L)
                             : sc->fields[i];
                    keep = 1;
                    child_mode = e >= 0 ? SCHEMA_MODE(e) : MODE_PAYLOAD;
                } else if (payload_cell) {
                    keep = 1; child_mode = MODE_PAYLOAD;
                } else if (ly->is_array) {
                    keep = 1;
                    if (!ly->elements_payload) child_mode = deeper;
                    else {
                        /* the elements are user data: one role covers
                         * every slot of the buffer */
                        long e = payload_edge(edges, nedges, mode.layer,
                                              shape_index, i, 1);
                        child_mode =
                            e >= 0 ? SCHEMA_MODE(e) : MODE_PAYLOAD;
                    }
                } else {
                    int in_i = i < 8 * sizeof(uintnat)
                               && ((sh->interior >> i) & 1u);
                    int in_p = i < 8 * sizeof(uintnat)
                               && ((sh->payload >> i) & 1u);
                    keep = in_i || in_p;      /* neither: bookkeeping */
                    if (in_i)
                        child_mode = deeper;
                    else {
                        /* a payload edge: hand the user data below it
                         * to the schema for this slot's role, if the
                         * instrumentation could describe one */
                        long e = payload_edge(edges, nedges, mode.layer,
                                              shape_index, i, 0);
                        child_mode = e >= 0 ? SCHEMA_MODE(e) : MODE_PAYLOAD;
                    }
                }
                if (!keep) continue;
                value f = Field(v, i);
                cfield fl = {0};
                fl.label = sc != NULL ? schema_label(sc, i)
                                      : field_label(sh, k);
                if (!Is_block(f)) {
                    capture_leaf(&fl, f);
                } else {
                    long id = mem_lookup(members, nm, (uintnat)f);
                    if (id >= 0) {
                        fl.k = F_ID;     /* defined at an earlier event */
                        fl.ival = (intnat)id;
                    } else if (!Walkable_tag(Tag_val(f))) {
                        capture_leaf(&fl, f);
                    } else {
                        long idx = itab_get(&seen_tab, (uintnat)f);
                        if (idx >= 0) {
                            /* within-walk revisit (sharing or a cycle):
                             * a back-reference, never a second parent,
                             * so the node tree stays strict */
                            fl.k = F_ID;
                            fl.ival = (intnat)(idx == 0
                                          ? root_id : next_id + idx - 1);
                        } else if (seen.len >= WALK_MAX_CELLS) {
                            /* budget spent: name the field, but record
                             * the block opaquely instead of walking it */
                            fl.k = F_ADDR;
                            fl.ptr = (uintnat)f;
                        } else {
                            idx = (long)seen.len;
                            vec_push(&seen, f);
                            /* an interior edge carries the window this
                             * cell computed; every other edge carries
                             * none */
                            mvec_push(&modes,
                                      child_mode == deeper
                                      ? child : mode_at(child_mode));
                            lvec_push(&par_parent, (long)head);
                            lvec_push(&par_field, (long)i);
                            itab_put(&seen_tab, (uintnat)f, idx);
                            fl.k = F_CHILD;
                            fl.idx = idx;
                        }
                    }
                }
                c.fields[c.nfields++] = fl;
            }
        } else {
            /* A non-walkable block only ever reaches the queue as the
             * ROOT (as a field it would have been captured in place):
             * a float array, an all-float record, a string.  Decode it
             * as this node's sole entry -- emitting an empty node
             * would lose the value entirely. */
            cfield fl = {0};
            fl.label = index_label(0);
            capture_leaf(&fl, v);
            c.fields = malloc(sizeof(cfield));
            c.fields[0] = fl;
            c.nfields = 1;
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
            bx = alloc_block(fl);   /* F_CHILD becomes the [Child] marker */
            ent = caml_alloc(2, 0);
            Store_field(ent, 0, caml_copy_string(fl->label));
            Store_field(ent, 1, bx);
            cons = caml_alloc(2, 0);
            Store_field(cons, 0, ent);
            Store_field(cons, 1, lst);
            lst = cons;
        }
        nodev = caml_alloc(4, 0);
        Store_field(nodev, 0, Val_long(i == 0 ? root_id
                                              : next_id + (long)i - 1));
        Store_field(nodev, 1, caml_copy_nativeint((intnat)c->addr));
        Store_field(nodev, 2, lst);               /* block */
        Store_field(nodev, 3, Val_emptylist);     /* children: pass B */
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
        Store_field(Field(nodes, i), 3, lst);
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
    free(modes.data);
    free(seen_tab.keys);
    free(seen_tab.idxs);
    layers_free(layers, nlayers);
    schemas_free(schemas, nschemas);
    edges_free(edges, nedges);
    free(members);

    /* the discovery edges of the new cells (cell 0, the root, is the
     * caller's own value and needs no path) */
    pathsarr = ncells > 1 ? caml_alloc(ncells - 1, 0) : Atom(0);
    for (size_t i = 1; i < ncells; i++) {
        pairv = caml_alloc(2, 0);
        Store_field(pairv, 0, Val_long(par_parent.data[i]));
        Store_field(pairv, 1, Val_long(par_field.data[i]));
        Store_field(pathsarr, i - 1, pairv);
    }
    free(par_parent.data);
    free(par_field.data);

    regarr = alloc_registry(reg, nk);
    registry_free(reg, nk);
    resv = caml_alloc(3, 0);
    Store_field(resv, 0, Field(nodes, 0));
    Store_field(resv, 1, regarr);
    Store_field(resv, 2, pathsarr);
    CAMLreturn(resv);
}

/* ------------------------------------------------------------------ *
 * The dump sink.  The instrumentation brackets every event with "{" / "}"
 * via [__wire_emit] (see typing/vreplay_instrumentation.ml); the reader sums
 * them to recover call depth.  Everything -- markers and records -- goes
 * through the one sink, chosen once at the first emit:
 *
 *   VREPLAY_SOCK=<path>   connect a Unix domain stream socket (a live
 *                         listener, e.g. the debugger interface); if the
 *                         connect fails, warn on stderr and fall through
 *   VREPLAY_FILE=<path>   write that file (truncating)
 *   neither               write ./vreplay.dump
 *
 * Never stdout: the dump must not interleave with the program's own
 * prints (they'd corrupt the stream for the reader).  Writes are raw
 * [write]/[send] full-write loops, verbatim -- no prefix, no newline
 * (framing is the caller's job) -- and unbuffered, so the dump stays
 * ordered without flushing.  Socket writes use MSG_NOSIGNAL so a
 * vanished listener surfaces as EPIPE instead of SIGPIPE killing the
 * program; any write error (or failure to open a sink at all) warns
 * once on stderr and disables emission rather than take the program
 * down with it.
 * ------------------------------------------------------------------ */
static int wire_fd = -2;               /* -2 not yet chosen, -1 disabled */
#ifndef _WIN32
static int wire_fd_is_socket = 0;      /* only the POSIX path has sockets */
#endif

static void wire_disable(const char *what, const char *detail)
{
    fprintf(stderr, "vreplay: %s %s (%s); dump disabled\n",
            what, detail, strerror(errno));
    wire_fd = -1;
}

static void wire_open_sink(void)
{
#ifndef _WIN32
    const char *sock = getenv("VREPLAY_SOCK");
    if (sock != NULL) {
        struct sockaddr_un addr;
        if (strlen(sock) < sizeof(addr.sun_path)) {
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            memset(&addr, 0, sizeof(addr));
            addr.sun_family = AF_UNIX;
            strcpy(addr.sun_path, sock);
            if (fd >= 0
                && connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
                wire_fd = fd;
                wire_fd_is_socket = 1;
                return;
            }
            if (fd >= 0) close(fd);
        } else
            errno = ENAMETOOLONG;
        fprintf(stderr,
                "vreplay: cannot connect VREPLAY_SOCK %s (%s); "
                "falling back to a file\n",
                sock, strerror(errno));
    }
#endif
    const char *path = getenv("VREPLAY_FILE");
    if (path == NULL) path = "vreplay.dump";
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { wire_disable("cannot open", path); return; }
    wire_fd = fd;
}

static void wire_write(const char *buf, size_t len)
{
    if (wire_fd == -2) wire_open_sink();
    while (wire_fd >= 0 && len > 0) {
#ifdef _WIN32
        int n;                         /* MSVC has no ssize_t */
#else
        ssize_t n;
#endif
#ifndef _WIN32
        if (wire_fd_is_socket) n = send(wire_fd, buf, len, MSG_NOSIGNAL);
        else
#endif
            n = write(wire_fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            wire_disable("write failed on", "the dump sink");
            return;
        }
        buf += n;
        len -= (size_t)n;
    }
}

/* external __wire_emit : string -> unit = "caml_wire_emit" */
CAMLprim value caml_wire_emit(value v_msg)
{
    CAMLparam1(v_msg);
    wire_write(String_val(v_msg), caml_string_length(v_msg));
    CAMLreturn(Val_unit);
}
