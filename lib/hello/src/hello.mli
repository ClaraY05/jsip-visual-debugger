(** A minimal example module.

    Demonstrates the house style: [open! Core], a [type t] with the usual
    deriving, and doc comments on every exported value.

    {[
      Hello.greeting (Hello.of_name "Ada") = "Hello, Ada!"
    ]} *)

open! Core

(** The name of whoever we are greeting. *)
type t [@@deriving sexp_of, compare, equal]

(** [of_name name] builds a value to greet. Leading and trailing whitespace
    is stripped. Raises if [name] is empty after trimming. *)
val of_name : string -> t

(** [greeting t] is the human-readable greeting for [t]. *)
val greeting : t -> string
