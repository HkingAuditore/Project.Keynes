#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_core_apply.h"
#include "economy_effect_forward.h"
#include "modifier_api.h"
#include "country_host_port.h"

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
    out.research_daily_budgets = _country_research_daily_budgets;
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
Dictionary NativeCountryRuntime::cell_summary(int32_t cell) const {
    if (!_bootstrapped || cell < 0 || cell >= _cell_count) return {};
    Dictionary out;
    out["ok"] = true;
    out["cell"] = cell;
    const int32_t slot = _cell_country_slot[static_cast<size_t>(cell)];
    out["country_slot"] = slot;
    if (slot < 0) {
        out["owned"] = false;
        // Must use utf8(): Godot String(const char*) is not UTF-8 and mojibakes CJK.
        out["country_name"] = String::utf8("无主之地");
        out["country_handle"] = static_cast<int64_t>(0);
        return out;
    }
    Dictionary country = country_summary(static_cast<int64_t>(make_handle(slot)));
    const Array keys = country.keys();
    for (int64_t index = 0; index < keys.size(); ++index)
        out[keys[index]] = country[keys[index]];
    out["cell"] = cell;
    out["country_slot"] = slot;
    return out;
}

Dictionary NativeCountryRuntime::country_summary(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return fail("country_handle_invalid");
    int32_t nonzero_goods = 0;
    for (size_t good = 0; good < _good_ids.size(); ++good)
        if (_country_goods[static_cast<size_t>(slot) * _good_ids.size() + good] != 0)
            ++nonzero_goods;
    int32_t technologies = 0;
    for (int32_t tech = 0;
         tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech)) ++technologies;
    Dictionary out;
    out["ok"] = true;
    out["owned"] = true;
    out["country_handle"] = handle;
    out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
    out["country_name"] = String::utf8(
        _countries.display_name[static_cast<size_t>(slot)].c_str());
    out["territory_count"] =
        _countries.territory_count[static_cast<size_t>(slot)];
    out["cash"] = _countries.cash[static_cast<size_t>(slot)];
    out["nonzero_good_count"] = nonzero_goods;
    out["technology_count"] = technologies;
    out["state_version"] = static_cast<int64_t>(
        _countries.state_version[static_cast<size_t>(slot)]);
    out["political_regime_id"] = _countries.political_regime_id[
        static_cast<size_t>(slot)];
    const int32_t regime = _countries.political_regime_id[
        static_cast<size_t>(slot)];
    out["political_regime_key"] = regime >= 0 &&
            static_cast<size_t>(regime) < _political_regime_ids.size()
        ? String::utf8(_political_regime_ids[static_cast<size_t>(regime)].c_str())
        : String();
    out["political_regime_capability_bits"] = static_cast<int64_t>(
        _countries.political_regime_capability_bits[static_cast<size_t>(slot)]);
    Dictionary politics;
    politics["regime_id"] = _countries.political_regime_id[static_cast<size_t>(slot)];
    politics["regime_key"] = out["political_regime_key"];
    politics["capability_bits"] = out["political_regime_capability_bits"];
    politics["can_treasury_construction"] =
        (_countries.political_regime_capability_bits[static_cast<size_t>(slot)] &
         CAP_TREASURY_CONSTRUCTION) != 0;
    politics["state_version"] = out["state_version"];
    out["politics"] = politics;
    out["capability_bits"] = out["political_regime_capability_bits"];
    out["can_treasury_construction"] = politics["can_treasury_construction"];
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

int32_t NativeCountryRuntime::political_regime_id_for_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        _countries.active[static_cast<size_t>(slot)] == 0 ||
        static_cast<size_t>(slot) >= _countries.political_regime_id.size())
        return -1;
    return _countries.political_regime_id[static_cast<size_t>(slot)];
}

uint32_t NativeCountryRuntime::political_regime_capabilities_for_slot(
        int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        _countries.active[static_cast<size_t>(slot)] == 0 ||
        static_cast<size_t>(slot) >= _countries.political_regime_capability_bits.size())
        return 0;
    return _countries.political_regime_capability_bits[static_cast<size_t>(slot)];
}

Dictionary NativeCountryRuntime::political_regime_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return fail("country_handle_invalid");
    const int32_t regime = political_regime_id_for_slot(slot);
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["regime_id"] = regime;
    out["regime_key"] = regime >= 0 && static_cast<size_t>(regime) <
            _political_regime_ids.size()
        ? String::utf8(_political_regime_ids[static_cast<size_t>(regime)].c_str())
        : String();
    out["capability_bits"] = static_cast<int64_t>(
        political_regime_capabilities_for_slot(slot));
    out["can_treasury_construction"] =
        (political_regime_capabilities_for_slot(slot) & CAP_TREASURY_CONSTRUCTION) != 0;
    out["catalog_hash"] = static_cast<int64_t>(_political_regime_catalog_hash);
    out["state_version"] = static_cast<int64_t>(
        _countries.state_version[static_cast<size_t>(slot)]);
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

PackedStringArray NativeCountryRuntime::completed_technology_ids(
        int64_t handle) const {
    int32_t slot = -1;
    PackedStringArray technology_ids;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return technology_ids;
    for (int32_t tech = 0;
         tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech))
            technology_ids.push_back(
                _technology_ids[static_cast<size_t>(tech)].c_str());
    return technology_ids;
}

Dictionary NativeCountryRuntime::submit_observation_batch(
        int64_t handle, const PackedInt32Array &cells,
        const PackedInt32Array &signals, int64_t effective_day) {
    if (!_configured || !_bootstrapped) return fail("country_not_bootstrapped");
    if (_mode == MODE_OFF) return fail("country_runtime_off");
    if (effective_day < 0 || cells.size() != signals.size())
        return fail("country_observation_batch_invalid");
    int32_t country_slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), country_slot))
        return fail("country_handle_invalid");
    const int32_t count = cells.size();
    if (count == 0) {
        Dictionary out;
        out["ok"] = true;
        out["submitted"] = 0;
        out["pending"] = static_cast<int64_t>(_pending_commands.size());
        return out;
    }
    const int32_t signal_count = static_cast<int32_t>(_research_signal_ids.size());
    for (int32_t i = 0; i < count; ++i) {
        if (cells[i] < 0 || cells[i] >= _cell_count ||
            signals[i] < 0 || signals[i] >= signal_count)
            return fail("country_observation_batch_invalid");
    }
    _pending_commands.reserve(_pending_commands.size() + size_t(count));
    for (int32_t i = 0; i < count; ++i) {
        Command command;
        command.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL;
        command.effective_day = effective_day;
        command.sequence = i;
        command.target_handle = static_cast<uint64_t>(handle);
        command.cell = cells[i];
        command.aux = signals[i];
        command.value = 1;
        command.submit_order = ++_submit_order;
        _pending_commands.push_back(std::move(command));
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted"] = count;
    out["pending"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool NativeCountryRuntime::has_completed_technology(
        int64_t handle, int32_t technology_id) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(handle), slot) &&
           has_technology(slot, technology_id);
}

int32_t NativeCountryRuntime::visual_era_index_for_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        _countries.active[static_cast<size_t>(slot)] == 0 ||
        _technology_words <= 0)
        return -1;
    int32_t era = -1;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t i = 0;
         i < static_cast<int32_t>(_technology_era_milestone_indices.size()); ++i) {
        const int32_t technology =
            _technology_era_milestone_indices[static_cast<size_t>(i)];
        if (technology < 0 ||
            technology >= static_cast<int32_t>(_technology_ids.size()))
            continue;
        const size_t word = base + static_cast<size_t>(technology / 64);
        if (word < _country_technologies.size() &&
            (_country_technologies[word] &
             (uint64_t{1} << (technology % 64))) != 0)
            era = i;
    }
    return era;
}

Dictionary NativeCountryRuntime::consume_visual_era_dirty_slots() {
    Dictionary out;
    std::sort(_visual_era_dirty_slots.begin(), _visual_era_dirty_slots.end());
    _visual_era_dirty_slots.erase(std::unique(_visual_era_dirty_slots.begin(),
                                              _visual_era_dirty_slots.end()),
                                  _visual_era_dirty_slots.end());
    PackedInt32Array slots;
    slots.resize(static_cast<int64_t>(_visual_era_dirty_slots.size()));
    for (int64_t i = 0; i < slots.size(); ++i)
        slots.set(i, _visual_era_dirty_slots[static_cast<size_t>(i)]);
    _visual_era_dirty_slots.clear();
    out["ok"] = _bootstrapped;
    out["country_era_generation"] =
        static_cast<int64_t>(_visual_era_generation);
    out["country_slots"] = slots;
    if (!_bootstrapped) out["reason"] = "country_not_bootstrapped";
    return out;
}

Dictionary NativeCountryRuntime::country_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedStringArray technology_ids = completed_technology_ids(handle);
    PackedInt32Array cells;
    if (slot + 1 < static_cast<int32_t>(_country_cell_offsets.size())) {
        const int32_t begin = _country_cell_offsets[static_cast<size_t>(slot)];
        const int32_t end = _country_cell_offsets[static_cast<size_t>(slot + 1)];
        cells.resize(end - begin);
        if (end > begin) std::memcpy(cells.ptrw(), _country_cells.data() + begin, static_cast<size_t>(end - begin) * sizeof(int32_t));
    }
    Dictionary out = country_summary(handle);
    out["cell"] = cells.is_empty() ? -1 : cells[0];
    out["country_slot"] = slot;
    out["technology_ids"] = technology_ids;
    out["territory_cells"] = cells;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

Dictionary NativeCountryRuntime::treasury_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedStringArray good_ids;
    PackedInt64Array quantities;
    for (size_t good = 0; good < _good_ids.size(); ++good) {
        const int64_t quantity = _country_goods[static_cast<size_t>(slot) * _good_ids.size() + good];
        if (quantity == 0) continue;
        good_ids.push_back(_good_ids[good].c_str());
        quantities.push_back(quantity);
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["cash"] = _countries.cash[static_cast<size_t>(slot)];
    out["good_ids"] = good_ids;
    out["quantities"] = quantities;
    return out;
}

Dictionary NativeCountryRuntime::tax_policy_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return fail("country_handle_invalid");

    PackedInt32Array defaults;
    PackedInt32Array default_modes;
    defaults.resize(TAX_KIND_COUNT);
    default_modes.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        const size_t index =
            static_cast<size_t>(slot) * TAX_KIND_COUNT + kind;
        defaults.set(kind, _country_tax_defaults[index]);
        default_modes.set(kind, _country_tax_default_modes[index]);
    }

    auto make_rates = [&](int32_t kind, const char *kind_key,
                          const std::vector<std::string> &item_ids,
                          const std::vector<int32_t> &values,
                          const std::vector<int32_t> &modes) {
        PackedInt32Array rates, effective_rates;
        PackedInt32Array rates_percent, effective_rates_percent;
        PackedInt32Array assessment_modes;
        PackedInt32Array absolute_amounts;
        PackedByteArray overrides;
        const int32_t count = tax_item_count(kind);
        rates.resize(count);
        effective_rates.resize(count);
        rates_percent.resize(count);
        effective_rates_percent.resize(count);
        assessment_modes.resize(count);
        absolute_amounts.resize(count);
        overrides.resize(count);
        for (int32_t item = 0; item < count; ++item) {
            const size_t index =
                static_cast<size_t>(slot) * count + item;
            const int32_t raw = values[index];
            const int32_t raw_mode = modes[index];
            const int32_t mode = raw_mode == TAX_MODE_INHERIT
                ? default_modes[kind] : raw_mode;
            const int32_t base_value = raw == TAX_RATE_INHERIT
                ? defaults[kind] : raw;
            rates.set(item, base_value);
            assessment_modes.set(item, mode);
            absolute_amounts.set(
                item, mode == TAX_MODE_ABSOLUTE ? base_value : 0);
            int32_t effective_value = base_value;
            if (mode == TAX_MODE_PERCENT_BP &&
                _modifier_runtime != nullptr &&
                item < static_cast<int32_t>(item_ids.size())) {
                const std::string stat_key = std::string("country.tax.") +
                    kind_key + "." + item_ids[item] + ".rate_bp";
                const int32_t stat_id =
                    modifier_api::stat_id_for_key(*_modifier_runtime, stat_key);
                if (stat_id >= 0) {
                    effective_value = static_cast<int32_t>(std::clamp<int64_t>(
                        std::lround(modifier_api::effective_value(*_modifier_runtime,
                            ModifierApi::COUNTRY, stat_id,
                            static_cast<uint64_t>(handle), 0, base_value)),
                        TAX_RATE_MIN_BP, TAX_RATE_MAX_BP));
                }
            }
            effective_rates.set(item, effective_value);
            rates_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP ? base_value / 100 : 0);
            effective_rates_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP ? effective_value / 100 : 0);
            overrides.set(item, raw == TAX_RATE_INHERIT &&
                                        raw_mode == TAX_MODE_INHERIT
                                    ? 0
                                    : 1);
        }
        Dictionary result;
        result["rates_basis_points"] = rates;
        result["effective_rates_basis_points"] = effective_rates;
        result["rates"] = rates_percent;
        result["effective_rates"] = effective_rates_percent;
        result["assessment_modes"] = assessment_modes;
        result["absolute_amounts"] = absolute_amounts;
        result["has_override"] = overrides;
        return result;
    };
    auto make_ids = [](const std::vector<std::string> &ids) {
        PackedStringArray out;
        for (const std::string &id : ids) out.push_back(id.c_str());
        return out;
    };

    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["policy_version"] = static_cast<int64_t>(_tax_policy_version);
    out["catalog_hash"] = static_cast<int64_t>(catalog_hash());
    PackedInt32Array defaults_percent;
    defaults_percent.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        defaults_percent.set(
            kind,
            default_modes[kind] == TAX_MODE_PERCENT_BP
                ? defaults[kind] / 100
                : 0);
    }
    out["default_rates_basis_points"] = defaults;
    out["default_rates"] = defaults_percent;
    out["default_assessment_modes"] = default_modes;
    out["profession_ids"] = make_ids(_profession_ids);
    out["good_ids"] = make_ids(_good_ids);
    out["building_type_ids"] = make_ids(_building_type_ids);
    out["income"] = make_rates(TAX_INCOME, "income", _profession_ids,
                               _country_income_tax_overrides,
                               _country_income_tax_mode_overrides);
    out["consumption"] = make_rates(
        TAX_CONSUMPTION, "consumption", _good_ids,
        _country_consumption_tax_overrides,
        _country_consumption_tax_mode_overrides);
    out["transaction"] = out["consumption"];
    out["business"] = make_rates(
        TAX_BUSINESS, "business", _building_type_ids,
        _country_business_tax_overrides,
        _country_business_tax_mode_overrides);
    out["import"] = make_rates(TAX_IMPORT, "import", _good_ids,
                               _country_import_tax_overrides,
                               _country_import_tax_mode_overrides);
    out["export"] = make_rates(TAX_EXPORT, "export", _good_ids,
                               _country_export_tax_overrides,
                               _country_export_tax_mode_overrides);
    out["tariffs_active"] = false;
    return out;
}

Dictionary NativeCountryRuntime::cell_tax_policy_snapshot(int32_t cell) const {
    if (!_bootstrapped || cell < 0 || cell >= _cell_count)
        return fail("country_cell_tax_cell_invalid");
    const int32_t slot = _cell_country_slot[static_cast<size_t>(cell)];
    if (slot < 0) return fail("country_cell_tax_unowned");
    const uint64_t handle = make_handle(slot);
    const CellTaxPolicy &policy = cell_tax_policy(
        _cell_tax_policy_ids[static_cast<size_t>(cell)]);

    PackedInt32Array country_defaults;
    PackedInt32Array country_default_modes;
    PackedInt32Array local_defaults;
    PackedInt32Array local_default_modes;
    PackedByteArray has_local_default;
    country_defaults.resize(TAX_KIND_COUNT);
    country_default_modes.resize(TAX_KIND_COUNT);
    local_defaults.resize(TAX_KIND_COUNT);
    local_default_modes.resize(TAX_KIND_COUNT);
    has_local_default.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        const size_t index =
            static_cast<size_t>(slot) * TAX_KIND_COUNT + kind;
        country_defaults.set(kind, _country_tax_defaults[index]);
        country_default_modes.set(kind, _country_tax_default_modes[index]);
        const int32_t local = policy.defaults[static_cast<size_t>(kind)];
        const int32_t local_mode =
            policy.default_modes[static_cast<size_t>(kind)];
        local_defaults.set(kind, local == TAX_RATE_INHERIT ? 0 : local);
        local_default_modes.set(
            kind, local_mode == TAX_MODE_INHERIT ? 0 : local_mode);
        has_local_default.set(
            kind,
            local == TAX_RATE_INHERIT && local_mode == TAX_MODE_INHERIT
                ? 0
                : 1);
    }

    auto make_kind = [&](int32_t kind, const char *kind_key) {
        const auto &ids = tax_item_ids(kind);
        const std::vector<int32_t> *country_overrides =
            tax_override_vector(kind);
        const std::vector<int32_t> *country_mode_overrides =
            tax_mode_override_vector(kind);
        const int32_t count = static_cast<int32_t>(ids.size());
        PackedStringArray item_ids;
        PackedInt32Array country_base_rates;
        PackedInt32Array local_item_rates;
        PackedInt32Array final_base_rates;
        PackedInt32Array effective_rates;
        PackedInt32Array assessment_modes;
        PackedInt32Array absolute_amounts;
        PackedByteArray has_local_item;
        PackedStringArray source_scopes;
        item_ids.resize(count);
        country_base_rates.resize(count);
        local_item_rates.resize(count);
        final_base_rates.resize(count);
        effective_rates.resize(count);
        assessment_modes.resize(count);
        absolute_amounts.resize(count);
        has_local_item.resize(count);
        source_scopes.resize(count);
        size_t local_cursor = 0;
        while (local_cursor < policy.overrides.size() &&
               policy.overrides[local_cursor].kind < kind)
            ++local_cursor;
        for (int32_t item = 0; item < count; ++item) {
            item_ids.set(item, ids[static_cast<size_t>(item)].c_str());
            const size_t country_index =
                static_cast<size_t>(slot) * count + item;
            const int32_t country_raw = (*country_overrides)[country_index];
            const int32_t country_mode_raw =
                (*country_mode_overrides)[country_index];
            const int32_t country_base = country_raw == TAX_RATE_INHERIT
                ? country_defaults[kind] : country_raw;
            const int32_t country_mode =
                country_mode_raw == TAX_MODE_INHERIT
                    ? country_default_modes[kind]
                    : country_mode_raw;
            country_base_rates.set(item, country_base);
            while (local_cursor < policy.overrides.size() &&
                   policy.overrides[local_cursor].kind == kind &&
                   policy.overrides[local_cursor].item < item)
                ++local_cursor;
            const bool local_item =
                local_cursor < policy.overrides.size() &&
                policy.overrides[local_cursor].kind == kind &&
                policy.overrides[local_cursor].item == item;
            const int32_t local_default =
                policy.defaults[static_cast<size_t>(kind)];
            const int32_t local_default_mode =
                policy.default_modes[static_cast<size_t>(kind)];
            int32_t base_value = country_base;
            int32_t mode = country_mode;
            if (local_item) {
                base_value = policy.overrides[local_cursor].rate;
                mode = policy.overrides[local_cursor].mode == TAX_MODE_INHERIT
                    ? (local_default_mode != TAX_MODE_INHERIT
                           ? local_default_mode
                           : country_mode)
                    : policy.overrides[local_cursor].mode;
            } else if (local_default != TAX_RATE_INHERIT ||
                       local_default_mode != TAX_MODE_INHERIT) {
                if (local_default != TAX_RATE_INHERIT)
                    base_value = local_default;
                if (local_default_mode != TAX_MODE_INHERIT)
                    mode = local_default_mode;
            }
            local_item_rates.set(item, local_item
                ? policy.overrides[local_cursor].rate : 0);
            has_local_item.set(item, local_item ? 1 : 0);
            final_base_rates.set(item, base_value);
            assessment_modes.set(item, mode);
            absolute_amounts.set(
                item, mode == TAX_MODE_ABSOLUTE ? base_value : 0);
            const char *source = local_item ? "cell_item"
                : ((local_default != TAX_RATE_INHERIT ||
                    local_default_mode != TAX_MODE_INHERIT)
                    ? "cell_default"
                   : (country_raw != TAX_RATE_INHERIT ||
                      country_mode_raw != TAX_MODE_INHERIT
                      ? "country_item" : "country_default"));
            source_scopes.set(item, source);

            int32_t effective_value = base_value;
            if (mode == TAX_MODE_PERCENT_BP &&
                _modifier_runtime != nullptr) {
                const std::string stat_key = std::string("country.tax.") +
                    kind_key + "." + ids[static_cast<size_t>(item)] +
                    ".rate_bp";
                const int32_t stat_id =
                    modifier_api::stat_id_for_key(*_modifier_runtime, stat_key);
                if (stat_id >= 0) {
                    effective_value = static_cast<int32_t>(
                        std::clamp<int64_t>(std::lround(
                            modifier_api::effective_value(*_modifier_runtime,
                                ModifierApi::COUNTRY, stat_id, handle,
                                0, base_value)), TAX_RATE_MIN_BP,
                            TAX_RATE_MAX_BP));
                }
            }
            effective_rates.set(item, effective_value);
        }
        Dictionary result;
        PackedInt32Array country_base_percent, local_item_percent;
        PackedInt32Array final_base_percent, effective_percent;
        country_base_percent.resize(count);
        local_item_percent.resize(count);
        final_base_percent.resize(count);
        effective_percent.resize(count);
        for (int32_t item = 0; item < count; ++item) {
            const int32_t mode = assessment_modes[item];
            country_base_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? country_base_rates[item] / 100
                    : 0);
            local_item_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? local_item_rates[item] / 100
                    : 0);
            final_base_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? final_base_rates[item] / 100
                    : 0);
            effective_percent.set(
                item,
                mode == TAX_MODE_PERCENT_BP
                    ? effective_rates[item] / 100
                    : 0);
        }
        result["item_ids"] = item_ids;
        result["country_base_rates_basis_points"] = country_base_rates;
        result["local_item_rates_basis_points"] = local_item_rates;
        result["final_base_rates_basis_points"] = final_base_rates;
        result["effective_rates_basis_points"] = effective_rates;
        result["assessment_modes"] = assessment_modes;
        result["absolute_amounts"] = absolute_amounts;
        result["country_base_rates"] = country_base_percent;
        result["local_item_rates"] = local_item_percent;
        result["has_local_item"] = has_local_item;
        result["final_base_rates"] = final_base_percent;
        result["effective_rates"] = effective_percent;
        result["source_scopes"] = source_scopes;
        return result;
    };

    Dictionary out;
    out["ok"] = true;
    out["cell"] = cell;
    out["country_handle"] = static_cast<int64_t>(handle);
    out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
    out["country_name"] = String::utf8(
        _countries.display_name[static_cast<size_t>(slot)].c_str());
    out["policy_version"] = static_cast<int64_t>(_tax_policy_version);
    PackedInt32Array country_defaults_percent, local_defaults_percent;
    country_defaults_percent.resize(TAX_KIND_COUNT);
    local_defaults_percent.resize(TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
        country_defaults_percent.set(
            kind,
            country_default_modes[kind] == TAX_MODE_PERCENT_BP
                ? country_defaults[kind] / 100
                : 0);
        local_defaults_percent.set(
            kind,
            local_default_modes[kind] == TAX_MODE_PERCENT_BP
                ? local_defaults[kind] / 100
                : 0);
    }
    out["country_default_rates_basis_points"] = country_defaults;
    out["local_default_rates_basis_points"] = local_defaults;
    out["country_default_assessment_modes"] = country_default_modes;
    out["local_default_assessment_modes"] = local_default_modes;
    out["country_default_rates"] = country_defaults_percent;
    out["local_default_rates"] = local_defaults_percent;
    out["has_local_default"] = has_local_default;
    out["income"] = make_kind(TAX_INCOME, "income");
    out["consumption"] = make_kind(TAX_CONSUMPTION, "consumption");
    out["transaction"] = out["consumption"];
    out["business"] = make_kind(TAX_BUSINESS, "business");
    out["import"] = make_kind(TAX_IMPORT, "import");
    out["export"] = make_kind(TAX_EXPORT, "export");
    out["tariffs_active"] = false;
    return out;
}

Dictionary NativeCountryRuntime::research_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedInt32Array states;
    PackedInt64Array progress;
    states.resize(static_cast<int64_t>(_technology_ids.size()));
    progress.resize(static_cast<int64_t>(_technology_ids.size()));
    const size_t word_base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech) {
        const uint64_t bit = 1ULL << (tech % 64);
        int32_t state = 0;
        if ((_country_technologies[word_base + tech / 64] & bit) != 0) state = 5;
        else if ((_country_pending_technologies[word_base + tech / 64] & bit) != 0) state = 4;
        else if ((_country_discovered[word_base + tech / 64] & bit) != 0)
            state = prerequisites_met(slot, tech) ? 2 : 1;
        states.set(tech, state);
        progress.set(tech, progress_for(slot, tech));
    }
    PackedInt32Array queue_offsets;
    PackedInt32Array queue_technologies;
    queue_offsets.push_back(0);
    for (int32_t domain = 0; domain < 4; ++domain) {
        const size_t length_index = static_cast<size_t>(slot) * 4U + domain;
        const size_t queue_base = length_index * 8U;
        const int32_t length = _country_research_queue_lengths[length_index];
        for (int32_t position = 0; position < length; ++position) {
            const int32_t tech = _country_research_queues[queue_base + position];
            queue_technologies.push_back(tech);
            if (states[tech] < 4) states.set(tech, 3);
        }
        queue_offsets.push_back(queue_technologies.size());
    }
    PackedInt32Array weights;
    for (int32_t domain = 0; domain < 4; ++domain)
        weights.push_back(_country_research_weights_bp[static_cast<size_t>(slot) * 4U + domain]);
    const int64_t stock = _country_goods[
        static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(_technology_points_good_id)];
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["technology_states"] = states;
    out["technology_progress"] = progress;
    out["queue_offsets"] = queue_offsets;
    out["queue_technology_indices"] = queue_technologies;
    out["domain_weights_bp"] = weights;
    out["auto_purchase_enabled"] =
        _country_research_auto_purchase[static_cast<size_t>(slot)] != 0;
    out["daily_procurement_budget"] =
        _country_research_daily_budgets[static_cast<size_t>(slot)];
    out["technology_points_stock"] = stock;
    out["country_cash"] =
        slot < _countries.cash.size() ? _countries.cash[slot] : 0;
    out["deferred_unallocated_points"] =
        _country_research_deferred_points[static_cast<size_t>(slot)];
    out["purchased_total"] = _country_research_purchased_total[static_cast<size_t>(slot)];
    out["consumed_total"] = _country_research_consumed_total[static_cast<size_t>(slot)];
    out["progress_total"] = _country_research_progress_total[static_cast<size_t>(slot)];
    out["completed_total"] = _country_research_completed_total[static_cast<size_t>(slot)];
    out["last_research_day"] = _last_research_day;
    out["generation"] = static_cast<int64_t>(_generation);
    {
        // One-shot probe: proves the UI research path is reading the worker
        // replica (generation moves) rather than the frozen sync store.
        static int s_ui_left = 16;
        if (s_ui_left-- > 0) {
            int32_t owned = 0;
            int32_t pending = 0;
            int32_t queued = 0;
            int64_t nonzero_progress = 0;
            for (int32_t tech = 0; tech < states.size(); ++tech) {
                const int32_t state = states[tech];
                if (state >= 5) ++owned;
                else if (state == 4) ++pending;
                else if (state == 3) ++queued;
                if (progress[tech] != 0) ++nonzero_progress;
            }
            UtilityFunctions::print(vformat(
                "[tech-ui-diag/research] handle=%d gen=%d day=%d "
                "owned=%d pending=%d queued=%d progress_nonzero=%d stock=%d "
                "deferred=%d consumed=%d cash=%d budget=%d auto=%d",
                handle, static_cast<int64_t>(_generation), _last_research_day,
                owned, pending, queued, nonzero_progress, stock,
                _country_research_deferred_points[static_cast<size_t>(slot)],
                _country_research_consumed_total[static_cast<size_t>(slot)],
                slot < _countries.cash.size() ? _countries.cash[slot] : 0,
                _country_research_daily_budgets[static_cast<size_t>(slot)],
                _country_research_auto_purchase[static_cast<size_t>(slot)]));
        }
    }
    return out;
}

Dictionary NativeCountryRuntime::research_signal_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot))
        return fail("country_handle_invalid");
    PackedInt32Array signal_ids;
    PackedInt32Array counts;
    PackedInt64Array first_days;
    PackedInt64Array last_days;
    PackedInt32Array first_cells;
    if (slot >= 0 && slot < static_cast<int32_t>(_country_research_signal_evidence.size())) {
        const std::vector<SignalEvidence> &entries =
            _country_research_signal_evidence[static_cast<size_t>(slot)];
        signal_ids.resize(static_cast<int64_t>(entries.size()));
        counts.resize(static_cast<int64_t>(entries.size()));
        first_days.resize(static_cast<int64_t>(entries.size()));
        last_days.resize(static_cast<int64_t>(entries.size()));
        first_cells.resize(static_cast<int64_t>(entries.size()));
        for (size_t i = 0; i < entries.size(); ++i) {
            signal_ids.set(static_cast<int64_t>(i), entries[i].signal);
            counts.set(static_cast<int64_t>(i), entries[i].count);
            first_days.set(static_cast<int64_t>(i), entries[i].first_day);
            last_days.set(static_cast<int64_t>(i), entries[i].last_day);
            first_cells.set(static_cast<int64_t>(i), entries[i].first_cell);
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["signal_ids"] = signal_ids;
    out["counts"] = counts;
    out["first_days"] = first_days;
    out["last_days"] = last_days;
    out["first_cells"] = first_cells;
    return out;
}

bool NativeCountryRuntime::research_procurement_policy(int32_t country_slot, bool &enabled,
                                                       int64_t &cash_budget,
                                                       int64_t &remaining_points) const {
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_asset_snapshot() : nullptr;
    const auto &active = worker ? worker->country_active : _countries.active;
    const auto &_country_research_auto_purchase = worker ? worker->research_auto_purchase : this->_country_research_auto_purchase;
    const auto &_country_research_daily_budgets = worker ? worker->research_daily_budgets : this->_country_research_daily_budgets;
    const auto &_country_research_queues = worker ? worker->research_queues : this->_country_research_queues;
    const auto &_country_research_queue_lengths = worker ? worker->research_queue_lengths : this->_country_research_queue_lengths;
    const auto &_country_research_deferred_points = worker ? worker->research_deferred_points : this->_country_research_deferred_points;
    const auto &_country_goods = worker ? worker->country_goods : this->_country_goods;
    const size_t good_count = worker != nullptr
        ? static_cast<size_t>(worker->good_count) : _good_ids.size();
    const int32_t technology_count = worker != nullptr
        ? static_cast<int32_t>(worker->technology_count)
        : static_cast<int32_t>(_technology_ids.size());
    if (country_slot < 0 ||
        country_slot >= static_cast<int32_t>(active.size()) ||
        active[static_cast<size_t>(country_slot)] == 0) return false;
    const size_t slot = static_cast<size_t>(country_slot);
    if (slot >= _country_research_auto_purchase.size() ||
        slot >= _country_research_daily_budgets.size() ||
        slot >= _country_research_deferred_points.size() ||
        _technology_points_good_id < 0 ||
        static_cast<size_t>(_technology_points_good_id) >= good_count) {
        return false;
    }
    enabled = _country_research_auto_purchase[slot] != 0;
    cash_budget = _country_research_daily_budgets[slot];
    remaining_points = 0;
    for (int32_t domain = 0; domain < 4; ++domain) {
        const size_t length_index = slot * 4U + domain;
        if (length_index >= _country_research_queue_lengths.size()) break;
        const size_t queue_base = length_index * 8U;
        for (int32_t position = 0;
             position < _country_research_queue_lengths[length_index];
             ++position) {
            if (queue_base + static_cast<size_t>(position) >=
                _country_research_queues.size()) break;
            const int32_t tech = _country_research_queues[
                queue_base + static_cast<size_t>(position)];
            if (tech < 0 || tech >= technology_count ||
                tech >= static_cast<int32_t>(_technology_costs.size())) continue;
            const int64_t cost = worker
                ? country_effective_research_cost(
                    _technology_costs[static_cast<size_t>(tech)],
                    slot < worker->research_cost_factor.size()
                        ? worker->research_cost_factor[slot] : 1.0)
                : effective_research_cost(country_slot, tech);
            const int64_t progress = worker
                ? (slot * static_cast<size_t>(worker->technology_count) +
                       static_cast<size_t>(tech) < worker->research_progress.size()
                       ? worker->research_progress[
                             slot * static_cast<size_t>(worker->technology_count) +
                             static_cast<size_t>(tech)]
                       : 0)
                : progress_for(country_slot, tech);
            remaining_points += std::max<int64_t>(0, cost - progress);
        }
    }
    const size_t stock_index =
        slot * good_count + static_cast<size_t>(_technology_points_good_id);
    const int64_t stock = stock_index < _country_goods.size()
        ? _country_goods[stock_index] : 0;
    const int64_t unreserved = std::max<int64_t>(
        0, stock - _country_research_deferred_points[slot]);
    // Unreserved treasury stock is a real buyer gap of zero: government will
    // not purchase points it already holds. Starter grants must therefore not
    // cover later queued techs, or automatic investment never sees demand —
    // and epoch-frozen procurement must re-read this after stock is spent.
    remaining_points = std::max<int64_t>(0, remaining_points - unreserved);
    return true;
}
PackedInt32Array NativeCountryRuntime::cell_country_snapshot() const {
    // This plane is what MapData, vision and country borders read. Under worker
    // authority the sync store is frozen at its pre-handoff contents, so copying
    // it would publish a territory map missing every claim the worker has
    // committed since — and worse, overwrite the correct plane that the Host
    // read-view already patched into MapData. Pin the same committed snapshot
    // country_slot_for_cell() uses so every territory reader agrees.
    if (_simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) {
        const auto snapshot = _simulation_host->country_asset_snapshot();
        if (snapshot != nullptr &&
            snapshot->cell_country_slot.size() == _cell_country_slot.size()) {
            PackedInt32Array out;
            out.resize(static_cast<int64_t>(snapshot->cell_country_slot.size()));
            if (!snapshot->cell_country_slot.empty())
                std::memcpy(out.ptrw(), snapshot->cell_country_slot.data(),
                            snapshot->cell_country_slot.size() * sizeof(int32_t));
            return out;
        }
    }
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(_cell_country_slot.size()));
    if (!_cell_country_slot.empty()) std::memcpy(out.ptrw(), _cell_country_slot.data(), _cell_country_slot.size() * sizeof(int32_t));
    return out;
}
int32_t NativeCountryRuntime::country_slot_for_cell(int32_t cell) const {
    if (_simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) {
        const auto snapshot = _simulation_host->country_asset_snapshot();
        if (snapshot != nullptr) {
            if (cell < 0 ||
                static_cast<size_t>(cell) >= snapshot->cell_country_slot.size())
                return NEUTRAL_SLOT;
            return snapshot->cell_country_slot[static_cast<size_t>(cell)];
        }
    }
    return cell >= 0 && cell < _cell_count
        ? _cell_country_slot[static_cast<size_t>(cell)] : NEUTRAL_SLOT;
}

int64_t NativeCountryRuntime::country_handle_for_cell(int32_t cell) const {
    const int32_t slot = country_slot_for_cell(cell);
    return slot < 0 ? 0 : static_cast<int64_t>(make_handle(slot));
}

bool NativeCountryRuntime::valid_handle(int64_t handle) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(handle), slot);
}

int64_t NativeCountryRuntime::total_cash() const {
    if (_simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) {
        const auto snapshot = _simulation_host->country_economy_audit_snapshot();
        if (snapshot != nullptr) {
            int64_t total = 0;
            for (size_t i = 0; i < snapshot->country_cash.size(); ++i) {
                if (snapshot->country_active[i] == 0) continue;
                const int64_t cash = snapshot->country_cash[i];
                if (cash > 0 && total > INT64_MAX - cash) return INT64_MAX;
                total += cash;
            }
            return total;
        }
    }
    int64_t total = 0;
    for (size_t i = 0; i < _countries.cash.size(); ++i) {
        if (_countries.active[i] == 0) continue;
        if (_countries.cash[i] > 0 && total > std::numeric_limits<int64_t>::max() - _countries.cash[i])
            return std::numeric_limits<int64_t>::max();
        total += _countries.cash[i];
    }
    return total;
}

int64_t NativeCountryRuntime::cash_for_slot(int32_t country_slot) const {
    if (_simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) {
        const auto snapshot = _simulation_host->country_economy_audit_snapshot();
        if (snapshot) return country_slot >= 0 &&
            static_cast<size_t>(country_slot) < snapshot->country_cash.size() &&
            snapshot->country_active[country_slot] != 0
            ? snapshot->country_cash[country_slot] : 0;
    }
    return country_slot >= 0 &&
           country_slot < static_cast<int32_t>(_countries.active.size()) &&
           _countries.active[static_cast<size_t>(country_slot)] != 0
        ? _countries.cash[static_cast<size_t>(country_slot)] : 0;
}

int64_t NativeCountryRuntime::total_good(int32_t good_id) const {
    if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size())) return 0;
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_economy_audit_snapshot() : nullptr;
    const auto &_country_goods = worker ? worker->country_goods : this->_country_goods;
    int64_t total = 0;
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        if (_countries.active[slot] == 0) continue;
        const int64_t value = _country_goods[slot * _good_ids.size() + static_cast<size_t>(good_id)];
        if (value > 0 && total > std::numeric_limits<int64_t>::max() - value) return std::numeric_limits<int64_t>::max();
        total += value;
    }
    return total;
}

void NativeCountryRuntime::sample_economy_goods_audit(
        int64_t &country_goods_total, int64_t &research_consumed_total,
        int64_t &country_cash_total) const {
    country_goods_total = 0;
    research_consumed_total = 0;
    country_cash_total = 0;
    // Economy opening/VERIFY must pin sealed authority assets — never the
    // peer-wait plan preview that overlays uncommitted research spend.
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_economy_audit_snapshot() : nullptr;
    const size_t good_count = worker != nullptr
        ? static_cast<size_t>(worker->good_count)
        : _good_ids.size();
    const size_t country_count = worker != nullptr
        ? static_cast<size_t>(worker->country_count)
        : _countries.active.size();
    const auto &active = worker != nullptr ? worker->country_active
                                           : _countries.active;
    const auto &cash = worker != nullptr ? worker->country_cash
                                         : _countries.cash;
    const auto &goods = worker != nullptr ? worker->country_goods
                                          : _country_goods;
    const auto &consumed = worker != nullptr
        ? worker->research_consumed_total
        : _country_research_consumed_total;
    // Era advancement treasury sink is a goods sink of the same kind: it is
    // folded into the returned research_consumed_total so Economy VERIFY sees
    // one monotone "Country consumed goods" counter.
    const auto &treasury_consumed = worker != nullptr
        ? worker->treasury_goods_consumed_total
        : _country_treasury_goods_consumed_total;
    for (size_t slot = 0; slot < country_count; ++slot) {
        if (slot >= active.size() || active[slot] == 0) continue;
        if (slot < treasury_consumed.size()) {
            const int64_t value = treasury_consumed[slot];
            if (value > 0 &&
                research_consumed_total >
                    std::numeric_limits<int64_t>::max() - value)
                research_consumed_total = std::numeric_limits<int64_t>::max();
            else if (value > 0)
                research_consumed_total += value;
        }
        if (slot < cash.size()) {
            const int64_t value = cash[slot];
            if (value > 0 &&
                country_cash_total > std::numeric_limits<int64_t>::max() - value)
                country_cash_total = std::numeric_limits<int64_t>::max();
            else
                country_cash_total += value;
        }
        if (slot < consumed.size()) {
            const int64_t value = consumed[slot];
            if (value > 0 &&
                research_consumed_total >
                    std::numeric_limits<int64_t>::max() - value)
                research_consumed_total = std::numeric_limits<int64_t>::max();
            else
                research_consumed_total += value;
        }
        if (good_count == 0 || goods.size() < (slot + 1u) * good_count) continue;
        const size_t base = slot * good_count;
        for (size_t good = 0; good < good_count; ++good) {
            const int64_t value = goods[base + good];
            if (value > 0 &&
                country_goods_total >
                    std::numeric_limits<int64_t>::max() - value) {
                country_goods_total = std::numeric_limits<int64_t>::max();
                break;
            }
            country_goods_total += value;
        }
    }
}

int64_t NativeCountryRuntime::research_consumed_total() const {
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_economy_audit_snapshot() : nullptr;
    const auto &_country_research_consumed_total = worker ? worker->research_consumed_total : this->_country_research_consumed_total;
    int64_t total = 0;
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        if (_countries.active[slot] == 0 ||
            slot >= _country_research_consumed_total.size()) continue;
        const int64_t value = _country_research_consumed_total[slot];
        if (value > 0 && total > std::numeric_limits<int64_t>::max() - value)
            return std::numeric_limits<int64_t>::max();
        total += value;
    }
    // Include the transient era-advancement sink (see sample_economy_goods_audit).
    const int64_t treasury = treasury_goods_consumed_total();
    if (treasury > 0 && total > std::numeric_limits<int64_t>::max() - treasury)
        return std::numeric_limits<int64_t>::max();
    return total + std::max<int64_t>(0, treasury);
}

int64_t NativeCountryRuntime::treasury_goods_consumed_total() const {
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_economy_audit_snapshot() : nullptr;
    const auto &values = worker ? worker->treasury_goods_consumed_total
                                : _country_treasury_goods_consumed_total;
    const auto &active = worker ? worker->country_active : _countries.active;
    int64_t total = 0;
    for (size_t slot = 0; slot < values.size() && slot < active.size(); ++slot) {
        if (active[slot] == 0) continue;
        const int64_t value = values[slot];
        if (value <= 0) continue;
        if (total > std::numeric_limits<int64_t>::max() - value)
            return std::numeric_limits<int64_t>::max();
        total += value;
    }
    return total;
}

int64_t NativeCountryRuntime::good_for_slot(int32_t country_slot,
                                            int32_t good_id) const {
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_economy_audit_snapshot() : nullptr;
    const auto &active = worker ? worker->country_active : _countries.active;
    const auto &goods = worker ? worker->country_goods : _country_goods;
    const size_t good_count = worker ? static_cast<size_t>(worker->good_count)
                                     : _good_ids.size();
    if (country_slot < 0 || good_id < 0 ||
        static_cast<size_t>(country_slot) >= active.size() ||
        active[static_cast<size_t>(country_slot)] == 0 ||
        static_cast<size_t>(good_id) >= good_count) return 0;
    const size_t index = static_cast<size_t>(country_slot) * good_count +
        static_cast<size_t>(good_id);
    return index < goods.size() ? goods[index] : 0;
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
    if (repaired.research_daily_budgets.size() != country_count)
        repaired.research_daily_budgets.assign(country_count, 0);
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
    _countries.generation = repaired.country_generation;
    _countries.stable_id = repaired.country_stable_ids;
    _countries.display_name = repaired.country_display_names;
    _research_active_country_slots = repaired.research_active_country_slots;
    _countries.territory_count = repaired.territory_count;
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
    _country_research_daily_budgets = repaired.research_daily_budgets;
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
