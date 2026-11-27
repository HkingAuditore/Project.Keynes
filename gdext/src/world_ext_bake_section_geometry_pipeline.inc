// ─────────────────────────────────────────────────────────────────────────
// run_bake_geometry_fields_pass — bake 期几何场编排下沉 C++（dots-total-cpp step2）
// GDScript 一次请求 → C++ 进程内串起 terrain-index → erosion → river → latitude，
// 中间 buffer（尤其 height_buffer）不跨语言往返，一次返回完整 bundle。
// ─────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::run_bake_geometry_fields_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    if (w <= 0 || h <= 0) {
        out["reason"] = String("invalid size");
        return out;
    }

    auto t_all0 = std::chrono::high_resolution_clock::now();

    // ① terrain-index：height/biome/moisture/veg/cover + CSR + pixel_to_cell_index。
    Dictionary terr = run_bake_terrain_index_pass(knobs);
    const bool terr_fallback = bool(terr.get("fallback", true));
    if (terr_fallback) {
        // terrain 是 bundle 的数据枢纽（CSR / pixel_to_cell 后续解包必需）；失败则整体 fallback，
        // 由 GDScript 回退旧 per-pass / _bake_height_biome_moisture 路径。
        out["reason"] = String("terrain_index_fallback:") + String(terr.get("reason", String()));
        return out;
    }
    PackedFloat32Array height_buf = terr.get("height_buffer", PackedFloat32Array());
    // 刻谷/侵蚀/下切之前的程序高度；visual tile 用 final − procedural 作为低频改造量，
    // 叠到 tile 分辨率重算的程序高度上（COW：下面 ptrw 不会改到这份）。
    const PackedFloat32Array procedural_height = height_buf;

    // ③ river SDF：读 ext 暂存拓扑（_gen_river_*），trace+CR+warp+stamp+chamfer+normalize。
    //    不依赖高度，提前算好供汇流刻谷把河道当作出口。
    Dictionary riv = run_bake_river_sdf_pass(knobs);
    const bool riv_ok = !bool(riv.get("fallback", true));

    // ── 侵蚀阶段（①b 刻谷 / SPL 管线 + ② droplet）：模式分支（contracts §3.1）──────────
    // carve = 现状全序（刻谷 + droplet，逐位基线）／spl = 只 SPL 管线／
    // spl+carve = SPL + 浅刻谷（dem_spl_carve_scale）／droplet = 仅 droplet。
    // C++ 缺省恒 "carve"：perf-validation 不传该 knob → 与改动前逐位相同（计划 §12 Q5）。
    const ErosionKnobs ek = pk_parse_erosion_knobs(knobs);
    // 模式串规范化：只有四个已知取值生效；其它（拼写错误 / 旧存档 knob）一律回退 carve，
    // 即「不认识的模式 = 现状行为」，与「C++ 缺省恒 carve」同一取向（契约 §3.1）。
    // 注：godot::String 只重载了 operator==(const char*)，比较一律走 == 包装，避免 != 触发
    //     Variant/StringName 的隐式转换而变得有歧义。
    String erosion_mode = ek.mode;
    auto mode_is = [&erosion_mode](const char *m) { return erosion_mode == m; };
    if (!mode_is("carve") && !mode_is("spl") && !mode_is("spl+carve") && !mode_is("droplet")) {
        erosion_mode = String("carve");
    }
    const bool mode_carve = mode_is("carve");
    const bool mode_spl = mode_is("spl") || mode_is("spl+carve");
    const bool mode_spl_carve = mode_is("spl+carve");
    const bool mode_droplet = mode_is("droplet");
    // droplet 只在 carve（逐位基线）与 droplet（历史对照）执行；spl* 跳过（计划 §4.8 / checklist §A1）。
    const bool run_droplet = (mode_carve || mode_droplet);
    // 全量刻谷只在 carve 执行；droplet 模式按 A1「仅 droplet」，不做几何刻谷。
    const bool run_carve_legacy = mode_carve;

    const int np_erosion = w * h;
    const double depth_per_relief = double(knobs.get("dem_valley_depth_per_relief", 1.4));
    PackedFloat32Array dem_relief = terr.get("dem_relief_buffer", PackedFloat32Array());
    PackedByteArray biome = terr.get("biome_buffer", PackedByteArray());
    const bool erosion_sizes_ok = height_buf.size() == np_erosion
            && dem_relief.size() == np_erosion && biome.size() == np_erosion;

    double valley_ms = -1.0;             // 刻谷阶段（carve：出口集合 + 刻谷；spl+carve：仅浅刻谷）
    double carve_ms = -1.0;              // carve 的 CarveStats.total_ms（未跑 = -1）
    double erosion_stage_ms = -1.0;      // spl*：整个侵蚀阶段（管线 [+ 浅刻谷]）
    pk_dem::CarveStats carve_stats;      // 未跑 carve 时全 -1（=「未执行」）
    SplPipelineReport spl_rep;           // 未跑 SPL 时 ok=false、分项全 -1
    PackedFloat32Array area_hex_diag;    // [S2/S4.4 诊断] 仅 dem_erosion_area_dump=1 时填充

    // 出口集合 wet = 水体 ∪ 河心像素（carve 与 SPL 共用的汇流出口，沿用 carve 约定 R4）。
    // 计时起点仍在出口集合构造之前：carve 模式下 valley_ms 的语义与改动前一致。
    auto tv0 = std::chrono::high_resolution_clock::now();
    // ── [S7-T7 2026-11-18] G2 注入门（计划 §10.4）──────────────────────────────────────
    // dem_spl_inject_cell_area（bool，**缺省 false**）为真、且满足「spl* 模式 + 河流拓扑/p2c 齐备」
    // 时，才把 cell 层汇水注入像素 SPL（河心像素不再是出口）。**carve 模式恒 false**（逐位基线不许
    // 动）；任意条件不满足（缺 p2c / 缺 _gen_river_* / n_cells 对不上）也 false ⇒ 下面三条路径
    // （wet 语义 / 注入场 / G3 下切）全部退回改动前的实现，与 knob=false 的逐位一致同一条路。
    const int n_cells_bake = int(knobs.get("n_cells", 0));
    const PackedInt32Array p2c_all = terr.get("pixel_to_cell_index", PackedInt32Array());
    const double river_outlet_flow = double(knobs.get("dem_valley_river_outlet_flow", 0.6));
    PackedFloat32Array river_sdf_hi;   // G2/G3 共用：河 SDF（河心=1 → 远岸=0）
    if (riv_ok) river_sdf_hi = riv.get("out_buf", PackedFloat32Array());
    const bool spl_inject_on = ek.spl_inject_cell_area && mode_spl && erosion_sizes_ok
            && riv_ok && river_sdf_hi.size() == np_erosion
            && n_cells_bake > 0 && int(p2c_all.size()) == np_erosion
            && _gen_river_n == n_cells_bake
            && int(_gen_river_has.size()) == _gen_river_n
            && int(_gen_river_downstream.size()) == _gen_river_n;
    std::vector<float> inject_hi;      // 每像素注入面积（hex²，只有陆上河心像素非 0）
    double inject_ms = -1.0;           // up_cells + 注入场构造耗时（G2 专用分项；未执行 = -1）
    std::vector<uint8_t> wet;
    if (erosion_sizes_ok && (mode_spl || run_carve_legacy)) {
        wet.assign(static_cast<size_t>(np_erosion), uint8_t(0));
        const uint8_t *BI = biome.ptr();
        for (int i = 0; i < np_erosion; ++i) wet[size_t(i)] = pk_is_water_terrain(BI[i]) ? 1 : 0;
        // [S7-T7] G2：注入开启 ⇒ wet 只含**真水体**（pk_is_water_terrain），河心像素改为「带外部
        //   汇水的普通陆地像素」，照常进入流向树并被 SPL 下切/限坡；关闭 ⇒ 旧语义（河心并入 wet
        //   当汇流出口）。旧语句原样保留在下面这个分支里，关闭时逐位不变。
        if (!spl_inject_on) {
            if (riv_ok) {
                PackedFloat32Array flow = riv.get("out_buf", PackedFloat32Array());
                const double outlet = river_outlet_flow;
                if (flow.size() == np_erosion && outlet < 1.0) {
                    const float *FL = flow.ptr();
                    for (int i = 0; i < np_erosion; ++i) {
                        if (double(FL[i]) >= outlet) wet[size_t(i)] = 1;
                    }
                }
            }
        }
    }

    // ── [S7-T7 2026-11-18] G2：cell 河流汇水注入像素 SPL（计划 §10.4）────────────────────
    // 像素层原来的「河心像素 = wet 出口」把汇水在河心截断（实测 A_hex p99 只有 1.55 hex²），干流在
    // 像素层从不被 SPL 下切，支谷只能在河边「悬挂」。这里用 post_base 已暂存的 cell 河流拓扑做一次
    // 上游累积，把每格的上游面积均摊到该格内的陆上河心像素上，作为它们在流向树里的初始汇水增量：
    //   1) up_cells[c]：沿 _gen_river_downstream 反向累加（每个河流格自身贡献 1 格，O(n_cells)）；
    //   2) n_center[c]：该格内「河 SDF ≥ 出口阈值且非真水体」的像素数；
    //   3) inject[i] = up_cells[c] · cell_area_hex / max(1, n_center[c])，cell_area_hex = √3/2。
    // 不变量：只降 / 陆地不下海 / 水体逐位不动都不受影响（注入只改 area_hex 初值与受体偏好）。
    if (spl_inject_on) {
        const auto t_inj0 = std::chrono::high_resolution_clock::now();
        const int rn = _gen_river_n;
        const int32_t * const DOWN = _gen_river_downstream.data();
        // 1) up_cells：Kahn 拓扑序（入度 = 有多少 cell 把本格声明为自己的下游）一次 O(n_cells) 扫描。
        //    按 cell 下标序入队 ⇒ 确定性；自环/环不参与（不会死循环，退化为未累加）。
        std::vector<int32_t> up(size_t(rn), 0);
        std::vector<int32_t> indeg(size_t(rn), 0);
        for (int c = 0; c < rn; ++c) {
            if (_gen_river_has[size_t(c)] != 0) up[size_t(c)] = 1;
            const int32_t d = DOWN[c];
            if (d >= 0 && d < rn && d != c) indeg[size_t(d)] += 1;
        }
        std::vector<int32_t> topo;
        topo.reserve(size_t(rn));
        for (int c = 0; c < rn; ++c) {
            if (indeg[size_t(c)] == 0) topo.push_back(int32_t(c));
        }
        for (size_t qi = 0; qi < topo.size(); ++qi) {
            const int32_t c = topo[qi];
            const int32_t d = DOWN[c];
            if (d < 0 || d >= rn || d == c) continue;
            if (up[size_t(c)] > 0) up[size_t(d)] += up[size_t(c)];
            if (--indeg[size_t(d)] == 0) topo.push_back(d);
        }
        // 2) n_center[c]：每格内的陆上河心像素数（真水体不进注入 —— 它们仍是 wet 出口）。
        //    顺手把合格像素下标收进 inj_px（河心像素只占 np 的百分之一量级），后面第 3 步只遍历它，
        //    避免再对整个像素面重算一遍判据。
        const float * const FLP = river_sdf_hi.ptr();
        const int32_t * const P2C = p2c_all.ptr();
        const uint8_t * const BI = biome.ptr();
        inject_hi.assign(static_cast<size_t>(np_erosion), 0.0f);
        std::vector<int32_t> n_center(size_t(rn), 0);
        std::vector<int32_t> inj_px;
        inj_px.reserve(size_t(np_erosion) / 64 + 64);
        for (int i = 0; i < np_erosion; ++i) {
            if (double(FLP[i]) < river_outlet_flow) continue;      // 非河心
            if (pk_is_water_terrain(BI[i])) continue;              // 真水体不动（wet 出口）
            const int ci = P2C[i];
            if (ci < 0 || ci >= rn) continue;                      // 该像素 cell 未知 → 不注入
            n_center[size_t(ci)] += 1;
            inj_px.push_back(int32_t(i));
        }
        // 3) 把整格上游面积均摊到格内河心像素（分母取 max(1, n) ⇒ 恒有定义、不会除零）。
        constexpr double PK_CELL_AREA_HEX = 0.86602540378443864676;   // √3/2：单格面积（hex²）
        float * const INJ = inject_hi.data();
        for (size_t q = 0; q < inj_px.size(); ++q) {
            const int32_t i = inj_px[q];
            const int ci = P2C[i];
            const double denom = double(std::max(1, int(n_center[size_t(ci)])));
            INJ[size_t(i)] = float(double(up[size_t(ci)]) * PK_CELL_AREA_HEX / denom);
        }
        inject_ms = std::chrono::duration<double, std::milli>(
                std::chrono::high_resolution_clock::now() - t_inj0).count();
    }

    // 栅格几何（carve 与 SPL 共用同一套算式；三个算式与改动前逐字相同）
    const double size_x = double(knobs.get("size_x", 0.0));
    const double step_x = size_x / double(w);
    const double period = double(knobs.get("wrap_period_x", 0.0));
    const double hex_size = double(knobs.get("hex_size", 1.0));
    const double bake_sea_level = double(knobs.get("sea_level", 0.64));
    const double bake_hex_px = step_x > 1e-9 ? hex_size * 1.7320508075688772 / step_x : 1.0;
    int bake_wrap_cols = 0;
    if (bool(knobs.get("wrap_x", true)) && period > 1e-6 && step_x > 1e-9) {
        bake_wrap_cols = std::min(w, int(std::llround(period / step_x)));
    }

    if (mode_spl) {
        // ── spl / spl+carve：SPL 管线（计划 §4.1：建树 → 系数 → 下切 → [沉积/展宽] → 限坡）──
        const auto ts0 = std::chrono::high_resolution_clock::now();
        if (!erosion_sizes_ok) {
            spl_rep.reason = "erosion buffers size mismatch";
        } else {
            // spl+carve 且 factor==1 时复用 SPL 的填洼（checklist §A2：省掉第二次填洼）
            pk_dem::FillResult fill_reuse;
            spl_rep = pk_run_erosion_spl_pipeline(
                    height_buf.ptrw(), dem_relief.ptr(), wet.data(), w, h, bake_wrap_cols,
                    bake_hex_px, bake_sea_level, ek.max_dim, ek.sp, ek.dep, ek.lim,
                    // [S7-T7] G2 注入四参：未开启时全传 nullptr/0 ⇒ Grid 的三个新指针保持 nullptr，
                    //   build_flow 的注入分支整体不进入（knob=false 的逐位基线）。
                    spl_inject_on ? inject_hi.data() : nullptr,
                    spl_inject_on ? p2c_all.ptr() : nullptr,
                    spl_inject_on ? _gen_river_downstream.data() : nullptr,
                    spl_inject_on ? _gen_river_n : 0,
                    ek.pit_audit, mode_spl_carve ? &fill_reuse : nullptr,
                    ek.area_dump ? &area_hex_diag : nullptr);
            if (mode_spl_carve && spl_rep.ok) {
                // 浅刻谷：只叠一层浅谷形（深度 × dem_spl_carve_scale），不跑 droplet。
                const double carve_depth = depth_per_relief * ek.carve_scale;
                if (carve_depth > 0.0) {
                    pk_dem::DrainageParams cdp;
                    cdp.width = w;
                    cdp.height = h;
                    cdp.wrap_cols = bake_wrap_cols;
                    cdp.sea_level = bake_sea_level;
                    cdp.hex_px = bake_hex_px;
                    cdp.depth_per_relief = carve_depth;
                    cdp.wall_per_relief = double(knobs.get("dem_valley_wall_per_relief", 5.0));
                    cdp.area_lo_px = double(knobs.get("dem_valley_area_lo", 8.0));
                    cdp.area_hi_px = double(knobs.get("dem_valley_area_hi", 4000.0));
                    cdp.depth_exp = double(knobs.get("dem_valley_depth_exp", 0.8));
                    cdp.mfd_exponent = double(knobs.get("dem_valley_mfd_exponent", 6.0));
                    const auto tc0 = std::chrono::high_resolution_clock::now();
                    const pk_dem::FillResult *reuse = fill_reuse.z.empty() ? nullptr : &fill_reuse;
                    pk_dem::carve_drainage_valleys(height_buf.ptrw(), dem_relief.ptr(), wet.data(),
                            cdp, &carve_stats, reuse);
                    valley_ms = std::chrono::duration<double, std::milli>(
                            std::chrono::high_resolution_clock::now() - tc0).count();
                    carve_ms = carve_stats.total_ms;
                    spl_rep.carve_ms = carve_stats.total_ms;
                }
            }
        }
        if (spl_rep.ok) {
            erosion_stage_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::high_resolution_clock::now() - ts0).count();
        }
    } else if (run_carve_legacy && depth_per_relief > 0.0 && erosion_sizes_ok) {
        // ── carve：现状全序（逐位基线）────────────────────────────────────────
        // 与原实现逐条相同：DrainageParams 每个字段、carve 调用顺序、写回位置都不变；
        // 唯一差异是多传了 &carve_stats（只读并行计时，不参与任何计算）。
        pk_dem::DrainageParams dp;
        dp.width = w;
        dp.height = h;
        dp.wrap_cols = bake_wrap_cols;
        dp.sea_level = bake_sea_level;
        dp.hex_px = bake_hex_px;
        dp.depth_per_relief = depth_per_relief;
        dp.wall_per_relief = double(knobs.get("dem_valley_wall_per_relief", 5.0));
        dp.area_lo_px = double(knobs.get("dem_valley_area_lo", 8.0));
        dp.area_hi_px = double(knobs.get("dem_valley_area_hi", 4000.0));
        dp.depth_exp = double(knobs.get("dem_valley_depth_exp", 0.8));
        dp.mfd_exponent = double(knobs.get("dem_valley_mfd_exponent", 6.0));
        pk_dem::carve_drainage_valleys(height_buf.ptrw(), dem_relief.ptr(), wet.data(), dp, &carve_stats);
        carve_ms = carve_stats.total_ms;
        valley_ms = std::chrono::duration<double, std::milli>(
                std::chrono::high_resolution_clock::now() - tv0).count();
    }

    // ② droplet：carve（逐位基线）与 droplet（历史对照）执行，spl* 跳过
    //    （计划 §4.8「默认路径不再调用液滴」在 DEM_DEFAULTS 切到 spl 后自动成立）。
    //    height_final 的赋值顺序与改动前一致：droplet 失败 → 用当前高度（含刻谷 / SPL）续算。
    Dictionary ero;
    bool ero_ok = false;
    if (run_droplet) {
        knobs["height_buffer"] = height_buf;   // C++ 内注入 height_buffer，不跨语言
        ero = run_bake_erosion_pass(knobs);
        ero_ok = !bool(ero.get("fallback", true));
    }
    PackedFloat32Array height_final = height_buf;
    if (ero_ok) {
        PackedFloat32Array he = ero.get("height_out", PackedFloat32Array());
        if (he.size() == height_buf.size()) height_final = he;
    }

    // 整个侵蚀阶段的状态与耗时（erosion_ok / erosion_ms 语义保留 = 该阶段整体，contracts §3.4）
    const bool erosion_ok = mode_spl ? spl_rep.ok : ero_ok;
    const double erosion_ms = mode_spl ? erosion_stage_ms : double(ero.get("elapsed_ms", -1.0));

    // ④ latitude。
    Dictionary lat = run_bake_latitude_field_pass(knobs);
    const bool lat_ok = !bool(lat.get("fallback", true));

    // [river-carve-bake 2026-06-25] #2a 河流切进 bake height_buffer（per-pixel，crisp 河岸法线）──
    // river SDF(flow_buffer：河心=1→远岸=0)算完后、bundle 前，按 flow 对 height_final 逐像素刻 V 形河谷。
    // flow 的 SDF 衰减天然形成河岸坡 → terrain_normal_tex/height_tex/relief 都读得到 crisp 河岸；与 #2b
    // (仿真 E 的 cell 级河谷+堤岸)叠加成多尺度河岸。仅陆地段(height>sea_level，不刻入海口/水下)；
    // fused 内 height_final 与 flow 均为 hm_size、索引对齐。GDScript legacy 路径镜像见 _carve_river_into_height。
    //
    // [S7-T7 2026-11-18] G3（计划 §10.5）分支门：只有 G2 注入真的生效（knob 开 + 拓扑齐备）**且 SPL
    //   跑成功**时才走「下切随流量 + 只补刻」的新实现；其余情况（含 carve 模式、注入关闭、SPL 失败）
    //   **整段旧循环原样执行**——P0 的 carve 逐位基线与 knob=false 的逐位一致都靠这一点守住。
    const bool river_incise_scaled = spl_inject_on && spl_rep.ok;
    if (riv_ok) {
        PackedFloat32Array flow = riv.get("out_buf", PackedFloat32Array());
        const int nf = w * h;
        if (flow.size() == nf && height_final.size() == nf) {
            constexpr double PK_BAKE_RIVER_INCISE = 0.045;  // bake 河道最大下切(height 单位，× notch)
            const double bake_sea = double(knobs.get("sea_level", 0.64));
            float * const HF = height_final.ptrw();
            const float * const FL = flow.ptr();
            if (!river_incise_scaled) {
                for (int i = 0; i < nf; ++i) {
                    const double f = double(FL[i]);
                    if (f <= 0.02) continue;
                    double e = double(HF[i]);
                    if (e <= bake_sea) continue;                    // 不刻入海口/水下
                    const double notch = f * f * (3.0 - 2.0 * f);   // smoothstep 锐化河岸坡
                    e -= PK_BAKE_RIVER_INCISE * notch;
                    if (e < 0.0) e = 0.0;
                    HF[i] = float(e);
                }
            } else {
                // incise = dem_river_incise_base + dem_river_incise_flow · river_flow(cell)
                //   （缺省 0.020 + 0.035：river_flow=1 时与上面的旧常量 0.045 同值）。
                // **只补刻**：目标 = 侵蚀前高度 e_pre − incise·notch，落点 = min(e_spl, 目标)。
                //   SPL 已经刻得比目标更低时保持 SPL 的结果不动 —— 这样 G2 的干流下切与河流 SDF 的
                //   notch 不会叠成双重深槽（风险 G-K4），支谷汇入处也不会被再压一刀。
                // 退化：p2c 缺失 / 该像素 cell 越界 / _gen_river_flow 缺失 ⇒ 该像素退回旧常量 0.045。
                const double inc_base = ek.river_incise_base;
                const double inc_flow = ek.river_incise_flow;
                const int32_t * const P2C = (p2c_all.size() == nf) ? p2c_all.ptr() : nullptr;
                const bool rflow_ok = (_gen_river_n > 0)
                        && (int(_gen_river_flow.size()) == _gen_river_n);
                const float * const RFL = rflow_ok ? _gen_river_flow.data() : nullptr;
                const float * const PRE = procedural_height.ptr();   // SPL 之前的高度（e_pre）
                for (int i = 0; i < nf; ++i) {
                    const double f = double(FL[i]);
                    if (f <= 0.02) continue;
                    double e = double(HF[i]);
                    if (e <= bake_sea) continue;                    // 不刻入海口/水下
                    const double notch = f * f * (3.0 - 2.0 * f);
                    double incise = PK_BAKE_RIVER_INCISE;           // 退化值：旧常量
                    if (P2C != nullptr && RFL != nullptr) {
                        const int ci = P2C[i];
                        if (ci >= 0 && ci < _gen_river_n) {
                            double rf = double(RFL[size_t(ci)]);
                            if (rf < 0.0) rf = 0.0;
                            else if (rf > 1.0) rf = 1.0;
                            incise = inc_base + inc_flow * rf;
                        }
                    }
                    const double target = double(PRE[i]) - incise * notch;
                    double en = (e < target) ? e : target;          // min(e_spl, e_pre − incise·notch)
                    if (en < 0.0) en = 0.0;
                    HF[i] = float(en);
                }
            }
        }
    }

    // [coast-carve-bake water-bodies] 海/湖统一离岸像素 SDF 岸坡 carve（对标河流 #2a 真实做法）──
    // 在 river carve 之后、bundle 之前，用独立 run_bake_coast_sdf_pass(chamfer DT) 算出每像素
    // 离岸距离，对 height_final 逐像素刻"陆侧上坡、止于水线"的连续岸坡 → terrain_normal_tex 拿到
    // crisp 海岸/湖岸法线（取代仅贴水 1-cell 带的 barycentric beach carve，与之加性叠加、单调下切，
    // 两者都向水线方向下压且 clamp 到 sea_level，叠加无冲突）。shore_carve_amp<=0 → 关闭（回退旧法）。
    Dictionary coast;
    bool coast_ok = false;
    {
        const double shore_carve_amp  = double(knobs.get("shore_carve_amp", 0.06));
        const int    shore_carve_band = int(knobs.get("shore_carve_band", 6));
        if (shore_carve_amp > 0.0 && shore_carve_band > 0) {
            knobs["biome_buffer"] = terr.get("biome_buffer", PackedByteArray());
            coast = run_bake_coast_sdf_pass(knobs);
            coast_ok = !bool(coast.get("fallback", true));
            if (coast_ok) {
                PackedFloat32Array csdf = coast.get("out_buf", PackedFloat32Array());
                const int nc = w * h;
                if (csdf.size() == nc && height_final.size() == nc) {
                    const double bake_sea = double(knobs.get("sea_level", 0.64));
                    const double inv_band = 1.0 / double(shore_carve_band);
                    float * const HF = height_final.ptrw();
                    const float * const CD = csdf.ptr();
                    for (int i = 0; i < nc; ++i) {
                        const double d = double(CD[i]);              // 离水像素距离（0=水/水线）
                        if (d <= 0.0 || d > double(shore_carve_band)) continue; // 水体自身 / 带外不刻
                        double e = double(HF[i]);
                        if (e <= bake_sea) continue;                 // 不刻水下
                        const double tband = 1.0 - d * inv_band;     // 近岸=1 → 带缘=0
                        const double notch = tband * tband * (3.0 - 2.0 * tband); // smoothstep 锐化
                        e -= shore_carve_amp * notch;
                        if (e < bake_sea) e = bake_sea;              // 止于水线
                        HF[i] = float(e);
                    }
                }
            }
        }
    }

    // ── [water-depth-tex 2026-06-26] 海/湖统一水深 R8（per-pixel，使用真实高程图）──────────────
    // 关键：per-cell cell_water_depth 现承载"水面高度 level"（湖=hydro_fill、海=sea_level、陆=0），
    // 逐像素用 surface - height_final（含 carve 的湖盆/洋底 + 侵蚀细节）得真实水深，再按水体类型归一化
    // （湖用湖深尺度、海用 sea_level → 湖也能吃满 [0,1] 对比）。shader 每水像素仅 1 次采样。
    // 缺失/尺寸不符 → 输出空 buffer（shader 端按缺纹理回退旧路径）。
    PackedByteArray water_depth_buf;
    {
        PackedFloat32Array cell_surf = knobs.get("cell_water_depth", PackedFloat32Array());
        PackedByteArray    cell_terr = knobs.get("cell_terrain", PackedByteArray());
        PackedInt32Array p2c = terr.get("pixel_to_cell_index", PackedInt32Array());
        const int n_cells_wd = int(knobs.get("n_cells", 0));
        const double sea = double(knobs.get("sea_level", 0.64));
        const int np = w * h;
        // 湖泊水深归一尺度（height 单位）：与 world_ext_generate 的 PK_LAKE_MAX_DEPTH(0.24) 同量级、
        // 略小以放大对比 → 湖心吃满深色、近岸浅色。
        const double LAKE_DEPTH_NORM = 0.16;
        if (n_cells_wd > 0 && cell_surf.size() == n_cells_wd && p2c.size() == np
                && height_final.size() == np && sea > 1e-4) {
            water_depth_buf.resize(np);
            uint8_t * const __restrict WB = water_depth_buf.ptrw();
            const float * const __restrict SF = cell_surf.ptr();
            const uint8_t * const __restrict CT = (cell_terr.size() == n_cells_wd) ? cell_terr.ptr() : nullptr;
            const int32_t * const __restrict P2C = p2c.ptr();
            const float * const __restrict HF = height_final.ptr();
            const double inv_sea = 1.0 / sea;
            const double inv_lake = 1.0 / LAKE_DEPTH_NORM;
            for (int i = 0; i < np; ++i) {
                const int ci = P2C[i];
                double depth01 = 0.0;
                if (ci >= 0 && ci < n_cells_wd) {
                    const double surface = double(SF[ci]);   // per-cell 水面高度（陆地=0）
                    if (surface > 1e-4) {
                        double draw = surface - double(HF[i]);  // 逐像素真实水深（height 单位）
                        if (draw < 0.0) draw = 0.0;
                        const bool is_lake = (CT != nullptr) && (CT[ci] == 18);
                        depth01 = draw * (is_lake ? inv_lake : inv_sea);
                        if (depth01 > 1.0) depth01 = 1.0;
                    }
                }
                int b = int(depth01 * 255.0 + 0.5);
                if (b < 0) b = 0; else if (b > 255) b = 255;
                WB[i] = uint8_t(b);
            }
        }
    }

    auto t_all1 = std::chrono::high_resolution_clock::now();

    // ── 合并 bundle ──
    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["width"] = w;
    out["height"] = h;

    // terrain 字段（数据枢纽，原样透传）
    out["height_buffer"] = height_final;  // 已含侵蚀
    out["procedural_height_buffer"] = procedural_height;
    out["biome_buffer"] = terr.get("biome_buffer", PackedByteArray());
    out["moisture_buffer"] = terr.get("moisture_buffer", PackedFloat32Array());
    out["vegetation_buffer"] = terr.get("vegetation_buffer", PackedByteArray());
    out["cover_buffer"] = terr.get("cover_buffer", PackedByteArray());
    out["pixel_to_cell_index"] = terr.get("pixel_to_cell_index", PackedInt32Array());
    out["edge_secondary_index_buffer"] = terr.get("edge_secondary_index_buffer", PackedByteArray());
    out["edge_distance_buffer"] = terr.get("edge_distance_buffer", PackedByteArray());
    // [cell-field warp 2026-11-18] 边界扭曲场随 terrain 原样透传：非 tiled 路径要靠这三个键
    //   把 RG8 场交给 surface 打包（layer6）；漏转发会让 P0 数据在不经 tile 的路径上静默丢失。
    out["boundary_warp_buffer"] = terr.get("boundary_warp_buffer", PackedByteArray());
    out["boundary_warp_range"] = terr.get("boundary_warp_range", 1.6);
    out["boundary_warp_clamped"] = terr.get("boundary_warp_clamped", 0);
    out["cell_first_px"] = terr.get("cell_first_px", PackedInt32Array());
    out["cell_px_count"] = terr.get("cell_px_count", PackedInt32Array());
    out["flat_px_indices"] = terr.get("flat_px_indices", PackedInt32Array());
    out["total_px"] = terr.get("total_px", 0);

    // 其余几何场（失败置空，由 GDScript 决定是否硬报错）
    out["flow_buffer"] = riv_ok ? PackedFloat32Array(riv.get("out_buf", PackedFloat32Array())) : PackedFloat32Array();
    out["latitude_buffer"] = lat_ok ? PackedFloat32Array(lat.get("latitude_buffer", PackedFloat32Array())) : PackedFloat32Array();
    out["water_depth_buffer"] = water_depth_buf;  // [water-depth-tex] 海/湖统一 R8 深度（空=回退旧 shader 路径）

    // coast SDF（离岸距离场，供调试/校验；carve 已就地作用于 height_final）
    out["coast_ok"] = coast_ok;
    out["coast_sdf_buffer"] = coast_ok ? PackedFloat32Array(coast.get("out_buf", PackedFloat32Array())) : PackedFloat32Array();
    out["coast_ms"] = coast_ok ? coast.get("elapsed_ms", -1.0) : Variant(-1.0);
    out["coast_reason"] = coast.get("reason", String());

    // stage 诊断（GDScript 打印 / 校验用）
    out["terrain_ok"] = true;
    out["valley_ms"] = valley_ms;
    out["erosion_ok"] = erosion_ok;
    out["river_ok"] = riv_ok;
    out["latitude_ok"] = lat_ok;
    out["terrain_ms"] = terr.get("elapsed_ms", -1.0);
    out["erosion_ms"] = erosion_ms;
    out["river_ms"] = riv.get("elapsed_ms", -1.0);
    out["latitude_ms"] = lat.get("elapsed_ms", -1.0);
    out["river_reason"] = riv.get("reason", String());

    // ── 侵蚀模式与分项（terrain-erosion-spl 计划 §4.11 / contracts §3.4；**只增不改**，未执行 = -1）──
    // carve 模式：只有 fill_ms/mfd_ms/wall_ms/carve_ms/valley_ms/erosion_ms 有值，SPL 项全 -1；
    // spl*：flow/spl/dep/limit/upsample + stats 有值，fill/mfd/wall 只有 spl+carve 跑浅刻谷时才有。
    out["erosion_mode"] = erosion_mode;
    out["erosion_grid_w"] = spl_rep.ok ? spl_rep.w_lo : -1;
    out["erosion_grid_h"] = spl_rep.ok ? spl_rep.h_lo : -1;
    out["erosion_grid_factor"] = spl_rep.ok ? spl_rep.factor : -1;
    out["flow_ms"] = spl_rep.flow_ms;
    out["spl_ms"] = spl_rep.spl_ms;
    out["dep_ms"] = spl_rep.dep_ms;
    out["limit_ms"] = spl_rep.limit_ms;
    out["upsample_ms"] = spl_rep.upsample_ms;
    out["carve_ms"] = carve_ms;
    out["fill_ms"] = carve_stats.fill_ms;       // carve 分项（P0 新增，未跑 = -1）
    out["mfd_ms"] = carve_stats.mfd_ms;
    out["wall_ms"] = carve_stats.wall_ms;
    out["spl_iters_effective"] = spl_rep.ok ? spl_rep.stats.iters_effective : -1;
    out["spl_p99_drop"] = spl_rep.ok ? spl_rep.stats.p99_drop : -1.0;
    out["spl_max_drop"] = spl_rep.ok ? spl_rep.stats.max_drop : -1.0;
    out["eroded_vol"] = spl_rep.ok ? spl_rep.stats.eroded_vol : -1.0;
    out["deposited_vol"] = spl_rep.ok ? spl_rep.stats.deposited_vol : -1.0;
    out["spl_sea_clamped"] = spl_rep.ok ? int(spl_rep.stats.sea_clamped) : -1;
    out["spl_nan"] = spl_rep.ok ? int(spl_rep.stats.nan) : -1;
    out["pits_in"] = spl_rep.ok ? int(spl_rep.stats.pits_in) : -1;
    out["pits_out"] = spl_rep.ok ? int(spl_rep.stats.pits_out) : -1;
    // [S2/S4.4 诊断] 像素层汇水面积（hex²）。仅 dem_erosion_area_dump=1 时非空。
    if (!area_hex_diag.is_empty()) out["area_hex_buffer"] = area_hex_diag;
    // [S7-T7 2026-11-18] G2/G3 诊断（**只增不改**，契约 §3.4）：注入是否生效 + 其构造耗时
    //   （up_cells 累积 + 逐像素注入场；未执行 = -1）。注入场的紧凑化/下采样计入 upsample_ms，
    //   build_flow 的注入分支计入 flow_ms，三者相加才是 G2 的真实成本。
    out["spl_inject_cell_area"] = spl_inject_on ? 1 : 0;
    out["spl_inject_ms"] = spl_inject_on ? inject_ms : -1.0;
    // 诊断：spl* 分支为什么没跑（尺寸不符等）；正常为空串。
    out["erosion_reason"] = String(spl_rep.ok ? "" : spl_rep.reason);
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t_all1 - t_all0).count();
    return out;
}
