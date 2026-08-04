(** Parses the text [perf report --stdio -F sample,sym] prints.

    The report is one aggregated line per symbol,

    {v
              318  [.] Greet.shout_2_8_code
    v}

    plus [#]-prefixed headers and blank lines. {!parse} keeps every data row
    as a raw [(samples, symbol_name)] pair — filtering what counts as OCaml
    code is {!Ocaml_symbol}'s job — and errors loudly on a line it does not
    recognize, so a perf output-format change fails the pipeline visibly
    instead of silently dropping heat. *)

open! Core

val parse : string -> (int * string) list Or_error.t
