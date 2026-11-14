#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_core_apply.h"
// The shared authority-aware instance write. Technology instances are Effect
// instances, so they take the same worker/legacy door as the family ones.
#include "economy_effect_forward.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>


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
    _country_research_daily_budgets.clear();
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

int32_t NativeCountryRuntime::append_country(const std::string &stable_id,
                                              const std::string &display_name,
                                              int64_t cash) {
    const int32_t slot = static_cast<int32_t>(_countries.active.size());
    _countries.active.push_back(1);
    _countries.generation.push_back(1);
    _countries.stable_id.push_back(stable_id);
    _countries.display_name.push_back(display_name);
    _countries.territory_count.push_back(0);
    _countries.cash.push_back(cash);
    _countries.state_version.push_back(1);
    const auto early = _political_regime_index.find("early_clan");
    const int32_t default_regime = early == _political_regime_index.end()
        ? 0 : early->second;
    _countries.political_regime_id.push_back(default_regime);
    _countries.political_regime_capability_bits.push_back(
        default_regime >= 0 && static_cast<size_t>(default_regime) <
            _political_regime_capability_bits.size()
            ? _political_regime_capability_bits[static_cast<size_t>(default_regime)]
            : 0u);
    _economy_asset_reserved_cash.resize(_countries.active.size(), 0);
    _economy_asset_reserved_goods.resize(
        _countries.active.size() * _good_ids.size(), 0);
    _economy_asset_reserved_research_points.resize(
        _countries.active.size(), 0);
    _country_technologies.resize(static_cast<size_t>(slot + 1) * _technology_words, 0);
    _current_visual_era.resize(static_cast<size_t>(slot + 1), -1);
    _country_goods.resize(static_cast<size_t>(slot + 1) * _good_ids.size(), 0);
    _country_tax_defaults.resize(static_cast<size_t>(slot + 1) * TAX_KIND_COUNT,
                                 0);
    _country_tax_default_modes.resize(
        static_cast<size_t>(slot + 1) * TAX_KIND_COUNT, TAX_MODE_PERCENT_BP);
    _country_income_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _profession_ids.size(),
        TAX_RATE_INHERIT);
    _country_consumption_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_RATE_INHERIT);
    _country_business_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _building_type_ids.size(),
        TAX_RATE_INHERIT);
    _country_import_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_RATE_INHERIT);
    _country_export_tax_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_RATE_INHERIT);
    _country_income_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _profession_ids.size(),
        TAX_MODE_INHERIT);
    _country_consumption_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_MODE_INHERIT);
    _country_business_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _building_type_ids.size(),
        TAX_MODE_INHERIT);
    _country_import_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_MODE_INHERIT);
    _country_export_tax_mode_overrides.resize(
        static_cast<size_t>(slot + 1) * _good_ids.size(), TAX_MODE_INHERIT);
    initialize_country_research(slot);
    return slot;
}

Dictionary NativeCountryRuntime::bootstrap(const Dictionary &packet,
                                            const PackedByteArray &is_water) {
    if (!_configured) return fail("country_not_configured");
    if (is_water.size() != _cell_count) return fail("country_water_mask_size_mismatch");
    _is_water.resize(static_cast<size_t>(_cell_count));
    if (_cell_count > 0) std::memcpy(_is_water.data(), is_water.ptr(), static_cast<size_t>(_cell_count));

    const std::vector<std::string> ids = packed_strings(packet, "country_ids");
    const std::vector<std::string> names = packed_strings(packet, "country_names");
    const std::vector<std::string> regime_ids = packed_strings(packet, "regime_ids");
    const std::vector<int64_t> cash = packed_i64(packet, "country_cash");
    const std::vector<int32_t> territory_offsets = packed_i32(packet, "territory_offsets");
    const std::vector<int32_t> territory_cells = packed_i32(packet, "territory_cells");
    const std::vector<int32_t> tech_offsets = packed_i32(packet, "technology_offsets");
    const std::vector<int32_t> tech_indices = packed_i32(packet, "technology_indices");
    const std::vector<int32_t> discovered_offsets =
        packed_i32(packet, "discovered_technology_offsets");
    const std::vector<int32_t> discovered_indices =
        packed_i32(packet, "discovered_technology_indices");
    const std::vector<int32_t> research_signal_offsets =
        packed_i32(packet, "research_signal_offsets");
    const std::vector<int32_t> research_signal_indices =
        packed_i32(packet, "research_signal_indices");
    const std::vector<int32_t> research_signal_cells =
        packed_i32(packet, "research_signal_cells");
    const std::vector<int64_t> research_signal_days =
        packed_i64(packet, "research_signal_days");
    const std::vector<int32_t> treasury_offsets = packed_i32(packet, "treasury_offsets");
    const std::vector<int32_t> treasury_good_indices = packed_i32(packet, "treasury_good_indices");
    const std::vector<int64_t> treasury_quantities = packed_i64(packet, "treasury_quantities");
    const std::vector<int32_t> research_weights =
        packed_i32(packet, "research_weights_bp");
    const std::vector<int64_t> research_budgets =
        packed_i64(packet, "research_daily_budgets");
    const std::vector<uint8_t> research_auto_purchase =
        packed_u8(packet, "research_auto_purchase");

    _countries = {};
    std::fill(_cell_country_slot.begin(), _cell_country_slot.end(), NEUTRAL_SLOT);
    _country_technologies.clear();
    _country_goods.clear();
    _country_discovered.clear();
    _country_pending_technologies.clear();
    _pending_activation_indices.clear();
    _pending_activation_index_dirty = true;
    _pending_activation_count = 0;
    _research_queue_rebuilds = 0;
    _country_research_signals.clear();
    _country_research_signal_cells.clear();
    _country_research_signal_evidence.clear();
    _country_research_progress.clear();
    _country_research_queues.clear();
    _country_research_queue_lengths.clear();
    _country_research_weights_bp.clear();
    _country_research_auto_purchase.clear();
    _country_research_daily_budgets.clear();
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
    _typed_receipts.clear();
    _typed_request_state.clear();
    clear_peer_protocol_state();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _effect_host_request_map.clear();
    _effect_host_receipt_cursor = 0;
    _next_effect_request_id = 1;
    _economy_asset_transactions_in_flight.clear();
    _economy_asset_reserved_cash.assign(_countries.active.size(), 0);
    _economy_asset_reserved_goods.assign(
        _countries.active.size() * _good_ids.size(), 0);
    _economy_asset_reserved_research_points.assign(
        _countries.active.size(), 0);
    _era_reward_reference = {};
    _events.clear();
    _command_batch = {};

    if (ids.empty()) {
        int32_t land_count = 0;
        for (uint8_t water : _is_water) if (water == 0) ++land_count;
        if (land_count == 0) return fail("country_bootstrap_no_land");
        const int32_t slot = append_country("country.default", "默认国家", 0);
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            if (_is_water[static_cast<size_t>(cell)] != 0) continue;
            _cell_country_slot[static_cast<size_t>(cell)] = slot;
            ++_countries.territory_count[static_cast<size_t>(slot)];
        }
        for (int32_t tech : _starting_technologies)
            _country_technologies[static_cast<size_t>(slot) * _technology_words + tech / 64] |= 1ULL << (tech % 64);
        _starting_country_slot = slot;
    } else {
        if (names.size() != ids.size() || (!cash.empty() && cash.size() != ids.size()) ||
            (!regime_ids.empty() && regime_ids.size() != ids.size()) ||
            territory_offsets.size() != ids.size() + 1 || territory_offsets.front() != 0 ||
            territory_offsets.back() != static_cast<int32_t>(territory_cells.size()))
            return fail("country_bootstrap_shape_invalid");
        if ((!tech_offsets.empty() && (tech_offsets.size() != ids.size() + 1 || tech_offsets.front() != 0 ||
             tech_offsets.back() != static_cast<int32_t>(tech_indices.size()))) ||
            (!discovered_offsets.empty() && (discovered_offsets.size() != ids.size() + 1 ||
             discovered_offsets.front() != 0 ||
             discovered_offsets.back() != static_cast<int32_t>(discovered_indices.size()))) ||
            (!research_signal_offsets.empty() &&
             (research_signal_offsets.size() != ids.size() + 1 || research_signal_offsets.front() != 0 ||
              research_signal_offsets.back() != static_cast<int32_t>(research_signal_indices.size()) ||
              research_signal_indices.size() != research_signal_cells.size() ||
              research_signal_indices.size() != research_signal_days.size())) ||
            (!treasury_offsets.empty() && (treasury_offsets.size() != ids.size() + 1 || treasury_offsets.front() != 0 ||
             treasury_offsets.back() != static_cast<int32_t>(treasury_good_indices.size()) ||
             treasury_good_indices.size() != treasury_quantities.size())))
            return fail("country_bootstrap_csr_invalid");
        if ((!research_weights.empty() && research_weights.size() != ids.size() * 4U) ||
            (!research_budgets.empty() && research_budgets.size() != ids.size()) ||
            (!research_auto_purchase.empty() &&
             research_auto_purchase.size() != ids.size()))
            return fail("country_bootstrap_research_shape_invalid");
		if (!regime_ids.empty()) {
			for (const std::string &regime_key : regime_ids)
				if (_political_regime_index.find(regime_key) == _political_regime_index.end())
					return fail("country_bootstrap_political_regime_invalid");
		}

        std::unordered_set<std::string> stable_ids;
        for (size_t i = 0; i < ids.size(); ++i) {
            if (ids[i].empty() || names[i].empty() || !stable_ids.insert(ids[i]).second)
                return fail("country_bootstrap_identity_invalid");
            if (territory_offsets[i] == territory_offsets[i + 1]) return fail("country_bootstrap_zero_territory");
            append_country(ids[i], names[i], cash.empty() ? 0 : cash[i]);
            if (!regime_ids.empty()) {
                const auto found = _political_regime_index.find(regime_ids[i]);
                if (found == _political_regime_index.end())
                    return fail("country_bootstrap_political_regime_invalid");
                const int32_t regime = found->second;
                _countries.political_regime_id[i] = regime;
                _countries.political_regime_capability_bits[i] =
                    static_cast<size_t>(regime) < _political_regime_capability_bits.size()
                    ? _political_regime_capability_bits[static_cast<size_t>(regime)] : 0u;
            }
        }
        for (size_t slot = 0; slot < ids.size(); ++slot) {
            for (int32_t edge = territory_offsets[slot]; edge < territory_offsets[slot + 1]; ++edge) {
                const int32_t cell = territory_cells[static_cast<size_t>(edge)];
                if (cell < 0 || cell >= _cell_count) return fail("country_bootstrap_cell_invalid");
                if (_is_water[static_cast<size_t>(cell)] != 0) return fail("country_bootstrap_water_owned");
                if (_cell_country_slot[static_cast<size_t>(cell)] != NEUTRAL_SLOT)
                    return fail("country_bootstrap_duplicate_territory");
                _cell_country_slot[static_cast<size_t>(cell)] = static_cast<int32_t>(slot);
                ++_countries.territory_count[slot];
            }
            if (tech_offsets.empty()) {
                for (int32_t tech : _starting_technologies)
                    _country_technologies[slot * _technology_words + tech / 64] |= 1ULL << (tech % 64);
            } else {
                for (int32_t edge = tech_offsets[slot]; edge < tech_offsets[slot + 1]; ++edge) {
                    const int32_t tech = tech_indices[static_cast<size_t>(edge)];
                    if (tech < 0 || tech >= static_cast<int32_t>(_technology_ids.size()))
                        return fail("country_bootstrap_technology_invalid");
                    _country_technologies[slot * _technology_words + tech / 64] |= 1ULL << (tech % 64);
                }
            }
            if (!discovered_offsets.empty()) {
                for (int32_t edge = discovered_offsets[slot];
                     edge < discovered_offsets[slot + 1]; ++edge) {
                    const int32_t tech = discovered_indices[static_cast<size_t>(edge)];
                    if (tech < 0 || tech >= static_cast<int32_t>(_technology_ids.size()))
                        return fail("country_bootstrap_discovered_technology_invalid");
                    _country_discovered[slot * _technology_words + tech / 64] |=
                        1ULL << (tech % 64);
                }
            }
            if (!treasury_offsets.empty()) {
                for (int32_t edge = treasury_offsets[slot]; edge < treasury_offsets[slot + 1]; ++edge) {
                    const int32_t good = treasury_good_indices[static_cast<size_t>(edge)];
                    const int64_t quantity = treasury_quantities[static_cast<size_t>(edge)];
                    if (good < 0 || good >= static_cast<int32_t>(_good_ids.size()) || quantity < 0)
                        return fail("country_bootstrap_treasury_invalid");
                    _country_goods[slot * _good_ids.size() + good] = quantity;
                }
            }
            if (!research_weights.empty()) {
                int32_t total = 0;
                for (int32_t domain = 0; domain < 4; ++domain) {
                    const int32_t weight = research_weights[slot * 4U + domain];
                    if (weight < 0 || weight > 10000)
                        return fail("country_bootstrap_research_policy_invalid");
                    _country_research_weights_bp[slot * 4U + domain] = weight;
                    total += weight;
                }
                if (total != 10000)
                    return fail("country_bootstrap_research_policy_invalid");
            }
            if (!research_budgets.empty()) {
                if (research_budgets[slot] < 0)
                    return fail("country_bootstrap_research_policy_invalid");
                _country_research_daily_budgets[slot] = research_budgets[slot];
            }
            if (!research_auto_purchase.empty()) {
                if (research_auto_purchase[slot] > 1)
                    return fail("country_bootstrap_research_policy_invalid");
                _country_research_auto_purchase[slot] =
                    research_auto_purchase[slot];
            }
            if (!research_signal_offsets.empty()) {
                std::vector<uint64_t> &observed_cells =
                    _country_research_signal_cells[slot];
                std::vector<SignalEvidence> &evidence =
                    _country_research_signal_evidence[slot];
                for (int32_t edge = research_signal_offsets[slot];
                     edge < research_signal_offsets[slot + 1]; ++edge) {
                    const int32_t signal = research_signal_indices[static_cast<size_t>(edge)];
                    const int32_t cell = research_signal_cells[static_cast<size_t>(edge)];
                    const int64_t day = research_signal_days[static_cast<size_t>(edge)];
                    if (signal < 0 || signal >= static_cast<int32_t>(_research_signal_ids.size()) ||
                        cell < 0 || cell >= _cell_count || day < 0)
                        return fail("country_bootstrap_research_signal_invalid");
                    const uint64_t observation_key =
                        (static_cast<uint64_t>(static_cast<uint32_t>(signal)) << 32U) |
                        static_cast<uint32_t>(cell);
                    auto observed_it = std::lower_bound(
                        observed_cells.begin(), observed_cells.end(), observation_key);
                    if (observed_it != observed_cells.end() && *observed_it == observation_key)
                        continue;
                    observed_cells.insert(observed_it, observation_key);
                    if (_research_signal_words > 0) {
                        _country_research_signals[slot * static_cast<size_t>(_research_signal_words) +
                                                   static_cast<size_t>(signal / 64)] |=
                            uint64_t{1} << (signal % 64);
                    }
                    auto evidence_it = std::lower_bound(
                        evidence.begin(), evidence.end(), signal,
                        [](const SignalEvidence &entry, int32_t needle) {
                            return entry.signal < needle;
                        });
                    if (evidence_it == evidence.end() || evidence_it->signal != signal) {
                        SignalEvidence entry;
                        entry.signal = signal;
                        entry.count = 0;
                        entry.first_day = day;
                        entry.last_day = day;
                        entry.first_cell = cell;
                        evidence_it = evidence.insert(evidence_it, entry);
                    }
                    ++evidence_it->count;
                    evidence_it->first_day = std::min(evidence_it->first_day, day);
                    evidence_it->last_day = std::max(evidence_it->last_day, day);
                    if (evidence_it->first_cell < 0 || cell < evidence_it->first_cell)
                        evidence_it->first_cell = cell;
                }
            }
        }
        _starting_country_slot = 0;
    }

    for (int32_t slot = 0; slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech) {
            if (has_technology(slot, tech))
                _country_discovered[static_cast<size_t>(slot) * _technology_words + tech / 64] |=
                    1ULL << (tech % 64);
        }
        refresh_discovery(slot);
    }

    rebuild_cell_csr();
    _generation = 1;
    _territory_generation = 1;
    _research_generation = 1;
    _pending_activation_index_dirty = true;
    rebuild_research_active_index();
    int32_t bootstrap_effect_rejected = 0;
    if (_effect_runtime_enabled && _effect_runtime != nullptr) {
        for (int32_t slot = 0; slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
            const uint64_t handle = make_handle(slot);
            for (int32_t technology = 0;
                 technology < static_cast<int32_t>(_technology_ids.size()); ++technology) {
                if (!has_technology(slot, technology) ||
                    _technology_modifier_definition_keys[static_cast<size_t>(technology)].empty())
                    continue;
                std::string effect_error;
                // Restored technologies own one Effect instance per (country,
                // technology). Route the install through the forwarder so the
                // authority that actually runs the Effect domain receives it:
                // under F8 ACTIVE the sync facade is writeback-only and the row
                // written into it here disappeared at the next worker snapshot.
                // `next_due_day` stays 0 -- restore keeps the historical
                // "available immediately" semantics, unlike the peer adapter
                // which schedules committed_day + 1.
                const bool installed = effect_pod_upsert(
                    _effect_runtime, _effect_forwarder,
                    static_cast<int64_t>(((handle & 0x00007fffffffffffULL) << 16U) |
                        static_cast<uint64_t>(technology + 1)),
                    std::string("technology.") + _technology_ids[static_cast<size_t>(technology)],
                    static_cast<uint32_t>(handle >> 32U), 0x54454348, technology + 1,
                    handle, handle, static_cast<uint32_t>(handle >> 32U), 0,
                    0, -1, true, effect_error);
                // The old code dropped this result on the floor, so a technology
                // whose program key failed to resolve restored as "country has
                // the technology, Effect has nothing". Count it instead: the
                // bootstrap report carries the number and it is the only signal
                // that the new door refuses a row the sync facade accepted.
                if (!installed || !effect_error.empty()) ++bootstrap_effect_rejected;
            }
        }
    }
    _bootstrapped = true;
    _current_visual_era.resize(_countries.active.size(), -1);
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot)
        _current_visual_era[static_cast<size_t>(slot)] =
            visual_era_index_for_slot(slot);
    _last_committed_day = -1;
    _last_research_day = -1;
    publish_report("aggregate_publish", -1, 0, 0, 0, _cell_count,
                   static_cast<int32_t>(_countries.active.size()), _mode == MODE_ACTIVE);
    begin_reference_boundary(-1);
    record_reference_frame("bootstrap", -1, true, false);
    Dictionary out = report();
    out["ok"] = true;
    out["default_bootstrap"] = ids.empty();
    out["bootstrap_effect_rejected"] = bootstrap_effect_rejected;
    return out;
}










CountryCoreStepResult NativeCountryRuntime::run_slice_core(
        int64_t requested_day) {
    CoreSliceContext context;
    context.requested_day = requested_day;
    if (_mode == MODE_OFF) {
        context.result.status = CountryCoreStepStatus::OFF;
        context.result.path = "off";
        return context.result;
    }
    if (!prepare_country_slice(context)) return context.result;
    if (!preflight_country_slice(context)) return context.result;
    commit_country_slice(context);
    return context.result;
}
void NativeCountryRuntime::rebuild_cell_csr() {
    const int32_t count = static_cast<int32_t>(_countries.active.size());
    _country_cell_offsets.assign(static_cast<size_t>(count + 1), 0);
    for (int32_t owner : _cell_country_slot)
        if (owner >= 0 && owner < count) ++_country_cell_offsets[static_cast<size_t>(owner + 1)];
    for (int32_t slot = 0; slot < count; ++slot)
        _country_cell_offsets[static_cast<size_t>(slot + 1)] += _country_cell_offsets[static_cast<size_t>(slot)];
    _country_cells.assign(static_cast<size_t>(_country_cell_offsets.back()), -1);
    std::vector<int32_t> cursor = _country_cell_offsets;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t owner = _cell_country_slot[static_cast<size_t>(cell)];
        if (owner >= 0 && owner < count) _country_cells[static_cast<size_t>(cursor[static_cast<size_t>(owner)]++)] = cell;
    }
    // `territory_count` is DERIVED from `_cell_country_slot`, and this is the one place
    // that already recomputes everything else derived from it. Before this line the two
    // were maintained separately: the command path incremented the staged copy
    // (`:3196`) while the cell delta was applied here, so `COMMAND_CLAIM_UNOWNED_TERRITORY`
    // left the column updated and the count stale.
    //
    // Consequence of that drift: `get_country_territory_counts()` under-reported forever,
    // `state_hash` hashed a value that disagreed with reality, and the wrong number was
    // PERSISTED. It also made ">32 cells" unobservable, which is why the real-world
    // sample could not be produced (M5-52).
    //
    // Recomputing from the CSR offsets costs O(countries) and cannot drift, because the
    // offsets below came from the authoritative column one line earlier.
    for (int32_t slot = 0; slot < count; ++slot)
        _countries.territory_count[static_cast<size_t>(slot)] =
            _country_cell_offsets[static_cast<size_t>(slot + 1)] -
            _country_cell_offsets[static_cast<size_t>(slot)];
}




Dictionary NativeCountryRuntime::reset(const String &reason) {
    _bootstrapped = false;
    _state_hash_cache_valid = false;
    _countries = {};
    _cell_country_slot.assign(static_cast<size_t>(std::max(0, _cell_count)), NEUTRAL_SLOT);
    _country_cell_offsets.clear();
    _country_cells.clear();
    _country_technologies.clear();
    _country_goods.clear();
    _country_discovered.clear();
    _country_pending_technologies.clear();
    _current_visual_era.clear();
    _visual_era_dirty_slots.clear();
    _visual_era_generation = 0;
    _territory_generation = 0;
    _research_generation = 0;
    _research_active_country_slots.clear();
    _research_active_country_scratch.clear();
    _research_active_country_membership.clear();
    _research_activated_pending_scratch.clear();
    _research_activated_technologies_scratch.clear();
    _research_modifier_cache.clear();
    _pending_activation_indices.clear();
    _pending_activation_index_dirty = true;
    _pending_activation_count = 0;
    _research_queue_rebuilds = 0;
    _research_full_scan_fallbacks = 0;
    _research_discovery_frontier_mismatches = 0;
    _research_queue_fallback_reason.clear();
    _country_research_progress.clear();
    _country_research_queues.clear();
    _country_research_queue_lengths.clear();
    _country_research_weights_bp.clear();
    _country_research_auto_purchase.clear();
    _country_research_daily_budgets.clear();
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
    _cell_tax_policy_ids.assign(static_cast<size_t>(std::max(0, _cell_count)), 0);
    _cell_tax_policies.assign(1, CellTaxPolicy{});
    _cell_tax_policy_refcounts.assign(1, 0);
    _cell_tax_policy_free_ids.clear();
    _cell_tax_policy_intern.clear();
    _tax_policy_version = 0;
    _last_research_day = -1;
    _pending_commands.clear();
    _typed_receipts.clear();
    _typed_request_state.clear();
    clear_peer_protocol_state();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _effect_host_request_map.clear();
    _effect_host_receipt_cursor = 0;
    _next_effect_request_id = 1;
    _era_reward_reference = {};
    _events.clear();
    _command_batch = {};
    ++_generation;
    _report.clear();
    _report["configured"] = _configured;
    _report["bootstrapped"] = false;
    _report["reason"] = reason;
    Dictionary out;
    out["ok"] = true;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

















void NativeCountryRuntime::push_event(Event event) {
    event.event_id = static_cast<int64_t>(_next_event_id++);
    _events.push_back(std::move(event));
    while (_events.size() > 2048) _events.pop_front();
}

Dictionary NativeCountryRuntime::poll_events(int64_t after_event_id, int32_t limit) const {
    limit = std::clamp(limit, 1, 512);
    PackedInt64Array event_ids, days, handles, values;
    PackedInt32Array opcodes, cells, old_slots, new_slots, technologies, signals,
        signal_sources, evidence_deltas;
    PackedStringArray stable_ids, display_names;
    for (const Event &event : _events) {
        if (event.event_id <= after_event_id || event_ids.size() >= limit) continue;
        event_ids.push_back(event.event_id);
        days.push_back(event.day);
        handles.push_back(static_cast<int64_t>(event.country_handle));
        values.push_back(event.value);
        opcodes.push_back(event.opcode);
        cells.push_back(event.cell);
        old_slots.push_back(event.old_country_slot);
        new_slots.push_back(event.new_country_slot);
        technologies.push_back(event.technology_id);
        signals.push_back(event.signal_id);
        signal_sources.push_back(event.signal_source_kind);
        evidence_deltas.push_back(event.evidence_delta);
        stable_ids.push_back(event.stable_id.c_str());
        display_names.push_back(String::utf8(event.display_name.c_str()));
    }
    Dictionary out;
    out["ok"] = true;
    out["event_ids"] = event_ids;
    out["days"] = days;
    out["opcodes"] = opcodes;
    out["country_handles"] = handles;
    out["cells"] = cells;
    out["old_country_slots"] = old_slots;
    out["new_country_slots"] = new_slots;
    out["technology_ids"] = technologies;
    out["signal_ids"] = signals;
    out["signal_source_kinds"] = signal_sources;
    out["evidence_deltas"] = evidence_deltas;
    out["values"] = values;
    out["stable_ids"] = stable_ids;
    out["display_names"] = display_names;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}


} // namespace pk
