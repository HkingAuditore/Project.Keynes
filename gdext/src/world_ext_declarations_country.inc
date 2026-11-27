// Country bindings and runtime status queries.

    // ---- bindings: country ----
    godot::Dictionary capture_country_runtime_snapshot();
    // Per-country owned-cell counts from the CURRENT epoch snapshot, plus the
    // widest territory. Exists because the cell-layer migration's whole premise is
    // "a country's territory can exceed 32 cells", and no bridge exposed that, so
    // the premise could not be checked against a generated world. Read-only.
    godot::Dictionary get_country_territory_counts() const;
    // The ECONOMY-side territory plane, which is a different object from the
    // country runtime's table: `country_cell_count` reads `_epoch_cell_country`,
    // populated only by `capture_country_epoch`
    // (economy_runtime.cpp:4986). When that plane's size does not equal the cell
    // count the selector returns ZERO targets, which looks exactly like "the card
    // matched nothing" -- so a probe needs to see this number directly.
    godot::Dictionary get_economy_territory_plane() const;
    godot::Dictionary capture_country_pod_catalog();
    godot::Dictionary get_country_worker_protocol_status() const;
    godot::Dictionary get_country_worker_read_view(
            int64_t after_generation = 0) const;
    godot::Dictionary poll_country_worker_intent();
    godot::Dictionary get_country_economy_asset_protocol_status() const;
    godot::Dictionary poll_country_economy_asset_request();
    godot::Dictionary submit_country_economy_asset_result(
        const godot::Dictionary &result);
    bool runtime_country_host_economy_protocol_self_test() const;
    bool runtime_country_host_handoff_self_test() const;
    godot::Dictionary prepare_country_authority_handoff(int target_owner);
    godot::Dictionary install_country_authority_handoff();
    godot::Dictionary abort_country_authority_handoff();
    godot::Dictionary get_country_authority_handoff_status() const;
    bool runtime_country_host_rejection_self_test() const;
    // Main-thread transport service for the Country worker.  In SHADOW this
    // only replays a typed, side-effect-free ACK; ACTIVE must not use this
    // compatibility path until the peer transaction bridge is authoritative.
    godot::Dictionary service_country_worker_peer_adapter(
        int max_intents = 64, bool shadow_replay = true);
    godot::Dictionary configure_country_reference_trace(bool enabled,
                                                         int max_frames = 4096);
    godot::Dictionary poll_country_reference_trace(int64_t after_frame_id = 0,
                                                    int limit = 128) const;
    godot::Dictionary capture_country_reference_checkpoint() const;
    godot::Dictionary restore_country_runtime_checkpoint(
        const godot::PackedByteArray &canonical_pkcn);
    godot::Dictionary set_country_peer_async_mode(bool enabled);
    godot::Dictionary get_country_peer_protocol_status() const;
    godot::Dictionary poll_country_peer_intent();
    godot::Dictionary submit_country_peer_result(
        const godot::Dictionary &result);
    godot::Dictionary service_country_peer_adapter(int max_intents = 64);
    godot::Dictionary begin_country_economy_treasury_spend(
        int64_t country_handle, const godot::PackedInt32Array &good_ids,
        const godot::PackedInt64Array &quantities, int64_t cash,
        int64_t origin_epoch = -1, int origin_stage = -1,
        int64_t request_id = 0);
    godot::Dictionary begin_country_economy_fiscal_reserve(
        int64_t country_handle, int64_t requested, int64_t origin_epoch = -1,
        int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary begin_country_economy_fiscal_return(
        int64_t country_handle, int64_t offered, int64_t origin_epoch = -1,
        int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary begin_country_economy_fiscal_collect(
        int64_t country_handle, int64_t offered, int64_t origin_epoch = -1,
        int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary begin_country_economy_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch = -1,
        int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary begin_country_economy_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch = -1,
        int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary begin_country_economy_good_to_market(
        int64_t country_handle, int good_id, int64_t requested,
        int64_t origin_epoch = -1, int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary begin_country_economy_good_from_market(
        int64_t country_handle, int good_id, int64_t offered,
        int64_t origin_epoch = -1, int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary begin_country_economy_research_purchase(
        int64_t country_handle, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch = -1, int origin_stage = -1, int64_t request_id = 0);
    godot::Dictionary ack_country_economy_asset_peer_prepared(
        int64_t transaction_id, int64_t session_epoch,
        int64_t country_generation, int64_t peer_generation, bool accepted,
        const godot::String &reason = {});
    godot::Dictionary commit_country_economy_treasury_spend(
        int64_t transaction_id);
    godot::Dictionary commit_country_economy_fiscal_reserve(
        int64_t transaction_id);
    godot::Dictionary commit_country_economy_asset_transaction(
        int64_t transaction_id);
    godot::Dictionary ack_country_economy_asset_peer_applied(
        int64_t transaction_id, int64_t session_epoch,
        int64_t country_generation, int64_t peer_generation, bool accepted,
        const godot::String &reason = {});
    godot::Dictionary get_country_economy_asset_transaction(
        int64_t transaction_id) const;
    bool runtime_country_core_protocol_self_test();
    bool runtime_country_peer_protocol_self_test();
    godot::Dictionary bootstrap_country(const godot::Dictionary &packet,
                                        const godot::PackedByteArray &is_water);
    godot::Dictionary submit_country_commands(const godot::Dictionary &packed_batch);
    godot::Dictionary poll_country_command_receipts(
            int64_t after_publication = 0, int limit = 128);
    bool runtime_country_host_receipt_self_test() const;
    bool runtime_country_shadow_parity_self_test() const;
    void set_country_sync_store_writes_forbidden(bool forbidden);
    godot::Dictionary run_country_slice(const godot::Dictionary &ctx);
    /// Push NativeCountryRuntime territory into DataCore + MapData before
    /// vision/borders consume country_slot_arr. CLAIM can bump native ownership
    /// while MapData still holds a CoW-stale mirror; visuals must not race that.
    godot::Dictionary sync_country_territory_to_map();
    bool country_should_run(int64_t day_index) const;
    godot::Dictionary get_country_report() const;
    int64_t get_country_state_hash() const;
    godot::Dictionary get_country_cell_summary(int cell_idx) const;
    godot::Dictionary get_country_snapshot(int64_t handle) const;
    godot::Dictionary get_country_political_regime_snapshot(int64_t handle) const;
    godot::Dictionary configure_annual_reports(int64_t handle, int64_t days_per_year,
        int64_t initial_day, const godot::Dictionary &profile);
    godot::Dictionary commit_annual_reports(int64_t day);
    godot::Dictionary get_annual_report_status() const;
    godot::Dictionary get_annual_report_snapshot(int64_t report_id) const;
    godot::Dictionary get_annual_report_history(int32_t offset, int32_t limit) const;
    godot::Dictionary mark_annual_report_presented(int64_t report_id);
    godot::PackedByteArray capture_annual_report_state() const;
    godot::Dictionary restore_annual_report_state(const godot::PackedByteArray &bytes);
    godot::Dictionary annual_report_self_test() const;
    godot::Dictionary get_country_treasury_snapshot(int64_t handle) const;
    godot::Dictionary get_country_research_snapshot(int64_t handle) const;
    godot::Dictionary get_country_research_signal_snapshot(int64_t handle) const;
    godot::Dictionary consume_country_visual_era_dirty_slots();
    bool has_completed_country_technology(int64_t handle,
                                          int32_t technology_id) const;
    godot::Dictionary get_country_tax_policy_snapshot(int64_t handle) const;
    godot::Dictionary get_country_cell_tax_policy_snapshot(int cell_idx) const;
    godot::Dictionary get_country_ui_snapshot(int64_t handle,
                                              int section_mask) const;
    godot::Dictionary poll_country_events(int64_t after_event_id, int limit = 128) const;
    godot::Dictionary reset_country(const godot::String &reason);
    godot::Dictionary begin_country_save(int chunk_bytes = 4 * 1024 * 1024);
    godot::Dictionary begin_country_forensics_save(int chunk_bytes = 4 * 1024 * 1024);
    godot::PackedByteArray read_country_save_chunk(int max_bytes = 4 * 1024 * 1024);
    godot::Dictionary end_country_save();
    godot::Dictionary begin_country_restore();
    godot::Dictionary feed_country_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_country_restore();
    // Country AI (foreign countries only). Plans typed Country commands on the
    // worker (ACTIVE) or through the synchronous adapter in run_country_slice.
    godot::Dictionary configure_country_ai(const godot::Dictionary &catalog);
    godot::Dictionary set_country_ai_mode(const godot::String &mode);
    godot::Dictionary set_country_ai_excluded_handles(const godot::PackedInt64Array &handles);
    godot::Dictionary set_country_ai_topology(const godot::PackedInt32Array &neighbors,
                                              const godot::PackedInt32Array &cell_value_q16);
    godot::Dictionary get_country_ai_report() const;
    godot::Dictionary get_country_ai_country_snapshot(int64_t handle) const;
    godot::Dictionary poll_country_ai_decisions(int64_t after_id, int limit = 128) const;
    godot::Dictionary drain_country_ai_record_rows(int limit = 4096);
    godot::PackedByteArray encode_country_ai_state() const;
    godot::Dictionary restore_country_ai_state(const godot::PackedByteArray &bytes);
    bool runtime_country_ai_self_test() const;
