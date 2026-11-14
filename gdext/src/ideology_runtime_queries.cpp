#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>


namespace pk {

using namespace godot;

Dictionary NativeIdeologyRuntime::reconcile_effects_for_test(int64_t handle) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr)
        return fail("ideology_effect_runtime_unavailable");
    CountryState *country = country_state_for(static_cast<uint64_t>(handle), false);
    if (country == nullptr) return fail("ideology_country_unknown");
    const uint64_t publishes_before = _metric_publishes;
    const uint64_t skipped_before = _metric_publishes_skipped;
    reconcile_country_effect_activations(*country,
        std::max<int64_t>(0, _last_day));
    int64_t instances = 0;
    for (const IdeaState &state : country->ideas)
        instances += static_cast<int64_t>(state.effect_instances.size());
    Dictionary out;
    out["ok"] = true;
    // Deltas, not totals: a caller that reconciles twice compares these.
    out["metric_publishes"] = static_cast<int64_t>(_metric_publishes - publishes_before);
    out["metric_publishes_skipped"] =
        static_cast<int64_t>(_metric_publishes_skipped - skipped_before);
    out["instances"] = instances;
    out["last_error"] = String(_last_error.c_str());
    return out;
}







Dictionary NativeIdeologyRuntime::apply_self_pod_snapshot_for_test(int64_t generation) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    // Business-only schema tests must not inherit a frozen worker factor table
    // from an earlier fixture in the same runtime.
    _worker_opinion_inputs = RuntimeIdeologyOpinionSnapshot{};
    _worker_opinion_inputs_valid = false;
    // Mirrors what the worker would publish for the CURRENT state, so applying
    // it must be a no-op for the instance set. That is the P1-B contract and the
    // only way to exercise it without a real worker (a headless fixture never
    // earns the IDEOLOGY grant -- see ideology_effect_worker_forward_test.gd).
    RuntimeIdeologyPodSnapshot snapshot;
    if (!export_pod_business_snapshot(snapshot))
        return fail("ideology_runtime_unconfigured");
    // The hook's whole point is to control the generation it applies, so it
    // overrides whatever the export used (the internal cursor).
    snapshot.generation =
        static_cast<uint64_t>(std::max<int64_t>(1, generation));
    int64_t instances_before = 0;
    for (const CountryState &country : _countries)
        for (const IdeaState &state : country.ideas)
            instances_before += static_cast<int64_t>(state.effect_instances.size());
    const uint64_t publishes_before = _metric_publishes;
    std::string error;
    const bool ok = apply_pod_snapshot(snapshot, error);
    int64_t instances_after = 0;
    for (const CountryState &country : _countries)
        for (const IdeaState &state : country.ideas)
            instances_after += static_cast<int64_t>(state.effect_instances.size());
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    out["instances_before"] = instances_before;
    out["instances_after"] = instances_after;
    out["refresh_pending"] = _instance_refresh_pending;
    out["refresh_dirty"] = _instance_refresh_dirty;
    // apply_pod_snapshot must not reconcile: any publish here means the inline
    // full pass came back.
    out["metric_publishes"] =
        static_cast<int64_t>(_metric_publishes - publishes_before);
    return out;
}


Dictionary NativeIdeologyRuntime::effect_instance_report(int64_t handle) const {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const CountryState *country = country_state_for(static_cast<uint64_t>(handle));
    if (country == nullptr) return fail("ideology_country_unknown");
    PackedInt64Array idea_ids, idea_levels, instance_ids, generations,
        program_hashes, target_handles;
    PackedInt32Array target_generations, target_domains;
    PackedInt32Array magnitude_scales;
    PackedByteArray present;
    std::unordered_map<uint64_t, int32_t> domain_by_program;
    for (const IdeaState &state : country->ideas) {
        collect_idea_program_domains(*country, state, domain_by_program);
        for (const IdeaState::EffectInstanceRef &ref : state.effect_instances) {
            idea_ids.append(state.ideology_id);
            idea_levels.append(state.level);
            instance_ids.append(ref.instance_id);
            generations.append(static_cast<int64_t>(ref.generation));
            program_hashes.append(static_cast<int64_t>(ref.program_hash));
            target_handles.append(static_cast<int64_t>(ref.target_handle));
            target_generations.append(static_cast<int32_t>(ref.target_generation));
            // -1 = "this ref could not be labelled", which a reader MUST treat
            // as "do not draw", not as "domain zero". The distinction matters:
            // target_handle is a cell index for domains 2/5 and a country handle
            // otherwise, so guessing wrong paints an unrelated hex.
            const auto found = domain_by_program.find(ref.program_hash);
            target_domains.append(found == domain_by_program.end()
                ? -1 : found->second);
            magnitude_scales.append(ref.magnitude_scale_q16);
            // Deliberately NOT authority-aware: this column is the *ownership*
            // bit ("did the main thread own this instance, or was it handed to
            // the worker"), the same signal family_branch_effects.effect_present
            // carries. Routing it through the worker snapshot would make both
            // authorities report 1 and destroy the only way a reroute can be
            // told apart from a drop.
            present.append(_effect_runtime != nullptr &&
                _effect_runtime->has_instance_pod(
                    ref.instance_id, ref.generation) ? 1 : 0);
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["count"] = static_cast<int64_t>(instance_ids.size());
    out["idea_ids"] = idea_ids;
    out["idea_levels"] = idea_levels;
    out["instance_ids"] = instance_ids;
    out["generations"] = generations;
    out["program_hashes"] = program_hashes;
    out["target_handles"] = target_handles;
    out["target_generations"] = target_generations;
    out["target_domains"] = target_domains;
    out["magnitude_scales"] = magnitude_scales;
    out["present"] = present;
    return out;
}

Dictionary NativeIdeologyRuntime::effect_target_report(int64_t handle) const {
    const Dictionary instances = effect_instance_report(handle);
    if (!bool(instances.get("ok", false))) return instances;
    PackedInt64Array idea_ids = instances["idea_ids"];
    PackedInt64Array idea_levels = instances["idea_levels"];
    PackedInt64Array program_hashes = instances["program_hashes"];
    PackedInt64Array target_handles = instances["target_handles"];
    PackedInt32Array target_domains = instances["target_domains"];
    PackedByteArray backends;
    backends.resize(idea_ids.size());
    backends.fill(0);
    // Derived rows only while the front they built is the one serving readers.
    const DerivedCellFront *front = _modifier_runtime == nullptr ? nullptr
        : modifier_api::derived_cell_front(*_modifier_runtime);
    if (front != nullptr && front->generation == _derived_installed_generation) {
        for (const DerivedProgramContribution &row : _derived_installed_contributions) {
            if (row.source_country != static_cast<uint64_t>(handle)) continue;
            for (const int32_t cell : row.cells) {
                idea_ids.append(row.ideology_id);
                idea_levels.append(row.level);
                program_hashes.append(static_cast<int64_t>(row.program_hash));
                target_handles.append(cell);
                target_domains.append(2);   // DerivedCell programs are cell-domain only
                backends.append(1);
            }
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["count"] = static_cast<int64_t>(idea_ids.size());
    out["idea_ids"] = idea_ids;
    out["idea_levels"] = idea_levels;
    out["program_hashes"] = program_hashes;
    out["target_handles"] = target_handles;
    out["target_domains"] = target_domains;
    out["backends"] = backends;
    return out;
}

Dictionary NativeIdeologyRuntime::snapshot(int64_t handle) const {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const CountryState *country = country_state_for(static_cast<uint64_t>(handle));
    Dictionary out; out["ok"] = true; out["country_handle"] = handle;
    out["offer_cost_q16"] = _offer_cost_q16;
    out["starting_points_q16"] = _starting_points_q16;
    const int32_t country_slot_id = static_cast<int32_t>(
        static_cast<uint64_t>(handle) & 0xffffffffULL);
    const bool handle_valid = _country_runtime != nullptr && handle != 0 &&
        country_api::valid_handle(*_country_runtime, handle);
    out["ideology_slots_capacity_max"] = _ideology_capacity_max;
    out["national_spirit_slots_capacity_max"] = _spirit_capacity_max;
    out["reroll_cost_percent"] = _reroll_cost_percent;
    {
        // Slot unlock milestones for the UI: technology id plus deltas.
        PackedInt32Array unlock_tech, unlock_ideology, unlock_spirit;
        PackedByteArray unlock_owned;
        for (const CapacityUnlock &unlock : _capacity_unlocks) {
            unlock_tech.append(unlock.technology_id);
            unlock_ideology.append(unlock.ideology_delta);
            unlock_spirit.append(unlock.spirit_delta);
            unlock_owned.append(handle_valid &&
                country_api::has_technology(*_country_runtime, country_slot_id, unlock.technology_id) ? 1 : 0);
        }
        out["capacity_unlock_technology_ids"] = unlock_tech;
        out["capacity_unlock_ideology_deltas"] = unlock_ideology;
        out["capacity_unlock_spirit_deltas"] = unlock_spirit;
        out["capacity_unlock_owned"] = unlock_owned;
    }
    auto put_points = [&](const CountryState *row) {
        const uint64_t draws = row == nullptr ? 0 : row->draw_sequence;
        out["draw_sequence"] = static_cast<int64_t>(draws);
        out["free_draws"] = row == nullptr ? 0 : static_cast<int64_t>(
            row->free_draws);
        out["next_offer_cost_q16"] = offer_cost_for(draws);
        out["reroll_cost_q16"] = reroll_cost_for(draws, handle);
        const RuntimeIdeologyPodPointLedger ledger =
            row == nullptr ? RuntimeIdeologyPodPointLedger{} : row->ledger;
        out["point_ledger_population_q16"] = ledger.population_q16;
        out["point_ledger_building_q16"] = ledger.building_q16;
        out["point_ledger_trade_q16"] = ledger.trade_q16;
        out["point_ledger_opinion_factor_q16"] = ledger.opinion_factor_q16;
        out["point_ledger_gain_factor_q16"] = ledger.gain_factor_q16;
        out["point_ledger_gain_q16"] = ledger.gain_q16;
        out["point_ledger_day"] = ledger.day;
        out["point_baseline_ready"] = row != nullptr && row->baseline_ready != 0;
        out["lifetime_points_q16"] = row == nullptr ? 0 : row->lifetime_points_q16;
        // Oldest-first gains of the last POINT_HISTORY settlements.
        PackedInt64Array history;
        if (row != nullptr) {
            const int32_t count = row->history_count;
            const int32_t start = (row->history_head + POINT_HISTORY - count) % POINT_HISTORY;
            for (int32_t i = 0; i < count; ++i)
                history.append(row->history_q16[static_cast<size_t>((start + i) % POINT_HISTORY)]);
        }
        out["point_history_q16"] = history;
        PackedInt32Array synergy_ids;
        if (row != nullptr)
            for (int32_t id = 0; id < static_cast<int32_t>(_synergies.size()); ++id)
                if (synergy_active(*row, id)) synergy_ids.append(id);
        out["active_synergy_ids"] = synergy_ids;
    };
    auto put_scalars = [&](const CountryState *row) {
        // Derived, read-only mirrors of the values published into the Effect
        // metric slab. National spirits deliberately do not count as equipped.
        int32_t equipped = 0;
        std::array<int32_t, 32> routes{};
        if (row != nullptr) {
            for (const IdeaState &idea : row->ideas) {
                if (idea.location != IDEOLOGY || idea.ideology_id < 0 ||
                        idea.ideology_id >=
                            static_cast<int32_t>(_definitions.size()))
                    continue;
                ++equipped;
                const uint32_t route_mask =
                    _definitions[static_cast<size_t>(idea.ideology_id)]
                        .route_mask;
                for (int32_t route = 0;
                        route < static_cast<int32_t>(_route_keys.size());
                        ++route) {
                    if ((route_mask & (uint32_t{1} << route)) != 0)
                        ++routes[static_cast<size_t>(route)];
                }
            }
        }
        Dictionary route_counts;
        for (int32_t route = 0;
                route < static_cast<int32_t>(_route_keys.size()); ++route) {
            route_counts[String(_route_keys[static_cast<size_t>(route)].c_str())] =
                static_cast<int64_t>(routes[static_cast<size_t>(route)]);
        }
        int32_t active_synergies = 0;
        if (row != nullptr)
            for (const uint64_t word : row->active_synergy_bits)
                active_synergies += popcount64(word);
        int32_t unlocked_era = 0;
        int32_t country_slot = -1;
        if (handle_valid && validate_country(
                static_cast<uint64_t>(handle), country_slot))
            unlocked_era = unlocked_era_for(country_slot);
        out["ideology_scalar_equipped_count"] =
            static_cast<int64_t>(equipped);
        out["ideology_scalar_route_counts"] = route_counts;
        out["ideology_scalar_active_synergy_count"] =
            static_cast<int64_t>(active_synergies);
        out["ideology_scalar_unlocked_era"] =
            static_cast<int64_t>(unlocked_era);
    };
    put_points(country);
    put_scalars(country);
    if (country == nullptr) {
        // UI reads this before the first command materializes a country row.
        // Keep the same keys as a live empty country so slot gauges and draw
        // cost never collapse to 0/0.
        out["materialized"] = false;
        out["ideology_points_q16"] = _starting_points_q16;
        out["known_ids"] = PackedInt32Array();
        out["idea_ids"] = PackedInt32Array();
        out["understanding_q16"] = PackedInt64Array();
        out["levels"] = PackedInt32Array();
        out["locations"] = PackedInt32Array();
        out["slot_indices"] = PackedInt32Array();
        out["transition_pending"] = PackedByteArray();
        out["binding_ids"] = PackedInt64Array();
        out["binding_generations"] = PackedInt32Array();
        out["binding_signatures"] = PackedInt64Array();
        out["binding_program_hashes"] = PackedInt64Array();
        out["binding_verified"] = PackedByteArray();
        PackedInt32Array empty_transition_offsets;
        empty_transition_offsets.append(0);
        out["transition_transaction_offsets"] = empty_transition_offsets;
        out["transition_transaction_ids"] = PackedInt64Array();
        out["transition_transaction_statuses"] = PackedInt32Array();
        out["ideology_slots_used"] = 0;
        out["ideology_slots_capacity"] = handle_valid
            ? ideology_capacity_for(country_slot_id) : _ideology_capacity;
        out["national_spirit_slots_used"] = 0;
        out["national_spirit_slots_capacity"] = handle_valid
            ? spirit_capacity_for(country_slot_id) : _spirit_capacity;
        out["offer_active"] = false;
        out["offer_generation"] = static_cast<int64_t>(0);
        out["offer_ids"] = PackedInt32Array();
        out["support_revision"] = static_cast<int64_t>(0);
        out["last_error"] = String(_last_error.c_str());
        return out;
    }
    out["materialized"] = true;
    PackedInt32Array known_ids, idea_ids, levels, locations, slot_indices;
    PackedInt64Array understanding, binding_ids, binding_signatures,
        binding_program_hashes, transition_transaction_ids;
    PackedInt32Array binding_generations, transition_transaction_offsets,
        transition_transaction_statuses;
    PackedByteArray transition_pending, binding_verified;
    transition_transaction_offsets.append(0);
    for (int32_t ideology_id = 0; ideology_id < static_cast<int32_t>(_definitions.size()); ++ideology_id)
        if (known(*country, ideology_id)) known_ids.append(ideology_id);
    for (const IdeaState &state : country->ideas) {
        idea_ids.append(state.ideology_id); understanding.append(state.understanding_q16);
        levels.append(state.level); locations.append(state.location);
        slot_indices.append(state.slot_index);
        transition_pending.append(state.transition.active);
        binding_ids.append(state.binding_id);
        binding_generations.append(static_cast<int32_t>(state.binding_generation));
        binding_signatures.append(static_cast<int64_t>(state.binding_signature));
        binding_program_hashes.append(static_cast<int64_t>(state.binding_program_hash));
        const bool verified = state.location == INACTIVE
            ? state.binding_id == 0
            : _effect_runtime != nullptr &&
                _effect_runtime->has_external_binding_pod(state.binding_id,
                    state.binding_generation, 0x4944454f, state.ideology_id,
                    country->handle,
                    static_cast<uint32_t>(country->handle >> 32U), state.level,
                    state.location, state.binding_signature,
                    state.binding_program_hash);
        binding_verified.append(verified ? 1 : 0);
        for (const int64_t transaction_id : state.transition.transaction_ids) {
            transition_transaction_ids.append(transaction_id);
            transition_transaction_statuses.append(_effect_runtime == nullptr ? 0
                : _effect_runtime->transaction_status_pod(transaction_id));
        }
        transition_transaction_offsets.append(
            static_cast<int32_t>(transition_transaction_ids.size()));
    }
    PackedInt32Array offer_ids;
    // Only the rows the draw actually filled. The tail is -1 by construction, and
    // a UI that zips `offer_ids` against localised card names would render three
    // "unknown" chips for a two-row offer otherwise.
    for (int32_t index = 0;
            index < static_cast<int32_t>(country->offer.choice_count); ++index)
        offer_ids.append(country->offer.ideology_ids[static_cast<size_t>(index)]);
    out["ideology_points_q16"] = country->ideology_points_q16;
    out["known_ids"] = known_ids; out["idea_ids"] = idea_ids;
    out["understanding_q16"] = understanding; out["levels"] = levels;
    out["locations"] = locations;
    out["slot_indices"] = slot_indices;
    out["transition_pending"] = transition_pending;
    out["binding_ids"] = binding_ids;
    out["binding_generations"] = binding_generations;
    out["binding_signatures"] = binding_signatures;
    out["binding_program_hashes"] = binding_program_hashes;
    out["binding_verified"] = binding_verified;
    out["transition_transaction_offsets"] = transition_transaction_offsets;
    out["transition_transaction_ids"] = transition_transaction_ids;
    out["transition_transaction_statuses"] = transition_transaction_statuses;
    out["ideology_slots_used"] = ideology_slot_cost(*country);
    out["ideology_slots_capacity"] = handle_valid
        ? ideology_capacity_for(country_slot_id) : _ideology_capacity;
    out["national_spirit_slots_used"] = spirit_slot_cost(*country);
    out["national_spirit_slots_capacity"] = handle_valid
        ? spirit_capacity_for(country_slot_id) : _spirit_capacity;
    out["offer_active"] = country->offer.active != 0;
    out["offer_generation"] = static_cast<int64_t>(country->offer.generation);
    out["offer_choice_count"] = static_cast<int32_t>(country->offer.choice_count);
    out["offer_ids"] = offer_ids;
    uint64_t support_revision = 0;
    if (_economy_runtime != nullptr) {
        const EconomyApi::CountryClassOpinionSnapshot &opinion =
            economy_api::country_class_opinion_snapshot(*_economy_runtime);
        const int32_t country_slot =
            static_cast<int32_t>(country->handle & 0xffffffffULL);
        if (opinion.class_hash == _political_class_hash &&
                opinion.class_count == _political_class_count &&
                country_slot >= 0 && country_slot < opinion.country_count &&
                country_slot < static_cast<int32_t>(
                    opinion.country_handles.size()) &&
                opinion.country_handles[static_cast<size_t>(country_slot)] ==
                    country->handle)
            support_revision = opinion.revision;
    }
    out["support_revision"] = static_cast<int64_t>(support_revision);
    out["last_error"] = String(_last_error.c_str());
    return out;
}
Dictionary NativeIdeologyRuntime::explain(int64_t handle, int32_t id) {
    if (id < 0 || id >= static_cast<int32_t>(_definitions.size()))
        return fail("ideology_id_invalid");
    Dictionary out;
    out["ok"] = true;
    out["ideology_id"] = id;
    CountryState *country =
        country_state_for(static_cast<uint64_t>(handle), false);
    const IdeaState *state =
        country == nullptr ? nullptr : idea_state_for(*country, id);
    const Definition &definition =
        _definitions[static_cast<size_t>(id)];
    out["known"] = country != nullptr && known(*country, id);
    out["level"] = state == nullptr ? -1 : state->level;
    out["understanding_q16"] =
        state == nullptr ? 0 : state->understanding_q16;
    out["location"] = state == nullptr ? INACTIVE : state->location;
    PackedInt64Array thresholds;
    PackedInt64Array daily;
    for (int32_t level = 0; level < definition.level_count; ++level) {
        thresholds.append(_levels[static_cast<size_t>(
            definition.level_begin + level)].threshold_q16);
        daily.append(_levels[static_cast<size_t>(
            definition.level_begin + level)].daily_understanding_q16);
    }
    out["thresholds_q16"] = thresholds;
    out["daily_understanding_q16"] = daily;
    out["min_spirit_level"] = definition.min_spirit_level;
    PackedInt32Array support_q16;
    PackedInt32Array support_thresholds;
    PackedInt32Array blocking_classes;
    PackedByteArray support_available;
    PackedByteArray support_allowed;
    uint64_t revision = 0;
    for (int32_t direction = SUPPORT_ADOPT;
            direction <= SUPPORT_PROMOTE; ++direction) {
        const SupportResult support = country == nullptr
            ? SupportResult{}
            : evaluate_support(*country, id,
                static_cast<SupportDirection>(direction));
        support_q16.append(support.support_q16);
        support_thresholds.append(support.threshold_q16);
        blocking_classes.append(support.blocking_class);
        support_available.append(support.available ? 1 : 0);
        support_allowed.append(support.allowed ? 1 : 0);
        revision = std::max(revision, support.revision);
    }
    out["support_q16"] = support_q16;
    out["support_thresholds_q16"] = support_thresholds;
    out["support_blocking_classes"] = blocking_classes;
    out["support_available"] = support_available;
    out["support_allowed"] = support_allowed;
    out["support_revision"] = static_cast<int64_t>(revision);
    PackedInt32Array stance_classes;
    PackedInt64Array class_influence;
    PackedInt32Array adopt_stances;
    PackedInt32Array repeal_stances;
    PackedInt32Array promote_stances;
    PackedInt64Array adopt_contributions;
    PackedInt64Array repeal_contributions;
    PackedInt64Array promote_contributions;
    for (int32_t row = definition.stance_begin;
            row < definition.stance_begin + definition.stance_count; ++row) {
        const ClassStance &stance =
            _class_stances[static_cast<size_t>(row)];
        const int64_t influence =
            country != nullptr &&
                    static_cast<size_t>(stance.class_index) <
                        country->class_influence.size()
                ? country->class_influence[
                    static_cast<size_t>(stance.class_index)] : 0;
        stance_classes.append(stance.class_index);
        class_influence.append(influence);
        adopt_stances.append(stance.stance_q16[SUPPORT_ADOPT]);
        repeal_stances.append(stance.stance_q16[SUPPORT_REPEAL]);
        promote_stances.append(stance.stance_q16[SUPPORT_PROMOTE]);
        adopt_contributions.append(mul_sat(influence,
            stance.stance_q16[SUPPORT_ADOPT]));
        repeal_contributions.append(mul_sat(influence,
            stance.stance_q16[SUPPORT_REPEAL]));
        promote_contributions.append(mul_sat(influence,
            stance.stance_q16[SUPPORT_PROMOTE]));
    }
    out["stance_class_indices"] = stance_classes;
    out["class_influence"] = class_influence;
    out["adopt_stances_q16"] = adopt_stances;
    out["repeal_stances_q16"] = repeal_stances;
    out["promote_stances_q16"] = promote_stances;
    out["adopt_contributions"] = adopt_contributions;
    out["repeal_contributions"] = repeal_contributions;
    out["promote_contributions"] = promote_contributions;
    PackedInt32Array affected_synergy_ids;
    PackedByteArray current_synergy_active;
    PackedByteArray expected_synergy_active;
    if (country != nullptr && id + 1 <
            static_cast<int32_t>(_ideology_synergy_offsets.size())) {
        for (int32_t cursor =
                _ideology_synergy_offsets[static_cast<size_t>(id)];
                cursor < _ideology_synergy_offsets[
                    static_cast<size_t>(id + 1)]; ++cursor) {
            const int32_t synergy_id =
                _ideology_synergy_ids[static_cast<size_t>(cursor)];
            affected_synergy_ids.append(synergy_id);
            current_synergy_active.append(
                synergy_active(*country, synergy_id) ? 1 : 0);
            expected_synergy_active.append(
                synergy_requirements_met(*country, synergy_id) ? 1 : 0);
        }
    }
    out["affected_synergy_ids"] = affected_synergy_ids;
    out["current_synergy_active"] = current_synergy_active;
    out["expected_synergy_active"] = expected_synergy_active;
    return out;
}

Dictionary NativeIdeologyRuntime::explain_batch(int64_t handle,
        const PackedInt32Array &requested_ids) {
    CountryState *country =
        country_state_for(static_cast<uint64_t>(handle), false);
    if (country == nullptr) return fail("ideology_country_unknown");

    PackedInt32Array ids;
    if (requested_ids.is_empty()) {
        for (int32_t id = 0;
                id < static_cast<int32_t>(_definitions.size()); ++id)
            if (known(*country, id)) ids.append(id);
    } else {
        std::vector<uint8_t> seen(_definitions.size(), 0);
        for (const int32_t id : requested_ids) {
            if (id < 0 || id >= static_cast<int32_t>(_definitions.size()))
                return fail("ideology_id_invalid");
            if (seen[static_cast<size_t>(id)] != 0) continue;
            seen[static_cast<size_t>(id)] = 1;
            ids.append(id);
        }
    }

    PackedInt32Array support_q16;
    PackedInt32Array support_thresholds;
    PackedInt32Array blocking_classes;
    PackedByteArray support_available;
    PackedByteArray support_allowed;
    PackedByteArray equip_allowed;
    PackedByteArray unequip_allowed;
    PackedByteArray promote_allowed;
    PackedByteArray exclusion_allowed;
    PackedInt32Array stance_offsets;
    PackedInt32Array stance_class_indices;
    PackedInt64Array class_influence;
    PackedInt64Array adopt_contributions;
    PackedInt64Array repeal_contributions;
    PackedInt64Array promote_contributions;
    PackedInt32Array synergy_offsets;
    PackedInt32Array affected_synergy_ids;
    PackedByteArray current_synergy_active;
    PackedByteArray equip_synergy_active;
    PackedByteArray unequip_synergy_active;
    PackedByteArray promote_synergy_active;
    stance_offsets.append(0);
    synergy_offsets.append(0);
    uint64_t revision = 0;

    auto requirements_met_with_override =
        [&](int32_t synergy_id, int32_t override_ideology_id,
                uint8_t override_location,
                int32_t override_level) -> bool {
        if (synergy_id < 0 ||
                synergy_id >= static_cast<int32_t>(_synergies.size()))
            return false;
        const Synergy &synergy =
            _synergies[static_cast<size_t>(synergy_id)];
        for (int32_t row = synergy.requirement_begin;
                row < synergy.requirement_begin + synergy.requirement_count;
                ++row) {
            const SynergyRequirement &requirement =
                _synergy_requirements[static_cast<size_t>(row)];
            const IdeaState *required_state =
                idea_state_for(*country, requirement.ideology_id);
            const uint8_t location =
                requirement.ideology_id == override_ideology_id
                ? override_location
                : (required_state == nullptr
                    ? INACTIVE : required_state->location);
            const int32_t level =
                requirement.ideology_id == override_ideology_id
                ? override_level
                : (required_state == nullptr ? -1 : required_state->level);
            if (level < requirement.minimum_level ||
                    (requirement.location_mask & (1U << location)) == 0)
                return false;
        }
        return true;
    };

    for (const int32_t id : ids) {
        const Definition &definition =
            _definitions[static_cast<size_t>(id)];
        IdeaState *state = idea_state_for(*country, id, false);
        std::array<SupportResult, 3> supports;
        for (int32_t direction = SUPPORT_ADOPT;
                direction <= SUPPORT_PROMOTE; ++direction) {
            supports[static_cast<size_t>(direction)] =
                evaluate_support(*country, id,
                    static_cast<SupportDirection>(direction));
            const SupportResult &support =
                supports[static_cast<size_t>(direction)];
            support_q16.append(support.support_q16);
            support_thresholds.append(support.threshold_q16);
            blocking_classes.append(support.blocking_class);
            support_available.append(support.available ? 1 : 0);
            support_allowed.append(support.allowed ? 1 : 0);
            revision = std::max(revision, support.revision);
        }

        std::string ignored;
        const bool exclusion_ok = exclusion_allows(*country, id, ignored);
        exclusion_allowed.append(exclusion_ok ? 1 : 0);
        const bool state_pending =
            state != nullptr && state->transition.active != 0;
        const bool country_pending =
            country->pending_transition_count > 0 && !_synergies.empty();
        const uint8_t location =
            state == nullptr ? INACTIVE : state->location;
        const int32_t reconciled_level =
            state == nullptr ? -1
            : std::max(state->level, unlocked_level(*state));
        equip_allowed.append(
            known(*country, id) && state != nullptr &&
            location == INACTIVE && !state_pending && !country_pending &&
            exclusion_ok && supports[SUPPORT_ADOPT].allowed &&
            country->ideology_slots_used + definition.ideology_cost <=
                _ideology_capacity ? 1 : 0);
        unequip_allowed.append(
            state != nullptr && location == IDEOLOGY &&
            !state_pending && !country_pending &&
            supports[SUPPORT_REPEAL].allowed ? 1 : 0);
        promote_allowed.append(
            state != nullptr && location == IDEOLOGY &&
            !state_pending && !country_pending &&
            reconciled_level >= definition.min_spirit_level &&
            country->spirit_slots_used + definition.spirit_cost <=
                _spirit_capacity &&
            supports[SUPPORT_PROMOTE].allowed ? 1 : 0);

        for (int32_t row = definition.stance_begin;
                row < definition.stance_begin + definition.stance_count;
                ++row) {
            const ClassStance &stance =
                _class_stances[static_cast<size_t>(row)];
            const int64_t influence =
                static_cast<size_t>(stance.class_index) <
                    country->class_influence.size()
                ? country->class_influence[
                    static_cast<size_t>(stance.class_index)] : 0;
            stance_class_indices.append(stance.class_index);
            class_influence.append(influence);
            adopt_contributions.append(mul_sat(influence,
                stance.stance_q16[SUPPORT_ADOPT]));
            repeal_contributions.append(mul_sat(influence,
                stance.stance_q16[SUPPORT_REPEAL]));
            promote_contributions.append(mul_sat(influence,
                stance.stance_q16[SUPPORT_PROMOTE]));
        }
        stance_offsets.append(stance_class_indices.size());

        if (id + 1 < static_cast<int32_t>(
                _ideology_synergy_offsets.size())) {
            for (int32_t cursor =
                    _ideology_synergy_offsets[static_cast<size_t>(id)];
                    cursor < _ideology_synergy_offsets[
                        static_cast<size_t>(id + 1)]; ++cursor) {
                const int32_t synergy_id =
                    _ideology_synergy_ids[static_cast<size_t>(cursor)];
                affected_synergy_ids.append(synergy_id);
                current_synergy_active.append(
                    synergy_active(*country, synergy_id) ? 1 : 0);
                equip_synergy_active.append(
                    requirements_met_with_override(synergy_id, id,
                        IDEOLOGY, reconciled_level) ? 1 : 0);
                unequip_synergy_active.append(
                    requirements_met_with_override(synergy_id, id,
                        INACTIVE, reconciled_level) ? 1 : 0);
                promote_synergy_active.append(
                    requirements_met_with_override(synergy_id, id,
                        NATIONAL_SPIRIT, reconciled_level) ? 1 : 0);
            }
        }
        synergy_offsets.append(affected_synergy_ids.size());
    }

    Dictionary out;
    out["ok"] = true;
    out["ideology_ids"] = ids;
    out["support_revision"] = static_cast<int64_t>(revision);
    out["support_q16"] = support_q16;
    out["support_thresholds_q16"] = support_thresholds;
    out["support_blocking_classes"] = blocking_classes;
    out["support_available"] = support_available;
    out["support_allowed"] = support_allowed;
    out["equip_allowed"] = equip_allowed;
    out["unequip_allowed"] = unequip_allowed;
    out["promote_allowed"] = promote_allowed;
    out["exclusion_allowed"] = exclusion_allowed;
    out["stance_offsets"] = stance_offsets;
    out["stance_class_indices"] = stance_class_indices;
    out["class_influence"] = class_influence;
    out["adopt_contributions"] = adopt_contributions;
    out["repeal_contributions"] = repeal_contributions;
    out["promote_contributions"] = promote_contributions;
    out["affected_synergy_offsets"] = synergy_offsets;
    out["affected_synergy_ids"] = affected_synergy_ids;
    out["current_synergy_active"] = current_synergy_active;
    out["equip_synergy_active"] = equip_synergy_active;
    out["unequip_synergy_active"] = unequip_synergy_active;
    out["promote_synergy_active"] = promote_synergy_active;
    return out;
}

Dictionary NativeIdeologyRuntime::report() const {
    Dictionary out;
    out["configured"] = _configured;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    // Plan §11.5: the execution-contract identity this runtime is executing under. A
    // reader compares it with what an archive claims, which is how an archive produced
    // under different execution rules gets refused instead of reinterpreted.
    out["execution_contract_hash"] = static_cast<int64_t>(compute_execution_contract_hash());
    out["ideology_count"] = static_cast<int32_t>(_definitions.size());
    out["countries_allocated"] = static_cast<int32_t>(_countries.size());
    out["pending_commands"] = static_cast<int32_t>(pending_command_count());
    out["pending_transitions"] = static_cast<int32_t>(_pending_transitions.size());
    out["active_visits"] = static_cast<int64_t>(_active_visits);
    out["dormant_scan_count"] = static_cast<int64_t>(_dormant_scan_count);
    out["sparse_idea_scan_count"] = static_cast<int64_t>(_sparse_idea_scan_count);
    out["pending_transition_visits"] = static_cast<int64_t>(_pending_transition_visits);
    out["command_queue_resorts"] = static_cast<int64_t>(_command_queue_resorts);
    out["command_queue_shift_steps"] = static_cast<int64_t>(_command_queue_shift_steps);
    out["command_queue_merge_steps"] = static_cast<int64_t>(_command_queue_merge_steps);
    out["derived_rebuild_visits"] = static_cast<int64_t>(_derived_rebuild_visits);
    // Cell-layer rebuild diagnostics (plan 22 §12.4). `cell_layer_rebuild_visits`
    // counts calls to the sharded rebuild, which is a different question
    // from `derived_rebuild_visits` above (an idea-iteration counter).
    out["cell_layer_rebuild_visits"] = static_cast<int64_t>(_cell_layer_rebuild_visits);
    out["cell_layer_rebuild_skips"] = static_cast<int64_t>(_cell_layer_rebuild_skips);
    out["cell_layer_rebuild_ms"] = _cell_layer_rebuild_ms;
    // §14.3: split so a slice boundary can be placed where the time actually goes.
    out["cell_layer_collect_ms"] = _derived_collect_ms;
    out["cell_layer_materialise_ms"] = _derived_materialise_ms;
    // How many slices the sharded rebuild needed; 1 means it fit in a single step.
    out["cell_layer_rebuild_steps"] = static_cast<int64_t>(_derived_rebuild_steps);
    // A sharded rebuild finishes across several `run_ideology_daily` calls. A caller
    // that reads the layer immediately after one call sees an EMPTY front, which is
    // exactly what broke B7/B8/B10/stress when the stage was introduced -- the tests
    // drive a fixed number of days and never learned that the layer now needs
    // draining. Exposing the flag lets them (and production) wait honestly instead of
    // guessing a call count.
    out["derived_rebuild_pending"] = derived_rebuild_pending();
    // Plan §9.3 asks for the ability to tell which projections are not eligible yet.
    out["derived_basis_confirmed_day"] = _derived_basis_confirmed_day;
    out["derived_basis_eligible_day"] = _derived_basis_eligible_day;
    // Plan §18.2: how many (country, program) rows the LAST projection was built from,
    // and a digest of them. Zero means no derived program has been applied yet -- which
    // is also why a capture of such a world persists an empty basis block, not a
    // fabricated one.
    out["applied_program_basis_rows"] =
        static_cast<int64_t>(_applied_program_basis.size());
    out["applied_program_basis_digest"] = static_cast<int64_t>(
        mix_applied_program_basis(1469598103934665603ULL,
            _applied_program_basis));
    // WHICH program the surviving basis names. A count and a digest cannot tell a no-op
    // from a HALF-WRITE when both sides hold one row, so the atomicity assertion (a
    // refusal that happens AFTER the basis was parsed must leave the previous basis
    // intact) needs the identity itself.
    out["applied_program_basis_first_program"] = String(
        _applied_program_basis.empty()
            ? "" : _applied_program_basis.front().program_key.c_str());
    // §18.5: the local scalar basis the LAST RESTORE installed, and the sample day the
    // last projection was built from. `rows == 0` on a runtime that has never
    // restored is the state the atomicity assertion needs: a refused restore that had
    // already parsed (and committed) a non-empty record must leave BOTH numbers where
    // they were. Same reason as `applied_program_basis_first_program` above, the
    // identity of the first row is reported -- a count and a digest cannot tell a
    // no-op from a half-write when both sides hold one row.
    out["local_scalar_basis_rows"] =
        static_cast<int64_t>(_local_scalar_basis.size());
    out["local_scalar_basis_digest"] = static_cast<int64_t>(
        mix_local_scalar_basis(1469598103934665603ULL, _local_scalar_basis));
    out["local_scalar_basis_first_metric"] = _local_scalar_basis.empty()
        ? -1 : _local_scalar_basis.front().metric_id;
    out["local_scalar_basis_first_value"] = _local_scalar_basis.empty()
        ? 0 : _local_scalar_basis.front().value_q16;
    // §18.5: WHY the last `ideology_save_scalar_basis_mismatch` fired, in one line:
    // row counts on both sides plus the first differing (country, metric, value) pairs.
    // Empty when the last restore did not refuse. A named refusal without this costs a
    // debugging round per firing, which is exactly what happened the first time.
    out["local_scalar_basis_mismatch_detail"] =
        String(_last_scalar_basis_mismatch_detail.c_str());
    out["derived_basis_sample_day"] = _derived_basis_sample_day;
    // §18.5: the epoch id the projection was built against. STRUCTURALLY 0 -- declared
    // once, never assigned, and read only as the DerivedCellMaterializeJob argument --
    // which is exactly why the payload does NOT carry it (see `capture`). Reported so
    // that claim is measurable from outside instead of being a comment.
    out["derived_basis_epoch_id"] = static_cast<int64_t>(_derived_epoch_id);
    out["derived_rebuild_gated_by_eligibility"] =
        _derived_rebuild_gated_by_eligibility;
    // Non-zero proves the sharded path EVALUATED ramp terms instead of deferring them.
    out["ramp_samples_taken"] = static_cast<int64_t>(_derived_ramp_samples_taken);
    // Proof that the PROGRAM ran, not the metric fallback.
    out["derived_program_evaluations"] =
        static_cast<int64_t>(_derived_program_evaluations);
    out["derived_program_failures"] = static_cast<int64_t>(_derived_program_failures);
    out["ramp_candidates"] = static_cast<int64_t>(_ramp_candidates);
    // I01 evidence: how many programs the old plane SKIPPED because the derived layer
    // owns them. Without this number "the plane no longer double-counts" is not
    // observable from outside.
    out["cell_plane_derived_elsewhere"] =
        static_cast<int64_t>(_cell_plane_derived_elsewhere);
    out["cell_plane_builds"] = static_cast<int64_t>(_cell_plane_builds);
    // Ownership-scope evidence: how many fan-out resolves ran under each scope.
    out["ownership_filtered_resolves"] =
        static_cast<int64_t>(_ownership_filtered_resolves);
    out["ownership_own_resolves"] = static_cast<int64_t>(_ownership_own_resolves);
    out["ownership_foreign_resolves"] =
        static_cast<int64_t>(_ownership_foreign_resolves);
    out["consumer_publish_calls"] = static_cast<int64_t>(_consumer_publish_calls);
    out["consumer_tag_ids"] = _consumer_tag_ids_last;
    out["consumer_levels_with_tags"] = static_cast<int64_t>(_consumer_levels_with_tags);
    out["ramp_metric_ok"] = static_cast<int64_t>(_ramp_metric_ok);
    out["ramp_samples_memoised"] =
        static_cast<int64_t>(_derived_ramp_samples_memoised);
    out["cell_layer_collect_count"] = _derived_collect_count;
    out["cell_layer_collect_rows"] = _derived_collect_rows;
    out["cell_layer_collect_ideas"] = _derived_collect_ideas;
    out["cell_layer_delta_a"] = _derived_first_country_delta;
    out["cell_layer_delta_b"] = _derived_second_country_delta;
    out["cell_layer_contribs_passed"] = _derived_contribs_passed;
    out["cell_layer_rows_emitted"] = _last_derived_materialize.rows_emitted;
    out["cell_layer_allocations"] = _last_derived_materialize.allocations;
    out["cell_layer_cells_visited"] = _last_derived_materialize.cells_visited;
    out["cell_layer_collect_ok"] = _derived_last_collect_ok;
    // M4 diagnosis: which exit `collect_effect_activations` took.
    out["collect_entries"] = static_cast<int64_t>(_collect_entries);
    out["collect_templates"] = static_cast<int64_t>(_collect_templates);
    out["collect_program_empty"] = static_cast<int64_t>(_collect_program_empty);
    out["collect_pod_fail"] = static_cast<int64_t>(_collect_pod_fail);
    {
        PackedStringArray keys;
        for (const std::string &key : _collect_pod_fail_keys) keys.append(key.c_str());
        out["collect_pod_fail_keys"] = keys;
        PackedStringArray ok_keys;
        for (const std::string &key : _collect_pod_ok_keys) ok_keys.append(key.c_str());
        out["collect_pod_ok_keys"] = ok_keys;
    }
    out["collect_targets_fail"] = static_cast<int64_t>(_collect_targets_fail);
    out["collect_derived_emitted"] = static_cast<int64_t>(_collect_derived_emitted);
    out["targets_country_zero"] = static_cast<int64_t>(_targets_country_zero);
    out["targets_domain_gate"] = static_cast<int64_t>(_targets_domain_gate);
    out["targets_economy_null"] = static_cast<int64_t>(_targets_economy_null);
    out["targets_anchor_neg"] = static_cast<int64_t>(_targets_anchor_neg);
    out["targets_collected_empty"] = static_cast<int64_t>(_targets_collected_empty);
    out["targets_fanout_no_tag"] = static_cast<int64_t>(_targets_fanout_no_tag);
    out["targets_fanout_no_source"] = static_cast<int64_t>(_targets_fanout_no_source);
    out["targets_fanout_ring_empty"] = static_cast<int64_t>(_targets_fanout_ring_empty);
    // §18.3 peak memory. Bytes of the derived structure, not process RSS.
    // `scratch` is NOT reported: the materialiser's working buffers are not reachable
    // from here, and a made-up number would be worse than a documented gap.
    out["peak_retained_bytes"] = static_cast<int64_t>(_derived_peak_retained_bytes);
    out["peak_candidate_bytes"] = static_cast<int64_t>(_derived_peak_candidate_bytes);
    out["peak_total_bytes"] = static_cast<int64_t>(_derived_peak_total_bytes);
    // M3 ramp sampling: `taken` counts real metric samples, `memoised` counts
    // country-scope cache hits. For a wide territory a country metric should
    // show memoised >> 0; if taken grows while memoised stays 0, the cache key
    // or the scoped id range is wrong.
    out["ramp_samples_taken"] = static_cast<int64_t>(_ramp_samples_taken);
    out["ramp_samples_memoised"] = static_cast<int64_t>(_ramp_samples_memoised);
    out["ramp_terms_evaluated"] = static_cast<int64_t>(_ramp_terms_evaluated);
    out["ramp_terms_deferred"] = static_cast<int64_t>(_ramp_terms_deferred);
    out["commands_applied"] = static_cast<int64_t>(_commands_applied);
    out["commands_rejected"] = static_cast<int64_t>(_commands_rejected);
    out["offers_opened"] = static_cast<int64_t>(_offers_opened);
    out["levels_advanced"] = static_cast<int64_t>(_levels_advanced);
    out["class_snapshot_reads"] =
        static_cast<int64_t>(_class_snapshot_reads);
    out["political_class_hash"] = static_cast<int64_t>(_political_class_hash);
    out["political_class_count"] = static_cast<int32_t>(_political_class_count);
    out["points_accrue_result"] = static_cast<int32_t>(_points_accrue_result);
    out["points_accrue_revision"] = static_cast<int64_t>(_points_accrue_revision);
    out["points_revision_seen"] = static_cast<int64_t>(_points_revision_seen);
    out["support_evaluations"] =
        static_cast<int64_t>(_support_evaluations);
    out["synergy_candidates_visited"] =
        static_cast<int64_t>(_synergy_candidates_visited);
    out["selector_truncations"] = static_cast<int64_t>(_selector_truncations);
    out["selector_matched_total"] =
        static_cast<int64_t>(_selector_stats.matched_total);
    out["source_count_evaluations"] =
        static_cast<int64_t>(_source_count_evaluations);
    out["metric_publishes"] = static_cast<int64_t>(_metric_publishes);
    out["metric_publishes_skipped"] =
        static_cast<int64_t>(_metric_publishes_skipped);
    out["managed_idea_count"] = static_cast<int64_t>(_managed_active_total);
    out["instance_refresh_visits"] =
        static_cast<int64_t>(_instance_refresh_visits);
    out["cell_plane_rebuilds"] = static_cast<int64_t>(_cell_plane_builds);
    out["synergy_scale_lookups"] = static_cast<int64_t>(_synergy_scale_lookups);
    out["synergy_scale_scans"] = static_cast<int64_t>(_synergy_scale_scans);
    out["instance_refresh_skips"] =
        static_cast<int64_t>(_instance_refresh_skips);
    out["instance_refresh_passes"] =
        static_cast<int64_t>(_instance_refresh_passes);
    out["instance_refresh_lag_revisions"] =
        static_cast<int64_t>(_instance_refresh_lag_revisions);
    out["instance_refresh_pending"] = _instance_refresh_pending;
    out["instance_refresh_ms"] = _instance_refresh_ms;
    out["effect_input_revision_seen"] =
        static_cast<int64_t>(_effect_input_revision_seen);
    out["effect_input_revision_target"] =
        static_cast<int64_t>(_effect_input_revision_target);
    out["effect_input_revision"] = _economy_runtime == nullptr
        ? static_cast<int64_t>(0)
        : static_cast<int64_t>(economy_api::effect_input_revision(*_economy_runtime));
    out["transition_poll_ms"] = _transition_poll_ms;
    out["command_apply_ms"] = _command_apply_ms;
    out["active_progress_ms"] = _active_progress_ms;
    out["last_slice_ms"] = _last_slice_ms;
    out["max_slice_ms"] = _max_slice_ms;
    out["active_progress_day"] = _active_progress_day;
    out["active_country_cursor"] = _active_country_cursor;
    out["active_item_cursor"] = _active_item_cursor;
    out["last_error"] = String(_last_error.c_str());
    return out;
}

} // namespace pk
