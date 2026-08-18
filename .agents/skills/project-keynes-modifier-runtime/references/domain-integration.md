# Domain Integration

## Climate

Apply `climate.cell.radiative_target` after base radiative target and season offset, before clamp
and thermal inertia. Keep scalar C++, production thread, async pure kernel, and GDScript fallback
aligned. Async receives frozen per-cell add/factor POD arrays. Removal restores target input but
does not rewind temperature, snow, or energy.

## Country To Economy

Country freezes generation-safe handles and `country.economy_output_factor`. Economy converts
the factor to Q16 at `capture_country_epoch()`. Never query the Country store in cohort/building
inner loops.

## Building Output

Use `effective_building_output_quantity()` or its target variant for actual output and every
forecast: wage affordability, survival capacity, working capital, investment revenue/output,
issuance, recovery, and liquidation. Combine country and building factors before existing
fixed-point goods settlement. Do not modify cash or goods directly.

Refresh BuildingGroup cached handle/factor at epoch capture, after topology rebuild, and after
restore. Retire identity when the group disappears.

Technology-authored `country.output.building.<building_id>_factor` stats are resolved for every stable
building ID during economy configuration and frozen as one country×building-type Q16 table at epoch
capture. Include that factor in both cached group output and target-forecast output. Do not resolve the
stable key or query the Country store inside a building loop.

`value_conversion` is not currently passed into the native catalog. Convert economy values through
the existing deterministic Q16 helper and never assume automatic catalog-driven conversion.

## Gameplay

Register explicit native objects and base stats. No Godot Object pointer or arbitrary property
reflection. Unregistering an object performs entity cleanup and records the event. Add an
archetype stat allow-list before exposing diverse gameplay archetypes beyond the current generic
stat.
