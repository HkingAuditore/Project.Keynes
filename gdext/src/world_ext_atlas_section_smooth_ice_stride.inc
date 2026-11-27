    // ────────────────────────────────────────────────────────────────────
    // Phase SMOOTH：(eco_real ∪ dirty) 1-跳邻居膨胀；需要 neighbor SoA
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::SMOOTH) {
    // [TEMP DIAG sea-ice phase D-smo-entry]
    {
        static int _diag_smo_entry_dumped = 0;
        if (_diag_smo_entry_dumped < 4) {
            UtilityFunctions::print(
                "[PHASE-D-SMO-ENTRY] have_nb=", have_nb,
                " cache_valid_smo=", cache_valid_smo,
                " dirty_path_used=", dirty_path_used,
                " dirty_noop=", dirty_noop,
                " dirty_sz=", dirty_indices.size(),
                " eco_decay_sz=", st->eco_active_decay_indices.size(),
                " prep_smo_ready=", st->prep_smo_ready);
            ++_diag_smo_entry_dumped;
        }
    }
    int max_smooth_cells_per_call = opts.has("max_smooth_cells_per_call")
        ? int(opts["max_smooth_cells_per_call"]) : 512;
    if (max_smooth_cells_per_call < 128) max_smooth_cells_per_call = 128;
    if (max_smooth_cells_per_call > n_cells) max_smooth_cells_per_call = n_cells;
    if (!st->prep_smo_ready) {
        PackedInt32Array smo_real_indices;
        t_p = std::chrono::high_resolution_clock::now();
        {
            bool skip_phase = false;
            if (!have_nb) {
                // 没有 neighbor SoA：缺乏 smooth 数据源 → 跳过（GD 端旧路径会 fallback）
                skip_phase = true;
            } else if (!cache_valid_smo) {
                // cache_invalid → 全集
                smo_real_indices.resize(n_cells);
                for (int i = 0; i < n_cells; ++i) smo_real_indices[i] = i;
            } else if (dirty_path_used && dirty_noop && st->eco_active_decay_indices.size() == 0) {
                // 完全无变化：跳过
                skip_phase = true;
            } else {
                // seed = dirty ∪ decay；膨胀 = seed ∪ 6 邻居
                std::vector<uint8_t> seen(n_cells, 0);
                std::vector<int32_t> seed;
                seed.reserve(dirty_indices.size() + st->eco_active_decay_indices.size());
                if (dirty_path_used && !dirty_noop) {
                    const int32_t * const D = dirty_indices.ptr();
                    for (int i = 0; i < dirty_indices.size(); ++i) {
                        const int idx = D[i];
                        if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                        seen[idx] = 1;
                        seed.push_back(idx);
                    }
                }
                const int32_t * const A = st->eco_active_decay_indices.ptr();
                for (int i = 0; i < st->eco_active_decay_indices.size(); ++i) {
                    const int idx = A[i];
                    if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                    seen[idx] = 1;
                    seed.push_back(idx);
                }
                // 1-跳膨胀（自适应稀疏 / 稠密同 baker_dirty_helpers.gd 行为）
                const int32_t * const NB = nb_arr.ptr();
                std::vector<int32_t> dilated;
                dilated.reserve(seed.size() * 7);
                for (int32_t idx : seed) {
                    dilated.push_back(idx);
                    const int base = idx * 6;
                    for (int d = 0; d < 6; ++d) {
                        const int32_t ni = NB[base + d];
                        if (ni < 0 || ni >= n_cells || seen[ni]) continue;
                        seen[ni] = 1;
                        dilated.push_back(ni);
                    }
                }
                smo_real_indices.resize(int(dilated.size()));
                int32_t *p = smo_real_indices.ptrw();
                for (size_t i = 0; i < dilated.size(); ++i) p[i] = dilated[i];
            }
            // skip_phase 时 smo_real_indices 保持空
            (void)skip_phase;
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_smo_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->prep_smo_real_indices = smo_real_indices;
        st->prep_smo_ready = true;
        st->prep_smo_cursor = 0;
    } else {
        st->ms_smo_prep = 0.0;
    }
    PackedInt32Array &smo_real_indices = st->prep_smo_real_indices;
    const int K = smo_real_indices.size();
    const int k_begin = st->prep_smo_cursor;
    const int k_end = std::min(K, k_begin + max_smooth_cells_per_call);

    // smooth phase 直接写 buffer：避免构造 Dictionary / K 级临时 CSR 数组 / neighbor_is_water。
    {
        t_p = std::chrono::high_resolution_clock::now();
        if (K > 0 && have_nb && k_begin < k_end) {
            const int32_t * const REAL = smo_real_indices.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const int32_t * const FLAT = soa.flat_px_indices.ptr();
            const int32_t * const NB = nb_arr.ptr();
            int32_t * const PS = st->prev_sigs_smo.ptrw();
            uint8_t * const BUF = st->buf_smo.ptrw();
            const int flat_n = soa.flat_px_indices.size();

            // sea-ice-render-source-unify 阶段 C：sig_of 改用 is_water + sea_ice_frac，
            // 让 SEA_ICE / OCEAN 等水域 cell 的 A 通道写 ice_byte（与 GDScript fallback
            // _dynamic_cell_signature 1:1 对齐）。
            auto sig_of = [&](int idx) -> uint32_t {
                return pk_atlas_sig_dynamic(
                    double(TEMP[idx]), double(MOIST[idx]),
                    double(SNOW[idx]), double(VIT[idx]),
                    double(ICE[idx]), cell_is_water(idx));
            };

            for (int k = k_begin; k < k_end; ++k) {
                const int ci = REAL[k];
                if (ci < 0 || ci >= n_cells) continue;

                const uint32_t c_sig = sig_of(ci);
                const int cr = int(c_sig & 0xFFu);
                const int cg = int((c_sig >> 8) & 0xFFu);
                const int cb = int((c_sig >> 16) & 0xFFu);
                const int ca = int((c_sig >> 24) & 0xFFu);
                // sea-ice-render-source-unify 阶段 C：A 通道水陆分裂均值，
                // 与 GDScript dyn_atlas_smooth_chunk_step / encode_dyn_smooth_atlas
                // 函数版 1:1 对齐。中心 is_water 决定只累加同语义邻居 A。
                const bool center_is_water = cell_is_water(ci);

                uint32_t hood_h = 0x811C9DC5u;
                hood_h = (hood_h ^ uint32_t(cr)) * 0x01000193u;
                hood_h = (hood_h ^ uint32_t(cg)) * 0x01000193u;
                hood_h = (hood_h ^ uint32_t(cb)) * 0x01000193u;
                hood_h = (hood_h ^ uint32_t(ca)) * 0x01000193u;

                int nr = 0, ng = 0, nb_sum = 0, na = 0, nc = 0, na_c = 0;
                const int nb_base = ci * 6;
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[nb_base + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    const uint32_t n_sig = sig_of(int(ni));
                    const int nrb = int(n_sig & 0xFFu);
                    const int ngb = int((n_sig >> 8) & 0xFFu);
                    const int nbb = int((n_sig >> 16) & 0xFFu);
                    const int nab = int((n_sig >> 24) & 0xFFu);
                    nr += nrb; ng += ngb; nb_sum += nbb; ++nc;
                    // A 通道独立计数：仅累加与中心同水/陆类的邻居，避免
                    // sea_ice_frac 与 vegetation_vitality 异语义数据互相污染。
                    const bool n_is_water = cell_is_water(int(ni));
                    if (center_is_water == n_is_water) {
                        na += nab;
                        ++na_c;
                    }
                    hood_h = (hood_h ^ uint32_t(nrb)) * 0x01000193u;
                    hood_h = (hood_h ^ uint32_t(ngb)) * 0x01000193u;
                    hood_h = (hood_h ^ uint32_t(nbb)) * 0x01000193u;
                    hood_h = (hood_h ^ uint32_t(nab)) * 0x01000193u;
                }

                // [TEMP DIAG sea-ice phase D-smo]
                const bool _diag_smo_match = (TERR[ci] == 20) && (double(ICE[ci]) > 0.5);
                const bool _diag_smo_skip = cache_valid_smo && uint32_t(PS[ci]) == hood_h;
                static int _diag_smo_dumped = 0;
                if (_diag_smo_dumped < 8 && _diag_smo_match) {
                    UtilityFunctions::print(
                        "[PHASE-D-SMO] ci=", ci, " TERR=", int(TERR[ci]),
                        " ICE=", double(ICE[ci]),
                        " ca=", ca, " nc=", nc, " na_c=", na_c,
                        " na_sum=", na,
                        " hood_h=", String::num_uint64(uint64_t(hood_h), 16),
                        " PS_hood=", String::num_uint64(uint64_t(uint32_t(PS[ci])), 16),
                        " skip=", _diag_smo_skip,
                        " cache_valid_smo=", cache_valid_smo);
                    ++_diag_smo_dumped;
                }
                if (_diag_smo_skip) {
                    continue;
                }
                PS[ci] = int32_t(hood_h);

                int or_, og, ob, oa;
                if (nc > 0) {
                    or_ = (cr + (nr / nc)) / 2;
                    og = (cg + (ng / nc)) / 2;
                    // sea-ice-render-source-unify 阶段 C：B 通道（snow_cover）
                    // 改为 passthrough（与 encode_dyn_smooth_atlas 函数版 1:1）。
                    // 历史原因：单格 95% 雪盖会被无雪邻居拖到 ~47.5%，shader 后段
                    // smoothstep 直接压成不可见。对 B 不做 box blur 是必要妥协。
                    ob = cb;
                    // A 通道：用同水陆类邻居数 na_c 做均值，全异类 (na_c=0) 退回中心值。
                    if (na_c > 0) {
                        oa = (ca + (na / na_c)) / 2;
                    } else {
                        oa = ca;
                    }
                } else {
                    or_ = cr; og = cg; ob = cb; oa = ca;
                }

                // [TEMP DIAG sea-ice phase D-smo-final]
                static int _diag_smo_oa_dumped = 0;
                if (_diag_smo_oa_dumped < 8 && TERR[ci] == 20 && double(ICE[ci]) > 0.5) {
                    UtilityFunctions::print(
                        "[PHASE-D-SMO-OA] ci=", ci, " ICE=", double(ICE[ci]),
                        " ca=", ca, " na=", na, " na_c=", na_c,
                        " oa=", oa,
                        " first_px=", SF[ci], " count=", SC[ci]);
                    ++_diag_smo_oa_dumped;
                }

                const int first = SF[ci];
                const int count = SC[ci];
                if (count <= 0 || first < 0 || first + count > flat_n) continue;
                for (int p = 0; p < count; ++p) {
                    const int px_idx = FLAT[first + p];
                    if (px_idx < 0 || px_idx >= n_pix) continue;
                    const int base = px_idx * 4;
                    BUF[base    ] = uint8_t(or_);
                    BUF[base + 1] = uint8_t(og);
                    BUF[base + 2] = uint8_t(ob);
                    BUF[base + 3] = uint8_t(oa);
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_smo_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_smo_fin = 0.0;
    }
    st->prep_smo_cursor = k_end;
    smo_real_count = smo_real_indices.size();
    if (st->prep_smo_cursor < smo_real_count) {
        yielded = true;
    } else {
        st->prep_smo_ready = false;
        st->prep_smo_cursor = 0;
        st->prep_smo_real_indices = PackedInt32Array();
        st->phase = AtlasPipelineState::ICE;
        ++phases_done_this_call;
        if (phases_done_this_call >= phase_budget) yielded = true;
    }
    }  // end Phase SMOOTH gate

    // ────────────────────────────────────────────────────────────────────
    // Phase ICE：dirty ∩ water；cache_invalid 时全水域；走 water_cell_pixel_lists
    //   注意：ice atlas 的 pixel layout 来自 water_cell_pixel_lists（而非整图
    //   cell_pixel_lists），但 SoA cell_first_px_arr 是整图的，不能直接复用。
    //   解决：fallback 用 SoA 整图 pixel list，shader 端 mask 已经只读水域。
    //   实际上 GD encode_ice_state_atlas 已用 sea_ice_frac 量化（陆地 cell
    //   sea_ice_frac=0 → byte=0），所以走整图 SoA 也能得到 bit-equal 结果。
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::ICE) {
    PackedInt32Array ice_real_indices;
    t_p = std::chrono::high_resolution_clock::now();
    {
        bool skip_phase = false;
        if (!cache_valid_ice) {
            // cache_invalid → 全水域 cell（以 SoA cell_first_px>=0 + passable_sea
            // 作筛选。此处简化为全集，encode 内部对陆地 cell 写 byte=0 与原行为等价）。
            // 注意：这里用 cell_is_ice_renderable 而非 cell_psea —— 已结冰
            // (terrain==SEA_ICE) 的 cell 也要进入编码集，否则视觉上看不到冰。
            ice_real_indices.resize(n_cells);
            int kw = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (cell_is_ice_renderable(i)) ice_real_indices[kw++] = i;
            }
            ice_real_indices.resize(kw);
        } else if (dirty_path_used && dirty_noop) {
            // 完全无变化：跳过
            skip_phase = true;
        } else if (dirty_path_used) {
            // dirty ∩ water
            ice_real_indices.resize(dirty_indices.size());
            int kw = 0;
            const int32_t * const D = dirty_indices.ptr();
            int32_t * const OUT = ice_real_indices.ptrw();
            int32_t * const PV = st->prev_sigs_ice.ptrw();
            for (int i = 0; i < dirty_indices.size(); ++i) {
                const int idx = D[i];
                if (idx < 0 || idx >= n_cells || !cell_is_ice_renderable(idx)) continue;
                // value-diff
                const int byte_v = pk_q01_byte_ice(double(ICE[idx]));
                if (cache_valid_ice && PV[idx] == byte_v) continue;
                PV[idx] = byte_v;
                OUT[kw++] = idx;
            }
            ice_real_indices.resize(kw);
        } else {
            // 无 dirty path：全水域
            // 同上：用 cell_is_ice_renderable 把 SEA_ICE terrain 也纳入编码集。
            ice_real_indices.resize(n_cells);
            int kw = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (cell_is_ice_renderable(i)) ice_real_indices[kw++] = i;
            }
            ice_real_indices.resize(kw);
        }
        (void)skip_phase;
    }
    t_q = std::chrono::high_resolution_clock::now();
    st->ms_ice_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();

    // 调 encode_ice_state_atlas
    {
        t_p = std::chrono::high_resolution_clock::now();
        const int K = ice_real_indices.size();
        if (K > 0) {
            // ★ 修复 C：完全内联 encode 逻辑，绕开 encode_ice_state_atlas 函数。
            // 原因：Apple Clang ARM64 在 encode_ice_state_atlas 函数内部对
            // PackedFloat32Array.ptr() 的间接索引读 ICE[ci] 做 alias-DCE，
            // 即便加 volatile/memcpy 也无法稳定规避（pixels_written 一直=0）。
            // 外层 ICE 指针在 PIPELINE-ENTRY 探针中证实工作良好（first_nz=0,val=1.0），
            // 因此把整个编码循环搬到外层 scope，直接读 ICE/写 buf_ice。
            const int32_t * const REAL = ice_real_indices.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const int32_t * const FLAT = soa.flat_px_indices.ptr();
            const int n_pix_local = n_pix;
            const int flat_size = soa.flat_px_indices.size();
            int32_t * const PV = st->prev_sigs_ice.ptrw();

            // 取 buf_ice 写入指针（如果尺寸不对先 resize）
            if (st->buf_ice.size() != n_pix_local) {
                st->buf_ice.resize(n_pix_local);
                uint8_t * const BUF_INIT = st->buf_ice.ptrw();
                for (int p = 0; p < n_pix_local; ++p) BUF_INIT[p] = 0;
            }
            uint8_t * const BUF = st->buf_ice.ptrw();

            for (int k = 0; k < K; ++k) {
                const int ci = REAL[k];
                if (ci < 0 || ci >= n_cells) continue;
                const float ice_v = ICE[ci];   // ★ 外层 ICE 已证可信
                const int byte_v = pk_q01_byte_ice(double(ice_v));
                // 同步 prev_sigs_ice，使后续 dirty path 的 value-diff 正确
                PV[ci] = int32_t(byte_v);
                // 写像素
                const int f = SF[ci];
                const int c_cnt = SC[ci];
                if (f < 0 || c_cnt <= 0) continue;
                for (int p = 0; p < c_cnt; ++p) {
                    const int fi = f + p;
                    if (fi < 0 || fi >= flat_size) continue;
                    const int px_idx = FLAT[fi];
                    if (px_idx < 0 || px_idx >= n_pix_local) continue;
                    BUF[px_idx] = uint8_t(byte_v);
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_ice_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_ice_fin = 0.0;
    }
    ice_real_count = ice_real_indices.size();
    st->phase = AtlasPipelineState::DONE;
    ++phases_done_this_call;
    // ICE 是最后一个 phase，跑完 phase=DONE，无需再 yield 检查
    }  // end Phase ICE gate

    auto t_total_end = std::chrono::high_resolution_clock::now();
    const double this_call_ms = std::chrono::duration<double, std::milli>(
        t_total_end - t_total_start).count();
    st->stride_total_ms_accum += this_call_ms;

    // 状态机：phase==DONE → 本 stride 跑完；否则中途 yield。
    const bool stride_done = (st->phase == AtlasPipelineState::DONE);
    if (stride_done) {
        st->stride_active = false;
        st->stride_counter += 1;
    }
