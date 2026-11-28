#pragma once

#include "runtime_pod_protocol.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

namespace pk {

struct RuntimeVisionFrame;
struct RuntimeClimateSnapshot;
struct RuntimeValleyFogFrame;
struct RuntimeEffectReadView;
struct RuntimeEraRewardView;
struct RuntimeNarrativeView;
struct RuntimeGoldenSnapshot;
struct RuntimeModifierPodSnapshot;
struct RuntimeEraAdvancementView;
struct RuntimeIdeologyReadView;
struct RuntimeGdpDisplay;
class TriggerRuntime;
class NativeIdeologyRuntime;

struct RuntimeTriggerDelivery {
    TriggerRuntime *runtime = nullptr;
    NativeIdeologyRuntime *ideology = nullptr;
    std::shared_ptr<const TriggerRuntime> initial_view;
    std::shared_ptr<const RuntimeIdeologyReadView> initial_ideology_view;
    bool research_reconciled = false;
};

struct RuntimeResourceDisplayPatch {
    // Cell-major. Each pending cell appears once with its latest values.
    std::unordered_map<int32_t, size_t> offsets;
    std::vector<int32_t> cells;
    std::vector<float> reserve;
    std::vector<float> extra;
};

// A producer-built snapshot of all display changes since the last take.
struct RuntimeDisplayBatch {
    std::shared_ptr<const RuntimeCommit> commit;
    godot::Array records;
    godot::Array notices;
    godot::Array receipts;
    godot::Array construction_receipts;
    godot::Array colonization_receipts;
    godot::Dictionary gdp, fiscal_history;
    godot::PackedInt32Array changed_cells, changed_classes;
    RuntimeResourceDisplayPatch resources;
    std::vector<uint8_t> cell_flags;
};

struct RuntimeCellLutFrame {
    std::vector<uint8_t> previous_vitality;
    std::vector<uint8_t> transition_age;
};

godot::Array pack_runtime_receipts(const std::vector<RuntimeCommandReceipt> &receipts);

struct RuntimeDayTail {
    int32_t resource_recovery_cells = 0;
    int32_t species_diffused_cells = 0;
    int64_t species_introductions_consumed = 0;
    std::vector<int32_t> occupancy;
    std::shared_ptr<const RuntimeVisionFrame> vision;
    std::shared_ptr<const RuntimeClimateSnapshot> climate;
    std::shared_ptr<const RuntimeValleyFogFrame> valley_fog;
    RuntimeCountryReadView country;
    std::shared_ptr<const RuntimeGdpDisplay> gdp;
    std::shared_ptr<const RuntimeModifierPodSnapshot> modifier;
    RuntimeCellLutFrame cell_luts;
    std::vector<RuntimeNotice> notices;
    int32_t military_trail_cells = 0;
    int32_t vision_observations = 0;
    int32_t species_observations = 0;
    bool vision_solved = false;
    std::shared_ptr<const RuntimeEffectReadView> effect;
    std::shared_ptr<const RuntimeEraRewardView> era_reward;
    std::shared_ptr<const RuntimeNarrativeView> narrative;
    std::shared_ptr<const RuntimeGoldenSnapshot> golden;
    std::shared_ptr<const RuntimeEraAdvancementView> era_advancement;
    std::shared_ptr<const TriggerRuntime> trigger;
    std::shared_ptr<const RuntimeIdeologyReadView> ideology;
};

} // namespace pk
