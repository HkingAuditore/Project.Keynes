#include "economy_invariant_probe.h"
#include "economy_runtime.h"
#include "runtime_economy_ecp2.h"
#include <memory>

namespace pk {
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
}
