(** The per-function compute profile the pipeline hands the interface.

    Built from a perf report over the natively compiled, unmodified program
    ({!of_perf_report}): parse the rows ({!Perf_report}), decode each symbol
    ({!Ocaml_symbol}), drop what isn't attributable OCaml code, and sum
    samples per function.

    {!save} writes the versioned sexp that is the wire contract with
    [jsip-debugger-interface] (its [Heat_profile] reader derives the exact
    inverse), e.g.

    {v
    ((version 1)
     (root_module Greet)
     (entries
      (((module_path (Stdlib String)) (kind (Named concat)) (samples 675))
       ((module_path (Greet)) (kind (Named shout)) (samples 318)))))
    v}

    [root_module] names the profiled program's own module so the reader can
    prefer the user's functions when an unqualified trace name is ambiguous.
    Entries are sorted hottest-first for human eyes; readers must not rely on
    the order. *)

open! Core

module Entry : sig
  type t =
    { module_path : string list
    ; kind : Ocaml_symbol.Kind.t
    ; samples : int
    }
  [@@deriving sexp]
end

type t =
  { version : int
  ; root_module : string
  ; entries : Entry.t list
  }
[@@deriving sexp]

val current_version : int
val of_perf_report : report_text:string -> root_module:string -> t Or_error.t

(** samples attributed to OCaml functions — the share denominator on the
    interface side, and the adequacy measure for the capture loop *)
val total_samples : t -> int

val save : t -> file:string -> unit
