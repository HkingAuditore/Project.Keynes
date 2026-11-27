// Reference passes and diagnostic benchmark declarations.

    // ---- bindings: demo ----
    // Tile data recorder CSV encoder. GDScript remains the authority for
    // selecting MapData SoA arrays and fixed diagnostic columns; C++ only
    // formats one full tick worth of numeric rows into UTF-8 CSV bytes.
    //
    // Returns an empty PackedByteArray on invalid input so the GDScript caller
    // can fall back to the reference formatter.
    godot::PackedByteArray encode_tile_csv_rows(godot::Dictionary knobs);
    // ─── Mode-B reference implementation: temp_drift_pass ────────────────
    // The minimal "hello world" pass that validates the full Owned-by-C++
    // communication contract end-to-end. Adds `drift_amount` to every
    // element of `_slots[CELL_TEMP].arr_f32` via a tight ptrw() loop with
    // ZERO Variant operations and ZERO obj.set() flushes.
    //
    // This is NOT a game feature. It exists so:
    //   1. We have a reference C++ writer to copy-paste from.
    //   2. We can bit-precisely cross-check against a GDScript replica
    //      (addition is exact, no FP drift).
    //   3. `docs/architecture/current-state.md` §12 documents this exact code as
    //      the canonical Mode-B template.
    //
    // Safety: if the slot id (looked up by StringName "cell_temp") is not
    // registered, the call is a no-op (no crash, no error spam).
    void run_temp_drift_pass(float drift_amount);
    // ─── Mode-B reference implementation: thermal_gradient_pass (Pass #2) ─
    // Pass #2 stresses the four real-business complexities that Pass #1
    // intentionally skipped:
    //   1. multi-input SoA  : reads BOTH cell_temp AND cell_elevation
    //   2. neighbour access : 4-neighbour central difference (clamp-to-edge)
    //   3. write new comp   : writes to cell_demo_thermal_gradient
    //   4. overlay surfaceable: result lives on a real component slot, so
    //                          the GDScript-side baker can sample it through
    //                          snapshot_f32() and feed it to the data overlay.
    //
    // Per-cell formula (mirrors performance-charter §12.6 spec):
    //   grad_x = (T_east - T_west) * 0.5    (clamp-to-edge at borders)
    //   grad_y = (T_south - T_north) * 0.5  (clamp-to-edge at borders)
    //   amp    = 1 + elevation_gain * cell_elevation[i]
    //   out    = clamp(sqrt(grad_x*grad_x + grad_y*grad_y) * amp * normalize_k, 0, 1)
    //
    // Hot-loop discipline (copy verbatim into new "with-neighbour" passes):
    //   * Resolve all slot ids ONCE before the loop.
    //   * Take ONE ptr() per read buffer + ONE ptrw() per write buffer.
    //   * Inner loop accesses neighbours by integer index ONLY (no Variant,
    //     no view_f32() per cell, no map->get() per cell).
    //   * Borders use "self-substitute" (Tn := T at y==0 etc.) instead of
    //     conditional branches — avoids both OOB and modulo-wrap artefacts.
    //
    // Safety: if any of the three slots is not registered or sizes do not
    // match grid_w * grid_h, the call is a no-op + a single push_warning.
    // No crash, no exception, no half-written buffer.
    void run_thermal_gradient_pass(int grid_w,
                                   int grid_h,
                                   float elevation_gain,
                                   float normalize_k);
    // ─── Mode-B reference implementation: demo_complex_pass (Pass #3) ─────
    // Pass #3 keeps every piece of Pass #2's communication scaffolding
    // (component slot, overlay mode, climate switch, baker, tick hook,
    // performance-charter §12.6 entry) and ONLY upgrades the kernel from
    // a one-shot 4-neighbour gradient to an iterated anisotropic-diffusion
    // + multi-scale wind approximation. The point is to push real ops/cell
    // up two orders of magnitude (~10 → ~2400 at default knobs) so the
    // user can both (a) see richer overlay patterns and (b) probe how far
    // C++ single-threaded can scale before climate Pass-A is revisited.
    //
    // Per-step formula (mirrors performance-charter §12.6.6 spec):
    //   for it in 0..iterations-1:
    //     smooth[i] = sum(src[nb] * gauss_weight[dx,dy]) / sum(gauss_weight)
    //     gx, gy   = sobel_3x3(src, x, y)                      (clamp-to-edge)
    //     rotate (gx, gy) by 90° * coriolis_strength * sgn(y - h/2)
    //     damp     = 1 - terrain_drag * cell_elevation[i]
    //     dst[i]   = smooth[i] + (gx' + gy') * damp * 0.05      (step constant)
    //   normalize last buffer to [0,1] then apply (1+gain*elev)*k + clamp.
    //
    // Knob clamps (silently corrected, single push_warning per process):
    //   iterations   ∈ [1, 64]   (default 16)
    //   kernel_radius∈ [1, 5]    (default 2  → 5×5 neighbourhood)
    //   coriolis     ∈ [-1, 1]   (default 0.5)
    //   terrain_drag ∈ [0, 1]    (default 0.6)
    //   elevation_gain / normalize_k: passed through unchanged from Pass #2.
    //
    // Hot-loop discipline (verbatim from §12.6 template):
    //   * Resolve all slot ids ONCE before the iteration loop.
    //   * Pre-compute the (2r+1)² Gaussian kernel ONCE on the C-stack array.
    //   * Two std::vector<float> ping-pong buffers, allocated ONCE per call.
    //   * Inner loop: only ptr/ptrw + integer index + table lookup. NO
    //     Variant, NO obj.set, NO map->get per cell.
    //   * Borders use clamp-to-edge (Neumann BC) — same as Pass #2.
    //
    // BIT-EQUAL DISCIPLINE: every intermediate runs in double on the C++
    // side and is only narrowed back to float at the FINAL store, mirroring
    // GDScript's implicit-double arithmetic in PackedFloat32Array.
    //
    // Safety: same as Pass #2 — missing slot / dtype mismatch / size
    // mismatch all yield no-op + push_warning. No crash, no half-written
    // buffer.
    void run_demo_complex_pass(int grid_w,
                               int grid_h,
                               int iterations,
                               int kernel_radius,
                               float coriolis_strength,
                               float terrain_drag,
                               float elevation_gain,
                               float normalize_k);
    // ─── DOTS-A1 EXPERIMENT: archetype-filtered demo_complex_pass ─────────
    // Identical algorithm to `run_demo_complex_pass` (same kernel, same
    // bit-equal contract), with ONE additional discipline: cells whose
    // `_entity_archetype[i]` does not equal `target_archetype` are SKIPPED
    // — their output slot is set to 0.0f and they do not contribute to the
    // post-iter normalization min/max either.
    //
    // Special semantics for `target_archetype`:
    //   ≥ 0  : only cells with _entity_archetype[i] == target_archetype run.
    //   < 0  : "no filter" — every cell runs (= equivalent to vanilla
    //          `run_demo_complex_pass`, used as the bit-equal control row).
    //
    // Why a separate function (not an extra param to the vanilla pass):
    //   * Vanilla `run_demo_complex_pass` is the canonical Mode-B template
    //     reference quoted verbatim in performance-charter §12.6.6 — we do
    //     not want to perturb its hot-loop layout.
    //   * The archetype branch adds a load+compare per cell; keeping it in
    //     a sibling function makes the cost obvious in the bench numbers.
    //
    // Safety: same as vanilla — missing slot / dtype mismatch / size
    // mismatch all yield no-op + push_warning. If `_entity_archetype.size()`
    // is smaller than the cell count and `target_archetype >= 0`, the call
    // is a no-op + push_warning (defensive: archetype assignment hasn't
    // happened yet).
    void run_demo_complex_pass_archetyped(int grid_w,
                                          int grid_h,
                                          int iterations,
                                          int kernel_radius,
                                          float coriolis_strength,
                                          float terrain_drag,
                                          float elevation_gain,
                                          float normalize_k,
                                          int target_archetype);
    // ─── Phase 3a Step 0: alias spike (TEMPORARY — to be removed) ─────────
    // Three variants probe whether `obj.set(prop, arr)` followed by
    // `arr.ptrw()[i] = v` keeps the buffer aliased between obj.<prop> and
    // the C++-side `arr` reference. Real result drives the bind_map_data
    // strategy in Step 1. See plan/dots-roadmap-to-gdextension.
    //
    // All three return the value seen by the GDScript side AFTER the C++
    // mutation, so the caller can simply compare against the sentinel.
    //   v1 : naive   — get, set, ptrw-write
    //   v2 : release — get, set, drop local ref, re-get, ptrw-write
    //   v3 : write-then-set — get, ptrw-write, set
    float _spike_alias_v1_naive          (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);
    float _spike_alias_v2_release        (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);
    float _spike_alias_v3_write_then_set (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);
    // ─── Phase 3a Step 1: alias verification helper (TEMPORARY) ──────────
    // Writes `sentinel` into _slots[comp_id].arr_f32[idx] via ptrw() — the
    // same path that hot loops will use. The companion test reads back via
    // GDScript-side `map.<prop>[idx]` to confirm the alias survives a pure
    // C++ mutation (no obj.set call after the write). If the test PASSes,
    // the bind_map_data push-back contract is correct: GDScript and C++
    // share the buffer, no per-write set needed.
    // Removed once Step 1 validation is signed off (along with the spike).
    float _debug_poke_f32(int comp_id, int idx, float sentinel);
    // T1b: same as _debug_poke_f32, but performs map_data->set(prop_name,
    // s.arr_f32) immediately after the ptrw() write to push the (possibly
    // detached) buffer back to the GDScript side. Probes whether
    // "write-then-set per pass" is the correct alias contract — if T1b
    // PASSes while T1 FAILs, then bind_map_data's one-time push-back is
    // insufficient and every C++ hot pass must re-set on exit.
    // Looks up comp_id → property_name via the BIND_TABLE.
    float _debug_poke_f32_with_flush(int comp_id, int idx, float sentinel);
    // ─── Phase-3 micro-bench API ────────────────────────────────────────
    // These are NOT production paths; they exist solely so tmp/bench_*.gd
    // can compare three optimisation strategies head-to-head:
    //   B-scalar : C++ tight loop, ptrw(), naive scalar code (compiler may
    //              auto-vectorise depending on flags / loop shape).
    //   B-simd   : C++ tight loop with explicit AVX2/SSE2 intrinsics.
    //   C-thread : same as B-simd but split across WorkerThreadPool workers.
    //
    // Workload model (mimics climate Pass-A's per-cell math):
    //   new[i] = base + lat[i]*k1 + (sum of 6 nb of prev[i])*k2 + season
    //
    // Inputs are passed explicitly (not via bind_map_data) so the bench can
    // run standalone without a real MapData. Returns the bench-internal
    // elapsed milliseconds (whatever the inside loop took, excluding the
    // GDScript dispatch overhead) — caller still wraps in get_ticks_usec
    // for a true end-to-end measurement.
    void bench_pass_a_full_scalar(int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season);
    void bench_pass_a_full_simd  (int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season);
    void bench_pass_a_full_thread(int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season,
                                  int n_tasks);
    void bench_pass_a_indexed_scalar(int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season);
    void bench_pass_a_indexed_simd  (int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season);
    void bench_pass_a_indexed_thread(int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season,
                                     int n_tasks);
