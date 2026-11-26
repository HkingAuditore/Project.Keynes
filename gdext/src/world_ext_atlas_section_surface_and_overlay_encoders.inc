godot::Dictionary DCWorldExt::encode_dyn_smooth_atlas(godot::Dictionary knobs) {
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
        UtilityFunctions::push_warning("[DCWorldExt] encode_dyn_smooth_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 4);
    if (!c.valid) return fail(c.err);

    if (!knobs.has("neighbor_indices")) return fail("missing neighbor_indices");
    if (!knobs.has("cell_is_water")) return fail("missing cell_is_water");
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedByteArray cell_iw = knobs["cell_is_water"];
    if (cell_iw.size() != c.K) return fail("cell_is_water size mismatch");
    const bool cache_valid = bool(knobs.get("cache_valid", false));
    PackedInt32Array prev_sigs;
    bool prev_sigs_usable = false;
    if (cache_valid && knobs.has("prev_sigs")) {
        prev_sigs = knobs["prev_sigs"];
        prev_sigs_usable = (prev_sigs.size() == c.K);
    }

    // sea-ice-render-source-unify 阶段 C：中心 cell + 邻居都需要“是否水域”进行
    // A 通道双语义判定 + 邻居均值分裂。调用方必须使用 is_water 语义（含
    // SEA_ICE）而非 passable_sea，否则 SEA_ICE cell 会被误归入陆格分支。
    // GDScript 端走 map.is_water_arr 或 MapData.is_water_lut() 填充。
    if (!knobs.has("neighbor_is_water")) return fail("missing neighbor_is_water");
    PackedByteArray nb_iw = knobs["neighbor_is_water"];
    if (nb_iw.size() != c.K * 6) return fail("neighbor_is_water size mismatch (need K*6)");
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_vit = component_id(StringName("cell_vegetation_vitality"));
    // [sea-ice-render-source-unify 阶段 A] sig A 字节双语义需要 sea_ice_frac slot。
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
    if (nb_arr.size() < n_cells * 6) return fail("neighbor_indices size < n_cells*6");

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
    const uint8_t * const __restrict PSEA = cell_iw.ptr();
    const uint8_t * const __restrict NB_PSEA = nb_iw.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const int32_t * const __restrict PREV_SIGS = prev_sigs_usable ? prev_sigs.ptr() : nullptr;
    uint8_t * const __restrict BUF = c.buffer.ptrw();

    PackedInt32Array new_sigs; new_sigs.resize(c.K); int32_t * const SIGS = new_sigs.ptrw();

    // 内联 sig 计算（与 _dynamic_cell_signature 等价）：
    //   r=q01(temp), g=q01(moist), b=q01(snow)
    //   [sea-ice-render-source-unify 阶段 C] A 通道双语义：
    //     水格 (is_water=true)：a = q01_byte_ice(sea_ice_frac)
    //     陆格 (is_water=false)：a = q01_byte(vit)
    //   is_water 语义含 SEA_ICE，不同于只看航行性的 passable_sea。
    auto sig_of = [&](int idx, bool iw) -> uint32_t {
        const int r = pk_q01_byte(double(TEMP[idx]));
        const int g = pk_q01_byte(double(MOIST[idx]));
        const int b = pk_q01_byte(double(SNOW[idx]));
        const int a = iw
            ? pk_q01_byte_ice(double(SIF[idx]))
            : pk_q01_byte(double(VIT[idx]));
        return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (uint32_t(a) << 24);
    };

    int pixels_written = 0;
    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) { SIGS[k] = 0; continue; }

        const uint32_t c_sig = sig_of(ci, PSEA[k] != 0);
        const int cr = int(c_sig & 0xFF);
        const int cg = int((c_sig >> 8) & 0xFF);
        const int cb = int((c_sig >> 16) & 0xFF);
        const int ca = int((c_sig >> 24) & 0xFF);
        const bool center_is_water = (PSEA[k] != 0);

        // FNV-1a 32-bit hood hash（中心 + 邻居各 4 byte），与 GDScript 1:1 镜像。
        uint32_t hood_h = 0x811C9DC5u;
        hood_h = (hood_h ^ uint32_t(cr)) * 0x01000193u;
        hood_h = (hood_h ^ uint32_t(cg)) * 0x01000193u;
        hood_h = (hood_h ^ uint32_t(cb)) * 0x01000193u;
        hood_h = (hood_h ^ uint32_t(ca)) * 0x01000193u;

        int nr = 0, ng = 0, nb_sum = 0, na = 0, nc = 0, na_c = 0;
        const int nb_base_global = ci * 6;
        const int nb_base_local = k * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[nb_base_global + d];
            if (ni < 0 || ni >= n_cells) continue;
            const bool n_psea = (NB_PSEA[nb_base_local + d] != 0);
            const uint32_t n_sig = sig_of(int(ni), n_psea);
            const int nrb = int(n_sig & 0xFF);
            const int ngb = int((n_sig >> 8) & 0xFF);
            const int nbb = int((n_sig >> 16) & 0xFF);
            const int nab = int((n_sig >> 24) & 0xFF);
            nr += nrb; ng += ngb; nb_sum += nbb; nc += 1;
            // ─────────────────────────────────────────────────────────
            // [sea-ice-render-source-unify 阶段 A] A 通道水陆分裂平均：
            //   - 中心陆格：A=vit，仅累加陆地邻居（海邻 A=ice_byte 与 vit 异语义）。
            //   - 中心水格：A=sea_ice_frac，仅累加水域邻居（陆邻 A=vit 与 ice 异语义）。
            // 历史背景（2026-05-21 修复）：陆地 A 累加海邻会被海格 0 系统性拖低；
            // 现海格 A 不再为 0 而是 ice_byte，必须更严格地按语义同类分组。
            // SAME_SOURCE：scripts/rendering/map_baker.gd::dyn_atlas_smooth_chunk_step。
            // ─────────────────────────────────────────────────────────
            if (center_is_water) {
                if (n_psea) { na += nab; na_c += 1; }
            } else {
                if (!n_psea) { na += nab; na_c += 1; }
            }
            hood_h = (hood_h ^ uint32_t(nrb)) * 0x01000193u;
            hood_h = (hood_h ^ uint32_t(ngb)) * 0x01000193u;
            hood_h = (hood_h ^ uint32_t(nbb)) * 0x01000193u;
            hood_h = (hood_h ^ uint32_t(nab)) * 0x01000193u;
        }

        SIGS[k] = int32_t(hood_h);
        if (PREV_SIGS != nullptr && uint32_t(PREV_SIGS[k]) == hood_h) {
            continue;
        }

        int or_, og, ob, oa;
        if (nc > 0) {
            // 中心 0.5 + 邻居均值 0.5；GDScript 用 int 除法，C++ 必须镜像同语义。
            // (cr + nr / nc) / 2，全部 int 截断除。
            // ─────────────────────────────────────────────────────────
            // 2026-05-21 修复 (issue: 95% 雪盖在屏幕上不可见)：
            // B 通道（snow_cover）是「阈值型」现象——单格可在雪线之上而所有
            // 邻居都在雪线之下；它不是温度/湿度那样的连续梯度场，不应参与
            // box blur，否则 95% 的真值被邻居 0 拖到 ~47.5% 直接被后段
            // smoothstep 压成几乎不可见。R/G/A 仍走原有 box blur 逻辑以保留
            // 温度/湿度/植被活力沿 hex 边界的平滑过渡。SAME_SOURCE 兜底见
            // map_baker.gd::dyn_atlas_smooth_chunk_step。
            // 2026-05-21 D 项追加：A 通道仅平均"非海域邻居"，详见上方
            // for 循环内的注释。海岸陆地 cell 不再被海洋 0 系统性拖低。
            // ─────────────────────────────────────────────────────────
            const int t1 = cr + (nr / nc);
            const int t2 = cg + (ng / nc);
            or_ = t1 / 2; og = t2 / 2;
            ob = cb;  // snow passthrough：保留 cell 真值，不做邻居平均。
            // A 通道：用陆地邻居数 na_c 做平均；陆地 cell 全是海邻（na_c=0）
            // 时退回中心值，避免除 0 也避免被 0 邻居拖低。
            if (na_c > 0) {
                const int t4 = ca + (na / na_c);
                oa = t4 / 2;
            } else {
                oa = ca;
            }
            if (or_ < 0) or_ = 0; else if (or_ > 255) or_ = 255;
            if (og < 0) og = 0; else if (og > 255) og = 255;
            if (ob < 0) ob = 0; else if (ob > 255) ob = 255;
            if (oa < 0) oa = 0; else if (oa > 255) oa = 255;
        } else {
            or_ = cr; og = cg; ob = cb; oa = ca;
        }

        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = uint8_t(or_);
            BUF[base + 1] = uint8_t(og);
            BUF[base + 2] = uint8_t(ob);
            BUF[base + 3] = uint8_t(oa);
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
    return out;
}

godot::Dictionary DCWorldExt::encode_ice_state_atlas(godot::Dictionary knobs) {
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
        UtilityFunctions::push_warning("[DCWorldExt] encode_ice_state_atlas: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");

    auto c = parse_csr_common(knobs, 1);  // R8 = 1 byte/pixel
    if (!c.valid) return fail(c.err);

    const int sid_ice = component_id(StringName("cell_sea_ice_frac"));
    if (sid_ice < 0) return fail("missing slot id cell_sea_ice_frac");
    Slot &s_ice = _slots.write[sid_ice];
    const int n_cells = _entity_count;
    if (s_ice.arr_f32.size() < n_cells) return fail("sea_ice_frac slot too small");

    auto t0 = std::chrono::high_resolution_clock::now();

    // ICE 指针保留 volatile：Apple Clang 在 ARM64 对 PackedFloat32Array.ptr()
    // 返回值做 alias-based DCE，加 volatile 强制每次 ICE[i] 从内存重读。
    // （process_atlas_pipeline_step 里 ICE phase 已改为完全内联编码循环，
    //  本函数仅作为非热路径 caller 的 fallback 入口。）
    const volatile float * const ICE = s_ice.arr_f32.ptr();

    const int32_t * const CELLS = c.cell_indices.ptr();
    const int32_t * const FIRST = c.first_px.ptr();
    const int32_t * const CNT = c.px_count.ptr();
    const int32_t * const FLAT = c.flat_px.ptr();
    uint8_t * const BUF = c.buffer.ptrw();

    PackedByteArray new_bytes; new_bytes.resize(c.K); uint8_t * const NB_OUT = new_bytes.ptrw();

    int pixels_written = 0;

    // ★ 优先用调用方预打包好的 cell_ice_values（K 个值，按 CELLS 顺序）。
    // 这条路径绕过 encode 内部对 ICE slot 的间接读，避免 Apple Clang ARM64
    // 在 ICE2[CELLS[k]] 这种间接索引上做的激进 alias DCE。
    bool have_iv = false;
    PackedFloat32Array iv_arr;
    if (knobs.has("cell_ice_values")) {
        iv_arr = knobs["cell_ice_values"];
        have_iv = (iv_arr.size() >= c.K);
    }
    const float * const IV = have_iv ? iv_arr.ptr() : nullptr;

    for (int k = 0; k < c.K; ++k) {
        const int ci = CELLS[k];
        if (ci < 0 || ci >= n_cells) { NB_OUT[k] = 0; continue; }
        const float ice_v = have_iv ? IV[k] : ICE[ci];
        const int byte_v = pk_q01_byte_ice(double(ice_v));
        NB_OUT[k] = uint8_t(byte_v);
        const int first = FIRST[k];
        const int count = CNT[k];
        for (int p = 0; p < count; ++p) {
            const int px_idx = FLAT[first + p];
            if (px_idx < 0 || px_idx >= c.n_pix) continue;
            BUF[px_idx] = uint8_t(byte_v);
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
    // ice atlas 走 cell_byte cache（见 _last_ice_state_cell_bytes），返回 PackedByteArray
    out["new_bytes"] = new_bytes;
    return out;
}

// ────────────────────────────────────────────────────────────────────────────
// plan/debug-overlay-perf v2（2026-06-12）：Debug Data Overlay pixel fan-out 下沉 C++
//   data_overlay_baker.gd 把 18 个 overlay mode 的 per-cell 采样结果（R/G byte +
//   有效标记）按 cell.index 打包传入，本方法负责清零 buffer + 把每个有效 cell
//   的 (R, G, 0, 255) 扇出写到它覆盖的全部像素。镜像 GDScript 内层像素循环，
//   与之 byte-for-byte 等价。协议详见 world_ext.h::encode_overlay_atlas。
// ────────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::encode_overlay_atlas(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels_written"] = 0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    // 本 pass 不读 _slots，无需 _bound：overlay 数据全部由 GDScript 预采样喂入。
    if (!knobs.has("n_pix") || !knobs.has("n_cells") ||
        !knobs.has("atlas_buffer") || !knobs.has("cell_first_px") ||
        !knobs.has("cell_px_count") || !knobs.has("flat_px_indices") ||
        !knobs.has("cell_r") || !knobs.has("cell_g") || !knobs.has("cell_valid")) {
        return fail("missing required overlay knob");
    }

    const int n_pix = int(knobs["n_pix"]);
    const int n_cells = int(knobs["n_cells"]);
    if (n_pix <= 0) return fail("n_pix <= 0");
    if (n_cells <= 0) return fail("n_cells <= 0");

    PackedByteArray buffer = knobs["atlas_buffer"];
    if (int64_t(buffer.size()) != int64_t(n_pix) * 4) {
        return fail("atlas_buffer size mismatch");
    }

    PackedInt32Array first_px = knobs["cell_first_px"];
    PackedInt32Array px_count = knobs["cell_px_count"];
    PackedInt32Array flat_px = knobs["flat_px_indices"];
    PackedByteArray cell_r = knobs["cell_r"];
    PackedByteArray cell_g = knobs["cell_g"];
    PackedByteArray cell_valid = knobs["cell_valid"];

    if (first_px.size() < n_cells || px_count.size() < n_cells) {
        return fail("cell CSR array size < n_cells");
    }
    if (cell_r.size() < n_cells || cell_g.size() < n_cells ||
        cell_valid.size() < n_cells) {
        return fail("per-cell byte array size < n_cells");
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    const int32_t * const __restrict FIRST = first_px.ptr();
    const int32_t * const __restrict CNT = px_count.ptr();
    const int32_t * const __restrict FLAT = flat_px.ptr();
    const int flat_n = flat_px.size();
    const uint8_t * const __restrict R = cell_r.ptr();
    const uint8_t * const __restrict G = cell_g.ptr();
    const uint8_t * const __restrict VALID = cell_valid.ptr();
    uint8_t * const __restrict BUF = buffer.ptrw();

    // 默认全像素清零：alpha=0（无效/未覆盖 → shader 渲染中性/透明）。
    // memset 比 GDScript PackedByteArray.fill(0) 略快，且让本方法自给自足。
    std::memset(BUF, 0, size_t(n_pix) * 4);

    int pixels_written = 0;
    for (int ci = 0; ci < n_cells; ++ci) {
        if (VALID[ci] == 0) continue;
        const int first = FIRST[ci];
        const int count = CNT[ci];
        if (first < 0 || count <= 0) continue;
        const uint8_t r = R[ci];
        const uint8_t g = G[ci];
        for (int p = 0; p < count; ++p) {
            const int fi = first + p;
            if (fi < 0 || fi >= flat_n) continue;
            const int px_idx = FLAT[fi];
            if (px_idx < 0 || px_idx >= n_pix) continue;
            const int base = px_idx * 4;
            BUF[base    ] = r;
            BUF[base + 1] = g;
            BUF[base + 2] = 0;
            BUF[base + 3] = 255;
            ++pixels_written;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = ms;
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels_written"] = pixels_written;
    out["atlas_buffer"] = buffer;
    return out;
}
