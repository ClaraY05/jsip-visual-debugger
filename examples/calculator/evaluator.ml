(* Walks a [Parser.expr] against an environment of bindings. The environment
   is a stdlib [Map] — exactly what the replay instrumentation tracks, so
   every [Env.add] a [let] performs shows up as a step in the visual
   debugger, with the environment's heap shape beside it. *)

module Env = Map.Make (String)

let rec eval env (expr : Parser.expr) =
  match expr with
  | Parser.Number n -> n
  | Parser.Variable name ->
    (match Env.find_opt name env with
     | Some value -> value
     | None -> failwith ("unbound variable " ^ name))
  | Parser.Add (left, right) -> eval env left + eval env right
  | Parser.Subtract (left, right) -> eval env left - eval env right
  | Parser.Multiply (left, right) -> eval env left * eval env right
  | Parser.Divide (left, right) -> eval env left / eval env right
;;

(* a binding extends the environment; a bare expression just shows its value *)
let run env (statement : Parser.statement) =
  match statement with
  | Parser.Bind (name, expr) ->
    let value = eval env expr in
    Env.add name value env, name ^ " = " ^ string_of_int value
  | Parser.Evaluate expr ->
    let value = eval env expr in
    env, string_of_int value
;;
