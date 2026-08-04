(* Turns "let a = 2 + 3 * (b - 1)" into a queue of tokens. The queue is a
   structure the replay instrumentation tracks, so the debugger shows it
   fill here token by token — and drain again over in [Parser]. *)

type token =
  | Number of int
  | Ident of string
  | Keyword_let
  | Keyword_def
  | Equals
  | Plus
  | Minus
  | Star
  | Slash
  | Lparen
  | Rparen

let is_digit c = c >= '0' && c <= '9'
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

(* the longest run of [pred] characters starting at [start] *)
let read_while input pred start =
  let rec stop i =
    if i < String.length input && pred input.[i] then stop (i + 1) else i
  in
  let stop = stop start in
  String.sub input start (stop - start), stop
;;

let tokenize input =
  let tokens = Queue.create () in
  let rec go i =
    if i < String.length input
    then (
      let c = input.[i] in
      if c = ' '
      then go (i + 1)
      else if is_digit c
      then (
        let text, next = read_while input is_digit i in
        Queue.add (Number (int_of_string text)) tokens;
        go next)
      else if is_alpha c
      then (
        let text, next = read_while input is_alpha i in
        let token =
          match text with
          | "let" -> Keyword_let
          | "def" -> Keyword_def
          | _ -> Ident text
        in
        Queue.add token tokens;
        go next)
      else (
        let token =
          match c with
          | '=' -> Equals
          | '+' -> Plus
          | '-' -> Minus
          | '*' -> Star
          | '/' -> Slash
          | '(' -> Lparen
          | ')' -> Rparen
          | _ -> failwith (Printf.sprintf "unexpected character %c" c)
        in
        Queue.add token tokens;
        go (i + 1)))
  in
  go 0;
  tokens
;;
