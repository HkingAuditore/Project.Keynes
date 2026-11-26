// Pure weather field calculations shared by the production and worker paths.

// ─── weather field solve 的无状态 helper（原在 world_ext_internal.h）────────
//
// 这些本来就不依赖 Godot，搬来是为了让 stage 11 的纯内核和生产热路径共用同一
// 份定义。名字与作用域不变（namespace pk 全局），原有的非限定调用点照旧解析。
// 唯一的替换是 Math::sqrt → std::sqrt：两者都是 IEEE 正确舍入的 sqrtf，逐位相同
// （p1-psi 已在 30 日对拍上验证过这一替换是 bit-neutral）。

inline void wf_wrapped_delta(float ax, float ay, float bx, float by,
                             float wrap_width_x, float &dx, float &dy) {
    dx = bx - ax;
    dy = by - ay;
    if (wrap_width_x > 0.001f) {
        const float half = wrap_width_x * 0.5f;
        if (dx > half) {
            dx -= wrap_width_x;
        } else if (dx < -half) {
            dx += wrap_width_x;
        }
    }
}

inline float wf_smoothstep(float edge0, float edge1, float x) {
    float t = (x - edge0) / (edge1 - edge0);
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return t * t * (3.0f - 2.0f * t);
}

// Deterministic per-(cell,tick) hash → [0,1). Integer ops chosen to mirror GDScript exactly
// (32-bit wrap). Used to seed the synoptic eddy field ψ (Stage7). Same formula in field_solver.gd.
inline float wf_hash01(int cell, int tick) {
    uint32_t h = (uint32_t)cell * 374761393u + (uint32_t)tick * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= (h >> 16);
    return (float)(h & 0x00FFFFFFu) / (float)0x01000000u;
}

// Mirror weather_system.gd::_neighbor_average_vapor_idx (line 1314).
inline float wf_neighbor_average_vapor_idx(int idx, const int32_t *NB,
                                          const float *PV) {
    float sum_v = PV[idx];
    int   n     = 1;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        sum_v += PV[nb_idx];
        n += 1;
    }
    return sum_v / float(n);
}

// POD position variant of wf_neighbor_aligned_idx. Bit-identical to the
// godot::Vector2 version in world_ext_internal.h — same operation order, same
// sqrt — with the interleaved position array split into two float lanes so a
// worker-side kernel can call it. The Vector2 version delegates here.
inline int wf_neighbor_aligned_idx_xy(int idx, float dir_x, float dir_y,
                                      const float *POSX, const float *POSY,
                                      const int32_t *NB,
                                      int n_cells, float cell_pos_scale,
                                      float wrap_width_x) {
    if (idx < 0 || idx >= n_cells) return -1;
    const float dl2 = dir_x * dir_x + dir_y * dir_y;
    if (dl2 <= 0.0001f) return -1;
    const float inv_dl = 1.0f / std::sqrt(dl2);
    const float ndx = dir_x * inv_dl;
    const float ndy = dir_y * inv_dl;
    const float self_x = POSX[idx];
    const float self_y = POSY[idx];
    int   best_idx = -1;
    const float pos_scale = (cell_pos_scale > 0.001f) ? cell_pos_scale : 1.0f;
    float best_dot = pos_scale * 0.31176915f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float to_nb_x = 0.0f;
        float to_nb_y = 0.0f;
        wf_wrapped_delta(self_x, self_y, POSX[nb_idx], POSY[nb_idx],
                         wrap_width_x, to_nb_x, to_nb_y);
        const float dot = to_nb_x * ndx + to_nb_y * ndy;
        if (dot > best_dot) {
            best_dot = dot;
            best_idx = nb_idx;
        }
    }
    return best_idx;
}

// Mirror weather_system.gd::_is_water_terrain — bit-equal terrain enum check.
// OCEAN=0, COAST=1, LAKE=18, REEF=19, SEA_ICE=20, KELP=21 (terrain_type.gd).
inline bool wf_is_water_terrain(uint8_t t) {
    return t == 0 || t == 1 || t == 18 || t == 19 || t == 20 || t == 21;
}

// Mirror weather_system.gd::_vegetation_transpiration_factor. Veg ordinals from
// vegetation_type.gd VEG enum.
inline float wf_vegetation_transp_factor(uint8_t veg) {
    if (veg == 0) return 0.0f;                          // NONE
    if (veg == 14 || veg == 19 || veg == 20) return 1.0f;   // RAINFOREST/MANGROVE/SWAMP
    if (veg == 5 || veg == 7 || veg == 12) return 0.65f;    // TAIGA/DECIDUOUS/SUBTROPICAL
    if (veg == 9 || veg == 13 || veg == 21) return 0.35f;   // GRASSLAND/SAVANNA/MARSH
    return 0.18f;
}

// Mirror weather_system.gd::_avg_ocean_anomaly_at_idx.
// `TA` is per-cell `cell.temperature_transport_anomaly`.
inline float wf_avg_ocean_anomaly_at_idx(int idx, const uint8_t *TERR,
                                         const int32_t *NB, const float *TA) {
    if (wf_is_water_terrain(TERR[idx])) return TA[idx];
    float sum_an  = 0.0f;
    int   n_water = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        if (wf_is_water_terrain(TERR[nb_idx])) {
            sum_an += TA[nb_idx];
            n_water += 1;
        }
    }
    if (n_water == 0) return 0.0f;
    return sum_an / float(n_water);
}

// Mirror weather_system.gd::_evaporation_for_cell_idx.
inline float wf_evaporation_for_cell_idx(int idx, const uint8_t *TERR,
                                         const uint8_t *VEG,
                                         const uint8_t *HAS_RIV,
                                         const int32_t *NB,
                                         float temp, float moisture,
                                         float ocean_an, bool on_water,
                                         float field_ocean_evap_gain,
                                         float field_lake_evap_scale) {
    float evap = on_water ? 0.028f : 0.006f;
    if (TERR[idx] == 18) {
        evap *= field_lake_evap_scale;
    }
    const float excess_moist = moisture - 0.45f;
    if (excess_moist > 0.0f) evap += excess_moist * 0.018f;
    evap += wf_vegetation_transp_factor(VEG[idx]) * 0.012f;
    if (!on_water) {
        if (HAS_RIV[idx] != 0) evap += 0.012f;
        const int base = idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            if (wf_is_water_terrain(TERR[nb_idx])) {
                evap += 0.018f;
                break;
            }
        }
    }
    float ocean_mul = 1.0f + ocean_an * field_ocean_evap_gain;
    if (ocean_mul < 0.55f) ocean_mul = 0.55f;
    else if (ocean_mul > 1.85f) ocean_mul = 1.85f;
    float temp_mul = 0.35f + temp * 1.25f;
    if (temp_mul < 0.12f) temp_mul = 0.12f;
    else if (temp_mul > 1.35f) temp_mul = 1.35f;
    return evap * ocean_mul * temp_mul;
}

// Mirror weather_system.gd::_orographic_lift_from_upstream_idx.
inline float wf_orographic_lift_from_upstream_idx(int idx, int upstream_idx,
                                                  const float *ELEV) {
    if (upstream_idx < 0) return 0.0f;
    const float diff = ELEV[idx] - ELEV[upstream_idx];
    if (diff > 0.02f) {
        float v = diff * 2.2f;
        if (v > 1.0f) v = 1.0f;
        return v;
    }
    if (diff < -0.02f) {
        float v = diff * 1.6f;
        if (v < -1.0f) v = -1.0f;
        return v;
    }
    return 0.0f;
}

inline float wf_wind_speed_norm(float dir_x, float dir_y, float speed) {
    if (speed > 0.0001f) return speed;
    const float len2 = dir_x * dir_x + dir_y * dir_y;
    return (len2 > 0.0001f) ? std::sqrt(len2) : 0.0f;
}

// POD position variant of wf_upstream_vapor_idx_from_first.
inline float wf_upstream_vapor_idx_from_first_xy(
        int idx, int first_upstream_idx,
        const float *POSX, const float *POSY, const int32_t *NB,
        const float *PV, float wind_dx, float wind_dy,
        int n_cells, float cell_pos_scale, float wrap_width_x,
        int field_advect_steps) {
    if (first_upstream_idx < 0 || field_advect_steps <= 0) return PV[idx];
    int   current_idx = first_upstream_idx;
    float sum_v   = PV[current_idx];
    float weight  = 1.0f;
    float w_decay = 0.75f;
    for (int step = 1; step < field_advect_steps; ++step) {
        const int upstream_idx = wf_neighbor_aligned_idx_xy(
            current_idx, -wind_dx, -wind_dy, POSX, POSY, NB, n_cells,
            cell_pos_scale, wrap_width_x);
        if (upstream_idx < 0) break;
        sum_v   += PV[upstream_idx] * w_decay;
        weight  += w_decay;
        w_decay *= 0.75f;
        current_idx = upstream_idx;
    }
    return sum_v / weight;
}

// POD position variant of wf_wind_convergence_idx.
// ─── 邻域几何缓存版（bit-equal 加速变体）────────────────────────────────────
// 与上面三个逐位等价，只把热循环里每次重算的 self->nb wrapped delta 与
// 1/sqrt(dl2) 换成调用方预算的缓存 NB_DX/NB_DY/NB_INVD（n*6，dir 序）。
// NB_DX/NB_DY[base+d] == wf_wrapped_delta(self, POS[nb])（nb<0 处为 0）；
// NB_INVD[base+d] == 1/sqrt(dl2)（dl2<=1e-4 或 nb<0 处为 0 哨兵）。
inline int wf_neighbor_aligned_idx_cached(int idx, float dir_x, float dir_y,
                                          const int32_t *NB,
                                          const float *NB_DX, const float *NB_DY,
                                          int n_cells, float cell_pos_scale) {
    if (idx < 0 || idx >= n_cells) return -1;
    const float dl2 = dir_x * dir_x + dir_y * dir_y;
    if (dl2 <= 0.0001f) return -1;
    const float inv_dl = 1.0f / std::sqrt(dl2);
    const float ndx = dir_x * inv_dl;
    const float ndy = dir_y * inv_dl;
    int   best_idx = -1;
    const float pos_scale = (cell_pos_scale > 0.001f) ? cell_pos_scale : 1.0f;
    float best_dot = pos_scale * 0.31176915f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        const float dot = NB_DX[base + d] * ndx + NB_DY[base + d] * ndy;
        if (dot > best_dot) {
            best_dot = dot;
            best_idx = nb_idx;
        }
    }
    return best_idx;
}

inline float wf_upstream_vapor_idx_from_first_cached(
        int idx, int first_upstream_idx, const int32_t *NB,
        const float *NB_DX, const float *NB_DY, const float *PV,
        float wind_dx, float wind_dy, int n_cells, float cell_pos_scale,
        int field_advect_steps) {
    if (first_upstream_idx < 0 || field_advect_steps <= 0) return PV[idx];
    int   current_idx = first_upstream_idx;
    float sum_v   = PV[current_idx];
    float weight  = 1.0f;
    float w_decay = 0.75f;
    for (int step = 1; step < field_advect_steps; ++step) {
        const int upstream_idx = wf_neighbor_aligned_idx_cached(
            current_idx, -wind_dx, -wind_dy, NB, NB_DX, NB_DY, n_cells,
            cell_pos_scale);
        if (upstream_idx < 0) break;
        sum_v   += PV[upstream_idx] * w_decay;
        weight  += w_decay;
        w_decay *= 0.75f;
        current_idx = upstream_idx;
    }
    return sum_v / weight;
}

// ─── 风场辐合：有符号净流入 ─────────────────────────────────────────────────
//
// 旧实现（半波整流均值 `mean_d max(0, cos(self→nb, wind_nb))`）已在 W9 退役：
// 六角格 6 个等间隔方向上它恒在 0.29–1.25，**与风场有没有辐合无关** ——
// 均匀流（零辐散）实测读 0.3333。回归：tests/world/weather_convergence_metric_test.gd
//
// 现行口径：
//   w_d     = clamp(|v_nb| / 1.2, 0, 1.25)
//   inflow  = Σ_d max(0,  cos_in_d) · w_d
//   outflow = Σ_d max(0, -cos_in_d) · w_d
//   conv    = clamp((inflow - outflow) / (inflow + outflow), 0, 1)
//
// 均匀流 ⇒ 0；辐合中心 ⇒ 1；辐散 ⇒ 钳 0。输出 [0,1]，消费者阈值按此分布标定
// （p50≈0.016 / p90≈0.458 / p95≈0.636），见 docs/architecture/feature-guides.md。
inline float wf_wind_convergence_idx_xy(int idx,
                                            const float *POSX, const float *POSY,
                                            const int32_t *NB,
                                            const float *WX, const float *WY,
                                            const float *WSPD,
                                            float wrap_width_x) {
    const float self_x = POSX[idx];
    const float self_y = POSY[idx];
    float inflow = 0.0f;
    float outflow = 0.0f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float dx = 0.0f;
        float dy = 0.0f;
        wf_wrapped_delta(POSX[nb_idx], POSY[nb_idx], self_x, self_y,
                         wrap_width_x, dx, dy);
        const float dl2 = dx * dx + dy * dy;
        if (dl2 <= 0.0001f) continue;
        const float wx = WX[nb_idx];
        const float wy = WY[nb_idx];
        const float wl2 = wx * wx + wy * wy;
        if (wl2 <= 0.0001f) continue;
        const float inv_d = 1.0f / std::sqrt(dl2);
        const float inv_w = 1.0f / std::sqrt(wl2);
        const float cos_in = (dx * wx + dy * wy) * (inv_d * inv_w);
        const float wsp = (WSPD != nullptr)
            ? wf_wind_speed_norm(wx, wy, WSPD[nb_idx]) : std::sqrt(wl2);
        float speed_w = wsp / 1.2f;
        if (speed_w < 0.0f) speed_w = 0.0f;
        else if (speed_w > 1.25f) speed_w = 1.25f;
        if (cos_in > 0.0f) inflow += cos_in * speed_w;
        else outflow += -cos_in * speed_w;
    }
    const float denom = inflow + outflow;
    if (denom <= 1e-4f) return 0.0f;
    const float net = (inflow - outflow) / denom;
    if (net <= 0.0f) return 0.0f;
    return (net > 1.0f) ? 1.0f : net;
}

inline float wf_wind_convergence_idx_cached(
        int idx, const int32_t *NB,
        const float *NB_DX, const float *NB_DY, const float *NB_INVD,
        const float *WX, const float *WY, const float *WSPD) {
    float inflow = 0.0f;
    float outflow = 0.0f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        const float inv_d = NB_INVD[base + d];
        if (inv_d <= 0.0f) continue;          // dl2<=1e-4 哨兵
        // 与旧口径一致：dx,dy = self - nb = -(self->nb)。
        const float dx = -NB_DX[base + d];
        const float dy = -NB_DY[base + d];
        const float wx = WX[nb_idx];
        const float wy = WY[nb_idx];
        const float wl2 = wx * wx + wy * wy;
        if (wl2 <= 0.0001f) continue;
        const float inv_w = 1.0f / std::sqrt(wl2);
        const float cos_in = (dx * wx + dy * wy) * (inv_d * inv_w);
        const float wsp = (WSPD != nullptr)
            ? wf_wind_speed_norm(wx, wy, WSPD[nb_idx]) : std::sqrt(wl2);
        float speed_w = wsp / 1.2f;
        if (speed_w < 0.0f) speed_w = 0.0f;
        else if (speed_w > 1.25f) speed_w = 1.25f;
        if (cos_in > 0.0f) inflow += cos_in * speed_w;
        else outflow += -cos_in * speed_w;
    }
    const float denom = inflow + outflow;
    if (denom <= 1e-4f) return 0.0f;
    const float net = (inflow - outflow) / denom;
    if (net <= 0.0f) return 0.0f;
    return (net > 1.0f) ? 1.0f : net;
}

inline float wf_precip_terrain_damping_factor(uint8_t terrain) {
    // TerrainType.TERRAIN: HILL=5, SWAMP=10, JUNGLE=11, LAKE=18, DELTA=22.
    switch (terrain) {
        case 18: return 0.50f; // LAKE
        case 22: return 0.40f; // DELTA
        case 10: return 0.30f; // SWAMP
        case 11: return 0.0f;  // JUNGLE
        case 5:  return 0.0f;  // HILL
        default: return 0.0f;
    }
}

inline float wf_apply_precip_stability(uint8_t terrain, float precip,
                                       float wet_damp, float lake_damp,
                                       float soft_cap, float softness) {
    float out = precip;
    if (out < 0.0f) out = 0.0f;
    else if (out > 1.0f) out = 1.0f;
    const float factor = wf_precip_terrain_damping_factor(terrain);
    if (factor > 0.0f && out > 0.08f) {
        float damp = (terrain == 18) ? lake_damp : wet_damp;
        if (damp < 0.0f) damp = 0.0f;
        else if (damp > 1.0f) damp = 1.0f;
        out -= (out - 0.08f) * damp * factor;
    }
    if (soft_cap < 0.0f) soft_cap = 0.0f;
    else if (soft_cap > 1.0f) soft_cap = 1.0f;
    if (softness < 0.0f) softness = 0.0f;
    else if (softness > 1.0f) softness = 1.0f;
    if (soft_cap > 0.0f && out > soft_cap) {
        out = soft_cap + (out - soft_cap) * softness;
    }
    if (out < 0.0f) out = 0.0f;
    else if (out > 1.0f) out = 1.0f;
    return out;
}

// Cyclone thresholds were calibrated against the mean of inward components.
template <typename Delta>
inline float wf_cyclone_inward_wind(int idx, const int32_t *neighbors,
        const float *wind_x, const float *wind_y, const float *wind_speed,
        const Delta &delta) {
    float incoming = 0.0f;
    int checked = 0;
    for (int d = 0; d < 6; ++d) {
        const int neighbor = neighbors[idx * 6 + d];
        if (neighbor < 0) continue;
        float dx, dy;
        delta(neighbor, idx, dx, dy);
        const float dl2 = dx * dx + dy * dy;
        const float wx = wind_x[neighbor], wy = wind_y[neighbor];
        const float wl2 = wx * wx + wy * wy;
        if (dl2 <= 0.0001f || wl2 <= 0.0001f) continue;
        const float cosine = (dx * wx + dy * wy) *
            ((1.0f / std::sqrt(dl2)) * (1.0f / std::sqrt(wl2)));
        const float speed = wind_speed ? wf_wind_speed_norm(wx, wy, wind_speed[neighbor])
                                       : std::sqrt(wl2);
        incoming += std::max(0.0f, cosine) * std::clamp(speed / 1.2f, 0.20f, 1.25f);
        ++checked;
    }
    return checked > 0 ? std::min(1.0f, incoming / float(checked)) : 0.0f;
}

inline float wf_cyclone_inward_wind_xy(int idx, const float *pos_x, const float *pos_y,
        const int32_t *neighbors, const float *wind_x, const float *wind_y,
        const float *wind_speed, float wrap_width_x) {
    return wf_cyclone_inward_wind(idx, neighbors, wind_x, wind_y, wind_speed,
        [&](int from, int to, float &dx, float &dy) {
            wf_wrapped_delta(pos_x[from], pos_y[from], pos_x[to], pos_y[to],
                             wrap_width_x, dx, dy);
        });
}

// Mirror weather_system.gd::_classify_field_weather_core.
// WeatherType.WT: CLEAR=0 RAIN=1 STORM=2 BLIZZARD=3 DROUGHT=4 FOG=5 HEATWAVE=6
//                 MONSOON=7
inline bool wf_meets_precipitation_gate(float vapor, float cloud, float cloud_water,
                                         float precip, bool is_water, float gate) {
    const float cloud_gate = is_water ? 0.18f : 0.10f;
    const float vapor_gate = is_water ? 0.28f : 0.09f;
    return precip > gate && std::max(cloud, cloud_water * 1.25f) > cloud_gate &&
        std::max(cloud_water, precip * 0.70f) > cloud_gate * 0.35f &&
        vapor > vapor_gate;
}

inline uint8_t wf_classify_field_weather_at(float temp, float vapor, float cloud,
                                            float cloud_water, float precip,
                                            float instability, float ocean_an,
                                            float wind_speed, float temp_anom,
                                            float monsoon_flux,
                                            bool cold_precip_as_blizzard,
                                            float snow_classification_margin,
                                            bool is_water,
                                            float snow_cover,
                                            float gate_land = 0.040f,
                                            float gate_water = 0.032f) {
    const bool warm  = temp > 0.55f;
    const float humid_gate     = is_water ? 0.28f  : 0.09f;
    const float monsoon_vapor  = is_water ? 0.40f  : 0.14f;
    const float monsoon_precip = is_water ? 0.055f : 0.065f;
    const float monsoon_cloud  = is_water ? 0.45f  : 0.24f;
    const float fog_vapor      = is_water ? 0.22f  : 0.16f;
    const float fog_cloud      = is_water ? 0.085f : 0.10f;
    const bool humid = vapor > humid_gate;
    const float effective_cloud = (cloud > cloud_water * 1.25f) ? cloud : (cloud_water * 1.25f);
    const float precip_cloud_mass = (cloud_water > precip * 0.70f) ? cloud_water : (precip * 0.70f);
    // W4：两段门合成一段 —— 降水率 + 三项支持条件。旧实现里 `precip > precip_gate`
    // 是**无条件**通过的，等于「下一点就报雨」；这是「到处都是降水图标」的直接成因之一。
    // 门槛值来自 ClimateProfile（陆/水各一档），缺省保持旧的 0.040 / 0.032 以便回滚。
    const float precip_gate = is_water ? gate_water : gate_land;
    const bool meaningful_precip = wf_meets_precipitation_gate(
        vapor, cloud, cloud_water, precip, is_water, precip_gate);

    if (cold_precip_as_blizzard && meaningful_precip) {
        if (temp <= 0.24f)
            return 3; // BLIZZARD
        if (!is_water && snow_cover >= 0.25f &&
            temp < 0.31f + snow_classification_margin)
            return 3;
        if (temp < 0.31f + snow_classification_margin &&
            effective_cloud > 0.18f && vapor > 0.20f && precip > 0.04f &&
            wind_speed > 1.0f)
            return 3;
    }
    const bool warm_ocean_core = is_water && ocean_an > 0.05f &&
        instability > 0.64f && precip > 0.060f && effective_cloud > 0.24f &&
        precip_cloud_mass > 0.045f;
    // W4 补丁：STORM 与 MONSOON 一样必须过 meaningful_precip。旧逻辑里两者的判据比 RAIN 松，
    // 新门上线后出现「RAIN 2.7% / STORM 7.5% / MONSOON 5.7%」的倒挂 —— 中强度格被抢判成强天气。
    if (warm && humid && meaningful_precip &&
        ((instability > 0.70f && precip > 0.065f && precip_cloud_mass > 0.050f) ||
         warm_ocean_core))
        return 2; // STORM
    float monsoon_driver = wf_smoothstep(monsoon_vapor * 0.78f,
                                         monsoon_vapor + 0.06f, vapor) * 0.24f;
    if (monsoon_flux > monsoon_driver) monsoon_driver = monsoon_flux;
    const bool sustained_precip = precip > monsoon_precip * 0.82f &&
        precip_cloud_mass > monsoon_cloud * 0.38f;
    const float monsoon_flux_gate = is_water ? 0.08f : 0.13f;
    const bool inland_monsoon_plume = !is_water && vapor > 0.24f &&
        wind_speed > 0.75f && precip > monsoon_precip &&
        precip_cloud_mass > monsoon_cloud * 0.45f;
    const bool monsoon_flow_gate = monsoon_driver > monsoon_flux_gate ||
        inland_monsoon_plume;
    // W4 补丁：MONSOON 也必须先过 meaningful_precip。旧逻辑里它自成一档，判据比 RAIN 更松，
    // p80 门上线后出现「RAIN 2.6% / MONSOON 13.8%」的排序倒挂 —— 高强度格被抢判成热带暴雨。
    if (warm && meaningful_precip && sustained_precip &&
        effective_cloud > monsoon_cloud * 0.82f && monsoon_flow_gate)
        return 7; // MONSOON
    if (meaningful_precip)
        return 1; // RAIN
    if (vapor > fog_vapor && effective_cloud > fog_cloud && precip < 0.030f &&
        temp < 0.55f)
        return 5; // FOG
    if (!is_water && temp > 0.55f && temp_anom > 0.05f && precip < 0.006f &&
        effective_cloud < 0.18f)
        return 4; // DROUGHT
    // W6 补丁：热浪判据原来要求 `vapor < 0.12`（干空气），实测在暖区 154 个过云门的格子里
    // **没有一个** vapor < 0.12 ⇒ 该分支结构性不可达（实测 HEATWAVE 恒 0）。
    // 改成 `vapor > 0.12`：热浪 = 湿热，干旱 = 干热，用湿度把两者分开，两个分支都可达。
    if (!is_water && warm && temp_anom > 0.04f && precip < 0.012f &&
        effective_cloud < 0.30f && vapor > 0.12f)   // W6 校准：0.24 在 effective_cloud=max(cloud, cw*1.25) 下过紧（实测只出 5 格）
        return 6; // HEATWAVE
    return 0; // CLEAR
}

inline bool wf_is_precip_weather_type(uint8_t wt) {
    return wt == 1 || wt == 2 || wt == 3 || wt == 7;
}

// Mirror weather_system.gd::_field_intensity_for_type.
inline float wf_field_intensity_for_type(uint8_t wt, float temp, float vapor,
                                         float cloud, float precip,
                                         float instability, float ocean_an) {
    float v = 0.0f;
    switch (wt) {
        case 2: { // STORM
            const float m = (precip > instability) ? precip : instability;
            v = m * 0.82f + cloud * 0.18f;
            break;
        }
        case 7: // MONSOON
            v = precip * 0.72f + vapor * 0.18f + cloud * 0.18f;
            break;
        case 1: // RAIN
        case 3: // BLIZZARD
            v = precip * 1.15f + cloud * 0.20f;
            break;
        case 5: // FOG
            v = cloud * 0.75f + vapor * 0.20f;
            break;
        case 6: { // HEATWAVE
            float dry = 0.32f - vapor;
            if (dry < 0.0f) dry = 0.0f;
            v = (temp - 0.65f) * 2.2f + dry;
            break;
        }
        case 4: { // DROUGHT
            float oa = -ocean_an;
            if (oa < 0.0f) oa = 0.0f;
            v = (0.35f - vapor) * 2.0f + (0.16f - cloud) + oa * 0.6f;
            break;
        }
        default:
            return 0.0f;
    }
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

// Mirror weather_system.gd::_apply_frontal_convergence_boost fast-indexed path.
inline void wf_apply_frontal_convergence_boost_idx(
        int idx, const float *T, const float *AA, const int32_t *NB,
        float climate_anomaly, float convergence,
        float temp_self, float vapor, float ocean_an, float cloud_water,
        bool is_water, float precip_gate, float &cloud, float &precip,
        float &instability, uint8_t &wt, float &intensity) {
    constexpr float STORM_TEMP_DIFF = 0.28f;
    // W3：旧 0.45 是按 legacy 口径（p50=0.376）标的；net 口径 p95=0.636 ⇒ 0.64。
    constexpr float CONVERGENCE_THRESHOLD = 0.64f;
    if (convergence < CONVERGENCE_THRESHOLD) return;

    float t_min = temp_self;
    float t_max = temp_self;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float t_nb = T[nb_idx] + climate_anomaly + AA[nb_idx];
        if (t_nb < 0.0f) t_nb = 0.0f;
        else if (t_nb > 1.0f) t_nb = 1.0f;
        if (t_nb < t_min) t_min = t_nb;
        if (t_nb > t_max) t_max = t_nb;
    }

    const float temp_diff = t_max - t_min;
    float diff_score = temp_diff / STORM_TEMP_DIFF;
    if (diff_score < 0.0f) diff_score = 0.0f;
    else if (diff_score > 1.0f) diff_score = 1.0f;
    float frontal_score = ((convergence - CONVERGENCE_THRESHOLD)
            / (1.0f - CONVERGENCE_THRESHOLD)) * diff_score;
    if (frontal_score < 0.0f) frontal_score = 0.0f;
    else if (frontal_score > 1.0f) frontal_score = 1.0f;
    if (frontal_score < 0.45f) return;

    const float cloud_min = 0.25f + frontal_score * 0.20f;
    const float precip_min = 0.05f + frontal_score * 0.12f;
    const float inst_min = 0.25f + frontal_score * 0.15f;
    if (cloud < cloud_min) cloud = cloud_min;
    if (instability < inst_min) instability = inst_min;
    if (cloud > 1.0f) cloud = 1.0f;
    if (precip > 1.0f) precip = 1.0f;
    if (instability > 1.0f) instability = 1.0f;

    const float boosted_precip = std::max(precip, precip_min);
    if (wf_meets_precipitation_gate(vapor, cloud, cloud_water, boosted_precip,
                                    is_water, precip_gate)) {
        precip = boosted_precip;
        if (!wf_is_precip_weather_type(wt)) wt = 1; // RAIN
    }
    intensity = wf_field_intensity_for_type(
        wt, temp_self, vapor, cloud, precip, instability, ocean_an);
}
