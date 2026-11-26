// Committed gameplay, building, population, market, and canal queries.

    struct CommittedGameplayFact {
        int32_t kind = 0;
        int32_t cell = -1;
        uint64_t entity_handle = 0;
        int32_t entity_id = -1;
        int64_t value = 0;
        std::array<int32_t, 4> payload{};
        int32_t flags = 0;
    };
    enum GameplayFactKind : int32_t {
        GAMEPLAY_FACT_CONSTRUCTION_COMPLETED = 1,
        GAMEPLAY_FACT_TRADE_ARRIVED = 2,
        GAMEPLAY_FACT_SOCIAL_PRESSURE = 3,
        GAMEPLAY_FACT_TARIFF_SUBSIDY_INTENT = 4,
        GAMEPLAY_FACT_TECHNOLOGY_PRACTICE = 5,
        GAMEPLAY_FACT_TECHNOLOGY_CONTACT = 6,
        GAMEPLAY_FACT_INFRASTRUCTURE_COMPLETED = 7,
        GAMEPLAY_FACT_REPEATED_CROP_FAILURE = 8,
        GAMEPLAY_FACT_COUNTRY_DEVELOPMENT_METRIC = 9,
        GAMEPLAY_FACT_STRATUM_MOBILIZATION = 10,
    };
    enum TechnologyPracticeRule : int32_t {
        PRACTICE_MAIZE_SELECTION = 0,
        PRACTICE_DRYLAND_DAYS = 1,
        PRACTICE_DRYLAND_DROUGHTS = 2,
        PRACTICE_HYDRAULIC_ENGINEERING = 3,
        PRACTICE_METALWORKING = 4,
        PRACTICE_PRINTING = 5,
        PRACTICE_STEAM_POWER = 6,
        PRACTICE_ELECTRIFICATION = 7,
        PRACTICE_INDUSTRIAL_ORGANIZATION = 8,
        PRACTICE_AUTOMATION = 9,
        PRACTICE_CLIMATE_MODELING = 10,
        PRACTICE_SEED_SAVING = 11,
        PRACTICE_RAINFED_ADAPTATION = 12,
        PRACTICE_PADDY_CONTROL = 13,
        PRACTICE_TERRACE_MAINTENANCE = 14,
        PRACTICE_MINE_SUPPORT = 15,
        PRACTICE_MINE_DRAINAGE = 16,
        PRACTICE_KILN_TEMPERATURE = 17,
        PRACTICE_PRINT_CALIBRATION = 18,
        PRACTICE_STEAM_SEALING = 19,
        PRACTICE_MOTOR_WINDING = 20,
        PRACTICE_ASSEMBLY_LINE = 21,
        PRACTICE_DIGITAL_CONTROL = 22,
        PRACTICE_MARITIME_OPERATIONS = 23,
        PRACTICE_WATERSHED_MANAGEMENT = 24,
        PRACTICE_FOREST_MANAGEMENT = 25,
        PRACTICE_CHEMICAL_PROCESS_CONTROL = 26,
        PRACTICE_ENERGY_CONTROL = 27,
        PRACTICE_HIDE_WORKING = 28,
        PRACTICE_RULE_COUNT = 29,
    };
    bool drain_committed_gameplay_facts(
        std::vector<CommittedGameplayFact> &out);
    // Gameplay journal row for a committed fact (phase 9, source 1). False for
    // kinds that are not published.
    static bool gameplay_fact_event(int32_t kind, int32_t &event_type,
                                    int32_t &payload_schema);
    bool compile_development_catalog(const godot::Dictionary &catalog,
                                     std::string &error);
    int32_t building_resource_access_cells(int32_t cell, int32_t resource_id,
                                           int32_t *out_cells, int32_t capacity) const;
    static constexpr uint8_t WATER_CLASS_NONE = 0;
    static constexpr uint8_t WATER_CLASS_LAKE = 1;
    static constexpr uint8_t WATER_CLASS_SHALLOW = 2;
    static constexpr uint8_t WATER_CLASS_FAR = 3;
    static constexpr uint8_t WATER_CLASS_DEEP = 4;
    static constexpr uint8_t WATER_CAP_RIVER = 1u;
    static constexpr uint8_t WATER_CAP_SHALLOW_SEA = 2u;
    static constexpr uint8_t WATER_CAP_FAR_SEA = 4u;
    static constexpr uint8_t WATER_CAP_DEEP_SEA = 8u;
    static constexpr int32_t WATER_LAYER_COUNT = 8;
    static constexpr int32_t WATER_PORTAL_GRAPH_COUNT = 4;
    static constexpr int32_t WATER_TRANSFER_PENALTY = 2;
    static constexpr int32_t WATER_ENTER_COST = 1;

    static int32_t water_maritime_level(uint8_t cap) {
        if ((cap & WATER_CAP_DEEP_SEA) != 0) return 3;
        if ((cap & WATER_CAP_FAR_SEA) != 0) return 2;
        if ((cap & WATER_CAP_SHALLOW_SEA) != 0) return 1;
        return 0;
    }
    static int32_t water_layer_index(uint8_t cap) {
        return ((cap & WATER_CAP_RIVER) != 0 ? 4 : 0) + water_maritime_level(cap);
    }
    static int32_t water_portal_graph_index(uint8_t cap) {
        const int32_t level = water_maritime_level(cap);
        if (level >= 1) return level;
        if ((cap & WATER_CAP_RIVER) != 0) return 0;
        return -1;
    }
    static uint8_t water_capability_from_layer(int32_t layer) {
        layer = std::clamp(layer, 0, WATER_LAYER_COUNT - 1);
        uint8_t cap = 0;
        if (layer >= 4) cap |= WATER_CAP_RIVER;
        const int32_t maritime = layer % 4;
        if (maritime >= 1) cap |= WATER_CAP_SHALLOW_SEA;
        if (maritime >= 2) cap |= WATER_CAP_FAR_SEA;
        if (maritime >= 3) cap |= WATER_CAP_DEEP_SEA;
        return cap;
    }

    bool capture_trade_topology(const int32_t *neighbor_indices,
                                const uint8_t *terrain,
                                const uint8_t *canal_edge_mask,
                                const float *canal_water,
                                const uint8_t *trade_passable_lut,
                                const int32_t *trade_move_cost_lut,
                                int32_t count, uint64_t generation,
                                std::string &error,
                                const uint8_t *landform = nullptr,
                                const uint8_t *has_river = nullptr);
    bool capture_trade_visibility(const uint8_t *visible, int32_t count,
                                  bool fog_solved, bool from_map,
                                  std::string &error);
    bool trade_visibility_manual() const { return _trade_visibility_manual; }
    bool refresh_canal_topology(const uint8_t *canal_edge_mask,
                                const float *canal_water,
                                int32_t count, std::string &error);
    int32_t trade_edge_cost(int32_t from_cell, int32_t to_cell) const;
    int32_t trade_land_step_cost(int32_t from_cell, int32_t to_cell,
                                 uint8_t cap) const;
    int32_t trade_component_for(int32_t cell, uint8_t cap) const;
    uint8_t water_capability_for_country(int32_t country_slot, bool frozen) const;
    uint8_t water_capability_for_handle(uint64_t country_handle, bool frozen) const;
    bool water_class_navigable(uint8_t water_class, uint8_t cap) const;
    bool cells_are_hex_neighbors(int32_t a, int32_t b) const;
    uint64_t canal_topology_hash() const {
        return _trade_topology.ready ? _trade_topology.topology_hash : 0;
    }
    uint64_t geo_flags_rebuilds() const {
        return _geo_flags_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t family_cell_metric_rebuilds() const {
        return _family_cell_metric_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t family_country_metric_rebuilds() const {
        return _family_country_metric_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t class_metric_rebuilds() const {
        return _class_metric_rebuilds.load(std::memory_order_relaxed);
    }
    int64_t class_metric_source_revision() const {
        return static_cast<int64_t>(_class_metric_source_revision);
    }
    int64_t class_metric_source_epoch_day() const {
        return _class_metric_source_epoch_day;
    }
    uint64_t class_metric_source_content_hash() const {
        return _class_metric_source_content_hash;
    }
    // Test-only: runs the same refresh as the epoch boundary without advancing
    // the simulation. Used to synchronize a fixture with the already-committed
    // snapshot before measuring.
    void refresh_class_opinion_metrics_for_test() {
        refresh_class_opinion_metrics();
    }
    const std::vector<int64_t> &class_metric_satisfaction_q16() const {
        return _epoch_country_class_satisfaction_q16;
    }
    const std::vector<int64_t> &class_metric_weighted_satisfaction_q16() const {
        return _epoch_country_weighted_satisfaction_q16;
    }
    const std::vector<int64_t> &class_metric_farmer_satisfaction_q16() const {
        return _epoch_country_farmer_satisfaction_q16;
    }
    const std::vector<int64_t> &class_metric_worker_satisfaction_q16() const {
        return _epoch_country_worker_satisfaction_q16;
    }
    uint64_t technology_metric_rebuilds() const {
        return _technology_metric_rebuilds.load(std::memory_order_relaxed);
    }
    uint64_t technology_metric_source_hash() const {
        return _technology_metric_source_hash;
    }
    uint64_t neighbor_distinct_goods_source_hash() const {
        return _neighbor_distinct_goods_source_hash;
    }
    // Test-only: replace the captured country technology bitset with an exact
    // shape, then run the production hash-gated refresh.
    void set_epoch_country_technologies_for_test(
        const std::vector<uint64_t> &bits);
    void clear_epoch_country_technologies_for_test();
    int32_t epoch_country_count_for_test() const {
        return _epoch_country_count;
    }
    // Size of the ECONOMY-side territory plane. `country_cell_count` returns 0
    // whenever this does not equal the cell count
    // (economy_runtime_family_buff.cpp:970), which makes every territory selector
    // produce zero targets -- indistinguishable from "the card matched nothing".
    // M4 diagnosis for the own-territory selector: how many times its branch ran,
    // what `owned` it saw, and how many cells it emitted. Without these, an empty
    // result is indistinguishable from "the branch never ran".
    mutable int64_t _own_territory_branch = 0;
    // Last-seen inputs of the own-territory branch. `emitted` was 0 while
    // `owned` was 1600, which can only be one of: source_cell out of range,
    // country != the slot that owns everything, or every country_cell_at returning
    // -1. These three record which.
    mutable int64_t _own_last_source_cell = -999;
    mutable int64_t _own_last_country = -999;
    mutable int64_t _own_last_cap = -999;
    mutable int64_t _own_first_cell_ok = -999;
    mutable int64_t _own_last_tag = -999;
    // Cells pushed inside the collect loop, BEFORE sort/unique/cap. If this is
    // non-zero while `emitted` is 0, the loss is in sort/unique/cap; if it is 0,
    // the loop itself never pushed.
    mutable int64_t _own_pushed_raw = 0;
    mutable int64_t _own_cell_neg = 0;
    mutable int64_t _own_tag_rejected = 0;
    int64_t own_last_source_cell_debug() const { return _own_last_source_cell; }
    int64_t own_last_country_debug() const { return _own_last_country; }
    int64_t own_last_cap_debug() const { return _own_last_cap; }
    int64_t own_first_cell_ok_debug() const { return _own_first_cell_ok; }
    int64_t own_last_tag_debug() const { return _own_last_tag; }
    int64_t own_pushed_raw_debug() const { return _own_pushed_raw; }
    int64_t own_cell_neg_debug() const { return _own_cell_neg; }
    int64_t own_tag_rejected_debug() const { return _own_tag_rejected; }
    mutable int64_t _own_territory_owned = 0;
    mutable int64_t _own_territory_emitted = 0;
    int64_t own_territory_branch_count() const { return _own_territory_branch; }
    int64_t own_territory_owned_total() const { return _own_territory_owned; }
    int64_t own_territory_emitted_total() const { return _own_territory_emitted; }

    // Readiness of the building-context columns the RADIAL selectors depend on.
    //
    // `collect_effect_target_cells` returns "no cells" for kinds 6..11 unless all four
    // columns are sized to the grid (`economy_runtime_family_buff.cpp:2554-2562`). That
    // guard is invisible from outside, so a fixture whose ring comes back empty cannot
    // tell "no neighbours" from "the snapshot was never captured".
    godot::Dictionary building_context_ready_for_test() const;

    size_t epoch_cell_country_size_for_test() const {
        return _epoch_cell_country.size();
    }
    // Colonization gate probes (plan 22 M3-8). `family_colonization_quotes`
    // rejects a cell with `passable == 0` unless an epoch is active
    // (`economy_runtime_colonization.cpp:496`), and NEITHER input was observable --
    // which is why a diagnostic that checked the other gates reported "all clear"
    // while the call kept failing.
    //
    // Both are const and side-effect free; they exist so a probe can say WHICH of
    // the two conditions is unmet instead of inferring it.
    bool trade_passable_for_test(int32_t cell) const {
        if (cell < 0 ||
            static_cast<size_t>(cell) >= _trade_topology.passable.size())
            return false;
        return _trade_topology.passable[static_cast<size_t>(cell)] != 0;
    }
    bool epoch_active_for_test() const { return _epoch_active; }
    bool trade_topology_ready_for_test() const {
        return _trade_topology.ready &&
            _trade_topology.passable.size() ==
                static_cast<size_t>(_cell_count.get());
    }
    int32_t epoch_country_technology_words_for_test() const {
        return _epoch_country_technology_words;
    }
    int64_t epoch_country_technology_word_for_test(
            int32_t country, int32_t word) const {
        if (country < 0 || word < 0) return 0;
        const size_t index =
            static_cast<size_t>(country) *
                static_cast<size_t>(_epoch_country_technology_words) +
            static_cast<size_t>(word);
        return index < _epoch_country_technologies.size()
            ? static_cast<int64_t>(_epoch_country_technologies[index]) : 0;
    }
    // Bounded, read-only payload used by the Effect gameplay adapter. The
    // route remains Economy-owned until the Effect transaction is ACKED.
    bool canal_project_commit_payload(uint64_t project_handle,
                                      uint32_t project_generation,
                                      std::vector<int32_t> &route_cells,
                                      std::vector<int32_t> &route_edge_dirs,
                                      uint64_t &topology_hash,
                                      std::string &error) const;
