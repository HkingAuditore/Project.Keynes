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

} // namespace pk
