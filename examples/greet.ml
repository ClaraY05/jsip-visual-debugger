(* A small stdlib-only program for exercising the replay pipeline: nested
   calls over strings, the shape the instrumentation currently tracks
   (compare app/bin/dummy.txt in the interface repo). *)

let generate_string s = "hello " ^ s
let generate_string2 s = "hi " ^ generate_string s
let shout s = String.uppercase_ascii (generate_string s)

let () =
  print_endline (generate_string2 "robyn");
  print_endline (shout "clara")
;;
