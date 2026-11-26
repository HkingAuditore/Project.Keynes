    pk::parallel_for_range("pk_bake_visual_tile_height", height_bands, height_bands, 1,
            [&](int band_begin, int band_end) {
        for (int band = band_begin; band < band_end; ++band) {
            const int y_begin = band * height_band_rows;
            const int y_end = std::min(y_begin + height_band_rows, WH);
            for (int y = y_begin; y < y_end; ++y) {
                const double wy = work_origin_y + (double(y) + 0.5) * step_y;
                for (int x = 0; x < WW; ++x) {
                    const int i = y * WW + x;
                    const double wx = work_origin_x + (double(x) + 0.5) * step_x;
                    const double base = sample_base_height(wx, wy);
                    const bool water = pk_is_water_terrain(BIOME_W[i]);
                    double procedural_detail = 0.0;
                    if (!water && BASE_P != nullptr && procedural_detail_gain > 0.0) {
                        procedural_detail = std::max(-procedural_detail_max, std::min(procedural_detail_max,
                                (double(PH[i]) - sample_base_bicubic(BASE_P, wx, wy)) * procedural_detail_gain));
                    }
                    double residual = 0.0;
                    if (!water && residual_amp > 0.0) {
                        const auto &columns = residual_columns[x];
                        const double n0 = band_periodic_noise(band, columns[0], wy);
                        const double navg = 0.25 * (
                                band_periodic_noise(band, columns[1], wy) +
                                band_periodic_noise(band, columns[2], wy) +
                                band_periodic_noise(band, columns[0], wy - residual_filter_radius) +
                                band_periodic_noise(band, columns[0], wy + residual_filter_radius));
                        const double relief_gate = std::max(0.12, std::min(1.0,
                                std::fabs(double(PH[i]) - base) / 0.06));
                        residual = std::max(-residual_amp, std::min(residual_amp,
                                (n0 - navg) * residual_amp * 3.0 * relief_gate));
                    }
                    double h = std::max(0.0, std::min(1.0, base + procedural_detail + residual));
                    if (water) h = std::min(h, sea_level);
                    else h = std::max(h, sea_level);
                    HW[i] = float(h);
                }
            }
        }
    });

    mark("height");

    Dictionary river = run_bake_river_sdf_pass(work_knobs);
    PackedFloat32Array flow_work = river.get("out_buf", PackedFloat32Array());
    if (bool(river.get("fallback", true)) || flow_work.size() != WN) {
        flow_work.resize(WN);
        float * const FW = flow_work.ptrw();
        const float * const BF = baseline_flow.size() >= BN ? baseline_flow.ptr() : nullptr;
        for (int y = 0; y < WH; ++y) {
            const double wy = work_origin_y + (double(y) + 0.5) * step_y;
            for (int x = 0; x < WW; ++x) {
                const double wx = work_origin_x + (double(x) + 0.5) * step_x;
                FW[y * WW + x] = BF != nullptr ? float(sample_base_scalar(BF, wx, wy)) : 0.0f;
            }
        }
    }
    const float * const FLOW_W = flow_work.ptr();
    for (int i = 0; i < WN; ++i) {
        const double f = std::max(0.0, std::min(1.0, double(FLOW_W[i])));
        if (f <= 0.02 || double(HW[i]) <= sea_level) continue;
        const double notch = f * f * (3.0 - 2.0 * f);
        HW[i] = float(std::max(0.0, double(HW[i]) - 0.045 * notch));
    }

    // Artificial canals share the height texture's A channel. Rasterization
    // uses only the owner cell and its six directed edges, keeping the work
    // bounded per pixel and adding no runtime sampler.
    mark("river");
    PackedFloat32Array canal_work;
    canal_work.resize(WN);
    canal_work.fill(0.0f);
    PackedByteArray canal_mask = knobs.get("cell_canal_edge_mask", PackedByteArray());
    PackedFloat32Array canal_pos_x = knobs.get("cell_pos_x", PackedFloat32Array());
    PackedFloat32Array canal_pos_y = knobs.get("cell_pos_y", PackedFloat32Array());
    PackedInt32Array canal_neighbors = knobs.get("neighbor_indices", PackedInt32Array());
    const int canal_n_cells = int(knobs.get("n_cells", 0));
    if (canal_mask.size() >= canal_n_cells && canal_pos_x.size() >= canal_n_cells &&
        canal_pos_y.size() >= canal_n_cells && canal_neighbors.size() >= canal_n_cells * 6) {
        float * const CW = canal_work.ptrw();
        const uint8_t * const CM = canal_mask.ptr();
        const float * const CPX = canal_pos_x.ptr();
        const float * const CPY = canal_pos_y.ptr();
        const int32_t * const CN = canal_neighbors.ptr();
        const int32_t * const owner = p2c_work.ptr();
        const double radius = std::max(step_x, step_y) +
            hex_size * std::max(0.01, std::min(0.12,
                double(knobs.get("canal_stroke_hex_factor", 0.045))));
        for (int y = 0; y < WH; ++y) {
            const double py = work_origin_y + (double(y) + 0.5) * step_y;
            for (int x = 0; x < WW; ++x) {
                const int pixel = y * WW + x;
                const int32_t cell = owner[pixel];
                if (cell < 0 || cell >= canal_n_cells || (CM[cell] & 0x3fU) == 0)
                    continue;
                double px = work_origin_x + (double(x) + 0.5) * step_x;
                const double ax = double(CPX[cell]) * hex_size;
                const double ay = double(CPY[cell]) * hex_size;
                if (wrap_period_x > 0.0001) {
                    while (px - ax > wrap_period_x * 0.5) px -= wrap_period_x;
                    while (px - ax < -wrap_period_x * 0.5) px += wrap_period_x;
                }
                double best = radius;
                for (int direction = 0; direction < 6; ++direction) {
                    if ((CM[cell] & (1U << direction)) == 0) continue;
                    const int32_t neighbor = CN[cell * 6 + direction];
                    if (neighbor < 0 || neighbor >= canal_n_cells) continue;
                    double bx = double(CPX[neighbor]) * hex_size;
                    const double by = double(CPY[neighbor]) * hex_size;
                    if (wrap_period_x > 0.0001) {
                        while (bx - ax > wrap_period_x * 0.5) bx -= wrap_period_x;
                        while (bx - ax < -wrap_period_x * 0.5) bx += wrap_period_x;
                    }
                    const double vx = bx - ax, vy = by - ay;
                    const double denom2 = std::max(1e-12, vx * vx + vy * vy);
                    const double t = std::max(0.0, std::min(1.0,
                        ((px - ax) * vx + (py - ay) * vy) / denom2));
                    const double dx = px - (ax + vx * t);
                    const double dy = py - (ay + vy * t);
                    best = std::min(best, std::sqrt(dx * dx + dy * dy));
                }
                double canal = std::max(0.0, std::min(1.0, 1.0 - best / radius));
                canal = canal * canal * (3.0 - 2.0 * canal);
                CW[pixel] = float(canal);
                // Half one 8-bit horizon-height quantum: normals see the bank,
                // while horizon/GI remain valid.
                HW[pixel] = float(std::max(0.0, double(HW[pixel]) -
                    canal * (0.5 / 255.0)));
            }
        }
    }
    const float * const CANAL_W = canal_work.ptr();
    mark("canal");

    work_knobs["biome_buffer"] = biome_work;
    Dictionary coast = run_bake_coast_sdf_pass(work_knobs);
    if (!bool(coast.get("fallback", true))) {
        PackedFloat32Array coast_sdf = coast.get("out_buf", PackedFloat32Array());
        if (coast_sdf.size() == WN) {
            const float * const CD = coast_sdf.ptr();
            const double amp = double(knobs.get("shore_carve_amp", 0.06));
            const int band = shore_carve_band_px;
            for (int i = 0; i < WN; ++i) {
                const double d = double(CD[i]);
                if (d <= 0.0 || d > double(band) || double(HW[i]) <= sea_level) continue;
                const double t = 1.0 - d / double(band);
                const double notch = t * t * (3.0 - 2.0 * t);
                HW[i] = float(std::max(sea_level, double(HW[i]) - amp * notch));
            }
        }
    }

    mark("coast");

    // height RGBA8: RG=16-bit carved visual elevation, B=natural river SDF,
    // A=artificial canal SDF.
    // 与 Legacy encode_height_flow_tex 对齐；不再单独产出 flow 层。
    // terrain_normal RGBA8: RG=粗法线 xy，BA=近景高度细节坡度（运行期只在拉近时淡入）。
    // terrain_relief RGBA8: RG=粗段细节坡度，BA=细段细节坡度。坡度均为 pk_relief::encode_slope。
    // terrain_detail R8: 连续细节噪声。
    // water_depth RGBA8: R=水深，G/B/A=湖 / 礁 / 海带的 3×3 软权重。
    // edge_distance RGBA8: R=到次生格的距离，G=沟谷深度（凹处遮蔽），B/A=8 邻域水 / 湖占比
    //   （海岸过渡；海占比 ≈ 水 − 湖）。fragment setup 每像素只读这一次，陆地和水面共用。
    // [cell-field warp 2026-11-18] boundary_warp RG8: R/G = 边界扭曲场 xy 的 8-bit 编码
    //   （v = clamp((warp+hi)/1.6, -1, 1)，byte = round((v*0.5+0.5)*255)），供 hex cell
    //   field shader 解析格界；与 terrain_index 的同名 buffer 逐字节同源（同栅格直搬）。
    PackedByteArray height_data; height_data.resize(N * 4);
    PackedByteArray normal_data; normal_data.resize(N * 4);
    // 细节坡度是 sub-hex 尺度的高频量，按 relief_supersample 倍分辨率烘焙（只这一张），
    // 运行期仍是 1 次采样：tile 寻址是归一化坐标，与该数组的物理尺寸无关。
    const int RS = std::max(1, std::min(4, int(knobs.get("relief_supersample", 1))));
    const int RW = W * RS;
    const int RH = H * RS;
    PackedByteArray relief_data; relief_data.resize(RW * RH * 4);
    PackedByteArray map_index_data; map_index_data.resize(N * 4);
    PackedByteArray water_data; water_data.resize(N * 4);
    PackedByteArray detail_data; detail_data.resize(N);
    PackedByteArray edge_data; edge_data.resize(N * 2);
    PackedByteArray edge_distance_data; edge_distance_data.resize(N * 4);
    // [cell-field warp 2026-11-18] 边界扭曲场 RG8：静态几何场，逐 texel 2 字节（与 edge_neighbor 同宽）。
    PackedByteArray boundary_warp_data; boundary_warp_data.resize(N * 2);
    uint8_t * const HD = height_data.ptrw();
    uint8_t * const ND = normal_data.ptrw();
    uint8_t * const RD = relief_data.ptrw();
    uint8_t * const MD = map_index_data.ptrw();
    uint8_t * const WD = water_data.ptrw();
    uint8_t * const DD = detail_data.ptrw();
    uint8_t * const ED = edge_data.ptrw();
    uint8_t * const EDD = edge_distance_data.ptrw();
    uint8_t * const BWD = boundary_warp_data.ptrw();
    const int32_t * const P2C = p2c_work.ptr();
    const uint8_t * const EW = edge_work.ptr();
    const uint8_t * const EDW = edge_distance_work.ptr();
    PackedByteArray landform = knobs.get("cell_landform", PackedByteArray());
    const uint8_t * const LF = landform.is_empty() ? nullptr : landform.ptr();
    const int n_cells = int(knobs.get("n_cells", 0));
    PackedFloat32Array cell_surface = knobs.get("cell_water_depth", PackedFloat32Array());
    PackedByteArray cell_terrain = knobs.get("cell_terrain", PackedByteArray());
    const float * const CS = cell_surface.size() >= n_cells ? cell_surface.ptr() : nullptr;
    const uint8_t * const CT = cell_terrain.size() >= n_cells ? cell_terrain.ptr() : nullptr;
    const uint8_t * const BWATER = baseline_water.size() >= BN ? baseline_water.ptr() : nullptr;
    const double normal_gain_x = normal_height_scale_hex * hex_size /
            (double(normal_radius_x * 2) * step_x);
    const double normal_gain_y = normal_height_scale_hex * hex_size /
            (double(normal_radius_y * 2) * step_y);

    godot::Ref<godot::FastNoiseLite> detail_noise;
    detail_noise.instantiate();
    detail_noise->set_noise_type(godot::FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    detail_noise->set_seed(int(knobs.get("seed", 0)) + 2503);
    detail_noise->set_frequency(float(0.18 / hex_size));
    detail_noise->set_fractal_type(godot::FastNoiseLite::FRACTAL_FBM);
    detail_noise->set_fractal_octaves(4);
    auto detail_periodic = [&](double wx, double wy) -> double {
        if (wrap_period_x <= 0.0001) return double(detail_noise->get_noise_2d(wx, wy));
        const double phase = wrap_world_x(wx) / wrap_period_x * (2.0 * M_PI);
        const double radius = wrap_period_x / (2.0 * M_PI);
        return double(detail_noise->get_noise_3d(
                std::cos(phase) * radius, std::sin(phase) * radius, wy));
    };

    // 分地形细节法线与静态邻域量的输入。运行期着色参数在这里取默认值烘死；
    // 改动后需重新生成地图（与 normal_height_scale_hex 同类）。
    const float relief_coarse_strength = float(knobs.get("hillshade_coarse_strength", 1.65));
    const float relief_height_detail = float(knobs.get("hillshade_detail_strength", 0.16)) *
            float(knobs.get("hillshade_detail_quality", 0.55));
    const float relief_slope_gain = float(knobs.get("hillshade_slope_gain", 15.0));
    const float relief_shore_detail = float(knobs.get("shore_detail_strength", 0.45)) *
            float(knobs.get("hillshade_detail_quality", 0.55));
    const float relief_shore_band = std::max(0.001f, float(knobs.get("shore_band_height", 0.06)));
    const float relief_world_scale = std::max(1.0f,
            float(knobs.get("terrain_erosion_world_size", 72.0))) / 72.0f;
    const float relief_strength = std::max(0.0f, float(knobs.get("terrain_erosion_strength", 1.0)));
    const int map_w = int(knobs.get("map_width", 0));
    const int map_h = int(knobs.get("map_height", 0));
    PackedInt32Array offset_to_index = knobs.get("offset_to_index", PackedInt32Array());
    const int32_t * const O2I = (map_w > 0 && map_h > 0 &&
            offset_to_index.size() >= map_w * map_h) ? offset_to_index.ptr() : nullptr;
    const float flow_off_x = float(hex_size / step_x);
    const float flow_off_y = float(hex_size / step_y);
    const float hd_off = 3.5f;

    auto height_bilinear = [&](float fx, float fy) -> float {
        fx = std::max(0.0f, std::min(float(WW - 1), fx));
        fy = std::max(0.0f, std::min(float(WH - 1), fy));
        const int x0 = std::min(WW - 2, int(fx));
        const int y0 = std::min(WH - 2, int(fy));
        const float tx = fx - float(x0), ty = fy - float(y0);
        const float a = HW[y0 * WW + x0] * (1.0f - tx) + HW[y0 * WW + x0 + 1] * tx;
        const float b = HW[(y0 + 1) * WW + x0] * (1.0f - tx) + HW[(y0 + 1) * WW + x0 + 1] * tx;
        return a * (1.0f - ty) + b * ty;
    };
    // 沙丘只在成片沙海里成形：按本格 + 6 邻格中有沙丘配置的占比衰减，孤立的一两格沙漠不起沙丘。
    std::vector<float> dune_erg(size_t(std::max(n_cells, 0)), 1.0f);
