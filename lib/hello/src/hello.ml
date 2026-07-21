open! Core

type t = string [@@deriving sexp_of, compare, equal]

let of_name name =
  match String.strip name with
  | "" -> raise_s [%message "Hello.of_name: empty name" (name : string)]
  | name -> name
;;

let greeting t = [%string "Hello, %{t}!"]
