#pragma once

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

namespace pk {

struct RuntimeVisionFrame;
struct RuntimeEffectReadView;
struct RuntimeEraRewardView;
struct RuntimeNarrativeView;
struct RuntimeGoldenSnapshot;
struct RuntimeEraAdvancementView;
struct RuntimeIdeologyReadView;
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

struct RuntimeDayTail {
    int32_t resource_recovery_cells = 0;
    int32_t species_diffused_cells = 0;
    int64_t species_introductions_consumed = 0;
    std::vector<int32_t> occupancy;
    std::shared_ptr<const RuntimeVisionFrame> vision;
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
