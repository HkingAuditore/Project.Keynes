#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "effect_runtime.h"
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

void NativeCountryRuntime::initialize_country_research(int32_t slot) {
    const size_t countries = static_cast<size_t>(slot + 1);
    _country_discovered.resize(countries * _technology_words, 0);
    _country_pending_technologies.resize(countries * _technology_words, 0);
    _country_research_progress.resize(countries);
    _country_research_queues.resize(countries * 4U * 8U, -1);
    _country_research_queue_lengths.resize(countries * 4U, 0);
    _country_research_weights_bp.resize(countries * 4U, 2500);
    _country_research_auto_purchase.resize(countries, 1);
    _country_research_deferred_points.resize(countries, 0);
    _country_research_purchased_total.resize(countries, 0);
    _country_research_consumed_total.resize(countries, 0);
    _country_treasury_goods_consumed_total.resize(countries, 0);
    _country_research_progress_total.resize(countries, 0);
    _country_research_completed_total.resize(countries, 0);
    _country_research_signals.resize(countries * _research_signal_words, 0);
    _country_research_signal_cells.resize(countries);
    _country_research_signal_evidence.resize(countries);
    _research_active_country_membership.resize(countries, 0);
    _research_modifier_cache.resize(countries);
}

void NativeCountryRuntime::rebuild_pending_activation_index() const {
    _pending_activation_indices.assign(_countries.active.size(), {});
    _pending_activation_count = 0;
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        if (_countries.active[static_cast<size_t>(slot)] == 0) continue;
        std::vector<int32_t> &pending =
            _pending_activation_indices[static_cast<size_t>(slot)];
        for (int32_t technology = 0;
             technology < static_cast<int32_t>(_technology_ids.size());
             ++technology) {
            const size_t word_index = static_cast<size_t>(slot) *
                _technology_words + technology / 64;
            const uint64_t bit = 1ULL << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) != 0)
                pending.push_back(technology);
        }
        _pending_activation_count += static_cast<int64_t>(pending.size());
    }
    _pending_activation_index_dirty = false;
    ++_research_queue_rebuilds;
}

bool NativeCountryRuntime::validate_pending_activation_index() const {
    if (_pending_activation_index_dirty ||
        _pending_activation_indices.size() != _countries.active.size() ||
        _technology_words <= 0 ||
        _country_pending_technologies.size() !=
            _countries.active.size() * static_cast<size_t>(_technology_words)) {
        return false;
    }
    int64_t counted = 0;
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        const auto &pending = _pending_activation_indices[static_cast<size_t>(slot)];
        if (_countries.active[static_cast<size_t>(slot)] == 0) {
            if (!pending.empty()) return false;
            continue;
        }
        int32_t previous = -1;
        for (const int32_t technology : pending) {
            if (technology <= previous || technology < 0 ||
                technology >= static_cast<int32_t>(_technology_ids.size())) {
                return false;
            }
            const size_t word_index = static_cast<size_t>(slot) *
                static_cast<size_t>(_technology_words) +
                static_cast<size_t>(technology / 64);
            const uint64_t bit = uint64_t{1} << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) == 0) return false;
            previous = technology;
        }
        int64_t bit_count = 0;
        const size_t word_base = static_cast<size_t>(slot) *
            static_cast<size_t>(_technology_words);
        for (int32_t word = 0; word < _technology_words; ++word) {
            uint64_t bits = _country_pending_technologies[word_base +
                static_cast<size_t>(word)];
            while (bits != 0) {
                bits &= bits - 1;
                ++bit_count;
            }
        }
        if (bit_count != static_cast<int64_t>(pending.size())) return false;
        counted += bit_count;
    }
    return counted == _pending_activation_count;
}

void NativeCountryRuntime::insert_pending_activation(
        int32_t slot, int32_t technology) {
    if (_pending_activation_index_dirty || slot < 0 || technology < 0 ||
        slot >= static_cast<int32_t>(_pending_activation_indices.size()))
        return;
    std::vector<int32_t> &pending =
        _pending_activation_indices[static_cast<size_t>(slot)];
    const auto position = std::lower_bound(
        pending.begin(), pending.end(), technology);
    if (position != pending.end() && *position == technology) return;
    pending.insert(position, technology);
    ++_pending_activation_count;
}

void NativeCountryRuntime::erase_pending_activation(
        int32_t slot, int32_t technology) {
    if (_pending_activation_index_dirty || slot < 0 || technology < 0 ||
        slot >= static_cast<int32_t>(_pending_activation_indices.size()))
        return;
    std::vector<int32_t> &pending =
        _pending_activation_indices[static_cast<size_t>(slot)];
    const auto position = std::lower_bound(
        pending.begin(), pending.end(), technology);
    if (position == pending.end() || *position != technology) return;
    pending.erase(position);
    --_pending_activation_count;
}

bool NativeCountryRuntime::country_has_research_work(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
        _countries.active[static_cast<size_t>(slot)] == 0) {
        return false;
    }
    const size_t word_base = static_cast<size_t>(slot) *
        static_cast<size_t>(_technology_words);
    for (int32_t word = 0; word < _technology_words; ++word) {
        if (_country_pending_technologies[word_base + static_cast<size_t>(word)] != 0)
            return true;
    }
    const size_t queue_base = static_cast<size_t>(slot) * 4U;
    for (int32_t domain = 0; domain < 4; ++domain) {
        if (_country_research_queue_lengths[queue_base +
                static_cast<size_t>(domain)] != 0) {
            return true;
        }
    }
    return false;
}

void NativeCountryRuntime::rebuild_research_active_index() {
    _research_active_country_slots.clear();
    _research_active_country_membership.assign(_countries.active.size(), 0);
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot) {
        if (!country_has_research_work(slot)) continue;
        _research_active_country_slots.push_back(slot);
        _research_active_country_membership[static_cast<size_t>(slot)] = 1;
    }
}

int64_t NativeCountryRuntime::progress_for(int32_t slot, int32_t technology) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_country_research_progress.size())) return 0;
    const auto &entries = _country_research_progress[static_cast<size_t>(slot)];
    const auto it = std::lower_bound(entries.begin(), entries.end(), technology,
        [](const std::pair<int32_t, int64_t> &entry, int32_t value) {
            return entry.first < value;
        });
    return it != entries.end() && it->first == technology ? it->second : 0;
}

void NativeCountryRuntime::set_progress(int32_t slot, int32_t technology, int64_t value) {
    auto &entries = _country_research_progress[static_cast<size_t>(slot)];
    const auto it = std::lower_bound(entries.begin(), entries.end(), technology,
        [](const std::pair<int32_t, int64_t> &entry, int32_t needle) {
            return entry.first < needle;
        });
    if (it != entries.end() && it->first == technology) {
        if (value <= 0) entries.erase(it);
        else it->second = value;
    } else if (value > 0) {
        entries.insert(it, {technology, value});
    }
}

int64_t NativeCountryRuntime::effective_research_cost(
        int32_t slot, int32_t technology,
        const CountryPeerContext *peer_context) const {
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_costs.size()))
        return 1;
    ensure_research_modifier_cache(slot, peer_context);
    const double cost_factor = slot >= 0 &&
        slot < static_cast<int32_t>(_research_modifier_cache.size())
        ? _research_modifier_cache[static_cast<size_t>(slot)].cost_factor : 1.0;
    return country_effective_research_cost(
        _technology_costs[static_cast<size_t>(technology)], cost_factor);
}

void NativeCountryRuntime::ensure_research_modifier_cache(
        int32_t slot, const CountryPeerContext *peer_context) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return;
    if (_research_modifier_cache.size() < _countries.active.size())
        _research_modifier_cache.resize(_countries.active.size());
    ResearchModifierCache &cache =
        _research_modifier_cache[static_cast<size_t>(slot)];
    const uint64_t handle = make_handle(slot);
    const uint64_t version = peer_context != nullptr
        ? peer_context->modifier_generation
        : (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime)
            ? modifier_api::domain_snapshot_version(*_modifier_runtime, ModifierApi::COUNTRY)
            : 0);
    if (cache.country_handle == handle && cache.modifier_version == version) {
        ++_research_modifier_cache_hits;
        return;
    }

    const Clock::time_point started = Clock::now();
    cache.country_handle = handle;
    cache.modifier_version = version;
    cache.cost_factor = 1.0;
    cache.efficiency = {{1.0, 1.0, 1.0, 1.0}};
    if (peer_context != nullptr) {
        const size_t slot_index = static_cast<size_t>(slot);
        if (slot_index < peer_context->research_cost_factor.size())
            cache.cost_factor = peer_context->research_cost_factor[slot_index];
        const size_t efficiency_base = slot_index * 4u;
        if (efficiency_base + 4u <= peer_context->research_efficiency.size()) {
            for (int32_t domain = 0; domain < 4; ++domain)
                cache.efficiency[static_cast<size_t>(domain)] =
                    peer_context->research_efficiency[efficiency_base +
                        static_cast<size_t>(domain)];
        }
        _research_modifier_ms += elapsed_ms(started);
        return;
    }
    if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime)) {
        static const char *EFFICIENCY_STATS[4] = {
            "country.research.agriculture_efficiency",
            "country.research.engineering_efficiency",
            "country.research.science_efficiency",
            "country.research.society_efficiency",
        };
        cache.cost_factor = modifier_api::effective_value(*_modifier_runtime,
            ModifierApi::COUNTRY, "country.research.cost_factor",
            handle, 0, 1.0);
        ++_research_modifier_queries;
        for (int32_t domain = 0; domain < 4; ++domain) {
            cache.efficiency[static_cast<size_t>(domain)] =
                modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::COUNTRY, EFFICIENCY_STATS[domain],
                    handle, 0, 1.0);
            ++_research_modifier_queries;
        }
    }
    _research_modifier_ms += elapsed_ms(started);
}

int64_t NativeCountryRuntime::max_storable_research_progress(
        int32_t technology) const {
    if (technology < 0 ||
        technology >= static_cast<int32_t>(_technology_costs.size())) {
        return 1;
    }
    const int64_t base_cost = std::max<int64_t>(
        1, _technology_costs[static_cast<size_t>(technology)]);
    // Keep in sync with ModifierCatalog TECHNOLOGY_STATS for
    // country.research.cost_factor when the ModifierRuntime is not configured.
    constexpr double kResearchCostFactorFallbackMax = 4.0;
    double max_factor = kResearchCostFactorFallbackMax;
    if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime)) {
        max_factor = modifier_api::stat_clamp_max(*_modifier_runtime,
            "country.research.cost_factor", kResearchCostFactorFallbackMax);
    }
    if (!(max_factor > 0.0) || !std::isfinite(max_factor)) {
        max_factor = kResearchCostFactorFallbackMax;
    }
    return std::max<int64_t>(
        base_cost,
        static_cast<int64_t>(std::llround(
            static_cast<double>(base_cost) * max_factor)));
}

bool NativeCountryRuntime::finalize_research_head_if_complete(
        int32_t slot, int32_t domain, int64_t day_index,
        bool use_pending_queue, CountryPeerContext *peer_context) {
    if (slot < 0 || domain < 0 || domain >= 4) return false;
    const size_t length_index = static_cast<size_t>(slot) * 4U +
        static_cast<size_t>(domain);
    uint8_t &length = _country_research_queue_lengths[length_index];
    if (length == 0) return false;
    const size_t queue_base = length_index * 8U;
    const int32_t technology = _country_research_queues[queue_base];
    if (technology < 0 || has_technology(slot, technology) ||
        !prerequisites_met(slot, technology) ||
        progress_for(slot, technology) < effective_research_cost(
            slot, technology, peer_context))
        return false;

    const size_t word_index = static_cast<size_t>(slot) * _technology_words +
        static_cast<size_t>(technology / 64);
    const uint64_t bit = uint64_t{1} << (technology % 64);
    _country_pending_technologies[word_index] |= bit;
    if (use_pending_queue) insert_pending_activation(slot, technology);
    const std::string &modifier_key =
        _technology_modifier_definition_keys[static_cast<size_t>(technology)];
    if (!modifier_key.empty() && peer_context != nullptr)
        ensure_technology_effect_instance(
            slot, technology, day_index, *peer_context);
    ++_country_research_completed_total[static_cast<size_t>(slot)];
    for (int32_t i = 1; i < length; ++i)
        _country_research_queues[queue_base + static_cast<size_t>(i - 1)] =
            _country_research_queues[queue_base + static_cast<size_t>(i)];
    _country_research_queues[queue_base + static_cast<size_t>(--length)] = -1;
    return true;
}
bool NativeCountryRuntime::ensure_technology_effect_instance(
        int32_t slot, int32_t technology, int64_t day_index,
        CountryPeerContext &peer_context) {
    if (technology < 0 || technology >= static_cast<int32_t>(_technology_ids.size()))
        return false;
    const CountryPeerTechnologyState *state = find_peer_technology_state(
        peer_context, slot, technology);
    const CountryPeerIntentCode opcode = state != nullptr &&
        state->has(COUNTRY_PEER_EFFECT_EXISTS)
        ? CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT
        : CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT;
    const CountryPeerIntent intent = make_peer_intent(
        peer_context, opcode, slot, technology, day_index);
    const CountryPeerResult result = apply_peer_intent(peer_context, intent);
    return result.ok();
}

bool NativeCountryRuntime::ack_chain_due(
        int64_t day_index, const CountryPeerContext *peer_context) const {
    if (!_peer_pending_intents.empty()) return true;
    if (peer_context != nullptr && peer_context->day == day_index)
        return peer_context->effect_should_run != 0 ||
            peer_context->modifier_should_run != 0;
    if (_effect_runtime_enabled && _effect_runtime != nullptr &&
        _effect_runtime->should_run(day_index))
        return true;
    return _modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime) &&
        modifier_api::should_run(*_modifier_runtime, day_index);
}

int32_t NativeCountryRuntime::run_research_day(
        int64_t day_index, const CountryPeerContext *peer_context,
        CountryPeerContext *out_peer_context) {
    if (_technology_points_good_id < 0) return 0;
    CountryPeerContext owned_peer_context;
    if (peer_context == nullptr) {
        std::string peer_error;
        if (!capture_peer_context(day_index, _reference_continuation_index,
                                  owned_peer_context, peer_error)) {
            if (!_pod_execution && !peer_error.empty())
                _report["country_peer_context_error"] = String(peer_error.c_str());
            if (out_peer_context != nullptr) *out_peer_context = owned_peer_context;
            return 0;
        }
        peer_context = &owned_peer_context;
    }
    if (peer_context->day != day_index ||
        peer_context->session_epoch != _session_epoch ||
        peer_context->country_generation != _generation) {
        if (!_pod_execution)
            _report["country_peer_context_error"] =
                "country_peer_context_identity_stale";
        if (out_peer_context != nullptr) *out_peer_context = *peer_context;
        return 0;
    }
    // The input capture remains immutable. Immediate synchronous adapter
    // results are applied to this local copy so a same-day continuation sees
    // exactly the facts produced by the intent it just submitted.
    CountryPeerContext working_peer_context = *peer_context;
    CountryPeerContext *working_context = &working_peer_context;
    _peer_protocol_fault_reason.clear();
    _research_activation_ms = 0.0;
    _research_allocation_ms = 0.0;
    _research_effect_ack_ms = 0.0;
    _research_discovery_ms = 0.0;
    _research_modifier_ms = 0.0;
    _research_countries_scanned = 0;
    _research_active_countries = 0;
    _research_pending_checks = 0;
    _research_discovery_checks = 0;
    _research_modifier_queries = 0;
    _research_modifier_cache_hits = 0;
    _research_remainder_iterations = 0;
    if (!retry_peer_rejections(day_index, *working_context)) {
        _peer_protocol_fault_reason = "country_peer_retry_protocol_fault";
        if (out_peer_context != nullptr)
            *out_peer_context = working_peer_context;
        return 0;
    }
    // Research allocation is once per day, but pending technologies may be
    // ACKed by Effect/Modifier later in the same day. Keep the activation
    // pass live for same-day continuations instead of making the completed
    // node wait for a new research command or the next calendar day.
    const bool research_due = day_index > _last_research_day;
    bool use_pending_queue = _pending_queue_enabled;
    bool pending_queue_fallback = false;
    if (use_pending_queue && _pending_activation_index_dirty)
        rebuild_pending_activation_index();
    if (_research_active_country_membership.size() != _countries.active.size())
        rebuild_research_active_index();
    // The parity check is transient diagnostics only.  It walks the compact
    // pending bitset, never the research conditions or full technology graph,
    // and therefore does not affect the LIGHT production hot path.
    if (use_pending_queue && _full_diagnostics &&
        !validate_pending_activation_index()) {
        use_pending_queue = false;
        // The configured feature flag remains enabled.  A parity failure is
        // a one-day safety fallback: the authoritative pending bitset is still
        // consumed by the deterministic full scan, then the compact index is
        // rebuilt so the next research day can automatically recover.
        pending_queue_fallback = true;
        _research_queue_fallback_reason = "pending_queue_mismatch";
        _pending_activation_index_dirty = true;
    }
    if (pending_queue_fallback) ++_research_full_scan_fallbacks;
    int32_t changed = 0;
    _research_active_country_scratch.clear();
    _research_active_country_scratch.swap(_research_active_country_slots);
    for (const int32_t slot : _research_active_country_scratch) {
        if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size()) ||
            _countries.active[static_cast<size_t>(slot)] == 0) continue;
        ++_research_countries_scanned;
        ++_research_active_countries;
        _research_active_country_membership[static_cast<size_t>(slot)] = 0;
        auto retain_if_active = [&]() {
            if (!country_has_research_work(slot)) return;
            _research_active_country_slots.push_back(slot);
            _research_active_country_membership[static_cast<size_t>(slot)] = 1;
        };
        const Clock::time_point activation_started = Clock::now();
        const size_t word_base = static_cast<size_t>(slot) * _technology_words;
        bool activated = false;
        std::vector<int32_t> &activated_pending =
            _research_activated_pending_scratch;
        std::vector<int32_t> &activated_technologies =
            _research_activated_technologies_scratch;
        activated_pending.clear();
        activated_technologies.clear();
        const int32_t candidate_count = use_pending_queue
            ? static_cast<int32_t>(
                _pending_activation_indices[static_cast<size_t>(slot)].size())
            : static_cast<int32_t>(_technology_ids.size());
        for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
            ++_research_pending_checks;
            const int32_t technology = use_pending_queue
                ? _pending_activation_indices[static_cast<size_t>(slot)][
                    static_cast<size_t>(candidate)]
                : candidate;
            const size_t word_index = word_base + technology / 64;
            const uint64_t bit = 1ULL << (technology % 64);
            if ((_country_pending_technologies[word_index] & bit) == 0) continue;
            if (peer_rejection_blocks_activation(slot, technology, day_index))
                continue;
            const std::string &technology_modifier_key =
                _technology_modifier_definition_keys[static_cast<size_t>(technology)];
            bool modifier_ready = technology_modifier_key.empty();
            const uint64_t handle = make_handle(slot);
            if (working_context->effect_enabled != 0 &&
                !technology_modifier_key.empty()) {
                const Clock::time_point effect_started = Clock::now();
                ensure_technology_effect_instance(
                    slot, technology, day_index, *working_context);
                const CountryPeerTechnologyState *peer_state =
                    find_peer_technology_state(*working_context, slot, technology);
                modifier_ready = peer_state != nullptr &&
                    (peer_state->has(COUNTRY_PEER_EFFECT_FIRE_ACKED) ||
                     peer_state->has(COUNTRY_PEER_MODIFIER_APPLIED));
                _research_effect_ack_ms += elapsed_ms(effect_started);
            }
            if (!modifier_ready &&
                working_context->effect_enabled == 0 &&
                working_context->modifier_enabled != 0 &&
                !technology_modifier_key.empty()) {
                const Clock::time_point effect_started = Clock::now();
                // Legacy configurations without EffectRuntime retain their
                // direct idempotent path. Once EffectRuntime is authoritative,
                // activation must wait for its cross-domain ACK chain.
                const CountryPeerIntent intent = make_peer_intent(
                    *working_context,
                    CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER,
                    slot, technology, day_index);
                const CountryPeerResult result = apply_peer_intent(
                    *working_context, intent);
                modifier_ready = result.ok() &&
                    result.has(COUNTRY_PEER_MODIFIER_APPLIED);
                _research_effect_ack_ms += elapsed_ms(effect_started);
            }
            if (!modifier_ready) continue;
            const int32_t visual_era_before = visual_era_index_for_slot(slot);
            _country_technologies[word_index] |= bit;
            _country_pending_technologies[word_index] &= ~bit;
            const int32_t visual_era_after = visual_era_index_for_slot(slot);
            if (visual_era_after != visual_era_before) {
                if (_current_visual_era.size() < _countries.active.size())
                    _current_visual_era.resize(_countries.active.size(), -1);
                _current_visual_era[static_cast<size_t>(slot)] = visual_era_after;
                _visual_era_dirty_slots.push_back(slot);
                ++_visual_era_generation;
            }
            if (use_pending_queue)
                activated_pending.push_back(technology);
            activated_technologies.push_back(technology);
            // Era rewards are emitted only after the technology's permanent
            // Effect has ACKed and the completed bit becomes authoritative.
            // Research progress reaching its cost never enters this hook.
            if (working_context->effect_enabled != 0) {
                const CountryPeerIntent reward_intent = make_peer_intent(
                    *working_context, CountryPeerIntentCode::NOTIFY_ERA_REWARD,
                    slot, technology, day_index);
                const CountryPeerResult reward_result = apply_peer_intent(
                    *working_context, reward_intent);
                if (!_pod_execution && !reward_result.ok())
                    _report["era_reward_error"] = String(
                        reward_result.reason.data());
                if (working_context->economy_enabled != 0) {
                    const CountryPeerIntent economy_intent = make_peer_intent(
                        *working_context,
                        CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE,
                        slot, technology, day_index);
                    apply_peer_intent(*working_context, economy_intent);
                }
            }
            activated = true;
        }
        for (const int32_t technology : activated_pending)
            erase_pending_activation(slot, technology);
        if (activated) {
            const Clock::time_point discovery_started = Clock::now();
            refresh_discovery_for_completed(slot, activated_technologies);
            _research_discovery_ms += elapsed_ms(discovery_started);
            _country_research_deferred_points[static_cast<size_t>(slot)] = 0;
            ++_countries.state_version[static_cast<size_t>(slot)];
            ++changed;
        }

        // Completion is a state transition, not a technology-points
        // purchase. If the final fractional unit was consumed on the
        // previous day, the treasury may now be empty even though the queue
        // head is complete. Finalize such heads before the stock early exit.
        for (int32_t domain = 0; domain < 4; ++domain) {
            while (finalize_research_head_if_complete(
                    slot, domain, day_index, use_pending_queue,
                    working_context)) {
                ++_countries.state_version[static_cast<size_t>(slot)];
                ++changed;
            }
        }
        _research_activation_ms += elapsed_ms(activation_started);

        int64_t &stock = _country_goods[
            static_cast<size_t>(slot) * _good_ids.size() +
            static_cast<size_t>(_technology_points_good_id)];
        if (!research_due) {
            retain_if_active();
            continue;
        }
        const int64_t prior_deferred = std::min(
            _country_research_deferred_points[static_cast<size_t>(slot)], stock);
        const int64_t available = stock - prior_deferred;
        if (available <= 0) {
            retain_if_active();
            continue;
        }

        const Clock::time_point allocation_started = Clock::now();

        std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> weights{{0, 0, 0, 0}};
        for (int32_t domain = 0; domain < 4; ++domain)
            weights[static_cast<size_t>(domain)] = _country_research_weights_bp[
                static_cast<size_t>(slot) * 4U + static_cast<size_t>(domain)];
        uint64_t remainder_iterations = 0;
        CountryResearchAllocation allocation =
            country_allocate_research_points(available, weights,
                                              &remainder_iterations);
        std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> queue_lengths{{0, 0, 0, 0}};
        for (int32_t domain = 0; domain < 4; ++domain)
            queue_lengths[static_cast<size_t>(domain)] =
                _country_research_queue_lengths[
                    static_cast<size_t>(slot) * 4U + static_cast<size_t>(domain)];
        country_redirect_idle_research_shares(allocation, weights, queue_lengths);
        _research_remainder_iterations += remainder_iterations;

        int64_t consumed = 0;
        int64_t newly_deferred = 0;
        for (int32_t domain = 0; domain < 4; ++domain) {
            int64_t domain_points = allocation.shares[static_cast<size_t>(domain)];
            const size_t length_index = static_cast<size_t>(slot) * 4U +
                static_cast<size_t>(domain);
            const uint8_t initial_length =
                _country_research_queue_lengths[length_index];
            while (domain_points > 0) {
                uint8_t &length = _country_research_queue_lengths[length_index];
                if (length == 0) break;
                const size_t queue_base = (static_cast<size_t>(slot) * 4U +
                    static_cast<size_t>(domain)) * 8U;
                const int32_t technology = _country_research_queues[queue_base];
                const size_t tech_word = word_base + static_cast<size_t>(technology / 64);
                const uint64_t tech_bit = 1ULL << (technology % 64);
                const bool settled = technology < 0 ||
                    has_technology(slot, technology) ||
                    (_country_pending_technologies[tech_word] & tech_bit) != 0;
                if (settled) {
                    for (int32_t i = 1; i < length; ++i)
                        _country_research_queues[queue_base + static_cast<size_t>(i - 1)] =
                            _country_research_queues[queue_base + static_cast<size_t>(i)];
                    _country_research_queues[queue_base + static_cast<size_t>(--length)] = -1;
                    continue;
                }
                if (!prerequisites_met(slot, technology)) break;
                const int64_t progress = progress_for(slot, technology);
                ensure_research_modifier_cache(slot, working_context);
                const double efficiency =
                    _research_modifier_cache[static_cast<size_t>(slot)]
                        .efficiency[static_cast<size_t>(domain)];
                const double cost_factor = _research_modifier_cache[
                    static_cast<size_t>(slot)].cost_factor;
                const CountryResearchProgress step =
                    country_advance_research_progress(
                        progress,
                        _technology_costs[static_cast<size_t>(technology)],
                        cost_factor, efficiency, domain_points);
                if (!step.valid || step.spend <= 0) break;
                set_progress(slot, technology, progress + step.progress_gain);
                domain_points -= step.spend;
                consumed += step.spend;
                _country_research_progress_total[static_cast<size_t>(slot)] +=
                    step.progress_gain;
                if (step.completed) {
                    _country_pending_technologies[word_base + technology / 64] |=
                        1ULL << (technology % 64);
                    if (use_pending_queue)
                        insert_pending_activation(slot, technology);
                    // Register the Effect instance on the completion day so the
                    // next morning's Effect job (priority 85) can fire before
                    // Country (255) checks ACK. Waiting until the activation
                    // loop would miss that slot and leave the node pending.
                    // Content-only leftover nodes have empty modifier keys; their
                    // unlocks are catalog tags, not Effect ACK. Instantiating the
                    // adopted-only recipe left native_country_ack_pending forever.
                    const std::string &completed_modifier_key =
                        _technology_modifier_definition_keys[static_cast<size_t>(technology)];
                    if (!completed_modifier_key.empty())
                        ensure_technology_effect_instance(
                            slot, technology, day_index, *working_context);
                    ++_country_research_completed_total[static_cast<size_t>(slot)];
                    for (int32_t i = 1; i < length; ++i)
                        _country_research_queues[queue_base + static_cast<size_t>(i - 1)] =
                            _country_research_queues[queue_base + static_cast<size_t>(i)];
                    _country_research_queues[queue_base + static_cast<size_t>(--length)] = -1;
                } else {
                    break;
                }
            }
            // Empty-domain shares were already moved onto queued domains.
            // A domain that had queue work but could not finish it (blocked
            // head or leftover after completion) still parks its remainder.
            if (initial_length > 0)
                newly_deferred += domain_points;
        }
        if (consumed > 0) {
            stock -= consumed;
            _country_research_consumed_total[static_cast<size_t>(slot)] += consumed;
            ++_countries.state_version[static_cast<size_t>(slot)];
            if (!activated) ++changed;
        }
        _country_research_deferred_points[static_cast<size_t>(slot)] =
            std::min(stock, prior_deferred + newly_deferred);
        _research_allocation_ms += elapsed_ms(allocation_started);
        retain_if_active();
    }
    if (pending_queue_fallback) {
        // Full-scan mutations intentionally bypass incremental queue updates.
        // Rebuild from the authoritative pending bits before publishing this
        // day so the queue is valid and deterministic on the following day.
        _pending_activation_index_dirty = true;
        rebuild_pending_activation_index();
    } else if (use_pending_queue &&
               _research_queue_fallback_reason == "pending_queue_mismatch") {
        // A clean parity check after a previous one-day fallback clears the
        // transient diagnostic marker without changing authority or hashes.
        _research_queue_fallback_reason.clear();
    }
    if (research_due) _last_research_day = day_index;
    if (changed > 0) {
        ++_research_generation;
        ++_generation;
    }
    if (out_peer_context != nullptr)
        *out_peer_context = std::move(working_peer_context);
    return changed;
}
int32_t NativeCountryRuntime::research_signal_evidence_count(
        int32_t country_slot, int32_t signal_id) const {
    return signal_count(country_slot, signal_id);
}

void NativeCountryRuntime::set_era_reward_reference_pod(
        int64_t plan_id, int64_t offer_generation,
        int32_t milestone_technology, int32_t status) {
    const bool changed = _era_reward_reference.plan_id != plan_id ||
        _era_reward_reference.offer_generation != offer_generation ||
        _era_reward_reference.milestone_technology != milestone_technology ||
        _era_reward_reference.status != status;
    _era_reward_reference.plan_id = plan_id;
    _era_reward_reference.offer_generation = offer_generation;
    _era_reward_reference.milestone_technology = milestone_technology;
    _era_reward_reference.status = status;
    _state_hash_cache_valid = false;
    if (changed) record_direct_reference_frame("era_reward_reference");
}

} // namespace pk
