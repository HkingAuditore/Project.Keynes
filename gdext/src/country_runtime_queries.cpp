#include "country_runtime.h"
#include "country_runtime_internal.h"
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
    out["capital_cell"] = static_cast<int64_t>(slot) <
            static_cast<int64_t>(_countries.capital_cell.size())
        ? _countries.capital_cell[static_cast<size_t>(slot)] : -1;
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
                                                       int64_t &remaining_points) const {
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_asset_snapshot() : nullptr;
    const auto &active = worker ? worker->country_active : _countries.active;
    const auto &_country_research_auto_purchase = worker ? worker->research_auto_purchase : this->_country_research_auto_purchase;
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
        slot >= _country_research_deferred_points.size() ||
        _technology_points_good_id < 0 ||
        static_cast<size_t>(_technology_points_good_id) >= good_count) {
        return false;
    }
    enabled = _country_research_auto_purchase[slot] != 0;
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

int32_t NativeCountryRuntime::capital_cell_for_slot(int32_t country_slot) const {
    // Capital is a political fact, not a territory claim. It is static between
    // commands and is copied into the worker snapshot at the same boundary as
    // the rest of the country record, so the committed sync store is the
    // authoritative read here.
    return country_slot >= 0 &&
           country_slot < static_cast<int32_t>(_countries.capital_cell.size())
        ? _countries.capital_cell[static_cast<size_t>(country_slot)] : -1;
}

} // namespace pk
