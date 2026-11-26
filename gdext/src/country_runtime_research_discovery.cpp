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

void NativeCountryRuntime::rebuild_discovery_dependents() {
    const int32_t technology_count =
        static_cast<int32_t>(_technology_ids.size());
    std::vector<std::vector<int32_t>> reverse(
        static_cast<size_t>(technology_count));
    auto add_edge = [&](int32_t source, int32_t target) {
        if (source < 0 || source >= technology_count || target < 0 ||
            target >= technology_count || source == target) return;
        reverse[static_cast<size_t>(source)].push_back(target);
    };
    for (int32_t target = 0; target < technology_count; ++target) {
        for (int32_t edge = _technology_prerequisite_offsets[
                 static_cast<size_t>(target)];
             edge < _technology_prerequisite_offsets[
                 static_cast<size_t>(target + 1)]; ++edge) {
            add_edge(_technology_prerequisites[static_cast<size_t>(edge)], target);
        }
        for (int32_t edge = _technology_milestone_offsets[
                 static_cast<size_t>(target)];
             edge < _technology_milestone_offsets[
                 static_cast<size_t>(target + 1)]; ++edge) {
            add_edge(_technology_milestone_candidates[static_cast<size_t>(edge)],
                     target);
        }
        for (int32_t op = _technology_reveal_condition_offsets[
                 static_cast<size_t>(target)];
             op < _technology_reveal_condition_offsets[
                 static_cast<size_t>(target + 1)]; ++op) {
            if (_technology_reveal_condition_ops[static_cast<size_t>(op)] == 1)
                add_edge(_technology_reveal_condition_refs[
                    static_cast<size_t>(op)], target);
        }
        if (target < static_cast<int32_t>(
                _technology_entry_milestone_indices.size())) {
            add_edge(_technology_entry_milestone_indices[
                static_cast<size_t>(target)], target);
        }
        if (target < static_cast<int32_t>(
                _technology_era_milestone_indices.size())) {
            add_edge(_technology_era_milestone_indices[
                static_cast<size_t>(target)], target);
        }
    }
    _technology_discovery_dependent_offsets.assign(
        static_cast<size_t>(technology_count + 1), 0);
    _technology_discovery_dependents.clear();
    for (int32_t source = 0; source < technology_count; ++source) {
        std::vector<int32_t> &bucket = reverse[static_cast<size_t>(source)];
        std::sort(bucket.begin(), bucket.end());
        bucket.erase(std::unique(bucket.begin(), bucket.end()), bucket.end());
        _technology_discovery_dependents.insert(
            _technology_discovery_dependents.end(), bucket.begin(), bucket.end());
        _technology_discovery_dependent_offsets[
            static_cast<size_t>(source + 1)] =
            static_cast<int32_t>(_technology_discovery_dependents.size());
    }
}

void NativeCountryRuntime::refresh_discovery_for_completed(
        int32_t slot, const std::vector<int32_t> &completed) {
    if (completed.empty()) return;
    std::vector<int32_t> frontier;
    for (const int32_t technology : completed) {
        if (technology < 0 || technology >= static_cast<int32_t>(_technology_ids.size()))
            continue;
        frontier.push_back(technology);
        if (technology + 1 >= static_cast<int32_t>(
                _technology_discovery_dependent_offsets.size())) continue;
        const int32_t begin = _technology_discovery_dependent_offsets[
            static_cast<size_t>(technology)];
        const int32_t end = _technology_discovery_dependent_offsets[
            static_cast<size_t>(technology + 1)];
        frontier.insert(frontier.end(),
            _technology_discovery_dependents.begin() + begin,
            _technology_discovery_dependents.begin() + end);
    }
    std::sort(frontier.begin(), frontier.end());
    frontier.erase(std::unique(frontier.begin(), frontier.end()), frontier.end());
    for (const int32_t technology : frontier)
        refresh_discovery_for_technology(slot, technology);

    if (_full_diagnostics) {
        const size_t word_base = static_cast<size_t>(slot) *
            static_cast<size_t>(_technology_words);
        std::vector<uint64_t> incremental(
            _country_discovered.begin() + static_cast<ptrdiff_t>(word_base),
            _country_discovered.begin() + static_cast<ptrdiff_t>(
                word_base + static_cast<size_t>(_technology_words)));
        refresh_discovery(slot);
        if (!std::equal(incremental.begin(), incremental.end(),
                _country_discovered.begin() + static_cast<ptrdiff_t>(word_base))) {
            ++_research_discovery_frontier_mismatches;
        }
    }
}
bool NativeCountryRuntime::has_technology(int32_t country_slot, int32_t technology_id) const {
    if (technology_id < 0 ||
        technology_id >= static_cast<int32_t>(_technology_ids.size())) return false;
    // Country ACTIVE freezes the sync store. Economy live gates
    // (building_available / cell_has_technology) and UI query paths must pin
    // the same immutable worker commit that copy_economy_snapshot already uses;
    // otherwise buildings unlock on the research panel while production still
    // reads a pre-handoff technology bitset.
    if (_simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) {
        const auto snapshot = _simulation_host->country_asset_snapshot();
        if (snapshot != nullptr) {
            const uint32_t words = snapshot->technology_words;
            if (country_slot < 0 || words == 0) return false;
            const size_t index = static_cast<size_t>(country_slot) * words +
                static_cast<size_t>(technology_id / 64);
            return index < snapshot->country_technologies.size() &&
                (snapshot->country_technologies[index] &
                 (uint64_t{1} << (technology_id % 64))) != 0;
        }
    }
    if (country_slot < 0 ||
        country_slot >= static_cast<int32_t>(_countries.active.size())) return false;
    return (_country_technologies[static_cast<size_t>(country_slot) *
                _technology_words + technology_id / 64] &
            (1ULL << (technology_id % 64))) != 0;
}

bool NativeCountryRuntime::has_research_signal(int32_t country_slot,
                                                int32_t signal_id) const {
    if (country_slot < 0 || country_slot >= static_cast<int32_t>(_countries.active.size()) ||
        signal_id < 0 || signal_id >= static_cast<int32_t>(_research_signal_ids.size()) ||
        _countries.active[static_cast<size_t>(country_slot)] == 0) return false;
    const size_t base = static_cast<size_t>(country_slot) * _research_signal_words;
    return (_country_research_signals[base + static_cast<size_t>(signal_id / 64)] &
            (1ULL << (signal_id % 64))) != 0;
}

bool NativeCountryRuntime::prerequisites_met(const std::vector<uint64_t> &completed,
                                              int32_t slot, int32_t technology) const {
    if (slot < 0 || technology < 0 ||
        technology >= static_cast<int32_t>(_technology_ids.size())) return false;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    const auto has = [&](int32_t tech) {
        return (completed[base + tech / 64] & (1ULL << (tech % 64))) != 0;
    };
    if (!era_entry_met(completed, slot, technology)) return false;
    const int32_t milestone_begin = _technology_milestone_offsets[static_cast<size_t>(technology)];
    const int32_t milestone_end = _technology_milestone_offsets[static_cast<size_t>(technology + 1)];
    if (milestone_end > milestone_begin) {
        int32_t count = 0;
        for (int32_t edge = milestone_begin; edge < milestone_end; ++edge)
            if (has(_technology_milestone_candidates[static_cast<size_t>(edge)])) ++count;
        return count >= _technology_milestone_required_counts[static_cast<size_t>(technology)];
    }
    const int32_t begin = _technology_prerequisite_offsets[static_cast<size_t>(technology)];
    const int32_t end = _technology_prerequisite_offsets[static_cast<size_t>(technology + 1)];
    for (int32_t edge = begin; edge < end; ++edge)
        if (!has(_technology_prerequisites[static_cast<size_t>(edge)])) return false;
    return true;
}

bool NativeCountryRuntime::era_entry_met(const std::vector<uint64_t> &completed,
                                          int32_t slot, int32_t technology) const {
    if (slot < 0 || technology < 0 ||
        technology >= static_cast<int32_t>(_technology_entry_milestone_indices.size())) return false;
    const int32_t entry = _technology_entry_milestone_indices[static_cast<size_t>(technology)];
    // -1: era 0/1 node, or a retired era token. With the "next era only" gate the
    // compiler fills this for every node of era >= 2 (previous-era milestone), so
    // an ordinary node can also be era-locked; era 0/1 nodes stay ungated.
    if (entry < 0) return true;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    const size_t word = base + static_cast<size_t>(entry / 64);
    return word < completed.size() &&
           (completed[word] & (uint64_t{1} << (entry % 64))) != 0;
}

bool NativeCountryRuntime::prerequisites_met(int32_t slot, int32_t technology) const {
    return research_condition_met(slot, technology);
}

bool NativeCountryRuntime::signal_present(const std::vector<uint64_t> &signals,
                                          int32_t slot, int32_t signal) const {
    if (slot < 0 || signal < 0 || signal >= static_cast<int32_t>(_research_signal_ids.size()) ||
        _research_signal_words <= 0) return false;
    const size_t index = static_cast<size_t>(slot) * _research_signal_words + signal / 64;
    return index < signals.size() && (signals[index] & (uint64_t{1} << (signal % 64))) != 0;
}

NativeCountryRuntime::SignalEvidence *NativeCountryRuntime::find_signal_evidence(
        std::vector<SignalEvidence> &entries, int32_t signal) {
    const auto it = std::lower_bound(entries.begin(), entries.end(), signal,
        [](const SignalEvidence &entry, int32_t needle) { return entry.signal < needle; });
    return it != entries.end() && it->signal == signal ? &*it : nullptr;
}

const NativeCountryRuntime::SignalEvidence *NativeCountryRuntime::find_signal_evidence(
        const std::vector<SignalEvidence> &entries, int32_t signal) {
    const auto it = std::lower_bound(entries.begin(), entries.end(), signal,
        [](const SignalEvidence &entry, int32_t needle) { return entry.signal < needle; });
    return it != entries.end() && it->signal == signal ? &*it : nullptr;
}

int32_t NativeCountryRuntime::signal_count(int32_t slot, int32_t signal) const {
    return signal_count(_country_research_signal_evidence, slot, signal);
}

int32_t NativeCountryRuntime::signal_count(
        const std::vector<std::vector<SignalEvidence>> &evidence,
        int32_t slot, int32_t signal) const {
    if (slot < 0 || slot >= static_cast<int32_t>(evidence.size())) return 0;
    const SignalEvidence *entry = find_signal_evidence(
        evidence[static_cast<size_t>(slot)], signal);
    return entry == nullptr ? 0 : entry->count;
}

bool NativeCountryRuntime::research_condition_met(const std::vector<uint64_t> &completed,
                                                   const std::vector<uint64_t> &signals,
                                                   const std::vector<std::vector<SignalEvidence>> &evidence,
                                                   int32_t slot, int32_t technology) const {
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_ids.size()) ||
        _technology_research_condition_offsets.empty()) return false;
    const int32_t begin = _technology_research_condition_offsets[static_cast<size_t>(technology)];
    const int32_t end = _technology_research_condition_offsets[static_cast<size_t>(technology + 1)];
    if (begin == end) return true;
    std::array<uint8_t, 128> stack{};
    int32_t depth = 0;
    const size_t tech_base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t cursor = begin; cursor < end; ++cursor) {
        const int32_t op = _technology_research_condition_ops[static_cast<size_t>(cursor)];
        const int32_t ref = _technology_research_condition_refs[static_cast<size_t>(cursor)];
        const int64_t value = _technology_research_condition_values[static_cast<size_t>(cursor)];
        if (op == 1) {
            if (depth >= static_cast<int32_t>(stack.size()) || ref < 0 ||
                ref >= static_cast<int32_t>(_technology_ids.size())) return false;
            stack[depth++] = (completed[tech_base + ref / 64] & (uint64_t{1} << (ref % 64))) != 0;
        } else if (op == 2) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_present(signals, slot, ref);
        } else if (op == 3) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_count(evidence, slot, ref) >= value;
        } else if (op == 13) {
            if (depth < 1) return false;
            stack[static_cast<size_t>(depth - 1)] =
                stack[static_cast<size_t>(depth - 1)] == 0 ? 1 : 0;
        } else if (op == 10 || op == 11 || op == 12) {
            if (ref <= 0 || ref > depth) return false;
            int32_t truth_count = 0;
            for (int32_t i = depth - ref; i < depth; ++i) truth_count += stack[static_cast<size_t>(i)] != 0;
            depth -= ref;
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = op == 10 ? truth_count == ref :
                (op == 11 ? truth_count > 0 : truth_count >= value);
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0] != 0;
}

bool NativeCountryRuntime::research_condition_met(int32_t slot, int32_t technology) const {
    return research_condition_met(_country_technologies, _country_research_signals,
                                  _country_research_signal_evidence,
                                  slot, technology);
}

bool NativeCountryRuntime::reveal_condition_met(int32_t slot, int32_t technology) const {
    if (slot < 0 || technology < 0 ||
        technology >= static_cast<int32_t>(_technology_ids.size()) ||
        _technology_reveal_condition_offsets.empty()) return false;
    const int32_t begin = _technology_reveal_condition_offsets[static_cast<size_t>(technology)];
    const int32_t end = _technology_reveal_condition_offsets[static_cast<size_t>(technology + 1)];
    if (begin == end) return true;
    std::array<uint8_t, 128> stack{};
    int32_t depth = 0;
    const size_t tech_base = static_cast<size_t>(slot) * _technology_words;
    for (int32_t cursor = begin; cursor < end; ++cursor) {
        const int32_t op = _technology_reveal_condition_ops[static_cast<size_t>(cursor)];
        const int32_t ref = _technology_reveal_condition_refs[static_cast<size_t>(cursor)];
        const int64_t value = _technology_reveal_condition_values[static_cast<size_t>(cursor)];
        if (op == 1) {
            if (depth >= static_cast<int32_t>(stack.size()) || ref < 0 ||
                ref >= static_cast<int32_t>(_technology_ids.size())) return false;
            stack[depth++] = (_country_technologies[tech_base + ref / 64] &
                              (uint64_t{1} << (ref % 64))) != 0;
        } else if (op == 2) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_present(_country_research_signals, slot, ref);
        } else if (op == 3) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = signal_count(slot, ref) >= value;
        } else if (op == 13) {
            if (depth < 1) return false;
            stack[static_cast<size_t>(depth - 1)] =
                stack[static_cast<size_t>(depth - 1)] == 0 ? 1 : 0;
        } else if (op == 10 || op == 11 || op == 12) {
            if (ref <= 0 || ref > depth) return false;
            int32_t truth_count = 0;
            for (int32_t i = depth - ref; i < depth; ++i)
                truth_count += stack[static_cast<size_t>(i)] != 0;
            depth -= ref;
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[depth++] = op == 10 ? truth_count == ref :
                (op == 11 ? truth_count > 0 : truth_count >= value);
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0] != 0;
}

void NativeCountryRuntime::refresh_discovery_for_technology(int32_t slot, int32_t tech) {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        tech < 0 || tech >= static_cast<int32_t>(_technology_ids.size())) return;
    ++_research_discovery_checks;
    const size_t base = static_cast<size_t>(slot) * _technology_words;
    const uint64_t bit = uint64_t{1} << (tech % 64);
    if ((_country_technologies[base + tech / 64] & bit) != 0) {
        _country_discovered[base + tech / 64] |= bit;
        return;
    }
    const int32_t reveal_begin = _technology_reveal_condition_offsets[static_cast<size_t>(tech)];
    const int32_t reveal_end = _technology_reveal_condition_offsets[static_cast<size_t>(tech + 1)];
    if (reveal_end > reveal_begin && !reveal_condition_met(slot, tech)) return;
    const int32_t begin = _technology_prerequisite_offsets[static_cast<size_t>(tech)];
    const int32_t end = _technology_prerequisite_offsets[static_cast<size_t>(tech + 1)];
    const int32_t milestone_begin = _technology_milestone_offsets[static_cast<size_t>(tech)];
    const int32_t milestone_end = _technology_milestone_offsets[static_cast<size_t>(tech + 1)];
    bool reveal = false;
    if (milestone_end > milestone_begin) {
        for (int32_t edge = milestone_begin; edge < milestone_end && !reveal; ++edge) {
            const int32_t candidate = _technology_milestone_candidates[static_cast<size_t>(edge)];
            reveal = (_country_technologies[base + candidate / 64] &
                      (uint64_t{1} << (candidate % 64))) != 0;
        }
    } else {
        for (int32_t edge = begin; edge < end && !reveal; ++edge) {
            const int32_t prerequisite = _technology_prerequisites[static_cast<size_t>(edge)];
            reveal = (_country_technologies[base + prerequisite / 64] &
                      (uint64_t{1} << (prerequisite % 64))) != 0;
        }
    }
    if (reveal || (reveal_end > reveal_begin && reveal_condition_met(slot, tech)))
        _country_discovered[base + tech / 64] |= bit;
}

void NativeCountryRuntime::refresh_discovery_for_signal(int32_t slot, int32_t signal) {
    if (signal < 0 || signal + 1 >= static_cast<int32_t>(_technology_reveal_signal_offsets.size()))
        return;
    const int32_t begin = _technology_reveal_signal_offsets[static_cast<size_t>(signal)];
    const int32_t end = _technology_reveal_signal_offsets[static_cast<size_t>(signal + 1)];
    for (int32_t cursor = begin; cursor < end; ++cursor)
        refresh_discovery_for_technology(slot,
            _technology_reveal_signal_technologies[static_cast<size_t>(cursor)]);
}

void NativeCountryRuntime::refresh_discovery(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech) {
        refresh_discovery_for_technology(slot, tech);
    }
}

} // namespace pk
