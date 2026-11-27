// Country peer transport and Country and Ideology parity state.

    // Country peer transport is a bounded cooperative bridge. The worker owns
    // the POD authority and plan; the main thread only moves typed values in
    // and out of these queues and never touches the authority itself.
    mutable std::mutex _country_transport_mutex;
    RuntimeCountryPodAuthority _country_pod_authority;
    RuntimeCountryPodCatalog _country_pod_catalog;
    std::atomic<bool> _country_pod_configured{false};
    std::atomic<bool> _country_pod_plan_active{false};
    std::atomic<CountryAiRuntime *> _country_ai_runtime{nullptr};
    RuntimeCountryPodSnapshot _country_ai_snapshot;
    CountryAiRuntime *country_ai_for_worker() const noexcept;
    void commit_country_ai_day(int64_t day);
    // One preview publish per open peer-wait so research enqueue appears in the
    // left queue without soft-committing the Country calendar boundary.
    bool _country_peer_wait_preview_published = false;
    std::map<int64_t, RuntimeCountryPodSnapshot> _country_references;
    // day -> reference snapshot. The country pair keeps whole snapshots for the
    // same reason: a hash says "different", only the snapshot says "which row,
    // which field". Bounded to 128 days exactly like the country map.
    // Published references in publish order. The worker consumes them FIFO: the
    // main thread keys by driver tick and the worker by its own calendar, so a
    // raw day lookup never matched (observed ref_day=5 vs worker_day=2).
    std::deque<RuntimeIdeologyPodSnapshot> _ideology_reference_fifo;
    // Day pairing actually used for the last comparison. Diagnostic only: it makes
    // a calendar-offset bug visible instead of looking like a business divergence.
    int64_t _ideology_last_reference_day = -1;
    int64_t _ideology_last_worker_day = -1;
    // First country row whose points differ, recomputed row by row. A section
    // hash is a running mix, so this is the only way to name the row.
    int64_t _ideology_points_row_mismatch_slot = -1;
    uint64_t _ideology_points_row_mismatch_reference_handle = 0;
    uint64_t _ideology_points_row_mismatch_worker_handle = 0;
    int64_t _ideology_points_row_mismatch_reference_points = 0;
    int64_t _ideology_points_row_mismatch_worker_points = 0;
    // Publish ledger: which days the main thread actually handed a reference for,
    // and how many country rows it carried. A reference with zero rows is not a
    // reference -- it makes every later comparison fail for a reason that has
    // nothing to do with the worker.
    struct IdeologyReferenceRecord {
        int64_t day = -1;
        int64_t countries = 0;
        int32_t with_points_revision = 0;
        uint64_t catalog_hash = 0;
    };
    IdeologyReferenceRecord _ideology_last_published;
    int64_t _ideology_reference_publish_count = 0;
    // References refused because the main thread had not produced a single
    // country row yet. Publishing one of those is worse than publishing
    // nothing: the worker always has rows, so every later comparison fails and
    // the reported `field` blames whichever section happens to differ first.
    int64_t _ideology_reference_skipped_count = 0;
    std::array<std::atomic<char>, 48> _ideology_reference_skip_reason{};
    // Catalog-hash disagreement is recorded, never counted as a comparison.
    int64_t _ideology_catalog_mismatch_count = 0;
    uint64_t _ideology_last_reference_catalog_hash = 0;
    uint64_t _ideology_last_worker_catalog_hash = 0;
    // R9-1: which opinion the worker consumed for which day, as ONE record.
    //
    // Three independent atomics cannot express this: a reader can see plan_day
    // from day 5 next to the opinion of day 4, and then bind the main thread to an
    // input the worker never used on that day -- the same class of defect as
    // comparing two calendars, only intermittent. The day and the opinion are
    // published together under this mutex as a small ring, and readers copy a
    // consistent (day, opinion) pair.
    struct IdeologyWorkerOpinionUse {
        int64_t plan_day = -1;
        int64_t committed_day = -1;
        int64_t period_index = -1;
        uint64_t revision = 0;
        uint64_t ideology_generation = 0;
        std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> opinion;
    };
    static constexpr size_t IDEOLOGY_WORKER_OPINION_RING = 16;
    mutable std::mutex _ideology_worker_opinion_mutex;
    std::array<IdeologyWorkerOpinionUse, IDEOLOGY_WORKER_OPINION_RING>
        _ideology_worker_opinion_ring{};
    size_t _ideology_worker_opinion_count = 0;
    void record_ideology_worker_opinion_use(
        int64_t plan_day,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> owner,
        uint64_t ideology_generation);
    std::atomic<int64_t> _ideology_pod_committed_day{-1};
    // First diverging country row, kept once per run (not per day) so a failing
    // parity can be read as numbers instead of "somewhere in `points`".
    struct IdeologyPointsDiff {
        bool valid = false;
        int64_t day = -1;
        int64_t slot = -1;
        int64_t reference_countries = 0;
        int64_t worker_countries = 0;
        uint64_t handle = 0;
        uint64_t reference_handle = 0;
        uint64_t worker_handle = 0;
        int64_t reference_points_q16 = 0;
        int64_t worker_points_q16 = 0;
        int64_t reference_lifetime_q16 = 0;
        int64_t worker_lifetime_q16 = 0;
        uint64_t reference_revision = 0;
        uint64_t worker_revision = 0;
        int32_t reference_baseline_ready = 0;
        int32_t worker_baseline_ready = 0;
        int64_t reference_baseline_population = 0;
        int64_t worker_baseline_population = 0;
        int64_t reference_baseline_buildings = 0;
        int64_t worker_baseline_buildings = 0;
        int32_t reference_history_count = 0;
        int32_t worker_history_count = 0;
        int32_t reference_history_head = 0;
        int32_t worker_history_head = 0;
        std::array<int64_t, 8> reference_history_q16{};
        std::array<int64_t, 8> worker_history_q16{};
        // Why the reference side is missing rows at all. The first version of
        // this diff reported all-zero values for a real mismatch, because the
        // reference snapshot had no country rows to compare against.
        int64_t reference_last_day = -1;
        int64_t worker_round_day = -1;
        int64_t worker_committed_day = -1;
        int64_t reference_catalog_hash = 0;
        int64_t worker_catalog_hash = 0;
    };
    IdeologyPointsDiff _ideology_points_diff;
    void capture_ideology_points_diff(
        const RuntimeIdeologyPodSnapshot &reference,
        const RuntimeIdeologyPodSnapshot &worker);
    // Same atomic-char trick the country field uses: written on the economy thread
    // while the main thread may be formatting a report.
    std::array<std::atomic<char>, 48> _ideology_parity_field{};
    // `_ideology_transport_mutex` already exists for the snapshot ring; this one
    // only guards the reference map so the two cannot deadlock on each other.
    mutable std::mutex _ideology_parity_mutex;
    void record_ideology_parity_locked(const RuntimeIdeologyPodSnapshot &worker);
    std::atomic<bool> _ideology_parity_compared{false};
    std::atomic<bool> _ideology_parity_matched{false};
    std::atomic<int64_t> _ideology_parity_compared_count{0};
    std::atomic<int64_t> _ideology_parity_matched_count{0};
    std::atomic<uint64_t> _ideology_parity_reference_hash{0};
    std::atomic<uint64_t> _ideology_parity_worker_hash{0};
    std::atomic<int64_t> _ideology_parity_first_mismatch_day{-1};
    // R8-4: a worker day with no reference on the SAME calendar day. Counted
    // separately so "we could not compare" is never folded into "compared and
    // matched"; the gate asserts compared == matched, so a silently-dropped day
    // must not look like a pass.
    int64_t _ideology_parity_uncompared_day_offset = 0;
    int64_t _ideology_last_uncompared_distance = -1;
    std::deque<CountryPeerResult> _country_shadow_peer_mirrors;
    std::atomic<uint8_t> _country_parity_compared{0};
    std::atomic<uint8_t> _country_parity_matched{0};
    std::atomic<uint64_t> _country_parity_compared_count{0};
    std::atomic<uint64_t> _country_parity_matched_count{0};
    std::atomic<int64_t> _country_parity_first_mismatch_day{-1};
    std::atomic<uint64_t> _country_parity_reference_hash{0};
    std::atomic<uint64_t> _country_parity_worker_hash{0};
    std::atomic<int32_t> _country_parity_index{-1};
    std::array<std::atomic<char>, 64> _country_parity_status{};
    std::array<std::atomic<char>, 48> _country_parity_field{};
    CountryPeerProtocolStatus _country_worker_protocol{};
    RuntimeCountryPodPlan _country_pod_plan;
    std::deque<uint64_t> _country_worker_intent_queue;
    std::unordered_map<uint64_t, CountryPeerIntent> _country_worker_intents;
    std::unordered_map<uint64_t, CountryPeerResult> _country_worker_results;
    std::unordered_map<uint64_t, CountryPeerResult> _country_worker_terminal_results;
    std::deque<CountryWorkerNotification> _country_worker_notifications;
    // Country -> Economy is a separate bounded transport.  Requests remain
    // addressable after polling so a delayed/duplicate result can be checked
    // against the original transaction identity; only terminal results are
    // retained in the terminal cache after the worker consumes the request.
    std::deque<uint64_t> _country_economy_asset_request_queue;
    std::unordered_map<uint64_t, RuntimeEconomyAssetRequest>
        _country_economy_asset_requests;
    std::unordered_map<uint64_t, RuntimeEconomyAssetResult>
        _country_economy_asset_results;
    std::unordered_map<uint64_t, RuntimeEconomyAssetResult>
        _country_economy_asset_terminal_results;
    // Request ids that already crossed the Host transport boundary. A worker
    // continuation must not enqueue the same request again merely because the
    // Economy coordinator polled it from the queue.
    std::unordered_set<uint64_t> _country_economy_asset_dispatched;
    RuntimeEconomyAssetProtocolStatus _country_economy_asset_protocol{};
    std::deque<uint64_t> _economy_origin_asset_queue;
    std::unordered_set<uint64_t> _country_economy_asset_committed;
    std::unordered_set<uint64_t> _country_economy_asset_self_settled;
    CountryAuthorityOwner _country_authority_owner =
        CountryAuthorityOwner::SYNC;
    CountryAuthorityOwner _country_authority_prepared =
        CountryAuthorityOwner::SYNC;
    bool _country_authority_prepare_pending = false;
    std::array<char, 64> _country_authority_handoff_reason{};
    // Country command lifecycle is separate from the legacy generic receipt
    // queue. The generic queue reports transport/preflight admission for all
    // domains; this ordered map carries Country's typed terminal state and is
    // drained by a request-id cursor so a terminal result cannot be confused
    // with an admission acknowledgement.
    std::map<uint64_t, CountryCommandReceipt> _country_command_terminals;
    std::vector<uint64_t> _country_command_publications;
    // Complete Host-side request lifecycle. The terminal map is only the
    // cursor-visible projection; this map also retains Accepted requests so a
    // save can prove that every restored Country pending packet is admissible.
    std::map<uint64_t, CountryCommandReceipt> _country_command_states;
    std::atomic<uint64_t> _country_peer_signal{0};
    uint64_t _country_worker_session_epoch = 1;
    uint64_t _country_worker_country_generation = 0;
    int64_t _country_worker_day = -1;
    uint32_t _country_worker_continuation_index = 0;
    CountryBoundarySeal _country_worker_seal{};
