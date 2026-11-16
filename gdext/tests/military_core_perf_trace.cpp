// Deterministic before/after trace. Copy this SAME source to each checkout's
// gdext/tests/ before compiling. It uses only the pre-redesign public contract.
// The include supplies the existing pure-C++ Sim fixture; exclude the standalone
// military_core_selftest.cpp from the compilation command to avoid duplicates:
//
// python3 - <checkout> <output-binary> <<'PY'
// import pathlib, subprocess, sys
// root = pathlib.Path(sys.argv[1])
// sources = sorted((root / "gdext/src").glob("military_core*.cpp"))
// sources = [str(p) for p in sources if p.name != "military_core_selftest.cpp"]
// subprocess.run(["c++", "-std=c++17", "-O2", "-I" + str(root / "gdext/src"),
//                 str(root / "gdext/tests/military_core_perf_trace.cpp"),
//                 *sources, "-o", sys.argv[2]], check=True)
// PY
//
// Run both binaries to separate log files and compare them byte for byte.
// No wall-clock or diagnostic counters enter this output.
#include "../src/military_core_selftest.cpp"

#include <iostream>

namespace {

bool trace_failure(const std::string &message) {
    std::cerr << "military trace FAIL: " << message << '\n';
    return false;
}

void write_trace(const pk::Sim &sim) {
    std::cout << "day " << sim.day - 1 << " state " << sim.core.state_hash()
              << " intents " << sim.last.size() << '\n';
    for (size_t i = 0; i < sim.last.size(); ++i) {
        const pk::MilitaryIntent &in = sim.last[i];
        // All declared fields, in emitted order. Reserved/pad are explicit
        // fields too; object padding bytes are intentionally never read.
        std::cout << "intent " << i << ' ' << in.kind << ' ' << in.reserved
                  << ' ' << in.cell << ' ' << in.good << ' ' << in.pad
                  << ' ' << in.country_a << ' ' << in.country_b << ' ' << in.count
                  << ' ' << in.amount << ' ' << in.source_id << '\n';
    }
    // PKMI covers continuation fields outside state_hash's projection. Include
    // the complete deterministic byte stream at the warm and mid-war boundaries.
    if (sim.day == 21 || sim.day == 60 || sim.day == 150) {
        const std::vector<uint8_t> bytes = sim.core.encode();
        static constexpr char hex[] = "0123456789abcdef";
        std::cout << "save " << bytes.size() << ' ';
        for (uint8_t value : bytes) std::cout << hex[value >> 4] << hex[value & 15];
        std::cout << '\n';
    }
}

bool run_trace() {
    using namespace pk;
    const MilitaryTerrainInput terrain = make_hex_terrain(kW, kH);
    MilitaryCatalog catalog = make_catalog();
    // Exercise physical maintenance along with ordinary ration procurement.
    catalog.state_buildings[0].repair_materials.push_back({0, 1ll << 32});
    Sim sim;
    if (!sim.init(terrain, 777, std::move(catalog))) return trace_failure(sim.error);
    const int32_t staging[] = {cell_at(13, 12), cell_at(15, 12), kEnclave};
    sim.dg.country_soldier_living_cost = {1000, 1500, 1100};
    sim.dg.country_cash = {200000000, 180000000, 90000000};
    for (int32_t country = 0; country < 3; ++country) {
        const int32_t cell = staging[country];
        MilitaryCommand build;
        build.cell = cell;
        build.unit_to = 0;
        MilitaryCommand target;
        target.value = 100;
        if (!sim.submit(MCMD_STATE_BUILD, country, build) ||
            !sim.submit(MCMD_FORCE_SET_TARGET, country, target))
            return trace_failure(sim.error);
        sim.dg.cell_has_merchant[(size_t)cell] = 1;
        sim.dg.market_cell.push_back(cell);
        sim.dg.market_good.push_back(0);
        sim.dg.market_sellable.push_back(1000000);
        sim.dg.market_price.push_back(20000);
    }
    bool saw_army = false, saw_war = false, saw_payroll = false;
    bool saw_procurement = false, saw_engagement = false;
    for (int32_t day = 0; day < 150; ++day) {
        if (day == 21) {
            for (int32_t country = 0; country < 3; ++country) {
                if (garrison_at(sim.core, staging[country]) != 100)
                    return trace_failure("recruitment precondition");
            }
            for (int32_t country = 0; country < 2; ++country) {
                MilitaryCommand army;
                army.cell = staging[country];
                army.ints = {0, 80};
                if (!sim.submit(MCMD_ARMY_CREATE, country, army)) return trace_failure(sim.error);
            }
            for (int32_t target = 1; target <= 2; ++target) {
                MilitaryCommand war;
                war.other = handle_for(target);
                if (!sim.submit(MCMD_WAR_DECLARE, 0, war)) return trace_failure(sim.error);
            }
        }
        if (day == 22) {
            const int32_t a = sim.army_of(0), b = sim.army_of(1);
            if (a < 0 || b < 0 || !sim.core.at_war(0, 1) || !sim.core.at_war(0, 2))
                return trace_failure("nonzero armies and wars precondition");
            MilitaryCommand attack;
            attack.army = sim.core.army_handle(a);
            attack.cell = kEnclave;
            MilitaryCommand counter;
            counter.army = sim.core.army_handle(b);
            counter.cell = staging[0];
            if (!sim.submit(MCMD_ARMY_MOVE, 0, attack) ||
                !sim.submit(MCMD_ARMY_MOVE, 1, counter))
                return trace_failure(sim.error);
        }
        // Change committed inputs after the wars start. Both builds receive the
        // exact same scripted changes, independent of elapsed time or outputs.
        if (day == 40) sim.dg.cell_population[(size_t)staging[0]] += 123;
        if (day == 50) sim.dg.country_cash[1] = 900;
        if (day == 51) sim.dg.country_cash[1] = 180000000;
        if (!sim.step()) return trace_failure(sim.error);
        if (sim.core.report().reconcile_delta != 0) return trace_failure("inventory conservation");
        for (const MilitaryIntent &in : sim.last) {
            saw_payroll = saw_payroll || in.kind == MILITARY_INTENT_PAY_WAGES ||
                                       in.kind == MILITARY_INTENT_ARMY_PAY;
            saw_procurement = saw_procurement || in.kind == MILITARY_INTENT_PROCURE_GOOD;
        }
        saw_army = saw_army || sim.army_of(0) >= 0;
        saw_war = saw_war || sim.core.at_war(0, 1);
        for (const MilitaryEngagement &e : sim.core.engagements())
            saw_engagement = saw_engagement || e.active != 0;
        write_trace(sim);
    }
    if (!saw_army || !saw_war || !saw_payroll || !saw_procurement || !saw_engagement)
        return trace_failure("trace did not exercise every intended military path");
    std::cout << "military trace PASS: 150 days, armies, wars, payroll, procurement, engagement\n";
    return true;
}
} // namespace

int main() {
    return run_trace() ? 0 : 1;
}
