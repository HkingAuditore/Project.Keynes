#include "world_ext.h"

#include <godot_cpp/classes/noise.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <vector>

// 仓库既有约定：world_ext 的实现文件都包在 `namespace pk` 里，并在其中
// `using namespace godot;`（见 world_ext_bio.cpp:22-24），下面才能写裸
// Dictionary / PackedFloat32Array。
namespace pk {

using namespace godot;

// ─────────────────────────────────────────────────────────────────────────────
// run_resource_deposit_pass — 生成期「自然资源矿藏储量」一次性烘焙。
//
// 逐行复刻 map_generator.gd 的 _bootstrap_natural_resource_deposits() 主循环
// 以及 _select_micro_deposit_cells() / _allocate_ranked_deposit_budget()。
// 迁到 C++ 的理由（实测 2400 cell / 31 种资源）：
//   * GDScript 版本是 O(资源数 × cell 数)，每格 append 一个 Dictionary，
//     每个资源还要 sort_custom(lambda)；2400 cell 已要 1.2s，桌面允许的
//     200k cell 会到分钟级；
//   * 这里只用裸指针 + std::vector<RankedCell> + std::sort，每格零 Variant 分配。
//
// 噪声不自行实现：接收 GDScript 建好的 Ref<Noise>（同 seed / 同 frequency），
// 保证与旧路径取值一致。
//
// 与 GDScript 版本的**已知差异**：sort_custom 的比较器用 is_equal_approx 判
// 并列，那不是严格弱序、排序结果依赖 introsort 内部实现。这里改成严格序
// （suit 降序、cell 升序），只在 |Δsuit| < 1e-5 的近似并列带里可能选出不同但
// 等价的格子。
// ─────────────────────────────────────────────────────────────────────────────

namespace {

// knobs["scalars"] 每个资源占用的 float 槽位数（顺序即下面枚举）
constexpr int kScalarStride = 32;

enum ScalarSlot : int {
    kInitBase = 0,
    kInitTemp = 1,
    kInitMoisture = 2,
    kInitReserveScale = 3,
    kInitFloorReserve = 4,
    kInitMinCoverage = 5,
    kInitMinReserve = 6,
    kInitTargetCoverage = 7,
    kInitTargetReserveDensity = 8,
    kInitTargetMeanReserve = 9,
    kInitRichnessExponent = 10,
    kInitMicroCoverage = 11,
    kInitMicroReserveShare = 12,
    kInitMicroMinReserve = 13,
    kInitElevation = 14,
    kInitRiver = 15,
    kInitVolcano = 16,
    kInitOceanCurrent = 17,
    kInitUpwelling = 18,
    kInitEstuary = 19,
    kInitNoise = 20,
    kInitProvince = 21,
    kInitBelt = 22,
    kClimateTempOpt = 23,
    kClimateTempTol = 24,
    kClimateMoistureOpt = 25,
    kClimateMoistureTol = 26,
    kInitClimateFit = 27,
    kTempLo = 28,
    kTempHi = 29,
    // 每块大陆的保底格数上限（0 = 不做大陆配额）。
    kInitContinentFloorCells = 30,
    // 槽 31 留空：保底储量不单开参数，直接取该资源的 min_reserve（最小真矿）。
};

struct RankedCell {
    double suit = 0.0;
    int32_t cell = 0;
};

inline double clampd(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// 复刻 ResourceProfileRegistry.habitat_available() 的 0..5 语义。
inline bool habitat_available(int code, int mask) {
    switch (code) {
        case 0: return true;
        case 1: return (mask & 1) != 0;
        case 2: return (mask & 2) != 0;
        case 3: return (mask & 4) != 0;
        case 4: return (mask & 8) != 0;
        case 5: return (mask & (2 | 8)) != 0;
        default: return false;
    }
}

struct ResourceParams {
    double init_base = 0.0;
    double init_temp = 0.0;
    double init_moisture = 0.0;
    double reserve_scale = 0.0;
    double floor_reserve = 0.0;
    // 按大陆配额补几格；与上面 floor_reserve（全图逐格地板）无关，也不带储量，
    // 补的格储量固定取 min_reserve。
    double continent_floor_cells = 0.0;
    double min_coverage = 0.0;
    double min_reserve = 0.0;
    double target_coverage = 0.0;
    double target_reserve_density = 0.0;
    double target_mean_reserve = 0.0;
    double richness_exponent = 1.0;
    double micro_coverage = 0.0;
    double micro_reserve_share = 0.0;
    double micro_min_reserve = 0.0;
    double w_elev = 0.0;
    double w_river = 0.0;
    double w_volc = 0.0;
    double w_ocean_current = 0.0;
    double w_upwelling = 0.0;
    double w_estuary = 0.0;
    double w_noise = 0.0;
    double w_province = 0.0;
    double w_belt = 0.0;
    double climate_temp_opt = 0.5;
    double climate_temp_tol = 1.0;
    double climate_moisture_opt = 0.5;
    double climate_moisture_tol = 1.0;
    double w_climate_fit = 0.0;
    double temp_lo = 0.0;
    double inv_span = 0.0;
    int habitat_code = 0;
    bool use_elev = false;
    bool use_lf = false;
    bool use_veg = false;
    bool use_river = false;
    bool use_volc = false;
    bool use_ocean_current = false;
    bool use_upwelling = false;
    bool use_estuary = false;
    bool use_noise = false;
    bool use_province = false;
    bool use_belt = false;
};

struct SparseWeights {
    const int32_t *keys = nullptr;
    const float *vals = nullptr;
    int count = 0;

    double lookup(int32_t key) const {
        for (int i = 0; i < count; ++i) {
            if (keys[i] == key) return double(vals[i]);
        }
        return 0.0;
    }
};

// 复刻 _allocate_ranked_deposit_budget()：按适宜度相对值把预算摊到候选格。
// `ranks` 是 ranked[] 里按 suit 降序排好的名次列表。
void allocate_ranked_budget(float *arr, const std::vector<RankedCell> &ranked,
        const std::vector<int32_t> &ranks, double budget, double minimum_reserve,
        double richness_exponent) {
    const int count = int(ranks.size());
    if (count <= 0 || budget <= 0.0) {
        return;
    }
    const double remaining =
            std::max(budget - minimum_reserve * double(count), 0.0);
    const double best_suit = ranked[size_t(ranks[0])].suit;
    const double cutoff_suit = ranked[size_t(ranks[size_t(count - 1)])].suit;
    const double suit_span = std::max(best_suit - cutoff_suit, 0.000001);

    std::vector<double> weights(size_t(count), 0.0);
    double weight_sum = 0.0;
    for (int rank = 0; rank < count; ++rank) {
        const double relative = clampd(
                (ranked[size_t(ranks[size_t(rank)])].suit - cutoff_suit) / suit_span,
                0.0, 1.0);
        const double weight = std::pow(std::max(relative, 0.001), richness_exponent);
        weights[size_t(rank)] = weight;
        weight_sum += weight;
    }
    for (int rank = 0; rank < count; ++rank) {
        const int32_t cell = ranked[size_t(ranks[size_t(rank)])].cell;
        const double enrichment = weight_sum > 0.0
                ? remaining * weights[size_t(rank)] / weight_sum
                : remaining / double(count);
        arr[cell] = float(minimum_reserve + enrichment);
    }
}

// 复刻 _select_micro_deposit_cells()：核心富集区之外，间一格距离挑小微矿点。
// 输出的是 ranked[] 的名次（不是 cell id），便于复用 allocate_ranked_budget。
void select_micro_cells(const std::vector<RankedCell> &ranked, int core_count,
        int micro_count, const int32_t *neighbors, bool have_neighbors, int n,
        std::vector<int32_t> &out_ranks) {
    out_ranks.clear();
    if (micro_count <= 0 || core_count >= int(ranked.size())) {
        return;
    }
    std::vector<char> occupied(size_t(n), 0);
    std::vector<char> selected(size_t(n), 0);
    for (int rank = 0; rank < std::min<int>(core_count, int(ranked.size())); ++rank) {
        occupied[size_t(ranked[size_t(rank)].cell)] = 1;
    }
    out_ranks.reserve(size_t(micro_count));
    for (int rank = core_count; rank < int(ranked.size()); ++rank) {
        if (int(out_ranks.size()) >= micro_count) break;
        const int32_t cell = ranked[size_t(rank)].cell;
        bool touches_deposit = false;
        if (have_neighbors) {
            for (int dir = 0; dir < 6; ++dir) {
                const int32_t neighbour = neighbors[size_t(cell) * 6 + size_t(dir)];
                if (neighbour >= 0 && neighbour < n && occupied[size_t(neighbour)]) {
                    touches_deposit = true;
                    break;
                }
            }
        }
        if (touches_deposit) continue;
        out_ranks.push_back(int32_t(rank));
        selected[size_t(cell)] = 1;
        occupied[size_t(cell)] = 1;
    }
    for (int rank = core_count; rank < int(ranked.size()); ++rank) {
        if (int(out_ranks.size()) >= micro_count) break;
        const int32_t cell = ranked[size_t(rank)].cell;
        if (selected[size_t(cell)]) continue;
        out_ranks.push_back(int32_t(rank));
        selected[size_t(cell)] = 1;
    }
}

bool read_sparse_weights(const Dictionary &knobs, const char *keys_key,
        const char *vals_key, const char *offsets_key, int resource_count,
        std::vector<SparseWeights> &out, String &reason) {
    const PackedInt32Array keys = knobs.get(keys_key, PackedInt32Array());
    const PackedFloat32Array vals = knobs.get(vals_key, PackedFloat32Array());
    const PackedInt32Array offsets = knobs.get(offsets_key, PackedInt32Array());
    if (offsets.size() != resource_count + 1 || keys.size() != vals.size()) {
        reason = String(keys_key) + "_shape_invalid";
        return false;
    }
    if (offsets[resource_count] != keys.size()) {
        reason = String(offsets_key) + "_offset_invalid";
        return false;
    }
    out.assign(size_t(resource_count), SparseWeights{});
    for (int r = 0; r < resource_count; ++r) {
        const int begin = offsets[r];
        const int end = offsets[r + 1];
        if (begin < 0 || end < begin || end > keys.size()) {
            reason = String(offsets_key) + "_range_invalid";
            return false;
        }
        SparseWeights w;
        w.keys = keys.ptr() + begin;
        w.vals = vals.ptr() + begin;
        w.count = end - begin;
        out[size_t(r)] = w;
    }
    return true;
}

// ── 大陆标号：6 邻接 BFS，与 gdext/src/world_ext_bio.cpp:895-912 同算法、
// 同一邻接表访问顺序；验收 V10 逐格比对 map.landmass_id_arr。
// landmass_of[i] = 0 表示水面/未标记，>0 为大陆标号；landmass_size[L] 为该陆块格数。
//
// 「大陆」面积门槛：与生态保底同口径。常量与算法复述自
// gdext/src/world_ext_bio.cpp:392-393（kMinContinentCells / kMinContinentShare）
// 与 :1115-1120（largest_land × share 取门槛），两边必须同步改。
constexpr int32_t kMinContinentCells = 8;
constexpr float kMinContinentShare = 0.18f;

// 「保底配额资格」门槛：只决定哪些陆块参与资源的保底配额（:744），
// 不参与上面「大陆」定义，也不改 world_ext_bio 的任何行为。
// 与 kMinContinentCells 刻意分开：continent_floor 随最大陆地面积涨（56×38 上是 48），
// 会把这些陆块整段跳过配额，导致缺盐/硅砂/锡的 37、33、11 格陆块拿不到保底。
constexpr int32_t kMinQuotaCells = 8;

void label_landmasses(const uint8_t *water, const int32_t *neighbors, int n,
        std::vector<int32_t> &landmass_of, std::vector<int32_t> &landmass_size) {
    landmass_of.assign(size_t(n), 0);
    int32_t landmass_count = 0;
    std::vector<int32_t> stack;
    stack.reserve(size_t(n));
    for (int cell = 0; cell < n; ++cell) {
        if (water[cell] != 0 || landmass_of[size_t(cell)] != 0) continue;
        ++landmass_count;
        stack.clear();
        stack.push_back(int32_t(cell));
        landmass_of[size_t(cell)] = landmass_count;
        while (!stack.empty()) {
            const int32_t cur = stack.back();
            stack.pop_back();
            const int32_t base = cur * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nxt = neighbors[base + d];
                if (nxt < 0 || nxt >= n || water[nxt] != 0
                        || landmass_of[size_t(nxt)] != 0) {
                    continue;
                }
                landmass_of[size_t(nxt)] = landmass_count;
                stack.push_back(nxt);
            }
        }
    }
    landmass_size.assign(size_t(landmass_count) + 1, 0);
    for (int cell = 0; cell < n; ++cell) {
        const int32_t l = landmass_of[size_t(cell)];
        if (l > 0) landmass_size[size_t(l)] += 1;
    }
}

} // namespace

godot::Dictionary DCWorldExt::run_resource_deposit_pass(const godot::Dictionary &knobs) {
    const auto t_start = std::chrono::steady_clock::now();
    Dictionary out;
    out["ok"] = false;
    out["path"] = String("gdext");

    const int n = int(knobs.get("cell_count", 0));
    if (n <= 0 || n > 4000000) {
        out["reason"] = String("resource_deposit_cell_count_invalid");
        return out;
    }

    const PackedFloat32Array temp_arr = knobs.get("temperature", PackedFloat32Array());
    const PackedFloat32Array moist_arr = knobs.get("moisture", PackedFloat32Array());
    const PackedFloat32Array elev_arr = knobs.get("elevation", PackedFloat32Array());
    const PackedByteArray terrain_arr = knobs.get("terrain", PackedByteArray());
    const PackedByteArray veg_arr = knobs.get("vegetation", PackedByteArray());
    const PackedByteArray lf_arr = knobs.get("landform", PackedByteArray());
    const PackedByteArray river_arr = knobs.get("has_river", PackedByteArray());
    const PackedByteArray lake_arr = knobs.get("is_lake", PackedByteArray());
    const PackedByteArray volcano_arr = knobs.get("has_volcano", PackedByteArray());
    const PackedFloat32Array ocean_x_arr = knobs.get("ocean_x", PackedFloat32Array());
    const PackedFloat32Array ocean_y_arr = knobs.get("ocean_y", PackedFloat32Array());
    const PackedFloat32Array upwelling_arr = knobs.get("upwelling", PackedFloat32Array());
    const PackedFloat32Array estuary_arr = knobs.get("estuary", PackedFloat32Array());
    const PackedFloat32Array pos_x_arr = knobs.get("pos_x", PackedFloat32Array());
    const PackedFloat32Array pos_y_arr = knobs.get("pos_y", PackedFloat32Array());
    const PackedByteArray habitat_arr = knobs.get("habitat_mask", PackedByteArray());
    const PackedInt32Array neighbor_arr = knobs.get("neighbor_indices", PackedInt32Array());
    // 大陆配额用；旧调用方/旧 DLL 不带这个 knob，缺失时整段配额跳过（见 have_landmass）。
    const PackedByteArray water_arr = knobs.get("is_water", PackedByteArray());

    if (temp_arr.size() < n || moist_arr.size() < n || habitat_arr.size() < n) {
        out["reason"] = String("resource_deposit_core_arrays_invalid");
        return out;
    }

    const bool have_terrain = terrain_arr.size() >= n;
    const bool have_veg = veg_arr.size() >= n;
    const bool have_lf = lf_arr.size() >= n;
    const bool have_river = river_arr.size() >= n;
    const bool have_lake = lake_arr.size() >= n;
    const bool have_volcano = volcano_arr.size() >= n;
    const bool have_elev = elev_arr.size() >= n;
    const bool have_ocean_current = ocean_x_arr.size() >= n && ocean_y_arr.size() >= n;
    const bool have_upwelling = upwelling_arr.size() >= n;
    const bool have_estuary = estuary_arr.size() >= n;
    const bool have_pos = pos_x_arr.size() >= n && pos_y_arr.size() >= n;
    const bool have_neighbors = neighbor_arr.size() >= int64_t(n) * 6;
    const bool have_landmass = water_arr.size() >= n && have_neighbors;

    const PackedStringArray field_names = knobs.get("field_names", PackedStringArray());
    const PackedInt32Array habitat_codes = knobs.get("habitat_codes", PackedInt32Array());
    const PackedFloat32Array scalars = knobs.get("scalars", PackedFloat32Array());
    // ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE is the only definition;
    // every authored reserve is scaled by it exactly once, at parse time.
    const double cell_area_scale = double(knobs.get("cell_area_resource_scale", 0.0));
    if (!(cell_area_scale > 0.0)) {
        out["reason"] = String("resource_deposit_cell_area_scale_missing");
        return out;
    }
    const int resource_count = int(field_names.size());
    if (resource_count <= 0 || resource_count > 256
            || habitat_codes.size() != resource_count
            || scalars.size() != int64_t(resource_count) * kScalarStride) {
        out["reason"] = String("resource_deposit_profile_shape_invalid");
        return out;
    }

    std::vector<SparseWeights> lf_weights;
    std::vector<SparseWeights> veg_weights;
    String shape_reason;
    if (!read_sparse_weights(knobs, "lf_keys", "lf_vals", "lf_offsets", resource_count,
                lf_weights, shape_reason)) {
        out["reason"] = shape_reason;
        return out;
    }
    if (!read_sparse_weights(knobs, "veg_keys", "veg_vals", "veg_offsets", resource_count,
                veg_weights, shape_reason)) {
        out["reason"] = shape_reason;
        return out;
    }

    const int excluded_terrain_width = int(knobs.get("excluded_terrain_width", 0));
    const PackedByteArray excluded_terrain = knobs.get("excluded_terrain", PackedByteArray());
    const int excluded_veg_width = int(knobs.get("excluded_vegetation_width", 0));
    const PackedByteArray excluded_vegetation =
            knobs.get("excluded_vegetation", PackedByteArray());
    if (excluded_terrain_width > 0
            && excluded_terrain.size() < int64_t(resource_count) * excluded_terrain_width) {
        out["reason"] = String("resource_deposit_excluded_terrain_invalid");
        return out;
    }
    if (excluded_veg_width > 0
            && excluded_vegetation.size() < int64_t(resource_count) * excluded_veg_width) {
        out["reason"] = String("resource_deposit_excluded_vegetation_invalid");
        return out;
    }

    const Array noise_refs = knobs.get("noise", Array());
    const Array province_refs = knobs.get("province_noise", Array());
    const Array belt_refs = knobs.get("belt_noise", Array());
    if (noise_refs.size() != resource_count || province_refs.size() != resource_count
            || belt_refs.size() != resource_count) {
        out["reason"] = String("resource_deposit_noise_refs_invalid");
        return out;
    }

    const float *temp = temp_arr.ptr();
    const float *moist = moist_arr.ptr();
    const float *elev = have_elev ? elev_arr.ptr() : nullptr;
    const uint8_t *terrain = have_terrain ? terrain_arr.ptr() : nullptr;
    const uint8_t *veg = have_veg ? veg_arr.ptr() : nullptr;
    const uint8_t *lf = have_lf ? lf_arr.ptr() : nullptr;
    const uint8_t *river = have_river ? river_arr.ptr() : nullptr;
    const uint8_t *lake = have_lake ? lake_arr.ptr() : nullptr;
    const uint8_t *volcano = have_volcano ? volcano_arr.ptr() : nullptr;
    const float *ocean_x = have_ocean_current ? ocean_x_arr.ptr() : nullptr;
    const float *ocean_y = have_ocean_current ? ocean_y_arr.ptr() : nullptr;
    const float *upwelling = have_upwelling ? upwelling_arr.ptr() : nullptr;
    const float *estuary = have_estuary ? estuary_arr.ptr() : nullptr;
    const float *pos_x = have_pos ? pos_x_arr.ptr() : nullptr;
    const float *pos_y = have_pos ? pos_y_arr.ptr() : nullptr;
    const uint8_t *habitat = habitat_arr.ptr();
    const int32_t *neighbors = have_neighbors ? neighbor_arr.ptr() : nullptr;

    Array reserves;
    reserves.resize(resource_count);

    // 大陆标号只算一次，供所有资源的配额段复用。is_water 缺失 → 不标、配额整段跳过。
    std::vector<int32_t> landmass_of;
    std::vector<int32_t> landmass_size;
    int32_t continent_floor = 0;
    if (have_landmass) {
        label_landmasses(water_arr.ptr(), neighbors, n, landmass_of, landmass_size);
        int32_t largest_land = 0;
        for (size_t l = 1; l < landmass_size.size(); ++l) {
            largest_land = std::max(largest_land, landmass_size[l]);
        }
        // max(8, round(0.18 × 最大陆地))：与 world_ext_bio.cpp:1115-1120 同一式子，
        // 连 float 中间量也一致，保证两边「大陆」定义逐位相同。
        continent_floor = std::max(kMinContinentCells,
                int32_t(std::lround(float(largest_land) * kMinContinentShare)));
    }

    // 纯诊断，不进存档、不进 state hash。
    PackedInt32Array quota_fields;
    quota_fields.resize(resource_count);
    quota_fields.fill(0);
    int32_t *quota_field_cells = quota_fields.ptrw();
    int quota_cells_total = 0;
    int quota_unmet_total = 0;

    for (int r = 0; r < resource_count; ++r) {
        const float *scalar = scalars.ptr() + size_t(r) * kScalarStride;
        ResourceParams p;
        p.init_base = double(scalar[kInitBase]);
        p.init_temp = double(scalar[kInitTemp]);
        p.init_moisture = double(scalar[kInitMoisture]);
        p.reserve_scale =
                std::max(double(scalar[kInitReserveScale]), 0.0) * cell_area_scale;
        p.floor_reserve =
                std::max(double(scalar[kInitFloorReserve]), 0.0) * cell_area_scale;
        p.min_coverage = double(scalar[kInitMinCoverage]);
        p.min_reserve = double(scalar[kInitMinReserve]) * cell_area_scale;
        p.target_coverage = clampd(double(scalar[kInitTargetCoverage]), 0.0, 1.0);
        p.target_reserve_density = std::max(
                double(scalar[kInitTargetReserveDensity]), 0.0) * cell_area_scale;
        p.target_mean_reserve = std::max(
                double(scalar[kInitTargetMeanReserve]), 0.0) * cell_area_scale;
        p.richness_exponent = double(scalar[kInitRichnessExponent]);
        p.micro_coverage = clampd(double(scalar[kInitMicroCoverage]), 0.0, 1.0);
        p.micro_reserve_share = double(scalar[kInitMicroReserveShare]);
        p.micro_min_reserve = std::max(
                double(scalar[kInitMicroMinReserve]), 0.0) * cell_area_scale;
        // 只决定格数，不含储量 → 不乘 cell_area_scale（保底储量走 p.min_reserve，
        // 它在上面已经乘过 cell_area_scale）。
        p.continent_floor_cells = std::max(double(scalar[kInitContinentFloorCells]), 0.0);
        p.w_elev = double(scalar[kInitElevation]);
        p.w_river = double(scalar[kInitRiver]);
        p.w_volc = double(scalar[kInitVolcano]);
        p.w_ocean_current = double(scalar[kInitOceanCurrent]);
        p.w_upwelling = double(scalar[kInitUpwelling]);
        p.w_estuary = double(scalar[kInitEstuary]);
        p.w_noise = double(scalar[kInitNoise]);
        p.w_province = double(scalar[kInitProvince]);
        p.w_belt = double(scalar[kInitBelt]);
        p.climate_temp_opt = double(scalar[kClimateTempOpt]);
        p.climate_temp_tol = double(scalar[kClimateTempTol]);
        p.climate_moisture_opt = double(scalar[kClimateMoistureOpt]);
        p.climate_moisture_tol = double(scalar[kClimateMoistureTol]);
        p.w_climate_fit = double(scalar[kInitClimateFit]);
        p.temp_lo = double(scalar[kTempLo]);
        const double temp_hi = double(scalar[kTempHi]);
        p.inv_span = temp_hi > p.temp_lo ? 1.0 / (temp_hi - p.temp_lo) : 0.0;
        p.habitat_code = habitat_codes[r];

        p.use_elev = have_elev && p.w_elev != 0.0;
        p.use_lf = have_lf && lf_weights[size_t(r)].count > 0;
        p.use_veg = have_veg && veg_weights[size_t(r)].count > 0;
        p.use_river = p.w_river != 0.0 && (have_river || have_lake);
        p.use_volc = have_volcano && p.w_volc != 0.0;
        p.use_ocean_current = have_ocean_current && p.w_ocean_current != 0.0;
        p.use_upwelling = have_upwelling && p.w_upwelling != 0.0;
        p.use_estuary = p.w_estuary != 0.0 && have_estuary;
        p.use_noise = have_pos && std::fabs(p.w_noise) > 0.0;
        p.use_province = have_pos && std::fabs(p.w_province) > 0.0;
        p.use_belt = have_pos && std::fabs(p.w_belt) > 0.0;

        Ref<Noise> noise = noise_refs[r];
        Ref<Noise> province_noise = province_refs[r];
        Ref<Noise> belt_noise = belt_refs[r];
        if (p.use_noise && noise.is_null()) p.use_noise = false;
        if (p.use_province && province_noise.is_null()) p.use_province = false;
        if (p.use_belt && belt_noise.is_null()) p.use_belt = false;

        const uint8_t *excluded_terrain_row =
                (excluded_terrain_width > 0 && have_terrain)
                ? excluded_terrain.ptr() + size_t(r) * excluded_terrain_width
                : nullptr;
        const uint8_t *excluded_veg_row =
                (excluded_veg_width > 0 && have_veg)
                ? excluded_vegetation.ptr() + size_t(r) * excluded_veg_width
                : nullptr;

        PackedFloat32Array arr;
        arr.resize(n);
        // PackedFloat32Array::resize 不保证零初始化；GDScript 旧路径是复用 SoA 里
        // 已零初始化的字段、只在入选格写值，因此未入选格必须保持 0。这里显式清零，
        // 否则尾部是堆上残留值（每次进程/分配次序不同 → 储量逐局漂移）。
        arr.fill(0.0f);
        float *values = arr.ptrw();
        int quota_added = 0;   // 本资源实际补上的格数
        int quota_unmet = 0;   // 本资源遍历完候选集仍未补满的格数

        const bool use_ranked_distribution = p.target_coverage > 0.0;
        const bool collect_ranked =
                use_ranked_distribution || (p.min_coverage > 0.0 && p.min_reserve > 0.0);
        std::vector<RankedCell> ranked;
        if (collect_ranked) {
            ranked.reserve(size_t(n));
        }

        for (int i = 0; i < n; ++i) {
            if (p.habitat_code > 0 && !habitat_available(p.habitat_code, int(habitat[i]))) {
                values[i] = 0.0f;
                continue;
            }
            if (excluded_terrain_row != nullptr && int(terrain[i]) < excluded_terrain_width
                    && excluded_terrain_row[size_t(terrain[i])]) {
                values[i] = 0.0f;
                continue;
            }
            if (excluded_veg_row != nullptr && int(veg[i]) < excluded_veg_width
                    && excluded_veg_row[size_t(veg[i])]) {
                values[i] = 0.0f;
                continue;
            }
            const double temp_v = double(temp[i]);
            const double moisture = double(moist[i]);
            const double tn = clampd((temp_v - p.temp_lo) * p.inv_span, 0.0, 1.0);
            double suit = p.init_base + p.init_temp * tn + p.init_moisture * moisture;
            if (p.w_climate_fit != 0.0) {
                const double temp_fit = 1.0 - clampd(std::fabs(tn - p.climate_temp_opt)
                        / std::max(p.climate_temp_tol, 0.0001), 0.0, 1.0);
                const double moisture_fit =
                        1.0 - clampd(std::fabs(moisture - p.climate_moisture_opt)
                                / std::max(p.climate_moisture_tol, 0.0001), 0.0, 1.0);
                suit += p.w_climate_fit * temp_fit * moisture_fit;
            }
            if (p.use_elev) {
                suit += p.w_elev * clampd(double(elev[i]), 0.0, 1.0);
            }
            if (p.use_lf) {
                suit += lf_weights[size_t(r)].lookup(int32_t(lf[i]));
            }
            if (p.use_veg) {
                suit += veg_weights[size_t(r)].lookup(int32_t(veg[i]));
            }
            if (p.use_river) {
                const bool water_feature = (have_river && river[i] != 0)
                        || (have_lake && lake[i] != 0);
                if (water_feature) {
                    suit += p.w_river;
                }
            }
            if (p.use_volc && volcano[i] != 0) {
                suit += p.w_volc;
            }
            if (p.use_ocean_current) {
                const double speed = std::sqrt(double(ocean_x[i]) * double(ocean_x[i])
                        + double(ocean_y[i]) * double(ocean_y[i]));
                suit += p.w_ocean_current * clampd(speed, 0.0, 1.0);
            }
            if (p.use_upwelling) {
                suit += p.w_upwelling * clampd(double(upwelling[i]), 0.0, 1.0);
            }
            if (p.use_estuary) {
                suit += p.w_estuary * double(estuary[i]);
            }
            if (p.use_noise) {
                const double n01 =
                        (double(noise->get_noise_2d(pos_x[i], pos_y[i])) + 1.0) * 0.5;
                suit += p.w_noise * n01;
            }
            if (p.use_province) {
                const double province01 =
                        (double(province_noise->get_noise_2d(pos_x[i], pos_y[i])) + 1.0) * 0.5;
                suit += p.w_province * (province01 - 0.55) * 2.0;
            }
            if (p.use_belt) {
                const double ridge = 1.0
                        - std::fabs(double(belt_noise->get_noise_2d(pos_x[i], pos_y[i])));
                suit += p.w_belt * (ridge - 0.72) * 2.0;
            }
            values[i] = float(std::max(0.0, suit) * p.reserve_scale);
            if (p.floor_reserve > 0.0) {
                values[i] = std::max(values[i], float(p.floor_reserve));
            }
            if (collect_ranked) {
                ranked.push_back(RankedCell{suit, int32_t(i)});
            }
        }

        int target_cells;
        if (use_ranked_distribution) {
            target_cells = std::min<int>(int(ranked.size()),
                    int(std::ceil(double(ranked.size()) * p.target_coverage)));
        } else {
            target_cells = std::min<int>(int(ranked.size()),
                    int(std::ceil(double(ranked.size())
                            * clampd(p.min_coverage, 0.0, 1.0))));
        }

        if (target_cells > 0) {
            std::sort(ranked.begin(), ranked.end(),
                    [](const RankedCell &a, const RankedCell &b) {
                        if (a.suit != b.suit) return a.suit > b.suit;
                        return a.cell < b.cell;
                    });
            if (use_ranked_distribution) {
                for (const RankedCell &rc : ranked) {
                    values[rc.cell] = 0.0f;
                }
                const int micro_target = std::min<int>(int(ranked.size()) - target_cells,
                        int(std::ceil(double(ranked.size()) * p.micro_coverage)));
                std::vector<int32_t> micro_ranks;
                select_micro_cells(ranked, target_cells, micro_target, neighbors,
                        have_neighbors, n, micro_ranks);

                const double minimum_reserve =
                        std::max(p.floor_reserve, p.min_reserve);
                const double micro_minimum_reserve =
                        std::max(p.micro_min_reserve, 0.0);
                const double reserve_density =
                        std::max(p.target_reserve_density, 0.0);
                const double target_mean_reserve =
                        std::max(p.target_mean_reserve, 0.0);

                if (reserve_density > 0.0 || target_mean_reserve > 0.0) {
                    const double target_total_reserve = reserve_density > 0.0
                            ? reserve_density * double(ranked.size())
                            : target_mean_reserve * double(target_cells);
                    const double core_floor_total = minimum_reserve * double(target_cells);
                    const double micro_floor_total =
                            micro_minimum_reserve * double(micro_ranks.size());
                    const double total_reserve = std::max(target_total_reserve,
                            core_floor_total + micro_floor_total);
                    double micro_budget = micro_ranks.empty() ? 0.0
                            : total_reserve * clampd(p.micro_reserve_share, 0.0, 0.5);
                    micro_budget = std::max(micro_budget, micro_floor_total);
                    micro_budget = std::min(micro_budget, total_reserve - core_floor_total);

                    std::vector<int32_t> core_ranks;
                    core_ranks.resize(size_t(target_cells));
                    for (int rank = 0; rank < target_cells; ++rank) {
                        core_ranks[size_t(rank)] = int32_t(rank);
                    }
                    allocate_ranked_budget(values, ranked, core_ranks,
                            total_reserve - micro_budget, minimum_reserve,
                            std::max(p.richness_exponent, 0.1));
                    allocate_ranked_budget(values, ranked, micro_ranks, micro_budget,
                            micro_minimum_reserve, 0.65);
                } else {
                    for (int rank = 0; rank < target_cells; ++rank) {
                        const int32_t cell = ranked[size_t(rank)].cell;
                        values[cell] = std::max(values[cell], float(minimum_reserve));
                    }
                    for (size_t k = 0; k < micro_ranks.size(); ++k) {
                        const int32_t cell = ranked[size_t(micro_ranks[k])].cell;
                        values[cell] = std::max(values[cell], float(micro_minimum_reserve));
                    }
                }
            } else {
                const double minimum = p.min_reserve;
                for (int rank = 0; rank < target_cells; ++rank) {
                    const int32_t cell = ranked[size_t(rank)].cell;
                    values[cell] = std::max(values[cell], float(minimum));
                }
            }
        }

        // ── 大陆保底配额：只对 continent_floor_cells>0 的资源；两种分布分支都已算完。
        // 判据是「储量 ≥ min_reserve 的格数」，不是「>0 的格数」——散布型的零头格本来
        // 就该算作没矿。补的格直接写 values[cell]，不进 allocate_ranked_budget：
        // 不动 cutoff_suit、不改已入选格，只可能把零头抬到最小真矿（逐格只增不减）。
        // float 与 float 比：floor_v 与 values[] 同为 float32，写进去的就是同一个值。
        const float floor_v = float(p.min_reserve);
        if (p.continent_floor_cells > 0.0 && p.min_reserve > 0.0
                && have_landmass && !ranked.empty() && continent_floor > 0) {
            const int floor_n = std::max(1, int(std::lround(p.continent_floor_cells)));
            std::vector<int32_t> have(landmass_size.size(), 0);
            std::vector<int32_t> need(landmass_size.size(), 0);
            int total_need = 0;
            for (int i = 0; i < n; ++i) {
                const int32_t l = landmass_of[size_t(i)];
                if (l > 0 && values[i] >= floor_v) ++have[size_t(l)];
            }
            for (size_t l = 1; l < landmass_size.size(); ++l) {
                // 配额资格门槛：用独立的 kMinQuotaCells，不用 continent_floor。
                // 礁石/碎岛仍不算；但 37/33/11 格这种「够不上大陆、却真缺矿」的陆块
                // 现在参与配额。大陆定义（continent_floor）一个字没动。
                if (landmass_size[l] < kMinQuotaCells) continue;
                const int q = std::min(floor_n,
                        std::max(1, int(std::ceil(0.01 * double(landmass_size[l])))));
                if (have[l] < q) {
                    need[l] = q - have[l];
                    total_need += need[l];
                }
            }
            for (size_t rank = 0; rank < ranked.size() && total_need > 0; ++rank) {
                const int32_t cell = ranked[rank].cell;
                const int32_t l = landmass_of[size_t(cell)];
                if (l <= 0 || need[size_t(l)] <= 0) continue;
                if (values[cell] >= floor_v) continue;
                values[cell] = floor_v;
                --need[size_t(l)];
                --total_need;
                ++quota_added;
            }
            // 遍历完 ranked 还没补满 → 必须报出来，不许悄悄降级。
            quota_unmet += total_need;
        }
        quota_field_cells[r] = quota_added;
        quota_cells_total += quota_added;
        quota_unmet_total += quota_unmet;

        reserves[r] = arr;
    }

    const double elapsed_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t_start).count();
    out["ok"] = true;
    out["elapsed_ms"] = elapsed_ms;
    out["fields"] = field_names;
    out["reserves"] = reserves;
    // A6 诊断（不进存档、不进 state hash）：quota_unmet > 0 = 该图保底没做到。
    out["quota_fields"] = quota_fields;
    out["quota_cells"] = quota_cells_total;
    out["quota_unmet"] = quota_unmet_total;
    out["quota_skipped"] = have_landmass ? 0 : 1;
    return out;
}

} // namespace pk
