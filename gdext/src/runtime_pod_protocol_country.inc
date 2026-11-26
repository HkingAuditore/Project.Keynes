// Country day input, committed snapshot, catalog, and command wire records.

// Country-domain ABI used by the Phase B adapter.  These records are
// deliberately smaller than the Godot-facing country report: a worker may
// pass them between fixed stages without constructing dynamic Godot values.
// The adapter is currently opt-in; the legacy facade remains authoritative
// until all country command/economy barriers are migrated.
struct RuntimeCountryDayContext {
    int64_t day = 0;
    double speed_scale = 1.0;
    uint64_t input_generation = 0;
    // Immutable peer facts captured at the semantic Country boundary.  The
    // pointer is borrowed for one cooperative step and is never retained by a
    // worker after the call returns.
    const CountryPeerContext *peer_context = nullptr;
};

enum class RuntimeCountryPodError : uint16_t {
    NONE = 0,
    NOT_BOOTSTRAPPED = 1,
    INVALID_CONTEXT = 2,
    COMMAND_BATCH_PENDING = 3,
    CROSS_DOMAIN_BARRIER_REQUIRED = 4,
    COMMAND_REJECTED = 5,
};

struct RuntimeCountryDayCommit {
    uint32_t dirty_families = 0;
    uint32_t changed_countries = 0;
    uint32_t changed_territory_cells = 0;
    uint64_t research_work_units = 0;
    uint64_t state_hash = 0;
    uint64_t country_generation = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 0;
    uint8_t ack_required = 0;
    uint8_t reserved = 0;
    RuntimeCountryPodError error_code = RuntimeCountryPodError::NONE;
};

// Immutable, worker-safe country input.  This is intentionally a numeric
// projection of NativeCountryRuntime: strings, Godot values and peer-runtime
// pointers never cross the simulation thread boundary.  The vectors are
// copied once at a main-thread capture boundary and then treated as const by
// the POD adapter.
struct RuntimeCountryPodSnapshot {
    // Transport identity captured with the immutable input. Zero is retained
    // for older diagnostic fixtures and normalized by the worker authority.
    uint64_t session_epoch = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    int64_t committed_day = -1;
    int64_t last_research_day = -1;
    uint32_t cell_count = 0;
    uint32_t country_count = 0;
    uint32_t technology_words = 0;
    uint32_t technology_count = 0;
    uint32_t good_count = 0;
    uint32_t profession_count = 0;
    uint32_t building_type_count = 0;
    uint32_t research_signal_words = 0;
    uint32_t research_signal_count = 0;
    // Catalog identity is captured with the immutable country projection. A
    // worker must reject a snapshot whose catalog is not the one it was
    // bootstrapped against; strings and Godot catalog objects never cross the
    // worker boundary.
    uint64_t catalog_hash = 0;
    bool bootstrapped = false;
    bool research_active_index_valid = false;
    std::vector<uint8_t> country_active;
    std::vector<uint32_t> country_generation;
    std::vector<int32_t> country_political_regime_ids;
    std::vector<uint32_t> country_political_regime_capabilities;
    // Identity strings are copied once at the command/snapshot boundary. They
    // never participate in the numeric hot loop, but CREATE/RENAME must still
    // have the same durable semantics as the synchronous core.
    std::vector<std::string> country_stable_ids;
    std::vector<std::string> country_display_names;
    // Sorted dense slots whose research state can make progress on the next
    // day.  This is a derived membership index captured from Country's
    // native hot loop; an empty vector is accepted for compatibility and
    // means the adapter must conservatively scan all country slots.
    std::vector<int32_t> research_active_country_slots;
    std::vector<int32_t> territory_count;
    // Per-country capital cell (v16). -1 means "no capital" (legacy fixture or
    // a country whose capital was lost); a valid capital is a land cell.
    std::vector<int32_t> capital_cell;
    std::vector<uint64_t> country_state_version;
    std::vector<int64_t> country_cash;
    std::vector<int64_t> country_goods;
    std::vector<int32_t> cell_country_slot;
    std::vector<int32_t> territory_offsets;
    std::vector<int32_t> territory_cells;
    std::vector<uint64_t> country_technologies;
    std::vector<uint64_t> country_discovered;
    std::vector<uint64_t> country_pending_technologies;
    std::vector<uint64_t> country_research_signals;
    std::vector<int32_t> research_signal_cell_offsets;
    std::vector<uint64_t> research_signal_cells;
    std::vector<int32_t> research_signal_evidence_offsets;
    struct SignalEvidence {
        int32_t signal = -1;
        int32_t count = 0;
        int64_t first_day = -1;
        int64_t last_day = -1;
        int32_t first_cell = -1;
    };
    std::vector<SignalEvidence> research_signal_evidence;
    std::vector<int32_t> research_queues;
    std::vector<uint8_t> research_queue_lengths;
    std::vector<int32_t> research_weights_bp;
    std::vector<int64_t> research_deferred_points;
    std::vector<int64_t> research_progress_total;
    std::vector<int64_t> research_completed_total;
    // Per-technology progress is required for deterministic plan/replay. The
    // legacy probe only exported aggregate totals; a worker authority must
    // reject captures that omit this matrix.
    std::vector<int64_t> research_progress;
    // Peer modifier inputs captured at the same semantic boundary. They are
    // required for deterministic completion-day arithmetic and are not a
    // second mutable authority.
    std::vector<double> research_cost_factor;
    std::vector<double> research_efficiency;
    // Dense numeric flags for pending technology peer state. A value is the
    // OR of CountryPeerTechnologyState flags for (country, technology).
    std::vector<uint8_t> research_peer_flags;
    std::vector<uint8_t> research_auto_purchase;
    std::vector<int64_t> research_purchased_total;
    std::vector<int64_t> research_consumed_total;
    // Transient era-advancement treasury sink (CONSUME_TREASURY_GOODS).
    // Excluded from the business hash, PKCN and worker checkpoint payloads;
    // the economy goods audit samples it like research_consumed_total.
    // Empty is accepted (older fixtures) and treated as all-zero.
    std::vector<int64_t> treasury_goods_consumed_total;
    static constexpr uint32_t TAX_KIND_COUNT = 5u;
    std::vector<int32_t> country_tax_defaults;
    std::vector<int32_t> country_tax_default_modes;
    std::vector<int32_t> country_income_tax_overrides;
    std::vector<int32_t> country_consumption_tax_overrides;
    std::vector<int32_t> country_business_tax_overrides;
    std::vector<int32_t> country_import_tax_overrides;
    std::vector<int32_t> country_export_tax_overrides;
    std::vector<int32_t> country_income_tax_mode_overrides;
    std::vector<int32_t> country_consumption_tax_mode_overrides;
    std::vector<int32_t> country_business_tax_mode_overrides;
    std::vector<int32_t> country_import_tax_mode_overrides;
    std::vector<int32_t> country_export_tax_mode_overrides;
    struct CellTaxOverride {
        int32_t kind = -1;
        int32_t item = -1;
        int32_t rate = std::numeric_limits<int32_t>::min();
        int32_t mode = std::numeric_limits<int32_t>::min();
    };
    struct CellTaxPolicy {
        std::array<int32_t, TAX_KIND_COUNT> defaults{};
        std::array<int32_t, TAX_KIND_COUNT> modes{};
        std::vector<CellTaxOverride> overrides;
    };
    std::vector<uint32_t> cell_tax_policy_ids;
    std::vector<CellTaxPolicy> cell_tax_policies;
    std::vector<uint8_t> is_water;
};

// Main-thread read view for a committed worker Country state. `generation` is
// the monotonic publication cursor, not necessarily the Country business
// generation: a rejected peer boundary may commit Country-side state without
// advancing the business generation, and must still be visible to readers.
// The snapshot remains immutable and owned by the host; the patch is the only
// territory payload copied for the normal publish path. `full_snapshot_required`
// is set when the consumer missed a generation that changed territory and
// therefore cannot reconstruct owners from the retained sparse patch. A gap
// that only advanced cash, tax, or research stays sparse.
struct RuntimeCountryReadView {
    bool available = false;
    bool full_snapshot_required = false;
    uint64_t generation = 0;
    uint64_t patch_base_generation = 0;
    int64_t committed_day = -1;
    uint64_t state_hash = 0;
    uint32_t dirty_families = 0;
    uint64_t territory_watermark = 0;
    uint64_t research_watermark = 0;
    uint64_t tax_watermark = 0;
    uint64_t visual_watermark = 0;
    uint32_t country_count = 0;
    uint32_t cell_count = 0;
    std::vector<int32_t> changed_cells;
    std::vector<int32_t> changed_owners;
    std::shared_ptr<const RuntimeCountryPodSnapshot> snapshot;
};

// Numeric, immutable catalog compiled by the main-thread facade before a
// worker is started. Strings and Godot catalog objects never cross the worker
// boundary. The condition CSR is explicit so a worker can reject an
// incomplete capture instead of guessing at reference semantics.
struct RuntimeCountryPodCatalog {
    uint64_t catalog_hash = 0;
    uint32_t technology_count = 0;
    uint32_t technology_words = 0;
    int32_t technology_points_good_id = -1;
    bool research_conditions_complete = false;
    std::vector<int64_t> technology_costs;
    std::vector<int32_t> technology_domains;
    std::vector<int32_t> technology_flags;
    // Stable numeric projection of whether a technology has a peer Effect /
    // Modifier activation requirement. String definition keys stay main-thread
    // catalog data and never cross into the worker.
    std::vector<uint8_t> technology_effect_required;
    // hash_text("technology.<id>"): the worker's key for the Effect program.
    std::vector<uint64_t> technology_effect_key_hashes;
    std::vector<int32_t> prerequisite_offsets;
    std::vector<int32_t> prerequisites;
    std::vector<int32_t> milestone_offsets;
    std::vector<int32_t> milestone_candidates;
    std::vector<int32_t> milestone_required_counts;
    std::vector<int32_t> entry_milestone_indices;
    std::vector<int32_t> research_condition_offsets;
    std::vector<int32_t> research_condition_ops;
    std::vector<int32_t> research_condition_refs;
    std::vector<int64_t> research_condition_values;
    // Discovery/reveal conditions are distinct from queue eligibility. They
    // must cross the worker boundary because DISCOVER_COUNTRY_SIGNAL can make
    // technologies visible before they are researchable.
    std::vector<int32_t> reveal_condition_offsets;
    std::vector<int32_t> reveal_condition_ops;
    std::vector<int32_t> reveal_condition_refs;
    std::vector<int64_t> reveal_condition_values;
    std::vector<int32_t> starting_technologies;
    std::vector<std::string> political_regime_ids;
    std::vector<uint32_t> political_regime_capability_bits;
    uint64_t political_regime_catalog_hash = 0;
};

struct RuntimeCountryPodDiagnostics {
    uint64_t snapshot_generation = 0;
    uint64_t state_hash = 0;
    uint64_t work_units = 0;
    uint32_t active_country_count = 0;
    uint32_t active_index_count = 0;
    uint32_t pending_checks = 0;
    uint32_t changed_country_count = 0;
    uint32_t changed_cell_count = 0;
    uint8_t ack_pending = 0;
    char blocker[64]{};
};

// Country command payload used by the Phase B adapter.  This is deliberately
// a fixed-size, string-free record: stable/display names and catalog ids are
// resolved on the Godot facade before a command crosses the worker boundary.
// The record is also useful to the synchronous reference path because it makes
// the validation contract identical before the full Country store is moved
// behind NativeSimulationHost.
constexpr uint32_t RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY = 256u;
constexpr uint32_t RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT = 4u;
constexpr size_t RUNTIME_COUNTRY_STABLE_ID_CAPACITY = 96u;
constexpr size_t RUNTIME_COUNTRY_DISPLAY_NAME_CAPACITY = 192u;

struct RuntimeCountryCommand {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t submit_order = 0;
    uint64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    uint16_t opcode = 0;
    uint16_t reserved = 0;
    uint64_t target_handle = 0;
    int32_t cell = -1;
    int32_t aux = -1;
    int32_t domain = -1;
    int32_t position = -1;
    std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> weights_bp{
        {2500, 2500, 2500, 2500}};
    int32_t tax_kind = -1;
    int32_t tax_item = -1;
    int32_t tax_rate_basis_points = 0;
    int32_t tax_assessment_mode = 0;
    int64_t value = 0;
    std::array<char, RUNTIME_COUNTRY_STABLE_ID_CAPACITY> stable_id{};
    std::array<char, RUNTIME_COUNTRY_DISPLAY_NAME_CAPACITY> display_name{};
};

RuntimeCommandPacket encode_country_packet(const RuntimeCountryCommand &command);
// PKSR uses this reserved producer value only for its executor observation rows.
constexpr uint32_t COUNTRY_OBSERVATION_ARCHIVE_PRODUCER = 0xffffffffu;
bool is_country_day_observation(const RuntimeCommandEnvelope &envelope);

struct RuntimeCountryCommandBatch {
    uint32_t count = 0;
    std::array<RuntimeCountryCommand,
               RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY> commands{};
};

inline bool runtime_country_research_weights_valid(
        const std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> &weights) noexcept {
    int64_t total = 0;
    for (const int32_t weight : weights) {
        if (weight < 0 || weight > 10000) return false;
        total += weight;
    }
    return total == 10000;
}
