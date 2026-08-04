(** Decodes one native-code symbol name to its OCaml identity.

    The perf report names the functions of a natively compiled program by
    their assembler symbols. This module recognizes the two spellings the
    OCaml compiler's mangling can reach us in and rejects everything that is
    not attributable OCaml code:

    - raw mangled, e.g. [camlGreet__shout_2_8_code] or
      [camlGreet__fn$5bgreet.ml$3a5$2c27$2d$2d33$5d_4_4_code] (the [$xx]
      pairs hex-escape characters an assembler symbol can't hold);
    - pre-demangled, the form perf 6.x prints, e.g. [Greet.shout_2_8_code] or
      [Greet.fn[greet.ml:5,27--33]_4_4_code].

    Runtime C ([caml_alloc_string]), glue ([caml_apply3], [caml_curry_2]),
    module plumbing ([Greet.entry], [camlGreet__code_begin]), data symbols,
    PLT stubs and kernel symbols all decode to [None]; their samples are
    runtime overhead, not any function's compute.

    {!Perf_report} extracts the [(samples, symbol)] rows this module decodes;
    {!Heat_profile} aggregates the survivors. *)

open! Core

module Kind : sig
  type t =
    | Named of string
    (** an ordinary [let]-bound function: [shout], [fold] *)
    | Anonymous of
        { file_path : string
        ; line_number : int
        ; char_range : int * int
        }
    (** a lambda, named by the compiler after its definition site:
        [fn[greet.ml:5,27--33]] *)
  [@@deriving sexp, compare, equal]
end

type t =
  { module_path : string list (** e.g. [["Greet"]] or [["Stdlib"; "Map"]] *)
  ; kind : Kind.t
  }
[@@deriving sexp, compare, equal]

include Comparable.S with type t := t

(** [None] when the symbol is not OCaml code we can attribute to a function;
    see the module comment for the taxonomy. *)
val of_symbol_name : string -> t option
