(* Recursive descent: expressions with the usual precedence (factors bind
   tighter than terms), [let name = expr] eager bindings, and
   [def name = expr] deferred ones — a [def]'s body is kept as raw tokens
   and only parsed when the evaluator first needs it, so parsing calls
   appear inside evaluation in the debugger's call stack. *)

type expr =
  | Number of int
  | Variable of string
  | Add of expr * expr
  | Subtract of expr * expr
  | Multiply of expr * expr
  | Divide of expr * expr

type statement =
  | Bind of string * expr
  | Define of string * Lexer.token list
  | Evaluate of expr

(* factor := number | variable | ( expr ) *)
let rec parse_factor tokens =
  match tokens with
  | Lexer.Number n :: rest -> Number n, rest
  | Lexer.Ident name :: rest -> Variable name, rest
  | Lexer.Lparen :: rest ->
    let inner, rest = parse_expr rest in
    (match rest with
     | Lexer.Rparen :: rest -> inner, rest
     | _ -> failwith "expected )")
  | _ -> failwith "expected a number, a variable, or ("

(* term := factor (( * | / ) factor)*, left associative *)
and parse_term tokens =
  let rec loop left tokens =
    match tokens with
    | Lexer.Star :: rest ->
      let right, rest = parse_factor rest in
      loop (Multiply (left, right)) rest
    | Lexer.Slash :: rest ->
      let right, rest = parse_factor rest in
      loop (Divide (left, right)) rest
    | _ -> left, tokens
  in
  let left, rest = parse_factor tokens in
  loop left rest

(* expr := term (( + | - ) term)*, left associative *)
and parse_expr tokens =
  let rec loop left tokens =
    match tokens with
    | Lexer.Plus :: rest ->
      let right, rest = parse_term rest in
      loop (Add (left, right)) rest
    | Lexer.Minus :: rest ->
      let right, rest = parse_term rest in
      loop (Subtract (left, right)) rest
    | _ -> left, tokens
  in
  let left, rest = parse_term tokens in
  loop left rest
;;

(* a whole expression and nothing else — also what the evaluator calls
   when it finally parses a [def]'s saved body *)
let parse_expr_exn tokens =
  let expr, rest = parse_expr tokens in
  match rest with
  | [] -> expr
  | _ :: _ -> failwith "trailing tokens after an expression"
;;

(* drain the lexer's queue into a list, front to back *)
let rec drain tokens =
  match Queue.take_opt tokens with
  | Some token -> token :: drain tokens
  | None -> []
;;

let parse tokens =
  match Queue.take_opt tokens with
  | Some Lexer.Keyword_let ->
    (match Queue.take_opt tokens, Queue.take_opt tokens with
     | Some (Lexer.Ident name), Some Lexer.Equals ->
       Bind (name, parse_expr_exn (drain tokens))
     | _ -> failwith "expected: let <name> = <expr>")
  | Some Lexer.Keyword_def ->
    (match Queue.take_opt tokens, Queue.take_opt tokens with
     | Some (Lexer.Ident name), Some Lexer.Equals ->
       (* deferred: keep the raw tokens, parse on first use *)
       Define (name, drain tokens)
     | _ -> failwith "expected: def <name> = <expr>")
  | Some first -> Evaluate (parse_expr_exn (first :: drain tokens))
  | None -> failwith "empty line"
;;
