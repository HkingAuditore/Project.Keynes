// Included inside NativeSimulationHost. Public parity report for Ideology.
    struct IdeologyParityReport {
        bool compared = false;
        bool matched = false;
        int64_t compared_count = 0;
        int64_t matched_count = 0;
        uint64_t reference_hash = 0;
        uint64_t worker_hash = 0;
        int64_t first_mismatch_day = -1;
        // R8-4: worker days dropped because no reference exists on the same
        // calendar day. Reported so the gate can tell "the calendars do not
        // line up" apart from "the two sides agree".
        int64_t uncompared_day_offset = 0;
        int64_t last_uncompared_distance = -1;
        char field[48]{};
        const char *status = "none";
        // Raw numbers behind a `points*` field, so a failure is readable without
        // re-running under a debugger. Zeroed until a points mismatch happens.
        bool points_diff_valid = false;
        int64_t points_diff_day = -1;
        int64_t points_diff_slot = -1;
        int64_t points_diff_reference_countries = 0;
        int64_t points_diff_worker_countries = 0;
        int64_t points_diff_handle = 0;
        int64_t points_diff_reference_handle = 0;
        int64_t points_diff_worker_handle = 0;
        int64_t points_diff_reference_points_q16 = 0;
        int64_t points_diff_worker_points_q16 = 0;
        int64_t points_diff_reference_lifetime_q16 = 0;
        int64_t points_diff_worker_lifetime_q16 = 0;
        int64_t points_diff_reference_revision = 0;
        int64_t points_diff_worker_revision = 0;
        int32_t points_diff_reference_baseline_ready = 0;
        int32_t points_diff_worker_baseline_ready = 0;
        int64_t points_diff_reference_baseline_population = 0;
        int64_t points_diff_worker_baseline_population = 0;
        int64_t points_diff_reference_baseline_buildings = 0;
        int64_t points_diff_worker_baseline_buildings = 0;
        int32_t points_diff_reference_history_count = 0;
        int32_t points_diff_worker_history_count = 0;
        int32_t points_diff_reference_history_head = 0;
        int32_t points_diff_worker_history_head = 0;
        std::array<int64_t, 8> points_diff_reference_history_q16{};
        std::array<int64_t, 8> points_diff_worker_history_q16{};
        int64_t points_diff_reference_last_day = -1;
        int64_t points_diff_worker_round_day = -1;
        int64_t points_diff_worker_committed_day = -1;
        int64_t points_diff_reference_catalog_hash = 0;
        int64_t points_diff_worker_catalog_hash = 0;
        int64_t reference_publish_count = 0;
        int64_t reference_published_day = -1;
        int64_t reference_published_countries = 0;
        int32_t reference_published_with_points_revision = 0;
        int64_t reference_skipped_count = 0;
        char reference_skip_reason[48]{};
        // Catalog agreement is a PRECONDITION for comparison, not a business
        // field: the two sides compute `catalog_hash` with different functions,
        // so equality is never expected and a mismatch must never be counted as
        // a business divergence. Reported for diagnosis only.
        int64_t catalog_mismatch_count = 0;
        int64_t last_reference_catalog_hash = 0;
        int64_t last_worker_catalog_hash = 0;
        // The Economy opinion revision the worker last accrued from. Compared
        // against the reference's own `points_revision` in `points_diff`: equal
        // means both sides saw the same input, so a remaining divergence is a
        // real business one rather than a driver alignment artefact.
        int64_t worker_opinion_revision = 0;
        // A1: what the worker actually consumed. A driver binds the main thread
        // to these so both sides settle the SAME opinion for the same day.
        int64_t worker_opinion_period_index = -1;
        int64_t worker_opinion_committed_day = -1;
        // Day the worker last committed Ideology for. -1 means it never ran.
        int64_t worker_committed_ideology_day = -1;
        // The (reference day, worker day) pair the comparison actually used.
        int64_t paired_reference_day = -1;
        int64_t paired_worker_day = -1;
        // First row whose points differ (recomputed row by row).
        int64_t row_mismatch_slot = -1;
        int64_t row_mismatch_reference_handle = 0;
        int64_t row_mismatch_worker_handle = 0;
        int64_t row_mismatch_reference_points = 0;
        int64_t row_mismatch_worker_points = 0;
    };
    IdeologyParityReport ideology_parity_report() const;
