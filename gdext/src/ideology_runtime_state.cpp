#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>


namespace pk {

using namespace godot;

bool NativeIdeologyRuntime::validate_country(uint64_t handle, int32_t &slot) const { slot=static_cast<int32_t>(handle & 0xffffffffULL); return _country_runtime!=nullptr && handle!=0 && country_api::valid_handle(*_country_runtime, static_cast<int64_t>(handle)); }
NativeIdeologyRuntime::CountryState *NativeIdeologyRuntime::country_state_for(
        uint64_t handle, bool create) {
    int32_t slot = -1;
    if (!validate_country(handle, slot)) return nullptr;
    if (slot >= static_cast<int32_t>(_countries.size())) {
        if (!create) return nullptr;
        _countries.resize(static_cast<size_t>(slot + 1));
    }
    CountryState &state = _countries[static_cast<size_t>(slot)];
    if (state.handle != handle) {
        if (!create && state.handle == 0) return nullptr;
        init_country_state(state, handle);
    }
    return &state;
}
void NativeIdeologyRuntime::init_country_state(CountryState &state,
        uint64_t handle) const {
    state = CountryState{};
    state.handle = handle;
    state.ideology_points_q16 = _starting_points_q16;
    // Seed from the handle and the SHARED world seed only. The worker uses
    // `runtime_ideology_country_rng_seed()` with the same pair; seeding from
    // `_catalog_hash` here made `rng_state` differ by construction, and seeding
    // from the handle alone made every session of a map draw the same sequence.
    state.rng_state = runtime_ideology_country_rng_seed(handle, _world_seed);
    state.known_bits.assign(static_cast<size_t>(_idea_words), 0);
    state.banned_bits.assign(static_cast<size_t>(_idea_words), 0);
    state.gate_bits.assign(static_cast<size_t>(_gate_words), 0);
    state.active_bits.assign(static_cast<size_t>(_idea_words), 0);
    state.active_synergy_bits.assign((_synergies.size() + 63U) / 64U, 0);
}
const NativeIdeologyRuntime::CountryState *NativeIdeologyRuntime::country_state_for(uint64_t handle) const { const int32_t slot=static_cast<int32_t>(handle & 0xffffffffULL); if(slot<0 || slot>=static_cast<int32_t>(_countries.size())) return nullptr; const CountryState &state=_countries[slot]; return state.handle==handle?&state:nullptr; }
NativeIdeologyRuntime::IdeaState *NativeIdeologyRuntime::idea_state_for(CountryState &country,int32_t id,bool create) { auto found=country.idea_indices.find(id); if(found!=country.idea_indices.end()) return &country.ideas[found->second]; if(!create || id<0 || id>=static_cast<int32_t>(_definitions.size())) return nullptr; const int32_t index=static_cast<int32_t>(country.ideas.size()); country.ideas.push_back({id,0,-1,0,1,INACTIVE}); country.idea_indices[id]=index; return &country.ideas.back(); }
const NativeIdeologyRuntime::IdeaState *NativeIdeologyRuntime::idea_state_for(const CountryState &country,int32_t id) const { auto found=country.idea_indices.find(id); return found==country.idea_indices.end()?nullptr:&country.ideas[found->second]; }
bool NativeIdeologyRuntime::known(const CountryState &c,int32_t id) const { return id>=0 && id<static_cast<int32_t>(_definitions.size()) && (c.known_bits[id/64]&(1ULL<<(id%64)))!=0; }
void NativeIdeologyRuntime::set_known(CountryState &c,int32_t id) { c.known_bits[id/64]|=(1ULL<<(id%64)); }
bool NativeIdeologyRuntime::gate(const CountryState &c,int32_t id) const { return id>=0 && id<_gate_count && (c.gate_bits[id/64]&(1ULL<<(id%64)))!=0; }
void NativeIdeologyRuntime::set_gate(CountryState &c,int32_t id,bool value) { if(id<0||id>=_gate_count)return; const uint64_t mask=1ULL<<(id%64); if(value)c.gate_bits[id/64]|=mask; else c.gate_bits[id/64]&=~mask; }
bool NativeIdeologyRuntime::requirements_met(const CountryState &country,int32_t slot,const Definition &d) const { if(_country_runtime==nullptr)return false; for(int32_t i=0;i<d.technology_requirement_count;++i) if(!country_api::has_technology(*_country_runtime, slot,_technology_requirements[d.technology_requirement_begin+i])) return false; for(int32_t i=0;i<d.signal_requirement_count;++i) if(!country_api::has_research_signal(*_country_runtime, slot,_signal_requirements[d.signal_requirement_begin+i])) return false; for(int32_t i=0;i<d.gate_requirement_count;++i) if(!gate(country,_gate_requirements[d.gate_requirement_begin+i])) return false; return true; }

NativeIdeologyRuntime::SupportResult NativeIdeologyRuntime::evaluate_support(
        CountryState &country, int32_t ideology_id,
        SupportDirection direction) {
    SupportResult result;
    if (ideology_id < 0 ||
            ideology_id >= static_cast<int32_t>(_definitions.size()) ||
            direction < SUPPORT_ADOPT || direction > SUPPORT_PROMOTE)
        return result;
    const Definition &definition =
        _definitions[static_cast<size_t>(ideology_id)];
    result.threshold_q16 =
        definition.support_threshold_q16[static_cast<size_t>(direction)];
    ++_support_evaluations;
    if (definition.stance_count == 0) {
        result.available = true;
        result.allowed = true;
        return result;
    }
    if (_economy_runtime == nullptr) return result;
    const EconomyApi::CountryClassOpinionSnapshot &snapshot =
        economy_api::country_class_opinion_snapshot(*_economy_runtime);
    ++_class_snapshot_reads;
    const int32_t country_slot =
        static_cast<int32_t>(country.handle & 0xffffffffULL);
    if (snapshot.revision == 0 ||
            snapshot.class_hash != _political_class_hash ||
            snapshot.class_count != _political_class_count ||
            country_slot < 0 || country_slot >= snapshot.country_count ||
            country_slot >=
                static_cast<int32_t>(snapshot.country_handles.size()) ||
            snapshot.country_handles[static_cast<size_t>(country_slot)] !=
                country.handle)
        return result;
    result.revision = snapshot.revision;
    if (country.opinion_revision != snapshot.revision ||
            country.class_influence.size() !=
                static_cast<size_t>(_political_class_count)) {
        country.class_influence.assign(
            static_cast<size_t>(_political_class_count), 0);
        const size_t row_begin = static_cast<size_t>(country_slot) *
            static_cast<size_t>(_political_class_count);
        for (int32_t class_index = 0;
                class_index < _political_class_count; ++class_index) {
            const size_t row = row_begin +
                static_cast<size_t>(class_index);
            if (row >= snapshot.population.size() ||
                    row >= snapshot.funds.size() ||
                    row >= snapshot.owner_employed.size())
                continue;
            int64_t influence =
                std::max<int64_t>(0, snapshot.population[row]);
            influence = add_sat(influence, mul_sat(
                std::max<int64_t>(0, snapshot.owner_employed[row]),
                _opinion_owner_influence_weight));
            influence = add_sat(influence,
                std::max<int64_t>(0, snapshot.funds[row]) /
                    _opinion_funds_per_influence);
            country.class_influence[static_cast<size_t>(class_index)] =
                std::max<int64_t>(0, influence);
        }
        country.opinion_revision = snapshot.revision;
    }
    int64_t total_influence = 0;
    for (const int64_t influence : country.class_influence)
        total_influence = add_sat(total_influence,
            std::max<int64_t>(0, influence));
    if (total_influence <= 0) return result;
    int64_t weighted_support = 0;
    for (int32_t row = definition.stance_begin;
            row < definition.stance_begin + definition.stance_count; ++row) {
        const ClassStance &stance =
            _class_stances[static_cast<size_t>(row)];
        const int64_t influence =
            country.class_influence[static_cast<size_t>(
                stance.class_index)];
        const int32_t stance_value =
            stance.stance_q16[static_cast<size_t>(direction)];
        weighted_support = add_sat(weighted_support,
            mul_sat(influence, stance_value));
        const int32_t critical_min =
            stance.critical_min_q16[static_cast<size_t>(direction)];
        if (critical_min >= -65536 &&
                (influence <= 0 || stance_value < critical_min) &&
                result.blocking_class < 0)
            result.blocking_class = stance.class_index;
    }
    result.support_q16 = static_cast<int32_t>(std::clamp<int64_t>(
        weighted_support / total_influence, -Q16_ONE, Q16_ONE));
    result.available = true;
    result.allowed = result.support_q16 >= result.threshold_q16 &&
        result.blocking_class < 0;
    return result;
}

bool NativeIdeologyRuntime::support_gate(CountryState &country,
        int32_t ideology_id, SupportDirection direction,
        std::string &error) {
    const SupportResult result =
        evaluate_support(country, ideology_id, direction);
    if (!result.available) {
        error = "ideology_class_opinion_unavailable";
        return false;
    }
    if (result.blocking_class >= 0) {
        error = "ideology_critical_class_blocked";
        return false;
    }
    if (!result.allowed) {
        error = "ideology_support_threshold_not_met";
        return false;
    }
    return true;
}

bool NativeIdeologyRuntime::exclusion_allows(
        const CountryState &country, int32_t ideology_id,
        std::string &error) const {
    const int32_t group =
        _definitions[static_cast<size_t>(ideology_id)].exclusion_group_id;
    if (group < 0) return true;
    for (const int32_t idea_slot : country.active_state_indices) {
        if (idea_slot < 0 ||
                idea_slot >= static_cast<int32_t>(country.ideas.size()))
            continue;
        const IdeaState &other =
            country.ideas[static_cast<size_t>(idea_slot)];
        if (other.ideology_id != ideology_id &&
                other.location != INACTIVE &&
                _definitions[static_cast<size_t>(other.ideology_id)]
                    .exclusion_group_id == group) {
            error = "ideology_exclusion_group_conflict";
            return false;
        }
    }
    return true;
}

bool NativeIdeologyRuntime::synergy_active(
        const CountryState &country, int32_t synergy_id) const {
    return synergy_id >= 0 &&
        synergy_id < static_cast<int32_t>(_synergies.size()) &&
        static_cast<size_t>(synergy_id / 64) <
            country.active_synergy_bits.size() &&
        (country.active_synergy_bits[static_cast<size_t>(synergy_id / 64)] &
         (1ULL << (synergy_id % 64))) != 0;
}

void NativeIdeologyRuntime::set_synergy_active(CountryState &country,
        int32_t synergy_id, bool active) {
    if (synergy_id < 0 ||
            synergy_id >= static_cast<int32_t>(_synergies.size()))
        return;
    if (country.active_synergy_bits.size() <
            (_synergies.size() + 63U) / 64U)
        country.active_synergy_bits.resize(
            (_synergies.size() + 63U) / 64U, 0);
    uint64_t &word = country.active_synergy_bits[
        static_cast<size_t>(synergy_id / 64)];
    const uint64_t mask = 1ULL << (synergy_id % 64);
    const bool previous = (word & mask) != 0;
    if (active) word |= mask;
    else word &= ~mask;
    if (previous != active)
        mark_instance_refresh_dirty();
}

bool NativeIdeologyRuntime::synergy_requirements_met(
        const CountryState &country, int32_t synergy_id) const {
    if (synergy_id < 0 ||
            synergy_id >= static_cast<int32_t>(_synergies.size()))
        return false;
    const Synergy &synergy =
        _synergies[static_cast<size_t>(synergy_id)];
    const int32_t needed = synergy.min_count > 0
        ? synergy.min_count : synergy.requirement_count;
    int32_t held = 0;
    for (int32_t row = synergy.requirement_begin;
            row < synergy.requirement_begin + synergy.requirement_count;
            ++row) {
        const SynergyRequirement &requirement =
            _synergy_requirements[static_cast<size_t>(row)];
        const IdeaState *state =
            idea_state_for(country, requirement.ideology_id);
        if (state != nullptr &&
                state->level >= requirement.minimum_level &&
                (requirement.location_mask &
                 (1U << state->location)) != 0) {
            if (++held >= needed) return true;
        }
    }
    return held >= needed;
}

bool NativeIdeologyRuntime::collect_affected_synergies(
        CountryState &country, int32_t ideology_id, int64_t day,
        IdeaState::Transition &transition,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (ideology_id < 0 ||
            ideology_id + 1 >=
                static_cast<int32_t>(_ideology_synergy_offsets.size()))
        return true;
    if (++_synergy_candidate_generation == 0) {
        std::fill(_synergy_candidate_stamps.begin(),
            _synergy_candidate_stamps.end(), 0);
        _synergy_candidate_generation = 1;
    }
    _synergy_candidate_scratch.clear();
    for (int32_t cursor =
            _ideology_synergy_offsets[static_cast<size_t>(ideology_id)];
            cursor < _ideology_synergy_offsets[
                static_cast<size_t>(ideology_id + 1)]; ++cursor) {
        const int32_t synergy_id =
            _ideology_synergy_ids[static_cast<size_t>(cursor)];
        if (_synergy_candidate_stamps[static_cast<size_t>(synergy_id)] ==
                _synergy_candidate_generation)
            continue;
        _synergy_candidate_stamps[static_cast<size_t>(synergy_id)] =
            _synergy_candidate_generation;
        _synergy_candidate_scratch.push_back(synergy_id);
    }
    std::sort(_synergy_candidate_scratch.begin(),
        _synergy_candidate_scratch.end());
    for (const int32_t synergy_id : _synergy_candidate_scratch) {
        ++_synergy_candidates_visited;
        const bool previous = synergy_active(country, synergy_id);
        const bool next = synergy_requirements_met(country, synergy_id);
        if (previous == next) continue;
        const Synergy &synergy =
            _synergies[static_cast<size_t>(synergy_id)];
        if (commands.size() + static_cast<size_t>(synergy.effect_count) >
                static_cast<size_t>(_max_transition_commands)) {
            error = "ideology_transition_command_limit_exceeded";
            return false;
        }
        transition.changed_synergy_ids.push_back(synergy_id);
        transition.previous_synergy_active.push_back(previous ? 1 : 0);
        set_synergy_active(country, synergy_id, next);
        for (int32_t effect = 0; effect < synergy.effect_count; ++effect) {
            const int32_t effect_index = synergy.effect_begin + effect;
            const EffectTemplate &templ =
                _synergy_templates[static_cast<size_t>(effect_index)];
            uint64_t hash = 1469598103934665603ULL;
            hash = mixv(hash, country.handle);
            hash = mixv(hash, synergy_id);
            hash = mixv(hash, effect_index);
            EffectRuntime::ExternalEffectCommandPod command;
            command.effect_id = static_cast<int64_t>(
                hash & 0x7fffffffffffffffULL);
            command.source_id = static_cast<int64_t>(
                (0x7fffULL << 48U) |
                (static_cast<uint64_t>(synergy_id + 1) << 16U) |
                static_cast<uint32_t>(effect + 1));
            command.program_key = "ideology.command";
            // The row this command produces must be keyed by `source_id` above, NOT by
            // the per-fire Effect instance. `source_id` is stable per (synergy, effect),
            // so the later deactivation's REMOVE resolves to the same row. With an
            // instance-derived key the removal could never match and the row leaked
            // permanently (measured: factors stayed at 0.95/1.03 after the bond died).
            command.stable_source_identity = true;
            command.fire_sequence = static_cast<uint64_t>(day) ^
                (next ? 0ULL : (1ULL << 63U));
            command.action = templ.action;
            command.domain = templ.domain;
            command.opcode = next ? templ.opcode : 2;
            command.resolved_value = templ.value_q16;
            command.duration_days = templ.duration_days;
            command.stacks = templ.stacks;
            command.command_key = templ.command_key;
            command.definition_key = templ.definition_key;
            command.payload = templ.payload;
            commands.push_back(std::move(command));
        }
    }
    return true;
}

void NativeIdeologyRuntime::rollback_synergies(
        CountryState &country,
        const IdeaState::Transition &transition) {
    const size_t count = std::min(transition.changed_synergy_ids.size(),
        transition.previous_synergy_active.size());
    for (size_t index = 0; index < count; ++index)
        set_synergy_active(country,
            transition.changed_synergy_ids[index],
            transition.previous_synergy_active[index] != 0);
}

void NativeIdeologyRuntime::rebuild_synergies(CountryState &country) {
    country.active_synergy_bits.assign(
        (_synergies.size() + 63U) / 64U, 0);
    for (int32_t synergy_id = 0;
            synergy_id < static_cast<int32_t>(_synergies.size());
            ++synergy_id)
        if (synergy_requirements_met(country, synergy_id))
            set_synergy_active(country, synergy_id, true);
}

int32_t NativeIdeologyRuntime::ideology_slot_cost(const CountryState &country) const {
    return country.ideology_slots_used;
}

int32_t NativeIdeologyRuntime::spirit_slot_cost(const CountryState &country) const {
    return country.spirit_slots_used;
}

void NativeIdeologyRuntime::insert_active_state(CountryState &country, int32_t idea_slot) {
    if (idea_slot < 0 || idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    const int32_t ideology_id = country.ideas[static_cast<size_t>(idea_slot)].ideology_id;
    auto found = std::lower_bound(country.active_state_indices.begin(),
        country.active_state_indices.end(), ideology_id,
        [&](int32_t current_slot, int32_t needle_id) {
            return country.ideas[static_cast<size_t>(current_slot)].ideology_id < needle_id;
        });
    if (found == country.active_state_indices.end() || *found != idea_slot)
        country.active_state_indices.insert(found, idea_slot);
    country.active_bits[static_cast<size_t>(ideology_id / 64)] |=
        1ULL << (ideology_id % 64);
}

void NativeIdeologyRuntime::remove_active_state(CountryState &country, int32_t idea_slot) {
    if (idea_slot < 0 || idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    const int32_t ideology_id = country.ideas[static_cast<size_t>(idea_slot)].ideology_id;
    auto found = std::lower_bound(country.active_state_indices.begin(),
        country.active_state_indices.end(), ideology_id,
        [&](int32_t current_slot, int32_t needle_id) {
            return country.ideas[static_cast<size_t>(current_slot)].ideology_id < needle_id;
        });
    if (found != country.active_state_indices.end() && *found == idea_slot)
        country.active_state_indices.erase(found);
    country.active_bits[static_cast<size_t>(ideology_id / 64)] &=
        ~(1ULL << (ideology_id % 64));
}

void NativeIdeologyRuntime::set_state_location(CountryState &country,
        int32_t idea_slot, uint8_t location) {
    if (idea_slot < 0 || idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
    if (state.location == location) return;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    if (state.location == IDEOLOGY)
        country.ideology_slots_used -= definition.ideology_cost;
    else if (state.location == NATIONAL_SPIRIT)
        country.spirit_slots_used -= definition.spirit_cost;
    const bool was_active = state.location != INACTIVE;
    const bool will_be_active = location != INACTIVE;
    state.location = location;
    if (location == IDEOLOGY)
        country.ideology_slots_used += definition.ideology_cost;
    else if (location == NATIONAL_SPIRIT)
        country.spirit_slots_used += definition.spirit_cost;
    if (!was_active && will_be_active) insert_active_state(country, idea_slot);
    else if (was_active && !will_be_active) remove_active_state(country, idea_slot);
    mark_instance_refresh_dirty();
}

uint8_t NativeIdeologyRuntime::next_free_slot(const CountryState &country,
        uint8_t location, int32_t exclude_ideology_id) const {
    if (location == INACTIVE) return 0;
    std::array<bool, 64> occupied{};
    for (const IdeaState &idea : country.ideas) {
        if (idea.ideology_id == exclude_ideology_id ||
                idea.location != location || idea.slot_index >= occupied.size())
            continue;
        occupied[static_cast<size_t>(idea.slot_index)] = true;
    }
    for (uint8_t slot = 0; slot < static_cast<uint8_t>(occupied.size());
            ++slot)
        if (!occupied[static_cast<size_t>(slot)]) return slot;
    return 63;
}

void NativeIdeologyRuntime::rebuild_country_derived(CountryState &country) {
    country.active_bits.assign(static_cast<size_t>(_idea_words), 0);
    country.active_state_indices.clear();
    country.ideology_slots_used = 0;
    country.spirit_slots_used = 0;
    country.pending_transition_count = 0;
    country.opinion_revision = 0;
    country.class_influence.clear();
    for (int32_t idea_slot = 0; idea_slot < static_cast<int32_t>(country.ideas.size());
            ++idea_slot) {
        ++_derived_rebuild_visits;
        const IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
        if (state.transition.active != 0)
            ++country.pending_transition_count;
        if (state.location == IDEOLOGY)
            country.ideology_slots_used +=
                _definitions[static_cast<size_t>(state.ideology_id)].ideology_cost;
        else if (state.location == NATIONAL_SPIRIT)
            country.spirit_slots_used +=
                _definitions[static_cast<size_t>(state.ideology_id)].spirit_cost;
        if (state.location != INACTIVE) {
            country.active_state_indices.push_back(idea_slot);
            country.active_bits[static_cast<size_t>(state.ideology_id / 64)] |=
                1ULL << (state.ideology_id % 64);
        }
    }
    std::sort(country.active_state_indices.begin(), country.active_state_indices.end(),
        [&](int32_t a, int32_t b) {
            return country.ideas[static_cast<size_t>(a)].ideology_id <
                country.ideas[static_cast<size_t>(b)].ideology_id;
        });
    rebuild_synergies(country);
}

void NativeIdeologyRuntime::append_pending_transition(CountryState &country,
        int32_t idea_slot) {
    int32_t country_slot = -1;
    if (!validate_country(country.handle, country_slot) || idea_slot < 0 ||
            idea_slot >= static_cast<int32_t>(country.ideas.size())) return;
    const IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
    _pending_transitions.push_back({
        country.handle, country_slot, idea_slot, state.generation});
}

void NativeIdeologyRuntime::rebuild_pending_transition_index() {
    _pending_transitions.clear();
    _pending_transition_cursor = 0;
    for (int32_t country_slot = 0; country_slot < static_cast<int32_t>(_countries.size()); ++country_slot) {
        CountryState &country = _countries[static_cast<size_t>(country_slot)];
        if (country.handle == 0) continue;
        for (int32_t idea_slot = 0; idea_slot < static_cast<int32_t>(country.ideas.size()); ++idea_slot) {
            ++_derived_rebuild_visits;
            const IdeaState &state = country.ideas[static_cast<size_t>(idea_slot)];
            if (state.transition.active != 0)
                _pending_transitions.push_back({country.handle, country_slot, idea_slot, state.generation});
        }
    }
}
int32_t NativeIdeologyRuntime::unlocked_level(const IdeaState &state) const {
    if (state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size())) return -1;
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    int32_t unlocked = -1;
    for (int32_t level = 0; level < definition.level_count; ++level) {
        if (state.understanding_q16 < _levels[definition.level_begin + level].threshold_q16) break;
        unlocked = level;
    }
    return unlocked;
}

void NativeIdeologyRuntime::reconcile_level(IdeaState &state) {
    const int32_t unlocked = unlocked_level(state);
    if (unlocked > state.level) {
        state.level = unlocked;
        ++state.generation;
        ++_levels_advanced;
    }
}

uint64_t NativeIdeologyRuntime::unentered_level_mask(const IdeaState &state,
                                                      int32_t through_level) const {
    if (through_level < 0) return 0;
    const int32_t capped = std::min(through_level, 63);
    const uint64_t available = capped == 63 ? ~0ULL : ((1ULL << (capped + 1)) - 1ULL);
    return available & ~state.entered_levels;
}



void NativeIdeologyRuntime::set_worker_opinion_inputs(
        const RuntimeIdeologyOpinionSnapshot &opinion) {
    _worker_opinion_inputs = opinion;
    _worker_opinion_inputs_valid = true;
    mark_instance_refresh_dirty();
}




void NativeIdeologyRuntime::recount_managed_active() {
    rebuild_level_managed_if_needed();
    int32_t total = 0;
    for (const CountryState &country : _countries) {
        if (country.handle == 0) continue;
        for (const int32_t row : country.active_state_indices) {
            if (row < 0 || row >= static_cast<int32_t>(country.ideas.size()))
                continue;
            const IdeaState &state = country.ideas[static_cast<size_t>(row)];
            if (level_is_managed(state.ideology_id, state.level)) ++total;
        }
    }
    _managed_active_total = total;
}




bool NativeIdeologyRuntime::start_transition(CountryState &country, IdeaState &state,
        uint8_t location, int32_t level, uint8_t slot_index,
        bool remove_previous_persistent, bool apply_current_persistent,
        uint64_t entered_on_success, int64_t day, std::string &error) {
    if (state.transition.active != 0) { error = "ideology_transition_pending"; return false; }
    const auto index_it = country.idea_indices.find(state.ideology_id);
    if (index_it == country.idea_indices.end()) {
        error = "ideology_state_index_missing";
        return false;
    }
    const int32_t idea_slot = index_it->second;
    IdeaState::Transition transition;
    transition.active = 1;
    transition.producer_id = _applying_producer_id;
    transition.command_sequence = _applying_sequence;
    transition.command_opcode = _applying_opcode;
    transition.previous_level = state.level;
    transition.previous_entered_levels = state.entered_levels;
    transition.previous_generation = state.generation;
    transition.previous_location = state.location;
    transition.previous_slot_index = state.slot_index;
    transition.entered_on_success = entered_on_success;
    const int64_t previous_binding_id = state.binding_id;
    const uint32_t previous_binding_generation = state.binding_generation;
    const uint64_t previous_binding_signature = state.binding_signature;
    const uint64_t previous_binding_program_hash = state.binding_program_hash;
    bool new_binding_created = false;
    auto rollback_before_transition = [&]() {
        rollback_synergies(country, transition);
        if (new_binding_created && state.binding_id > 0 &&
                state.binding_generation != 0 && _effect_runtime != nullptr) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(state.binding_id,
                state.binding_generation, ignored);
        }
        set_state_location(country, idea_slot, transition.previous_location);
        state.slot_index = transition.previous_slot_index;
        state.level = transition.previous_level;
        state.generation = transition.previous_generation;
        state.binding_id = previous_binding_id;
        state.binding_generation = previous_binding_generation;
        state.binding_signature = previous_binding_signature;
        state.binding_program_hash = previous_binding_program_hash;
        // A level replacement keeps the same external identity.  Restore its
        // previous durable binding after the failed new generation has been
        // retired; without this, a failed transition would leave PKID active
        // while PKEF held an inactive binding for that same identity.
        if (state.location != INACTIVE && _effect_runtime != nullptr) {
            std::string restore_error;
            if (!sync_external_binding(country.handle, state, restore_error) &&
                    error.empty())
                error = restore_error.empty()
                    ? "ideology_effect_binding_rollback_failed" : restore_error;
        }
    };
    _transition_command_scratch.clear();
    if (_transition_command_scratch.capacity() <
            static_cast<size_t>(_max_transition_commands))
        _transition_command_scratch.reserve(
            static_cast<size_t>(_max_transition_commands));
    set_state_location(country, idea_slot, location);
    state.slot_index = slot_index;
    state.level = level;
    ++state.generation;
    // Effect transactions are compacted after ACK.  Record a separate
    // durable binding before issuing any command so PKID can prove, on load,
    // which active ideology generation owns the persistent source.
    if (location != INACTIVE && !sync_external_binding(country.handle, state, error)) {
        rollback_before_transition();
        return false;
    }
    new_binding_created = location != INACTIVE;
    // REMOVE and APPLY go into SEPARATE batches, because they must name DIFFERENT
    // generations.
    //
    // Both are `enqueue_external_effect_batch_pod` calls, and that function derives
    // the Effect instance id from (source_type, transition_source_id, first.effect_id,
    // fire_sequence) (`effect_runtime.cpp:3465`). `transition_source_id` embeds the
    // idea's generation, and `NATIVE_MODIFIER_IDEOLOGY` then sets the Modifier row's
    // `source_id` from that instance (`effect_runtime.cpp:5509`).
    //
    // The row being removed was applied at `previous_generation`; the row being added
    // belongs to `state.generation`. Sharing one batch id therefore always mismatches
    // one side:
    //   * unequip (remove only): nothing is found, `already_removed`, row survives;
    //   * level-up / relocation (remove + apply in one transaction): the OLD level's
    //     row keeps its old `source_id`, so the REMOVE cannot find it and BOTH levels
    //     stay live.
    // Splitting the enqueue by generation fixes both cases with one rule instead of a
    // special case per command kind.
    if (remove_previous_persistent && transition.previous_location != INACTIVE &&
            transition.previous_level >= 0) {
        _removed_command_scratch.clear();
        if (!emit_level_effects(country, state, transition.previous_level, true,
                false, day, _removed_command_scratch, error)) {
            rollback_before_transition();
            return false;
        }
        if (!_removed_command_scratch.empty()) {
            const int64_t remove_source_id = static_cast<int64_t>(
                (static_cast<uint64_t>(state.ideology_id + 1) << 32U) |
                static_cast<uint32_t>(transition.previous_generation));
            int64_t remove_transaction_id = 0;
            if (!_effect_runtime->enqueue_external_effect_batch_pod(
                    day, 0x4944454F, remove_source_id, country.handle,
                    country.handle, static_cast<uint32_t>(country.handle >> 32U),
                    _removed_command_scratch.data(),
                    _removed_command_scratch.size(), error,
                    &remove_transaction_id) ||
                    remove_transaction_id <= 0) {
                if (error.empty()) error = "ideology_effect_batch_enqueue_failed";
                rollback_before_transition();
                return false;
            }
            transition.transaction_ids.push_back(remove_transaction_id);
        }
    }
    if (apply_current_persistent && location != INACTIVE && level >= 0 &&
            !emit_level_effects(country, state, level, false, false, day,
                _transition_command_scratch, error)) {
        rollback_before_transition();
        return false;
    }
    const Definition &definition = _definitions[static_cast<size_t>(state.ideology_id)];
    for (int32_t entered_level = 0; entered_level < definition.level_count && entered_level < 64; ++entered_level) {
        if ((entered_on_success & (1ULL << entered_level)) == 0) continue;
        const Level &row = _levels[definition.level_begin + entered_level];
        if (!emit_templates(country.handle, state.ideology_id, entered_level, row.on_enter_begin,
                row.on_enter_count, false, day, static_cast<uint64_t>(entered_level + 1),
                _transition_command_scratch, error)) {
            rollback_before_transition();
            return false;
        }
    }
    if (!collect_affected_synergies(country, state.ideology_id, day,
            transition, _transition_command_scratch, error)) {
        rollback_before_transition();
        return false;
    }
    if (!_transition_command_scratch.empty()) {
        int64_t transaction_id = 0;
        // Remaining scratch holds everything that BELONGS to the new generation: the
        // APPLY rows, on-enter one-shots and synergy rows. The REMOVE rows were
        // already enqueued above under `previous_generation` (see that block for why
        // the two cannot share a batch id).
        const int64_t transition_source_id = static_cast<int64_t>(
            (static_cast<uint64_t>(state.ideology_id + 1) << 32U) |
            static_cast<uint32_t>(state.generation));
        if (!_effect_runtime->enqueue_external_effect_batch_pod(
                day, 0x4944454F, transition_source_id, country.handle,
                country.handle, static_cast<uint32_t>(country.handle >> 32U),
                _transition_command_scratch.data(),
                _transition_command_scratch.size(), error, &transaction_id) ||
                transaction_id <= 0) {
            if (error.empty()) error = "ideology_effect_batch_enqueue_failed";
            rollback_before_transition();
            return false;
        }
        transition.transaction_ids.push_back(transaction_id);
    }
    if (transition.transaction_ids.empty()) {
        state.entered_levels |= entered_on_success;
        if (transition.previous_location != INACTIVE && _effect_runtime != nullptr) {
            std::string ignored;
            const int64_t retired_id = previous_binding_id > 0 ? previous_binding_id
                : static_cast<int64_t>(binding_id_for(country.handle, state.ideology_id,
                    transition.previous_location));
            const uint32_t retired_generation = previous_binding_generation != 0
                ? previous_binding_generation : transition.previous_generation;
            _effect_runtime->retire_external_binding_pod(retired_id,
                retired_generation, ignored);
        }
        if (state.location == INACTIVE) {
            state.binding_id = 0;
            state.binding_generation = 0;
            state.binding_signature = 0;
            state.binding_program_hash = 0;
        }
        // Allocated at the top for the deferred path; see the note there.
        {
            std::string reconcile_error;
            if (!reconcile_effect_activations(country, state, day,
                    reconcile_error))
                _last_error = reconcile_error;
        }
        return true;
    }
    state.transition = std::move(transition);
    ++country.pending_transition_count;
    append_pending_transition(country, idea_slot);
    return true;
}

bool NativeIdeologyRuntime::poll_pending_transition(PendingTransitionRef &ref,
        int64_t day) {
    if (_effect_runtime == nullptr || ref.country_slot < 0 ||
            ref.country_slot >= static_cast<int32_t>(_countries.size())) return false;
    CountryState &country = _countries[static_cast<size_t>(ref.country_slot)];
    if (country.handle != ref.country_handle || ref.idea_slot < 0 ||
            ref.idea_slot >= static_cast<int32_t>(country.ideas.size())) return false;
    IdeaState &state = country.ideas[static_cast<size_t>(ref.idea_slot)];
    if (state.transition.active == 0 || state.generation != ref.state_generation)
        return false;
    bool pending = false;
    bool failed = false;
    for (const int64_t transaction_id : state.transition.transaction_ids) {
        const int32_t status = _effect_runtime->transaction_status_pod(transaction_id);
        if (status == EffectRuntime::ACKED) continue;
        if (status == EffectRuntime::REJECTED ||
                status == EffectRuntime::RESYNC_REQUIRED || status == 0) {
            failed = true;
            break;
        }
        pending = true;
    }
    if (pending && !failed) return true;
    if (failed) {
        _last_error = "ideology_effect_transition_rejected";
        append_transition_receipt(state.transition, state, country.handle,
            RECEIPT_REJECTED, day, _last_error);
        rollback_synergies(country, state.transition);
        if (state.location != INACTIVE) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(state.binding_id,
                state.binding_generation, ignored);
        }
        const uint8_t previous_location = state.transition.previous_location;
        const uint8_t previous_slot_index =
            state.transition.previous_slot_index;
        state.level = state.transition.previous_level;
        state.entered_levels = state.transition.previous_entered_levels;
        state.generation = state.transition.previous_generation;
        set_state_location(country, ref.idea_slot, previous_location);
        state.slot_index = previous_slot_index;
        state.binding_id = 0;
        state.binding_generation = 0;
        state.binding_signature = 0;
        state.binding_program_hash = 0;
        if (state.location != INACTIVE) {
            std::string restore_error;
            if (!sync_external_binding(country.handle, state, restore_error))
                _last_error = restore_error;
        }
        mark_instance_refresh_dirty();
    } else {
        append_transition_receipt(state.transition, state, country.handle,
            RECEIPT_SETTLED, day);
        state.entered_levels |= state.transition.entered_on_success;
        if (state.transition.previous_location != INACTIVE) {
            std::string ignored;
            _effect_runtime->retire_external_binding_pod(
                binding_id_for(country.handle, state.ideology_id,
                    state.transition.previous_location),
                state.transition.previous_generation, ignored);
        }
        if (state.location == INACTIVE) {
            state.binding_id = 0;
            state.binding_generation = 0;
            state.binding_signature = 0;
            state.binding_program_hash = 0;
        }
        mark_instance_refresh_dirty();
    }
    country.pending_transition_count =
        std::max(0, country.pending_transition_count - 1);
    state.transition = IdeaState::Transition{};
    if (!failed) {
        // ── plan §9.3: the projection is confirmed TODAY, eligible TOMORROW ──
        //
        // "该确认投影的 eligible_from_day = D+1. 在 sample_day = S 的新经济冻结边界，只能
        // 选择满足 eligible_from_day <= S 的最新已确认投影."
        //
        // Recorded only on the success path: a rejected transition produces no
        // projection, so it must not move the dates.
        _derived_basis_confirmed_day = day;
        _derived_basis_eligible_day = day + 1;
        // Deferred success is the only point where level/location are durably
        // committed, so the instance set converges here rather than at request
        // time. A failure leaves the previous set untouched by construction.
        std::string reconcile_error;
        if (!reconcile_effect_activations(country, state, day,
                reconcile_error))
            _last_error = reconcile_error;
    }
    return false;
}

bool NativeIdeologyRuntime::start_next_level_transition(CountryState &country,
        IdeaState &state, int64_t day, std::string &error) {
    if (state.location == INACTIVE || state.transition.active != 0) return true;
    if (country.pending_transition_count > 0 && !_synergies.empty())
        return true;
    const int32_t unlocked = unlocked_level(state);
    const int32_t next = state.level + 1;
    if (unlocked < next) return true;
    const uint64_t entered = next < 64 && (state.entered_levels & (1ULL << next)) == 0
        ? (1ULL << next) : 0;
    const bool started = start_transition(country, state, state.location, next,
        state.slot_index, state.level >= 0, true, entered, day, error);
    if (started) ++_levels_advanced;
    return started;
}

} // namespace pk
