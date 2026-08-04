(* A calculator session: each line is lexed into a token queue, parsed
   against it, tallied into the operator stats, and evaluated against the
   environment the previous lines built up — with [def] lines deferring
   their bodies until first use, so evaluation calls back into the parser.
   Results pile onto a stack; the run ends with the session's stats. *)

let session =
  [ "let width = 2 + 3 * 4"
  ; "def area = width * height"
  ; "let height = (width - 4) / 2"
  ; "let a = area"
  ; "let b = area + a"
  ; "a + b - height"
  ]
;;

let () =
  let results = Stack.create () in
  let final_env, final_stats =
    List.fold_left
      (fun (env, stats) line ->
        let tokens = Lexer.tokenize line in
        let statement = Parser.parse tokens in
        let stats = Stats.record statement stats in
        let env, shown = Evaluator.run env statement in
        Stack.push (line ^ "   => " ^ shown) results;
        print_endline (line ^ "   => " ^ shown);
        env, stats)
      (Evaluator.Env.empty, Stats.Op_map.empty)
      session
  in
  print_endline
    (Printf.sprintf
       "%d lines, %d bindings, operators:"
       (Stack.length results)
       (Evaluator.Env.cardinal final_env));
  Stats.report final_stats
;;
