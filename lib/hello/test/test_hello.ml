open! Core
open Sandbox_hello

let%expect_test "greeting" =
  print_endline (Hello.greeting (Hello.of_name "Ada"));
  [%expect {| Hello, Ada! |}]
;;

let%expect_test "names are trimmed" =
  print_endline (Hello.greeting (Hello.of_name "  Grace  "));
  [%expect {| Hello, Grace! |}]
;;

let%expect_test "empty name raises" =
  Expect_test_helpers_core.require_does_raise (fun () -> Hello.of_name "   ");
  [%expect {| ("Hello.of_name: empty name" (name "   ")) |}]
;;
