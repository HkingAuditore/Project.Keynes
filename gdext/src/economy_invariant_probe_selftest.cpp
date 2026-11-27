#include "economy_invariant_probe.h"
#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "economy_runtime_variant_helpers.h"
#include "fault_taxonomy.h"
#include "pk_build_id.h"
#include "runtime_economy_ecp2.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

bool EconomyInvariantProbe::run(std::string &error) {
    if (!run_demand_basis_cache(error)) return false;
    {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        RuntimeEconomyEcp2State incomplete;
        incomplete.authority_domain_mask = ECP2_DOMAIN_EPOCH_RESUME;
        incomplete.resume.epoch_active = 1;
        std::string refusal;
        if (economy->apply_ecp2_authority(incomplete, refusal) ||
            refusal != "ecp2_mid_epoch_resume_unsupported" ||
            economy->_bootstrapped || economy->_epoch_active) {
            error = "ecp2_incomplete_resume_not_rejected_before_install";
            return false;
        }
    }
    {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = 1;
        economy->_merchant_profession_id = 0;
        for (int32_t profession = 0; profession < 3; ++profession) {
            NativeEconomyRuntime::Signature signature;
            signature.profession_id = profession;
            economy->_signatures.push_back(signature);
        }
        NativeEconomyRuntime::BuildingType type;
        type.owner_slots_per_building = 1;
        economy->_building_types.push_back(type);
        auto &population = economy->population_store();
        population.clear(1);
        const int32_t merchant = population.allocate_slot(0, 0);
        const int32_t sponsor = population.allocate_slot(0, 1);
        const int32_t owner = population.allocate_slot(0, 2);
        for (int32_t slot : {merchant, sponsor, owner}) {
            population.population.write_scalar(slot, 10);
            population.funds.write_scalar(slot, slot == owner ? 0 : 100);
        }
        if (!economy->rebuild_merchant_ranges(error)) return false;
        NativeEconomyRuntime::InvestmentCandidatePlan own, borrowed;
        own.type_id = borrowed.type_id = 0;
        own.sponsor = merchant;
        own.owner_signature_id = 0;
        own.allocated_count = borrowed.allocated_count = 1;
        own.funding_capital = 90;
        borrowed.sponsor = sponsor;
        borrowed.owner_signature_id = 2;
        borrowed.merchant_credit = 90;
        const NativeEconomyRuntime::InvestmentCandidatePlan *plans[] = {&own, &borrowed};
        NativeEconomyRuntime::ConstructionMaterialPlan materials[2];
        for (auto &material : materials) {
            material.feasible = true;
            material.total_cost = 90;
        }
        if (economy->investment_portfolio_funds_feasible(0, plans, materials, 2) ||
            population.funds[merchant] != 100 || population.funds[sponsor] != 100 ||
            population.funds[owner] != 0 || population.population[sponsor] != 10) {
            error = "investment_portfolio_reused_merchant_construction_cash";
            return false;
        }
        // The construction guard must still reject the old funding sequence.
        population.funds.write_scalar(merchant, 10);
        NativeEconomyRuntime::Command command;
        command.i32_0 = command.i32_1 = 0;
        command.i64_0 = 1;
        economy->market_store().cell_to_market.resize(1);
        economy->market_store().cell_to_market.write_scalar(0, 0);
        std::string drift;
        if (economy->commit_preflighted_build_command(command, merchant,
                materials[0], 0, 0, 0, 0, drift) ||
            drift != "building_construction_preflight_funds_drift") {
            error = "investment_portfolio_construction_funds_guard_missing";
            return false;
        }
        // A construction-material drift is the second half of the same stage and
        // has no cursor either, so it must also leave a named row behind.
        {
            const godot::Dictionary context = economy->fatal_context_report();
            if (!context.has("construction_row")) {
                error = "fatal_context_missing_construction_row";
                return false;
            }
            const godot::Dictionary row = context["construction_row"];
            if (static_cast<int32_t>(static_cast<int64_t>(row["cell"])) != 0 ||
                static_cast<int32_t>(static_cast<int64_t>(row["type_id"])) != 0 ||
                static_cast<int64_t>(row["total_cost"]) != 90 ||
                static_cast<int64_t>(row["owner_funds"]) != 10 ||
                static_cast<int32_t>(static_cast<int64_t>(row["owner_slot"])) !=
                    merchant ||
                static_cast<int64_t>(row["allocated_count"]) != 1 ||
                static_cast<godot::String>(row["reason"]) !=
                    godot::String("building_construction_preflight_funds_drift")) {
                error = "fatal_context_construction_row_mismatch";
                return false;
            }
            // R1-7/R1-8: the row alone is not actionable without the ledger id and
            // a typed witness, and both must be present before fail() marks the
            // context valid (the player report is often taken from here).
            if (static_cast<godot::String>(context["assert_id"]) !=
                godot::String("INV-ECON-0042")) {
                error = "fatal_context_assert_id_mismatch";
                return false;
            }
            const godot::Dictionary witness = context["witness"];
            if (static_cast<int64_t>(witness["total_cost"]) != 90 ||
                static_cast<int64_t>(witness["owner_funds"]) != 10 ||
                static_cast<int32_t>(static_cast<int64_t>(witness["cell"])) != 0 ||
                static_cast<int32_t>(static_cast<int64_t>(
                    witness["portfolio_index"])) !=
                    static_cast<int32_t>(static_cast<int64_t>(
                        row["portfolio_index"]))) {
                error = "fatal_context_witness_mismatch";
                return false;
            }
        }
        population.funds.write_scalar(merchant, 100);
        borrowed.allocated_count = 0;
        if (!economy->investment_portfolio_funds_feasible(0, plans, materials, 2)) {
            error = "investment_portfolio_funded_prefix_rejected";
            return false;
        }
        borrowed.allocated_count = 1;
        population.funds.write_scalar(merchant, 200);
        if (!economy->investment_portfolio_funds_feasible(0, plans, materials, 2)) {
            error = "investment_portfolio_funded_credit_rejected";
            return false;
        }
        own.sponsor = sponsor;
        own.owner_signature_id = 2;
        own.funding_capital = borrowed.funding_capital = 60;
        borrowed.merchant_credit = 0;
        materials[0].total_cost = materials[1].total_cost = 60;
        if (economy->investment_portfolio_funds_feasible(0, plans, materials, 2)) {
            error = "investment_portfolio_reused_shared_sponsor_cash";
            return false;
        }
        population.funds.write_scalar(sponsor, 200);
        if (!economy->investment_portfolio_funds_feasible(0, plans, materials, 2)) {
            error = "investment_portfolio_funded_shared_owner_rejected";
            return false;
        }
    }
    for (bool family_sponsored : {true, false}) {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = 1;
        economy->_merchant_profession_id = 0;
        for (int32_t profession = 0; profession < 3; ++profession) {
            NativeEconomyRuntime::Signature signature;
            signature.profession_id = profession;
            economy->_signatures.push_back(signature);
        }
        NativeEconomyRuntime::BuildingType type;
        type.owner_slots_per_building = 1;
        economy->_building_types.push_back(type);
        economy->_building_types.push_back(type);
        auto &population = economy->population_store();
        population.clear(1);
        const int32_t merchant = population.allocate_slot(0, 0);
        const int32_t sponsor = population.allocate_slot(0, 1);
        const int32_t owner = population.allocate_slot(0, 2);
        for (int32_t slot : {merchant, sponsor, owner})
            population.population.write_scalar(slot, 10);

        // One person takes 100 out of 220. Cohort-average cash is only
        // 22, so the old preview accepted a 140 invoice on a 120 balance.
        population.funds.write_scalar(sponsor, 220);
        constexpr uint64_t family_handle = 1;
        const int64_t family_people = family_sponsored ? 2 : 9;
        const int64_t family_cash = family_sponsored ? 200 : 120;
        economy->family_memberships().push_back({
            family_handle, population.handle_for_slot(sponsor), family_people, family_cash,
            population.population[sponsor], population.funds[sponsor],
        });
        if (!economy->rebuild_merchant_ranges(error)) return false;

        NativeEconomyRuntime::InvestmentCandidatePlan transition, existing_owner;
        transition.type_id = 0;
        existing_owner.type_id = 1;
        transition.sponsor = existing_owner.sponsor = sponsor;
        transition.owner_signature_id = 2;
        existing_owner.owner_signature_id = 1;
        transition.sponsor_family_handle = family_sponsored ? family_handle : 0;
        existing_owner.sponsor_family_handle = family_handle;
        transition.allocated_count = existing_owner.allocated_count = 1;
        transition.funding_capital = 20;
        existing_owner.funding_capital = 140;
        const NativeEconomyRuntime::InvestmentCandidatePlan *plans[] = {&transition, &existing_owner};
        NativeEconomyRuntime::ConstructionMaterialPlan materials[2];
        materials[0].feasible = materials[1].feasible = true;
        materials[0].total_cost = 20;
        materials[1].total_cost = 140;
        materials[0].good_ids = materials[1].good_ids = {0};
        materials[0].quantities = materials[1].quantities = {1};
        if (!economy->investment_portfolio_funds_feasible(0, plans, materials, 1) ||
            economy->investment_portfolio_funds_feasible(0, plans, materials, 2) ||
            population.funds[sponsor] != 220 || population.funds[owner] != 0 ||
            economy->family_memberships()[0].cash_claim != family_cash) {
            error = family_sponsored ? "investment_portfolio_overlooked_family_transition_cash"
                : "investment_portfolio_overlooked_anonymous_transition_cash";
            return false;
        }
        materials[1].total_cost = 120;
        existing_owner.funding_capital = 120;
        if (!economy->investment_portfolio_funds_feasible(0, plans, materials, 2)) {
            error = "investment_portfolio_rejected_exactly_funded_transition";
            return false;
        }
        if (!economy->move_cohort_population(sponsor, 0, 2, 1, error,
                nullptr, transition.sponsor_family_handle, true)) return false;
        if (population.funds[sponsor] != 120 || population.funds[owner] != 100) {
            error = "investment_portfolio_transition_fixture_cash_mismatch";
            return false;
        }

        auto &market = economy->market_store();
        market.cell_to_market.resize(1);
        market.cell_to_market.write_scalar(0, 0);
        market.market_count = 1;
        market.good_count = 1;
        market.stock.resize(1);
        market.stock.write_scalar(0, 2);
        NativeEconomyRuntime::Command command;
        command.i32_0 = command.i32_1 = 0;
        command.i64_0 = 1;
        economy->_construction_sponsor_override_set = true;
        economy->_construction_sponsor_override = transition.sponsor_family_handle;
        if (!economy->commit_preflighted_build_command(command, owner,
                materials[0], 0, 0, 0, 0, error)) return false;
        command.i32_1 = existing_owner.type_id;
        economy->_construction_sponsor_override = existing_owner.sponsor_family_handle;
        if (!economy->commit_preflighted_build_command(command, sponsor,
                materials[1], 0, 0, 0, 0, error)) return false;
        if (economy->pending_construction_count() != 2 || market.stock[0] != 0 ||
            population.funds[merchant] != 140 || population.funds[owner] != 80 ||
            population.funds[sponsor] != 0) {
            error = "investment_portfolio_transition_construction_not_conserved";
            return false;
        }
    }
    // A later portfolio leg can name a sponsor cohort the epoch has already
    // emptied: move_cohort_population() keeps a released slot's signature id, so
    // the leg still reads as a funded profession transition and returns success
    // without moving a single unit (economy_runtime.cpp:1675-1677). The commit
    // used to write the leg and only then fail the balance assertion with
    // building_investment_capital_preflight_drift, which froze a player's game
    // at day 12236. The pre-write gate must trim that leg instead and keep the
    // funded one, with money and population conserved.
    {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = 1;
        economy->_merchant_profession_id = 0;
        for (int32_t profession = 0; profession < 4; ++profession) {
            NativeEconomyRuntime::Signature signature;
            signature.profession_id = profession;
            economy->_signatures.push_back(signature);
        }
        NativeEconomyRuntime::BuildingType type;
        type.owner_slots_per_building = 1;
        economy->_building_types.push_back(type);
        economy->_building_types.push_back(type);
        auto &population = economy->population_store();
        population.clear(1);
        const int32_t merchant = population.allocate_slot(0, 0);
        const int32_t exhausted = population.allocate_slot(0, 1);
        const int32_t owner = population.allocate_slot(0, 2);
        const int32_t funded = population.allocate_slot(0, 3);
        population.population.write_scalar(merchant, 10);
        population.funds.write_scalar(merchant, 1000);
        population.population.write_scalar(funded, 2);
        population.funds.write_scalar(funded, 100);
        if (!economy->rebuild_merchant_ranges(error)) return false;
        // Exactly the state a drained move leaves behind: lanes cleared, slot
        // released, signature id retained (economy_runtime.cpp:1862-1865).
        population.population.write_scalar(exhausted, 0);
        population.funds.write_scalar(exhausted, 0);
        population.release_slot(exhausted);
        if (population.population[exhausted] != 0 ||
            population.funds[exhausted] != 0 ||
            population.active[exhausted] != 0 ||
            population.signature_id[exhausted] != 1) {
            error = "investment_portfolio_exhausted_sponsor_fixture_state";
            return false;
        }

        NativeEconomyRuntime::BuildingInvestmentCellContext ctx(0);
        ctx.portfolio_size = 2;
        for (int32_t i = 0; i < ctx.portfolio_size; ++i) {
            auto &plan = ctx.portfolio[i].plan;
            plan.cell = 0;
            plan.allocated_count = 1;
            plan.owner_signature_id = 2;
            plan.owner_slots = 1;
            plan.funding_capital = 10;
            ctx.commit_material_plans[i].feasible = true;
            ctx.commit_material_plans[i].total_cost = 10;
            ctx.commit_material_plans[i].good_ids = {0};
            ctx.commit_material_plans[i].quantities = {1};
        }
        ctx.portfolio[0].plan.type_id = 0;
        ctx.portfolio[0].plan.sponsor = exhausted;
        ctx.portfolio[1].plan.type_id = 1;
        ctx.portfolio[1].plan.sponsor = funded;

        auto &market = economy->market_store();
        market.cell_to_market.resize(1);
        market.cell_to_market.write_scalar(0, 0);
        market.market_count = 1;
        market.good_count = 1;
        market.stock.resize(1);
        market.stock.write_scalar(0, 2);

        int64_t funds_before = 0;
        int64_t population_before = 0;
        for (int32_t slot : {merchant, exhausted, owner, funded}) {
            funds_before += population.funds[slot];
            population_before += population.population[slot];
        }
        bool population_changed = false;
        std::string commit_error;
        if (!economy->investment_commit_portfolio(ctx, population_changed,
                commit_error)) {
            // Reproduce the fail() forensics path on this very leg so the
            // failure message carries what the player report would show.
            economy->capture_fatal_context(commit_error);
            const godot::Dictionary report = economy->fatal_context_report();
            const godot::Dictionary row = report.get("investment_row",
                godot::Dictionary());
            const auto field = [&](const char *key, int64_t fallback) {
                return static_cast<int64_t>(row.get(key, fallback));
            };
            const godot::String excerpt = godot::String(" [fatal_context] valid=") +
                godot::String::num_int64(
                    bool(report.get("valid", false)) ? 1 : 0) +
                godot::String(" reason=") +
                godot::String(std::string(commit_error).c_str()) +
                godot::String(" cell=") + godot::String::num_int64(field("cell", -1)) +
                godot::String(" type_id=") + godot::String::num_int64(field("type_id", -1)) +
                godot::String(" leg=") + godot::String::num_int64(field("portfolio_index", -1)) +
                godot::String("/") + godot::String::num_int64(field("portfolio_size", 0)) +
                godot::String(" allocated=") + godot::String::num_int64(field("allocated_count", 0)) +
                godot::String(" required_capital=") + godot::String::num_int64(field("required_capital", 0)) +
                godot::String(" carried=") + godot::String::num_int64(field("carried", 0)) +
                godot::String(" correction=") + godot::String::num_int64(field("correction", 0)) +
                godot::String(" sponsor_slot=") + godot::String::num_int64(field("sponsor_slot", -1)) +
                godot::String(" sponsor_population=") + godot::String::num_int64(field("sponsor_population", 0)) +
                godot::String(" sponsor_funds=") + godot::String::num_int64(field("sponsor_funds", 0)) +
                godot::String(" source_drained=") +
                godot::String::num_int64(bool(row.get("source_drained", false)) ? 1 : 0) +
                godot::String(" branch=") + godot::String::num_int64(field("branch", 0));
            error = std::string(
                "investment_portfolio_exhausted_sponsor_not_trimmed:") +
                commit_error + std::string(excerpt.utf8().get_data());
            return false;
        }
        if (ctx.portfolio[0].plan.allocated_count != 0 ||
            ctx.portfolio[1].plan.allocated_count != 1 ||
            economy->pending_construction_count() != 1 ||
            economy->_building_investment_capital_limited != 1 ||
            population.population[funded] != 1 ||
            population.population[owner] != 1 ||
            population.funds[funded] != 50 || population.funds[owner] != 40 ||
            population.funds[merchant] != 1010 ||
            market.stock[0] != 1) {
            error = "investment_portfolio_exhausted_sponsor_trim_mismatch";
            return false;
        }
        int64_t funds_after = 0;
        int64_t population_after = 0;
        for (int32_t slot : {merchant, exhausted, owner, funded}) {
            funds_after += population.funds[slot];
            population_after += population.population[slot];
        }
        if (funds_before != funds_after || population_before != population_after) {
            error = "investment_portfolio_exhausted_sponsor_broke_conservation";
            return false;
        }
        // The leg trace must be readable from the fatal-context report even for a
        // successful commit: it is the only record of what each leg actually
        // carried/paid when the player cannot send the save.
        {
            const godot::Dictionary report = economy->fatal_context_report();
            const godot::Array legs = report.get("investment_legs", godot::Array());
            if (legs.is_empty()) {
                error = "fatal_context_missing_investment_legs";
                return false;
            }
            const godot::Dictionary leg = legs[legs.size() - 1];
            if (static_cast<int64_t>(leg.get("material_cost", -1)) < 0 ||
                static_cast<int64_t>(leg.get("owner_funds_at_material", -1)) < 0 ||
                static_cast<int64_t>(leg.get("required_capital", 0)) <= 0) {
                error = "fatal_context_investment_leg_incomplete";
                return false;
            }
        }
    }
    // The fatal context must carry the failing investment leg, not just a reason
    // string: FatalContext cannot recover a row for BUILDING_COMMIT, so
    // record_investment_fatal_row() feeds a nested `investment_row` object that
    // runtime_forensics.gd serialises into
    // [runtime-forensics/<tag>/fatal-context].
    {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = 1;
        economy->_merchant_profession_id = 0;
        NativeEconomyRuntime::Signature signature;
        signature.profession_id = 0;
        economy->_signatures.push_back(signature);
        auto &population = economy->population_store();
        population.clear(1);
        const int32_t sponsor = population.allocate_slot(0, 0);
        population.population.write_scalar(sponsor, 3);
        population.funds.write_scalar(sponsor, 77);
        NativeEconomyRuntime::InvestmentCandidatePlan plan;
        plan.cell = 0;
        plan.type_id = 0;
        plan.sponsor = sponsor;
        plan.owner_signature_id = 0;
        plan.allocated_count = 2;
        plan.funding_capital = 40;
        plan.merchant_credit = 5;
        economy->record_investment_fatal_row(0, plan, 1, 3, 2, 2, 80, 30, 50,
            0, 30, false);
        if (!economy->_investment_fatal_row.valid) {
            error = "fatal_context_investment_row_not_recorded";
            return false;
        }
        // The row must survive into the report even before fail() marks the
        // context valid, which is how the probe and any early reporter see it.
        const godot::Dictionary early_context = economy->fatal_context_report();
        if (!early_context.has("investment_row")) {
            error = "fatal_context_investment_row_hidden_before_fatal";
            return false;
        }
        economy->_fatal_context.valid = true;
        economy->_fatal_context.reason =
            "building_investment_capital_preflight_drift";
        const godot::Dictionary context = economy->fatal_context_report();
        if (!context.has("investment_row")) {
            error = "fatal_context_missing_investment_row";
            return false;
        }
        const godot::Dictionary row = context["investment_row"];
        if (static_cast<int32_t>(static_cast<int64_t>(row["cell"])) != 0 ||
            static_cast<int32_t>(static_cast<int64_t>(row["type_id"])) != 0 ||
            static_cast<int32_t>(static_cast<int64_t>(row["portfolio_index"])) != 1 ||
            static_cast<int32_t>(static_cast<int64_t>(row["portfolio_size"])) != 3 ||
            static_cast<int32_t>(static_cast<int64_t>(row["branch"])) != 2 ||
            static_cast<int64_t>(row["allocated_count"]) != 2 ||
            static_cast<int64_t>(row["required_capital"]) != 80 ||
            static_cast<int64_t>(row["carried"]) != 30 ||
            static_cast<int64_t>(row["correction"]) != 50 ||
            static_cast<int32_t>(static_cast<int64_t>(row["sponsor_slot"])) != sponsor ||
            static_cast<int64_t>(row["sponsor_population"]) != 3 ||
            static_cast<int64_t>(row["sponsor_funds"]) != 77) {
            error = "fatal_context_investment_row_mismatch";
            return false;
        }
        // R1-7/R1-8: the leg also names its ledger id and typed witness.
        if (static_cast<godot::String>(context["assert_id"]) !=
            godot::String("INV-ECON-0040")) {
            error = "fatal_context_investment_assert_id_mismatch";
            return false;
        }
        const godot::Dictionary witness = context["witness"];
        if (static_cast<int32_t>(static_cast<int64_t>(witness["branch"])) != 2 ||
            static_cast<int64_t>(witness["required_capital"]) != 80 ||
            static_cast<int64_t>(witness["correction"]) != 50 ||
            static_cast<int32_t>(static_cast<int64_t>(
                witness["portfolio_index"])) != 1) {
            error = "fatal_context_investment_witness_mismatch";
            return false;
        }
        // R1-6: every stop names the binary that produced it ("<sha>+<utc>").
        const godot::String build_id = context["build_id"];
        if (build_id.is_empty() || !build_id.contains("+")) {
            error = "fatal_context_build_id_missing";
            return false;
        }
    }
    // The gate must cover the whole top-up window, not just "sponsor cannot pay
    // at all". A sponsor with 2 people and 90 cash moving one owner carries 45,
    // so after the transfer it holds 45 while the top-up needs 55 and
    // required_capital is 100. The backstop reads the sponsor AFTER the
    // transfer ((90 - 45) < (100 - 45)), so gating on the narrow form
    // `funds < required - carried` (90 < 55) would miss this leg and the fatal
    // would survive. The gate must trim it before any write.
    {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = 1;
        economy->_merchant_profession_id = 0;
        for (int32_t profession = 0; profession < 3; ++profession) {
            NativeEconomyRuntime::Signature signature;
            signature.profession_id = profession;
            economy->_signatures.push_back(signature);
        }
        NativeEconomyRuntime::BuildingType type;
        type.owner_slots_per_building = 1;
        economy->_building_types.push_back(type);
        auto &population = economy->population_store();
        population.clear(1);
        const int32_t merchant = population.allocate_slot(0, 0);
        const int32_t sponsor = population.allocate_slot(0, 1);
        const int32_t owner = population.allocate_slot(0, 2);
        population.population.write_scalar(merchant, 10);
        population.funds.write_scalar(merchant, 1000);
        population.population.write_scalar(sponsor, 2);
        population.funds.write_scalar(sponsor, 90);
        if (!economy->rebuild_merchant_ranges(error)) return false;
        NativeEconomyRuntime::BuildingInvestmentCellContext ctx(0);
        ctx.portfolio_size = 1;
        auto &plan = ctx.portfolio[0].plan;
        plan.cell = 0;
        plan.type_id = 0;
        plan.sponsor = sponsor;
        plan.owner_signature_id = 2;
        plan.owner_slots = 1;
        plan.allocated_count = 1;
        plan.funding_capital = 100;
        ctx.commit_material_plans[0].feasible = true;
        ctx.commit_material_plans[0].total_cost = 10;
        ctx.commit_material_plans[0].good_ids = {0};
        ctx.commit_material_plans[0].quantities = {1};
        bool population_changed = false;
        std::string commit_error;
        if (!economy->investment_commit_portfolio(ctx, population_changed,
                commit_error)) {
            error = std::string(
                "investment_portfolio_top_up_window_not_trimmed:") + commit_error;
            return false;
        }
        if (ctx.portfolio[0].plan.allocated_count != 0 ||
            economy->_building_investment_capital_limited != 1 ||
            economy->pending_construction_count() != 0 ||
            population.funds[sponsor] != 90 ||
            population.population[sponsor] != 2 ||
            population.funds[owner] != 0 || population.population[owner] != 0 ||
            ctx.active_types != 0 || ctx.total_buildings != 0 ||
            ctx.total_owner_population != 0) {
            error = "investment_portfolio_top_up_window_write_happened";
            return false;
        }
    }
    // With nothing trimmed the recomputed aggregates must equal what the
    // preflight summed: the new recompute block may not double count.
    {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = 1;
        economy->_merchant_profession_id = 0;
        for (int32_t profession = 0; profession < 4; ++profession) {
            NativeEconomyRuntime::Signature signature;
            signature.profession_id = profession;
            economy->_signatures.push_back(signature);
        }
        NativeEconomyRuntime::BuildingType type;
        type.owner_slots_per_building = 1;
        economy->_building_types.push_back(type);
        economy->_building_types.push_back(type);
        auto &population = economy->population_store();
        population.clear(1);
        const int32_t merchant = population.allocate_slot(0, 0);
        const int32_t first = population.allocate_slot(0, 1);
        const int32_t owner = population.allocate_slot(0, 2);
        const int32_t second = population.allocate_slot(0, 3);
        population.population.write_scalar(merchant, 10);
        population.funds.write_scalar(merchant, 1000);
        for (int32_t slot : {first, second}) {
            population.population.write_scalar(slot, 2);
            population.funds.write_scalar(slot, 100);
        }
        if (!economy->rebuild_merchant_ranges(error)) return false;
        NativeEconomyRuntime::BuildingInvestmentCellContext ctx(0);
        ctx.portfolio_size = 2;
        for (int32_t i = 0; i < ctx.portfolio_size; ++i) {
            auto &leg = ctx.portfolio[i].plan;
            leg.cell = 0;
            leg.type_id = i;
            leg.allocated_count = 1;
            leg.owner_signature_id = 2;
            leg.owner_slots = 1;
            leg.funding_capital = 10;
            ctx.commit_material_plans[i].feasible = true;
            ctx.commit_material_plans[i].total_cost = 10;
            ctx.commit_material_plans[i].good_ids = {0};
            ctx.commit_material_plans[i].quantities = {1};
        }
        ctx.portfolio[0].plan.sponsor = first;
        ctx.portfolio[1].plan.sponsor = second;
        auto &market = economy->market_store();
        market.cell_to_market.resize(1);
        market.cell_to_market.write_scalar(0, 0);
        market.market_count = 1;
        market.good_count = 1;
        market.stock.resize(1);
        market.stock.write_scalar(0, 2);
        bool population_changed = false;
        std::string commit_error;
        if (!economy->investment_commit_portfolio(ctx, population_changed,
                commit_error)) {
            error = std::string("investment_portfolio_no_trim_commit_failed:") +
                commit_error;
            return false;
        }
        if (ctx.active_types != 2 || ctx.total_buildings != 2 ||
            ctx.total_owner_population != 2 ||
            economy->_building_investment_capital_limited != 0 ||
            economy->pending_construction_count() != 2 ||
            population.funds[merchant] != 1020 ||
            population.funds[first] != 50 || population.funds[second] != 50 ||
            population.funds[owner] != 80 ||
            population.population[owner] != 2 || market.stock[0] != 0) {
            error = "investment_portfolio_no_trim_aggregates_wrong";
            return false;
        }
    }
    // A cohort can leave the merchant profession during employment while the
    // cached merchant CSR still names its old slot. Debt service must never
    // debit an owner when that cache has no living recipient (day 10315).
    {
        auto economy = std::make_unique<NativeEconomyRuntime>();
        economy->_cell_count = 1;
        economy->_merchant_profession_id = 0;
        NativeEconomyRuntime::Signature merchant_signature;
        merchant_signature.profession_id = 0;
        NativeEconomyRuntime::Signature owner_signature;
        owner_signature.profession_id = 1;
        economy->_signatures.push_back(merchant_signature);
        economy->_signatures.push_back(owner_signature);
        auto &population = economy->population_store();
        population.clear(1);
        const int32_t merchant = population.allocate_slot(0, 0);
        const int32_t owner = population.allocate_slot(0, 1);
        population.population.write_scalar(merchant, 1);
        population.population.write_scalar(owner, 1);
        population.funds.write_scalar(owner, 100000);
        if (!economy->rebuild_merchant_ranges(error)) return false;
        population.population.write_scalar(merchant, 0);
        NativeEconomyRuntime::BuildingGroup debt;
        debt.cell = 0;
        debt.owner_signature_id = 1;
        debt.count = 1;
        debt.merchant_debt_principal = 11166;
        debt.merchant_debt_term_cycles_left = 1;
        const size_t group = economy->append_building_group(debt);
        int64_t premium = 0;
        int64_t paid = 0;
        {
            auto row = economy->building_at(group);
            paid = economy->repay_building_debt(0, owner, row, 11166, premium);
        }
        if (paid != 0 ||
            population.funds[owner] != 100000 || premium != 0 ||
            economy->buildings_store().merchant_debt_principal[group] != 11166) {
            error = "merchant_debt_missing_receiver_burned_owner_cash";
            return false;
        }
        int64_t repairs = 0;
        if (!economy->ensure_merchant_invariant(0, repairs, error) ||
            repairs != 1 || !economy->_merchant_ranges_dirty ||
            !economy->refresh_merchant_ranges_if_dirty(error) ||
            economy->_merchant_ranges_dirty ||
            economy->_merchant_slots != std::vector<int32_t>{owner}) {
            error = "merchant_replacement_did_not_refresh_receiver_csr";
            return false;
        }
        const int32_t debtor = population.allocate_slot(0, 1);
        population.population.write_scalar(debtor, 1);
        population.funds.write_scalar(owner, 0);
        population.funds.write_scalar(debtor, 100000);
        {
            auto row = economy->building_at(group);
            paid = economy->repay_building_debt(0, debtor, row, 11166, premium);
        }
        if (paid != 11166 ||
            population.funds[debtor] != 88834 ||
            population.funds[owner] != 11166 ||
            population.funds[merchant] != 0 ||
            economy->buildings_store().merchant_debt_principal[group] != 0) {
            error = "merchant_debt_receiver_retry_did_not_conserve_cash";
            return false;
        }
    }
    return true;
}

} // namespace pk
