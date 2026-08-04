(** Turns a perf report over the natively compiled, unmodified program into
    the per-function compute profile ([heat.sexp]) the visual debugger's
    interface colors its call stack with.

    [cool_name.sh] runs perf and pipes the report through
    [bin/perf_heat_interface.exe], which drives
    {!Heat_profile.of_perf_report}: {!Perf_report} parses the rows,
    {!Ocaml_symbol} decodes each symbol name, and {!Heat_profile} aggregates
    and writes the sexp contract file. *)

module Heat_profile = Heat_profile
module Ocaml_symbol = Ocaml_symbol
module Perf_report = Perf_report
