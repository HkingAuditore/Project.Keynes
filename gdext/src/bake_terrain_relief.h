#pragma once

// 分地形细节法线（沟谷 / 台坎 / 沙丘 / 起伏 / 丘状凹凸）的烘焙实现。
// 这些量只依赖生成期的高度场、格子地形与地貌，运行期不变，所以在 visual tile
// 烘焙时逐 texel 求出，shader 只做一次采样。
//
// 输出按波长分两段：粗段（波长 >= RELIEF_SPLIT_WL）与细段。运行期按缩放分别淡出，
// 代替原先逐倍频按屏幕像素波长淡出；烘焙侧只按 texel 波长淡出（防栅格混叠）。
//
// 坡度单位与 shader 一致：返回的 detail 是对 "法线 xy / z" 空间的偏移（已取负号），
// 运行期直接加到粗法线的 xy/z 上再归一化。
//
// 纯函数、只读输入，可在并行行循环里直接调用。哈希与 shader 侧 hash21 同式（float 精度）。

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pk_relief {

constexpr int B_OCEAN = 0, B_COAST = 1, B_PLAIN = 2, B_GRASSLAND = 3, B_FOREST = 4,
        B_HILL = 5, B_MOUNTAIN = 6, B_DESERT = 7, B_TUNDRA = 8, B_SNOW = 9, B_SWAMP = 10,
        B_JUNGLE = 11, B_SAVANNA = 12, B_TAIGA = 13, B_STEPPE = 14, B_SHRUBLAND = 15,
        B_MANGROVE = 16, B_GLACIER = 17, B_LAKE = 18, B_REEF = 19, B_SEA_ICE = 20,
        B_KELP = 21, B_DELTA = 22, B_OASIS = 23, B_SALT_FLAT = 24, B_BADLANDS = 25,
        B_COLD_DESERT = 26, B_CHAPARRAL = 27, B_MOOR = 28, B_FLOODPLAIN = 29, B_MESA = 30;
constexpr int LF_BADLANDS = 10, LF_PLATEAU = 13, LF_RIFT_VALLEY = 14, LF_CANYON = 15;

constexpr float GULLY_BASE_WL = 128.0f;
constexpr float GULLY_FULL_SLOPE = 0.30f;
constexpr float PHASOR_NORM = 0.45f;
constexpr float CREST_ROUND = 0.22f;
constexpr float STRATA_THICKNESS = 0.012f;
constexpr float STRATA_RISER = 0.45f;
constexpr float STRATA_MIN_SPACING_HEX = 0.40f;
// 粗 / 细两段的分界波长（世界单位，terrain_erosion_world_size = 72 时）。
constexpr float RELIEF_SPLIT_WL = 32.0f;
// 编码：v -> sign(v)·sqrt(|v|/RANGE)，小坡度保留更多 8-bit 精度。shader 侧同值解码。
constexpr float RELIEF_ENCODE_RANGE = 3.0f;

inline bool is_water(int b) {
    return b == B_OCEAN || b == B_COAST || b == B_LAKE || b == B_REEF || b == B_KELP ||
            b == B_SEA_ICE;
}

struct Profile {
    float gully, gully_wl, sharp, strata, dune, rolling, hummock;
};

inline Profile profile_for(int b) {
    //                                   gully  wl     sharp  strata dune   rolling hummock
    if (b == B_MOUNTAIN) return {0.42f, 64.0f, 0.70f, 0.00f, 0.0f, 0.00f, 0.05f};
    if (b == B_MESA) return {0.20f, 56.0f, 0.35f, 0.60f, 0.0f, 0.03f, 0.03f};
    if (b == B_BADLANDS) return {0.52f, 30.0f, 0.85f, 0.28f, 0.0f, 0.00f, 0.02f};
    if (b == B_HILL) return {0.22f, 84.0f, 0.10f, 0.00f, 0.0f, 0.26f, 0.06f};
    if (b == B_DESERT) return {0.00f, 64.0f, 0.00f, 0.00f, 0.30f, 0.03f, 0.00f};
    if (b == B_COLD_DESERT) return {0.12f, 56.0f, 0.50f, 0.10f, 0.12f, 0.04f, 0.05f};
    if (b == B_SALT_FLAT) return {0.00f, 64.0f, 0.00f, 0.00f, 0.00f, 0.01f, 0.02f};
    if (b == B_TUNDRA) return {0.06f, 72.0f, 0.20f, 0.00f, 0.00f, 0.05f, 0.09f};
    if (b == B_SNOW || b == B_GLACIER) return {0.10f, 96.0f, 0.00f, 0.00f, 0.06f, 0.05f, 0.00f};
    if (b == B_SHRUBLAND || b == B_CHAPARRAL) return {0.10f, 64.0f, 0.40f, 0.04f, 0.00f, 0.09f, 0.06f};
    if (b == B_GRASSLAND || b == B_STEPPE || b == B_SAVANNA)
        return {0.05f, 96.0f, 0.00f, 0.00f, 0.00f, 0.09f, 0.03f};
    if (b == B_FOREST || b == B_TAIGA || b == B_JUNGLE || b == B_MANGROVE)
        return {0.06f, 80.0f, 0.00f, 0.00f, 0.00f, 0.05f, 0.11f};
    if (b == B_SWAMP || b == B_MOOR) return {0.00f, 64.0f, 0.00f, 0.00f, 0.00f, 0.02f, 0.05f};
    if (b == B_PLAIN) return {0.02f, 110.0f, 0.0f, 0.00f, 0.00f, 0.07f, 0.02f};
    if (b == B_DELTA || b == B_FLOODPLAIN || b == B_OASIS)
        return {0.00f, 64.0f, 0.00f, 0.00f, 0.00f, 0.03f, 0.01f};
    return {0.04f, 80.0f, 0.00f, 0.00f, 0.00f, 0.06f, 0.03f};
}

// 近景高度细节法线的 biome 因子（原 shader terrain_detail_factor）。
inline float height_detail_factor(int b) {
    if (b == B_MOUNTAIN || b == B_MESA) return 0.70f;
    if (b == B_HILL || b == B_BADLANDS) return 0.55f;
    if (b == B_TUNDRA) return 0.28f;
    if (b == B_DESERT || b == B_SALT_FLAT || b == B_COLD_DESERT) return 0.22f;
    if (b == B_SNOW || b == B_GLACIER || b == B_SEA_ICE) return 0.22f;
    if (b == B_FOREST || b == B_JUNGLE || b == B_TAIGA || b == B_MANGROVE) return 0.28f;
    if (b == B_GRASSLAND || b == B_SAVANNA || b == B_STEPPE || b == B_SHRUBLAND ||
            b == B_CHAPARRAL)
        return 0.18f;
    if (b == B_PLAIN || b == B_SWAMP || b == B_MOOR || b == B_DELTA || b == B_FLOODPLAIN ||
            b == B_OASIS)
        return 0.08f;
    return 0.18f;
}

inline float landform_is_layered(int lf) {
    return (lf == LF_PLATEAU || lf == LF_CANYON || lf == LF_RIFT_VALLEY) ? 1.0f : 0.0f;
}

inline float clampf(float x, float a, float b) { return std::max(a, std::min(b, x)); }
inline float mixf(float a, float b, float t) { return a + (b - a) * t; }
inline float fractf(float x) { return x - std::floor(x); }
inline float modf_glsl(float x, float y) { return x - y * std::floor(x / y); }
inline float smoothstepf(float e0, float e1, float x) {
    const float t = clampf((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float hash21(float px, float py) {
    px = fractf(px * 234.34f);
    py = fractf(py * 435.345f);
    const float d = px * (px + 34.23f) + py * (py + 34.23f);
    px += d;
    py += d;
    return fractf(px * py);
}

// 世界坐标 → 格坐标；x 方向格数取整到 wrap 周期，经线环绕无缝。wx 须已折叠到 [0, period)。
inline void cell_coord(float wx, float wy, float cell_size, float wrap_period,
        float &px, float &py, float &period_cells) {
    period_cells = 0.0f;
    if (wrap_period > 0.0001f) {
        period_cells = std::max(1.0f, std::floor(wrap_period / cell_size + 0.5f));
        const float cell_w = wrap_period / period_cells;
        px = wx / cell_w;
        py = wy / cell_w;
        return;
    }
    px = wx / cell_size;
    py = wy / cell_size;
}

inline float value_noise(float px, float py, float period) {
    const float ix = std::floor(px), iy = std::floor(py);
    const float fx = px - ix, fy = py - iy;
    const float ux = fx * fx * (3.0f - 2.0f * fx), uy = fy * fy * (3.0f - 2.0f * fy);
    float x0 = ix, x1 = ix + 1.0f;
    if (period > 0.5f) {
        x0 = modf_glsl(x0, period);
        x1 = modf_glsl(x1, period);
    }
    const float a = hash21(x0, iy), b = hash21(x1, iy);
    const float c = hash21(x0, iy + 1.0f), d = hash21(x1, iy + 1.0f);
    return mixf(mixf(a, b, ux), mixf(c, d, ux), uy);
}

// 返回 v ∈ [-1, 1] 与 ∂v/∂p。
inline void value_noise_d(float px, float py, float period, float &v, float &gx, float &gy) {
    const float ix = std::floor(px), iy = std::floor(py);
    const float fx = px - ix, fy = py - iy;
    const float ux = fx * fx * (3.0f - 2.0f * fx), uy = fy * fy * (3.0f - 2.0f * fy);
    const float dux = 6.0f * fx * (1.0f - fx), duy = 6.0f * fy * (1.0f - fy);
    float x0 = ix, x1 = ix + 1.0f;
    if (period > 0.5f) {
        x0 = modf_glsl(x0, period);
        x1 = modf_glsl(x1, period);
    }
    const float a = hash21(x0, iy), b = hash21(x1, iy);
    const float c = hash21(x0, iy + 1.0f), d = hash21(x1, iy + 1.0f);
    const float k = a - b - c + d;
    const float val = a + (b - a) * ux + (c - a) * uy + k * ux * uy;
    v = val * 2.0f - 1.0f;
    gx = dux * ((b - a) + k * uy) * 2.0f;
    gy = duy * ((c - a) + k * ux) * 2.0f;
}

// Phacelle 式归一化相量噪声。dir 为相位变化方向（条纹沿其垂直方向延伸）。
// harm2 > 0 叠二次谐波得不对称锯齿剖面。返回 h 与 ∂h/∂p（省略 2π 因子）。
inline void phasor(float px, float py, float dirx, float diry, float period, float harm2,
        float &h, float &gx, float &gy) {
    const float ipx = std::floor(px), ipy = std::floor(py);
    const float fpx = px - ipx, fpy = py - ipy;
    float ax = 0.0f, ay = 0.0f, wsum = 0.0f;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            float cx = ipx + float(i);
            const float cy = ipy + float(j);
            if (period > 0.5f) cx = modf_glsl(cx, period);
            const float hx = hash21(cx, cy);
            const float hy = hash21(cx + 17.31f, cy + 41.77f);
            const float dx = fpx - float(i) - 0.5f - (hx - 0.5f) * 0.5f;
            const float dy = fpy - float(j) - 0.5f - (hy - 0.5f) * 0.5f;
            const float w = std::max(0.0f, std::exp(-(dx * dx + dy * dy) * 2.0f) - 0.0439f);
            const float ph = (dx * dirx + dy * diry) * 6.2831853f;
            ax += std::cos(ph) * w;
            ay += std::sin(ph) * w;
            wsum += w;
        }
    }
    float vx = ax / std::max(wsum, 1e-4f), vy = ay / std::max(wsum, 1e-4f);
    const float vl = std::max(std::sqrt(vx * vx + vy * vy), 1.0f - PHASOR_NORM);
    vx /= vl;
    vy /= vl;
    const float c = vx, s = vy;
    const float s2 = 2.0f * s * c;
    const float c2 = c * c - s * s;
    h = c - harm2 * s2;
    const float dd = -s - 2.0f * harm2 * c2;
    gx = dd * dirx;
    gy = dd * diry;
}

struct Inputs {
    float wx = 0.0f, wy = 0.0f;  // 已折叠到 [0, wrap_period) 的世界坐标
    float nc_x = 0.0f, nc_y = 0.0f, nc_z = 1.0f;  // 粗法线（含运行期粗法线强度）
    float elev = 0.0f;
    float sea_level = 0.64f;
    float flow_gx = 0.0f, flow_gy = 0.0f, flow_mean = 0.0f;  // ~1 格半径平滑高程梯度 / 均值
    Profile P{};
    float lf_layered = 0.0f, lf_bad = 0.0f;  // 层状 / 荒地地貌权重（格心插值）
    float hex_size = 1.0f;
    float height_scale_hex = 2.10f;
    float texel_world = 1.0f;
    float wrap_period = 0.0f;
    float world_scale = 1.0f;  // terrain_erosion_world_size / 72
    float strength = 1.0f;     // terrain_erosion_strength
};

struct Output {
    float coarse_x = 0.0f, coarse_y = 0.0f;
    float fine_x = 0.0f, fine_y = 0.0f;
    float crease = 0.0f;
};

// 波长在烘焙栅格上不足 ~2-4 texel 的层无法表示，按 texel 淡出（防混叠）。
inline float texel_lod(float wl, float texel_world) {
    return smoothstepf(2.0f, 4.0f, wl / std::max(texel_world, 1e-4f));
}

inline Output evaluate(const Inputs &in) {
    Output out;
    const float inv_nz = 1.0f / std::max(in.nc_z, 0.2f);
    const float grad_x = -in.nc_x * inv_nz, grad_y = -in.nc_y * inv_nz;
    const float slope = std::sqrt(grad_x * grad_x + grad_y * grad_y);
    const float land_h = clampf((in.elev - in.sea_level) / std::max(1.0f - in.sea_level, 0.001f),
            0.0f, 1.0f);
    const float slope_gate = smoothstepf(0.015f, 0.10f, slope);

    Profile P = in.P;
    // 坡度补强：林地也可以长在山上，沟谷由宏观坡度连续驱动。
    P.gully = std::max(P.gully, 0.40f * smoothstepf(0.05f, 0.35f, slope));
    P.sharp = std::max(P.sharp, 0.70f * smoothstepf(0.12f, 0.45f, slope));
    P.rolling = std::max(P.rolling,
            0.12f * smoothstepf(0.02f, 0.10f, slope) * (1.0f - smoothstepf(0.15f, 0.35f, slope)));
    // 地貌补强。
    const float layered = in.lf_layered * slope_gate;
    const float bad = in.lf_bad * slope_gate;
    P.strata = std::max(P.strata, 0.55f * layered);
    P.gully = std::max(P.gully, 0.46f * bad);
    P.sharp = std::max(P.sharp, 0.80f * bad);
    P.strata = std::max(P.strata, 0.22f * bad);

    P.gully *= in.strength;
    P.strata *= in.strength;
    P.dune *= in.strength;
    P.rolling *= in.strength;
    P.hummock *= in.strength;

    const float scale = in.world_scale;
    const float split_wl = RELIEF_SPLIT_WL * scale;
    const float flow_to_slope = in.height_scale_hex * in.hex_size;
    float cx = 0.0f, cy = 0.0f, fx = 0.0f, fy = 0.0f;
    auto add = [&](float wl, float gx, float gy) {
        if (wl >= split_wl) {
            cx += gx;
            cy += gy;
        } else {
            fx += gx;
            fy += gy;
        }
    };

    // ① 顺坡沟谷。
    const float gully_amp = P.gully * clampf(slope / GULLY_FULL_SLOPE, 0.25f, 1.0f) *
            mixf(0.6f, 1.0f, smoothstepf(0.0f, 0.12f, land_h));
    if (gully_amp > 0.002f) {
        float fp_x, fp_y, flow_period;
        cell_coord(in.wx, in.wy, 288.0f * scale, in.wrap_period, fp_x, fp_y, flow_period);
        const float ffx = value_noise(fp_x, fp_y, flow_period) * 2.0f - 1.0f;
        const float ffy = value_noise(fp_x, fp_y + 57.0f, flow_period) * 2.0f - 1.0f;
        const float gdir_x = in.flow_gx * flow_to_slope + ffx * 0.03f;
        const float gdir_y = in.flow_gy * flow_to_slope + ffy * 0.03f;
        const float band_c = std::log2(GULLY_BASE_WL / std::max(P.gully_wl, 1.0f));
        float wl = GULLY_BASE_WL * scale;
        float h_sum = 0.0f, h_norm = 0.0f, steer_x = 0.0f, steer_y = 0.0f;
        for (int o = 0; o < 5; ++o) {
            const float lod = texel_lod(wl, in.texel_world);
            if (lod <= 0.0f) break;
            const float of = float(o);
            const float amp = (of <= band_c) ? std::exp2(-(band_c - of) * 1.5f)
                                             : std::exp2(-(of - band_c));
            if (amp < 0.03f) {
                wl *= 0.5f;
                continue;
            }
            const float dir_len = std::sqrt(gdir_x * gdir_x + gdir_y * gdir_y);
            float sx = steer_x * gully_amp, sy = steer_y * gully_amp;
            const float sl = std::sqrt(sx * sx + sy * sy);
            if (sl > dir_len) {
                sx *= dir_len / sl;
                sy *= dir_len / sl;
            }
            const float gdx = gdir_x + sx * 0.35f, gdy = gdir_y + sy * 0.35f;
            const float gl = std::sqrt(gdx * gdx + gdy * gdy);
            float dir_x = 1.0f, dir_y = 0.0f;
            if (gl > 1e-4f) {
                dir_x = gdy / gl;
                dir_y = -gdx / gl;
            }
            float px, py, cells_x;
            cell_coord(in.wx, in.wy, wl, in.wrap_period, px, py, cells_x);
            px += float(o * 17);
            py += float(o * 29);
            float nh, ngx, ngy;
            phasor(px, py, dir_x, dir_y, cells_x, 0.0f, nh, ngx, ngy);
            const float ha = std::sqrt(nh * nh + CREST_ROUND * CREST_ROUND);
            const float hs = mixf(nh, 1.0f - 2.0f * ha, P.sharp);
            const float gsx = mixf(ngx, -2.0f * (nh / ha) * ngx, P.sharp);
            const float gsy = mixf(ngy, -2.0f * (nh / ha) * ngy, P.sharp);
            add(wl, gsx * amp * lod * gully_amp, gsy * amp * lod * gully_amp);
            steer_x += ngx * amp * lod;
            steer_y += ngy * amp * lod;
            h_sum += hs * amp * lod;
            h_norm += amp * lod;
            wl *= 0.5f;
        }
        out.crease = (h_norm > 0.0f)
                ? clampf(-h_sum / h_norm, 0.0f, 1.0f) * std::min(1.0f, gully_amp * 2.5f)
                : 0.0f;
    }

    // ② 层状台坎：沿平滑等高线的平台 + 陡坎。
    const float strata_amp = P.strata;
    const float elev_grad = std::sqrt(in.flow_gx * in.flow_gx + in.flow_gy * in.flow_gy);
    if (strata_amp > 0.002f && slope > 0.004f && elev_grad > 1e-6f) {
        float wp_x, wp_y, wob_period;
        cell_coord(in.wx, in.wy, 160.0f * scale, in.wrap_period, wp_x, wp_y, wob_period);
        const float wob = value_noise(wp_x, wp_y, wob_period) * 2.0f - 1.0f;
        const float min_spacing = std::max(3.0f * in.texel_world,
                STRATA_MIN_SPACING_HEX * in.hex_size);
        const float spacing = STRATA_THICKNESS / elev_grad;
        const float level = std::max(0.0f, std::log2(min_spacing / spacing));
        const float l0 = std::floor(level);
        const float lt = level - l0;
        const float base = in.flow_mean / STRATA_THICKNESS + wob * 0.35f;
        float tp_mix = 0.0f;
        for (int li = 0; li < 2; ++li) {
            const float s = base / std::exp2(l0 + float(li));
            const float x = clampf((fractf(s) - (1.0f - STRATA_RISER)) / STRATA_RISER, 0.0f, 1.0f);
            const float tp = 6.0f * x * (1.0f - x) / STRATA_RISER;
            tp_mix += (tp - 1.0f) * ((li == 0) ? (1.0f - lt) : lt);
        }
        const float lod = 1.0f - smoothstepf(3.0f, 4.0f, level);
        const float k = tp_mix * flow_to_slope * strata_amp * lod;
        cx += in.flow_gx * k;
        cy += in.flow_gy * k;
    }

    // ③ 沙丘：风向随超大尺度噪声缓慢转动。
    const float dune_amp = P.dune;
    if (dune_amp > 0.002f) {
        float wi_x, wi_y, wind_period;
        cell_coord(in.wx, in.wy, 900.0f * scale, in.wrap_period, wi_x, wi_y, wind_period);
        const float wa = 0.65f + (value_noise(wi_x, wi_y, wind_period) - 0.5f) * 2.2f;
        const float wdx = std::cos(wa), wdy = std::sin(wa);
        float wl = 44.0f * scale;
        float amp = 1.0f;
        for (int o = 0; o < 2; ++o) {
            const float lod = texel_lod(wl, in.texel_world);
            if (lod <= 0.0f) break;
            float px, py, cells_x;
            cell_coord(in.wx, in.wy, wl, in.wrap_period, px, py, cells_x);
            px += float(o * 23);
            py += float(o * 11);
            float nh, ngx, ngy;
            phasor(px, py, wdx, wdy, cells_x, (o == 0) ? 0.45f : 0.30f, nh, ngx, ngy);
            add(wl, ngx * amp * lod * dune_amp, ngy * amp * lod * dune_amp);
            amp *= 0.35f;
            wl *= 0.28f;
        }
    }

    // ④ 宽缓起伏。
    const float rolling_amp = P.rolling;
    if (rolling_amp > 0.002f) {
        float wl = 150.0f * scale;
        float amp = 1.0f;
        for (int o = 0; o < 2; ++o) {
            const float lod = texel_lod(wl, in.texel_world);
            if (lod <= 0.0f) break;
            float px, py, cells_x;
            cell_coord(in.wx, in.wy, wl, in.wrap_period, px, py, cells_x);
            px += float(o * 31 + 5);
            py += float(o * 13 + 7);
            float v, gx, gy;
            value_noise_d(px, py, cells_x, v, gx, gy);
            add(wl, gx * amp * lod * rolling_amp, gy * amp * lod * rolling_amp);
            amp *= 0.5f;
            wl *= 0.5f;
        }
    }

    // ⑤ 丘状凹凸：平方把起伏收成圆顶小丘。
    const float hummock_amp = P.hummock;
    if (hummock_amp > 0.002f) {
        float wl = 16.0f * scale;
        float amp = 1.0f;
        for (int o = 0; o < 2; ++o) {
            const float lod = texel_lod(wl, in.texel_world);
            if (lod <= 0.0f) break;
            float px, py, cells_x;
            cell_coord(in.wx, in.wy, wl, in.wrap_period, px, py, cells_x);
            px += float(o * 19 + 3);
            py += float(o * 37 + 1);
            float v, gx, gy;
            value_noise_d(px, py, cells_x, v, gx, gy);
            const float k = 2.0f * std::max(v, 0.0f) * amp * lod * hummock_amp;
            add(wl, gx * k, gy * k);
            amp *= 0.5f;
            wl *= 0.5f;
        }
    }

    // detail_grad 在 shader 里是从法线 xy/z 中减去的量。
    out.coarse_x = -cx;
    out.coarse_y = -cy;
    out.fine_x = -fx;
    out.fine_y = -fy;
    return out;
}

inline uint8_t encode_slope(float v) {
    const float e = std::sqrt(std::min(std::fabs(v) / RELIEF_ENCODE_RANGE, 1.0f));
    const float s = (v < 0.0f) ? -e : e;
    return uint8_t(std::max(0, std::min(255, int(std::lround((s * 0.5f + 0.5f) * 255.0f)))));
}

}  // namespace pk_relief
