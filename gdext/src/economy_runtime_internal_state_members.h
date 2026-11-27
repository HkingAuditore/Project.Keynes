// Included inside NativeEconomyRuntime; preserve declaration order and access.
    enum HouseholdSlicePhase : size_t {
        HOUSEHOLD_PREPARE = 0,
        HOUSEHOLD_WORKER,
        HOUSEHOLD_MERGE_AGGREGATE,
        HOUSEHOLD_MERGE_TRADE,
        HOUSEHOLD_TRACE,
        HOUSEHOLD_OTHER,
        HOUSEHOLD_POST_BUILDINGS,
        HOUSEHOLD_RESERVE_SHORTFALL,
        HOUSEHOLD_INCOME_SUBSIDY,
        HOUSEHOLD_STRUCTURAL_SORT,
        HOUSEHOLD_SLICE_PHASE_COUNT,
    };
    std::array<double, HOUSEHOLD_SLICE_PHASE_COUNT> _household_slice_phase_ms{};
    std::array<int64_t, HOUSEHOLD_SLICE_PHASE_COUNT> _household_slice_phase_work{};

    AuditTotals _opening_totals;
    AuditTotals _closing_totals;
    AuditTotals _publish_accum;
#include "economy_runtime_internal_state_members_population_and_lineage.h"
    // Track B spread mode: per-live-cell derived work cache so each day only a
    // 1/N slice of cells is recomputed and the ordered merge covers all cells.
    std::vector<TrackBDerivedCellWork> _track_b_derived_cell_cache;
    int64_t _track_b_derived_cell_cache_day = -1000000;
    int32_t _track_b_derived_cell_cache_cells = -1;
    struct DerivedHouseholdPreview {
        std::vector<int64_t> goods;
        int64_t saturations = 0;
        bool ready = false;
    };
    std::vector<DerivedHouseholdPreview> _derived_household_preview_scratch;
    // Same-input-edge substitutes that were not selected for procurement still
    // receive this shadow demand so producers of eligible SKUs (e.g. chipped
    // stone when bronze was chosen) can see category-level unmet need. Price,
    // investment, and Leontief seeding read it; merchant targets do not.
    std::vector<int64_t> _epoch_substitute_business_demand;
    std::vector<int64_t> _epoch_desired_business_demand;
    std::vector<int64_t> _epoch_funded_business_demand;
    // Confidence weight for folding derived demand into price pressure.
    int32_t _derived_business_demand_weight_q16 = Q16_ONE / 2;
    int64_t _derived_business_demand_total = 0;
    int64_t _derived_business_demand_lanes = 0;
    int64_t _derived_business_demand_edges = 0;
    std::vector<int64_t> _epoch_offered_supply_ema;
    // Current and previous-cycle producer absorption observations, aligned to
    // sparse (cell, good) market-signal lanes. Quotes read the previous cycle,
    // so both generations belong to PKEC64 and the authoritative state hash.
    std::vector<int64_t> _epoch_producer_sellable_current;
    std::vector<int64_t> _epoch_producer_merchant_sold_current;
    std::vector<int64_t> _epoch_previous_producer_sellable;
    std::vector<int64_t> _epoch_previous_producer_merchant_sold;
    std::vector<int64_t> _epoch_producer_discarded_current;
    std::vector<int64_t> _epoch_nonhousehold_withdrawals;
    std::vector<int32_t> _epoch_cost_anchor_price;
    std::vector<int64_t> _production_input_reserve;
    std::vector<int64_t> _construction_material_reserve;
    // Country research demand is derived once from the frozen country policy,
    // prices, and population at epoch begin. It is deliberately transient:
    // country treasury/goods remain Country authority and this cache is not
    // part of PKEC or the economy state hash.
    // Frozen one-shot procurement backlog, sparse sorted (cell/market, good).
    // Rebuilt from PREPARING custody and spendable Country cash each epoch;
    // not an order, withdrawal, wallet, persistent EMA, or save/hash lane.
    std::vector<std::pair<uint64_t, int64_t>> _epoch_colonization_demand_by_cell;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_colonization_demand_by_market;
    // Derived daily military demand. The standing snapshot itself reuses the
    // persisted owner command queue (opcode 36); no second ingress/save lane.
    std::vector<std::pair<uint64_t, int64_t>> _epoch_military_demand_by_cell;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_military_demand_by_market;
    int32_t _epoch_research_good_id = -1;
    std::vector<int64_t> _epoch_research_demand_by_cell;
    std::vector<int64_t> _epoch_research_demand_by_market;
    // One shared, deterministic mint budget per cell across all monetary goods.
    // Production and investment read the same remaining quota; no candidate can value the
    // complete global cap independently.
    std::vector<uint64_t> _epoch_bullion_quota_keys;
    std::vector<int64_t> _epoch_bullion_quota_initial;
    std::vector<int64_t> _epoch_bullion_quota_remaining;
    int64_t _epoch_bullion_quota_initial_total = 0;
    int64_t _epoch_bullion_quota_remaining_total = 0;
    int64_t _epoch_bullion_quota_remainder_units = 0;
    // Temporary rows shared by wages, building retention, and households.
    // The economy owner assigns slots before dispatch. Workers fill separate rows.
    struct DemandBasisCache {
        struct Slot {
            int32_t cell;
            bool ready;
        };
        std::vector<int32_t> cell_to_slot;
        std::vector<Slot> slots;
        std::vector<int64_t> values;

        int64_t values_bytes() const {
            return static_cast<int64_t>(values.capacity()) * sizeof(int64_t);
        }
        int64_t index_bytes() const {
            return static_cast<int64_t>(cell_to_slot.capacity()) * sizeof(int32_t) +
                   static_cast<int64_t>(slots.capacity()) * sizeof(Slot);
        }
    } _demand_basis_cache;
    // Persistent per-cell rolling settlement state. Phase is derived from the
    // Stable cell id; last day and generation are PKEC v16 authority.
    EconomyOwnedColumn<int64_t> _cell_last_settlement_day{{{16, 9}, "native_columns.cell_last_settlement_day", EconomyFieldEncoding::I64, 8}};
    // Q32 fractional births accumulated per cell and ethnicity.
    EconomyOwnedColumn<int64_t> _birth_residual_q32{{{16, 1}, "native_columns.birth_residual_q32", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<uint32_t> _cell_settlement_generation{{{16, 13}, "native_columns.cell_settlement_generation", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_price_stock_gen{{{16, 12}, "native_columns.cell_price_stock_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_owner_cash_gen{{{16, 10}, "native_columns.cell_owner_cash_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_population_gen{{{16, 11}, "native_columns.cell_population_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_building_structure_gen{{{16, 2}, "native_columns.cell_building_structure_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_technology_gen{{{16, 16}, "native_columns.cell_technology_gen", EconomyFieldEncoding::U32, 4}};
    ChangeRegistry _resource_changes_local;
    EconomyTrackedColumn<uint32_t> _cell_resource_gen{_resource_changes_local,
        {{3, 2}, "resource.cell_generation", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<uint32_t> _cell_trade_gen{{{16, 17}, "native_columns.cell_trade_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<int32_t> _cell_effect_shortage_q16{{{16, 28}, "persisted_columns.cell_effect_shortage_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_essentials_shortage_q16{{{16, 29}, "persisted_columns.cell_essentials_shortage_q16", EconomyFieldEncoding::I32, 4}};
    std::vector<int32_t> _cell_resource_abundance_q16;
    std::vector<int32_t> _cell_previous_precipitation_q16;
    std::vector<int32_t> _cell_rain_event_q16;
    std::vector<uint8_t> _good_is_essential;
    int32_t _max_building_upgrade_tier = 0;
    // Transaction worksets are deterministic, sorted and never persisted.
    std::vector<int32_t> _epoch_market_ids;
    std::vector<int64_t> _epoch_market_work_weights;
    // Scratch union of populated / building / pending-construction cells.
    // Rebuilt each epoch_begin; never saved or hashed.
    std::vector<int32_t> _economy_live_cells;
    // Copy for main-thread readers: the worker iterates _economy_live_cells
    // (tax, investment) during an epoch, so queries must never rebuild it.
    mutable std::mutex _economy_live_cells_published_mutex;
    std::shared_ptr<const std::vector<int32_t>> _economy_live_cells_published;
    std::vector<int32_t> _epoch_settlement_cells;
    std::vector<int32_t> _epoch_building_cells;
    // Subset of today's market workset whose plan evaluation is due on the
    // locked slow cycle S. Cells that are S-due but not in today's market
    // bucket wait until their next market day. Production still consumes the
    // last computed plan.
    std::vector<int32_t> _epoch_plan_cells;
    std::vector<int64_t> _household_post_saturation_scratch;
    std::vector<int64_t> _household_post_restarted_scratch;
    std::vector<int64_t> _household_post_failed_scratch;
    std::vector<int64_t> _household_reserve_shortfall_scratch;
    // Diagnostic-only per-cell contributions for the current rolling epoch.
    // Employment can be recomputed after structural changes; replacing the
    // cached contribution avoids subtracting a cell that was never counted in
    // this epoch and keeps the published totals non-negative.
    std::vector<int64_t> _employment_metrics_epoch_by_cell;
    std::vector<int64_t> _employment_owner_jobs_by_cell;
    std::vector<int64_t> _employment_employee_jobs_by_cell;
    std::vector<int64_t> _employment_unemployed_by_cell;
    // Epoch-transient lanes. They are rebuilt from the frozen sample and are
    // intentionally excluded from save data and the authoritative state hash.
    std::vector<int64_t> _building_survival_utilization_floor_q16;
    std::vector<int64_t> _building_planned_capacity_before_climate_q16;
    std::vector<int64_t> _building_funded_capacity_q16;
    std::vector<int64_t> _building_working_capital_allocated;
    std::vector<int64_t> _building_owner_livelihood_credit;
    std::vector<int64_t> _building_merchant_credit_limit;
    // Suspended producers keep no production, labor, or input demand. Permanent
    // liquidation is reviewed only when a full restart is physically and
    // financially executable but still economically unviable.
    std::vector<int64_t> _building_recovery_probe_capacity_q16;
    std::vector<uint8_t> _building_recovery_liquidation_eligible;
#include "economy_runtime_internal_state_members_building_and_market.h"
#include "economy_runtime_internal_state_members_configuration_and_environment.h"
#include "economy_runtime_internal_state_members_command_and_publication.h"
    // ── Effect input revision (P1-A) ────────────────────────────────────────
    // A monotone count of "an input an ideology program reads actually changed".
    // Deliberately a CONTENT digest, not a clock: bumping once per economy epoch
    // would make every managed card refresh every day, which is exactly the
    // no-op churn this revision exists to prevent (see 04-review-verification
    // §3.1). All fields below are derived and never persisted.
    mutable std::atomic<uint64_t> _effect_input_revision{0};
    uint64_t _published_effect_input_digest = 0;
    // Declared by the ideology catalog: the union of the per-cell metrics its
    // managed programs read, and whether any of them selects targets by tag.
    // Both empty/false means "no managed card reads economy input", and the
    // digest then costs nothing at all.
    // P3-B, second half: the consumer set moves behind one immutable object.
    // Previously `metric_mask`, `tags_needed` and the "force republish" flag were
    // plain fields written by the catalog configurer on the main thread and read
    // by the digest on the economy thread -- the same data race the revisions had.
    struct EffectInputConsumers {
        MetricMask metric_mask;
        bool tags_needed = false;
        // WHICH tags are consumed, as 0-based indices.
        //
        // `tags_needed` alone forces the rebuild to evaluate every declared tag: a
        // world whose cards use one tag still paid `cells x 296` matches, measured at
        // 35.66 ms for 6400 cells (M4-22). With the set, the sweep narrows to the tags
        // that can actually be read.
        //
        // Empty + `tags_needed == false` means "no tags". Empty + true is a caller that
        // declared the need but not the ids, and is treated as "all tags" so a
        // conservative publisher cannot silently narrow the target set.
        std::vector<int32_t> tag_ids;
        bool families_needed = false;
        // Bumped on every swap so the digest can tell "the consumer set changed"
        // without the writer touching the digest's own published state.
        uint64_t generation = 0;
        std::array<std::vector<int64_t>, FAMILY_METRIC_COUNT> thresholds;
    };
    std::shared_ptr<const EffectInputConsumers> _effect_input_consumers;
    uint64_t _published_consumers_generation = 0;
    // Published revision snapshot (see EffectInputSnapshot at namespace scope).
    std::shared_ptr<const EffectInputSnapshot> _effect_input_snapshot;
    // Per-metric revisions (review §3, second half). The global revision stays a
    // union -- "something moved" -- so the existing refresh/should_run gates keep
    // their meaning; these let a card's signature depend only on the metrics it
    // actually reads, instead of re-signing every economy-input card whenever any
    // metric moves.
    // Test hook: a metric value forced for every cell. The gate's job is to react
    // to *threshold crossings*, and the only way to test that deterministically is
    // to move one metric by a chosen amount -- the simulation cannot be steered
    // that precisely. Unset means "use the sampled value".
    // The override is a test hook, but it was still a main-thread write into the
    // digest thread's state. Same treatment as everything else on this path: one
    // immutable object, swapped atomically.
    struct EffectMetricOverrideSet {
        std::array<int64_t, FAMILY_METRIC_COUNT> values{};
        std::array<uint8_t, FAMILY_METRIC_COUNT> set{};
        uint64_t generation = 0;
    };
    std::shared_ptr<const EffectMetricOverrideSet> _effect_metric_override_snapshot;
    uint64_t _published_override_generation = 0;
    // Test-only tag overrides, consulted while sampling a cell's effect metrics.
    // Unlike the metric override, these are scoped to one cell: a card's tagged
    // fixture cell and an untagged control cell can coexist in one world.
    struct CellTagOverride {
        uint8_t force_true = 0;
        uint8_t force_false = 0;
    };
    struct CellTagOverrideSet {
        std::unordered_map<int32_t, std::vector<CellTagOverride>> cells;
        uint64_t generation = 0;
    };
    std::shared_ptr<const CellTagOverrideSet> _cell_tag_override_snapshot;
    uint64_t _tag_override_published_generation = 0;
    uint64_t _tag_snapshot_override_generation = 0;
    // Last published digests, used only by the digest pass itself (single writer,
    // single thread) to decide what moved.
    std::array<uint64_t, FAMILY_METRIC_COUNT> _effect_metric_published{};
    uint64_t _effect_territory_published = 0;
    uint64_t _effect_tag_published = 0;
    uint64_t _effect_family_published = 0;

    uint64_t _effect_input_digest_computations = 0;
    double _effect_input_digest_ms = 0.0;
    // X7 second half: distinct specialized goods per country. One small bitset
    // per country while building, then collapsed to a count. Derived from a
    // per-cell sample of (dominant output good, its share), so it carries its
    // own valid flag and is dropped with the rest of the epoch state.
    //
    // Nested vectors instead of one flat country x good matrix: the good id
    // space is data-driven (data/goods), and a flat matrix would need a good
    // count the runtime does not hold. Growing each country's bitset on demand
    // keeps this exact without inventing a cap.
    // X7b (metric 67) now lives inside the published `TagSnapshot`; readers go
    // through `tag_snapshot()`. The `mutable` lazy-build trio it used to have is
    // gone with R-3.
    std::vector<uint8_t> _epoch_cell_visible;
    int32_t _epoch_player_country_slot = -1;
    bool _epoch_trade_vision_gated = false;
    bool _trade_visibility_manual = false;
    std::vector<uint64_t> _epoch_country_technologies;
    EconomyOwnedColumn<uint64_t> _epoch_country_handles{{{16, 18}, "native_columns.epoch_country_handles", EconomyFieldEncoding::U64, 8}};
    std::vector<uint32_t> _epoch_country_political_regime_capabilities;
    // Derived per-epoch read of Country's capital cells (PKCN v16). Not an
    // owned/persisted Economy column: it is re-captured from Country every
    // epoch, so it never needs a save section or state-hash mix.
    std::vector<int32_t> _epoch_country_capital_cells;
    // Catalog-resolved tax stat ids and the per-epoch effective integer rates.
    // Only configure/capture touches ModifierRuntime; workers read these dense arrays.
    std::vector<int32_t> _income_tax_stat_ids;
    std::vector<int32_t> _consumption_tax_stat_ids;
    std::vector<int32_t> _business_tax_stat_ids;
    std::vector<int32_t> _import_tax_stat_ids;
    std::vector<int32_t> _export_tax_stat_ids;
    std::vector<int32_t> _country_family_output_stat_ids;
    std::vector<int32_t> _country_good_output_stat_ids;
    std::vector<int32_t> _country_good_input_stat_ids;
    std::vector<int32_t> _country_good_consumption_stat_ids;
    // Per-good trade factors. Same resolution rule as the three vectors above:
    // indexed in `_good_ids` order, -1 when that good declares no such stat.
    std::vector<int32_t> _country_good_trade_capacity_stat_ids;
    std::vector<int32_t> _country_good_trade_speed_stat_ids;
    std::vector<int32_t> _country_resource_use_stat_ids;
    std::vector<int32_t> _country_resource_generation_stat_ids;
    // X16: indexed by `profession_id`; -1 means the stat is absent.
    std::vector<int32_t> _profession_tax_tolerance_stat_ids;
    std::vector<int32_t> _profession_satisfaction_bp_stat_ids;
    // Per-political-class satisfaction bias (`economy.class.<id>.satisfaction_bp`),
    // indexed in `_political_class_ids` order; folded into per-profession and
    // general-class epoch satisfaction biases during `freeze_country_epoch_inputs`.
    std::vector<int32_t> _political_class_satisfaction_bp_stat_ids;
    std::vector<int32_t> _country_terrain_sector_output_stat_ids;
    std::vector<int32_t> _country_landform_sector_output_stat_ids;
    std::vector<int32_t> _country_building_output_stat_ids;
    int32_t _country_production_input_stat_id = -1;
    int32_t _country_household_consumption_stat_id = -1;
    int32_t _country_population_death_stat_id = -1;
    int32_t _country_resource_use_stat_id = -1;
    std::array<int32_t, 4> _country_climate_loss_stat_ids{-1, -1, -1, -1};
    // Dense [production climate profile][hazard] stat IDs, resolved at configure.
    std::vector<int32_t> _country_climate_profile_loss_stat_ids;
    int32_t _city_birth_stat_id = -1;
    int32_t _city_consumption_stat_id = -1;
    std::vector<int32_t> _city_need_consumption_stat_ids;
    std::vector<int32_t> _city_good_consumption_stat_ids;
    std::vector<int32_t> _city_good_output_stat_ids;
    std::vector<int32_t> _city_building_output_stat_ids;
    std::vector<int32_t> _epoch_income_tax_rates;
    std::vector<int32_t> _epoch_consumption_tax_rates;
    std::vector<int32_t> _epoch_business_tax_rates;
    std::vector<int32_t> _epoch_import_tax_rates;
    std::vector<int32_t> _epoch_export_tax_rates;
    std::vector<int32_t> _epoch_income_tax_modes;
    std::vector<int32_t> _epoch_consumption_tax_modes;
    std::vector<int32_t> _epoch_business_tax_modes;
    std::vector<int32_t> _epoch_import_tax_modes;
    std::vector<int32_t> _epoch_export_tax_modes;
    static constexpr size_t CELL_TAX_KIND_COUNT = 5;
    struct CompiledCellTaxOverride {
        int32_t item = -1;
        int32_t rate = 0;
        int32_t mode = 0; // TAX_MODE_PERCENT_BP
    };
    struct CompiledCellTaxPolicy {
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            default_row_ids{-1, -1, -1, -1, -1};
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            override_begin{};
        std::array<int32_t, CELL_TAX_KIND_COUNT>
            override_end{};
        uint8_t active_mask = 0;
        uint8_t negative_mask = 0;
        uint8_t absolute_mask = 0;
    };
    struct CompiledCellTaxDefaultRow {
        int32_t kind = -1;
        int32_t country = -1;
        int32_t base_rate = 0;
        int32_t base_mode = 0; // TAX_MODE_PERCENT_BP
        int32_t offset = 0;
        int32_t count = 0;
    };
    std::vector<uint32_t> _epoch_cell_compiled_tax_policy;
    std::vector<uint8_t> _epoch_cell_active_tax_mask;
    // Per-cell tax mode masks keep fiscal post-processing data-oriented.  The
    // active mask answers whether a lane has any non-zero rate; these masks
    // answer whether the lane can actually enter the negative-tax or absolute
    // settlement paths, so ordinary positive percentage tax does not trigger
    // a full cohort/building scan.
    std::vector<uint8_t> _epoch_cell_negative_tax_mask;
    std::vector<uint8_t> _epoch_cell_absolute_tax_mask;
    std::vector<CompiledCellTaxPolicy> _epoch_compiled_cell_tax_policies;
    std::vector<CompiledCellTaxOverride> _epoch_compiled_cell_tax_overrides;
    std::vector<CompiledCellTaxDefaultRow> _epoch_compiled_cell_tax_default_rows;
    std::vector<int32_t> _epoch_compiled_cell_tax_default_rates;
    std::vector<int32_t> _epoch_compiled_cell_tax_default_modes;
    int64_t _epoch_cell_tax_cache_bytes = 0;
    double _epoch_cell_tax_compile_ms = 0.0;
    bool _epoch_has_cell_tax_policies = false;
    uint64_t _epoch_tax_policy_version = 0;
    uint8_t _epoch_active_tax_mask = 0;
    uint8_t _epoch_negative_tax_mask = 0;
    uint8_t _epoch_absolute_tax_mask = 0;
    static constexpr int32_t ACTIVE_TAX_KIND_COUNT = 3;
    EconomyOwnedColumn<int64_t> _fiscal_previous_requests{{{16, 26}, "native_columns.fiscal_previous_requests", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<uint64_t> _fiscal_previous_country_handles{{{16, 25}, "native_columns.fiscal_previous_country_handles", EconomyFieldEncoding::U64, 8}};
    // Epoch-transient reservation weights. Income lanes are seeded from the
    // frozen minimum-living subsidy floor for current cohorts plus a bounded
    // prospective floor for available owner/employee professions, so a newly
    // enabled negative income rate can attract a transition without waiting
    // for one historical batch. Business lanes get the matching prospective
    // floor on investment-review cells only, bounded by one building of the
    // single most valuable subsidised type.
    std::vector<int64_t> _fiscal_reservation_requests;
    int64_t _fiscal_business_prospective_lanes = 0;
    int64_t _fiscal_business_prospective_request = 0;
    std::vector<int64_t> _fiscal_current_requests;
    std::vector<int64_t> _fiscal_budgets;
    std::vector<int64_t> _fiscal_remaining;
    // Frozen promise ratio shared by forecasts and settlement. This prevents
    // iteration order from changing which rational actor receives a subsidy.
    std::vector<int32_t> _fiscal_fulfillment_q16;
    std::vector<int64_t> _fiscal_epoch_bases;
    std::vector<int64_t> _fiscal_epoch_assessed;
    std::vector<int64_t> _fiscal_epoch_collected;
    std::vector<int64_t> _fiscal_epoch_paid;
    // 在途国库贷记：fiscal collect 已把 escrow 划出、国家 pod 尚未提交，
    // 因此还没进入 country_economy_audit_snapshot。审计把它算作国库，
    // 否则出现 escrow 已清零、国库未增的假缺口（m0 实测 -162903）。
    // 清零判据：国库镜像相对「上一次审计读到的值」发生了变化（说明钱已落地）。
    mutable int64_t _country_pending_credit = 0;
    mutable int64_t _country_pending_credit_last_raw = -1;
    EconomyOwnedColumn<int64_t> _fiscal_escrow_by_country{{{16, 23}, "native_columns.fiscal_escrow_by_country", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedJournal<uint64_t, AssetPeerJournalRecord> _asset_peer_journal{
        {{13, 1}, "fiscal.peer_journal", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyOwnedColumn<int64_t> _fiscal_last_bases{{{16, 45}, "persisted_columns.fiscal_last_bases", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_assessed{{{16, 44}, "persisted_columns.fiscal_last_assessed", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_collected{{{16, 46}, "persisted_columns.fiscal_last_collected", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_requests{{{16, 48}, "persisted_columns.fiscal_last_requests", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_reserved{{{16, 49}, "persisted_columns.fiscal_last_reserved", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_paid{{{16, 47}, "persisted_columns.fiscal_last_paid", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_unmet{{{16, 50}, "persisted_columns.fiscal_last_unmet", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_last_events{{{16, 24}, "native_columns.fiscal_last_events", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_bases{{{16, 19}, "native_columns.fiscal_cumulative_bases", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_collected{{{16, 20}, "native_columns.fiscal_cumulative_collected", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_requests{{{16, 22}, "native_columns.fiscal_cumulative_requests", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _fiscal_cumulative_paid{{{16, 21}, "native_columns.fiscal_cumulative_paid", EconomyFieldEncoding::I64, 8}};
    // Non-tax treasury outflows. Every one of these pays treasury cash OUT to a
    // merchant (or into an expedition) without being a tax kind, so none of them
    // could ever appear on the five-lane fiscal grid. They share one
    // country x kind lane instead, published beside the tax lanes so 国库支出
    // reconciles with the treasury the player actually owns.
    enum NonTaxOutflow : int32_t {
        NON_TAX_RESEARCH_PURCHASE = 0,
        NON_TAX_EXPEDITION_PROCUREMENT = 1,
        NON_TAX_CONSTRUCTION = 2,
        NON_TAX_CANAL = 3,
        // Era advancement procurement (market -> treasury). Transient lane:
        // PKEC schema 58 persists only the first NON_TAX_PERSISTED_KIND_COUNT
        // kinds, so this slot restores as zero.
        NON_TAX_ERA_PROCUREMENT = 4,
        NON_TAX_KIND_COUNT = 5,
        NON_TAX_PERSISTED_KIND_COUNT = 4,
    };
    EconomyOwnedColumn<int64_t> _fiscal_last_non_tax_outflow{{{16, 60}, "persisted_columns.fiscal_last_non_tax_outflow", EconomyFieldEncoding::I64, 8}};
    // Outflows booked since the last published batch, keyed by generation-safe
    // country handle rather than by epoch country index: family expedition
    // procurement settles at the idle day boundary, when the country set may
    // already have changed. commit_fiscal drains this buffer into the batch.
    struct PendingNonTaxOutflow {
        uint64_t country_handle = 0;
        int64_t cash[NON_TAX_KIND_COUNT] = {0, 0, 0, 0, 0};
    };
    std::vector<PendingNonTaxOutflow> _pending_non_tax_outflow;
    FiscalReservationContinuation _fiscal_reservation_continuation;
    FiscalSettlementContinuation _fiscal_settlement_continuation;
    // Tariffs stay on a sparse cell x {import, export} lane separate from the
    // domestic cell x 3 fiscal arrays. The dense generation-stamped lookup is
    // transient metadata; monetary columns exist only for endpoint lanes
    // touched in the current epoch.
    std::vector<int32_t> _tariff_epoch_cells;
    std::vector<uint8_t> _tariff_epoch_kinds;
    std::vector<int64_t> _tariff_epoch_bases;
    std::vector<int64_t> _tariff_epoch_assessed;
    std::vector<int64_t> _tariff_epoch_collected;
    std::vector<int64_t> _tariff_epoch_requests;
    std::vector<int64_t> _tariff_epoch_reserved;
    std::vector<int64_t> _tariff_epoch_paid;
    std::vector<int64_t> _tariff_epoch_events;
    std::vector<int32_t> _tariff_lane_index;
    std::vector<uint32_t> _tariff_lane_stamp;
    uint32_t _tariff_lane_generation = 0;
    // Tariff subsidies share the country escrow with domestic subsidies. The
    // country vectors are the authoritative reservation budget consumed by
    // dispatch; cell lanes remain the sparse reporting surface.
    std::vector<int64_t> _tariff_country_requests;
    std::vector<int64_t> _tariff_country_budgets;
    std::vector<int64_t> _tariff_country_remaining;
    // Per-slot derived epoch scratch; intentionally excluded from save/hash.
    std::vector<int64_t> _income_taxable_base_by_slot;
    std::vector<int64_t> _income_subsidy_floor_by_slot;
    std::vector<int32_t> _epoch_country_output_factor_q16;
    std::vector<int32_t> _epoch_country_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_research_output_factor_q16;
    std::vector<int32_t> _epoch_country_family_output_factor_q16;
    std::vector<int32_t> _epoch_country_good_output_factor_q16;
    std::vector<int32_t> _epoch_country_good_input_factor_q16;
    std::vector<int32_t> _epoch_country_good_consumption_factor_q16;
    std::vector<int32_t> _epoch_country_resource_use_factor_q16;
    std::vector<int32_t> _epoch_country_resource_generation_factor_q16;
    // X16 frozen per (country slot, profession id), stride = profession count.
    //
    // Frozen once per epoch like every other country modifier read: the satisfaction
    // loop runs per cell per cohort, and resolving a modifier stat there would both
    // cost a lookup per cohort and let the value change mid-epoch (two cohorts in the
    // same country could then see different tolerances). Q16 factor and basis points,
    // clamped to [0.5, 3.0] and [-2500, 2500] respectively.
    std::vector<int32_t> _epoch_country_profession_tax_tolerance_q16;
    std::vector<int32_t> _epoch_country_profession_satisfaction_bp;
    std::vector<int32_t> _epoch_country_general_satisfaction_bp;
    // R-4 metric 69: per-country treasury reserve ratio, in percentage points.
    // v0 denominator is a 365-day extrapolation of the live income EMA (no new save
    // state); the true rolling-year accumulator is deferred to M4 (09 §8).
    std::vector<int32_t> _epoch_country_reserve_pct;
    std::vector<int32_t> _epoch_country_terrain_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_landform_sector_output_factor_q16;
    std::vector<int32_t> _epoch_country_building_output_factor_q16;
    std::vector<int32_t> _epoch_country_production_input_factor_q16;
    std::vector<int32_t> _epoch_country_household_consumption_factor_q16;
    std::vector<int32_t> _epoch_country_death_factor_q16;
    std::vector<int32_t> _epoch_country_resource_global_use_factor_q16;
    std::vector<int32_t> _epoch_country_climate_loss_factor_q16;
    // Dense [country][production climate profile][hazard] Q16 loss factors.
    std::vector<int32_t> _epoch_country_climate_profile_loss_factor_q16;
    std::vector<int32_t> _epoch_country_trade_capacity_factor_q16;
    std::vector<int32_t> _epoch_country_trade_speed_factor_q16;
    // Dense [country][good] Q16 twins of the two rows above, from
    // `country.trade.good.<good>.{capacity,speed}_factor` (tech tree stage 4).
    // Same two trade consumption points, one dimension finer: `country.trade.*`
    // stays the country-wide factor (ideology cards and tax content write it),
    // these multiply on top per good. A good that declares no such stat keeps
    // the Q16_ONE the epoch assign wrote -- never 0, which would silently zero
    // every trade of that good.
    std::vector<int32_t> _epoch_country_good_trade_capacity_factor_q16;
    std::vector<int32_t> _epoch_country_good_trade_speed_factor_q16;
    std::vector<uint8_t> _epoch_country_water_capability;
    std::vector<int32_t> _epoch_country_construction_cost_factor_q16;
    std::vector<int32_t> _epoch_country_construction_time_factor_q16;
    std::vector<int32_t> _epoch_cell_birth_factor_q16;
    std::vector<int32_t> _epoch_cell_need_consumption_factor_q16;
    std::vector<int32_t> _epoch_cell_good_consumption_factor_q16;
    std::vector<int32_t> _epoch_cell_rain_event_threshold_q16;
    std::vector<int32_t> _epoch_cell_cold_capacity_factor_q16;
    std::vector<int32_t> _epoch_cell_sector_output_factor_q16;
    std::vector<int32_t> _family_policy_stamped_cells;
    // The city factor tables are pure functions of the city stat buckets in the
    // ECONOMY modifier store, so they survive across epochs and are rebuilt only
    // when those buckets (or the catalog shape behind the tables) change. The
    // cached shared row is what every cell without a group bucket holds, so a
    // rebuild only has to repaint the cells listed in _city_factor_dirty_cells.
    uint64_t _epoch_city_factor_stat_version = 0;
    bool _epoch_city_factor_valid = false;
    int32_t _city_factor_shared_birth_q16 = Q16_ONE;
    std::vector<int32_t> _city_factor_shared_needs_q16;
    std::vector<int32_t> _city_factor_shared_goods_q16;
    std::vector<int32_t> _city_factor_dirty_cells;
    std::vector<uint64_t> _city_factor_group_cells_scratch;
    // Resume cursor for `refresh_city_modifier_factors` (plan 14.3 sharding).
    // < 0 means "no shard in flight": the next call repaints the shared row and
    // re-collects the scope list. >= 0 is the next index into
    // `_city_factor_group_cells_scratch`.
    // Cells processed per `refresh_city_modifier_factors` slice. M1-6 measured
    // ~6.0 us per covered cell at B7 scale, so 64 cells ~= 0.38 ms, leaving
    // headroom inside the plan §14.3 1 ms slice budget for the surrounding
    // epoch-open work. A fixed count beats a wall-clock check here because it is
    // deterministic and therefore assertable in a test (plan §14.4).
    static constexpr int32_t CITY_FACTOR_SHARD_CELLS = 64;
    int32_t _city_factor_shard_cursor = -1;
    // The stat version the in-flight shard was built against. A resume under a
    // different version restarts instead of finishing a stale work set.
    uint64_t _city_factor_shard_version = 0;
    // Resume cursor for `refresh_city_output_modifier_factors`, independent of
    // the city-factor cursor so neither reader blocks the other.
    int32_t _city_output_shard_cursor = -1;
    uint64_t _city_output_shard_version = 0;
    // Intermediate collector for the sharded output reader. The per-cell query
    // loop can stop between cells, but the sort + CSR rebuild that consumes its
    // output cannot, so the partial result has to survive across slices. Empty
    // when no shard is in flight.
    struct CityOutputOverrideRow {
        int32_t cell = -1;
        int32_t good = -1;
        int32_t factor_q16 = Q16_ONE;
    };
    std::vector<CityOutputOverrideRow> _city_output_shard_partial;
    // Work-set size of the LAST pass that actually collected one. Kept separate
    // from `_city_factor_group_cells_scratch.size()` because a pass that
    // short-circuits on the version gate never re-collects, so reading the
    // scratch afterwards reports a stale (or empty) number -- which is exactly
    // what made a shard test read `work=0` while 255 cells had been painted.
    int64_t _city_factor_work_cells = 0;
    // Cells ACTUALLY processed by the most recent pass, incremented INSIDE the
    // cell loop. `_city_factor_work_cells` above only records what the last
    // collect produced, so on a day where the version gate short-circuits it
    // still reports the previous pass's size -- and a reader that skipped the
    // work set becomes indistinguishable from one that finished it in
    // microseconds. That exact confusion produced a "2000 cells in 0.003 ms"
    // reading (M2-10) which is physically impossible.
    int64_t _city_factor_cells_processed = 0;
    // Size of the work set collected by the CURRENT pass, distinct from
    // `_city_factor_work_cells` which persists across passes. M2-11 reasoned that
    // a `processed=16` reading implied `total=16`; this field makes that
    // verifiable instead of inferred.
    int64_t _city_factor_collected_cells = 0;
    // Cumulative cost of the WHOLE city-factor build across every shard of the
    // current epoch, plus how many shard calls it took.
    //
    // `_epoch_begin_city_factor_ms` only measures ONE call (`economy_runtime.cpp:
    // 5542`), and a full build is spread over `work_cells / CITY_FACTOR_SHARD_CELLS`
    // calls, so that field reports the LAST shard -- typically the small remainder.
    // A 2000-cell work set therefore read as "16 cells, 0.002 ms" and looked
    // thousands of times faster than it is (M2-11).
    //
    // These two fields are the number §14.3 actually needs: total time and total
    // work for the whole materialisation, not the tail of it.
    double _city_factor_epoch_ms = 0.0;
    int64_t _city_factor_epoch_slices = 0;
    int64_t _city_factor_epoch_cells = 0;
    bool _city_factor_epoch_in_progress = false;
    std::vector<int32_t> _city_factor_stat_ids_scratch;
    // Exact city-good production factors use one shared global row plus sparse
    // per-cell overrides. The CSR scales with authored effects, not
    // `cell_count * good_count`, and is rebuilt only when one of those stats
    // changes. Transient; never saved or hashed.
    uint64_t _epoch_city_output_factor_stat_version = 0;
    bool _epoch_city_output_factor_valid = false;
    std::vector<int32_t> _city_output_shared_goods_q16;
    std::vector<int32_t> _city_output_cell_offsets;
    std::vector<int32_t> _city_output_good_indices;
    std::vector<int32_t> _city_output_factors_q16;
    std::vector<uint64_t> _city_output_scope_cells_scratch;
    std::vector<int32_t> _city_output_scope_stat_ids_scratch;
    // Epoch-transient country/type availability cache. Technology authority is
    // frozen once per daily transaction, so every cell in a country shares the
    // same result and hot loops can consume the ascending CSR directly.
    std::vector<uint8_t> _epoch_country_building_available;
    std::vector<uint8_t> _epoch_country_good_available;
    std::vector<uint8_t> _epoch_country_market_available;
    std::vector<uint8_t> _epoch_country_profession_available;
    std::vector<uint8_t> _epoch_country_variant_available;
    std::vector<int32_t> _epoch_country_building_type_offsets;
    std::vector<int32_t> _epoch_country_building_type_indices;
    // Social-development inputs frozen with the country epoch. Technology
    // progress is one popcount per country; the per-cell value additionally
    // folds in settlement tier and local built-industry variety so the hot loop
    // only reads a single Q16 per cell.
    std::vector<int32_t> _epoch_country_technology_progress_q16;
    std::vector<int32_t> _epoch_cell_development_q16;
    // Population-weighted survival-plan cost per person per day, refreshed by
    // compute_cell_living_costs_from_basis. Derived diagnostics only: it is the
    // savings dimension's denominator and never moves money.
    std::vector<int64_t> _cell_living_cost_per_capita;
    // Last published social-pressure level per cell. Persisted so a reload does
    // not replay a level-crossing event that already fired.
    EconomyOwnedColumn<uint8_t> _cell_social_pressure_level{{{16, 14}, "native_columns.cell_social_pressure_level", EconomyFieldEncoding::U8, 1}};
    // Slow EMA of the surplus×sat mix factor. Fertility reads this so a single
    // harvest spike does not jump K_eff. Persisted in PKEC v36.
    EconomyOwnedColumn<int32_t> _cell_support_ema_q16{{{16, 15}, "native_columns.cell_support_ema_q16", EconomyFieldEncoding::I32, 4}};
    // Derived carrying diagnostics. Not hashed except support EMA; Inspector only.
    std::vector<int64_t> _cell_carrying_k_geo;
    std::vector<int64_t> _cell_carrying_k_eff;
    std::vector<int32_t> _cell_carrying_surplus_q16;
    std::vector<int32_t> _cell_carrying_sat_q16;
    std::vector<int32_t> _cell_carrying_family_surplus_q16;
    std::vector<uint8_t> _cell_carrying_family_bindable;
    // Previous completed-period food-flow authority. The *_period lanes are
    // worker/settlement accumulators for the current epoch; demography reads
    // only the *_previous lanes.
    std::vector<int64_t> _cell_food_output_eq_period;
    std::vector<int64_t> _cell_food_input_eq_period;
    std::vector<int64_t> _cell_food_import_eq_period;
    std::vector<int64_t> _cell_food_export_eq_period;
    std::vector<int64_t> _cell_food_access_eq_period;
    EconomyOwnedColumn<int64_t> _cell_food_output_eq_previous{{{16, 8}, "native_columns.cell_food_output_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_input_eq_previous{{{16, 7}, "native_columns.cell_food_input_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_import_eq_previous{{{16, 6}, "native_columns.cell_food_import_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_export_eq_previous{{{16, 4}, "native_columns.cell_food_export_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_food_access_eq_previous{{{16, 3}, "native_columns.cell_food_access_eq_previous", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<uint8_t> _cell_food_flow_valid{{{16, 5}, "native_columns.cell_food_flow_valid", EconomyFieldEncoding::U8, 1}};
    EconomyTrackedScalar<int32_t> _food_flow_previous_period_days{_metadata_changes, {{15, 16}, "metadata.food_flow_previous_period_days", EconomyFieldEncoding::I32, 4}, 0};
    int64_t _food_output_events = 0;
    int64_t _food_input_events = 0;
    int64_t _food_trade_events = 0;
    int64_t _food_access_events = 0;
    int64_t _carrying_old_resource_scan_steps = 0;
    int32_t _epoch_country_count = 0;
    int32_t _epoch_country_technology_words = 0;
    uint64_t _epoch_country_generation = 0;
    uint64_t _epoch_country_hash = 0;
    uint64_t _epoch_country_topology_hash = 0;
    // Merchant capacity is frozen with the country snapshot so dispatch does
    // not rescan every map cell on each trade slice.
    std::vector<int64_t> _epoch_country_merchant_population;
    // Frozen at the same epoch boundary for the small-country birth bonus.
    std::vector<int64_t> _epoch_country_population;
    std::vector<BuildingType> _building_types;
    std::vector<std::string> _production_climate_profile_ids;
    std::vector<ProductionClimateProfile> _production_climate_profiles;
    // Catalog-baked, sorted unique signal edges per building type. Topology
    // rebuilds consume these spans instead of walking nested recipe columns.
    std::vector<int32_t> _building_type_market_signal_goods;
    std::vector<int32_t> _building_type_labor_signal_professions;
    std::vector<JobRole> _building_employee_roles;
    std::vector<GoodAmount> _building_construction_goods;
    // Candidate CSR is parallel to _building_construction_goods. The legacy
    // preferred good remains the first-class group identity; each slice is an
    // OR list of regional substitutes for that required group.
    std::vector<int32_t> _building_construction_candidate_offsets;
    std::vector<ConstructionCandidate> _building_construction_candidates;
    std::vector<int32_t> _building_maintenance_author_offsets;
    std::vector<GoodAmount> _building_maintenance_author_goods;
    std::vector<GoodAmount> _building_maintenance_goods;
    std::vector<ProductionInput> _building_inputs;
    // Catalogue-static physical quantity for each input candidate row
    // (input quantity / candidate efficiency, rounded up). Recomputed by the
    // selection hot path before; only depends on catalogue data.
    std::vector<int64_t> _building_input_candidate_physical_daily;
    std::vector<InputCandidate> _building_input_candidates;
    std::vector<GoodAmount> _building_outputs;
    std::vector<int32_t> _building_output_cost_shares_q16;
    std::vector<ResourceAmount> _building_resources;
    std::vector<ResourceAmount> _building_resource_generation;
    std::vector<ConditionToken> _building_conditions;
    // A+Y N2: buildings_store() is the sole building-group storage. Hot paths
    // read and write it through building_at() / building_count(); there is no
    // AoS scratch lane to materialize or flush.
    // Kit settlement may append groups during LEDGER_APPLY. Reordering and
    // market-signal rebuild wait for BUILDING_COMMIT so frozen epoch group
    // indices and production reserves stay aligned. Idle-boundary landings
    // rebuild immediately and leave this false.
    bool _pending_building_topology_rebuild = false;
    // Handle -> compact group index acceleration for the group lane. Rebuilt
    // lazily whenever the group lane changes size and verified on every hit,
    // so a stale entry degrades into a rebuild instead of a wrong index.
    mutable std::unordered_map<uint64_t, int32_t> _building_handle_index;
    mutable size_t _building_handle_index_stamp = static_cast<size_t>(-1);
    mutable bool _building_handle_index_clean = false;
    // Transient topology scratch and reusable role/input spans. Structural
    // commits swap the compact group lane but keep authoritative role arrays
    // in place; these caches are reconstructed after configure/restore.
    // Destination order over the current group lane plus the matching
    // is-new flags, consumed by permute_building_group_columns().
    std::vector<int32_t> _building_group_order_scratch;
    std::vector<uint8_t> _building_group_is_new_scratch;
    std::vector<int32_t> _building_existing_indices_scratch;
    std::vector<int32_t> _building_new_indices_scratch;
    std::vector<int64_t> _building_investment_score_rebuild_scratch;
    std::vector<int64_t> _building_investment_payback_rebuild_scratch;
    std::vector<int32_t> _building_investment_rejection_rebuild_scratch;
    std::vector<std::vector<BuildingRoleSpan>> _building_free_role_spans_by_type;
    std::vector<uint32_t> _building_market_signal_stamp;
    std::vector<uint32_t> _building_labor_signal_stamp;
    uint32_t _building_market_signal_stamp_generation = 0;
    uint32_t _building_labor_signal_stamp_generation = 0;
    std::vector<int32_t> _building_cell_offsets;
    std::vector<int32_t> _building_active_cells;
    std::vector<int32_t> _building_visual_cell_offsets;
    std::vector<int32_t> _building_visual_type_indices;
    std::vector<int64_t> _building_visual_counts;
    std::vector<int32_t> _building_visual_dirty_cells;
    uint64_t _building_visual_generation = 0;
    // Presentation-only social bands with hysteresis: not persisted and not
    // part of the state hash; rebuilt from cohorts on read_view_reset().
    std::vector<uint8_t> _visual_living_level;
    std::vector<uint8_t> _visual_rich_bucket;
    std::vector<uint8_t> _visual_poor_bucket;
