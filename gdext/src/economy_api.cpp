// One-line forwards from the public Economy API to NativeEconomyRuntime.
// No logic lives here: each function calls exactly one member, unchanged.
#include "economy_api.h"
#include "economy_runtime.h"
#include "runtime_economy_display.h"

namespace pk {
namespace economy_api { bool military_purchase_receipt(const NativeEconomyRuntime &e, int64_t s, int64_t &q, int64_t &c) { return e.military_purchase_receipt(s, q, c); } }
namespace economy_api {

std::vector<RuntimeGdpCell> capture_settlement_output(
        const NativeEconomyRuntime &economy, uint64_t country) {
    return economy.capture_settlement_output(country);
}

godot::Dictionary fiscal_snapshot(const NativeEconomyRuntime &economy, int64_t country) {
    return economy.fiscal_snapshot(country);
}

EconomyNaturalResourceCatalogView natural_resource_catalog(const NativeEconomyRuntime &economy) {
    return economy.natural_resource_catalog();
}

void configure_natural_resources(NativeEconomyRuntime &economy,
                                 const std::vector<EconomyNaturalResourceProfile> &profiles) {
    economy.configure_worker_natural_resources(profiles);
}

bool natural_resources_configured(const NativeEconomyRuntime &economy) {
    return economy.worker_natural_resources_configured();
}

bool natural_resources_seeded(const NativeEconomyRuntime &economy) {
    return economy.worker_resource_seeded();
}

bool seed_natural_resources(NativeEconomyRuntime &economy, int64_t day,
                           const std::vector<const float *> &reserves,
                           const std::vector<const float *> &changes) {
    return economy.seed_worker_resource_reserves(day, reserves, changes);
}

godot::Dictionary detail_report(const NativeEconomyRuntime &economy) {
    return economy.report();
}
godot::Dictionary named_settlement_snapshot(const NativeEconomyRuntime &economy) {
    return economy.named_settlement_snapshot();
}
bool capture_trade_topology(NativeEconomyRuntime &economy, const int32_t *neighbors,
    const uint8_t *terrain, const uint8_t *canal_mask, const float *canal_water,
    const uint8_t *passable, const int32_t *move_cost, int32_t count,
    uint64_t generation, std::string &error, const uint8_t *landform, const uint8_t *river) {
    return economy.capture_trade_topology(neighbors, terrain, canal_mask, canal_water,
        passable, move_cost, count, generation, error, landform, river);
}
bool capture_trade_visibility(NativeEconomyRuntime &economy, const uint8_t *visible,
    int32_t count, bool solved, bool from_map, std::string &error) {
    return economy.capture_trade_visibility(visible, count, solved, from_map, error);
}

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

int64_t state_hash(const NativeEconomyRuntime &economy) { return economy.state_hash(); }
uint64_t golden_population_market_hash(const NativeEconomyRuntime &economy,
                                      int64_t sample_day, int64_t committed_day) {
    return economy.golden_population_market_hash(sample_day, committed_day);
}

void notify_era_milestone_activated(NativeEconomyRuntime &economy,
                                    uint64_t country_handle) {
    economy.notify_era_milestone_activated(country_handle);
}

// ---- Military (world_ext_military*.cpp, world_ext_economy_military.cpp)
void military_read_cell_view(const NativeEconomyRuntime &economy, EconomyMilitaryCellView &out, int32_t good_count) { economy.military_read_cell_view(out, good_count); }
void military_read_market(const NativeEconomyRuntime &economy, int32_t good,
    std::vector<int32_t> &cells, std::vector<int64_t> &sellable,
    std::vector<int64_t> &price, std::vector<uint8_t> &stocked) {
    economy.military_read_market(good, cells, sellable, price, stocked);
}
void military_read_equipment_production(const NativeEconomyRuntime &economy,
    const std::vector<int32_t> &cells, const std::vector<uint8_t> &equipment,
    std::vector<uint8_t> &out) {
    economy.military_read_equipment_production(cells, equipment, out);
}
int32_t military_soldier_profession(NativeEconomyRuntime &economy) { return economy.military_soldier_profession(); }
int32_t military_unemployed_profession(const NativeEconomyRuntime &economy) { return economy.military_unemployed_profession(); }
int32_t military_merchant_profession(const NativeEconomyRuntime &economy) { return economy.military_merchant_profession(); }
int64_t military_soldier_living_cost(const NativeEconomyRuntime &economy, int32_t country_slot) { return economy.military_soldier_living_cost(country_slot); }
uint64_t military_cohort_handle_any_ethnicity(const NativeEconomyRuntime &economy, int32_t cell, int32_t profession_id) { return economy.military_cohort_handle_any_ethnicity(cell, profession_id); }
uint64_t military_cohort_handle_from_professions(const NativeEconomyRuntime &economy, int32_t cell, const int32_t *professions, int32_t count) { return economy.military_cohort_handle_from_professions(cell, professions, count); }
int64_t military_soldier_heads(const NativeEconomyRuntime &economy, int32_t cell) { return economy.military_soldier_heads(cell); }
int32_t military_cohort_signature(const NativeEconomyRuntime &economy, uint64_t handle) { return economy.military_cohort_signature(handle); }
int32_t military_cohort_ethnicity(const NativeEconomyRuntime &economy, uint64_t handle) { return economy.military_cohort_ethnicity(handle); }
int32_t military_signature_for_cell_ethnicity(const NativeEconomyRuntime &economy, int32_t cell, int32_t profession) { return economy.military_signature_for_cell_ethnicity(cell, profession); }
int32_t military_signature_for(const NativeEconomyRuntime &economy, int32_t profession_id, int32_t ethnicity_id) { return economy.military_signature_for(profession_id, ethnicity_id); }
int64_t military_collect_cash(NativeEconomyRuntime &economy, int64_t country_handle, int64_t amount) { return economy.military_collect_cash(country_handle, amount); }
bool military_command_window_open(const NativeEconomyRuntime &economy) { return economy.military_command_window_open(); }
int32_t set_military_ration_satisfaction(NativeEconomyRuntime &economy, const std::vector<int32_t> &cells, const std::vector<int32_t> &q16) { return economy.set_military_ration_satisfaction(cells, q16); }
int32_t set_military_cell_garrison(NativeEconomyRuntime &economy, const std::vector<int32_t> &cells, const std::vector<int32_t> &heads) { return economy.set_military_cell_garrison(cells, heads); }
void set_military_army_ration(NativeEconomyRuntime &economy, uint64_t army_handle, int32_t ration_q16) { economy.set_military_army_ration(army_handle, ration_q16); }
int64_t military_army_population(const NativeEconomyRuntime &economy, uint64_t army_handle) { return economy.military_army_population(army_handle); }
int64_t military_army_funds(const NativeEconomyRuntime &economy, uint64_t army_handle) { return economy.military_army_funds(army_handle); }
bool military_army_lane_split_supported(const NativeEconomyRuntime &economy) { return economy.military_army_lane_split_supported(); }
bool military_army_lane_pay_supported(const NativeEconomyRuntime &economy) { return economy.military_army_lane_pay_supported(); }
int32_t profession_count(const NativeEconomyRuntime &economy) { return economy.profession_count(); }
int64_t last_committed_day(const NativeEconomyRuntime &economy) { return economy.last_committed_day(); }
bool epoch_active(const NativeEconomyRuntime &economy) { return economy.epoch_active(); }
godot::Dictionary poll_events(const NativeEconomyRuntime &economy, const godot::Dictionary &opts) { return economy.poll_events(opts); }
godot::Dictionary trace_report(const NativeEconomyRuntime &economy) { return economy.trace_report(); }
bool set_cell_tag_override_for_test(NativeEconomyRuntime &economy, const std::string &tag_key, int32_t cell, bool on) { return economy.set_cell_tag_override_for_test(tag_key, cell, on); }
void clear_cell_tag_overrides_for_test(NativeEconomyRuntime &economy) { economy.clear_cell_tag_overrides_for_test(); }

// ---- State building and procurement bindings (world_ext_economy.cpp, world_ext_military.cpp)
bool military_read_state_buildings(const NativeEconomyRuntime &economy, std::vector<int32_t> &out_cells, std::vector<int32_t> &out_type_ids, std::vector<int32_t> &out_state_roles, std::vector<int64_t> &out_units) { return economy.military_read_state_buildings(out_cells, out_type_ids, out_state_roles, out_units); }
godot::Dictionary queue_treasury_sponsored_build(NativeEconomyRuntime &economy, int64_t country_handle, int32_t cell_idx, int32_t type_id, int64_t effective_day, int64_t sequence, bool queue_for_worker, bool military_order) { return economy.queue_treasury_sponsored_build(country_handle, cell_idx, type_id, effective_day, sequence, queue_for_worker, military_order); }
godot::Dictionary queue_treasury_sponsored_demolish(NativeEconomyRuntime &economy, int64_t country_handle, int32_t cell_idx, int32_t type_id, int64_t count, int64_t effective_day, int64_t sequence, bool queue_for_worker, bool military_order) { return economy.queue_treasury_sponsored_demolish(country_handle, cell_idx, type_id, count, effective_day, sequence, queue_for_worker, military_order); }
godot::Dictionary family_colonization_quotes(NativeEconomyRuntime &economy,
    int64_t country, int32_t target, int64_t family, int32_t source, int32_t offset, int32_t limit,
    const uint8_t *visible, int32_t visible_count, uint64_t vision_revision) {
    return economy.family_colonization_quotes(country, target, family, source, offset, limit,
        visible, visible_count, vision_revision);
}
godot::Dictionary family_colonization_quote_detail(const NativeEconomyRuntime &economy,
    int64_t quote, int64_t population) {
    return economy.family_colonization_quote_detail(quote, population);
}
godot::Dictionary submit_family_colonization_start(NativeEconomyRuntime &economy,
    int64_t country, int64_t family, int32_t source, int32_t target, int64_t population,
    int64_t quote, int64_t day, int64_t sequence, const uint8_t *visible,
    int32_t visible_count, uint64_t vision_revision, bool queue_for_worker) {
    return economy.submit_family_colonization_start(country, family, source, target, population,
        quote, day, sequence, visible, visible_count, vision_revision, queue_for_worker);
}
godot::Dictionary country_procurement_snapshot(const NativeEconomyRuntime &economy, int64_t country) {
    return economy.country_procurement_snapshot(country);
}
godot::Dictionary submit_family_colonization_cancel(NativeEconomyRuntime &economy,
    int64_t country, int64_t expedition, int64_t day, int64_t sequence) {
    return economy.submit_family_colonization_cancel(country, expedition, day, sequence, true);
}
int32_t player_family_founding_offer(const NativeEconomyRuntime &economy) {
    return economy.player_family_founding_offer();
}
godot::Dictionary family_founding_offer(const NativeEconomyRuntime &economy, int32_t offset) {
    return economy.family_founding_offers(offset, 1);
}
godot::Dictionary submit_family_founding_choice(NativeEconomyRuntime &economy,
    int64_t offer, int64_t generation, int32_t choice, int64_t day, int64_t sequence,
    bool check_now) {
    return economy.submit_family_founding_choice(offer, generation, choice, day, sequence, check_now);
}
godot::Array take_family_founding_receipts(NativeEconomyRuntime &economy) {
    return economy.take_family_founding_receipts();
}
godot::Dictionary queue_canal_construction(NativeEconomyRuntime &economy,
    int64_t country, int64_t quote, int64_t day, int64_t sequence) {
    return economy.queue_canal_construction(country, quote, day, sequence);
}
godot::Dictionary era_advancement_economy_summary(const NativeEconomyRuntime &economy, int64_t country) {
    return economy.country_economy_overview(country, "summary", -1, -1, 0, 64);
}
godot::Dictionary set_era_procurement_target(NativeEconomyRuntime &economy,
        int64_t country, bool active, const godot::PackedInt32Array &goods,
        const godot::PackedInt64Array &quantities, int64_t day, int64_t sequence) {
    return economy.set_era_procurement_target(country, active, goods, quantities, day, sequence);
}
godot::Dictionary set_country_procurement_policy(NativeEconomyRuntime &economy, int64_t country_handle, bool enabled, int32_t treasury_share_bp, int32_t research_share_bp, int64_t effective_day, int64_t sequence, int32_t era_share_bp, int32_t colonization_share_bp) { return economy.set_country_procurement_policy(country_handle, enabled, treasury_share_bp, research_share_bp, effective_day, sequence, era_share_bp, colonization_share_bp); }
bool trade_topology_ready_for_test(const NativeEconomyRuntime &economy) { return economy.trade_topology_ready_for_test(); }
bool trade_passable_for_test(const NativeEconomyRuntime &economy, int32_t cell) { return economy.trade_passable_for_test(cell); }
bool epoch_active_for_test(const NativeEconomyRuntime &economy) { return economy.epoch_active_for_test(); }

} // namespace economy_api
} // namespace pk
