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

namespace {

// --- `.pkinc` reading helpers -------------------------------------------------
// The bundle is the merge of incident.json + witness.json + cell.json (see
// docs/runtime/incident-bundle-schema.md), so every section may arrive either as
// a nested object or flattened onto the top-level dictionary.

bool pk_is_dictionary(const godot::Variant &value) {
    return value.get_type() == godot::Variant::DICTIONARY;
}

bool pk_is_array(const godot::Variant &value) {
    return value.get_type() == godot::Variant::ARRAY;
}

// Array section of a bundle object, or an empty array when the section is absent
// (a minimal incident may carry only `reason` + `witness`).
godot::Array pk_dict_array(const godot::Dictionary &dict, const char *key) {
    const godot::StringName name(key);
    if (!dict.has(name)) return godot::Array();
    const godot::Variant value = dict[name];
    return pk_is_array(value) ? godot::Array(value) : godot::Array();
}

godot::String pk_text(const std::string &value) {
    return godot::String::utf8(value.data(), static_cast<int64_t>(value.size()));
}

// JSON has a single number type, so a witness read back from a `.pkinc` arrives
// as float (and a bool the GDScript emitter writes as 1/0 arrives as int) while
// the C++ row holds int64/bool. Comparing Variant tags would make every integer
// field of every real bundle "differ", so compare numbers by value.
bool pk_value_matches(const godot::Variant &expected, const godot::Variant &actual) {
    const godot::Variant::Type expected_type = expected.get_type();
    const godot::Variant::Type actual_type = actual.get_type();
    if (expected_type == actual_type) return expected == actual;
    const auto is_number = [](godot::Variant::Type type) {
        return type == godot::Variant::INT || type == godot::Variant::FLOAT ||
            type == godot::Variant::BOOL;
    };
    if (!is_number(expected_type) || !is_number(actual_type))
        return expected == actual;
    if (expected_type == godot::Variant::BOOL || actual_type == godot::Variant::BOOL)
        return static_cast<bool>(expected) == static_cast<bool>(actual);
    const auto as_int = [](const godot::Variant &value, int64_t &out) {
        if (value.get_type() == godot::Variant::INT) {
            out = static_cast<int64_t>(value);
            return true;
        }
        const double number = static_cast<double>(value);
        if (number != std::floor(number) || number < -9.0e18 || number > 9.0e18)
            return false;
        out = static_cast<int64_t>(value);
        return true;
    };
    int64_t expected_int = 0;
    int64_t actual_int = 0;
    if (as_int(expected, expected_int) && as_int(actual, actual_int))
        return expected_int == actual_int;
    return static_cast<double>(expected) == static_cast<double>(actual);
}

// Witness fields compared field by field, in ledger order. `reason` is excluded:
// the same witness shape backs both construction drifts and the reason check is
// done separately.
const char *const kConstructionWitnessFields[] = {
    "cell", "type_id", "allocated_count", "total_cost", "owner_slot",
    "owner_funds", "funding_gap", "debt_principal", "material_feasible",
    "good_count", "first_good_id", "first_required", "first_stock",
    "portfolio_index", "portfolio_size"};
const char *const kInvestmentWitnessFields[] = {
    "branch", "cell", "type_id", "portfolio_index", "portfolio_size",
    "allocated_count", "owner_population", "funding_capital", "merchant_credit",
    "required_capital", "carried", "correction", "sponsor_slot",
    "sponsor_population", "sponsor_funds", "owner_slot", "owner_funds",
    "source_drained"};

}  // namespace

Dictionary EconomyInvariantProbe::replay_incident(const Dictionary &incident) {
    using variant_helpers::dict_num;
    using variant_helpers::dict_string;
    constexpr int kConstructionFieldCount =
        static_cast<int>(sizeof(kConstructionWitnessFields) /
                         sizeof(kConstructionWitnessFields[0]));
    constexpr int kInvestmentFieldCount =
        static_cast<int>(sizeof(kInvestmentWitnessFields) /
                         sizeof(kInvestmentWitnessFields[0]));

    Dictionary out;
    Array diff;
    out["reproduced"] = false;
    out["assert_id"] = String();
    out["assert_id_actual"] = String();
    out["reason"] = String();
    out["reason_actual"] = String();
    out["assert_fired"] = false;
    out["witness_before"] = Dictionary();
    out["witness_after"] = Dictionary();
    out["diff"] = diff;
    out["missing"] = Array();
    out["fixture_notes"] = Array();
    out["uncompared"] = Array();
    out["detail"] = String();
    // R1-6: a replayed incident must name the binary that replayed it; a report
    // that reproduces on a different build is not the same evidence.
    out["build_id"] = String::utf8(pk::pk_build_id());

    // --- 1. identity --------------------------------------------------------
    // `reason` is authoritative (the schema requires it). `assert_id` may be
    // empty in the bundle when the ledger had no entry at capture time.
    std::string reason = dict_string(incident, "reason");
    std::string assert_id = dict_string(incident, "assert_id");
    if (assert_id.empty()) assert_id = pk::fault_assert_id(reason.c_str());
    if (reason.empty() && !assert_id.empty())
        reason = pk::fault_reason_for_assert_id(assert_id.c_str());
    out["assert_id"] = pk_text(assert_id);
    out["reason"] = pk_text(reason);
    if (reason.empty()) {
        out["detail"] = String(
            "incident_reason_missing: neither reason nor a registered assert_id");
        return out;
    }

    Dictionary witness;
    if (incident.has(StringName("witness")) &&
        pk_is_dictionary(incident[StringName("witness")]))
        witness = Dictionary(incident[StringName("witness")]);
    if (witness.is_empty()) witness = incident;
    Dictionary cell_slice;
    if (incident.has(StringName("cell")) &&
        pk_is_dictionary(incident[StringName("cell")]))
        cell_slice = Dictionary(incident[StringName("cell")]);
    else
        cell_slice = incident;
    out["witness_before"] = witness;

    const bool construction = reason == "building_construction_preflight_funds_drift" ||
        reason == "building_construction_preflight_stock_drift";
    const bool investment = reason == "building_investment_capital_preflight_drift";
    if (!construction && !investment) {
        // save_family_expedition_person_invalid and any future reason have no
        // isolated entry point: reproduce needs the PKEC restore path plus the
        // full person/family tables, which a `.pkinc` deliberately does not
        // carry. Say so instead of failing silently.
        out["detail"] = pk_text(
            "assert_point_not_replayable: " + reason +
            " has no isolated entry point (needs the PKEC restore path and the "
            "full person/family tables, which a .pkinc does not carry)");
        return out;
    }

    // --- 2. minimal world ---------------------------------------------------
    // Cell index: the witness names a world cell and the assertion records the
    // cell it was handed, so the fixture mirrors that index instead of always
    // using 0 — otherwise every real bundle differs on `cell` by construction.
    // A bundle that names no cell (or an implausible one) falls back to 0 and
    // the remap is published in `fixture_notes`.
    Array fixture_notes;
    const int64_t witness_cell = dict_num<int64_t>(witness, "cell",
        dict_num<int64_t>(cell_slice, "cell", 0));
    constexpr int64_t kMaxFixtureCells = 65536;
    const int32_t fixture_cell =
        (witness_cell >= 0 && witness_cell < kMaxFixtureCells)
            ? static_cast<int32_t>(witness_cell) : 0;
    if (witness_cell != fixture_cell) {
        fixture_notes.push_back(String("cell_remap:") +
            String::num_int64(witness_cell) + String("->") +
            String::num_int64(fixture_cell));
    }
    const int32_t cell_count = fixture_cell + 1;
    auto economy = std::make_unique<NativeEconomyRuntime>();
    economy->_cell_count = cell_count;
    economy->_merchant_profession_id = 0;
    auto &population = economy->population_store();
    population.clear(cell_count);

    // Slot layout. `is_merchant_slot()` is "active && population > 0 && the slot's
    // signature profession == _merchant_profession_id", and rebuild_merchant_ranges()
    // runs ensure_merchant_invariant(), which (a) needs a *living* merchant in the
    // cell and (b) needs a signature with the merchant profession for that cohort's
    // ethnicity. A fixture that skips both used to stop here with
    // merchant_signature_missing_for_ethnicity, which killed every replay of a real
    // cell.json before it reached the assertion.
    const Array cohorts = pk_dict_array(cell_slice, "cohorts");
    const Array merchants = pk_dict_array(cell_slice, "merchants");
    const int64_t owner_funds_hint = dict_num<int64_t>(witness, "owner_funds", -1);
    const int64_t owner_people_hint = dict_num<int64_t>(witness, "owner_population", -1);
    const int64_t sponsor_funds_hint = dict_num<int64_t>(witness, "sponsor_funds", -1);
    const int64_t sponsor_people_hint = dict_num<int64_t>(witness, "sponsor_population", -1);
    // Which cohort is the owner / sponsor, judged by the values the witness
    // recorded (cell.json has no slot ids of its own).
    const auto match_cohort_index = [&](int64_t funds, int64_t people,
                                        int32_t fallback) -> int32_t {
        int32_t single = -1;
        int32_t seen = 0;
        for (int i = 0; i < cohorts.size(); ++i) {
            if (!pk_is_dictionary(cohorts[i])) continue;
            ++seen;
            single = i;
            const Dictionary cohort = cohorts[i];
            if (funds >= 0 && dict_num<int64_t>(cohort, "funds", -1) != funds) continue;
            if (people >= 0 && dict_num<int64_t>(cohort, "population", -1) != people) continue;
            return i;
        }
        return seen == 1 ? single : fallback;
    };
    const int32_t owner_cohort = match_cohort_index(owner_funds_hint,
        owner_people_hint, -1);
    const int32_t sponsor_cohort = match_cohort_index(sponsor_funds_hint,
        sponsor_people_hint, -1);
    // Pad with empty cohorts so the role the assertion reads lands on the slot id
    // the witness recorded. Without this the replayed row always reports slot 0
    // and `owner_slot` differs even though the fixture is otherwise identical.
    constexpr int64_t kMaxFixtureSlots = 4096;
    const int32_t anchor_target = construction
        ? static_cast<int32_t>(dict_num<int64_t>(witness, "owner_slot", -1))
        : static_cast<int32_t>(dict_num<int64_t>(witness, "sponsor_slot",
            dict_num<int64_t>(witness, "owner_slot", -1)));
    const int32_t anchor_cohort = construction
        ? (owner_cohort >= 0 ? owner_cohort : 0)
        : (sponsor_cohort >= 0 ? sponsor_cohort : (owner_cohort >= 0 ? owner_cohort : 0));
    int32_t pad_slots = 0;
    if (anchor_target > anchor_cohort && anchor_target < kMaxFixtureSlots) {
        pad_slots = anchor_target - anchor_cohort;
        fixture_notes.push_back(String("slot_padding:") +
            String::num_int64(pad_slots));
    }
    // Padding cohorts keep population 0, so they never count as a merchant or as
    // a sponsor the invariant repair could pick.
    const auto make_signature = [&](int32_t profession) -> uint32_t {
        NativeEconomyRuntime::Signature signature;
        signature.profession_id = profession;
        // cell.json carries no ethnicity column; merchant repair looks up
        // (profession, ethnicity), so a consistent value is required.
        signature.ethnicity_id = 0;
        economy->_signatures.push_back(signature);
        return static_cast<uint32_t>(economy->_signatures.size() - 1);
    };
    std::vector<int32_t> slots;
    const auto add_slot = [&](int32_t signature_id, int64_t people,
                              int64_t funds) -> int32_t {
        const int32_t slot = population.allocate_slot(fixture_cell,
            static_cast<uint32_t>(signature_id));
        population.population.write_scalar(slot, people);
        population.funds.write_scalar(slot, funds);
        return slot;
    };
    constexpr int32_t kPadProfession = -1;
    for (int32_t pad = 0; pad < pad_slots; ++pad) {
        slots.push_back(add_slot(static_cast<int32_t>(make_signature(kPadProfession)),
            0, 0));
    }
    for (int i = 0; i < cohorts.size(); ++i) {
        if (!pk_is_dictionary(cohorts[i])) continue;
        const Dictionary cohort = cohorts[i];
        const int32_t signature = static_cast<int32_t>(make_signature(
            dict_num<int32_t>(cohort, "profession", 0)));
        // Array order defines the slot order, so a witness slot index can be
        // resolved back to the cohort that produced it.
        slots.push_back(add_slot(signature,
            dict_num<int64_t>(cohort, "population", 0),
            dict_num<int64_t>(cohort, "funds", 0)));
    }
    const auto add_cohort = [&](int64_t people, int64_t funds) -> int32_t {
        const int32_t slot = add_slot(
            static_cast<int32_t>(make_signature(0)), people, funds);
        slots.push_back(slot);
        return slot;
    };
    // Merchant identity. `merchants[]` names the runtime slot of the market maker,
    // so the merchant profession is taken from that cohort; when the slice has no
    // usable merchant row the profession is synthesized above every cohort
    // profession and one dedicated cohort is added (cell.json has no identity
    // columns — this is the documented degradation, recorded in `fixture_notes`).
    int32_t merchant_profession = -1;
    for (int i = 0; i < merchants.size() && merchant_profession < 0; ++i) {
        if (!pk_is_dictionary(merchants[i])) continue;
        const int64_t merchant_slot = dict_num<int64_t>(Dictionary(merchants[i]),
            "slot", -1);
        if (merchant_slot < 0 || merchant_slot >= static_cast<int64_t>(slots.size()))
            continue;
        const int32_t slot = slots[static_cast<size_t>(merchant_slot)];
        const uint32_t signature = population.signature_id[slot];
        if (signature < economy->_signatures.size() &&
            economy->_signatures[signature].profession_id != kPadProfession) {
            merchant_profession =
                economy->_signatures[signature].profession_id;
        }
    }
    if (merchant_profession < 0) {
        merchant_profession = 0;
        for (const NativeEconomyRuntime::Signature &signature : economy->_signatures)
            merchant_profession = std::max<int32_t>(merchant_profession,
                signature.profession_id + 1);
        fixture_notes.push_back(String("merchant_profession_synthesized:") +
            String::num_int64(merchant_profession));
    }
    economy->_merchant_profession_id = merchant_profession;
    bool living_merchant = false;
    for (const int32_t slot : slots) {
        if (economy->is_merchant_slot(slot)) { living_merchant = true; break; }
    }
    if (!living_merchant) {
        int64_t merchant_cash = 0;
        for (int i = 0; i < merchants.size(); ++i) {
            if (!pk_is_dictionary(merchants[i])) continue;
            merchant_cash = std::max<int64_t>(merchant_cash,
                dict_num<int64_t>(Dictionary(merchants[i]), "cash", 0));
        }
        // Kept out of `slots` so witness slot hints keep their meaning.
        add_slot(static_cast<int32_t>(make_signature(merchant_profession)), 1,
            merchant_cash);
        fixture_notes.push_back(String("merchant_cohort_synthesized"));
    }
    // Witness slot ids are session-local. Resolve them by (funds, population)
    // when the slice does not list the same number of cohorts, and synthesize the
    // single cohort the assertion reads when the bundle has no slice at all.
    // `population_key` may be null when the caller only knows the balance.
    const auto resolve_slot = [&](const char *slot_key, const char *funds_key,
                                  const char *population_key) -> int32_t {
        const int64_t hinted = dict_num<int64_t>(witness, slot_key, -1);
        if (hinted >= 0 && hinted < static_cast<int64_t>(slots.size()))
            return slots[static_cast<size_t>(hinted)];
        const int64_t funds = dict_num<int64_t>(witness, funds_key, -1);
        const int64_t people = population_key == nullptr
            ? -1 : dict_num<int64_t>(witness, population_key, -1);
        if (funds >= 0) {
            for (const int32_t slot : slots) {
                if (population.funds[slot] != funds) continue;
                if (people >= 0 && population.population[slot] != people) continue;
                return slot;
            }
        }
        return -1;
    };

    // Building types must exist for every referenced id: the commit path and the
    // investment portfolio both index _building_types[type_id].
    int32_t max_type_id = std::max<int32_t>(0,
        dict_num<int32_t>(witness, "type_id", 0));
    const Array buildings = pk_dict_array(cell_slice, "buildings");
    for (int i = 0; i < buildings.size(); ++i) {
        if (!pk_is_dictionary(buildings[i])) continue;
        max_type_id = std::max<int32_t>(max_type_id,
            dict_num<int32_t>(Dictionary(buildings[i]), "type_id", 0));
    }
    economy->_building_types.clear();
    for (int32_t type_id = 0; type_id <= max_type_id; ++type_id) {
        NativeEconomyRuntime::BuildingType type;
        type.owner_slots_per_building = 1;
        economy->_building_types.push_back(type);
    }

    // Market lane slice: stock/price per good for the single failed cell.
    const Array lanes = pk_dict_array(cell_slice, "market_lanes");
    const Array pending = pk_dict_array(cell_slice, "pending_construction");
    int32_t good_count = 1;
    for (int i = 0; i < lanes.size(); ++i) {
        if (!pk_is_dictionary(lanes[i])) continue;
        good_count = std::max<int32_t>(good_count,
            dict_num<int32_t>(Dictionary(lanes[i]), "good_id", 0) + 1);
    }
    for (int i = 0; i < pending.size(); ++i) {
        if (!pk_is_dictionary(pending[i])) continue;
        good_count = std::max<int32_t>(good_count,
            dict_num<int32_t>(Dictionary(pending[i]), "required_good", 0) + 1);
    }
    auto &market = economy->market_store();
    market.cell_to_market.resize(cell_count);
    for (int32_t cell = 0; cell < cell_count; ++cell)
        market.cell_to_market.write_scalar(cell, 0);
    market.market_count = 1;
    market.good_count = good_count;
    market.stock.resize(good_count);
    market.price.resize(good_count);
    market.demand_ema.resize(good_count);
    market.last_shortage_q16.resize(good_count);
    for (int32_t good = 0; good < good_count; ++good) {
        market.stock.write_scalar(good, 0);
        market.price.write_scalar(good, 0);
        market.demand_ema.write_scalar(good, 0);
        market.last_shortage_q16.write_scalar(good, 0);
    }
    for (int i = 0; i < lanes.size(); ++i) {
        if (!pk_is_dictionary(lanes[i])) continue;
        const Dictionary lane = lanes[i];
        const int32_t good = dict_num<int32_t>(lane, "good_id", 0);
        if (good < 0 || good >= good_count) continue;
        const int64_t index = market.index(0, good);
        market.stock.write_scalar(index, dict_num<int64_t>(lane, "stock", 0));
        market.price.write_scalar(index, dict_num<int32_t>(lane, "price", 0));
    }
    // Merchant CSR. A failure here is a fixture-scope note, not a dead replay:
    // the construction drift never reads the CSR, and an empty one is still a
    // consistent shape (offsets all zero). Only the investment credit lane
    // genuinely needs it, so the note travels with the result.
    std::string merchant_error;
    if (!economy->rebuild_merchant_ranges(merchant_error)) {
        fixture_notes.push_back(String("merchant_ranges_unavailable:") +
            String::utf8(merchant_error.c_str()));
    }
    out["fixture_notes"] = fixture_notes;

    // --- 3. re-run the assertion point named by the reason ------------------
    std::string replay_error;
    bool commit_ok = true;
    if (construction) {
        if (reason == "building_construction_preflight_stock_drift" &&
            pending.is_empty()) {
            // The stock branch compares market stock against the planned
            // material quantities, so without pending_construction there is
            // nothing to fail on and the replay would silently commit.
            Array missing = Array();
            missing.push_back(String("pending_construction"));
            out["missing"] = missing;
            out["detail"] = String(
                "incident_missing: pending_construction (the material plan is "
                "rebuilt from the pending construction rows)");
            return out;
        }
        const int32_t owner_slot = resolve_slot("owner_slot", "owner_funds",
            nullptr);
        const int32_t resolved_owner = owner_slot >= 0 ? owner_slot
            : add_cohort(1, dict_num<int64_t>(witness, "owner_funds", 0));
        NativeEconomyRuntime::ConstructionMaterialPlan material;
        material.feasible = dict_num<bool>(witness, "material_feasible", true);
        material.total_cost = dict_num<int64_t>(witness, "total_cost", 0);
        for (int i = 0; i < pending.size(); ++i) {
            if (!pk_is_dictionary(pending[i])) continue;
            const Dictionary row = pending[i];
            material.good_ids.push_back(dict_num<int32_t>(row, "required_good", 0));
            material.quantities.push_back(dict_num<int64_t>(row, "required_qty", 0));
        }
        // The funds branch records good_count == planned goods, so padding keeps
        // the size-mismatch check out of the way; that is how the original
        // failure reached the funds comparison.
        const int32_t planned = dict_num<int32_t>(witness, "good_count",
            static_cast<int32_t>(material.good_ids.size()));
        while (static_cast<int32_t>(material.good_ids.size()) < planned) {
            material.good_ids.push_back(0);
            material.quantities.push_back(0);
        }
        NativeEconomyRuntime::Command command;
        command.i32_0 = fixture_cell;
        command.i32_1 = dict_num<int32_t>(witness, "type_id", 0);
        command.i64_0 = dict_num<int64_t>(witness, "allocated_count", 1);
        // The row reports the portfolio position the commit was at; on the live
        // path these are set by the investment stage around this call, so the
        // fixture restores them from the witness.
        economy->_construction_fatal_portfolio_index =
            dict_num<int32_t>(witness, "portfolio_index", -1);
        economy->_construction_fatal_portfolio_size =
            dict_num<int32_t>(witness, "portfolio_size", 0);
        commit_ok = economy->commit_preflighted_build_command(command,
            resolved_owner, material, 0,
            dict_num<int64_t>(witness, "debt_principal", 0), 0,
            dict_num<int64_t>(witness, "funding_gap", 0), replay_error);
    } else {
        int32_t sponsor_slot = resolve_slot("sponsor_slot", "sponsor_funds",
            "sponsor_population");
        if (sponsor_slot < 0) {
            sponsor_slot = add_cohort(
                dict_num<int64_t>(witness, "sponsor_population", 1),
                dict_num<int64_t>(witness, "sponsor_funds", 0));
        }
        int32_t owner_slot = resolve_slot("owner_slot", "owner_funds",
            "owner_population");
        if (owner_slot < 0 || owner_slot == sponsor_slot) {
            owner_slot = add_cohort(
                dict_num<int64_t>(witness, "owner_population", 1),
                dict_num<int64_t>(witness, "owner_funds", 0));
        }
        // The leg is a profession transition when the owner cohort carries a
        // different signature than the sponsor; that is the only branch that
        // records this witness.
        NativeEconomyRuntime::Signature owner_signature;
        owner_signature.profession_id = 1;
        owner_signature.ethnicity_id = 0;
        economy->_signatures.push_back(owner_signature);
        const uint32_t owner_signature_id =
            static_cast<uint32_t>(economy->_signatures.size() - 1);
        NativeEconomyRuntime::BuildingInvestmentCellContext ctx(fixture_cell);
        // The row records (portfolio_index, portfolio_size) at the failing leg, so
        // the fixture places the leg at the witnessed position and keeps the
        // witnessed size; earlier positions stay unallocated and the commit loop
        // skips them.
        const int32_t leg_index = std::clamp<int32_t>(
            dict_num<int32_t>(witness, "portfolio_index", 0), 0, 3);
        ctx.portfolio_size = std::clamp<int32_t>(
            dict_num<int32_t>(witness, "portfolio_size", 1),
            leg_index + 1, 4);
        auto &plan = ctx.portfolio[leg_index].plan;
        plan.cell = fixture_cell;
        plan.type_id = dict_num<int32_t>(witness, "type_id", 0);
        plan.sponsor = sponsor_slot;
        plan.owner_signature_id = static_cast<int32_t>(owner_signature_id);
        plan.owner_slots = 1;
        plan.allocated_count = dict_num<int64_t>(witness, "allocated_count", 1);
        plan.funding_capital = dict_num<int64_t>(witness, "funding_capital", 0);
        plan.merchant_credit = dict_num<int64_t>(witness, "merchant_credit", 0);
        ctx.commit_material_plans[leg_index].feasible = true;
        ctx.commit_material_plans[leg_index].total_cost = plan.funding_capital;
        bool population_changed = false;
        commit_ok = economy->investment_commit_portfolio(ctx, population_changed,
            replay_error);
    }

    // --- 4. compare ---------------------------------------------------------
    const Dictionary report = economy->fatal_context_report();
    const Dictionary witness_after = report.has(StringName("witness"))
        ? Dictionary(report[StringName("witness")]) : Dictionary();
    out["witness_after"] = witness_after;
    out["assert_id_actual"] = report.get("assert_id", String());
    out["reason_actual"] = pk_text(replay_error);
    const bool assert_fired = !commit_ok && replay_error == reason;
    out["assert_fired"] = assert_fired;
    const char *const *fields = construction ? kConstructionWitnessFields
                                             : kInvestmentWitnessFields;
    const int field_count = construction ? kConstructionFieldCount
                                         : kInvestmentFieldCount;
    // The funds-drift branch records -1/0/0 in the first_* fields: they are the
    // stock branch's evidence and the funds comparison never computes them. They
    // are therefore only compared for a stock drift; the published `uncompared`
    // list keeps the exclusion auditable instead of silently widening the pass
    // criterion. Every field the fired branch does record stays strict.
    const bool compare_first_material =
        reason == "building_construction_preflight_stock_drift";
    Array uncompared;
    for (int i = 0; i < field_count; ++i) {
        const StringName key(fields[i]);
        if (!witness.has(key)) continue;
        if (!compare_first_material &&
            (key == StringName("first_good_id") ||
             key == StringName("first_required") ||
             key == StringName("first_stock"))) {
            uncompared.push_back(String(fields[i]));
            continue;
        }
        const Variant expected = witness[key];
        const bool present = witness_after.has(key);
        const Variant actual = present ? witness_after[key] : Variant();
        if (present && pk_value_matches(expected, actual)) continue;
        Dictionary row;
        row["field"] = String(fields[i]);
        row["expected"] = expected;
        row["actual"] = present ? actual : Variant(String("<absent>"));
        diff.push_back(row);
    }
    out["uncompared"] = uncompared;
    out["diff"] = diff;
    out["reproduced"] = assert_fired && diff.is_empty();
    if (bool(out["reproduced"])) {
        out["detail"] = String();
        return out;
    }
    if (!assert_fired) {
        out["detail"] = pk_text(commit_ok
            ? "assertion_no_longer_fires: the replay of " + reason +
                " returned success (the pre-write gate suppresses it)"
            : "different_assertion: replay produced '" + replay_error +
                "' instead of '" + reason + "'");
    } else {
        out["detail"] = pk_text(
            "witness_differs: the assertion fires with the same reason but the "
            "replayed witness does not match field by field");
    }
    return out;
}

} // namespace pk
