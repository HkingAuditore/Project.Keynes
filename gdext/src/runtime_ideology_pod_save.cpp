#include "runtime_ideology_pod_save_internal.h"
#include <algorithm>
#include <utility>

namespace pk {

uint64_t RuntimeIdeologyPodAuthority::compute_catalog_hash(
        const RuntimeIdeologyPodCatalog &catalog) {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, catalog.abi_version);
    hash = hash_value(hash, catalog.country_catalog_hash);
    // The offer RNG depends on it, so a peer with a different world seed draws a
    // different card from the same sequence and must be rejected up front.
    hash = hash_value(hash, catalog.world_seed);
    hash = hash_value(hash, catalog.class_hash);
    hash = hash_value(hash, catalog.class_count);
    hash = hash_value(hash, catalog.technology_count);
    hash = hash_value(hash, catalog.research_signal_count);
    hash = hash_value(hash, catalog.gate_count);
    hash = hash_value(hash, catalog.ideology_capacity);
    hash = hash_value(hash, catalog.spirit_capacity);
    hash = hash_value(hash, catalog.ideology_capacity_max);
    hash = hash_value(hash, catalog.spirit_capacity_max);
    hash = hash_value(hash, catalog.offer_cost_q16);
    hash = hash_value(hash, catalog.offer_cost_growth_percent);
    hash = hash_value(hash, catalog.offer_cost_max_q16);
    hash = hash_value(hash, catalog.reroll_cost_percent);
    hash = hash_value(hash, catalog.starting_points_q16);
    hash = hash_value(hash, catalog.point_population_weight_q16);
    hash = hash_value(hash, catalog.point_building_weight_q16);
    hash = hash_value(hash, catalog.point_trade_weight_q16);
    hash = hash_value(hash, catalog.point_gain_cap_q16);
    hash = hash_value(hash, catalog.point_gain_stat_id);
    hash = hash_text_vector(hash, catalog.route_keys);
    hash = hash_value(hash, catalog.point_population_factor_stat_id);
    hash = hash_value(hash, catalog.point_building_factor_stat_id);
    hash = hash_value(hash, catalog.point_trade_factor_stat_id);
    hash = hash_value(hash, catalog.opinion_factor_floor_stat_id);
    hash = hash_text_vector(hash, catalog.school_keys);
    hash = hash_vector(hash, catalog.school_strength_factor_stat_ids);
    hash = hash_value(hash, catalog.understanding_gain_stat_id);
    hash = hash_value(hash, catalog.reroll_cost_stat_id);
    hash = hash_value(hash, catalog.owner_influence_weight);
    hash = hash_value(hash, catalog.funds_per_influence);
    hash = hash_value(hash, catalog.max_commands_per_slice);
    hash = hash_value(hash, catalog.max_transition_commands);
    hash = hash_value(hash, catalog.max_transition_polls_per_slice);
    hash = hash_value(hash, catalog.max_active_visits_per_slice);
    for (const auto &d : catalog.definitions) {
        hash = hash_value(hash, d.acquisition); hash = hash_value(hash, d.rarity_weight);
        hash = hash_value(hash, d.copy_left_programs);
        hash = hash_value(hash, d.copyable);
        hash = hash_value(hash, d.school_index);
        hash = hash_value(hash, d.ideology_cost); hash = hash_value(hash, d.spirit_cost);
        hash = hash_value(hash, d.min_spirit_level); hash = hash_value(hash, d.level_begin);
        hash = hash_value(hash, d.level_count); hash = hash_value(hash, d.technology_begin);
        hash = hash_value(hash, d.technology_count); hash = hash_value(hash, d.signal_begin);
        hash = hash_value(hash, d.signal_count); hash = hash_value(hash, d.gate_begin);
        hash = hash_value(hash, d.gate_count); hash = hash_value(hash, d.stance_begin);
        hash = hash_value(hash, d.stance_count);
        for (int32_t value : d.support_threshold_q16) hash = hash_value(hash, value);
        hash = hash_value(hash, d.exclusion_group_id);
        hash = hash_value(hash, d.era_index);
        hash = hash_value(hash, d.route_mask);
    }
    for (const auto &level : catalog.levels) {
        hash = hash_value(hash, level.threshold_q16);
        hash = hash_value(hash, level.daily_understanding_q16);
        hash = hash_value(hash, level.modifier_begin);
        hash = hash_value(hash, level.modifier_count);
        hash = hash_value(hash, level.on_enter_free_draws);
    }
    hash = hash_vector(hash, catalog.technology_requirements);
    hash = hash_vector(hash, catalog.signal_requirements);
    hash = hash_vector(hash, catalog.gate_requirements);
    // Peers that disagree on the decay curve would draw different cards from the
    // same seed, so the curve is part of the catalog contract.
    hash = hash_vector(hash, catalog.era_decay_bp);
    hash = hash_vector(hash, catalog.era_milestone_technologies);
    // 精进 changes which cards may appear at all, so it belongs in the contract
    // for the same reason the decay curve does.
    hash = hash_value(hash, catalog.refine_weight_bp);
    hash = hash_value(hash, catalog.refine_understanding_q16);
    hash = hash_value(hash, catalog.draw_count);
    for (const auto &stance : catalog.class_stances) {
        hash = hash_value(hash, stance.class_index);
        for (int32_t value : stance.stance_q16) hash = hash_value(hash, value);
        for (int32_t value : stance.critical_min_q16) hash = hash_value(hash, value);
    }
    for (const auto &requirement : catalog.synergy_requirements) {
        hash = hash_value(hash, requirement.ideology_id);
        hash = hash_value(hash, requirement.minimum_level);
        hash = hash_value(hash, requirement.location_mask);
    }
    for (const auto &synergy : catalog.synergies) {
        hash = hash_value(hash, synergy.requirement_begin);
        hash = hash_value(hash, synergy.requirement_count);
        hash = hash_value(hash, synergy.min_count);
        hash = hash_value(hash, synergy.modifier_begin);
        hash = hash_value(hash, synergy.modifier_count);
    }
    hash = hash_vector(hash, catalog.ideology_synergy_offsets);
    hash = hash_vector(hash, catalog.ideology_synergy_ids);
    for (const auto *rows : {&catalog.level_modifiers, &catalog.synergy_modifiers}) {
        hash = hash_value(hash, static_cast<uint64_t>(rows->size()));
        for (const auto &row : *rows) {
            hash = hash_value(hash, row.definition_key_hash);
            hash = hash_value(hash, row.domain);
            hash = hash_value(hash, row.magnitude_q16);
        }
    }
    hash = hash_value(hash, static_cast<uint64_t>(catalog.capacity_unlocks.size()));
    for (const auto &unlock : catalog.capacity_unlocks) {
        hash = hash_value(hash, unlock.technology_id);
        hash = hash_value(hash, unlock.ideology_delta);
        hash = hash_value(hash, unlock.spirit_delta);
    }
    return hash;
}

uint64_t RuntimeIdeologyPodAuthority::compute_state_hash(
        const RuntimeIdeologyPodSnapshot &state) {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, state.catalog_hash); hash = hash_value(hash, state.input_generation);
    hash = hash_value(hash, state.opinion_revision); hash = hash_value(hash, state.generation);
    hash = hash_value(hash, state.committed_day); hash = hash_value(hash, state.round_day);
    hash = hash_value(hash, state.phase); hash = hash_value(hash, state.pending_cursor);
    hash = hash_value(hash, state.command_cursor); hash = hash_value(hash, state.active_country_cursor);
    hash = hash_value(hash, state.active_idea_cursor); hash = hash_value(hash, state.next_submit_order);
    hash = hash_value(hash, static_cast<uint64_t>(state.producer_high_watermarks.size()));
    for (const auto &watermark : state.producer_high_watermarks) {
        hash = hash_value(hash, watermark.producer_id);
        hash = hash_value(hash, watermark.sequence);
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.countries.size()));
    for (const auto &country : state.countries) {
        hash = hash_value(hash, country.handle); hash = hash_value(hash, country.generation);
        hash = hash_value(hash, country.ideology_points_q16); hash = hash_value(hash, country.rng_state);
        hash = hash_value(hash, country.free_draws);
        hash = hash_value(hash, country.points_revision); hash = hash_value(hash, country.baseline_ready);
        hash = hash_value(hash, country.history_count); hash = hash_value(hash, country.history_head);
        hash = hash_value(hash, country.baseline_population); hash = hash_value(hash, country.baseline_buildings);
        hash = hash_value(hash, country.lifetime_points_q16);
    hash = hash_value(hash, country.trade_paid_day);
        hash = hash_value(hash, country.ledger.population_q16); hash = hash_value(hash, country.ledger.building_q16);
        hash = hash_value(hash, country.ledger.trade_q16); hash = hash_value(hash, country.ledger.opinion_factor_q16);
        hash = hash_value(hash, country.ledger.gain_factor_q16); hash = hash_value(hash, country.ledger.gain_q16);
        hash = hash_value(hash, country.ledger.day);
        for (int64_t value : country.history_q16) hash = hash_value(hash, value);
        hash = hash_value(hash, country.draw_sequence); hash = hash_value(hash, country.ideology_slots_used);
        hash = hash_value(hash, country.spirit_slots_used); hash = hash_value(hash, country.unlocked_era);
        hash = hash_value(hash, country.opinion_revision);
        hash = hash_value(hash, country.offer.generation); hash = hash_value(hash, country.offer.active);
        hash = hash_value(hash, country.offer.choice_count);
        for (int32_t id : country.offer.ideology_ids) hash = hash_value(hash, id);
        hash = hash_vector(hash, country.known_bits); hash = hash_vector(hash, country.banned_bits);
        hash = hash_vector(hash, country.gate_bits);
        hash = hash_vector(hash, country.synergy_bits);
        hash = hash_vector(hash, country.active_idea_ids);
        hash = hash_value(hash, static_cast<uint64_t>(country.ideas.size()));
        for (const auto &idea : country.ideas) {
            hash = hash_value(hash, idea.understanding_q16); hash = hash_value(hash, idea.level);
            hash = hash_value(hash, idea.entered_levels); hash = hash_value(hash, idea.generation);
            hash = hash_value(hash, idea.location); hash = hash_value(hash, idea.slot_index);
        }
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.commands.size()));
    for (const auto &command : state.commands) {
        hash = hash_value(hash, command.request_id); hash = hash_value(hash, command.source_priority);
        hash = hash_value(hash, command.producer_id); hash = hash_value(hash, command.sequence);
        hash = hash_value(hash, command.submit_order); hash = hash_value(hash, command.requested_day);
        hash = hash_value(hash, command.effective_day); hash = hash_value(hash, command.opcode);
        hash = hash_value(hash, command.country_handle); hash = hash_value(hash, command.ideology_id);
        hash = hash_value(hash, command.value_q16); hash = hash_value(hash, command.offer_generation);
        hash = hash_value(hash, command.choice_index); hash = hash_value(hash, command.gate_id);
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.pending_transitions.size()));
    for (const auto &transition : state.pending_transitions) {
        hash = hash_value(hash, transition.intent_id); hash = hash_value(hash, transition.request_id);
        hash = hash_value(hash, transition.producer_id); hash = hash_value(hash, transition.sequence);
        hash = hash_value(hash, transition.effective_day); hash = hash_value(hash, transition.country_slot);
        hash = hash_value(hash, transition.country_generation); hash = hash_value(hash, transition.ideology_id);
        hash = hash_value(hash, transition.desired_level); hash = hash_value(hash, transition.desired_entered_levels);
        hash = hash_value(hash, transition.desired_location);
        hash = hash_value(hash, transition.desired_slot_index);
        hash = hash_value(hash, transition.intent_emitted);
        hash = hash_value(hash, transition.previous_entered_levels);
        hash = hash_vector(hash, transition.desired_synergy_bits);
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.receipts.size()));
    for (const auto &receipt : state.receipts) {
        hash = hash_value(hash, receipt.request_id); hash = hash_value(hash, receipt.producer_id);
        hash = hash_value(hash, receipt.sequence); hash = hash_value(hash, receipt.status);
        hash = hash_value(hash, receipt.opcode); hash = hash_value(hash, receipt.country_handle);
        hash = hash_value(hash, receipt.ideology_id); hash = hash_value(hash, receipt.settled_day);
        hash = hash_value(hash, receipt.reason_code);
    }
    return hash;
}

void RuntimeIdeologyPodAuthority::serialize(std::vector<uint8_t> &out) const {
    serialize_snapshot(_current, out);
}

// Derived per-country indices + the state hash, for a snapshot built OUTSIDE this
// POD (the main-thread runtime exporting the state a restore installed). The import
// path must run this before `serialize_snapshot`: `active_idea_ids` takes part in
// `compute_state_hash` and `restore` recomputes that hash, so a snapshot that skipped
// it is refused as `ideology_pod_save_state_hash_failed` -- correctly, because the
// bytes would otherwise describe a state this POD can never hold.
void RuntimeIdeologyPodAuthority::canonicalize_import(
        RuntimeIdeologyPodSnapshot &state) {
    for (auto &country : state.countries) rebuild_active_idea_ids(country);
    state.state_hash = compute_state_hash(state);
}

void RuntimeIdeologyPodAuthority::serialize_snapshot(
        const RuntimeIdeologyPodSnapshot &state, std::vector<uint8_t> &out) {
    out.clear(); out.reserve(4096);
    append_le<uint32_t>(out, SAVE_MAGIC); append_le<uint32_t>(out, RUNTIME_IDEOLOGY_POD_ABI_VERSION);
    append_le<uint64_t>(out, state.catalog_hash); append_le<uint64_t>(out, state.state_hash);
    append_le<uint64_t>(out, state.input_generation); append_le<uint64_t>(out, state.opinion_revision);
    append_le<uint64_t>(out, state.generation); append_le<int64_t>(out, state.committed_day);
    append_le<int64_t>(out, state.round_day); append_le(out, state.phase);
    append_le<uint32_t>(out, state.pending_cursor); append_le<uint32_t>(out, state.command_cursor);
    append_le<uint32_t>(out, state.active_country_cursor); append_le<uint32_t>(out, state.active_idea_cursor);
    append_le<uint64_t>(out, state.next_submit_order);
    append_le<uint32_t>(out, static_cast<uint32_t>(state.producer_high_watermarks.size()));
    for (const auto &watermark : state.producer_high_watermarks) {
        append_le<uint32_t>(out, watermark.producer_id);
        append_le<uint64_t>(out, watermark.sequence);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.countries.size()));
    for (const auto &country : state.countries) {
        append_le<uint64_t>(out, country.handle); append_le<uint32_t>(out, country.generation);
        append_le<int64_t>(out, country.ideology_points_q16); append_le<uint64_t>(out, country.rng_state);
        append_le<uint64_t>(out, country.points_revision); append_le<uint8_t>(out, country.baseline_ready);
        append_le<uint8_t>(out, country.history_count); append_le<uint8_t>(out, country.history_head);
        append_le<int64_t>(out, country.baseline_population); append_le<int64_t>(out, country.baseline_buildings);
        append_le<int64_t>(out, country.lifetime_points_q16);
        // Ring/day markers that gate the trade flow. Omitting one would let a
        // restored session pay trade again for a day it already paid.
        append_le<int64_t>(out, country.trade_paid_day);
        append_le<int64_t>(out, country.ledger.population_q16); append_le<int64_t>(out, country.ledger.building_q16);
        append_le<int64_t>(out, country.ledger.trade_q16); append_le<int32_t>(out, country.ledger.opinion_factor_q16);
        append_le<int32_t>(out, country.ledger.gain_factor_q16); append_le<int64_t>(out, country.ledger.gain_q16);
        append_le<int64_t>(out, country.ledger.day);
        for (int64_t value : country.history_q16) append_le<int64_t>(out, value);
        append_le<uint64_t>(out, country.draw_sequence);
        append_le<uint16_t>(out, country.free_draws);
        append_le<int32_t>(out, country.ideology_slots_used);
        append_le<int32_t>(out, country.spirit_slots_used); append_le<int32_t>(out, country.unlocked_era);
        append_le<uint64_t>(out, country.opinion_revision);
        append_le<uint32_t>(out, country.offer.generation); for (int32_t id : country.offer.ideology_ids) append_le<int32_t>(out, id);
        append_le<uint8_t>(out, country.offer.active); append_le<uint8_t>(out, country.offer.choice_count);
        append_vector(out, country.known_bits); append_vector(out, country.banned_bits);
        append_vector(out, country.gate_bits); append_vector(out, country.synergy_bits);
        append_le<uint32_t>(out, static_cast<uint32_t>(country.ideas.size()));
        for (const auto &idea : country.ideas) {
            append_le<int64_t>(out, idea.understanding_q16); append_le<int32_t>(out, idea.level);
            append_le<uint64_t>(out, idea.entered_levels); append_le<uint32_t>(out, idea.generation);
            append_le(out, idea.location); append_le<uint8_t>(out, idea.slot_index);
        }
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.commands.size()));
    for (const auto &command : state.commands) {
        append_le<uint64_t>(out, command.request_id); append_le<int32_t>(out, command.source_priority);
        append_le<uint32_t>(out, command.producer_id); append_le<uint64_t>(out, command.sequence);
        append_le<uint64_t>(out, command.submit_order); append_le<int64_t>(out, command.requested_day);
        append_le<int64_t>(out, command.effective_day); append_le(out, command.opcode);
        append_le<uint64_t>(out, command.country_handle); append_le<int32_t>(out, command.ideology_id);
        append_le<int64_t>(out, command.value_q16); append_le<uint32_t>(out, command.offer_generation);
        append_le<int32_t>(out, command.choice_index); append_le<int32_t>(out, command.gate_id);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.pending_transitions.size()));
    for (const auto &transition : state.pending_transitions) {
        append_le<uint64_t>(out, transition.intent_id); append_le<uint64_t>(out, transition.request_id);
        append_le<uint32_t>(out, transition.producer_id); append_le<uint64_t>(out, transition.sequence);
        append_le<int64_t>(out, transition.effective_day); append_le<uint32_t>(out, transition.country_slot);
        append_le<uint32_t>(out, transition.country_generation); append_le<int32_t>(out, transition.ideology_id);
        append_le<int32_t>(out, transition.desired_level); append_le<uint64_t>(out, transition.desired_entered_levels);
        append_le(out, transition.desired_location);
        append_le<uint8_t>(out, transition.desired_slot_index);
        append_le<uint8_t>(out, transition.intent_emitted);
        append_le<uint64_t>(out, transition.previous_entered_levels);
        append_vector(out, transition.desired_synergy_bits);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.receipts.size()));
    for (const auto &receipt : state.receipts) {
        append_le<uint64_t>(out, receipt.request_id); append_le<uint32_t>(out, receipt.producer_id);
        append_le<uint64_t>(out, receipt.sequence); append_le(out, receipt.status); append_le(out, receipt.opcode);
        append_le<uint64_t>(out, receipt.country_handle); append_le<int32_t>(out, receipt.ideology_id);
        append_le<int64_t>(out, receipt.settled_day); append_le<uint32_t>(out, receipt.reason_code);
    }
    append_le<uint32_t>(out, SAVE_END);
    append_le<uint64_t>(out, hash_bytes(FNV_OFFSET, out.data(), out.size()));
}

bool RuntimeIdeologyPodAuthority::restore(
        const uint8_t *data, size_t size, std::string &error) {
    error.clear();
    if (!_configured || data == nullptr || size < 64u || size > MAX_SAVE_BYTES) { error = "ideology_pod_save_invalid"; return false; }
    uint64_t encoded_checksum = 0; size_t checksum_cursor = size - sizeof(uint64_t);
    if (!read_le(data, size, checksum_cursor, encoded_checksum) ||
        hash_bytes(FNV_OFFSET, data, size - sizeof(uint64_t)) != encoded_checksum) { error = "ideology_pod_save_checksum_failed"; return false; }
    const size_t end = size - sizeof(uint64_t); size_t cursor = 0;
    uint32_t magic = 0, abi = 0; uint64_t catalog_hash = 0, saved_hash = 0;
    RuntimeIdeologyPodSnapshot state;
    if (!read_le(data,end,cursor,magic) || !read_le(data,end,cursor,abi) ||
        !read_le(data,end,cursor,catalog_hash) || !read_le(data,end,cursor,saved_hash) ||
        !read_le(data,end,cursor,state.input_generation) || !read_le(data,end,cursor,state.opinion_revision) ||
        !read_le(data,end,cursor,state.generation) || !read_le(data,end,cursor,state.committed_day) ||
        !read_le(data,end,cursor,state.round_day) || !read_le(data,end,cursor,state.phase) ||
        !read_le(data,end,cursor,state.pending_cursor) || !read_le(data,end,cursor,state.command_cursor) ||
        !read_le(data,end,cursor,state.active_country_cursor) || !read_le(data,end,cursor,state.active_idea_cursor) ||
        !read_le(data,end,cursor,state.next_submit_order) || magic != SAVE_MAGIC ||
        abi != RUNTIME_IDEOLOGY_POD_ABI_VERSION || catalog_hash != _catalog.catalog_hash) { error = "ideology_pod_save_header_invalid"; return false; }
    state.catalog_hash = catalog_hash;
    uint32_t count = 0;
    if (!read_le(data, end, cursor, count) ||
        count > RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) {
        error = "ideology_pod_producer_watermark_count_invalid";
        return false;
    }
    state.producer_high_watermarks.resize(count);
    uint32_t previous_producer = 0;
    for (auto &watermark : state.producer_high_watermarks) {
        if (!read_le(data, end, cursor, watermark.producer_id) ||
            !read_le(data, end, cursor, watermark.sequence) ||
            watermark.producer_id == 0 ||
            watermark.producer_id <= previous_producer) {
            error = "ideology_pod_producer_watermark_invalid";
            return false;
        }
        previous_producer = watermark.producer_id;
    }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_COUNTRIES) { error = "ideology_pod_country_count_invalid"; return false; }
    state.countries.resize(count);
    const uint32_t bit_limit = static_cast<uint32_t>((std::max(_catalog.definitions.size(), _catalog.synergies.size()) + 63u) / 64u);
    for (auto &country : state.countries) {
        if (!read_le(data,end,cursor,country.handle) || !read_le(data,end,cursor,country.generation) ||
            !read_le(data,end,cursor,country.ideology_points_q16) || !read_le(data,end,cursor,country.rng_state) ||
            !read_le(data,end,cursor,country.points_revision) || !read_le(data,end,cursor,country.baseline_ready) ||
            !read_le(data,end,cursor,country.history_count) || !read_le(data,end,cursor,country.history_head) ||
            country.history_count > RUNTIME_IDEOLOGY_POD_HISTORY || country.history_head >= RUNTIME_IDEOLOGY_POD_HISTORY ||
            !read_le(data,end,cursor,country.baseline_population) || !read_le(data,end,cursor,country.baseline_buildings) ||
            !read_le(data,end,cursor,country.lifetime_points_q16) ||
            !read_le(data,end,cursor,country.trade_paid_day) ||
            !read_le(data,end,cursor,country.ledger.population_q16) || !read_le(data,end,cursor,country.ledger.building_q16) ||
            !read_le(data,end,cursor,country.ledger.trade_q16) || !read_le(data,end,cursor,country.ledger.opinion_factor_q16) ||
            !read_le(data,end,cursor,country.ledger.gain_factor_q16) || !read_le(data,end,cursor,country.ledger.gain_q16) ||
            !read_le(data,end,cursor,country.ledger.day) ||
            !std::all_of(country.history_q16.begin(), country.history_q16.end(), [&](int64_t &value) { return read_le(data,end,cursor,value); }) ||
            !read_le(data,end,cursor,country.draw_sequence) ||
            !read_le(data,end,cursor,country.free_draws) ||
            !read_le(data,end,cursor,country.ideology_slots_used) ||
            !read_le(data,end,cursor,country.spirit_slots_used) || !read_le(data,end,cursor,country.unlocked_era) ||
            !read_le(data,end,cursor,country.opinion_revision) ||
            !read_le(data,end,cursor,country.offer.generation) ||
            // The full capacity, always: the save writes a fixed-size row so a
            // build with a different capacity is rejected by the ABI version
            // instead of silently consuming the next field.
            !read_le(data,end,cursor,country.offer.ideology_ids[0]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[1]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[2]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[3]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[4]) ||
            !read_le(data,end,cursor,country.offer.active) ||
            !read_le(data,end,cursor,country.offer.choice_count) ||
            country.offer.choice_count > IDEOLOGY_OFFER_CHOICE_CAPACITY ||
            !read_vector(data,end,cursor,country.known_bits,bit_limit) ||
            !read_vector(data,end,cursor,country.banned_bits,bit_limit) ||
            !read_vector(data,end,cursor,country.gate_bits,static_cast<uint32_t>((_catalog.gate_count + 63u) / 64u)) ||
            !read_vector(data,end,cursor,country.synergy_bits,bit_limit) ||
            !read_le(data,end,cursor,count) || count != _catalog.definitions.size()) { error = "ideology_pod_country_truncated"; return false; }
        country.ideas.resize(count);
        for (auto &idea : country.ideas)
            if (!read_le(data,end,cursor,idea.understanding_q16) || !read_le(data,end,cursor,idea.level) ||
                !read_le(data,end,cursor,idea.entered_levels) || !read_le(data,end,cursor,idea.generation) ||
                !read_le(data,end,cursor,idea.location) ||
                !read_le(data,end,cursor,idea.slot_index) ||
                idea.level < -1 || idea.level >= 64) {
                error = "ideology_pod_idea_truncated"; return false;
            }
        if (country.unlocked_era < 0 || country.unlocked_era > kMaxEraIndex) { error = "ideology_pod_era_invalid"; return false; }
        rebuild_active_idea_ids(country);
    }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) { error = "ideology_pod_command_count_invalid"; return false; }
    state.commands.resize(count);
    for (auto &command : state.commands) {
        if (!read_le(data,end,cursor,command.request_id) || !read_le(data,end,cursor,command.source_priority) ||
            !read_le(data,end,cursor,command.producer_id) || !read_le(data,end,cursor,command.sequence) ||
            !read_le(data,end,cursor,command.submit_order) || !read_le(data,end,cursor,command.requested_day) ||
            !read_le(data,end,cursor,command.effective_day) || !read_le(data,end,cursor,command.opcode) ||
            !read_le(data,end,cursor,command.country_handle) || !read_le(data,end,cursor,command.ideology_id) ||
            !read_le(data,end,cursor,command.value_q16) || !read_le(data,end,cursor,command.offer_generation) ||
            !read_le(data,end,cursor,command.choice_index) || !read_le(data,end,cursor,command.gate_id) ||
            !validate_command(command, error)) return false;
    }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_TRANSITIONS) { error = "ideology_pod_transition_count_invalid"; return false; }
    state.pending_transitions.resize(count);
    for (auto &transition : state.pending_transitions)
        if (!read_le(data,end,cursor,transition.intent_id) || !read_le(data,end,cursor,transition.request_id) ||
            !read_le(data,end,cursor,transition.producer_id) || !read_le(data,end,cursor,transition.sequence) ||
            !read_le(data,end,cursor,transition.effective_day) || !read_le(data,end,cursor,transition.country_slot) ||
            !read_le(data,end,cursor,transition.country_generation) || !read_le(data,end,cursor,transition.ideology_id) ||
            !read_le(data,end,cursor,transition.desired_level) || !read_le(data,end,cursor,transition.desired_entered_levels) ||
            !read_le(data,end,cursor,transition.desired_location) ||
            !read_le(data,end,cursor,transition.desired_slot_index) ||
            !read_le(data,end,cursor,transition.intent_emitted) ||
            !read_le(data,end,cursor,transition.previous_entered_levels) ||
            !read_vector(data,end,cursor,transition.desired_synergy_bits,bit_limit) || transition.intent_id == 0 ||
            transition.country_slot >= state.countries.size() || transition.ideology_id < 0 ||
            transition.ideology_id >= static_cast<int32_t>(_catalog.definitions.size())) { error = "ideology_pod_transition_truncated"; return false; }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) { error = "ideology_pod_receipt_count_invalid"; return false; }
    state.receipts.resize(count);
    for (auto &receipt : state.receipts)
        if (!read_le(data,end,cursor,receipt.request_id) || !read_le(data,end,cursor,receipt.producer_id) ||
            !read_le(data,end,cursor,receipt.sequence) || !read_le(data,end,cursor,receipt.status) ||
            !read_le(data,end,cursor,receipt.opcode) || !read_le(data,end,cursor,receipt.country_handle) ||
            !read_le(data,end,cursor,receipt.ideology_id) || !read_le(data,end,cursor,receipt.settled_day) ||
            !read_le(data,end,cursor,receipt.reason_code)) { error = "ideology_pod_receipt_truncated"; return false; }
    uint32_t end_marker = 0;
    if (!read_le(data,end,cursor,end_marker) || end_marker != SAVE_END || cursor != end) { error = "ideology_pod_save_trailing_bytes"; return false; }
    if (state.command_cursor > state.commands.size() || state.pending_cursor > state.pending_transitions.size() ||
        state.active_country_cursor > state.countries.size()) { error = "ideology_pod_cursor_invalid"; return false; }
    state.state_hash = compute_state_hash(state);
    if (state.state_hash != saved_hash) { error = "ideology_pod_save_state_hash_failed"; return false; }
    _current = std::move(state); _planned = _current; _plan_ready = false;
    // A restore MEANS "your authoritative state is now this" -- whether the bytes came
    // from this POD's own save or from the main-thread runtime's import. Its committed
    // day is now the FLOOR of this worker's calendar: every day at or below it is
    // already settled by the imported state and must plan as a no-op instead of
    // failing `ideology_day_not_monotonic` (see `plan_day`).
    _import_supersedes_calendar = true;
    return true;
}


} // namespace pk
