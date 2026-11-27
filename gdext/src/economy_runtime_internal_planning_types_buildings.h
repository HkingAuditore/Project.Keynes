// Catalog formulas and needs, building groups, construction plans, and sparse storage views.

    struct FormulaBatchInput {
        const int64_t *population = nullptr;
        const int64_t *funds = nullptr;
        const int64_t *income_ema = nullptr;
        int32_t count = 0;
        int32_t price = 0;
        int32_t dt_days = 1;
        const int64_t *params = nullptr;
        int32_t param_count = 0;
    };
    using FormulaBatchFn = void (*)(const FormulaBatchInput &, int64_t *, int64_t &);

    struct FormulaDefinition {
        std::string stable_id;
        int32_t version = 1;
        int32_t min_params = 0;
        int32_t max_params = 0;
        FormulaBatchFn batch = nullptr;
    };

    struct Rule {
        int32_t good_id = -1;
        int32_t formula_id = -1;
        int32_t formula_version = 0;
        int32_t priority = 0;
        int32_t param_begin = 0;
        int32_t param_count = 0;
    };

    struct Plan {
        int32_t need_begin = 0;
        int32_t need_count = 0;
    };

    static constexpr size_t HOUSEHOLD_WEALTH_ANCHOR_COUNT = 15;
    static constexpr std::array<int32_t, HOUSEHOLD_WEALTH_ANCHOR_COUNT>
        HOUSEHOLD_WEALTH_ANCHORS_Q16 = {
            4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288,
            1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864};

    struct Need {
        int32_t stable_id = -1;
        int32_t priority = 0;
        int32_t variant_begin = 0;
        int32_t variant_count = 0;
        int64_t base_qty_per_person = 0;
        int32_t wealth_elasticity_q16 = 0;
        int32_t wealth_min_q16 = 0;
        int32_t wealth_max_q16 = Q16_ONE;
        int32_t price_quantity_elasticity_q16 = Q16_ONE;
        int32_t price_quantity_floor_q16 = 0;
        int32_t quantity_env_curve = -1;
        int32_t living_cost_weight_q16 = 0;
        // Composite satisfaction classification, resolved from the need catalog
        // rather than from need id strings.
        int32_t satisfaction_tier = SAT_DIM_BASIC;
        int32_t satisfaction_weight_q16 = Q16_ONE;
        std::array<int32_t, HOUSEHOLD_WEALTH_ANCHOR_COUNT> wealth_lut_q16{};
    };

    struct VariantChoice {
        int32_t component_begin = 0;
        int32_t component_count = 0;
        int32_t preference_q16 = Q16_ONE;
        int32_t price_elasticity_q16 = Q16_ONE;
        int32_t preference_env_curve = -1;
        int64_t reference_unit_price = MONEY_SCALE;
        int32_t wealth_elasticity_q16 = 0;
        int32_t savings_threshold_months_q16 = 0;
        std::array<int32_t, HOUSEHOLD_WEALTH_ANCHOR_COUNT> wealth_lut_q16{};
        // 目录证明：任意 i32 价格/消费系数下，预估价格不产生饱和事件。
        bool preview_price_saturation_free = false;
        int32_t price_basis_source = -1;
    };

    struct VariantPriceBasis {
        int64_t unit_price = 1;
        int64_t elasticity_factor = 0;
        int64_t saturations = 0;
        bool available = false;
        bool ready = false;
    };

    struct NeedComponent {
        int32_t good_id = -1;
        int64_t qty_per_need = GOODS_SCALE;
    };

    struct EnvironmentCurve {
        int32_t signal_id = 0;
        int32_t values_q16[ENV_CURVE_SAMPLES]{};
    };

    struct EnvironmentSample {
        int32_t temperature_q16 = Q16_ONE / 2;
        int32_t temperature_30d_q16 = Q16_ONE / 2;
        int32_t moisture_q16 = Q16_ONE / 2;
        int32_t plant_available_water_q16 = Q16_ONE / 2;
        int32_t snow_q16 = 0;
        int32_t weather_q16 = 0;
        bool ready = false;
    };

    struct ProductionClimateProfile {
        int32_t temperature_opt_q16 = Q16_ONE / 2;
        int32_t temperature_tolerance_q16 = Q16_ONE;
        int32_t water_opt_q16 = Q16_ONE / 2;
        int32_t water_tolerance_q16 = Q16_ONE;
        int32_t exposure_q16 = 0;
        int32_t floor_q16 = Q16_ONE;
    };

    struct Signature {
        int32_t profession_id = -1;
        int32_t ethnicity_id = -1;
        int32_t plan_id = -1;
        int64_t birth_rate_q32 = 0;
        int64_t death_rate_q32 = 0;
        int64_t satisfaction_birth_weight_q16 = Q16_ONE;
        // Class-specific composite weights, indexed by SatisfactionDimension.
        std::array<int32_t, SAT_DIM_COUNT> satisfaction_weights_q16{};
    };

    struct BuildingType {
		int32_t kind = 1; // 0=collector, 1=industrial, 2=service, 3=state.
        // State-owned buildings (kind 3) carry an authored role. 0=none and
        // only meaningful for kind 3; barred from investment review, recovery,
        // liquidation, loss closure, family ownership and merchant credit.
        int32_t state_role = 0;
        int32_t economic_sector = 2; // agriculture, extractive, manufacturing, energy, knowledge.
        int32_t production_climate_profile_id = -1;
        int32_t upgrade_family_id = -1;
        int32_t upgrade_tier = 0;
        int32_t owner_profession_id = -1;
        int64_t owner_slots_per_building = 0;
        int32_t employee_begin = 0;
        int32_t employee_count = 0;
        int32_t construction_begin = 0;
        int32_t construction_count = 0;
        int32_t maintenance_begin = 0;
        int32_t maintenance_count = 0;
        int32_t maintenance_horizon_days = 0;
        int32_t input_begin = 0;
        int32_t input_count = 0;
        int32_t output_begin = 0;
        int32_t output_count = 0;
        int32_t resource_begin = 0;
        int32_t resource_count = 0;
        int32_t generation_begin = 0;
        int32_t generation_count = 0;
        int32_t generation_floor_q16 = 0;
        int32_t condition_begin = 0;
        int32_t condition_count = 0;
        int32_t construction_days = 0;
        int32_t behavior_id = 0; // 0=none, 1=consume, 2=cultivate+consume.
        int32_t behavior_version = 1;
        int32_t target_operating_margin_q16 = 0;
        int32_t supply_price_elasticity_q16 = Q16_ONE;
        int32_t output_cost_share_begin = 0;
        int32_t output_cost_share_count = 0;
        int32_t market_signal_begin = 0;
        int32_t market_signal_count = 0;
        int32_t labor_signal_begin = 0;
        int32_t labor_signal_count = 0;
        uint32_t kit_role_mask = 0;
    };

    struct JobRole {
        int32_t profession_id = -1;
        int64_t slots_per_building = 0;
        // Employee wages are discovered from living-cost, market, and
        // employer-profit signals at each planning boundary. Content never
        // supplies a wage amount.
        int32_t wage_policy = 2; // retained for catalog/save compatibility
    };

    struct GoodAmount {
        int32_t good_id = -1;
        int64_t quantity = 0;
    };

    struct ConstructionCandidate {
        int32_t good_id = -1;
        int32_t efficiency_q16 = Q16_ONE;
    };

    struct ConstructionMaterialPlan {
        std::vector<int32_t> good_ids;
        std::vector<int64_t> quantities;
        int64_t total_cost = 0;
        int32_t failed_group = -1;
        bool feasible = false;
    };

    struct ProductionInput {
        int32_t preferred_good_id = -1;
        int64_t quantity = 0;
        int32_t candidate_begin = 0;
        int32_t candidate_count = 0;
        int32_t required_q16 = Q16_ONE;
    };

    struct InputCandidate {
        int32_t good_id = -1;
        int32_t efficiency_q16 = Q16_ONE;
    };

    struct ResourceAmount {
        int32_t resource_id = -1;
        int64_t quantity = 0;
        int32_t mode = 0; // 0=extract per day, 1=capacity per building.
        int32_t access_mode = 0; // 0=local, 1=local plus six hex neighbors.
    };

    struct CarryingSupportYield {
        int32_t building_type_id = -1;
        int32_t resource_id = -1;
        int32_t secondary_resource_id = -1;
        int32_t mode = 1;
        int64_t food_output_per_day = 0;
        int64_t resource_qty = 1;
        int64_t secondary_qty = 0;
    };

    struct ConditionToken {
        int32_t opcode = 0; // 1=predicate, 2=and, 3=or, 4=not.
        int32_t signal = 0;
        int32_t compare = 0;
        int32_t reference = -1;
        int64_t value = 0;
    };

    struct BuildingGroup {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t filled_owner = 0;
        int32_t employee_fill_begin = -1;
        int32_t last_input_selection_begin = -1;
        int64_t last_capacity_q16 = 0;
        int64_t last_temperature_fit_q16 = Q16_ONE;
        int64_t last_water_fit_q16 = Q16_ONE;
        int64_t last_climate_capacity_q16 = Q16_ONE;
        int64_t last_climate_lost_output = 0;
        int64_t last_input = 0;
        int64_t last_output = 0;
        int64_t last_sold = 0;
        int64_t last_discarded = 0;
        int64_t last_resource = 0;
        int64_t last_resource_generated = 0;
        int64_t last_revenue = 0;
        int64_t last_input_cost = 0;
        int64_t last_wages_paid = 0;
        int64_t last_wages_due = 0;
        int64_t last_expected_revenue = 0;
        int64_t last_operating_cost = 0;
        int64_t last_maintenance_cost = 0;
        // Frozen quote and realized cashflow separation. These values are
        // period totals, so prediction can use the last observed receipt
        // instead of treating a nameplate recipe as an actual sale.
        int64_t last_market_receipt = 0;
        int64_t last_bullion_mint_receipt = 0;
        int64_t last_producer_support_receipt = 0;
        int64_t last_business_tax_paid = 0;
        int64_t last_business_subsidy_received = 0;
        int64_t last_maintenance_due = 0;
        // Previous committed period's actual workforce-capacity-days, encoded
        // as Q16 * building-days. Zero means no owner/role capacity was
        // actually present at settlement; it is not a planning estimate.
        int64_t last_observed_capacity_days_q16 = 0;
        int64_t last_quoted_market_receipt = 0;
        int64_t last_quoted_operating_cost = 0;
        int32_t last_margin_gap_q16 = 0;
        int32_t planned_utilization_q16 = Q16_ONE;
        int64_t sample_unit_input_cost = 0;
        int64_t sample_unit_maintenance_cost = 0;
        int64_t last_base_wages_paid = 0;
        int64_t last_base_wages_due = 0;
        int64_t last_bonus_paid = 0;
        int64_t last_bonus_due = 0;
        // Planned purchase/production intent. This may retain a bounded
        // shortage-recovery probe while last_capacity_q16 is zero because a
        // hard input cannot be funded or reserved.
        int64_t purchase_intent_capacity_q16 = 0;
        int32_t realized_profit_margin_q16 = 0;
        uint16_t severe_loss_cycles = 0;
        uint16_t recovery_cycles = 0;
        uint16_t recovery_failed_reviews = 0;
        uint16_t merchant_debt_term_cycles_left = 0;
        uint16_t merchant_debt_delinquent_cycles = 0;
        uint8_t operating_state = 0; // 0=ACTIVE, 1=SUSPENDED_LOSS.
        uint8_t wage_suspended = 0;
        int64_t merchant_debt_principal = 0;
        int64_t merchant_debt_premium = 0;
        int64_t last_in_kind_livelihood_value = 0;
        uint8_t pending_operating_state = 255; // 255=NONE; applied at next due-cell epoch.
        uint16_t recovery_cooldown_cycles = 0;
        uint64_t modifier_handle = 0;
        int32_t output_factor_q16 = Q16_ONE;
    };

// A+Y N2: buildings_store() is the sole building-group storage. This list maps
// every historical BuildingGroup field to its column and fixes the member order
// of BuildingGroupRefT, so one row still reads and writes as `group.count`.
#define PK_BUILDING_GROUP_COLUMNS(X)                                           \
    X(int32_t, cell, cell)                                                     \
    X(int32_t, type_id, type_id)                                               \
    X(int32_t, owner_signature_id, owner_signature_id)                         \
    X(int64_t, count, group_units)                                             \
    X(int64_t, filled_owner, filled_owner)                                     \
    X(int32_t, employee_fill_begin, employee_fill_begin)                       \
    X(int32_t, last_input_selection_begin, last_input_selection_begin)         \
    X(int64_t, last_capacity_q16, last_capacity_q16)                           \
    X(int64_t, last_temperature_fit_q16, last_temperature_fit_q16)             \
    X(int64_t, last_water_fit_q16, last_water_fit_q16)                         \
    X(int64_t, last_climate_capacity_q16, last_climate_capacity_q16)           \
    X(int64_t, last_climate_lost_output, last_climate_lost_output)             \
    X(int64_t, last_input, last_input)                                         \
    X(int64_t, last_output, last_output)                                       \
    X(int64_t, last_sold, last_sold)                                           \
    X(int64_t, last_discarded, last_discarded)                                 \
    X(int64_t, last_resource, last_resource)                                   \
    X(int64_t, last_resource_generated, last_resource_generated)               \
    X(int64_t, last_revenue, last_revenue)                                     \
    X(int64_t, last_input_cost, last_input_cost)                               \
    X(int64_t, last_wages_paid, last_wages_paid)                               \
    X(int64_t, last_wages_due, last_wages_due)                                 \
    X(int64_t, last_expected_revenue, last_expected_revenue)                   \
    X(int64_t, last_operating_cost, last_operating_cost)                       \
    X(int64_t, last_maintenance_cost, last_maintenance_cost)                   \
    X(int64_t, last_market_receipt, last_market_receipt)                       \
    X(int64_t, last_bullion_mint_receipt, last_bullion_mint_receipt)           \
    X(int64_t, last_producer_support_receipt, last_producer_support_receipt)   \
    X(int64_t, last_business_tax_paid, last_business_tax_paid)                 \
    X(int64_t, last_business_subsidy_received, last_business_subsidy_received) \
    X(int64_t, last_maintenance_due, last_maintenance_due)                     \
    X(int64_t, last_observed_capacity_days_q16,                                \
      last_observed_capacity_days_q16)                                         \
    X(int64_t, last_quoted_market_receipt, last_quoted_market_receipt)         \
    X(int64_t, last_quoted_operating_cost, last_quoted_operating_cost)         \
    X(int32_t, last_margin_gap_q16, last_margin_gap_q16)                       \
    X(int32_t, planned_utilization_q16, planned_utilization_q16)               \
    X(int64_t, sample_unit_input_cost, sample_unit_input_cost)                 \
    X(int64_t, sample_unit_maintenance_cost, sample_unit_maintenance_cost)     \
    X(int64_t, last_base_wages_paid, last_base_wages_paid)                     \
    X(int64_t, last_base_wages_due, last_base_wages_due)                       \
    X(int64_t, last_bonus_paid, last_bonus_paid)                               \
    X(int64_t, last_bonus_due, last_bonus_due)                                 \
    X(int64_t, purchase_intent_capacity_q16, purchase_intent_capacity_q16)     \
    X(int32_t, realized_profit_margin_q16, realized_profit_margin_q16)         \
    X(uint16_t, severe_loss_cycles, severe_loss_cycles)                        \
    X(uint16_t, recovery_cycles, recovery_cycles)                              \
    X(uint16_t, recovery_failed_reviews, recovery_failed_reviews)              \
    X(uint16_t, merchant_debt_term_cycles_left,                                \
      merchant_debt_term_cycles_left)                                          \
    X(uint16_t, merchant_debt_delinquent_cycles,                               \
      merchant_debt_delinquent_cycles)                                         \
    X(uint8_t, operating_state, operating_state)                               \
    X(uint8_t, wage_suspended, wage_suspended)                                 \
    X(int64_t, merchant_debt_principal, merchant_debt_principal)               \
    X(int64_t, merchant_debt_premium, merchant_debt_premium)                   \
    X(int64_t, last_in_kind_livelihood_value, last_in_kind_livelihood_value)   \
    X(uint8_t, pending_operating_state, pending_operating_state)               \
    X(uint16_t, recovery_cooldown_cycles, recovery_cooldown_cycles)            \
    X(uint64_t, modifier_handle, modifier_handle)                              \
    X(int32_t, output_factor_q16, output_factor_q16)

    // Field-reference view over one buildings_store() row. Copying the view is
    // cheap and never copies group state; the referenced columns stay sole.
    template <bool Const>
    struct BuildingGroupRefT {
        std::shared_ptr<EconomyRowWriteLease> write_lease;
        using StoreType =
            std::conditional_t<Const, const RuntimeEconomyBuildingStore,
                               RuntimeEconomyBuildingStore>;
        template <typename T>
        using Field = std::conditional_t<Const, const T, T> &;
        template<typename T>
        Field<T> bind_field(std::conditional_t<Const, const EconomyTrackedColumn<T>, EconomyTrackedColumn<T>> &column,
            size_t row) {
            if constexpr (Const) return column[row];
            else return column.borrow_row(row, *write_lease);
        }

#define PK_BUILDING_GROUP_DECL(TYPE, NAME, COLUMN) Field<TYPE> NAME;
        PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_DECL)
#undef PK_BUILDING_GROUP_DECL
        size_t index;

        BuildingGroupRefT(StoreType &store, size_t row, EconomyWorkerChanges *sink = nullptr)
            : write_lease(Const ? nullptr : EconomyRowWriteLease::create(sink)),
#define PK_BUILDING_GROUP_BIND(TYPE, NAME, COLUMN) NAME(bind_field<TYPE>(store.COLUMN, row)),
              PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_BIND)
#undef PK_BUILDING_GROUP_BIND
              index(row) {}

        template <bool OtherConst,
                  typename = std::enable_if_t<Const && !OtherConst>>
        BuildingGroupRefT(const BuildingGroupRefT<OtherConst> &other)
            : write_lease(other.write_lease),
#define PK_BUILDING_GROUP_REBIND(TYPE, NAME, COLUMN) NAME(other.NAME),
              PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_REBIND)
#undef PK_BUILDING_GROUP_REBIND
              index(other.index) {}

        BuildingGroupRefT(const BuildingGroupRefT &) = default;
        BuildingGroupRefT &operator=(const BuildingGroupRefT &) = delete;
    };

    using BuildingGroupRef = BuildingGroupRefT<false>;
    using BuildingGroupConstRef = BuildingGroupRefT<true>;

    size_t building_count() const noexcept {
        return buildings_store().cell.size();
    }
    BuildingGroupRef building_at(size_t row) noexcept {
        return BuildingGroupRef(buildings_store(), row, market_mutation_sink());
    }
    BuildingGroupConstRef building_at(size_t row) const noexcept {
        return BuildingGroupConstRef(buildings_store(), row);
    }
    // Read-only row view from mutable code. A mutable building_at() borrows
    // every column (lease entry + audit preimage per column), so pure reads
    // in hot loops must use this instead.
    BuildingGroupConstRef building_view(size_t row) const noexcept {
        return BuildingGroupConstRef(buildings_store(), row);
    }
    // Appends one row to every group column. Role spans are not allocated
    // here; rebuild_building_role_storage() assigns them for new rows.
    size_t append_building_group(const BuildingGroup &group);
    void write_building_group(size_t row, const BuildingGroup &group);
    void clear_building_groups();
    void reserve_building_groups(size_t capacity);
    // Repacks buildings_store() role_count/role_begin/role_* from the sparse
    // `_building_employee_*` lanes. Group columns are already sole, so this is
    // the only projection the ECP wire and ledger capture still need.
    void refresh_building_store_role_lanes() const;
    size_t building_group_memory_bytes() const;
    BuildingGroup building_group_copy(size_t row) const;
    // Gathers every group column through `order`, so index-keyed side tables
    // (investment score, factor cache) stay aligned with the same permutation.
    void permute_building_group_columns(const std::vector<int32_t> &order);

    // Epoch-derived quote used by employment, investment and diagnostics. It
    // is rebuilt from frozen inputs and is intentionally absent from PKEC.
    struct OwnerOpportunityQuote {
        int64_t prospective_scale_q16 = 0;
        int64_t owner_run_q16 = 0;
        int64_t climate_factor_q16 = Q16_ONE;
        int64_t resource_factor_q16 = Q16_ONE;
        int64_t natural_capacity_q16 = Q16_ONE;
        int64_t soft_productivity_q16 = Q16_ONE;
        int64_t natural_max_output = 0;
        int64_t fundable_output = 0;
        int64_t actual_output = 0;
        int64_t fixed_cost = 0;
        int64_t variable_cost = 0;
        int64_t cash_receipt = 0;
        int64_t in_kind_retail_value = 0;
        int64_t input_cost = 0;
        int64_t wages = 0;
        int64_t maintenance = 0;
        int64_t owner_living_cost = 0;
        int64_t business_transfer = 0;
        int64_t income_transfer = 0;
        int64_t owner_income_per_day = 0;
        int64_t disposable_survival_power_per_day = 0;
        int64_t executable_capacity_q16 = 0;
        int64_t monetary_quota_absorption_q16 = 0;
        bool survival_priority = false;
        bool monetary_quote_capped = false;
        bool feasible = false;
        // Normalized fields shared with investment and wage planning.
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t utilization_q16 = 0;
        int64_t owner_use_value_per_day = 0;
        int64_t merchant_revenue_per_day = 0;
        int64_t producer_support_revenue_per_day = 0;
        int64_t cash_revenue_per_day = 0;
        int64_t economic_revenue_per_day = 0;
        int64_t input_cost_per_day = 0;
        int64_t wage_cost_per_day = 0;
        int64_t maintenance_cost_per_day = 0;
        int64_t owner_living_cost_per_day = 0;
        int64_t after_tax_revenue_per_day = 0;
        int64_t profit_per_day = 0;
        int64_t affordable_wage_per_day = 0;
        int64_t owner_slots = 0;
        int64_t employee_slots = 0;
        int64_t owner_jobs_filled = 0;
        int64_t employee_jobs_filled = 0;
        bool operator==(const OwnerOpportunityQuote &b) const noexcept {
            return prospective_scale_q16 == b.prospective_scale_q16 && owner_run_q16 == b.owner_run_q16 &&
                climate_factor_q16 == b.climate_factor_q16 && resource_factor_q16 == b.resource_factor_q16 &&
                natural_capacity_q16 == b.natural_capacity_q16 && soft_productivity_q16 == b.soft_productivity_q16 &&
                natural_max_output == b.natural_max_output &&
                fundable_output == b.fundable_output && actual_output == b.actual_output && fixed_cost == b.fixed_cost &&
                variable_cost == b.variable_cost &&
                cash_receipt == b.cash_receipt && in_kind_retail_value == b.in_kind_retail_value && input_cost == b.input_cost &&
                wages == b.wages && maintenance == b.maintenance && owner_living_cost == b.owner_living_cost &&
                business_transfer == b.business_transfer && income_transfer == b.income_transfer &&
                owner_income_per_day == b.owner_income_per_day && disposable_survival_power_per_day == b.disposable_survival_power_per_day &&
                executable_capacity_q16 == b.executable_capacity_q16 && monetary_quota_absorption_q16 == b.monetary_quota_absorption_q16 &&
                survival_priority == b.survival_priority && monetary_quote_capped == b.monetary_quote_capped && feasible == b.feasible &&
                cell == b.cell && type_id == b.type_id && owner_signature_id == b.owner_signature_id &&
                utilization_q16 == b.utilization_q16 && owner_use_value_per_day == b.owner_use_value_per_day &&
                merchant_revenue_per_day == b.merchant_revenue_per_day && producer_support_revenue_per_day == b.producer_support_revenue_per_day &&
                cash_revenue_per_day == b.cash_revenue_per_day && economic_revenue_per_day == b.economic_revenue_per_day &&
                input_cost_per_day == b.input_cost_per_day && wage_cost_per_day == b.wage_cost_per_day &&
                maintenance_cost_per_day == b.maintenance_cost_per_day && owner_living_cost_per_day == b.owner_living_cost_per_day &&
                after_tax_revenue_per_day == b.after_tax_revenue_per_day && profit_per_day == b.profit_per_day &&
                affordable_wage_per_day == b.affordable_wage_per_day && owner_slots == b.owner_slots && employee_slots == b.employee_slots &&
                owner_jobs_filled == b.owner_jobs_filled && employee_jobs_filled == b.employee_jobs_filled;
        }
    };

    struct PendingConstruction {
        int32_t cell = -1;
        int32_t type_id = -1;
        int32_t owner_signature_id = -1;
        int64_t count = 0;
        int64_t ready_day = 0;
        int64_t sequence = 0;
        int64_t merchant_debt_principal = 0;
        int64_t merchant_debt_premium = 0;
        uint16_t merchant_debt_term_cycles_left = 0;
        uint64_t sponsor_family_handle = 0;
    };

// A+Y N8: buildings_store() pending_* columns are the sole pending-construction
// storage. This list maps every historical PendingConstruction field to its
// column and fixes the member order of PendingConstructionRefT, so one row
// still reads and writes as `pending.count`.
#define PK_PENDING_CONSTRUCTION_COLUMNS(X)                                     \
    X(int32_t, cell, pending_cell)                                             \
    X(int32_t, type_id, pending_type_id)                                       \
    X(int32_t, owner_signature_id, pending_owner_signature_id)                 \
    X(int64_t, count, pending_count)                                           \
    X(int64_t, ready_day, pending_ready_day)                                   \
    X(int64_t, sequence, pending_sequence)                                     \
    X(int64_t, merchant_debt_principal, pending_merchant_debt_principal)       \
    X(int64_t, merchant_debt_premium, pending_merchant_debt_premium)           \
    X(uint16_t, merchant_debt_term_cycles_left,                                \
      pending_merchant_debt_term_cycles_left)                                  \
    X(uint64_t, sponsor_family_handle, pending_sponsor_family_handle)

    // Field-reference view over one pending row, mirroring BuildingGroupRefT.
    template <bool Const>
    struct PendingConstructionRefT {
        std::shared_ptr<EconomyRowWriteLease> write_lease;
        using StoreType =
            std::conditional_t<Const, const RuntimeEconomyBuildingStore,
                               RuntimeEconomyBuildingStore>;
        template <typename T>
        using Field = std::conditional_t<Const, const T, T> &;
        template<typename T>
        Field<T> bind_field(std::conditional_t<Const, const EconomyTrackedColumn<T>, EconomyTrackedColumn<T>> &column,
            size_t row) {
            if constexpr (Const) return column[row];
            else return column.borrow_row(row, *write_lease);
        }

#define PK_PENDING_CONSTRUCTION_DECL(TYPE, NAME, COLUMN) Field<TYPE> NAME;
        PK_PENDING_CONSTRUCTION_COLUMNS(PK_PENDING_CONSTRUCTION_DECL)
#undef PK_PENDING_CONSTRUCTION_DECL
        size_t index;

        PendingConstructionRefT(StoreType &store, size_t row)
            : write_lease(Const ? nullptr : EconomyRowWriteLease::create()),
#define PK_PENDING_CONSTRUCTION_BIND(TYPE, NAME, COLUMN) NAME(bind_field<TYPE>(store.COLUMN, row)),
              PK_PENDING_CONSTRUCTION_COLUMNS(PK_PENDING_CONSTRUCTION_BIND)
#undef PK_PENDING_CONSTRUCTION_BIND
              index(row) {}

        template <bool OtherConst,
                  typename = std::enable_if_t<Const && !OtherConst>>
        PendingConstructionRefT(const PendingConstructionRefT<OtherConst> &other)
            : write_lease(other.write_lease),
#define PK_PENDING_CONSTRUCTION_REBIND(TYPE, NAME, COLUMN) NAME(other.NAME),
              PK_PENDING_CONSTRUCTION_COLUMNS(PK_PENDING_CONSTRUCTION_REBIND)
#undef PK_PENDING_CONSTRUCTION_REBIND
              index(other.index) {}

        PendingConstructionRefT(const PendingConstructionRefT &) = default;
        PendingConstructionRefT &operator=(const PendingConstructionRefT &) =
            delete;
    };

    using PendingConstructionRef = PendingConstructionRefT<false>;
    using PendingConstructionConstRef = PendingConstructionRefT<true>;

    // Indexable range over the pending columns. Iteration yields a row view, so
    // `for (const auto pending : pending_construction())` reads SoA directly.
    template <bool Const>
    struct PendingConstructionLaneT {
        using StoreType =
            std::conditional_t<Const, const RuntimeEconomyBuildingStore,
                               RuntimeEconomyBuildingStore>;
        using Reference = PendingConstructionRefT<Const>;

        StoreType *store;

        struct Iterator {
            StoreType *store;
            size_t row;
            Reference operator*() const { return Reference(*store, row); }
            Iterator &operator++() {
                ++row;
                return *this;
            }
            bool operator==(const Iterator &other) const {
                return row == other.row;
            }
            bool operator!=(const Iterator &other) const {
                return row != other.row;
            }
        };

        size_t size() const noexcept { return store->pending_cell.size(); }
        bool empty() const noexcept { return store->pending_cell.empty(); }
        Reference operator[](size_t row) const { return Reference(*store, row); }
        Iterator begin() const { return Iterator{store, 0}; }
        Iterator end() const { return Iterator{store, size()}; }
    };

    using PendingConstructionLane = PendingConstructionLaneT<false>;
    using PendingConstructionConstLane = PendingConstructionLaneT<true>;

    PendingConstructionLane pending_construction() noexcept {
        return PendingConstructionLane{&buildings_store()};
    }
    PendingConstructionConstLane pending_construction() const noexcept {
        return PendingConstructionConstLane{&buildings_store()};
    }
    size_t pending_construction_count() const noexcept {
        return buildings_store().pending_cell.size();
    }
    PendingConstructionRef pending_construction_at(size_t row) noexcept {
        return PendingConstructionRef(buildings_store(), row);
    }
    PendingConstructionConstRef pending_construction_at(
            size_t row) const noexcept {
        return PendingConstructionConstRef(buildings_store(), row);
    }
    // Appends one row to every pending column; returns the new row index.
    size_t append_pending_construction(const PendingConstruction &pending);
    void clear_pending_construction();
    void reserve_pending_construction(size_t capacity);
    PendingConstruction pending_construction_copy(size_t row) const;
    size_t pending_construction_memory_bytes() const;
    // Drops every row with `ready_day <= day` in place, preserving order.
    // Returns the number of removed rows.
    size_t erase_ready_pending_construction(int64_t day);

    // NotablePersonStore / PersonNeedState: see
    // runtime_economy_family_side_tables.h (aliased above).
