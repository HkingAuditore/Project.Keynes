// ─────────────────────────────────────────────────────────────────────────
// run_bake_terrain_index_pass — 生成期 height/biome/moisture/veg/cover 逐像素烘焙
// 复刻 map_baker.gd::_bake_height_biome_moisture（warp + cube_round + sextant
// barycentric + per-biome detail noise）。离散数据始终归属 cube_round 的硬主 cell；
// 视觉边界另行输出副 cell RG8 与边界距离 R8，避免 atlas-space dither 被近景放大。
//
// 全程经 knobs 传参（不依赖 bound slot —— bake 发生在 generation 期、bind 时机
// 不确定，与 encode_bake_* 同范式）。输出 CSR 三件套（按 cell.index）直接喂
// encode_bake_enum_atlas_payload；G/B/A 由硬主 cell 的桶成员驱动。
// 另输出边界扭曲场 RG8（boundary_warp_buffer / _range / _clamped，契约见
// docs/plans/terrain-cell-field-contract.md §2）：R/G = (warp + hi) / PK_WARP_RANGE
// 的 8-bit 编码，供 hex cell field shader 解析格界；clamped 为被 clamp 的通道数
// （按构造应为 0，非 0 即说明 warp 幅值超出 1.6，需进报告排查）。
// ─────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::run_bake_terrain_index_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
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

    const int W = int(knobs.get("width", 0));
    const int H = int(knobs.get("height", 0));
    const int n_pix = W * H;
    if (W <= 0 || H <= 0 || n_pix <= 0) return fail("invalid size");

    const int map_w = int(knobs.get("map_width", 0));
    const int map_h = int(knobs.get("map_height", 0));
    const int n_cells = int(knobs.get("n_cells", 0));
    const bool emit_csr = bool(knobs.get("emit_csr", true));
    if (map_w <= 0 || map_h <= 0 || n_cells <= 0) return fail("invalid map dims / n_cells");

    const double origin_x = double(knobs.get("origin_x", 0.0));
    const double origin_y = double(knobs.get("origin_y", 0.0));
    const double size_x = double(knobs.get("size_x", 0.0));
    const double size_y = double(knobs.get("size_y", 0.0));
    const double hex_size = double(knobs.get("hex_size", 1.0));
    const double wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    const int seed = int(knobs.get("seed", 0));
    // [P1 hypsometric Layer A 2026-06-25] sea_level 供锚定陆地段残差重映射（caller 传 world.sea_level）。
    const double sea_level = double(knobs.get("sea_level", 0.64));

    // ── cell SoA（by cell.index）+ offset→index 映射 ──
    PackedFloat32Array elev_in = knobs.get("cell_elevation", PackedFloat32Array());
    PackedFloat32Array moist_in = knobs.get("cell_moisture", PackedFloat32Array());
    PackedByteArray terr_in = knobs.get("cell_terrain", PackedByteArray());
    PackedByteArray landform_in = knobs.get("cell_landform", PackedByteArray());
    PackedByteArray veg_in = knobs.get("cell_vegetation", PackedByteArray());
    PackedByteArray cov_in = knobs.get("cell_cover", PackedByteArray());
    PackedInt32Array o2i_in = knobs.get("offset_to_index", PackedInt32Array());
    if (elev_in.size() < n_cells || moist_in.size() < n_cells ||
        terr_in.size() < n_cells || veg_in.size() < n_cells || cov_in.size() < n_cells) {
        return fail("cell SoA size < n_cells");
    }
    if (o2i_in.size() < map_w * map_h) return fail("offset_to_index too small");
    if (!landform_in.is_empty() && landform_in.size() != n_cells) return fail("cell_landform size != n_cells");

    const float * const __restrict E = elev_in.ptr();
    const float * const __restrict M = moist_in.ptr();
    const uint8_t * const __restrict T = terr_in.ptr();
    const uint8_t * const LF = landform_in.is_empty() ? nullptr : landform_in.ptr();
    const uint8_t * const __restrict VG = veg_in.ptr();
    const uint8_t * const __restrict CV = cov_in.ptr();
    const int32_t * const __restrict O2I = o2i_in.ptr();

    // ── 与 map_baker.gd 常量逐一对齐 ──
    constexpr double WARP_AMP = 0.4;
    constexpr double WARP_FREQ = 0.024;
    constexpr double WARP_HIGH_FREQ_MUL = 3.4;
    constexpr double WARP_HIGH_AMP_RATIO = 0.55;
    // [cell-field warp 2026-11-18] 边界扭曲场编码的归一化分母（契约 §2）。每个分量
    //   |warp| ≤ 1，hi 再乘 WARP_HIGH_AMP_RATIO ⇒ 理论上界 1.55 < 1.6，正常应零 clamp。
    //   与 GDScript DCHexCellField.WARP_RANGE、shader terrain_warp_range 同源。
    constexpr double PK_WARP_RANGE = 1.6;
    // [DEM 地貌 2026-10-09] P0 起伏 = 山脊网络（脊状 fBm）+ 顺坡沟谷（bake_dem_landform.h）。
    //   旧实现把脊状 / 岩屑噪声以 0.8~0.97 / 世界单位的频率直接采样世界坐标，波长约 1 个世界单位，
    //   而本栅格像素间距约 2 个世界单位：0.26 振幅整层落在奈奎斯特以上，烘出的是逐像素混叠噪点
    //   与斜向条纹。现在所有倍频的波长都按栅格截断；沟谷走向取宏观坡度 + 山脊坡度，
    //   于是沟谷从每条山脊两侧顺坡流下（羽状 / 树枝状水系）。
    //   knobs 未传时取下列默认值（与 terrain_index_baker.gd DEM_DEFAULTS 一致）。
    const double DEM_RELIEF_LO           = double(knobs.get("dem_relief_lo", 0.006));   // 邻格最大高差门控：below→平原保持平坦
    const double DEM_RELIEF_HI           = double(knobs.get("dem_relief_hi", 0.120));
    const double DEM_RELIEF_CAP          = double(knobs.get("dem_relief_cap", 0.25));
    const double DEM_RIDGE_AMP_PER_RELIEF = double(knobs.get("dem_ridge_amp_per_relief", 0.55));
    const double DEM_RIDGE_WAVELENGTH_HEX = double(knobs.get("dem_ridge_wavelength_hex", 2.4));
    const double DEM_RIDGE_CREST_EXP = std::clamp(double(knobs.get("dem_ridge_crest_exp", 2.2)), 1.0, 4.0);
    const double DEM_MOUNTAIN_FLOOR = std::max(0.0, double(knobs.get("dem_mountain_relief_floor", 0.055)));
    const double DEM_PEAK_FLOOR = std::max(0.0, double(knobs.get("dem_peak_relief_floor", 0.080)));
    // 逐层坡度贡献 ∝ 振幅 × 频率 = (2 × gain)^k：gain < 0.5 才是粗层主导、有主脊主谷的层级。
    const double DEM_RIDGE_GAIN          = double(knobs.get("dem_ridge_gain", 0.40));
    const double DEM_AMP_PER_RELIEF      = double(knobs.get("dem_amp_per_relief", 0.1));   // 最粗一层沟谷振幅 = 局地起伏 × 该系数
    const double DEM_BASE_WAVELENGTH_HEX = double(knobs.get("dem_base_wavelength_hex", 1.0));   // 最粗一层沟距
    const int    DEM_OCTAVES             = int(knobs.get("dem_octaves", 4));
    const double DEM_GAIN_WET            = double(knobs.get("dem_gain_wet", 0.48));   // 湿润：细沟弱、坡面圆滑
    const double DEM_GAIN_DRY            = double(knobs.get("dem_gain_dry", 0.62));   // 干燥：细沟密、棱角分明
    constexpr double DEM_NYQUIST_TEXELS  = 4.0;    // 最细倍频至少跨 4 个像素
    // TerrainType.TERRAIN 枚举（与 terrain_type.gd 顺序严格一致）
    constexpr int TT_OCEAN = 0, TT_COAST = 1;

    // ── FastNoiseLite：与 map_baker.gd::_init_noise 逐位同源 ──
    Ref<FastNoiseLite> warp_lo;  warp_lo.instantiate();
    warp_lo->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    warp_lo->set_seed(seed + 71);
    warp_lo->set_frequency(WARP_FREQ);
    warp_lo->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_lo->set_fractal_octaves(3);

    Ref<FastNoiseLite> warp_hi;  warp_hi.instantiate();
    warp_hi->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    warp_hi->set_seed(seed + 233);
    warp_hi->set_frequency(WARP_FREQ * WARP_HIGH_FREQ_MUL);
    warp_hi->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_hi->set_fractal_octaves(3);

    FastNoiseLite *NW_LO = warp_lo.ptr();
    FastNoiseLite *NW_HI = warp_hi.ptr();

    // 山脊网络：频率 = 1 / 波长（世界单位），倍频数按栅格奈奎斯特截断。
    const double dem_step = std::max(size_x / double(W), size_y / double(H));
    const double dem_min_wavelength = DEM_NYQUIST_TEXELS * dem_step;
    const double dem_ridge_wavelength = std::max(1e-3, hex_size * DEM_RIDGE_WAVELENGTH_HEX);
    int dem_ridge_octaves = 0;
    for (double wl = dem_ridge_wavelength; wl >= dem_min_wavelength && dem_ridge_octaves < 4; wl *= 0.5) {
        ++dem_ridge_octaves;
    }
    Ref<FastNoiseLite> dem_ridge;  dem_ridge.instantiate();
    dem_ridge->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    dem_ridge->set_seed(seed + 977);
    dem_ridge->set_frequency(float(1.0 / dem_ridge_wavelength));
    dem_ridge->set_fractal_type(FastNoiseLite::FRACTAL_RIDGED);
    dem_ridge->set_fractal_octaves(std::max(1, dem_ridge_octaves));
    dem_ridge->set_fractal_gain(float(DEM_RIDGE_GAIN));
    dem_ridge->set_fractal_lacunarity(2.0f);
    FastNoiseLite *NRG = dem_ridge.ptr();
    // 经线环绕：映射到圆柱面取 3D 噪声，接缝两侧连续且不需要混合带。
    auto dem_ridge_at = [&](double x, double y) -> double {
        if (dem_ridge_octaves <= 0) return 0.0;
        if (wrap_period_x <= 0.0001) return double(NRG->get_noise_2d(x, y));
        const double phase = x / wrap_period_x * 6.283185307179586;
        const double radius = wrap_period_x / 6.283185307179586;
        return double(NRG->get_noise_3d(std::cos(phase) * radius, std::sin(phase) * radius, y));
    };

    // ── 数学原语（逐一对齐 map_baker.gd / hex_utils.gd）──
    auto fposmodd = [](double a, double b) -> double {
        double m = std::fmod(a, b);
        if (m < 0.0) m += b;
        return m;
    };
    auto smooth01 = [](double e0, double e1, double x) -> double {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        double t = (x - e0) / (e1 - e0);
        t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
        return t * t * (3.0 - 2.0 * t);
    };
    // _cyl_noise：2D 接缝包裹（fposmod + band smoothstep lerp 到 seam 均值）。
    // phase_origin_x 必须跟调用点的 x 偏移/缩放同相位，否则 x+91.1 这类采样会把
    // 人造 fposmod seam 移进地图内部。
    auto cyl = [&](FastNoiseLite *nz, double x, double y,
                   double period_scale = 1.0, double phase_origin_x = 0.0) -> double {
        const double period = wrap_period_x * std::max(period_scale, 0.0001);
        if (period <= 0.0001) return double(nz->get_noise_2d(x, y));
        const double phase = fposmodd(x - phase_origin_x, period);
        double xw = phase_origin_x + phase;
        double base = double(nz->get_noise_2d(xw, y));
        double band = std::min(std::max(hex_size * 8.0 * std::max(period_scale, 0.0001), 1.0), period * 0.12);
        if (band <= 0.0001) return base;
        double left = double(nz->get_noise_2d(phase_origin_x, y));
        double right = double(nz->get_noise_2d(phase_origin_x + period, y));
        double seam_avg = (left + right) * 0.5;
        if (phase < band) {
            double tl = smooth01(0.0, band, phase);
            return seam_avg + (base - seam_avg) * tl;
        }
        if (phase > period - band) {
            double tr = smooth01(0.0, band, period - phase);
            return seam_avg + (base - seam_avg) * tr;
        }
        return base;
    };
    const double SQRT3 = std::sqrt(3.0);
    // cube_to_world(q, r, size)
    auto cube_to_world_x = [&](int q, int r) -> double { return hex_size * SQRT3 * (double(q) + double(r) / 2.0); };
    auto cube_to_world_y = [&](int r) -> double { return hex_size * 1.5 * double(r); };
    // cube → cell.index（含东西经度环绕；南北硬边界返回 -1）
    auto cell_at_cube = [&](int q, int r) -> int {
        if (r < 0 || r >= map_h) return -1;
        int col = q + ((r - (r & 1)) / 2);          // cube_to_offset.col
        col = ((col % map_w) + map_w) % map_w;       // posmod wrap
        return O2I[r * map_w + col];
    };
    // _neighbor_dir：atan2 sextant 编号 → cube 方向（0=E,1=SE,2=SW,3=W,4=NW,5=NE）
    static const int NDQ[6] = { 1, 0, -1, -1, 0, 1 };
    static const int NDR[6] = { 0, 1, 1, 0, -1, -1 };

    // ── 输出 buffer ──
    PackedFloat32Array height_buf;  height_buf.resize(n_pix);
    // 每像素 DEM 起伏尺度（height 单位，= 局地起伏 × 门控；水体 / 平原为 0），供汇流刻谷定深度。
    PackedFloat32Array dem_relief_buf;  dem_relief_buf.resize(n_pix);
    float * const __restrict DREL = dem_relief_buf.ptrw();
    PackedByteArray biome_buf;      biome_buf.resize(n_pix);
    PackedFloat32Array moist_buf;   moist_buf.resize(n_pix);
    PackedByteArray veg_buf;        veg_buf.resize(n_pix);
    PackedByteArray cover_buf;      cover_buf.resize(n_pix);
    PackedInt32Array p2c;           p2c.resize(n_pix);
    PackedByteArray edge_secondary_buf; edge_secondary_buf.resize(n_pix * 2);
    PackedByteArray edge_distance_buf;  edge_distance_buf.resize(n_pix);
    // [cell-field warp 2026-11-18] 边界扭曲场 RG8（契约 §2）：逐像素 2 字节，R=x / G=y。
    PackedByteArray boundary_warp_buf;  boundary_warp_buf.resize(n_pix * 2);
    float * const __restrict HBUF = height_buf.ptrw();
    uint8_t * const __restrict BBUF = biome_buf.ptrw();
    float * const __restrict MBUF = moist_buf.ptrw();
    uint8_t * const __restrict VBUF = veg_buf.ptrw();
    uint8_t * const __restrict CBUF = cover_buf.ptrw();
    int32_t * const __restrict P2C = p2c.ptrw();
    uint8_t * const __restrict ESEC = edge_secondary_buf.ptrw();
    uint8_t * const __restrict EDIST = edge_distance_buf.ptrw();
    uint8_t * const __restrict BWARP = boundary_warp_buf.ptrw();

    // CSR 计数（by cell.index）
    PackedInt32Array first_px;  first_px.resize(n_cells);
    PackedInt32Array px_count;  px_count.resize(n_cells);
    int32_t * const __restrict FIRST = first_px.ptrw();
    int32_t * const __restrict CNT = px_count.ptrw();
    for (int c = 0; c < n_cells; ++c) { FIRST[c] = -1; CNT[c] = 0; }

    const double step_x = size_x / double(W);
    const double step_y = size_y / double(H);
    const double warp_scale = hex_size * WARP_AMP;
    const double PI = 3.14159265358979323846;
    pk_dem::LandformParams dem_params;
    dem_params.wrap_period_x = wrap_period_x;
    dem_params.base_wavelength = hex_size * DEM_BASE_WAVELENGTH_HEX;
    dem_params.min_wavelength = dem_min_wavelength;
    dem_params.max_octaves = DEM_OCTAVES;
    dem_params.seed = uint32_t(seed) * 0x2c1b3c6dU + 0x297a2d39U;
    // 视觉 ecotone 需要覆盖足够的 cell 内侧范围。中心距差约为实际垂直边界
    // 距离的两倍，因此 0.90 gap 对应单侧约 0.45 hex；shader 再按质量缩放。
    // 边界场本身对所有合法邻格通用；是否允许跨水陆混合由各视觉消费者决定。
    auto t0 = std::chrono::high_resolution_clock::now();

    // ── [P0] per-cell 高程梯度 + 局地起伏预计算（六邻居有限差分；O(n_cells)）──
    //    grad 方向供各向异性脊线（沿等高线方向拉长山脊）；relief（邻格最大高差）供连续
    //    振幅门控（平原→趋零、山地补区域起伏与地貌下限），不依赖 hex_size 量纲。
    std::vector<float> CGX(size_t(n_cells), 0.0f), CGY(size_t(n_cells), 0.0f), CREL(size_t(n_cells), 0.0f);
    for (int r = 0; r < map_h; ++r) {
        const int qbase = -((r - (r & 1)) / 2);          // offset.col → cube.q（cell_at_cube 互逆）
        for (int col = 0; col < map_w; ++col) {
            const int self_c = O2I[r * map_w + col];
            if (self_c < 0 || self_c >= n_cells) continue;
            const int q = col + qbase;
            const double e0 = double(E[self_c]);
            const double sx0 = cube_to_world_x(q, r);
            const double sy0 = cube_to_world_y(r);
            double Sxx = 0.0, Sxy = 0.0, Syy = 0.0, Sxz = 0.0, Syz = 0.0;
            double relief = 0.0;
            for (int d = 0; d < 6; ++d) {
                const int nq = q + NDQ[d], nr = r + NDR[d];
                const int nb = cell_at_cube(nq, nr);     // 含经度环绕；南北极返回 -1
                if (nb < 0) continue;
                const double dz = double(E[nb]) - e0;
                // 用 unwrapped cube 世界坐标算局部偏移（接缝处仍连续，梯度方向正确）
                const double dx = cube_to_world_x(nq, nr) - sx0;
                const double dy = cube_to_world_y(nr) - sy0;
                Sxx += dx * dx; Sxy += dx * dy; Syy += dy * dy;
                Sxz += dx * dz; Syz += dy * dz;
                const double adz = dz < 0.0 ? -dz : dz;
                if (adz > relief) relief = adz;
            }
            const double det = Sxx * Syy - Sxy * Sxy;    // 2×2 最小二乘解世界空间梯度
            if (det > 1e-12 || det < -1e-12) {
                const double inv = 1.0 / det;
                CGX[size_t(self_c)] = float((Syy * Sxz - Sxy * Syz) * inv);
                CGY[size_t(self_c)] = float((Sxx * Syz - Sxy * Sxz) * inv);
            }
            // 两圈的高差折算回一格尺度；只在山地身份中补强区域起伏，避免远山污染平原。
            double regional_min = e0, regional_max = e0;
            for (int dq = -2; dq <= 2; ++dq) {
                for (int dr = std::max(-2, -dq - 2); dr <= std::min(2, -dq + 2); ++dr) {
                    const int nb = cell_at_cube(q + dq, r + dr);
                    if (nb < 0 || pk_relief::is_water(T[nb])) continue;
                    regional_min = std::min(regional_min, double(E[nb]));
                    regional_max = std::max(regional_max, double(E[nb]));
                }
            }
            const int lf = LF != nullptr ? int(LF[self_c]) : -1;
            const bool mountain = lf == 7 || lf == 8 || lf == 12;
            if (mountain) {
                relief = std::max(relief, (regional_max - regional_min) * 0.35);
                relief = std::max(relief, lf == 8 ? DEM_PEAK_FLOOR : DEM_MOUNTAIN_FLOOR);
            } else if (lf == 13) {
                // 高原内部压低细纹，陡坎仍由实测邻格高差驱动。
                relief *= 0.35 + 0.65 * smooth01(0.02, 0.10, relief);
            }
            CREL[size_t(self_c)] = pk_relief::is_water(T[self_c]) ? 0.0f : float(relief);
        }
    }

    // [P1 hypsometric Layer A 2026-06-25] bake 期 per-pixel 残差塑形：cell E 已被 Layer B(仿真高程)
    // 重塑，经 barycentric 插值后台地边缘被线性抹软；此处对 elev_blend 以小 mix(PK_HYPSO_LAYER_A_MIX)
    // 重新施加同曲线，在像素分辨率下重锐化台地/陡坡。仅陆地段、锚定 sea_level，避免与 B 双重压缩过度。
    const PkHypsoCurve hypso = pk_make_hypso_curve();
    const double hy_above = 1.0 - sea_level;
    const double hy_inv_above = (hy_above > 1e-6) ? (1.0 / hy_above) : 0.0;

    // [cell-field warp 2026-11-18] warp clamp 计数按行分槽：run_rows 是并行体，跨行共享一个
    // 累加器就是 data race（理由与下方 CSR 直方图注释相同）。每行只写自己的槽（该行只被一个
    // task 处理），并行区结束后再串行求和，与 CSR 直方图同一模式。
    std::vector<int> warp_clamp_rows(size_t(H), 0);
    int * const __restrict WCLAMP_ROW = warp_clamp_rows.data();

    // 逐行并行：每像素只写自己的 idx 槽，CGX/CGY/CREL 与四个 FastNoiseLite 实例
    // 在此之后只读——噪声参数全部在进入并行区前设完，get_noise_2d 是纯读，
    // 多线程共享同一实例安全。唯一的跨行共享写（CSR 直方图）已移到并行区之后。
    auto run_rows = [&](int y_begin, int y_end) {
        for (int y = y_begin; y < y_end; ++y) {
            const double wy_base = origin_y + (double(y) + 0.5) * step_y;
            const int row = y * W;
            int row_clamp = 0;   // 本行被 clamp 的 warp 通道数（只属于该行的槽）
            for (int x = 0; x < W; ++x) {
                const double wx_base = origin_x + (double(x) + 0.5) * step_x;

                // 1. warp（双频）
                const double warp_x = cyl(NW_LO, wx_base, wy_base);
                const double warp_y = cyl(NW_LO, wx_base + 31.7, wy_base - 17.3, 1.0, 31.7);
                const double hi_x = cyl(NW_HI, wx_base + 91.1, wy_base + 53.7, 1.0, 91.1) * WARP_HIGH_AMP_RATIO;
                const double hi_y = cyl(NW_HI, wx_base - 41.5, wy_base + 23.9, 1.0, -41.5) * WARP_HIGH_AMP_RATIO;
                const double wx = wx_base + (warp_x + hi_x) * warp_scale;
                const double wy = wy_base + (warp_y + hi_y) * warp_scale;

                // 2. cube 归属（world_to_cube_f + cube_round）
                const double qf = (SQRT3 / 3.0 * wx - (1.0 / 3.0) * wy) / hex_size;
                const double rf = (2.0 / 3.0 * wy) / hex_size;
                const double sf = -qf - rf;
                double rq = std::round(qf), rr = std::round(rf), rs = std::round(sf);
                const double dq = std::fabs(rq - qf), dr = std::fabs(rr - rf), ds = std::fabs(rs - sf);
                if (dq > dr && dq > ds) rq = -rr - rs;
                else if (dr > ds) rr = -rq - rs;
                else rs = -rq - rr;
                const int cq = int(rq), cr = int(rr);
                const int self_idx = cell_at_cube(cq, cr);

                // 3. sextant 邻居
                const double scx = cube_to_world_x(cq, cr);
                const double scy = cube_to_world_y(cr);
                const double lx = (wx - scx) / hex_size;
                const double ly = (wy - scy) / hex_size;
                const double angle = std::atan2(ly, lx);
                const int sextant = int(std::floor(fposmodd((angle + PI / 6.0) / (PI / 3.0), 6.0)));
                const int s0 = sextant % 6;
                const int s1 = (sextant + 1) % 6;
                const int nb1_q = cq + NDQ[s0], nb1_r = cr + NDR[s0];
                const int nb2_q = cq + NDQ[s1], nb2_r = cr + NDR[s1];
                const int nb1_idx = cell_at_cube(nb1_q, nb1_r);
                const int nb2_idx = cell_at_cube(nb2_q, nb2_r);

                // 4. barycentric（self + 2 邻居中心）
                const double ax = scx, ay = scy;
                const double bx = cube_to_world_x(nb1_q, nb1_r), b_y = cube_to_world_y(nb1_r);
                const double ccx = cube_to_world_x(nb2_q, nb2_r), ccy = cube_to_world_y(nb2_r);
                double w_self = 1.0, w_nb1 = 0.0, w_nb2 = 0.0;
                {
                    const double v0x = bx - ax, v0y = b_y - ay;
                    const double v1x = ccx - ax, v1y = ccy - ay;
                    const double v2x = wx - ax, v2y = wy - ay;
                    const double d00 = v0x * v0x + v0y * v0y;
                    const double d01 = v0x * v1x + v0y * v1y;
                    const double d11 = v1x * v1x + v1y * v1y;
                    const double d20 = v2x * v0x + v2y * v0y;
                    const double d21 = v2x * v1x + v2y * v1y;
                    const double denom = d00 * d11 - d01 * d01;
                    if (std::fabs(denom) >= 0.000001) {
                        const double inv = 1.0 / denom;
                        double vb = (d11 * d20 - d01 * d21) * inv;
                        double vc = (d00 * d21 - d01 * d20) * inv;
                        double va = 1.0 - vb - vc;
                        va = va < 0.0 ? 0.0 : va;
                        vb = vb < 0.0 ? 0.0 : vb;
                        vc = vc < 0.0 ? 0.0 : vc;
                        const double sum = va + vb + vc;
                        if (sum >= 0.0001) { w_self = va / sum; w_nb1 = vb / sum; w_nb2 = vc / sum; }
                    }
                }

                // 5. 取值
                const double elev_self = self_idx >= 0 ? double(E[self_idx]) : 0.0;
                const double elev_nb1 = nb1_idx >= 0 ? double(E[nb1_idx]) : elev_self;
                const double elev_nb2 = nb2_idx >= 0 ? double(E[nb2_idx]) : elev_self;
                const double moist_self = self_idx >= 0 ? double(M[self_idx]) : 0.5;
                const double moist_nb1 = nb1_idx >= 0 ? double(M[nb1_idx]) : moist_self;
                const double moist_nb2 = nb2_idx >= 0 ? double(M[nb2_idx]) : moist_self;
                const int terrain_self = self_idx >= 0 ? int(T[self_idx]) : TT_OCEAN;
                const int veg_self = self_idx >= 0 ? int(VG[self_idx]) : 0;
                const int cover_self = self_idx >= 0 ? int(CV[self_idx]) : 0;

                // 6. barycentric 插值
                double elev_blend = elev_self * w_self + elev_nb1 * w_nb1 + elev_nb2 * w_nb2;
                const double moist_blend = moist_self * w_self + moist_nb1 * w_nb1 + moist_nb2 * w_nb2;

                // 6.5 [P1 hypsometric Layer A] 锚定 sea_level 的小 mix 残差重映射（重锐化台地边缘，
                //     不重复整条 Layer B 曲线）；水下/无陆地段时透传。relief 随后叠在重塑基底上。
                if (hy_inv_above > 0.0 && elev_blend > sea_level) {
                    elev_blend = pk_hypso_remap_elev(hypso, elev_blend, sea_level,
                                                     hy_inv_above, hy_above, PK_HYPSO_LAYER_A_MIX);
                }

                // 6.6 [coast-beach 2026-06-25] 近岸海滩坡（治"海岸无法线"）：P1 后内陆平原也贴 sea_level，
                //     elev 无法区分海岸/内陆，故改用 barycentric 水邻居权重(亚格距水近度)——只有真正与水
                //     cell 相邻的陆地像素才下压成海滩坡（写进 height → terrain_normal_tex 拿到 crisp 海岸
                //     法线，与河岸 #2a 同法）。仅陆地 self、止于水线不越过；与 GDScript 镜像同公式。
                if (terrain_self != TT_OCEAN && terrain_self != TT_COAST && elev_blend > sea_level) {
                    constexpr double PK_COAST_BEACH = 0.05;  // 海滩坡最大下压(height 单位，× smoothstep)
                    double water_w = 0.0;
                    if (nb1_idx >= 0 && pk_is_water_terrain(uint8_t(T[nb1_idx]))) water_w += w_nb1;
                    if (nb2_idx >= 0 && pk_is_water_terrain(uint8_t(T[nb2_idx]))) water_w += w_nb2;
                    if (water_w > 0.0) {
                        const double beach = water_w * water_w * (3.0 - 2.0 * water_w);  // smoothstep 锐化
                        double e = elev_blend - PK_COAST_BEACH * beach;
                        if (e < sea_level) e = sea_level;   // 海滩止于水线
                        elev_blend = e;
                    }
                }


                // 7. [P0] per-pixel relief：山脊网络 + 顺坡沟谷（DEM 地貌）。沟谷走向取 per-cell 高程梯度
                //    与山脊坡度之和，振幅随局地起伏连续变化（平原趋平、山地满幅），干燥地表细沟更密；
                //    地貌已在 per-cell 起伏尺度中连续插值，不对像素做硬类别切换。
                double elev_final = elev_blend;
                double dem_relief_px = 0.0;
                if (terrain_self != TT_OCEAN && terrain_self != TT_COAST) {
                    // 插值 per-cell 梯度方向 + 局地起伏（复用 self/nb1/nb2 barycentric 权重）
                    double gx = CGX[size_t(self_idx)] * w_self;
                    double gy = CGY[size_t(self_idx)] * w_self;
                    double relief_p = CREL[size_t(self_idx)] * w_self;
                    if (nb1_idx >= 0) { gx += CGX[size_t(nb1_idx)] * w_nb1; gy += CGY[size_t(nb1_idx)] * w_nb1; relief_p += CREL[size_t(nb1_idx)] * w_nb1; }
                    if (nb2_idx >= 0) { gx += CGX[size_t(nb2_idx)] * w_nb2; gy += CGY[size_t(nb2_idx)] * w_nb2; relief_p += CREL[size_t(nb2_idx)] * w_nb2; }

                    const double gate = smooth01(DEM_RELIEF_LO, DEM_RELIEF_HI, relief_p);
                    if (gate > 0.0) {
                        const double relief_c = std::min(relief_p, DEM_RELIEF_CAP);
                        dem_relief_px = relief_c * gate;
                        // 尖化主脊并抬高峰肩对比；前向差分使用同一塑形曲线供沟谷定向。
                        const double ridge_amp = DEM_RIDGE_AMP_PER_RELIEF * relief_c * gate;
                        double ridge_off = 0.0, rgx = 0.0, rgy = 0.0;
                        if (ridge_amp > 0.0 && dem_ridge_octaves > 0) {
                            const double e = dem_min_wavelength * 0.25;
                            auto crest_at = [&](double x, double y) {
                                const double u = std::clamp((dem_ridge_at(x, y) + 1.0) * 0.5, 0.0, 1.0);
                                return (std::pow(u, DEM_RIDGE_CREST_EXP) - 0.40) * 2.0;
                            };
                            const double r0 = crest_at(wx_base, wy_base);
                            ridge_off = r0 * ridge_amp;
                            rgx = (crest_at(wx_base + e, wy_base) - r0) / e * ridge_amp;
                            rgy = (crest_at(wx_base, wy_base + e) - r0) / e * ridge_amp;
                        }
                        pk_dem::LandformParams lp = dem_params;
                        lp.gain = DEM_GAIN_WET + (DEM_GAIN_DRY - DEM_GAIN_WET) * (1.0 - moist_blend);
                        const double amp = DEM_AMP_PER_RELIEF * relief_c * gate;
                        elev_final = elev_blend + ridge_off
                                + pk_dem::landform(wx_base, wy_base, gx + rgx, gy + rgy, amp, lp);
                        if (elev_blend > sea_level && elev_final <= sea_level) {
                            elev_final = sea_level + 0.0005;   // 沟谷不把陆地刻成水面
                        }
                    }
                }

                // 8. 权威硬主索引 + 通用视觉边界辅助数据。为所有合法邻格输出副索引
                //    和距离，让 terrain/fog/weather 各自决定能否以及如何形成 ecotone；
                //    动态状态、CSR 与交互仍不被视觉过渡改派。
                int edge_secondary = -1;
                double edge_gap_hex = VISUAL_EDGE_DISTANCE_SATURATE_HEX;
                if (self_idx >= 0) {
                    const double self_dx = wx - scx;
                    const double self_dy = wy - scy;
                    const double self_distance = std::sqrt(self_dx * self_dx + self_dy * self_dy);
                    auto consider_edge_neighbor = [&](int candidate_idx, double cx, double cy) {
                        if (candidate_idx < 0 || candidate_idx >= n_cells) return;
                        const double dx = wx - cx;
                        const double dy = wy - cy;
                        const double candidate_distance = std::sqrt(dx * dx + dy * dy);
                        const double gap = std::max(0.0,
                                (candidate_distance - self_distance) / std::max(hex_size, 0.0001));
                        if (edge_secondary < 0 || gap < edge_gap_hex - 1e-12 ||
                                (std::fabs(gap - edge_gap_hex) <= 1e-12 &&
                                 candidate_idx < edge_secondary)) {
                            edge_secondary = candidate_idx;
                            edge_gap_hex = gap;
                        }
                    };
                    consider_edge_neighbor(nb1_idx, bx, b_y);
                    consider_edge_neighbor(nb2_idx, ccx, ccy);
                }

                const int idx = row + x;
                double hf = elev_final; hf = hf < 0.0 ? 0.0 : (hf > 1.0 ? 1.0 : hf);
                double mf = moist_blend; mf = mf < 0.0 ? 0.0 : (mf > 1.0 ? 1.0 : mf);
                HBUF[idx] = float(hf);
                DREL[idx] = float(dem_relief_px);
                BBUF[idx] = uint8_t(terrain_self & 0xFF);
                MBUF[idx] = float(mf);
                VBUF[idx] = uint8_t(veg_self & 0xFF);
                CBUF[idx] = uint8_t(cover_self & 0xFF);
                P2C[idx] = self_idx;
                if (edge_secondary >= 0 && edge_secondary < 0xFFFF) {
                    ESEC[idx * 2] = uint8_t(edge_secondary & 0xFF);
                    ESEC[idx * 2 + 1] = uint8_t((edge_secondary >> 8) & 0xFF);
                    const double edge_n = std::min(1.0,
                            edge_gap_hex / VISUAL_EDGE_DISTANCE_SATURATE_HEX);
                    EDIST[idx] = uint8_t(std::round(edge_n * 255.0));
                } else {
                    ESEC[idx * 2] = 0xFF;
                    ESEC[idx * 2 + 1] = 0xFF;
                    EDIST[idx] = 0xFF;
                }

                // 9.5 [cell-field warp 2026-11-18] 边界扭曲场 RG8（契约 §2）：与 height/biome 等
                //     buffer 同行并行，每像素只写自己的 2 字节，不碰任何跨行状态。total 取的是
                //     第 1 步里乘 warp_scale **之前**的 (warp + hi)，与 CPU 高程/海滩坡同源。
                {
                    const double total_x = warp_x + hi_x;
                    const double total_y = warp_y + hi_y;
                    double vx = total_x / PK_WARP_RANGE;
                    double vy = total_y / PK_WARP_RANGE;
                    if (vx < -1.0) { vx = -1.0; ++row_clamp; }
                    else if (vx > 1.0) { vx = 1.0; ++row_clamp; }
                    if (vy < -1.0) { vy = -1.0; ++row_clamp; }
                    else if (vy > 1.0) { vy = 1.0; ++row_clamp; }
                    BWARP[idx * 2] = uint8_t(std::round((vx * 0.5 + 0.5) * 255.0));
                    BWARP[idx * 2 + 1] = uint8_t(std::round((vy * 0.5 + 0.5) * 255.0));
                }
            }
            WCLAMP_ROW[y] = row_clamp;
        }
    };
    pk::parallel_for_range("pk_bake_terrain_index", H, bake_row_tasks(H),
            /*seq_threshold=*/8, run_rows);

    // [cell-field warp 2026-11-18] warp clamp 计数汇总：并行区内每行只写自己的槽，这里串行
    // 求和（与下面 CSR 直方图同一模式）。按构造理论上界 1.55 < PK_WARP_RANGE=1.6 ⇒ 应为 0。
    int boundary_warp_clamped = 0;
    for (int y = 0; y < H; ++y) boundary_warp_clamped += WCLAMP_ROW[y];

    // ── CSR build：prefix-sum first_px + scatter flat（counting sort，by cell.index）──
    // 直方图必须留在 run_rows 之外：CNT[cell] 是跨行共享的累加目标，放进并行体里
    // 就是 data race。逐 P2C 串行数一遍与原逐像素累加结果逐位相同，且 O(n_pix)
    // 相对每像素 ~24 次噪声采样可忽略。
    if (emit_csr) {
        for (int i = 0; i < n_pix; ++i) {
            const int c = P2C[i];
            if (c >= 0 && c < n_cells) CNT[c] += 1;
        }
    }
    int total_px = 0;
    PackedInt32Array flat_px;
    int32_t *FLAT = nullptr;
    if (emit_csr) {
        for (int c = 0; c < n_cells; ++c) {
            if (CNT[c] > 0) { FIRST[c] = total_px; total_px += CNT[c]; }
            else { FIRST[c] = -1; }
        }
        flat_px.resize(total_px);
        FLAT = flat_px.ptrw();
    }
    // 写游标：复用临时数组（各 cell 段起点）
    if (emit_csr) {
        std::vector<int> cursor(n_cells);
        for (int c = 0; c < n_cells; ++c) cursor[c] = FIRST[c];
        for (int i = 0; i < n_pix; ++i) {
            const int c = P2C[i];
            if (c >= 0 && c < n_cells && cursor[c] >= 0) {
                FLAT[cursor[c]] = i;
                cursor[c] += 1;
            }
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["width"] = W;
    out["height"] = H;
    out["height_buffer"] = height_buf;
    out["dem_relief_buffer"] = dem_relief_buf;
    out["biome_buffer"] = biome_buf;
    out["moisture_buffer"] = moist_buf;
    out["vegetation_buffer"] = veg_buf;
    out["cover_buffer"] = cover_buf;
    out["pixel_to_cell_index"] = p2c;
    out["edge_secondary_index_buffer"] = edge_secondary_buf;
    out["edge_distance_buffer"] = edge_distance_buf;
    out["edge_distance_units"] = String("normalized_hex_center_gap");
    out["edge_distance_saturate_hex"] = VISUAL_EDGE_DISTANCE_SATURATE_HEX;
    // [cell-field warp 2026-11-18] 边界扭曲场（契约 §2）：RG8 payload + 解码分母 + clamp 诊断。
    out["boundary_warp_buffer"] = boundary_warp_buf;
    out["boundary_warp_range"] = PK_WARP_RANGE;
    out["boundary_warp_clamped"] = boundary_warp_clamped;
    out["cell_first_px"] = first_px;
    out["cell_px_count"] = px_count;
    out["flat_px_indices"] = flat_px;
    out["total_px"] = total_px;
    out["csr_emitted"] = emit_csr;
    return out;
}
