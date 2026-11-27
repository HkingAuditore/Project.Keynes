// Configuration, peer routing, ownership handoff, and input staging interface.

    // 只统计 (id & tag) 是否非零与 tagged 一致的请求号：主线程入口与日执行者各有一套号。
    uint64_t asset_peer_request_high_watermark(uint64_t tag, bool tagged) const noexcept;
    void attach_csv_recorder(EconomyCsvRecorder *recorder) { _csv_recorder = recorder; }
    void set_sync_writes_forbidden(bool forbidden) {
        _sync_writes_forbidden = forbidden;
    }
    bool sync_writes_forbidden() const { return _sync_writes_forbidden; }
    void set_d7_operation_gate_mask(uint32_t mask) {
        _d7_operation_gate_mask = mask;
    }
    uint32_t d7_operation_gate_mask() const { return _d7_operation_gate_mask; }
    // Opens all nine Country/Economy asset ops for peer completion. Non-fiscal
    // COUNTRY_PREPARED requests journal COMPLETED with prepared amounts; M2–M5
    // cohort/market ops also apply local SoA via apply_peer_asset_side_effects
    // (Country has already transferred treasury value on its commit path).
    void open_all_d7_operation_gates() {
        _d7_operation_gate_mask = RUNTIME_ECONOMY_D7_ALL_GATE_MASK;
    }
    // Country unique-writer still needs treasury technology-point purchase even
    // when Economy remains sync (fiscal-only default mask). Research is the
    // minimum non-fiscal op required for government procurement to resume.
    void open_research_purchase_d7_gate() {
        _d7_operation_gate_mask |=
            (1u << static_cast<uint32_t>(
                RuntimeEconomyAssetOperation::RESEARCH_PURCHASE));
    }
    // Country ACTIVE + Economy sync still needs the two legs used by local
    // expedition procurement: market -> Country treasury, then treasury ->
    // expedition cargo.  They are peer-routed through the Country worker;
    // leaving either gate closed parks PREPARING at 0% without a fatal.
    void open_country_market_purchase_d7_gates() {
        _d7_operation_gate_mask |=
            (1u << static_cast<uint32_t>(
                RuntimeEconomyAssetOperation::GOOD_FROM_MARKET)) |
            (1u << static_cast<uint32_t>(
                RuntimeEconomyAssetOperation::TREASURY_SPEND));
    }
    bool bind_soa_view(EconomySoAView &view, std::string &error);
    // Phase-5 A+Y: formula hot path mutates OwnedState population/market in
    // place. While bound, population_store()/market_store() alias OwnedState.
    bool bind_formula_owned_state(RuntimeEconomyOwnedState &owned,
                                  std::string &error);
    void unbind_formula_owned_state() noexcept;
    bool formula_owned_bound() const noexcept {
        return _formula_owned != nullptr;
    }
    RuntimeEconomyBuildingStore &buildings_store() noexcept {
        return _formula_owned != nullptr ? _formula_owned->buildings
                                         : _buildings_soa_local;
    }
    const RuntimeEconomyBuildingStore &buildings_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->buildings
                                         : _buildings_soa_local;
    }
    // Same lane as buildings_store(), reachable from const members. Only the
    // role/pending projections are refreshed through it; group columns stay
    // read-only for const callers.
    RuntimeEconomyBuildingStore &mutable_buildings_store() const noexcept {
        return _formula_owned != nullptr ? _formula_owned->buildings
                                         : _buildings_soa_local;
    }
    const char *formula_backing_tag() const noexcept {
        return _formula_owned != nullptr ? "owned_state" : "ner_local";
    }
    std::unique_ptr<EconomyGraphStageOps> make_graph_stage_ops(bool mutate);
    // POD command path: maps RuntimeEconomyPodCommand → apply_command.
    // Sync submit_commands remains the facade; do not double-submit the same
    // request through both POD commit and sync enqueue.
    bool apply_pod_command(const RuntimeEconomyPodCommand &pod,
                           std::string &error);
    bool enqueue_or_apply_pod_command(const RuntimeEconomyPodCommand &pod,
                                      std::string &error);
    // Phase-2.6.3: copy OwnedState columns into production NER after a
    // POD-first command, coordinate country peers, and recapture mirrors.
    bool pull_owned_command_result(RuntimeEconomyOwnedState &owned,
                                   const RuntimeEconomyPodCommand &command,
                                   int64_t settled, std::string &error);
    // Legacy narrow pull for mint/burn/stock tests.
    bool pull_owned_core_columns(const RuntimeEconomyOwnedState &owned,
                                 int32_t opcode, int64_t settled,
                                 std::string &error);
    void fill_economy_audit_snapshot(int64_t &pop_err, int64_t &money_err,
                                     int64_t &goods_err,
                                     uint32_t &dirty_family_mask,
                                     int64_t &changed_cells,
                                     int64_t &changed_cohorts) const;
    void fill_economy_business_summary(int64_t &summary_population,
                                       int64_t &summary_funds,
                                       int32_t &summary_markets,
                                       int32_t &summary_buildings,
                                       int32_t &summary_cohorts,
                                       int32_t &summary_families) const;
    // Copies only committed ledger columns. This is a cold publish-boundary
    // handoff for POD parity; it is never used while an epoch is mutable.
    // `compute_ledger_hash=false` leaves ledger_hash 0; every reader of such a
    // ledger must hash on demand.
    void capture_committed_ledger_state(RuntimeEconomyLedgerState &out,
                                       uint64_t completed_stage_hash = 0,
                                       bool compute_ledger_hash = true) const;
    // Phase-4 layout unification: AoS→OwnedState SoA mirrors (capture path).
    void flush_formula_owned_domain_mirrors();
    // A+Y N2: refreshes the role/pending projections on the sole live group
    // lane, then copies it out when `out` is a different store.
    void sync_owned_building_store(RuntimeEconomyBuildingStore &out) const;
    void sync_owned_trade_escrow_store(RuntimeEconomyTradeEscrowStore &out) const;
    void sync_owned_family_store(RuntimeEconomyFamilyStore &out) const;
    void sync_owned_resource_store(RuntimeEconomyResourceStore &out) const;
    void fill_ledger_building_from_store(
        RuntimeEconomyBuildingCommittedBlock &block,
        const RuntimeEconomyBuildingStore &store) const;
    void fill_ledger_trade_escrow_from_store(
        RuntimeEconomyTradeEscrowCommittedBlock &block,
        const RuntimeEconomyTradeEscrowStore &store) const;
    void fill_ledger_family_from_store(
        RuntimeEconomyFamilyCommittedBlock &block,
        const RuntimeEconomyFamilyStore &store) const;
    void fill_ledger_resource_from_store(
        RuntimeEconomyResourceCommittedBlock &block,
        const RuntimeEconomyResourceStore &store) const;
    // Idle-day cursor identity. Capture and the Owned mirror flush share it so
    // a day-end export from OwnedState carries the same cursor block.
    void fill_ledger_epoch_cursor(
        RuntimeEconomyEpochCursorCommittedBlock &block) const;
    // Optional alias: publish/resource hot loops read stock lanes through
    // OwnedState when bound (see resource_stock_lanes()).
    void bind_resource_store(RuntimeEconomyResourceStore *store) noexcept {
        _resource_store_alias = store;
    }
    EconomyTrackedColumn<int64_t> &resource_stock_lanes() noexcept;
    const EconomyTrackedColumn<int64_t> &resource_stock_lanes() const noexcept;
    // A+Y N9: epoch harvest scratch follows the same alias rule as the stock
    // lanes — the bound store owns it, the NER locals are the unbound fallback.
    std::vector<int64_t> &resource_remaining_lanes() noexcept;
    const std::vector<int64_t> &resource_remaining_lanes() const noexcept;
    std::vector<int64_t> &resource_harvest_remaining_lanes() noexcept;
    const std::vector<int64_t> &resource_harvest_remaining_lanes() const noexcept;
    std::vector<int64_t> &resource_delta_lanes() noexcept;
    const std::vector<int64_t> &resource_delta_lanes() const noexcept;
    std::vector<uint32_t> &resource_lane_generation_lanes() noexcept;
    const std::vector<uint32_t> &resource_lane_generation_lanes() const noexcept;
    // Named-kernel household boundary: one post-building finalize chunk when
    // phase==1; otherwise ok hash boundary (settle stays on compact slice).
    bool kernel_run_household_market_boundary(
        EconomyStageCursor &cursor, const RuntimeEconomyEpochInput &input,
        EconomyStageResult &result, std::string &error);
    void attach_modifier_runtime(ModifierRuntime *runtime) { _modifier_runtime = runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) { _effect_runtime = runtime; }
    // M2b: the family path writes Effect instances one row at a time, so it has
    // to route through the same forwarder the declarative batch path uses.
    // Null keeps the pre-M2b behaviour of writing EffectRuntime directly.
    void attach_effect_forwarder(EffectInstanceForwarder *forwarder) {
        _effect_forwarder = forwarder;
    }
    void attach_trigger_runtime(TriggerRuntime *runtime) { _trigger_runtime = runtime; }
    bool valid_family_effect_entity_handle(uint64_t handle) const;
    // X9-b ideology family targeting. FAMILY_COMMIT owns both the family and
    // branch tables, so resolution stays on this side of the domain boundary.
    bool valid_family_effect_target_handle(uint64_t handle) const;
    void collect_family_effect_target_handles(int32_t country_slot,
        int32_t min_branches, int32_t cap,
        std::vector<uint64_t> &out_handles) const;
    // Worker fixtures use this to exercise the authored >=3 branch clause with
    // the one founder branch a headless world can create. It may only relax the
    // authored floor; 0 disables the override.
    void set_family_target_min_branches_override_for_test(int32_t min_branches);
    int32_t family_target_min_branches_for_test(int32_t authored_min) const {
        return _family_target_min_branches_override_for_test > 0
            ? std::min(authored_min,
                _family_target_min_branches_override_for_test)
            : authored_min;
    }
    void notify_era_milestone_activated(uint64_t country_handle);
    bool country_restore_allowed() const {
        return !_bootstrapped && !_save.active && !_restore.active;
    }
    bool country_save_allowed() const {
        return !_epoch_active && !_save.active && !_restore.active && !_fatal;
    }

    godot::Dictionary configure(const godot::Dictionary &catalog,
                                const godot::Dictionary &profile,
                                int32_t cell_count,
                                int64_t seed);
    godot::Dictionary bootstrap(const godot::Dictionary &population_packet,
                                const godot::Dictionary &market_packet);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
