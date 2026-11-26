// ─────────────────────────────────────────────────────────────────────────
// 侵蚀模式接线（terrain-erosion-spl，2026-11-18）
// 规格：docs/plans/terrain-erosion-spl-contracts.md §3（模式语义已裁决，见 §3.1 与本文件下文）
//       docs/plans/terrain-erosion-spl-plan.md §4.1（总体流程）/§4.7（Web 计算栅格）/§4.11（输出契约）
//
// 模式语义（**已裁决**，contracts §3.1 + checklist §A1）：
//   carve     = 现状全序：汇流刻谷 + droplet 液滴。height_buffer 必须与改动前**逐位相同**
//               （P0 的 hash 门禁靠它守住一键回退），因此 droplet 在 carve 下照旧执行。
//   spl       = 只跑 SPL 管线（建树 → 隐式下切 → [沉积/谷底展宽] → 限坡），不跑 carve、不跑 droplet。
//   spl+carve = SPL 管线 + 浅刻谷（carve 深度 × dem_spl_carve_scale），不跑 droplet。
//   droplet   = 仅 droplet（历史对照，供 A/B 复现旧视觉）。
// C++ 缺省恒 "carve"：Project/perf-validation 加载同一 DLL 但不传该 knob → 行为逐位不变（计划 §12 Q5）。
//
// 单位约定：除 dem_erosion_max_dim（像素）与各 ms 外，全部长度/面积参数以 hex 为单位（计划 §4.2），
//   迭代次数只按分辨率分档，禁止按耗时自适应（计划 §3.2-6 确定性）。
// 不变量（计划 §3.2）：h ≤ h_pre、陆地 ≥ sea_level + 5e-4、水体/河心像素逐位不变、deposited ≤ eroded。
//   [S7-T7 2026-11-18] G2 注入开启（dem_spl_inject_cell_area=true，**非缺省**）时第三条收窄为
//   「**真水体**逐位不变」：河心像素从汇流出口改为「带外部汇水的普通陆地像素」，因此会被
//   SPL 下切 / 限坡改动（这正是 G2 的目的）；关闭该 knob 时一切回到改动前（含河心并入 wet）。
// ─────────────────────────────────────────────────────────────────────────

namespace {

// 侵蚀 knobs 解析结果（融合 pass 与 run_bake_erosion_spl_pass 共用一份实现，不复制参数表）。
struct ErosionKnobs {
    String mode = String("carve");   // C++ 缺省恒 carve（计划 §4.8 / §12 Q5）
    pk_erosion::SplParams sp;        // dem_spl_*
    pk_erosion::DepParams dep;       // dem_dep_* / dem_floor_*
    pk_erosion::LimParams lim;       // dem_slope_limit_* / dem_crest_round
    int max_dim = 1024;              // 计算栅格长边上限（像素）；<=0 → 不下采样
    double carve_scale = 0.40;       // 仅 spl+carve：浅刻谷深度系数
    bool pit_audit = false;          // 诊断：额外算 pits_out（默认关，不改变高度）
    bool area_dump = false;          // 诊断：额外导出像素层 A_hex（默认关，不改变高度）
    // ── [S7-T7 2026-11-18] G2/G3（计划 §10.4 / §10.5）────────────────────────────
    // dem_spl_inject_cell_area（bool，**缺省 false**，见 T7 验收结论）：开启后 cell 层河流汇水注入像素 SPL，
    //   河心像素不再是汇流出口。**false ⇒ 与改动前逐位一致**（注入代码路径整体不进入）。
    // dem_river_incise_base / dem_river_incise_flow（缺省 0.020 / 0.035）：河道 SDF 下切
    //   incise = base + flow · river_flow(cell)（river_flow=1 时 = 改动前的常量 0.045）。
    bool spl_inject_cell_area = true;
    double river_incise_base = 0.020;
    double river_incise_flow = 0.035;
};

// ── 侵蚀 knobs 解析：缺省值 = 计划 §4.10 的「C++ 缺省」列，与 DEM_DEFAULTS 原值一致 ──
ErosionKnobs pk_parse_erosion_knobs(const Dictionary &knobs) {
    ErosionKnobs ek;
    ek.mode = String(knobs.get("dem_erosion_mode", String("carve")));   // 缺省恒 carve
    ek.max_dim = int(knobs.get("dem_erosion_max_dim", 1024));
    // SPL 下切（计划 §4.4）
    ek.sp.iters = int(knobs.get("dem_spl_iters", 6));
    // [P2 标定 2026-11-18] dem_spl_k 缺省 = 0.50，必须与 GDScript DEM_DEFAULTS 同值：
    // 生产恒由 dem_landform_knobs() 显式传入，这里只是「谁漏传」时的兜底，两处不同值会变成隐形陷阱。
    // 标定依据见 terrain_index_baker.gd::DEM_DEFAULTS 与 docs/plans/terrain-erosion-spl-checklist.md §A4。
    ek.sp.k_total = double(knobs.get("dem_spl_k", 0.50));
    ek.sp.m = double(knobs.get("dem_spl_m", 0.45));
    ek.sp.min_area_hex = double(knobs.get("dem_spl_min_area_hex", 0.03));
    // 限坡（计划 §4.5；默认与 carve 的谷壁坡度对齐，锐度≈现状）
    ek.lim.per_relief = double(knobs.get("dem_slope_limit_per_relief", 5.0));
    ek.lim.relief_floor = double(knobs.get("dem_slope_limit_relief_floor", 0.04));
    ek.lim.cap_per_relief = double(knobs.get("dem_slope_limit_cap_per_relief", 1.4));
    ek.lim.crest_round = double(knobs.get("dem_crest_round", 0.0));
    // 输运沉积（P3a）+ 谷底展宽（P3b），计划 §4.6，默认关
    ek.dep.enabled = bool(knobs.get("dem_dep_enabled", false));
    ek.dep.kc = double(knobs.get("dem_dep_kc", 0.02));
    ek.dep.rate = double(knobs.get("dem_dep_rate", 0.5));
    ek.dep.min_area_hex = double(knobs.get("dem_dep_min_area_hex", 0.5));
    ek.dep.floor_widen = bool(knobs.get("dem_floor_widen", false));
    ek.dep.floor_width_hex = double(knobs.get("dem_floor_width_hex", 0.04));
    ek.dep.floor_slope = double(knobs.get("dem_floor_slope", 0.002));
    ek.dep.floor_min_area_hex = double(knobs.get("dem_floor_min_area_hex", 2.0));
    // 仅 spl+carve
    ek.carve_scale = double(knobs.get("dem_spl_carve_scale", 0.40));
    // 测试/诊断：让合并管线额外算 pits_out
    ek.pit_audit = bool(knobs.get("dem_erosion_pit_audit", false));
    // [S2/S4.4 诊断 2026-11-18] 导出像素层汇水面积 A_hex（单位 hex²），供
    //   X2「河心是否走在像素汇流主干上」与 §5.4「dem_spl_k 为什么需要 17 倍」的量级核算。
    //   纯诊断：只在传此键时分配并返回，不参与任何计算、不改变高度输出。
    ek.area_dump = bool(knobs.get("dem_erosion_area_dump", false));
    // [S7-T7 2026-11-18] G2/G3 knob（计划 §10.4/§10.5，缺省值与 §10 的文字规格一致）：
    //   dem_spl_inject_cell_area 缺省 false；不开启时注入代码路径整体不进入（逐位回退到改动前）。
    //   dem_river_incise_base/flow 只在注入生效时才被使用（见融合 pass 的 G3 分支）。
    // [S7-T7 2026-11-18] **默认关**：机制已实现并验证「关闭时逐位一致」，但验收未通过——
    // 开启后 A12 的相对门禁 �� FAIL（X1(spl) 0.767→0.746、0.781→0.764，Δ −0.014 < −0.01）。
    // 按计划 §2.3 应先走 E1–E3 排查再决定是否设为 true；在未验收前不改变默认行为。
    ek.spl_inject_cell_area = bool(knobs.get("dem_spl_inject_cell_area", false));
    ek.river_incise_base = double(knobs.get("dem_river_incise_base", 0.020));
    ek.river_incise_flow = double(knobs.get("dem_river_incise_flow", 0.035));
    return ek;
}

// SPL 管线报告（contracts §3.2）。ms 全部 -1 = 该步未执行；factor/w_lo/h_lo 描述**实际**计算栅格。
struct SplPipelineReport {
    bool ok = false;
    const char *reason = "";
    int factor = 1;
    int w_lo = 0;
    int h_lo = 0;
    double flow_ms = -1.0;      // 建树（填洼 + 最陡受体 + 汇水面积）+ 系数预计算
    double spl_ms = -1.0;       // SPL 隐式下切
    double dep_ms = -1.0;       // 输运沉积（含谷底展宽）；未开 = -1
    double limit_ms = -1.0;     // 限坡倒角扫描
    double carve_ms = -1.0;     // 由调用方回填（spl+carve 的浅刻谷）
    double upsample_ms = -1.0;  // 缩放/搬运段：紧凑化 + 下采样 + delta 取非负 + 双线性放大 + 写回基线
                                // （**不含**任何核函数耗时）；factor==1 且无别名列 = -1
    pk_erosion::Stats stats{};
};

// ── 一份实现两处调用：融合 pass（run_bake_geometry_fields_pass 的 spl* 分支）与
//    run_bake_erosion_spl_pass 都走这里，算法/顺序/不变量只有一处。
//
// H：入口高度（就地改写成最终高度）；relief/wet：同尺寸基线栅格（w×h）。
// wrap_cols：0 = 不环绕；>2 且 < w 时前 wrap_cols 列是一个经线周期、其后列是 x-wrap_cols 的别名
//   （与 pk_dem::carve_drainage_valleys 同一约定：只读前 wrap_cols 列，写回时别名列按 delta 复制）。
// hex_px_hi：基线栅格上「一个 hex 跨度」的像素数；max_dim<=0 → 不下采样。
// pit_audit / fill_out 是契约 §3.2 签名之外的**可选尾参**（都有缺省值，不影响契约调用形态）：
//   pit_audit = dem_erosion_pit_audit（contracts §4.1）要求合并管线能算 pits_out；
//   fill_out  = 融合 pass 的 spl+carve 复用同一份填洼（checklist §A2），factor>1 跨网格不复用。
// [S7-T7 2026-11-18] G2 注入四参（计划 §10.4；缺省 = 不注入，行为与改动前逐位一致）：
//   inject_hi / cell_id_hi 是**基线（hi）栅格**逐像素数组（与 H/relief/wet 同尺寸 w×h），
//   cell_downstream 是 by cell.index 的声明下游（长度 n_cells，-1 = 无）。
//   四个都传齐才在计算栅格上装配 Grid.inject_area / Grid.cell_id（下采样见步骤 3b），
//   否则 Grid 三个新指针保持 nullptr，build_flow 整段走旧实现。诊断入口
//   run_bake_erosion_spl_pass 没有 cell 拓扑，恒传 nullptr（退化为旧语义）。
// 返回时全部中间 buffer 已在函数内释放（契约 §4.12：峰值 ~20 MB @620k px，进入 tile 烘焙前归零）。
static SplPipelineReport pk_run_erosion_spl_pipeline(
        float *H, const float *relief, const uint8_t *wet, int w, int h, int wrap_cols,
        double hex_px_hi, double sea_level, int max_dim,
        const pk_erosion::SplParams &sp, const pk_erosion::DepParams &dp,
        const pk_erosion::LimParams &lp,
        const float *inject_hi = nullptr, const int32_t *cell_id_hi = nullptr,
        const int32_t *cell_downstream = nullptr, int32_t n_cells = 0,
        bool pit_audit = false, pk_dem::FillResult *fill_out = nullptr,
        PackedFloat32Array *area_out = nullptr) {
    SplPipelineReport rep;
    if (H == nullptr || relief == nullptr || wet == nullptr || w <= 2 || h <= 2) {
        rep.reason = "invalid grid";
        return rep;
    }
    if (fill_out != nullptr) {
        fill_out->z.clear();
        fill_out->order.clear();
        fill_out->pits = 0;
    }

    // 经线周期：与 carve 同一约定（前 hi_w 列是周期本体，[hi_w, w) 是别名列）。
    const bool periodic = (wrap_cols > 2 && wrap_cols <= w);
    const int hi_w = periodic ? wrap_cols : w;
    const bool alias_cols = (hi_w < w);

    // 1. 计算栅格因子：长边超过 max_dim 时按整数因子盒式下采样（计划 §4.7）。
    //    长边取**周期列数 hi_w**（而不是含别名列的光栅宽 w）：别名列是周期本体的重复数据，
    //    不参与计算，把它们算进长边会让 Web high 多做一次没必要的 2× 下采样。
    int factor = 1;
    if (max_dim > 0) {
        const int long_dim = std::max(hi_w, h);
        if (long_dim > max_dim) factor = (long_dim + max_dim - 1) / max_dim;
    }
    // 下采样后不足 3 列/行就建不出流向树：退回不下采样（宁可多花内存，也不要退化栅格）。
    while (factor > 1 && (hi_w / factor <= 2 || h / factor <= 2)) --factor;
    const int gw = hi_w / factor;
    const int gh = h / factor;
    // 注：periodic 且 hi_w 不能被 factor 整除时，周期尾部剩下的 r = hi_w - gw*factor 列在 lo 栅格上
    // 没有独立列表示（downsample 只覆盖 floor 列）；放大时它们按 u 取模落到周期头部，即接缝处
    // 至多 f-1 列继承左侧列的 delta。只影响 Web high（factor>1）这一档，且包体本身是周期重复列，
    // 视觉上不可见；真要严格，就把 wrap_cols 选成 factor 的整数倍。
    rep.factor = factor;
    rep.w_lo = gw;
    rep.h_lo = gh;
    const size_t n_lo = size_t(gw) * size_t(gh);

    // 2. 入口面：有别名列时先紧凑成 hi_w×h（只取周期本体，与 carve 的 z/rel/wet 装配同一约定）。
    //    [计时] upsample_ms 第 1 段 = 紧凑化(wrap 别名列搬运) + 盒式下采样 + 建 Grid + 拷 h_pre。
    //    核函数（build_flow/precompute_coeff/spl_incise/deposit/slope_limit）**绝不**计入这个键：
    //    计划 §4.11 把它定义为「计算栅格下采样 + delta 取非负 + 双线性放大 + 写回基线」这一段的分项耗时。
    const auto t_scale0 = std::chrono::high_resolution_clock::now();
    std::vector<float> h_cmp, rel_cmp;
    std::vector<uint8_t> wet_cmp;
    float *h_hi = H;
    const float *rel_hi = relief;
    const uint8_t *wet_hi = wet;
    if (alias_cols) {
        h_cmp.resize(size_t(hi_w) * size_t(h));
        rel_cmp.resize(size_t(hi_w) * size_t(h));
        wet_cmp.resize(size_t(hi_w) * size_t(h));
        for (int y = 0; y < h; ++y) {
            const size_t s = size_t(y) * size_t(w);
            const size_t d = size_t(y) * size_t(hi_w);
            for (int x = 0; x < hi_w; ++x) {
                h_cmp[d + size_t(x)] = H[s + size_t(x)];
                rel_cmp[d + size_t(x)] = relief[s + size_t(x)];
                wet_cmp[d + size_t(x)] = wet[s + size_t(x)];
            }
        }
        h_hi = h_cmp.data();
        rel_hi = rel_cmp.data();
        wet_hi = wet_cmp.data();
    }

    // 3. 工作面（计算栅格）：factor==1 时直接复用入口面（就地改写，零拷贝），否则盒式下采样。
    std::vector<float> h_lo, rel_lo;
    std::vector<uint8_t> wet_lo;
    if (factor > 1) {
        h_lo.resize(n_lo);
        rel_lo.resize(n_lo);
        wet_lo.resize(n_lo);
        pk_erosion::downsample_box_f32(h_hi, hi_w, h, factor, h_lo.data());
        pk_erosion::downsample_box_f32(rel_hi, hi_w, h, factor, rel_lo.data());
        pk_erosion::downsample_box_u8(wet_hi, hi_w, h, factor, wet_lo.data());
    }

    pk_erosion::Grid g;
    g.w = gw;
    g.h = gh;
    g.wrap_cols = periodic ? gw : 0;   // 计算栅格整幅即一个经线周期
    g.sea_level = sea_level;
    g.sea_eps = 5e-4;                  // 与 carve 的下海截断同值（bake_dem_landform.h 写回段）
    g.hex_px = (hex_px_hi > 1e-9 ? hex_px_hi : 1.0) / double(factor);
    g.H = (factor > 1) ? h_lo.data() : h_hi;
    g.relief = (factor > 1) ? rel_lo.data() : rel_hi;
    g.wet = (factor > 1) ? wet_lo.data() : wet_hi;

    // 入口快照：H_pre 全程只读（下切下限 / delta / 沉积上限）。factor==1 时就地改写 H，故先拷一份。
    std::vector<float> h_pre(n_lo);
    std::memcpy(h_pre.data(), g.H, n_lo * sizeof(float));
    g.H_pre = h_pre.data();

    // 3b. [S7-T7 2026-11-18] G2 注入场：基线(hi)栅格 → 计算栅格。与 h/relief/wet 同一套「先紧凑化
    //     （wrap 别名列）、再盒式下采样」。三条指针齐备才装配 Grid 的注入字段；否则三个新指针一律保持
    //     nullptr，build_flow 的两处注入分支整体不进入 ⇒ dem_spl_inject_cell_area=false 时逐位一致。
    const bool inject_on = (inject_hi != nullptr && cell_id_hi != nullptr
            && cell_downstream != nullptr && n_cells > 0);
    std::vector<float> inject_lo;
    std::vector<int32_t> cell_lo;
    if (inject_on) {
        const float *inject_cmp = inject_hi;
        const int32_t *cell_cmp = cell_id_hi;
        std::vector<float> inject_cmp_buf;
        std::vector<int32_t> cell_cmp_buf;
        if (alias_cols) {
            inject_cmp_buf.resize(size_t(hi_w) * size_t(h));
            cell_cmp_buf.resize(size_t(hi_w) * size_t(h));
            for (int y = 0; y < h; ++y) {
                const size_t s = size_t(y) * size_t(w);
                const size_t d = size_t(y) * size_t(hi_w);
                for (int x = 0; x < hi_w; ++x) {
                    inject_cmp_buf[d + size_t(x)] = inject_hi[s + size_t(x)];
                    cell_cmp_buf[d + size_t(x)] = cell_id_hi[s + size_t(x)];
                }
            }
            inject_cmp = inject_cmp_buf.data();
            cell_cmp = cell_cmp_buf.data();
        }
        inject_lo.resize(n_lo);
        pk_erosion::downsample_box_f32(inject_cmp, hi_w, h, factor, inject_lo.data());
        if (factor > 1) {
            // 面积是广延量：downsample_box_f32 给的是块内**均值**，乘 f² 还原成块内**和**
            // （一个 lo 像素覆盖 f² 个 hi 像素，两者的 base area 也正好差 f²，量纲自洽）。
            const float area_scale = float(double(factor) * double(factor));
            for (size_t i = 0; i < n_lo; ++i) inject_lo[i] *= area_scale;
        }
        // 所属格：取块中心像素的 p2c（只是受体偏好的标签；块心必落在同一格内，确定性）。
        cell_lo.resize(n_lo);
        const int half = factor / 2;
        for (int ly = 0; ly < gh; ++ly) {
            const int sy = std::min(h - 1, ly * factor + half);
            const size_t srow = size_t(sy) * size_t(hi_w);
            const size_t drow = size_t(ly) * size_t(gw);
            for (int lx = 0; lx < gw; ++lx) {
                const int sx = std::min(hi_w - 1, lx * factor + half);
                cell_lo[drow + size_t(lx)] = cell_cmp[srow + size_t(sx)];
            }
        }
        g.inject_area = inject_lo.data();
        g.cell_id = cell_lo.data();
        g.cell_downstream = cell_downstream;
        g.n_cells = n_cells;
    }

    // [计时] upsample_ms 第 1 段收尾（紧凑化 / 下采样 / 建 Grid / 拷 h_pre）。factor==1 且无别名列时
    //    这一段没做任何缩放搬运，upsample_ms 保持 -1（契约：未执行项 = -1）。
    //    第 2 段（delta + 放大 + 写回）在步骤 8 单独计时，两段之和才是 upsample_ms，
    //    保证核函数耗时不会再混进这个键（此前 185.6ms 的误报就是混算所致）。
    const bool scaled = (factor > 1 || alias_cols);
    const double scale_ms = scaled
            ? std::chrono::duration<double, std::milli>(
                    std::chrono::high_resolution_clock::now() - t_scale0).count()
            : 0.0;

    // 4. 建树 + 系数（pow 每像素只算一次），随后按 order 串行下切（确定性：无并行、无 RNG）。
    pk_erosion::Flow flow;
    pk_erosion::Stats st{};
    const auto t_flow0 = std::chrono::high_resolution_clock::now();
    // build_flow 的第三参（可选）：填洼时顺带把入口闭合洼地数写进 st.pits_in，零额外扫描。
    pk_erosion::build_flow(g, flow, &st);
    std::vector<float> coeff;
    pk_erosion::precompute_coeff(g, flow, sp, coeff);
    if (area_out != nullptr) {
        // [S2/S4.4 诊断] 把计算栅格的 area_hex 映射回基线栅格（最近邻；别名列回绕到周期本体）。
        // factor==1 时等价于直拷（lo 栅格就是 hi_w×h），factor>1 时按整数因子取上游格。
        // 语义：汇水面积，单位 hex²（单像素初值 1/hex_px²）。纯诊断，不影响下切。
        const int hw = hi_w;
        area_out->resize(w * h);
        float * const AO = area_out->ptrw();
        for (int y = 0; y < h; ++y) {
            const int ly = std::min(gh - 1, y / factor);
            const size_t lrow = size_t(ly) * size_t(gw);
            const size_t hrow = size_t(y) * size_t(w);
            for (int x = 0; x < w; ++x) {
                const int lx = std::min(gw - 1, (x % hw) / factor);
                AO[hrow + size_t(x)] = flow.area_hex[lrow + size_t(lx)];
            }
        }
    }
    rep.flow_ms = std::chrono::duration<double, std::milli>(
            std::chrono::high_resolution_clock::now() - t_flow0).count();

    const auto t_spl0 = std::chrono::high_resolution_clock::now();
    pk_erosion::spl_incise(g, flow, coeff, sp, st);
    rep.spl_ms = std::chrono::duration<double, std::milli>(
            std::chrono::high_resolution_clock::now() - t_spl0).count();

    // 5. 输运沉积（P3a）+ 谷底展宽（P3b）：同一棵流向树，只把 SPL 削掉的部分填回，上限 h_pre。
    //    顺序固定 deposit → floor_widen → slope_limit（floor_widen 拿 deposit 之后的 H 当槽底，
    //    限坡再削出谷壁）；两个开关彼此独立（dp.enabled=false + dp.floor_widen=true 合法）。
    if (dp.enabled || dp.floor_widen) {
        const auto t_dep0 = std::chrono::high_resolution_clock::now();
        if (dp.enabled) pk_erosion::deposit(g, flow, dp, sp, st);
        if (dp.floor_widen) pk_erosion::floor_widen(g, flow, dp, st);
        rep.dep_ms = std::chrono::duration<double, std::milli>(
                std::chrono::high_resolution_clock::now() - t_dep0).count();
    }

    // 6. 限坡（必须在下切/沉积/展宽之后：它决定谷宽与截面形状，计划 §4.5；
    //    dem_crest_round 由 slope_limit 内部在限坡前处理，不在这里重复调用）。
    const auto t_lim0 = std::chrono::high_resolution_clock::now();
    pk_erosion::slope_limit(g, lp, st);
    rep.limit_ms = std::chrono::duration<double, std::milli>(
            std::chrono::high_resolution_clock::now() - t_lim0).count();

    // pits_out：填洼复核（诊断）。只在开了沉积或显式 audit 时算，否则保持 -1（契约 §3.2-5）。
    if (dp.enabled || pit_audit) {
        st.pits_out = pk_erosion::count_pits(g);
    }

    // 7. spl+carve 的填洼复用（checklist §A2）：只有 factor==1 时计算栅格与 carve 栅格同几何。
    if (fill_out != nullptr && factor == 1 && flow.z_fill.size() == n_lo) {
        fill_out->z.resize(n_lo);
        for (size_t i = 0; i < n_lo; ++i) fill_out->z[i] = double(flow.z_fill[i]);
        fill_out->order = flow.order;
        fill_out->pits = (st.pits_in >= 0) ? st.pits_in : 0;
    }

    // 8. 写回基线栅格：delta = max(0, h_pre - h) 搬回去 —— 只降、水体不动、陆地不下海。
    //    factor==1 且无别名列时 SPL 已就地改写 H，这一步跳过（upsample_ms 保持 -1）。
    //    [计时] upsample_ms 第 2 段 = delta 取非负 + 双线性放大 + 逐像素写回（只含这一段，不含核函数）。
    const auto t_wb0 = std::chrono::high_resolution_clock::now();
    if (factor > 1) {
        std::vector<float> delta_lo(n_lo);
        for (size_t i = 0; i < n_lo; ++i) {
            const float d = g.H_pre[i] - g.H[i];
            delta_lo[i] = (d > 0.0f) ? d : 0.0f;
        }
        // 双线性放大（wrap 感知）：hi 宽 = w，别名列由 upsample 的 u 取模自然复制。
        std::vector<float> delta_hi(size_t(w) * size_t(h));
        pk_erosion::upsample_box_f32(delta_lo.data(), gw, gh, factor, delta_hi.data(), w, h);
        if (!periodic) {
            // 无经线环绕时，放大语义要求 u 取模 wrap；但地图左右边缘应夹紧而不是跨图插值，
            // 否则首末列会出现一条假接缝。这里按同一双线性公式只修越界的边缘列。
            for (int y = 0; y < h; ++y) {
                const size_t drow = size_t(y) * size_t(w);
                const size_t srow = size_t(y) * size_t(gw);
                for (int x = 0; x < w; ++x) {
                    const double u = (double(x) + 0.5) / double(factor) - 0.5;
                    if (u >= 0.0 && u <= double(gw - 1)) continue;
                    const double uc = (u < 0.0) ? 0.0 : double(gw - 1);
                    const int i0 = int(std::floor(uc));
                    const int i1 = std::min(gw - 1, i0 + 1);
                    const double t = uc - double(i0);
                    delta_hi[drow + size_t(x)] = float(
                            (1.0 - t) * double(delta_lo[srow + size_t(i0)])
                            + t * double(delta_lo[srow + size_t(i1)]));
                }
            }
        }
        const double sea_floor = sea_level + 5e-4;
        for (int y = 0; y < h; ++y) {
            const size_t row = size_t(y) * size_t(w);
            for (int x = 0; x < w; ++x) {
                const size_t i = row + size_t(x);
                if (wet[i]) continue;                       // 水体 / 河心像素：逐位不变
                const double h0 = double(H[i]);             // 入口高度（H 此刻尚未被改写）
                double hn = h0 - double(delta_hi[i]);
                if (h0 > sea_level && hn < sea_floor) hn = sea_floor;
                if (hn > h0) hn = h0;                       // 只降
                H[i] = float(hn);
            }
        }
    } else if (alias_cols) {
        const double sea_floor = sea_level + 5e-4;
        for (int y = 0; y < h; ++y) {
            const size_t srow = size_t(y) * size_t(w);
            const size_t drow = size_t(y) * size_t(hi_w);
            for (int x = 0; x < w; ++x) {
                const size_t i = srow + size_t(x);
                if (wet[i]) continue;
                const size_t j = drow + size_t(x % hi_w);   // 别名列取周期本体的 delta
                const float d0 = g.H_pre[j] - g.H[j];
                const double h0 = double(H[i]);
                double hn = h0 - double(d0 > 0.0f ? d0 : 0.0f);
                if (h0 > sea_level && hn < sea_floor) hn = sea_floor;
                if (hn > h0) hn = h0;
                H[i] = float(hn);
            }
        }
    }
    if (scaled) {
        // upsample_ms = 第 1 段（紧凑化/下采样/建 Grid/拷 h_pre）+ 第 2 段（delta/放大/写回）。
        // 两段之间隔着全部核函数，故不再相减整段——否则会把 flow/spl/limit 误算进来（task-8）。
        rep.upsample_ms = scale_ms + std::chrono::duration<double, std::milli>(
                std::chrono::high_resolution_clock::now() - t_wb0).count();
    }

    rep.stats = st;
    rep.ok = true;
    rep.reason = "";
    return rep;
}

} // namespace

// run_bake_erosion_spl_pass — SPL 汇流侵蚀管线的 buffer-encoder 入口（测试 / A-B probe 用）。
// 生产路径走融合 pass（run_bake_geometry_fields_pass）的 spl / spl+carve 分支，两者共用同一份
// pk_run_erosion_spl_pipeline（不复制算法）。范式同 run_bake_erosion_pass：坐标/尺寸在循环外解析、
// 裸指针、fallback 初始 true 成功才置 false、失败**不** push_error（测试与融合 pass 都靠它判据）。
// 入参 knobs：width/height；height_buffer(F32，入口高度)/relief_buffer(F32，局地起伏)/
//   wet_buffer(U8，1 = 水体或河心像素 → 汇流出口)；sea_level；hex_px（缺省由 size_x + hex_size 推）；
//   wrap_cols（0 = 不环绕，>2 时前 wrap_cols 列为经线周期）+ 全部 dem_* knob。
//   dem_erosion_mode 只按 spl / spl+carve 解释（carve / droplet 由融合 pass 负责）。
// 出参：fallback/path/height_out(F32)/width/height/erosion_mode/erosion_grid_w/h/factor +
//   flow_ms/spl_ms/dep_ms/limit_ms/carve_ms/upsample_ms/fill_ms/mfd_ms/wall_ms +
//   spl_iters_effective/spl_p99_drop/spl_max_drop/eroded_vol/deposited_vol/
//   spl_sea_clamped/spl_nan/pits_in/pits_out + elapsed_ms/reason（契约 §3.3/§3.4，未执行项 -1）。
godot::Dictionary DCWorldExt::run_bake_erosion_spl_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;
    // 契约 §3.4：report keys 只增不改。先把全部分项/统计键按「未执行 = -1」填好，成功再逐项覆盖，
    // 失败分支因此也回一套完整键（测试可直接断言「某项未执行」）。
    out["erosion_mode"] = String("spl");
    out["erosion_grid_w"] = -1;
    out["erosion_grid_h"] = -1;
    out["erosion_grid_factor"] = -1;
    out["flow_ms"] = -1.0;
    out["spl_ms"] = -1.0;
    out["dep_ms"] = -1.0;
    out["limit_ms"] = -1.0;
    out["carve_ms"] = -1.0;
    out["upsample_ms"] = -1.0;
    out["fill_ms"] = -1.0;
    out["mfd_ms"] = -1.0;
    out["wall_ms"] = -1.0;
    out["spl_iters_effective"] = -1;
    out["spl_p99_drop"] = -1.0;
    out["spl_max_drop"] = -1.0;
    out["eroded_vol"] = -1.0;
    out["deposited_vol"] = -1.0;
    out["spl_sea_clamped"] = -1;
    out["spl_nan"] = -1;
    out["pits_in"] = -1;
    out["pits_out"] = -1;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 2 || h <= 2 || n <= 0) return fail("invalid size");
    out["width"] = w;
    out["height"] = h;

    PackedFloat32Array src = knobs.get("height_buffer", PackedFloat32Array());
    if (src.size() < n) return fail("height buffer too small");
    PackedFloat32Array relief = knobs.get("relief_buffer", PackedFloat32Array());
    if (relief.size() < n) return fail("relief buffer too small");
    PackedByteArray wet = knobs.get("wet_buffer", PackedByteArray());
    if (wet.size() < n) return fail("wet buffer too small");

    // 侵蚀 knobs（与融合 pass 共用同一份解析实现）
    const ErosionKnobs ek = pk_parse_erosion_knobs(knobs);
    // 本 pass 只解释 SPL 两档模式（carve / droplet 交给融合 pass）：缺省按 spl，spl+carve 保留。
    // 注：godot::String 只重载了 operator==(const char*)，这里一律用 == 判断。
    String mode = String("spl");
    if (ek.mode == "spl+carve") mode = String("spl+carve");
    out["erosion_mode"] = mode;

    const double sea_level = double(knobs.get("sea_level", 0.64));
    const int wrap_cols = int(knobs.get("wrap_cols", 0));
    double hex_px = double(knobs.get("hex_px", 0.0));
    if (hex_px <= 1e-9) {
        // 缺省由世界尺寸反推：与 carve / 融合 pass 的 dp.hex_px 同一算式（hex_size·√3 / 像素步长）。
        const double size_x = double(knobs.get("size_x", 0.0));
        const double step_x = (size_x > 1e-9) ? size_x / double(w) : 0.0;
        const double hex_size = double(knobs.get("hex_size", 1.0));
        hex_px = (step_x > 1e-9) ? hex_size * 1.7320508075688772 / step_x : 1.0;
    }

    PackedFloat32Array height_out = src;
    height_out.resize(n);
    auto t0 = std::chrono::high_resolution_clock::now();

    pk_dem::CarveStats carve_stats;   // spl+carve 时回填（未跑时全 -1）
    PackedFloat32Array area_diag;     // [S2/S4.4 诊断] 仅 dem_erosion_area_dump=1 时填充
    // [S7-T7 2026-11-18] G2 注入四参恒传 nullptr/0：本诊断 pass 的输入只有「已合成的 wet_buffer」，
    //   没有 cell 拓扑（p2c / _gen_river_downstream），无法做 cell 级汇水注入 ⇒ 显式退化为旧语义
    //   （plan §10.4 的「数组缺失 → 退化」）。生产路径的注入只在融合 pass 里生效。
    SplPipelineReport rep = pk_run_erosion_spl_pipeline(
            height_out.ptrw(), relief.ptr(), wet.ptr(), w, h, wrap_cols,
            hex_px, sea_level, ek.max_dim, ek.sp, ek.dep, ek.lim,
            nullptr, nullptr, nullptr, 0,
            ek.pit_audit, nullptr,
            ek.area_dump ? &area_diag : nullptr);

    // spl+carve：叠浅刻谷（深度 × dem_spl_carve_scale）。诊断 pass 不复用填洼（factor>1 也无法复用；
    // 复用路径在融合 pass 里通过 fill_out 拿到）。
    if (rep.ok && mode == "spl+carve") {
        const double carve_depth = double(knobs.get("dem_valley_depth_per_relief", 1.4)) * ek.carve_scale;
        if (carve_depth > 0.0) {
            pk_dem::DrainageParams cdp;
            cdp.width = w;
            cdp.height = h;
            cdp.wrap_cols = wrap_cols;
            cdp.sea_level = sea_level;
            cdp.hex_px = hex_px;
            cdp.depth_per_relief = carve_depth;
            cdp.wall_per_relief = double(knobs.get("dem_valley_wall_per_relief", 5.0));
            cdp.area_lo_px = double(knobs.get("dem_valley_area_lo", 8.0));
            cdp.area_hi_px = double(knobs.get("dem_valley_area_hi", 4000.0));
            cdp.depth_exp = double(knobs.get("dem_valley_depth_exp", 0.8));
            cdp.mfd_exponent = double(knobs.get("dem_valley_mfd_exponent", 6.0));
            pk_dem::carve_drainage_valleys(height_out.ptrw(), relief.ptr(), wet.ptr(), cdp, &carve_stats);
            rep.carve_ms = carve_stats.total_ms;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();

    if (!rep.ok) {
        // 退化栅格等原因失败：fallback=true 且**不**返回 height_out（避免 caller 误用半成品）。
        out["reason"] = String((rep.reason != nullptr) ? rep.reason : "spl pipeline failed");
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        return out;
    }

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["height_out"] = height_out;
    out["erosion_grid_w"] = rep.w_lo;
    out["erosion_grid_h"] = rep.h_lo;
    out["erosion_grid_factor"] = rep.factor;
    out["flow_ms"] = rep.flow_ms;
    out["spl_ms"] = rep.spl_ms;
    out["dep_ms"] = rep.dep_ms;
    out["limit_ms"] = rep.limit_ms;
    out["carve_ms"] = rep.carve_ms;
    out["upsample_ms"] = rep.upsample_ms;
    out["fill_ms"] = carve_stats.fill_ms;
    out["mfd_ms"] = carve_stats.mfd_ms;
    out["wall_ms"] = carve_stats.wall_ms;
    out["spl_iters_effective"] = rep.stats.iters_effective;
    out["spl_p99_drop"] = rep.stats.p99_drop;
    out["spl_max_drop"] = rep.stats.max_drop;
    out["eroded_vol"] = rep.stats.eroded_vol;
    out["deposited_vol"] = rep.stats.deposited_vol;
    out["spl_sea_clamped"] = int(rep.stats.sea_clamped);
    out["spl_nan"] = int(rep.stats.nan);
    out["pits_in"] = int(rep.stats.pits_in);
    out["pits_out"] = int(rep.stats.pits_out);
    // [S2/S4.4 诊断] 像素层汇水面积（hex²）。仅 dem_erosion_area_dump=1 时非空。
    if (ek.area_dump && area_diag.size() == n) out["area_hex_buffer"] = area_diag;
    out["format"] = String("F32");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    return out;
}
