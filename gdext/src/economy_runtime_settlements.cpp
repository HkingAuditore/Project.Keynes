#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <chrono>
#include <numeric>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

int64_t NativeEconomyRuntime::population_total_for_cell(int32_t cell) const {
    if (cell < 0 ||
        cell >= static_cast<int32_t>(_committed_cells.size()))
        return 0;
    return std::max<int64_t>(0, _committed_cells[cell].population);
}

uint8_t NativeEconomyRuntime::prosperity_tier_for_population(
        int64_t population, uint8_t current) const {
    if (_prosperity_thresholds.empty()) return 0;
    int32_t tier = std::min<int32_t>(
        current, static_cast<int32_t>(_prosperity_thresholds.size()) - 1);
    while (tier + 1 < static_cast<int32_t>(_prosperity_thresholds.size()) &&
           population >= _prosperity_thresholds[tier + 1])
        ++tier;
    while (tier > 0) {
        const int64_t downgrade = (_prosperity_thresholds[tier] *
            _settlement_downgrade_bp + 9999) / 10000;
        if (population >= downgrade) break;
        --tier;
    }
    return static_cast<uint8_t>(tier);
}

std::string NativeEconomyRuntime::settlement_name_for_cell(int32_t cell) const {
    if (cell < 0 || cell >= _cell_count ||
        cell >= static_cast<int32_t>(_settlements.name_active.size()) ||
        _settlements.name_active[cell] == 0) return {};
    const int32_t p = _settlements.prefix[cell];
    const int32_t r = _settlements.root[cell];
    const int32_t s = _settlements.suffix[cell];
    if (r < 0) {
        if (p < 0 ||
            p >= static_cast<int32_t>(_settlement_full_name_text.size()))
            return {};
        std::string value = _settlement_full_name_text[p];
        if (_settlements.disambiguator[cell] > 0)
            value += "\xE8\xB7\xAF" + std::to_string(
                _settlements.disambiguator[cell] + 1);
        return value;
    }
    if (p < 0 || p >= static_cast<int32_t>(_settlement_prefix_text.size()) ||
        r < 0 || r >= static_cast<int32_t>(_settlement_root_text.size()) ||
        s < 0 || s >= static_cast<int32_t>(_settlement_suffix_text.size()))
        return {};
    std::string value = _settlement_prefix_text[p] +
        _settlement_root_text[r] + _settlement_suffix_text[s];
    if (_settlements.disambiguator[cell] > 0)
        value += "\xE8\xB7\xAF" + std::to_string(_settlements.disambiguator[cell] + 1);
    return value;
}

void NativeEconomyRuntime::assign_settlement_name(int32_t cell) {
    if (cell < 0 || cell >= _cell_count ||
        _settlements.name_active[cell] != 0) return;
    const uint64_t full_count = _settlement_full_name_text.size();
    const uint64_t pc = _settlement_prefix_text.size();
    const uint64_t rc = _settlement_root_text.size();
    const uint64_t sc = _settlement_suffix_text.size();
    const uint64_t component_count = pc * rc * sc;
    const uint64_t combinations = full_count + component_count;
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(cell));
    hash = trace_hash_mix(hash, _settlements.name_roll_generation[cell]);
    for (unsigned char ch : _settlement_name_pack_id)
        hash = trace_hash_mix(hash, ch);
    const auto weighted_pick = [&](const std::vector<int32_t> &weights,
                                   uint64_t salt) {
        int64_t total = 0;
        for (int32_t weight : weights) total += weight;
        int64_t roll = static_cast<int64_t>(
            trace_hash_mix(hash, salt) % static_cast<uint64_t>(total));
        for (int32_t i = 0; i < static_cast<int32_t>(weights.size()); ++i) {
            if (roll < weights[i]) return i;
            roll -= weights[i];
        }
        return static_cast<int32_t>(weights.size()) - 1;
    };
    const bool choose_full = full_count > 0 &&
        (component_count == 0 ||
         static_cast<int32_t>(trace_hash_mix(hash, 0x4d4f4445ULL) & 0xffffULL) <
            _settlement_full_name_share_q16);
    int32_t p = choose_full
        ? weighted_pick(_settlement_full_name_weights, 0x46554c4cULL)
        : weighted_pick(_settlement_prefix_weights, 0x50524546ULL);
    int32_t r = choose_full ? -1 :
        weighted_pick(_settlement_root_weights, 0x524f4f54ULL);
    int32_t s = choose_full ? -1 :
        weighted_pick(_settlement_suffix_weights, 0x53554646ULL);
    uint64_t flat = choose_full ? static_cast<uint64_t>(p) :
        full_count + (static_cast<uint64_t>(p) * rc +
            static_cast<uint64_t>(r)) * sc + static_cast<uint64_t>(s);
    uint64_t step = (trace_hash_mix(hash, 0x53544550ULL) | 1ULL) % combinations;
    if (step == 0) step = 1;
    while (std::gcd(step, combinations) != 1) {
        step = (step + 2) % combinations;
        if (step == 0) step = 1;
    }
    uint32_t disambiguator = 0;
    std::string name;
    for (uint64_t probe = 0; probe < combinations; ++probe) {
        const uint64_t candidate = (flat + probe * step) % combinations;
        if (candidate < full_count) {
            p = static_cast<int32_t>(candidate);
            r = -1;
            s = -1;
            name = _settlement_full_name_text[p];
        } else {
            const uint64_t component = candidate - full_count;
            p = static_cast<int32_t>(component / (rc * sc));
            const uint64_t tail = component % (rc * sc);
            r = static_cast<int32_t>(tail / sc);
            s = static_cast<int32_t>(tail % sc);
            name = _settlement_prefix_text[p] + _settlement_root_text[r] +
                _settlement_suffix_text[s];
        }
        if (_settlements.active_names.find(name) ==
            _settlements.active_names.end()) {
            _settlement_name_collision_probes += static_cast<int64_t>(probe);
            break;
        }
        name.clear();
    }
    if (name.empty()) {
        std::string base;
        if (flat < full_count) {
            p = static_cast<int32_t>(flat);
            r = -1;
            s = -1;
            base = _settlement_full_name_text[p];
        } else {
            const uint64_t component = flat - full_count;
            p = static_cast<int32_t>(component / (rc * sc));
            const uint64_t tail = component % (rc * sc);
            r = static_cast<int32_t>(tail / sc);
            s = static_cast<int32_t>(tail % sc);
            base = _settlement_prefix_text[p] +
                _settlement_root_text[r] + _settlement_suffix_text[s];
        }
        do {
            ++disambiguator;
            name = base + "\xE8\xB7\xAF" + std::to_string(disambiguator + 1);
        } while (_settlements.active_names.find(name) !=
                 _settlements.active_names.end());
    }
    _settlements.prefix[cell] = p;
    _settlements.root[cell] = r;
    _settlements.suffix[cell] = s;
    _settlements.disambiguator[cell] = disambiguator;
    _settlements.name_active[cell] = 1;
    _settlements.active_names.emplace(name, cell);
    ++_settlement_names_assigned;
}

void NativeEconomyRuntime::release_settlement_name(int32_t cell) {
    if (cell < 0 || cell >= _cell_count ||
        _settlements.name_active[cell] == 0) return;
    _settlements.active_names.erase(settlement_name_for_cell(cell));
    _settlements.name_active[cell] = 0;
    _settlements.prefix[cell] = -1;
    _settlements.root[cell] = -1;
    _settlements.suffix[cell] = -1;
    _settlements.disambiguator[cell] = 0;
    ++_settlements.name_roll_generation[cell];
    ++_settlement_names_released;
}

void NativeEconomyRuntime::initialize_settlements_from_population() {
    _settlements.clear(_cell_count);
    std::vector<int32_t> cells;
    cells.reserve(_cell_count);
    for (int32_t cell = 0; cell < _cell_count; ++cell) cells.push_back(cell);
    for (int32_t cell : cells) {
        const uint8_t tier = prosperity_tier_for_population(
            population_total_for_cell(cell), 0);
        _settlements.tier[cell] = tier;
        if (tier >= _settlement_named_tier) assign_settlement_name(cell);
    }
    _settlement_names_assigned = 0;
    _settlement_name_collision_probes = 0;
    _settlements.revision = 1;
}

void NativeEconomyRuntime::update_settlements_for_changed_cells() {
    const auto started = Clock::now();
    std::sort(_population_changed_cells.begin(), _population_changed_cells.end());
    _population_changed_cells.erase(std::unique(
        _population_changed_cells.begin(), _population_changed_cells.end()),
        _population_changed_cells.end());
    SettlementRevision revision;
    for (int32_t cell : _population_changed_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        const uint8_t before = _settlements.tier[cell];
        const uint8_t after = prosperity_tier_for_population(
            population_total_for_cell(cell), before);
        if (after == before) continue;
        _settlements.tier[cell] = after;
        ++_settlements.prosperity_generation[cell];
        if (after > before) ++_prosperity_promotions;
        else ++_prosperity_demotions;
        if (before < _settlement_named_tier &&
            after >= _settlement_named_tier)
            assign_settlement_name(cell);
        else if (before >= _settlement_named_tier &&
                 after < _settlement_named_tier &&
                 _settlements.name_forced[cell] == 0)
            release_settlement_name(cell);
        if (after > before) {
            if (_family_cell_offsets.size() == static_cast<size_t>(_cell_count) + 1) {
                for (int32_t cursor = _family_cell_offsets[cell];
                     cursor < _family_cell_offsets[cell + 1]; ++cursor) {
                    const int32_t family = _family_cell_indices[
                        static_cast<size_t>(cursor)];
                    fire_family_event_once_effect(family,
                        "family.effect.city_founder");
                }
            }
        }
        revision.changes.push_back({
            cell, after, _settlements.name_active[cell]});
    }
    _prosperity_changed_cells += static_cast<int64_t>(revision.changes.size());
    if (!revision.changes.empty()) {
        revision.revision = ++_settlements.revision;
        _settlements.revisions.push_back(std::move(revision));
        while (_settlements.revisions.size() > 8)
            _settlements.revisions.pop_front();
        size_t entries = 0;
        for (const auto &item : _settlements.revisions)
            entries += item.changes.size();
        while (!_settlements.revisions.empty() &&
               entries > static_cast<size_t>(std::max(1, _cell_count * 2))) {
            entries -= _settlements.revisions.front().changes.size();
            _settlements.revisions.pop_front();
        }
    }
    _prosperity_update_ms += elapsed_ms(started);
}

void NativeEconomyRuntime::append_settlement_fields(
        Dictionary &out, int32_t cell) const {
    if (cell < 0 || cell >= _cell_count ||
        cell >= static_cast<int32_t>(_settlements.tier.size())) return;
    const int32_t tier = _settlements.tier[cell];
    out["prosperity_tier"] = tier;
    out["prosperity_id"] = from_utf8(_prosperity_ids[tier]);
    out["prosperity_name"] = from_utf8(_prosperity_names[tier]);
    out["prosperity_generation"] = static_cast<int64_t>(
        _settlements.prosperity_generation[cell]);
    out["settlement_name_active"] =
        _settlements.name_active[cell] != 0;
    out["settlement_name_forced"] =
        _settlements.name_forced[cell] != 0;
    out["settlement_name"] = from_utf8(settlement_name_for_cell(cell));
    out["name_roll_generation"] = static_cast<int64_t>(
        _settlements.name_roll_generation[cell]);
    out["settlement_revision"] = _settlements.revision;
}

Dictionary NativeEconomyRuntime::settlement_rows(
        const std::vector<SettlementChange> &changes, bool full_snapshot) const {
    Dictionary out;
    PackedInt32Array cells;
    PackedByteArray tiers;
    PackedByteArray active;
    PackedStringArray names;
    PackedStringArray pack_ids;
    PackedStringArray prefix_ids;
    PackedStringArray root_ids;
    PackedStringArray suffix_ids;
    PackedInt32Array disambiguators;
    for (const SettlementChange &change : changes) {
        if (change.cell < 0 || change.cell >= _cell_count) continue;
        cells.push_back(change.cell);
        tiers.push_back(_settlements.tier[change.cell]);
        active.push_back(_settlements.name_active[change.cell]);
        names.push_back(from_utf8(settlement_name_for_cell(change.cell)));
        const bool named = _settlements.name_active[change.cell] != 0;
        const bool full_name = named &&
            _settlements.root[change.cell] < 0;
        pack_ids.push_back(named
            ? from_utf8(_settlement_name_pack_id) : String());
        prefix_ids.push_back(named
            ? from_utf8((full_name ? _settlement_full_name_ids[
                _settlements.prefix[change.cell]] : _settlement_prefix_ids[
                _settlements.prefix[change.cell]])) : String());
        root_ids.push_back(named && !full_name
            ? from_utf8(_settlement_root_ids[
                _settlements.root[change.cell]]) : String());
        suffix_ids.push_back(named && !full_name
            ? from_utf8(_settlement_suffix_ids[
                _settlements.suffix[change.cell]]) : String());
        disambiguators.push_back(named
            ? static_cast<int32_t>(_settlements.disambiguator[change.cell])
            : 0);
    }
    out["ok"] = true;
    out["revision"] = _settlements.revision;
    out["full_snapshot"] = full_snapshot;
    out["cell_indices"] = cells;
    out["prosperity_tiers"] = tiers;
    out["name_active"] = active;
    out["settlement_names"] = names;
    out["naming_pack_ids"] = pack_ids;
    out["prefix_ids"] = prefix_ids;
    out["root_ids"] = root_ids;
    out["suffix_ids"] = suffix_ids;
    out["disambiguators"] = disambiguators;
    return out;
}

} // namespace pk
