(* A minimal s-expression AST, hand-rolled because the compiler build has
   no sexplib (and must not grow an opam dependency). *)
type t =
  | Atom of string
  | List of t list

(* Renders on one line.  Atoms are quoted/escaped the way sexplib quotes
   printable ASCII (specials and non-printables in "..." with \-escapes),
   so the output parses with either [of_string] or sexplib. *)
val to_string : t -> string

(* Parses exactly one sexp; the inverse of [to_string].  Raises [Failure]
   on malformed or trailing input. *)
val of_string : string -> t
