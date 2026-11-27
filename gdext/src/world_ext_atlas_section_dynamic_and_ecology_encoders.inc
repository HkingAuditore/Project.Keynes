// ─── Dirty-Push Atlas Encode (plan/dirty-push-atlas-encode 阶段 F) ──────────
// 4 个 atlas baker 的 byte-fill pass C++ 化。CSR 协议详见 world_ext.h 注释。
//
// 共享 CSR 验证 helper：失败时调用 fail() 回 fallback Dictionary。
namespace {

struct AtlasEncodeCommon {
    int n_pix = 0;
    int stride = 0;
    int K = 0;                 // dirty cell count
    int total_px = 0;          // sum(cell_px_count)
    godot::PackedByteArray buffer;
    godot::PackedInt32Array cell_indices;
    godot::PackedInt32Array first_px;
    godot::PackedInt32Array px_count;
    godot::PackedInt32Array flat_px;
    bool valid = false;
    const char *err = "";
};

// 提取并校验 CSR 通用入参。失败时设 err 并返回 valid=false。
inline AtlasEncodeCommon parse_csr_common(const godot::Dictionary &knobs, int expected_stride) {
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    AtlasEncodeCommon c;
    c.stride = expected_stride;
    if (!knobs.has("n_pix") || !knobs.has("atlas_buffer") ||
        !knobs.has("cell_indices") || !knobs.has("cell_first_px") ||
        !knobs.has("cell_px_count") || !knobs.has("flat_px_indices")) {
        c.err = "missing required CSR knob";
        return c;
    }
    c.n_pix = int(knobs["n_pix"]);
    if (c.n_pix <= 0) { c.err = "n_pix <= 0"; return c; }
    c.buffer = knobs["atlas_buffer"];
    if (c.buffer.size() != c.n_pix * c.stride) {
        c.err = "atlas_buffer size mismatch";
        return c;
    }
    c.cell_indices = knobs["cell_indices"];
    c.first_px = knobs["cell_first_px"];
    c.px_count = knobs["cell_px_count"];
    c.flat_px = knobs["flat_px_indices"];
    c.K = c.cell_indices.size();
    if (c.first_px.size() != c.K || c.px_count.size() != c.K) {
        c.err = "CSR row-ptr length mismatch";
        return c;
    }
    c.total_px = c.flat_px.size();
    // 边界 sanity：last cell first_px + px_count <= total_px
    if (c.K > 0) {
        const int last_first = c.first_px[c.K - 1];
        const int last_count = c.px_count[c.K - 1];
        if (last_first < 0 || last_count < 0 || last_first + last_count > c.total_px) {
            c.err = "CSR row-ptr out of bounds";
            return c;
        }
    }
    c.valid = true;
    return c;
}

} // anonymous namespace

godot::Dictionary DCWorldExt::encode_dynamic_cell_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_dynamic_cell_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 4);
    if (!c.valid) return fail(c.err);
    if (!knobs.has("cell_is_water")) return fail("missing cell_is_water");
    PackedByteArray is_water = knobs["cell_is_water"];
    if (is_water.size() != c.K) return fail("cell_is_water size mismatch");

    // [perf 2026-05-20 sig-diff-skip] 与 GDScript 路径对齐的 sig cache：
    //   GD 端 dynamic_cell_atlas_chunk_step line 727:
    //       if cache_valid and _last_dynamic_cell_sigs.get(cell, -1) == sig: continue
    //   原 cpp 路径"所有 cell 都重写 pixel"，整图 2400 dirty 时 pixel fan-out 主导耗时。
    //   现在让 cpp 也消费 prev_sigs（按 cell_indices 顺序打包）+ cache_valid，
    //   命中比对就跳过 pixel fan-out，仅写 SIGS[k]=sig 让 GD 端 cache 一致。
    //   prev_sigs 缺省/size mismatch/cache_valid=false 都退化为"全部重写"，行为等价旧版。
    const bool sig_cache_valid = bool(knobs.get("cache_valid", false));
    PackedInt32Array prev_sigs;
    bool prev_sigs_usable = false;
    if (sig_cache_valid && knobs.has("prev_sigs")) {
        prev_sigs = knobs["prev_sigs"];
        prev_sigs_usable = (prev_sigs.size() == c.K);
    }

    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    // [sea-ice-render-source-unify 阶段 A] A 通道双语义：
    //   水格 A = q01_byte_ice(sea_ice_fraction)，shader 水路径单源消费；
    //   陆格 A = q01_byte(vegetation_vitality)（保持原语义）。
    const int sid_sif = component_id(StringName("cell_sea_ice_frac"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 || sid_sif < 0) {
        return fail("missing slot id (temp/moist/snow/vitality/sea_ice_frac)");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_sif = _slots.write[sid_sif];
    const int n_cells = _entity_count;
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_sif.arr_f32.size() < n_cells) {
        return fail("slot array size < entity_count");
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const float * const __restrict VIT = s_vit.arr_f32.ptr();
    const float * const __restrict SIF = s_sif.arr_f32.ptr();
    const int32_t * const __restrict CELLS = c.cell_indices.ptr();
    const int32_t * const __restrict FIRST = c.first_px.ptr();
    const int32_t * const __restrict CNT = c.px_count.ptr();
    const int32_t * const __restrict FLAT = c.flat_px.ptr();
    const uint8_t * const __restrict PSEA = is_water.ptr();
    const int32_t * const __restrict PREV_SIGS =
        prev_sigs_usable ? prev_sigs.ptr() : nullptr;
    uint8_t * const __restrict BUF = c.buffer.ptrw();

    PackedInt32Array new_sigs;
    new_sigs.resize(c.K);
    int32_t * const __restrict SIGS = new_sigs.ptrw();

    int pixels_written = 0;
    int sig_skipped = 0;  // 命中 sig diff skip 的 cell 数（诊断用）
    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) {
            SIGS[k] = 0;
            continue;
        }
        const int r = pk_q01_byte(double(TEMP[ci]));
        const int g = pk_q01_byte(double(MOIST[ci]));
        const int b = pk_q01_byte(double(SNOW[ci]));
        // [sea-ice-render-source-unify 阶段 C] A 通道：水格存海冰、陆格存植被活力。
        // 水陆判定基于 is_water 语义（含 SEA_ICE）；GDScript 侧统一从 is_water_arr/LUT 喂入。
        const int a = (PSEA[k] != 0)
            ? pk_q01_byte_ice(double(SIF[ci]))
            : pk_q01_byte(double(VIT[ci]));
        const uint32_t sig = uint32_t(r) | (uint32_t(g) << 8) |
                             (uint32_t(b) << 16) | (uint32_t(a) << 24);
        SIGS[k] = int32_t(sig);

        // sig-diff fast skip：与上次 cache 一致则跳过 pixel fan-out（热点中的热点）。
        if (PREV_SIGS != nullptr && uint32_t(PREV_SIGS[k]) == sig) {
            ++sig_skipped;
            continue;
        }

        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = uint8_t(r);
            BUF[base + 1] = uint8_t(g);
            BUF[base + 2] = uint8_t(b);
            BUF[base + 3] = uint8_t(a);
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = c.buffer;
    out["new_sigs"] = new_sigs;
    out["sig_skipped"] = sig_skipped;
    return out;
}

godot::Dictionary DCWorldExt::encode_ecology_visual_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] encode_ecology_visual_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 4);
    if (!c.valid) return fail(c.err);
    if (!knobs.has("prev_veg") || !knobs.has("prev_vitality") ||
        !knobs.has("prev_transition")) {
        return fail("missing ecology prev_* knob");
    }
    PackedByteArray prev_veg = knobs["prev_veg"];
    PackedByteArray prev_vit = knobs["prev_vitality"];
    PackedByteArray prev_tr = knobs["prev_transition"];
    if (prev_veg.size() != c.K || prev_vit.size() != c.K || prev_tr.size() != c.K) {
        return fail("ecology prev_* size mismatch");
    }
    const bool cache_valid = bool(knobs.get("cache_valid", false));
    PackedInt32Array prev_sigs;
    bool prev_sigs_usable = false;
    if (cache_valid && knobs.has("prev_sigs")) {
        prev_sigs = knobs["prev_sigs"];
        prev_sigs_usable = (prev_sigs.size() == c.K);
    }

    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    const int sid_terr = component_id(StringName("cell_terrain"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_vit < 0 ||
        sid_terr < 0 || sid_veg < 0) {
        return fail("missing slot id (temp/moist/snow/vit/terr/veg)");
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_vit = _slots.write[sid_vit];
    Slot &s_terr = _slots.write[sid_terr];
    Slot &s_veg = _slots.write[sid_veg];
    const int n_cells = _entity_count;
    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow.arr_f32.size() < n_cells || s_vit.arr_f32.size() < n_cells ||
        s_terr.arr_u8.size() < n_cells || s_veg.arr_u8.size() < n_cells) {
        return fail("slot array size < entity_count");
    }

    // 透传 GDScript TerrainType.TERRAIN.LAKE / SEA_ICE / VegetationType.VEG.NONE 常量。
    // 通过 knobs 入参（避免 C++ 端硬编码 enum 值导致 schema 漂移）。
    const int TERRAIN_LAKE = int(knobs.get("terrain_lake", -1));
    const int TERRAIN_SEA_ICE = int(knobs.get("terrain_sea_ice", -1));
    const int VEG_NONE = int(knobs.get("veg_none", -1));

    if (!knobs.has("cell_is_water")) return fail("missing cell_is_water");
    PackedByteArray is_water = knobs["cell_is_water"];
    if (is_water.size() != c.K) return fail("cell_is_water size mismatch");

    auto t0 = std::chrono::high_resolution_clock::now();

    const float * const __restrict TEMP = s_temp.arr_f32.ptr();
    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const float * const __restrict VIT = s_vit.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const uint8_t * const __restrict VEG = s_veg.arr_u8.ptr();
    const int32_t * const __restrict CELLS = c.cell_indices.ptr();
    const int32_t * const __restrict FIRST = c.first_px.ptr();
    const int32_t * const __restrict CNT = c.px_count.ptr();
    const int32_t * const __restrict FLAT = c.flat_px.ptr();
    const uint8_t * const __restrict PSEA = is_water.ptr();
    const uint8_t * const __restrict PV_VEG = prev_veg.ptr();
    const uint8_t * const __restrict PV_VIT = prev_vit.ptr();
    const uint8_t * const __restrict PV_TR = prev_tr.ptr();
    const int32_t * const __restrict PREV_SIGS = prev_sigs_usable ? prev_sigs.ptr() : nullptr;
    uint8_t * const __restrict BUF = c.buffer.ptrw();

    PackedByteArray new_veg;  new_veg.resize(c.K);  uint8_t * const NV = new_veg.ptrw();
    PackedByteArray new_vit;  new_vit.resize(c.K);  uint8_t * const NVI = new_vit.ptrw();
    PackedByteArray new_tr;   new_tr.resize(c.K);   uint8_t * const NT = new_tr.ptrw();
    PackedInt32Array new_sigs; new_sigs.resize(c.K); int32_t * const SIGS = new_sigs.ptrw();

    // smoothstep helper：与 GDScript smoothstep(edge0, edge1, x) 同义。
    auto smoothstep = [](double e0, double e1, double x) {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        double t = (x - e0) / (e1 - e0);
        if (t < 0.0) t = 0.0;
        else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };
    auto clamp01 = [](double v) {
        return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
    };

    int pixels_written = 0;
    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) {
            NV[k] = 0; NVI[k] = 0; NT[k] = 0; SIGS[k] = 0;
            continue;
        }
        const int cur_veg = int(VEG[ci]) & 0xFF;
        const int cur_vit_byte = pk_q01_byte(double(VIT[ci]));
        const int prev_veg_byte = int(PV_VEG[k]);
        const int prev_vit_byte = int(PV_VIT[k]);
        int transition_age = int(PV_TR[k]);
        if (cache_valid) {
            if (cur_veg != prev_veg_byte) transition_age = 255;
            else if (transition_age > 0) {
                transition_age = transition_age - 18;
                if (transition_age < 0) transition_age = 0;
            }
        } else {
            transition_age = 0;
        }

        // ── _ecology_visual_signature 镜像 ─────────────────────────
        // sea-ice-render-source-unify 阶段 C：PSEA 已是 is_water 语义（含 SEA_ICE/LAKE），
        // 后两个 terrain 兜底成为防御性冗余（保留以防 GDScript 端误传 passable_sea）。
        const int terrain_id = int(TERR[ci]);
        const bool is_water_cell = (PSEA[k] != 0) ||
            (terrain_id == TERRAIN_LAKE) ||
            (terrain_id == TERRAIN_SEA_ICE);
        const int veg_id = cur_veg;
        const double vitality = clamp01(double(VIT[ci]));
        const double moist = clamp01(double(MOIST[ci]));
        const double temp = clamp01(double(TEMP[ci]));
        const double snow = clamp01(double(SNOW[ci]));

        double foliage = 0.0;
        if (!is_water_cell && veg_id != VEG_NONE) {
            const double cold_loss = (1.0 - smoothstep(0.02, 0.18, temp)) * 0.55;
            const double snow_loss = smoothstep(0.12, 0.75, snow) * 0.70;
            const double dry_loss = (1.0 - smoothstep(0.05, 0.35, moist)) * 0.45;
            foliage = clamp01(vitality * 0.72 + moist * 0.28 - cold_loss - snow_loss - dry_loss);
        }
        double stress = 0.0;
        if (!is_water_cell) {
            const double dryness = 1.0 - moist;
            const double heat_stress = smoothstep(0.72, 0.95, temp);
            const double cold_stress = 1.0 - smoothstep(0.03, 0.20, temp);
            const double vit_stress = 1.0 - vitality;
            const double a1 = dryness * 0.70;
            const double a2 = (heat_stress > cold_stress ? heat_stress : cold_stress) * 0.65;
            const double a3 = (a1 > a2 ? a1 : a2);
            stress = clamp01(a3 + vit_stress * 0.45);
        }
        const double vit_delta = (double(pk_q01_byte(vitality)) - double(prev_vit_byte)) / 255.0;
        const double growth_damage = clamp01(0.5 + vit_delta * 5.0 + (foliage - 0.5) * 0.12 - stress * 0.10);

        const int r = pk_q01_byte(foliage);
        const int g = pk_q01_byte(stress);
        int b = transition_age;
        if (b < 0) b = 0;
        else if (b > 255) b = 255;
        const int a = pk_q01_byte(growth_damage);
        const uint32_t sig = uint32_t(r) | (uint32_t(g) << 8) |
                             (uint32_t(b) << 16) | (uint32_t(a) << 24);

        // 写回 prev/sig 状态（每 cell 都写，无论 cache 命中）
        NV[k] = uint8_t(cur_veg);
        NVI[k] = uint8_t(cur_vit_byte);
        NT[k] = uint8_t(b);
        SIGS[k] = int32_t(sig);

        if (PREV_SIGS != nullptr && uint32_t(PREV_SIGS[k]) == sig) {
            continue;
        }

        // byte fill
        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = uint8_t(r);
            BUF[base + 1] = uint8_t(g);
            BUF[base + 2] = uint8_t(b);
            BUF[base + 3] = uint8_t(a);
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = c.buffer;
    out["new_veg"] = new_veg;
    out["new_vitality"] = new_vit;
    out["new_transition"] = new_tr;
    out["new_sigs"] = new_sigs;
    return out;
}
