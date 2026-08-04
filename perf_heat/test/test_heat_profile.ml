open! Core
open Sandbox_perf_heat

let report =
  {|
#      Samples  Symbol
#
         11041  [.] caml_alloc_string
          8841  [.] Greet.shout_2_5_code
          3819  [.] Greet.generate_string_0_3_code
          1912  [.] Greet.generate_string2_1_4_code
          1000  [.] camlGreet__generate_string_0_3_code
           250  [.] Greet.fn[greet.ml:5,27--33]_4_4_code
           131  [.] Stdlib.Map.fold_31_173_code
           634  [.] memmove@plt
          4013  [.] Greet.entry
|}
;;

let profile =
  Heat_profile.of_perf_report ~report_text:report ~root_module:"Greet"
  |> Or_error.ok_exn
;;

let%expect_test "aggregates per function, drops non-code, sorts hottest \
                 first"
  =
  (* the raw-mangled and demangled spellings of generate_string are the same
     function and their samples merge: 3819 + 1000 *)
  print_s [%sexp (profile : Heat_profile.t)];
  [%expect
    {|
    ((version 1) (root_module Greet)
     (entries
      (((module_path (Greet)) (kind (Named shout)) (samples 8841))
       ((module_path (Greet)) (kind (Named generate_string)) (samples 4819))
       ((module_path (Greet)) (kind (Named generate_string2)) (samples 1912))
       ((module_path (Greet))
        (kind
         (Anonymous (file_path greet.ml) (line_number 5) (char_range (27 33))))
        (samples 250))
       ((module_path (Stdlib Map)) (kind (Named fold)) (samples 131)))))
    |}];
  print_s [%sexp (Heat_profile.total_samples profile : int)];
  [%expect {| 15953 |}]
;;

let%expect_test "the contract sexp round-trips" =
  let round_tripped =
    Heat_profile.t_of_sexp (Heat_profile.sexp_of_t profile)
  in
  print_s
    [%sexp
      (Sexp.equal
         (Heat_profile.sexp_of_t profile)
         (Heat_profile.sexp_of_t round_tripped)
       : bool)];
  [%expect {| true |}]
;;

let%expect_test "a bad report fails loudly" =
  print_s
    [%sexp
      (Heat_profile.of_perf_report
         ~report_text:"garbage in"
         ~root_module:"Greet"
       : Heat_profile.t Or_error.t)];
  [%expect
    {| (Error ("Perf_report: unrecognized line" (line "garbage in"))) |}]
;;
