#include "world_ext.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

// 生成收尾「facade 引导链」融合 pass（dots-boot-facade-2026-10）。
//
// 迁移动机（Web wasm 实测，60x40=2400 cell）：加载尾段原本是 6 段 GDScript
// 数据搬运 + 5 次 `await _yield_generation_frame()`（非 headless 下每次等 4 帧）。
// 这些步骤没有语义，只是「在 GDScript 里造数组 → 交给 native」：
//   _bootstrap_natural_resource_deposits() 的 habitat 掩码段 + 河口强度段
//   run_resource_deposit_pass（本来就是 native，但要走一次语言往返）
//   _publish_bootstrapped_natural_resources_to_runtime（槽发布，保留 GDScript 半段）
//   _append_natural_resource_research_signals（native，但又要往返一次）
//   _seed_bio_occupancy（native province+seed，再往返一次）
//   _log_bio_occupancy_seed 的 per-cell 诊断聚合（2400 cell × 物种数）
//
// 这里把它们按原顺序在 C++ 内串起来：中间量（habitat/estuary/储量列）不跨语言
// 边界，GDScript 只发一份 knobs 并解包结果。子 pass 直接复用已经验收的实现
// （run_resource_deposit_pass / run_research_signal_generation_pass /
// run_bio_bootstrap_pass），因此数值在构造上逐位相同，本文件新增的只有两段
// per-cell 循环（habitat 掩码、河口羽流）和一段诊断聚合。

namespace pk {

using namespace godot;

namespace {

// 与 landing/landform_type.gd 的 LF 枚举同序（tags 不可重排）。
constexpr int kLfDeepOcean = 0;
constexpr int kLfOcean = 1;
constexpr int kLfCoast = 2;
constexpr int kLfLake = 3;

inline bool lf_is_open_sea(int lf) {
    return lf == kLfDeepOcean || lf == kLfOcean || lf == kLfCoast;
}

inline double now_ms(const std::chrono::steady_clock::time_point &t0) {
    return std::chrono::duration<double, std::milli>(
               std::chrono::steady_clock::now() - t0)
        .count();
}

// map_generator.gd `_bootstrap_natural_resource_deposits()` 的 habitat 掩码段，
// 逐行复刻（含 have_* 形状判据与 neighbor 下标越界跳过）：
//   bit0 = 陆地, bit1 = 开阔海/湖, bit2 = 河湖接壤(内陆淡水), bit3 = 临海。
PackedByteArray boot_habitat_mask(int n, const PackedByteArray &water_arr,
                                  const PackedByteArray &lf_arr,
                                  const PackedByteArray &river_arr,
                                  const PackedInt32Array &neighbor_arr,
                                  const PackedByteArray &habitat_in) {
    PackedByteArray habitat = habitat_in;
    if (habitat.size() < n) habitat.resize(n);
    const bool have_water = water_arr.size() >= n;
    const bool have_lf = lf_arr.size() >= n;
    const bool have_river = river_arr.size() >= n;
    const bool have_neighbors = neighbor_arr.size() >= int64_t(n) * 6;

    const uint8_t *__restrict water = have_water ? water_arr.ptr() : nullptr;
    const uint8_t *__restrict lf = have_lf ? lf_arr.ptr() : nullptr;
    const uint8_t *__restrict river = have_river ? river_arr.ptr() : nullptr;
    const int32_t *__restrict neighbors = have_neighbors ? neighbor_arr.ptr() : nullptr;
    uint8_t *__restrict out = habitat.ptrw();

    for (int i = 0; i < n; ++i) {
        int mask = 0;
        const bool is_water_cell = have_water && water[i] != 0;
        const int landform = have_lf ? int(lf[i]) : -1;
        if (!is_water_cell) {
            mask |= 1;
            if (have_river && river[i] != 0) mask |= 4;
            if (have_neighbors) {
                for (int direction = 0; direction < 6; ++direction) {
                    const int neighbor = int(neighbors[int64_t(i) * 6 + direction]);
                    if (neighbor < 0 || neighbor >= n || !have_water
                            || water[neighbor] == 0) {
                        continue;
                    }
                    const int neighbor_landform = have_lf ? int(lf[neighbor]) : -1;
                    if (neighbor_landform == kLfLake) {
                        mask |= 4;
                    } else if (lf_is_open_sea(neighbor_landform)) {
                        mask |= 8;
                    }
                }
            }
        } else if (lf_is_open_sea(landform)) {
            mask |= 2;
        } else if (landform == kLfLake) {
            mask |= 4;
        }
        out[i] = uint8_t(mask);
    }
    return habitat;
}

// 河口/羽流生产力：河格 + 入海格同强度，外圈 45% 羽流。逐行复刻 GDScript 段，
// 包括 `exp()` 用 double、写回 PackedFloat32Array 时的截断顺序（maxf 先比后存）。
PackedFloat32Array boot_estuary_strength(int n, const PackedByteArray &lf_arr,
                                         const PackedByteArray &river_arr,
                                         const PackedFloat32Array &river_flow_arr,
                                         const PackedInt32Array &river_downstream_arr,
                                         const PackedInt32Array &neighbor_arr) {
    PackedFloat32Array estuary;
    estuary.resize(n);
    float *__restrict dst = estuary.ptrw();
    const bool have_lf = lf_arr.size() >= n;
    const bool have_river = river_arr.size() >= n;
    const bool have_river_flow = river_flow_arr.size() >= n;
    const bool have_river_downstream = river_downstream_arr.size() >= n;
    const bool have_neighbors = neighbor_arr.size() >= int64_t(n) * 6;
    if (!have_lf || !have_river || !have_river_downstream) return estuary;

    const uint8_t *__restrict lf = lf_arr.ptr();
    const uint8_t *__restrict river = river_arr.ptr();
    const float *__restrict river_flow = have_river_flow ? river_flow_arr.ptr() : nullptr;
    const int32_t *__restrict downstream = river_downstream_arr.ptr();
    const int32_t *__restrict neighbors = have_neighbors ? neighbor_arr.ptr() : nullptr;

    for (int source = 0; source < n; ++source) {
        if (river[source] == 0) continue;
        const int outlet = int(downstream[source]);
        if (outlet < 0 || outlet >= n) continue;
        if (!lf_is_open_sea(int(lf[outlet]))) continue;
        const double flow = have_river_flow ? double(river_flow[source]) : 1.0;
        const double flow_signal = 1.0 - std::exp(-std::max(flow, 0.0) * 0.25);
        const double mouth_strength = 0.75 + 0.25 * flow_signal;
        const float mouth = float(mouth_strength);
        dst[source] = std::max(dst[source], mouth);
        dst[outlet] = std::max(dst[outlet], mouth);
        if (have_neighbors) {
            for (int direction = 0; direction < 6; ++direction) {
                const int plume = int(neighbors[int64_t(outlet) * 6 + direction]);
                if (plume < 0 || plume >= n) continue;
                if (!lf_is_open_sea(int(lf[plume]))) continue;
                dst[plume] = std::max(dst[plume], float(mouth_strength * 0.45));
            }
        }
    }
    return estuary;
}

// `_log_bio_occupancy_seed()` 的 per-cell 聚合段：按 cell 顺序扫描，每个
// landmass 维护「按首次出现顺序」的 foods / classes 名字列表（与原 GDScript
// 的 Array.has 去重 + append 顺序完全一致）。输出两条已 join 的字符串列。
void boot_bio_landmass_summary(const PackedInt32Array &occupancy,
                               const PackedInt32Array &landmass,
                               const PackedInt32Array &food_bits,
                               const PackedStringArray &food_names,
                               const PackedInt32Array &species_bits,
                               const PackedInt32Array &species_habitat,
                               const PackedStringArray &class_names,
                               PackedInt32Array &out_landmass,
                               PackedStringArray &out_classes,
                               PackedStringArray &out_foods) {
    const int cells = std::min(occupancy.size(), landmass.size());
    const int foods_n = std::min(food_bits.size(), food_names.size());
    const int species_n = std::min(species_bits.size(), species_habitat.size());
    const int classes_n = class_names.size();

    struct Bucket {
        std::vector<int32_t> classes;  // class_names 下标，按首次出现顺序
        std::vector<int32_t> foods;    // food_names 下标，按首次出现顺序
    };
    std::vector<int32_t> order;  // landmass id，按首次出现顺序
    std::unordered_map<int32_t, size_t> index_of;
    std::vector<Bucket> buckets;
    index_of.reserve(64);
    order.reserve(64);
    buckets.reserve(64);

    const int32_t *occ = occupancy.ptr();
    const int32_t *lid_arr = landmass.ptr();
    const int32_t *fbits = food_bits.ptr();
    const int32_t *sbits = species_bits.ptr();
    const int32_t *shab = species_habitat.ptr();

    for (int cell = 0; cell < cells; ++cell) {
        const int32_t lid = lid_arr[cell];
        if (lid <= 0) continue;
        size_t slot;
        auto it = index_of.find(lid);
        if (it == index_of.end()) {
            slot = buckets.size();
            index_of.emplace(lid, slot);
            order.push_back(lid);
            buckets.emplace_back();
        } else {
            slot = it->second;
        }
        const int64_t bits = int64_t(occ[cell]);
        if (bits == 0) continue;
        Bucket &bucket = buckets[slot];
        for (int i = 0; i < foods_n; ++i) {
            const int32_t bit = fbits[i];
            if (bit < 0 || bit > 62) continue;
            if ((bits & (int64_t(1) << bit)) == 0) continue;
            const int32_t name_id = i;
            if (std::find(bucket.foods.begin(), bucket.foods.end(), name_id)
                    == bucket.foods.end()) {
                bucket.foods.push_back(name_id);
            }
        }
        for (int si = 0; si < species_n; ++si) {
            const int32_t bit = sbits[si];
            const int32_t habitat = shab[si];
            // 与 GDScript 判据严格一致：bit 必须落在 [0,32) 且 habitat 在 (0,n)。
            if (bit < 0 || bit >= 32) continue;
            if ((bits & (int64_t(1) << bit)) == 0) continue;
            if (habitat <= 0 || habitat >= classes_n) continue;
            if (std::find(bucket.classes.begin(), bucket.classes.end(), habitat)
                    == bucket.classes.end()) {
                bucket.classes.push_back(habitat);
            }
        }
    }

    const int count = int(order.size());
    out_landmass.resize(count);
    out_classes.resize(count);
    out_foods.resize(count);
    for (int i = 0; i < count; ++i) {
        out_landmass.set(i, order[size_t(i)]);
        const Bucket &bucket = buckets[size_t(i)];
        String classes;
        for (size_t k = 0; k < bucket.classes.size(); ++k) {
            if (k > 0) classes += String(", ");
            classes += class_names[bucket.classes[k]];
        }
        String foods;
        for (size_t k = 0; k < bucket.foods.size(); ++k) {
            if (k > 0) foods += String(", ");
            foods += food_names[bucket.foods[k]];
        }
        out_classes.set(i, classes.is_empty() ? String("none") : classes);
        out_foods.set(i, foods.is_empty() ? String("none") : foods);
    }
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
// run_boot_facade_pass — 生成收尾 facade 引导链一次调用。
//
// 输入 knobs：
//   cell_count / is_water / landform / has_river / river_flow /
//   river_downstream / neighbor_indices / habitat_mask_in
//   run_deposits   bool   → 跑 run_resource_deposit_pass
//   deposit        Dict   → 上面那个 pass 的 knobs（缺 habitat_mask/estuary，由本 pass 填）
//   run_signals    bool   → 资源研究信号 CSR 合并
//   resource_signals Dict → run_research_signal_generation_pass(mode=resources) 的 knobs
//   run_bio        bool   → 生态 landmass/province + 播种
//   bio            Dict   → run_bio_bootstrap_pass 的 knobs
//   bio_food_names / bio_food_bits / bio_class_names → 诊断聚合用的名字表
//
// 返回：
//   ok / path / reason / elapsed_ms / stage_ms
//   habitat_mask / estuary_strength                （两段新循环的产物）
//   deposit_ok / deposit_reason / deposit_fields / deposit_reserves
//   signal_ok / signal_reason / cell_signal_offsets / cell_signal_ids / cell_signal_values
//   bio_ok / bio_reason + run_bio_bootstrap_pass 的全部键（landmass_ids/province_ids/
//   occupancy_bits/各项计数）
//   bio_log_landmass_ids / bio_log_classes / bio_log_foods （诊断聚合，已 join）
//
// 任一子 pass 不可用只把自己那一段标 false，不整体失败：GDScript 侧据此决定
// 哪几段回退到老路径（旧 DLL 逐段回退的行为不变）。
// ─────────────────────────────────────────────────────────────────────────────
Dictionary DCWorldExt::run_boot_facade_pass(const Dictionary &knobs) {
    const auto t_pass = std::chrono::steady_clock::now();
    Dictionary out;
    out["ok"] = false;
    out["path"] = String("gdext_boot_facade");

    const int n = int(knobs.get("cell_count", 0));
    if (n <= 0 || n > 4000000) {
        out["reason"] = String("boot_facade_cell_count_invalid");
        return out;
    }

    Dictionary stage_ms;

    auto t_stage = std::chrono::steady_clock::now();
    const PackedByteArray habitat = boot_habitat_mask(
        n, knobs.get("is_water", PackedByteArray()),
        knobs.get("landform", PackedByteArray()),
        knobs.get("has_river", PackedByteArray()),
        knobs.get("neighbor_indices", PackedInt32Array()),
        knobs.get("habitat_mask_in", PackedByteArray()));
    out["habitat_mask"] = habitat;
    stage_ms["habitat"] = now_ms(t_stage);

    t_stage = std::chrono::steady_clock::now();
    const PackedFloat32Array estuary = boot_estuary_strength(
        n, knobs.get("landform", PackedByteArray()),
        knobs.get("has_river", PackedByteArray()),
        knobs.get("river_flow", PackedFloat32Array()),
        knobs.get("river_downstream", PackedInt32Array()),
        knobs.get("neighbor_indices", PackedInt32Array()));
    out["estuary_strength"] = estuary;
    stage_ms["estuary"] = now_ms(t_stage);

    Array reserves;
    PackedStringArray deposit_fields;

    // ── 矿藏储量：把刚算好的两列填进子 pass 的 knobs，输入与 GDScript 逐位相同 ──
    if (bool(knobs.get("run_deposits", false))) {
        t_stage = std::chrono::steady_clock::now();
        Dictionary deposit_knobs = knobs.get("deposit", Dictionary());
        deposit_knobs["cell_count"] = n;
        deposit_knobs["habitat_mask"] = habitat;
        deposit_knobs["estuary"] = estuary;
        const Dictionary deposit = run_resource_deposit_pass(deposit_knobs);
        const bool deposit_ok = bool(deposit.get("ok", false));
        out["deposit_ok"] = deposit_ok;
        if (deposit_ok) {
            deposit_fields = deposit.get("fields", PackedStringArray());
            reserves = deposit.get("reserves", Array());
            out["deposit_fields"] = deposit_fields;
            out["deposit_reserves"] = reserves;
            out["deposit_native_ms"] = deposit.get("elapsed_ms", 0.0);
        } else {
            out["deposit_reason"] = deposit.get("reason", String("unknown"));
        }
        stage_ms["deposit"] = now_ms(t_stage);
    }

    // ── 资源研究信号：直接吃上面的储量列，不再经 MapData 中转 ──────────────
    if (bool(knobs.get("run_signals", false)) && !reserves.is_empty()) {
        t_stage = std::chrono::steady_clock::now();
        Dictionary signal_knobs = knobs.get("resource_signals", Dictionary());
        signal_knobs["mode"] = String("resources");
        signal_knobs["cell_count"] = n;
        signal_knobs["resource_reserves"] = reserves;
        const Dictionary signals = run_research_signal_generation_pass(signal_knobs);
        const bool signal_ok = bool(signals.get("ok", false));
        out["signal_ok"] = signal_ok;
        if (signal_ok) {
            out["cell_signal_offsets"] = signals.get(
                "cell_signal_offsets", PackedInt32Array());
            out["cell_signal_ids"] = signals.get("cell_signal_ids", PackedInt32Array());
            out["cell_signal_values"] = signals.get(
                "cell_signal_values", PackedInt32Array());
        } else {
            out["signal_reason"] = signals.get("reason", String("unknown"));
        }
        stage_ms["signals"] = now_ms(t_stage);
    }

    // ── 生态播种：landmass/province 拓扑 + origin 填充 + niche 打包 ──────────
    int landmass_count = 0;
    int province_count = 0;
    PackedInt32Array occupancy;
    PackedInt32Array bio_landmass;
    int bio_carrier_declared = 0;
    int bio_carrier_used = 0;
    if (bool(knobs.get("run_bio", false))) {
        t_stage = std::chrono::steady_clock::now();
        Dictionary bio_knobs = knobs.get("bio", Dictionary());
        if (!bio_knobs.is_empty()) {
            // carrier 储量列：老链路是「矿藏 pass 写回 MapData → _bio_reserve_column()
            // 读回」，融合路径里 MapData 还没写，因此按 reserve 字段名从刚算好的
            // deposit 输出里对齐取列（同一份数值、同一列序）。
            const PackedStringArray carrier_fields = bio_knobs.get(
                "carrier_reserve_fields", PackedStringArray());
            bio_carrier_declared = carrier_fields.size();
            if (!carrier_fields.is_empty()) {
                Array columns;
                columns.resize(carrier_fields.size());
                for (int i = 0; i < carrier_fields.size(); ++i) {
                    int col = -1;
                    for (int k = 0; k < deposit_fields.size(); ++k) {
                        if (deposit_fields[k] == carrier_fields[i]) { col = k; break; }
                    }
                    if (col >= 0 && col < reserves.size()) {
                        columns[i] = reserves[col];
                    } else {
                        PackedFloat32Array empty;
                        empty.resize(n);
                        columns[i] = empty;
                    }
                }
                bio_knobs["carrier_reserves"] = columns;
                bio_carrier_used = columns.size();
            }
            out["bio_carrier_declared"] = bio_carrier_declared;
            out["bio_carrier_used"] = bio_carrier_used;
            const Dictionary bio = run_bio_bootstrap_pass(bio_knobs);
            const bool bio_ok = bool(bio.get("ok", false));
            out["bio_ok"] = bio_ok;
            if (bio_ok) {
                // 只搬运诊断打印用到的计数键（显式白名单：绝不覆盖本 pass 的
                // ok/path/reason，也不把 landmass/province/occupancy 重复拷一份）。
                static const char *kDiagKeys[] = {
                    "envelope_cell_counts", "origin_envelope_cell_counts",
                    "occupied_cell_counts", "origin_landmass_ids",
                    "seeded_landmass_counts", "hearth_cell_counts",
                };
                for (const char *diag_key : kDiagKeys)
                    out[String(diag_key)] = bio.get(String(diag_key), PackedInt32Array());
                out["secondary_hearth_count"] = int(bio.get("secondary_hearth_count", 0));
                bio_landmass = bio.get("landmass_ids", PackedInt32Array());
                out["landmass_ids"] = bio_landmass;
                out["province_ids"] = bio.get("province_ids", PackedInt32Array());
                occupancy = bio.get("occupancy_bits", PackedInt32Array());
                out["occupancy_bits"] = occupancy;
                landmass_count = int(bio.get("landmass_count", 0));
                province_count = int(bio.get("province_count", 0));
            } else {
                out["bio_reason"] = bio.get("reason", String("unknown"));
            }
        }
        stage_ms["bio"] = now_ms(t_stage);
    }

    // ── 诊断聚合（原 `_log_bio_occupancy_seed()` 的 per-cell 段）───────────
    if (!occupancy.is_empty() && bio_landmass.size() == n) {
        t_stage = std::chrono::steady_clock::now();
        const Dictionary bio_knobs = knobs.get("bio", Dictionary());
        PackedInt32Array log_landmass;
        PackedStringArray log_classes;
        PackedStringArray log_foods;
        boot_bio_landmass_summary(
            occupancy, bio_landmass,
            knobs.get("bio_food_bits", PackedInt32Array()),
            knobs.get("bio_food_names", PackedStringArray()),
            bio_knobs.get("species_occupancy_bits", PackedInt32Array()),
            bio_knobs.get("species_habitat_class", PackedInt32Array()),
            knobs.get("bio_class_names", PackedStringArray()),
            log_landmass, log_classes, log_foods);
        out["bio_log_landmass_ids"] = log_landmass;
        out["bio_log_classes"] = log_classes;
        out["bio_log_foods"] = log_foods;
        out["bio_log_landmass_count"] = landmass_count;
        out["bio_log_province_count"] = province_count;
        stage_ms["bio_log"] = now_ms(t_stage);
    }

    out["stage_ms"] = stage_ms;
    // 回显调用方给的输入指纹，供 A/B 探针判断「探针重建的 knobs」是否与内联调用同源。
    out["deposit_knob_sig"] = knobs.get("deposit_knob_sig", 0);
    out["elapsed_ms"] = now_ms(t_pass);
    out["ok"] = true;
    return out;
}

} // namespace pk
