#include "economy_runtime.h"

#include <algorithm>
#include <tuple>

namespace pk {

void NativeEconomyRuntime::add_colonization_kit_cargo(
        ColonizationKitPlan &kit, int32_t good_id, int64_t quantity,
        uint8_t flags, int64_t &sat) const {
    if (good_id < 0 || quantity <= 0) return;
    for (FamilyExpeditionCargoLine &line : kit.cargo) {
        if (line.good_id == good_id && line.flags == flags) {
            line.quantity = saturating_add(line.quantity, quantity, sat);
            return;
        }
    }
    kit.cargo.push_back({good_id, quantity, flags});
}

void NativeEconomyRuntime::sort_colonization_kit_cargo(
        ColonizationKitPlan &kit) const {
    std::sort(kit.cargo.begin(), kit.cargo.end(),
        [](const FamilyExpeditionCargoLine &a,
           const FamilyExpeditionCargoLine &b) {
            return std::tie(a.flags, a.good_id) < std::tie(b.flags, b.good_id);
        });
}

bool NativeEconomyRuntime::extract_family_expedition_cargo(
        int32_t expedition, const ColonizationKitPlan &kit,
        std::string &error) {
    // Procurement has already populated the expedition cargo range. Only the
    // frozen building plan is attached here.
    error.clear();
    const uint32_t cargo_begin =
        family_expeditions_store().cargo_begin[expedition];
    const uint32_t cargo_count =
        family_expeditions_store().cargo_count[expedition];
    if (static_cast<size_t>(cargo_begin) + cargo_count >
            family_expedition_cargo().size()) {
        error = "colonization_cargo_range_invalid";
        return false;
    }
    family_expeditions_store().kit_building_begin.write_scalar(expedition, static_cast<uint32_t>(
        family_expedition_kit_buildings().size()), market_mutation_sink());
    if (kit.place_buildings != 0) {
        family_expedition_kit_buildings().insert(
            family_expedition_kit_buildings().end(),
            kit.buildings.begin(), kit.buildings.end());
        family_expeditions_store().kit_building_count.write_scalar(expedition, static_cast<uint32_t>(kit.buildings.size()), market_mutation_sink());
    } else {
        family_expeditions_store().kit_building_count.write_scalar(expedition, 0, market_mutation_sink());
    }
    return true;
}

bool NativeEconomyRuntime::restore_family_expedition_cargo(
        int32_t expedition, int32_t destination_cell, bool consume_construction,
        std::string &error) {
    const uint32_t begin = family_expeditions_store().cargo_begin[expedition];
    const uint32_t count = family_expeditions_store().cargo_count[expedition];
    const uint32_t end = begin + count;
    if (end > family_expedition_cargo().size()) {
        error = "colonization_cargo_range_invalid";
        return false;
    }
    int64_t construction_consumed = 0;
    for (uint32_t i = begin; i < end; ++i) {
        const FamilyExpeditionCargoLine &line = family_expedition_cargo()[i];
        if (consume_construction &&
            line.flags == EXPEDITION_CARGO_CONSTRUCTION) {
            construction_consumed = saturating_add(construction_consumed,
                line.quantity, _saturation_count);
            continue;
        }
        if (!adjust_market_stock(destination_cell, line.good_id, line.quantity,
                error))
            return false;
    }
    family_expeditions_store().cargo_count.write_scalar(expedition, 0, market_mutation_sink());
    // Idle/opening-prelude settlements belong to the next opening baseline.
    if (construction_consumed > 0 && _epoch_active)
        _construction_goods_consumed = saturating_add(
            _construction_goods_consumed, construction_consumed,
            _saturation_count);
    return true;
}

} // namespace pk
