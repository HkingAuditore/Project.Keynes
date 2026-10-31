// Rebuilt-kernel verification (plan 22 §5.1 / §5.5 / §12.4 / §15.5).
//
// WHY THIS FILE EXISTS
//
// The five new headers/impls were destroyed by a `git pull` (they were never
// tracked) and rebuilt from their call sites in `ideology_runtime.cpp`,
// `modifier_runtime.cpp` and `world_ext_modifier.cpp`. A rebuild that only
// COMPILES proves nothing: the semantics have to be re-derived and re-asserted.
//
// So this file pins the four contracts the rebuild had to reproduce:
//
//   A. plan §5.1 fold: `clamp((base + add_total) * factor_total, min, max)` with
//      ONE clamp at the end;
//   B. plan §5.5: a zero factor annihilates the product, and is COUNTED (the
//      product cannot recover "there was a zero" afterwards);
//   C. plan §12.4: the derived path never truncates -- 1000 cells stay 1000;
//   D. plan I13 / §7.4: identical content is an idempotent no-op (`out_skipped`).
//
// Plus the per-target magnitude scale that M4-2 identified: a source-count card
// must scale each cell by its own `magnitude_scale`, and the rebuild's `add`
// signature returns bool so a malformed row cannot be silently dropped.
//
// Build:
//   cl /std:c++17 /O2 /EHsc /W4 /I src tests\derived_layer_rebuild_test.cpp ^
//      src\derived_cell_materializer.cpp

#include "cell_program_eligibility.h"
#include "derived_cell_layer.h"
#include "derived_cell_materializer.h"
#include "selector_ownership.h"
#include "selector_cell_cap.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;

void expect(bool ok, const char *label, const std::string &detail = "") {
    ++g_checks;
    if (ok) return;
    ++g_failures;
    std::fprintf(stderr, "FAIL %s %s\n", label, detail.c_str());
}

bool near(double a, double b) { return std::fabs(a - b) < 1e-9; }

pk::DerivedProgramContribution make_program(
        std::vector<int32_t> cells, int32_t stat_id, double add, double factor,
        int32_t operation = 0, double magnitude_scale = 1.0) {
    pk::DerivedProgramContribution program;
    program.source_country = 0xA1;
    program.backend = pk::CellProgramBackend::DerivedCell;
    program.cells = std::move(cells);
    program.magnitude_scale = magnitude_scale;
    pk::DerivedProgramContribution::Term term;
    term.stat_id = stat_id;
    term.operation = operation;
    term.add = add;
    term.factor = factor;
    program.terms.push_back(term);
    return program;
}

struct Built {
    pk::DerivedCellFront front;
    pk::DerivedMaterializeReport report;
    bool skipped = false;
    bool ok = false;
};

Built build(const std::vector<pk::DerivedProgramContribution> &programs,
            const pk::DerivedCellFront *previous = nullptr) {
    Built out;
    out.ok = pk::build_derived_cell_front(
        programs, 1, 1, 1, 1, 1, previous, out.front, out.report, out.skipped);
    return out;
}

// The plan §5.1 formula, applied once.
double effective(const pk::DerivedCellContribution &slot, double base,
                 double min_v, double max_v) {
    const double factor = slot.zero_factor_count > 0 ? 0.0 : slot.product_nonzero;
    const double raw = (base + slot.sum_add) * factor;
    return raw < min_v ? min_v : (raw > max_v ? max_v : raw);
}

// A: the fold is a sum and a product, clamped once.
void test_fold_and_single_clamp() {
    const int32_t stat = 4;
    std::vector<pk::DerivedProgramContribution> programs;
    programs.push_back(make_program({7}, stat, 1.0, 1.0));            // +1.0
    programs.push_back(make_program({7}, stat, 0.0, 2.0, 0, 1.0));    // factor 2
    // A factor term carries its factor in `factor`, so add 0 keeps the sum at 1.
    const Built b = build(programs);
    const pk::DerivedCellStatRow *row = b.front.row_for_stat(stat);
    expect(row != nullptr, "A: the stat row exists");
    if (row == nullptr) return;
    const pk::DerivedCellContribution *slot = row->find(7);
    expect(slot != nullptr, "A: the cell exists");
    if (slot == nullptr) return;
    expect(near(slot->sum_add, 1.0), "A: adds accumulate",
        std::to_string(slot->sum_add));
    expect(near(slot->product_nonzero, 2.0), "A: factors multiply",
        std::to_string(slot->product_nonzero));
    // (base 1 + 1) * 2 = 4
    expect(near(effective(*slot, 1.0, 0.0, 100.0), 4.0),
        "A: the fold is (base+add)*factor");
    // One clamp: a value above max pins at max, and is NOT re-multiplied.
    expect(near(effective(*slot, 1.0, 0.0, 3.0), 3.0),
        "A: the clamp applies once, at the end");
}

// B: a zero factor annihilates, and is counted separately.
void test_zero_factor_is_counted() {
    const int32_t stat = 9;
    std::vector<pk::DerivedProgramContribution> programs;
    programs.push_back(make_program({2}, stat, 5.0, 1.0));
    programs.push_back(make_program({2}, stat, 0.0, 0.0));  // -100%
    const Built b = build(programs);
    const pk::DerivedCellStatRow *row = b.front.row_for_stat(stat);
    expect(row != nullptr, "B: the stat row exists");
    if (row == nullptr) return;
    const pk::DerivedCellContribution *slot = row->find(2);
    expect(slot != nullptr, "B: the cell exists");
    if (slot == nullptr) return;
    expect(slot->zero_factor_count == 1, "B: one zero factor recorded",
        std::to_string(slot->zero_factor_count));
    // The non-zero product must NOT have been multiplied by the zero.
    expect(near(slot->product_nonzero, 1.0),
        "B: a zero does not enter the product",
        std::to_string(slot->product_nonzero));
    expect(near(effective(*slot, 1.0, 0.0, 100.0), 0.0),
        "B: annihilation yields the clamp minimum");
}

// C: no truncation, at any size.
void test_no_truncation() {
    const int32_t stat = 11;
    std::vector<int32_t> cells;
    for (int32_t i = 0; i < 1000; ++i) cells.push_back(i);
    const Built b = build({make_program(cells, stat, 0.01, 1.0)});
    expect(b.report.truncated == 0, "C: truncated stays 0 at 1000 cells",
        std::to_string(b.report.truncated));
    const pk::DerivedCellStatRow *row = b.front.row_for_stat(stat);
    expect(row != nullptr, "C: the stat row exists");
    if (row == nullptr) return;
    expect(row->cells.size() == 1000, "C: all 1000 cells survive",
        std::to_string(row->cells.size()));
    expect(b.report.cells_visited == 1000, "C: the report counted every cell",
        std::to_string(b.report.cells_visited));
}

// D: identical content is an idempotent no-op.
void test_idempotent_skip() {
    const int32_t stat = 13;
    std::vector<pk::DerivedProgramContribution> programs{
        make_program({1, 2, 3}, stat, 0.5, 1.0)};
    const Built first = build(programs);
    expect(!first.skipped, "D: the first build is not skipped");
    const Built second = build(programs, &first.front);
    expect(second.skipped, "D: an identical rebuild is skipped");
}

// E: `magnitude_scale` is the CALLER's to consume, not the materializer's.
//
// The collector already multiplies each term by that target's scale
// (`ideology_runtime.cpp:2353`). Applying it again inside the fold made a cell that
// should read 1.06 read 1.03 -- 0.12 x 0.5 x 0.5. So the field stays on the struct
// for hand-built contributions, and the fold must IGNORE it.
//
// This assertion exists to keep that division of labour from drifting back: if the
// fold starts applying the scale again, x1b's T2 fails and this test says why.
void test_magnitude_scale_not_double_applied() {
    const int32_t stat = 15;
    std::vector<pk::DerivedProgramContribution> programs;
    programs.push_back(make_program({5}, stat, 0.20, 1.0, 0, 1.0));
    programs.push_back(make_program({5}, stat, 0.20, 1.0, 0, 0.5));
    const Built b = build(programs);
    const pk::DerivedCellStatRow *row = b.front.row_for_stat(stat);
    expect(row != nullptr, "E: the stat row exists");
    if (row == nullptr) return;
    const pk::DerivedCellContribution *slot = row->find(5);
    expect(slot != nullptr, "E: the cell exists");
    if (slot == nullptr) return;
    // Both terms carry their own `add` unchanged: 0.20 + 0.20 = 0.40.
    // If the fold applied the scale it would be 0.30.
    expect(near(slot->sum_add, 0.40),
        "E: the fold does NOT re-apply magnitude_scale",
        std::to_string(slot->sum_add));
}

// F: a non-derived program is skipped, never coerced (I01).
void test_i01_skip() {
    const int32_t stat = 17;
    pk::DerivedProgramContribution legacy = make_program({1}, stat, 1.0, 1.0);
    legacy.backend = pk::CellProgramBackend::EffectInstance;
    const Built b = build({legacy});
    expect(b.report.programs_skipped_legacy == 1,
        "F: an EffectInstance program is skipped",
        std::to_string(b.report.programs_skipped_legacy));
    expect(b.front.row_for_stat(stat) == nullptr,
        "F: and contributes no row");
}

// G: the ramp path defers without a sampler instead of folding to zero.
void test_ramp_deferred_without_sampler() {
    const int32_t stat = 19;
    pk::DerivedProgramContribution program = make_program({3}, stat, 0.0, 1.0);
    program.terms[0].magnitude_source =
        pk::DerivedProgramContribution::MagnitudeSource::RampMetric;
    program.terms[0].metric_id = 57;
    program.terms[0].ramp_scale = 0.5;
    const Built b = build({program});
    expect(b.report.ramp_terms_deferred == 1,
        "G: a ramp without a sampler is DEFERRED",
        std::to_string(b.report.ramp_terms_deferred));
    expect(b.report.ramp_terms_evaluated == 0,
        "G: and not evaluated");
    const pk::DerivedCellStatRow *row = b.front.row_for_stat(stat);
    // The cell is visited but contributes nothing; a zero would mute the effect.
    if (row != nullptr) {
        const pk::DerivedCellContribution *slot = row->find(3);
        if (slot != nullptr) {
            expect(near(slot->sum_add, 0.0),
                "G: the deferred cell adds nothing");
        }
    }
}

// H: the ramp path evaluates per cell when a sampler is supplied.
void test_ramp_per_cell() {
    const int32_t stat = 21;
    pk::DerivedProgramContribution program =
        make_program({2, 4}, stat, 0.0, 1.0);
    program.terms[0].magnitude_source =
        pk::DerivedProgramContribution::MagnitudeSource::RampMetric;
    program.terms[0].metric_id = 57;
    program.terms[0].ramp_scale = 0.5;
    pk::DerivedRampSampler sampler = [](int32_t, int32_t cell, uint64_t) {
        return static_cast<double>(cell) * 2.0;
    };
    pk::DerivedMaterializeOptions options;
    options.ramp_sampler = &sampler;
    pk::DerivedCellFront front;
    pk::DerivedMaterializeReport report;
    bool skipped = false;
    const bool ok = pk::build_derived_cell_front(
        {program}, 1, 1, 1, 1, 1, nullptr, front, report, skipped, options);
    expect(ok, "H: the ramp build succeeds");
    expect(report.ramp_terms_evaluated == 2,
        "H: both cells were evaluated",
        std::to_string(report.ramp_terms_evaluated));
    const pk::DerivedCellStatRow *row = front.row_for_stat(stat);
    expect(row != nullptr, "H: the stat row exists");
    if (row == nullptr) return;
    // cell 2 -> 2*2.0*0.5 = 2.0 ; cell 4 -> 4*2.0*0.5 = 4.0
    const pk::DerivedCellContribution *two = row->find(2);
    const pk::DerivedCellContribution *four = row->find(4);
    expect(two != nullptr && four != nullptr, "H: both cells exist");
    if (two != nullptr) {
        expect(near(two->sum_add, 2.0), "H: cell 2 magnitude",
            std::to_string(two->sum_add));
    }
    if (four != nullptr) {
        expect(near(four->sum_add, 4.0), "H: cell 4 magnitude",
            std::to_string(four->sum_add));
    }
    expect(!near(two != nullptr ? two->sum_add : 0.0,
                 four != nullptr ? four->sum_add : 0.0),
        "H: different cells get DIFFERENT magnitudes");
}

// I: the eligibility column (I01) — one backend per program.
void test_eligibility() {
    pk::CellProgramFacts facts;
    facts.target_domain = 2;
    facts.selector_kind = 12;
    facts.lifecycle = 0;
    pk::CellProgramCommandFacts command;
    command.value_mode = 0;  // VALUE_CONSTANT
    command.definition_resolved = true;
    command.all_terms_sum = true;
    facts.commands.push_back(command);
    const pk::CellProgramDecision ok = pk::decide_cell_program_backend(facts);
    expect(ok.backend == pk::CellProgramBackend::DerivedCell,
        "I: a permanent cell program is DerivedCell");
    expect(ok.reason == pk::CellProgramLegacyReason::None,
        "I: with no legacy reason");

    // A metric ramp is EXPRESSIBLE since M3 (it was deferred before).
    pk::CellProgramFacts ramp = facts;
    ramp.commands[0].value_mode = 1;
    ramp.commands[0].stack_top_is_constant = false;
    ramp.commands[0].has_metric_ramp = true;
    expect(pk::decide_cell_program_backend(ramp).backend ==
               pk::CellProgramBackend::DerivedCell,
        "I: a metric ramp is admitted");

    // A non-constant, non-ramp magnitude is still refused.
    pk::CellProgramFacts refused = facts;
    refused.commands[0].value_mode = 1;
    refused.commands[0].stack_top_is_constant = false;
    refused.commands[0].has_metric_ramp = false;
    const pk::CellProgramDecision bad =
        pk::decide_cell_program_backend(refused);
    expect(bad.backend == pk::CellProgramBackend::EffectInstance,
        "I: a non-constant non-ramp magnitude stays on the instance path");
    expect(bad.reason == pk::CellProgramLegacyReason::NonConstantValueMode,
        "I: and is named");

    // Rollout is separate from capability.
    expect(pk::cell_program_rollout_enabled(12),
        "I: kind 12 is enabled at the current milestone");
    expect(pk::cell_program_rollout_enabled(16),
        "I: kind 16 is enabled at the current milestone (M4)");
}

// J: the cap split (M2-1 / M2-5).
void test_cell_cap_split() {
    using namespace pk;
    expect(selector_cell_ceiling(CAP_SELECTOR_NEIGHBORS_R1) == 6,
        "J: R1 reaches 6 cells");
    expect(selector_cell_ceiling(CAP_SELECTOR_NEIGHBORS_R2) == 18,
        "J: R2 reaches 18 cells");
    expect(selector_cell_cap_is_unbounded(CAP_SELECTOR_OWN_TERRITORY),
        "J: territory has no POLICY cap");
    // An authored 0 on a territory query means the WHOLE territory.
    expect(resolve_selector_cell_cap(CAP_SELECTOR_OWN_TERRITORY, 0, 1600) == 1600,
        "J: authored 0 + territory = the whole map");
    // An explicit 32 still wins, so content and behaviour stay separable.
    expect(resolve_selector_cell_cap(CAP_SELECTOR_OWN_TERRITORY, 32, 1600) == 32,
        "J: an explicit 32 is still honoured");
    // No map means no query, not "everything".
    expect(resolve_selector_cell_cap(CAP_SELECTOR_OWN_TERRITORY, 0, 0) == 0,
        "J: no map yields 0");
    // Bounded kinds clamp to their geometric ceiling.
    expect(resolve_selector_cell_cap(CAP_SELECTOR_NEIGHBORS_R1, 100, 1600) == 6,
        "J: R1 clamps to 6");
    // The AUTHORED ceiling stays 32 for bounded kinds: shipped content authors 8
    // for R1 whose walk yields 6, so validating against geometry would reject it.
    expect(selector_authored_cell_ceiling(CAP_SELECTOR_NEIGHBORS_R1) == 32,
        "J: the authored ceiling stays at the legacy 32 for bounded kinds");
    expect(selector_authored_cap_is_unbounded(CAP_SELECTOR_OWN_TERRITORY),
        "J: unbounded kinds accept any authored value");
    // An unknown kind must not become unbounded.
    expect(selector_cell_ceiling(9999) == 0,
        "J: an unknown kind has no ceiling at all");
}


// K: the RESUMABLE job must produce EXACTLY what the one-shot build produces.
//
// This is the assertion the first sharding attempt (M4-18) was missing entirely: it
// looped a slice vector that was never handed to the builder, so it "sharded" by
// doing nothing. A job split across TWO steps with a zero budget must still fold
// every contribution, and its front must match the one-shot front value for value.
void test_resumable_job_matches_one_shot() {
    const int32_t stat = 31;
    std::vector<pk::DerivedProgramContribution> programs;
    for (int32_t cell = 0; cell < 50; ++cell)
        programs.push_back(make_program({cell}, stat, 0.1, 1.0));

    // One-shot.
    pk::DerivedCellFront once;
    pk::DerivedMaterializeReport once_report;
    bool once_skipped = false;
    const bool once_ok = pk::build_derived_cell_front(
        programs, 1, 1, 1, 1, 1, nullptr, once, once_report, once_skipped);
    expect(once_ok, "K: the one-shot build succeeds");

    // Resumable, deliberately split across many steps: a 0 budget forces one
    // contribution per step, which is the worst case for a resume bug.
    pk::DerivedCellMaterializeJob job(1, 1, 1, 1, 1, pk::DerivedMaterializeOptions{});
    int steps = 0;
    while (!job.done() && steps < 1000) {
        job.fold_step(programs, 0.0);
        ++steps;
    }
    expect(job.done(), "K: the job reaches done", std::to_string(steps));
    expect(steps > 1, "K: the job really took multiple steps",
        std::to_string(steps));
    expect(job.total() == programs.size(), "K: the job saw every contribution",
        std::to_string(job.total()));

    pk::DerivedCellFront split;
    pk::DerivedMaterializeReport split_report;
    bool split_skipped = false;
    const bool split_ok = job.finish(nullptr, split, split_report, split_skipped);
    expect(split_ok, "K: the job finishes");

    const pk::DerivedCellStatRow *row_once = once.row_for_stat(stat);
    const pk::DerivedCellStatRow *row_split = split.row_for_stat(stat);
    expect(row_once != nullptr, "K: one-shot row exists");
    expect(row_split != nullptr, "K: split row exists");
    if (row_once == nullptr || row_split == nullptr) return;
    expect(row_once->cells.size() == row_split->cells.size(),
        "K: the SAME cell count survives the split",
        std::to_string(row_once->cells.size()) + " vs " +
            std::to_string(row_split->cells.size()));
    expect(row_once->cells.size() == 50, "K: all 50 cells are present",
        std::to_string(row_once->cells.size()));
    double sum_once = 0.0;
    double sum_split = 0.0;
    for (const pk::DerivedCellContribution &slot : row_once->contributions)
        sum_once += slot.sum_add;
    for (const pk::DerivedCellContribution &slot : row_split->contributions)
        sum_split += slot.sum_add;
    expect(near(sum_once, sum_split),
        "K: the split front has the same total value",
        std::to_string(sum_once) + " vs " + std::to_string(sum_split));
    expect(split_report.cells_visited == once_report.cells_visited,
        "K: the split visited the same cells",
        std::to_string(split_report.cells_visited) + " vs " +
            std::to_string(once_report.cells_visited));
}


// L: the RESUMABLE job must still EVALUATE ramp terms.
//
// M4-19 constructed the job with an empty `DerivedMaterializeOptions`, so every ramp
// term was DEFERRED instead of evaluated while the one-shot path still evaluated them.
// That is a silent behaviour change: a ramp card would simply contribute nothing.
//
// A zero-budget split is used deliberately, because the resume path is where the
// options were lost.
void test_resumable_job_evaluates_ramps() {
    const int32_t stat = 41;
    pk::DerivedProgramContribution program = make_program({2, 4, 6}, stat, 0.0, 1.0);
    program.terms[0].magnitude_source =
        pk::DerivedProgramContribution::MagnitudeSource::RampMetric;
    program.terms[0].metric_id = 57;
    program.terms[0].ramp_scale = 0.5;

    pk::DerivedRampSampler sampler = [](int32_t, int32_t cell, uint64_t) {
        return static_cast<double>(cell) * 2.0;
    };
    pk::DerivedMaterializeOptions options;
    options.ramp_sampler = &sampler;

    pk::DerivedCellMaterializeJob job(1, 1, 1, 1, 1, options);
    int steps = 0;
    while (!job.done() && steps < 100) {
        job.fold_step({program}, 0.0);   // zero budget: one step per contribution
        ++steps;
    }
    pk::DerivedCellFront front;
    pk::DerivedMaterializeReport report;
    bool skipped = false;
    const bool ok = job.finish(nullptr, front, report, skipped);
    expect(ok, "L: the sharded ramp build succeeds");
    expect(report.ramp_terms_deferred == 0,
        "L: NO ramp term is deferred when a sampler is supplied",
        std::to_string(report.ramp_terms_deferred));
    expect(report.ramp_terms_evaluated == 3,
        "L: every cell evaluated its ramp",
        std::to_string(report.ramp_terms_evaluated));

    const pk::DerivedCellStatRow *row = front.row_for_stat(stat);
    expect(row != nullptr, "L: the stat row exists");
    if (row == nullptr) return;
    // cell 2 -> 2*2.0*0.5 = 2 ; cell 4 -> 4 ; cell 6 -> 6
    const pk::DerivedCellContribution *two = row->find(2);
    const pk::DerivedCellContribution *six = row->find(6);
    expect(two != nullptr && six != nullptr, "L: both cells exist");
    if (two != nullptr) {
        expect(near(two->sum_add, 2.0), "L: cell 2 magnitude",
            std::to_string(two->sum_add));
    }
    if (six != nullptr) {
        expect(near(six->sum_add, 6.0), "L: cell 6 magnitude",
            std::to_string(six->sum_add));
    }
}


// M: ownership scope for a source fan-out (kinds 14/15/16).
//
// The fan-out used to be ownership-blind, so a "周围地块" card reached foreign cells
// across a border. The scope lives in bits 12..13 of `target_selector_param[0]`, and
// the DEFAULT must be OWN -- a card that names nothing stays home.
//
// These are decode assertions, deliberately: the filter itself is a one-line predicate
// over `cell_country_slot`, and a wrong DEFAULT would silently disable every existing
// card. That is the failure mode worth pinning here.
void test_ownership_scope_decode() {
    namespace ER = pk;   // the pure header is Godot-free on purpose

    // A card whose param[0] is just a cap (32) must decode as the OWN default.
    expect(ER::decode_ownership_scope(32) == ER::OWNERSHIP_OWN,
        "M: an unauthored scope defaults to OWN",
        std::to_string(ER::decode_ownership_scope(32)));

    // The kind-16 live values from content (radius/cap bits set, scope absent) must
    // also read as OWN, or the 66 shipped kind-16 cards would silently keep the old
    // border-blind behaviour.
    for (const int32_t live : {544, 576, 800, 832, 864, 1568}) {
        expect(ER::decode_ownership_scope(live) == ER::OWNERSHIP_OWN,
            "M: a live kind-16 param decodes as OWN",
            std::to_string(live) + " -> " +
                std::to_string(ER::decode_ownership_scope(live)));
    }

    // Explicit scopes round-trip.
    const int32_t own = 32 | (ER::OWNERSHIP_OWN << ER::OWNERSHIP_SCOPE_SHIFT);
    const int32_t foreign = 32 | (ER::OWNERSHIP_FOREIGN << ER::OWNERSHIP_SCOPE_SHIFT);
    const int32_t any = 32 | (ER::OWNERSHIP_ANY << ER::OWNERSHIP_SCOPE_SHIFT);
    expect(ER::decode_ownership_scope(own) == ER::OWNERSHIP_OWN, "M: OWN round-trips");
    expect(ER::decode_ownership_scope(foreign) == ER::OWNERSHIP_FOREIGN,
        "M: FOREIGN round-trips");
    expect(ER::decode_ownership_scope(any) == ER::OWNERSHIP_ANY,
        "M: ANY round-trips");

    // An out-of-range value (3) must fall back to ANY, not OWN: silently restricting a
    // card whose intent is unclear would empty its target set with no signal.
    expect(ER::decode_ownership_scope(32 | (3 << ER::OWNERSHIP_SCOPE_SHIFT)) ==
            ER::OWNERSHIP_ANY,
        "M: an unknown scope falls back to ANY");

    // The scope bits must NOT leak into the cap. Before masking, cap 0 (meaning "the
    // kind's default") became 4096, and `4096 > 0` made the sentinel look authored.
    expect(ER::ownership_stripped_cap(ER::OWNERSHIP_ANY << ER::OWNERSHIP_SCOPE_SHIFT)
            == 0,
        "M: masking the scope leaves cap 0 intact",
        std::to_string(ER::ownership_stripped_cap(
            ER::OWNERSHIP_ANY << ER::OWNERSHIP_SCOPE_SHIFT)));
    expect(ER::ownership_stripped_cap(any) == 32,
        "M: masking keeps an authored cap of 32",
        std::to_string(ER::ownership_stripped_cap(any)));

    // The FILTER predicate -- the actual behaviour change.
    expect(ER::ownership_accepts(ER::OWNERSHIP_OWN, true) &&
            !ER::ownership_accepts(ER::OWNERSHIP_OWN, false),
        "M: OWN accepts own cells only");
    expect(ER::ownership_accepts(ER::OWNERSHIP_FOREIGN, false) &&
            !ER::ownership_accepts(ER::OWNERSHIP_FOREIGN, true),
        "M: FOREIGN accepts foreign cells only");
    expect(ER::ownership_accepts(ER::OWNERSHIP_ANY, true) &&
            ER::ownership_accepts(ER::OWNERSHIP_ANY, false),
        "M: ANY accepts both");

    // OWN and FOREIGN must PARTITION the unscoped set for any mixed list of cells.
    // This is the property the end-to-end test would assert; checking it on the
    // predicate keeps the guarantee testable without a world.
    int own_kept = 0;
    int foreign_kept = 0;
    int any_kept = 0;
    for (int i = 0; i < 20; ++i) {
        const bool is_own = (i % 3) != 0;   // a mix, not all one side
        if (ER::ownership_accepts(ER::OWNERSHIP_OWN, is_own)) ++own_kept;
        if (ER::ownership_accepts(ER::OWNERSHIP_FOREIGN, is_own)) ++foreign_kept;
        if (ER::ownership_accepts(ER::OWNERSHIP_ANY, is_own)) ++any_kept;
    }
    expect(own_kept > 0 && foreign_kept > 0, "M: the sample has both sides",
        std::to_string(own_kept) + "/" + std::to_string(foreign_kept));
    expect(own_kept + foreign_kept == any_kept,
        "M: OWN + FOREIGN partition ANY",
        std::to_string(own_kept) + " + " + std::to_string(foreign_kept) +
            " != " + std::to_string(any_kept));


    // ── THREE cases, not two: unowned land is neither own nor foreign ──────
    //
    // The first cut collapsed both into `is_own == false`, so OWNERSHIP_FOREIGN
    // accepted every unowned cell. Neutral land is not "another country"; folding it
    // into FOREIGN would have shipped a wrong semantic into the first card that uses
    // that scope. Unowned cells are NEGATIVE slots
    // (`economy_runtime_family_buff.cpp:953`).
    constexpr int32_t kMe = 0;
    constexpr int32_t kThem = 1;
    constexpr int32_t kNobody = -1;
    expect(ER::ownership_relation(kMe, kMe) == ER::OWNERSHIP_RELATION_OWN,
        "M3: same slot is OWN");
    expect(ER::ownership_relation(kMe, kThem) == ER::OWNERSHIP_RELATION_OTHER_COUNTRY,
        "M3: a different real slot is OTHER_COUNTRY");
    expect(ER::ownership_relation(kMe, kNobody) == ER::OWNERSHIP_RELATION_UNOWNED,
        "M3: a negative slot is UNOWNED");
    // Even when the SOURCE itself is unowned, the target's relation is about the target.
    expect(ER::ownership_relation(kNobody, kThem) ==
            ER::OWNERSHIP_RELATION_OTHER_COUNTRY,
        "M3: relation is target-relative");

    expect(!ER::ownership_accepts(ER::OWNERSHIP_OWN, ER::OWNERSHIP_RELATION_UNOWNED),
        "M3: OWN rejects unowned land");
    expect(!ER::ownership_accepts(ER::OWNERSHIP_FOREIGN,
            ER::OWNERSHIP_RELATION_UNOWNED),
        "M3: FOREIGN rejects unowned land (the fix)");
    expect(ER::ownership_accepts(ER::OWNERSHIP_ANY, ER::OWNERSHIP_RELATION_UNOWNED),
        "M3: ANY accepts unowned land");

    // And the partition property still holds over REAL countries only; unowned cells
    // are outside it by construction rather than being double-counted into FOREIGN.
    int partition_own = 0;
    int partition_foreign = 0;
    int partition_any = 0;
    int partition_unowned_taken = 0;
    int partition_unowned = 0;
    for (int32_t target = -3; target < 10; ++target) {
        const ER::OwnershipRelation rel = ER::ownership_relation(kMe, target);
        if (rel == ER::OWNERSHIP_RELATION_UNOWNED) ++partition_unowned;
        if (ER::ownership_accepts(ER::OWNERSHIP_OWN, rel)) ++partition_own;
        if (ER::ownership_accepts(ER::OWNERSHIP_FOREIGN, rel)) ++partition_foreign;
        if (ER::ownership_accepts(ER::OWNERSHIP_ANY, rel)) ++partition_any;
        if (rel == ER::OWNERSHIP_RELATION_UNOWNED &&
                (ER::ownership_accepts(ER::OWNERSHIP_OWN, rel) ||
                 ER::ownership_accepts(ER::OWNERSHIP_FOREIGN, rel)))
            ++partition_unowned_taken;
    }
    expect(partition_unowned_taken == 0,
        "M3: no unowned cell is taken by OWN or FOREIGN",
        std::to_string(partition_unowned_taken));
    expect(partition_unowned == 3, "M3: the sweep really contains unowned slots",
        std::to_string(partition_unowned));
    expect(partition_own + partition_foreign + partition_unowned == partition_any,
        "M3: OWN + FOREIGN + unowned == ANY",
        std::to_string(partition_own) + "+" + std::to_string(partition_foreign) +
            "+" + std::to_string(partition_unowned) + " vs " +
            std::to_string(partition_any));
}


// N: a NEGATIVE additive delta must fold as a sum, not as a multiplier.
//
// The old v1 plane guarded this ("a cut definition yields a negative delta"): a debuff
// arrives as an ADD term whose `value` is negative, because Modifier magnitudes are
// clamped to [0, 4] and cannot carry a sign. Getting it wrong turns every "-8%" card
// into "+8%" and nothing in the pipeline complains.
//
// This is the assertion that lets the plane be deleted: the coverage is not unique to
// the plane, it just used to live there.
void test_negative_delta_folds_additively() {
    const int32_t stat = 43;
    // A -12.5% cut: additive delta -0.125, factor identity.
    const Built debuff = build({make_program({1}, stat, -0.125, 1.0)});
    const pk::DerivedCellStatRow *row = debuff.front.row_for_stat(stat);
    expect(row != nullptr, "N: the debuff row exists");
    if (row == nullptr) return;
    const pk::DerivedCellContribution *slot = row->find(1);
    expect(slot != nullptr, "N: the debuff cell exists");
    if (slot == nullptr) return;
    expect(near(slot->sum_add, -0.125), "N: the negative delta is kept as a sum term",
        std::to_string(slot->sum_add));
    expect(near(slot->product_nonzero, 1.0),
        "N: and does NOT become a multiplier",
        std::to_string(slot->product_nonzero));
    // 1.0 base - 0.125 = 0.875. Reading it as a multiplier would give 1.0 * 0.875 = 0.875
    // too, so the DISCRIMINATING case is a base other than 1.
    expect(near(effective(*slot, 2.0, 0.0, 100.0), 1.875),
        "N: with base 2 the sum is 1.875 (a multiplier would give 1.75)",
        std::to_string(effective(*slot, 2.0, 0.0, 100.0)));

    // A pure multiplier must scale the base instead.
    const Built buff = build({make_program({1}, stat, 0.0, 1.5, 1)});
    const pk::DerivedCellStatRow *mrow = buff.front.row_for_stat(stat);
    expect(mrow != nullptr, "N: the multiplier row exists");
    if (mrow == nullptr) return;
    const pk::DerivedCellContribution *mslot = mrow->find(1);
    expect(mslot != nullptr, "N: the multiplier cell exists");
    if (mslot == nullptr) return;
    expect(near(effective(*mslot, 2.0, 0.0, 100.0), 3.0),
        "N: with base 2 the multiplier gives 3.0",
        std::to_string(effective(*mslot, 2.0, 0.0, 100.0)));
}

// O: the BACKLOG is a measurement, not a constant.
//
// Plan 18.3 asks for "peak memory, allocations and backlog". Memory and the allocation
// count are already reported (`scratch_bytes`, `allocations`), and `scratch_bytes` was
// proven non-zero. `backlog` had no definition at all: the plan's evidence quoted B3's
// "9 calls per day", which is a function of the slice budget rather than of the world.
//
// The definition pinned here is `rebuild_backlog_cells`: cell-visits the fold still OWES
// at a slice boundary (`total_cells - cells_visited`). It is not a second copy of
// `cells_visited` -- that counts work done, this counts work left, and their sum is the
// queue, which nothing else reports.
//
// The point of this test is that the field MOVES: it must be non-zero when the fold
// spans slices and zero when it does not. A counter that reads 0 everywhere is a dead
// field, and this codebase has shipped several.
void test_rebuild_backlog() {
    const int32_t stat = 47;
    std::vector<pk::DerivedProgramContribution> programs;
    // 40 contributions, one term and one cell each, so the whole job is exactly 40
    // cell-visits of work. Small on purpose: a zero budget then yields 40 slices, which
    // is the worst case for the resume path and the easiest depth to predict by hand.
    for (int32_t cell = 0; cell < 40; ++cell)
        programs.push_back(make_program({cell}, stat, 0.1, 1.0));

    // (1) ZERO case A -- the single-shot path. It folds every contribution before it
    // returns, so no cell is ever left owed BETWEEN slices.
    const Built once = build(programs);
    expect(once.report.rebuild_backlog_cells == 0,
        "O: the single-shot build owes no backlog",
        std::to_string(once.report.rebuild_backlog_cells));
    expect(once.report.rebuild_backlog_peak_cells == 0,
        "O: and never had any",
        std::to_string(once.report.rebuild_backlog_peak_cells));

    // (2) ZERO case B -- a resumable job whose one slice clears the whole list. The
    // number tracks QUEUED work, not the job's size, so a fast enough slice leaves no
    // backlog even though 40 cells were folded.
    {
        pk::DerivedCellMaterializeJob job(1, 1, 1, 1, 1,
                                          pk::DerivedMaterializeOptions{});
        job.fold_step(programs, 1.0e9);
        expect(job.done(), "O: one generous slice finishes the fold");
        pk::DerivedCellFront front;
        pk::DerivedMaterializeReport report;
        bool skipped = false;
        job.finish(nullptr, front, report, skipped);
        expect(report.cells_visited == 40, "O: one slice visited every cell",
            std::to_string(report.cells_visited));
        expect(report.rebuild_backlog_cells == 0,
            "O: no backlog after that slice",
            std::to_string(report.rebuild_backlog_cells));
        expect(report.rebuild_backlog_peak_cells == 0,
            "O: a one-slice rebuild never queued anything",
            std::to_string(report.rebuild_backlog_peak_cells));
        // Printed, not just asserted: the plan's 18.3 row quotes a NUMBER, and a number
        // that only ever appears as a pass/fail verdict cannot be quoted.
        std::printf("[backlog] one-slice rebuild: backlog=%lld peak=%lld "
                    "cells_visited=%lld\n",
                    static_cast<long long>(report.rebuild_backlog_cells),
                    static_cast<long long>(report.rebuild_backlog_peak_cells),
                    static_cast<long long>(report.cells_visited));
    }

    // (3) NON-ZERO -- a zero budget forces one contribution per slice, so the queue is
    // real. After the first slice 39 of the 40 cells are still owed.
    {
        pk::DerivedCellMaterializeJob job(1, 1, 1, 1, 1,
                                          pk::DerivedMaterializeOptions{});
        int steps = 0;
        int64_t first_depth = -1;
        bool monotonic = true;
        int64_t previous_depth = -1;
        while (!job.done() && steps < 1000) {
            job.fold_step(programs, 0.0);   // zero budget: one contribution per slice
            ++steps;
            // Read BETWEEN slices: this is the only point the field is observable, and
            // the reason `live_report()` exists.
            const int64_t depth = job.live_report().rebuild_backlog_cells;
            if (first_depth < 0) first_depth = depth;
            if (previous_depth >= 0 && depth > previous_depth) monotonic = false;
            previous_depth = depth;
        }
        expect(steps == 40, "O: 40 slices cleared 40 cells",
            std::to_string(steps));
        expect(first_depth == 39,
            "O: after one slice the rebuild OWES 39 of 40 cells",
            std::to_string(first_depth));
        expect(first_depth > 0, "O: so the backlog is NON-ZERO mid-rebuild",
            std::to_string(first_depth));
        expect(monotonic, "O: and it never grows across slices");
        expect(job.live_report().rebuild_backlog_cells == 0,
            "O: it reaches 0 when the fold completes",
            std::to_string(job.live_report().rebuild_backlog_cells));

        pk::DerivedCellFront front;
        pk::DerivedMaterializeReport report;
        bool skipped = false;
        job.finish(nullptr, front, report, skipped);
        expect(report.rebuild_backlog_peak_cells == 39,
            "O: the PEAK survives into the report finish() publishes",
            std::to_string(report.rebuild_backlog_peak_cells));
        expect(report.rebuild_backlog_cells == 0,
            "O: while the terminal backlog is 0 by construction",
            std::to_string(report.rebuild_backlog_cells));
        // The identity that proves this is the COMPLEMENT of `cells_visited` rather than
        // a second copy of it: peak + the work the first slice retired == total work.
        expect(report.cells_visited == 40 &&
                report.rebuild_backlog_peak_cells + 1 == report.cells_visited,
            "O: peak + the first slice == the cells_visited total",
            std::to_string(report.rebuild_backlog_peak_cells) + " + 1 vs " +
                std::to_string(report.cells_visited));
        std::printf("[backlog] 40-slice rebuild: first_depth=%lld peak=%lld "
                    "terminal=%lld cells_visited=%lld\n",
                    static_cast<long long>(first_depth),
                    static_cast<long long>(report.rebuild_backlog_peak_cells),
                    static_cast<long long>(report.rebuild_backlog_cells),
                    static_cast<long long>(report.cells_visited));
    }

    // (4) PARITY of the denominator. `rebuild_backlog_cells` is `total - cells_visited`,
    // so the only way it can lie is if the up-front count applies DIFFERENT skip rules
    // than the fold. The mix below exercises all three skip rules at once: a legacy
    // backend, a program with no cells, and a term with no stat.
    //
    // A drift in either direction fails here: too small a total clamps the terminal value
    // to 0 and would understate the first depth; too large a total leaves the terminal
    // value above 0.
    {
        std::vector<pk::DerivedProgramContribution> mixed;
        for (int32_t cell = 0; cell < 3; ++cell)
            mixed.push_back(make_program({cell}, stat, 0.25, 1.0));
        pk::DerivedProgramContribution legacy = make_program({100}, stat, 9.0, 1.0);
        legacy.backend = pk::CellProgramBackend::EffectInstance;
        mixed.push_back(legacy);                              // no cell is visited
        mixed.push_back(make_program({}, stat, 9.0, 1.0));    // no cells at all
        pk::DerivedProgramContribution no_stat = make_program({101}, -1, 9.0, 1.0);
        mixed.push_back(no_stat);                             // counted as missing_stat

        pk::DerivedCellMaterializeJob job(1, 1, 1, 1, 1,
                                          pk::DerivedMaterializeOptions{});
        int steps = 0;
        int64_t first_depth = -1;
        while (!job.done() && steps < 100) {
            job.fold_step(mixed, 0.0);
            ++steps;
            if (first_depth < 0)
                first_depth = job.live_report().rebuild_backlog_cells;
        }
        pk::DerivedCellFront front;
        pk::DerivedMaterializeReport report;
        bool skipped = false;
        job.finish(nullptr, front, report, skipped);
        expect(first_depth == 2,
            "O: the denominator skips legacy/no-cell/no-stat programs",
            std::to_string(first_depth));
        expect(report.cells_visited == 3,
            "O: only the three legal cells were visited",
            std::to_string(report.cells_visited));
        expect(report.rebuild_backlog_peak_cells == 2,
            "O: so the peak is 2 of 3, not 5 of 6",
            std::to_string(report.rebuild_backlog_peak_cells));
    }
}

}  // namespace

int main() {
    test_fold_and_single_clamp();
    test_zero_factor_is_counted();
    test_no_truncation();
    test_idempotent_skip();
    test_magnitude_scale_not_double_applied();
    test_i01_skip();
    test_ramp_deferred_without_sampler();
    test_ramp_per_cell();
    test_eligibility();
    test_cell_cap_split();
    test_resumable_job_matches_one_shot();
    test_resumable_job_evaluates_ramps();
    test_ownership_scope_decode();
    test_negative_delta_folds_additively();
    test_rebuild_backlog();

    std::printf("=== rebuilt kernel: %d checks, %d failures ===\n",
        g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
