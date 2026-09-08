// Standalone parity contract test.
//
// The parity reduction is pure POD logic with no Godot dependency, so it can be
// exercised by a plain executable. Iterating here takes under a second where a
// headless Godot round trip takes several, and a failure points at C++ directly
// instead of at a GDScript harness.
//
// Build and run:
//   cd gdext/tests && scons -f SConstruct.climate_parity
//   ..\..\tmp\climate_parity\climate_parity_test.exe

#include "runtime_climate_parity.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const char *what) {
    if (condition) {
        std::printf("  ok   %s\n", what);
        return;
    }
    std::printf("  FAIL %s\n", what);
    ++failures;
}

// Mirrors what the GDExtension binding does: fill a store from production
// arrays. Keeping an independent copy here proves the hash agrees across two
// separately written fill paths, which is exactly the property S1 needs.
pk::RuntimeClimateStore store_from_reference_arrays(
        uint32_t cells,
        const std::vector<float> &temperature,
        const std::vector<float> &moisture,
        const std::vector<uint8_t> &weather_type,
        const std::vector<int32_t> &growth_streak,
        float climate_anomaly) {
    pk::RuntimeClimateStore store;
    store.reset(cells);
    store.climate_anomaly = climate_anomaly;
    store.temperature = temperature;
    store.moisture = moisture;
    store.weather_type = weather_type;
    store.vegetation_growth_streak = growth_streak;
    return store;
}

} // namespace

int main() {
    std::printf("=== climate parity contract ===\n");

    std::string error;
    const bool self_test_ok = pk::runtime_climate_parity_self_test(error);
    if (!self_test_ok) std::printf("  self-test error: %s\n", error.c_str());
    check(self_test_ok, "runtime_climate_parity_self_test");

    const size_t total = pk::runtime_climate_parity_field_count();
    const size_t comparable = pk::runtime_climate_parity_comparable_count();
    std::printf("  fields: %zu total, %zu comparable, %zu excluded\n",
                total, comparable, total - comparable);
    check(total > 0, "field table is non-empty");
    check(comparable < total, "excluded fields are recorded, not dropped");

    // Every exclusion must carry a reason, so a future reader can tell a
    // deliberate gap from an oversight.
    const pk::RuntimeClimateParityField *table = pk::runtime_climate_parity_fields();
    bool notes_present = true;
    for (size_t i = 0; i < total; ++i) {
        if (table[i].comparability == pk::RuntimeClimateParityComparability::COMPARABLE)
            continue;
        std::printf("  excluded: %-32s (%s) %s\n", table[i].name,
                    table[i].comparability ==
                            pk::RuntimeClimateParityComparability::TYPE_MISMATCH
                        ? "type_mismatch" : "no_reference",
                    table[i].note);
        if (table[i].note == nullptr || table[i].note[0] == '\0') notes_present = false;
    }
    check(notes_present, "each excluded field explains itself");

    // The S1 acceptance property: a store filled from production arrays and a
    // store the worker owns must reduce to the same hash when the physical
    // state is the same, even though the worker has advanced its bookkeeping.
    constexpr uint32_t CELLS = 16;
    std::vector<float> temperature(CELLS);
    std::vector<float> moisture(CELLS);
    std::vector<uint8_t> weather_type(CELLS);
    std::vector<int32_t> growth_streak(CELLS);
    for (uint32_t i = 0; i < CELLS; ++i) {
        temperature[i] = -3.5f + 1.25f * static_cast<float>(i);
        moisture[i] = 0.05f * static_cast<float>(i);
        weather_type[i] = static_cast<uint8_t>(i % 5u);
        growth_streak[i] = static_cast<int32_t>(i * 2u);
    }

    const pk::RuntimeClimateStore reference = store_from_reference_arrays(
        CELLS, temperature, moisture, weather_type, growth_streak, 0.125f);

    pk::RuntimeClimateStore worker = reference;
    worker.generation = 512;
    worker.climate_generation = 511;
    worker.committed_day = 30;
    worker.rng_state = 0x1234567887654321ull;
    worker.annual_rng_state = 0xfedcba9876543210ull;
    worker.history_cursor = 7;
    worker.annual_temperature_drift = -0.25f;

    check(reference.parity_hash() == worker.parity_hash(),
          "reference and worker agree on parity_hash");
    check(reference.state_hash() != worker.state_hash(),
          "state_hash still separates the two (save integrity preserved)");

    pk::RuntimeClimateParityReport report;
    check(!pk::runtime_climate_parity_first_difference(reference, worker, report),
          "no divergence reported for equal physical state");

    worker.moisture[9] += 0.001f;
    check(reference.parity_hash() != worker.parity_hash(),
          "a physical divergence changes parity_hash");
    check(pk::runtime_climate_parity_first_difference(reference, worker, report),
          "divergence is located");
    std::printf("  located: field=%s cell=%u reference=%s worker=%s\n",
                report.field, report.cell, report.reference_bits, report.worker_bits);
    check(std::string(report.field) == "moisture" && report.cell == 9,
          "divergence points at the mutated cell");

    // The S2 deliverable is a stage/field matrix, so every field must resolve
    // to a stage and the per-field fold must count all divergent cells.
    bool stages_named = true;
    for (size_t i = 0; i < total; ++i) {
        const std::string stage_name =
            pk::runtime_climate_stage_name(table[i].stage);
        if (stage_name == "UNKNOWN") stages_named = false;
    }
    check(stages_named, "every field names a producing stage");

    worker.moisture[2] += 0.5f;
    worker.sea_ice[4] += 0.25f;
    std::vector<pk::RuntimeClimateParityFieldDiff> diffs(total);
    const size_t diverged_fields = pk::runtime_climate_parity_field_divergence(
        reference, worker, diffs.data(), diffs.size());
    check(diverged_fields == 2, "the fold reports both divergent fields");
    for (size_t i = 0; i < total; ++i) {
        if (diffs[i].diverged_cells == 0) continue;
        std::printf("  matrix: %-28s stage=%-24s cells=%u/%u first=%u max_delta=%.6g\n",
                    table[i].name,
                    pk::runtime_climate_stage_name(table[i].stage),
                    diffs[i].diverged_cells, diffs[i].compared_cells,
                    diffs[i].first_cell, diffs[i].max_abs_delta);
        if (std::string(table[i].name) == "moisture") {
            check(diffs[i].diverged_cells == 2 && diffs[i].first_cell == 2,
                  "moisture reports both divergent cells and the first one");
        }
    }

    std::printf("=== %s ===\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
