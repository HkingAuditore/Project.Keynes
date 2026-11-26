// Settlement revisions, route topology, trade plans, market signals, and labor stores.

    struct SettlementChange {
        int32_t cell = -1;
        uint8_t tier = 0;
        uint8_t name_active = 0;
    };

    struct SettlementRevision {
        int64_t revision = 0;
        std::vector<SettlementChange> changes;
    };

    struct SettlementStore {
        EconomyOwnedColumn<uint8_t> tier{{{17, 1}, "SettlementStore.tier", EconomyFieldEncoding::U8, 1}};
        EconomyOwnedColumn<uint8_t> name_active{{{17, 2}, "SettlementStore.name_active", EconomyFieldEncoding::U8, 1}};
        EconomyOwnedColumn<uint8_t> name_forced{{{17, 3}, "SettlementStore.name_forced", EconomyFieldEncoding::U8, 1}};
        EconomyOwnedColumn<uint32_t> prosperity_generation{{{17, 4}, "SettlementStore.prosperity_generation", EconomyFieldEncoding::U32, 4}};
        EconomyOwnedColumn<uint32_t> name_roll_generation{{{17, 5}, "SettlementStore.name_roll_generation", EconomyFieldEncoding::U32, 4}};
        EconomyOwnedColumn<int32_t> prefix{{{17, 6}, "SettlementStore.prefix", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> root{{{17, 7}, "SettlementStore.root", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> suffix{{{17, 8}, "SettlementStore.suffix", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<uint32_t> disambiguator{{{17, 9}, "SettlementStore.disambiguator", EconomyFieldEncoding::U32, 4}};
        std::unordered_map<std::string, int32_t> active_names;
        std::deque<SettlementRevision> revisions;
        int64_t revision = 0;

        void clear(int32_t cells) {
            tier.assign(cells, 0);
            name_active.assign(cells, 0);
            name_forced.assign(cells, 0);
            prosperity_generation.assign(cells, 0);
            name_roll_generation.assign(cells, 0);
            prefix.assign(cells, -1);
            root.assign(cells, -1);
            suffix.assign(cells, -1);
            disambiguator.assign(cells, 0);
            active_names.clear();
            revisions.clear();
            revision = 0;
        }
    };

    using PriceCeilingState = RuntimeEconomyPriceCeilingState;
    struct PriceCeilingObservation {
        int32_t market = -1, good = -1, price = 1, base = 1, days = 0;
        int64_t requested = 0, unfilled = 0;
    };
    using MarketStore = RuntimeEconomyMarketStore;
    using ResourceStore = RuntimeEconomyResourceStore;

    struct MarketSignalStore {
        EconomyOwnedColumn<int32_t> cell_offsets{{{18, 1}, "MarketSignalStore.cell_offsets", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> good_ids{{{18, 2}, "MarketSignalStore.good_ids", EconomyFieldEncoding::I32, 4}};
        // Optional O(1) (cell, good) -> sparse signal index. Rebuilt from the
        // authoritative ascending CSR and excluded from save/hash state.
        std::vector<int32_t> dense_index;
        EconomyOwnedColumn<int64_t> business_demand_ema{{{18, 3}, "MarketSignalStore.business_demand_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> offered_supply_ema{{{18, 4}, "MarketSignalStore.offered_supply_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> realized_withdrawal_ema{{{18, 5}, "MarketSignalStore.realized_withdrawal_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int32_t> cost_anchor_price{{{18, 6}, "MarketSignalStore.cost_anchor_price", EconomyFieldEncoding::I32, 4}};

        void clear(int32_t cells) {
            cell_offsets.assign(static_cast<size_t>(std::max(0, cells)) + 1, 0);
            good_ids.clear();
            dense_index.clear();
            business_demand_ema.clear();
            offered_supply_ema.clear();
            realized_withdrawal_ema.clear();
            cost_anchor_price.clear();
        }
    };

    struct WaterPortalGraph {
        std::vector<int32_t> cell_portal;
        std::vector<int32_t> portal_cells;
        std::vector<int32_t> offsets;
        std::vector<int32_t> targets;
        std::vector<int32_t> costs;
        std::vector<int32_t> reverse_offsets;
        std::vector<int32_t> reverse_targets;
        std::vector<int32_t> reverse_costs;

        void clear() {
            cell_portal.clear();
            portal_cells.clear();
            offsets.clear();
            targets.clear();
            costs.clear();
            reverse_offsets.clear();
            reverse_targets.clear();
            reverse_costs.clear();
        }
    };

    struct TradeTopologyStore {
        std::vector<int32_t> neighbors;
        std::vector<uint8_t> passable;
        std::vector<int32_t> enter_cost;
        std::vector<int32_t> edge_cost;
        std::vector<uint8_t> canal_edge_mask;
        std::vector<float> canal_water;
        std::vector<int32_t> component;
        std::vector<uint8_t> water_class;
        std::vector<uint8_t> has_river;
        WaterPortalGraph water_portals[WATER_PORTAL_GRAPH_COUNT];
        std::vector<int32_t> component_layers;
        uint64_t topology_generation = 0;
        uint64_t topology_hash = 0;
        // Hash of the frozen cell->country ownership map used to build
        // components. Country cash/treasury generations must not invalidate
        // routing when borders did not change.
        uint64_t component_country_hash = 0;
        bool ready = false;

        void clear() {
            neighbors.clear();
            passable.clear();
            enter_cost.clear();
            edge_cost.clear();
            canal_edge_mask.clear();
            canal_water.clear();
            component.clear();
            water_class.clear();
            has_river.clear();
            for (WaterPortalGraph &graph : water_portals) graph.clear();
            component_layers.clear();
            topology_generation = 0;
            topology_hash = 0;
            component_country_hash = 0;
            ready = false;
        }
    };

    struct TradeSignal {
        int32_t cell = -1;
        int32_t good = -1;
        int32_t country = -1;
        int32_t price = 0;
        int64_t quantity = 0;
        int32_t age_days = 0;
        int32_t response_priority = 0;
    };

    struct TradeCandidate {
        int32_t source = -1;
        int32_t destination = -1;
        int32_t good = -1;
        int32_t country = -1;
        // `country` is retained as the source-country compatibility field.
        int32_t source_country = -1;
        int32_t destination_country = -1;
        uint64_t source_country_handle = 0;
        uint64_t destination_country_handle = 0;
        int32_t route_cost = 0;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        int64_t quantity = 0;
        int64_t expected_profit = 0;
        int64_t base_value = 0;
        int64_t retail_value = 0;
        int64_t import_transfer = 0;
        int64_t export_transfer = 0;
        int64_t transaction_transfer = 0;
        int64_t capacity_work = 0;
        int64_t density_q16 = 0;
        int32_t signal_age_days = 0;
        int32_t response_priority = 0;
        uint32_t source_price_stock_generation = 0;
        uint32_t destination_price_stock_generation = 0;
        int64_t planned_day = -1;
        uint64_t topology_generation = 0;
        uint64_t country_topology_hash = 0;
        uint8_t flags = 0;
    };

    enum TradeLineFlags : uint8_t {
        TRADE_LINE_FOREIGN = 1U << 0,
        TRADE_LINE_RELIEF = 1U << 1,
        TRADE_LINE_IMPORT_SUBSIDY = 1U << 2,
        TRADE_LINE_EXPORT_SUBSIDY = 1U << 3,
        TRADE_LINE_IMPORT_TAX = 1U << 4,
        TRADE_LINE_EXPORT_TAX = 1U << 5,
    };

    struct TradeQuote {
        int64_t base = 0;
        int64_t retail = 0;
        int64_t import_transfer = 0;
        int64_t export_transfer = 0;
        int64_t transaction_transfer = 0;
        int64_t importer_outlay = 0;
        int64_t exporter_receipt = 0;
        int64_t importer_profit = 0;
        int64_t combined_profit = 0;
        int64_t margin_q16 = 0;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        bool foreign = false;
        bool relief = false;
    };

    struct TradePlanStore {
        enum Phase : int32_t { IDLE = 0, SCAN = 1, ROUTE = 2 };
        int32_t phase = IDLE;
        int64_t scan_cursor = 0;
        int32_t route_cursor = 0;
        int64_t scan_total = 0;
        std::vector<int32_t> scan_cells;
        std::vector<int32_t> scan_goods;
        std::vector<int64_t> scan_inbound;
        uint64_t country_topology_hash = 0;
        uint64_t topology_generation = 0;
        std::vector<TradeSignal> sources;
        std::vector<TradeSignal> destinations;
        std::vector<TradeCandidate> working_candidates;
        std::vector<TradeCandidate> ready_candidates;
        // Rebuildable one-batch retry queue for nominally viable routes that
        // emitted a tariff subsidy intent. It is deliberately not persisted or
        // hashed; dispatch revalidates every endpoint, price and resource bound.
        std::vector<TradeCandidate> deferred_subsidy_candidates;
        std::vector<int64_t> distance;
        std::vector<uint32_t> distance_stamp;
        std::vector<int32_t> target_signal;
        std::vector<uint32_t> target_stamp;
        std::vector<std::pair<int64_t, int32_t>> heap;
        uint32_t search_stamp = 0;
        std::vector<uint64_t> route_cache_keys;
        std::vector<int32_t> route_cache_costs;
        uint64_t route_cache_country_topology_hash = 0;
        uint64_t route_cache_topology_generation = 0;
        bool route_search_active = false;
        int32_t route_search_source = -1;
        int32_t route_search_accepted = 0;
        int32_t route_search_pending_targets = 0;
        int32_t route_search_expansions = 0;
        int64_t completed_scans = 0;

        void clear_transient() {
            phase = IDLE;
            scan_cursor = 0;
            route_cursor = 0;
            scan_total = 0;
            scan_cells.clear();
            scan_goods.clear();
            scan_inbound.clear();
            sources.clear();
            destinations.clear();
            working_candidates.clear();
            ready_candidates.clear();
            deferred_subsidy_candidates.clear();
            distance.clear();
            distance_stamp.clear();
            target_signal.clear();
            target_stamp.clear();
            heap.clear();
            route_cache_keys.clear();
            route_cache_costs.clear();
            route_cache_country_topology_hash = 0;
            route_cache_topology_generation = 0;
            route_search_active = false;
            route_search_source = -1;
            route_search_accepted = 0;
            route_search_pending_targets = 0;
            route_search_expansions = 0;
            search_stamp = 0;
            completed_scans = 0;
            country_topology_hash = 0;
            topology_generation = 0;
        }
    };

    // Sole live trade/family storage accessors (see sync/flush helpers above).
    // A+Y N3/N4: these alias RuntimeEconomyOwnedState while a formula state is
    // bound; `_trade_orders_local` / `_families_local` are the unbound fallback.
    TradeOrderStore &trade_orders_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_trade_orders
                                         : _trade_orders_local;
    }
    const TradeOrderStore &trade_orders_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_trade_orders
                                         : _trade_orders_local;
    }
    FamilyStore &families_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_families
                                         : _families_local;
    }
    const FamilyStore &families_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->live_families
                                         : _families_local;
    }

    // A+Y N5: the notable-family side tables follow the same rule. Every
    // authoritative person/membership/ownership/expedition/influence/trait/
    // need row lives on RuntimeEconomyOwnedState while a formula state is
    // bound; the `_*_local` members are the unbound fallback only.
    //
    // Derived CSR rebuild caches (_family_member_offsets,
    // _person_family_offsets, _person_need_offsets, _family_cell_offsets,
    // _family_expedition_target_index, _family_expedition_due_heap, ...) are
    // deliberately NOT moved: they are recomputed from the tables below at
    // FAMILY_COMMIT / PERSON_COMMIT and after a structural restore, so they
    // carry no authority and stay NER-local across bind/unbind.
#define PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(type, name, owned, local)       \
    type &name() noexcept {                                                   \
        return _formula_owned != nullptr ? _formula_owned->owned : local;     \
    }                                                                         \
    const type &name() const noexcept {                                       \
        return _formula_owned != nullptr ? _formula_owned->owned : local;     \
    }

    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(NotablePersonStore, persons_store,
                                          live_persons, _persons_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyMembershipEdge>,
                                          family_memberships, live_memberships,
                                          _family_memberships_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyBuildingOwnership>,
                                          family_ownerships, live_ownerships,
                                          _family_ownerships_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(FamilyExpeditionStore,
                                          family_expeditions_store,
                                          live_expeditions,
                                          _family_expeditions_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyOwnedColumn<int32_t>,
                                          family_expedition_route_cells,
                                          live_expedition_route_cells,
                                          _family_expedition_route_cells_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyOwnedColumn<int32_t>,
                                          family_expedition_route_costs,
                                          live_expedition_route_costs,
                                          _family_expedition_route_costs_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyExpeditionPayload>,
                                          family_expedition_payloads,
                                          live_expedition_payloads,
                                          _family_expedition_payloads_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyOwnedColumn<uint64_t>,
                                          family_expedition_person_handles,
                                          live_expedition_person_handles,
                                          _family_expedition_person_handles_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyExpeditionCargoLine>,
                                          family_expedition_cargo,
                                          live_expedition_cargo,
                                          _family_expedition_cargo_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(
        EconomyTrackedRecords<FamilyExpeditionKitBuilding>,
        family_expedition_kit_buildings, live_expedition_kit_buildings,
        _family_expedition_kit_buildings_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(
        EconomyOwnedColumn<int32_t>, family_expedition_missing_good_ids,
        live_expedition_missing_good_ids,
        _family_expedition_missing_good_ids_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(
        EconomyOwnedColumn<int64_t>, family_expedition_missing_good_quantities,
        live_expedition_missing_good_quantities,
        _family_expedition_missing_good_quantities_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(FamilyCellInfluenceStore,
                                          family_influences, live_influences,
                                          _family_influences_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<FamilyTraitRoll>,
                                          family_trait_rolls, live_traits,
                                          _family_traits_local)
    PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR(EconomyTrackedRecords<PersonNeedState>,
                                          person_needs, live_person_needs,
                                          _person_needs_local)

#undef PK_ECONOMY_FAMILY_SIDE_TABLE_ACCESSOR

    struct TradeFlowSignalStore {
        EconomyOwnedColumn<int32_t> cells{{{20, 1}, "TradeFlowSignalStore.cells", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> goods{{{20, 2}, "TradeFlowSignalStore.goods", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int64_t> import_ema{{{20, 3}, "TradeFlowSignalStore.import_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_ema{{{20, 4}, "TradeFlowSignalStore.export_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> period_import{{{20, 5}, "TradeFlowSignalStore.period_import", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> period_export{{{20, 6}, "TradeFlowSignalStore.period_export", EconomyFieldEncoding::I64, 8}};

        void clear() {
            cells.clear(); goods.clear(); import_ema.clear(); export_ema.clear();
            period_import.clear(); period_export.clear();
        }
    };

    struct CountryGoodTradeAggregateStore {
        EconomyOwnedColumn<int32_t> countries{{{21, 1}, "CountryGoodTradeAggregateStore.countries", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> goods{{{21, 2}, "CountryGoodTradeAggregateStore.goods", EconomyFieldEncoding::I32, 4}};
        // Cumulative authority.
        EconomyOwnedColumn<int64_t> import_quantity{{{21, 3}, "CountryGoodTradeAggregateStore.import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_quantity{{{21, 4}, "CountryGoodTradeAggregateStore.export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> import_base{{{21, 5}, "CountryGoodTradeAggregateStore.import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_base{{{21, 6}, "CountryGoodTradeAggregateStore.export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> import_tariff{{{21, 7}, "CountryGoodTradeAggregateStore.import_tariff", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_tariff{{{21, 8}, "CountryGoodTradeAggregateStore.export_tariff", EconomyFieldEncoding::I64, 8}};
        // Latest touched epoch. Query treats rows from an older epoch as a
        // lazy-zero previous batch while retaining the cumulative columns.
        EconomyOwnedColumn<int64_t> batch_epoch{{{21, 9}, "CountryGoodTradeAggregateStore.batch_epoch", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_quantity{{{21, 10}, "CountryGoodTradeAggregateStore.batch_import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_quantity{{{21, 11}, "CountryGoodTradeAggregateStore.batch_export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_base{{{21, 12}, "CountryGoodTradeAggregateStore.batch_import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_base{{{21, 13}, "CountryGoodTradeAggregateStore.batch_export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_tariff{{{21, 14}, "CountryGoodTradeAggregateStore.batch_import_tariff", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_tariff{{{21, 15}, "CountryGoodTradeAggregateStore.batch_export_tariff", EconomyFieldEncoding::I64, 8}};
        void clear() {
            countries.clear(); goods.clear(); import_quantity.clear();
            export_quantity.clear(); import_base.clear(); export_base.clear();
            import_tariff.clear(); export_tariff.clear();
            batch_epoch.clear(); batch_import_quantity.clear();
            batch_export_quantity.clear(); batch_import_base.clear();
            batch_export_base.clear(); batch_import_tariff.clear();
            batch_export_tariff.clear();
        }
    };

    struct CountryPartnerTradeAggregateStore {
        EconomyOwnedColumn<int32_t> countries{{{22, 1}, "CountryPartnerTradeAggregateStore.countries", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> partners{{{22, 2}, "CountryPartnerTradeAggregateStore.partners", EconomyFieldEncoding::I32, 4}};
        // Cumulative authority.
        EconomyOwnedColumn<int64_t> import_quantity{{{22, 3}, "CountryPartnerTradeAggregateStore.import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_quantity{{{22, 4}, "CountryPartnerTradeAggregateStore.export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> import_base{{{22, 5}, "CountryPartnerTradeAggregateStore.import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> export_base{{{22, 6}, "CountryPartnerTradeAggregateStore.export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> order_count{{{22, 7}, "CountryPartnerTradeAggregateStore.order_count", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_epoch{{{22, 8}, "CountryPartnerTradeAggregateStore.batch_epoch", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_quantity{{{22, 9}, "CountryPartnerTradeAggregateStore.batch_import_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_quantity{{{22, 10}, "CountryPartnerTradeAggregateStore.batch_export_quantity", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_import_base{{{22, 11}, "CountryPartnerTradeAggregateStore.batch_import_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_export_base{{{22, 12}, "CountryPartnerTradeAggregateStore.batch_export_base", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> batch_order_count{{{22, 13}, "CountryPartnerTradeAggregateStore.batch_order_count", EconomyFieldEncoding::I64, 8}};
        void clear() {
            countries.clear(); partners.clear(); import_quantity.clear();
            export_quantity.clear(); import_base.clear(); export_base.clear();
            order_count.clear();
            batch_epoch.clear(); batch_import_quantity.clear();
            batch_export_quantity.clear(); batch_import_base.clear();
            batch_export_base.clear(); batch_order_count.clear();
        }
    };

    struct TariffHistoryStore {
        EconomyOwnedColumn<int32_t> countries{{{23, 1}, "TariffHistoryStore.countries", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> kinds{{{23, 2}, "TariffHistoryStore.kinds", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int64_t> bases{{{23, 3}, "TariffHistoryStore.bases", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> assessed{{{23, 4}, "TariffHistoryStore.assessed", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> collected{{{23, 5}, "TariffHistoryStore.collected", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> requests{{{23, 6}, "TariffHistoryStore.requests", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> reserved{{{23, 7}, "TariffHistoryStore.reserved", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> paid{{{23, 8}, "TariffHistoryStore.paid", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_bases{{{23, 9}, "TariffHistoryStore.cumulative_bases", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_collected{{{23, 10}, "TariffHistoryStore.cumulative_collected", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_requests{{{23, 11}, "TariffHistoryStore.cumulative_requests", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> cumulative_paid{{{23, 12}, "TariffHistoryStore.cumulative_paid", EconomyFieldEncoding::I64, 8}};
        void clear() {
            countries.clear(); kinds.clear(); bases.clear(); assessed.clear();
            collected.clear(); requests.clear(); reserved.clear(); paid.clear();
            cumulative_bases.clear(); cumulative_collected.clear();
            cumulative_requests.clear(); cumulative_paid.clear();
        }
    };

    struct LaborMarketStore {
        EconomyOwnedColumn<int32_t> cell_offsets{{{19, 1}, "LaborMarketStore.cell_offsets", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int32_t> profession_ids{{{19, 2}, "LaborMarketStore.profession_ids", EconomyFieldEncoding::I32, 4}};
        EconomyOwnedColumn<int64_t> base_living_cost{{{19, 3}, "LaborMarketStore.base_living_cost", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> role_living_cost{{{19, 4}, "LaborMarketStore.role_living_cost", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> contract_wage_ema{{{19, 5}, "LaborMarketStore.contract_wage_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> paid_wage_ema{{{19, 6}, "LaborMarketStore.paid_wage_ema", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int64_t> job_days{{{19, 7}, "LaborMarketStore.job_days", EconomyFieldEncoding::I64, 8}};
        EconomyOwnedColumn<int32_t> pay_ratio_q16{{{19, 8}, "LaborMarketStore.pay_ratio_q16", EconomyFieldEncoding::I32, 4}};

        void clear(int32_t cells) {
            cell_offsets.assign(static_cast<size_t>(std::max(0, cells)) + 1, 0);
            profession_ids.clear();
            base_living_cost.clear();
            role_living_cost.clear();
            contract_wage_ema.clear();
            paid_wage_ema.clear();
            job_days.clear();
            pay_ratio_q16.clear();
        }
    };
