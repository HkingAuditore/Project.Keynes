// run_bake_river_sdf_pass — 复刻 map_baker.gd::_bake_river_sdf 的全部计算。
// GDScript 只 trace 原始河流链（HexCell 对象图，输出极小）；本 pass 在 C++ 内完成
// 连续经度展开 + Catmull-Rom 致密化 + warp 噪声（FastNoiseLite 复刻 _warp_noise_lo/hi）+
// 变宽 polyline stamp + chamfer 3-4 双通 SDT + 归一化。dense polyline / mask 中间数据
// 全部留在 C++（最小化跨语言传输）。几何用 float 复刻 Godot Vector2 real_t；scalar 用 double。
godot::Dictionary DCWorldExt::run_bake_river_sdf_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::FastNoiseLite;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::Ref;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");

    const float origin_x = float(double(knobs.get("origin_x", 0.0)));
    const float origin_y = float(double(knobs.get("origin_y", 0.0)));
    const float inv_world_x = float(double(knobs.get("inv_world_x", 0.0)));
    const float inv_world_y = float(double(knobs.get("inv_world_y", 0.0)));
    if (inv_world_x <= 0.0f || inv_world_y <= 0.0f) return fail("invalid world scale");
    const float hex_size = float(double(knobs.get("hex_size", 1.0)));
    const int seed = int(knobs.get("seed", 0));
    const double base_radius_px = double(knobs.get("base_radius_px", 0.0));
    const double sdf_max_dist_px = double(knobs.get("sdf_max_dist_px", 5.0));
    const double wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    const int cr_step = std::max(1, int(knobs.get("cr_step", 12)));
    // [river-endpoint-taper 2026-06-26] 端点淡出：河源(headwater)与陆地死端(未入水、非汇流)的
    // 钝圆头是"断头河"观感的主因（stamp 半径有 0.40×base 下限 → 末端永远是个钝圆点）。这里沿链
    // 弧长在端点附近把"半径乘子"从 1 渐降到 taper_floor，让河首/河尾收成尖点而非钝头。仅对真正的
    // 死端(dead-end)与河源生效；入海/入湖口、汇流接点保持满宽不淡出（避免在水边/汇流处反而断开）。
    const double taper_cells = std::max(0.0, double(knobs.get("river_endpoint_taper_cells", 1.5)));
    const float taper_floor = float(std::clamp(double(knobs.get("river_endpoint_taper_floor", 0.0)), 0.0, 1.0));

    // 河流拓扑来自 ext 成员（post_base 末尾暂存），在 C++ 内 trace（零跨语言再传输）。
    const int rn = _gen_river_n;
    if (rn <= 0
            || int(_gen_river_q.size()) != rn || int(_gen_river_r.size()) != rn
            || int(_gen_river_terrain.size()) != rn || int(_gen_river_elev.size()) != rn
            || int(_gen_river_has.size()) != rn || int(_gen_river_flow.size()) != rn
            || int(_gen_river_downstream.size()) != rn
            || int(_gen_river_neighbors.size()) != size_t(rn) * 6) {
        return fail("river topology cache missing (run post_base first)");
    }

    PackedFloat32Array out_buf;
    out_buf.resize(n);
    float * const __restrict OUT = out_buf.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    // warp 噪声：复刻 map_baker.gd::_init_noise 的 _warp_noise_lo / _warp_noise_hi。
    Ref<FastNoiseLite> warp_lo;  warp_lo.instantiate();
    Ref<FastNoiseLite> warp_hi;  warp_hi.instantiate();
    if (warp_lo.is_null() || warp_hi.is_null()) return fail("fast_noise_lite_instantiate_failed");
    warp_lo->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    warp_lo->set_seed(seed + 71);
    warp_lo->set_frequency(0.024);  // WARP_FREQ
    warp_lo->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_lo->set_fractal_octaves(3);
    warp_hi->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    warp_hi->set_seed(seed + 233);
    warp_hi->set_frequency(0.024 * 3.4);  // WARP_FREQ * WARP_HIGH_FREQ_MUL
    warp_hi->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_hi->set_fractal_octaves(3);

    // mask 初值 INF。值以 chamfer 的 3-unit 基数表示到河缘的距离：保留亚像素
    // 半径，而不是把所有落在河内的 texel 都量化成同一个 0。
    static const float MASK_INF = 1.0e9f;
    std::vector<float> mask(size_t(n), MASK_INF);

    const float warp_amp = hex_size * 0.30f;
    auto fposmodf = [](float a, float b) -> float {
        float m = std::fmod(a, b);
        if (m < 0.0f) m += b;
        return m;
    };
    auto smooth01f = [](float edge0, float edge1, float x) -> float {
        if (edge1 <= edge0) return x < edge0 ? 0.0f : 1.0f;
        float t = (x - edge0) / (edge1 - edge0);
        if (t < 0.0f) t = 0.0f;
        else if (t > 1.0f) t = 1.0f;
        return t * t * (3.0f - 2.0f * t);
    };
    auto river_cyl = [&](FastNoiseLite *nz, float x, float y, float phase_origin_x = 0.0f) -> float {
        const float period = float(wrap_period_x);
        if (period <= 0.0001f) return nz->get_noise_2d(x, y);
        const float phase = fposmodf(x - phase_origin_x, period);
        const float xw = phase_origin_x + phase;
        const float base = nz->get_noise_2d(xw, y);
        const float band = std::min(std::max(hex_size * 8.0f, 1.0f), period * 0.12f);
        if (band <= 0.0001f) return base;
        const float left = nz->get_noise_2d(phase_origin_x, y);
        const float right = nz->get_noise_2d(phase_origin_x + period, y);
        const float seam_avg = (left + right) * 0.5f;
        if (phase < band) {
            const float t = smooth01f(0.0f, band, phase);
            return seam_avg + (base - seam_avg) * t;
        }
        if (phase > period - band) {
            const float t = smooth01f(0.0f, band, period - phase);
            return seam_avg + (base - seam_avg) * t;
        }
        return base;
    };

    // catmull_rom（Vector2 real_t=float），镜像 map_baker.gd::_catmull_rom。
    auto catmull = [](float p0x, float p0y, float p1x, float p1y,
                      float p2x, float p2y, float p3x, float p3y,
                      float t, float &ox, float &oy) {
        const float t2 = t * t;
        const float t3 = t2 * t;
        ox = 0.5f * (p1x * 2.0f + (p2x - p0x) * t
                + (p0x * 2.0f - p1x * 5.0f + p2x * 4.0f - p3x) * t2
                + (-p0x + p1x * 3.0f - p2x * 3.0f + p3x) * t3);
        oy = 0.5f * (p1y * 2.0f + (p2y - p0y) * t
                + (p0y * 2.0f - p1y * 5.0f + p2y * 4.0f - p3y) * t2
                + (-p0y + p1y * 3.0f - p2y * 3.0f + p3y) * t3);
    };

    // 单段 run（≥2 原始点）：CR 致密化 + warp + 变宽 stamp。中间 buffer 全留 C++。
    // rt：每个 coarse 点的"端点半径乘子"(1=满宽，<1=向尖点淡出)，随 CR 一并致密化、逐像素缩放半径。
    std::vector<float> dpx, dpy, dwd, dtp;  // dense warped points + widths + taper（run-local，复用）
    auto stamp_run = [&](const std::vector<float> &rx, const std::vector<float> &ry,
                         const std::vector<float> &rw, const std::vector<float> &rt) {
        const int m = int(rx.size());
        if (m < 2) return;
        // ── Catmull-Rom 致密化 with widths（镜像 _catmull_rom_dense_with_widths）──
        dpx.clear(); dpy.clear(); dwd.clear(); dtp.clear();
        for (int i = 0; i < m - 1; ++i) {
            const float p0x = (i > 0) ? rx[i - 1] : rx[i];
            const float p0y = (i > 0) ? ry[i - 1] : ry[i];
            const float p1x = rx[i],     p1y = ry[i];
            const float p2x = rx[i + 1], p2y = ry[i + 1];
            const float p3x = (i + 2 < m) ? rx[i + 2] : rx[i + 1];
            const float p3y = (i + 2 < m) ? ry[i + 2] : ry[i + 1];
            const float w1 = rw[i];
            const float w2 = rw[i + 1];
            const float tp1 = rt[i];
            const float tp2 = rt[i + 1];
            for (int j = 0; j < cr_step; ++j) {
                const float t = float(j) / float(cr_step);
                float cxp, cyp;
                catmull(p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y, t, cxp, cyp);
                // warp（镜像 _warp_river_chain）：noise 在 dense 点上采样
                float wx_off = river_cyl(warp_lo.ptr(), cxp, cyp) * warp_amp;
                float wy_off = river_cyl(warp_lo.ptr(), cxp + 31.7f, cyp - 17.3f, 31.7f) * warp_amp;
                wx_off += river_cyl(warp_hi.ptr(), cxp + 91.1f, cyp + 53.7f, 91.1f) * warp_amp * 0.30f;
                wy_off += river_cyl(warp_hi.ptr(), cxp - 41.5f, cyp + 23.9f, -41.5f) * warp_amp * 0.30f;
                dpx.push_back(cxp + wx_off);
                dpy.push_back(cyp + wy_off);
                dwd.push_back(w1 + (w2 - w1) * t);
                dtp.push_back(tp1 + (tp2 - tp1) * t);
            }
        }
        dpx.push_back(rx[m - 1]);
        dpy.push_back(ry[m - 1]);
        dwd.push_back(rw[m - 1]);
        dtp.push_back(rt[m - 1]);
        // ── 变宽 polyline stamp（镜像 _stamp_polyline_variable）──
        const int dn = int(dpx.size());
        for (int i = 0; i < dn - 1; ++i) {
            const double w0 = double(dwd[i]);
            const double w1 = double(dwd[i + 1]);
            const double wmax = w0 > w1 ? w0 : w1;
            // [river-hierarchy 2026-07-31] 与 map_baker._stamp_polyline_variable 同步：
            // 0.40+pow(w,1.4)*3.7 → 0.18+pow(w,1.85)*5.2，拉开干支流宽度差。
            const double seg_radius_px = base_radius_px * (0.18 + std::pow(wmax, 1.85) * 5.2);
            const int pad = int(std::ceil(seg_radius_px)) + 1;
            const float p0x = (dpx[i] - origin_x) * inv_world_x;
            const float p0y = (dpy[i] - origin_y) * inv_world_y;
            const float p1x = (dpx[i + 1] - origin_x) * inv_world_x;
            const float p1y = (dpy[i + 1] - origin_y) * inv_world_y;
            int min_x = int(std::floor(double(p0x < p1x ? p0x : p1x))) - pad;
            int max_x = int(std::ceil(double(p0x > p1x ? p0x : p1x))) + pad;
            int min_y = int(std::floor(double(p0y < p1y ? p0y : p1y))) - pad;
            int max_y = int(std::ceil(double(p0y > p1y ? p0y : p1y))) + pad;
            if (min_x < 0) min_x = 0; if (max_x > w - 1) max_x = w - 1;
            if (min_y < 0) min_y = 0; if (max_y > h - 1) max_y = h - 1;
            const float segx = p1x - p0x;
            const float segy = p1y - p0y;
            const float seg_len_sq = segx * segx + segy * segy;
            const double tp0 = double(dtp[i]);
            const double tp1 = double(dtp[i + 1]);
            for (int y = min_y; y <= max_y; ++y) {
                for (int x = min_x; x <= max_x; ++x) {
                    const float px = float(x) + 0.5f;
                    const float py = float(y) + 0.5f;
                    double t = 0.0;
                    if (seg_len_sq > 0.0001f) {
                        const float dot = (px - p0x) * segx + (py - p0y) * segy;
                        t = double(dot) / double(seg_len_sq);
                        if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
                    }
                    const double wl = w0 + (w1 - w0) * t;
                    const double taper = tp0 + (tp1 - tp0) * t;  // 端点半径乘子（1=满宽→尖点淡出）
                    const double radius = base_radius_px * (0.18 + std::pow(wl, 1.85) * 5.2) * taper;
                    const float closx = p0x + segx * float(t);
                    const float closy = p0y + segy * float(t);
                    const float ddx = px - closx;
                    const float ddy = py - closy;
                    const float dpix = std::sqrt(ddx * ddx + ddy * ddy);
                    // Keep the true local river radius in the distance seed. With a binary
                    // inside/outside mask, low-density tiles quantize every small tributary
                    // to the same one-pixel source before the SDF pass can see its flow.
                    const double edge_distance = std::max(0.0, double(dpix) - radius);
                    const float chamfer_seed = float(edge_distance * 3.0);
                    float &seed = mask[size_t(y) * w + x];
                    if (chamfer_seed < seed) seed = chamfer_seed;
                }
            }
        }
    };

    // ── 河流图遍历（镜像 _trace_all_rivers / _trace_river_chain / _find_river_*）──
    // 读 ext 暂存拓扑（by cell.index，与 _assemble_native_generation_map 装配顺序一致）。
    const int32_t * const RQ = _gen_river_q.data();
    const int32_t * const RR = _gen_river_r.data();
    const uint8_t * const RT = _gen_river_terrain.data();
    const float   * const RE = _gen_river_elev.data();
    const uint8_t * const RH = _gen_river_has.data();
    const float   * const RF = _gen_river_flow.data();
    const int32_t * const RD = _gen_river_downstream.data();
    const int32_t * const RNB = _gen_river_neighbors.data();
    const float root3 = std::sqrt(3.0f);
    // cube_to_world（pointy-top，镜像 HexUtils.cube_to_world）+ 生成期 width=clamp(river_flow)
    auto cube_wx = [&](int i) -> float { return hex_size * root3 * (float(RQ[i]) + float(RR[i]) * 0.5f); };
    auto cube_wy = [&](int i) -> float { return hex_size * 1.5f * float(RR[i]); };
    auto width_w = [&](int i) -> float { const float f = RF[i]; return f < 0.0f ? 0.0f : (f > 1.0f ? 1.0f : f); };
    // _is_river_terminal_water ≡ pk_is_water_terrain（OCEAN/COAST/LAKE/REEF/KELP/SEA_ICE 同集合）
    auto find_downstream = [&](int i) -> int {  // 镜像 _find_river_downstream_neighbor
        const int dec = RD[i];
        if (dec >= 0 && dec < rn && (RH[dec] || pk_is_water_terrain(RT[dec]))) return dec;
        int best = -1; float best_flow = RF[i];
        for (int d = 0; d < 6; ++d) {
            const int nb = RNB[size_t(i) * 6 + d];
            if (nb < 0) continue;
            if (!RH[nb] || pk_is_water_terrain(RT[nb])) continue;
            if (RF[nb] > best_flow || (std::fabs(RF[nb] - best_flow) <= 1e-5f && RE[nb] < RE[i])) {
                best_flow = RF[nb]; best = nb;
            }
        }
        return best;
    };
    auto find_terminal_water = [&](int i) -> int {  // 镜像 _find_river_terminal_water_neighbor
        int best = -1;
        for (int d = 0; d < 6; ++d) {
            const int nb = RNB[size_t(i) * 6 + d];
            if (nb < 0 || !pk_is_water_terrain(RT[nb])) continue;
            if (best < 0 || RE[nb] < RE[best]) best = nb;
        }
        return best;
    };

    // chains：每条链 = world 点序列 + 宽度 + 端点 taper（镜像 _trace_all_rivers 输出）
    std::vector<std::vector<float>> chain_x, chain_y, chain_w, chain_t;
    {
        // 端点淡出弧长（世界单位）：约 taper_cells 个 hex 间距（pointy-top 邻距 ≈ hex_size*√3）。
        const float taper_dist = hex_size * root3 * float(taper_cells);
        auto sstep01 = [](float e) -> float {
            if (e <= 0.0f) return 0.0f;
            if (e >= 1.0f) return 1.0f;
            return e * e * (3.0f - 2.0f * e);
        };
        std::vector<uint8_t> visited(size_t(rn), 0);
        std::vector<int> inbound(size_t(rn), 0);
        // pass1：inbound 计数（确定源头）
        for (int i = 0; i < rn; ++i) {
            if (!RH[i] || pk_is_water_terrain(RT[i])) continue;
            const int dec = RD[i];
            if (dec >= 0 && dec < rn && RH[dec] && !pk_is_water_terrain(RT[dec])) inbound[dec] += 1;
        }
        // pass2：从源头（inbound==0、未访问）trace 整条链
        for (int i = 0; i < rn; ++i) {
            if (!RH[i] || pk_is_water_terrain(RT[i])) continue;
            if (visited[i] || inbound[i] > 0) continue;
            std::vector<float> px, py, pw;
            px.push_back(cube_wx(i)); py.push_back(cube_wy(i)); pw.push_back(width_w(i));
            visited[i] = 1;
            int current = i;
            bool ended_in_water = false;
            bool ended_at_confluence = false;  // 在已访问的河格汇入另一条链 → 末端必须接住、不淡出
            while (true) {
                const int nxt = find_downstream(current);
                if (nxt < 0) break;
                const bool nxt_water = pk_is_water_terrain(RT[nxt]);
                px.push_back(cube_wx(nxt)); py.push_back(cube_wy(nxt));
                pw.push_back(width_w(nxt_water ? current : nxt));
                if (nxt_water) { current = nxt; ended_in_water = true; break; }
                current = nxt;
                if (visited[nxt]) { ended_at_confluence = true; break; }
                visited[nxt] = 1;
            }
            // 尾巴伸入终端水体一半（lerp 0.78），避免河口在最后陆地 cell 中心硬截断。
            bool reached_water = ended_in_water;
            if (!ended_in_water) {
                const int wnb = find_terminal_water(current);
                if (wnb >= 0) {
                    const float rex = cube_wx(current), rey = cube_wy(current);
                    const float wcx = cube_wx(wnb), wcy = cube_wy(wnb);
                    float water_dx = wcx - rex;
                    if (wrap_period_x > 0.0001) {
                        const float half_period = float(wrap_period_x * 0.5);
                        if (water_dx > half_period) water_dx -= float(wrap_period_x);
                        else if (water_dx < -half_period) water_dx += float(wrap_period_x);
                    }
                    px.push_back(rex + water_dx * 0.78f);
                    py.push_back(rey + (wcy - rey) * 0.78f);
                    pw.push_back(pw.empty() ? 0.5f : pw.back());
                    reached_water = true;
                }
            }
            const int np = int(px.size());
            if (np < 2) continue;
            // Keep a wrapped chain continuous in one unwrapped longitude frame. The
            // raster stage emits only the periodic copies intersecting this target.
            if (wrap_period_x > 0.0001) {
                const float period = float(wrap_period_x);
                const float half_period = period * 0.5f;
                for (int k = 1; k < np; ++k) {
                    while (px[k] - px[k - 1] > half_period) px[k] -= period;
                    while (px[k] - px[k - 1] < -half_period) px[k] += period;
                }
            }
            // ── 端点 taper：源头(链首)恒淡出成尖点；陆地死端(链尾且未入水、非汇流)也淡出。
            //    入海/入湖口、汇流接点保持满宽(taper=1)以接住水体/相邻链。──
            std::vector<float> pt(size_t(np), 1.0f);
            if (taper_dist > 1e-4f) {
                const bool tail_is_dead = (!reached_water) && (!ended_at_confluence);
                std::vector<float> arc(size_t(np), 0.0f);
                for (int k = 1; k < np; ++k) {
                    const float dx = px[k] - px[k - 1];
                    const float dy = py[k] - py[k - 1];
                    arc[k] = arc[k - 1] + std::sqrt(dx * dx + dy * dy);
                }
                const float total = arc[np - 1];
                const float inv_td = 1.0f / taper_dist;
                for (int k = 0; k < np; ++k) {
                    float f = sstep01(arc[k] * inv_td);              // 链首淡入（恒开）
                    if (tail_is_dead) {
                        f = std::min(f, sstep01((total - arc[k]) * inv_td));  // 链尾淡出
                    }
                    pt[k] = std::max(f, taper_floor);
                }
            }
            chain_x.push_back(px); chain_y.push_back(py); chain_w.push_back(pw); chain_t.push_back(pt);
        }
    }

    // ── 遍历 chains：连续经度 run + 与目标相交的周期副本 ──
    {
        std::vector<float> shifted_x;
        const double raster_min_x = double(origin_x);
        const double raster_max_x = double(origin_x) + double(w) / double(inv_world_x);
        const double max_radius_px = base_radius_px * 5.4 + sdf_max_dist_px + 2.0;
        const double margin_x = max_radius_px / double(inv_world_x);
        for (size_t c = 0; c < chain_x.size(); ++c) {
            const std::vector<float> &px = chain_x[c];
            const std::vector<float> &py = chain_y[c];
            const std::vector<float> &pw = chain_w[c];
            const std::vector<float> &ptp = chain_t[c];
            const int clen = int(px.size());
            if (clen < 2) continue;
            if (wrap_period_x <= 0.0001) {
                stamp_run(px, py, pw, ptp);
                continue;
            }
            const auto bounds = std::minmax_element(px.begin(), px.end());
            const double chain_min_x = double(*bounds.first);
            const double chain_max_x = double(*bounds.second);
            const int copy_min = int(std::ceil(
                    (raster_min_x - margin_x - chain_max_x) / wrap_period_x));
            const int copy_max = int(std::floor(
                    (raster_max_x + margin_x - chain_min_x) / wrap_period_x));
            for (int copy = copy_min; copy <= copy_max; ++copy) {
                if (copy == 0) {
                    stamp_run(px, py, pw, ptp);
                    continue;
                }
                shifted_x.resize(px.size());
                const float shift = float(double(copy) * wrap_period_x);
                for (size_t k = 0; k < px.size(); ++k) shifted_x[k] = px[k] + shift;
                stamp_run(shifted_x, py, pw, ptp);
            }
        }
    }

    // ── chamfer 3-4 双通 SDT（镜像 _chamfer_sdt）──
    const double d3 = 3.0, d4 = 4.0;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const int idx = y * w + x;
            double v = double(mask[idx]);
            if (v <= 0.0) continue;
            if (x > 0) { double c = double(mask[idx - 1]) + d3; if (c < v) v = c; }
            if (y > 0) {
                double c = double(mask[idx - w]) + d3; if (c < v) v = c;
                if (x > 0) { double c2 = double(mask[idx - w - 1]) + d4; if (c2 < v) v = c2; }
                if (x < w - 1) { double c2 = double(mask[idx - w + 1]) + d4; if (c2 < v) v = c2; }
            }
            mask[idx] = float(v);
        }
    }
    for (int y = h - 1; y >= 0; --y) {
        for (int x = w - 1; x >= 0; --x) {
            const int idx = y * w + x;
            double v = double(mask[idx]);
            if (v <= 0.0) continue;
            if (x < w - 1) { double c = double(mask[idx + 1]) + d3; if (c < v) v = c; }
            if (y < h - 1) {
                double c = double(mask[idx + w]) + d3; if (c < v) v = c;
                if (x > 0) { double c2 = double(mask[idx + w - 1]) + d4; if (c2 < v) v = c2; }
                if (x < w - 1) { double c2 = double(mask[idx + w + 1]) + d4; if (c2 < v) v = c2; }
            }
            mask[idx] = float(v);
        }
    }
    const double inv3 = 1.0 / 3.0;
    // 归一化为 [0,1]：1 = 河上，0 = 距离 >= SDF_MAX_DIST_PX
    const double inv_max = 1.0 / sdf_max_dist_px;
    for (int i = 0; i < n; ++i) {
        const double m = double(mask[i]) * inv3;
        double tt = m * inv_max;
        if (tt < 0.0) tt = 0.0; else if (tt > 1.0) tt = 1.0;
        OUT[i] = float(1.0 - tt);
    }

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["out_buf"] = out_buf;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("F32");
    return out;
}

// run_bake_erosion_pass — 复刻 map_baker.gd::_hydraulic_erosion（droplet 水力侵蚀）。
