// Ledger audits, goods validation, population movement, and formula helpers.

    AuditTotals incremental_audit_totals() const;
    AuditTotals audit_totals_from_shadow(const AuditTotals &baseline) const;
    int64_t country_cash_for_audit(int64_t raw) const;
    void commit_incremental_audit_shadow();
    void diagnose_incremental_audit_mismatch(const AuditTotals &full);
    void capture_goods_audit_candidates();
    void capture_money_audit_candidates();
    AuditTotals audit_totals() const;
    int64_t memory_bytes() const;
    int32_t choose_epoch_days(int64_t cohort_count);
    void write_cadence_report(godot::Dictionary &out) const;
    void write_hash_work_report(godot::Dictionary &out) const;
#include "economy_runtime_internal_change_tracking.h"
    void write_fiscal_continuation_report(godot::Dictionary &out) const;
    godot::Dictionary fatal_context_report() const;
    // R1-7/R1-8: assert_id + typed witness for the reason last stopped on.
    // Live in economy_runtime_fault_context.cpp; diagnostics only, never saved.
    godot::String fatal_assert_id() const;
    godot::Dictionary fatal_witness_report() const;
    // R4-2: generation / state_hash / restore_eligible for begin_save()'s result.
    // Lives in economy_runtime_fault_context.cpp so the persistence leaf does not
    // grow for a diagnostics-only contract.
    void write_save_identity_report(godot::Dictionary &out) const;
    int32_t locked_market_cycle_days() const;
    int32_t locked_slow_cycle_days() const;
    int32_t locked_plan_cycle_days() const;
    int32_t locked_investment_cycle_days() const;
    int32_t cycle_phase(int64_t day, int64_t start, int32_t cycle) const;
    bool market_in_workset(int32_t market, int64_t day) const;
    bool cell_in_market_workset(int32_t cell, int64_t day) const;
    bool cell_due_slow_review(int32_t cell, int64_t day) const;
    bool cell_due_plan_review(int32_t cell, int64_t day) const;
    bool cell_due_investment_review(int32_t cell, int64_t day) const;
    int32_t workset_elapsed_days(int64_t day_index) const;
    void capture_cell_elapsed_days(int64_t day_index);
    int32_t cell_elapsed_days(int32_t cell) const;
    enum TierReason : int32_t {
        TIER_REASON_PLAYER_TERRITORY = 0,
        TIER_REASON_VISIBLE,
        TIER_REASON_FORCED_WAKE,
        TIER_REASON_EFFECT_SHORTAGE,
        TIER_REASON_ESSENTIALS_SHORTAGE,
        TIER_REASON_CONSTRUCTION,
        TIER_REASON_RECENT_CHANGE,
        TIER_REASON_QUIET_SHORT,
        TIER_REASON_QUIET_WITH_BUILDINGS,
        TIER_REASON_DORMANT,
        TIER_REASON_OUT_OF_RANGE,
        TIER_REASON_COUNT,
    };
    uint8_t classify_cell_activity_tier(int32_t cell, int64_t day_index,
                                        int32_t *reason_out = nullptr) const;
    void refresh_cell_activity_tiers(int64_t day_index);
    void request_cell_wake(int32_t cell);
    int32_t tier_review_period_days(uint8_t tier) const;
    void collect_economy_live_cells(std::vector<int32_t> &cells,
                                    std::vector<int64_t> *population_totals) const;
    void rebuild_economy_live_cells();
    void capture_epoch_country_population();
    void refresh_cadence_estimates();
    void maybe_lock_cadence_cycles(int64_t day_index);
    void lock_market_cycle(int64_t day_index);
    void lock_slow_cycle(int64_t day_index);
    void lock_plan_cycle(int64_t day_index);
    void lock_investment_cycle(int64_t day_index);
    void apply_locked_slow_days();
    void note_completed_epoch_cadence_ms();
    void synthesize_cadence_locks_from_legacy_save();
    int32_t longer_investment_cycle_days(int32_t plan_days, int32_t n,
                                         int32_t candidate) const;
    int32_t snap_slow_days_to_market_multiple(int32_t s, int32_t n) const;
    int32_t snap_cycle_days(int32_t value, int32_t n, int32_t lo,
                            int32_t hi) const;
    int32_t knives_per_day(double ms_per_knife) const;
    double quantized_ms_per_knife(double cycle_ms, int32_t knives) const;
    int32_t building_slice_end(int32_t active_begin) const;
    int32_t building_slice_end(int32_t active_begin, int32_t cell_cap,
                               int32_t group_cap) const;
    int32_t building_plan_slice_end(int32_t active_begin) const;
    int32_t plan_evaluate_slice_end(int32_t active_begin) const;
    int32_t slice_end_over(const std::vector<int32_t> &cells,
                           int32_t active_begin, int32_t cell_cap,
                           int32_t group_cap) const;
    int32_t household_post_slice_end(int32_t active_begin) const;
    int32_t estimate_building_ranges() const;
    int32_t stage_progress_q16() const;
    const char *stage_name() const;
    const char *stage_name(Stage stage) const;
    const char *publish_phase_name(PublishPhase phase) const;
    const char *trade_plan_init_phase_name(TradePlanInitPhase phase) const;

    static int64_t saturating_add(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t saturating_sub(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t saturating_mul(int64_t a, int64_t b, int64_t &saturation_count);
    static int64_t inventory_adjusted_cost_pressure(int64_t cost, int64_t inventory, int64_t &sat);
    static int64_t goods_cost(int64_t quantity, int64_t price, int64_t &sat);
    static int64_t mul_div_sat(int64_t a, int64_t b, int64_t divisor,
                               int64_t &saturation_count);
    static int64_t proportional_cash_share(int64_t cash, int64_t people,
                                          int64_t population, int64_t &sat);
    static int64_t pow_q16(int64_t ratio_q16, int64_t exponent_q16,
                           int64_t &saturation_count);
    int32_t sample_environment_curve(int32_t curve_id, int32_t cell) const;
    int32_t sample_environment_curve(int32_t curve_id,
                                     const EnvironmentSample &sample) const;
    EnvironmentSample environment_sample_for_cell(int32_t cell) const;
    static EnvironmentSample environment_sample_from_float(float temperature,
                                                            float moisture,
                                                            float snow_cover,
                                                            float weather_intensity,
                                                            bool ready);
    int64_t variant_unit_price(int32_t market, int32_t variant_id,
                               int64_t &saturation_count) const;
    void build_demand_basis(int32_t market, const EnvironmentSample &sample,
                            std::vector<int64_t> &variant_scores,
                            std::vector<int64_t> &variant_prices,
                            std::vector<int64_t> &need_score_sums,
                            std::vector<int64_t> &need_composites,
                            std::vector<int64_t> &need_environment,
                            int64_t &saturation_count) const;
    void build_demand_basis_cached(int32_t cell, int32_t market,
                                   const EnvironmentSample &sample,
                                   std::vector<int64_t> &variant_scores,
                                   std::vector<int64_t> &variant_prices,
                                   std::vector<int64_t> &need_score_sums,
                                   std::vector<int64_t> &need_composites,
                                   std::vector<int64_t> &need_environment,
                                   int64_t &saturation_count);
    void prepare_due_demand_basis_cache();
    int64_t desired_need_units(int32_t slot, int32_t need_index, int32_t dt_days,
                               int64_t environment_factor_q16,
                               int64_t composite_factor_q16,
                               int64_t &saturation_count) const;
    int64_t desired_need_units_for_funds(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t funds, int64_t &saturation_count) const;
    void compute_cohort_demand_preview(
        int32_t slot, int32_t market, const EnvironmentSample &sample,
        const std::vector<int32_t> *price_override, int64_t funds_override,
        std::vector<int64_t> &good_per_capita_daily,
        int64_t &saturation_count) const;
    int64_t survival_required_units(int32_t slot, int32_t stable_need_id,
                                    int32_t dt_days,
                                    const EnvironmentSample &sample,
                                    int64_t &saturation_count) const;
    godot::Dictionary population_cell_snapshot_impl(
        int32_t cell_idx, const EnvironmentSample &sample,
        bool include_details) const;
    void append_population_employment_fields(
        godot::Dictionary &out, int32_t cell_idx) const;
    void group_job_totals(BuildingGroupConstRef group, int64_t &job_capacity,
                          int64_t &jobs_filled, int64_t &sat) const;
    bool compile_settlement_catalog(const godot::Dictionary &catalog,
                                    std::string &error);
    int64_t population_total_for_cell(int32_t cell) const;
    uint8_t prosperity_tier_for_population(int64_t population,
                                           uint8_t current) const;
    std::string settlement_name_for_cell(int32_t cell) const;
    void assign_settlement_name(int32_t cell);
    void release_settlement_name(int32_t cell);
    void initialize_settlements_from_population();
    void update_settlements_for_changed_cells();
    void append_settlement_fields(godot::Dictionary &out, int32_t cell) const;
    godot::Dictionary settlement_rows(const std::vector<SettlementChange> &changes,
                                      bool full_snapshot) const;
    static void formula_fixed_per_capita(const FormulaBatchInput &in, int64_t *out,
                                         int64_t &saturation_count);
    static void formula_income_price_linear(const FormulaBatchInput &in, int64_t *out,
                                            int64_t &saturation_count);
