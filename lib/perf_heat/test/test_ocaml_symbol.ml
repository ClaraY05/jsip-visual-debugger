open! Core
open Sandbox_perf_heat

(* every accepted name below was captured from a real [nm]/[perf report] over
   examples/greet.ml compiled with the 5.2.0+ox switch's ocamlopt *)

let show name =
  print_s [%sexp (Ocaml_symbol.of_symbol_name name : Ocaml_symbol.t option)]
;;

let%expect_test "raw mangled function symbols" =
  show "camlGreet__generate_string_0_3_code";
  [%expect {| (((module_path (Greet)) (kind (Named generate_string)))) |}];
  show "camlStdlib__Map__fold_31_173_code";
  [%expect {| (((module_path (Stdlib Map)) (kind (Named fold)))) |}]
;;

let%expect_test "raw mangled operator symbols hex-decode" =
  show "camlStdlib__$5e_6_99_code";
  [%expect {| (((module_path (Stdlib)) (kind (Named ^)))) |}];
  show "camlStdlib__$5e$5e_62_155_code";
  [%expect {| (((module_path (Stdlib)) (kind (Named ^^)))) |}]
;;

let%expect_test "raw mangled anonymous function carries its definition site" =
  show
    "camlCamlinternalLazy__fn$5b$2fworkspace_root$2fcamlinternalLazy.ml$3a61$2c32$2d$2d51$5d_1_7_code";
  [%expect
    {|
    (((module_path (CamlinternalLazy))
      (kind
       (Anonymous (file_path /workspace_root/camlinternalLazy.ml)
        (line_number 61) (char_range (32 51))))))
    |}]
;;

let%expect_test "perf-demangled forms" =
  show "Greet.shout_2_5_code";
  [%expect {| (((module_path (Greet)) (kind (Named shout)))) |}];
  show "Stdlib.Map.fold_31_173_code";
  [%expect {| (((module_path (Stdlib Map)) (kind (Named fold)))) |}];
  show "Greet.fn[greet.ml:5,27--33]_4_4_code";
  [%expect
    {|
    (((module_path (Greet))
      (kind
       (Anonymous (file_path greet.ml) (line_number 5) (char_range (27 33))))))
    |}]
;;

let%expect_test "runtime C, glue, plumbing, data and foreign symbols reject" =
  List.iter
    ~f:(fun name -> show name)
    [ "caml_alloc_string"
    ; "caml_apply3"
    ; "caml_curry_2"
    ; "caml_c_call"
    ; "Greet.entry"
    ; "Std_exit.entry"
    ; "camlGreet__code_begin"
    ; "camlGreet__frametable"
    ; "memmove@plt"
    ; "pthread_mutex_unlock@plt"
    ; "fill_hashtable.constprop.0"
    ; "flush_partial"
    ; "check_pending"
    ];
  [%expect
    {|
    ()
    ()
    ()
    ()
    ()
    ()
    ()
    ()
    ()
    ()
    ()
    ()
    ()
    |}]
;;
