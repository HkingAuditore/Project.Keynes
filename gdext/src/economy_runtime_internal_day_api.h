// Day advancement, stage controls, and settled performance reporting interface.

    godot::Dictionary run_slice(const godot::Dictionary &ctx);
    godot::Dictionary run_slice_compact(const godot::Dictionary &ctx);
    // Sparse-workset / continuation probe. Diagnostic only: pure reads of
    // epoch-scoped counters, no settlement decision depends on it.
    void write_workset_probe_report(godot::Dictionary &out) const;
    godot::Dictionary probe_report() const;
    void note_boundary_phase_ms(int32_t phase, double ms);
    void note_probe_slice(const godot::Dictionary &slice_result);
    // Worker ACTIVE production: one compact ECONOMY_GRAPH slice on the existing
    // formula owner (no second formula set). Returns false on fatal/ledger error.
    // When non-null, *done is set from the slice result (epoch idle for the day).
    // pending_input=true means same-day env/building context is not yet captured
    // on the main thread; returns true (not fatal) with *done=false so Host can
    // park the ECONOMY stage without soft-completing.
    bool worker_run_compact_slice(int64_t day_index, std::string &error,
                                  bool *done = nullptr,
                                  bool *pending_input = nullptr);
    // Published by the worker into the perf snapshot. Epoch counters reset in
    // clear_epoch_metrics; masks are the frozen epoch tax masks.
    struct TaxSchedDiag {
        double epoch_fiscal_ms = 0.0;
        double fiscal_settlement_ms = 0.0;
        double income_subsidy_ms = 0.0;
        uint8_t negative_tax_mask = 0;
        uint8_t active_tax_mask = 0;
    };
    void copy_tax_sched_diag(TaxSchedDiag &out, char *stage, size_t stage_cap,
                             char *substage, size_t substage_cap) const;
    // Phase-2.4.4.1: StageOps epoch-open prelude (peer/fiscal/trade/start_epoch).
    // Mirrors compact idle-open semantics without entering graph stages.
    bool run_epoch_open_prelude_drain(int64_t day_index, int64_t &work_done,
                                      std::string &error,
                                      bool *pending_input = nullptr,
                                      bool *idle_done = nullptr);
    // Phase-2.4.5: sync StageOps mutate day (prelude + all graph stage drains).
    bool run_stage_ops_day(int64_t day_index, std::string &error);
    bool stage_ops_epoch_open_ready() const noexcept { return _epoch_active; }
    uint32_t next_stage_ops_stage_index() const noexcept;
    bool capture_worker_day_input(const RuntimeEconomyDayInput &input,
                                  std::string &error);
    bool capture_environment(int64_t day_index, const float *temperature,
                             const float *temperature_30d, const float *moisture,
                             const float *plant_available_water,
                             const float *precipitation,
                             const float *snow_cover,
                             const float *weather_intensity,
                             const float *temperature_365d,
                             const uint8_t *weather_type,
                             const uint8_t *cover, int32_t count,
                             std::string &error);
    bool needs_environment_capture(int64_t day_index) const {
        return !_epoch_active && day_index > _last_committed_day &&
               _environment_day != day_index;
    }
    bool epoch_active() const { return _epoch_active; }
    // Committed-day identity used by the day-end Owned mirror publish. This is
    // the same day `capture_committed_ledger_state` stamps on the ledger.
    int64_t current_day() const { return _current_day; }
    int64_t last_committed_day() const { return _last_committed_day; }
    bool should_run(int64_t day_index) const;
    bool deadline_critical(int64_t day_index) const;
    // Mutable peer-domain watermark.  `_epoch_id` identifies an Economy
    // epoch; this value identifies the latest committed aggregate state.
    uint64_t committed_generation() const { return _committed_generation; }
    void take_bio_introduces(std::vector<int32_t> &cells,
                            std::vector<int32_t> &bits);
    godot::PackedInt32Array economy_live_cells_query();
    godot::Dictionary report() const;
    godot::Dictionary committed_audit_report() const;
    // Test-only previous-cycle wall time. Negative values clear the override.
    // Injected milliseconds participate in N/P/I selection only; they never enter
    // the authoritative state hash or PKEC. The third argument is optional; a
    // negative value reuses the plan-cycle milliseconds for investment knives.
    godot::Dictionary inject_cadence_timing(double market_cycle_ms,
                                            double plan_cycle_ms,
                                            double investment_cycle_ms = -1.0);
    godot::Dictionary population_cell_summary(int32_t cell_idx) const;
    godot::Dictionary named_settlement_snapshot() const;
    godot::Dictionary settlement_delta(int64_t since_revision) const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx) const;
    godot::Dictionary population_cell_snapshot(
        int32_t cell_idx, bool include_details) const;
    godot::Dictionary population_cell_snapshot(int32_t cell_idx,
                                                float temperature,
                                                float moisture,
                                                float snow_cover,
                                                float weather_intensity,
                                                bool environment_ready) const;
    godot::Dictionary market_cell_snapshot(int32_t cell_idx) const;
    // Read-only bounded order page. `good_index` >= 0 keeps only orders that
    // carry that good line and emits only its lines; -1 keeps every line.
    // Rows are stably ordered by (arrival_day, order id) before paging.
    godot::Dictionary trade_orders_for_cell(int32_t cell_idx, int32_t offset,
                                             int32_t limit,
                                             int32_t good_index = -1) const;
    godot::Dictionary country_trade_snapshot(int64_t country_handle,
                                              const godot::String &view,
                                              int32_t offset, int32_t limit) const;
    godot::Dictionary building_cell_snapshot(int32_t cell_idx) const;
    // Read-only country economy rollup over the frozen epoch territory. Views:
    // summary / professions / buildings / goods / investment / settlements.
    // scope_cell < 0 aggregates the whole territory; filter_id narrows the
    // buildings view to one economic sector. Never simulation input.
    godot::Dictionary country_economy_overview(int64_t country_handle,
                                               const godot::String &view,
                                               int32_t scope_cell,
                                               int32_t filter_id,
                                               int32_t offset,
                                               int32_t limit) const;
    // Bounded committed projection for automatic, near-map situation icons.
    // No economy state is copied into MapData or the save schema.
    godot::Dictionary cell_situation_snapshot(
        const godot::PackedInt32Array &requested_cells) const;
