    // ── 2.55 [ocean-bathymetry 2026-06-25] 海洋深度自然化（离岸越远越深）─────────────
    // 现状根因：海洋 raw 的起伏项全乘 dist_field，离岸即趋 0，海底没有任何"拉深"机制；唯一向下的
    // 力量是极地 edge_falloff → min/max 归一化后只有极地深海、其余全挤在 sea_level 下方(浅海)。此处
    // 在 normalize 之后、侵蚀/分类之前，对 below-sea 段按"距岸 hex 距离"重塑海底：近岸大陆架(浅)→
    // 远海深渊(深)，叠低频盆地噪声造海沟/海岭。锚定 sea_level：陆地(E>=sea)完全不动 → 海陆边界/normalize
    // 的 land 段不破坏。下游 DEEP_OCEAN/OCEAN 分类、距海气候、水面深浅色全部看到自然海底（远海变深蓝、
    // 浅海大陆架，符合预期）。base pass 已 100% C++（生成 fallback 已删）→ 无 GDScript 镜像。
    // [bimodal 2026-06-26] 双峰模型负责陆地平台 + 海陆 mask；本 BFS 作为"海洋这一半"的科学剖面：
    // 给回大陆架(近海浅水)→大陆坡→深海平原的距岸渐变（不靠 cont 值，避免被海岸线噪声打散）。常开。
    {
        constexpr double PK_OCEAN_SHELF_CELLS = 3.0;    // 大陆架宽度(hex)：近岸浅水带(近海/reef/kelp)
        constexpr double PK_OCEAN_DEEP_CELLS  = 10.0;   // 到此距离(hex)达深渊
        constexpr double PK_OCEAN_SHELF_D01   = 0.06;   // 大陆架归一深度（浅，落在 COAST 带→近海可见）
        constexpr double PK_OCEAN_ABYSS_FRAC  = 0.92;   // 深渊最大深度占 sea_level 的比例
        constexpr double PK_OCEAN_BASIN_AMP   = 0.30;   // 低频盆地噪声幅度(海沟/海岭，仅深水区生效)
        const double sea = sea_level;
        if (sea > 1e-4) {
            // 多源 BFS：所有陆地格(E>=sea)为源(dist=0)，向海洋格逐 hex 扩散 → 每个海洋格得到距岸距离。
            std::vector<int32_t> cdist(size_t(n), -1);
            std::vector<int32_t> bfsq;
            bfsq.reserve(size_t(n));
            for (int i = 0; i < n; ++i) {
                if (double(E[i]) >= sea) { cdist[i] = 0; bfsq.push_back(i); }
            }
            size_t head = 0;
            while (head < bfsq.size()) {
                const int ci = bfsq[head++];
                const int cd = cdist[ci];
                const int cq = Q[ci], cr = R[ci];
                for (int k = 0; k < 6; ++k) {
                    const int ni = index_for_qr(cq + DQ[k], cr + DR[k]);
                    if (ni < 0 || cdist[ni] >= 0) continue;
                    cdist[ni] = cd + 1;
                    bfsq.push_back(ni);
                }
            }
            const double max_depth = sea * PK_OCEAN_ABYSS_FRAC;
            const double inv_ramp = 1.0 / std::max(1.0, PK_OCEAN_DEEP_CELLS - PK_OCEAN_SHELF_CELLS);
            for (int i = 0; i < n; ++i) {
                if (double(E[i]) >= sea) continue;       // 陆地不动（锚定 sea_level）
                const int d = cdist[i];
                const double dist = (d < 0) ? PK_OCEAN_DEEP_CELLS : double(d);  // 全封闭内海(理论上不会)按最深兜底
                double ramp = (dist - PK_OCEAN_SHELF_CELLS) * inv_ramp;
                if (ramp < 0.0) ramp = 0.0; else if (ramp > 1.0) ramp = 1.0;
                double depth01 = PK_OCEAN_SHELF_D01 + (1.0 - PK_OCEAN_SHELF_D01) * pk_smoothstep(0.0, 1.0, ramp);
                // 低频盆地噪声(海沟/海岭)：仅在深水(× ramp)出现，避免扰动大陆架与海岸线判定。
                const int row = i / width;
                const int col = i % width;
                const double ny = double(row) * inv_h;
                const double th = PK_TWO_PI * (double(col) / double(width));
                const double basin = cyl_noise(height_noise.ptr(), simulation_math::cos(th), simulation_math::sin(th), ny, 120.0, -571.0, 311.0, 0.0);
                depth01 += basin * PK_OCEAN_BASIN_AMP * ramp;
                if (depth01 < 0.0) depth01 = 0.0; else if (depth01 > 1.0) depth01 = 1.0;
                double e_new = sea - depth01 * max_depth;
                if (e_new < 0.0) e_new = 0.0; else if (e_new >= sea) e_new = sea - 1e-4;
                E[i] = float(e_new);
            }
        }
    }

    // ── R. [P5-1.1 2026-11-18] 脊信号前置：构造抬升场 ────────────────────────────────
    // 旧 §5 在 SPL **之后**把一份与汇水完全无关的脊噪声直接加到 E 上：脊线横跨河谷、在谷中筑坝，
    // 坝后盆地被 post-base 的 Priority-Flood 识别成湖盆（terrain-ridge-uplift-plan §1.2 问题 1/2）。
    // 新做法把同一份脊信号搬到 SPL **之前**算成抬升场 U 的一部分，让山脊在「抬升 vs 下切」的
    // 准平衡里自己长出来：脊信号强、汇水小的格 U/C 大 → 高出下游 → 成脊；穿过山带的大河 A/C 大
    // → 抬升被下切抵消 → 峡谷（先成河）；无脊信号的地台只剩 u_relief·relief0 的轻微抬升 → 平缓。
    // **输入必须冻结在 SPL 入口的 E0**：先拷一份 e0_frozen 再算，绝不读随后会被 SPL 改写的 E
    // （否则 ridge_add 取决于迭代次数/顺序，破坏「同种子逐位一致」不变量 1）。
    // 公式与常量逐字沿用旧 §5（噪声 180/220×feature_scale、偏移 71.3/-33.7 与 -50.7/91.1、
    // pow(max,1.4)、land_factor^1.5、slope_gate=clamp(slope×8, 0.30, 1.0)、×ridge_boost_amp），
    // 只把输入换成 E0；海洋格 ridge_add = 0。
    // 高度预算口径（契约 §D-2，与 §5 同值，不新造）：§2.4' 末尾预算与 §5' 尾巴共用这两个常量。
    const double land_elev_cap = std::max(0.93, sea_level + (1.0 - sea_level) * 0.94);
    const double soft_max = land_elev_cap - (land_elev_cap - sea_level) * 0.06;
    const double denom_lf = std::max(1.0 - sea_level, 0.001);
    std::vector<float> ridge_add(size_t(n), 0.0f);
    if (ridge_boost_amp > 0.0) {
        std::vector<float> e0_frozen(size_t(n), 0.0f);
        std::copy(E, E + n, e0_frozen.begin());
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(e0_frozen[size_t(idx)]) < sea_level) continue;  // 海洋格 ridge_add=0
                const double ny2 = double(row) * inv_h;
                // [cylindrical-earth-daylight] 山脊噪声圆柱采样 → 山脉跨接缝东西无缝；
                // 经度 period=width（col/width），col=0 与 col=width-1 相邻不重合。
                const double th2 = PK_TWO_PI * (double(col) / double(width));
                const double ct2 = simulation_math::cos(th2);
                const double st2 = simulation_math::sin(th2);
                const double ridge_a = 1.0 - std::fabs(cyl_noise(detail_noise.ptr(), ct2, st2, ny2, 180.0 * feature_scale, 71.3, -33.7, 0.0));
                const double ridge_b = 1.0 - std::fabs(cyl_noise(detail_noise.ptr(), ct2, st2, ny2, 220.0 * feature_scale, -50.7, 91.1, 0.0));
                const double ridge_signal = simulation_math::pow(std::max(ridge_a, ridge_b), 1.4);
                double lowest = double(e0_frozen[size_t(idx)]);
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[idx] + DQ[d], R[idx] + DR[d]);
                    if (ni >= 0 && double(e0_frozen[size_t(ni)]) < lowest) lowest = double(e0_frozen[size_t(ni)]);
                }
                const double slope = double(e0_frozen[size_t(idx)]) - lowest;
                double slope_gate = slope * 8.0;
                if (slope_gate < 0.30) slope_gate = 0.30;
                else if (slope_gate > 1.0) slope_gate = 1.0;
                double land_factor = (double(e0_frozen[size_t(idx)]) - sea_level) / denom_lf;
                land_factor = simulation_math::pow(land_factor, 1.5);
                ridge_add[size_t(idx)] = float(ridge_signal * land_factor * slope_gate * ridge_boost_amp);
            }
        }
    }
    // [P5-0 诊断 2026-11-18] 导出**未乘 §5' 预算缩放 g** 的脊增量场：lead 的 M1（Spearman(ridge_add,
    // log 汇水面积)）与全部标定都读它。纯诊断，不参与计算（ridge_boost_amp=0 时导出全 0）。
    if (ridge_debug_dump) {
        ridge_add_diag.resize(n);
        for (int i = 0; i < n; ++i) ridge_add_diag[i] = ridge_add[size_t(i)];
    }
    // [S7-T1 诊断 2026-11-18] `debug_dump_ridge_e0`：导出 **E0（SPL 入口冻结面）** 与 **在 E0 上算的 ridge_add**。
    // 用途：S7 §3「同口径新旧对比」——两版的 §1 地台/§2.55 洋底一致 ⇒ E0 两版相同，用它当「哪里是脊」的公共参照场，
    // 跨版本比较才成立（上一轮用各自版本的 ridge_add 比较，高脊格集合 Jaccard 只有 0.31–0.43 ⇒ 比不了）。
    // 此刻 E 尚未被 §2.4' 改写，所以直接拷 E 就是 E0。**纯诊断**：只在传该键时分配并返回，不参与任何计算。
    if (ridge_debug_e0_dump) {
        e0_diag.resize(n);
        ridge_e0_diag.resize(n);
        for (int i = 0; i < n; ++i) {
            e0_diag[i] = E[i];
            ridge_e0_diag[i] = ridge_add[size_t(i)];
        }
    }

    // ── 2.4' [P5-1/P5-2/P5-3 2026-11-18] Stream-Power 河流侵蚀：抬升场 + 坡面扩散 + 最陡受体 ──
    // 原 §2.4 SPL 与 §2.5 液滴/热力坍塌合并为本节：液滴与热力坍塌分支已删除（坡面扩散承担软化
    // 陡坡与圆脊的职责，见 §3.3）。置于 normalize + 洋底之后、地形决策之前。
    {
        // ── 2.4 Stream-Power 河流侵蚀 (Cordonnier et al. 2016；隐式、无条件稳定) ──────
        // 学术界标准做法：构造抬升 + 河流(stream-power)侵蚀达准平衡 → 自然产生连贯山脉脊线、
        // 流域、树状河网。每轮：priority-flood 求填洼面 filled 与处理序 proc → 取**最陡受体** rcv
        // → 汇水面积 A 沿 rcv 累积 → 隐式 SPL 下切：
        //     E[i] = (E[i] + U[i] + C·E[rcv]) / (1+C),   C = K·(A/Ā)^m
        // U = spl_uplift_rate·relief0 + spl_ridge_uplift·ridge_add（[P5-1.2] 构造抬升场，每轮施加）。
        // proc 升序(下游先)⇒更新 E[i] 时 E[rcv] 本轮已就绪，且 E[i]≥E[rcv] 恒成立(加权平均)
        // ⇒ 不倒灌、不发散。每轮下切后再做一步坡面扩散（[P5-2.1]，见循环末尾）。
        // 产出：高汇水处下切成树状河谷(长干流+支流、Strahler↑)、低汇水脊线保留(宏观山脉/高原
        // 读得出)、杂散闭流洼地被抬填(减少内陆碎水，并修复运行时"盆地凭空灌满水")。
        // 性能：O(n log n)×iters，15000格几十ms。一键回退：spl_iters=0（回到「无侵蚀」基线）。
        const int spl_iters = std::max(0, geti(profile, "spl_iters", 14));
        const double spl_k = std::max(0.0, getd(profile, "spl_erodibility", 1.2));
        const double spl_m = getd(profile, "spl_area_exp", 0.45);
        const double spl_uplift_rate = std::max(0.0, getd(profile, "spl_uplift_rate", 0.10));
        // [P5-1.2 2026-11-18] 每轮脊抬升系数（契约 §A.1，默认 0.012）：14 轮累计抬升 ≈14×该值×ridge_add，
        // 由计划 §4 标定到与改动前的 p99 陆地高度一致。0 = 完全内生（山脊只由 u_relief 与水系决定）。
        // [P5 标定 2026-11-18] 0.012（计划初值）实测过弱（M1 几乎不动），0.06/0.10 会把 p90 抬到基线 +23%/+24%
    // 并让闭合洼地回升。取 0.03：大图闭合洼地 -36%、小图 -31%，land p50 偏差 -6.4%（大图），M1 ≈ 基线。
    // 必须与 climate_profile.gd::spl_ridge_uplift 同值（漏传时兜底不同值会成隐形陷阱）。
    // 标定扫描与取舍依据见 docs/plans/terrain-ridge-uplift-checklist.md 附 B。
    const double spl_ridge_uplift = std::max(0.0, getd(profile, "spl_ridge_uplift", 0.010));   // [S7-T9] 0.03 -> 0.010
        // [P5-2.1 2026-11-18] 坡面扩散 κ（契约 §A.1，默认 0.08）。显式扩散稳定上界 κ<1，契约范围
        // [0, 0.45] 留足余量；夹取既防 profile 传入失控值把山磨平（K4），也保证确定性。
        const double spl_diffusion = std::clamp(getd(profile, "spl_hillslope_diffusion", 0.08), 0.0, 0.45);
        // [spl-scale 2026-10-12] 准平衡满足 E[i] = E[down] + U/C，逐格成立 → 内陆高度 ≈ 海岸起
        // 格数 × U/C。格数 ∝ sqrt(N)，不缩放时 200x150 内陆整片顶到 land_elev_cap 成纯平高原。
        // 物理一致：每格高差 ∝ 1/s，故 C ×s；汇水面积 A∝s²、均值 Ā∝s，(A/Ā)/s 换回参考格距。
        // N <= spl_ref_cells 时 s=1，与旧行为逐位一致。
        const double spl_ref_cells = std::max(100.0, getd(profile, "spl_ref_cells", 2400.0));
        const double spl_res_scale = std::max(1.0, std::sqrt(double(n) / spl_ref_cells));
        if (spl_iters > 0) {
            std::vector<float> relief0(size_t(n), 0.0f);
            for (int i = 0; i < n; ++i) relief0[size_t(i)] = std::max(0.0f, float(double(E[i]) - sea_level));
            // ── [S7-T6 / G1 2026-11-18] 脊参与初始建网：把脊拆成「初始地形」+「逐轮抬升」两部分 ──
            // 缺陷（同口径复核计划 §10 G1）：ridge_add 此前只以 `U += u·ridge_add` 逐轮进入 SPL，
            // 第 1 轮建树时 E 里还没有脊，水网按 E0 组织；此后每轮抬升量小，14 轮内水网基本继承 E0
            // ⇒ 河流大量「先于脊存在」、横穿脊带。实测印证：M1' 只比零假设高 7 pp；加轮数时 M1' 单调上升。
            // 做法：建树前先叠 f_pre·(iters·u)·ridge_add，让第 1 轮就看到脊；剩余 (1−f_pre) 仍逐轮施加。
            // 这样 f_pre 只改变「脊在第几轮出现」，不改变总脊量 ⇒ f_pre=0 时与改动前逐位一致。
            const double spl_ridge_prestamp = std::clamp(
                    getd(profile, "spl_ridge_prestamp_frac", 0.5), 0.0, 1.0);
            if (spl_ridge_prestamp > 0.0 && ridge_boost_amp > 0.0) {
                const double a_ridge = double(spl_iters) * spl_ridge_uplift;   // iters 轮的脊抬升总量
                const double pre = spl_ridge_prestamp * a_ridge;
                for (int i = 0; i < n; ++i) {
                    const double add = pre * double(ridge_add[size_t(i)]);
                    if (add <= 0.0) continue;                                  // 海洋格 ridge_add=0，自动跳过
                    E[i] = float(std::min(1.0, double(E[i]) + add));
                }
                // 预叠脊会在谷里造出闭合洼地——正是旧版「脊在 SPL 之后叠加」造坝的同一机制，必须在建树前消掉，
                // 否则第 1 轮水网会绕着坝走（G-K1）。规则与 §4 pit fill 相同：Priority-Flood（种子 = 南北边缘 ∪ 水体）
                // 填平后 +1e-3。这一步**只抬高**、且不碰水体，故不破坏「陆地不下海 / 水体不动」。
                {
                    std::vector<uint8_t> pz_seen(size_t(n), 0);
                    std::vector<float> pz(size_t(n), 0.0f);
                    std::priority_queue<std::pair<float, int>, std::vector<std::pair<float, int>>,
                                        std::greater<std::pair<float, int>>> pq2;
                    for (int row = 0; row < height; ++row) {
                        for (int col = 0; col < width; ++col) {
                            const int i = row * width + col;
                            const bool edge = (row == 0 || row == height - 1);
                            const bool water = (double(E[i]) < sea_level);
                            if (!edge && !water) continue;
                            pz_seen[size_t(i)] = 1;
                            pz[size_t(i)] = E[i];
                            pq2.push(std::make_pair(E[i], i));
                        }
                    }
                    while (!pq2.empty()) {
                        const std::pair<float, int> top = pq2.top(); pq2.pop();
                        const int cur = top.second;
                        if (top.first > pz[size_t(cur)] + 1e-6f) continue;
                        for (int d = 0; d < 6; ++d) {
                            const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                            if (ni < 0 || pz_seen[size_t(ni)]) continue;
                            pz_seen[size_t(ni)] = 1;
                            const float sp = std::max(E[ni], pz[size_t(cur)]);
                            pz[size_t(ni)] = sp;
                            pq2.push(std::make_pair(sp, ni));
                        }
                    }
                    for (int i = 0; i < n; ++i) {
                        if (double(E[i]) < sea_level) continue;               // 水体逐位不动
                        if (pz[size_t(i)] > E[i] + 1e-7f) {
                            E[i] = float(std::min(1.0, double(pz[size_t(i)]) + 1e-3));
                        }
                    }
                }
            }
            std::vector<float> filled(size_t(n), 0.0f);
            std::vector<int32_t> down(size_t(n), -1);
            // [P5-3.1 2026-11-18] 最陡受体（取代 Priority-Flood 的「关闭者」down）。down 仍保留：
            // 无严格更低邻点的平地格必须回落到它，否则平地上面积无法下传、河流断流。
            std::vector<int32_t> rcv(size_t(n), -1);
            std::vector<int> proc; proc.reserve(size_t(n));
            std::vector<uint8_t> pf_seen(size_t(n), 0);
            std::vector<double> area(size_t(n), 0.0);
            // [P5-2.1] 坡面扩散双缓冲：读 E 写 e_diff，整步结束后一次拷回（不就地累加）。
            std::vector<float> e_diff;
            if (spl_diffusion > 0.0) e_diff.assign(size_t(n), 0.0f);
            // [P5-2.1/P5-3.1 性能] 6 邻索引表（n×6，= -1 表示缺行边界），只依赖 Q/R/width/height
            // （整段不变）→ 建一次。最陡受体与坡面扩散每轮各要扫一遍 6 邻，若逐次重算
            // index_for_qr，14 轮 × n × 6 × 2 会多出数百万次整数取模，把 +10 ms 预算吃满；
            // 用表后两次扫描各只剩一次顺序读 + 一次 E 读。语义与 index_for_qr 逐位相同。
            std::vector<int32_t> nb6(size_t(n) * 6, -1);
            for (int i = 0; i < n; ++i) {
                const int qi = Q[i], ri = R[i];
                for (int d = 0; d < 6; ++d) {
                    nb6[size_t(i) * 6 + size_t(d)] = index_for_qr(qi + DQ[d], ri + DR[d]);
                }
            }
            for (int it = 0; it < spl_iters; ++it) {
                std::fill(pf_seen.begin(), pf_seen.end(), uint8_t(0));
                for (int i = 0; i < n; ++i) down[size_t(i)] = -1;
                proc.clear();
                std::priority_queue<std::pair<float, int>, std::vector<std::pair<float, int>>,
                                    std::greater<std::pair<float, int>>> pq;
                for (int row = 0; row < height; ++row) {
                    for (int col = 0; col < width; ++col) {
                        // [cylindrical-earth-daylight] 仅南北极(row)作排水基准；东西经度环绕由 index_for_qr 在 flood 扩散时处理。
                        if (row != 0 && row != height - 1) continue;
                        const int i = row * width + col;
                        pf_seen[size_t(i)] = 1; filled[size_t(i)] = E[i];
                        pq.push(std::make_pair(E[i], i));
                    }
                }
                while (!pq.empty()) {
                    const std::pair<float, int> top = pq.top(); pq.pop();
                    const int cur = top.second;
                    if (top.first > filled[size_t(cur)] + 1e-6f) continue;
                    proc.push_back(cur);
                    for (int d = 0; d < 6; ++d) {
                        const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                        if (ni < 0 || pf_seen[size_t(ni)]) continue;
                        pf_seen[size_t(ni)] = 1;
                        const float sp = std::max(E[ni], top.first);
                        filled[size_t(ni)] = sp; down[size_t(ni)] = cur;
                        pq.push(std::make_pair(sp, ni));
                    }
                }
                // ── 最陡受体 [P5-3.1] ────────────────────────────────────────────────
                // rcv[i] = argmax_d( filled[i] − filled[nb_d] )，只取**严格更低**的邻点；平局取 d 小者
                // （下面用严格 > 比较，先到者即 d 小者）；无严格更低邻点 → 沿用 Priority-Flood 的
                // 关闭者 down[i]，即平地 ε 路径。**这一条不能漏**：漏了平地格就无受体，面积下传
                // 断裂、河流在这些格上断流。
                // 拓扑合法性：filled 严格更低的邻点必然更早出栈（PQ 按 filled 单调弹出）⇒ proc 仍是
                // 合法拓扑序，下切循环里 E[rcv] 本轮已就绪；落差严格 > 0 ⇒ 受体链不可能成环。
                for (int i = 0; i < n; ++i) {
                    if (!spl_steepest_receiver) {          // [S7-T1 消融] 复刻旧行为：关闭者当受体
                        rcv[size_t(i)] = down[size_t(i)];
                        continue;
                    }
                    const float fi = filled[size_t(i)];
                    int best = down[size_t(i)];
                    float best_drop = 0.0f;
                    const int32_t *nbp = &nb6[size_t(i) * 6];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = nbp[d];
                        if (ni < 0) continue;
                        const float drop = fi - filled[size_t(ni)];
                        if (drop > best_drop) { best_drop = drop; best = ni; }  // 严格 > ⇒ 平局取 d 小者
                    }
                    rcv[size_t(i)] = best;
                }
                for (int i = 0; i < n; ++i) area[size_t(i)] = 1.0;
                for (int k = int(proc.size()) - 1; k >= 0; --k) {
                    const int i = proc[k]; const int d = rcv[size_t(i)];
                    if (d >= 0) area[size_t(d)] += area[size_t(i)];
                }
                double area_mean = 0.0;
                for (int i = 0; i < n; ++i) area_mean += area[size_t(i)];
                const double inv_area_mean = 1.0 / std::max(1.0, area_mean / double(std::max(1, n)));
                for (int k = 0; k < int(proc.size()); ++k) {
                    const int i = proc[k]; const int d = rcv[size_t(i)];
                    if (d < 0) continue;
                    if (double(E[i]) < sea_level) continue; // 海洋不侵蚀
                    const double C = spl_k * spl_res_scale
                            * simulation_math::pow(area[size_t(i)] * inv_area_mean / spl_res_scale, spl_m);
                    // [P5-1.2] 每轮抬升 = 残余地势回补 + 构造脊抬升场（ridge_add 由 §R 在冻结的 E0 上算得）。
                    // [S7-T6 / G1] 其中脊项只留 (1−f_pre) 的份额：f_pre 的份额已在建树前预叠进 E_init，
                    // 两者相加仍是 u·ridge_add，所以 f_pre 只改变「脊在第几轮出现」、不改变总脊量。
                    const double U = spl_uplift_rate * double(relief0[size_t(i)])
                            + (1.0 - spl_ridge_prestamp) * spl_ridge_uplift * double(ridge_add[size_t(i)]);
                    double z = (double(E[i]) + U + C * double(E[d])) / (1.0 + C);
                    if (z < double(E[d])) z = double(E[d]);
                    E[i] = float(z);
                }
                // ── 坡面扩散 [P5-2.1]：E'_i = E_i + κ·Σ_{6邻}(E_nb − E_i)/6，每轮一次，仅陆地 ──
                // 海洋格自身不动，但按它自己的 E 当固定边界参与邻点求和；行边界外缺失的邻点不计入
                // 求和（仍除 6）→ 只让极行扩散略弱，稳定性不受影响。
                // **双缓冲**：整步只读 E、写 e_diff，循环结束后一次拷回 —— 就地累加会让结果依赖
                // 遍历方向，破坏不变量 1（同种子逐位一致、与线程数无关）。目的：削尖圆脊，让山顶不
                // 再需要膝点硬压缩（后者才是「分水岭平坦高海拔 → 高原候选」的来源）。
                if (spl_diffusion > 0.0) {
                    std::copy(E, E + n, e_diff.begin());
                    for (int i = 0; i < n; ++i) {
                        const double ei = double(E[i]);
                        if (ei < sea_level) continue;  // 海洋固定边界：自身高度不变
                        double sum = 0.0;
                        const int32_t *nbp = &nb6[size_t(i) * 6];
                        for (int d = 0; d < 6; ++d) {
                            const int ni = nbp[d];
                            if (ni >= 0) sum += double(E[ni]);
                        }
                        e_diff[size_t(i)] = float(ei + spl_diffusion * (sum - 6.0 * ei) / 6.0);
                    }
                    std::copy(e_diff.begin(), e_diff.end(), E);
                }
            }
            // ── 高度预算 [P5-1.3 / 契约 §D-2]：取消膝点压缩，改为一次「只压不抬」的线性缩放 ──
            // 旧膝点压缩把 knee 以上的高度整体挤进 [knee, headroom] → 山顶被压成平顶（旧问题 3）。
            // 新做法：只对陆地相对海平面高度 h = E − sea 乘**同一个**系数，使 p99(h) 落到
            // target = sea + (soft_max − sea)·spl_headroom_frac。统一缩放保序（高程序与地貌阈值
            // 含义不变）；p99 > target 时系数恒 < 1，代码里再夹一次 ≤1 ⇒ 从不放大，未超预算的地图
            // 逐位不变。land_elev_cap / soft_max 定义在 §R（契约 §D-2 原式，与 §5' 共用）。
            {
                std::vector<float> land_h;
                land_h.reserve(size_t(n));
                for (int i = 0; i < n; ++i) {
                    const double e = double(E[i]);
                    if (e >= sea_level) land_h.push_back(float(e - sea_level));
                }
                const double headroom_frac = std::clamp(getd(profile, "spl_headroom_frac", 0.97), 0.5, 1.0);
                const double budget_target = sea_level + (soft_max - sea_level) * headroom_frac;
                if (!land_h.empty() && budget_target > sea_level + 1e-4) {
                    const size_t k99 = std::min(land_h.size() - 1, size_t(double(land_h.size()) * 0.99));
                    std::nth_element(land_h.begin(), land_h.begin() + std::ptrdiff_t(k99), land_h.end());
                    const double p99 = double(land_h[k99]);
                    if (p99 > budget_target) {
                        double scale = (budget_target - sea_level) / std::max(p99 - sea_level, 1e-6);
                        if (scale > 1.0) scale = 1.0;  // 只压不抬（p99>target 时上式恒 <1，此处仅作保险）
                        for (int i = 0; i < n; ++i) {
                            const double h = double(E[i]) - sea_level;
                            if (h > 0.0) E[i] = float(sea_level + h * scale);
                        }
                    }
                }
            }
            for (int i = 0; i < n; ++i) {
                double e = double(E[i]);
                E[i] = float(e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e));
            }
        }

        // [P5-2.2 / P5-2.3 2026-11-18] 液滴侵蚀与热力坍塌分支已整体删除：
        // 坡面扩散（§2.4' 每轮一步）承担软化陡坡与圆脊的职责，旧「SPL 之后再来 6000 滴 + 2 轮
        // talus」既与 SPL 抢同一条谷、又就地扫描依赖遍历方向。对应 profile 键
        // erosion_droplet_factor / erosion_max_lifetime / erosion_capacity / erosion_deposit_rate /
        // erosion_erode_rate / erosion_evaporation / erosion_gravity / erosion_min_slope /
        // erosion_thermal_iters / erosion_thermal_talus / erosion_thermal_rate 不再读取
        // （计划 §2.3 明确不保留旧算法，故这里不留若 SPL 关闭就回液滴的分支）。
    }

    // ── 2.6 [P1 hypsometric Layer B 2026-06-25] 高程分段重映射（粗，定结构）──────────────
    // 置于 normalize + 侵蚀(SPL/droplet/thermal)之后、湖判/分类之前：对陆地段(E>sea_level)按
    // land_h 应用单调三段曲线——低地压平(真平原)、中段台地、高段陡升(拉开起伏)。锚定 sea_level：
    // below-sea(海洋/湖种)保持不变，海陆边界与 ocean/coast 分类不被破坏；下游湖判/气候/分类全部
    // 看到重塑后的 E。单调 → 不倒置高程序；置于侵蚀之后 → 保留河谷网络与台地保形。Layer A(bake)
    // 在此基础上做 per-pixel 小 mix 残差精修。曲线与 map_baker.gd / Layer A 同源。
    // [bimodal 2026-06-26] 双峰地台模型已直接产出平坦地台，P1 压平被吸收 → 默认关闭。
    if (!PK_BIMODAL_ENABLED) {
        const PkHypsoCurve hypso = pk_make_hypso_curve();
        const double sea = sea_level;
        const double above = 1.0 - sea;
        const double inv_above = (above > 1e-6) ? (1.0 / above) : 0.0;
        if (inv_above > 0.0) {
            for (int i = 0; i < n; ++i) {
                const double e = double(E[i]);
                if (e <= sea) continue;  // 水下不动（锚定 sea_level）
                E[i] = float(pk_hypso_remap_elev(hypso, e, sea, inv_above, above, 1.0));
            }
        }
    }
