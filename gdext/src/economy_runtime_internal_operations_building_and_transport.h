// Building and lineage configuration data and route graph setup operations.

    // Transient CSR baked from stable building order. Recovery reviews touch
    // only the current cell-modulo-review bucket instead of scanning all groups.
    std::vector<int32_t> _building_review_phase_offsets;
    std::vector<int32_t> _building_review_group_indices;
    std::vector<int32_t> _building_special_reset_group_indices;
    ChangeRegistry _building_role_changes;
    EconomyTrackedColumn<int64_t> _building_employee_filled{_building_role_changes, {{10, 1}, "building_roles.building_employee_filled", EconomyFieldEncoding::I64, 8}};
    // Inspector-only last purchased good per (building group, input slot).
    // This diagnostic lane is intentionally excluded from save and state hash.
    std::vector<int32_t> _building_last_input_selected_goods;
    EconomyTrackedColumn<int64_t> _building_role_contract_wage{_building_role_changes, {{10, 2}, "building_roles.building_role_contract_wage", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_base_living_cost{_building_role_changes, {{10, 3}, "building_roles.building_role_base_living_cost", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_living_cost{_building_role_changes, {{10, 4}, "building_roles.building_role_living_cost", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_local_average_wage{_building_role_changes, {{10, 5}, "building_roles.building_role_local_average_wage", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_base_wage_due{_building_role_changes, {{10, 6}, "building_roles.building_role_base_wage_due", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_base_wage_paid{_building_role_changes, {{10, 7}, "building_roles.building_role_base_wage_paid", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_bonus_due{_building_role_changes, {{10, 8}, "building_roles.building_role_bonus_due", EconomyFieldEncoding::I64, 8}};
    EconomyTrackedColumn<int64_t> _building_role_bonus_paid{_building_role_changes, {{10, 9}, "building_roles.building_role_bonus_paid", EconomyFieldEncoding::I64, 8}};
    // Epoch-derived cold-start funding ceiling. This is rebuilt before
    // employment from demand-backed absorption and is intentionally excluded
    // from PKEC and the authoritative state hash.
    std::vector<int32_t> _building_role_forecast_pay_ratio_q16;
    // A+Y N8: pending construction lives in buildings_store().pending_*; hot
    // paths reach it through pending_construction() / pending_construction_at().
    // Epoch-transient stable CSR over those pending columns. This removes the
    // previous all-pending scan from every active building cell.
    std::vector<int32_t> _pending_construction_cell_offsets;
    std::vector<int32_t> _pending_construction_cell_indices;
    EconomyTrackedScalar<int64_t> _building_catalog_hash{_metadata_changes, {{15, 1}, "metadata.building_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _building_catalog_compat_hash_v6 = 0;
    int64_t _building_catalog_compat_hash_v7 = 0;
    int64_t _building_catalog_compat_hash_v13 = 0;
    int64_t _catalog_compat_hash_v7 = 0;
    int64_t _catalog_compat_hash_v8 = 0;
    EconomyTrackedScalar<int64_t> _catalog_compat_hash_v10{_metadata_changes, {{15, 2}, "metadata.catalog_compat_hash_v10", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _catalog_compat_hash_v13 = 0;
    int64_t _catalog_compat_hash_v39 = 0;
    EconomyTrackedScalar<int64_t> _family_catalog_hash{_metadata_changes, {{15, 40}, "config.family_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _family_catalog_compat_hash_v39 = 0;
    EconomyTrackedScalar<int32_t> _family_trait_catalog_version{_metadata_changes, {{15, 15}, "metadata.family_trait_catalog_version", EconomyFieldEncoding::I32, 4}, 0};
    EconomyTrackedScalar<int64_t> _family_trait_catalog_hash{_metadata_changes, {{15, 14}, "metadata.family_trait_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    int32_t _family_core_trait_min = 0;
    int32_t _family_core_trait_max = 0;
    std::vector<std::string> _family_trait_ids;
    std::vector<std::string> _family_trait_display_names;
    std::vector<int32_t> _family_trait_weights;
    std::vector<uint8_t> _family_trait_core_eligible;
    std::vector<int32_t> _family_trait_strength_min_q16;
    std::vector<int32_t> _family_trait_strength_max_q16;
    std::vector<int32_t> _family_trait_strength_step_q16;
    std::vector<int32_t> _family_trait_prerequisite_offsets;
    std::vector<int32_t> _family_trait_prerequisites;
    std::vector<int32_t> _family_trait_exclusion_offsets;
    std::vector<int32_t> _family_trait_exclusions;
    std::vector<int32_t> _family_trait_technology_prerequisite_offsets;
    std::vector<int32_t> _family_trait_technology_prerequisites;
    std::vector<uint8_t> _family_trait_technology_match_any;
    std::vector<int32_t> _family_trait_behavior_offsets;
    std::vector<int32_t> _family_trait_behavior_axes;
    std::vector<int32_t> _family_trait_behavior_selector_kinds;
    std::vector<int32_t> _family_trait_behavior_selector_ids;
    std::vector<int32_t> _family_trait_behavior_factors_q16;
    std::vector<int32_t> _family_trait_behavior_score_terms;
    std::vector<int32_t> _family_trait_behavior_condition_offsets;
    std::vector<int32_t> _family_trait_behavior_condition_ops;
    std::vector<int32_t> _family_trait_behavior_condition_arg0;
    std::vector<int64_t> _family_trait_behavior_condition_values;
    // Catalog-derived union of metric operands; never persisted or hashed.
    std::vector<MetricMask> _family_trait_behavior_metric_masks;
    std::vector<int32_t> _family_trait_modifier_offsets;
    std::vector<std::string> _family_trait_modifier_definition_keys;
    std::vector<int32_t> _family_trait_modifier_targets;
    std::vector<int32_t> _family_trait_modifier_tier_magnitudes_q16;
    std::vector<int32_t> _family_trait_trigger_offsets;
    std::vector<std::string> _family_trait_trigger_definition_keys_by_tier;
    std::vector<int32_t> _family_trait_trigger_reward_targets;
    std::vector<int32_t> _family_trait_effect_offsets;
    std::vector<std::string> _family_trait_effect_keys;
    std::vector<int32_t> _family_trait_origin_landform_offsets;
    std::vector<uint8_t> _family_trait_origin_landforms;
    std::vector<uint8_t> _family_trait_origin_adjacent_water;
    std::vector<int32_t> _family_trait_origin_population_max;
    std::vector<int32_t> _family_trait_origin_temperature_max_q16;
    std::vector<int32_t> _family_trait_required_resource_offsets;
    std::vector<int32_t> _family_trait_required_resource_ids;
    std::vector<uint8_t> _family_trait_require_tax_or_subsidy;
    int32_t _family_effect_catalog_version = 0;
    int64_t _family_effect_catalog_hash = 0;
    std::vector<std::string> _family_effect_keys;
    std::vector<int32_t> _family_effect_source_kinds;
    std::vector<int32_t> _family_effect_weights;
    std::vector<uint8_t> _family_effect_random_pool_eligible;
    std::vector<int32_t> _family_effect_prerequisite_offsets;
    std::vector<int32_t> _family_effect_prerequisites;
    std::vector<uint8_t> _family_effect_technology_match_any;
    std::vector<int32_t> _family_effect_exclusion_offsets;
    std::vector<int32_t> _family_effect_exclusions;
    std::vector<int32_t> _family_effect_magnitude_by_prestige_q16;
    std::vector<std::string> _family_effect_trigger_definition_keys_by_tier;
    std::vector<int32_t> _family_effect_trigger_reward_targets;
    int32_t _family_corn_good_id = -1;
    int32_t _family_knowledge_class_index = -1;
    struct PendingFamilySplitGift {
        uint64_t family_handle = 0;
        int32_t cell = -1;
        uint16_t flags = 0;
        int32_t building_type_id = -1;
        int32_t building_count = 1;
        int64_t population = 0;
    };
    std::vector<PendingFamilySplitGift> _pending_family_split_gifts;
    std::string _family_surname_pack_id = "default_zh";
    std::vector<std::string> _family_surname_ids;
    std::vector<std::string> _family_surname_text;
    std::vector<int32_t> _family_surname_weights;
    std::vector<int32_t> _family_surname_culture_group_ids;
    std::vector<std::string> _family_culture_group_ids;
    std::vector<std::string> _family_culture_group_display_names;
    std::vector<std::string> _family_culture_group_naming_formats;
    std::vector<std::string> _family_culture_group_separators;
    std::vector<std::string> _family_culture_group_suffixes;
    EconomyTrackedScalar<int64_t> _person_catalog_hash{_metadata_changes, {{15, 73}, "config.person_catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    std::string _person_given_name_pack_id = "default_zh";
    std::vector<std::string> _person_given_name_ids;
    std::vector<std::string> _person_given_name_text;
    std::vector<int32_t> _person_given_name_weights;

    // Notable-family policy. The anonymous majority remains implicit.
    EconomyTrackedScalar<int32_t> _family_runtime_mode{_metadata_changes, {{15, 45}, "config.family_runtime_mode", EconomyFieldEncoding::I32, 4}, 2}; // 0=OFF, 1=PROBE, 2=ACTIVE.
    EconomyTrackedScalar<int32_t> _family_review_days{_metadata_changes, {{15, 44}, "config.family_review_days", EconomyFieldEncoding::I32, 4}, 30};
    // Ascending committed-population thresholds; each one crossed by a cell
    // produces one founding offer. Starter capital founders do not count.
    std::vector<int64_t> _family_milestone_populations{
        60, 100, 200, 500, 1000, 2000, 5000, 10000, 20000};
    EconomyTrackedScalar<int64_t> _family_min_founder_people{_metadata_changes, {{15, 43}, "config.family_min_founder_people", EconomyFieldEncoding::I64, 8}, 30};
    int32_t _family_founding_choice_mode = 1; // 0=AUTO, 1=PLAYER.
    EconomyTrackedScalar<int64_t> _family_split_population_threshold{_metadata_changes, {{15, 46}, "config.family_split_population_threshold", EconomyFieldEncoding::I64, 8}, 100};
    EconomyTrackedScalar<int32_t> _family_max_per_cell{_metadata_changes, {{15, 42}, "config.family_max_per_cell", EconomyFieldEncoding::I32, 4}, 8};
    int32_t _family_cells_per_slice = 128;
    EconomyTrackedScalar<int32_t> _family_decline_reviews{_metadata_changes, {{15, 41}, "config.family_decline_reviews", EconomyFieldEncoding::I32, 4}, 3};
    // Notable households include dependents of the owned owner posts, not just
    // the two shopkeepers. Anonymous majority stays implicit.
    int32_t _family_household_people_per_owner_slot = 256;
    int32_t _family_household_max_people = 1024;
    EconomyTrackedScalar<int32_t> _person_runtime_mode{_metadata_changes, {{15, 78}, "config.person_runtime_mode", EconomyFieldEncoding::I32, 4}, 2}; // 0=OFF, 1=PROBE, 2=ACTIVE.
    EconomyTrackedScalar<int32_t> _person_max_per_family{_metadata_changes, {{15, 75}, "config.person_max_per_family", EconomyFieldEncoding::I32, 4}, 4};
    EconomyTrackedScalar<int32_t> _person_max_per_cell{_metadata_changes, {{15, 74}, "config.person_max_per_cell", EconomyFieldEncoding::I32, 4}, 128};
    EconomyTrackedScalar<int32_t> _person_max_total{_metadata_changes, {{15, 76}, "config.person_max_total", EconomyFieldEncoding::I32, 4}, 65536};
    EconomyTrackedScalar<int32_t> _person_records_per_slice{_metadata_changes, {{15, 77}, "config.person_records_per_slice", EconomyFieldEncoding::I32, 4}, 4096};

    SaveState _save;
    RestoreState _restore;

    void register_builtin_formulas();
    bool compile_catalog(const godot::Dictionary &catalog, std::string &error);
    bool configure_profile(const godot::Dictionary &profile, std::string &error);
    godot::Dictionary run_slice_internal(const godot::Dictionary &ctx, bool compact);
    godot::Dictionary compact_report() const;
    godot::Dictionary household_slice_breakdown_ms() const;
    godot::Dictionary household_slice_breakdown_work() const;
    bool start_epoch(int64_t day_index, std::string &error);
    void clear_demand_basis_day();
    void register_demand_basis_cell(int32_t cell);
    size_t demand_basis_row_width() const;
    void store_demand_basis_row(int32_t slot,
                                const std::vector<int64_t> &variant_scores,
                                const std::vector<int64_t> &variant_prices,
                                const std::vector<int64_t> &need_score_sums,
                                const std::vector<int64_t> &need_composites,
                                const std::vector<int64_t> &need_environment);
    godot::Dictionary demand_basis_cache_report() const;
    bool finish_epoch_start_after_fiscal(int64_t day_index,
                                         std::string &error);
    bool trade_planner_should_run() const;
    bool run_trade_planner_slice(int64_t &work_done, std::string &error);
    bool begin_trade_plan_slice(int64_t &work_done, std::string &error);
    bool trade_vision_allows_pair(int32_t source, int32_t destination) const;
    bool route_trade_source(int32_t source_index, int32_t expansion_budget,
                            int32_t &expansions_done, bool &source_done,
                            std::string &error);
    int32_t cached_trade_route_cost(int32_t source, int32_t destination,
                                    int32_t country, int32_t &expansions);
    void collect_transport_successors(int32_t cell, uint8_t cap, bool reverse);
    void build_water_transport_graphs();
