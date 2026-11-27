// Building display, world inputs, and natural resource interface.

    // Sparse, committed visual projection. This lane is deliberately excluded
    // from PKEC and state_hash; it is rebuilt from authoritative groups.
    godot::Dictionary building_visual_snapshot(
        const godot::PackedInt32Array &requested_cells) const;
    godot::Dictionary consume_building_visual_dirty_cells();
    godot::Dictionary treasury_construction_quotes(
        int64_t country_handle, int32_t cell_idx,
        const godot::PackedInt32Array &type_ids) const;
    godot::Dictionary construction_command_receipts(int64_t after_receipt_id,
                                                     int32_t limit,
                                                     int64_t settled_day = -1) const;
    // Player-facing treasury construction ingress. `submit_commands` is
    // fail-closed while StageOps owns production, so a formal build request
    // reaches the epoch command queue through this boundary instead (same
    // contract as the canal / family-colonization lanes).
    godot::Dictionary queue_treasury_sponsored_build(
        int64_t country_handle, int32_t cell_idx, int32_t type_id,
        int64_t effective_day, int64_t sequence, bool queue_for_worker, bool military_order = false);
    // Removal mirror of `queue_treasury_sponsored_build`: a state lot leaves the
    // economy ledger first, and the military bookkeeping command is only
    // forwarded afterwards (requirement 6.5).
    godot::Dictionary queue_treasury_sponsored_demolish(
        int64_t country_handle, int32_t cell_idx, int32_t type_id,
        int64_t count, int64_t effective_day, int64_t sequence,
        bool queue_for_worker, bool military_order = false);
    godot::Dictionary canal_route_quote(
        int64_t country_handle, int32_t start_cell, int32_t end_cell,
        const godot::PackedInt32Array &waypoints);
    godot::Dictionary canal_route_quote_detail(
        int64_t country_handle, int64_t quote_token) const;
    godot::Dictionary queue_canal_construction(
        int64_t country_handle, int64_t quote_token,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary canal_construction_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int32_t limit) const;
    godot::Dictionary family_cell_snapshot(int32_t cell_idx, int32_t offset,
                                            int32_t limit) const;
    godot::Dictionary family_snapshot(int64_t family_handle) const;
    godot::Dictionary family_branches(int64_t family_handle, int32_t offset,
                                      int32_t limit) const;
    godot::Dictionary family_traits(int64_t family_handle) const;
    godot::Dictionary family_branch_effects(int64_t family_handle,
                                            int32_t cell) const;
    bool submit_effect_family_trait(uint64_t family, const std::string &trait, bool grant,
        int32_t strength, int64_t day, int64_t sequence);
    godot::Dictionary submit_family_trait_commands(
        const godot::Dictionary &packed_batch);
    godot::Dictionary family_founding_offers(int32_t offset,
                                             int32_t limit) const;
    godot::Dictionary submit_family_founding_choice(
        int64_t offer_id, int64_t generation, int32_t choice_index,
        int64_t effective_day, int64_t sequence, bool check_now = true);
    godot::Dictionary family_industries(int64_t family_handle, int32_t offset,
                                        int32_t limit) const;
    godot::Dictionary family_notable_people(int64_t family_handle,
                                            int32_t offset,
                                            int32_t limit) const;
    int32_t player_family_founding_offer() const;
    godot::Array take_family_founding_receipts();
#include "economy_runtime_internal_colonization_quotes.h"
    void fill_colonization_query_flags(godot::Dictionary &out) const;
    godot::Dictionary submit_family_colonization_start(
        int64_t country_handle, int64_t family_handle, int32_t source_cell,
        int32_t target_cell, int64_t population, int64_t quote_token,
        int64_t effective_day, int64_t sequence, const uint8_t *visible,
        int32_t visible_count, uint64_t vision_revision,
        bool queue_for_worker = false);
    godot::Dictionary submit_family_colonization_cancel(
        int64_t country_handle, int64_t expedition_handle,
        int64_t effective_day, int64_t sequence,
        bool queue_for_worker = false);
    // National procurement budget + era procurement target (era advancement,
    // docs/cpp-dots-runtime/era-advancement-runtime.md §2.2-2.4). Both are
    // transient (not PKEC, not state hash). Setters may be called from the
    // main thread at any time: they only append to a mutex-guarded pending
    // table that the Economy owner thread applies at the next epoch begin.
    godot::Dictionary set_country_procurement_policy(
        int64_t country_handle, bool enabled, int32_t treasury_share_bp,
        int32_t research_share_bp, int64_t effective_day, int64_t sequence,
        int32_t era_share_bp = -1, int32_t colonization_share_bp = -1);
    godot::Dictionary set_era_procurement_target(
        int64_t country_handle, bool active,
        const godot::PackedInt32Array &good_indices,
        const godot::PackedInt64Array &required_quantities,
        int64_t effective_day, int64_t sequence);
    godot::Dictionary country_procurement_snapshot(int64_t country_handle) const;
    godot::Dictionary family_expeditions(int64_t country_handle,
                                         int32_t offset,
                                         int32_t limit) const;
    godot::Dictionary family_expedition_snapshot(
        int64_t country_handle, int64_t expedition_handle) const;
    godot::Dictionary family_colonization_receipts(
        int64_t country_handle, int64_t after_receipt_id,
        int32_t limit) const;
    godot::Dictionary notable_person_snapshot(int64_t person_handle) const;
    godot::Dictionary notable_person_needs(int64_t person_handle,
                                           int32_t offset,
                                           int32_t limit) const;
    godot::Dictionary building_notable_people(int64_t building_handle,
                                              int32_t offset,
                                              int32_t limit) const;
    // Cold-path satisfaction tracing. Both are pure reads of published state
    // and are only safe to call between native slices.
    godot::Dictionary explain_cohort_satisfaction(int64_t cohort_handle) const;
    godot::Dictionary cell_satisfaction_attractiveness(int32_t cell_idx) const;
    // Per-cell stratum-mobilization rows (organization/stage/cooldown). Returns
    // an empty list when the cell has no aggrieved profession.
    godot::Dictionary cell_mobilization_snapshot(int32_t cell_idx) const;
    void sample_narrative_cell(NarrativeCellView &, bool detailed) const;
    std::vector<NarrativeEconomyNotice> narrative_economy_notices(int64_t day, uint64_t country) const;
    bool narrative_unrest_rows(int32_t cell, std::vector<NarrativeUnrestRow> &) const;
    NarrativeUnrestOdds calculate_mobilization_odds(int32_t cell, int32_t profession,
        int32_t action, int64_t spend_bp, godot::Dictionary *details) const;
    // Bounded country-level summary for the top bar/alerts.
    godot::Dictionary country_mobilization_summary(int32_t country_slot) const;
    godot::Dictionary fiscal_snapshot(int64_t country_handle) const;
    godot::Dictionary production_climate_math_probe(
        const godot::Dictionary &vectors) const;
    int64_t state_hash() const;
    int64_t state_hash_legacy() const;
    // Diagnostic only; caller must hold the complete simulation-day boundary.
    uint64_t golden_population_market_hash(int64_t sample_day,
                                           int64_t committed_day) const;
    godot::Dictionary reset(const godot::String &reason);

    godot::Dictionary begin_save(int32_t chunk_bytes);
    godot::Dictionary begin_forensics_save(int32_t chunk_bytes);
    godot::PackedByteArray read_save_chunk(int32_t max_bytes);
    godot::Dictionary end_save();
    godot::Dictionary begin_restore();
    godot::Dictionary feed_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_restore();

    // ECP2 full-authority capture/apply (PKEC section remapping + resource wire).
    bool capture_ecp2_authority(RuntimeEconomyEcp2State &out, std::string &error,
                                  uint32_t flags = 0) const;
    bool apply_ecp2_authority(const RuntimeEconomyEcp2State &in,
                              std::string &error);
    const std::string &restore_rejected_reason() const noexcept {
        return _restore_rejected_reason;
    }

    // Committed, read-only economy event stream. Events produced by an active
    // frozen epoch remain private until aggregate_publish succeeds.
    godot::Dictionary event_schema() const;
    godot::Dictionary set_trace_filter(const godot::Dictionary &filter);
    godot::Dictionary set_inspector_trace_cell(int32_t cell_idx);
    godot::Dictionary poll_events(const godot::Dictionary &opts) const;
    godot::Dictionary ack_events(const godot::StringName &consumer_id,
                                 int64_t up_to_event_id);
    godot::Dictionary trace_report() const;
    godot::Dictionary begin_event_archive(int32_t chunk_bytes);
    godot::PackedByteArray read_event_archive_chunk(int32_t max_bytes);
    godot::Dictionary end_event_archive();

    // Building context is captured once at the frozen sample boundary. Natural
    // resources are resource-major and use GOODS_SCALE units in native state.
    bool capture_building_context(int64_t day_index, const float *elevation,
                                  const uint8_t *terrain, const uint8_t *landform,
                                  const uint8_t *vegetation, const uint8_t *is_water,
                                  const uint8_t *has_river, const int32_t *neighbor_indices,
                                  const std::vector<const float *> &resources,
                                  const std::vector<const float *> &resource_changes,
                                  int32_t count, std::string &error);
    bool needs_building_context_capture(int64_t day_index) const {
        return !_epoch_active && day_index > _last_committed_day &&
               _building_context_day != day_index;
    }
    const std::vector<std::string> &resource_ids() const { return _resource_ids; }
    const std::vector<std::string> &building_resource_reserve_slots() const {
        return _resource_reserve_slots;
    }
    const std::vector<std::string> &building_resource_extra_slots() const {
        return _resource_extra_slots;
    }
    int32_t cell_count() const { return _cell_count; }
    bool drain_building_resource_deltas(std::vector<size_t> &out_lanes,
                                        std::vector<int64_t> &out_deltas);
    // Natural regeneration coefficients for the worker-owned reserve lanes,
    // aligned with _resource_ids. Pointers inside `constants` stay unset.
    struct WorkerNaturalResource {
        NatResRuntime constants;
        int32_t habitat_mode = 0;
        int32_t temperature_signal = 0;
        int32_t moisture_signal = 0;
    };
    EconomyNaturalResourceCatalogView natural_resource_catalog() const;
    void configure_worker_natural_resources(const std::vector<EconomyNaturalResourceProfile> &profiles);
    bool worker_natural_resources_configured() const;
    bool worker_resource_seeded() const;
    int32_t worker_resource_recovered_cells() const;
    bool seed_worker_resource_reserves(int64_t initial_day,
        const std::vector<const float *> &reserves, const std::vector<const float *> &changes);
    void take_worker_resource_mirror_cells(std::vector<int32_t> &out);
    const std::vector<float> &worker_resource_reserve_lanes() const;
    const std::vector<float> &worker_resource_extra_lanes() const;
