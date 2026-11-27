#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_core_apply.h"
#include "economy_effect_forward.h"
#include "country_runtime_queries_peer_reads.inc"
#include "country_host_port.h"
#include "runtime_text_hash.h"

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

bool NativeCountryRuntime::export_pod_snapshot(
        RuntimeCountryPodSnapshot &out, std::string &error) const {
    out = RuntimeCountryPodSnapshot{};
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_not_bootstrapped";
        return false;
    }
    out.generation = _generation;
    out.committed_day = _last_committed_day;
    out.last_research_day = _last_research_day;
    out.session_epoch = _session_epoch;
    out.cell_count = static_cast<uint32_t>(std::max(0, _cell_count));
    out.country_count = static_cast<uint32_t>(_countries.active.size());
    out.technology_words = static_cast<uint32_t>(std::max(0, _technology_words));
    out.technology_count = static_cast<uint32_t>(_technology_ids.size());
    out.good_count = static_cast<uint32_t>(_good_ids.size());
    out.profession_count = static_cast<uint32_t>(_profession_ids.size());
    out.building_type_count = static_cast<uint32_t>(_building_type_ids.size());
    out.research_signal_words = static_cast<uint32_t>(std::max(0, _research_signal_words));
    out.research_signal_count = static_cast<uint32_t>(_research_signal_ids.size());
    out.catalog_hash = _technology_catalog_identity_hash ^ _political_regime_catalog_hash;
    out.bootstrapped = true;
    out.research_active_index_valid = true;
    out.country_active = _countries.active;
    out.country_generation = _countries.generation;
    out.country_political_regime_ids = _countries.political_regime_id;
    out.country_political_regime_capabilities =
        _countries.political_regime_capability_bits;
    out.country_stable_ids = _countries.stable_id;
    out.country_display_names = _countries.display_name;
    out.research_active_country_slots = _research_active_country_slots;
    out.territory_count = _countries.territory_count;
    out.capital_cell = _countries.capital_cell;
    out.country_state_version = _countries.state_version;
    out.country_cash = _countries.cash;
    out.country_goods = _country_goods;
    out.cell_country_slot = _cell_country_slot;
    out.territory_offsets = _country_cell_offsets;
    out.territory_cells = _country_cells;
    out.country_technologies = _country_technologies;
    out.country_discovered = _country_discovered;
    out.country_pending_technologies = _country_pending_technologies;
    out.country_research_signals = _country_research_signals;
    out.research_signal_cell_offsets.assign(
        _country_research_signal_cells.size() + 1u, 0);
    for (size_t slot = 0; slot < _country_research_signal_cells.size(); ++slot) {
        out.research_signal_cell_offsets[slot + 1u] =
            out.research_signal_cell_offsets[slot] +
            static_cast<int32_t>(_country_research_signal_cells[slot].size());
        out.research_signal_cells.insert(out.research_signal_cells.end(),
            _country_research_signal_cells[slot].begin(),
            _country_research_signal_cells[slot].end());
    }
    out.research_signal_evidence_offsets.assign(
        _country_research_signal_evidence.size() + 1u, 0);
    for (size_t slot = 0; slot < _country_research_signal_evidence.size(); ++slot) {
        const auto &entries = _country_research_signal_evidence[slot];
        out.research_signal_evidence_offsets[slot + 1u] =
            out.research_signal_evidence_offsets[slot] +
            static_cast<int32_t>(entries.size());
        for (const SignalEvidence &entry : entries) {
            RuntimeCountryPodSnapshot::SignalEvidence copy;
            copy.signal = entry.signal;
            copy.count = entry.count;
            copy.first_day = entry.first_day;
            copy.last_day = entry.last_day;
            copy.first_cell = entry.first_cell;
            out.research_signal_evidence.push_back(copy);
        }
    }
    out.research_queues = _country_research_queues;
    out.research_queue_lengths = _country_research_queue_lengths;
    out.research_weights_bp = _country_research_weights_bp;
    out.research_deferred_points = _country_research_deferred_points;
    out.research_progress_total = _country_research_progress_total;
    out.research_completed_total = _country_research_completed_total;
    out.research_auto_purchase = _country_research_auto_purchase;
    out.research_purchased_total = _country_research_purchased_total;
    out.research_consumed_total = _country_research_consumed_total;
    out.treasury_goods_consumed_total = _country_treasury_goods_consumed_total;
    out.treasury_goods_consumed_total.resize(_countries.active.size(), 0);
    out.country_tax_defaults = _country_tax_defaults;
    out.country_tax_default_modes = _country_tax_default_modes;
    out.country_income_tax_overrides = _country_income_tax_overrides;
    out.country_consumption_tax_overrides = _country_consumption_tax_overrides;
    out.country_business_tax_overrides = _country_business_tax_overrides;
    out.country_import_tax_overrides = _country_import_tax_overrides;
    out.country_export_tax_overrides = _country_export_tax_overrides;
    out.country_income_tax_mode_overrides = _country_income_tax_mode_overrides;
    out.country_consumption_tax_mode_overrides = _country_consumption_tax_mode_overrides;
    out.country_business_tax_mode_overrides = _country_business_tax_mode_overrides;
    out.country_import_tax_mode_overrides = _country_import_tax_mode_overrides;
    out.country_export_tax_mode_overrides = _country_export_tax_mode_overrides;
    out.cell_tax_policy_ids = _cell_tax_policy_ids;
    out.cell_tax_policies.resize(_cell_tax_policies.size());
    for (size_t index = 0; index < _cell_tax_policies.size(); ++index) {
        for (uint32_t kind = 0; kind < RuntimeCountryPodSnapshot::TAX_KIND_COUNT; ++kind) {
            out.cell_tax_policies[index].defaults[kind] =
                _cell_tax_policies[index].defaults[kind];
            out.cell_tax_policies[index].modes[kind] =
                _cell_tax_policies[index].default_modes[kind];
        }
        for (const CellTaxOverride &entry : _cell_tax_policies[index].overrides) {
            out.cell_tax_policies[index].overrides.push_back({
                entry.kind, entry.item, entry.rate, entry.mode});
        }
    }
    out.research_progress.resize(_country_research_progress.size() *
                                 static_cast<size_t>(out.technology_count), 0);
    for (size_t slot = 0; slot < _country_research_progress.size(); ++slot) {
        for (const auto &entry : _country_research_progress[slot]) {
            if (entry.first < 0 || entry.first >= static_cast<int32_t>(out.technology_count))
                continue;
            out.research_progress[slot * out.technology_count +
                                   static_cast<size_t>(entry.first)] = entry.second;
        }
    }
    out.research_cost_factor.assign(out.country_count, 1.0);
    out.research_efficiency.assign(
        static_cast<size_t>(out.country_count) * 4u, 1.0);
    if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime)) {
        static constexpr const char *EFFICIENCY_STATS[4] = {
            "country.research.agriculture_efficiency",
            "country.research.engineering_efficiency",
            "country.research.science_efficiency",
            "country.research.society_efficiency",
        };
        for (uint32_t slot = 0; slot < out.country_count; ++slot) {
            if (_countries.active[slot] == 0) continue;
            const uint64_t handle = make_handle(static_cast<int32_t>(slot));
            double cost_factor = modifier_api::effective_value(*_modifier_runtime,
                ModifierApi::COUNTRY, "country.research.cost_factor",
                handle, 0, 1.0);
            if (!(cost_factor > 0.0) || !std::isfinite(cost_factor))
                cost_factor = 1.0;
            out.research_cost_factor[slot] = cost_factor;
            for (uint32_t domain = 0; domain < 4u; ++domain) {
                double efficiency = modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::COUNTRY, EFFICIENCY_STATS[domain],
                    handle, 0, 1.0);
                if (!(efficiency > 0.0) || !std::isfinite(efficiency))
                    efficiency = 1.0;
                out.research_efficiency[static_cast<size_t>(slot) * 4u + domain] =
                    efficiency;
            }
        }
    }
    out.research_peer_flags.assign(
        static_cast<size_t>(out.country_count) * out.technology_count, 0);
    for (uint32_t slot = 0; slot < out.country_count; ++slot) {
        for (uint32_t technology = 0; technology < out.technology_count; ++technology) {
            const size_t word = static_cast<size_t>(slot) * out.technology_words +
                technology / 64u;
            const uint64_t bit = uint64_t{1} << (technology % 64u);
            if ((out.country_pending_technologies[word] & bit) == 0) continue;
            uint8_t flags = 0;
            if (_effect_runtime_enabled && _effect_runtime != nullptr) {
                const uint64_t target = make_handle(static_cast<int32_t>(slot));
                const uint64_t effect_id = ((target & 0x00007fffffffffffULL) << 16U) +
                    static_cast<uint64_t>(technology + 1u);
                const uint32_t effect_generation = static_cast<uint32_t>(target >> 32U);
                // Ask whichever side owns EFFECT. The old unconditional
                // EffectRuntime query read false for every worker-owned instance,
                // so the report claimed the technology had no Effect at all.
                bool effect_exists = false;
                effect_pod_instance_exists(_effect_runtime, _effect_forwarder,
                    static_cast<int64_t>(effect_id), effect_generation,
                    effect_exists);
                if (effect_exists) flags |= COUNTRY_PEER_EFFECT_EXISTS;
                bool effect_acked = false;
                effect_pod_instance_fire_acked(_effect_runtime, _effect_forwarder,
                    static_cast<int64_t>(effect_id), effect_generation,
                    effect_acked);
                if (effect_acked) flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
            }
            if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime) &&
                technology < _technology_modifier_definition_keys.size() &&
                !_technology_modifier_definition_keys[technology].empty() &&
                modifier_api::has_technology_effect(*_modifier_runtime,
                    make_handle(static_cast<int32_t>(slot)),
                    _technology_modifier_definition_keys[technology],
                    static_cast<int32_t>(technology)))
                flags |= COUNTRY_PEER_MODIFIER_APPLIED;
            out.research_peer_flags[static_cast<size_t>(slot) * out.technology_count +
                                    technology] = flags;
        }
    }
    out.is_water = _is_water;
    if (out.cell_count != out.cell_country_slot.size() ||
        out.country_count != out.country_generation.size() ||
        out.country_count != out.country_active.size() ||
        out.country_count != out.country_state_version.size() ||
        out.country_count != out.country_political_regime_ids.size() ||
        out.country_count != out.country_political_regime_capabilities.size() ||
        out.country_count * out.good_count != out.country_goods.size() ||
        out.research_cost_factor.size() != out.country_count ||
        out.research_efficiency.size() != out.country_count * 4u ||
        out.research_peer_flags.size() !=
            static_cast<size_t>(out.country_count) * out.technology_count ||
        (out.research_signal_words > 0 &&
         out.country_count * out.research_signal_words !=
             out.country_research_signals.size()) ||
        out.research_signal_evidence_offsets.size() !=
            static_cast<size_t>(out.country_count) + 1u ||
        out.research_signal_cell_offsets.size() !=
            static_cast<size_t>(out.country_count) + 1u ||
        out.territory_offsets.size() != static_cast<size_t>(out.country_count) + 1u ||
        out.territory_offsets.back() != static_cast<int32_t>(out.territory_cells.size())) {
        error = "country_pod_snapshot_shape_mismatch";
        out = RuntimeCountryPodSnapshot{};
        return false;
    }
    out.state_hash = country_core_hash_business_state(out);
    return true;
}

bool NativeCountryRuntime::export_pod_catalog(
        RuntimeCountryPodCatalog &out, std::string &error) const {
    out = RuntimeCountryPodCatalog{};
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_not_bootstrapped";
        return false;
    }
    out.catalog_hash = _technology_catalog_identity_hash ^ _political_regime_catalog_hash;
    out.technology_count = static_cast<uint32_t>(_technology_ids.size());
    out.technology_words = static_cast<uint32_t>(std::max(0, _technology_words));
    out.technology_points_good_id = _technology_points_good_id;
    out.technology_costs = _technology_costs;
    out.technology_domains = _technology_domains;
    out.technology_flags = _technology_flags;
    out.technology_effect_required.resize(out.technology_count, 0);
    for (size_t technology = 0; technology < out.technology_count; ++technology)
        out.technology_effect_required[technology] =
            technology < _technology_modifier_definition_keys.size() &&
            !_technology_modifier_definition_keys[technology].empty() ? 1u : 0u;
    out.technology_effect_key_hashes.resize(out.technology_count, 0);
    for (size_t technology = 0; technology < out.technology_count; ++technology)
        out.technology_effect_key_hashes[technology] =
            runtime_text_hash(("technology." + _technology_ids[technology]).c_str());
    out.prerequisite_offsets = _technology_prerequisite_offsets;
    out.prerequisites = _technology_prerequisites;
    out.milestone_offsets = _technology_milestone_offsets;
    out.milestone_candidates = _technology_milestone_candidates;
    out.milestone_required_counts = _technology_milestone_required_counts;
    out.entry_milestone_indices = _technology_entry_milestone_indices;
    out.research_condition_offsets = _technology_research_condition_offsets;
    out.research_condition_ops = _technology_research_condition_ops;
    out.research_condition_refs = _technology_research_condition_refs;
    out.research_condition_values = _technology_research_condition_values;
    out.reveal_condition_offsets = _technology_reveal_condition_offsets;
    out.reveal_condition_ops = _technology_reveal_condition_ops;
    out.reveal_condition_refs = _technology_reveal_condition_refs;
    out.reveal_condition_values = _technology_reveal_condition_values;
    out.starting_technologies = _starting_technologies;
    out.political_regime_ids = _political_regime_ids;
    out.political_regime_capability_bits = _political_regime_capability_bits;
    out.political_regime_catalog_hash = _political_regime_catalog_hash;
    out.research_conditions_complete =
        out.research_condition_offsets.size() ==
            static_cast<size_t>(out.technology_count) + 1u &&
        out.research_condition_ops.size() == out.research_condition_refs.size() &&
        out.research_condition_ops.size() == out.research_condition_values.size() &&
        !out.research_condition_offsets.empty() &&
        out.research_condition_offsets.back() ==
            static_cast<int32_t>(out.research_condition_ops.size());
    return true;
}

bool NativeCountryRuntime::apply_committed_read_snapshot(
        const RuntimeCountryPodSnapshot &snapshot) {
    // A read replica must never partially install a malformed worker commit.
    // Keep the previous immutable view intact when a producer publishes an
    // incomplete fixture or an older ABI shape.
    // research_queue_lengths / research_weights_bp are per domain (×4), matching
    // export_pod_snapshot, PKCN, and RuntimeCountryPodAuthority validation.
    //
    // Optional CSR / tax planes that POD validation does not require can arrive
    // undersized after soft-commit. Repair those here so ACTIVE UI research
    // progress cannot freeze on the pre-handoff sync store forever.
    RuntimeCountryPodSnapshot repaired = snapshot;
    const size_t country_count = static_cast<size_t>(repaired.country_count);
    const size_t technology_count = static_cast<size_t>(repaired.technology_count);
    const size_t cell_count = static_cast<size_t>(repaired.cell_count);
    const size_t technology_words =
        static_cast<size_t>(repaired.technology_words);
    const size_t domain_lanes =
        country_count * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
    if (repaired.cell_tax_policy_ids.size() != cell_count)
        repaired.cell_tax_policy_ids.assign(cell_count, 0u);
    if (repaired.country_discovered.size() != country_count * technology_words)
        repaired.country_discovered.assign(country_count * technology_words, 0u);
    if (repaired.research_deferred_points.size() != country_count)
        repaired.research_deferred_points.assign(country_count, 0);
    if (repaired.research_progress_total.size() != country_count)
        repaired.research_progress_total.assign(country_count, 0);
    if (repaired.research_completed_total.size() != country_count)
        repaired.research_completed_total.assign(country_count, 0);
    if (repaired.research_auto_purchase.size() != country_count)
        repaired.research_auto_purchase.assign(country_count, 0);
    if (repaired.research_purchased_total.size() != country_count)
        repaired.research_purchased_total.assign(country_count, 0);
    if (repaired.research_consumed_total.size() != country_count)
        repaired.research_consumed_total.assign(country_count, 0);
    if (repaired.country_political_regime_ids.size() != country_count)
        repaired.country_political_regime_ids.assign(country_count, 0);
    if (repaired.country_political_regime_capabilities.size() != country_count)
        repaired.country_political_regime_capabilities.assign(country_count, 0);
    const auto repair_signal_csr = [&](std::vector<int32_t> &offsets,
                                       size_t payload_size) {
        if (offsets.size() == country_count + 1u &&
            !offsets.empty() && offsets.front() == 0 &&
            static_cast<size_t>(offsets.back()) == payload_size) {
            bool mono = true;
            for (size_t i = 1; i < offsets.size(); ++i) {
                if (offsets[i] < offsets[i - 1u]) {
                    mono = false;
                    break;
                }
            }
            if (mono) return;
        }
        offsets.assign(country_count + 1u, 0);
    };
    repair_signal_csr(repaired.research_signal_cell_offsets,
                      repaired.research_signal_cells.size());
    if (repaired.research_signal_cell_offsets.back() == 0)
        repaired.research_signal_cells.clear();
    repair_signal_csr(repaired.research_signal_evidence_offsets,
                      repaired.research_signal_evidence.size());
    if (repaired.research_signal_evidence_offsets.back() == 0)
        repaired.research_signal_evidence.clear();
    const bool shape_ok =
        repaired.country_active.size() == country_count &&
        repaired.country_generation.size() == country_count &&
        repaired.country_stable_ids.size() == country_count &&
        repaired.country_display_names.size() == country_count &&
        repaired.territory_count.size() == country_count &&
        repaired.country_state_version.size() == country_count &&
        repaired.country_political_regime_ids.size() == country_count &&
        repaired.country_political_regime_capabilities.size() == country_count &&
        repaired.country_cash.size() == country_count &&
        repaired.country_goods.size() == country_count *
            static_cast<size_t>(repaired.good_count) &&
        repaired.country_technologies.size() == country_count * technology_words &&
        repaired.country_discovered.size() == country_count * technology_words &&
        repaired.country_pending_technologies.size() ==
            country_count * technology_words &&
        repaired.research_queues.size() == domain_lanes * 8U &&
        repaired.research_queue_lengths.size() == domain_lanes &&
        repaired.research_weights_bp.size() == domain_lanes &&
        repaired.research_progress.size() == country_count * technology_count &&
        repaired.research_signal_cell_offsets.size() == country_count + 1 &&
        repaired.research_signal_evidence_offsets.size() == country_count + 1 &&
        repaired.cell_country_slot.size() == cell_count &&
        repaired.cell_tax_policy_ids.size() == cell_count &&
        repaired.territory_offsets.size() == country_count + 1;
    if (!shape_ok) {
        static int s_shape_left = 12;
        if (s_shape_left-- > 0) {
            UtilityFunctions::print(vformat(
                "[tech-ui-diag/apply] reject gen=%d day=%d countries=%d cells=%d "
                "techs=%d words=%d goods=%d "
                "active=%d genv=%d ids=%d names=%d terr=%d ver=%d cash=%d "
                "goods_v=%d tech=%d disc=%d pend=%d "
                "rq=%d rql=%d rqw=%d prog=%d "
                "sig_off=%d sig_cells=%d ev_off=%d ev=%d "
                "owners=%d tax=%d terr_off=%d",
                static_cast<int64_t>(repaired.generation),
                repaired.committed_day,
                static_cast<int64_t>(country_count),
                static_cast<int64_t>(cell_count),
                static_cast<int64_t>(technology_count),
                static_cast<int64_t>(technology_words),
                static_cast<int64_t>(repaired.good_count),
                static_cast<int64_t>(repaired.country_active.size()),
                static_cast<int64_t>(repaired.country_generation.size()),
                static_cast<int64_t>(repaired.country_stable_ids.size()),
                static_cast<int64_t>(repaired.country_display_names.size()),
                static_cast<int64_t>(repaired.territory_count.size()),
                static_cast<int64_t>(repaired.country_state_version.size()),
                static_cast<int64_t>(repaired.country_cash.size()),
                static_cast<int64_t>(repaired.country_goods.size()),
                static_cast<int64_t>(repaired.country_technologies.size()),
                static_cast<int64_t>(repaired.country_discovered.size()),
                static_cast<int64_t>(repaired.country_pending_technologies.size()),
                static_cast<int64_t>(repaired.research_queues.size()),
                static_cast<int64_t>(repaired.research_queue_lengths.size()),
                static_cast<int64_t>(repaired.research_weights_bp.size()),
                static_cast<int64_t>(repaired.research_progress.size()),
                static_cast<int64_t>(repaired.research_signal_cell_offsets.size()),
                static_cast<int64_t>(repaired.research_signal_cells.size()),
                static_cast<int64_t>(
                    repaired.research_signal_evidence_offsets.size()),
                static_cast<int64_t>(repaired.research_signal_evidence.size()),
                static_cast<int64_t>(repaired.cell_country_slot.size()),
                static_cast<int64_t>(repaired.cell_tax_policy_ids.size()),
                static_cast<int64_t>(repaired.territory_offsets.size())));
        }
        return false;
    }
    for (size_t slot = 0; slot < country_count; ++slot) {
        if (repaired.research_signal_cell_offsets[slot] < 0 ||
            repaired.research_signal_cell_offsets[slot + 1] <
                repaired.research_signal_cell_offsets[slot] ||
            static_cast<size_t>(repaired.research_signal_cell_offsets[slot + 1]) >
                repaired.research_signal_cells.size() ||
            repaired.research_signal_evidence_offsets[slot] < 0 ||
            repaired.research_signal_evidence_offsets[slot + 1] <
                repaired.research_signal_evidence_offsets[slot] ||
            static_cast<size_t>(
                repaired.research_signal_evidence_offsets[slot + 1]) >
                repaired.research_signal_evidence.size()) {
            static int s_csr_left = 8;
            if (s_csr_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ui-diag/apply] csr reject slot=%d gen=%d "
                    "cell_off=%d/%d cells=%d ev_off=%d/%d ev=%d",
                    static_cast<int64_t>(slot),
                    static_cast<int64_t>(repaired.generation),
                    repaired.research_signal_cell_offsets[slot],
                    repaired.research_signal_cell_offsets[slot + 1],
                    static_cast<int64_t>(repaired.research_signal_cells.size()),
                    repaired.research_signal_evidence_offsets[slot],
                    repaired.research_signal_evidence_offsets[slot + 1],
                    static_cast<int64_t>(
                        repaired.research_signal_evidence.size())));
            }
            return false;
        }
    }
    _simulation_host = nullptr;
    _sync_store_writes_forbidden = true;
    _state_hash_cache_valid = false;
    _generation = repaired.generation;
    _last_committed_day = repaired.committed_day;
    _last_research_day = repaired.last_research_day;
    _session_epoch = repaired.session_epoch;
    _countries.active = repaired.country_active;
    _starting_country_slot = _countries.active.empty() ? -1 : 0;
    _countries.generation = repaired.country_generation;
    _countries.stable_id = repaired.country_stable_ids;
    _countries.display_name = repaired.country_display_names;
    _research_active_country_slots = repaired.research_active_country_slots;
    _countries.territory_count = repaired.territory_count;
    _countries.capital_cell = repaired.capital_cell;
    if (_countries.capital_cell.size() != _countries.active.size())
        _countries.capital_cell.assign(_countries.active.size(), -1);
    _countries.state_version = repaired.country_state_version;
    _countries.political_regime_id = repaired.country_political_regime_ids;
    _countries.political_regime_capability_bits =
        repaired.country_political_regime_capabilities;
    _countries.cash = repaired.country_cash;
    _country_goods = repaired.country_goods;
    _cell_country_slot = repaired.cell_country_slot;
    _country_cell_offsets = repaired.territory_offsets;
    _country_cells = repaired.territory_cells;
    _country_technologies = repaired.country_technologies;
    _country_discovered = repaired.country_discovered;
    _country_pending_technologies = repaired.country_pending_technologies;
    _country_research_signals = repaired.country_research_signals;
    _country_research_queues = repaired.research_queues;
    _country_research_queue_lengths = repaired.research_queue_lengths;
    _country_research_weights_bp = repaired.research_weights_bp;
    _country_research_deferred_points = repaired.research_deferred_points;
    _country_research_progress_total = repaired.research_progress_total;
    _country_research_completed_total = repaired.research_completed_total;
    _country_research_auto_purchase = repaired.research_auto_purchase;
    _country_research_purchased_total = repaired.research_purchased_total;
    _country_research_consumed_total = repaired.research_consumed_total;
    _country_treasury_goods_consumed_total = repaired.treasury_goods_consumed_total;
    _country_treasury_goods_consumed_total.resize(country_count, 0);
    _country_tax_defaults = repaired.country_tax_defaults;
    _country_tax_default_modes = repaired.country_tax_default_modes;
    _country_income_tax_overrides = repaired.country_income_tax_overrides;
    _country_consumption_tax_overrides = repaired.country_consumption_tax_overrides;
    _country_business_tax_overrides = repaired.country_business_tax_overrides;
    _country_import_tax_overrides = repaired.country_import_tax_overrides;
    _country_export_tax_overrides = repaired.country_export_tax_overrides;
    _country_income_tax_mode_overrides = repaired.country_income_tax_mode_overrides;
    _country_consumption_tax_mode_overrides = repaired.country_consumption_tax_mode_overrides;
    _country_business_tax_mode_overrides = repaired.country_business_tax_mode_overrides;
    _country_import_tax_mode_overrides = repaired.country_import_tax_mode_overrides;
    _country_export_tax_mode_overrides = repaired.country_export_tax_mode_overrides;
    _cell_tax_policy_ids = repaired.cell_tax_policy_ids;
    _is_water = repaired.is_water;
    _tax_policy_version = repaired.generation;
    _territory_generation = repaired.generation;
    _research_generation = repaired.generation;
    // Worker snapshots do not carry the visual-era cache. Derive it from the
    // committed milestone bits so building visuals refresh in ACTIVE mode.
    if (_current_visual_era.size() < _countries.active.size())
        _current_visual_era.resize(_countries.active.size(), -1);
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        const int32_t era = visual_era_index_for_slot(slot);
        if (_current_visual_era[static_cast<size_t>(slot)] == era) continue;
        _current_visual_era[static_cast<size_t>(slot)] = era;
        _visual_era_dirty_slots.push_back(slot);
        ++_visual_era_generation;
    }
    _country_research_progress.assign(repaired.country_count, {});
    _country_research_signal_cells.assign(repaired.country_count, {});
    _country_research_signal_evidence.assign(repaired.country_count, {});
    for (uint32_t slot = 0; slot < repaired.country_count; ++slot) {
        for (uint32_t tech = 0; tech < repaired.technology_count; ++tech) {
            const auto value = repaired.research_progress[slot * repaired.technology_count + tech];
            if (value != 0) _country_research_progress[slot].emplace_back(tech, value);
        }
        _country_research_signal_cells[slot].assign(
            repaired.research_signal_cells.begin() + repaired.research_signal_cell_offsets[slot],
            repaired.research_signal_cells.begin() + repaired.research_signal_cell_offsets[slot + 1]);
        for (int32_t i = repaired.research_signal_evidence_offsets[slot];
             i < repaired.research_signal_evidence_offsets[slot + 1]; ++i) {
            const auto &v = repaired.research_signal_evidence[i];
            _country_research_signal_evidence[slot].push_back(
                {v.signal, v.count, v.first_day, v.last_day, v.first_cell});
        }
    }
    _cell_tax_policies.clear();
    for (const auto &policy : repaired.cell_tax_policies) {
        CellTaxPolicy out;
        out.defaults = policy.defaults;
        out.default_modes = policy.modes;
        for (const auto &v : policy.overrides)
            out.overrides.push_back({v.kind, v.item, v.rate, v.mode});
        _cell_tax_policies.push_back(std::move(out));
    }
    _report = _report.duplicate();
    _report["last_committed_day"] = repaired.committed_day;
    _report["generation"] = static_cast<int64_t>(repaired.generation);
    _report["ok"] = true;
    return true;
}

} // namespace pk
