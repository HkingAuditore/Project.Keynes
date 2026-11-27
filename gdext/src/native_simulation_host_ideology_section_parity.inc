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
            out.worker_opinion_revision = static_cast<int64_t>(last.revision);
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
