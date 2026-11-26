#include "runtime_climate_passes.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace pk {
namespace pk_async_climate {

// ─── stage 11 WEATHER：ψ 整步推进 ───────────────────────────────────────────
//
// 这里是 ψ 推进的唯一实现。搬过来之前生产热路径里内联了一份、
// DCWorldExt::run_synoptic_advance_pass 里另有一份，两份的 damp / diffuse 默认值
// 不同，且只有内联版带斜压振幅饱和与阈值清零 —— 也就是说"提取出的内核该等价于
// 哪一份"没有答案。以内联版为准合成一份，因为跑在生产热路径上的是它。
void synoptic_advance_pure(int n_cells,
                           const int32_t *neighbor_indices,
                           const float *pos_x,
                           const float *pos_y,
                           const float *wind_x,
                           const float *wind_y,
                           const float *temp_norm,
                           const SynopticAdvanceKnobs &knobs,
                           std::vector<float> &psi,
                           std::vector<float> &psi_prev) {
    if (n_cells <= 0 || neighbor_indices == nullptr || pos_x == nullptr ||
        pos_y == nullptr || wind_x == nullptr || wind_y == nullptr ||
        temp_norm == nullptr) {
        return;
    }
    if (psi.size() != (size_t)n_cells) psi.assign((size_t)n_cells, 0.0f);
    psi_prev = psi;                                     // 整步快照（脱离切片）
    float * const __restrict PSI_W = psi.data();
    const float * const __restrict PSI_R = psi_prev.data();
    const int32_t * const __restrict NB = neighbor_indices;
    const float * const __restrict WX = wind_x;
    const float * const __restrict WY = wind_y;
    const float * const __restrict TR = temp_norm;

    int adv_cells = knobs.adv_cells;
    if (adv_cells < 0) adv_cells = 0;
    else if (adv_cells > 16) adv_cells = 16;

    pk::parallel_for_range("pk_weather_synoptic", n_cells, 0, 2048, [&](int begin, int end) {
        for (int p = begin; p < end; ++p) {
            const int pb = p * 6;
            // 平滑引导流：风邻域平均（去地转风小尺度切变→平移连贯，不打散）
            float gx = WX[p], gy = WY[p];
            int gn = 1;
            for (int d = 0; d < 6; ++d) {
                const int nb = NB[pb + d];
                if (nb < 0) continue;
                gx += WX[nb]; gy += WY[nb]; ++gn;
            }
            gx /= float(gn); gy /= float(gn);
            // 半拉格朗日真平移：沿 -引导流走 adv_cells 格取 departure 的 ψ_prev
            int dep = p;
            for (int s = 0; s < adv_cells; ++s) {
                const int up = wf_neighbor_aligned_idx_xy(
                    dep, -gx, -gy, pos_x, pos_y, NB, n_cells,
                    knobs.cell_pos_scale, knobs.wrap_width_x);
                if (up < 0 || up >= n_cells) break;
                dep = up;
            }
            float ps = PSI_R[dep];
            // 斜压门：邻域温度梯度
            float tmn = TR[p], tmx = TR[p];
            for (int d = 0; d < 6; ++d) {
                const int nb = NB[pb + d];
                if (nb < 0) continue;
                const float tv = TR[nb];
                if (tv < tmn) tmn = tv;
                if (tv > tmx) tmx = tv;
            }
            const float g = wf_smoothstep(0.04f, 0.16f, tmx - tmn);
            const float aps0 = ps < 0.0f ? -ps : ps;
            // 斜压增长随振幅饱和→有界，不会全场饱和
            ps *= (1.0f + knobs.baroclinic * g * (1.0f - aps0));
            const float sr = knobs.seed_rate * (0.30f + 0.70f * g);
            if (wf_hash01(p, knobs.tick) < sr)
                ps += knobs.seed_amp * (wf_hash01(p + 50021, knobs.tick) - 0.5f) * 2.0f;
            ps += (wf_neighbor_average_vapor_idx(p, NB, PSI_R) - ps) * knobs.diffuse;
            ps *= knobs.damp;
            if (ps > 1.0f) ps = 1.0f; else if (ps < -1.0f) ps = -1.0f;
            // 阈值清零→防低值 ψ 经扩散/平流铺满全场，保稀疏移动涡旋
            if (ps < 0.05f && ps > -0.05f) ps = 0.0f;
            PSI_W[p] = ps;
        }
    });
}

// ─── stage 11 WEATHER：field solve 主循环（纯内核）──────────────────────────
//
// 循环体是从 DCWorldExt::run_weather_field_solve_pass 原样搬过来的，只把原先解析
// 到 DCWorldExt 成员或 Dictionary 查找的名字换成结构体字段（见
// tools/runtime/extract_weather_kernel.py 里的替换表）。数值语句一行未改。



// 邻域几何缓存：self->nb 的 wrapped delta 与 1/sqrt(dl2)。原来内联在 solve pass 里，
// 与主循环的 wf_wrapped_delta / sqrt 同序同式，所以缓存命中与否 bit-equal。
void weather_field_geometry_cache_pure(int n_cells,
                                       const int32_t *neighbor_indices,
                                       const float *pos_x,
                                       const float *pos_y,
                                       float wrap_width_x,
                                       float *geom_dx,
                                       float *geom_dy,
                                       float *geom_invd) {
    if (n_cells <= 0 || neighbor_indices == nullptr || pos_x == nullptr ||
        pos_y == nullptr || geom_dx == nullptr || geom_dy == nullptr ||
        geom_invd == nullptr) {
        return;
    }
    for (int p = 0; p < n_cells; ++p) {
        const int b = p * 6;
        const float sx = pos_x[p];
        const float sy = pos_y[p];
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = neighbor_indices[b + d];
            if (nb_idx < 0) {
                geom_dx[b + d] = 0.0f;
                geom_dy[b + d] = 0.0f;
                geom_invd[b + d] = 0.0f;
                continue;
            }
            float dx = 0.0f, dy = 0.0f;
            wf_wrapped_delta(sx, sy, pos_x[nb_idx], pos_y[nb_idx],
                             wrap_width_x, dx, dy);
            geom_dx[b + d] = dx;
            geom_dy[b + d] = dy;
            const float dl2 = dx * dx + dy * dy;
            geom_invd[b + d] = (dl2 > 0.0001f) ? (1.0f / std::sqrt(dl2)) : 0.0f;
        }
    }
}

} // namespace pk_async_climate
} // namespace pk
