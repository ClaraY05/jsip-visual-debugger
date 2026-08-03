(* Two containers over the same records, for the pipeline's second demo.

   Each [let] of an [order] fires its own event -- values of a type the
   program declared are tracked for their own sake, not only as some
   container's contents -- and each [Hashtbl]/[Queue] call fires another.
   Because both containers hold the SAME record blocks, the heap pane
   draws each order once and points at it from wherever it comes up
   again, which is the thing worth seeing here.

   Both containers are bound to plain names on purpose: an event rooted
   at a MUTATION needs a named identifier, so [Hashtbl.replace book ...]
   is recorded where [Hashtbl.replace t.book ...] would be silent. *)

type order =
  { id : int
  ; symbol : string
  ; qty : int
  }

let () =
  let book = Hashtbl.create 8 in
  let pending = Queue.create () in
  let acme = { id = 1; symbol = "ACME"; qty = 100 } in
  let bolt = { id = 2; symbol = "BOLT"; qty = 250 } in
  Hashtbl.replace book acme.id acme;
  Queue.add acme pending;
  Hashtbl.replace book bolt.id bolt;
  Queue.add bolt pending;
  let filled = Queue.pop pending in
  Hashtbl.remove book filled.id;
  Printf.printf
    "filled %s x%d, %d still on the book\n"
    filled.symbol
    filled.qty
    (Hashtbl.length book)
;;
