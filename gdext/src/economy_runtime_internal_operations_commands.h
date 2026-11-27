// Command handling, event ingress, and pending construction and expedition operations.

    void build_water_portal_graph(int32_t graph_index);
    void build_water_component_layers();
    bool reconstruct_water_corridor(int32_t from_portal, int32_t to_portal,
                                    uint8_t cap,
                                    std::vector<int32_t> &water_cells) const;
    void fill_trade_water_columns(const uint8_t *terrain, const uint8_t *landform,
                                  const uint8_t *has_river, int32_t count,
                                  std::vector<uint8_t> &water_class,
                                  std::vector<uint8_t> &river) const;
    bool append_colonization_route_step(int32_t from_cell, int32_t to_cell,
                                        uint8_t cap, int64_t reverse_from,
                                        int64_t reverse_to,
                                        std::vector<int32_t> &route,
                                        std::vector<int32_t> &cumulative,
                                        int64_t &running) const;
    static uint64_t trade_route_cache_key(int32_t source, int32_t destination,
                                          int32_t layer);
    int32_t estimate_trade_price(int32_t market, int32_t good,
                                 int64_t stock_after, int64_t &sat) const;
    int64_t trade_relief_pressure_q16(int32_t market, int32_t good,
                                      int64_t &sat) const;
    int64_t trade_local_stock_target(int32_t market, int32_t good,
                                     int64_t &sat) const;
    int64_t trade_export_floor(int32_t market, int32_t good,
                               int64_t &sat) const;
    int64_t profitable_trade_quantity(int32_t source, int32_t destination,
                                      int32_t good, int64_t max_quantity,
                                      bool relief_route, int32_t &source_price,
                                      int32_t &destination_price,
                                      int64_t &profit, int64_t &margin_q16,
                                      int64_t &sat) const;
    TradeQuote make_trade_quote(int32_t source, int32_t destination,
                                int32_t good, int64_t quantity,
                                int32_t source_price,
                                int32_t destination_price,
                                bool relief_route,
                                int64_t &saturation_count) const;
    int64_t merchant_inventory_target(int32_t market, int32_t good,
                                      int32_t signal_index,
                                      int64_t realized_withdrawal,
                                      int64_t export_ema,
                                      int64_t cold_start_daily_supply,
                                      int64_t &sat) const;
    int64_t merchant_procurement_quota(int32_t market, int32_t good,
                                       int32_t signal_index,
                                       int64_t sellable,
                                       int64_t target,
                                       int64_t stock,
                                       int64_t realized_withdrawal,
                                       int64_t export_ema,
                                       int64_t &sat) const;
    int32_t effective_merchant_buy_factor_q16(
        int32_t market, int32_t good, int64_t target, int64_t stock,
        int64_t &sat) const;
    bool settle_due_trade_orders(std::string &error);
    bool dispatch_trade_candidates(std::string &error);
    void update_trade_flow_ema();
    int32_t trade_flow_index(int32_t cell, int32_t good, bool create);
    int32_t trade_signal_clock_index(int32_t cell, int32_t good) const;
    int32_t ensure_trade_signal_clock_index(int32_t cell, int32_t good);
    void ensure_trade_signal_clock_keys_bulk(
        const std::vector<uint64_t> &sorted_unique_keys);
    void record_trade_signal_attempt(int32_t cell, int32_t good, int32_t reason);
    void refresh_trade_response_diagnostics();
    int64_t credit_trade_sellers(int32_t order_index, int64_t amount,
                                 int32_t cashflow_source = CASHFLOW_MERCHANT_BUSINESS);
    int64_t debit_trade_sellers(int32_t order_index, int64_t amount,
                                int32_t cashflow_source);
    void rebuild_trade_arrival_buckets();
    void compact_trade_orders(const std::vector<uint8_t> &remove);
    void rebuild_country_trade_indices();
    void sort_dirty_country_trade_display_indices();
    int64_t trade_transit_goods() const;
    int64_t trade_escrow_cash() const;
    bool apply_command(const Command &cmd, std::string &error);
    Command command_from_pod(const RuntimeEconomyPodCommand &pod) const;
    bool validate_command_pod(const Command &cmd, std::string &error) const;
    bool family_ledger_command_preflight(const Command &cmd) const;
    bool family_split_policy_command_preflight(const Command &cmd) const;
    bool apply_family_free_building_reward(const Command &cmd,
                                           std::string &error);
    bool apply_family_population_reward(const Command &cmd,
                                        std::string &error);
    bool apply_family_absorb_anonymous(const Command &cmd,
                                       std::string &error);
    bool apply_family_purchase_discount(const Command &cmd,
                                        std::string &error);
    bool apply_family_set_split_policy(const Command &cmd,
                                       std::string &error);
    bool process_market_cell(int32_t market, MarketResult &result, std::string &error);
    bool commit_structural(const StructuralCommand &cmd, std::string &error);
    // BEGIN army personnel lane (contract §1.2/§1.3).
    bool apply_army_lane_command(const Command &cmd, std::string &error,
                                 int64_t &settled);
    // Army pay's treasury debit when Country is worker-authoritative (army-pay
    // contract §1.1). The synchronous fiscal escrow (`military_collect_cash`) is
    // refused there, so this drives the same Country economy-asset peer the cohort
    // cash lane uses — prepare, service, finish — synchronously on the worker
    // thread inside one epoch. That is what keeps the treasury debit and the lane
    // credit in the SAME audit window; deferring to the enqueue-only route instead
    // splits them and closes the epoch with money_conservation_failed.
    // `moved` is what Country actually committed (<= requested).
    bool pay_army_lane_from_worker_country(uint64_t army_handle, int64_t country_handle,
                                           int64_t requested, int64_t &moved,
                                           std::string &error);
    // Cohort side of 30/31. Inside an epoch the record joins the structural
    // stage that still runs later in this same epoch; between epochs (the POD
    // drain at a committed day boundary) that day's structural stage has already
    // run, so the same record is committed through the same structural path
    // immediately — queueing there would delay a D+1 batch by a whole epoch and
    // the lane would not be visible to the D+1 read.
    bool queue_or_commit_army_lane(const StructuralCommand &record,
                                   std::string &error, int64_t &moved);
    // `moved_out` reports the heads that actually crossed (a no-op reports 0).
    bool commit_structural_army_lane(const StructuralCommand &cmd,
                                     std::string &error,
                                     int64_t *moved_out = nullptr);
    int64_t army_lane_country_handle(int32_t cell) const;
    void run_army_personnel_consumption(int32_t market, MarketResult &result);
    void sum_army_personnel_holdings(int64_t &population, int64_t &funds,
                                     int64_t &saturation_count) const;
    // END army personnel lane
    // Core cohort migration primitive extracted from commit_structural. Moves up
    // to `requested_pop` people from `source` into the (dest_cell, dest_signature)
    // cohort, carrying a proportional share of funds/income/expense/ema/residual,
    // population-weighting needs_satisfaction, and transferring any rounding
    // residue of a fully-drained source to the treasury (never burned). Pushes
    // both cells onto _structural_touched_cells and appends a structural trace.
    // Callers are responsible for command-level guards (profession_available,
    // same-cell/same-signature no-op) before invoking it. Returns false only on a
    // hard failure (allocation / treasury transfer); an empty move is a no-op true.
    //
    // `source_drained_out` (optional): set to true when the move emptied `source`
    // and released its slot, false otherwise. The employment pass (in-line layoff
    // / hiring) iterates a *snapshot* of a cell's slots -- it must never migrate
    // from inside for_each_in_cell -- and uses this flag to skip a snapshot slot
    // that a prior migration in the same loop already released, preventing
    // stale-slot reuse. When null it is ignored (commit_structural path).
    bool move_cohort_population(int32_t source, int32_t dest_cell,
                                int32_t dest_signature, int64_t requested_pop,
                                std::string &error,
                                bool *source_drained_out = nullptr,
                                uint64_t preferred_family_handle = 0,
                                bool preferred_family_strict = false);
    // Cash that a move of `moved_population` from `source_slot` carries on the
    // live state, resolved through the same rule the write applies
    // (economy_cohort_move_cash.h cohort_move_cash). Fills _family_move_plan as
    // a dry run and mutates no persisted column, so a caller can preflight a
    // transfer before writing. `will_drain_out` reports whether the move will
    // empty the source cohort.
    int64_t plan_cohort_move_cash(int32_t source_slot, int32_t destination_cell,
                                  int64_t moved_population,
                                  uint64_t preferred_family_handle,
                                  bool preferred_family_strict,
                                  bool *will_drain_out = nullptr);
    bool apply_start_family_expedition(const Command &cmd, std::string &error,
        const uint8_t *visible = nullptr, int32_t visible_count = 0, uint64_t kit_identity = 0);
    bool apply_cancel_family_expedition(const Command &cmd,
                                        std::string &error);
    bool apply_settle_family_expedition(const Command &cmd,
                                        std::string &error);
    bool extract_family_expedition_payload(int32_t expedition,
                                           int64_t requested,
                                           std::string &error);
    bool extract_family_expedition_anonymous_lanes(int32_t expedition,
                                                   std::string &error);
    void clip_cell_employment_and_defer_reconcile(int32_t cell);
    bool preparing_kit_launchable(const ColonizationKitPlan &kit,
                                  int64_t people) const;
    void unwind_family_expedition_payload_extract(int32_t expedition);
    bool extract_family_expedition_cargo(int32_t expedition,
                                         const ColonizationKitPlan &kit,
                                         std::string &error);
    bool restore_family_expedition_cargo(int32_t expedition,
                                         int32_t destination_cell,
                                         bool consume_construction,
                                         std::string &error);
    bool restore_family_expedition_payload(int32_t expedition,
                                            int32_t destination_cell,
                                            std::string &error);
    bool settle_family_expedition_kit(int32_t expedition,
                                      int32_t destination_cell,
                                      std::string &error);
    bool finalize_immediate_family_expedition_settlement(
        int32_t destination_cell, std::string &error);
    void release_family_expedition_reservations(int32_t expedition);
    bool process_due_family_expeditions(int64_t day, std::string &error);
    int64_t family_expedition_displayed_population(int32_t expedition) const;
    int64_t market_stock(int32_t cell, int32_t good_id) const;
    bool colonization_good_is_tools(int32_t good_id) const;
    uint64_t hash_preparing_missing_stock(int32_t source_cell,
                                          const int32_t *good_ids,
                                          uint32_t count) const;
    void store_preparing_missing_goods(int32_t expedition,
                                       const ColonizationKitPlan &kit);
    void refresh_preparing_family_expedition_missing(int32_t expedition);
    void abort_preparing_family_expedition(int32_t expedition, int64_t day,
                                           uint8_t kind, const char *code, int64_t sequence = 0);
    bool launch_preparing_family_expedition(int32_t expedition, int64_t day,
                                            const ColonizationKitPlan &kit,
                                            std::string &error);
    bool advance_preparing_family_expedition(int32_t expedition, int64_t day,
                                             std::string &error);
    bool family_expedition_settle_inflight(uint64_t expedition_handle) const;
    void recover_lost_family_settlement_commands();
    bool stage_allows_in_epoch_family_settlement() const;
    void queue_family_settlement_command(const Command &command);
    void rebuild_family_expedition_indices();
    void push_family_expedition_due(int32_t expedition);
    void append_colonization_receipt(int32_t expedition, int64_t sequence,
                                     int64_t effective_day, int64_t settled_day,
                                     uint8_t kind, const char *code);
    void append_colonization_command_receipt(uint64_t country_handle,
                                             uint64_t expedition_handle,
                                             int32_t target_cell,
                                             int64_t sequence,
                                             int64_t effective_day,
                                             int64_t settled_day,
                                             uint8_t kind, const char *code);
    bool pending_family_expedition_target_taken(uint64_t country_handle, int32_t target_cell) const;
    bool apply_family_expedition_player_command(const Command &cmd,
                                                std::string &error);
    bool apply_queued_family_expedition_start(const Command &cmd, std::string &error);
    int64_t family_population_in_cell(uint64_t family_handle,
                                      int32_t cell) const;
    int64_t family_dispatchable_population_in_cell(uint64_t family_handle,
        int32_t cell) const;
    // Unaffiliated (no family membership edge) people in a cell. A family-less
    // settler party moves exactly these people; they never become family members.
    int64_t anonymous_population_in_cell(int32_t cell) const;
    int64_t anonymous_dispatchable_in_cell(int32_t cell) const;
    bool colonization_target_owner_allowed(uint64_t country_handle,
                                           int32_t cell) const;
    bool colonization_destination_family_allowed(uint64_t family_handle,
                                                 int32_t cell) const;
    bool plan_family_colonization_route(uint64_t country_handle,
                                        int32_t source_cell,
                                        int32_t target_cell,
                                        const uint8_t *visible,
                                        int32_t visible_count,
                                        std::vector<int32_t> &route,
                                        std::vector<int32_t> &cumulative,
                                        int32_t &cost,
                                        std::string &error);
    uint64_t colonization_visibility_hash(const uint8_t *visible,
                                          int32_t count) const;
    uint64_t family_expedition_target_key(uint64_t country_handle,
                                          int32_t target_cell) const;
    bool cell_has_submitted_or_pending_buildings(int32_t cell) const;
    bool colonization_kit_type_eligible(int32_t source_cell, int32_t target_cell,
                                        int32_t type_id, bool frozen) const;
    int64_t colonization_kit_output_per_building(int32_t target_cell,
                                                 int32_t type_id,
                                                 int32_t good_id) const;
    int64_t colonization_kit_input_per_building(int32_t type_id,
                                                int32_t good_id) const;
    int64_t colonization_kit_daily_food_required(int32_t target_cell,
                                                 int64_t population) const;
    uint64_t hash_colonization_kit_plan(const ColonizationKitPlan &kit) const;
    void fill_colonization_kit_buffer(int32_t source_cell, int32_t target_cell,
                                      int64_t population, int32_t travel_days,
                                      ColonizationKitPlan &kit,
                                      const ColonizationReserveContext *reserve
                                          = nullptr,
                                      int32_t bridge_days_override = 0) const;
    void collect_family_expedition_reserved_stock(
        int32_t expedition, std::vector<int64_t> &reserved) const;
    bool reserve_preparing_family_expedition_cargo(
        int32_t expedition, ColonizationKitPlan &kit,
        std::string &error, int64_t day = -1);
    void note_family_expedition_procurement_rejection(
        int32_t expedition, int32_t good, uint8_t cargo_flags, int64_t day,
        const std::string &reason);
    bool advance_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &continuation,
        std::string &error);
    bool credit_family_expedition_procurement_merchants(
        FamilyExpeditionProcurementContinuation &continuation,
        std::string &error);
    bool settle_family_expedition_procurement_orphans(std::string &error);
    bool start_family_expedition_procurement(
        FamilyExpeditionProcurementContinuation &continuation,
        int32_t expedition, int32_t source_cell, int32_t market,
        int32_t good, uint8_t cargo_flags, int64_t quantity, int64_t cash,
        std::string &error);
    void add_colonization_kit_cargo(ColonizationKitPlan &kit, int32_t good_id,
                                    int64_t quantity, uint8_t flags,
                                    int64_t &sat) const;
    void sort_colonization_kit_cargo(ColonizationKitPlan &kit) const;
    bool plan_colonization_kit(int32_t source_cell, int32_t target_cell,
                               int64_t population, int32_t travel_days,
                               bool frozen, ColonizationKitPlan &kit,
                               bool ignore_existing = false,
                               const ColonizationReserveContext *reserve
                                   = nullptr) const;
