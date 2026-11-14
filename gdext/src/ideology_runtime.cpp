#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>

// Authority-aware instance queries: the ideology report and the ideology restore
// both ask whether an instance still exists / has fired.

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace pk {
using namespace godot;



void NativeIdeologyRuntime::reset_runtime_state() {
    _worker_opinion_inputs = RuntimeIdeologyOpinionSnapshot{};
    _worker_opinion_inputs_valid = false;
    _countries.clear();
    _commands.clear();
    _command_cursor = 0;
    _producer_high_watermarks.clear();
    _receipts.clear();
    _next_receipt_id = 1;
    _applying_producer_id = 0;
    _applying_sequence = 0;
    _applying_opcode = 0;
    _pending_transitions.clear();
    _pending_transition_cursor = 0;
    _active_progress_day = -1;
    _daily_continuation_day = -1;
    _active_country_cursor = 0;
    _active_item_cursor = 0;
    _submit_order = 0;
    _last_day = -1;
    _active_visits = 0;
    _dormant_scan_count = 0;
    _sparse_idea_scan_count = 0;
    _pending_transition_visits = 0;
    _command_queue_resorts = 0;
    _command_queue_shift_steps = 0;
    _command_queue_merge_steps = 0;
    _derived_rebuild_visits = 0;
    _commands_applied = 0;
    _commands_rejected = 0;
    _offers_opened = 0;
    _levels_advanced = 0;
    _class_snapshot_reads = 0;
    _support_evaluations = 0;
    _synergy_candidates_visited = 0;
    _metric_publishes = 0;
    _metric_publishes_skipped = 0;
    _selector_stats = EffectSelectorStats{};
    _selector_truncations = 0;
    _source_count_evaluations = 0;
    _managed_active_total = 0;
    _effect_input_revision_seen = 0;
    _effect_input_revision_target = 0;
    _instance_refresh_pending = false;
    _instance_refresh_dirty = false;
    _instance_refresh_country_cursor = 0;
    _instance_refresh_visits = 0;
    _instance_refresh_skips = 0;
    _instance_refresh_passes = 0;
    _instance_refresh_lag_revisions = 0;
    _instance_refresh_ms = 0.0;
    _level_managed_built = false;
    _synergy_candidate_generation = 0;
    _synergy_candidate_scratch.clear();
    _transition_poll_ms = 0.0;
    _command_apply_ms = 0.0;
    _active_progress_ms = 0.0;
    _last_slice_ms = 0.0;
    _max_slice_ms = 0.0;
    _pod_snapshot_generation = 0;
    _points_revision_seen = 0;
    _worker_origin = false;
    // The applied basis describes the country rows and the catalogs it was derived
    // from; a reset clears the rows, so the basis goes with them. (The two basis DATES
    // are deliberately left alone here: §9.3 eligibility is a clock property, not a row
    // property, and resetting it would let a reconfigure re-adopt a projection early.)
    _applied_program_basis.clear();
    _derived_installed_contributions.clear();
    _derived_installed_generation = 0;
    // §18.5: same argument for the scalar record -- it describes the rows that were
    // just cleared. `_derived_basis_sample_day` is a clock/identity property of the
    // projection like the two dates above, so it is deliberately left alone.
    _local_scalar_basis.clear();
    _last_error.clear();
}

bool NativeIdeologyRuntime::apply_pod_snapshot(
        const RuntimeIdeologyPodSnapshot &snapshot, std::string &error) {
    error.clear();
    if (!_configured) {
        error = "ideology_runtime_not_configured";
        return false;
    }
    // ── plan §9.3 in WORKER mode ────────────────────────────────────────────
    //
    // The two basis dates were stamped only in `settle_transition`'s success path, which
    // never runs on the main thread when the worker owns IDEOLOGY. Without this the
    // eligibility gate is permanently open there, and publishing projections with §9.3
    // silently unenforced is worse than publishing none.
    //
    // The mirror's `committed_day` is the worker's own confirmation day: everything in
    // this snapshot was ACKed on it, so the projection it carries is confirmed that day
    // and eligible the next -- the same rule the local path applies.
    if (snapshot.committed_day != _derived_basis_confirmed_day) {
        _derived_basis_confirmed_day = snapshot.committed_day;
        _derived_basis_eligible_day = snapshot.committed_day + 1;
    }


    if (_worker_opinion_inputs_valid) {
        const size_t school_count = _school_keys.size();
        if (school_count > 0) {
            const bool shaped =
                _worker_opinion_inputs.school_strength_factor_q16.empty() ||
                _worker_opinion_inputs.school_strength_factor_q16.size() ==
                    snapshot.countries.size() * school_count;
            if (!shaped) {
                error = "ideology_school_strength_snapshot_shape_invalid";
                return false;
            }
        }
    }
    if (snapshot.abi_version != RUNTIME_IDEOLOGY_POD_ABI_VERSION) {
        error = "ideology_pod_snapshot_abi_mismatch";
        return false;
    }
    if (snapshot.generation != 0 &&
            snapshot.generation <= _pod_snapshot_generation) {
        error = "ideology_pod_snapshot_generation_regression";
        return false;
    }
    const size_t definition_count = _definitions.size();
    const size_t idea_words = static_cast<size_t>(std::max(0, _idea_words));
    const size_t gate_words = static_cast<size_t>(std::max(0, _gate_words));
    const size_t synergy_words = (_synergies.size() + 63u) / 64u;

    std::vector<CountryState> next_countries(snapshot.countries.size());
    for (size_t slot = 0; slot < snapshot.countries.size(); ++slot) {
        const RuntimeIdeologyPodCountryState &source = snapshot.countries[slot];
        if (source.handle == 0) continue;
        CountryState &target = next_countries[slot];
        // P1-B: the instance set is NOT part of the POD snapshot -- the worker
        // never sees an Effect instance, the facade owns them. Carry the previous
        // rows across by (country, ideology) so a write-back cannot resubmit the
        // whole world, and so the retire pass still has something to compare
        // against. Moved, not copied: the old table is discarded right below.
        CountryState *previous_country = nullptr;
        const uint32_t previous_slot =
            static_cast<uint32_t>(source.handle & 0xffffffffULL);
        if (previous_slot < _countries.size() &&
                _countries[previous_slot].handle == source.handle)
            previous_country = &_countries[previous_slot];
        target.handle = source.handle;
        target.unlocked_era = source.unlocked_era;
        target.ideology_points_q16 = source.ideology_points_q16;
        target.rng_state = source.rng_state;
        target.draw_sequence = source.draw_sequence;
        target.free_draws = source.free_draws;
        target.points_revision = source.points_revision;
        target.baseline_ready = source.baseline_ready;
        target.history_count = source.history_count;
        target.history_head = source.history_head;
        target.baseline_population = source.baseline_population;
        target.baseline_buildings = source.baseline_buildings;
        target.lifetime_points_q16 = source.lifetime_points_q16;
        target.trade_paid_day = source.trade_paid_day;
        target.ledger = source.ledger;
        for (size_t i = 0; i < target.history_q16.size() &&
                i < source.history_q16.size(); ++i)
            target.history_q16[i] = source.history_q16[i];
        target.opinion_revision = source.opinion_revision;
        target.ideology_slots_used = source.ideology_slots_used;
        target.spirit_slots_used = source.spirit_slots_used;
        target.known_bits.assign(idea_words, 0);
        target.gate_bits.assign(gate_words, 0);
        target.active_bits.assign(idea_words, 0);
        target.active_synergy_bits.assign(synergy_words, 0);
        // 封存 lives in its own bitmap, and the POD has always carried it. Not
        // copying it let a banned card reappear in the offer the moment a worker
        // snapshot landed.
        target.banned_bits.assign(idea_words, 0);
        for (size_t word = 0;
                word < idea_words && word < source.banned_bits.size(); ++word)
            target.banned_bits[word] = source.banned_bits[word];
        if (source.offer.choice_count > OFFER_CHOICE_CAPACITY ||
                source.unlocked_era < 0) {
            error = "ideology_pod_snapshot_country_invalid";
            return false;
        }
        for (size_t word = 0;
                word < idea_words && word < source.known_bits.size(); ++word)
            target.known_bits[word] = source.known_bits[word];
        for (size_t word = 0;
                word < gate_words && word < source.gate_bits.size(); ++word)
            target.gate_bits[word] = source.gate_bits[word];
        for (size_t word = 0;
                word < synergy_words && word < source.synergy_bits.size(); ++word)
            target.active_synergy_bits[word] = source.synergy_bits[word];
        target.offer.generation = source.offer.generation;
        target.offer.ideology_ids = source.offer.ideology_ids;
        target.offer.active = source.offer.active;
        target.offer.choice_count = source.offer.choice_count;
        // POD ideas are dense by ideology_id. The facade keeps sparse rows plus
        // an id->row index, so only rows that carry state are materialised;
        // everything else stays absent exactly as the synchronous path leaves
        // an undiscovered idea.
        for (size_t id = 0; id < source.ideas.size() && id < definition_count;
                ++id) {
            const RuntimeIdeologyPodIdeaState &idea = source.ideas[id];
            const bool discovered = (id / 64u) < target.known_bits.size() &&
                (target.known_bits[id / 64u] & (1ull << (id % 64u))) != 0;
            if (!discovered &&
                    idea.location == RuntimeIdeologyPodLocation::INACTIVE &&
                    idea.understanding_q16 == 0 && idea.level < 0 &&
                    idea.entered_levels == 0 && idea.generation <= 1) {
                continue;
            }
            const int32_t row = static_cast<int32_t>(target.ideas.size());
            IdeaState state;
            state.ideology_id = static_cast<int32_t>(id);
            state.understanding_q16 = idea.understanding_q16;
            state.level = idea.level;
            state.entered_levels = idea.entered_levels;
            state.generation = idea.generation;
            state.location = static_cast<uint8_t>(idea.location);
            state.slot_index = idea.slot_index;
            // Carry the facade-owned instance rows and the signature that
            // produced them. Without this every write-back looked like "no
            // instances held", so reconcile resubmitted every card and the
            // retire pass had nothing to retire against.
            if (previous_country != nullptr) {
                auto previous_row =
                    previous_country->idea_indices.find(state.ideology_id);
                if (previous_row != previous_country->idea_indices.end()) {
                    IdeaState &previous = previous_country->ideas[
                        static_cast<size_t>(previous_row->second)];
                    state.effect_instances = std::move(previous.effect_instances);
                    state.activation_signature = previous.activation_signature;
                    // The worker snapshot is authoritative for whether the idea
                    // is still equipped. If it just went inactive, retires can
                    // no longer ride the active-only refresh pass, so release
                    // the carried facade instances here.
                    if (state.location == INACTIVE &&
                            !state.effect_instances.empty()) {
                        retire_effect_activations(state, snapshot.committed_day);
                        state.activation_signature = 0;
                    }
                }
            }
            // The durable binding identity is a pure function of (handle, idea,
            // location, generation, level), so it is derived rather than carried.
            // Leaving it zero made compute_state_hash disagree between the
            // synchronous and worker paths for the same world.
            if (state.location != INACTIVE) {
                state.binding_id = static_cast<int64_t>(binding_id_for(
                    target.handle, state.ideology_id, state.location));
                state.binding_generation = state.generation;
                state.binding_signature =
                    binding_signature_for(state.ideology_id, state.level);
                state.binding_program_hash =
                    _effect_runtime != nullptr ? _effect_runtime->catalog_hash() : 0;
            }
            target.idea_indices[state.ideology_id] = row;
            if (state.location != INACTIVE) {
                // Rows are appended in ascending ideology_id, so the active
                // index is already in the sorted order insert_active_state
                // maintains.
                target.active_state_indices.push_back(row);
                target.active_bits[id / 64u] |= 1ull << (id % 64u);
            }
            target.ideas.push_back(state);
        }
    }

    std::vector<PendingTransitionRef> next_pending;
    next_pending.reserve(snapshot.pending_transitions.size());
    for (const RuntimeIdeologyPodTransition &pending :
            snapshot.pending_transitions) {
        if (pending.country_slot >= next_countries.size() ||
                pending.ideology_id < 0 ||
                pending.ideology_id >= static_cast<int32_t>(definition_count)) {
            error = "ideology_pod_snapshot_transition_invalid";
            return false;
        }
        CountryState &country =
            next_countries[static_cast<size_t>(pending.country_slot)];
        if (country.handle == 0) {
            error = "ideology_pod_snapshot_transition_country_inactive";
            return false;
        }
        auto found = country.idea_indices.find(pending.ideology_id);
        if (found == country.idea_indices.end()) {
            // A first transition can be the only state an idea carries, and
            // the dense POD row above then looked empty.
            IdeaState state;
            state.ideology_id = pending.ideology_id;
            const int32_t row = static_cast<int32_t>(country.ideas.size());
            country.idea_indices[pending.ideology_id] = row;
            country.ideas.push_back(state);
            found = country.idea_indices.find(pending.ideology_id);
        }
        IdeaState &state = country.ideas[static_cast<size_t>(found->second)];
        // The worker applies a transition only on the Effect ACK, so the row
        // above is still the pre-transition state. previous_* mirrors it: a
        // rollback on rejection is then a no-op instead of inventing state the
        // POD snapshot never carried. desired_level / desired_location have no
        // facade field; the next snapshot carries them as the applied row.
        state.transition.active = 1;
        state.transition.producer_id = static_cast<int32_t>(pending.producer_id);
        state.transition.command_sequence =
            static_cast<int64_t>(pending.sequence);
        state.transition.previous_level = state.level;
        state.transition.previous_entered_levels = state.entered_levels;
        state.transition.previous_generation = state.generation;
        state.transition.previous_location = state.location;
        state.transition.previous_slot_index = state.slot_index;
        state.transition.entered_on_success = pending.desired_entered_levels;
        state.transition.transaction_ids.assign(
            1, static_cast<int64_t>(pending.intent_id));
        ++country.pending_transition_count;
        next_pending.push_back({country.handle,
            static_cast<int32_t>(pending.country_slot), found->second,
            state.generation});
    }

    std::vector<Receipt> next_receipts;
    next_receipts.reserve(snapshot.receipts.size());
    int64_t next_receipt_id = 1;
    for (const RuntimeIdeologyPodReceipt &source : snapshot.receipts) {
        Receipt receipt;
        receipt.receipt_id = next_receipt_id++;
        receipt.producer_id = static_cast<int32_t>(source.producer_id);
        receipt.sequence = static_cast<int64_t>(source.sequence);
        receipt.status = static_cast<int32_t>(source.status);
        receipt.opcode = static_cast<int32_t>(source.opcode);
        receipt.country_handle = source.country_handle;
        receipt.ideology_id = source.ideology_id;
        receipt.settled_day = source.settled_day;
        if (source.status == RuntimeIdeologyPodReceiptStatus::REJECTED)
            receipt.reason = source.reason_text.empty()
                ? "ideology_worker_rejected" : source.reason_text;
        next_receipts.push_back(receipt);
    }

    _countries = std::move(next_countries);
    _pending_transitions = std::move(next_pending);
    _pending_transition_cursor = 0;
    _receipts = std::move(next_receipts);
    _next_receipt_id = next_receipt_id;
    _producer_high_watermarks.clear();
    for (const RuntimeIdeologyPodProducerWatermark &watermark :
            snapshot.producer_high_watermarks) {
        _producer_high_watermarks[static_cast<int32_t>(watermark.producer_id)] =
            static_cast<int64_t>(watermark.sequence);
    }
    // The worker owns the command queue under ACTIVE. Whatever is staged here
    // was already mirrored across the transport by submit_ideology_commands,
    // so replaying it on the main thread would double-apply it.
    _commands.clear();
    _command_cursor = 0;
    _daily_continuation_day = -1;
    _active_progress_day = snapshot.round_day;
    _active_country_cursor = 0;
    _active_item_cursor = 0;
    _submit_order = std::max(_submit_order, snapshot.next_submit_order);
    _pod_snapshot_generation = snapshot.generation;
    _last_day = snapshot.committed_day;
    _worker_origin = true;
    // The pod owns level/location under worker authority, so this snapshot is
    // the only place where the main thread learns that a card changed tier.
    //
    // Do NOT converge here. Reconciling every card of every country on every
    // write-back is the P1-B defect: one snapshot per generation, and a
    // generation per day, meant the whole world was re-submitted daily. Mark
    // the refresh dirty instead; the sliced pass recomputes only the cards whose
    // signature actually moved.
    mark_instance_refresh_dirty();
    recount_managed_active();
    return true;
}












Dictionary NativeIdeologyRuntime::clear_state(){if(!_configured)return fail("ideology_runtime_unconfigured");reset_runtime_state();_worker_import_pending=false;Dictionary o;o["ok"]=true;return o;}
} // namespace pk
