open! Core

module Kind = struct
  type t =
    | Named of string
    | Anonymous of
        { file_path : string
        ; line_number : int
        ; char_range : int * int
        }
  [@@deriving sexp, compare, equal]
end

module T = struct
  type t =
    { module_path : string list
    ; kind : Kind.t
    }
  [@@deriving sexp, compare, equal]
end

include T

let hex_value char =
  match char with
  | '0' .. '9' -> Some (Char.to_int char - Char.to_int '0')
  | 'a' .. 'f' -> Some (Char.to_int char - Char.to_int 'a' + 10)
  | 'A' .. 'F' -> Some (Char.to_int char - Char.to_int 'A' + 10)
  | _ -> None
;;

(* "$5b" -> "["; a "$" not followed by two hex digits passes through *)
let decode_escapes s =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec go i =
    match i < len with
    | false -> ()
    | true ->
      let escape =
        match Char.equal s.[i] '$' && i + 2 < len with
        | false -> None
        | true -> Option.both (hex_value s.[i + 1]) (hex_value s.[i + 2])
      in
      (match escape with
       | Some (high, low) ->
         Buffer.add_char buf (Char.of_int_exn ((high * 16) + low));
         go (i + 3)
       | None ->
         Buffer.add_char buf s.[i];
         go (i + 1))
  in
  go 0;
  Buffer.contents buf
;;

let chop_trailing_uid s =
  match String.rindex s '_' with
  | None -> None
  | Some i ->
    let digits = String.subo s ~pos:(i + 1) in
    (match
       (not (String.is_empty digits))
       && String.for_all digits ~f:Char.is_digit
       && i > 0
     with
     | true -> Some (String.subo s ~pos:0 ~len:i)
     | false -> None)
;;

(* "shout_2_8_code" -> Some "shout". A last component without the compiler's
   _<uid>_<uid>_code tail is not a function's code symbol (entry, code_begin,
   frametable, data, ...). *)
let chop_code_suffix base =
  let open Option.Let_syntax in
  let%bind rest = String.chop_suffix base ~suffix:"_code" in
  let%bind rest = chop_trailing_uid rest in
  let%bind rest = chop_trailing_uid rest in
  match String.is_empty rest with true -> None | false -> Some rest
;;

(* "fn[greet.ml:5,27--33]" -> the definition site it names *)
let parse_anonymous base =
  let open Option.Let_syntax in
  let%bind inner = String.chop_prefix base ~prefix:"fn[" in
  let%bind inner = String.chop_suffix inner ~suffix:"]" in
  let%bind file_line, range = String.rsplit2 inner ~on:',' in
  let%bind file_path, line = String.rsplit2 file_line ~on:':' in
  let%bind dashes = String.substr_index range ~pattern:"--" in
  let%bind line_number = Int.of_string_opt line in
  let%bind char_start = Int.of_string_opt (String.subo range ~len:dashes) in
  let%bind char_end =
    Int.of_string_opt (String.subo range ~pos:(dashes + 2))
  in
  match String.is_empty file_path with
  | true -> None
  | false ->
    Some
      (Kind.Anonymous
         { file_path; line_number; char_range = char_start, char_end })
;;

(* split on [sep] pattern; components keep their text verbatim *)
let split_on_pattern s ~sep =
  String.substr_index_all s ~may_overlap:false ~pattern:sep
  |> List.fold_right
       ~init:(String.length s, [])
       ~f:(fun cut (upto, acc) ->
         let piece =
           String.sub
             s
             ~pos:(cut + String.length sep)
             ~len:(upto - cut - String.length sep)
         in
         cut, piece :: acc)
  |> fun (upto, acc) -> String.subo s ~len:upto :: acc
;;

(* split on '.' outside brackets: the anonymous-function marker embeds a file
   name ("greet.ml") whose dot must not cut *)
let split_qualified s =
  let components = Queue.create () in
  let buf = Buffer.create (String.length s) in
  let depth = ref 0 in
  String.iter s ~f:(fun char ->
    match char with
    | '[' ->
      incr depth;
      Buffer.add_char buf char
    | ']' ->
      decr depth;
      Buffer.add_char buf char
    | '.' when !depth = 0 ->
      Queue.enqueue components (Buffer.contents buf);
      Buffer.clear buf
    | char -> Buffer.add_char buf char);
  Queue.enqueue components (Buffer.contents buf);
  Queue.to_list components
;;

let is_module_name s = (not (String.is_empty s)) && Char.is_uppercase s.[0]

let make ~module_path ~base =
  let open Option.Let_syntax in
  let%bind base = chop_code_suffix base in
  match
    (not (List.is_empty module_path))
    && List.for_all module_path ~f:is_module_name
  with
  | false -> None
  | true ->
    let kind =
      match parse_anonymous base with
      | Some anonymous -> anonymous
      | None -> Kind.Named base
    in
    Some { module_path; kind }
;;

let of_raw_mangled name =
  let open Option.Let_syntax in
  let%bind rest = String.chop_prefix name ~prefix:"caml" in
  match String.is_empty rest || not (Char.is_uppercase rest.[0]) with
  | true -> None
  | false ->
    let components =
      split_on_pattern rest ~sep:"__" |> List.map ~f:decode_escapes
    in
    (match List.drop_last components, List.last components with
     | Some module_path, Some base when not (List.is_empty module_path) ->
       make ~module_path ~base
     | _, _ -> None)
;;

let of_demangled name =
  match split_qualified name with
  | [] | [ _ ] -> None
  | components ->
    (match List.drop_last components, List.last components with
     | Some module_path, Some base -> make ~module_path ~base
     | _, _ -> None)
;;

let of_symbol_name name =
  match String.contains name '@' || String.contains name ' ' with
  | true -> None
  | false ->
    (match of_raw_mangled name with
     | Some t -> Some t
     | None -> of_demangled name)
;;

include Comparable.Make (T)
