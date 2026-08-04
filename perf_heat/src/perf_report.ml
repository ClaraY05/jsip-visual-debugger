open! Core

(* the second column is perf's privilege-level marker: [.] user, [k] kernel,
   [g]/[H] guest — one character in brackets *)
let is_marker token =
  String.length token = 3
  && Char.equal token.[0] '['
  && Char.equal token.[2] ']'
;;

let parse_line line =
  match
    String.split line ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
  with
  | samples :: marker :: symbol_words
    when is_marker marker && not (List.is_empty symbol_words) ->
    (match Int.of_string_opt samples with
     | Some samples -> Ok (samples, String.concat symbol_words ~sep:" ")
     | None ->
       Or_error.error_s
         [%message
           "Perf_report: sample count is not a number" (line : string)])
  | _ ->
    Or_error.error_s
      [%message "Perf_report: unrecognized line" (line : string)]
;;

let parse text =
  String.split_lines text
  |> List.filter ~f:(fun line ->
    let stripped = String.strip line in
    (not (String.is_empty stripped))
    && not (String.is_prefix stripped ~prefix:"#"))
  |> List.map ~f:parse_line
  |> Or_error.all
;;
