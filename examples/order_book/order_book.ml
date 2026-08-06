(* A limit order book with price-time priority, built out of Core the way a
   real one is, and small enough to step through.

   The shape is taken from jsip-exchange's [Jsip_order_book.Order_book]: each
   side of each book is a [Map] from price to a [Hash_queue] of the orders
   resting at that price, so "best price" is a [Map.min_elt] and "oldest
   order at that price" is the front of the queue. A separate [Hashtbl] from
   order id to order makes a cancel O(1) without knowing what price the order
   is sitting at. That is five Core containers working together on one set of
   records:

   - [Map] from symbol to book, and from price to level;
   - [Hash_queue] for the orders queued at a price;
   - [Hashtbl] for the id index;
   - [Hash_set] for the participants who have traded;
   - [Fdeque] for the tape of recent fills.

   The heap pane is where this pays off. Every container here holds
   the *same* [order] records -- a resting order is in its price level, in
   the id index, and named by every fill it takes part in -- so the debugger
   draws each order once and points at it from each of the three places it
   appears, rather than drawing three copies.

   Run it with [./canary.sh examples/order_book/order_book.exe]. It prints
   the closing books, the tape and the P&L-ish tally, then exits.

   One thing to know when reading the code below: an event rooted at
   a *mutation* needs a named identifier to hang off, so this file binds a
   container to a name before mutating it -- [Hashtbl.set index ...] rather
   than [Hashtbl.set t.index ...]. That happens to be how you would write it
   anyway once the book functions take the index as an argument, but it is
   not an accident. Rebinding an immutable container into a record field
   ([t.books <- Map.set t.books ...]) is recorded either way, because that
   event is rooted at the result. *)

open! Core

module Order_id = struct
  module T = struct
    type t = int [@@deriving compare, equal, hash, sexp_of]
  end

  include T
  include Comparable.Make_plain (T)
  include Hashable.Make_plain (T)

  let to_string t = Int.to_string t
end

(* Prices are whole cents. Keeping them an [int] under a name means the [Map]
   of price levels is keyed by something that prints as money. *)
module Price = struct
  module T = struct
    type t = int [@@deriving compare, equal, sexp_of]
  end

  include T
  include Comparable.Make_plain (T)

  let to_string t = Printf.sprintf "%d.%02d" (t / 100) (t % 100)
end

module Participant = struct
  module T = struct
    type t = string [@@deriving compare, equal, hash, sexp_of]
  end

  include T
  include Comparable.Make_plain (T)
  include Hashable.Make_plain (T)

  let to_string t = t
end

module Symbol = struct
  module T = struct
    type t = string [@@deriving compare, equal, sexp_of]
  end

  include T
  include Comparable.Make_plain (T)

  let to_string t = t
end

module Side = struct
  type t =
    | Buy
    | Sell
  [@@deriving equal, sexp_of]

  let opposite = function Buy -> Sell | Sell -> Buy
  let to_string = function Buy -> "buy" | Sell -> "sell"
end

(* [open_size] shrinks as the order fills; [size] is what it came in for, so
   the two together say how much of the order has traded. *)
type order =
  { id : Order_id.t
  ; owner : Participant.t
  ; symbol : Symbol.t
  ; side : Side.t
  ; price : Price.t
  ; size : int
  ; mutable open_size : int
  }
[@@deriving sexp_of]

module Level = Hash_queue.Make (Order_id)

type book =
  { symbol : Symbol.t
  ; mutable bids : order Level.t Map.M(Price).t
  ; mutable asks : order Level.t Map.M(Price).t
  }

type fill =
  { taker : Participant.t
  ; maker : Participant.t
  ; symbol : Symbol.t
  ; price : Price.t
  ; size : int
  }
[@@deriving sexp_of]

let create_book symbol =
  { symbol
  ; bids = Map.empty (module Price)
  ; asks = Map.empty (module Price)
  }
;;

let levels book (side : Side.t) =
  match side with Buy -> book.bids | Sell -> book.asks
;;

let set_levels book (side : Side.t) map =
  match side with Buy -> book.bids <- map | Sell -> book.asks <- map
;;

(* Best on the bid is the highest price, best on the offer the lowest, so the
   two sides read opposite ends of the same [Map]. *)
let best_level book (side : Side.t) =
  match side with
  | Buy -> Map.max_elt (levels book side)
  | Sell -> Map.min_elt (levels book side)
;;

let crosses ~(taker : order) ~(resting_price : Price.t) =
  match taker.side with
  | Buy -> taker.price >= resting_price
  | Sell -> taker.price <= resting_price
;;

(* Walk the far side, best price first and oldest order first inside a price
   level, for as long as the incoming order still wants size and the price it
   finds is one it will pay. A level that empties out is dropped from the
   map, which is what makes the book thin as it trades.

   [index] is passed in rather than read off a record so that removing a
   filled order is a mutation of a named identifier. *)
let match_order ~index book (taker : order) =
  let resting_side = Side.opposite taker.side in
  let rec take fills =
    match best_level book resting_side with
    | None -> fills
    | Some (resting_price, level) ->
      if taker.open_size = 0 || not (crosses ~taker ~resting_price)
      then fills
      else (
        match Level.first level with
        | None ->
          set_levels
            book
            resting_side
            (Map.remove (levels book resting_side) resting_price);
          take fills
        | Some maker ->
          let size = Int.min taker.open_size maker.open_size in
          maker.open_size <- maker.open_size - size;
          taker.open_size <- taker.open_size - size;
          if maker.open_size = 0
          then (
            ignore (Level.dequeue_front level : order option);
            Hashtbl.remove index maker.id);
          if Level.is_empty level
          then
            set_levels
              book
              resting_side
              (Map.remove (levels book resting_side) resting_price);
          take
            ({ taker = taker.owner
             ; maker = maker.owner
             ; symbol = book.symbol
             ; price = resting_price
             ; size
             }
             :: fills))
  in
  List.rev (take [])
;;

(* What did not trade goes on the book, at the back of the queue for its
   price -- that is the "time" half of price-time priority. A price that had
   nothing resting at it gets a queue of its own first. *)
let rest ~index book (order : order) =
  let side_levels = levels book order.side in
  let level =
    match Map.find side_levels order.price with
    | Some level -> level
    | None -> Level.create ()
  in
  Level.enqueue_back_exn level order.id order;
  Hashtbl.set index ~key:order.id ~data:order;
  set_levels
    book
    order.side
    (Map.set side_levels ~key:order.price ~data:level)
;;

let cancel ~index book order_id =
  match Hashtbl.find index order_id with
  | None -> `No_such_order
  | Some (order : order) ->
    let side_levels = levels book order.side in
    (match Map.find side_levels order.price with
     | None -> ()
     | Some level ->
       ignore (Level.remove level order_id : [ `Ok | `No_such_key ]);
       if Level.is_empty level
       then set_levels book order.side (Map.remove side_levels order.price)
       else
         set_levels
           book
           order.side
           (Map.set side_levels ~key:order.price ~data:level));
    Hashtbl.remove index order_id;
    `Cancelled order
;;

let depth book side =
  Map.fold (levels book side) ~init:0 ~f:(fun ~key:_ ~data:level acc ->
    acc + Level.length level)
;;

(* The session around the book: one book per symbol, one id index across all
   of them, who has sent an order and who has actually traded, and a tape of
   the most recent fills.

   [seen] and [traded] are two [Hash_set]s rather than one because the
   difference between them is the interesting part -- a participant who
   quoted or rested and never got filled shows up in one and not the other. *)
let tape_length = 4

type t =
  { mutable books : book Map.M(Symbol).t
  ; index : order Hashtbl.M(Order_id).t
  ; seen : Hash_set.M(Participant).t
  ; traded : Hash_set.M(Participant).t
  ; mutable tape : fill Fdeque.t
  ; mutable next_id : int
  ; mutable filled_size : int Map.M(Participant).t
  }

let create symbols =
  { books =
      List.fold
        symbols
        ~init:(Map.empty (module Symbol))
        ~f:(fun books symbol ->
          Map.set books ~key:symbol ~data:(create_book symbol))
  ; index = Hashtbl.create (module Order_id)
  ; seen = Hash_set.create (module Participant)
  ; traded = Hash_set.create (module Participant)
  ; tape = Fdeque.empty
  ; next_id = 1
  ; filled_size = Map.empty (module Participant)
  }
;;

let book_exn t symbol = Map.find_exn t.books symbol

(* The tape keeps the last [tape_length] fills and forgets the rest, so it is
   an [Fdeque] pushed at the back and dropped from the front. *)
let record_fill t (fill : fill) =
  let traded = t.traded in
  Hash_set.add traded fill.taker;
  Hash_set.add traded fill.maker;
  t.filled_size
  <- List.fold
       [ fill.taker; fill.maker ]
       ~init:t.filled_size
       ~f:(fun totals participant ->
         Map.update totals participant ~f:(function
           | None -> fill.size
           | Some total -> total + fill.size));
  let tape = Fdeque.enqueue_back t.tape fill in
  t.tape
  <- (if Fdeque.length tape > tape_length
      then Fdeque.drop_front_exn tape
      else tape)
;;

let submit
  t
  ~owner
  ~symbol
  ~side
  ~price
  ~size
  ~(time_in_force : [ `Day | `Ioc ])
  =
  let order =
    { id = t.next_id; owner; symbol; side; price; size; open_size = size }
  in
  t.next_id <- t.next_id + 1;
  let seen = t.seen in
  Hash_set.add seen owner;
  let index = t.index in
  let book = book_exn t symbol in
  let fills = match_order ~index book order in
  List.iter fills ~f:(fun fill -> record_fill t fill);
  (match time_in_force with
   | `Ioc -> ()
   | `Day -> if order.open_size > 0 then rest ~index book order);
  order
;;

(* [submit] hands the order back so that a caller can cancel it later on;
   most of the script below has no use for it. *)
let submit_ t ~owner ~symbol ~side ~price ~size ~time_in_force =
  ignore (submit t ~owner ~symbol ~side ~price ~size ~time_in_force : order)
;;

let print_book t symbol =
  let book = book_exn t symbol in
  print_endline [%string "  %{symbol#Symbol}"];
  let side_line side =
    let entries =
      Map.to_alist
        ~key_order:
          (match (side : Side.t) with
           | Buy -> `Decreasing
           | Sell -> `Increasing)
        (levels book side)
    in
    match entries with
    | [] -> [%string "    %{side#Side}s  (empty)"]
    | entries ->
      let shown =
        List.map entries ~f:(fun (price, level) ->
          let size =
            Level.fold level ~init:0 ~f:(fun acc (order : order) ->
              acc + order.open_size)
          in
          [%string "%{price#Price}x%{size#Int}"])
      in
      let joined = String.concat ~sep:"  " shown in
      [%string "    %{side#Side}s  %{joined}"]
  in
  print_endline (side_line Sell);
  print_endline (side_line Buy)
;;

let print_report t =
  print_endline "== books at the close ==";
  Map.iter_keys t.books ~f:(fun symbol -> print_book t symbol);
  print_endline
    [%string "== tape (last %{tape_length#Int}, most recent last) =="];
  Fdeque.iter t.tape ~f:(fun (fill : fill) ->
    print_endline
      [%string
        "  %{fill.symbol#Symbol} %{fill.size#Int}@%{fill.price#Price} \
         %{fill.taker#Participant} took %{fill.maker#Participant}"]);
  print_endline "== participants ==";
  List.iter
    (List.sort (Hash_set.to_list t.seen) ~compare:Participant.compare)
    ~f:(fun participant ->
      let traded =
        match Map.find t.filled_size participant with
        | Some size when Hash_set.mem t.traded participant ->
          [%string "%{size#Int} traded"]
        | None | Some _ -> "no fills"
      in
      print_endline [%string "  %{participant#Participant} %{traded}"]);
  print_endline "== still resting ==";
  Map.iteri t.books ~f:(fun ~key:symbol ~data:book ->
    let bids = depth book Buy in
    let asks = depth book Sell in
    print_endline
      [%string "  %{symbol#Symbol} bids=%{bids#Int} asks=%{asks#Int}"]);
  let indexed = Hashtbl.length t.index in
  print_endline [%string "  indexed %{indexed#Int} orders in all"]
;;

(* A scripted session: quote both symbols, cross the spread from both sides,
   pull an order, then sweep one book with an immediate-or-cancel priced
   through several levels. Nothing is random, so two runs produce the same
   dump. *)
let run () =
  let aapl = "AAPL" in
  let tsla = "TSLA" in
  let t = create [ aapl; tsla ] in
  print_endline "== session ==";
  let quote ~symbol ~mid ~levels_deep =
    List.iter
      (List.range 1 (levels_deep + 1))
      ~f:(fun level ->
        let offset = level * 25 in
        let size = 100 * level in
        let owner = "MarketMaker" in
        submit_
          t
          ~owner
          ~symbol
          ~side:Buy
          ~price:(mid - offset)
          ~size
          ~time_in_force:`Day;
        submit_
          t
          ~owner
          ~symbol
          ~side:Sell
          ~price:(mid + offset)
          ~size
          ~time_in_force:`Day)
  in
  quote ~symbol:aapl ~mid:15_000 ~levels_deep:4;
  quote ~symbol:tsla ~mid:24_050 ~levels_deep:3;
  (* Alice lifts the AAPL offer and takes more than the first level holds, so
     this fill walks two price levels. *)
  submit_
    t
    ~owner:"Alice"
    ~symbol:aapl
    ~side:Buy
    ~price:15_060
    ~size:250
    ~time_in_force:`Day;
  (* Bob hits the TSLA bid for less than is resting there, which leaves the
     market maker's order on the book with part of it gone. *)
  submit_
    t
    ~owner:"Bob"
    ~symbol:tsla
    ~side:Sell
    ~price:24_000
    ~size:60
    ~time_in_force:`Day;
  (* Charlie joins inside the spread rather than crossing it, so this one
     rests and becomes the best bid. Then he pulls it. *)
  let charlie =
    submit
      t
      ~owner:"Charlie"
      ~symbol:aapl
      ~side:Buy
      ~price:14_990
      ~size:75
      ~time_in_force:`Day
  in
  let index = t.index in
  (match cancel ~index (book_exn t aapl) charlie.id with
   | `No_such_order -> print_endline "  (charlie's order was already gone)"
   | `Cancelled (order : order) ->
     print_endline
       [%string
         "  cancelled %{order.id#Order_id} for %{order.owner#Participant}"]);
  (* An immediate-or-cancel priced through the whole TSLA offer ladder: it
     takes every level it can reach in one call and the remainder is
     discarded rather than rested. *)
  submit_
    t
    ~owner:"Bob"
    ~symbol:tsla
    ~side:Buy
    ~price:24_200
    ~size:900
    ~time_in_force:`Ioc;
  print_report t
;;

let () = run ()
