#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"

namespace pk {

bool NativeSimulationHost::publish_ideology_reference(
        int64_t day, const RuntimeIdeologyPodSnapshot &state) {
    if (day < 0) return false;
    // OFF unless a parity harness asked for it. Storing whole snapshots is the
    // most expensive part of this diagnostic (a 64-country world is tens of KB
    // per day), so a production session must not pay for it (03 idle-zero-cost).
    if (!ideology_parity_enabled()) return false;
    // A reference is only a reference if it describes the same shape the worker
    // will produce. The main thread starves its own ideology runtime whenever
    // the day is suppressed for it (worker-authoritative) or the opinion
    // snapshot has not landed yet, and in that state `countries` is EMPTY. Storing
    // that empty state made every later comparison fail with a `points*` field,
    // which pointed at point accrual when the real problem was "the main thread
    // never ran this day at all". Refuse it and report the reason instead.
    size_t populated = 0;
    for (const RuntimeIdeologyPodCountryState &country : state.countries)
        if (country.handle != 0) ++populated;
    if (populated == 0) {
        std::lock_guard<std::mutex> lock(_ideology_parity_mutex);
        ++_ideology_reference_skipped_count;
        store_atomic_chars48(_ideology_reference_skip_reason,
                             "ideology_reference_empty");
        return false;
    }
    const uint64_t hash = ideology_business_hash(state);
    if (hash == 0) return false;
    std::lock_guard<std::mutex> lock(_ideology_parity_mutex);
    // R9-1: the day-keyed map is gone. Nothing ever read it -- the comparison
    // consumes the FIFO below by exact day -- so it was a second full copy of every
    // reference snapshot whose only effect was memory.
    //
    // The FIFO is what the worker actually consumes. Cap it so a worker that
    // stalls cannot grow it without bound; deep enough to cover the calendar
    // offset between the two clocks.
    _ideology_reference_fifo.push_back(state);
    while (_ideology_reference_fifo.size() > 16u)
        _ideology_reference_fifo.pop_front();
    // Record what the reference actually carried. `countries == 0` means the
    // main-thread runtime had not allocated a single country row when the day
    // was published, which is a main-thread starvation, not a worker fault.
    _ideology_last_published.day = day;
    _ideology_last_published.countries = static_cast<int64_t>(populated);
    int32_t with_points_revision = 0;
    for (const RuntimeIdeologyPodCountryState &country : state.countries)
        if (country.handle != 0 && country.points_revision != 0)
            ++with_points_revision;
    _ideology_last_published.with_points_revision = with_points_revision;
    _ideology_last_published.catalog_hash = state.catalog_hash;
    ++_ideology_reference_publish_count;
    return true;
}

void NativeSimulationHost::record_ideology_parity_locked(
        const RuntimeIdeologyPodSnapshot &worker) {
    const uint64_t worker_hash = ideology_business_hash(worker);
    if (worker_hash == 0) return;
    _ideology_parity_worker_hash.store(worker_hash, std::memory_order_release);
    RuntimeIdeologyPodSnapshot reference;
    {
        std::lock_guard<std::mutex> lock(_ideology_parity_mutex);
        // Pair ONLY on an exact calendar day (R8-4).
        //
        // The previous version picked the queued reference whose day was CLOSEST
        // to the worker's, which silently compared day 14 against day 12 and
        // reported the date difference as a business divergence (`matched=0`,
        // first_mismatch_day=1). A nearest-match pairing can never be evidence:
        // the two states describe different days, so any difference is expected
        // and any coincidence is luck.
        //
        // A reference whose day differs from the worker's is now counted as
        // UNCOMPARED and dropped. Fixing the two calendars is the driver's job
        // (run `run_ideology_daily` for the worker's committed day), not the
        // comparator's: fuzzing the pairing hides exactly the defect this gate
        // exists to catch.
        auto exact = _ideology_reference_fifo.end();
        for (auto it = _ideology_reference_fifo.begin();
                it != _ideology_reference_fifo.end(); ++it) {
            if (it->committed_day != worker.committed_day) continue;
            exact = it;
            break;
        }
        if (exact == _ideology_reference_fifo.end()) {
            // Nothing for this day. Record WHY, and do not account it as either
            // compared or matched, so `compared == matched` stays honest.
            const int64_t nearest_distance = _ideology_reference_fifo.empty()
                ? -1
                : std::llabs(_ideology_reference_fifo.back().committed_day -
                             worker.committed_day);
            _ideology_parity_compared.store(false, std::memory_order_release);
            ++_ideology_parity_uncompared_day_offset;
            _ideology_last_uncompared_distance = nearest_distance;
            _ideology_last_reference_day = _ideology_reference_fifo.empty()
                ? -1 : _ideology_reference_fifo.back().committed_day;
            _ideology_last_worker_day = worker.committed_day;
            return;
        }
        reference = *exact;
        _ideology_reference_fifo.erase(exact);
        _ideology_last_reference_day = reference.committed_day;
        _ideology_last_worker_day = worker.committed_day;
    }
    IdeologyBusinessSections reference_sections;
    ideology_business_sections(reference, reference_sections);
    // Locate which country row makes `points_balance` differ. Recomputing the
    // sub-hash row by row is the only way to name it: the section is a running
    // mix, so the first divergent row cannot be recovered from the final value.
    {
        const size_t rows = std::max(reference.countries.size(),
                                     worker.countries.size());
        for (size_t slot = 0; slot < rows; ++slot) {
            const uint64_t rh = slot < reference.countries.size()
                ? reference.countries[slot].handle : 0;
            const uint64_t wh = slot < worker.countries.size()
                ? worker.countries[slot].handle : 0;
            const int64_t rp = slot < reference.countries.size()
                ? reference.countries[slot].ideology_points_q16 : 0;
            const int64_t wp = slot < worker.countries.size()
                ? worker.countries[slot].ideology_points_q16 : 0;
            const int64_t rl = slot < reference.countries.size()
                ? reference.countries[slot].lifetime_points_q16 : 0;
            const int64_t wl = slot < worker.countries.size()
                ? worker.countries[slot].lifetime_points_q16 : 0;
            if (rh == wh && rp == wp && rl == wl) continue;
            std::lock_guard<std::mutex> lock(_ideology_parity_mutex);
            _ideology_points_row_mismatch_slot = static_cast<int64_t>(slot);
            _ideology_points_row_mismatch_reference_handle = rh;
            _ideology_points_row_mismatch_worker_handle = wh;
            _ideology_points_row_mismatch_reference_points = rp;
            _ideology_points_row_mismatch_worker_points = wp;
            break;
        }
    }
    // Catalog READINESS, not catalog equality.
    //
    // The two sides compute `catalog_hash` with two different functions over two
    // different structures, so the values always differ and comparing them
    // counted a mismatch on every single day -- a check that could never fail
    // meaningfully. What parity actually needs is that both sides HOLD a
    // catalog; a zero hash means one side is cold and the comparison is
    // vacuous, which is worth reporting.
    {
        std::lock_guard<std::mutex> lock(_ideology_parity_mutex);
        _ideology_last_reference_catalog_hash = reference.catalog_hash;
        _ideology_last_worker_catalog_hash = worker.catalog_hash;
        if (reference.catalog_hash == 0 || worker.catalog_hash == 0)
            ++_ideology_catalog_mismatch_count;
    }
    // Reference hash is the same mix the publisher used, so the two sides cannot
    // drift apart in how they combine them. `committed_day` is part of that mix.
    const uint64_t reference_hash = ideology_business_hash(reference);
    _ideology_parity_compared.store(true, std::memory_order_release);
    _ideology_parity_compared_count.fetch_add(1, std::memory_order_relaxed);
    _ideology_parity_reference_hash.store(reference_hash,
                                          std::memory_order_release);
    if (reference_hash == worker_hash) {
        _ideology_parity_matched.store(true, std::memory_order_release);
        _ideology_parity_matched_count.fetch_add(1, std::memory_order_relaxed);
        if (_ideology_parity_first_mismatch_day.load(std::memory_order_acquire) < 0)
            _ideology_parity_first_mismatch_day.store(-1,
                std::memory_order_release);
        return;
    }
    _ideology_parity_matched.store(false, std::memory_order_release);
    int64_t first = _ideology_parity_first_mismatch_day.load(
        std::memory_order_acquire);
    if (first < 0)
        _ideology_parity_first_mismatch_day.store(worker.committed_day,
                                                  std::memory_order_release);
    // Name the first diverging section: "mismatch" alone cannot be acted on.
    IdeologyBusinessSections worker_sections;
    ideology_business_sections(worker, worker_sections);
    const char *field = "unknown";
    if (worker_sections.points != reference_sections.points) {
        // Only `points_balance` and `points_lifetime` feed `points`. The
        // `points_revision` / `history_cursor` sub-hashes are diagnostic and
        // deliberately EXCLUDED from the business sections, so they cannot explain
        // a `points` difference -- naming them here reported
        // `field=points_revision` while the real gap was 0 vs 23002 points.
        field = worker_sections.points_balance != reference_sections.points_balance
                ? "points_balance"
            : worker_sections.points_lifetime != reference_sections.points_lifetime
                ? "points_lifetime" : "points";
    } else if (worker_sections.baseline != reference_sections.baseline) field = "baseline";
    else if (worker_sections.history != reference_sections.history) field = "history";
    else if (worker_sections.draw != reference_sections.draw) field = "draw";
    else if (worker_sections.bits != reference_sections.bits) field = "bits";
    else if (worker_sections.offer != reference_sections.offer) field = "offer";
    else if (worker_sections.ideas != reference_sections.ideas) field = "ideas";
    else field = "committed_day";
    // Capture on ANY divergence, not just `points`: the row dump is what makes a
    // failure readable, and after the points section was corrected the first
    // divergent section is usually a different one (observed: `history`). Gating
    // the dump on `points` left `points_diff` empty exactly when it was needed.
    capture_ideology_points_diff(reference, worker);
    store_atomic_chars48(_ideology_parity_field, field);
}

void NativeSimulationHost::capture_ideology_points_diff(
        const RuntimeIdeologyPodSnapshot &reference,
        const RuntimeIdeologyPodSnapshot &worker) {
    // One shot: the first diverging day is the interesting one, and later days
    // only repeat the same offset with a bigger magnitude.
    if (_ideology_points_diff.valid) return;
    IdeologyPointsDiff diff;
    diff.valid = true;
    diff.day = worker.committed_day;
    diff.reference_countries = static_cast<int64_t>(reference.countries.size());
    diff.worker_countries = static_cast<int64_t>(worker.countries.size());
    diff.reference_last_day = reference.committed_day;
    diff.worker_round_day = worker.round_day;
    diff.worker_committed_day = worker.committed_day;
    diff.reference_catalog_hash = static_cast<int64_t>(reference.catalog_hash);
    diff.worker_catalog_hash = static_cast<int64_t>(worker.catalog_hash);
    const size_t rows = std::max(reference.countries.size(),
                                 worker.countries.size());
    // Pass 0: a row whose BUSINESS values differ. Pass 1 (only if none): a row
    // that differs merely in its accrual cursor. `points_revision` differs by
    // construction -- it is the last Economy revision each side settled -- so a
    // single mixed predicate always stopped on slot 0 and hid the row that
    // actually diverged.
    for (int pass = 0; pass < 2 && diff.slot < 0; ++pass) {
    for (size_t slot = 0; slot < rows; ++slot) {
        RuntimeIdeologyPodCountryState expected;
        RuntimeIdeologyPodCountryState actual;
        if (slot < reference.countries.size()) expected = reference.countries[slot];
        if (slot < worker.countries.size()) actual = worker.countries[slot];
        // The hash mixes `handle`, so a row present on one side and absent on the
        // other is a divergence even when every point value is zero.
        const bool business_differs =
            expected.handle != actual.handle ||
            expected.ideology_points_q16 != actual.ideology_points_q16 ||
            expected.lifetime_points_q16 != actual.lifetime_points_q16 ||
            expected.baseline_ready != actual.baseline_ready ||
            expected.baseline_population != actual.baseline_population ||
            expected.baseline_buildings != actual.baseline_buildings;
        if (pass == 0 && !business_differs) continue;
        if (pass == 1 && (!(expected.points_revision != actual.points_revision)
                          || business_differs))
            continue;
        diff.slot = static_cast<int64_t>(slot);
        diff.reference_handle = expected.handle;
        diff.worker_handle = actual.handle;
        diff.handle = actual.handle != 0 ? actual.handle : expected.handle;
        diff.reference_points_q16 = expected.ideology_points_q16;
        diff.worker_points_q16 = actual.ideology_points_q16;
        diff.reference_lifetime_q16 = expected.lifetime_points_q16;
        diff.worker_lifetime_q16 = actual.lifetime_points_q16;
        diff.reference_revision = expected.points_revision;
        diff.worker_revision = actual.points_revision;
        diff.reference_baseline_ready = expected.baseline_ready;
        diff.worker_baseline_ready = actual.baseline_ready;
        diff.reference_baseline_population = expected.baseline_population;
        diff.worker_baseline_population = actual.baseline_population;
        diff.reference_baseline_buildings = expected.baseline_buildings;
        diff.worker_baseline_buildings = actual.baseline_buildings;
        diff.reference_history_count = expected.history_count;
        diff.worker_history_count = actual.history_count;
        diff.reference_history_head = expected.history_head;
        diff.worker_history_head = actual.history_head;
        for (size_t i = 0; i < diff.reference_history_q16.size() &&
                i < expected.history_q16.size(); ++i)
            diff.reference_history_q16[i] = expected.history_q16[i];
        for (size_t i = 0; i < diff.worker_history_q16.size() &&
                i < actual.history_q16.size(); ++i)
            diff.worker_history_q16[i] = actual.history_q16[i];
        break;
    }
    }
    std::lock_guard<std::mutex> lock(_ideology_parity_mutex);
    if (!_ideology_points_diff.valid) _ideology_points_diff = diff;
}

NativeSimulationHost::IdeologyParityReport
NativeSimulationHost::ideology_parity_report() const {
    IdeologyParityReport out;
    out.compared = _ideology_parity_compared.load(std::memory_order_acquire);
    out.matched = _ideology_parity_matched.load(std::memory_order_acquire);
    out.compared_count =
        _ideology_parity_compared_count.load(std::memory_order_acquire);
    out.matched_count =
        _ideology_parity_matched_count.load(std::memory_order_acquire);
    out.reference_hash =
        _ideology_parity_reference_hash.load(std::memory_order_acquire);
    out.worker_hash =
        _ideology_parity_worker_hash.load(std::memory_order_acquire);
    out.first_mismatch_day =
        _ideology_parity_first_mismatch_day.load(std::memory_order_acquire);
    out.uncompared_day_offset = _ideology_parity_uncompared_day_offset;
    out.last_uncompared_distance = _ideology_last_uncompared_distance;
    out.status = out.compared_count == 0 ? "uncompared"
        : (out.matched ? "comparable" : "mismatch");
    // Reference-publish ledger. Outside the points-diff block on purpose: the
    // question "did the main thread ever hand over a usable reference?" must be
    // answerable on a run that never mismatched, which is the only state a
    // healthy parity run has.
    out.reference_publish_count = _ideology_reference_publish_count;
    out.reference_skipped_count = _ideology_reference_skipped_count;
    out.catalog_mismatch_count = _ideology_catalog_mismatch_count;
    out.last_reference_catalog_hash =
        static_cast<int64_t>(_ideology_last_reference_catalog_hash);
    out.last_worker_catalog_hash =
        static_cast<int64_t>(_ideology_last_worker_catalog_hash);
    out.worker_opinion_revision = static_cast<int64_t>(
        _ideology_worker_opinion_revision.load(std::memory_order_acquire));
    // R9-1: the three independent atomics are gone; the last published (day,
    // opinion) pair is read from the locked ring instead, so the day and the
    // commit printed here always belong to the same plan.
    {
        std::lock_guard<std::mutex> lock(_ideology_worker_opinion_mutex);
        const size_t filled = std::min<size_t>(_ideology_worker_opinion_count,
                                               IDEOLOGY_WORKER_OPINION_RING);
        if (filled > 0) {
            const IdeologyWorkerOpinionUse &last =
                _ideology_worker_opinion_ring[
                    (_ideology_worker_opinion_count - 1u) %
                    IDEOLOGY_WORKER_OPINION_RING];
            out.worker_opinion_period_index = last.period_index;
            out.worker_opinion_committed_day = last.committed_day;
        }
    }
    out.worker_committed_ideology_day = _ideology_pod_committed_day.load(
        std::memory_order_acquire);
    out.paired_reference_day = _ideology_last_reference_day;
    out.paired_worker_day = _ideology_last_worker_day;
    out.row_mismatch_slot = _ideology_points_row_mismatch_slot;
    out.row_mismatch_reference_handle = static_cast<int64_t>(
        _ideology_points_row_mismatch_reference_handle);
    out.row_mismatch_worker_handle = static_cast<int64_t>(
        _ideology_points_row_mismatch_worker_handle);
    out.row_mismatch_reference_points =
        _ideology_points_row_mismatch_reference_points;
    out.row_mismatch_worker_points = _ideology_points_row_mismatch_worker_points;
    load_atomic_chars48(_ideology_reference_skip_reason,
                        out.reference_skip_reason,
                        sizeof(out.reference_skip_reason));
    {
        std::lock_guard<std::mutex> lock(_ideology_parity_mutex);
        out.points_diff_valid = _ideology_points_diff.valid;
        out.points_diff_day = _ideology_points_diff.day;
        out.points_diff_slot = _ideology_points_diff.slot;
        out.points_diff_reference_countries =
            _ideology_points_diff.reference_countries;
        out.points_diff_worker_countries = _ideology_points_diff.worker_countries;
        out.points_diff_handle =
            static_cast<int64_t>(_ideology_points_diff.handle);
        out.points_diff_reference_handle =
            static_cast<int64_t>(_ideology_points_diff.reference_handle);
        out.points_diff_worker_handle =
            static_cast<int64_t>(_ideology_points_diff.worker_handle);
        out.points_diff_reference_points_q16 =
            _ideology_points_diff.reference_points_q16;
        out.points_diff_worker_points_q16 =
            _ideology_points_diff.worker_points_q16;
        out.points_diff_reference_lifetime_q16 =
            _ideology_points_diff.reference_lifetime_q16;
        out.points_diff_worker_lifetime_q16 =
            _ideology_points_diff.worker_lifetime_q16;
        out.points_diff_reference_revision =
            static_cast<int64_t>(_ideology_points_diff.reference_revision);
        out.points_diff_worker_revision =
            static_cast<int64_t>(_ideology_points_diff.worker_revision);
        out.points_diff_reference_baseline_ready =
            _ideology_points_diff.reference_baseline_ready;
        out.points_diff_worker_baseline_ready =
            _ideology_points_diff.worker_baseline_ready;
        out.points_diff_reference_baseline_population =
            _ideology_points_diff.reference_baseline_population;
        out.points_diff_worker_baseline_population =
            _ideology_points_diff.worker_baseline_population;
        out.points_diff_reference_baseline_buildings =
            _ideology_points_diff.reference_baseline_buildings;
        out.points_diff_worker_baseline_buildings =
            _ideology_points_diff.worker_baseline_buildings;
        out.points_diff_reference_history_count =
            _ideology_points_diff.reference_history_count;
        out.points_diff_worker_history_count =
            _ideology_points_diff.worker_history_count;
        out.points_diff_reference_history_head =
            _ideology_points_diff.reference_history_head;
        out.points_diff_worker_history_head =
            _ideology_points_diff.worker_history_head;
        out.points_diff_reference_history_q16 =
            _ideology_points_diff.reference_history_q16;
        out.points_diff_worker_history_q16 =
            _ideology_points_diff.worker_history_q16;
        out.points_diff_reference_last_day =
            _ideology_points_diff.reference_last_day;
        out.points_diff_worker_round_day = _ideology_points_diff.worker_round_day;
        out.points_diff_worker_committed_day =
            _ideology_points_diff.worker_committed_day;
        out.points_diff_reference_catalog_hash =
            _ideology_points_diff.reference_catalog_hash;
        out.points_diff_worker_catalog_hash =
            _ideology_points_diff.worker_catalog_hash;
        out.reference_published_day = _ideology_last_published.day;
        out.reference_published_countries =
            _ideology_last_published.countries;
        out.reference_published_with_points_revision =
            _ideology_last_published.with_points_revision;
    }
    load_atomic_chars48(_ideology_parity_field, out.field, sizeof(out.field));
    return out;
}

bool NativeSimulationHost::configure_ideology_pod(
        const RuntimeIdeologyPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "ideology_pod_configure_while_running";
        return false;
    }
    RuntimeIdeologyPodAuthority candidate;
    if (!candidate.configure(catalog, error)) return false;
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    _ideology_pod_authority = std::move(candidate);
    _ideology_pod_catalog = catalog;
    _ideology_pod_catalog.catalog_hash = _ideology_pod_authority.catalog_hash();
    _ideology_pod_configured = true;
    _ideology_reference_opinions.clear();
    _ideology_commands.clear();
    _ideology_intents.clear();
    _ideology_acks.clear();
    _ideology_modifier_inflight.clear();
    _ideology_loose_modifier_rows.clear();
    _ideology_day_modifier_batches.clear();
    return true;
}

void NativeSimulationHost::record_ideology_worker_opinion_use(
        int64_t plan_day, const RuntimeIdeologyOpinionSnapshot &opinion,
        std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> owner,
        uint64_t ideology_generation) {
    // Publish the day and the opinion as ONE record (R9-1). Three separate
    // atomics let a reader pair day N with the opinion of day N-1, which is the
    // intermittency this replaces: the reader then binds the main thread to an
    // input the worker never used.
    IdeologyWorkerOpinionUse use;
    use.plan_day = plan_day;
    use.committed_day = opinion.committed_day;
    use.period_index = opinion.period_index;
    use.revision = opinion.revision;
    use.ideology_generation = ideology_generation;
    use.opinion = std::move(owner);
    std::lock_guard<std::mutex> lock(_ideology_worker_opinion_mutex);
    _ideology_worker_opinion_ring[
        _ideology_worker_opinion_count % IDEOLOGY_WORKER_OPINION_RING] =
        std::move(use);
    ++_ideology_worker_opinion_count;
}

std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::worker_opinion_snapshot_for_ideology_generation(
        uint64_t generation) const {
    if (generation == 0) return nullptr;
    std::lock_guard<std::mutex> lock(_ideology_worker_opinion_mutex);
    const size_t filled = std::min<size_t>(_ideology_worker_opinion_count,
                                           IDEOLOGY_WORKER_OPINION_RING);
    for (size_t i = 0; i < filled; ++i) {
        const size_t slot = (_ideology_worker_opinion_count - 1u - i) %
                            IDEOLOGY_WORKER_OPINION_RING;
        const IdeologyWorkerOpinionUse &use = _ideology_worker_opinion_ring[slot];
        if (use.ideology_generation != generation || use.opinion == nullptr)
            continue;
        return use.opinion;
    }
    return nullptr;
}

std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::worker_opinion_snapshot_for_day(int64_t day) const {
    // The opinion the worker consumed when it planned THIS day (R9-1).
    //
    // A single record lookup under the mutex, so the day and the opinion can
    // never come from different plans. Returning null means "the worker never
    // planned this day", and the caller must then not publish a reference for it
    // rather than re-deriving an opinion: a re-derived input is exactly what made
    // the two sides diverge depending on thread scheduling.
    //
    // NOTE (05 §2.7): this reader is correct and unit-verifiable, but nothing calls
    // it yet. The join between the worker's plan day and the day the main thread is
    // asked to run is not the same coordinate, so wiring it is still open.
    std::lock_guard<std::mutex> lock(_ideology_worker_opinion_mutex);
    const size_t filled = std::min<size_t>(_ideology_worker_opinion_count,
                                           IDEOLOGY_WORKER_OPINION_RING);
    for (size_t i = 0; i < filled; ++i) {
        const size_t slot = (_ideology_worker_opinion_count - 1u - i) %
                            IDEOLOGY_WORKER_OPINION_RING;
        const IdeologyWorkerOpinionUse &use = _ideology_worker_opinion_ring[slot];
        if (use.plan_day != day || use.opinion == nullptr) continue;
        return use.opinion;
    }
    return nullptr;
}

std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::pin_ideology_reference_opinion(int64_t day,
        const RuntimeIdeologyOpinionSnapshot &snapshot) {
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    const auto found = _ideology_reference_opinions.find(day);
    if (found != _ideology_reference_opinions.end()) return found->second;
    auto copy = std::make_shared<const RuntimeIdeologyOpinionSnapshot>(snapshot);
    _ideology_reference_opinions.emplace(day, copy);
    // Retain only inputs either side can still need. This is consumer-driven
    // retirement, without a time/count cap or a "latest" fallback.
    const int64_t worker_day = _committed_day.load(
        std::memory_order_acquire);
    const int64_t through = std::min(day, worker_day);
    while (!_ideology_reference_opinions.empty() &&
        _ideology_reference_opinions.begin()->first < through)
        _ideology_reference_opinions.erase(_ideology_reference_opinions.begin());
    return copy;
}

bool NativeSimulationHost::publish_ideology_opinion_snapshot(
        const RuntimeIdeologyOpinionSnapshot &snapshot, std::string &error) {
    if (snapshot.revision == 0 || snapshot.class_hash == 0 ||
        snapshot.country_count == 0 || snapshot.class_count == 0) {
        error = "ideology_opinion_snapshot_invalid";
        return false;
    }
    const size_t lanes = static_cast<size_t>(snapshot.country_count) *
        snapshot.class_count;
    if (snapshot.country_handles.size() != snapshot.country_count ||
        snapshot.country_generations.size() != snapshot.country_count ||
        snapshot.population.size() != lanes || snapshot.funds.size() != lanes ||
        snapshot.owner_employed.size() != lanes ||
        snapshot.satisfaction_weighted.size() != lanes ||
        snapshot.satisfaction_q16.size() != lanes) {
        error = "ideology_opinion_snapshot_shape_invalid";
        return false;
    }
    auto copy = std::make_shared<RuntimeIdeologyOpinionSnapshot>(snapshot);
    // The ordinary worker path reads the latest committed input. SHADOW parity
    // separately pins the input at the reference's actual daily entry; it never
    // infers the simulation day from Economy's committed_day or period index.
    std::atomic_store_explicit(&_ideology_opinion_snapshot,
        std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>(std::move(copy)),
        std::memory_order_release);
    return true;
}

bool NativeSimulationHost::queue_ideology_pod_command(
        const RuntimeIdeologyPodCommand &command, std::string &error) {
    return queue_ideology_pod_commands({command}, error);
}

bool NativeSimulationHost::queue_ideology_pod_commands(
        const std::vector<RuntimeIdeologyPodCommand> &commands,
        std::string &error) {
    if (!_ideology_pod_configured) { error = "ideology_pod_not_configured"; return false; }
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    // The Effect adapter stages this vector as one semantic batch. Validate
    // every row before publishing any of them, otherwise a reject on row N
    // leaves rows 0..N-1 in the transport and the caller reports failure while
    // the worker still applies a partial grant.
    for (const RuntimeIdeologyPodCommand &command : commands) {
        const int32_t opcode = static_cast<int32_t>(command.opcode);
        if (command.request_id == 0 || command.producer_id == 0 ||
                command.country_handle == 0 ||
                command.requested_day < 0 || command.effective_day < 0 ||
                command.effective_day < command.requested_day ||
                opcode < static_cast<int32_t>(
                    RuntimeIdeologyPodOpcode::DISCOVER) ||
                opcode > static_cast<int32_t>(
                    RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW)) {
            error = "ideology_command_invalid";
            return false;
        }
        if (command.opcode == RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW &&
                (command.value_q16 <= 0 || command.value_q16 > 65535 ||
                 command.ideology_id != -1)) {
            error = "ideology_free_draw_invalid";
            return false;
        }
    }
    if (commands.size() > RUNTIME_COMMAND_QUEUE_CAPACITY -
            _ideology_commands.size()) {
        error = "ideology_command_capacity_exceeded";
        return false;
    }
    _ideology_commands.insert(_ideology_commands.end(),
                              commands.begin(), commands.end());
    return true;
}

bool NativeSimulationHost::poll_ideology_pod_intent(RuntimeDomainIntent &intent) {
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    if (_ideology_intents.empty()) return false;
    intent = _ideology_intents.front();
    _ideology_intents.pop_front();
    return true;
}

bool NativeSimulationHost::submit_ideology_pod_ack(
        const RuntimeDomainAck &ack, std::string &error) {
    if (ack.domain != static_cast<uint16_t>(RuntimeDomainId::EFFECT) ||
        (ack.transaction_id == 0 && ack.request_id == 0)) {
        error = "ideology_ack_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    if (_ideology_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "ideology_ack_capacity_exceeded";
        return false;
    }
    _ideology_acks.push_back(ack);
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
    return true;
}

std::shared_ptr<const RuntimeIdeologyPodSnapshot>
NativeSimulationHost::ideology_pod_snapshot() const {
    return std::atomic_load_explicit(&_ideology_snapshot,
                                     std::memory_order_acquire);
}

bool NativeSimulationHost::encode_ideology_pod_save(
        std::vector<uint8_t> &bytes, std::string &error) const {
    if (!_ideology_pod_configured) { error = "ideology_pod_not_configured"; return false; }
    _ideology_pod_authority.serialize(bytes);
    if (bytes.empty()) { error = "ideology_pod_save_encode_failed"; return false; }
    return true;
}

bool NativeSimulationHost::restore_ideology_pod_save(
        const uint8_t *bytes, size_t size, std::string &error) {
    if (!_ideology_pod_configured) { error = "ideology_pod_not_configured"; return false; }
    RuntimeIdeologyPodAuthority candidate;
    if (!candidate.configure(_ideology_pod_catalog, error) ||
        !candidate.restore(bytes, size, error)) return false;
    _ideology_pod_authority = std::move(candidate);
    _ideology_modifier_inflight.clear();
    _ideology_loose_modifier_rows.clear();
    _ideology_day_modifier_batches.clear();
    _ideology_pod_authority.rearm_pending_transitions();
    return true;
}

bool NativeSimulationHost::ideology_pod_self_test(std::string *out_error) const {
    std::string error;
    if (!RuntimeIdeologyPodAuthority::self_test(error)) {
        if (out_error != nullptr) *out_error = error;
        return false;
    }
    if (!runtime_published_view_self_test() || !RuntimeIdeologySnapshotRing::self_test()) {
        if (out_error != nullptr)
            *out_error = "ideology_pod_snapshot_ring_self_test_failed";
        return false;
    }
    return true;
}

bool NativeSimulationHost::execute_ideology_worker_stage(
        int64_t day, RuntimeDayCommit &commit, std::string &error) {
    (void)commit;
    error.clear();
    if (!_ideology_pod_configured) {
        error = "ideology_pod_not_configured";
        return false;
    }
    const auto country = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    const auto opinion_view = copy_economy_opinion_view(day);
    assert(!opinion_view.data || opinion_view.observe(_opinion_view_version));
    auto opinion = opinion_view.data;
    if (country == nullptr || opinion == nullptr) {
        error = country == nullptr ? "ideology_country_snapshot_missing" :
            "ideology_opinion_snapshot_missing";
        return false;
    }
    // Freeze the country.ideology.* multipliers from the last committed Modifier
    // snapshot (Modifier runs after Ideology, so this is the previous day's
    // value). Only the opinion copy changes; the published input stays.
    //
    // One loop per stat rather than one pass bucketing all three: buckets are
    // sorted by (domain, scope, stat), so a single pass could collect all three
    // in one sweep, but the sweep runs once per day per country and the three
    // passes keep the "which array does this bucket belong to" question inside
    // the lambda instead of in a switch nobody tests.
    if (_modifier_pod_configured &&
        opinion->country_population.size() == opinion->country_count &&
        (_ideology_pod_catalog.point_gain_stat_id >= 0 ||
         _ideology_pod_catalog.understanding_gain_stat_id >= 0 ||
         _ideology_pod_catalog.reroll_cost_stat_id >= 0 ||
         _ideology_pod_catalog.era_decay_floor_stat_id >= 0 ||
         _ideology_pod_catalog.offer_choice_bonus_stat_id >= 0 ||
         _ideology_pod_catalog.point_population_factor_stat_id >= 0 ||
         _ideology_pod_catalog.point_building_factor_stat_id >= 0 ||
         _ideology_pod_catalog.point_trade_factor_stat_id >= 0 ||
         _ideology_pod_catalog.opinion_factor_floor_stat_id >= 0 ||
         !_ideology_pod_catalog.school_strength_factor_stat_ids.empty())) {
        auto with_factors = std::make_shared<RuntimeIdeologyOpinionSnapshot>(*opinion);
        const RuntimeModifierCommittedView modifier_view =
            _modifier_pod_authority.copy_committed_view();
        assert(_modifier_pod_authority.observe_committed_view(modifier_view));
        const auto &buckets = modifier_view.buckets;
        auto freeze = [&](int32_t stat_id, std::vector<int32_t> &out,
                          double minimum = 0.0, double maximum = 4.0) {
            if (stat_id < 0) return;
            out.assign(opinion->country_count, 65536);
            for (const RuntimeModifierPodBucket &bucket : buckets) {
                if (bucket.domain != 1 || bucket.scope != 2 ||
                    bucket.stat_id != static_cast<uint32_t>(stat_id)) continue;
                const uint32_t slot =
                    static_cast<uint32_t>(bucket.scope_id & 0xffffffffull);
                if (slot >= opinion->country_count ||
                    opinion->country_handles[slot] != bucket.scope_id) continue;
                double value = (1.0 + bucket.sum_add) * bucket.product_factor;
                if (!std::isfinite(value)) value = 1.0;
                value = std::clamp(value, minimum, maximum);
                out[slot] = static_cast<int32_t>(std::lround(value * 65536.0));
            }
        };
        freeze(_ideology_pod_catalog.point_gain_stat_id,
               with_factors->point_gain_factor_q16);
        freeze(_ideology_pod_catalog.understanding_gain_stat_id,
               with_factors->understanding_gain_q16);
        freeze(_ideology_pod_catalog.reroll_cost_stat_id,
               with_factors->reroll_cost_q16);
        freeze(_ideology_pod_catalog.point_population_factor_stat_id,
               with_factors->point_population_factor_q16, 0.5, 3.0);
        freeze(_ideology_pod_catalog.point_building_factor_stat_id,
               with_factors->point_building_factor_q16, 0.5, 3.0);
        freeze(_ideology_pod_catalog.point_trade_factor_stat_id,
               with_factors->point_trade_factor_q16, 0.5, 3.0);
        // The opinion floor is ADDitive from a 0.5 base and clamped to
        // [0.3, 0.5]. A negative row therefore lowers the floor without ever
        // producing a negative multiplier.
        auto freeze_opinion_floor = [&]() {
            if (_ideology_pod_catalog.opinion_factor_floor_stat_id < 0) return;
            with_factors->opinion_factor_floor_q16.assign(
                opinion->country_count, 32768);
            for (const RuntimeModifierPodBucket &bucket : buckets) {
                if (bucket.domain != 1 || bucket.scope != 2 ||
                    bucket.stat_id != static_cast<uint32_t>(
                        _ideology_pod_catalog.opinion_factor_floor_stat_id))
                    continue;
                const uint32_t slot =
                    static_cast<uint32_t>(bucket.scope_id & 0xffffffffull);
                if (slot >= opinion->country_count ||
                    opinion->country_handles[slot] != bucket.scope_id)
                    continue;
                double value = (0.5 + bucket.sum_add) * bucket.product_factor;
                if (!std::isfinite(value)) value = 0.5;
                with_factors->opinion_factor_floor_q16[slot] =
                    static_cast<int32_t>(std::lround(
                        std::clamp(value, 0.3, 0.5) * 65536.0));
            }
        };
        freeze_opinion_floor();
        const int32_t school_count = static_cast<int32_t>(
            _ideology_pod_catalog.school_keys.size());
        if (school_count > 0 &&
            _ideology_pod_catalog.school_strength_factor_stat_ids.size() ==
                static_cast<size_t>(school_count)) {
            with_factors->school_strength_factor_q16.assign(
                static_cast<size_t>(opinion->country_count) *
                    static_cast<size_t>(school_count), 65536);
            for (int32_t school = 0; school < school_count; ++school) {
                const int32_t stat_id =
                    _ideology_pod_catalog.school_strength_factor_stat_ids[
                        static_cast<size_t>(school)];
                if (stat_id < 0) continue;
                for (const RuntimeModifierPodBucket &bucket : buckets) {
                    if (bucket.domain != 1 || bucket.scope != 2 ||
                        bucket.stat_id != static_cast<uint32_t>(stat_id)) {
                        continue;
                    }
                    const uint32_t country_slot =
                        static_cast<uint32_t>(
                            bucket.scope_id & 0xffffffffull);
                    if (country_slot >= opinion->country_count ||
                        opinion->country_handles[country_slot] !=
                            bucket.scope_id) {
                        continue;
                    }
                    double value =
                        (1.0 + bucket.sum_add) * bucket.product_factor;
                    if (!std::isfinite(value)) value = 1.0;
                    const size_t lane =
                        static_cast<size_t>(country_slot) *
                            static_cast<size_t>(school_count) +
                        static_cast<size_t>(school);
                    with_factors->school_strength_factor_q16[lane] =
                        static_cast<int32_t>(std::lround(
                            std::clamp(value, 0.5, 2.0) * 65536.0));
                }
            }
        }
        // The two draw-side values are ADDITIVE, not multipliers: an empty array
        // has to read as 0 (no floor, no extra rows), while `freeze` seeds 65536
        // because 1.0 is the identity for a factor. Sharing `freeze` here would
        // silently give every country a 65536 bp floor and 65536 extra rows.
        auto freeze_additive = [&](int32_t stat_id, std::vector<int32_t> &out,
                                   int32_t ceiling) {
            if (stat_id < 0) return;
            out.assign(opinion->country_count, 0);
            for (const RuntimeModifierPodBucket &bucket : buckets) {
                if (bucket.domain != 1 || bucket.scope != 2 ||
                    bucket.stat_id != static_cast<uint32_t>(stat_id)) continue;
                const uint32_t slot =
                    static_cast<uint32_t>(bucket.scope_id & 0xffffffffull);
                if (slot >= opinion->country_count ||
                    opinion->country_handles[slot] != bucket.scope_id) continue;
                double value = bucket.sum_add;
                if (!std::isfinite(value)) value = 0.0;
                out[slot] = static_cast<int32_t>(std::lround(
                    std::clamp(value, 0.0, static_cast<double>(ceiling))));
            }
        };
        freeze_additive(_ideology_pod_catalog.era_decay_floor_stat_id,
                        with_factors->era_decay_floor_bp, 10000);
        freeze_additive(_ideology_pod_catalog.offer_choice_bonus_stat_id,
                        with_factors->offer_choice_bonus,
                        IDEOLOGY_OFFER_CHOICE_CAPACITY - IDEOLOGY_OFFER_CHOICE_BASE);
        opinion = std::move(with_factors);
    }
    // R9-1: publish the exact opinion THIS worker day settles from, now that every
    // transformation (including the frozen Modifier factors above) has happened.
    //
    // Recording earlier would hand parity a snapshot that still lacked the frozen
    // `point_gain_factor_q16`, so the two sides would settle from inputs that
    // differ in a field the accounting reads. The shared_ptr is kept alive by the
    // ring, so the main thread can consume it after this stage returns.
    if (_ideology_pod_authority.snapshot().countries.empty()) {
        if (!_ideology_pod_authority.bootstrap(*country, *opinion, error))
            return false;
    }
    if (domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY))
        queue_annual_worker_reward(day);
    std::deque<RuntimeIdeologyPodCommand> commands;
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        commands.swap(_ideology_commands);
        acks.assign(_ideology_acks.begin(), _ideology_acks.end());
        _ideology_acks.clear();
    }
    while (!commands.empty()) {
        const RuntimeIdeologyPodCommand command = commands.front();
        commands.pop_front();
        if (!_ideology_pod_authority.queue_command(command, error)) {
            std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
            _ideology_commands.push_front(command);
            while (!commands.empty()) {
                _ideology_commands.push_front(commands.back());
                commands.pop_back();
            }
            return false;
        }
    }

    const auto plan_started = std::chrono::steady_clock::now();
    double replay_ms = 0.0;
    uint32_t emitted = 0;
    RuntimeIdeologyPodPlan plan;
    bool first_slice = true;
    for (uint32_t slice = 0; slice < RUNTIME_IDEOLOGY_POD_MAX_COMMANDS; ++slice) {
        static const std::vector<RuntimeDomainAck> empty_acks;
        const auto &effective_acks = first_slice ? acks : empty_acks;
        first_slice = false;
        if (!_ideology_pod_authority.plan_day(
                day, *country, *opinion, effective_acks, plan, error)) {
            _ideology_pod_authority.discard_plan();
            return false;
        }
        if (ideology_modifier_bridge_active()) {
            // Worker owns MODIFIER: keep the transition in-worker until the
            // Modifier POD has really applied its rows.
            for (const RuntimeDomainIntent &intent : plan.intents) {
                IdeologyModifierInflight inflight;
                inflight.intent = intent;
                for (const auto &row : plan.modifier_rows)
                    if (row.transition_id == intent.source_id)
                        inflight.rows.push_back(row);
                auto existing = std::find_if(
                    _ideology_modifier_inflight.begin(),
                    _ideology_modifier_inflight.end(),
                    [&](const IdeologyModifierInflight &item) {
                        return item.intent.source_id == intent.source_id;
                    });
                if (existing != _ideology_modifier_inflight.end())
                    *existing = std::move(inflight);
                else
                    _ideology_modifier_inflight.push_back(std::move(inflight));
                ++emitted;
            }
            for (const auto &row : plan.modifier_rows)
                if (row.transition_id == 0)
                    _ideology_loose_modifier_rows.push_back(row);
        } else {
            std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
            for (const RuntimeDomainIntent &intent : plan.intents) {
                if (_ideology_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                    _ideology_pod_authority.discard_plan();
                    error = "ideology_intent_capacity_exceeded";
                    return false;
                }
                _ideology_intents.push_back(intent);
                ++emitted;
            }
        }
        const auto replay_started = std::chrono::steady_clock::now();
        if (!_ideology_pod_authority.commit_day(plan, error)) return false;
        replay_ms += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - replay_started).count();
        if (plan.completed_day != 0) break;
        if (slice + 1u == RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) {
            error = "ideology_same_day_continuation_limit_exceeded";
            return false;
        }
    }
    const RuntimeIdeologyPodSnapshot &snapshot =
        _ideology_pod_authority.snapshot();
    record_ideology_worker_opinion_use(
        day, *opinion, opinion, snapshot.generation);
    if (domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY))
        settle_annual_worker_reward(snapshot);
    auto copy = std::make_shared<RuntimeIdeologyPodSnapshot>(snapshot);
    std::atomic_store_explicit(&_ideology_snapshot,
        std::shared_ptr<const RuntimeIdeologyPodSnapshot>(std::move(copy)),
        std::memory_order_release);
    // G8: publish the immutable snapshot for main-thread NativeIdeologyRuntime
    // write-back. The shared_ptr above stays for SHADOW diagnostics readers.
    uint32_t ideology_slot = 0;
    if (_ideology_snapshots.try_begin_write(ideology_slot)) {
        _ideology_snapshots.write_buffer(ideology_slot) = snapshot;
        _ideology_snapshots.publish(ideology_slot);
    }
    _ideology_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _ideology_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _ideology_pod_state_hash.store(snapshot.state_hash, std::memory_order_release);
    record_ideology_parity_locked(snapshot);
    _ideology_pod_snapshot_generation.store(snapshot.generation,
                                            std::memory_order_release);
    // The day the worker last committed Ideology for. Callers need this to tell
    // "the worker never advanced" apart from "it is simply behind"; the previous
    // report had no such field and a probe read a misspelled one, so every run
    // printed a stale `worker_day=1`.
    _ideology_pod_committed_day.store(snapshot.committed_day,
                                      std::memory_order_release);
    _ideology_pod_pending_transition_count.store(
        static_cast<uint32_t>(snapshot.pending_transitions.size()),
        std::memory_order_release);
    _ideology_pod_intent_count.store(emitted, std::memory_order_release);
    return true;
}

bool NativeSimulationHost::ideology_modifier_bridge_active() const {
    const uint32_t requested =
        _requested_authority_mask.load(std::memory_order_acquire);
    return _mode.load(std::memory_order_acquire) ==
               RuntimeSimulationMode::ACTIVE &&
        _modifier_pod_configured &&
        (requested & runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u &&
        (requested & runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u;
}

void NativeSimulationHost::stage_ideology_modifier_commands(
        int64_t day, uint64_t input_generation) {
    _ideology_day_modifier_batches.clear();
    if (_ideology_modifier_inflight.empty() &&
        _ideology_loose_modifier_rows.empty()) return;
    auto resolve = [this](const RuntimeIdeologyPodModifierRow &row) {
        const auto found = _modifier_definition_id_by_key_hash.find(
            row.definition_key_hash);
        return found == _modifier_definition_id_by_key_hash.end()
            ? -1 : found->second;
    };
    auto make_command = [&](const RuntimeIdeologyPodModifierRow &row,
                            int32_t definition_id) {
        RuntimeModifierPodCommand command;
        uint64_t hash = 1469598103934665603ull;
        for (uint64_t value : {row.transition_id, row.source_id,
                               row.definition_key_hash,
                               static_cast<uint64_t>(row.ordinal),
                               static_cast<uint64_t>(row.opcode),
                               _ideology_modifier_sequence}) {
            hash ^= value; hash *= 1099511628211ull;
        }
        command.request_id = hash == 0 ? 1 : hash;
        command.producer_id = 0x49444530u; // IDE0
        command.sequence = _ideology_modifier_sequence++;
        command.requested_day = day;
        command.effective_day = day;
        command.opcode = row.opcode;
        command.domain = row.domain;
        command.definition_id = definition_id;
        command.scope = 2; // ENTITY: the country handle
        command.entity_handle = row.country_handle;
        command.target_generation = row.country_generation;
        command.source_type = RUNTIME_IDEOLOGY_MODIFIER_SOURCE_TYPE;
        command.source_id = row.source_id;
        command.duration_days = -1;
        command.stacks = 1;
        command.magnitude_q16 = row.magnitude_q16;
        command.input_generation = input_generation;
        return command;
    };
    for (auto &inflight : _ideology_modifier_inflight) {
        if (inflight.submitted != 0) continue;
        // Preflight the whole batch: one unresolved row means zero submission.
        bool resolved = true;
        for (const auto &row : inflight.rows)
            if (resolve(row) < 0) { resolved = false; break; }
        inflight.batch_index = -1;
        if (!resolved) {
            // Settled as REJECTED after this day's Modifier stage.
            inflight.submitted = 2;
            continue;
        }
        std::vector<RuntimeModifierPodCommand> batch;
        batch.reserve(inflight.rows.size());
        for (const auto &row : inflight.rows) {
            batch.push_back(make_command(row, resolve(row)));
        }
        inflight.batch_index =
            static_cast<int32_t>(_ideology_day_modifier_batches.size());
        _ideology_day_modifier_batches.push_back(std::move(batch));
        inflight.submitted = 1;
    }
    // Loose synergy rows: each synergy add/remove pair is its own batch.
    for (const auto &row : _ideology_loose_modifier_rows) {
        const int32_t definition_id = resolve(row);
        if (definition_id >= 0)
            _ideology_day_modifier_batches.push_back({make_command(row, definition_id)});
    }
}

void NativeSimulationHost::settle_ideology_modifier_acks(
        const std::vector<uint8_t> &batch_ok, bool committed) {
    // Loose synergy rows stay queued until a Modifier day commits them.
    if (committed) _ideology_loose_modifier_rows.clear();
    std::vector<RuntimeDomainAck> settled;
    for (auto it = _ideology_modifier_inflight.begin();
         it != _ideology_modifier_inflight.end();) {
        auto &inflight = *it;
        if (inflight.submitted == 0) { ++it; continue; }
        RuntimeDomainAckCode code = RuntimeDomainAckCode::OK;
        bool done = false;
        if (inflight.submitted == 2) {
            code = RuntimeDomainAckCode::REJECTED;
            done = true;
        } else if (!committed) {
            // Modifier day failed atomically: resubmit the batch next day.
            inflight.submitted = 0;
            ++it;
            continue;
        } else {
            done = true;
            if (inflight.batch_index < 0 ||
                static_cast<size_t>(inflight.batch_index) >= batch_ok.size() ||
                batch_ok[static_cast<size_t>(inflight.batch_index)] == 0u)
                code = RuntimeDomainAckCode::REJECTED;
        }
        if (!done) { ++it; continue; }
        RuntimeDomainAck ack;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        ack.code = code;
        ack.request_id = inflight.intent.request_id != 0
            ? inflight.intent.request_id : inflight.intent.source_id;
        ack.transaction_id = inflight.intent.source_id;
        ack.target_handle = inflight.intent.target_handle;
        ack.target_generation = inflight.intent.target_generation;
        ack.effective_day = inflight.intent.effective_day;
        ack.producer_id = inflight.intent.producer_id;
        ack.sequence = inflight.intent.sequence;
        settled.push_back(ack);
        it = _ideology_modifier_inflight.erase(it);
    }
    if (settled.empty()) return;
    {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        for (const auto &ack : settled) _ideology_acks.push_back(ack);
    }
    // Internal Modifier completion uses the same ACK queue as the split-
    // authority transport. Wake the day barrier so the next Ideology poll
    // cannot remain asleep with transition_pending latched forever.
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
}
} // namespace pk
