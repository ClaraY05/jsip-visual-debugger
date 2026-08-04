(* Running usage statistics over the session: how often each operator
   appears, folded into a [Map] as each statement is parsed. Another
   tracked structure for the heap pane, and another module for the call
   stack to bounce through. *)

module Op_map = Map.Make (String)

let bump op counts =
  Op_map.update
    op
    (fun count -> Some (1 + Option.value ~default:0 count))
    counts
;;

let rec count_ops (expr : Parser.expr) counts =
  match expr with
  | Parser.Number _ | Parser.Variable _ -> counts
  | Parser.Add (left, right) ->
    bump "+" counts |> count_ops left |> count_ops right
  | Parser.Subtract (left, right) ->
    bump "-" counts |> count_ops left |> count_ops right
  | Parser.Multiply (left, right) ->
    bump "*" counts |> count_ops left |> count_ops right
  | Parser.Divide (left, right) ->
    bump "/" counts |> count_ops left |> count_ops right
;;

let record (statement : Parser.statement) counts =
  match statement with
  | Parser.Bind (_, expr) | Parser.Evaluate expr -> count_ops expr counts
  | Parser.Define (_, _) ->
    (* a def's body is raw tokens until the evaluator forces it *)
    counts
;;

let report counts =
  Op_map.iter
    (fun op count ->
      print_endline (Printf.sprintf "  %s used %d times" op count))
    counts
;;
