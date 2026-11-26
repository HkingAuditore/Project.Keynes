#include "economy_runtime.h"
#include "country_api.h"
#include "economy_runtime_binary_codec.h"
#include "pk_log.h"
#include "runtime_switch_registry.h"

#include <algorithm>
#include <limits>

namespace pk {
using namespace godot;
using namespace binary_codec;

// Validate catalog/world identity and prepare the candidate's authoritative
// columns. Section rows are decoded separately, after this header succeeds.
bool NativeEconomyRuntime::decode_restore_header(
        const std::vector<uint8_t> &bytes, size_t &cursor, uint16_t schema,
        uint32_t records, std::string &error) {
    if (_restore.header_seen || records != 1) {
        error = "duplicate_or_invalid_save_header";
        return false;
    }
    int32_t saved_cells = 0, markets = 0, goods = 0, pages = 0, epoch_days = 0,
            pending_count = 0, building_count = 0, construction_count = 0,
            audit_count = 0, signal_count = 0, labor_signal_count = 0;
    int64_t active_count = 0, last_day = 0, epoch_id = 0, seed = 0,
            catalog_hash = 0, money_scale = 0, goods_scale = 0, ratio_scale = 0,
            rate_scale = 0, environment_day = -1, environment_hash = 0,
            building_catalog_hash = 0;
    int64_t saved_research_points = 0, saved_research_cash = 0,
            saved_research_orders = 0;
    int64_t saved_prosperity_profile_hash = 0;
    int64_t saved_family_catalog_hash = 0;
    int32_t saved_family_mode = _family_runtime_mode.get();
    int32_t saved_family_min_founders = static_cast<int32_t>(
        _family_min_founder_people.get());
    int32_t saved_family_review_days = _family_review_days.get();
    int64_t saved_family_milestone_hash = family_milestone_hash();
    int64_t saved_family_split_population_threshold =
        _family_split_population_threshold.get();
    int32_t saved_family_max_per_cell = _family_max_per_cell.get();
    int32_t saved_family_decline_reviews = _family_decline_reviews.get();
    int64_t saved_person_catalog_hash = _person_catalog_hash.get();
    int32_t saved_person_mode = _person_runtime_mode.get();
    int32_t saved_person_max_per_family = _person_max_per_family.get();
    int32_t saved_person_max_per_cell = _person_max_per_cell.get();
    int32_t saved_person_max_total = _person_max_total.get();
    int32_t saved_person_records_per_slice = _person_records_per_slice.get();
    int32_t person_count = 0, person_need_count = 0;
    int32_t saved_trait_catalog_version = 0;
    int64_t saved_trait_catalog_hash = 0;
    int32_t family_trait_count = 0, family_influence_count = 0,
        family_trait_command_count = 0;
    int32_t family_expedition_slots = 0, family_expedition_count = 0;
    int64_t next_family_expedition_stable_id = 1,
        next_colonization_receipt_id = 1;
    int32_t canal_quote_count = 0, canal_project_count = 0;
    uint64_t next_canal_quote_token = 1, next_canal_project_id = 1;
    int64_t next_canal_receipt_id = 1;
    int32_t saved_locked_market_cycle_days = MARKET_CYCLE_MAX_DAYS;
    int64_t saved_market_cycle_start_day = 0;
    int32_t saved_locked_slow_cycle_days = SLOW_CYCLE_MIN_DAYS;
    int64_t saved_slow_cycle_start_day = 0;
    int32_t saved_locked_investment_cycle_days = INVEST_CYCLE_MIN_DAYS;
    int64_t saved_investment_cycle_start_day = 0;
    int32_t country_schema = 0;
    uint64_t country_generation = 0, country_hash = 0;
    uint64_t next_submit = 0;
    int64_t next_event_id = 1;
    uint64_t event_stream_hash = 1469598103934665603ULL;
    int32_t trade_order_count = 0, trade_flow_count = 0;
    int32_t tariff_history_count = 0, country_good_count = 0,
        country_partner_count = 0, saved_trade_mode = 0;
    uint64_t country_trade_revision = 0;
    int64_t next_trade_order_id = 1, saved_trade_capacity = 0;
    int32_t saved_trade_speed = 0, saved_trade_margin = 0,
            saved_trade_targets = 0, saved_trade_signal_budget = 0,
            saved_trade_route_budget = 0, saved_trade_expansions = 0,
            saved_trade_cache = 0, saved_trade_signals = 0,
            saved_trade_candidates = 0,
            saved_trade_orders = 0, saved_trade_alpha = 0,
            saved_trade_stock_share = 0;
    int32_t saved_loss_threshold = -16384, saved_loss_cycles = 3,
            saved_restart_margin = 6554, saved_restart_cycles = 2,
            saved_merchant_reserve = 16384,
            saved_market_making_days = Q16_ONE,
            saved_credit_mode = 2, saved_credit_exposure = 16384,
            saved_credit_premium = 3277, saved_credit_terms = 6,
            saved_recovery_cycles = 2, saved_liquidation_reviews = 6;
    int32_t saved_trade_export_days = 5,
            saved_trade_export_fraction = 32768,
            saved_trade_import_fraction = 32768,
            saved_trade_response_days = 15,
            saved_investment_review_days = 180,
            saved_investment_shortage = 8192,
            saved_investment_utilization = 42598,
            saved_investment_payback_days = 365,
            saved_investment_cycles = 2,
            saved_investment_gap_fill_share = 16384,
            saved_investment_portfolio_max_types = 4,
            saved_investment_max_type_owner_share = 32768,
            saved_investment_max_growth_share = 6554,
            saved_investment_new_type_seed_buildings = 1,
            saved_investment_merchant_transition_min_improvement = 32768,
            saved_recovery_liquidation_max_share = 16384,
            saved_resource_reserve = 22938,
            saved_resource_harvest = 0,
            saved_resource_horizon = 3650,
            saved_bullion_cap = 655,
            saved_support_cap = 3277;
    std::vector<std::string> professions, ethnicities, good_ids, plan_ids;
    if (!read_le(bytes, cursor, saved_cells) || !read_le(bytes, cursor, markets) ||
        !read_le(bytes, cursor, goods) || !read_le(bytes, cursor, pages) ||
        !read_le(bytes, cursor, active_count) || !read_le(bytes, cursor, epoch_days) ||
        !read_le(bytes, cursor, last_day) || !read_le(bytes, cursor, epoch_id) ||
        !read_le(bytes, cursor, country_schema) ||
        !read_le(bytes, cursor, country_generation) ||
        !read_le(bytes, cursor, country_hash) || !read_le(bytes, cursor, seed) ||
        !read_le(bytes, cursor, catalog_hash)) {
        error = "save_header_payload_truncated";
        return false;
    }
    if (!read_le(bytes, cursor, building_catalog_hash) ||
        !read_le(bytes, cursor, building_count) ||
        !read_le(bytes, cursor, construction_count)) {
        error = "save_building_header_payload_truncated";
        return false;
    }
    if (
        !read_le(bytes, cursor, environment_day) || !read_le(bytes, cursor, environment_hash) ||
        !read_le(bytes, cursor, next_submit) ||
        !read_le(bytes, cursor, money_scale) || !read_le(bytes, cursor, goods_scale) ||
        !read_le(bytes, cursor, ratio_scale) || !read_le(bytes, cursor, rate_scale) ||
        !read_le(bytes, cursor, pending_count) ||
        !read_le(bytes, cursor, audit_count) ||
        !read_le(bytes, cursor, signal_count) ||
        !read_le(bytes, cursor, labor_signal_count) ||
        !read_le(bytes, cursor, next_event_id) ||
        !read_le(bytes, cursor, event_stream_hash)) {
        error = "save_header_payload_truncated";
        return false;
    }
    if (schema >= 11 && (!read_le(bytes, cursor, trade_order_count) ||
        !read_le(bytes, cursor, trade_flow_count) ||
        (schema >= 33 && (!read_le(bytes, cursor, tariff_history_count) ||
            !read_le(bytes, cursor, country_good_count) ||
            !read_le(bytes, cursor, country_partner_count) ||
            !read_le(bytes, cursor, country_trade_revision))) ||
        !read_le(bytes, cursor, next_trade_order_id) ||
        !read_le(bytes, cursor, saved_trade_mode) ||
        !read_le(bytes, cursor, saved_trade_capacity) ||
        !read_le(bytes, cursor, saved_trade_speed) ||
        !read_le(bytes, cursor, saved_trade_margin) ||
        !read_le(bytes, cursor, saved_trade_targets) ||
        !read_le(bytes, cursor, saved_trade_signal_budget) ||
        !read_le(bytes, cursor, saved_trade_route_budget) ||
        !read_le(bytes, cursor, saved_trade_expansions) ||
        !read_le(bytes, cursor, saved_trade_cache) ||
        !read_le(bytes, cursor, saved_trade_signals) ||
        !read_le(bytes, cursor, saved_trade_candidates) ||
        !read_le(bytes, cursor, saved_trade_orders) ||
        !read_le(bytes, cursor, saved_trade_alpha) ||
        !read_le(bytes, cursor, saved_trade_stock_share))) {
        error = "save_trade_header_payload_truncated";
        return false;
    }
    if (schema >= 12 && (!read_le(bytes, cursor, saved_loss_threshold) ||
        !read_le(bytes, cursor, saved_loss_cycles) ||
        !read_le(bytes, cursor, saved_restart_margin) ||
        !read_le(bytes, cursor, saved_restart_cycles) ||
        !read_le(bytes, cursor, saved_merchant_reserve) ||
        !read_le(bytes, cursor, saved_market_making_days) ||
        !read_le(bytes, cursor, saved_credit_mode) ||
        !read_le(bytes, cursor, saved_credit_exposure) ||
        !read_le(bytes, cursor, saved_credit_premium) ||
        !read_le(bytes, cursor, saved_credit_terms) ||
        !read_le(bytes, cursor, saved_recovery_cycles) ||
        !read_le(bytes, cursor, saved_liquidation_reviews))) {
        error = "save_business_policy_header_payload_truncated";
        return false;
    }
    if (schema >= 14 && (!read_le(bytes, cursor, saved_trade_export_days) ||
        !read_le(bytes, cursor, saved_trade_export_fraction) ||
        !read_le(bytes, cursor, saved_trade_import_fraction) ||
        !read_le(bytes, cursor, saved_trade_response_days) ||
        !read_le(bytes, cursor, saved_investment_review_days) ||
        !read_le(bytes, cursor, saved_investment_shortage) ||
        !read_le(bytes, cursor, saved_investment_utilization) ||
        !read_le(bytes, cursor, saved_investment_payback_days) ||
        !read_le(bytes, cursor, saved_investment_cycles) ||
        !read_le(bytes, cursor, saved_investment_gap_fill_share) ||
        !read_le(bytes, cursor, saved_investment_portfolio_max_types) ||
        !read_le(bytes, cursor, saved_investment_max_type_owner_share) ||
        !read_le(bytes, cursor, saved_investment_max_growth_share) ||
        !read_le(bytes, cursor, saved_investment_new_type_seed_buildings) ||
        !read_le(bytes, cursor,
            saved_investment_merchant_transition_min_improvement) ||
        !read_le(bytes, cursor, saved_recovery_liquidation_max_share) ||
        !read_le(bytes, cursor, saved_resource_reserve) ||
        !read_le(bytes, cursor, saved_resource_harvest) ||
        !read_le(bytes, cursor, saved_resource_horizon) ||
        !read_le(bytes, cursor, saved_bullion_cap) ||
        !read_le(bytes, cursor, saved_support_cap))) {
        error = "save_dynamic_policy_header_payload_truncated";
        return false;
    }
    if (!read_le(bytes, cursor, saved_research_points) ||
        !read_le(bytes, cursor, saved_research_cash) ||
        !read_le(bytes, cursor, saved_research_orders) ||
        saved_research_points < 0 || saved_research_cash < 0 ||
        saved_research_orders < 0) {
        error = "save_research_procurement_header_payload_truncated";
        return false;
    }
    if (schema >= 24 &&
        (!read_le(bytes, cursor, saved_prosperity_profile_hash) ||
         saved_prosperity_profile_hash != _prosperity_profile_hash.get())) {
        error = "save_prosperity_profile_hash_mismatch";
        return false;
    }
    int32_t saved_building_plan_days = _building_plan_days.get();
    if (schema >= 25 && !read_le(bytes, cursor, saved_building_plan_days)) {
        error = "save_building_plan_days_mismatch";
        return false;
    }
    if (schema >= 25 && schema < 38 &&
        saved_building_plan_days != _building_plan_days.get()) {
        error = "save_building_plan_days_mismatch";
        return false;
    }
    if (schema >= 26) {
        if (!read_le(bytes, cursor, saved_family_catalog_hash) ||
            (saved_family_catalog_hash != _family_catalog_hash.get() &&
             !(schema == 39 && _family_catalog_compat_hash_v39 != 0 &&
               saved_family_catalog_hash == _family_catalog_compat_hash_v39))) {
            error = "save_family_catalog_hash_mismatch";
            return false;
        }
        if (!read_le(bytes, cursor, saved_family_mode) ||
            !read_le(bytes, cursor, saved_family_min_founders) ||
            !read_le(bytes, cursor, saved_family_review_days) ||
            !read_le(bytes, cursor, saved_family_milestone_hash) ||
            (schema >= 40 && !read_le(bytes, cursor,
                saved_family_split_population_threshold)) ||
            !read_le(bytes, cursor, saved_family_max_per_cell) ||
            !read_le(bytes, cursor, saved_family_decline_reviews)) {
            error = "save_family_policy_header_payload_truncated";
            return false;
        }
        if (saved_family_mode != _family_runtime_mode.get() ||
            saved_family_min_founders != _family_min_founder_people.get() ||
            saved_family_review_days != _family_review_days.get() ||
            saved_family_milestone_hash != family_milestone_hash() ||
            saved_family_split_population_threshold !=
                _family_split_population_threshold.get() ||
            saved_family_max_per_cell != _family_max_per_cell.get() ||
            saved_family_decline_reviews != _family_decline_reviews.get()) {
            error = "save_family_policy_profile_mismatch";
            return false;
        }
    }
    if (schema >= 27) {
        if (!read_le(bytes, cursor, saved_person_catalog_hash) ||
            saved_person_catalog_hash != _person_catalog_hash.get()) {
            error = "save_person_catalog_hash_mismatch";
            return false;
        }
        if (!read_le(bytes, cursor, saved_person_mode) ||
            !read_le(bytes, cursor, saved_person_max_per_family) ||
            !read_le(bytes, cursor, saved_person_max_per_cell) ||
            !read_le(bytes, cursor, saved_person_max_total) ||
            !read_le(bytes, cursor, saved_person_records_per_slice) ||
            !read_le(bytes, cursor, person_count) ||
            !read_le(bytes, cursor, person_need_count)) {
            error = "save_person_policy_header_payload_truncated";
            return false;
        }
        if (saved_person_mode != _person_runtime_mode.get() ||
            saved_person_max_per_family != _person_max_per_family.get() ||
            saved_person_max_per_cell != _person_max_per_cell.get() ||
            saved_person_max_total != _person_max_total.get() ||
            saved_person_records_per_slice != _person_records_per_slice.get()) {
            error = "save_person_policy_profile_mismatch";
            return false;
        }
    }
    if (!read_le(bytes, cursor, saved_trait_catalog_version) ||
        !read_le(bytes, cursor, saved_trait_catalog_hash) ||
        !read_le(bytes, cursor, family_trait_count) ||
        !read_le(bytes, cursor, family_influence_count) ||
        !read_le(bytes, cursor, family_trait_command_count) ||
        !read_le(bytes, cursor, family_expedition_slots) ||
        !read_le(bytes, cursor, family_expedition_count) ||
        !read_le(bytes, cursor, next_family_expedition_stable_id) ||
        !read_le(bytes, cursor, next_colonization_receipt_id) ||
        saved_trait_catalog_version != _family_trait_catalog_version.get() ||
        saved_trait_catalog_hash != _family_trait_catalog_hash.get() ||
        family_trait_count < 0 || family_trait_count > 1000000 ||
        family_influence_count < 0 || family_influence_count > 10000000 ||
        family_trait_command_count < 0 ||
        family_trait_command_count > 1000000 ||
        family_expedition_slots < 0 || family_expedition_slots > 1000000 ||
        family_expedition_count < 0 ||
        family_expedition_count > family_expedition_slots ||
        next_family_expedition_stable_id <= 0 ||
        next_colonization_receipt_id <= 0) {
        error = "save_family_trait_header_invalid";
        return false;
    }
    if (schema >= 34 &&
        (!read_le(bytes, cursor, canal_quote_count) ||
         !read_le(bytes, cursor, canal_project_count) ||
         !read_le(bytes, cursor, next_canal_quote_token) ||
         !read_le(bytes, cursor, next_canal_project_id) ||
         !read_le(bytes, cursor, next_canal_receipt_id) ||
         canal_quote_count < 0 || canal_quote_count > 1000000 ||
         canal_project_count < 0 || canal_project_count > 1000000 ||
         next_canal_quote_token == 0 || next_canal_project_id == 0 ||
         next_canal_receipt_id <= 0)) {
        error = "save_canal_header_invalid";
        return false;
    }
    if (schema >= 38 &&
        (!read_le(bytes, cursor, saved_locked_market_cycle_days) ||
         !read_le(bytes, cursor, saved_market_cycle_start_day) ||
         !read_le(bytes, cursor, saved_locked_slow_cycle_days) ||
         !read_le(bytes, cursor, saved_slow_cycle_start_day) ||
         saved_locked_market_cycle_days < MARKET_CYCLE_MIN_DAYS ||
         saved_locked_market_cycle_days > MARKET_CYCLE_MAX_DAYS ||
         saved_locked_slow_cycle_days < SLOW_CYCLE_MIN_DAYS ||
         saved_locked_slow_cycle_days > SLOW_CYCLE_MAX_DAYS)) {
        error = "save_cadence_header_invalid";
        return false;
    }
    if (schema >= 39 &&
        (!read_le(bytes, cursor, saved_locked_investment_cycle_days) ||
         !read_le(bytes, cursor, saved_investment_cycle_start_day) ||
         saved_locked_investment_cycle_days < INVEST_CYCLE_MIN_DAYS ||
         saved_locked_investment_cycle_days > INVEST_CYCLE_MAX_DAYS)) {
        error = "save_cadence_investment_header_invalid";
        return false;
    }
    int32_t saved_maintenance_horizons[5] = {5475, 2920, 3650, 2190, 7300};
    int32_t saved_maintenance_cost_factor = Q16_ONE;
    int32_t saved_startup_demand_mode = 0;
    if (schema >= 43) {
        for (int32_t sector = 0; sector < 5; ++sector) {
            if (!read_le(bytes, cursor, saved_maintenance_horizons[sector]) ||
                saved_maintenance_horizons[sector] < 1 ||
                saved_maintenance_horizons[sector] > 365000) {
                error = "save_maintenance_policy_header_invalid";
                return false;
            }
        }
        if (!read_le(bytes, cursor, saved_maintenance_cost_factor) ||
            saved_maintenance_cost_factor < 1 ||
            saved_maintenance_cost_factor > Q16_ONE * 4) {
            error = "save_maintenance_policy_header_invalid";
            return false;
        }
    }
    if (schema >= 44 &&
        (!read_le(bytes, cursor, saved_startup_demand_mode) ||
         saved_startup_demand_mode < 0 || saved_startup_demand_mode > 1)) {
        error = "save_startup_demand_mode_invalid";
        return false;
    }
    int32_t ceiling_confirm = 0, ceiling_expand = 0, ceiling_recover = 0;
    int64_t ceiling_count = 0;
    int32_t fiscal_peer_count = 0;
    if (!read_le(bytes, cursor, ceiling_confirm) || !read_le(bytes, cursor, ceiling_expand) ||
        !read_le(bytes, cursor, ceiling_recover) || !read_le(bytes, cursor, ceiling_count) ||
        ceiling_confirm != _price_ceiling_confirm_days.get() || ceiling_expand != _price_ceiling_expand_bp.get() ||
        ceiling_recover != _price_ceiling_recover_bp.get() || ceiling_count < 0 ||
        ceiling_count > int64_t(markets) * goods) {
        error = "save_price_ceiling_profile_or_count_invalid";
        return false;
    }
    _restore.expected_ceilings = ceiling_count;
    if (schema >= 52 &&
        (!read_le(bytes, cursor, fiscal_peer_count) ||
         fiscal_peer_count < 0 || fiscal_peer_count > 1000000)) {
        error = "save_fiscal_peer_header_invalid";
        return false;
    }
    _restore.expected_fiscal_peer = schema >= 52 ? fiscal_peer_count : 0;
    _restore.expected_d7_peer_ext = schema >= 53 ? fiscal_peer_count : 0;
    _restore.expected_resource_rows = static_cast<int64_t>(_resource_ids.size()) *
        static_cast<int64_t>(_cell_count.get());
    if (!read_id_table(bytes, cursor, professions) || !read_id_table(bytes, cursor, ethnicities) ||
        !read_id_table(bytes, cursor, good_ids) || !read_id_table(bytes, cursor, plan_ids) ||
        cursor != bytes.size()) {
        error = "save_header_payload_truncated";
        return false;
    }
    const bool market_hash_ok = schema == 10
        ? (_catalog_compat_hash_v10.get() != 0 && catalog_hash == _catalog_compat_hash_v10.get())
        : (schema == 13 ? (_catalog_compat_hash_v13 != 0 &&
            catalog_hash == _catalog_compat_hash_v13) :
            (schema == 39 ? (_catalog_compat_hash_v39 != 0 &&
                catalog_hash == _catalog_compat_hash_v39) :
                catalog_hash == _catalog_hash.get()));
    const bool building_hash_ok = schema == 13
        ? (_building_catalog_compat_hash_v13 != 0 &&
           building_catalog_hash == _building_catalog_compat_hash_v13)
        : building_catalog_hash == _building_catalog_hash.get();
    // One reason per rule. A single combined reason gave a player whose
    // save would not load nothing to act on: a changed catalog, a changed
    // map size, and a capacity knob all read the same.
    const char *header_mismatch = nullptr;
#include "economy_runtime_persistence_header_section_world_compatibility.inc"
    if (schema >= 35 && !dynamic_policy_matches) {
        error = "save_dynamic_policy_profile_mismatch";
        return false;
    }
    const bool country_schema_compatible =
        // PKCN 14 (military Country opcodes) added no Economy-visible
        // fields, so PKEC written against PKCN 13 stays loadable.
        (country_schema >= 13 && country_schema <= CountryApi::SCHEMA_VERSION) ||
        (schema == 22 && country_schema == 3) ||
        (schema <= 19 && country_schema == 1);
    const uint64_t expected_country_hash =
        schema == 22 && country_schema == 3 &&
                _country_runtime != nullptr
            ? static_cast<uint64_t>(
                country_reads().state_hash_v3_compat())
            : (_country_runtime != nullptr
                ? static_cast<uint64_t>(country_reads().state_hash())
                : 0);
    // LOAD ORDER EXCEPTION (worker start after a save).
    //
    // The worker-start path applies the ECP2 bundle to Economy BEFORE Country is
    // installed (`native_simulation_host.cpp`), so at this moment the live Country is
    // still the freshly bootstrapped one -- measured:
    // `saved_gen=19 live_gen=1 saved_hash=325166771088284131
    //  live_hash=1824313771786949620`. Comparing hashes then can only fail, which is
    // how every load of a real save ended in
    // `economy_country_restore_order_or_hash_mismatch` -> `runtime_worker_start_failed`.
    //
    // `_accept_stale_country_identity` is set ONLY by the host while it is installing
    // a restore bundle, and cleared as soon as that start proceeds. Outside that
    // window the comparison is exactly as strict as before: applying an ECP2 to a
    // live economy whose Country has moved is a real corruption and must still fail.
    //
    // What this does NOT give up: the archive's expected identity is recorded here
    // and re-checked by the Host once the PKCN checkpoint is installed
    // (`NativeEconomyRuntime::verify_deferred_country_identity`). Deferring the
    // comparison is only legitimate because somebody still performs it -- an
    // archive whose Country bytes and Economy bytes come from different saves must
    // still fail to start the worker. The other shape checks
    // (`country_schema_compatible`, generation sanity, building/trade counts) run
    // in both cases.
    const bool country_identity_deferred = _accept_stale_country_identity;
    if (country_identity_deferred) {
        _deferred_country_generation = country_generation;
        _deferred_country_state_hash = country_hash;
        _deferred_country_identity_recorded = true;
    }
    if (_country_runtime == nullptr || !country_reads().economy_available() ||
        !country_schema_compatible ||
        (!country_identity_deferred && (
            country_generation != country_reads().generation() ||
            country_hash != expected_country_hash))) {
        if (pk::runtime_switch_value(pk::RuntimeSwitch::PK_COUNTRY_HASH_PROBE) != nullptr)
            pk::log_error("[country-hash] saved_schema=%u live_schema=%d "
                "saved_gen=%llu live_gen=%llu saved_hash=%llu live_hash=%llu "
                "compatible=%d economy_available=%d deferred=%d",
                country_schema,
                _country_runtime == nullptr ? -1
                    : CountryApi::SCHEMA_VERSION,
                static_cast<unsigned long long>(country_generation),
                static_cast<unsigned long long>(
                    _country_runtime == nullptr ? 0
                        : country_reads().generation()),
                static_cast<unsigned long long>(country_hash),
                static_cast<unsigned long long>(expected_country_hash),
                country_schema_compatible ? 1 : 0,
                (_country_runtime != nullptr &&
                 country_reads().economy_available()) ? 1 : 0,
                country_identity_deferred ? 1 : 0);
        error = "economy_country_restore_order_or_hash_mismatch";
        return false;
    }
    if (!building_hash_ok ||
        building_count < 0 || building_count > 10000000 || construction_count < 0 ||
        construction_count > 1000000) {
        error = "save_building_catalog_or_capacity_mismatch";
        return false;
    }
    _restore.schema_version = schema;
    _restore.expected_pages = pages;
    _restore.expected_commands = pending_count;
    _restore.expected_buildings = building_count;
    _restore.expected_construction = construction_count;
    _restore.expected_audits = audit_count;
    _restore.expected_signals = signal_count;
    _restore.expected_labor_signals = labor_signal_count;
    _restore.expected_trade_orders = trade_order_count;
    _restore.expected_trade_flows = trade_flow_count;
    _restore.expected_tariff_history = tariff_history_count;
    _restore.expected_country_good = country_good_count;
    _restore.expected_country_partner = country_partner_count;
    _restore.expected_canal_quotes = canal_quote_count;
    _restore.expected_canal_projects = canal_project_count;
    _restore.expected_persons = person_count;
    _restore.expected_family_traits = family_trait_count;
    _restore.expected_family_influences = family_influence_count;
    _restore.expected_family_trait_commands = family_trait_command_count;
    _restore.expected_person_needs = person_need_count;
    _restore.expected_family_expedition_slots = family_expedition_slots;
    _restore.expected_family_expeditions = family_expedition_count;
    _next_family_expedition_stable_id = next_family_expedition_stable_id;
    _next_colonization_receipt_id = next_colonization_receipt_id;
    _next_canal_quote_token = next_canal_quote_token;
    _next_canal_project_id = next_canal_project_id;
    _next_canal_receipt_id = next_canal_receipt_id;
    _next_event_id = next_event_id;
    _country_trade_revision = country_trade_revision;
    _event_stream_hash = event_stream_hash;
    _government_research_procured_points = saved_research_points;
    _government_research_procurement_cash = saved_research_cash;
    _government_research_procurement_orders = saved_research_orders;
    _audit_history.clear();
    _committed_event_batches.clear();
    _staging_construction_receipts.clear();
    _committed_construction_receipts.clear();
    _next_construction_receipt_id = 1;
    _event_consumer_ack.clear();
    population_store().clear(_cell_count.get());
    population_store().page_next.assign(pages, -1);
    population_store().page_cell.assign(pages, -1);
    const size_t slots = static_cast<size_t>(pages) * COHORT_PAGE_SIZE;
    population_store().active.assign(slots, 0);
    // Reservations are transient and are intentionally not serialized at a
    // committed save boundary.  Recreate their dense lanes explicitly so
    // post-restore allocation/release paths have the same shape as a fresh
    // runtime and cannot index an empty vector.
    population_store().reserved.assign(slots, 0);
    population_store().reservation_owner.assign(slots, 0);
    population_store().signature_id.assign(slots, 0);
    population_store().generation.assign(slots, 1);
    population_store().population.assign(slots, 0);
    population_store().funds.assign(slots, 0);
    population_store().epoch_income.assign(slots, 0);
    population_store().epoch_expense.assign(slots, 0);
    population_store().epoch_in_kind_income.assign(slots, 0);
    population_store().income_ema.assign(slots, 0);
    population_store().epoch_tax_paid.assign(slots, 0);
    population_store().epoch_subsidy_received.assign(slots, 0);
    population_store().income_baseline_ema.assign(slots, 0);
    population_store().needs_satisfaction.assign(slots, static_cast<uint16_t>(Q16_ONE - 1));
    population_store().worst_need_id.assign(slots, std::numeric_limits<uint16_t>::max());
    population_store().composite_satisfaction.assign(
        slots, static_cast<uint16_t>(Q16_ONE - 1));
    population_store().satisfaction_dims.assign(
        slots * static_cast<size_t>(SAT_DIM_COUNT),
        static_cast<uint16_t>(Q16_ONE - 1));
    population_store().worst_dimension_id.assign(
        slots, std::numeric_limits<uint8_t>::max());
    population_store().flags.assign(slots, 0);
    population_store().demography_residual.assign(slots, 0);
    population_store().owner_employed.assign(slots, 0);
    population_store().employee_employed.assign(slots, 0);
    population_store().active_count = active_count;
    population_store().high_water_slots = static_cast<int64_t>(slots);
    market_store().market_count = markets;
    market_store().price_ceilings.resize(markets);
    market_store().good_count = goods;
    market_store().stock.assign(static_cast<size_t>(markets) * goods, 0);
    market_store().price.assign(static_cast<size_t>(markets) * goods, 0);
    market_store().demand_ema.assign(static_cast<size_t>(markets) * goods, 0);
    market_store().last_shortage_q16.assign(static_cast<size_t>(markets) * goods, 0);
    _investment_active_good_words.assign(
        (static_cast<size_t>(goods) + 63U) / 64U, 0);
    _investment_active_goods_scratch.clear();
    _startup_demand_values.assign(
        static_cast<size_t>(markets) * static_cast<size_t>(goods), 0);
    _startup_demand_stamps.assign(
        static_cast<size_t>(markets) * static_cast<size_t>(goods), 0);
    _startup_demand_generation = 0;
    _startup_demand_touched_keys.clear();
    _trade_active_keys.clear();
    _trade_active_key_present.assign(static_cast<size_t>(markets) * goods, 0);
    market_store().cell_to_market.assign(_cell_count.get(), -1);
    _market_signals.clear(_cell_count.get());
    _market_signals.good_ids.reserve(signal_count);
    _market_signals.business_demand_ema.reserve(signal_count);
    _market_signals.offered_supply_ema.reserve(signal_count);
    _market_signals.realized_withdrawal_ema.reserve(signal_count);
    _market_signals.cost_anchor_price.reserve(signal_count);
    _labor_signals.clear(_cell_count.get());
    _labor_signals.profession_ids.reserve(labor_signal_count);
    _labor_signals.base_living_cost.reserve(labor_signal_count);
    _labor_signals.role_living_cost.reserve(labor_signal_count);
    _labor_signals.contract_wage_ema.reserve(labor_signal_count);
    _labor_signals.paid_wage_ema.reserve(labor_signal_count);
    _labor_signals.job_days.reserve(labor_signal_count);
    _labor_signals.pay_ratio_q16.reserve(labor_signal_count);
    trade_orders_store().clear();
    trade_orders_store().next_id = next_trade_order_id;
    trade_orders_store().ids.reserve(trade_order_count);
    _trade_flows.clear();
    _trade_flows.cells.reserve(trade_flow_count);
    _tariff_history.clear();
    _tariff_history.countries.reserve(tariff_history_count);
    _country_good_trade.clear();
    _country_good_trade.countries.reserve(country_good_count);
    _country_partner_trade.clear();
    _country_partner_trade.countries.reserve(country_partner_count);
    _environment_temperature_q16.assign(_cell_count.get(), 0);
    _environment_temperature_30d_q16.assign(_cell_count.get(), 0);
    _environment_moisture_q16.assign(_cell_count.get(), 0);
    _environment_plant_available_water_q16.assign(_cell_count.get(), 0);
    _environment_precipitation_q16.assign(_cell_count.get(), 0);
    _environment_snow_q16.assign(_cell_count.get(), 0);
    _environment_weather_q16.assign(_cell_count.get(), 0);
    _cell_temperature_annual_q16.assign(_cell_count.get(), Q16_ONE / 2);
    _cell_temperature_anomaly_q16.assign(_cell_count.get(), 0);
    _cell_hazard_today_mask.assign(_cell_count.get(), 0);
    _cell_dry_streak_days.assign(_cell_count.get(), 0);
    _cell_days_since_hazard.assign(_cell_count.get(), 0);
    _cell_previous_hazard_mask.assign(_cell_count.get(), 0);
    _cell_weather_type.assign(_cell_count.get(), 0);
    _cell_cover.assign(_cell_count.get(), 0);
    _cell_living_cost_per_capita.assign(_cell_count.get(), 0);
    _epoch_cell_development_q16.assign(_cell_count.get(), 0);
    _cell_social_pressure_level.assign(_cell_count.get(), 0);
    _cell_support_ema_q16.assign(_cell_count.get(), Q16_ONE);
    _cell_food_output_eq_period.assign(_cell_count.get(), 0);
    _cell_food_input_eq_period.assign(_cell_count.get(), 0);
    _cell_food_import_eq_period.assign(_cell_count.get(), 0);
    _cell_food_export_eq_period.assign(_cell_count.get(), 0);
    _cell_food_access_eq_period.assign(_cell_count.get(), 0);
    _cell_food_output_eq_previous.assign(_cell_count.get(), 0);
    _cell_food_input_eq_previous.assign(_cell_count.get(), 0);
    _cell_food_import_eq_previous.assign(_cell_count.get(), 0);
    _cell_food_export_eq_previous.assign(_cell_count.get(), 0);
    _cell_food_access_eq_previous.assign(_cell_count.get(), 0);
    _cell_food_flow_valid.assign(_cell_count.get(), 0);
    _food_flow_previous_period_days = 0;
    _cell_carrying_k_geo.assign(_cell_count.get(), _carrying_k_habitat_ref);
    _cell_carrying_k_eff.assign(_cell_count.get(), _carrying_k_habitat_ref);
    _cell_carrying_surplus_q16.assign(_cell_count.get(), Q16_ONE);
    _cell_carrying_sat_q16.assign(_cell_count.get(), Q16_ONE);
    _cell_carrying_family_surplus_q16.assign(
        static_cast<size_t>(_cell_count.get()) * CARRYING_FAMILY_COUNT, Q16_ONE);
    _cell_carrying_family_bindable.assign(
        static_cast<size_t>(_cell_count.get()) * CARRYING_FAMILY_COUNT, 0);
    _environment_day = environment_day;
    _environment_hash = environment_hash;
    _restore.environment_hash = environment_hash;
    _epoch_days = epoch_days;
    _commit_lag_budget_days = std::max(0, epoch_days - 1);
    if (schema >= 38) {
        _locked_market_cycle_days = saved_locked_market_cycle_days;
        _market_cycle_start_day = saved_market_cycle_start_day;
        _locked_slow_cycle_days = saved_locked_slow_cycle_days;
        _slow_cycle_start_day = saved_slow_cycle_start_day;
        if (schema >= 39) {
            _locked_investment_cycle_days =
                saved_locked_investment_cycle_days;
            _investment_cycle_start_day =
                saved_investment_cycle_start_day;
        } else {
            _locked_investment_cycle_days =
                longer_investment_cycle_days(
                    _locked_slow_cycle_days.get(),
                    _locked_market_cycle_days.get(),
                    saved_investment_review_days);
            const int32_t invest_cycle = std::max(
                1, _locked_investment_cycle_days.get());
            if (last_day < 0) {
                _investment_cycle_start_day = 0;
            } else {
                const int64_t phase =
                    ((last_day % invest_cycle) + invest_cycle) %
                    invest_cycle;
                _investment_cycle_start_day = last_day - phase;
            }
        }
        apply_locked_slow_days();
        if (schema >= 43) {
            for (int32_t sector = 0; sector < 5; ++sector)
                _maintenance_horizon_days_by_sector.write_scalar(sector,
                    saved_maintenance_horizons[sector]);
            _building_maintenance_cost_factor_q16 =
                saved_maintenance_cost_factor;
            if (!_building_types.empty())
                resolve_building_maintenance_csr();
        }
        _startup_demand_runtime_mode = schema >= 44
            ? saved_startup_demand_mode : 0;
        _cadence_initialized = true;
        _cadence_change_reason = 0;
    } else {
        _building_plan_days = saved_building_plan_days;
    }
    if (_auto_slice_by_scale) {
        const int32_t n = std::max(1, schema >= 38
            ? saved_locked_market_cycle_days
            : MARKET_CYCLE_MAX_DAYS);
        _cells_per_slice = std::max(1, (markets + n - 1) / n);
    }
    if (_auto_building_slice_by_scale) {
        _building_cells_per_slice = std::min(
            AUTO_BUILDING_CELLS_PER_SLICE,
            std::max(1, _cells_per_slice / 4));
    }
    _last_committed_day = last_day;
    _commit_day = last_day;
    _sample_day = last_day;
    _current_day = last_day;
    _epoch_id = epoch_id;
    _seed = seed;
    _next_submit_order = next_submit;
    _pending_commands.reserve(pending_count);
    clear_building_groups();
    _building_handle_index_clean = false;
    _building_group_order_scratch.clear();
    _building_group_is_new_scratch.clear();
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.clear();
    _building_free_role_spans_by_type.assign(_building_types.size(), {});
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    reserve_building_groups(static_cast<size_t>(building_count));
    clear_pending_construction();
    reserve_pending_construction(construction_count);
    families_store().clear();
    family_expeditions_store().clear();
    family_expedition_route_cells().clear();
    family_expedition_route_costs().clear();
    family_expedition_payloads().clear();
    family_expedition_person_handles().clear();
    family_expedition_cargo().clear();
    family_expedition_kit_buildings().clear();
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    _colonization_receipts.clear();
    {
        std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
        _worker_command_inbox->commands.clear();
    }
    clear_procurement_runtime_state(true);
    family_influences().clear();
    persons_store().clear();
    family_memberships().clear();
    _family_csr_edge_count = SIZE_MAX;
    _family_demography_rows.clear();
    _family_owner_seat_rows.clear();
    family_ownerships().clear();
    family_trait_rolls().clear();
    _family_colonization_population_reward_pending.clear();
    _family_trait_commands.clear();
    clear_family_founding_state();
    _family_modifier_bindings.clear();
    _family_industry_stats.clear();
    _family_owned_output_rows.clear();
    person_needs().clear();
    _person_needs_normalized = false;
    _family_member_offsets.clear();
    _family_member_edge_indices.clear();
    _family_owned_offsets.clear();
    _family_owned_edge_indices.clear();
    _family_cohort_offsets.clear();
    _family_cohort_edge_indices.clear();
    _family_building_offsets.clear();
    _family_building_edge_indices.clear();
    _family_cell_offsets.clear();
    _family_cell_indices.clear();
    _family_indices_dirty = true;
    _person_family_offsets.clear(); _person_family_indices.clear();
    _person_cohort_offsets.clear(); _person_cohort_indices.clear();
    _person_cohort_migrations.clear();
    _person_family_migrations.clear();
    _person_stable_ids.clear();
    _family_stable_ids.clear();
    _family_surname_members.clear();
    _person_cell_offsets.clear(); _person_cell_indices.clear();
    _person_building_offsets.clear(); _person_building_indices.clear();
    _person_need_offsets.clear(); _person_indices_dirty = true;
    _restore.header_seen = true;
    return true;
}

} // namespace pk
