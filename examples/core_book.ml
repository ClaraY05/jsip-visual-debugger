(* The same order book as [order_book.ml], written the way a Jane Street
   program actually would: [Core]'s containers rather than the stdlib's.

   It exists to show that the two are equally visible to the debugger.
   [Core.Map] is immutable, so it is recorded when a call's *result* is
   tracked -- [Map.set] below fires, [Map.find] does not. [Core.Hashtbl]
   and [Core.Queue] are mutable and re-walk on reads too, but an event
   rooted at a mutation needs a named identifier: [Hashtbl.set by_id ...]
   is recorded, [Hashtbl.set t.by_id ...] would not be. That is why the
   containers here are plain locals. *)

open! Core

type order =
  { id : int
  ; symbol : string
  ; qty : int
  }
[@@deriving sexp_of]

let () =
  let by_id = Hashtbl.create (module Int) in
  let pending = Queue.create () in
  let acme = { id = 1; symbol = "ACME"; qty = 100 } in
  let bolt = { id = 2; symbol = "BOLT"; qty = 250 } in
  Hashtbl.set by_id ~key:acme.id ~data:acme;
  Queue.enqueue pending acme;
  Hashtbl.set by_id ~key:bolt.id ~data:bolt;
  Queue.enqueue pending bolt;
  (* Both orders are reachable from three places at once -- the ladder,
     the index and the queue -- so the heap pane draws each record once
     and points the other two at it. *)
  let ladder = Map.of_alist_exn (module Int) [ 41_150, acme; 41_175, bolt ] in
  let ladder = Map.set ladder ~key:41_200 ~data:{ id = 3; symbol = "COIL"; qty = 50 } in
  let filled = Queue.dequeue_exn pending in
  Hashtbl.remove by_id filled.id;
  print_s
    [%message
      "filled" (filled : order) ~remaining:(Hashtbl.length by_id : int)
        ~levels:(Map.length ladder : int)]
;;
