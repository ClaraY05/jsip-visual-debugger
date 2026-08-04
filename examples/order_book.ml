(* A toy single-symbol order book in the shape of jsip-exchange's
   matching engine: bids and asks as price-level maps, price-time
   priority within a level, an incoming order crossing the far side
   while it is marketable and resting afterwards. The maps are what
   [-visual-replay] tracks, so every rest and every fill is a step in
   the debugger, with the book's shape beside it. *)

module Price_map = Map.Make (Int)

type side =
  | Buy
  | Sell

type order =
  { id : int
  ; side : side
  ; price : int
  ; size : int
  }

(* each price level holds the resting sizes in arrival order *)
type book =
  { bids : int list Price_map.t
  ; asks : int list Price_map.t
  }

let empty = { bids = Price_map.empty; asks = Price_map.empty }

let rest book (order : order) =
  let level sizes = Some (Option.value ~default:[] sizes @ [ order.size ]) in
  match order.side with
  | Buy -> { book with bids = Price_map.update order.price level book.bids }
  | Sell -> { book with asks = Price_map.update order.price level book.asks }

(* the most aggressively priced level an incoming order could trade
   against: the lowest ask for a buy, the highest bid for a sell *)
let best book side =
  match side with
  | Buy -> Price_map.min_binding_opt book.asks
  | Sell -> Price_map.max_binding_opt book.bids

let marketable order ~level_price =
  match order.side with
  | Buy -> order.price >= level_price
  | Sell -> order.price <= level_price

(* write a level's remaining sizes back, dropping the level when empty *)
let consume book side ~price ~sizes =
  let update map =
    match sizes with
    | [] -> Price_map.remove price map
    | _ :: _ -> Price_map.add price sizes map
  in
  match side with
  | Buy -> { book with asks = update book.asks }
  | Sell -> { book with bids = update book.bids }

let rec submit book (order : order) =
  let crossed =
    match best book order.side with
    | Some (level_price, resting :: deeper) when marketable order ~level_price
      ->
      Some (level_price, resting, deeper)
    | Some _ | None -> None
  in
  match crossed with
  | None -> rest book order
  | Some (level_price, resting, deeper) ->
    let traded = min order.size resting in
    Printf.printf "trade: order %d takes %d @ %d\n" order.id traded
      level_price;
    let sizes =
      match resting - traded with
      | 0 -> deeper
      | left -> left :: deeper
    in
    let book = consume book order.side ~price:level_price ~sizes in
    (match order.size - traded with
     | 0 -> book
     | remaining -> submit book { order with size = remaining })

let () =
  let orders =
    [ { id = 1; side = Sell; price = 101; size = 10 }
    ; { id = 2; side = Sell; price = 102; size = 5 }
    ; { id = 3; side = Buy; price = 100; size = 7 }
    ; { id = 4; side = Buy; price = 102; size = 12 }
    ; { id = 5; side = Sell; price = 99; size = 20 }
    ]
  in
  let final = List.fold_left submit empty orders in
  Printf.printf "resting: %d bid levels, %d ask levels\n"
    (Price_map.cardinal final.bids) (Price_map.cardinal final.asks)
