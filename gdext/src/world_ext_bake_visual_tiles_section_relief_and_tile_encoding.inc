    // ── 分地形细节坡度（RS 倍分辨率）─────────────────────────────────────
    // 子 texel 的粗法线 / 平滑高程场都从工作高度场双线性取，与基础分辨率的粗法线同半径同增益。
    const bool canal_refresh_only = bool(knobs.get("canal_refresh_only", false));
    std::vector<float> crease_sub(size_t(RW) * size_t(RH), 0.0f);
    const float sub_texel_world = float(std::sqrt(step_x * step_y) / double(RS));
    auto relief_rows = [&](int ry_begin, int ry_end) {
        for (int ry = ry_begin; ry < ry_end; ++ry) {
            const float fyw = float(halo) + (float(ry) + 0.5f) / float(RS) - 0.5f;
            const double wy = origin_y + (double(ry) + 0.5) * step_y / double(RS);
            const int by = std::min(H - 1, ry / RS);
            for (int rx = 0; rx < RW; ++rx) {
                const int ri_idx = ry * RW + rx;
                const int bx = std::min(W - 1, rx / RS);
                const int si = (by + halo) * WW + bx + halo;
                const int own_biome = BIOME_W[si];
                float out_c[4] = {0.0f, 0.0f, 0.0f, 0.0f};
                if (!pk_relief::is_water(own_biome)) {
                    const float fxw = float(halo) + (float(rx) + 0.5f) / float(RS) - 0.5f;
                    const double wx = origin_x + (double(rx) + 0.5) * step_x / double(RS);
                    const float sx = (height_bilinear(fxw + float(normal_radius_x), fyw) -
                            height_bilinear(fxw - float(normal_radius_x), fyw)) * float(normal_gain_x);
                    const float sy = (height_bilinear(fxw, fyw + float(normal_radius_y)) -
                            height_bilinear(fxw, fyw - float(normal_radius_y))) * float(normal_gain_y);
                    const float inv_len = 1.0f / std::sqrt(sx * sx + sy * sy + 1.0f);
                    pk_relief::Inputs ri;
                    ri.wx = float(wrap_world_x(wx));
                    ri.wy = float(wy);
                    ri.nc_x = -sx * inv_len * relief_coarse_strength;
                    ri.nc_y = -sy * inv_len * relief_coarse_strength;
                    ri.nc_z = std::sqrt(std::max(1e-4f,
                            1.0f - std::min(ri.nc_x * ri.nc_x + ri.nc_y * ri.nc_y, 0.998f)));
                    ri.elev = pk_relief::clampf(height_bilinear(fxw, fyw), 0.0f, 1.0f);
                    ri.sea_level = float(sea_level);
                    const float hl = height_bilinear(fxw - flow_off_x, fyw);
                    const float hr = height_bilinear(fxw + flow_off_x, fyw);
                    const float hu = height_bilinear(fxw, fyw - flow_off_y);
                    const float hd = height_bilinear(fxw, fyw + flow_off_y);
                    ri.flow_gx = (hr - hl) / float(2.0 * hex_size);
                    ri.flow_gy = (hd - hu) / float(2.0 * hex_size);
                    ri.flow_mean = (hl + hr + hu + hd) * 0.25f;
                    const int ci = P2C[si];
                    const int own_lf = (LF != nullptr && ci >= 0 && ci < landform.size()) ? LF[ci] : 0;
                    relief_profile(ri.wx, ri.wy, own_biome, own_lf, ci, ri.P, ri.lf_layered,
                            ri.lf_bad);
                    ri.hex_size = float(hex_size);
                    ri.height_scale_hex = float(normal_height_scale_hex);
                    ri.texel_world = sub_texel_world;
                    ri.wrap_period = float(wrap_period_x);
                    ri.world_scale = relief_world_scale;
                    ri.strength = relief_strength;
                    const pk_relief::Output ro = pk_relief::evaluate(ri);
                    out_c[0] = ro.coarse_x;
                    out_c[1] = ro.coarse_y;
                    out_c[2] = ro.fine_x;
                    out_c[3] = ro.fine_y;
                    crease_sub[size_t(ri_idx)] = ro.crease;
                }
                for (int c = 0; c < 4; ++c) RD[ri_idx * 4 + c] = pk_relief::encode_slope(out_c[c]);
            }
        }
    };
    mark("relief_setup");
    if (!canal_refresh_only) {
        pk::parallel_for_range("pk_bake_visual_tile_relief", RH, bake_row_tasks(RH),
                /*seq_threshold=*/8, relief_rows);
    }
    mark("relief");

    auto encode_rows = [&](int y_begin, int y_end) {
        for (int y = y_begin; y < y_end; ++y) {
            const int wy_i = y + halo;
            const double wy = origin_y + (double(y) + 0.5) * step_y;
            for (int x = 0; x < W; ++x) {
                const int wx_i = x + halo;
                const int si = wy_i * WW + wx_i;
                const int di = y * W + x;
                const double wx = origin_x + (double(x) + 0.5) * step_x;
                const double h = std::max(0.0, std::min(1.0, double(HW[si])));
                const int h16 = std::max(0, std::min(65535, int(std::round(h * 65535.0))));
                const double f = std::max(0.0, std::min(1.0, double(FLOW_W[si])));
                HD[di * 4] = uint8_t((h16 >> 8) & 0xFF);
                HD[di * 4 + 1] = uint8_t(h16 & 0xFF);
                HD[di * 4 + 2] = uint8_t(std::round(f * 255.0));
                HD[di * 4 + 3] = uint8_t(std::round(std::max(0.0,
                    std::min(1.0, double(CANAL_W[si]))) * 255.0));

                const double sx = (double(HW[wy_i * WW + wx_i + normal_radius_x]) -
                        double(HW[wy_i * WW + wx_i - normal_radius_x])) * normal_gain_x;
                const double sy = (double(HW[(wy_i + normal_radius_y) * WW + wx_i]) -
                        double(HW[(wy_i - normal_radius_y) * WW + wx_i])) * normal_gain_y;
                const double inv_len = 1.0 / std::sqrt(sx * sx + sy * sy + 1.0);
                ND[di * 4] = uint8_t(std::max(0, std::min(255,
                        int(std::round((-sx * inv_len * 0.5 + 0.5) * 255.0)))));
                ND[di * 4 + 1] = uint8_t(std::max(0, std::min(255,
                        int(std::round((-sy * inv_len * 0.5 + 0.5) * 255.0)))));

                const int ci = P2C[si];
                const int own_biome = BIOME_W[si];
                const bool own_water = pk_relief::is_water(own_biome);

                // ── 沟谷深度（子 texel 平均）与近景高度细节 ─────────────────────
                float crease = 0.0f;
                for (int oy = 0; oy < RS; ++oy) {
                    for (int ox = 0; ox < RS; ++ox) {
                        crease += crease_sub[size_t((y * RS + oy) * RW + x * RS + ox)];
                    }
                }
                crease /= float(RS * RS);
                float hd_sx = 0.0f, hd_sy = 0.0f;
                if (!own_water) {
                    const float ncx = float(-sx * inv_len) * relief_coarse_strength;
                    const float ncy = float(-sy * inv_len) * relief_coarse_strength;
                    const float nc_z = std::sqrt(std::max(1e-4f,
                            1.0f - std::min(ncx * ncx + ncy * ncy, 0.998f)));
                    const float fxc = float(wx_i), fyc = float(wy_i);

                    // 近景高度细节：宽差分读出崖壁 / 河岸局部坡，近岸窄带单独增强。
                    // 按格主地形取强度：逐像素 biome 在过渡带是抖动抽选的，会让强度逐像素跳变。
                    const int geo_biome = (CT != nullptr && ci >= 0 && ci < n_cells &&
                            !pk_relief::is_water(CT[ci])) ? int(CT[ci]) : own_biome;
                    float hd_amt = relief_height_detail * pk_relief::height_detail_factor(geo_biome);
                    if (relief_shore_detail > 0.0f && h > sea_level) {
                        const float band = 1.0f - pk_relief::smoothstepf(0.0f, relief_shore_band,
                                float(h - sea_level));
                        hd_amt = std::max(hd_amt, band * relief_shore_detail);
                    }
                    if (hd_amt > 0.0f) {
                        const float g = relief_slope_gain / hd_off;
                        const float ddx = (height_bilinear(fxc + hd_off, fyc) -
                                height_bilinear(fxc - hd_off, fyc)) * g;
                        const float ddy = (height_bilinear(fxc, fyc + hd_off) -
                                height_bilinear(fxc, fyc - hd_off)) * g;
                        hd_sx = -ddx * hd_amt / nc_z;
                        hd_sy = -ddy * hd_amt / nc_z;
                    }
                }
                ND[di * 4 + 2] = pk_relief::encode_slope(hd_sx);
                ND[di * 4 + 3] = pk_relief::encode_slope(hd_sy);

                // ── 海岸 8 邻域：水 / 湖占比 ─────────────────────────────────
                int n_water = 0, n_lake = 0;
                for (int oy = -1; oy <= 1; ++oy) {
                    for (int ox = -1; ox <= 1; ++ox) {
                        if (ox == 0 && oy == 0) continue;
                        const int nb = BIOME_W[(wy_i + oy) * WW + wx_i + ox];
                        n_water += pk_relief::is_water(nb) ? 1 : 0;
                        n_lake += nb == pk_relief::B_LAKE ? 1 : 0;
                    }
                }
                // ── 水面类别 3×3 软权重（湖 / 礁 / 海带），足迹半径 water_biome_radius_px ─
                float c_lake = 0.0f, c_reef = 0.0f, c_kelp = 0.0f, c_total = 0.0f;
                for (int oy = -1; oy <= 1; ++oy) {
                    for (int ox = -1; ox <= 1; ++ox) {
                        const int tx = wx_i + int(std::lround(double(ox) * water_biome_radius_px));
                        const int ty = wy_i + int(std::lround(double(oy) * water_biome_radius_px));
                        const int nb = BIOME_W[ty * WW + tx];
                        const float sw = 1.0f - 0.18f * std::min(1.41421356f,
                                std::sqrt(float(ox * ox + oy * oy)));
                        c_lake += nb == pk_relief::B_LAKE ? sw : 0.0f;
                        c_reef += nb == pk_relief::B_REEF ? sw : 0.0f;
                        c_kelp += nb == pk_relief::B_KELP ? sw : 0.0f;
                        c_total += sw;
                    }
                }
                const float inv_ct = 255.0f / std::max(c_total, 0.001f);
                MD[di * 4] = BIOME_W[si];
                MD[di * 4 + 1] = ci >= 0 && ci < 0xFFFF ? uint8_t(ci & 0xFF) : 0xFF;
                MD[di * 4 + 2] = ci >= 0 && ci < 0xFFFF ? uint8_t((ci >> 8) & 0xFF) : 0xFF;
                MD[di * 4 + 3] = (LF != nullptr && ci >= 0 && ci < landform.size()) ? LF[ci] : 0;

                double depth = 0.0;
                if (CS != nullptr && ci >= 0 && ci < n_cells && CS[ci] > 1e-4f) {
                    const double raw = std::max(0.0, double(CS[ci]) - h);
                    const bool lake = CT != nullptr && CT[ci] == 18;
                    depth = std::min(1.0, raw / (lake ? 0.16 : std::max(1e-4, sea_level)));
                } else if (BWATER != nullptr) {
                    depth = sample_base_byte(BWATER, wx, wy);
                }
                WD[di * 4] = uint8_t(std::round(depth * 255.0));
                WD[di * 4 + 1] = uint8_t(std::lround(c_lake * inv_ct));
                WD[di * 4 + 2] = uint8_t(std::lround(c_reef * inv_ct));
                WD[di * 4 + 3] = uint8_t(std::lround(c_kelp * inv_ct));
                const double dn = std::max(-1.0, std::min(1.0, detail_periodic(wx, wy)));
                DD[di] = uint8_t(std::round((dn * 0.5 + 0.5) * 255.0));
                ED[di * 2] = EW[si * 2];
                ED[di * 2 + 1] = EW[si * 2 + 1];
                // [cell-field warp 2026-11-18] warp 场与 edge_* 同一 halo 工作栅格，逐 texel 直搬
                // （无重采样）：工作栅格步长与 tile 栅格完全一致，si → di 只差 halo 偏移。
                if (BW_W != nullptr) {
                    BWD[di * 2] = BW_W[si * 2];
                    BWD[di * 2 + 1] = BW_W[si * 2 + 1];
                }
                EDD[di * 4] = EDW[si];
                EDD[di * 4 + 1] = uint8_t(std::lround(pk_relief::clampf(crease, 0.0f, 1.0f) * 255.0f));
                EDD[di * 4 + 2] = uint8_t(std::lround(float(n_water) * (255.0f / 8.0f)));
                EDD[di * 4 + 3] = uint8_t(std::lround(float(n_lake) * (255.0f / 8.0f)));
            }
        }
    };
    pk::parallel_for_range("pk_bake_visual_tile_encode", H, bake_row_tasks(H),
            /*seq_threshold=*/8, encode_rows);
    mark("encode");

    // 逐缓冲 FNV：只服务于人工对拍（换实现后确认逐字节等价）。
    // **不要**把它挪进条件分支：`tests/ui/visual_tile_native_bake_test.gd` 用
    // `first.hashes == second.hashes` 断言逐块确定性，一旦默认返回空 dict，
    // 那条断言就退化成 `{} == {}` 恒真（2026-11-18 曾有人把它包进
    // `emit_layer_hashes` 开关并默认关闭，会静默削弱该测试）。
    Dictionary hashes;
