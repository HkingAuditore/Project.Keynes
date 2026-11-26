-- Inputs are the revision and a categorical tint ID. Zero means no tint supplied.
private def cacheEvents (revision tint : Option Int) : List (List Int) → List CacheForecast.Event
  | [] => []
  | [rev, color] :: tail =>
      let nextTint := if color == 0 then tint else some color
      let event := if revision != some rev then CacheForecast.Event.keyChange
                   else if nextTint != tint then .invalidate else .hold
      event :: cacheEvents (some rev) nextTint tail
  | _ :: tail => cacheEvents revision tint tail

def expectedWork (inputs : List (List Int)) : List (List Nat) :=
  (CacheForecast.builds true (cacheEvents none none inputs)).map fun n => [n, 2*n]
