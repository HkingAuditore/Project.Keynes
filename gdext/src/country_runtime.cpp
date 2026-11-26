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
    _countries.capital_cell.push_back(-1);
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
    // Optional v16 addendum: one capital cell per country. Absent in legacy
    // fixtures; the bootstrap then falls back to each country's first territory
    // cell so the "capital cannot secede" rule still has a stable anchor.
    const std::vector<int32_t> capital_cells = packed_i32(packet, "capital_cells");
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
    const std::vector<uint8_t> research_auto_purchase =
        packed_u8(packet, "research_auto_purchase");

    _countries = {};
    _starting_country_slot = -1;
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
            (!capital_cells.empty() && capital_cells.size() != ids.size()) ||
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
            const int32_t capital = capital_cells.empty()
                ? territory_cells[static_cast<size_t>(territory_offsets[slot])]
                : capital_cells[slot];
            if (capital < 0 || capital >= _cell_count ||
                _cell_country_slot[static_cast<size_t>(capital)] != static_cast<int32_t>(slot))
                return fail("country_bootstrap_capital_invalid");
            _countries.capital_cell[slot] = capital;
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
    _starting_country_slot = -1;
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
