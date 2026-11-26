namespace CacheForecast

inductive Event where
  | keyChange | hold | invalidate
  deriving DecidableEq, Repr

-- A move takes priority over invalidation in the same frame. The result is
-- (needs rebuilding next frame, completed builds in this frame).
def step (dirty : Bool) : Event → Bool × Nat
  | .keyChange => (true, 0)
  | .invalidate => (false, 1)
  | .hold => (false, if dirty then 1 else 0)

def builds (dirty : Bool) : List Event → List Nat
  | [] => []
  | e :: es =>
    let (next, n) := step dirty e
    n :: builds next es

def total (dirty : Bool) : List Event → Nat
  | [] => 0
  | e :: es => (step dirty e).2 + total (step dirty e).1 es

theorem clean_holds (n : Nat) : total false (List.replicate n .hold) = 0 := by
  induction n with
  | zero => rfl
  | succ n ih => simpa [List.replicate, total, step] using ih

-- For either initial cache state, a move and one or more stable frames
-- cause exactly one build, however long the stable tail lasts.
theorem change_then_hold (dirty : Bool) (n : Nat) :
    total dirty (.keyChange :: .hold :: List.replicate n .hold) = 1 := by
  simp [total, step, clean_holds]

end CacheForecast
