open! Core

module Entry = struct
  type t =
    { module_path : string list
    ; kind : Ocaml_symbol.Kind.t
    ; samples : int
    }
  [@@deriving sexp]
end

type t =
  { version : int
  ; root_module : string
  ; entries : Entry.t list
  }
[@@deriving sexp]

let current_version = 1

let of_perf_report ~report_text ~root_module =
  let open Or_error.Let_syntax in
  let%map rows = Perf_report.parse report_text in
  let tally =
    List.fold
      rows
      ~init:Ocaml_symbol.Map.empty
      ~f:(fun tally (samples, symbol_name) ->
        match Ocaml_symbol.of_symbol_name symbol_name with
        | None -> tally
        | Some symbol ->
          Map.update tally symbol ~f:(fun sum ->
            samples + Option.value sum ~default:0))
  in
  let entries =
    Map.to_alist tally
    |> List.map ~f:(fun ({ Ocaml_symbol.module_path; kind }, samples) ->
      { Entry.module_path; kind; samples })
    |> List.sort ~compare:(fun (a : Entry.t) b ->
      Int.descending a.samples b.samples)
  in
  { version = current_version; root_module; entries }
;;

let total_samples t =
  List.sum (module Int) t.entries ~f:(fun entry -> entry.samples)
;;

let save t ~file =
  Out_channel.write_all file ~data:(Sexp.to_string_hum (sexp_of_t t) ^ "\n")
;;
