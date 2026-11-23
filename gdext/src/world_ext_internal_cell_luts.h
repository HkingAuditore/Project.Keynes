#pragma once

#include <cmath>
#include <cstdint>

namespace pk {

// 共享内联 helper：q01_byte / q01_byte_ice 与 GDScript map_baker.gd::_q01_byte
// 完全 bit-equal（int(round(clampf(v, 0, 1) * 255))）。round 走 C++ std::round
// half-away-from-zero，与 GDScript round() 一致。

static inline int pk_q01_byte(double v) {
    if (v <= 0.0) return 0;
    if (v >= 1.0) return 255;
    int q = int(std::round(v * 255.0));
    if (q < 0) q = 0;
    else if (q > 255) q = 255;
    return q;
}

// _q01_byte_ice：fraction>0 时强制 byte≥1，让微量海冰也能 shader 触发可见。
static inline int pk_q01_byte_ice(double v) {
    if (v <= 0.0) return 0;
    if (v >= 1.0) return 255;
    // ceil 而非 round，保证 v>0 → byte≥1。
    int q = int(std::ceil(v * 255.0));
    if (q < 1) q = 1;
    else if (q > 255) q = 255;
    return q;
}

// 与 GDScript map_baker.gd::_dynamic_cell_signature 1:1 镜像
// （sea-ice-render-source-unify 阶段 C 修订）：
//   r=q01(temp), g=q01(moist), b=q01(snow)
//   A 通道双语义：
//     水格 (is_water=true)：a = q01_byte_ice(sea_ice_frac)
//     陆格 (is_water=false)：a = q01_byte(vit)
// 关键：判定"水格"必须用 is_water 语义（含 SEA_ICE 等所有非陆地），
// 不能用 passable_sea（SEA_ICE 因冰面阻断航行 passable_sea=false 但
// 视觉上仍是水域，A 通道必须写 ice_byte 让 shader 水路径渲染冰）。
inline uint32_t pk_atlas_sig_dynamic(double temp, double moist, double snow,
                                     double vit, double sea_ice_frac, bool is_water) {
    const int r = pk_q01_byte(temp);
    const int g = pk_q01_byte(moist);
    const int b = pk_q01_byte(snow);
    const int a = is_water ? pk_q01_byte_ice(sea_ice_frac) : pk_q01_byte(vit);
    return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (uint32_t(a) << 24);
}

// 与 GDScript map_baker.gd::_ecology_visual_signature / 本文件
// encode_ecology_visual_atlas（14399-14440 行）1:1 镜像。提炼成可复用 helper，
// 供 cell-index 间接寻址 LUT 路径（encode_cell_luts）与现有 fan-out 路径共用同一公式，
// 保证 eco_lut 与 ecology_visual_atlas bit-equivalent。
//   r=q01(foliage), g=q01(stress), b=transition_age(byte), a=q01(growth_damage)
inline uint32_t pk_atlas_sig_ecology(double temp, double moist, double snow,
                                     double vit, int veg_id, bool is_water,
                                     int transition_age, int prev_vit_byte,
                                     int veg_none) {
    auto smoothstep = [](double e0, double e1, double x) {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        double t = (x - e0) / (e1 - e0);
        if (t < 0.0) t = 0.0;
        else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };
    auto clamp01 = [](double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); };
    const double vitality = clamp01(vit);
    const double m = clamp01(moist);
    const double t = clamp01(temp);
    const double sn = clamp01(snow);
    double foliage = 0.0;
    if (!is_water && veg_id != veg_none) {
        const double cold_loss = (1.0 - smoothstep(0.02, 0.18, t)) * 0.55;
        const double snow_loss = smoothstep(0.12, 0.75, sn) * 0.70;
        const double dry_loss = (1.0 - smoothstep(0.05, 0.35, m)) * 0.45;
        foliage = clamp01(vitality * 0.72 + m * 0.28 - cold_loss - snow_loss - dry_loss);
    }
    double stress = 0.0;
    if (!is_water) {
        const double dryness = 1.0 - m;
        const double heat_stress = smoothstep(0.72, 0.95, t);
        const double cold_stress = 1.0 - smoothstep(0.03, 0.20, t);
        const double vit_stress = 1.0 - vitality;
        const double a1 = dryness * 0.70;
        const double a2 = (heat_stress > cold_stress ? heat_stress : cold_stress) * 0.65;
        const double a3 = (a1 > a2 ? a1 : a2);
        stress = clamp01(a3 + vit_stress * 0.45);
    }
    const double vit_delta = (double(pk_q01_byte(vitality)) - double(prev_vit_byte)) / 255.0;
    const double growth = clamp01(0.5 + vit_delta * 5.0 + (foliage - 0.5) * 0.12 - stress * 0.10);
    const int r = pk_q01_byte(foliage);
    const int g = pk_q01_byte(stress);
    int b = transition_age;
    if (b < 0) b = 0;
    else if (b > 255) b = 255;
    const int a = pk_q01_byte(growth);
    return uint32_t(r) | (uint32_t(g) << 8) | (uint32_t(b) << 16) | (uint32_t(a) << 24);
}

} // namespace pk
