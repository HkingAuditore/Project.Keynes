#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>


namespace pk {
using namespace godot;

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
    PackedInt32Array adopt_stances;
    PackedInt32Array repeal_stances;
    PackedInt32Array promote_stances;
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

    int64_t total_influence = 0;
    for (const int64_t value : country->class_influence) {
        total_influence = add_sat(total_influence, std::max<int64_t>(0, value));
    }

    Dictionary out;
    out["ok"] = true;
    out["ideology_ids"] = ids;
    out["support_revision"] = static_cast<int64_t>(revision);
    out["total_influence"] = total_influence;
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
    out["adopt_stances_q16"] = adopt_stances;
    out["repeal_stances_q16"] = repeal_stances;
    out["promote_stances_q16"] = promote_stances;
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

} // namespace pk
