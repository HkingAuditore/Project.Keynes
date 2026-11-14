#include "ideology_runtime.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>


namespace pk {

using namespace godot;

bool NativeIdeologyRuntime::validate_catalog(const Dictionary &catalog, std::string &error) {
    if (int32_t(catalog.get("protocol_version", PROTOCOL_VERSION)) != PROTOCOL_VERSION) { error = "ideology_protocol_version_invalid"; return false; }
    const PackedStringArray ids = strings(catalog, "ideology_ids");
    const int32_t count = ids.size();
    if (count > MAX_IDEOLOGIES) { error = "ideology_definition_count_invalid"; return false; }
    const PackedByteArray acquisition = u8s(catalog, "acquisition_flags");
    const PackedInt32Array weights = i32s(catalog, "rarity_weights");
    const PackedInt32Array ideology_costs = i32s(catalog, "ideology_slot_costs");
    const PackedInt32Array spirit_costs = i32s(catalog, "spirit_slot_costs");
    const PackedInt32Array spirit_levels = i32s(catalog, "national_spirit_min_levels");
    const PackedInt32Array level_offsets = i32s(catalog, "level_offsets");
    const PackedInt64Array thresholds = i64s(catalog, "level_thresholds_q16");
    const PackedInt64Array daily = i64s(catalog, "level_daily_understanding_q16");
    const PackedInt32Array persistent_offsets = i32s(catalog, "level_persistent_offsets");
    const PackedInt32Array persistent_actions = i32s(catalog, "persistent_actions");
    const PackedInt32Array persistent_domains = i32s(catalog, "persistent_domains");
    const PackedInt32Array persistent_opcodes = i32s(catalog, "persistent_opcodes");
    const PackedInt64Array persistent_values = i64s(catalog, "persistent_values_q16");
    const PackedInt32Array persistent_durations = i32s(catalog, "persistent_duration_days");
    const PackedInt32Array persistent_stacks = i32s(catalog, "persistent_stacks");
    const PackedStringArray persistent_keys = strings(catalog, "persistent_command_keys");
    const PackedStringArray persistent_definitions = strings(catalog, "persistent_definition_keys");
    const PackedInt64Array persistent_i0 = i64s(catalog, "persistent_payload_i0");
    const PackedInt64Array persistent_i1 = i64s(catalog, "persistent_payload_i1");
    const PackedInt64Array persistent_i2 = i64s(catalog, "persistent_payload_i2");
    const PackedInt64Array persistent_i3 = i64s(catalog, "persistent_payload_i3");
    const PackedInt32Array enter_offsets = i32s(catalog, "level_on_enter_offsets");
    const PackedInt32Array enter_actions = i32s(catalog, "on_enter_actions");
    const PackedInt32Array enter_domains = i32s(catalog, "on_enter_domains");
    const PackedInt32Array enter_opcodes = i32s(catalog, "on_enter_opcodes");
    const PackedInt64Array enter_values = i64s(catalog, "on_enter_values_q16");
    const PackedInt32Array enter_durations = i32s(catalog, "on_enter_duration_days");
    const PackedInt32Array enter_stacks = i32s(catalog, "on_enter_stacks");
    const PackedStringArray enter_keys = strings(catalog, "on_enter_command_keys");
    const PackedStringArray enter_definitions = strings(catalog, "on_enter_definition_keys");
    const PackedInt64Array enter_i0 = i64s(catalog, "on_enter_payload_i0");
    const PackedInt64Array enter_i1 = i64s(catalog, "on_enter_payload_i1");
    const PackedInt64Array enter_i2 = i64s(catalog, "on_enter_payload_i2");
    const PackedInt64Array enter_i3 = i64s(catalog, "on_enter_payload_i3");
    const PackedInt32Array tech_offsets = i32s(catalog, "technology_requirement_offsets");
    const PackedInt32Array tech = i32s(catalog, "technology_requirements");
    const PackedInt32Array signal_offsets = i32s(catalog, "signal_requirement_offsets");
    const PackedInt32Array signals = i32s(catalog, "signal_requirements");
    const PackedInt32Array gate_offsets = i32s(catalog, "gate_requirement_offsets");
    const PackedInt32Array gates = i32s(catalog, "gate_requirements");
    const PackedInt32Array era_indices = i32s(catalog, "ideology_era_indices");
    const PackedInt32Array era_decay_bp = i32s(catalog, "era_decay_bp");
    const PackedInt32Array era_milestones =
        i32s(catalog, "ideology_era_milestone_technologies");
    const PackedByteArray copy_left_programs =
        u8s(catalog, "ideology_copy_left_programs");
    const PackedByteArray copyable = u8s(catalog, "ideology_copyable");
    const PackedInt32Array school_indices =
        i32s(catalog, "ideology_school_indices");
    const PackedStringArray school_keys =
        strings(catalog, "ideology_school_keys");
    const PackedStringArray school_strength_keys =
        strings(catalog, "school_strength_factor_stat_keys");
    const PackedStringArray gate_keys = strings(catalog, "gate_keys");
    const PackedStringArray political_class_ids =
        strings(catalog, "political_class_ids");
    const PackedInt32Array stance_offsets = i32s(catalog, "stance_offsets");
    const PackedInt32Array stance_classes =
        i32s(catalog, "stance_class_indices");
    const PackedInt32Array stance_adopt = i32s(catalog, "stance_adopt_q16");
    const PackedInt32Array stance_repeal = i32s(catalog, "stance_repeal_q16");
    const PackedInt32Array stance_promote = i32s(catalog, "stance_promote_q16");
    const PackedInt32Array stance_adopt_min =
        i32s(catalog, "stance_adopt_min_q16");
    const PackedInt32Array stance_repeal_min =
        i32s(catalog, "stance_repeal_min_q16");
    const PackedInt32Array stance_promote_min =
        i32s(catalog, "stance_promote_min_q16");
    const PackedInt32Array adopt_thresholds =
        i32s(catalog, "adopt_thresholds_q16");
    const PackedInt32Array repeal_thresholds =
        i32s(catalog, "repeal_thresholds_q16");
    const PackedInt32Array promote_thresholds =
        i32s(catalog, "promote_thresholds_q16");
    const PackedInt32Array exclusion_groups =
        i32s(catalog, "exclusion_group_ids");
    const PackedStringArray route_keys = strings(catalog, "route_keys");
    const PackedInt32Array route_masks =
        i32s(catalog, "ideology_route_masks");
    const PackedInt32Array synergy_requirement_offsets =
        i32s(catalog, "synergy_requirement_offsets");
    const PackedInt32Array synergy_requirement_ideologies =
        i32s(catalog, "synergy_requirement_ideology_ids");
    const PackedInt32Array synergy_requirement_levels =
        i32s(catalog, "synergy_requirement_min_levels");
    const PackedByteArray synergy_requirement_locations =
        u8s(catalog, "synergy_requirement_location_masks");
    const PackedInt32Array synergy_effect_offsets =
        i32s(catalog, "synergy_effect_offsets");
    const PackedInt32Array synergy_actions =
        i32s(catalog, "synergy_effect_actions");
    const PackedInt32Array synergy_domains =
        i32s(catalog, "synergy_effect_domains");
    const PackedInt32Array synergy_opcodes =
        i32s(catalog, "synergy_effect_opcodes");
    const PackedInt64Array synergy_values =
        i64s(catalog, "synergy_effect_values_q16");
    const PackedInt32Array synergy_durations =
        i32s(catalog, "synergy_effect_duration_days");
    const PackedInt32Array synergy_stacks =
        i32s(catalog, "synergy_effect_stacks");
    const PackedStringArray synergy_keys =
        strings(catalog, "synergy_effect_command_keys");
    const PackedStringArray synergy_definitions =
        strings(catalog, "synergy_effect_definition_keys");
    const PackedInt64Array synergy_i0 =
        i64s(catalog, "synergy_effect_payload_i0");
    const PackedInt64Array synergy_i1 =
        i64s(catalog, "synergy_effect_payload_i1");
    const PackedInt64Array synergy_i2 =
        i64s(catalog, "synergy_effect_payload_i2");
    const PackedInt64Array synergy_i3 =
        i64s(catalog, "synergy_effect_payload_i3");
    const PackedStringArray synergy_ids = strings(catalog, "synergy_ids");
    const PackedInt32Array ideology_synergy_offsets =
        i32s(catalog, "ideology_synergy_offsets");
    const PackedInt32Array ideology_synergy_ids =
        i32s(catalog, "ideology_synergy_ids");
    const PackedInt32Array synergy_min_counts =
        i32s(catalog, "synergy_min_counts");
    // L3-9 synergy magnitude overrides. All three columns are optional as a set;
    // a catalog that predates them has none and behaves exactly as before.
    const PackedInt32Array synergy_override_offsets =
        i32s(catalog, "synergy_override_offsets");
    const PackedStringArray synergy_override_programs =
        strings(catalog, "synergy_override_programs");
    const PackedInt32Array synergy_override_scales =
        i32s(catalog, "synergy_override_scales");
    const PackedInt32Array synergy_override_match_kinds =
        i32s(catalog, "synergy_override_match_kinds");
    const PackedStringArray synergy_override_match_values =
        strings(catalog, "synergy_override_match_values");
    const PackedInt32Array synergy_override_fields =
        i32s(catalog, "synergy_override_fields");
    const PackedInt32Array synergy_override_values =
        i32s(catalog, "synergy_override_values");
    const PackedStringArray synergy_override_tag_names =
        strings(catalog, "synergy_override_tag_names");
    const PackedInt32Array unlock_technologies =
        i32s(catalog, "capacity_unlock_technology_ids");
    const PackedInt32Array unlock_ideology =
        i32s(catalog, "capacity_unlock_ideology_deltas");
    const PackedInt32Array unlock_spirit =
        i32s(catalog, "capacity_unlock_spirit_deltas");
    const auto persistent_count = persistent_actions.size();
    const auto enter_count = enter_actions.size();
    const int32_t stance_count = stance_classes.size();
    const int32_t synergy_count = synergy_ids.size();
    const int32_t synergy_effect_count = synergy_actions.size();
    if (acquisition.size()!=count || weights.size()!=count || ideology_costs.size()!=count || spirit_costs.size()!=count || spirit_levels.size()!=count || level_offsets.size()!=count+1 || tech_offsets.size()!=count+1 || signal_offsets.size()!=count+1 || gate_offsets.size()!=count+1 || thresholds.size()!=daily.size() || thresholds.size()>MAX_LEVELS || persistent_offsets.size()!=thresholds.size()+1 || enter_offsets.size()!=thresholds.size()+1 || persistent_domains.size()!=persistent_count || persistent_opcodes.size()!=persistent_count || persistent_values.size()!=persistent_count || persistent_durations.size()!=persistent_count || persistent_stacks.size()!=persistent_count || persistent_keys.size()!=persistent_count || persistent_definitions.size()!=persistent_count || persistent_i0.size()!=persistent_count || persistent_i1.size()!=persistent_count || persistent_i2.size()!=persistent_count || persistent_i3.size()!=persistent_count || enter_domains.size()!=enter_count || enter_opcodes.size()!=enter_count || enter_values.size()!=enter_count || enter_durations.size()!=enter_count || enter_stacks.size()!=enter_count || enter_keys.size()!=enter_count || enter_definitions.size()!=enter_count || enter_i0.size()!=enter_count || enter_i1.size()!=enter_count || enter_i2.size()!=enter_count || enter_i3.size()!=enter_count || political_class_ids.is_empty() || stance_offsets.size()!=count+1 || stance_adopt.size()!=stance_count || stance_repeal.size()!=stance_count || stance_promote.size()!=stance_count || stance_adopt_min.size()!=stance_count || stance_repeal_min.size()!=stance_count || stance_promote_min.size()!=stance_count || adopt_thresholds.size()!=count || repeal_thresholds.size()!=count || promote_thresholds.size()!=count || exclusion_groups.size()!=count || synergy_requirement_offsets.size()!=synergy_count+1 || synergy_requirement_ideologies.size()!=synergy_requirement_levels.size() || synergy_requirement_ideologies.size()!=synergy_requirement_locations.size() || synergy_effect_offsets.size()!=synergy_count+1 || synergy_domains.size()!=synergy_effect_count || synergy_opcodes.size()!=synergy_effect_count || synergy_values.size()!=synergy_effect_count || synergy_durations.size()!=synergy_effect_count || synergy_stacks.size()!=synergy_effect_count || synergy_keys.size()!=synergy_effect_count || synergy_definitions.size()!=synergy_effect_count || synergy_i0.size()!=synergy_effect_count || synergy_i1.size()!=synergy_effect_count || synergy_i2.size()!=synergy_effect_count || synergy_i3.size()!=synergy_effect_count || ideology_synergy_offsets.size()!=count+1) { error="ideology_catalog_columns_invalid"; return false; }
    std::unordered_set<std::string> seen;
    int32_t max_gate=-1;
    for (int32_t i=0;i<count;++i) {
        const std::string id = String(ids[i]).utf8().get_data();
        if (id.empty() || !seen.insert(id).second || (acquisition[i] & ~(DISCOVER|DRAW)) != 0 || acquisition[i]==0 || weights[i]<=0 || ideology_costs[i]<=0 || spirit_costs[i]<=0 || spirit_levels[i]<0 || level_offsets[i]<0 || level_offsets[i+1] <= level_offsets[i] || level_offsets[i+1]-level_offsets[i] > 64 || level_offsets[i+1]>thresholds.size() || spirit_levels[i] >= level_offsets[i+1]-level_offsets[i] || tech_offsets[i]<0 || tech_offsets[i+1]<tech_offsets[i] || tech_offsets[i+1]>tech.size() || signal_offsets[i]<0 || signal_offsets[i+1]<signal_offsets[i] || signal_offsets[i+1]>signals.size() || gate_offsets[i]<0 || gate_offsets[i+1]<gate_offsets[i] || gate_offsets[i+1]>gates.size()) { error="ideology_definition_invalid"; return false; }
        int64_t previous=-1;
        for (int32_t row=level_offsets[i];row<level_offsets[i+1];++row) { if (thresholds[row]<0 || thresholds[row]<previous || daily[row]<0) { error="ideology_level_invalid"; return false; } previous=thresholds[row]; }
        for (int32_t row=tech_offsets[i];row<tech_offsets[i+1];++row) if (tech[row]<0) { error="ideology_technology_requirement_invalid"; return false; }
        for (int32_t row=signal_offsets[i];row<signal_offsets[i+1];++row) if (signals[row]<0) { error="ideology_signal_requirement_invalid"; return false; }
        for (int32_t row=gate_offsets[i];row<gate_offsets[i+1];++row) { if (gates[row]<0 || gates[row]>=MAX_GATES) { error="ideology_gate_requirement_invalid"; return false; } max_gate=std::max(max_gate,gates[row]); }
    }
    // Era metadata. A catalog authored before eras existed omits both arrays;
    // that degrades to "no decay" instead of failing, so the same runtime keeps
    // working with old content. Anything present must be well formed.
    if (!era_indices.is_empty() && era_indices.size() != count) {
        error = "ideology_era_indices_invalid";
        return false;
    }
    // X6-c catalog flags. Arrays are optional for older catalogs; when present
    // they must describe every definition, and a byte outside {0,1} is a typo
    // that would otherwise make a legendary card copyable or a copier silent.
    if ((!copy_left_programs.is_empty() &&
            copy_left_programs.size() != count) ||
            (!copyable.is_empty() && copyable.size() != count)) {
        error = "ideology_copy_flags_invalid";
        return false;
    }
    for (int32_t i = 0; i < copy_left_programs.size(); ++i) {
        if (copy_left_programs[i] > 1) {
            error = "ideology_copy_flags_invalid";
            return false;
        }
    }
    for (int32_t i = 0; i < copyable.size(); ++i) {
        if (copyable[i] > 1) {
            error = "ideology_copy_flags_invalid";
            return false;
        }
    }
    if (route_keys.size() > 31 ||
            (!route_masks.is_empty() && route_masks.size() != count)) {
        error = "ideology_route_table_invalid";
        return false;
    }
    if (route_keys.is_empty()) {
        for (int32_t i = 0; i < route_masks.size(); ++i) {
            if (route_masks[i] != 0) {
                error = "ideology_route_table_invalid";
                return false;
            }
        }
    }
    if (!school_keys.is_empty()) {
        if (school_keys.size() > 64 || school_indices.size() != count ||
                school_strength_keys.size() != school_keys.size()) {
            error = "ideology_school_strength_contract_invalid";
            return false;
        }
        std::unordered_set<std::string> seen_schools;
        std::unordered_set<std::string> seen_strength_stats;
        for (int32_t i = 0; i < school_keys.size(); ++i) {
            const std::string school =
                String(school_keys[i]).utf8().get_data();
            const std::string stat =
                String(school_strength_keys[i]).utf8().get_data();
            if (school.empty() || stat.empty() ||
                    !seen_schools.insert(school).second ||
                    !seen_strength_stats.insert(stat).second) {
                error = "ideology_school_strength_contract_invalid";
                return false;
            }
        }
        for (int32_t i = 0; i < school_indices.size(); ++i) {
            if (school_indices[i] < 0 ||
                    school_indices[i] >= school_keys.size()) {
                error = "ideology_school_index_invalid";
                return false;
            }
        }
    } else if (!school_indices.is_empty() ||
            !school_strength_keys.is_empty()) {
        error = "ideology_school_strength_contract_invalid";
        return false;
    }
    for (int32_t i = 0; i < era_indices.size(); ++i) {
        if (era_indices[i] < 0 || era_indices[i] > MAX_ERA_INDEX) {
            error = "ideology_era_index_invalid";
            return false;
        }
    }
    for (int32_t i = 0; i < era_decay_bp.size(); ++i) {
        if (era_decay_bp[i] < 0 || era_decay_bp[i] > 10000) {
            error = "ideology_era_decay_invalid";
            return false;
        }
    }
    // -1 marks an era without a milestone; anything else must be a real technology.
    // The dense index range is not known until the country catalog is attached, so
    // only the negative bound is checked here.
    for (int32_t i = 0; i < era_milestones.size(); ++i) {
        if (era_milestones[i] < -1) {
            error = "ideology_era_milestone_invalid";
            return false;
        }
    }
    for (int32_t level = 0; level < thresholds.size(); ++level) {
        if (persistent_offsets[level] < 0 || persistent_offsets[level + 1] < persistent_offsets[level] || persistent_offsets[level + 1] > persistent_count || enter_offsets[level] < 0 || enter_offsets[level + 1] < enter_offsets[level] || enter_offsets[level + 1] > enter_count) { error="ideology_effect_offsets_invalid"; return false; }
    }
    auto validate_template = [&](int32_t i, bool persistent) {
        const int32_t action = persistent ? persistent_actions[i] : enter_actions[i];
        const int32_t domain = persistent ? persistent_domains[i] : enter_domains[i];
        const int32_t opcode = persistent ? persistent_opcodes[i] : enter_opcodes[i];
        const int32_t stacks = persistent ? persistent_stacks[i] : enter_stacks[i];
        const std::string key = String(persistent ? persistent_keys[i] : enter_keys[i]).utf8().get_data();
        const std::string definition = String(persistent ? persistent_definitions[i] : enter_definitions[i]).utf8().get_data();
        return action >= EffectRuntime::MODIFIER_COMMAND && action <= EffectRuntime::CUSTOM_DOMAIN_COMMAND && domain >= 0 && domain < 32 && stacks > 0 && !key.empty() && !definition.empty() && (!persistent || (action == EffectRuntime::MODIFIER_COMMAND && domain < 4 && opcode == 1));
    };
    for (int32_t i=0;i<persistent_count;++i) if(!validate_template(i,true)) { error="ideology_persistent_template_invalid"; return false; }
    for (int32_t i=0;i<enter_count;++i) {
        // X6-b registers exactly one new Effect custom-domain opcode (3). The
        // row value is a positive count, not an Ideology opcode.
        if (enter_actions[i] == EffectRuntime::CUSTOM_DOMAIN_COMMAND &&
                enter_domains[i] == 6 &&
                enter_opcodes[i] == 3) {
            if (enter_values[i] <= 0 || enter_values[i] > 65535 ||
                    enter_stacks[i] <= 0 || enter_durations[i] < -1 ||
                    String(enter_keys[i]).is_empty() ||
                    String(enter_definitions[i]).is_empty()) {
                error = "ideology_on_enter_free_draw_invalid";
                return false;
            }
            continue;
        }
        if(!validate_template(i,false)) { error="ideology_on_enter_template_invalid"; return false; }
    }
    std::string previous_class;
    for (int32_t class_index = 0;
            class_index < political_class_ids.size(); ++class_index) {
        const std::string id =
            String(political_class_ids[class_index]).utf8().get_data();
        if (id.empty() || (class_index > 0 && id <= previous_class)) {
            error = "ideology_political_class_order_invalid";
            return false;
        }
        previous_class = id;
    }
    for (int32_t ideology = 0; ideology < count; ++ideology) {
        if (stance_offsets[ideology] < 0 ||
                stance_offsets[ideology + 1] < stance_offsets[ideology] ||
                stance_offsets[ideology + 1] > stance_count ||
                adopt_thresholds[ideology] < -65536 ||
                adopt_thresholds[ideology] > 65536 ||
                repeal_thresholds[ideology] < -65536 ||
                repeal_thresholds[ideology] > 65536 ||
                promote_thresholds[ideology] < -65536 ||
                promote_thresholds[ideology] > 65536 ||
                exclusion_groups[ideology] < -1) {
            error = "ideology_stance_definition_invalid";
            return false;
        }
        int32_t previous_stance_class = -1;
        for (int32_t row = stance_offsets[ideology];
                row < stance_offsets[ideology + 1]; ++row) {
            if (stance_classes[row] <= previous_stance_class ||
                    stance_classes[row] < 0 ||
                    stance_classes[row] >= political_class_ids.size() ||
                    stance_adopt[row] < -65536 ||
                    stance_adopt[row] > 65536 ||
                    stance_repeal[row] < -65536 ||
                    stance_repeal[row] > 65536 ||
                    stance_promote[row] < -65536 ||
                    stance_promote[row] > 65536 ||
                    stance_adopt_min[row] < -65537 ||
                    stance_adopt_min[row] > 65536 ||
                    stance_repeal_min[row] < -65537 ||
                    stance_repeal_min[row] > 65536 ||
                    stance_promote_min[row] < -65537 ||
                    stance_promote_min[row] > 65536) {
                error = "ideology_stance_row_invalid";
                return false;
            }
            previous_stance_class = stance_classes[row];
        }
    }
    for (int32_t synergy = 0; synergy < synergy_count; ++synergy) {
        if (synergy_requirement_offsets[synergy] < 0 ||
                synergy_requirement_offsets[synergy + 1] <=
                    synergy_requirement_offsets[synergy] ||
                synergy_requirement_offsets[synergy + 1] >
                    synergy_requirement_ideologies.size() ||
                synergy_effect_offsets[synergy] < 0 ||
                synergy_effect_offsets[synergy + 1] <
                    synergy_effect_offsets[synergy] ||
                synergy_effect_offsets[synergy + 1] >
                    synergy_effect_count) {
            error = "ideology_synergy_offsets_invalid";
            return false;
        }
        for (int32_t row = synergy_requirement_offsets[synergy];
                row < synergy_requirement_offsets[synergy + 1]; ++row) {
            if (synergy_requirement_ideologies[row] < 0 ||
                    synergy_requirement_ideologies[row] >= count ||
                    synergy_requirement_levels[row] < 0 ||
                    synergy_requirement_locations[row] == 0 ||
                    (synergy_requirement_locations[row] & ~6) != 0) {
                error = "ideology_synergy_requirement_invalid";
                return false;
            }
        }
    }
    if (!synergy_override_offsets.is_empty()) {
        if (synergy_override_offsets.size() != synergy_count + 1 ||
                synergy_override_programs.size() != synergy_override_scales.size() ||
                (!synergy_override_match_kinds.is_empty() &&
                    (synergy_override_match_kinds.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_match_values.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_fields.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_values.size() !=
                        synergy_override_programs.size() ||
                     synergy_override_tag_names.size() !=
                        synergy_override_programs.size())) ||
                synergy_override_offsets[synergy_count] < 0 ||
                synergy_override_offsets[synergy_count] !=
                    static_cast<int32_t>(synergy_override_programs.size())) {
            error = "ideology_synergy_override_columns_invalid";
            return false;
        }
        for (int32_t i = 0; i < synergy_count; ++i) {
            if (synergy_override_offsets[i] < 0 ||
                    synergy_override_offsets[i + 1] < synergy_override_offsets[i]) {
                error = "ideology_synergy_override_columns_invalid";
                return false;
            }
        }
        for (int32_t row = 0; row < static_cast<int32_t>(synergy_override_programs.size()); ++row) {
            const std::string program =
                String(synergy_override_programs[row]).utf8().get_data();
            const bool legacy_columns = synergy_override_match_kinds.is_empty();
            const int32_t field = legacy_columns ? 4
                : synergy_override_fields[row];
            const int32_t match_kind = legacy_columns ? 0
                : synergy_override_match_kinds[row];
            const int32_t value = legacy_columns ? synergy_override_scales[row]
                : synergy_override_values[row];
            const std::string match_value = legacy_columns ? program
                : String(synergy_override_match_values[row]).utf8().get_data();
            const std::string tag_name = legacy_columns ? std::string()
                : String(synergy_override_tag_names[row]).utf8().get_data();
            bool valid = !program.empty() && !match_value.empty() &&
                match_kind >= 0 && match_kind <= 1;
            if (valid && field == 4) { // MAGNITUDE_SCALE
                valid = value >= Q16_ONE / 4 && value <= 4 * Q16_ONE &&
                    match_kind == 0;
            } else if (valid && field == 5) { // TAG
                valid = !tag_name.empty() && match_kind == 1;
            } else if (valid && field == 6) { // SELECTOR_KIND
                valid = match_kind == 0 &&
                    (value == EffectRuntime::SELECTOR_NEIGHBORS_R1 ||
                     value == EffectRuntime::SELECTOR_NEIGHBORS_R2 ||
                     value == EffectRuntime::SELECTOR_TAG_SOURCE_R1 ||
                     value == EffectRuntime::SELECTOR_TAG_SOURCE_R2);
            } else if (valid && field == 7) { // SELECTOR_CAP
                valid = match_kind == 0 && value >= 1 &&
                    value <= EffectRuntime::SELECTOR_MAX_CELLS;
            } else {
                valid = false;
            }
            if (!valid) {
                error = "ideology_synergy_override_row_invalid";
                return false;
            }
        }
    }
    for (int32_t effect = 0; effect < synergy_effect_count; ++effect) {
        if (synergy_actions[effect] != EffectRuntime::MODIFIER_COMMAND ||
                synergy_domains[effect] < 0 || synergy_domains[effect] > 3 ||
                synergy_opcodes[effect] != 1 ||
                synergy_stacks[effect] <= 0 ||
                String(synergy_keys[effect]).is_empty() ||
                String(synergy_definitions[effect]).is_empty()) {
            error = "ideology_synergy_effect_invalid";
            return false;
        }
    }
    int32_t previous_reverse = 0;
    if (ideology_synergy_offsets[0] != 0) {
        error = "ideology_synergy_reverse_invalid";
        return false;
    }
    for (int32_t ideology = 0; ideology < count; ++ideology) {
        const int32_t end = ideology_synergy_offsets[ideology + 1];
        if (end < previous_reverse || end > ideology_synergy_ids.size()) {
            error = "ideology_synergy_reverse_invalid";
            return false;
        }
        int32_t previous_synergy = -1;
        for (int32_t row = previous_reverse; row < end; ++row) {
            if (ideology_synergy_ids[row] <= previous_synergy ||
                    ideology_synergy_ids[row] < 0 ||
                    ideology_synergy_ids[row] >= synergy_count) {
                error = "ideology_synergy_reverse_invalid";
                return false;
            }
            previous_synergy = ideology_synergy_ids[row];
        }
        previous_reverse = end;
    }
    if (previous_reverse != ideology_synergy_ids.size()) {
        error = "ideology_synergy_reverse_invalid";
        return false;
    }
    if (!synergy_min_counts.is_empty() &&
            synergy_min_counts.size() != synergy_count) {
        error = "ideology_synergy_min_counts_invalid";
        return false;
    }
    for (int32_t synergy = 0; synergy < synergy_min_counts.size(); ++synergy) {
        const int32_t requirements = synergy_requirement_offsets[synergy + 1] -
            synergy_requirement_offsets[synergy];
        if (synergy_min_counts[synergy] < 0 ||
                synergy_min_counts[synergy] > requirements) {
            error = "ideology_synergy_min_counts_invalid";
            return false;
        }
    }
    if (unlock_ideology.size() != unlock_technologies.size() ||
            unlock_spirit.size() != unlock_technologies.size()) {
        error = "ideology_capacity_unlocks_invalid";
        return false;
    }
    for (int32_t row = 0; row < unlock_technologies.size(); ++row) {
        if (unlock_technologies[row] < 0 || unlock_ideology[row] < 0 ||
                unlock_spirit[row] < 0 || unlock_ideology[row] > 16 ||
                unlock_spirit[row] > 16) {
            error = "ideology_capacity_unlocks_invalid";
            return false;
        }
    }
    _synergy_override_programs.clear();
    _synergy_override_scales.clear();
    _synergy_overrides.clear();
    _synergy_program_overrides.clear();
    _synergy_tag_overrides.clear();
    _synergy_override_tags_resolved = false;
    if (!synergy_override_offsets.is_empty()) {
        _synergy_override_programs.reserve(synergy_override_programs.size());
        for (int32_t row = 0; row < static_cast<int32_t>(synergy_override_programs.size()); ++row)
            _synergy_override_programs.emplace_back(
                String(synergy_override_programs[row]).utf8().get_data());
        _synergy_override_scales.assign(synergy_override_scales.ptr(),
            synergy_override_scales.ptr() + synergy_override_scales.size());
        const bool legacy_columns = synergy_override_match_kinds.is_empty();
        _synergy_overrides.reserve(
            static_cast<size_t>(synergy_override_programs.size()));
        for (int32_t row = 0;
                row < static_cast<int32_t>(synergy_override_programs.size());
                ++row) {
            SynergyOverride override;
            override.field = legacy_columns ? 4 : synergy_override_fields[row];
            override.value = legacy_columns ? synergy_override_scales[row]
                : synergy_override_values[row];
            override.match_kind = legacy_columns ? 0
                : synergy_override_match_kinds[row];
            override.match_value = legacy_columns ? _synergy_override_programs[
                static_cast<size_t>(row)]
                : String(synergy_override_match_values[row]).utf8().get_data();
            override.tag_name = legacy_columns ? std::string()
                : String(synergy_override_tag_names[row]).utf8().get_data();
            override.synergy_id = -1;
            _synergy_overrides.push_back(std::move(override));
        }
    }
    _definitions.clear(); _route_keys.clear(); _route_indices.clear(); _school_keys.clear(); _levels.clear(); _persistent_templates.clear(); _on_enter_templates.clear(); _synergy_templates.clear(); _class_stances.clear(); _synergy_requirements.clear(); _synergies.clear(); _technology_requirements.clear(); _signal_requirements.clear(); _gate_requirements.clear(); _era_decay_bp.clear(); _era_milestone_technologies.clear();
    _route_keys.reserve(static_cast<size_t>(route_keys.size()));
    for (int32_t i = 0; i < route_keys.size(); ++i) {
        const std::string key = String(route_keys[i]).utf8().get_data();
        if (key.empty() || !_route_indices.emplace(key, i).second) {
            error = "ideology_route_table_invalid";
            return false;
        }
        _route_keys.push_back(key);
    }
    for (int32_t i = 0; i < school_keys.size(); ++i)
        _school_keys.emplace_back(String(school_keys[i]).utf8().get_data());
    _definitions.reserve(count); _levels.reserve(thresholds.size());
    for (int32_t i=0;i<count;++i) {
        Definition d; d.stable_id=String(ids[i]).utf8().get_data(); d.acquisition=acquisition[i]; d.copy_left_programs=copy_left_programs.is_empty()?0:copy_left_programs[i]; d.copyable=copyable.is_empty()?1:copyable[i]; d.school_index=school_indices.is_empty()?-1:school_indices[i]; d.rarity_weight=weights[i]; d.ideology_cost=ideology_costs[i]; d.spirit_cost=spirit_costs[i]; d.min_spirit_level=spirit_levels[i]; d.level_begin=level_offsets[i]; d.level_count=level_offsets[i+1]-level_offsets[i]; d.technology_requirement_begin=tech_offsets[i]; d.technology_requirement_count=tech_offsets[i+1]-tech_offsets[i]; d.signal_requirement_begin=signal_offsets[i]; d.signal_requirement_count=signal_offsets[i+1]-signal_offsets[i]; d.gate_requirement_begin=gate_offsets[i]; d.gate_requirement_count=gate_offsets[i+1]-gate_offsets[i]; d.stance_begin=stance_offsets[i]; d.stance_count=stance_offsets[i+1]-stance_offsets[i]; d.support_threshold_q16={adopt_thresholds[i],repeal_thresholds[i],promote_thresholds[i]}; d.exclusion_group_id=exclusion_groups[i]; d.era_index=era_indices.is_empty()?0:era_indices[i]; d.route_mask=route_masks.is_empty()?0:static_cast<uint32_t>(route_masks[i]); _definitions.push_back(std::move(d)); }
    for (int32_t i=0;i<thresholds.size();++i) _levels.push_back({thresholds[i],daily[i],persistent_offsets[i],persistent_offsets[i+1]-persistent_offsets[i],enter_offsets[i],enter_offsets[i+1]-enter_offsets[i]});
    for (int32_t i=0;i<persistent_count;++i) _persistent_templates.push_back({persistent_actions[i],persistent_domains[i],persistent_opcodes[i],persistent_values[i],persistent_durations[i],persistent_stacks[i],String(persistent_keys[i]).utf8().get_data(),String(persistent_definitions[i]).utf8().get_data(),{persistent_i0[i],persistent_i1[i],persistent_i2[i],persistent_i3[i]}});
    for (int32_t i=0;i<enter_count;++i) _on_enter_templates.push_back({enter_actions[i],enter_domains[i],enter_opcodes[i],enter_values[i],enter_durations[i],enter_stacks[i],String(enter_keys[i]).utf8().get_data(),String(enter_definitions[i]).utf8().get_data(),{enter_i0[i],enter_i1[i],enter_i2[i],enter_i3[i]}});
    for (int32_t i=0;i<stance_count;++i) _class_stances.push_back({stance_classes[i],{stance_adopt[i],stance_repeal[i],stance_promote[i]},{stance_adopt_min[i],stance_repeal_min[i],stance_promote_min[i]}});
    for (int32_t i=0;i<synergy_requirement_ideologies.size();++i) _synergy_requirements.push_back({synergy_requirement_ideologies[i],synergy_requirement_levels[i],synergy_requirement_locations[i]});
    for (int32_t i=0;i<synergy_effect_count;++i) _synergy_templates.push_back({synergy_actions[i],synergy_domains[i],synergy_opcodes[i],synergy_values[i],synergy_durations[i],synergy_stacks[i],String(synergy_keys[i]).utf8().get_data(),String(synergy_definitions[i]).utf8().get_data(),{synergy_i0[i],synergy_i1[i],synergy_i2[i],synergy_i3[i]}});
    for (int32_t i=0;i<synergy_count;++i) {
        const int32_t requirements=synergy_requirement_offsets[i+1]-synergy_requirement_offsets[i];
        const int32_t min_count=synergy_min_counts.is_empty()||synergy_min_counts[i]==0?requirements:synergy_min_counts[i];
        const int32_t override_begin = synergy_override_offsets.is_empty()
            ? 0 : synergy_override_offsets[i];
        const int32_t override_count = synergy_override_offsets.is_empty()
            ? 0 : synergy_override_offsets[i + 1] - synergy_override_offsets[i];
        _synergies.push_back({synergy_requirement_offsets[i],requirements,synergy_effect_offsets[i],synergy_effect_offsets[i+1]-synergy_effect_offsets[i],min_count,override_begin,override_count});
    }
    // Reverse index, built once per catalog: the scale lookup is on the hot path
    // (per program, per country, per reconcile) and used to walk every synergy.
    _synergy_override_index.clear();
    _synergy_program_overrides.clear();
    for (size_t synergy_id = 0; synergy_id < _synergies.size(); ++synergy_id) {
        const Synergy &synergy = _synergies[synergy_id];
        const int32_t end = synergy.override_begin + synergy.override_count;
        for (int32_t row = synergy.override_begin; row < end; ++row) {
            if (row < 0 || row >= static_cast<int32_t>(_synergy_overrides.size()))
                continue;
            _synergy_overrides[static_cast<size_t>(row)].synergy_id =
                static_cast<int32_t>(synergy_id);
            const SynergyOverride &override =
                _synergy_overrides[static_cast<size_t>(row)];
            if (override.field != 4) {
                if (override.match_kind == 0)
                    _synergy_program_overrides[override.match_value].push_back(
                        static_cast<int32_t>(row));
                continue;
            }
            _synergy_override_index[override.match_value].push_back(
                {static_cast<int32_t>(synergy_id), override.value});
        }
    }
    _capacity_unlocks.clear();
    for (int32_t i=0;i<unlock_technologies.size();++i) _capacity_unlocks.push_back({unlock_technologies[i],unlock_ideology[i],unlock_spirit[i]});
    _ideology_synergy_offsets.assign(ideology_synergy_offsets.ptr(), ideology_synergy_offsets.ptr()+ideology_synergy_offsets.size());
    _ideology_synergy_ids.assign(ideology_synergy_ids.ptr(), ideology_synergy_ids.ptr()+ideology_synergy_ids.size());
    _synergy_candidate_stamps.assign(static_cast<size_t>(synergy_count), 0);
    // Optional. Only the offer RNG depends on it, and the worker receives the
    // same value through `export_pod_catalog`, so parity holds whether or not a
    // content layer supplies one.
    _world_seed = static_cast<uint64_t>(int64_t(catalog.get("world_seed", 0)));
    _political_class_count = political_class_ids.size();
    _political_class_hash = 1469598103934665603ULL;
    for (int32_t i=0;i<political_class_ids.size();++i) {
        const std::string id=String(political_class_ids[i]).utf8().get_data();
        for (const unsigned char value:id) { _political_class_hash^=value; _political_class_hash*=1099511628211ULL; }
        _political_class_hash^=0xffU; _political_class_hash*=1099511628211ULL;
    }
    _technology_requirements.assign(tech.ptr(), tech.ptr()+tech.size()); _signal_requirements.assign(signals.ptr(), signals.ptr()+signals.size()); _gate_requirements.assign(gates.ptr(),gates.ptr()+gates.size());
    _era_decay_bp.assign(era_decay_bp.ptr(), era_decay_bp.ptr()+era_decay_bp.size());
    _era_milestone_technologies.assign(era_milestones.ptr(), era_milestones.ptr()+era_milestones.size());
    _ideology_capacity=std::max(0,int32_t(catalog.get("ideology_capacity",6))); _spirit_capacity=std::max(0,int32_t(catalog.get("national_spirit_capacity",3))); _draw_count=int32_t(catalog.get("offer_choice_count",3)); _offer_cost_q16=int64_t(catalog.get("offer_cost_q16",Q16_ONE)); _starting_points_q16=std::max<int64_t>(0,int64_t(catalog.get("starting_points_q16",0))); _max_commands_per_slice=std::max(1,int32_t(catalog.get("max_commands_per_slice",4096))); _max_transition_commands=std::max(1,std::min(4096,int32_t(catalog.get("max_transition_commands",256)))); _max_transition_polls_per_slice=std::max(1,int32_t(catalog.get("max_transition_polls_per_slice",4096))); _max_active_visits_per_slice=std::max(1,int32_t(catalog.get("max_active_visits_per_slice",1024))); _opinion_owner_influence_weight=std::max(0,int32_t(catalog.get("opinion_owner_influence_weight",2))); _opinion_funds_per_influence=std::max<int64_t>(1,int64_t(catalog.get("opinion_funds_per_influence",1000000)));
    _draw_count=std::clamp(_draw_count,1,OFFER_CHOICE_CAPACITY);
    if (_offer_cost_q16<0) { error="ideology_profile_invalid"; return false; }
    _ideology_capacity_max=std::max(_ideology_capacity,int32_t(catalog.get("ideology_capacity_max",_ideology_capacity)));
    _spirit_capacity_max=std::max(_spirit_capacity,int32_t(catalog.get("national_spirit_capacity_max",_spirit_capacity)));
    _offer_cost_growth_percent=int64_t(catalog.get("offer_cost_growth_percent",100));
    if (_offer_cost_growth_percent<100 || _offer_cost_growth_percent>400) { error="ideology_profile_invalid"; return false; }
    _offer_cost_max_q16=std::max<int64_t>(_offer_cost_q16,int64_t(catalog.get("offer_cost_max_q16",_offer_cost_q16)));
    _reroll_cost_percent=std::clamp(int32_t(catalog.get("reroll_cost_percent",50)),0,1000);
    _point_population_weight_q16=std::max<int64_t>(0,int64_t(catalog.get("point_population_weight_q16",0)));
    _point_building_weight_q16=std::max<int64_t>(0,int64_t(catalog.get("point_building_weight_q16",0)));
    _point_trade_weight_q16=std::max<int64_t>(0,int64_t(catalog.get("point_trade_weight_q16",0)));
    _point_gain_cap_q16=std::max<int64_t>(0,int64_t(catalog.get("point_gain_cap_q16",0)));
    _point_gain_stat_key=String(catalog.get("point_gain_stat_key",String())).utf8().get_data();
    _point_population_factor_stat_key=String(catalog.get(
        "point_population_factor_stat_key",String())).utf8().get_data();
    _point_building_factor_stat_key=String(catalog.get(
        "point_building_factor_stat_key",String())).utf8().get_data();
    _point_trade_factor_stat_key=String(catalog.get(
        "point_trade_factor_stat_key",String())).utf8().get_data();
    _opinion_factor_floor_stat_key=String(catalog.get(
        "opinion_factor_floor_stat_key",String())).utf8().get_data();
    _school_strength_factor_stat_keys.clear();
    for (int32_t i = 0; i < school_strength_keys.size(); ++i)
        _school_strength_factor_stat_keys.emplace_back(
            String(school_strength_keys[i]).utf8().get_data());
    _understanding_gain_stat_key=
        String(catalog.get("understanding_gain_stat_key",String())).utf8().get_data();
    _reroll_cost_stat_key=
        String(catalog.get("reroll_cost_stat_key",String())).utf8().get_data();
    _era_decay_floor_stat_key=
        String(catalog.get("era_decay_floor_stat_key",String())).utf8().get_data();
    _offer_choice_bonus_stat_key=
        String(catalog.get("offer_choice_bonus_stat_key",String())).utf8().get_data();
    _refine_weight_bp=std::clamp(int32_t(catalog.get("refine_weight_bp",0)),0,10000);
    _refine_understanding_q16=std::max<int64_t>(0,
        int64_t(catalog.get("refine_understanding_q16",4*Q16_ONE)));
    // A reconfigure can renumber stat ids (dense ids are assigned in catalog
    // order), so any id cached against the previous catalog is stale.
    _understanding_gain_stat_id = -1;
    _reroll_cost_stat_id = -1;
    _era_decay_floor_stat_id = -1;
    _offer_choice_bonus_stat_id = -1;
    _point_population_factor_stat_id = -1;
    _point_building_factor_stat_id = -1;
    _point_trade_factor_stat_id = -1;
    _opinion_factor_floor_stat_id = -1;
    _school_strength_factor_stat_ids.assign(
        _school_strength_factor_stat_keys.size(), -1);
    // gate_bits must cover every registered gate key, not just the highest one a
    // requirement happens to reference: IdeologyFacade resolves a key to its index
    // in gate_keys and set_gate() drops anything past _gate_count, so a context
    // gate that no card requires yet (ctx.*) would be silently ignored.
    _gate_count=std::max(std::max(0,max_gate+1),static_cast<int32_t>(gate_keys.size())); _idea_words=(count+63)/64; _gate_words=(_gate_count+63)/64;
    return true;
}

Dictionary NativeIdeologyRuntime::configure(const Dictionary &catalog) {
    _configured=false; reset_runtime_state(); std::string error; if (!validate_catalog(catalog,error)) return fail(error); _catalog_hash=compute_catalog_hash(); _configured=true;
    // A configured runtime has no restore behind it, so there is nothing for the worker
    // to adopt and no imported catalog identity to remember yet.
    _worker_import_pending = false;
    _worker_import_last_code.clear();
    _worker_import_attempts = 0;
    _pod_catalog_hash = 0;
    if (_effect_runtime != nullptr && !resolve_synergy_override_tags(error)) {
        _configured = false;
        return fail(error);
    }
    // Hand the economy the declared consumer set: without it the digest covers
    // nothing and every managed card would sit frozen on a content change.
    publish_effect_input_consumers();
    // Plan §11.5: nothing is stamped here on purpose. The contract is computed wherever it
    // is needed (capture / restore / report), so it always describes the configuration in
    // force and cannot go stale behind a later `configure_effects`.
    Dictionary out; out["ok"]=true; out["catalog_hash"]=static_cast<int64_t>(_catalog_hash);
    out["execution_contract_hash"]=static_cast<int64_t>(compute_execution_contract_hash()); out["ideology_count"]=static_cast<int32_t>(_definitions.size()); return out;
}

} // namespace pk
