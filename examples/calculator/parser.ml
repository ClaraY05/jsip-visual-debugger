(* Recursive descent over a [Lexer.token list]: expressions with the usual
   precedence (factors bind tighter than terms), and [let name = expr]
   bindings. *)

type expr =
  | Number of int
  | Variable of string
  | Add of expr * expr
  | Subtract of expr * expr
  | Multiply of expr * expr
  | Divide of expr * expr

type statement =
  | Bind of string * expr
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

let parse tokens =
  match tokens with
  | Lexer.Keyword_let :: Lexer.Ident name :: Lexer.Equals :: rest ->
    let expr, rest = parse_expr rest in
    (match rest with
     | [] -> Bind (name, expr)
     | _ -> failwith "trailing tokens after a binding")
  | _ ->
    let expr, rest = parse_expr tokens in
    (match rest with
     | [] -> Evaluate expr
     | _ -> failwith "trailing tokens after an expression")
;;
