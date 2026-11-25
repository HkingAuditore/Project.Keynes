# Architecture and data contract

## Authority

`NativeCountryRuntime` is a peer of `NativeEconomyRuntime`. It owns country identity, display name,
territory, technology, cash, and goods. `CountryFacade` compiles resources and commands and exposes
read-only coarse queries. `CountryDailySystem` is a thin scheduler shell.

Only `cell.country_slot:int32` is mirrored into DataCore/MapData. `-1` means unowned. Country names,
stable IDs, CSR, technology bits, and treasury remain native.

## Dense layout

- CountryStore SoA: active, generation, stable ID, display name, territory count, cash, state version.
- External handle: `(generation << 32) | slot`; save references use stable IDs.
- Territory: dense `cell_country_slot` plus country-grouped cell CSR, rebuilt after territory commits.
- Technology: dense `country x technology` bitset.
- Goods treasury: dense `country x good` signed 64-bit fixed-point matrix.
- Scales: cash `10000`; goods `1000`.

Keep strings, Godot Objects, Dictionaries, and allocation out of hot loops. Prefer scalar C++ until a
release benchmark proves worker or SIMD work is needed.

## Bootstrap invariants

Explicit bootstrap uses parallel arrays/CSR and rejects malformed shapes, duplicate territory, water
ownership, unknown goods/technology, empty names, negative balances, and zero-territory countries.
Without explicit country data, create `country.default` / `默认国家` over every non-water cell. Keep
water unowned. An all-water map returns `country_bootstrap_no_land`.

Unowned land and enclaves are valid. Every active country must own at least one land cell.

## Commands

Supported v1 operations are create, rename, territory transfer, and technology grant. Sort by
effective day, sequence, then submission order. Preflight the entire due batch using sparse staging;
publish only after all invariants pass. A new country must gain territory in the same atomic batch.
It inherits technology from the first previous owner, or configured starting technology for unowned
land. Do not add deletion or technology revocation in v1.

## API and publication

Keep `DCWorldExt` APIs coarse: configure/bootstrap, command submit/should-run/slice/report, state
hash, reset, chunked save/restore, and snapshot queries. Query by cell or validated handle. Treasury
snapshots return only nonzero goods.

Country commits publish changed `cell.country_slot` entries and one country event. Daily economy
ticks may patch displayed numeric values; country commits may rebuild the selected Inspector summary.
