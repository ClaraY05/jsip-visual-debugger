(** Sandbox entry point.

    Run with: dune exec bin/main.exe -- Ada *)

open! Core
open Sandbox_hello

let () =
  let name =
    if Array.length (Sys.get_argv ()) > 1
    then (Sys.get_argv ()).(1)
    else "world"
  in
  print_endline (Hello.greeting (Hello.of_name name))
;;
