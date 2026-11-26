#include "world_ext.h"
#include "country_ai_runtime.h"
#include "country_core_apply.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <array>
#include <limits>
#include <string>
#include <vector>

namespace pk {

using namespace godot;

bool DCWorldExt::runtime_country_ai_self_test() const {
    const auto fail = [](const char *what) {
        UtilityFunctions::printerr(String("[country ai self-test] ") + String(what));
        return false;
    };
    // Curves and utility composition.
    CountryAiCurve linear;
    linear.x0 = 0; linear.x1 = 100;
    if (country_ai_eval_curve(linear, 50) != COUNTRY_AI_Q16 / 2) return fail("linear_mid");
    if (country_ai_eval_curve(linear, -5) != 0 || country_ai_eval_curve(linear, 500) != COUNTRY_AI_Q16)
        return fail("linear_clamp");
    CountryAiCurve inverse = linear;
    inverse.y0_q16 = COUNTRY_AI_Q16; inverse.y1_q16 = 0;
    if (country_ai_eval_curve(inverse, 100) != 0) return fail("inverse");
    const int32_t ones[3] = {COUNTRY_AI_Q16, COUNTRY_AI_Q16, COUNTRY_AI_Q16};
    if (country_ai_combine_scores(ones, 3) != COUNTRY_AI_Q16) return fail("combine_one");
    const int32_t zero[2] = {COUNTRY_AI_Q16, 0};
    if (country_ai_combine_scores(zero, 2) != 0) return fail("combine_zero_veto");
    std::array<int32_t, COUNTRY_AI_DOMAIN_COUNT> weights{};
    if (!country_ai_normalize_weights({{1, 1, 1, 0}}, weights) ||
        weights[0] + weights[1] + weights[2] + weights[3] != 10000 || weights[3] != 0)
        return fail("weights_sum");

    // Synthetic world: 2 countries (slot 0 = player, excluded), 4 techs.
    RuntimeCountryPodCatalog pod;
    pod.catalog_hash = 77;
    pod.technology_count = 4;
    pod.technology_words = 1;
    pod.research_conditions_complete = true;
    pod.technology_costs = {10, 20, 30, 50};
    pod.technology_domains = {0, 1, 2, 0};
    pod.technology_flags = {0, 0, 0, 0};
    pod.prerequisite_offsets = {0, 0, 1, 2, 2};
    pod.prerequisites = {0, 1};
    pod.milestone_offsets = {0, 0, 0, 0, 2};
    pod.milestone_candidates = {1, 2};
    pod.milestone_required_counts = {0, 0, 0, 1};
    pod.entry_milestone_indices = {-1, -1, -1, -1};
    pod.research_condition_offsets = {0, 0, 0, 0, 0};
    RuntimeCountryPodSnapshot state;
    state.cell_count = 6;
    state.country_count = 2;
    state.technology_words = 1;
    state.technology_count = 4;
    state.catalog_hash = 77;
    state.country_active = {1, 1};
    state.country_generation = {1, 1};
    state.territory_count = {1, 2};
    state.country_cash = {1000000, 1000000};
    state.cell_country_slot = {0, 1, 1, -1, -1, -1};
    state.territory_offsets = {0, 1, 3};
    state.territory_cells = {0, 1, 2};
    state.country_technologies = {1, 1};
    state.country_discovered = {0xf, 0xf};
    state.country_pending_technologies = {0, 0};
    state.research_queues.assign(2 * 4 * 8, -1);
    state.research_queue_lengths.assign(8, 0);
    state.research_weights_bp = {2500, 2500, 2500, 2500, 2500, 2500, 2500, 2500};
    state.research_auto_purchase = {0, 0};
    state.country_tax_defaults.assign(10, 0);
    state.country_tax_default_modes.assign(10, 0);
    state.country_state_version = {0, 0};
    state.research_deferred_points = {0, 0};
    state.is_water = {0, 0, 0, 0, 0, 1};
    CountryAiCatalog catalog;
    catalog.seed = 9;
    CountryAiPersonality personality;
    personality.tax_min_bp = {{0, 0, 0, 0, 0}};
    personality.tax_max_bp = {{2000, 2000, 2000, 0, 0}};
    personality.tax_initial_bp = {{500, 300, 400, 0, 0}};
    catalog.personalities.push_back(personality);
    for (CountryAiAgendaDef &agenda : catalog.agendas) agenda.consideration_count = 0;
    CountryAiEconomyDigest digest;
    CountryAiEconomyRow row;
    row.country_handle = (uint64_t{1} << 32) | 1u;
    row.population = 100;
    row.satisfaction_q16 = COUNTRY_AI_Q16 * 3 / 4;
    digest.rows.push_back(row);
    const std::vector<int32_t> neighbors = {
        1, -1, -1, -1, -1, -1,  0, 2, -1, -1, -1, -1,  1, 3, -1, -1, -1, -1,
        2, 4, -1, -1, -1, -1,  3, 5, -1, -1, -1, -1,  4, -1, -1, -1, -1, -1};
    const auto run = [&](CountryAiRuntime &runtime, std::vector<CountryAiCommand> &out_commands) {
        std::string error;
        if (!runtime.configure(catalog, error)) return false;
        runtime.set_mode(CountryAiMode::ACTIVE);
        runtime.set_excluded_handles({(uint64_t{1} << 32) | 0u});
        runtime.set_topology(neighbors, {});
        if (!runtime.plan(1, state, pod, &digest, out_commands)) return false;
        runtime.commit(1);
        return true;
    };
    {
        CountryAiRuntime unarmed;
        std::string error;
        std::vector<CountryAiCommand> none;
        unarmed.configure(catalog, error);
        unarmed.set_mode(CountryAiMode::ACTIVE);
        if (unarmed.due(1) || unarmed.plan(1, state, pod, &digest, none))
            return fail("unarmed_planned");
    }
    CountryAiRuntime a, b;
    std::vector<CountryAiCommand> ca, cb;
    if (!run(a, ca) || !run(b, cb)) return fail("plan_failed");
    if (ca.empty()) return fail("no_commands");
    bool enqueue_tech1 = false;
    for (const CountryAiCommand &c : ca) {
        if (c.target_handle != ((uint64_t{1} << 32) | 1u)) return fail("player_controlled");
        enqueue_tech1 = enqueue_tech1 || (c.opcode == 6 && c.aux == 1 && c.domain == 1);
        RuntimeCountryPodPlan plan;
        RuntimeCountryPodSnapshot scratch = state;
        std::string error;
        const RuntimeCountryCommand rc = CountryAiRuntime::to_runtime_command(c, 1, 0);
        if (!country_core_apply_command(scratch, pod, rc, plan, error))
            return fail((std::string("command_invalid:") + error).c_str());
    }
    if (!enqueue_tech1) return fail("goal_path_missing");
    if (a.report().command_hash != b.report().command_hash || a.state_hash() != b.state_hash())
        return fail("nondeterministic");
    const std::vector<uint8_t> blob = a.encode();
    CountryAiRuntime c;
    std::string error;
    c.configure(catalog, error);
    if (!c.restore(blob.data(), blob.size(), error)) return fail(error.c_str());
    if (c.state_hash() != a.state_hash()) return fail("restore_hash");
    {
        CountryAiCatalog other = catalog;
        other.seed = catalog.seed + 1;
        CountryAiRuntime mismatched;
        mismatched.configure(other, error);
        if (mismatched.restore(blob.data(), blob.size(), error) || error != "catalog_hash_mismatch")
            return fail("catalog_mismatch_accepted");
    }
    std::vector<CountryAiCommand> next_a, next_c;
    c.set_mode(CountryAiMode::ACTIVE);
    c.set_topology(neighbors, {});
    const bool planned_a = a.plan(4, state, pod, &digest, next_a);
    const bool planned_c = c.plan(4, state, pod, &digest, next_c);
    if (!planned_a || planned_a != planned_c || next_a.size() != next_c.size())
        return fail("restore_divergence");
    a.commit(4);
    c.commit(4);
    if (a.state_hash() != c.state_hash()) return fail("restore_state_divergence");

    // Food subsidy: on above the hungry threshold, only on food building
    // types, applied as ordinary overrides, and cleared once hunger recedes.
    {
        constexpr int32_t inherit = std::numeric_limits<int32_t>::min();
        RuntimeCountryPodSnapshot fed = state;
        fed.building_type_count = 3;
        fed.country_business_tax_overrides.assign(6, inherit);
        fed.country_business_tax_mode_overrides.assign(6, inherit);
        CountryAiEconomyDigest hungry = digest;
        hungry.food_building_types = {1, 0, 1};
        hungry.rows[0].hungry_share_q16 = COUNTRY_AI_Q16 / 4;
        CountryAiRuntime s;
        std::vector<CountryAiCommand> cmds;
        s.configure(catalog, error);
        s.set_mode(CountryAiMode::ACTIVE);
        s.set_excluded_handles({(uint64_t{1} << 32) | 0u});
        if (!s.plan(1, fed, pod, &hungry, cmds)) return fail("subsidy_first_plan");
        s.commit(1);
        if (!s.plan(4, fed, pod, &hungry, cmds)) return fail("subsidy_plan");
        s.commit(4);
        int32_t on = 0;
        RuntimeCountryPodPlan plan;
        for (uint32_t i = 0; i < cmds.size(); ++i) {
            if (cmds[i].opcode != 12) continue;
            if (cmds[i].tax_kind != 2 || cmds[i].tax_item == 1 ||
                cmds[i].tax_rate_bp != catalog.subsidy_food_rate_bp)
                return fail("subsidy_command_shape");
            if (!country_core_apply_command(fed, pod, CountryAiRuntime::to_runtime_command(cmds[i], 4, i),
                                            plan, error))
                return fail((std::string("subsidy_apply:") + error).c_str());
            ++on;
        }
        if (on != 2 || fed.country_business_tax_overrides[3] != catalog.subsidy_food_rate_bp ||
            fed.country_business_tax_overrides[4] != inherit)
            return fail("subsidy_not_applied");
        hungry.rows[0].hungry_share_q16 = 0;
        if (!s.plan(9, fed, pod, &hungry, cmds)) return fail("subsidy_off_plan");
        s.commit(9);
        int32_t off = 0;
        for (uint32_t i = 0; i < cmds.size(); ++i) {
            if (cmds[i].opcode != 13) continue;
            if (!country_core_apply_command(fed, pod, CountryAiRuntime::to_runtime_command(cmds[i], 9, i),
                                            plan, error))
                return fail((std::string("subsidy_clear:") + error).c_str());
            ++off;
        }
        if (off != 2 || fed.country_business_tax_overrides[3] != inherit)
            return fail("subsidy_not_cleared");
    }
    return true;
}

} // namespace pk
