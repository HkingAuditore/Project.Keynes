// Included inside NativeEconomyRuntime. Committed read queries and published building views.
    // EconomyCommitView. While the worker owns economy execution the main
    // thread must not read live economy state outside the authority boundary.
    // It registers demand for a query key; the worker evaluates the demanded
    // keys at its committed day boundary and publishes an immutable view.
    // Views are UI/diagnostic reads only: never simulation input, PKEC or hash.
    enum class ReadQuery : uint16_t {
        NONE = 0,
        POPULATION_CELL_SNAPSHOT,
        POPULATION_CELL_SUMMARY,
        NAMED_SETTLEMENT_SNAPSHOT,
        SETTLEMENT_DELTA,
        MARKET_CELL_SNAPSHOT,
        EXPLAIN_COHORT_SATISFACTION,
        CELL_SATISFACTION_ATTRACTIVENESS,
        FISCAL_SNAPSHOT,
        COUNTRY_TRADE_SNAPSHOT,
        TRADE_ORDERS_FOR_CELL,
        BUILDING_CELL_SNAPSHOT,
        TREASURY_CONSTRUCTION_QUOTES,
        CONSTRUCTION_COMMAND_RECEIPTS,
        CANAL_ROUTE_QUOTE,
        CANAL_ROUTE_QUOTE_DETAIL,
        CANAL_CONSTRUCTION_RECEIPTS,
        FAMILY_CELL_SNAPSHOT,
        FAMILY_SNAPSHOT,
        FAMILY_TRAITS,
        FAMILY_BRANCHES,
        FAMILY_COLONIZATION_QUOTES,
        FAMILY_COLONIZATION_QUOTE_DETAIL,
        FAMILY_EXPEDITIONS,
        FAMILY_EXPEDITION_SNAPSHOT,
        FAMILY_COLONIZATION_RECEIPTS,
        FAMILY_BRANCH_EFFECTS,
        FAMILY_FOUNDING_OFFERS,
        FAMILY_INDUSTRIES,
        FAMILY_NOTABLE_PEOPLE,
        NOTABLE_PERSON_SNAPSHOT,
        NOTABLE_PERSON_NEEDS,
        BUILDING_NOTABLE_PEOPLE,
        COUNTRY_CLASS_OPINION_SNAPSHOT,
        COUNTRY_ECONOMY_OVERVIEW,
        SITUATION_VISUAL_SNAPSHOT,
        COUNTRY_PROCUREMENT_SNAPSHOT,
        CELL_MOBILIZATION_SNAPSHOT,
        COUNTRY_MOBILIZATION_SUMMARY,
    };
    struct ReadKey {
        ReadQuery query = ReadQuery::NONE;
        std::array<int64_t, 8> args{};
        godot::String text;
        godot::PackedInt32Array ints;
        // Payload only (colonization visibility); its identity is the vision
        // revision carried in args.
        godot::PackedByteArray bytes;
        uint64_t hash = 0;
        void seal();
        bool same(const ReadKey &other) const;
    };
    struct ReadViewEntry {
        ReadKey key;
        godot::Dictionary value;
        // Entries survive across serves until the refresh interval, so each
        // carries the committed day it was evaluated at.
        int64_t committed_day = -1;
        uint64_t generation = 0;
    };
    struct ReadView {
        uint64_t serial = 0;
        uint64_t generation = 0;
        int64_t committed_day = -1;
        std::vector<ReadViewEntry> entries; // sorted by key.hash
        const ReadViewEntry *find(const ReadKey &key) const;
    };
    struct BuildingVisualView {
        uint64_t generation = 0;
        int32_t cell_count = 0;
        std::vector<int32_t> cell_offsets;
        std::vector<int32_t> type_indices;
        std::vector<int64_t> counts;
        // Per cell; BUILDING_VISUAL_UNKNOWN where no cohort has been sampled.
        std::vector<uint8_t> settlement_tiers;
        std::vector<uint8_t> living_levels;
        std::vector<uint8_t> rich_buckets;
        std::vector<uint8_t> poor_buckets;
    };
    godot::Dictionary evaluate_read_query(const ReadKey &key);
    bool read_view_subscribe(const ReadKey &key);
    std::shared_ptr<const ReadView> read_view() const {
        return std::atomic_load_explicit(&_read_view, std::memory_order_acquire);
    }
    // Caller must hold the economy authority boundary with no epoch open.
    void serve_read_view(bool requested = false);
    void publish_building_visual_view();
    std::shared_ptr<const BuildingVisualView> building_visual_view() const {
        return std::atomic_load_explicit(&_building_visual_view,
                                         std::memory_order_acquire);
    }
    static godot::Dictionary building_visual_rows(
        const BuildingVisualView &view,
        const godot::PackedInt32Array &requested_cells);
    godot::PackedInt32Array drain_building_visual_outbox();
    void read_view_reset();
    godot::Dictionary read_view_status() const;
