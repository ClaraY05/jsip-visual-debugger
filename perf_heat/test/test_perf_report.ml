open! Core
open Canary_perf_heat

(* verbatim excerpt (headers, blanks, tail comment included) of
   [perf report --stdio --dsos prog.exe --percent-limit 0 -F sample,sym] over
   examples/greet.ml looped in-process, perf 6.17 *)
let report =
  {|
# To display the perf.data header info, please use --header/--header-only options.
#
#
# Total Lost Samples: 0
#
# Samples: 519K of event 'task-clock:ppp'
# Event count (approx.): 5193750000
#
#      Samples  Symbol
# ............  ..............................................
#
         11041  [.] caml_alloc_string
          8841  [.] Greet.shout_2_5_code
          8823  [.] caml_ml_output_bytes
          4013  [.] Greet.entry
          3819  [.] Greet.generate_string_0_3_code
          1912  [.] Greet.generate_string2_1_4_code
           634  [.] memmove@plt
             4  [.] fill_hashtable.constprop.0
             1  [.] Std_exit.entry
             1  [.] sys_getenv


#
# (Cannot load tips.txt file, please install perf!)
#
|}
;;

let%expect_test "parses every data row and skips comments and blanks" =
  print_s [%sexp (Perf_report.parse report : (int * string) list Or_error.t)];
  [%expect
    {|
    (Ok
     ((11041 caml_alloc_string) (8841 Greet.shout_2_5_code)
      (8823 caml_ml_output_bytes) (4013 Greet.entry)
      (3819 Greet.generate_string_0_3_code)
      (1912 Greet.generate_string2_1_4_code) (634 memmove@plt)
      (4 fill_hashtable.constprop.0) (1 Std_exit.entry) (1 sys_getenv)))
    |}]
;;

let%expect_test "an unrecognized line is a loud error, not a dropped row" =
  print_s
    [%sexp
      (Perf_report.parse "  12.34%  [.] Greet.shout_2_5_code"
       : (int * string) list Or_error.t)];
  [%expect
    {|
    (Error
     ("Perf_report: sample count is not a number"
      (line "  12.34%  [.] Greet.shout_2_5_code")))
    |}];
  print_s
    [%sexp
      (Perf_report.parse "no columns here" : (int * string) list Or_error.t)];
  [%expect
    {| (Error ("Perf_report: unrecognized line" (line "no columns here"))) |}]
;;
