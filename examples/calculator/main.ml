(* A tiny calculator session: each line is lexed, parsed, and evaluated
   against the environment the previous lines built up. *)

let session =
  [ "let width = 2 + 3 * 4"
  ; "let height = (width - 4) / 2"
  ; "let area = width * height"
  ; "area - height * 2"
  ]
;;

let () =
  let final =
    List.fold_left
      (fun env line ->
        let tokens = Lexer.tokenize line in
        let statement = Parser.parse tokens in
        let env, shown = Evaluator.run env statement in
        print_endline (line ^ "   => " ^ shown);
        env)
      Evaluator.Env.empty
      session
  in
  ignore (Evaluator.Env.cardinal final)
;;
