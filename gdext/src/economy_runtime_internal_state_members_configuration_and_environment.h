// Economy catalog data, profession tables, world inputs, and resource stock.

    std::vector<FormulaDefinition> _formulas;
    std::unordered_map<std::string, int32_t> _formula_by_id;
    std::vector<Signature> _signatures;
    // Dense (profession_id * n_ethnicity + ethnicity_id) -> signature_id lookup,
    // -1 when absent. Built once alongside _signatures. Lets the employment pass
    // resolve "the signature for this profession worker of this ethnicity" and
    // "the unemployed signature for this ethnicity" in O(1) without scanning.
    std::vector<int32_t> _signature_by_profession_ethnicity;
    std::vector<Plan> _plans;
    std::vector<Need> _needs;
    std::vector<VariantChoice> _variants;
    std::vector<NeedComponent> _components;
    // Catalog-only equivalence for the market/environment part of preview.
    // Actor wealth, family preferences and quantities still run per cohort.
    std::vector<int32_t> _preview_need_basis_source;
    std::vector<EnvironmentCurve> _environment_curves;
    std::vector<std::string> _need_ids;
    std::vector<int32_t> _ethnicity_need_factor_q16;
    std::vector<Rule> _rules;
    std::vector<int64_t> _rule_params;
    EconomyKeyedVariableRecords<std::string> _profession_ids{{{26, 9}, "catalog_ids.profession_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _profession_class_index;
    // Days of the cell's per-capita living cost a cohort must hold per person
    // before members may move into this profession from a lower-entry one.
    std::vector<int32_t> _profession_entry_savings_days;
    // Days of owner living cost and maintenance a private investment must
    // pre-fund for this profession. Authored per tier: a few days for entry
    // collectors, a full month for capital-intensive professions.
    std::vector<int32_t> _profession_startup_capital_days;
    // Military v1 (design §5.1). `state_service_only` professions (the soldier)
    // may only be filled as employee roles of state buildings and never transfer
    // OUT of their own signature along any recruitment/reflux/migration lane.
    // `_profession_state_supplied_need_mask` is laid out as
    // [profession * _need_ids.size() + stable_need]; a need flagged here is a
    // military ration need whose satisfaction comes from
    // `set_military_ration_satisfaction` instead of a market purchase.
    std::vector<uint8_t> _profession_state_service_only;
    std::vector<uint8_t> _profession_state_supplied_need_mask;
    // Any nonzero entry means some profession has state-supplied needs, so the
    // household and employment hot loops can keep their fast path.
    int32_t _state_supplied_need_columns = 0;
    // Reserved owner sentinel for state buildings. The signature id is resolved
    // from the reserved flag so no real cohort can ever collide with it.
    int32_t _state_owner_signature = -1;
    // Per-cell military ration satisfaction (Q16, 1.0 = fully supplied).
    // Deterministic scratch cache owned by Military via
    // set_military_ration_satisfaction; absent cells read Q16_ONE so a world
    // without soldiers is bit-identical to the pre-military behaviour.
    std::vector<int32_t> _military_ration_sat_q16;
    std::vector<uint8_t> _military_ration_sat_present;
    // Military-owned per-cell garrison heads/ration inputs for the rebellion
    // suppression odds. Sparse-writing Military pushes only cells with lots.
    std::vector<int32_t> _cell_garrison_heads;
    std::vector<uint8_t> _cell_garrison_present;
    // Sparse (cell, profession) organization state. Rows exist only where a
    // profession is aggrieved or a chain is active; see
    // runtime_economy_stratum_mobilization.h.
    StratumMobilizationStore _stratum_mobilization;
    // Per-profession static content compiled once from the profession catalog.
    std::vector<uint16_t> _profession_mobilization_floor_q16;
    std::vector<uint16_t> _profession_political_weight_q16;
    std::vector<uint8_t> _profession_mobilization_config_ready;

    enum StateBuildingRole : int32_t {
        STATE_ROLE_NONE = 0,
        STATE_ROLE_BARRACKS = 1,
        STATE_ROLE_FORTIFICATION = 2,
        STATE_ROLE_WAR_COLLEGE = 3,
    };
    std::vector<std::string> _carrying_class_ids;
    std::vector<int32_t> _profession_political_class_index;
    // Profession x need Q16 spending basket, from each profession's consumption
    // plan. Published as the need-spend incidence channels; never written by
    // gameplay and never part of the conserved ledgers.
    std::vector<int32_t> _profession_need_weight_q16;
    std::vector<std::string> _political_class_ids;
    uint64_t _political_class_hash = 0;
    RuntimeCommittedViewVersion _lineage_opinion_view_version;
    std::array<CountryClassOpinionSnapshot, 2> _class_opinion_buffers;
    int32_t _class_opinion_committed_buffer = 0;
    uint64_t _class_opinion_revision = 0;
    std::unique_ptr<struct CountryAiShared> _country_ai;
    void reset_country_ai_pending();
    CountryReadView country_reads() const;
    void publish_country_ai_digest();
    void process_country_ai_colonization_intents(int64_t day_index);
    void mark_country_ai_colonization_demand(std::vector<uint8_t> &demand) const;
    int32_t family_founding_ai_choice(const FamilyFoundingOffer &offer) const;
    uint64_t _class_opinion_cells_scanned = 0;
    uint64_t _class_opinion_slots_scanned = 0;
    uint64_t _class_opinion_zero_population_rows = 0;
    uint64_t _last_class_opinion_cells_scanned = 0;
    uint64_t _last_class_opinion_slots_scanned = 0;
    uint64_t _last_class_opinion_zero_population_rows = 0;
    double _class_opinion_ms = 0.0;
    std::vector<std::string> _carrying_family_ids;
    std::vector<int32_t> _carrying_family_need_stable;
    std::vector<int32_t> _carrying_family_good_offsets;
    std::vector<int32_t> _carrying_family_goods;
    std::vector<int32_t> _need_carrying_family;
    std::vector<int32_t> _carrying_support_resource_ids;
    std::vector<int32_t> _carrying_food_yield_offsets;
    std::vector<CarryingSupportYield> _carrying_food_yields;
    int64_t _carrying_survival_food_per_person = 1;
    std::vector<CarryingSupportYield> _epoch_country_support_yield;
    std::vector<int32_t> _profession_technology_offsets;
    std::vector<int32_t> _profession_required_technologies;
    EconomyKeyedVariableRecords<std::string> _ethnicity_ids{{{26, 6}, "catalog_ids.ethnicity_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _ethnicity_culture_group_ids;
    EconomyKeyedVariableRecords<std::string> _good_ids{{{26, 7}, "catalog_ids.good_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _good_occupancy_bit_offsets;
    std::vector<int32_t> _good_occupancy_bits;
    std::vector<int32_t> _bio_introduce_cells;
    std::vector<int32_t> _bio_introduce_bits;
    // Main-thread only. Production workers land introductions in
    // ProductionResult; merge_building_production_result commits them here.
    std::unordered_set<uint64_t> _bio_introduce_keys;
    EconomyKeyedVariableRecords<std::string> _plan_ids{{{26, 8}, "catalog_ids.plan_ids", EconomyFieldEncoding::CanonicalRecord, 1}};
    std::vector<int32_t> _good_default_price;
    std::vector<int64_t> _good_default_stock;
    std::vector<int32_t> _good_reference_max_price;
    std::vector<int32_t> _good_price_adjust_q16;
    std::vector<int32_t> _good_demand_price_elasticity_q16;
    std::vector<int32_t> _good_household_wealth_elasticity_q16;
    std::vector<int32_t> _good_household_savings_threshold_months_q16;
    std::vector<int32_t> _good_demand_ema_alpha_q16;
    std::vector<int32_t> _good_target_inventory_days_q16;
    std::vector<int32_t> _good_inventory_weight_q16;
    std::vector<int32_t> _good_shortage_weight_q16;
    std::vector<int32_t> _good_excess_demand_weight_q16;
    std::vector<int32_t> _good_cost_anchor_weight_q16;
    std::vector<int32_t> _good_inactive_reversion_weight_q16;
    std::vector<int32_t> _good_business_demand_ema_alpha_q16;
    std::vector<int32_t> _good_supply_ema_alpha_q16;
    std::vector<int32_t> _good_cost_ema_alpha_q16;
    std::vector<int32_t> _good_max_price_rise_q16;
    std::vector<int32_t> _good_max_price_fall_q16;
    std::vector<int32_t> _good_merchant_buy_factor_q16;
	std::vector<uint8_t> _good_trade_enabled;
	std::vector<int32_t> _good_transport_load_per_unit_q16;
	std::vector<std::string> _good_category_ids;
	std::vector<int32_t> _good_storage_modes;
	std::vector<int64_t> _good_monetary_issue_values;
	std::vector<int32_t> _cycle_flow_good_ids;
	std::vector<int32_t> _good_technology_tag_offsets;
	std::vector<std::string> _good_technology_tags;
    std::vector<int32_t> _good_technology_offsets;
    std::vector<int32_t> _good_required_technologies;
    std::vector<int32_t> _merchant_primary_slot;
    std::vector<int32_t> _merchant_offsets;
    std::vector<int32_t> _merchant_slots;
    // Derived CSR invalidation; never persisted or hashed.
    bool _merchant_ranges_dirty = false;
    // 有商人的格，按格号升序，与 CSR 同一次构建产出。capture_country_epoch 原来
    // 为聚合每国商人人口扫整张地图；商人只存在于少数有人口的格，列表让它按实际
    // 端点数走。_valid=false 时消费方退回全图循环，语义不变。
    std::vector<int32_t> _merchant_nonempty_cells;
    bool _merchant_nonempty_cells_valid = false;
    EconomyOwnedColumn<int32_t> _environment_temperature_q16{{{16, 42}, "persisted_columns.environment_temperature_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_temperature_30d_q16{{{16, 41}, "persisted_columns.environment_temperature_30d_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_moisture_q16{{{16, 37}, "persisted_columns.environment_moisture_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_plant_available_water_q16{{{16, 38}, "persisted_columns.environment_plant_available_water_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_precipitation_q16{{{16, 39}, "persisted_columns.environment_precipitation_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_snow_q16{{{16, 40}, "persisted_columns.environment_snow_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _environment_weather_q16{{{16, 43}, "persisted_columns.environment_weather_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_temperature_annual_q16{{{16, 52}, "persisted_columns.cell_temperature_annual_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_temperature_anomaly_q16{{{16, 53}, "persisted_columns.cell_temperature_anomaly_q16", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_hazard_today_mask{{{16, 54}, "persisted_columns.cell_hazard_today_mask", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_dry_streak_days{{{16, 55}, "persisted_columns.cell_dry_streak_days", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<int32_t> _cell_days_since_hazard{{{16, 56}, "persisted_columns.cell_days_since_hazard", EconomyFieldEncoding::I32, 4}};
    EconomyOwnedColumn<uint8_t> _cell_previous_hazard_mask{{{16, 57}, "persisted_columns.cell_previous_hazard_mask", EconomyFieldEncoding::U8, 1}};
    EconomyOwnedColumn<uint8_t> _cell_weather_type{{{16, 58}, "persisted_columns.cell_weather_type", EconomyFieldEncoding::U8, 1}};
    EconomyOwnedColumn<uint8_t> _cell_cover{{{16, 59}, "persisted_columns.cell_cover", EconomyFieldEncoding::U8, 1}};
    std::vector<int32_t> _building_elevation_q16;
    std::vector<uint8_t> _building_terrain;
    std::vector<uint8_t> _building_landform;
    std::vector<uint8_t> _building_vegetation;
    std::vector<uint8_t> _building_is_water;
    std::vector<uint8_t> _building_has_river;
    std::vector<int32_t> _building_neighbors;
    // X12 derived geography columns. Rebuilt only when the territory hash or
    // canal topology hash changes; never persisted.
    std::vector<int32_t> _epoch_cell_geo_flags;
    std::vector<int32_t> _epoch_cell_waterway_component_size;
    uint64_t _geo_flags_territory_hash = 0;
    uint64_t _geo_flags_canal_hash = 0;
    std::atomic<uint64_t> _geo_flags_rebuilds{0};
    // X9-a derived family aggregates. Rebuilt only when the authoritative
    // branch columns change; a daily seal is not a content change.
    std::vector<int32_t> _epoch_cell_family_branch_count;
    std::vector<int64_t> _epoch_cell_max_branch_prestige_q16;
    std::vector<int32_t> _epoch_cell_family_asset_share_q16;
    uint64_t _family_cell_metric_signature = 0;
    std::vector<uint8_t> _family_cell_metric_changed_cells;
    std::atomic<uint64_t> _family_cell_metric_rebuilds{0};
    // X9-b derived country columns. Rebuilt in the same FAMILY_COMMIT pass as
    // the cell aggregates, then published to each country's anchor cell.
    std::vector<int32_t> _epoch_country_family_remote_branch_count;
    std::vector<int32_t> _epoch_country_families_with_at_least_3_branches;
    std::vector<int64_t> _epoch_country_oldest_family_founded_day;
    std::vector<int64_t> _epoch_country_family_founded_day_sum;
    std::vector<int32_t> _epoch_country_family_count;
    uint64_t _family_country_metric_signature = 0;
    std::vector<uint8_t> _family_country_metric_changed_countries;
    std::atomic<uint64_t> _family_country_metric_rebuilds{0};
    // X14 derived country columns. Copied from the last COMMITTED class
    // opinion snapshot at commit finalize; never persisted.
    std::vector<int64_t> _epoch_country_class_satisfaction_q16;
    std::vector<int64_t> _epoch_country_weighted_satisfaction_q16;
    std::vector<int64_t> _epoch_country_farmer_satisfaction_q16;
    std::vector<int64_t> _epoch_country_worker_satisfaction_q16;
    std::vector<int64_t> _class_opinion_override_population;
    std::vector<int32_t> _class_opinion_override_satisfaction_q16;
    std::vector<int64_t> _class_opinion_override_weighted;
    bool _class_opinion_source_override_enabled = false;
    // Test-only synthetic publication identity. The worker settles once per
    // committed day, so reusing the frozen source's identity would make every
    // controlled row update after the first one a no-op.
    uint64_t _class_opinion_override_revision = 0;
    int64_t _class_opinion_override_commit_day = -1;
    uint64_t _class_metric_source_revision = 0;
    uint64_t _class_metric_source_content_hash = 0;
    int64_t _class_metric_source_epoch_day = -1;
    std::atomic<uint64_t> _class_metric_rebuilds{0};
    // X10 derived country columns. The domain table is copied once from the
    // immutable Country catalog at configure; `_technology_domain_masks` holds
    // one mask per technology word per domain (the shipped catalog has >64
    // technologies). Counts are rebuilt only when the technology bitset content
    // changes, never on ordinary country state.
    std::vector<int32_t> _technology_domain_ids;
    std::vector<uint64_t> _technology_domain_masks;
    std::vector<int64_t> _epoch_country_completed_tech_count;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_0;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_1;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_2;
    std::vector<int64_t> _epoch_country_completed_tech_count_domain_3;
    // X13 residual: derived from the frozen climate counters and the country
    // territory CSR once per capture. Never persisted or hashed.
    std::vector<int32_t> _epoch_country_hazard_free_cell_share_q16;
    std::vector<uint64_t> _technology_metric_input_override;
    bool _technology_metric_input_override_enabled = false;
    uint64_t _technology_metric_source_hash = 0;
    std::atomic<uint64_t> _technology_metric_rebuilds{0};
    // X7-b frozen Country projection. Signal words are copied from the same
    // immutable Country commit as technologies; the three Economy counts are
    // derived from committed building/geography columns during epoch capture.
    std::vector<uint64_t> _epoch_country_research_signals;
    int32_t _epoch_country_research_signal_words = 0;
    std::vector<int32_t> _epoch_country_energy_cell_count;
    std::vector<int32_t> _epoch_country_abundant_mountain_forest_cell_count;
    std::vector<int32_t> _epoch_country_landform_signal_count;
    std::vector<int32_t> _epoch_country_weather_signal_count;
    std::vector<int32_t> _epoch_country_bio_signal_count;
    // X8 derived cell column. `_neighbor_distinct_goods_source_hash` is the
    // committed production shape (building groups, neighbour graph, and each
    // cell's dominant output) that can change the answer. A hash miss rebuilds
    // the column and advances the counter; an unchanged idle day does neither.
    std::vector<int32_t> _epoch_cell_neighbor_distinct_goods;
    uint64_t _neighbor_distinct_goods_source_hash = 0;
    std::atomic<uint64_t> _neighbor_distinct_goods_rebuilds{0};
    // A+Y N5/N9: unbound fallback for the live resource lanes. While a store is
    // bound these stay empty and the accessors alias OwnedState::resources.
    EconomyTrackedColumn<int64_t> _resource_snapshot{_resource_changes_local,
        {{3, 1}, "resource.stock", EconomyFieldEncoding::I64, 8}};
    std::vector<int64_t> _resource_remaining;
    // Per-epoch extract allowance for renewable resources. This is derived from
    // the frozen reserve, never serialized, and is shared by all local extractors.
    std::vector<int64_t> _resource_harvest_remaining;
    std::vector<int64_t> _resource_gen_base;
    std::vector<int64_t> _resource_gen_temp;
    std::vector<int64_t> _resource_gen_moisture;
    std::vector<int64_t> _resource_gen_self;
    std::vector<int64_t> _resource_decay_base;
    std::vector<int64_t> _resource_decay_temp;
    std::vector<int64_t> _resource_decay_moisture;
    std::vector<int32_t> _resource_decay_self_q16;
    std::vector<int64_t> _resource_ecology_capacity;
    std::vector<int32_t> _resource_ecology_growth_q16;
    std::vector<int32_t> _resource_temp_lo_q16;
    std::vector<int32_t> _resource_temp_hi_q16;
    std::vector<int32_t> _resource_climate_temp_opt_q16;
    std::vector<int32_t> _resource_climate_temp_tol_q16;
    std::vector<int32_t> _resource_climate_moisture_opt_q16;
    std::vector<int32_t> _resource_climate_moisture_tol_q16;
    std::vector<int32_t> _resource_runtime_fit_weight_q16;
    std::vector<int32_t> _resource_temperature_signal;
    std::vector<int32_t> _resource_moisture_signal;
    std::vector<int64_t> _resource_deltas;
    std::vector<uint32_t> _resource_lane_generation;
    // A restored resource stock is authoritative until the first post-restore
    // building-context capture has consumed the matching map snapshot.
    bool _resource_stock_restored_pending_capture = false;
    // Worker-owned reserves: after the first worker capture the main-thread
    // reserve/extra slots are only a display mirror. Their content at capture
    // time depends on how far the main thread ran ahead of the worker.
    std::vector<WorkerNaturalResource> _worker_natural_resources;
    bool _worker_resource_seeded = false;
    std::vector<float> _worker_resource_reserve;
    std::vector<float> _worker_resource_extra;
    std::vector<uint8_t> _worker_resource_extra_dirty;
    std::vector<int32_t> _worker_resource_last_day;
    std::vector<uint8_t> _worker_resource_was_live;
    std::vector<uint8_t> _worker_resource_cell_live;
    std::vector<int32_t> _worker_resource_live_cells;
    std::vector<uint8_t> _worker_resource_mirror_mark;
    std::vector<int32_t> _worker_resource_mirror_cells;
    std::vector<float> _worker_resource_regen_factors;
    int32_t _worker_resource_recovered_cells = 0;
    bool advance_worker_resource_reserves(const RuntimeEconomyDayInput &input,
                                          std::string &error);
    void fold_worker_resource_deltas();
    void write_worker_resource_stock(size_t lane);
    void mark_worker_resource_mirror_cell(int32_t cell);
    std::vector<size_t> _resource_touched_lanes;
    std::vector<size_t> _last_published_resource_touched_lanes;
    uint32_t _resource_current_generation = 0;
    // Debug/recording visibility for the most recently published building
    // resource changes. It is derived epoch output, not save/hash authority.
    std::vector<int64_t> _last_published_resource_deltas;
    std::vector<std::string> _resource_ids;
    std::vector<std::string> _modifier_sector_ids;
    std::vector<std::string> _modifier_terrain_ids;
    std::vector<std::string> _modifier_landform_ids;
    std::vector<std::string> _resource_reserve_slots;
    std::vector<std::string> _resource_extra_slots;
    int64_t _building_context_day = -1;
    bool _resource_deltas_ready = false;
    EconomyTrackedScalar<int64_t> _environment_day{_metadata_changes, {{15, 10}, "metadata.environment_day", EconomyFieldEncoding::I64, 8}, -1};
    EconomyTrackedScalar<int64_t> _environment_hash{_metadata_changes, {{15, 11}, "metadata.environment_hash", EconomyFieldEncoding::I64, 8}, 0};
    std::vector<int32_t> _market_cell_offsets;
    std::vector<int32_t> _market_cells;
    EconomyTrackedRecords<Command> _pending_commands{{{14, 1}, "commands.pending_commands", EconomyFieldEncoding::CanonicalRecord, 1}};
    EconomyTrackedRecords<Command> _epoch_commands{{{14, 2}, "commands.epoch_commands", EconomyFieldEncoding::CanonicalRecord, 1}};
