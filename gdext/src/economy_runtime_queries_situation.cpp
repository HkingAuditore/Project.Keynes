#include "economy_cell_class_satisfaction.h"

#include <algorithm>
#include <array>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;

Dictionary NativeEconomyRuntime::cell_situation_snapshot(
        const PackedInt32Array &requested_cells) const {
    // Presentation only. Keep slots 4/5 for current visible drought/flood,
    // which the map consumer reads from the published climate view.
    constexpr int32_t STRIDE = 8;
    constexpr int32_t MAX_CELLS = 128;
    Dictionary out;
    out["ok"] = false;
    out["economy_generation"] = static_cast<int64_t>(_committed_generation);
    out["sample_day"] = _last_committed_day.get();
    out["snapshot_source"] = "committed";
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    if (!_bootstrapped || _fatal || _epoch_active) {
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            (_fatal ? "economy_fatal" : "economy_busy_retry");
        return out;
    }
    if (requested_cells.size() > MAX_CELLS) {
        out["reason"] = "situation_cell_limit_exceeded";
        return out;
    }
    for (int32_t row = 0; row < requested_cells.size(); ++row) {
        if (requested_cells[row] < 0 || requested_cells[row] >= _cell_count.get()) {
            out["reason"] = "cell_out_of_range";
            return out;
        }
    }
    const int32_t goods = market_store().good_count.get();
    // Catalog derivation is done once per bounded batch, never once per cell.
    // Need tiers supply semantics; commodity filenames/categories do not.
    std::vector<uint8_t> household_kind(static_cast<size_t>(goods), 0);
    for (const Need &need : _needs) {
        const uint8_t bit = need.satisfaction_tier <= SAT_DIM_BASIC ? 1 : 2;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const VariantChoice &variant = _variants[need.variant_begin + v];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const int32_t good = _components[variant.component_begin + c].good_id;
                if (good >= 0 && good < goods) household_kind[good] |= bit;
            }
        }
    }
    PackedByteArray flags;
    PackedInt32Array severity, causes, worst_classes;
    PackedInt64Array state_days;
    // Per-cell class headcount, row-major (requested cell x political class). The
    // ideology panel turns this into cell-level support: the same
    // influence-weighted stance, just with the local class mix instead of the
    // national one. Bounded by the requested cells, never a global table.
    PackedInt64Array class_population;
    PackedInt32Array mobilization_stage, mobilization_org;
    const int32_t count = static_cast<int32_t>(requested_cells.size());
    flags.resize(count);
    severity.resize(count * STRIDE);
    causes.resize(count * 3);
    causes.fill(-1);
    worst_classes.resize(count);
    worst_classes.fill(-1);
    state_days.resize(count);
    EconomyCellClassSatisfaction class_satisfaction(_political_class_ids.size());
    int64_t scanned_cohorts = 0, scanned_goods = 0, scanned_groups = 0;
    for (int32_t row = 0; row < count; ++row) {
        const int32_t cell = requested_cells[row];
        const int32_t base = row * STRIDE;
        state_days[row] = _cell_last_settlement_day[cell];
        int32_t mob_stage = 0;
        int32_t mob_org = 0;
        if (_stratum_mobilization.cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get()) + 1u) {
            const int32_t mob_begin =
                _stratum_mobilization.cell_offsets[static_cast<size_t>(cell)];
            const int32_t mob_end =
                _stratum_mobilization.cell_offsets[static_cast<size_t>(cell) + 1u];
            for (int32_t i = mob_begin; i < mob_end; ++i) {
                const StratumMobilizationRow &mob_row =
                    _stratum_mobilization.rows[static_cast<size_t>(i)];
                if (mob_row.stage > mob_stage) mob_stage = mob_row.stage;
                if (mob_row.mobilization_q16 > mob_org)
                    mob_org = mob_row.mobilization_q16;
            }
        }
        mobilization_stage.append(mob_stage);
        mobilization_org.append(mob_org);
        class_satisfaction.clear();
        int64_t people = 0, unemployed = 0, sat = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            ++scanned_cohorts;
            const int64_t pop = std::max<int64_t>(0, population_store().population[slot]);
            if (pop <= 0) return;
            people = saturating_add(people, pop, sat);
            const int64_t employed = saturating_add(
                std::max<int64_t>(0, population_store().owner_employed[slot]),
                std::max<int64_t>(0, population_store().employee_employed[slot]), sat);
            unemployed = saturating_add(unemployed, std::max<int64_t>(0, pop - employed), sat);
            const int32_t signature = population_store().signature_id[slot];
            class_satisfaction.accumulate(_signatures[signature].profession_id,
                _profession_political_class_index, pop,
                population_store().composite_satisfaction[slot], sat, saturating_add, saturating_mul);
        });
        for (const int64_t class_headcount : class_satisfaction.headcounts)
            class_population.append(class_headcount);
        const auto worst = class_satisfaction.worst();
        worst_classes[row] = worst.class_index;
        severity[base + 3] = worst.severity_q16;
        const int32_t market = market_store().cell_to_market[cell];
        if (people > 0) {
            severity[base + 6] = static_cast<int32_t>(std::clamp<int64_t>(
                mul_div_sat(unemployed, Q16_ONE, people, sat), 0, Q16_ONE - 1));
            for (int32_t good = 0; good < goods; ++good) {
                ++scanned_goods;
                const int64_t index = market_store().index(market, good);
                const int32_t shortage = market_store().last_shortage_q16[index];
                if (shortage <= 0) continue;
                const int32_t kind = (household_kind[good] & 1) ? 0 :
                    ((household_kind[good] & 2) ? 2 : -1);
                if (kind >= 0 && shortage > severity[base + kind]) {
                    severity[base + kind] = shortage;
                    causes[row * 3 + kind] = good;
                }
            }
        }
        // Industrial pressure uses actual recipe/maintenance reservations,
        // not household shortage or empty inventories of unused goods.
        if (_market_signals.cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t signal = _market_signals.cell_offsets[cell];
                 signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
                const int32_t good = _market_signals.good_ids[signal];
                const int64_t input = static_cast<size_t>(signal) < _production_input_reserve.size()
                    ? _production_input_reserve[signal] : 0;
                const int64_t construction = static_cast<size_t>(signal) < _construction_material_reserve.size()
                    ? _construction_material_reserve[signal] : 0;
                const int64_t required = std::max(input, construction);
                if (required <= 0) continue;
                const int64_t stock = std::max<int64_t>(0, market_store().stock[market_store().index(market, good)]);
                const int32_t gap = static_cast<int32_t>(std::clamp<int64_t>(
                    mul_div_sat(std::max<int64_t>(0, required - stock), Q16_ONE,
                                required, sat), 0, Q16_ONE - 1));
                if (gap > severity[base + 1]) {
                    severity[base + 1] = gap;
                    causes[row * 3 + 1] = good;
                }
            }
        }
        int64_t capacity = 0, filled = 0;
        if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t group = _building_cell_offsets[cell];
                 group < _building_cell_offsets[cell + 1]; ++group) {
                ++scanned_groups;
                group_job_totals(building_view(static_cast<size_t>(group)), capacity, filled, sat);
            }
        }
        if (capacity > 0) severity[base + 7] = static_cast<int32_t>(std::clamp<int64_t>(
            mul_div_sat(std::max<int64_t>(0, capacity - filled), Q16_ONE, capacity, sat),
            0, Q16_ONE - 1));
        uint8_t mask = 0;
        for (int32_t kind = 0; kind < STRIDE; ++kind) {
            // 25% stock/job gaps, 20% unemployment, class composite below 40%.
            const int64_t threshold = kind == 3 ? EconomyCellClassSatisfaction::DISCONTENT_THRESHOLD :
                (kind == 6 ? Q16_ONE / 5 : Q16_ONE / 4);
            if (severity[base + kind] >= threshold) mask |= static_cast<uint8_t>(1U << kind);
        }
        flags[row] = mask;
    }
    PackedStringArray class_ids;
    for (const auto &id : _political_class_ids) class_ids.push_back(String(id.c_str()));
    out["ok"] = true;
    out["cell_indices"] = requested_cells;
    out["flags"] = flags;
    out["severity_q16"] = severity;
    out["severity_stride"] = STRIDE;
    out["cause_good_ids"] = causes;
    out["worst_class_ids"] = worst_classes;
    out["class_ids"] = class_ids;
    out["class_count"] = static_cast<int32_t>(_political_class_ids.size());
    out["class_population"] = class_population;
    out["state_days"] = state_days;
    out["mobilization_stage"] = mobilization_stage;
    out["mobilization_q16"] = mobilization_org;
    out["scanned_cohorts"] = scanned_cohorts;
    out["scanned_goods"] = scanned_goods;
    out["scanned_groups"] = scanned_groups;
    return out;
}
} // namespace pk
