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

godot::Dictionary DCWorldExt::encode_detail_scatter_delta(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    PackedInt32Array sample_indices = knobs.get("sample_cell_indices", PackedInt32Array());
    if (sample_indices.size() > 0) {
        auto t0 = std::chrono::high_resolution_clock::now();
        Dictionary out;
        out["fallback"] = true;
        out["path"] = String("gdscript");
        out["instance_count"] = 0;
        out["elapsed_ms"] = -1.0;
        auto fail = [&](const char *why) -> Dictionary {
            out["reason"] = String(why);
            return out;
        };

        PackedFloat32Array pos_x = knobs.get("cell_pos_x", PackedFloat32Array());
        PackedFloat32Array pos_y = knobs.get("cell_pos_y", PackedFloat32Array());
        PackedFloat32Array temp_arr = knobs.get("temp_arr", PackedFloat32Array());
        PackedFloat32Array moist_arr = knobs.get("moisture_arr", PackedFloat32Array());
        PackedFloat32Array snow_arr = knobs.get("snow_cover_arr", PackedFloat32Array());
        PackedFloat32Array weather_int_arr = knobs.get("weather_intensity_arr", PackedFloat32Array());
        PackedFloat32Array vitality_arr = knobs.get("vegetation_vitality_arr", PackedFloat32Array());
        PackedFloat32Array heat_arr = knobs.get("vegetation_heat_stress_arr", PackedFloat32Array());
        PackedFloat32Array drought_arr = knobs.get("vegetation_drought_stress_arr", PackedFloat32Array());
        PackedFloat32Array cold_arr = knobs.get("vegetation_cold_stress_arr", PackedFloat32Array());
        PackedFloat32Array elev_arr = knobs.get("elevation_arr", PackedFloat32Array());
        PackedFloat32Array soil_arr = knobs.get("soil_moisture_arr", PackedFloat32Array());
        PackedFloat32Array discharge_arr = knobs.get("river_discharge_arr", PackedFloat32Array());
        PackedFloat32Array wind_arr = knobs.get("wind_speed_arr", PackedFloat32Array());
        PackedByteArray landform_arr = knobs.get("landform_arr", PackedByteArray());
        PackedByteArray veg_arr = knobs.get("vegetation_arr", PackedByteArray());
        PackedByteArray cover_arr = knobs.get("cover_arr", PackedByteArray());
        PackedByteArray weather_type_arr = knobs.get("weather_type_arr", PackedByteArray());
        PackedByteArray is_water_arr = knobs.get("is_water_arr", PackedByteArray());
        PackedByteArray has_river_arr = knobs.get("has_river_arr", PackedByteArray());
        PackedFloat32Array ideal_t = knobs.get("veg_ideal_temp", PackedFloat32Array());
        PackedFloat32Array ideal_m = knobs.get("veg_ideal_moist", PackedFloat32Array());
        PackedFloat32Array tol_t = knobs.get("veg_temp_tol", PackedFloat32Array());
        PackedFloat32Array tol_m = knobs.get("veg_moist_tol", PackedFloat32Array());
        PackedFloat32Array veg_biomass = knobs.get("veg_biomass", PackedFloat32Array());

        const int n_pos = std::min(pos_x.size(), pos_y.size());
        if (n_pos <= 0) return fail("missing_native_sampling_positions");

        const double hex_size = double(knobs.get("hex_size", 22.0));
        if (hex_size <= 0.0) return fail("bad hex_size");
        const int detail_kind = int(knobs.get("detail_kind", 0));
        const int spawn_domain = int(knobs.get("spawn_domain", 0));
        const int max_per_cell = std::max(0, int(knobs.get("max_per_cell", 1)));
        const double quality_density = std::max(0.0, double(knobs.get("quality_density_scale", 1.0)));
        const double river_edge_density = double(knobs.get("river_edge_density", 0.85));
        const double river_valley_boost = double(knobs.get("river_valley_boost", 1.25));
        const double biomass_floor = double(knobs.get("biomass_floor", 0.30));
        const double biomass_ceil = double(knobs.get("biomass_ceil", 1.30));
        const double biomass_exponent = std::max(0.01, double(knobs.get("biomass_exponent", 1.0)));
        const double moisture_corridor_boost = double(knobs.get("moisture_corridor_boost", 0.65));
        const double vitality_patch_boost = double(knobs.get("vitality_patch_boost", 0.55));
        const double stress_hide_strength = double(knobs.get("stress_hide_strength", 0.78));
        const double snow_hide_strength = double(knobs.get("snow_hide_strength", 0.62));
        const double vitality_dead = double(knobs.get("vitality_dead_threshold", 0.12));
        const double vitality_sparse = double(knobs.get("vitality_sparse_threshold", 0.36));
        const double vitality_healthy = double(knobs.get("vitality_healthy_threshold", 0.72));
        const double vitality_density_power = double(knobs.get("vitality_density_power", 1.35));
        const double vitality_alpha_power = double(knobs.get("vitality_alpha_power", 1.10));
        const bool color_override = bool(knobs.get("base_color_override_enabled", false));
        const double override_r = double(knobs.get("base_color_r", 0.18));
        const double override_g = double(knobs.get("base_color_g", 0.39));
        const double override_b = double(knobs.get("base_color_b", 0.19));
        const double override_a = double(knobs.get("base_color_a", 0.88));
        Dictionary veg_over = knobs.get("vegetation_weight_overrides", Dictionary());
        Dictionary land_over = knobs.get("landform_weight_overrides", Dictionary());
        Dictionary cover_over = knobs.get("cover_weight_overrides", Dictionary());

        auto clampd = [](double v, double lo, double hi) -> double { return v < lo ? lo : (v > hi ? hi : v); };
        auto lerpd = [](double a, double b, double t) -> double { return a + (b - a) * t; };
        auto smoothstep = [&](double e0, double e1, double v) -> double {
            double t = clampd((v - e0) / (e1 - e0), 0.0, 1.0);
            return t * t * (3.0 - 2.0 * t);
        };
        auto f32_at = [](const PackedFloat32Array &arr, int idx, double fb) -> double {
            return (idx >= 0 && idx < arr.size()) ? double(arr[idx]) : fb;
        };
        auto u8_at = [](const PackedByteArray &arr, int idx, int fb) -> int {
            return (idx >= 0 && idx < arr.size()) ? int(arr[idx]) : fb;
        };
        auto is_water_lf = [](int lf) -> bool { return lf >= 0 && lf <= 3; };
        auto override_weight = [](Dictionary dict, int key, double fallback) -> double {
            if (dict.has(key)) return double(dict.get(key, fallback));
            String key_s(std::to_string(key).c_str());
            if (dict.has(key_s)) return double(dict.get(key_s, fallback));
            return fallback;
        };
        auto climate_compat = [&](int veg, double temp, double moist) -> double {
            if (veg >= 0 && veg < ideal_t.size() && veg < ideal_m.size() && veg < tol_t.size() && veg < tol_m.size()) {
                double dt = (temp - double(ideal_t[veg])) / std::max(double(tol_t[veg]), 0.01);
                double dm = (moist - double(ideal_m[veg])) / std::max(double(tol_m[veg]), 0.01);
                return std::exp(-0.5 * (dt * dt + dm * dm));
            }
            return 1.0;
        };
        auto vitality_norm = [&](double vitality) -> double {
            const double dead = std::min(vitality_dead, vitality_healthy - 0.001);
            const double healthy = std::max(vitality_healthy, dead + 0.001);
            return clampd((clampd(vitality, 0.0, 1.0) - dead) / (healthy - dead), 0.0, 1.0);
        };
        // 绝对生物量 → 密度乘子（镜像 shrub_layer.gd::_biomass_factor）。
        auto biomass_factor = [&](int veg) -> double {
            const double b = (veg >= 0 && veg < veg_biomass.size())
                ? clampd(double(veg_biomass[veg]), 0.0, 1.0)
                : 1.0;
            return lerpd(biomass_floor, biomass_ceil, std::pow(b, biomass_exponent));
        };
        // 河流格密度系数（镜像 shrub_layer.gd::_river_density_factor）。
        auto river_density_factor = [&](double temp, double moist, double soil) -> double {
            const double wet = std::max(moist, soil);
            const double warm_wet = smoothstep(0.35, 0.72, temp) * smoothstep(0.28, 0.62, wet);
            const double lush = std::max(river_edge_density, river_valley_boost);
            return lerpd(river_edge_density, lush, warm_wet);
        };
        auto climate_presence = [&](double moisture, double snow, double vitality, double heat, double drought, double cold, int wt, double wi) -> double {
            if (wt == 4 || wt == 6) {
                drought = std::max(drought, wi * 0.65);
                heat = std::max(heat, wi * 0.52);
            } else if (wt == 3) {
                snow = std::max(snow, wi * 0.85);
                cold = std::max(cold, wi * 0.62);
            } else if (wt == 1 || wt == 2 || wt == 7) {
                moisture = clampd(moisture + wi * 0.20, 0.0, 1.0);
            }
            const double dry = clampd(std::max(drought, std::max(heat * 0.78, (0.34 - moisture) * 1.9)), 0.0, 1.0);
            const double snow_hide = clampd(std::max(snow, cold * 0.55), 0.0, 1.0);
            double presence = std::pow(vitality_norm(vitality), vitality_alpha_power);
            presence *= 1.0 - dry * stress_hide_strength;
            presence *= 1.0 - snow_hide * snow_hide_strength;
            return clampd(presence, 0.0, 1.0);
        };
        auto scatter_presence = [&](int cover, double moisture, double snow, double vitality, double heat, double drought, double cold, int wt, double wi) -> double {
            if (spawn_domain == 1) {
                if (cover == 2 || cover == 3) return 0.0;
                return 1.0;
            }
            return climate_presence(moisture, snow, vitality, heat, drought, cold, wt, wi);
        };
        auto vitality_density = [&](double vitality) -> double {
            vitality = clampd(vitality, 0.0, 1.0);
            if (vitality <= vitality_dead) return 0.0;
            const double normalized = vitality_norm(vitality);
            const double sparse = lerpd(0.10, 0.62, smoothstep(vitality_dead, std::max(vitality_sparse, vitality_dead + 0.001), vitality));
            const double healthy = lerpd(0.62, 1.20, std::pow(normalized, vitality_density_power));
            return vitality < vitality_sparse ? std::min(sparse, healthy) : healthy;
        };
        auto ecology_bias = [&](double moisture, double vitality) -> double {
            const double wet = smoothstep(0.46, 0.82, moisture) * moisture_corridor_boost;
            const double vit = vitality_norm(vitality) * vitality_patch_boost;
            return clampd(0.68 + wet * 0.26 + vit * 0.30, 0.28, 1.35);
        };
        auto veg_weight_base = [&](int veg) -> double {
            if (detail_kind == 1) {
                switch (veg) {
                    case 14: case 12: return 1.22;
                    case 7: case 8: return 1.08;
                    case 5: return 0.98;
                    case 15: return 0.82;
                    case 20: case 19: return 0.64;
                    case 13: return 0.28;
                    case 6: case 11: return 0.12;
                    case 9: case 10: return 0.05;
                    case 16: case 17: case 0: case 22: case 23: return 0.0;
                    default: return 0.04;
                }
            }
            if (detail_kind == 2) {
                switch (veg) {
                    case 9: case 4: return 1.22;
                    case 10: return 0.98;
                    case 13: return 0.84;
                    case 21: return 0.78;
                    case 2: case 3: return 0.62;
                    case 16: return 0.32;
                    case 6: case 11: return 0.44;
                    case 14: case 12: return 0.24;
                    case 5: case 7: case 8: return 0.30;
                    case 17: case 1: return 0.02;
                    case 0: case 22: case 23: return 0.0;
                    default: return 0.18;
                }
            }
            switch (veg) {
                case 6: case 11: return 1.15;
                case 16: return 0.78;
                case 5: case 15: return 0.92;
                case 7: case 8: return 0.84;
                case 14: case 12: return 0.70;
                case 2: case 3: return 0.42;
                case 13: return 0.62;
                case 10: return 0.46;
                case 20: return 0.56;
                case 21: return 0.34;
                case 9: return 0.36;
                case 18: return 0.58;
                case 17: case 1: return 0.02;
                case 0: case 22: case 23: return 0.0;
                default: return 0.10;
            }
        };
        auto vegetation_weight = [&](int veg) -> double { return override_weight(veg_over, veg, veg_weight_base(veg)); };
        auto land_weight_base = [&](int lf) -> double {
            if (detail_kind == 1) {
                switch (lf) {
                    case 4: case 5: return 1.0;
                    case 6: return 0.74;
                    case 9: return 0.46;
                    case 7: return 0.16;
                    case 10: case 11: case 8: case 12: return 0.0;
                    default: return is_water_lf(lf) ? 0.0 : 0.38;
                }
            }
            if (detail_kind == 2) {
                switch (lf) {
                    case 4: case 5: return 1.0;
                    case 6: return 0.82;
                    case 9: return 0.72;
                    case 10: return 0.26;
                    case 11: return 0.04;
                    case 7: return 0.32;
                    case 8: case 12: return 0.0;
                    default: return is_water_lf(lf) ? 0.0 : 0.58;
                }
            }
            switch (lf) {
                case 4: case 5: return 1.0;
                case 6: return 0.84;
                case 9: return 0.64;
                case 10: return 0.42;
                case 11: return 0.06;
                case 7: return 0.14;
                case 8: case 12: return 0.0;
                default: return is_water_lf(lf) ? 0.0 : 0.55;
            }
        };
        auto land_weight = [&](int lf) -> double { return override_weight(land_over, lf, land_weight_base(lf)); };
        auto cover_weight = [&](int cover) -> double {
            double base = 1.0;
            if (cover == 2 || cover == 3 || cover == 6) base = 0.0;
            else if (cover == 5) base = 0.18;
            else if (cover == 1) base = 0.48;
            else if (cover == 4) base = 0.62;
            return override_weight(cover_over, cover, base);
        };
        auto archetype_affinity = [&](int arch, int veg, int lf, bool river, double temp, double moist, double soil, double discharge) -> double {
            const double wet = std::max(moist, soil);
            const double dry = std::min(moist, soil);
            const double big_river = clampd(discharge / 80.0, 0.0, 1.0);
            if (arch == 3) {
                double a = 0.10;
                if (veg == 5) a = 2.6; else if (veg == 8) a = 2.3; else if (veg == 6) a = 1.3; else if (veg == 3 || veg == 7) a = 0.8;
                return a * smoothstep(0.82, 0.22, temp);
            }
            if (arch == 4) {
                double a = 0.0;
                if (veg == 14 || veg == 12) a = 1.7; else if (veg == 15 || veg == 13) a = 1.1; else if (veg == 19 || veg == 18) a = 1.4;
                a *= smoothstep(0.55, 0.85, temp);
                if (lf == 9 || lf == 5 || river) a *= 1.3;
                return a * lerpd(1.0, 1.45, big_river);
            }
            if (arch == 5) {
                double a = 0.06;
                if (veg == 16) a = 1.9; else if (veg == 17) a = 1.0; else if (veg == 11 || veg == 13) a = 0.55; else if (veg == 18) a = 0.75;
                return a * smoothstep(0.5, 0.85, temp) * smoothstep(0.55, 0.16, dry);
            }
            if (arch == 6) {
                double a = 0.06;
                if (veg == 21) a = 1.9; else if (veg == 20 || veg == 19) a = 1.6; else if (veg == 9 || veg == 13) a = 0.45;
                a *= smoothstep(0.45, 0.85, wet);
                if (river) a *= 1.8;
                a *= lerpd(1.0, 1.6, big_river);
                if (lf == 9) a *= 1.4;
                return a;
            }
            if (arch == 7) {
                double a = 0.06;
                if (veg == 4) a = 2.0; else if (veg == 3 || veg == 2) a = 1.2; else if (veg == 9) a = 0.4;
                if (lf == 7 || lf == 6) a *= 1.25;
                return a * smoothstep(0.78, 0.32, temp);
            }
            return 1.0;
        };
        auto elevation_mod = [&](int arch, double elev) -> double {
            if (arch == 1 || arch == 4) return smoothstep(0.92, 0.58, elev);
            if (arch == 3) return smoothstep(0.22, 0.55, elev) * smoothstep(0.97, 0.74, elev) + 0.25;
            if (arch == 7) return clampd(smoothstep(0.46, 0.82, elev) + 0.12, 0.0, 1.2);
            if (arch == 0 || arch == 2 || arch == 5 || arch == 6) return smoothstep(0.97, 0.62, elev);
            return 1.0;
        };
        auto wind_mod = [&](int arch, double wind_speed) -> double {
            const double w = clampd(wind_speed / 18.0, 0.0, 1.0);
            if (arch == 4 || arch == 6 || arch == 7) return lerpd(1.0, 0.7, w);
            if (arch == 10) return lerpd(1.0, 0.6, w);
            return 1.0;
        };
        auto decoration_suit = [&](int arch, int veg, int lf, int cover, bool river, double temp, double snow, double vitality, double drought, double cold, double elev,
                                   double moisture, double heat, int wt, double wi) -> double {
            if (is_water_lf(lf)) return 0.0;
            double s = 0.0;
            if (arch == 8) {
                if (lf == 7 || lf == 8) s = 1.1; else if (lf == 12) s = 0.9; else if (lf == 10) s = 0.95; else if (lf == 6) s = 0.5; else if (lf == 11) s = 0.35; else s = 0.12;
                s *= lerpd(1.25, 0.55, vitality_norm(vitality));
                s *= lerpd(0.85, 1.4, smoothstep(0.5, 0.95, elev));
                if (river) s *= 0.6;
            } else if (arch == 9) {
                double snowy = std::max(snow, (cover == 1 || cover == 4) ? 1.0 : 0.0);
                if (cover == 2) snowy = std::max(snowy, 0.85);
                s = smoothstep(0.22, 0.7, snowy) * 1.1;
                s *= smoothstep(0.62, 0.2, temp);
                s *= lerpd(0.9, 1.3, smoothstep(0.55, 0.92, elev));
            } else if (arch == 10) {
                double stress = std::max(drought, cold);
                s = (1.0 - vitality_norm(vitality)) * lerpd(0.65, 1.5, clampd(stress, 0.0, 1.0));
                if (lf == 4 || lf == 5 || lf == 6) s *= 1.3; else if (lf == 10) s *= 0.95; else s *= 0.55;
            }
            s *= lerpd(0.18, 1.0, climate_presence(moisture, snow, vitality, heat, drought, cold, wt, wi));
            // 点缀层的 vegetation_weight_overrides 当白名单用（镜像
            // shrub_layer.gd::_decoration_vegetation_filter）：未列出的植被只留残量。
            if (!veg_over.is_empty()) {
                s *= std::max(0.0, override_weight(veg_over, veg, 0.12));
            }
            s *= quality_density;
            return clampd(s, 0.0, 1.25);
        };
        auto base_color = [&](int veg, double &r, double &g, double &b, double &a) {
            if (color_override) { r = override_r; g = override_g; b = override_b; a = override_a; return; }
            if (detail_kind == 1) {
                if (veg == 5 || veg == 8) { r = 0.10; g = 0.30; b = 0.17; a = 0.94; }
                else if (veg == 7) { r = 0.16; g = 0.42; b = 0.20; a = 0.94; }
                else if (veg == 14 || veg == 12) { r = 0.07; g = 0.34; b = 0.18; a = 0.96; }
                else if (veg == 15) { r = 0.24; g = 0.40; b = 0.18; a = 0.92; }
                else if (veg == 20 || veg == 19) { r = 0.08; g = 0.28; b = 0.18; a = 0.92; }
                else if (veg == 13) { r = 0.28; g = 0.39; b = 0.18; a = 0.88; }
                else { r = 0.14; g = 0.36; b = 0.18; a = 0.90; }
                return;
            }
            if (detail_kind == 2) {
                if (veg == 9 || veg == 4) { r = 0.34; g = 0.58; b = 0.22; a = 0.72; }
                else if (veg == 10 || veg == 13) { r = 0.48; g = 0.54; b = 0.22; a = 0.70; }
                else if (veg == 21 || veg == 20) { r = 0.20; g = 0.48; b = 0.25; a = 0.74; }
                else if (veg == 2 || veg == 3) { r = 0.38; g = 0.44; b = 0.26; a = 0.66; }
                else if (veg == 16) { r = 0.46; g = 0.42; b = 0.22; a = 0.60; }
                else { r = 0.30; g = 0.52; b = 0.22; a = 0.68; }
                return;
            }
            if (detail_kind == 3) { r = 0.10; g = 0.28; b = 0.18; a = 0.96; return; }
            if (detail_kind == 4) { r = 0.16; g = 0.40; b = 0.20; a = 0.96; return; }
            if (detail_kind == 5) { r = 0.30; g = 0.48; b = 0.32; a = 0.96; return; }
            if (detail_kind == 6) { r = 0.42; g = 0.52; b = 0.24; a = 0.92; return; }
            if (detail_kind == 7) { r = 0.64; g = 0.68; b = 0.52; a = 0.98; return; }
            if (detail_kind == 8) { r = 0.54; g = 0.54; b = 0.57; a = 1.0; return; }
            if (detail_kind == 9) { r = 0.95; g = 0.97; b = 1.0; a = 1.0; return; }
            if (detail_kind == 10) { r = 0.42; g = 0.36; b = 0.30; a = 0.98; return; }
            if (veg == 6 || veg == 11) { r = 0.16; g = 0.33; b = 0.20; a = 0.90; }
            else if (veg == 16) { r = 0.42; g = 0.38; b = 0.22; a = 0.88; }
            else if (veg == 2 || veg == 3) { r = 0.31; g = 0.38; b = 0.25; a = 0.86; }
            else if (veg == 20 || veg == 21) { r = 0.13; g = 0.32; b = 0.20; a = 0.88; }
            else if (veg == 13 || veg == 10) { r = 0.32; g = 0.43; b = 0.21; a = 0.88; }
            else { r = 0.18; g = 0.39; b = 0.19; a = 0.88; }
        };

        PackedInt32Array valid_indices;
        PackedInt32Array keys;
        PackedInt32Array native_cell_indices;
        PackedFloat32Array cx, cy, suit, vit, sized, cr, cg, cb, ca;
        PackedFloat32Array accp;
        PackedInt32Array att;
        const int sample_n = sample_indices.size();
        const int quota_cap = std::max(1, max_per_cell);

        for (int i = 0; i < sample_n; ++i) {
            const int idx = int(sample_indices[i]);
            if (idx < 0 || idx >= n_pos) continue;
            valid_indices.append(idx);
            const double temp = f32_at(temp_arr, idx, 0.5);
            const double moist = f32_at(moist_arr, idx, 0.5);
            const double snow = f32_at(snow_arr, idx, 0.0);
            const double wi = f32_at(weather_int_arr, idx, 0.0);
            const double vitality = f32_at(vitality_arr, idx, 0.7);
            const double heat = f32_at(heat_arr, idx, 0.0);
            const double drought = f32_at(drought_arr, idx, 0.0);
            const double cold = f32_at(cold_arr, idx, 0.0);
            const int lf = u8_at(landform_arr, idx, 4);
            const int veg = u8_at(veg_arr, idx, 0);
            const int cover = u8_at(cover_arr, idx, 0);
            const int wt = u8_at(weather_type_arr, idx, 0);
            const double elev = f32_at(elev_arr, idx, 0.4);
            const double soil = f32_at(soil_arr, idx, 0.4);
            const double discharge = f32_at(discharge_arr, idx, 0.0);
            const double wind_speed = f32_at(wind_arr, idx, 0.0);
            const bool cell_is_water = (idx < is_water_arr.size() && is_water_arr[idx] > 0) || is_water_lf(lf);
            const bool river = idx < has_river_arr.size() && has_river_arr[idx] > 0;
            if (spawn_domain == 0 && cell_is_water) continue;
            if (spawn_domain == 1 && !cell_is_water) continue;

            double suitability = 0.0;
            const double sp = scatter_presence(cover, moist, snow, vitality, heat, drought, cold, wt, wi);
            if (cell_is_water) {
                if (spawn_domain != 1 || cover == 2 || cover == 3) continue;
                const double lw = land_weight(lf), vw = vegetation_weight(veg), cw = cover_weight(cover);
                if (lw <= 0.0 || vw <= 0.0 || cw <= 0.0) continue;
                suitability = vw * lw * cw;
                suitability *= lerpd(0.74, 1.15, clampd(moist, 0.0, 1.0));
                suitability *= lerpd(0.70, 1.05, climate_compat(veg, temp, moist));
                suitability *= quality_density;
            } else if (detail_kind == 8 || detail_kind == 9 || detail_kind == 10) {
                suitability = decoration_suit(detail_kind, veg, lf, cover, river, temp, snow, vitality, drought, cold, elev, moist, heat, wt, wi);
            } else {
                const double lw = land_weight(lf), cw = cover_weight(cover);
                if (lw <= 0.0 || cw <= 0.0 || sp <= 0.02) continue;
                const double stress = std::max(heat, std::max(drought, cold));
                suitability = vegetation_weight(veg) * lw * cw;
                suitability *= biomass_factor(veg);
                suitability *= vitality_density(vitality);
                suitability *= lerpd(0.58, 1.0, clampd(climate_compat(veg, temp, moist), 0.0, 1.0));
                suitability *= 1.0 - clampd(stress, 0.0, 1.0) * 0.38;
                suitability *= lerpd(0.08, 1.0, sp);
                suitability *= ecology_bias(moist, vitality);
                suitability *= archetype_affinity(detail_kind, veg, lf, river, temp, moist, soil, discharge);
                suitability *= elevation_mod(detail_kind, elev);
                suitability *= wind_mod(detail_kind, wind_speed);
                if (river) suitability *= river_density_factor(temp, moist, soil);
                suitability *= quality_density;
            }
            suitability = clampd(suitability, 0.0, 1.25);
            if (suitability <= 0.0 || sp <= 0.02) continue;

            double rr = 0.18, gg = 0.39, bb = 0.19, aa = 0.88;
            base_color(veg, rr, gg, bb, aa);
            const double size_density = vegetation_weight(veg) * land_weight(lf) * cover_weight(cover);
            keys.append(idx);
            native_cell_indices.append(idx);
            cx.append(float(f32_at(pos_x, idx, 0.0) * hex_size));
            cy.append(float(f32_at(pos_y, idx, 0.0) * hex_size));
            // 配额化（镜像 shrub_layer.gd::_cell_quota）：期望株数对 suitability 线性。
            const double quota_target = double(quota_cap) * clampd(suitability, 0.0, 1.0);
            int quota_attempts = int(std::ceil(quota_target));
            if (quota_attempts < 1) quota_attempts = 1;
            if (quota_attempts > quota_cap) quota_attempts = quota_cap;
            suit.append(float(suitability));
            att.append(quota_attempts);
            accp.append(float(quota_target / double(quota_attempts)));
            vit.append(float(clampd(vitality, 0.0, 1.0)));
            sized.append(float(size_density));
            cr.append(float(rr)); cg.append(float(gg)); cb.append(float(bb)); ca.append(float(aa));
        }
        out["valid_indices"] = valid_indices;
        if (keys.size() <= 0) {
            out["fallback"] = false;
            out["path"] = String("gdext_delta_sampled");
            out["instance_count"] = 0;
            out["candidate_count"] = 0;
            out["wrap_edge_copy_count"] = 0;
            auto t1 = std::chrono::high_resolution_clock::now();
            out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
            out["sample_ms"] = out["elapsed_ms"];
            return out;
        }

        Dictionary next = knobs.duplicate();
        next.erase("sample_cell_indices");
        next["keys"] = keys;
        next["cell_indices"] = native_cell_indices;
        next["center_x"] = cx;
        next["center_y"] = cy;
        next["suitability"] = suit;
        next["attempts"] = att;
        next["accept_p"] = accp;
        next["vitality"] = vit;
        next["size_density"] = sized;
        next["color_r"] = cr;
        next["color_g"] = cg;
        next["color_b"] = cb;
        next["color_a"] = ca;
        const int requested_cap = int(knobs.get("instance_cap", 0));
        const int sampled_cap = int(keys.size()) * std::max(max_per_cell, 1) * 3;
        next["instance_cap"] = std::max(requested_cap, sampled_cap);
        Dictionary encoded = encode_detail_scatter(next);
        if (!bool(encoded.get("fallback", true))) {
            encoded["path"] = String("gdext_delta_sampled");
            encoded["valid_indices"] = valid_indices;
            auto t1 = std::chrono::high_resolution_clock::now();
            encoded["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
            encoded["sampled_cell_count"] = sample_n;
            encoded["active_cell_count"] = keys.size();
        }
        return encoded;
    }

    godot::Dictionary out = encode_detail_scatter(knobs);
    if (!bool(out.get("fallback", true))) {
        out["path"] = godot::String("gdext_delta");
    }
    return out;
}

godot::Dictionary DCWorldExt::encode_detail_scatter_family_cells(godot::Dictionary knobs) {
    using godot::Array;
    using godot::Dictionary;
    using godot::String;

    auto t0 = std::chrono::high_resolution_clock::now();
    Dictionary out;
    Array requests = knobs.get("requests", Array());
    Array payloads;
    payloads.resize(requests.size());
    int success_count = 0;
    int fallback_count = 0;
    int total_instances = 0;
    for (int i = 0; i < requests.size(); ++i) {
        Dictionary request = requests[i];
        Dictionary encoded = encode_detail_scatter_delta(request);
        encoded["family"] = request.get("family", 0);
        encoded["style_id"] = request.get("style_id", i);
        encoded["request_index"] = i;
        if (bool(encoded.get("fallback", true))) {
            ++fallback_count;
        } else {
            ++success_count;
            total_instances += int(encoded.get("instance_count", 0));
        }
        payloads[i] = encoded;
    }
    auto t1 = std::chrono::high_resolution_clock::now();
    out["fallback"] = requests.size() > 0 && success_count == 0;
    out["path"] = String("gdext_family_cells");
    out["payloads"] = payloads;
    out["request_count"] = requests.size();
    out["success_count"] = success_count;
    out["fallback_count"] = fallback_count;
    out["instance_count"] = total_instances;
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    return out;
}

} // namespace pk
