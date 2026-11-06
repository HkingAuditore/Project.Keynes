// One-line forwards from the public Economy API to NativeEconomyRuntime.
// No logic lives here: each function calls exactly one member, unchanged.
#include "economy_api.h"
#include "economy_runtime.h"

namespace pk {
namespace economy_api {

bool valid_family_effect_entity_handle(const NativeEconomyRuntime &economy,
                                       uint64_t handle) {
    return economy.valid_family_effect_entity_handle(handle);
}

bool valid_family_effect_target_handle(const NativeEconomyRuntime &economy,
                                       uint64_t handle) {
    return economy.valid_family_effect_target_handle(handle);
}

int32_t preflight_effect_commands_pod(const NativeEconomyRuntime &economy,
                                      const EconomyApi::EffectCommand *commands,
                                      size_t count, std::string &error) {
    return economy.preflight_effect_commands_pod(commands, count, error);
}

bool submit_effect_commands_pod(NativeEconomyRuntime &economy,
                                const EconomyApi::EffectCommand *commands,
                                size_t count, std::vector<int64_t> &request_ids,
                                std::string &error) {
    return economy.submit_effect_commands_pod(commands, count, request_ids, error);
}

bool effect_command_result_pod(const NativeEconomyRuntime &economy,
                               int64_t request_id, bool &complete, bool &ok,
                               std::string &reason) {
    return economy.effect_command_result_pod(request_id, complete, ok, reason);
}

const EconomyApi::CountryClassOpinionSnapshot &country_class_opinion_snapshot(
        const NativeEconomyRuntime &economy) {
    return economy.country_class_opinion_snapshot();
}

int32_t cell_country_slot(const NativeEconomyRuntime &economy, int32_t cell) {
    return economy.cell_country_slot(cell);
}

int32_t family_target_min_branches_for_test(
        const NativeEconomyRuntime &economy, int32_t authored_min) {
    return economy.family_target_min_branches_for_test(authored_min);
}

void collect_family_effect_target_handles(
        const NativeEconomyRuntime &economy, int32_t country_slot,
        int32_t min_branches, int32_t cap,
        std::vector<uint64_t> &out_handles) {
    economy.collect_family_effect_target_handles(
        country_slot, min_branches, cap, out_handles);
}

int32_t country_anchor_cell(const NativeEconomyRuntime &economy,
                            int32_t country_slot) {
    return economy.country_anchor_cell(country_slot);
}

int32_t target_tag_count(const NativeEconomyRuntime &economy) {
    return economy.target_tag_count();
}

void collect_own_tagged_cells(const NativeEconomyRuntime &economy,
                              int32_t country_slot, int32_t tag,
                              std::vector<int32_t> &out_cells) {
    economy.collect_own_tagged_cells(country_slot, tag, out_cells);
}

int32_t cell_count(const NativeEconomyRuntime &economy) {
    return economy.cell_count();
}

int32_t building_neighbor(const NativeEconomyRuntime &economy, int32_t cell,
                          int32_t direction) {
    return economy.building_neighbor(cell, direction);
}

void collect_effect_target_cells(
        const NativeEconomyRuntime &economy, int32_t source_cell,
        int32_t selector_kind, int32_t param0, int32_t param1,
        std::vector<int32_t> &out_cells, uint64_t selection_salt,
        EffectSelectorStats *stats) {
    economy.collect_effect_target_cells(source_cell, selector_kind, param0,
                                        param1, out_cells, selection_salt,
                                        stats);
}

void dilate_cell_set(const NativeEconomyRuntime &economy,
                     const std::vector<int32_t> &sources, int32_t depth,
                     std::vector<int32_t> &out_cells) {
    economy.dilate_cell_set(sources, depth, out_cells);
}

void sample_effect_metrics(const NativeEconomyRuntime &economy, int32_t cell,
                           int32_t metric_count, int64_t *out_metrics,
                           const MetricMask &metric_mask) {
    economy.sample_effect_metrics(cell, metric_count, out_metrics, metric_mask);
}

void set_effect_input_consumers(
        NativeEconomyRuntime &economy, const MetricMask &cell_metrics,
        bool tags_needed, bool families_needed,
        const std::array<std::vector<int64_t>, EconomyApi::FAMILY_METRIC_COUNT>
            &metric_thresholds,
        const std::vector<int32_t> &tag_ids) {
    economy.set_effect_input_consumers(
        cell_metrics, tags_needed, families_needed, metric_thresholds, tag_ids);
}

std::shared_ptr<const EffectInputSnapshot> effect_input_snapshot(
        const NativeEconomyRuntime &economy) {
    return economy.effect_input_snapshot();
}

uint64_t effect_input_revision(const NativeEconomyRuntime &economy) {
    return economy.effect_input_revision();
}

uint64_t committed_generation(const NativeEconomyRuntime &economy) {
    return economy.committed_generation();
}

void notify_era_milestone_activated(NativeEconomyRuntime &economy,
                                    uint64_t country_handle) {
    economy.notify_era_milestone_activated(country_handle);
}

} // namespace economy_api
} // namespace pk
