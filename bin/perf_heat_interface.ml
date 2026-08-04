(** The pipeline end of the heat capture: reads the text of
    [perf report --stdio -F sample,sym] on stdin and writes the profile sexp
    the interface's [-perf-file] flag consumes.

    Run by cool_name.sh's perf stage:

    {v
    perf report ... -F sample,sym | perf_heat_interface.exe Greet heat.sexp
    v}

    Exits 0 on success, 1 on a malformed report, 2 on usage error, and 3 when
    fewer OCaml-attributed samples arrived than the adequacy threshold
    (default 2000, overridable via JSIP_HEAT_MIN_SAMPLES) — the caller reacts
    to 3 by re-recording with more iterations. *)

open! Core
open Sandbox_perf_heat

let default_min_samples = 2000

let min_samples () =
  match Sys.getenv "JSIP_HEAT_MIN_SAMPLES" with
  | None -> default_min_samples
  | Some value ->
    (match Int.of_string_opt value with
     | Some minimum -> minimum
     | None ->
       eprintf
         "perf_heat_interface: JSIP_HEAT_MIN_SAMPLES is not a number: %s\n"
         value;
       exit 2)
;;

let () =
  match Sys.get_argv () with
  | [| _; root_module; out_file |] ->
    let report_text = In_channel.input_all In_channel.stdin in
    (match Heat_profile.of_perf_report ~report_text ~root_module with
     | Error error ->
       eprintf "perf_heat_interface: %s\n" (Error.to_string_hum error);
       exit 1
     | Ok profile ->
       let total = Heat_profile.total_samples profile in
       let minimum = min_samples () in
       (match total >= minimum with
        | true ->
          Heat_profile.save profile ~file:out_file;
          eprintf
            "perf_heat_interface: %d OCaml-attributed samples -> %s\n"
            total
            out_file
        | false ->
          eprintf
            "perf_heat_interface: only %d OCaml-attributed samples (need \
             %d); not writing %s\n"
            total
            minimum
            out_file;
          exit 3))
  | _ ->
    eprintf
      "usage: perf_heat_interface.exe <Root_module> <out.sexp> < report.txt\n";
    exit 2
;;
