(* Turns "let a = 2 + 3 * (b - 1)" into a list of tokens. *)

type token =
  | Number of int
  | Ident of string
  | Keyword_let
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
  let rec go i acc =
    if i >= String.length input
    then List.rev acc
    else (
      let c = input.[i] in
      if c = ' '
      then go (i + 1) acc
      else if is_digit c
      then (
        let text, next = read_while input is_digit i in
        go next (Number (int_of_string text) :: acc))
      else if is_alpha c
      then (
        let text, next = read_while input is_alpha i in
        let token = if text = "let" then Keyword_let else Ident text in
        go next (token :: acc))
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
        go (i + 1) (token :: acc)))
  in
  go 0 []
;;
