#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <functional>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif


#include "world_ext_internal.h"

namespace pk {

using namespace godot;

// ─── Detail scatter（vegetation-visual-pcg 阶段 A）──────────────────────────
// 植被/点缀散布的 per-instance 热循环 + MultiMesh buffer 组装。纯 buffer-encoder：
// 只读 knobs 内 flat PackedArray，不触 _slots / _bound。逐位复刻
// shrub_layer.gd 的 _try_append_instance / _candidate_position /
// _world_noise_suitability / _world_micro_gap / _hash01 / _value_noise2 /
// _is_water_position（world_to_cube→offset 栅格）/ _is_river_body_position（flow 双线性）。
godot::Dictionary DCWorldExt::encode_detail_scatter(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["path"] = String("gdscript");
    out["instance_count"] = 0;
    out["elapsed_ms"] = -1.0;
    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const double hex_size = double(knobs.get("hex_size", 22.0));
    if (hex_size <= 0.0) return fail("bad hex_size");
    const float origin_x = float(knobs.get("origin_x", 0.0));
    const float origin_y = float(knobs.get("origin_y", 0.0));
    const float bsize_x = float(knobs.get("size_x", 1.0));
    const float bsize_y = float(knobs.get("size_y", 1.0));
    const float wrap_period_x = float(knobs.get("wrap_period_x", 0.0));
    const float wrap_edge_margin = float(knobs.get("wrap_edge_margin", 0.0));
    const int grid_w = int(knobs.get("grid_w", 0));
    const int grid_h = int(knobs.get("grid_h", 0));
    const float river_clear = float(knobs.get("river_clear_threshold", 0.5));
    const float spawn_radius_factor = float(knobs.get("spawn_radius_factor", 0.78));
    const float warp_strength = float(knobs.get("world_noise_warp_strength", 0.2));
    const float patch_freq = float(knobs.get("patch_frequency", 0.095));
    const float patch_cutoff = float(knobs.get("patch_cutoff", 0.31));
    const float patch_contrast = float(knobs.get("patch_contrast", 2.15));
    const float mid_mix = float(knobs.get("world_noise_mid_mix", 0.38));
    const float fine_mix = float(knobs.get("world_noise_fine_mix", 0.10));
    const float micro_gap = float(knobs.get("micro_gap_threshold", 0.12));
    const float wn_acceptance = float(knobs.get("world_noise_acceptance", 1.10));
    const float min_size = float(knobs.get("min_size_factor", 0.095));
    const float max_size = float(knobs.get("max_size_factor", 0.19));
    const float size_scale = float(knobs.get("size_scale", 1.0));
    const float dead_thr = float(knobs.get("vitality_dead_threshold", 0.12));
    const float dieback = float(knobs.get("vitality_dieback_noise_strength", 0.45));
    const int instance_cap = int(knobs.get("instance_cap", 0));
    const int flow_w = int(knobs.get("flow_w", 0));
    const int flow_h = int(knobs.get("flow_h", 0));
    const int spawn_domain = int(knobs.get("spawn_domain", 0)); // 0 land, 1 water, 2 any
    const int rotation_mode = int(knobs.get("rotation_mode", 0)); // 0 random, 1 upright, 2 upright jitter
    const double rotation_strength = std::max(0.0, std::min(1.0, double(knobs.get("random_rotation_strength", 1.0))));
    const double upright_jitter_rad = std::max(0.0, std::min(0.610865238, double(knobs.get("upright_jitter_radians", 0.104719755))));

    PackedInt32Array keys = knobs.get("keys", PackedInt32Array());
    PackedInt32Array cell_indices_in = knobs.get("cell_indices", PackedInt32Array());
    PackedFloat32Array cx = knobs.get("center_x", PackedFloat32Array());
    PackedFloat32Array cy = knobs.get("center_y", PackedFloat32Array());
    PackedFloat32Array suit = knobs.get("suitability", PackedFloat32Array());
    PackedInt32Array att = knobs.get("attempts", PackedInt32Array());
    PackedFloat32Array vit = knobs.get("vitality", PackedFloat32Array());
    PackedFloat32Array sized = knobs.get("size_density", PackedFloat32Array());
    PackedFloat32Array cr = knobs.get("color_r", PackedFloat32Array());
    PackedFloat32Array cg = knobs.get("color_g", PackedFloat32Array());
    PackedFloat32Array cb = knobs.get("color_b", PackedFloat32Array());
    PackedFloat32Array ca = knobs.get("color_a", PackedFloat32Array());
    PackedByteArray offw = knobs.get("offset_is_water", PackedByteArray());
    PackedFloat32Array flow = knobs.get("flow_buffer", PackedFloat32Array());

    const int K = keys.size();
    if (K <= 0) return fail("no active cells");
    if (cell_indices_in.size() < K || cx.size() < K || cy.size() < K || suit.size() < K || att.size() < K ||
        vit.size() < K || sized.size() < K || cr.size() < K || cg.size() < K ||
        cb.size() < K || ca.size() < K) {
        return fail("per-cell array size mismatch");
    }
    if (instance_cap <= 0) return fail("zero instance cap");

    const int32_t *KEY = keys.ptr();
    const int32_t *CELL_IN = cell_indices_in.ptr();
    const float *CX = cx.ptr();
    const float *CY = cy.ptr();
    const float *SU = suit.ptr();
    const int32_t *AT = att.ptr();
    const float *VI = vit.ptr();
    const float *SD = sized.ptr();
    const float *CR = cr.ptr();
    const float *CG = cg.ptr();
    const float *CB = cb.ptr();
    const float *CA = ca.ptr();
    const uint8_t *OFFW = offw.ptr();
    const int offw_n = offw.size();
    const float *FLOW = flow.ptr();
    const int flow_n = flow.size();

    const double TAU = 6.283185307179586;

    auto hash01 = [](int64_t idx, int64_t salt) -> double {
        double x = std::sin(double(idx * 127 + salt * 311) * 12.9898) * 43758.5453123;
        return x - std::floor(x);
    };
    auto hash2i = [](int64_t x, int64_t y, int64_t salt) -> double {
        int64_t n = x * 374761393 + y * 668265263 + salt * 1442695041;
        n = (n ^ (n >> 13)) * 1274126177;
        n = n ^ (n >> 16);
        return double(n & 0x00ffffff) / double(0x01000000);
    };
    auto value_noise2 = [&](double x, double y, int64_t salt) -> double {
        int64_t ix = (int64_t)std::floor(x);
        int64_t iy = (int64_t)std::floor(y);
        double fx = x - double(ix);
        double fy = y - double(iy);
        double sx = fx * fx * (3.0 - 2.0 * fx);
        double sy = fy * fy * (3.0 - 2.0 * fy);
        double a = hash2i(ix, iy, salt);
        double b = hash2i(ix + 1, iy, salt);
        double c = hash2i(ix, iy + 1, salt);
        double d = hash2i(ix + 1, iy + 1, salt);
        double ab = a + (b - a) * sx;
        double cd = c + (d - c) * sx;
        return ab + (cd - ab) * sy;
    };
    auto clampd = [](double v, double lo, double hi) -> double { return v < lo ? lo : (v > hi ? hi : v); };
    auto lerpd = [](double a, double b, double t) -> double { return a + (b - a) * t; };
    auto posmodd = [](double v, double m) -> double {
        if (m <= 0.0) {
            return v;
        }
        double r = std::fmod(v, m);
        return r < 0.0 ? r + m : r;
    };
    auto smoothstep = [&](double e0, double e1, double v) -> double {
        double t = clampd((v - e0) / (e1 - e0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    };

    // _is_water_position：world_to_cube → cube_round → cube_to_offset(odd-r) → 栅格。
    const double SQRT3 = std::sqrt(3.0);
    auto world_is_water = [&](double px, double py) -> bool {
        double q_f = (SQRT3 / 3.0 * px - 1.0 / 3.0 * py) / hex_size;
        double r_f = (2.0 / 3.0 * py) / hex_size;
        double s_f = -q_f - r_f;
        int64_t rq = (int64_t)std::llround(q_f);
        int64_t rr = (int64_t)std::llround(r_f);
        int64_t rs = (int64_t)std::llround(s_f);
        double dq = std::fabs(double(rq) - q_f);
        double dr = std::fabs(double(rr) - r_f);
        double ds = std::fabs(double(rs) - s_f);
        if (dq > dr && dq > ds) {
            rq = -rr - rs;
        } else if (dr > ds) {
            rr = -rq - rs;
        }
        int64_t col = rq + (rr - (rr & 1)) / 2;
        int64_t row = rr;
        if (row < 0 || row >= grid_h) {
            return true;
        }
        col = (col % grid_w + grid_w) % grid_w;
        int64_t gi = row * (int64_t)grid_w + col;
        if (gi < 0 || gi >= offw_n) {
            return true;
        }
        return OFFW[gi] != 0;
    };

    // _is_river_body_position：flow_buffer 双线性（derived_size），>= 阈值即拒绝。
    auto river_body = [&](double px, double py) -> bool {
        if (flow_n <= 0 || flow_w <= 0 || flow_h <= 0) {
            return false;
        }
        double sample_x = (wrap_period_x > 0.0001f) ? posmodd(px, (double)wrap_period_x) : px;
        double u = (bsize_x < 0.001) ? 0.5 : (sample_x - origin_x) / bsize_x;
        double v = (bsize_y < 0.001) ? 0.5 : (py - origin_y) / bsize_y;
        u = clampd(u, 0.0, 1.0);
        v = clampd(v, 0.0, 1.0);
        double fx = u * double(flow_w - 1);
        double fy = v * double(flow_h - 1);
        int x0 = (int)std::floor(fx);
        if (x0 < 0) x0 = 0; else if (x0 > flow_w - 1) x0 = flow_w - 1;
        int y0 = (int)std::floor(fy);
        if (y0 < 0) y0 = 0; else if (y0 > flow_h - 1) y0 = flow_h - 1;
        int x1 = x0 + 1; if (x1 > flow_w - 1) x1 = flow_w - 1;
        int y1 = y0 + 1; if (y1 > flow_h - 1) y1 = flow_h - 1;
        double tx = fx - double(x0);
        double ty = fy - double(y0);
        int64_t i11 = (int64_t)y1 * flow_w + x1;
        if (i11 >= flow_n) {
            return false;
        }
        double v00 = FLOW[(int64_t)y0 * flow_w + x0];
        double v10 = FLOW[(int64_t)y0 * flow_w + x1];
        double v01 = FLOW[(int64_t)y1 * flow_w + x0];
        double v11 = FLOW[i11];
        double a0 = lerpd(v00, v10, tx);
        double a1 = lerpd(v01, v11, tx);
        return lerpd(a0, a1, ty) >= river_clear;
    };

    auto world_noise_suit = [&](double px, double py) -> double {
        double hs = (hex_size > 1.0) ? hex_size : 1.0;
        double pxn = px / hs;
        double pyn = py / hs;
        double wx = (value_noise2(pxn * patch_freq * 0.55, pyn * patch_freq * 0.55, 313) - 0.5) * 7.0;
        double wy = (value_noise2(pxn * patch_freq * 0.55, pyn * patch_freq * 0.55, 719) - 0.5) * 7.0;
        double coarse = value_noise2((pxn + wx) * patch_freq, (pyn + wy) * patch_freq, 17);
        double mid = value_noise2(pxn * patch_freq * 3.1 + 19.0, pyn * patch_freq * 3.1 - 11.0, 41);
        double fine = value_noise2(pxn * patch_freq * 8.5 - 37.0, pyn * patch_freq * 8.5 + 23.0, 83);
        double patch = smoothstep(patch_cutoff, 1.0, coarse);
        patch = std::pow(patch, (double)patch_contrast);
        patch *= lerpd(1.0, lerpd(0.55, 1.35, mid), mid_mix);
        patch *= lerpd(1.0, lerpd(0.82, 1.18, fine), fine_mix);
        return clampd(patch, 0.0, 1.0);
    };
    auto world_micro_gap = [&](double px, double py, int64_t key, int64_t attempt) -> double {
        double hs = (hex_size > 1.0) ? hex_size : 1.0;
        double pxn = px / hs;
        double pyn = py / hs;
        double cont = value_noise2(pxn * 0.82 + 23.0, pyn * 0.82 - 17.0, 131);
        double dith = hash01(key, 9900 + attempt * 19);
        return clampd(cont * 0.72 + dith * 0.28, 0.0, 1.0);
    };

    // 候选累积（按 score 排序后取 instance_cap）。
    struct Inst {
        int32_t cell_idx;
        float px, py, rot, size, seed, variant, score;
        float r, g, b, a;
    };
    std::vector<Inst> insts;
    insts.reserve((size_t)instance_cap * 2);

    auto t0 = std::chrono::high_resolution_clock::now();

    const double min_sz = (double)min_size;
    const double max_sz = (double)max_size;
    for (int c = 0; c < K; ++c) {
        const int64_t key = (int64_t)KEY[c];
        const int32_t cell_idx = CELL_IN[c];
        const double center_x = (double)CX[c];
        const double center_y = (double)CY[c];
        const double cell_suit = (double)SU[c];
        const int attempts = AT[c];
        const double vitality = (double)VI[c];
        const double size_density = clampd((double)SD[c], 0.0, 1.0);
        const double base_r = (double)CR[c];
        const double base_g = (double)CG[c];
        const double base_b = (double)CB[c];
        const double base_a = (double)CA[c];
        for (int attempt = 0; attempt < attempts; ++attempt) {
            if (vitality <= dead_thr) {
                double dn = hash01(key, 931 + attempt);
                if (dn < 1.0 - (double)dieback) {
                    continue;
                }
            }
            // _candidate_position
            double angle = std::fmod(hash01(key, 101) + double(attempt) * 0.61803398875, 1.0);
            if (angle < 0.0) angle += 1.0;
            angle *= TAU;
            double radius = std::sqrt(hash01(key, 200 + attempt * 37)) * hex_size * (double)spawn_radius_factor;
            double bpx = center_x + std::cos(angle) * radius;
            double bpy = center_y + std::sin(angle) * radius;
            double wnx = (value_noise2(bpx * 0.033, bpy * 0.033, 911) - 0.5);
            double wny = (value_noise2(bpx * 0.033, bpy * 0.033, 977) - 0.5);
            double px = bpx + wnx * (hex_size * (double)warp_strength);
            double py = bpy + wny * (hex_size * (double)warp_strength);

            const bool pos_is_water = world_is_water(px, py);
            if (spawn_domain == 0 && pos_is_water) {
                continue;
            }
            if (spawn_domain == 1 && !pos_is_water) {
                continue;
            }
            if (spawn_domain != 1 && river_body(px, py)) {
                continue;
            }
            double wn = world_noise_suit(px, py);
            if (wn <= 0.001) {
                continue;
            }
            double micro = world_micro_gap(px, py, key, attempt);
            if (micro < (double)micro_gap) {
                continue;
            }
            double noise_gate = std::pow(clampd(wn, 0.0, 1.0), 1.35);
            double local_acc = clampd(cell_suit * (double)wn_acceptance * noise_gate, 0.0, 1.0);
            if (hash01(key, 9300 + attempt) > local_acc) {
                continue;
            }
            double variant = hash01(key, 300 + attempt);
            double size = hex_size * lerpd(min_sz, max_sz, hash01(key, 400 + attempt));
            size *= lerpd(0.85, 1.12, size_density);
            size *= (double)size_scale;
            double rot = hash01(key, 500 + attempt) * TAU;
            if (rotation_mode == 1) {
                rot = 0.0;
            } else if (rotation_mode == 2) {
                rot = (hash01(key, 501 + attempt) * 2.0 - 1.0) * upright_jitter_rad;
            } else if (rotation_strength < 0.999) {
                rot = (hash01(key, 501 + attempt) * 2.0 - 1.0) * 3.14159265358979323846 * rotation_strength;
            }
            double seed = hash01(key, 600 + attempt);
            double score = wn * 0.66 + cell_suit * 0.27 + hash01(key, 7600 + attempt) * 0.07;

            // _base_color_for_state：variant 明暗微调。
            double shade = (variant - 0.5) * 0.16;
            double rr2 = base_r, gg2 = base_g, bb2 = base_b;
            if (shade >= 0.0) {
                rr2 = base_r + (1.0 - base_r) * shade;
                gg2 = base_g + (1.0 - base_g) * shade;
                bb2 = base_b + (1.0 - base_b) * shade;
            } else {
                double f = 1.0 + shade;  // = 1 - (-shade)
                rr2 = base_r * f;
                gg2 = base_g * f;
                bb2 = base_b * f;
            }

            Inst it;
            it.cell_idx = cell_idx;
            it.px = (float)px;
            it.py = (float)py;
            it.rot = (float)rot;
            it.size = (float)size;
            it.seed = (float)seed;
            it.variant = (float)variant;
            it.score = (float)score;
            it.r = (float)rr2;
            it.g = (float)gg2;
            it.b = (float)bb2;
            it.a = (float)base_a;
            insts.push_back(it);
        }
    }

    int n_total = (int)insts.size();
    int n_keep = n_total < instance_cap ? n_total : instance_cap;
    if (n_keep <= 0) {
        out["fallback"] = false;
        out["path"] = String("gdext");
        out["instance_count"] = 0;
        out["buffer"] = PackedFloat32Array();
        auto t1e = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1e - t0).count();
        return out;
    }
    if (n_total > instance_cap) {
        std::nth_element(insts.begin(), insts.begin() + (instance_cap - 1), insts.end(),
                         [](const Inst &a, const Inst &b) { return a.score > b.score; });
    }

    std::vector<Inst> draw_insts;
    draw_insts.reserve((size_t)n_keep + 32);
    const bool wrap_edges = wrap_period_x > 0.0001f && wrap_edge_margin > 0.0f;
    for (int i = 0; i < n_keep; ++i) {
        const Inst &it = insts[i];
        draw_insts.push_back(it);
        if (!wrap_edges) {
            continue;
        }
        if (it.px <= wrap_edge_margin) {
            Inst copy = it;
            copy.px += wrap_period_x;
            draw_insts.push_back(copy);
        }
        if (it.px >= wrap_period_x - wrap_edge_margin) {
            Inst copy = it;
            copy.px -= wrap_period_x;
            draw_insts.push_back(copy);
        }
    }

    const int n_draw = (int)draw_insts.size();

    // MultiMesh 2D buffer：每实例 16 float（transform 8 + color 4 + custom 4）。
    PackedFloat32Array buffer;
    PackedInt32Array cell_indices;
    buffer.resize((int64_t)n_draw * 16);
    cell_indices.resize(n_draw);
    float *BUF = buffer.ptrw();
    int32_t *CELL_IDX = cell_indices.ptrw();
    const double inv_sx = (bsize_x > 0.001) ? (1.0 / (double)bsize_x) : 0.0;
    const double inv_sy = (bsize_y > 0.001) ? (1.0 / (double)bsize_y) : 0.0;
    for (int i = 0; i < n_draw; ++i) {
        const Inst &it = draw_insts[i];
        CELL_IDX[i] = it.cell_idx;
        double cs = std::cos((double)it.rot) * (double)it.size;
        double sn = std::sin((double)it.rot) * (double)it.size;
        // x_axis = (cs, sn); y_axis = (-sn, cs); origin = (px, py)
        int64_t b = (int64_t)i * 16;
        BUF[b + 0] = (float)cs;          // columns[0][0] = x_axis.x
        BUF[b + 1] = (float)(-sn);       // columns[1][0] = y_axis.x
        BUF[b + 2] = 0.0f;
        BUF[b + 3] = it.px;              // columns[2][0] = origin.x
        BUF[b + 4] = (float)sn;          // columns[0][1] = x_axis.y
        BUF[b + 5] = (float)cs;          // columns[1][1] = y_axis.y
        BUF[b + 6] = 0.0f;
        BUF[b + 7] = it.py;              // columns[2][1] = origin.y
        BUF[b + 8] = it.r;
        BUF[b + 9] = it.g;
        BUF[b + 10] = it.b;
        BUF[b + 11] = it.a;
        double sample_x = (wrap_period_x > 0.0001f) ? posmodd((double)it.px, (double)wrap_period_x) : (double)it.px;
        double uvx = clampd((sample_x - origin_x) * inv_sx, 0.0, 1.0);
        double uvy = clampd(((double)it.py - origin_y) * inv_sy, 0.0, 1.0);
        BUF[b + 12] = (float)uvx;
        BUF[b + 13] = (float)uvy;
        BUF[b + 14] = it.seed;
        BUF[b + 15] = it.variant;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["fallback"] = false;
    out["path"] = String("gdext");
    out["instance_count"] = n_draw;
    out["candidate_count"] = n_total;
    out["wrap_edge_copy_count"] = n_draw - n_keep;
    out["buffer"] = buffer;
    out["cell_indices"] = cell_indices;
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    return out;
}


godot::Dictionary DCWorldExt::encode_detail_scatter_delta(godot::Dictionary knobs) {
    godot::Dictionary out = encode_detail_scatter(knobs);
    if (!bool(out.get("fallback", true))) {
        out["path"] = godot::String("gdext_delta");
    }
    return out;
}

} // namespace pk
