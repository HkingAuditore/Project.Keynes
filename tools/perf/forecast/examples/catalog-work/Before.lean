def expectedWork (inputs : List (List Int)) : List (List Nat) :=
  inputs.map fun p => match p with
    | [items, orders] => [items.toNat * orders.toNat, orders.toNat]
    | _ => []
