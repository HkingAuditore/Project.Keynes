// ─── F.5 main pass ──────────────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// map_generator.gd::_apply_transpiration_pass (line 4938).
//
// Algorithm structure (2-phase to be order-insensitive):
//   Phase 1 — compute deltas (don't write to moisture yet):
//     for each land cell with veg.transpiration >= 0.01:
//       output      = transpiration[veg] * moisture
//       self_share  = output * self_rate
//       nb_share    = output * outflow_rate / 6
//       deltas[i]  += self_share
//       for each non-water neighbour: deltas[nb_idx] += nb_share
//   Phase 2 — apply deltas:
//     for each cell with delta != 0:
//       moisture = clamp(moisture + delta, 0, 1)
//
// LandformType.LF enum order (landform_type.gd:9-23): DEEP_OCEAN=0, OCEAN=1,
// COAST=2, LAKE=3 are water; PLAIN=4+ are land. So is_water iff lf <= 3.


// DOTS-Total-CPP（plan/dots-total-cpp 任务 4）：
// run_ocean_field_rasterize — hex→pixel rasterize 一次性 C++ 直出。
// 替代 GDScript _rasterize_ocean_current_slice_from_hex + _rasterize_upwelling_slice_from_hex
// 的 17 个 pixel slice，消除 ocean_currents 25ms slow slice 源头。
godot::Dictionary DCWorldExt::run_ocean_field_rasterize(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels"] = 0;
    out["atlas_updated"] = false;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_ocean_field_rasterize: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("w") || !knobs.has("h") ||
        !knobs.has("pixel_to_cell_idx") ||
        !knobs.has("dst_currents") || !knobs.has("dst_upwelling")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const int W = int(knobs["w"]);
    const int H = int(knobs["h"]);
    if (n_cells <= 0 || W <= 0 || H <= 0) return fail("invalid dims");
    const int n_px = W * H;

    PackedInt32Array px2cell = knobs["pixel_to_cell_idx"];
    PackedByteArray  dst_cur = knobs["dst_currents"];
    PackedByteArray  dst_up  = knobs["dst_upwelling"];
    if (px2cell.size() != n_px) return fail("pixel_to_cell_idx size mismatch");
    if (dst_cur.size() != n_px * 2) return fail("dst_currents size mismatch");
    if (dst_up.size() != n_px) return fail("dst_upwelling size mismatch");

    // ─── Sub-slice 像素区间（plan/ocean-raster-subslice 2026-05-22）──────────
    // 可选 knobs：start_idx / end_idx（缺省 = 全图 [0, n_px)），用于把 4.7ms
    // 整图 raster 拆成 N 个 sub-tick 各 ~1.2ms，复用 commit-defer 框架。
    // hot loop per-pixel 完全独立（只读 P2C[i] / SoA[ci] + 写 DCUR/DUP/ATLAS[i]），
    // 任意 [start, end) 切片 bit-equal。pending buffer / atlas_data 长度仍按 n_px
    // 校验 — caller 必须保证整轮 round 复用同一组缓冲。
    int start_idx = 0;
    int end_idx = n_px;
    if (knobs.has("start_idx")) start_idx = int(knobs["start_idx"]);
    if (knobs.has("end_idx"))   end_idx   = int(knobs["end_idx"]);
    if (start_idx < 0) start_idx = 0;
    if (end_idx > n_px) end_idx = n_px;
    if (start_idx > end_idx) start_idx = end_idx;

    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_ocx     = component_id(StringName("cell_ocean_current_x"));
    const int sid_ocy     = component_id(StringName("cell_ocean_current_y"));
    const int sid_up      = component_id(StringName("cell_upwelling_strength"));
    if (sid_terrain < 0 || sid_ocx < 0 || sid_ocy < 0 || sid_up < 0) {
        return fail("missing slot id");
    }
    Slot &s_terr = _slots.write[sid_terrain];
    Slot &s_ocx  = _slots.write[sid_ocx];
    Slot &s_ocy  = _slots.write[sid_ocy];
    Slot &s_up   = _slots.write[sid_up];
    if (s_terr.arr_u8.size()  != n_cells ||
        s_ocx.arr_f32.size()  != n_cells ||
        s_ocy.arr_f32.size()  != n_cells ||
        s_up.arr_f32.size()   != n_cells) {
        return fail("slot array size mismatch");
    }

    PackedFloat32Array visual_x = s_ocx.arr_f32, visual_y = s_ocy.arr_f32, visual_up = s_up.arr_f32;
    if (knobs.has("physics_read_view")) {
        if (knobs["physics_read_view"].get_type() != Variant::DICTIONARY) return fail("physics_view_type");
        const Dictionary view = knobs["physics_read_view"];
        for (const char *key : {"ocean_current_x", "ocean_current_y", "upwelling"}) {
            if (!view.has(key) || view[key].get_type() != Variant::PACKED_FLOAT32_ARRAY ||
                PackedFloat32Array(view[key]).size() != n_cells) return fail("physics_view_shape");
            const PackedFloat32Array lane = view[key];
            for (int i = 0; i < n_cells; ++i) if (!std::isfinite(lane[i])) return fail("physics_view_nonfinite");
        }
        visual_x = view["ocean_current_x"]; visual_y = view["ocean_current_y"]; visual_up = view["upwelling"];
    }
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const float   * const __restrict OCX  = visual_x.ptr();
    const float   * const __restrict OCY  = visual_y.ptr();
    const float   * const __restrict UP   = visual_up.ptr();
    const int32_t * const __restrict P2C  = px2cell.ptr();
    uint8_t       * const __restrict DCUR = dst_cur.ptrw();
    uint8_t       * const __restrict DUP  = dst_up.ptrw();

    // 可选 atlas_data 同步（与 GDScript _vector_atlas_data 共享）
    bool atlas_ok = false;
    uint8_t *ATLAS = nullptr;
    PackedByteArray atlas_data;
    const bool update_atlas = bool(knobs.get("update_atlas_data", false));
    if (update_atlas && knobs.has("atlas_data")) {
        atlas_data = knobs["atlas_data"];
        if (atlas_data.size() == n_px * 4) {
            atlas_ok = true;
            ATLAS = atlas_data.ptrw();
        }
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    int written = 0;

    // ─── Hot loop 优化（25ns/pixel → 目标 ~3-5ns/pixel） ──────────────────
    // 1. 干掉 std::round（MSVC 不内联，每次函数调用 + double 转换）。
    //    替换为 `(int)(v * 127.5f + 128.5f)` —— round-half-up 的纯 float
    //    形式，编译器会发成单条 cvttss2si。误差仅在 v 正负边界的 0.5ULP，
    //    与原 GDScript round 行为一致（_quantize_to_byte_signed 也是 round_half）。
    // 2. 全 float 流水线，零 f32→f64→f32 来回转。
    // 3. clamp 改用三元 / std::min-max，向量化友好。
    // 4. atlas_ok 分支按整循环静态分流，避免每像素 if。
    auto quantize_signed = [](float v) -> uint8_t {
        // v ∈ [-1,1] → byte ∈ [0,255]，128 ≈ 0
        // 原 round((v*0.5+0.5)*255) = round(v*127.5+127.5)。round-half-up
        // 用 truncation 等价：trunc(x+0.5)。即 trunc(v*127.5 + 128.0)。
        // 与原 GDScript / C++ std::round 行为完全一致（误差 0 ULP）。
        float q = v * 127.5f + 128.0f;
        if (q <= 0.0f) return 0;
        if (q >= 255.0f) return 255;
        return uint8_t(int(q));  // trunc
    };
    // upwelling 用专门量化（原版 round(128 + 127*up)，比 currents 窄 1）
    auto quantize_upwelling = [](float v) -> uint8_t {
        if (v < -1.0f) v = -1.0f;
        else if (v > 1.0f) v = 1.0f;
        // round(128 + 127*v) → trunc(128 + 127*v + 0.5) = trunc(128.5 + 127*v)
        float q = 128.5f + 127.0f * v;
        if (q <= 0.0f) return 0;
        if (q >= 255.0f) return 255;
        return uint8_t(int(q));
    };

    // perf (2B): per-pixel 完全独立（只读 P2C[i]/SoA[ci]，写 DCUR/DUP/ATLAS[i] 互不相交，
    // 无标量累加器）→ 按像素区间并行、逐字节 bit-equal、无需 reduce。像素工作极轻
    // (~3-5ns)，seq_threshold 设高，仅大 raster 切片才并行（小切片走串行免线程开销）。
    auto raster_atlas = [&](int b, int e) {
        for (int i = b; i < e; ++i) {
            const int32_t ci = P2C[i];
            float cur_x = 0.0f;
            float cur_y = 0.0f;
            float up_v  = 0.0f;
            bool is_water = false;
            if (uint32_t(ci) < uint32_t(n_cells)) {  // unsigned cmp 同时排除 ci<0
                is_water = pk_is_water_terrain(TERR[ci]);
                if (is_water) {
                    cur_x = OCX[ci];
                    cur_y = OCY[ci];
                    up_v  = UP[ci];
                }
            }
            const uint8_t bx = quantize_signed(cur_x);
            const uint8_t by = quantize_signed(cur_y);
            DCUR[i * 2]     = bx;
            DCUR[i * 2 + 1] = by;
            DUP[i] = is_water ? quantize_upwelling(up_v) : uint8_t(128);
            ATLAS[i * 4]     = bx;
            ATLAS[i * 4 + 1] = by;
            // ATLAS[i*4+2..+3] 由 wind 通道写，rasterize 不动
        }
    };
    auto raster_plain = [&](int b, int e) {
        for (int i = b; i < e; ++i) {
            const int32_t ci = P2C[i];
            float cur_x = 0.0f;
            float cur_y = 0.0f;
            float up_v  = 0.0f;
            bool is_water = false;
            if (uint32_t(ci) < uint32_t(n_cells)) {
                is_water = pk_is_water_terrain(TERR[ci]);
                if (is_water) {
                    cur_x = OCX[ci];
                    cur_y = OCY[ci];
                    up_v  = UP[ci];
                }
            }
            DCUR[i * 2]     = quantize_signed(cur_x);
            DCUR[i * 2 + 1] = quantize_signed(cur_y);
            DUP[i] = is_water ? quantize_upwelling(up_v) : uint8_t(128);
        }
    };
    const int range_n = end_idx - start_idx;
    if (atlas_ok) {
        pk::parallel_for_range("pk_ocean_raster_a", range_n, /*n_tasks_hint=*/0,
            /*seq_threshold=*/16384,
            [&](int b, int e) { raster_atlas(start_idx + b, start_idx + e); });
    } else {
        pk::parallel_for_range("pk_ocean_raster", range_n, /*n_tasks_hint=*/0,
            /*seq_threshold=*/16384,
            [&](int b, int e) { raster_plain(start_idx + b, start_idx + e); });
    }
    written = end_idx - start_idx;

    knobs["dst_currents"]   = dst_cur;
    knobs["dst_upwelling"]  = dst_up;
    if (atlas_ok) {
        knobs["atlas_data"] = atlas_data;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels"] = written;
    out["atlas_updated"] = atlas_ok;
    out["start_idx"] = start_idx;
    out["end_idx"] = end_idx;
    return out;
}

// DOTS-Total-CPP（A 方案 / wind raster 孪生）：
// run_wind_field_rasterize — wind_x/wind_y SoA → hex→pixel byte 一次性直出。
// 替代 GDScript map_baker.gd::_rasterize_wind_slice_from_hex 的 21 片 × ~87ms 循环。
godot::Dictionary DCWorldExt::run_wind_field_rasterize(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels"] = 0;
    out["atlas_updated"] = false;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_wind_field_rasterize: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("w") || !knobs.has("h") ||
        !knobs.has("pixel_to_cell_idx") || !knobs.has("dst_wind")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const int W = int(knobs["w"]);
    const int H = int(knobs["h"]);
    if (n_cells <= 0 || W <= 0 || H <= 0) return fail("invalid dims");
    const int n_px = W * H;

    PackedInt32Array px2cell = knobs["pixel_to_cell_idx"];
    PackedByteArray  dst_wind = knobs["dst_wind"];
    if (px2cell.size() != n_px) return fail("pixel_to_cell_idx size mismatch");
    if (dst_wind.size() != n_px * 2) return fail("dst_wind size mismatch");

    const int sid_wind_x = component_id(StringName("cell_wind_x"));
    const int sid_wind_y = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    if (sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0) return fail("missing slot id");
    Slot &s_wx = _slots.write[sid_wind_x];
    Slot &s_wy = _slots.write[sid_wind_y];
    Slot &s_wsp = _slots.write[sid_wind_spd];
    if (s_wx.arr_f32.size() != n_cells || s_wy.arr_f32.size() != n_cells ||
        s_wsp.arr_f32.size() != n_cells) {
        return fail("slot array size mismatch");
    }

    PackedFloat32Array visual_x = s_wx.arr_f32, visual_y = s_wy.arr_f32, visual_speed = s_wsp.arr_f32;
    if (knobs.has("physics_read_view")) {
        if (knobs["physics_read_view"].get_type() != Variant::DICTIONARY) return fail("physics_view_type");
        const Dictionary view = knobs["physics_read_view"];
        for (const char *key : {"wind_x", "wind_y", "wind_speed"}) {
            if (!view.has(key) || view[key].get_type() != Variant::PACKED_FLOAT32_ARRAY ||
                PackedFloat32Array(view[key]).size() != n_cells) return fail("physics_view_shape");
            const PackedFloat32Array lane = view[key];
            for (int i = 0; i < n_cells; ++i) if (!std::isfinite(lane[i])) return fail("physics_view_nonfinite");
        }
        visual_x = view["wind_x"]; visual_y = view["wind_y"]; visual_speed = view["wind_speed"];
    }
    const float   * const __restrict WX  = visual_x.ptr();
    const float   * const __restrict WY  = visual_y.ptr();
    const float   * const __restrict WSP = visual_speed.ptr();
    const int32_t * const __restrict P2C = px2cell.ptr();
    uint8_t       * const __restrict DW  = dst_wind.ptrw();

    // 可选 atlas_data 同步（与 GDScript _vector_atlas_data 共享，wind 写 [+2]/[+3]）
    bool atlas_ok = false;
    uint8_t *ATLAS = nullptr;
    PackedByteArray atlas_data;
    const bool update_atlas = bool(knobs.get("update_atlas_data", false));
    if (update_atlas && knobs.has("atlas_data")) {
        atlas_data = knobs["atlas_data"];
        if (atlas_data.size() == n_px * 4) {
            atlas_ok = true;
            ATLAS = atlas_data.ptrw();
        }
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    int written = 0;

    // ─── Hot loop 优化（同 ocean rasterize：干掉 std::round + double 转换）。
    auto quantize_signed = [](float v) -> uint8_t {
        float q = v * 127.5f + 128.0f;
        if (q <= 0.0f) return 0;
        if (q >= 255.0f) return 255;
        return uint8_t(int(q));
    };

    if (atlas_ok) {
        for (int i = 0; i < n_px; ++i) {
            const int32_t ci = P2C[i];
            // 与 GDScript _rasterize_wind_slice_from_hex 一致：cell 缺失时默认 (1,0)
            float wx = 1.0f;
            float wy = 0.0f;
            if (uint32_t(ci) < uint32_t(n_cells)) {
                const float speed_norm = std::min(std::max(WSP[ci] / 1.7f, 0.0f), 1.0f);
                wx = WX[ci] * speed_norm;
                wy = WY[ci] * speed_norm;
            }
            const uint8_t bx = quantize_signed(wx);
            const uint8_t by = quantize_signed(wy);
            DW[i * 2]     = bx;
            DW[i * 2 + 1] = by;
            // ATLAS[i*4+0..+1] 由 ocean rasterize 写，wind 不动
            ATLAS[i * 4 + 2] = bx;
            ATLAS[i * 4 + 3] = by;
        }
    } else {
        for (int i = 0; i < n_px; ++i) {
            const int32_t ci = P2C[i];
            float wx = 1.0f;
            float wy = 0.0f;
            if (uint32_t(ci) < uint32_t(n_cells)) {
                const float speed_norm = std::min(std::max(WSP[ci] / 1.7f, 0.0f), 1.0f);
                wx = WX[ci] * speed_norm;
                wy = WY[ci] * speed_norm;
            }
            DW[i * 2]     = quantize_signed(wx);
            DW[i * 2 + 1] = quantize_signed(wy);
        }
    }
    written = n_px;

    knobs["dst_wind"] = dst_wind;
    if (atlas_ok) {
        knobs["atlas_data"] = atlas_data;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels"] = written;
    out["atlas_updated"] = atlas_ok;
    return out;
}
