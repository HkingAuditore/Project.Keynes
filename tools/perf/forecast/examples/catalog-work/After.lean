def expectedWork (inputs : List (List Int)) : List (List Nat) :=
  inputs.map fun p => match p with
    | [items, orders] => [if orders == 0 then 0 else items.toNat, orders.toNat]
    | _ => []

theorem catalog_work_nonincreasing (items orders : Nat) :
    (if orders = 0 then 0 else items) ≤ items * orders := by
  cases orders with
  | zero => simp
  | succ n =>
      simp [Nat.mul_succ]
      exact Nat.le_add_left _ _
