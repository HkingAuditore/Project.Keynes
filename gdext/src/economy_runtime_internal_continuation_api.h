// Deferred checkpoint validation, archive stamps, and construction result helpers.

  public:
    // Verify the country identity the archive asked for against the LIVE Country
    // runtime. Called by the Host once the PKCN checkpoint has been installed.
    //
    // This is the other half of `_accept_stale_country_identity`: the apply step
    // defers the comparison because Country is not installed yet, and this performs it
    // at the first moment the answer means something. Without it, pairing A's Country
    // bytes with B's Economy bytes would load silently -- the exact corruption the
    // original check existed to catch.
    //
    // Returns true when there is nothing to verify (no deferred identity), so a caller
    // can call it unconditionally on any start path.
    bool verify_deferred_country_identity(std::string &error) const;

  private:
    mutable bool _forensics_allow_fatal_export = false;
    // Set only for the begin_save call inside an ECP2 rollback-backup capture.
    mutable bool _ecp2_rollback_backup_export = false;
    // Country identity written into the save header while the Host builds a
    // bundle under worker Country authority (see EconomyAuthorityTransfer::capture).
    bool _save_country_identity_override = false;
    uint64_t _save_country_generation = 0;
    uint64_t _save_country_state_hash = 0;
    // Stable reject code for the last failed restore/ECP2 apply (diagnostics).
    std::string _restore_rejected_reason;
    // Why the last `apply_ecp2_authority` ran WITHOUT a rollback backup.
    //
    // The backup is best-effort: a live state that cannot be captured (which is normal
    // during a load, where the economy bundle is applied before the POD mirror is
    // installed) must not make the restore impossible. Kept for diagnostics so "we
    // applied without a rollback point" is visible instead of silent.
    std::string _last_restore_backup_skipped_reason;

    bool trace_detail_for_cell(int32_t cell) const;
    void trace_record_cashflow(int32_t cell, uint64_t cohort_handle, int32_t source,
                               int64_t income, int64_t expense);
    void trace_reconcile_inspector_cashflows();
    void trace_begin_epoch();
    void trace_append(int32_t kind, int32_t stage, int32_t cell,
                      int32_t subject_kind, int64_t subject_id,
                      int32_t subject_i0, int32_t subject_i1,
                      int64_t value0, int64_t value1, int64_t value2,
                      int64_t value3, const std::vector<EventLeg> *legs = nullptr,
                      int32_t flags = 0);
    void trace_commit_epoch(int64_t population_error, int64_t money_error,
                            int64_t goods_error);
    void trace_abort_epoch();
    void trace_evict_to_budget();
    int64_t trace_memory_bytes() const;
    static uint64_t trace_hash_mix(uint64_t hash, uint64_t value);
    static thread_local ProductionResult *_production_result_sink;
    static thread_local MarketResult *_market_result_sink;
    // Non-null only while a market worker task is running; stage_cell_summary
    // appends here instead of the shared list. Null on every scalar path.
    static thread_local std::vector<int32_t> *_staging_touched_sink;

    bool apply_treasury_sponsored_build_command(const Command &cmd,
                                                 std::string &error);
    bool apply_treasury_sponsored_demolish_command(const Command &cmd,
                                                    std::string &error);
    bool apply_canal_build_command(const Command &cmd, std::string &error);
    bool process_due_canal_projects(int64_t day, std::string &error);
    bool plan_canal_route(uint64_t country_handle, int32_t start_cell,
                          int32_t end_cell,
                          const godot::PackedInt32Array &waypoints,
                          CanalQuote &quote, std::string &error) const;
    bool validate_canal_quote_snapshot(const CanalQuote &quote,
                                       std::string &error) const;
    godot::Dictionary canal_quote_dictionary(const CanalQuote &quote) const;
    void stage_canal_receipt(const Command &cmd, bool ok,
                             const char *code, uint64_t project_handle = 0,
                             int64_t cash_paid = 0,
                             int64_t treasury_goods_used = 0,
                             int64_t market_goods_used = 0);
    int32_t treasury_build_owner_signature(int32_t cell,
                                           int32_t type_id) const;
    void stage_construction_receipt(const Command &cmd, bool ok,
                                    const char *code, int64_t cash_paid = 0,
                                    int64_t treasury_goods_used = 0,
                                    int64_t market_goods_used = 0, const char *step = "economy");
