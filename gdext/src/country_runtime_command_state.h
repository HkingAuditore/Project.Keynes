// Private country stores, command records, and command-pipeline continuation.

    struct CountryStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<std::string> stable_id;
        std::vector<std::string> display_name;
        std::vector<int32_t> territory_count;
        // Capital cell (PKCN v16). Set from the bootstrap start cell and from
        // CREATE_COUNTRY; -1 means unset/legacy. It is a political fact, not a
        // territory claim: a country may lose its capital and keep the cell id.
        std::vector<int32_t> capital_cell;
        std::vector<int64_t> cash;
        std::vector<uint64_t> state_version;
        std::vector<int32_t> political_regime_id;
        std::vector<uint32_t> political_regime_capability_bits;
    };

    struct Command {
        uint64_t request_id = 0;
        uint32_t producer_id = 0;
        uint64_t observed_generation = 0;
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        int32_t cell = -1;
        int32_t aux = -1;
        int32_t domain = -1;
        int32_t position = -1;
        int32_t weights_bp[4] = {0, 0, 0, 0};
        int32_t tax_kind = -1;
        int32_t tax_item = -1;
        int32_t tax_rate_basis_points = 0;
        int32_t tax_assessment_mode = TAX_MODE_PERCENT_BP;
        int64_t value = 0;
        std::string stable_id;
        std::string display_name;
        uint64_t submit_order = 0;
        int64_t effect_request_id = 0;
        uint64_t effect_idempotency_key = 0;
    };

    struct Event {
        int64_t event_id = 0;
        int64_t day = 0;
        int32_t opcode = 0;
        uint64_t country_handle = 0;
        int32_t cell = -1;
        int32_t old_country_slot = -1;
        int32_t new_country_slot = -1;
        int32_t technology_id = -1;
        int32_t signal_id = -1;
        int32_t signal_source_kind = 0;
        int32_t evidence_delta = 0;
        // Actual moved amount for opcode 23/24 (cash / goods quantity).
        int64_t value = 0;
        std::string stable_id;
        std::string display_name;
    };

    struct SparseCellDelta {
        std::vector<int32_t> keys;
        std::vector<int32_t> values;
        size_t mask = 0;
        size_t count = 0;

        void reserve(size_t expected) {
            size_t capacity = 8;
            while (capacity < expected * 2 + 1) capacity <<= 1U;
            keys.assign(capacity, -1);
            values.assign(capacity, NEUTRAL_SLOT);
            mask = capacity - 1;
            count = 0;
        }
        bool get(int32_t cell, int32_t &value) const {
            if (keys.empty()) return false;
            size_t cursor = (static_cast<uint32_t>(cell) * 2654435761U) & mask;
            while (true) {
                if (keys[cursor] == -1) return false;
                if (keys[cursor] == cell) {
                    value = values[cursor];
                    return true;
                }
                cursor = (cursor + 1) & mask;
            }
        }
        bool set(int32_t cell, int32_t value) {
            size_t cursor = (static_cast<uint32_t>(cell) * 2654435761U) & mask;
            while (keys[cursor] != -1 && keys[cursor] != cell)
                cursor = (cursor + 1) & mask;
            const bool inserted = keys[cursor] == -1;
            if (inserted) { keys[cursor] = cell; ++count; }
            values[cursor] = value;
            return inserted;
        }
        size_t size() const { return count; }
        bool empty() const { return count == 0; }
    };

    struct CountryEffectCommandResult {
        uint8_t complete = 0;
        uint8_t ok = 0;
        std::string reason;
    };

    struct SignalEvidence {
        int32_t signal = -1;
        int32_t count = 0;
        int64_t first_day = -1;
        int64_t last_day = -1;
        int32_t first_cell = -1;
    };

    struct CommandBatchState {
        bool active = false;
        int64_t day = -1;
        size_t cursor = 0;
        double preflight_ms = 0.0;
        int64_t observation_batch_input = 0;
        int64_t observation_batch_added = 0;
        CountryStore countries;
        std::vector<uint64_t> technologies;
        std::vector<int64_t> goods;
        std::vector<uint64_t> discovered;
        std::vector<uint64_t> pending;
        std::vector<std::vector<std::pair<int32_t, int64_t>>> progress;
        std::vector<int32_t> research_queues;
        std::vector<uint8_t> research_queue_lengths;
        std::vector<int32_t> research_weights_bp;
        std::vector<uint8_t> research_auto_purchase;
        std::vector<int64_t> research_deferred_points;
        std::vector<uint64_t> signals;
        std::vector<std::vector<uint64_t>> signal_cells;
        std::vector<std::vector<SignalEvidence>> signal_evidence;
        bool stage_technologies = false;
        bool stage_goods = false;
        bool stage_research = false;
        bool stage_signals = false;
        bool stage_tax = false;
        bool stage_cell_tax = false;
        std::vector<int32_t> tax_defaults;
        std::vector<int32_t> tax_default_modes;
        std::vector<int32_t> income_tax_overrides;
        std::vector<int32_t> consumption_tax_overrides;
        std::vector<int32_t> business_tax_overrides;
        std::vector<int32_t> import_tax_overrides;
        std::vector<int32_t> export_tax_overrides;
        std::vector<int32_t> income_tax_mode_overrides;
        std::vector<int32_t> consumption_tax_mode_overrides;
        std::vector<int32_t> business_tax_mode_overrides;
        std::vector<int32_t> import_tax_mode_overrides;
        std::vector<int32_t> export_tax_mode_overrides;
        std::unordered_map<int32_t, CellTaxPolicy> cell_tax_updates;
        SparseCellDelta cell_delta;
        std::vector<int32_t> cell_delta_order;
        std::vector<int32_t> direct_cell_owners;
        bool direct_unique_territory = false;
        std::vector<Event> events;
        std::vector<Command> commands;
        std::vector<uint8_t> changed_countries;
        // (slot, quantity) consumed by CONSUME_TREASURY_GOODS in this batch.
        std::vector<std::pair<int32_t, int64_t>> treasury_consumed;
    };

    // Per-call orchestration state for the country command pipeline. The
    // mutable batch remains the sole owner of staged country data; this only
    // carries the timing and result values across the three execution phases.
    struct CoreSliceContext {
        int64_t requested_day = -1;
        int64_t day = -1;
        size_t cursor_start = 0;
        size_t cursor_limit = 0;
        std::chrono::steady_clock::time_point start;
        CountryCoreStepResult result;
    };
