(* Walks a [Parser.expr] against an environment of bindings. The
   environment is a stdlib [Map]; a [let] stores its evaluated number, a
   [def] stores its body's raw tokens. Using a defined name parses and
   evaluates that body on the spot — [eval] calls back into [Parser] mid
   walk, which is the file-to-file bounce to watch in the call stack —
   and the result lands in a [Hashtbl] memo so later uses skip the work. *)

module Env = Map.Make (String)

type value =
  | Number of int
  | Definition of Lexer.token list

let memo : (string, int) Hashtbl.t = Hashtbl.create 8

let rec eval env (expr : Parser.expr) =
  match expr with
  | Parser.Number n -> n
  | Parser.Variable name ->
    (match Env.find_opt name env with
     | Some (Number value) -> value
     | Some (Definition body) ->
       (match Hashtbl.find_opt memo name with
        | Some value -> value
        | None ->
          let value = eval env (Parser.parse_expr_exn body) in
          Hashtbl.add memo name value;
          value)
     | None -> failwith ("unbound variable " ^ name))
  | Parser.Add (left, right) -> eval env left + eval env right
  | Parser.Subtract (left, right) -> eval env left - eval env right
  | Parser.Multiply (left, right) -> eval env left * eval env right
  | Parser.Divide (left, right) -> eval env left / eval env right
;;

(* a binding extends the environment; a definition is stored unevaluated;
   a bare expression just shows its value *)
let run env (statement : Parser.statement) =
  match statement with
  | Parser.Bind (name, expr) ->
    let value = eval env expr in
    Env.add name (Number value) env, name ^ " = " ^ string_of_int value
  | Parser.Define (name, body) ->
    Env.add name (Definition body) env, name ^ " deferred"
  | Parser.Evaluate expr ->
    let value = eval env expr in
    env, string_of_int value
;;
