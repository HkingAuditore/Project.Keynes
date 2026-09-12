#pragma once

// Canonical Climate parity contract.
//
// The worker and the production (OFF) path each own a full Climate state. To
// decide whether they agree, both sides must reduce their state through the
// *same* function over the *same* field set. Before this table existed the two
// sides used different hash functions over different field sets, so the
// equality test could not succeed at all.
//
// This header is the single declaration of that field set. It is consumed by
// three places, and must not be duplicated in any of them:
//
//   1. runtime_climate_parity_hash()          - the comparable reduction
//   2. the GDExtension reference binding      - MapData -> store, same hash
//   3. runtime_climate_parity_first_difference() - field/cell level diagnosis
//
// Deliberately excluded from the hash are the worker's own bookkeeping fields
// (generation, climate_generation, committed_day, rng_state, annual_rng_state,
// history_cursor, temperature_history, annual_temperature_drift). They have no
// counterpart in MapData, so including them makes the comparison impossible
// rather than strict. State integrity for save/restore keeps using
// RuntimeClimateStore::state_hash(), which does cover them.

#include "runtime_authoritative_domains.h"
#include "runtime_climate_kernel.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace pk {

// Element type of a per-cell field in RuntimeClimateStore.
enum class RuntimeClimateParityKind : uint8_t {
    F32 = 0,
    I32 = 1,
    U8 = 2,
};

enum class RuntimeClimateParityComparability : uint8_t {
    // Same physical quantity and a compatible element type on both sides.
    COMPARABLE = 0,
    // Both sides carry the field, but with element types that cannot be
    // compared bit for bit. Such a field is excluded from the hash so that it
    // cannot make every day mismatch; it is still reported so the discrepancy
    // stays visible instead of silently passing.
    TYPE_MISMATCH = 1,
    // The worker owns the field but the production path has no MapData array
    // for it, so there is nothing to compare against yet.
    NO_REFERENCE = 2,
};

// How strictly a field is held. Bit-exactness is the goal everywhere, but two
// classes of field cannot reach it while the production path still slices work
// across ticks:
//
//   * A sliced stage (WEATHER, and OCEAN_* once it has fields here) updates a
//     fraction of the map per tick against a persistent array. The worker runs
//     the whole map once per day. Both are correct; they are not the same
//     arithmetic, so the results differ by an amount bounded by one day of
//     forcing rather than by float error.
//   * A field downstream of a sliced stage inherits that spread through the
//     dependency chain even though its own kernel is shared and exact.
//
// A tolerance here is therefore a statement about *why* a field cannot be
// bit-exact, not a blanket allowance. Anything above its band is still a real
// divergence and must be explained, which is the point of banding rather than
// picking one loose global epsilon.
enum class RuntimeClimateParityTolerance : uint8_t {
    // Non-sliced stage running a shared kernel: must match bit for bit.
    BITWISE = 0,
    // Sliced stage: relative 1e-3.
    SLICED = 1,
    // Downstream of a sliced stage through the dependency chain: relative 5e-3.
    CHAINED = 2,
};

// Relative band for a tolerance class. BITWISE returns 0, i.e. exact equality.
double runtime_climate_parity_tolerance_band(RuntimeClimateParityTolerance t);

struct RuntimeClimateParityField {
    // Canonical name. Also the Dictionary key accepted by the reference
    // binding and the value written into RuntimeClimateParityReport::field.
    const char *name;
    // MapData member the production path fills, for cross-referencing.
    const char *map_data_array;
    RuntimeClimateParityKind kind;
    RuntimeClimateParityComparability comparability;
    RuntimeClimateParityTolerance tolerance;
    // Stage of the production pipeline that last writes this field. It is what
    // turns a list of divergent fields into a "stage x field" matrix, i.e. into
    // an ordered work list for extracting the shared kernel.
    RuntimeClimateStage stage;
    // Why a field is not comparable. Empty when it is.
    const char *note;
    // Exactly one of these is non-null, selected by `kind`.
    std::vector<float> RuntimeClimateStore::*f32;
    std::vector<int32_t> RuntimeClimateStore::*i32;
    std::vector<uint8_t> RuntimeClimateStore::*u8;
};

// Per-field outcome of a full comparison. `first_difference` answers "is there
// a divergence"; this answers "how far is each stage from parity", which is
// what decides the order the production passes get extracted in.
struct RuntimeClimateParityFieldDiff {
    uint32_t compared_cells = 0;
    // Cells differing at all, i.e. the bit-exact count. Kept because it is the
    // number that tells us whether a shared kernel is really shared.
    uint32_t diverged_cells = 0;
    // Cells differing by more than the field's tolerance band. For a BITWISE
    // field this equals diverged_cells; for a banded field it is the count that
    // still needs explaining.
    uint32_t out_of_band_cells = 0;
    uint32_t first_cell = 0;
    // Largest absolute difference over the field. Meaningful for F32 and I32;
    // for a byte field it is the largest absolute step between the two codes.
    double max_abs_delta = 0.0;
    // Cell carrying max_abs_delta. first_cell finds the earliest divergence,
    // which is often a rounding-level one; the worst cell is what tells you
    // whether a whole branch went the other way.
    uint32_t max_abs_delta_cell = 0;
    char reference_bits[24]{};
    char worker_bits[24]{};
};

// Upper bound on the field table size, so a fixed-size accumulator can live in
// the simulation host without allocating in the worker loop. The self test
// enforces that the table still fits.
constexpr size_t RUNTIME_CLIMATE_PARITY_MAX_FIELDS = 64u;

// Framing version for the parity reduction. Any change to the field set,
// their order, or the mixing scheme must bump this, because a reference hash
// computed under one version is not comparable to another.
// Version 2 splits the single uint8 weather_transition entry into the three
// lanes the production path keeps, which changes both the field set and the
// mixing order.
// Version 3 adds the two succession lanes (vegetation / base_vegetation) that the
// worker took over in B8-P1. The field set is part of the hash framing, so this
// must move whenever the table's membership changes.
// Version 4 adds worker-owned terrain / cover (CLM2 ABI 8 writeback).
constexpr uint32_t RUNTIME_CLIMATE_PARITY_VERSION = 4u;

size_t runtime_climate_parity_field_count();
const RuntimeClimateParityField *runtime_climate_parity_fields();
// Returns nullptr when no field carries that canonical name.
const RuntimeClimateParityField *runtime_climate_parity_field(const char *name);

// Number of fields actually mixed into the hash (COMPARABLE ones only).
size_t runtime_climate_parity_comparable_count();

// The comparable reduction. Covers cell_count, climate_anomaly and every
// COMPARABLE per-cell field, in table order.
uint64_t runtime_climate_parity_hash(const RuntimeClimateStore &store);

// Walks the comparable fields in table order and records the first element
// that differs, filling report.field / cell / reference_bits / worker_bits.
// Returns true when a difference was found. A field whose lengths differ is
// reported at the first index beyond the shorter side.
bool runtime_climate_parity_first_difference(
        const RuntimeClimateStore &reference,
        const RuntimeClimateStore &worker,
        RuntimeClimateParityReport &report);

// Compares every COMPARABLE field in full and writes one diff per table entry,
// including the entries that were skipped (those keep compared_cells == 0).
// Returns the number of fields that diverged. `out_count` must be at least
// runtime_climate_parity_field_count().
size_t runtime_climate_parity_field_divergence(
        const RuntimeClimateStore &reference,
        const RuntimeClimateStore &worker,
        RuntimeClimateParityFieldDiff *out,
        size_t out_count);

// Copies every COMPARABLE field from `reference` into `target`, leaving the
// worker's own bookkeeping and the excluded fields untouched. It exists for the
// measurement mode described in runtime_climate_authority.h: without it a
// single divergent day poisons every later day, so only one day could ever be
// measured. Returns false when the two shapes disagree.
bool runtime_climate_parity_adopt_comparable_fields(
        RuntimeClimateStore &target, const RuntimeClimateStore &reference);

// Stable identifier for a stage, used in reports and artifacts.
const char *runtime_climate_stage_name(RuntimeClimateStage stage);

// Verifies the properties the parity contract depends on: the table is
// self-consistent, worker-only bookkeeping cannot move the hash, physical
// fields can, and first-difference reporting points at the right cell.
bool runtime_climate_parity_self_test(std::string &error);

} // namespace pk
