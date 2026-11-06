// Test-only extension. Links the already-built production objects unchanged.
#include "country_runtime.h"
#include "economy_runtime.h"
#include "runtime_economy_pod.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <memory>

using namespace godot;

class MilitaryFiscalProbe : public RefCounted {
    GDCLASS(MilitaryFiscalProbe, RefCounted)
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("run", "catalog", "profile", "packet",
            "population", "market", "signature", "checkpoint"), &MilitaryFiscalProbe::run, DEFVAL(false));
    }
public:
    Dictionary run(const Dictionary &catalog, const Dictionary &profile,
                   const Dictionary &packet, const Dictionary &population,
                   const Dictionary &market, int signature, bool checkpoint = false) {
        auto country = std::make_unique<pk::NativeCountryRuntime>();
        auto economy = std::make_unique<pk::NativeEconomyRuntime>();
        Dictionary out;
        Dictionary cp;
        cp["country_runtime_mode"] = "ACTIVE";
        cp["starting_technology_ids"] = catalog["technology_ids"];
        Dictionary configured = country->configure(catalog, cp, 1, 104172);
        if (!static_cast<bool>(configured.get("ok", false))) return configured;
        PackedByteArray water; water.push_back(0);
        Dictionary boot = country->bootstrap(packet, water);
        if (!static_cast<bool>(boot.get("ok", false))) return boot;
        economy->attach_country_runtime(country.get());
        configured = economy->configure(catalog, profile, 1, 104172);
        if (!static_cast<bool>(configured.get("ok", false))) return configured;
        boot = economy->bootstrap(population, market);
        if (!static_cast<bool>(boot.get("ok", false))) return boot;
        const int64_t owner = country->cell_summary(0)["country_handle"];
        // This isolated one-cell fixture has no map input capture. Supply the
        // required empty resource rows before testing the actual save contract.
        const PackedStringArray resources = catalog.get("resource_ids", PackedStringArray());
        economy->resource_stock_lanes().assign(static_cast<size_t>(resources.size()), 0);
        constexpr uint64_t army = 7001001;
        Array rows;
        auto capture = [&](const char *stage, int64_t result, const std::string &error) {
            Dictionary row;
            row["stage"] = stage;
            row["result"] = result;
            row["error"] = String(error.c_str());
            row["country_cash"] = country->total_cash();
            const Dictionary pop = economy->population_cell_snapshot(0);
            const PackedInt64Array funds = pop.get("funds_by_cohort", PackedInt64Array());
            int64_t cohort_cash = 0;
            for (int64_t i = 0; i < funds.size(); ++i) cohort_cash += funds[i];
            row["cohort_cash"] = cohort_cash;
            row["army_population"] = economy->military_army_population(army);
            row["army_funds"] = economy->military_army_funds(army);
            row["total"] = country->total_cash() + cohort_cash + economy->military_army_funds(army);
            rows.push_back(row);
            return row;
        };
        capture("opening", 0, "");
        const int64_t reserved = country->reserve_fiscal_cash(owner, 12345);
        capture("reserve", reserved, "");
        const int64_t collected = country->collect_fiscal_cash(owner, reserved);
        capture("collect", collected, "");
        Dictionary deferred_checks;
        auto helper_attempt = [&](const char *label, int64_t payer, int64_t amount,
                                  int64_t expected) {
            const auto before = capture("helper_before", 0, "");
            const int64_t actual = economy->military_collect_cash(payer, amount);
            const auto after = capture(label, actual, "");
            deferred_checks[String(label)] = actual == expected &&
                static_cast<int64_t>(before["country_cash"]) == static_cast<int64_t>(after["country_cash"]) &&
                static_cast<int64_t>(before["cohort_cash"]) == static_cast<int64_t>(after["cohort_cash"]) &&
                static_cast<int64_t>(before["army_funds"]) == static_cast<int64_t>(after["army_funds"]) &&
                static_cast<int64_t>(before["total"]) == static_cast<int64_t>(after["total"]);
        };
        helper_attempt("actual_military_collect_cash", owner, 12345, 12345);
        helper_attempt("repeated_deferred_helper", owner, 12345, 12345);
        helper_attempt("invalid_owner", 0, 12345, 0);
        helper_attempt("zero_deferred_helper", owner, 0, 0);
        const int64_t held = country->reserve_fiscal_cash(owner, country->total_cash() - 777);
        helper_attempt("partial_deferred_helper", owner, 12345, 777);
        const int64_t tail = country->reserve_fiscal_cash(owner, 777);
        helper_attempt("empty_treasury", owner, 12345, 0);
        country->return_fiscal_cash(owner, held + tail);
        capture("restore_failed_case", held + tail, "");
        out["deferred_checks"] = deferred_checks;
        pk::RuntimeEconomyPodCommand cmd;
        cmd.opcode = pk::NativeEconomyRuntime::COMMAND_ARMY_EMBARK;
        cmd.target_cohort = army;
        cmd.target_cell = 0;
        cmd.target_country = signature;
        cmd.payload0 = 1;
        cmd.submit_order = 920010;
        std::string error;
        const bool embarked = economy->apply_pod_command(cmd, error);
        capture("actual_army_embark", embarked, error);
        if (!embarked || economy->military_army_population(army) != 1) {
            out["ok"] = false; out["trace"] = rows; return out;
        }
        const Dictionary before = rows[rows.size() - 1];
        cmd.opcode = pk::NativeEconomyRuntime::COMMAND_ARMY_LANE_PAY;
        cmd.payload0 = 12345;
        cmd.payload1 = owner;
        cmd.submit_order = 920011;
        const bool paid = economy->apply_pod_command(cmd, error);
        capture("actual_army_pay", paid, error);
        const Dictionary after = rows[rows.size() - 1];
        out["ok"] = paid;
        out["money_delta"] = static_cast<int64_t>(after["total"]) - static_cast<int64_t>(before["total"]);
        Dictionary checks;
        checks["paid_exact_debit"] = static_cast<int64_t>(before["country_cash"]) -
            static_cast<int64_t>(after["country_cash"]) == 12345;
        checks["paid_exact_credit"] = static_cast<int64_t>(after["army_funds"]) -
            static_cast<int64_t>(before["army_funds"]) == 12345;
        // Independent process comparison: preserve a nonzero soldier and paid lane.
        if (checkpoint) {
            auto save = [](auto &runtime, std::vector<PackedByteArray> &chunks) {
                if (!static_cast<bool>(runtime.begin_save(65536).get("ok", false))) return false;
                for (;;) {
                    auto chunk = runtime.read_save_chunk(65536);
                    if (chunk.is_empty()) break;
                    chunks.push_back(chunk);
                }
                return static_cast<bool>(runtime.end_save().get("ok", false));
            };
            auto restore = [&](auto &runtime, const std::vector<PackedByteArray> &chunks) {
                if (!static_cast<bool>(runtime.begin_restore().get("ok", false))) return false;
                for (const auto &chunk : chunks)
                    if (!static_cast<bool>(runtime.feed_restore_chunk(chunk).get("ok", false))) return false;
                const Dictionary result = runtime.end_restore();
                if (!static_cast<bool>(result.get("ok", false))) out["restore_result"] = result;
                return static_cast<bool>(result.get("ok", false));
            };
            std::vector<PackedByteArray> country_chunks, economy_chunks;
            if (!save(*country, country_chunks) || !save(*economy, economy_chunks)) {
                out["ok"] = false; out["checkpoint_error"] = "save"; return out;
            }
            auto loaded_country = std::make_unique<pk::NativeCountryRuntime>();
            auto loaded_economy = std::make_unique<pk::NativeEconomyRuntime>();
            loaded_country->configure(catalog, cp, 1, 104172);
            if (!restore(*loaded_country, country_chunks)) {
                out["ok"] = false; out["checkpoint_error"] = "country_restore"; return out;
            }
            loaded_economy->attach_country_runtime(loaded_country.get());
            loaded_economy->configure(catalog, profile, 1, 104172);
            if (!restore(*loaded_economy, economy_chunks)) {
                out["ok"] = false; out["checkpoint_error"] = "economy_restore"; return out;
            }
            economy.swap(loaded_economy);
            country.swap(loaded_country);
        }
        capture("continuation_boundary", 0, "");
        Array continuation;
        for (int64_t day = 1; day <= 8; ++day) {
            cmd.opcode = pk::NativeEconomyRuntime::COMMAND_ARMY_LANE_PAY;
            cmd.target_cohort = army;
            cmd.payload0 = 1234 + day;
            cmd.payload1 = owner;
            cmd.submit_order = 930000 + day;
            error.clear();
            const auto start = capture("daily_pay_before", 0, "");
            const bool ok = economy->apply_pod_command(cmd, error);
            const auto finish = capture("daily_pay_after", ok, error);
            Dictionary row = finish.duplicate();
            row["day"] = day;
            row["conserved"] = ok && static_cast<int64_t>(start["total"]) ==
                static_cast<int64_t>(finish["total"]);
            continuation.push_back(row);
        }
        out["continuation"] = continuation;
        // Each attempt reaches the real command branch, with a new identity.
        auto attempt = [&](const char *label, uint64_t target, int64_t payer,
                           int64_t amount, uint64_t sequence, bool expected_ok,
                           int64_t expected_moved) {
            const auto start = capture("case_before", 0, "");
            cmd.target_cohort = target;
            cmd.payload0 = amount;
            cmd.payload1 = payer;
            cmd.submit_order = sequence;
            error.clear();
            const bool ok = economy->apply_pod_command(cmd, error);
            const auto finish = capture(label, ok, error);
            checks[String(label)] = ok == expected_ok &&
                static_cast<int64_t>(finish["total"]) == static_cast<int64_t>(start["total"]) &&
                static_cast<int64_t>(start["country_cash"]) - static_cast<int64_t>(finish["country_cash"]) == expected_moved &&
                static_cast<int64_t>(finish["army_funds"]) - static_cast<int64_t>(start["army_funds"]) == expected_moved;
        };
        attempt("duplicate_pay", army, owner, 12345, 920011, true, 0);
        attempt("zero_pay", army, owner, 0, 920012, true, 0);
        attempt("invalid_pay_owner", army, 0, 12345, 920013, false, 0);
        attempt("missing_pay_lane", army + 1, owner, 12345, 920014, false, 0);
        const int64_t available = country->total_cash();
        attempt("insufficient_partial_pay", army, owner, available + 100,
            920015, true, available);
        attempt("empty_pay", army, owner, 1, 920016, false, 0);
        out["checks"] = checks;
        out["trace"] = rows;
        out["country_report"] = country->report();
        return out;
    }
};

static void initialize_probe(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) ClassDB::register_class<MilitaryFiscalProbe>();
}
extern "C" GDExtensionBool GDE_EXPORT military_fiscal_probe_init(
        GDExtensionInterfaceGetProcAddress get_proc, GDExtensionClassLibraryPtr library,
        GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc, library, initialization);
    init.register_initializer(initialize_probe);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
