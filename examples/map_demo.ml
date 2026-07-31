(* A small stdlib-Map program for the replay pipeline: build a map, double
   every value with a fold, then drop a key. Each [M.*] call fires a replay
   event carrying a walked snapshot of the map, which the TUI's heap pane
   renders step by step. The print at the end goes to the terminal, not the
   dump -- sinks are separate. *)

module M = Map.Make (String)

let () =
  let inventory = M.add "figs" 7 (M.add "dates" 3 M.empty) in
  let doubled =
    M.fold (fun k v acc -> M.add k (2 * v) acc) inventory M.empty
  in
  let trimmed = M.remove "dates" doubled in
  Printf.printf "figs on hand: %d\n" (M.find "figs" trimmed)
;;
