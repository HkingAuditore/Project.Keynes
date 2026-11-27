godot::Dictionary DCWorldExt::patch_enum_atlas_axes(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["dirty_cells"] = 0;
    out["dirty_pixels"] = 0;
    out["biome_dirty"] = 0;
    out["vegetation_dirty"] = 0;
    out["cover_dirty"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("n_pix") ||
        !knobs.has("cell_first_px") || !knobs.has("cell_px_count") ||
        !knobs.has("flat_px_indices") || !knobs.has("enum_atlas_data")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const int n_pix = int(knobs["n_pix"]);
    const bool run_biome = bool(knobs.get("run_biome", false));
    const bool run_vegetation = bool(knobs.get("run_vegetation", false));
    const bool run_cover = bool(knobs.get("run_cover", false));
    if (n_cells <= 0 || n_pix <= 0) return fail("invalid n_cells/n_pix");
    if (!run_biome && !run_vegetation && !run_cover) return fail("no axis enabled");

    PackedInt32Array first_px = knobs["cell_first_px"];
    PackedInt32Array px_count = knobs["cell_px_count"];
    PackedInt32Array flat_px = knobs["flat_px_indices"];
    PackedByteArray enum_data = knobs["enum_atlas_data"];
    if (first_px.size() < n_cells || px_count.size() < n_cells) return fail("cell CSR size < n_cells");
    if (enum_data.size() != n_pix * 4) return fail("enum_atlas_data size mismatch");

    PackedByteArray biome_buf = knobs.get("biome_buffer", PackedByteArray());
    PackedByteArray vegetation_buf = knobs.get("vegetation_buffer", PackedByteArray());
    PackedByteArray cover_buf = knobs.get("cover_buffer", PackedByteArray());
    if (run_biome && biome_buf.size() != n_pix) return fail("biome_buffer size mismatch");
    if (run_vegetation && vegetation_buf.size() != n_pix) return fail("vegetation_buffer size mismatch");
    if (run_cover && cover_buf.size() != n_pix) return fail("cover_buffer size mismatch");

    PackedByteArray prev_biome = knobs.get("prev_biome", PackedByteArray());
    PackedByteArray prev_vegetation = knobs.get("prev_vegetation", PackedByteArray());
    PackedByteArray prev_cover = knobs.get("prev_cover", PackedByteArray());
    const bool prev_biome_valid = prev_biome.size() == n_cells;
    const bool prev_vegetation_valid = prev_vegetation.size() == n_cells;
    const bool prev_cover_valid = prev_cover.size() == n_cells;
    if (run_biome && !prev_biome_valid) prev_biome.resize(n_cells);
    if (run_vegetation && !prev_vegetation_valid) prev_vegetation.resize(n_cells);
    if (run_cover && !prev_cover_valid) prev_cover.resize(n_cells);

    const int sid_terrain = run_biome ? component_id(StringName("cell_terrain")) : -1;
    const int sid_vegetation = run_vegetation ? component_id(StringName("cell_vegetation")) : -1;
    const int sid_cover = run_cover ? component_id(StringName("cell_cover")) : -1;
    if (run_biome && sid_terrain < 0) return fail("missing slot id cell_terrain");
    if (run_vegetation && sid_vegetation < 0) return fail("missing slot id cell_vegetation");
    if (run_cover && sid_cover < 0) return fail("missing slot id cell_cover");

    const uint8_t *TERR = nullptr;
    const uint8_t *VEG = nullptr;
    const uint8_t *COV = nullptr;
    if (run_biome) {
        Slot &s = _slots.write[sid_terrain];
        if (s.arr_u8.size() < n_cells) return fail("terrain slot too small");
        TERR = s.arr_u8.ptr();
    }
    if (run_vegetation) {
        Slot &s = _slots.write[sid_vegetation];
        if (s.arr_u8.size() < n_cells) return fail("vegetation slot too small");
        VEG = s.arr_u8.ptr();
    }
    if (run_cover) {
        Slot &s = _slots.write[sid_cover];
        if (s.arr_u8.size() < n_cells) return fail("cover slot too small");
        COV = s.arr_u8.ptr();
    }

    const int32_t * const FIRST = first_px.ptr();
    const int32_t * const CNT = px_count.ptr();
    const int32_t * const FLAT = flat_px.ptr();
    const int flat_n = flat_px.size();
    uint8_t * const ED = enum_data.ptrw();
    uint8_t *BB = run_biome ? biome_buf.ptrw() : nullptr;
    uint8_t *VB = run_vegetation ? vegetation_buf.ptrw() : nullptr;
    uint8_t *CB = run_cover ? cover_buf.ptrw() : nullptr;
    uint8_t *PB = run_biome ? prev_biome.ptrw() : nullptr;
    uint8_t *PV = run_vegetation ? prev_vegetation.ptrw() : nullptr;
    uint8_t *PC = run_cover ? prev_cover.ptrw() : nullptr;

    int biome_dirty = 0;
    int vegetation_dirty = 0;
    int cover_dirty = 0;
    int dirty_pixels = 0;

    for (int i = 0; i < n_cells; ++i) {
        const uint8_t b_t = run_biome ? TERR[i] : 0;
        const uint8_t b_v = run_vegetation ? VEG[i] : 0;
        const uint8_t b_c = run_cover ? COV[i] : 0;
        const bool dirty_b = run_biome && (!prev_biome_valid || PB[i] != b_t);
        const bool dirty_v = run_vegetation && (!prev_vegetation_valid || PV[i] != b_v);
        const bool dirty_c = run_cover && (!prev_cover_valid || PC[i] != b_c);
        if (!dirty_b && !dirty_v && !dirty_c) continue;

        if (dirty_b) { PB[i] = b_t; ++biome_dirty; }
        if (dirty_v) { PV[i] = b_v; ++vegetation_dirty; }
        if (dirty_c) { PC[i] = b_c; ++cover_dirty; }

        const int f = FIRST[i];
        const int c = CNT[i];
        if (c <= 0 || f < 0 || f + c > flat_n) continue;
        const int axis_changes = (dirty_b ? 1 : 0) + (dirty_v ? 1 : 0) + (dirty_c ? 1 : 0);
        dirty_pixels += c * axis_changes;
        for (int p = 0; p < c; ++p) {
            const int px = FLAT[f + p];
            if (px < 0 || px >= n_pix) continue;
            const int di = px * 4;
            if (dirty_b) { BB[px] = b_t; ED[di] = b_t; }
            if (dirty_v) { VB[px] = b_v; }
            if (dirty_c) { CB[px] = b_c; }
        }
    }

    out["fallback"] = false;
    out["reason"] = String();
    out["dirty_cells"] = biome_dirty + vegetation_dirty + cover_dirty;
    out["dirty_pixels"] = dirty_pixels;
    out["biome_dirty"] = biome_dirty;
    out["vegetation_dirty"] = vegetation_dirty;
    out["cover_dirty"] = cover_dirty;
    out["enum_atlas_data"] = enum_data;
    if (run_biome) {
        out["biome_buffer"] = biome_buf;
        out["prev_biome"] = prev_biome;
    }
    if (run_vegetation) {
        out["vegetation_buffer"] = vegetation_buf;
        out["prev_vegetation"] = prev_vegetation;
    }
    if (run_cover) {
        out["cover_buffer"] = cover_buf;
        out["prev_cover"] = prev_cover;
    }
    return out;
}
