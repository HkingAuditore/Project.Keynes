#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_core_apply.h"

#include <algorithm>

namespace pk {

using namespace godot;

Dictionary NativeCountryRuntime::configure(const Dictionary &catalog,
                                            const Dictionary &profile,
                                            int32_t cell_count, int64_t seed) {
    if (cell_count <= 0) return fail("country_cell_count_invalid");
    const std::vector<std::string> goods = packed_strings(catalog, "good_ids");
    const std::vector<std::string> professions =
        packed_strings(catalog, "profession_ids");
    const std::vector<std::string> building_types =
        packed_strings(catalog, "building_type_ids");
    const std::vector<std::string> technologies = packed_strings(catalog, "technology_ids");
    const std::vector<std::string> research_signals =
        packed_strings(catalog, "research_signal_ids");
    if (goods.empty() || professions.empty() || building_types.empty())
        return fail("country_tax_catalog_empty");

    std::unordered_set<std::string> unique;
    for (const std::string &id : goods)
        if (id.empty() || !unique.insert(id).second) return fail("country_good_catalog_invalid");
    unique.clear();
    for (const std::string &id : professions)
        if (id.empty() || !unique.insert(id).second)
            return fail("country_profession_catalog_invalid");
    unique.clear();
    for (const std::string &id : building_types)
        if (id.empty() || !unique.insert(id).second)
            return fail("country_building_catalog_invalid");
    unique.clear();
    for (const std::string &id : technologies)
        if (id.empty() || !unique.insert(id).second) return fail("country_technology_catalog_invalid");
    unique.clear();
    for (const std::string &id : research_signals)
        if (id.empty() || !unique.insert(id).second)
            return fail("country_research_signal_catalog_invalid");

    std::string mode = dict_string(profile, "country_runtime_mode", "ACTIVE");
    RuntimeMode parsed_mode = MODE_ACTIVE;
    if (mode == "OFF") parsed_mode = MODE_OFF;
    else if (mode == "PROBE") parsed_mode = MODE_PROBE;
    else if (mode != "ACTIVE") return fail("country_runtime_mode_invalid");
    const bool light_report_explicit = profile.has("country_light_report_enabled");
    _light_report_enabled = dict_num<bool>(
        profile, "country_light_report_enabled", true);
    // Direct Native callers and historical tests may only provide the runtime
    // mode. Keep that legacy contract FULL; the formal CountryProfile always
    // supplies the transient LIGHT switch explicitly for production ACTIVE.
    _full_diagnostics = parsed_mode == MODE_PROBE ||
        dict_num<bool>(profile, "country_full_diagnostics", false) ||
        !_light_report_enabled || !light_report_explicit;
    _pending_queue_enabled = dict_num<bool>(
        profile, "country_pending_queue_enabled", true);
    _state_hash_cache_valid = false;
    _pending_activation_index_dirty = true;
    _pending_activation_indices.clear();
    _pending_activation_count = 0;
    _research_queue_rebuilds = 0;
    _research_full_scan_fallbacks = 0;
    _research_discovery_frontier_mismatches = 0;
    _research_queue_fallback_reason.clear();

    _good_ids = goods;
    _profession_ids = professions;
    _building_type_ids = building_types;
    _technology_ids = technologies;
    _technology_catalog_identity_hash = static_cast<uint64_t>(
        dict_num<int64_t>(catalog, "technology_catalog_identity_hash", 0));
    _technology_content_binding_hash = static_cast<uint64_t>(
        dict_num<int64_t>(catalog, "technology_content_binding_hash", 0));
    _technology_trigger_definition_hash = static_cast<uint64_t>(
        dict_num<int64_t>(catalog, "technology_trigger_definition_hash", 0));
    if (_technology_catalog_identity_hash == 0 ||
        _technology_content_binding_hash == 0 ||
        _technology_trigger_definition_hash == 0)
        return fail("country_technology_catalog_identity_missing");
    _technology_era_reward_pool_ids = packed_strings(
        catalog, "technology_era_reward_pool_ids");
    _research_signal_ids = research_signals;
    _political_regime_ids = packed_strings(catalog, "political_regime_ids");
    std::vector<int32_t> authored_regime_caps = packed_i32(
        catalog, "political_regime_capability_bits");
    if (_political_regime_ids.empty()) {
        _political_regime_ids = {"local_council", "early_clan"};
        authored_regime_caps = {0, static_cast<int32_t>(CAP_TREASURY_CONSTRUCTION)};
    }
    if (authored_regime_caps.size() != _political_regime_ids.size())
        return fail("political_regime_catalog_shape_invalid");
    _political_regime_index.clear();
    _political_regime_capability_bits.clear();
    for (size_t i = 0; i < _political_regime_ids.size(); ++i) {
        if (_political_regime_ids[i].empty() ||
            !_political_regime_index.emplace(_political_regime_ids[i],
                                              static_cast<int32_t>(i)).second ||
            authored_regime_caps[i] < 0)
            return fail("political_regime_catalog_invalid");
        _political_regime_capability_bits.push_back(
            static_cast<uint32_t>(authored_regime_caps[i]));
    }
    _political_regime_catalog_hash = static_cast<uint64_t>(dict_num<int64_t>(
        catalog, "political_regime_catalog_hash", 0));
    if (_political_regime_catalog_hash == 0) {
        uint64_t hash = FNV_OFFSET;
        for (size_t i = 0; i < _political_regime_ids.size(); ++i) {
            hash_string(hash, _political_regime_ids[i]);
            hash_bytes(hash, &_political_regime_capability_bits[i],
                       sizeof(uint32_t));
        }
        _political_regime_catalog_hash = hash;
    }
    _good_index.clear();
    _technology_index.clear();
    for (int32_t i = 0; i < static_cast<int32_t>(_good_ids.size()); ++i) _good_index[_good_ids[i]] = i;
    for (int32_t i = 0; i < static_cast<int32_t>(_technology_ids.size()); ++i) _technology_index[_technology_ids[i]] = i;
    _technology_domains = packed_i32(catalog, "technology_domain_indices");
    _technology_costs = packed_i64(catalog, "technology_costs");
    _technology_prerequisite_offsets = packed_i32(catalog, "technology_prerequisite_offsets");
    _technology_prerequisites = packed_i32(catalog, "technology_prerequisites");
    _technology_milestone_offsets = packed_i32(catalog, "technology_milestone_offsets");
    _technology_milestone_candidates = packed_i32(catalog, "technology_milestone_candidates");
    _technology_milestone_required_counts = packed_i32(catalog, "technology_milestone_required_counts");
    _technology_entry_milestone_indices =
        packed_i32(catalog, "technology_entry_milestone_indices");
    _technology_era_milestone_indices =
        packed_i32(catalog, "technology_era_milestone_indices");
    _technology_flags = packed_i32(catalog, "technology_flags");
    _technology_modifier_definition_keys =
        packed_strings(catalog, "technology_modifier_definition_keys");
    _research_signal_requires_provenance =
        packed_u8(catalog, "research_signal_requires_provenance");
    _technology_research_condition_offsets =
        packed_i32(catalog, "technology_research_condition_offsets");
    _technology_research_condition_ops =
        packed_i32(catalog, "technology_research_condition_ops");
    _technology_research_condition_refs =
        packed_i32(catalog, "technology_research_condition_refs");
    _technology_research_condition_values =
        packed_i64(catalog, "technology_research_condition_values");
    _technology_reveal_condition_offsets =
        packed_i32(catalog, "technology_reveal_condition_offsets");
    _technology_reveal_condition_ops =
        packed_i32(catalog, "technology_reveal_condition_ops");
    _technology_reveal_condition_refs =
        packed_i32(catalog, "technology_reveal_condition_refs");
    _technology_reveal_condition_values =
        packed_i64(catalog, "technology_reveal_condition_values");
    _technology_reveal_signal_offsets =
        packed_i32(catalog, "technology_reveal_signal_offsets");
    _technology_reveal_signal_technologies =
        packed_i32(catalog, "technology_reveal_signal_technologies");
    const size_t tech_count = _technology_ids.size();
    if (catalog.has("technology_era_reward_pool_ids")) {
        std::unordered_set<std::string> reward_pool_ids;
        if (_technology_era_reward_pool_ids.size() != 11)
            return fail("country_era_reward_pool_mapping_invalid");
        for (const std::string &pool_id : _technology_era_reward_pool_ids)
            if (pool_id.empty() || !reward_pool_ids.insert(pool_id).second)
                return fail("country_era_reward_pool_mapping_invalid");
    }
    if (_technology_domains.size() != tech_count || _technology_costs.size() != tech_count ||
        _technology_prerequisite_offsets.size() != tech_count + 1 ||
        _technology_milestone_offsets.size() != tech_count + 1 ||
        _technology_milestone_required_counts.size() != tech_count ||
        _technology_entry_milestone_indices.size() != tech_count ||
        _technology_era_milestone_indices.size() != 11 ||
        _technology_flags.size() != tech_count ||
        _technology_modifier_definition_keys.size() != tech_count ||
        _technology_prerequisite_offsets.front() != 0 ||
        _technology_prerequisite_offsets.back() != static_cast<int32_t>(_technology_prerequisites.size()) ||
        _technology_milestone_offsets.front() != 0 ||
        _technology_milestone_offsets.back() != static_cast<int32_t>(_technology_milestone_candidates.size()))
        return fail("country_technology_metadata_invalid");

    if (_research_signal_requires_provenance.size() != _research_signal_ids.size() ||
        _technology_research_condition_offsets.size() != tech_count + 1 ||
        _technology_research_condition_offsets.empty() ||
        _technology_research_condition_offsets.front() != 0 ||
        _technology_research_condition_offsets.back() !=
            static_cast<int32_t>(_technology_research_condition_ops.size()) ||
        _technology_research_condition_ops.size() != _technology_research_condition_refs.size() ||
        _technology_research_condition_ops.size() != _technology_research_condition_values.size())
        return fail("country_research_condition_metadata_invalid");
    if (_technology_reveal_condition_offsets.size() != tech_count + 1 ||
        _technology_reveal_condition_offsets.empty() ||
        _technology_reveal_condition_offsets.front() != 0 ||
        _technology_reveal_condition_offsets.back() !=
            static_cast<int32_t>(_technology_reveal_condition_ops.size()) ||
        _technology_reveal_condition_ops.size() != _technology_reveal_condition_refs.size() ||
        _technology_reveal_condition_ops.size() != _technology_reveal_condition_values.size() ||
        _technology_reveal_signal_offsets.size() != _research_signal_ids.size() + 1 ||
        _technology_reveal_signal_offsets.empty() ||
        _technology_reveal_signal_offsets.front() != 0 ||
        _technology_reveal_signal_offsets.back() !=
            static_cast<int32_t>(_technology_reveal_signal_technologies.size()))
        return fail("country_reveal_condition_metadata_invalid");
    for (size_t tech = 0; tech < tech_count; ++tech) {
        if (_technology_domains[tech] < 0 || _technology_domains[tech] >= 4 ||
            _technology_costs[tech] < 0 ||
            _technology_milestone_required_counts[tech] < 0)
            return fail("country_technology_metadata_invalid");
    }
    for (int32_t prerequisite : _technology_prerequisites)
        if (prerequisite < 0 || prerequisite >= static_cast<int32_t>(tech_count))
            return fail("country_technology_prerequisite_invalid");
    for (int32_t entry_milestone : _technology_entry_milestone_indices)
        if (entry_milestone < -1 || entry_milestone >= static_cast<int32_t>(tech_count))
            return fail("country_technology_era_entry_invalid");
    for (int32_t candidate : _technology_milestone_candidates)
        if (candidate < 0 || candidate >= static_cast<int32_t>(tech_count))
            return fail("country_technology_milestone_candidate_invalid");
    for (size_t op = 0; op < _technology_research_condition_ops.size(); ++op) {
        const int32_t kind = _technology_research_condition_ops[op];
        const int32_t ref = _technology_research_condition_refs[op];
        const int64_t value = _technology_research_condition_values[op];
        if ((kind == 1 && (ref < 0 || ref >= static_cast<int32_t>(tech_count))) ||
            ((kind == 2 || kind == 3) &&
             (ref < 0 || ref >= static_cast<int32_t>(_research_signal_ids.size()))) ||
            ((kind == 10 || kind == 11 || kind == 12) && ref <= 0) ||
            (kind == 12 && value <= 0) ||
            (kind == 13 && ref != 1) ||
            (kind < 1 || kind > 13))
            return fail("country_research_condition_opcode_invalid");
    }
    for (size_t op = 0; op < _technology_reveal_condition_ops.size(); ++op) {
        const int32_t kind = _technology_reveal_condition_ops[op];
        const int32_t ref = _technology_reveal_condition_refs[op];
        const int64_t value = _technology_reveal_condition_values[op];
        if ((kind == 1 && (ref < 0 || ref >= static_cast<int32_t>(tech_count))) ||
            ((kind == 2 || kind == 3) &&
             (ref < 0 || ref >= static_cast<int32_t>(_research_signal_ids.size()))) ||
            ((kind == 10 || kind == 11 || kind == 12) && ref <= 0) ||
            (kind == 12 && value <= 0) ||
            (kind == 13 && ref != 1) ||
            (kind < 1 || kind > 13))
            return fail("country_reveal_condition_opcode_invalid");
    }
    for (int32_t technology : _technology_reveal_signal_technologies)
        if (technology < 0 || technology >= static_cast<int32_t>(tech_count))
            return fail("country_reveal_signal_index_invalid");
    rebuild_discovery_dependents();
    const auto points_it = _good_index.find("technology_points");
    if (points_it == _good_index.end()) return fail("country_technology_points_good_missing");
    _technology_points_good_id = points_it->second;
    _starting_technologies.clear();
    for (const std::string &id : packed_strings(profile, "starting_technology_ids")) {
        const auto it = _technology_index.find(id);
        if (it == _technology_index.end()) return fail("country_starting_technology_unknown");
        _starting_technologies.push_back(it->second);
    }
    std::sort(_starting_technologies.begin(), _starting_technologies.end());
    _starting_technologies.erase(std::unique(_starting_technologies.begin(), _starting_technologies.end()),
                                 _starting_technologies.end());

    _cell_count = cell_count;
    _seed = seed;
    _mode = parsed_mode;
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63U) / 64U);
    _research_signal_words = static_cast<int32_t>((_research_signal_ids.size() + 63U) / 64U);
    _max_commands_per_slice = std::max<int32_t>(1, dict_num<int32_t>(profile, "country_max_commands_per_slice", 65536));
    _configured = true;
    _bootstrapped = false;
    _generation = 0;
    _territory_generation = 0;
    _research_generation = 0;
    _submit_order = 0;
    _typed_receipts.clear();
    _typed_request_state.clear();
    clear_peer_protocol_state();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
    _next_event_id = 1;
    _last_committed_day = -1;
    _countries = {};
    _starting_country_slot = -1;
    _cell_country_slot.assign(static_cast<size_t>(_cell_count), NEUTRAL_SLOT);
    _country_cell_offsets.clear();
    _country_cells.clear();
    _country_technologies.clear();
    _country_goods.clear();
    _country_discovered.clear();
    _country_pending_technologies.clear();
    _current_visual_era.clear();
    _visual_era_dirty_slots.clear();
    _visual_era_generation = 0;
    _research_active_country_slots.clear();
    _research_active_country_membership.clear();
    _research_activated_pending_scratch.clear();
    _research_activated_pending_scratch.reserve(32);
    _research_activated_technologies_scratch.clear();
    _research_activated_technologies_scratch.reserve(32);
    _research_modifier_cache.clear();
    _country_research_signals.clear();
    _country_research_signal_cells.clear();
    _country_research_signal_evidence.clear();
    _country_research_progress.clear();
    _country_research_queues.clear();
    _country_research_queue_lengths.clear();
    _country_research_weights_bp.clear();
    _country_research_auto_purchase.clear();
    _country_research_deferred_points.clear();
    _country_research_purchased_total.clear();
    _country_research_consumed_total.clear();
    _country_treasury_goods_consumed_total.clear();
    _country_research_progress_total.clear();
    _country_research_completed_total.clear();
    _country_tax_defaults.clear();
    _country_tax_default_modes.clear();
    _country_income_tax_overrides.clear();
    _country_consumption_tax_overrides.clear();
    _country_business_tax_overrides.clear();
    _country_import_tax_overrides.clear();
    _country_export_tax_overrides.clear();
    _country_income_tax_mode_overrides.clear();
    _country_consumption_tax_mode_overrides.clear();
    _country_business_tax_mode_overrides.clear();
    _country_import_tax_mode_overrides.clear();
    _country_export_tax_mode_overrides.clear();
    _tax_policy_version = 0;
    _cell_tax_policy_ids.assign(static_cast<size_t>(_cell_count), 0);
    _cell_tax_policies.assign(1, CellTaxPolicy{});
    _cell_tax_policy_refcounts.assign(1, 0);
    _cell_tax_policy_free_ids.clear();
    _cell_tax_policy_intern.clear();
    _last_research_day = -1;
    _pending_commands.clear();
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _effect_host_request_map.clear();
    _effect_host_receipt_cursor = 0;
    _next_effect_request_id = 1;
    clear_peer_protocol_state();
    _era_reward_reference = {};
    _events.clear();
    _command_batch = {};
    _economy_asset_transaction_history.clear();
    _economy_asset_request_index.clear();
    _economy_asset_transactions_in_flight.clear();
    _economy_asset_reserved_cash.clear();
    _economy_asset_reserved_goods.clear();
    _economy_asset_reserved_research_points.clear();
    _next_economy_asset_transaction_id = 1;
    _economy_asset_operation_sequence = 0;
    _economy_asset_transactions_created = 0;
    _economy_asset_transactions_completed = 0;
    _economy_asset_transactions_rejected = 0;
    _economy_asset_prepare_count = 0;
    _economy_asset_commit_count = 0;
    _economy_asset_complete_count = 0;
    _economy_asset_ledger_failures = 0;
    _is_water.clear();
    _report.clear();
    _report["configured"] = true;
    _report["bootstrapped"] = false;
    _report["runtime_mode"] = mode.c_str();
    _report["schema_version"] = SCHEMA_VERSION;

    Dictionary out;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["runtime_mode"] = mode.c_str();
    out["cell_count"] = _cell_count;
    out["good_count"] = static_cast<int64_t>(_good_ids.size());
    out["profession_count"] = static_cast<int64_t>(_profession_ids.size());
    out["building_type_count"] =
        static_cast<int64_t>(_building_type_ids.size());
    out["technology_count"] = static_cast<int64_t>(_technology_ids.size());
    out["catalog_hash"] = static_cast<int64_t>(catalog_hash());
    return out;
}

} // namespace pk
