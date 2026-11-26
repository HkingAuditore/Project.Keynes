    // ────────────────────────────────────────────────────────────────────
    // Phase DYNAMIC：dirty ∩ value-diff(prev_sigs_dyn)
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::DYNAMIC) {
    t_p = std::chrono::high_resolution_clock::now();
    PackedInt32Array dyn_real_indices;
    PackedInt32Array dyn_real_sigs;
    {
        // 候选集：dirty_path_used 时为 dirty_indices；否则为全集（首帧 / cache_invalid）。
        // GD 端语义：dynamic_cache_valid=false 时 _phase_cells = all_cells；
        //          dirty_noop && cache_valid 时 _phase_cells = []。
        bool use_all = !dirty_path_used || !cache_valid_dyn;
        if (dirty_noop && cache_valid_dyn) {
            // 跳过 dynamic phase
        } else {
            int32_t * const PREV = st->prev_sigs_dyn.ptrw();
            const int N = use_all ? n_cells : dirty_indices.size();
            const int32_t * const SRC = use_all ? nullptr : dirty_indices.ptr();
            // 预估 reserve；diff-skip 后真正变化的远少于 N
            dyn_real_indices.resize(N);
            dyn_real_sigs.resize(N);
            int32_t * const OUT = dyn_real_indices.ptrw();
            int32_t * const OUT_SIG = dyn_real_sigs.ptrw();
            int kw = 0;
            // [TEMP DIAG sea-ice phase D]：Fix #4 (2026-06-15) — 改为 static
            // life-of-process 计数器（之前是 lambda 局部变量，每次 round 都重置
            // 8 次 PHASE-D-DIAG，移动端热路径累积 ~0.5ms/frame）。现在全局
            // 累计 8 行，调试完毕后整段可删。
            static int _diag_d_dumped = 0;
            // 加 use_all + dirty_size 让我们看 atlas pipeline 是否在 SIF 升到 1.0 之后还被触发。
            for (int i = 0; i < N; ++i) {
                const int idx = use_all ? i : SRC[i];
                if (idx < 0 || idx >= n_cells) continue;
                // sea-ice-render-source-unify 阶段 D：cell_is_water 走 is_water_render_lut
                //   （含 SEA_ICE）→ atlas A 通道一致写 ice byte，不再走陆路径写 vit byte。
                const bool iw = cell_is_water(idx);
                const uint32_t sig = pk_atlas_sig_dynamic(
                    double(TEMP[idx]), double(MOIST[idx]),
                    double(SNOW[idx]), double(VIT[idx]), double(ICE[idx]), iw);
                // 仅 dump 用户实际关心的 SEA_ICE cell（idx 区间常见为 1900~2400）
                // 且 ICE>0.5 才是探针点击的"应当渲染冰"格。
                const bool _diag_match = (TERR[idx] == 20) && (double(ICE[idx]) > 0.5);
                const bool _diag_skip = cache_valid_dyn && uint32_t(PREV[idx]) == sig;
                if (_diag_d_dumped < 8 && _diag_match) {
                    UtilityFunctions::print(
                        "[PHASE-D-DIAG] idx=", idx,
                        " TERR=", int(TERR[idx]),
                        " use_all=", use_all,
                        " N=", N, " dirty_sz=", dirty_indices.size(),
                        " iw=", iw,
                        " ICE=", double(ICE[idx]),
                        " sig.A=", int((sig >> 24) & 0xFFu),
                        " PREV.A=", int(uint32_t(PREV[idx]) >> 24) & 0xFF,
                        " cache_valid=", cache_valid_dyn,
                        " skip=", _diag_skip);
                    ++_diag_d_dumped;
                }
                if (_diag_skip) continue;  // skip
                PREV[idx] = int32_t(sig);
                OUT[kw] = idx;
                OUT_SIG[kw] = int32_t(sig);
                ++kw;
            }
            dyn_real_indices.resize(kw);
            dyn_real_sigs.resize(kw);
        }
    }
    t_q = std::chrono::high_resolution_clock::now();
    st->ms_dyn_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();

    // dynamic phase 直接写 buffer：prep 已完成 sig-diff，避免再构造 Dictionary/CSR 临时数组并二次算 sig。
    {
        t_p = std::chrono::high_resolution_clock::now();
        const int K = dyn_real_indices.size();
        if (K > 0) {
            const int32_t * const REAL = dyn_real_indices.ptr();
            const int32_t * const SIGS = dyn_real_sigs.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const int32_t * const FLAT = soa.flat_px_indices.ptr();
            uint8_t * const BUF = st->buf_dyn.ptrw();
            const int flat_n = soa.flat_px_indices.size();
            for (int k = 0; k < K; ++k) {
                const int idx = REAL[k];
                if (idx < 0 || idx >= soa.n_cells) continue;
                const int f = SF[idx];
                const int c = SC[idx];
                if (c <= 0 || f < 0 || f + c > flat_n) continue;
                const uint32_t sig = uint32_t(SIGS[k]);
                const uint8_t r = uint8_t(sig & 0xFFu);
                const uint8_t g = uint8_t((sig >> 8) & 0xFFu);
                const uint8_t b = uint8_t((sig >> 16) & 0xFFu);
                const uint8_t a = uint8_t((sig >> 24) & 0xFFu);
                for (int p = 0; p < c; ++p) {
                    const int px_idx = FLAT[f + p];
                    if (px_idx < 0 || px_idx >= n_pix) continue;
                    const int base = px_idx * 4;
                    BUF[base    ] = r;
                    BUF[base + 1] = g;
                    BUF[base + 2] = b;
                    BUF[base + 3] = a;
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_dyn_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_dyn_fin = 0.0;
    }
    dyn_real_count = dyn_real_indices.size();
    st->phase = AtlasPipelineState::ECOLOGY;
    ++phases_done_this_call;
    if (phases_done_this_call >= phase_budget) yielded = true;
    }  // end Phase DYNAMIC gate

    // ────────────────────────────────────────────────────────────────────
    // Phase ECOLOGY：dirty ∪ active_decay；cache_invalid 时全集；维护 transition_age
    // ────────────────────────────────────────────────────────────────────
    if (!yielded && st->phase == AtlasPipelineState::ECOLOGY) {
    PackedInt32Array eco_real_indices;
    t_p = std::chrono::high_resolution_clock::now();
    {
        // 工作集：cache_invalid → 全集；cache_valid + dirty_noop + decay 空 → 跳过；
        //          cache_valid + dirty_noop + decay 非空 → 仅 decay；其它走 dirty ∪ decay
        bool skip_phase = false;
        bool use_all = false;
        if (!cache_valid_eco) {
            use_all = true;
        } else if (dirty_path_used && dirty_noop) {
            if (st->eco_active_decay_indices.size() == 0) {
                skip_phase = true;
            }
            // else: 仅 decay（下方按 active_decay_indices 处理）
        }
        if (!skip_phase) {
            // seen[i]=1 表示已经入选；避免 dirty 与 decay 重复
            std::vector<uint8_t> seen(n_cells, 0);
            if (use_all) {
                eco_real_indices.resize(n_cells);
                for (int i = 0; i < n_cells; ++i) {
                    eco_real_indices[i] = i;
                    seen[i] = 1;
                }
            } else {
                eco_real_indices.resize(dirty_indices.size() + st->eco_active_decay_indices.size());
                int kw = 0;
                if (dirty_path_used && !dirty_noop) {
                    const int32_t * const D = dirty_indices.ptr();
                    for (int i = 0; i < dirty_indices.size(); ++i) {
                        const int idx = D[i];
                        if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                        seen[idx] = 1;
                        eco_real_indices[kw++] = idx;
                    }
                }
                const int32_t * const A = st->eco_active_decay_indices.ptr();
                for (int i = 0; i < st->eco_active_decay_indices.size(); ++i) {
                    const int idx = A[i];
                    if (idx < 0 || idx >= n_cells || seen[idx]) continue;
                    seen[idx] = 1;
                    eco_real_indices[kw++] = idx;
                }
                eco_real_indices.resize(kw);
            }
        }
    }
    t_q = std::chrono::high_resolution_clock::now();
    st->ms_eco_prep = std::chrono::duration<double, std::milli>(t_q - t_p).count();

    // 调 encode_ecology_visual_atlas
    {
        t_p = std::chrono::high_resolution_clock::now();
        const int K = eco_real_indices.size();
        if (K > 0) {
            PackedInt32Array first_px; first_px.resize(K);
            PackedInt32Array px_count; px_count.resize(K);
            PackedByteArray pass_sea; pass_sea.resize(K);
            PackedByteArray prev_veg; prev_veg.resize(K);
            PackedByteArray prev_vit; prev_vit.resize(K);
            PackedByteArray prev_tr; prev_tr.resize(K);
            PackedInt32Array prev_sigs_csr; prev_sigs_csr.resize(K);
            const int32_t * const REAL = eco_real_indices.ptr();
            const int32_t * const SF = soa.cell_first_px.ptr();
            const int32_t * const SC = soa.cell_px_count.ptr();
            const float * const TR = st->eco_transition_age.ptr();
            const int32_t * const PE_PREV = st->prev_sigs_eco.ptr();
            for (int k = 0; k < K; ++k) {
                const int idx = REAL[k];
                const int f = (idx < soa.n_cells) ? SF[idx] : -1;
                const int c = (idx < soa.n_cells) ? SC[idx] : 0;
                first_px[k] = (c <= 0 || f < 0) ? 0 : f;
                px_count[k] = (c <= 0 || f < 0) ? 0 : c;
                pass_sea[k] = cell_is_water(idx) ? 1 : 0;
                // prev_veg / prev_vit 从 SoA 读 cur 即可（GD 路径下 ecology baker
                // 维护的是"上一次写入"的镜像，本管线整体下沉后，cur 直接代表上一帧
                // 本 cell 的 vegetation/vitality —— 因为 sim 在 priority<250 写完，
                // atlas pipeline 在 250 read，下一帧 sim 才会再写，所以"cur=prev"
                // 在 ecology phase 入口成立）。
                // 唯一例外：本 phase 内部"先写 prev, 再写 cur"的语义——但 GD 路径
                // _ecology_visual_signature 里 prev_vitality_byte 只用作 vit_delta，
                // 而这里 vit_delta 永远是 0（cur==prev），与 GD"首次访问 fallback 到 cur"
                // 等价。这个细节差异在 ecology atlas 上不会产生 bit 不一致，因为
                // 当真正变化时，prev 的有效 baseline 已经被前一 stride 的 SoA 写入。
                prev_veg[k] = uint8_t(VEG[idx]);
                prev_vit[k] = uint8_t(pk_q01_byte(double(VIT[idx])));
                prev_tr[k] = uint8_t(int(TR[idx]) & 0xFF);
                prev_sigs_csr[k] = (idx >= 0 && idx < n_cells) ? PE_PREV[idx] : -1;
            }
            Dictionary knobs;
            knobs["n_pix"] = n_pix;
            knobs["stride_bytes"] = 4;
            knobs["atlas_buffer"] = st->buf_eco;
            knobs["cell_indices"] = eco_real_indices;
            knobs["cell_first_px"] = first_px;
            knobs["cell_px_count"] = px_count;
            knobs["flat_px_indices"] = soa.flat_px_indices;
            knobs["cell_is_water"] = pass_sea;
            knobs["prev_veg"] = prev_veg;
            knobs["prev_vitality"] = prev_vit;
            knobs["prev_transition"] = prev_tr;
            knobs["prev_sigs"] = prev_sigs_csr;
            knobs["cache_valid"] = cache_valid_eco;
            knobs["terrain_lake"] = int(opts.get("terrain_lake", -1));
            knobs["terrain_sea_ice"] = int(opts.get("terrain_sea_ice", -1));
            knobs["veg_none"] = int(opts.get("veg_none", -1));
            Dictionary res = encode_ecology_visual_atlas(knobs);
            if (!bool(res.get("fallback", true))) {
                st->buf_eco = res["atlas_buffer"];
                // 写回 transition_age + 重建 active_decay_indices
                if (res.has("new_transition")) {
                    PackedByteArray new_tr = res["new_transition"];
                    if (new_tr.size() == K) {
                        // 写回 transition_age SoA + 收集 active decay
                        PackedInt32Array new_decay; new_decay.resize(K);
                        int dw = 0;
                        float * const TRW = st->eco_transition_age.ptrw();
                        const uint8_t *NT = new_tr.ptr();
                        for (int k = 0; k < K; ++k) {
                            const int idx = REAL[k];
                            TRW[idx] = float(NT[k]);
                            if (NT[k] > 0) new_decay[dw++] = idx;
                        }
                        new_decay.resize(dw);
                        st->eco_active_decay_indices = new_decay;
                    }
                }
                // 写回 prev_sigs_eco（虽然外层暂未用 sig-diff 过滤 eco，但保持
                // snapshot 持久化以备 future 优化）
                if (res.has("new_sigs")) {
                    PackedInt32Array new_sigs = res["new_sigs"];
                    if (new_sigs.size() == K) {
                        int32_t * const PE = st->prev_sigs_eco.ptrw();
                        const int32_t * const NS = new_sigs.ptr();
                        for (int k = 0; k < K; ++k) {
                            const int idx = REAL[k];
                            if (idx >= 0 && idx < n_cells) PE[idx] = NS[k];
                        }
                    }
                }
            }
        }
        t_q = std::chrono::high_resolution_clock::now();
        st->ms_eco_step = std::chrono::duration<double, std::milli>(t_q - t_p).count();
        st->ms_eco_fin = 0.0;
    }
    eco_real_count = eco_real_indices.size();
    st->phase = AtlasPipelineState::SMOOTH;
    ++phases_done_this_call;
    if (phases_done_this_call >= phase_budget) yielded = true;
    }  // end Phase ECOLOGY gate
