#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_persistence_codec.h"
#include "modifier_runtime.h"

#include <algorithm>
#include <limits>
#include <unordered_map>
#include <unordered_set>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace persistence_codec;

bool NativeEconomyRuntime::decode_restore_chunk(const std::vector<uint8_t> &bytes,
                                                std::string &error) {
    size_t cursor = 0;
    uint32_t magic = 0;
    uint16_t schema = 0;
    uint16_t section = 0;
    uint32_t records = 0;
    uint32_t payload_bytes = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, schema) ||
        !read_le(bytes, cursor, section) || !read_le(bytes, cursor, records) ||
        !read_le(bytes, cursor, payload_bytes) || magic != SAVE_MAGIC ||
        payload_bytes != bytes.size() - cursor ||
        (_restore.header_seen && schema != _restore.schema_version)) {
        error = "save_chunk_header_invalid";
        return false;
    }
    if (schema != SCHEMA_VERSION) {
        error = "economy_save_price_v6_requires_new_game";
        return false;
    }
    if (!_restore.header_seen && section != SAVE_SECTION_HEADER) {
        error = "save_header_chunk_required_first";
        return false;
    }
    if (section == SAVE_SECTION_HEADER) {
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
        int32_t saved_family_mode = _family_runtime_mode;
        int32_t saved_family_min_tier = _family_min_settlement_tier;
        int32_t saved_family_review_days = _family_review_days;
        int64_t saved_family_min_population =
            _family_min_population_per_active;
        int64_t saved_family_split_population_threshold =
            _family_split_population_threshold;
        int32_t saved_family_max_per_cell = _family_max_per_cell;
        int32_t saved_family_decline_reviews = _family_decline_reviews;
        int64_t saved_person_catalog_hash = _person_catalog_hash;
        int32_t saved_person_mode = _person_runtime_mode;
        int32_t saved_person_max_per_family = _person_max_per_family;
        int32_t saved_person_max_per_cell = _person_max_per_cell;
        int32_t saved_person_max_total = _person_max_total;
        int32_t saved_person_records_per_slice = _person_records_per_slice;
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
             saved_prosperity_profile_hash != _prosperity_profile_hash)) {
            error = "save_prosperity_profile_hash_mismatch";
            return false;
        }
        int32_t saved_building_plan_days = _building_plan_days;
        if (schema >= 25 && !read_le(bytes, cursor, saved_building_plan_days)) {
            error = "save_building_plan_days_mismatch";
            return false;
        }
        if (schema >= 25 && schema < 38 &&
            saved_building_plan_days != _building_plan_days) {
            error = "save_building_plan_days_mismatch";
            return false;
        }
        if (schema >= 26) {
            if (!read_le(bytes, cursor, saved_family_catalog_hash) ||
                (saved_family_catalog_hash != _family_catalog_hash &&
                 !(schema == 39 && _family_catalog_compat_hash_v39 != 0 &&
                   saved_family_catalog_hash == _family_catalog_compat_hash_v39))) {
                error = "save_family_catalog_hash_mismatch";
                return false;
            }
            if (!read_le(bytes, cursor, saved_family_mode) ||
                !read_le(bytes, cursor, saved_family_min_tier) ||
                !read_le(bytes, cursor, saved_family_review_days) ||
                !read_le(bytes, cursor, saved_family_min_population) ||
                (schema >= 40 && !read_le(bytes, cursor,
                    saved_family_split_population_threshold)) ||
                !read_le(bytes, cursor, saved_family_max_per_cell) ||
                !read_le(bytes, cursor, saved_family_decline_reviews)) {
                error = "save_family_policy_header_payload_truncated";
                return false;
            }
            if (saved_family_mode != _family_runtime_mode ||
                saved_family_min_tier != _family_min_settlement_tier ||
                saved_family_review_days != _family_review_days ||
                saved_family_min_population !=
                    _family_min_population_per_active ||
                saved_family_split_population_threshold !=
                    _family_split_population_threshold ||
                saved_family_max_per_cell != _family_max_per_cell ||
                saved_family_decline_reviews != _family_decline_reviews) {
                error = "save_family_policy_profile_mismatch";
                return false;
            }
        }
        if (schema >= 27) {
            if (!read_le(bytes, cursor, saved_person_catalog_hash) ||
                saved_person_catalog_hash != _person_catalog_hash) {
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
            if (saved_person_mode != _person_runtime_mode ||
                saved_person_max_per_family != _person_max_per_family ||
                saved_person_max_per_cell != _person_max_per_cell ||
                saved_person_max_total != _person_max_total ||
                saved_person_records_per_slice != _person_records_per_slice) {
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
            saved_trait_catalog_version != _family_trait_catalog_version ||
            saved_trait_catalog_hash != _family_trait_catalog_hash ||
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
            ceiling_confirm != _price_ceiling_confirm_days || ceiling_expand != _price_ceiling_expand_bp ||
            ceiling_recover != _price_ceiling_recover_bp || ceiling_count < 0 ||
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
            static_cast<int64_t>(_cell_count);
        if (!read_id_table(bytes, cursor, professions) || !read_id_table(bytes, cursor, ethnicities) ||
            !read_id_table(bytes, cursor, good_ids) || !read_id_table(bytes, cursor, plan_ids) ||
            cursor != bytes.size()) {
            error = "save_header_payload_truncated";
            return false;
        }
        const bool market_hash_ok = schema == 10
            ? (_catalog_compat_hash_v10 != 0 && catalog_hash == _catalog_compat_hash_v10)
            : (schema == 13 ? (_catalog_compat_hash_v13 != 0 &&
                catalog_hash == _catalog_compat_hash_v13) :
                (schema == 39 ? (_catalog_compat_hash_v39 != 0 &&
                    catalog_hash == _catalog_compat_hash_v39) :
                    catalog_hash == _catalog_hash));
        const bool building_hash_ok = schema == 13
            ? (_building_catalog_compat_hash_v13 != 0 &&
               building_catalog_hash == _building_catalog_compat_hash_v13)
            : building_catalog_hash == _building_catalog_hash;
        if (saved_cells != _cell_count || markets <= 0 || markets > _cell_count ||
            goods != static_cast<int32_t>(_good_ids.size()) || pages < 0 || active_count < 0 ||
            active_count > static_cast<int64_t>(pages) * COHORT_PAGE_SIZE ||
            pending_count < 0 || pending_count > 1000000 ||
            audit_count < 0 || audit_count > 3650 || signal_count < 0 ||
            signal_count > 10000000 || labor_signal_count < 0 ||
            labor_signal_count > 10000000 || next_event_id <= 0 ||
            trade_order_count < 0 || trade_order_count > _trade_max_orders ||
            trade_flow_count < 0 || trade_flow_count > _trade_max_signals ||
            tariff_history_count < 0 || tariff_history_count > 1000000 ||
            country_good_count < 0 || country_good_count > 10000000 ||
            country_partner_count < 0 || country_partner_count > 10000000 ||
            next_trade_order_id <= 0 ||
            person_count < 0 || person_count > _person_max_total ||
            person_need_count < 0 || person_need_count >
                _person_max_total * MAX_NEEDS_PER_PLAN ||
            !market_hash_ok || money_scale != MONEY_SCALE ||
            goods_scale != GOODS_SCALE || ratio_scale != Q16_ONE || rate_scale != Q32_ONE ||
            professions != _profession_ids || ethnicities != _ethnicity_ids ||
            good_ids != _good_ids || plan_ids != _plan_ids) {
            error = "save_catalog_scale_or_capacity_mismatch";
            return false;
        }
        if (schema >= 11 && (saved_trade_mode != _trade_runtime_mode ||
            saved_trade_capacity != _trade_capacity_per_merchant_q16 ||
            saved_trade_speed != _trade_speed_cost_per_day ||
            saved_trade_margin != _trade_min_margin_q16 ||
            saved_trade_targets != _trade_target_count ||
            saved_trade_signal_budget != _trade_signal_pairs_per_slice ||
            saved_trade_route_budget != _trade_route_searches_per_slice ||
            saved_trade_expansions != _trade_max_route_expansions ||
            saved_trade_cache != _trade_route_cache_entries ||
            saved_trade_signals != _trade_max_signals ||
            saved_trade_candidates != _trade_max_candidates ||
            saved_trade_orders != _trade_max_orders ||
            saved_trade_alpha != _trade_flow_ema_alpha_q16 ||
            saved_trade_stock_share != _trade_max_stock_share_q16)) {
            error = "save_trade_profile_mismatch";
            return false;
        }
        const bool policy_matches =
            saved_loss_threshold == _building_severe_loss_threshold_q16 &&
            saved_loss_cycles == _building_severe_loss_cycles &&
            saved_restart_margin == _building_restart_margin_q16 &&
            saved_restart_cycles == _building_restart_cycles &&
            saved_merchant_reserve == _merchant_procurement_cash_reserve_q16 &&
            saved_market_making_days == _merchant_market_making_days_q16 &&
            saved_credit_mode == _merchant_credit_runtime_mode &&
            saved_credit_exposure == _merchant_credit_exposure_q16 &&
            saved_credit_premium == _merchant_credit_premium_q16 &&
            saved_credit_terms == _merchant_credit_term_cycles &&
            saved_recovery_cycles == _recovery_success_cycles &&
            saved_liquidation_reviews == _recovery_liquidation_failed_reviews;
        // v33/v34 saves contain the retired probe/restart policy fields. They
        // remain decodable, but the current profile is authoritative after
        // migration, including the one-year suspended liquidation window.
        if ((schema >= 35 && !policy_matches) ||
            (schema == 11 && _trade_runtime_mode == 2 && !policy_matches)) {
            error = "save_business_policy_profile_mismatch";
            return false;
        }
        const bool dynamic_policy_matches =
            saved_trade_export_days == _trade_export_floor_days &&
            saved_trade_export_fraction == _trade_export_inventory_fraction_q16 &&
            saved_trade_import_fraction == _trade_import_fill_fraction_q16 &&
            saved_trade_response_days == _trade_response_days &&
            (schema >= 38 ||
             saved_investment_review_days == _investment_review_days) &&
            saved_investment_shortage == _investment_min_shortage_q16 &&
            saved_investment_utilization == _investment_min_utilization_q16 &&
            saved_investment_payback_days == _investment_max_payback_days &&
            saved_investment_cycles == _investment_operating_cycles &&
            saved_investment_gap_fill_share ==
                _investment_gap_fill_share_q16 &&
            saved_investment_portfolio_max_types ==
                _investment_portfolio_max_types &&
            saved_investment_max_type_owner_share ==
                _investment_max_type_owner_share_q16 &&
            saved_investment_max_growth_share ==
                _investment_max_growth_share_q16 &&
            saved_investment_new_type_seed_buildings ==
                _investment_new_type_seed_buildings &&
            saved_investment_merchant_transition_min_improvement ==
                _investment_merchant_transition_min_improvement_q16 &&
            saved_recovery_liquidation_max_share ==
                _recovery_liquidation_max_share_q16 &&
            saved_resource_reserve == _resource_min_reserve_q16 &&
            saved_resource_harvest == _resource_safe_harvest_q16 &&
            saved_resource_horizon == _resource_min_horizon_days &&
            saved_bullion_cap == _bullion_monthly_issue_cap_q16 &&
            saved_support_cap == _producer_support_monthly_cap_q16;
        if (schema >= 35 && !dynamic_policy_matches) {
            error = "save_dynamic_policy_profile_mismatch";
            return false;
        }
        const bool country_schema_compatible =
            country_schema == NativeCountryRuntime::SCHEMA_VERSION ||
            (schema == 22 && country_schema == 3) ||
            (schema <= 19 && country_schema == 1);
        const uint64_t expected_country_hash =
            schema == 22 && country_schema == 3 &&
                    _country_runtime != nullptr
                ? static_cast<uint64_t>(
                    _country_runtime->state_hash_v3_compat())
                : (_country_runtime != nullptr
                    ? static_cast<uint64_t>(_country_runtime->state_hash())
                    : 0);
        if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
            !country_schema_compatible ||
            country_generation != _country_runtime->generation() ||
            country_hash != expected_country_hash) {
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
        population_store().clear(_cell_count);
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
        market_store().cell_to_market.assign(_cell_count, -1);
        _market_signals.clear(_cell_count);
        _market_signals.good_ids.reserve(signal_count);
        _market_signals.business_demand_ema.reserve(signal_count);
        _market_signals.offered_supply_ema.reserve(signal_count);
        _market_signals.realized_withdrawal_ema.reserve(signal_count);
        _market_signals.cost_anchor_price.reserve(signal_count);
        _labor_signals.clear(_cell_count);
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
        _environment_temperature_q16.assign(_cell_count, 0);
        _environment_temperature_30d_q16.assign(_cell_count, 0);
        _environment_moisture_q16.assign(_cell_count, 0);
        _environment_plant_available_water_q16.assign(_cell_count, 0);
        _environment_precipitation_q16.assign(_cell_count, 0);
        _environment_snow_q16.assign(_cell_count, 0);
        _environment_weather_q16.assign(_cell_count, 0);
        _cell_living_cost_per_capita.assign(_cell_count, 0);
        _epoch_cell_development_q16.assign(_cell_count, 0);
        _cell_social_pressure_level.assign(_cell_count, 0);
        _cell_support_ema_q16.assign(_cell_count, Q16_ONE);
        _cell_food_output_eq_period.assign(_cell_count, 0);
        _cell_food_input_eq_period.assign(_cell_count, 0);
        _cell_food_import_eq_period.assign(_cell_count, 0);
        _cell_food_export_eq_period.assign(_cell_count, 0);
        _cell_food_access_eq_period.assign(_cell_count, 0);
        _cell_food_output_eq_previous.assign(_cell_count, 0);
        _cell_food_input_eq_previous.assign(_cell_count, 0);
        _cell_food_import_eq_previous.assign(_cell_count, 0);
        _cell_food_export_eq_previous.assign(_cell_count, 0);
        _cell_food_access_eq_previous.assign(_cell_count, 0);
        _cell_food_flow_valid.assign(_cell_count, 0);
        _food_flow_previous_period_days = 0;
        _cell_carrying_k_geo.assign(_cell_count, _carrying_k_habitat_ref);
        _cell_carrying_k_eff.assign(_cell_count, _carrying_k_habitat_ref);
        _cell_carrying_surplus_q16.assign(_cell_count, Q16_ONE);
        _cell_carrying_sat_q16.assign(_cell_count, Q16_ONE);
        _cell_carrying_family_surplus_q16.assign(
            static_cast<size_t>(_cell_count) * CARRYING_FAMILY_COUNT, Q16_ONE);
        _cell_carrying_family_bindable.assign(
            static_cast<size_t>(_cell_count) * CARRYING_FAMILY_COUNT, 0);
        _environment_day = environment_day;
        _environment_hash = environment_hash;
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
                        _locked_slow_cycle_days,
                        _locked_market_cycle_days,
                        saved_investment_review_days);
                const int32_t invest_cycle = std::max(
                    1, _locked_investment_cycle_days);
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
                    _maintenance_horizon_days_by_sector[sector] =
                        saved_maintenance_horizons[sector];
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
        family_influences().clear();
        persons_store().clear();
        family_memberships().clear();
        family_ownerships().clear();
        family_trait_rolls().clear();
        _family_trait_commands.clear();
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
    if (section == SAVE_SECTION_PAGES) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t page = -1, next = -1, cell = -1;
            if (!read_le(bytes, cursor, page) || !read_le(bytes, cursor, next) ||
                !read_le(bytes, cursor, cell) || page != _restore.restored_pages ||
                page < 0 || page >= _restore.expected_pages) {
                error = "save_page_record_invalid";
                return false;
            }
            population_store().page_next[page] = next;
            population_store().page_cell[page] = cell;
            const int32_t base = page * COHORT_PAGE_SIZE;
            for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
                const int32_t slot = base + lane;
                if (!read_le(bytes, cursor, population_store().active[slot]) ||
                    !read_le(bytes, cursor, population_store().signature_id[slot]) ||
                    !read_le(bytes, cursor, population_store().generation[slot]) ||
                    !read_le(bytes, cursor, population_store().population[slot]) ||
                    !read_le(bytes, cursor, population_store().funds[slot]) ||
                    !read_le(bytes, cursor, population_store().epoch_income[slot]) ||
                    !read_le(bytes, cursor, population_store().epoch_expense[slot]) ||
                    !read_le(bytes, cursor, population_store().income_ema[slot]) ||
                    !read_le(bytes, cursor, population_store().needs_satisfaction[slot]) ||
                    !read_le(bytes, cursor, population_store().worst_need_id[slot]) ||
                    !read_le(bytes, cursor, population_store().flags[slot]) ||
                    !read_le(bytes, cursor, population_store().demography_residual[slot]) ||
                    !read_le(bytes, cursor, population_store().owner_employed[slot]) ||
                    !read_le(bytes, cursor, population_store().employee_employed[slot]) ||
                    !read_le(bytes, cursor, population_store().composite_satisfaction[slot]) ||
                    !read_le(bytes, cursor, population_store().worst_dimension_id[slot])) {
                    error = "save_page_payload_truncated";
                    return false;
                }
                const size_t dims_base = static_cast<size_t>(slot) *
                    static_cast<size_t>(SAT_DIM_COUNT);
                // satisfaction_dims 是 uint16_t（[0, 65535]），而合法值域上限恰好就是
                // Q16_ONE - 1 = 65535——两者重合，所以「>= Q16_ONE(65536)」这类范围检查
                // 对该存储类型永远不可能为真（也是 clang 在 web 构建里报
                // -Wtautological-constant-out-of-range-compare 的位置）。不是漏检：
                // 任何能从文件里读出来的比特模式已经天然落在合法区间，删掉判断不改变
                // 校验结果，只是去掉死代码。
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
                    if (!read_le(bytes, cursor,
                                 population_store().satisfaction_dims[
                                     dims_base + static_cast<size_t>(dim)])) {
                        error = "save_page_payload_truncated";
                        return false;
                    }
                }
                if (!read_le(bytes, cursor, population_store().income_baseline_ema[slot]) ||
                    !read_le(bytes, cursor, population_store().epoch_tax_paid[slot]) ||
                    !read_le(bytes, cursor,
                             population_store().epoch_subsidy_received[slot])) {
                    error = "save_page_payload_truncated";
                    return false;
                }
                // composite_satisfaction 同样是 uint16_t，见上方 satisfaction_dims 的
                // 注释——「>= Q16_ONE」对该类型恒假，不是遗漏的校验条件。
                if ((population_store().worst_dimension_id[slot] !=
                         std::numeric_limits<uint8_t>::max() &&
                     population_store().worst_dimension_id[slot] >= SAT_DIM_COUNT) ||
                    population_store().epoch_tax_paid[slot] < 0 ||
                    population_store().epoch_subsidy_received[slot] < 0) {
                    error = "save_page_satisfaction_state_out_of_range";
                    return false;
                }
            }
            ++_restore.restored_pages;
        }
    } else if (section == SAVE_SECTION_MARKETS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t market = -1;
            if (!read_le(bytes, cursor, market) || market != _restore.restored_markets ||
                market < 0 || market >= market_store().market_count) {
                error = "save_market_record_invalid";
                return false;
            }
            for (int32_t good = 0; good < market_store().good_count; ++good) {
                const int64_t idx = market_store().index(market, good);
                if (!read_le(bytes, cursor, market_store().stock[idx]) ||
                    !read_le(bytes, cursor, market_store().price[idx]) ||
                    !read_le(bytes, cursor, market_store().demand_ema[idx]) ||
                    !read_le(bytes, cursor, market_store().last_shortage_q16[idx])) {
                    error = "save_market_payload_truncated";
                    return false;
                }
            }
            ++_restore.restored_markets;
        }
    } else if (section == SAVE_SECTION_CELLS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1, market = -1;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, market) ||
                cell != _restore.restored_cells || cell < 0 || cell >= _cell_count) {
                error = "save_cell_market_record_invalid";
                return false;
            }
            if (!read_le(bytes, cursor, _environment_temperature_q16[cell]) ||
                !read_le(bytes, cursor, _environment_temperature_30d_q16[cell]) ||
                !read_le(bytes, cursor, _environment_moisture_q16[cell]) ||
                !read_le(bytes, cursor, _environment_plant_available_water_q16[cell]) ||
                !read_le(bytes, cursor, _environment_precipitation_q16[cell]) ||
                !read_le(bytes, cursor, _environment_snow_q16[cell]) ||
                !read_le(bytes, cursor, _environment_weather_q16[cell])) {
                error = "save_cell_environment_record_invalid";
                return false;
            }
            if (schema >= 15) {
                int32_t saved_phase = -1;
                const int32_t expected_phase = schema >= 38
                    ? ((cell % std::max(1, locked_market_cycle_days())) +
                        locked_market_cycle_days()) %
                        locked_market_cycle_days()
                    : cell % ROLLING_PHASE_COUNT;
                if (!read_le(bytes, cursor, _cell_last_settlement_day[cell]) ||
                    !read_le(bytes, cursor, _cell_settlement_generation[cell]) ||
                    !read_le(bytes, cursor, _cell_price_stock_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_owner_cash_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_population_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_building_structure_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_technology_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_resource_gen[cell]) ||
                    !read_le(bytes, cursor, _cell_trade_gen[cell]) ||
                    !read_le(bytes, cursor, saved_phase) ||
                    saved_phase != expected_phase) {
                    error = "save_cell_rolling_state_invalid";
                    return false;
                }
            }
            if (schema >= 23) {
                if (!read_le(bytes, cursor,
                        _fiscal_previous_country_handles[cell])) {
                    error = "save_cell_fiscal_country_truncated";
                    return false;
                }
                for (int32_t kind = 0;
                     kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
                    const size_t lane = static_cast<size_t>(cell) *
                        ACTIVE_TAX_KIND_COUNT + kind;
                    if (!read_le(bytes, cursor,
                            _fiscal_previous_requests[lane]) ||
                        _fiscal_previous_requests[lane] < 0) {
                        error = "save_cell_fiscal_request_invalid";
                        return false;
                    }
                }
            }
            if (schema >= 24) {
                uint8_t tier_flags = 0;
                if (!read_le(bytes, cursor, tier_flags) ||
                    !read_le(bytes, cursor,
                        _settlements.prosperity_generation[cell]) ||
                    !read_le(bytes, cursor,
                        _settlements.name_roll_generation[cell]) ||
                    (tier_flags & 0x7fU) >= _prosperity_thresholds.size()) {
                    error = "save_cell_settlement_state_invalid";
                    return false;
                }
                _settlements.tier[cell] =
                    static_cast<uint8_t>(tier_flags & 0x7fU);
                _settlements.name_forced[cell] =
                    (tier_flags & 0x80U) != 0 ? 1 : 0;
            }
            if (schema >= 30) {
                if (!read_le(bytes, cursor, _cell_social_pressure_level[cell]) ||
                    _cell_social_pressure_level[cell] >= SAT_PRESSURE_LEVEL_COUNT) {
                    error = "save_cell_social_pressure_level_invalid";
                    return false;
                }
            }
            if (schema >= 28) {
                const size_t birth_lane_begin =
                    static_cast<size_t>(cell) * _ethnicity_ids.size();
                for (size_t ethnicity = 0; ethnicity < _ethnicity_ids.size(); ++ethnicity) {
                    int64_t &residual_q32 =
                        _birth_residual_q32[birth_lane_begin + ethnicity];
                    if (!read_le(bytes, cursor, residual_q32) ||
                        residual_q32 < 0 || residual_q32 >= Q32_ONE) {
                        error = "save_cell_birth_residual_invalid";
                        return false;
                    }
                }
            }
            if (schema >= 36) {
                if (!read_le(bytes, cursor, _cell_support_ema_q16[cell]) ||
                    _cell_support_ema_q16[cell] < 0 ||
                    _cell_support_ema_q16[cell] > Q16_ONE * 4) {
                    error = "save_cell_support_ema_invalid";
                    return false;
                }
            }
            if (schema >= 45) {
                int32_t saved_food_days = 0;
                if (!read_le(bytes, cursor, _cell_food_flow_valid[cell]) ||
                    !read_le(bytes, cursor, _cell_food_output_eq_previous[cell]) ||
                    !read_le(bytes, cursor, _cell_food_input_eq_previous[cell]) ||
                    !read_le(bytes, cursor, _cell_food_import_eq_previous[cell]) ||
                    !read_le(bytes, cursor, _cell_food_export_eq_previous[cell]) ||
                    !read_le(bytes, cursor, _cell_food_access_eq_previous[cell]) ||
                    !read_le(bytes, cursor, saved_food_days) ||
                    _cell_food_flow_valid[cell] > 1 ||
                    _cell_food_output_eq_previous[cell] < 0 ||
                    _cell_food_input_eq_previous[cell] < 0 ||
                    _cell_food_import_eq_previous[cell] < 0 ||
                    _cell_food_export_eq_previous[cell] < 0 ||
                    _cell_food_access_eq_previous[cell] < 0 ||
                    saved_food_days < 0) {
                    error = "save_food_flow_payload_invalid";
                    return false;
                }
                _food_flow_previous_period_days = std::max(
                    _food_flow_previous_period_days, saved_food_days);
            }
            market_store().cell_to_market[cell] = market;
            ++_restore.restored_cells;
        }
    } else if (section == SAVE_SECTION_COMMANDS) {
        for (uint32_t record = 0; record < records; ++record) {
            Command cmd;
            if (!read_le(bytes, cursor, cmd.opcode) || !read_le(bytes, cursor, cmd.effective_day) ||
                !read_le(bytes, cursor, cmd.sequence) || !read_le(bytes, cursor, cmd.target_handle) ||
                !read_le(bytes, cursor, cmd.i32_0) || !read_le(bytes, cursor, cmd.i32_1) ||
                !read_le(bytes, cursor, cmd.i64_0) || !read_le(bytes, cursor, cmd.i64_1) ||
                !read_le(bytes, cursor, cmd.submit_order) ||
                (_restore.schema_version >= 31 &&
                    (!read_le(bytes, cursor, cmd.effect_request_id) ||
                     !read_le(bytes, cursor, cmd.effect_idempotency_key)))) {
                error = "save_command_payload_truncated";
                return false;
            }
            if (cmd.effect_request_id < 0 ||
                (cmd.effect_request_id == 0 && cmd.effect_idempotency_key != 0) ||
                (cmd.effect_request_id != 0 && cmd.effect_idempotency_key == 0)) {
                error = "save_effect_command_identity_invalid";
                return false;
            }
            if (cmd.effect_request_id != 0) {
                if (!_effect_idempotency_requests.emplace(
                        cmd.effect_idempotency_key, cmd.effect_request_id).second ||
                    !_effect_command_results.emplace(cmd.effect_request_id,
                        EffectCommandResult{}).second) {
                    error = "save_effect_command_identity_duplicate";
                    return false;
                }
                _next_effect_request_id = std::max(_next_effect_request_id,
                    cmd.effect_request_id + 1);
            }
            _pending_commands.push_back(cmd);
            ++_restore.restored_commands;
        }
    } else if (section == SAVE_SECTION_BUILDINGS) {
        for (uint32_t record = 0; record < records; ++record) {
            BuildingGroup group;
            int32_t roles = 0;
            if (!read_le(bytes, cursor, group.cell) || !read_le(bytes, cursor, group.type_id) ||
                !read_le(bytes, cursor, group.owner_signature_id) ||
                !read_le(bytes, cursor, group.count) ||
                !read_le(bytes, cursor, group.filled_owner) ||
                !read_le(bytes, cursor, group.last_capacity_q16) ||
                !read_le(bytes, cursor, group.last_temperature_fit_q16) ||
                !read_le(bytes, cursor, group.last_water_fit_q16) ||
                !read_le(bytes, cursor, group.last_climate_capacity_q16) ||
                !read_le(bytes, cursor, group.last_climate_lost_output) ||
                !read_le(bytes, cursor, group.last_input) ||
                !read_le(bytes, cursor, group.last_output) ||
                !read_le(bytes, cursor, group.last_sold) ||
                !read_le(bytes, cursor, group.last_discarded) ||
                !read_le(bytes, cursor, group.last_resource) ||
                !read_le(bytes, cursor, group.last_resource_generated) ||
                !read_le(bytes, cursor, group.last_revenue) ||
                !read_le(bytes, cursor, group.last_input_cost) ||
                !read_le(bytes, cursor, group.last_wages_paid) ||
                !read_le(bytes, cursor, group.last_wages_due) ||
                !read_le(bytes, cursor, group.last_expected_revenue) ||
                !read_le(bytes, cursor, group.last_operating_cost) ||
                !read_le(bytes, cursor, group.last_margin_gap_q16) ||
                !read_le(bytes, cursor, group.planned_utilization_q16) ||
                !read_le(bytes, cursor, group.last_base_wages_paid) ||
                !read_le(bytes, cursor, group.last_base_wages_due) ||
                !read_le(bytes, cursor, group.last_bonus_paid) ||
                !read_le(bytes, cursor, group.last_bonus_due) ||
                !read_le(bytes, cursor, group.wage_suspended)) {
                error = "save_building_record_invalid";
                return false;
            }
            if (_restore.schema_version >= 12 &&
                (!read_le(bytes, cursor, group.purchase_intent_capacity_q16) ||
                 !read_le(bytes, cursor, group.realized_profit_margin_q16) ||
                 !read_le(bytes, cursor, group.severe_loss_cycles) ||
                 !read_le(bytes, cursor, group.recovery_cycles) ||
                 !read_le(bytes, cursor, group.operating_state) ||
                 (_restore.schema_version >= 19 &&
                  (!read_le(bytes, cursor, group.pending_operating_state) ||
                   !read_le(bytes, cursor, group.recovery_cooldown_cycles))) ||
                 !read_le(bytes, cursor, group.recovery_failed_reviews) ||
                 !read_le(bytes, cursor, group.merchant_debt_term_cycles_left) ||
                 !read_le(bytes, cursor, group.merchant_debt_delinquent_cycles) ||
                 !read_le(bytes, cursor, group.merchant_debt_principal) ||
                 !read_le(bytes, cursor, group.merchant_debt_premium) ||
                 !read_le(bytes, cursor, group.last_in_kind_livelihood_value))) {
                error = "save_building_business_state_payload_truncated";
                return false;
            }
            if (_restore.schema_version >= 47 &&
                (!read_le(bytes, cursor, group.last_market_receipt) ||
                 !read_le(bytes, cursor, group.last_bullion_mint_receipt) ||
                 !read_le(bytes, cursor, group.last_producer_support_receipt) ||
                 !read_le(bytes, cursor, group.last_business_tax_paid) ||
                 !read_le(bytes, cursor, group.last_business_subsidy_received) ||
                 !read_le(bytes, cursor, group.last_maintenance_due) ||
                 !read_le(bytes, cursor, group.last_observed_capacity_days_q16) ||
                 !read_le(bytes, cursor, group.last_quoted_market_receipt) ||
                 !read_le(bytes, cursor, group.last_quoted_operating_cost))) {
                error = "save_building_fact_quote_payload_truncated";
                return false;
            }
            if (!read_le(bytes, cursor, roles) || group.cell < 0 || group.cell >= _cell_count ||
                group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()) ||
                group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
                group.count <= 0 || roles != _building_types[group.type_id].employee_count ||
                group.last_temperature_fit_q16 < 0 ||
                group.last_temperature_fit_q16 > Q16_ONE ||
                group.last_water_fit_q16 < 0 ||
                group.last_water_fit_q16 > Q16_ONE ||
                group.last_climate_capacity_q16 < 0 ||
                group.last_climate_capacity_q16 > Q16_ONE ||
                group.last_climate_lost_output < 0 ||
                group.purchase_intent_capacity_q16 < 0 ||
                group.purchase_intent_capacity_q16 > Q16_ONE ||
                (group.pending_operating_state > 1 && group.pending_operating_state != 255) ||
                group.operating_state > 1 || group.merchant_debt_principal < 0 ||
                group.merchant_debt_premium < 0 ||
                group.last_in_kind_livelihood_value < 0 ||
                group.last_market_receipt < 0 ||
                group.last_bullion_mint_receipt < 0 ||
                group.last_producer_support_receipt < 0 ||
                group.last_business_tax_paid < 0 ||
                group.last_business_subsidy_received < 0 ||
                group.last_maintenance_due < 0 ||
                group.last_observed_capacity_days_q16 < 0 ||
                group.last_quoted_market_receipt < 0 ||
                group.last_quoted_operating_cost < 0 ||
                ((group.merchant_debt_principal > 0 || group.merchant_debt_premium > 0) &&
                 group.merchant_debt_term_cycles_left == 0 &&
                 group.merchant_debt_delinquent_cycles == 0)) {
                error = "save_building_record_invalid";
                return false;
            }
            group.employee_fill_begin = static_cast<int32_t>(_building_employee_filled.size());
            group.last_input_selection_begin = static_cast<int32_t>(
                _building_last_input_selected_goods.size());
            _building_last_input_selected_goods.resize(
                _building_last_input_selected_goods.size() +
                    static_cast<size_t>(_building_types[group.type_id].input_count),
                -1);
            for (int32_t r = 0; r < roles; ++r) {
                int64_t value = 0;
                if (!read_le(bytes, cursor, value) || value < 0) {
                    error = "save_building_role_payload_invalid";
                    return false;
                }
                _building_employee_filled.push_back(value);
                const JobRole &role = _building_employee_roles[
                    _building_types[group.type_id].employee_begin + r];
                int64_t contract = role.reference_wage_per_day;
                int64_t base_living = 0;
                int64_t role_living = 0;
                int64_t local_average = 0;
                int64_t base_due = 0;
                int64_t base_paid = 0;
                int64_t bonus_due = 0;
                int64_t bonus_paid = 0;
                if (!read_le(bytes, cursor, contract) ||
                     !read_le(bytes, cursor, base_living) ||
                     !read_le(bytes, cursor, role_living) ||
                     !read_le(bytes, cursor, local_average) ||
                     !read_le(bytes, cursor, base_due) ||
                     !read_le(bytes, cursor, base_paid) ||
                     !read_le(bytes, cursor, bonus_due) ||
                     !read_le(bytes, cursor, bonus_paid)) {
                    error = "save_building_role_wage_payload_invalid";
                    return false;
                }
                if (contract < 0 || base_living < 0 || role_living < 0 ||
                    local_average < 0 || base_due < 0 || base_paid < 0 ||
                    bonus_due < 0 || bonus_paid < 0 || base_paid > base_due ||
                    bonus_paid > bonus_due) {
                    error = "save_building_role_wage_value_invalid";
                    return false;
                }
                _building_role_contract_wage.push_back(contract);
                _building_role_base_living_cost.push_back(base_living);
                _building_role_living_cost.push_back(role_living);
                _building_role_local_average_wage.push_back(local_average);
                _building_role_base_wage_due.push_back(base_due);
                _building_role_base_wage_paid.push_back(base_paid);
                _building_role_bonus_due.push_back(bonus_due);
                _building_role_bonus_paid.push_back(bonus_paid);
                _building_role_forecast_pay_ratio_q16.push_back(0);
            }
            append_building_group(group);
            ++_restore.restored_buildings;
        }
    } else if (section == SAVE_SECTION_CONSTRUCTION) {
        for (uint32_t record = 0; record < records; ++record) {
            PendingConstruction pending;
            if (!read_le(bytes, cursor, pending.cell) || !read_le(bytes, cursor, pending.type_id) ||
                !read_le(bytes, cursor, pending.owner_signature_id) ||
                !read_le(bytes, cursor, pending.count) ||
                !read_le(bytes, cursor, pending.ready_day) ||
                !read_le(bytes, cursor, pending.sequence) ||
                !read_le(bytes, cursor, pending.merchant_debt_principal) ||
                !read_le(bytes, cursor, pending.merchant_debt_premium) ||
                !read_le(bytes, cursor, pending.merchant_debt_term_cycles_left) ||
                (schema >= 26 && !read_le(bytes, cursor,
                    pending.sponsor_family_handle)) ||
                pending.cell < 0 ||
                pending.cell >= _cell_count || pending.type_id < 0 ||
                pending.type_id >= static_cast<int32_t>(_building_types.size()) ||
                pending.owner_signature_id < 0 ||
                pending.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
                pending.count <= 0 || pending.merchant_debt_principal < 0 ||
                pending.merchant_debt_premium < 0 ||
                ((pending.merchant_debt_principal > 0 ||
                  pending.merchant_debt_premium > 0) &&
                 pending.merchant_debt_term_cycles_left == 0)) {
                error = "save_construction_record_invalid";
                return false;
            }
            append_pending_construction(pending);
            ++_restore.restored_construction;
        }
    } else if (section == SAVE_SECTION_AUDIT) {
        for (uint32_t record = 0; record < records; ++record) {
            AuditFrame frame;
            if (!read_le(bytes, cursor, frame.epoch_id) ||
                !read_le(bytes, cursor, frame.sample_day) ||
                !read_le(bytes, cursor, frame.commit_day) ||
                !read_le(bytes, cursor, frame.event_count) ||
                !read_le(bytes, cursor, frame.leg_count) ||
                !read_le(bytes, cursor, frame.population_error) ||
                !read_le(bytes, cursor, frame.money_error) ||
                !read_le(bytes, cursor, frame.goods_error) ||
                !read_le(bytes, cursor, frame.stream_hash) ||
                frame.event_count < 0 || frame.leg_count < 0) {
                error = "save_audit_record_invalid";
                return false;
            }
            _audit_history.push_back(frame);
            ++_restore.restored_audits;
        }
    } else if (section == SAVE_SECTION_SIGNALS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            int32_t good = -1;
            int64_t business = 0;
            int64_t supply = 0;
            int64_t realized = 0;
            int32_t anchor = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, business) || !read_le(bytes, cursor, supply) ||
                (_restore.schema_version >= 12 && !read_le(bytes, cursor, realized)) ||
                !read_le(bytes, cursor, anchor) || cell < 0 || cell >= _cell_count ||
                good < 0 || good >= market_store().good_count || business < 0 || supply < 0 ||
                realized < 0 ||
                anchor < 0 || (anchor != 0 &&
                    (anchor < PRICE_NUMERIC_GUARD_MIN ||
                     anchor > PRICE_NUMERIC_GUARD_MAX)) ||
                (_restore.last_signal_cell > cell) ||
                (_restore.last_signal_cell == cell && _restore.last_signal_good >= good)) {
                error = "save_market_signal_record_invalid";
                return false;
            }
            _restore.last_signal_cell = cell;
            _restore.last_signal_good = good;
            ++_market_signals.cell_offsets[cell + 1];
            _market_signals.good_ids.push_back(good);
            _market_signals.business_demand_ema.push_back(business);
            _market_signals.offered_supply_ema.push_back(supply);
            _market_signals.realized_withdrawal_ema.push_back(realized);
            _market_signals.cost_anchor_price.push_back(anchor);
            ++_restore.restored_signals;
        }
    } else if (section == SAVE_SECTION_LABOR_SIGNALS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            int32_t profession = -1;
            int64_t base_living = 0;
            int64_t role_living = 0;
            int64_t contract = 0;
            int64_t paid = 0;
            int64_t jobs = 0;
            int32_t ratio = 0;
            if (!read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, profession) ||
                !read_le(bytes, cursor, base_living) ||
                !read_le(bytes, cursor, role_living) ||
                !read_le(bytes, cursor, contract) ||
                !read_le(bytes, cursor, paid) ||
                !read_le(bytes, cursor, jobs) ||
                !read_le(bytes, cursor, ratio) ||
                cell < 0 || cell >= _cell_count || profession < 0 ||
                profession >= static_cast<int32_t>(_profession_ids.size()) ||
                base_living < 0 || role_living < 0 || contract < 0 || paid < 0 ||
                jobs < 0 || ratio < 0 || ratio > Q16_ONE ||
                _restore.last_labor_cell > cell ||
                (_restore.last_labor_cell == cell &&
                 _restore.last_labor_profession >= profession)) {
                error = "save_labor_signal_record_invalid";
                return false;
            }
            _restore.last_labor_cell = cell;
            _restore.last_labor_profession = profession;
            ++_labor_signals.cell_offsets[cell + 1];
            _labor_signals.profession_ids.push_back(profession);
            _labor_signals.base_living_cost.push_back(base_living);
            _labor_signals.role_living_cost.push_back(role_living);
            _labor_signals.contract_wage_ema.push_back(contract);
            _labor_signals.paid_wage_ema.push_back(paid);
            _labor_signals.job_days.push_back(jobs);
            _labor_signals.pay_ratio_q16.push_back(ratio);
            ++_restore.restored_labor_signals;
        }
    } else if (schema >= 11 && section == SAVE_SECTION_TRADE_ORDERS) {
        for (uint32_t record = 0; record < records; ++record) {
            int64_t id = 0, departure = 0, arrival = 0, cash = 0, capacity = 0;
            int32_t source = -1, destination = -1, country = -1;
            uint64_t source_country_handle = 0;
            uint64_t destination_country_handle = 0;
            int32_t source_country_slot = -1, destination_country_slot = -1;
            uint8_t state = 0, delivered = 0;
            int32_t line_count = 0, seller_count = 0;
            if (!read_le(bytes, cursor, id) || !read_le(bytes, cursor, source) ||
                !read_le(bytes, cursor, destination) || !read_le(bytes, cursor, country) ||
                !read_le(bytes, cursor, source_country_handle) ||
                !read_le(bytes, cursor, destination_country_handle) ||
                !read_le(bytes, cursor, source_country_slot) ||
                !read_le(bytes, cursor, destination_country_slot) ||
                !read_le(bytes, cursor, departure) || !read_le(bytes, cursor, arrival) ||
                !read_le(bytes, cursor, cash) || !read_le(bytes, cursor, capacity) ||
                !read_le(bytes, cursor, state) || !read_le(bytes, cursor, delivered) ||
                !read_le(bytes, cursor, line_count) ||
                !read_le(bytes, cursor, seller_count) || id <= 0 ||
                (!trade_orders_store().ids.empty() && id <= trade_orders_store().ids.back()) ||
                source_country_handle == 0 || destination_country_handle == 0 ||
                source_country_slot < 0 || destination_country_slot < 0 ||
                source < 0 || source >= _cell_count || destination < 0 ||
                destination >= _cell_count || source == destination || country < 0 ||
                departure < 0 || arrival < departure || cash < 0 || capacity <= 0 ||
                state > TradeOrderStore::WAITING_RECEIVER || delivered > 1 ||
                (state == TradeOrderStore::IN_TRANSIT && delivered != 0) ||
                (state == TradeOrderStore::WAITING_RECEIVER && delivered == 0) ||
                line_count <= 0 || line_count > 16 || seller_count < 0 ||
                seller_count > 1000000) {
                error = "save_trade_order_record_invalid";
                return false;
            }
            trade_orders_store().ids.push_back(id);
            trade_orders_store().sources.push_back(source);
            trade_orders_store().destinations.push_back(destination);
            trade_orders_store().countries.push_back(country);
            trade_orders_store().source_country_handles.push_back(source_country_handle);
            trade_orders_store().destination_country_handles.push_back(
                destination_country_handle);
            trade_orders_store().source_country_slots.push_back(source_country_slot);
            trade_orders_store().destination_country_slots.push_back(
                destination_country_slot);
            trade_orders_store().departure_days.push_back(departure);
            trade_orders_store().arrival_days.push_back(arrival);
            trade_orders_store().cash_escrow.push_back(cash);
            trade_orders_store().capacity_work.push_back(capacity);
            trade_orders_store().states.push_back(state);
            trade_orders_store().cargo_delivered.push_back(delivered);
            for (int32_t line = 0; line < line_count; ++line) {
                int32_t good = -1, price = 0, destination_price = 0;
                int64_t quantity = 0, base_value = 0, retail_value = 0;
                int64_t import_transfer = 0, export_transfer = 0;
                int64_t transaction_transfer = 0;
                uint8_t line_flags = 0;
                if (!read_le(bytes, cursor, good) ||
                    !read_le(bytes, cursor, quantity) ||
                    !read_le(bytes, cursor, price) ||
                    !read_le(bytes, cursor, destination_price) ||
                    !read_le(bytes, cursor, base_value) ||
                    !read_le(bytes, cursor, retail_value) ||
                    !read_le(bytes, cursor, import_transfer) ||
                    !read_le(bytes, cursor, export_transfer) ||
                    (schema >= 46 &&
                     !read_le(bytes, cursor, transaction_transfer)) ||
                    !read_le(bytes, cursor, line_flags) || good < 0 ||
                    good >= market_store().good_count || _good_trade_enabled[good] == 0 ||
                    quantity <= 0 || price < PRICE_NUMERIC_GUARD_MIN ||
                    price > PRICE_NUMERIC_GUARD_MAX || destination_price < 0 ||
                    base_value < 0 || retail_value < 0) {
                    error = "save_trade_order_line_invalid";
                    return false;
                }
                trade_orders_store().line_goods.push_back(good);
                trade_orders_store().line_quantities.push_back(quantity);
                trade_orders_store().line_unit_prices.push_back(price);
                trade_orders_store().line_destination_prices.push_back(destination_price);
                trade_orders_store().line_base_values.push_back(base_value);
                trade_orders_store().line_retail_values.push_back(retail_value);
                trade_orders_store().line_import_transfers.push_back(import_transfer);
                trade_orders_store().line_export_transfers.push_back(export_transfer);
                trade_orders_store().line_transaction_transfers.push_back(
                    transaction_transfer);
                trade_orders_store().line_flags.push_back(line_flags);
            }
            trade_orders_store().line_offsets.push_back(
                static_cast<int32_t>(trade_orders_store().line_goods.size()));
            for (int32_t seller = 0; seller < seller_count; ++seller) {
                uint64_t handle = 0;
                int64_t weight = 0;
                if (!read_le(bytes, cursor, handle) ||
                    !read_le(bytes, cursor, weight) || handle == 0 || weight <= 0) {
                    error = "save_trade_order_seller_invalid";
                    return false;
                }
                trade_orders_store().seller_handles.push_back(handle);
                trade_orders_store().seller_weights.push_back(weight);
            }
            trade_orders_store().seller_offsets.push_back(
                static_cast<int32_t>(trade_orders_store().seller_handles.size()));
            ++_restore.restored_trade_orders;
        }
    } else if (schema >= 11 && section == SAVE_SECTION_TRADE_FLOWS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1, good = -1;
            int64_t import_ema = 0, export_ema = 0, period_import = 0,
                    period_export = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, import_ema) ||
                !read_le(bytes, cursor, export_ema) ||
                !read_le(bytes, cursor, period_import) ||
                !read_le(bytes, cursor, period_export) || cell < 0 ||
                cell >= _cell_count || good < 0 || good >= market_store().good_count ||
                import_ema < 0 || export_ema < 0 || period_import < 0 ||
                period_export < 0 || (!_trade_flows.cells.empty() &&
                    (_trade_flows.cells.back() > cell ||
                     (_trade_flows.cells.back() == cell &&
                      _trade_flows.goods.back() >= good)))) {
                error = "save_trade_flow_record_invalid";
                return false;
            }
            _trade_flows.cells.push_back(cell);
            _trade_flows.goods.push_back(good);
            _trade_flows.import_ema.push_back(import_ema);
            _trade_flows.export_ema.push_back(export_ema);
            _trade_flows.period_import.push_back(period_import);
            _trade_flows.period_export.push_back(period_export);
            ++_restore.restored_trade_flows;
        }
    } else if (schema >= 20 && section == SAVE_SECTION_MODIFIERS) {
        if (records != payload_bytes ||
            _restore.modifier_bytes.size() + payload_bytes >
                256ULL * 1024ULL * 1024ULL) {
            error = "save_modifier_section_invalid";
            return false;
        }
        _restore.modifier_bytes.insert(_restore.modifier_bytes.end(),
                                       bytes.begin() + static_cast<ptrdiff_t>(cursor),
                                       bytes.end());
        cursor = bytes.size();
        _restore.modifier_seen = true;
    } else if (schema >= 23 && section == SAVE_SECTION_FISCAL) {
        NativeCountryRuntime::EconomySnapshot country_snapshot;
        if (_country_runtime == nullptr ||
            !_country_runtime->copy_economy_snapshot(country_snapshot)) {
            error = "save_fiscal_country_snapshot_unavailable";
            return false;
        }
        const int32_t country_count = std::max(0,
            country_snapshot.country_count);
        const size_t summary_count = static_cast<size_t>(country_count) *
            NativeCountryRuntime::TAX_KIND_COUNT;
        if (_restore.expected_fiscal < 0) {
            _restore.expected_fiscal = country_count;
            _fiscal_escrow_by_country.assign(
                static_cast<size_t>(country_count), 0);
        } else if (_restore.expected_fiscal != country_count ||
                   _restore.restored_fiscal +
                       static_cast<int64_t>(records) > country_count) {
            error = "save_fiscal_record_count_invalid";
            return false;
        }
        const auto ensure_summary_size = [&](size_t size) {
            _fiscal_last_bases.resize(size, 0);
            _fiscal_last_assessed.resize(size, 0);
            _fiscal_last_collected.resize(size, 0);
            _fiscal_last_requests.resize(size, 0);
            _fiscal_last_reserved.resize(size, 0);
            _fiscal_last_paid.resize(size, 0);
            _fiscal_last_unmet.resize(size, 0);
            _fiscal_last_events.resize(size, 0);
            _fiscal_cumulative_bases.resize(size, 0);
            _fiscal_cumulative_collected.resize(size, 0);
            _fiscal_cumulative_requests.resize(size, 0);
            _fiscal_cumulative_paid.resize(size, 0);
        };
        ensure_summary_size(summary_count);
        const auto read_group = [&](std::vector<int64_t> &values,
                                    int32_t country) {
            for (int32_t kind = 0;
                 kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
                const size_t index = static_cast<size_t>(country) *
                    NativeCountryRuntime::TAX_KIND_COUNT + kind;
                if (index >= values.size() ||
                    !read_le(bytes, cursor, values[index]) ||
                    values[index] < 0)
                    return false;
            }
            return true;
        };
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1;
            int64_t escrow = 0;
            if (!read_le(bytes, cursor, country) ||
                country != _restore.restored_fiscal ||
                country < 0 || static_cast<size_t>(country) *
                    NativeCountryRuntime::TAX_KIND_COUNT >= summary_count ||
                !read_group(_fiscal_last_bases, country) ||
                !read_group(_fiscal_last_assessed, country) ||
                !read_group(_fiscal_last_collected, country) ||
                !read_group(_fiscal_last_requests, country) ||
                !read_group(_fiscal_last_reserved, country) ||
                !read_group(_fiscal_last_paid, country) ||
                !read_group(_fiscal_last_unmet, country) ||
                !read_group(_fiscal_last_events, country) ||
                !read_group(_fiscal_cumulative_bases, country) ||
                !read_group(_fiscal_cumulative_collected, country) ||
                !read_group(_fiscal_cumulative_requests, country) ||
                !read_group(_fiscal_cumulative_paid, country) ||
                !read_le(bytes, cursor, escrow) || escrow < 0 ||
                static_cast<size_t>(country) >=
                    _fiscal_escrow_by_country.size()) {
                error = "save_fiscal_record_invalid";
                return false;
            }
            _fiscal_escrow_by_country[static_cast<size_t>(country)] = escrow;
            ++_restore.restored_fiscal;
        }
        _restore.fiscal_seen = true;
    } else if (schema >= 24 &&
               section == SAVE_SECTION_SETTLEMENT_NAMES) {
        const auto stable_index = [](
                const std::vector<std::string> &ids,
                const std::vector<std::string> &alias_ids,
                const std::vector<std::string> &alias_targets,
                const std::string &id) -> int32_t {
            const auto found = std::find(ids.begin(), ids.end(), id);
            if (found != ids.end())
                return static_cast<int32_t>(found - ids.begin());
            const auto alias = std::find(
                alias_ids.begin(), alias_ids.end(), id);
            if (alias == alias_ids.end()) return -1;
            const size_t alias_index = static_cast<size_t>(
                alias - alias_ids.begin());
            const auto target = std::find(ids.begin(), ids.end(),
                alias_targets[alias_index]);
            return target == ids.end() ? -1 :
                static_cast<int32_t>(target - ids.begin());
        };
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            uint32_t disambiguator = 0;
            std::string pack_id, prefix_id, root_id, suffix_id;
            if (!read_le(bytes, cursor, cell) ||
                !read_string(bytes, cursor, pack_id) ||
                !read_string(bytes, cursor, prefix_id) ||
                !read_string(bytes, cursor, root_id) ||
                !read_string(bytes, cursor, suffix_id) ||
                !read_le(bytes, cursor, disambiguator) ||
                cell < 0 || cell >= _cell_count ||
                _settlements.name_active[cell] != 0 ||
                (_settlements.tier[cell] < _settlement_named_tier &&
                 _settlements.name_forced[cell] == 0) ||
                pack_id != _settlement_name_pack_id) {
                error = "save_settlement_name_record_invalid";
                return false;
            }
            const bool full_name_mode = root_id.empty() &&
                suffix_id.empty();
            const int32_t prefix = stable_index(
                full_name_mode ? _settlement_full_name_ids :
                    _settlement_prefix_ids,
                full_name_mode ? _settlement_full_name_alias_ids :
                    _settlement_prefix_alias_ids,
                full_name_mode ? _settlement_full_name_alias_targets :
                    _settlement_prefix_alias_targets, prefix_id);
            const int32_t root = full_name_mode ? -1 : stable_index(
                _settlement_root_ids, _settlement_root_alias_ids,
                _settlement_root_alias_targets, root_id);
            const int32_t suffix = full_name_mode ? -1 : stable_index(
                _settlement_suffix_ids, _settlement_suffix_alias_ids,
                _settlement_suffix_alias_targets, suffix_id);
            if (prefix < 0 ||
                (!full_name_mode && (root < 0 || suffix < 0))) {
                error = "save_settlement_name_component_missing";
                return false;
            }
            _settlements.name_active[cell] = 1;
            _settlements.prefix[cell] = prefix;
            _settlements.root[cell] = root;
            _settlements.suffix[cell] = suffix;
            _settlements.disambiguator[cell] = disambiguator;
            const std::string visible = settlement_name_for_cell(cell);
            if (!_settlements.active_names.emplace(visible, cell).second) {
                error = "save_settlement_name_duplicate";
                return false;
            }
        }
        _restore.settlement_names_seen = true;
    } else if (schema >= 26 && section == SAVE_SECTION_FAMILY_RECORDS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1, surname = -1, home_cell = -1, origin_cell = -1,
                    ethnicity = -1, culture_group = -1;
            uint8_t active = 0;
            uint32_t generation = 0, disambiguator = 0, split_sequence = 0;
            int64_t stable_id = 0, founded_day = -1;
            uint16_t decline = 0, flags = 0;
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, surname) ||
                !read_le(bytes, cursor, disambiguator) ||
                !read_le(bytes, cursor, founded_day) ||
                !read_le(bytes, cursor, home_cell) ||
                (schema >= 40 && !read_le(bytes, cursor, origin_cell)) ||
                !read_le(bytes, cursor, ethnicity) ||
                (schema >= 40 && !read_le(bytes, cursor, culture_group)) ||
                (schema >= 40 && !read_le(bytes, cursor, split_sequence)) ||
                !read_le(bytes, cursor, decline) ||
                !read_le(bytes, cursor, flags) ||
                index != static_cast<int32_t>(families_store().active.size()) ||
                active > 1 || generation == 0 ||
                (active != 0 && (stable_id <= 0 || surname < 0 ||
                    surname >= static_cast<int32_t>(_family_surname_ids.size()) ||
                    home_cell < 0 || home_cell >= _cell_count ||
                    (schema >= 40 && (origin_cell < 0 || origin_cell >= _cell_count ||
                        culture_group < 0 || ethnicity < 0 ||
                        ethnicity >= static_cast<int32_t>(_ethnicity_culture_group_ids.size()) ||
                        culture_group != _ethnicity_culture_group_ids[ethnicity])) ||
                    ethnicity < 0 || ethnicity >= static_cast<int32_t>(_ethnicity_ids.size())))) {
                error = "save_family_record_invalid";
                return false;
            }
            families_store().active.push_back(active);
            families_store().generation.push_back(generation);
            families_store().stable_id.push_back(stable_id);
            families_store().surname_id.push_back(surname);
            families_store().surname_disambiguator.push_back(disambiguator);
            families_store().founded_day.push_back(founded_day);
            families_store().home_cell.push_back(home_cell);
            families_store().origin_cell.push_back(schema >= 40 ? origin_cell : home_cell);
            families_store().origin_ethnicity.push_back(ethnicity);
            families_store().culture_group_id.push_back(schema >= 40 ? culture_group :
                (ethnicity >= 0 && ethnicity < static_cast<int32_t>(
                    _ethnicity_culture_group_ids.size())
                    ? _ethnicity_culture_group_ids[ethnicity] : 0));
            families_store().split_sequence.push_back(schema >= 40 ? split_sequence : 0);
            families_store().decline_reviews.push_back(decline);
            families_store().flags.push_back(flags);
            if (active != 0) {
                ++families_store().active_count;
                _family_stable_ids.insert(stable_id);
                if (static_cast<size_t>(surname) >=
                    _family_surname_members.size())
                    _family_surname_members.resize(
                        static_cast<size_t>(surname) + 1);
                _family_surname_members[static_cast<size_t>(surname)]
                    .push_back(index);
            } else {
                families_store().free_indices.push_back(index);
            }
            ++_restore.restored_families;
        }
        _restore.family_records_seen = true;
    } else if (schema >= 26 &&
               section == SAVE_SECTION_FAMILY_MEMBERSHIP) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyMembershipEdge edge;
            int32_t family = -1, slot = -1;
            if (!read_le(bytes, cursor, edge.family_handle) ||
                !read_le(bytes, cursor, edge.cohort_handle) ||
                !read_le(bytes, cursor, edge.people) ||
                !read_le(bytes, cursor, edge.cash_claim) ||
                !read_le(bytes, cursor, edge.population_basis) ||
                !read_le(bytes, cursor, edge.funds_basis) ||
                !read_le(bytes, cursor, edge.owner_employed) ||
                !read_le(bytes, cursor, edge.employee_employed) ||
                !families_store().valid_handle(edge.family_handle, family) ||
                !population_store().valid_handle(edge.cohort_handle, slot) ||
                edge.people <= 0 || edge.cash_claim < 0) {
                error = "save_family_membership_invalid";
                return false;
            }
            // Older saves could persist overshot employment attribution or
            // stale population/funds bases after membership merges. Repair the
            // derived fields instead of rejecting an otherwise loadable world.
            sanitize_family_membership_edge(edge);
            family_memberships().push_back(edge);
            ++_restore.restored_family_memberships;
        }
        _restore.family_membership_seen = true;
    } else if (schema >= 26 &&
               section == SAVE_SECTION_FAMILY_OWNERSHIP) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyBuildingOwnership edge;
            int32_t family = -1;
            if (!read_le(bytes, cursor, edge.family_handle) ||
                !read_le(bytes, cursor, edge.building_handle) ||
                !read_le(bytes, cursor, edge.owned_count) ||
                !read_le(bytes, cursor, edge.filled_owner) ||
                !families_store().valid_handle(edge.family_handle, family) ||
                edge.building_handle == 0 || edge.owned_count <= 0 ||
                edge.filled_owner < 0) {
                error = "save_family_ownership_invalid";
                return false;
            }
            family_ownerships().push_back(edge);
            ++_restore.restored_family_ownerships;
        }
        _restore.family_ownership_seen = true;
    } else if (schema >= 27 && section == SAVE_SECTION_PERSON_RECORDS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1;
            uint8_t active = 0, job_kind = 0;
            uint32_t generation = 0, disambiguator = 0;
            int64_t stable_id = 0, notable_since_day = -1, cash_claim = 0,
                    equity_share = 0, epoch_job_income = 0,
                    epoch_business_result = 0, epoch_consumption_expense = 0,
                    epoch_tax = 0, income_ema = 0, job_since_day = -1;
            uint64_t family_handle = 0, cohort_handle = 0,
                     building_handle = 0;
            int32_t given_name = -1, employee_role = -1;
            uint16_t flags = 0, satisfaction = 0,
                     worst_need = std::numeric_limits<uint16_t>::max();
            int32_t family = -1, cohort = -1;
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, family_handle) ||
                !read_le(bytes, cursor, cohort_handle) ||
                !read_le(bytes, cursor, given_name) ||
                !read_le(bytes, cursor, disambiguator) ||
                !read_le(bytes, cursor, notable_since_day) ||
                !read_le(bytes, cursor, flags) ||
                !read_le(bytes, cursor, cash_claim) ||
                !read_le(bytes, cursor, equity_share) ||
                !read_le(bytes, cursor, epoch_job_income) ||
                !read_le(bytes, cursor, epoch_business_result) ||
                !read_le(bytes, cursor, epoch_consumption_expense) ||
                !read_le(bytes, cursor, epoch_tax) ||
                !read_le(bytes, cursor, income_ema) ||
                !read_le(bytes, cursor, satisfaction) ||
                !read_le(bytes, cursor, worst_need) ||
                !read_le(bytes, cursor, building_handle) ||
                !read_le(bytes, cursor, job_kind) ||
                !read_le(bytes, cursor, employee_role) ||
                !read_le(bytes, cursor, job_since_day) ||
                index != static_cast<int32_t>(persons_store().active.size()) ||
                active > 1 || generation == 0 || job_kind > 2 ||
                (active != 0 &&
                    (stable_id <= 0 ||
                     !families_store().valid_handle(family_handle, family) ||
                     (cohort_handle != 0 &&
                      !population_store().valid_handle(cohort_handle, cohort)) ||
                     given_name < 0 || given_name >= static_cast<int32_t>(
                        _person_given_name_ids.size()) ||
                     notable_since_day < 0 || cash_claim < 0 ||
                     equity_share < 0 || equity_share > Q32_ONE ||
                     epoch_job_income < 0 || epoch_consumption_expense < 0 ||
                     epoch_tax < 0 || income_ema < 0 ||
                     // satisfaction 是 uint16_t，见 satisfaction_dims 处的注释——
                     // 「>= Q16_ONE」对该类型恒假。
                     (job_kind == 0 &&
                        (building_handle != 0 || employee_role != -1)) ||
                     (job_kind != 0 && building_handle == 0) ||
                     (job_kind == 1 && employee_role != -1) ||
                     (job_kind == 2 && employee_role < 0)))) {
                error = "save_person_record_invalid";
                return false;
            }
            persons_store().active.push_back(active);
            persons_store().generation.push_back(generation);
            persons_store().stable_id.push_back(stable_id);
            if (active != 0) _person_stable_ids.insert(stable_id);
            persons_store().family_handle.push_back(family_handle);
            persons_store().cohort_handle.push_back(cohort_handle);
            persons_store().given_name_id.push_back(given_name);
            persons_store().name_disambiguator.push_back(disambiguator);
            persons_store().notable_since_day.push_back(notable_since_day);
            persons_store().flags.push_back(flags);
            persons_store().cash_claim.push_back(cash_claim);
            persons_store().family_equity_share_q32.push_back(equity_share);
            persons_store().epoch_job_income.push_back(epoch_job_income);
            persons_store().epoch_business_result.push_back(epoch_business_result);
            persons_store().epoch_consumption_expense.push_back(
                epoch_consumption_expense);
            persons_store().epoch_tax.push_back(epoch_tax);
            persons_store().income_ema.push_back(income_ema);
            persons_store().needs_satisfaction.push_back(satisfaction);
            persons_store().worst_need_id.push_back(worst_need);
            persons_store().building_handle.push_back(building_handle);
            persons_store().job_kind.push_back(job_kind);
            persons_store().employee_role_index.push_back(employee_role);
            persons_store().job_since_day.push_back(job_since_day);
            if (active != 0) ++persons_store().active_count;
            else persons_store().free_indices.push_back(index);
            ++_restore.restored_persons;
        }
        _restore.person_records_seen = true;
    } else if (schema >= 27 && section == SAVE_SECTION_PERSON_NEEDS) {
        for (uint32_t record = 0; record < records; ++record) {
            PersonNeedState state;
            int32_t person = -1;
            if (!read_le(bytes, cursor, state.person_handle) ||
                !read_le(bytes, cursor, state.stable_need_id) ||
                !read_le(bytes, cursor, state.desired_period_units) ||
                !read_le(bytes, cursor, state.satisfaction_q16) ||
                !read_le(bytes, cursor, state.attributed_spend) ||
                !persons_store().valid_handle(state.person_handle, person) ||
                state.stable_need_id < 0 || state.stable_need_id >=
                    static_cast<int32_t>(_needs.size()) ||
                state.desired_period_units < 0 ||
                // satisfaction_q16 是 uint16_t，见 satisfaction_dims 处的注释——
                // 「>= Q16_ONE」对该类型恒假。
                state.attributed_spend < 0) {
                error = "save_person_need_invalid";
                return false;
            }
            person_needs().push_back(state);
            _person_needs_normalized = false;
            ++_restore.restored_person_needs;
        }
        _restore.person_needs_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_TRAITS) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyTraitRoll roll;
            int32_t family = -1;
            if (!read_le(bytes, cursor, roll.family_handle) ||
                !read_le(bytes, cursor, roll.trait_id) ||
                !read_le(bytes, cursor, roll.strength_q16) ||
                !read_le(bytes, cursor, roll.core) || roll.core > 1 ||
                !families_store().valid_handle(roll.family_handle, family) ||
                roll.trait_id < 0 || roll.trait_id >= static_cast<int32_t>(
                    _family_trait_ids.size()) ||
                roll.strength_q16 < _family_trait_strength_min_q16[roll.trait_id] ||
                roll.strength_q16 > _family_trait_strength_max_q16[roll.trait_id] ||
                (roll.strength_q16 -
                    _family_trait_strength_min_q16[roll.trait_id]) %
                    _family_trait_strength_step_q16[roll.trait_id] != 0) {
                error = "save_family_trait_roll_invalid";
                return false;
            }
            family_trait_rolls().push_back(roll);
            ++_restore.restored_family_traits;
        }
        _restore.family_traits_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_INFLUENCES) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1, cell = -1;
            uint8_t active = 0, level = 0, pending = 0, streak = 0;
            uint32_t generation = 0;
            uint64_t family_handle = 0;
            int64_t stable_id = 0, population = 0, cash = 0, asset = 0,
                last_review = -1;
            int32_t population_share = 0, cash_share = 0,
                building_share = 0, score = 0, satisfaction = 0;
            int32_t family = -1;
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, family_handle) ||
                !read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, population) ||
                !read_le(bytes, cursor, cash) ||
                !read_le(bytes, cursor, asset) ||
                !read_le(bytes, cursor, population_share) ||
                !read_le(bytes, cursor, cash_share) ||
                !read_le(bytes, cursor, building_share) ||
                !read_le(bytes, cursor, score) ||
                !read_le(bytes, cursor, satisfaction) ||
                !read_le(bytes, cursor, level) ||
                !read_le(bytes, cursor, pending) ||
                !read_le(bytes, cursor, streak) ||
                !read_le(bytes, cursor, last_review) ||
                index != static_cast<int32_t>(
                    family_influences().active.size()) || active > 1 ||
                generation == 0 || (active != 0 &&
                    (!families_store().valid_handle(family_handle, family) ||
                     cell < 0 || cell >= _cell_count || stable_id <= 0 ||
                     population < 0 || cash < 0 || asset < 0 || level > 5 ||
                     pending > 5 || population_share < 0 ||
                     population_share > Q16_ONE || cash_share < 0 ||
                     cash_share > Q16_ONE || building_share < 0 ||
                     building_share > Q16_ONE || score < 0 ||
                     score > Q16_ONE || satisfaction < 0 ||
                     satisfaction >= Q16_ONE))) {
                error = "save_family_influence_invalid";
                return false;
            }
            family_influences().active.push_back(active);
            family_influences().generation.push_back(generation);
            family_influences().family_handle.push_back(family_handle);
            family_influences().cell.push_back(cell);
            family_influences().stable_id.push_back(stable_id);
            family_influences().population.push_back(population);
            family_influences().cash.push_back(cash);
            family_influences().building_asset.push_back(asset);
            family_influences().population_share_q16.push_back(population_share);
            family_influences().cash_share_q16.push_back(cash_share);
            family_influences().building_share_q16.push_back(building_share);
            family_influences().score_q16.push_back(score);
            family_influences().satisfaction_q16.push_back(satisfaction);
            family_influences().prestige_level.push_back(level);
            family_influences().pending_target_level.push_back(pending);
            family_influences().review_streak.push_back(streak);
            family_influences().last_review_day.push_back(last_review);
            if (active == 0) family_influences().free_indices.push_back(index);
            ++_restore.restored_family_influences;
        }
        _restore.family_influences_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_TRAIT_COMMANDS) {
        for (uint32_t record = 0; record < records; ++record) {
            FamilyTraitCommand command;
            int32_t family = -1;
            if (!read_le(bytes, cursor, command.operation) ||
                !read_le(bytes, cursor, command.family_handle) ||
                !read_le(bytes, cursor, command.trait_id) ||
                !read_le(bytes, cursor, command.strength_q16) ||
                !read_le(bytes, cursor, command.effective_day) ||
                !read_le(bytes, cursor, command.priority) ||
                !read_le(bytes, cursor, command.sequence) ||
                !read_le(bytes, cursor, command.submit_order) ||
                command.operation < 1 || command.operation > 3 ||
                !families_store().valid_handle(command.family_handle, family) ||
                command.trait_id < 0 || command.trait_id >= static_cast<int32_t>(
                    _family_trait_ids.size()) || command.effective_day < 0 ||
                command.submit_order == 0) {
                error = "save_family_trait_command_invalid";
                return false;
            }
            _family_trait_commands.push_back(command);
            ++_restore.restored_family_trait_commands;
        }
        _restore.family_trait_commands_seen = true;
    } else if (section == SAVE_SECTION_FAMILY_EXPEDITIONS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t index = -1, source_cell = -1, target_cell = -1;
            uint8_t active = 0, state = 0;
            uint32_t generation = 0, route_count = 0, payload_count = 0;
            int64_t stable_id = 0, departure_day = -1, due_day = -1,
                population = 0, transaction_id = 0;
            uint64_t country_handle = 0, family_handle = 0,
                idempotency_key = 0;
            int32_t route_cost = 0, speed = 0;
            if (!read_le(bytes, cursor, index) ||
                !read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, generation) ||
                !read_le(bytes, cursor, stable_id) ||
                !read_le(bytes, cursor, country_handle) ||
                !read_le(bytes, cursor, family_handle) ||
                !read_le(bytes, cursor, source_cell) ||
                !read_le(bytes, cursor, target_cell) ||
                !read_le(bytes, cursor, departure_day) ||
                !read_le(bytes, cursor, due_day) ||
                !read_le(bytes, cursor, route_cost) ||
                !read_le(bytes, cursor, speed) ||
                !read_le(bytes, cursor, state) ||
                !read_le(bytes, cursor, population) ||
                !read_le(bytes, cursor, transaction_id) ||
                !read_le(bytes, cursor, idempotency_key) ||
                !read_le(bytes, cursor, route_count) ||
                !read_le(bytes, cursor, payload_count) ||
                index != static_cast<int32_t>(
                    family_expeditions_store().active.size()) ||
                active > 1 || generation == 0 || route_count > 8193 ||
                payload_count > 100000) {
                error = "save_family_expedition_record_invalid";
                return false;
            }
            int32_t family = -1;
            if (active != 0) {
                if (stable_id <= 0 || country_handle == 0 ||
                    !_country_runtime->valid_handle(
                        static_cast<int64_t>(country_handle))) {
                    error = "save_family_expedition_country_identity_invalid";
                    return false;
                }
                if (!families_store().valid_handle(family_handle, family)) {
                    error = "save_family_expedition_family_handle_invalid";
                    return false;
                }
                if (source_cell < 0 || source_cell >= _cell_count ||
                    target_cell < 0 || target_cell >= _cell_count) {
                    error = "save_family_expedition_cell_invalid"; return false;
                }
                if (departure_day < 0 || due_day < departure_day) {
                    error = "save_family_expedition_dates_invalid"; return false;
                }
                if (route_cost < 1 || speed < 1 || route_count < 2) {
                    error = "save_family_expedition_route_invalid"; return false;
                }
                const uint8_t max_state = schema >= 42
                    ? EXPEDITION_PREPARING : EXPEDITION_RETURNING;
                if (state < EXPEDITION_OUTBOUND || state > max_state ||
                    (schema < 42 && state == EXPEDITION_PREPARING)) {
                    error = "save_family_expedition_state_invalid"; return false;
                }
                const bool preparing = state == EXPEDITION_PREPARING;
                if (population < 1 ||
                    (preparing ? payload_count != 0 : payload_count < 1)) {
                    error = "save_family_expedition_payload_header_invalid"; return false;
                }
                if (idempotency_key == 0 ||
                    (state == EXPEDITION_SETTLING && transaction_id <= 0)) {
                    error = "save_family_expedition_transaction_invalid"; return false;
                }
            }
            family_expeditions_store().active.push_back(active);
            family_expeditions_store().generation.push_back(generation);
            family_expeditions_store().stable_id.push_back(stable_id);
            family_expeditions_store().country_handle.push_back(country_handle);
            family_expeditions_store().family_handle.push_back(family_handle);
            family_expeditions_store().source_cell.push_back(source_cell);
            family_expeditions_store().target_cell.push_back(target_cell);
            family_expeditions_store().departure_day.push_back(departure_day);
            family_expeditions_store().due_day.push_back(due_day);
            family_expeditions_store().route_cost.push_back(route_cost);
            family_expeditions_store().speed.push_back(speed);
            family_expeditions_store().state.push_back(state);
            family_expeditions_store().population.push_back(population);
            family_expeditions_store().effect_transaction_id.push_back(transaction_id);
            family_expeditions_store().idempotency_key.push_back(idempotency_key);
            family_expeditions_store().route_begin.push_back(static_cast<uint32_t>(
                family_expedition_route_cells().size()));
            family_expeditions_store().route_count.push_back(route_count);
            int32_t last_cost = -1;
            for (uint32_t route = 0; route < route_count; ++route) {
                int32_t cell = -1, cumulative = -1;
                if (!read_le(bytes, cursor, cell) ||
                    !read_le(bytes, cursor, cumulative) || active == 0 ||
                    cell < 0 || cell >= _cell_count || cumulative < last_cost ||
                    (route == 0 && (cell != source_cell || cumulative != 0)) ||
                    (route + 1 == route_count &&
                     (cell != target_cell || cumulative != route_cost))) {
                    error = "save_family_expedition_route_invalid";
                    return false;
                }
                family_expedition_route_cells().push_back(cell);
                family_expedition_route_costs().push_back(cumulative);
                last_cost = cumulative;
            }
            family_expeditions_store().payload_begin.push_back(static_cast<uint32_t>(
                family_expedition_payloads().size()));
            family_expeditions_store().payload_count.push_back(payload_count);
            int64_t payload_population = 0;
            for (uint32_t payload_index = 0; payload_index < payload_count;
                 ++payload_index) {
                FamilyExpeditionPayload lane;
                if (!read_le(bytes, cursor, lane.source_cohort_handle) ||
                    !read_le(bytes, cursor, lane.signature) ||
                    !read_le(bytes, cursor, lane.people) ||
                    !read_le(bytes, cursor, lane.funds) ||
                    !read_le(bytes, cursor, lane.epoch_income) ||
                    !read_le(bytes, cursor, lane.epoch_expense) ||
                    !read_le(bytes, cursor, lane.epoch_in_kind_income) ||
                    !read_le(bytes, cursor, lane.income_ema) ||
                    !read_le(bytes, cursor, lane.epoch_tax_paid) ||
                    !read_le(bytes, cursor, lane.epoch_subsidy_received) ||
                    !read_le(bytes, cursor, lane.income_baseline_ema) ||
                    !read_le(bytes, cursor, lane.demography_residual) ||
                    !read_le(bytes, cursor, lane.cash_claim) ||
                    !read_le(bytes, cursor, lane.owner_employed) ||
                    !read_le(bytes, cursor, lane.employee_employed) ||
                    !read_le(bytes, cursor, lane.needs_satisfaction) ||
                    !read_le(bytes, cursor, lane.worst_need_id) ||
                    !read_le(bytes, cursor, lane.composite_satisfaction) ||
                    !read_le(bytes, cursor, lane.worst_dimension_id)) {
                    error = "save_family_expedition_payload_truncated";
                    return false;
                }
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                    if (!read_le(bytes, cursor, lane.satisfaction_dims[dim])) {
                        error = "save_family_expedition_payload_truncated";
                        return false;
                    }
                if (!read_le(bytes, cursor, lane.person_count) || active == 0 ||
                    lane.signature < 0 || lane.signature >= static_cast<int32_t>(
                        _signatures.size()) || lane.people <= 0 || lane.funds < 0 ||
                    lane.cash_claim < 0 || lane.owner_employed < 0 ||
                    lane.employee_employed < 0 || lane.person_count > 100000) {
                    error = "save_family_expedition_payload_invalid";
                    return false;
                }
                lane.person_begin = static_cast<uint32_t>(
                    family_expedition_person_handles().size());
                for (uint32_t person = 0; person < lane.person_count; ++person) {
                    uint64_t person_handle = 0;
                    int32_t person_slot = -1;
                    if (!read_le(bytes, cursor, person_handle) ||
                        !persons_store().valid_handle(person_handle, person_slot) ||
                        persons_store().cohort_handle[person_slot] != 0 ||
                        persons_store().family_handle[person_slot] != family_handle) {
                        error = "save_family_expedition_person_invalid";
                        return false;
                    }
                    family_expedition_person_handles().push_back(person_handle);
                }
                payload_population += lane.people;
                family_expedition_payloads().push_back(lane);
            }
            if (active != 0 && state != EXPEDITION_PREPARING &&
                payload_population != population) {
                error = "save_family_expedition_population_mismatch";
                return false;
            }
            uint32_t cargo_count = 0;
            uint32_t kit_count = 0;
            family_expeditions_store().cargo_begin.push_back(static_cast<uint32_t>(
                family_expedition_cargo().size()));
            family_expeditions_store().kit_building_begin.push_back(
                static_cast<uint32_t>(family_expedition_kit_buildings().size()));
            if (schema >= 37) {
                if (!read_le(bytes, cursor, cargo_count) ||
                    cargo_count > 100000) {
                    error = "save_family_expedition_cargo_invalid";
                    return false;
                }
                for (uint32_t c = 0; c < cargo_count; ++c) {
                    FamilyExpeditionCargoLine line;
                    if (!read_le(bytes, cursor, line.good_id) ||
                        !read_le(bytes, cursor, line.quantity) ||
                        !read_le(bytes, cursor, line.flags) ||
                        line.good_id < 0 || line.good_id >= market_store().good_count ||
                        line.quantity <= 0 ||
                        (line.flags != EXPEDITION_CARGO_CONSTRUCTION &&
                         line.flags != EXPEDITION_CARGO_BUFFER) ||
                        active == 0) {
                        error = "save_family_expedition_cargo_invalid";
                        return false;
                    }
                    family_expedition_cargo().push_back(line);
                }
                if (!read_le(bytes, cursor, kit_count) || kit_count > 100000) {
                    error = "save_family_expedition_kit_invalid";
                    return false;
                }
                for (uint32_t k = 0; k < kit_count; ++k) {
                    FamilyExpeditionKitBuilding row;
                    if (!read_le(bytes, cursor, row.type_id) ||
                        !read_le(bytes, cursor, row.count) ||
                        row.type_id < 0 ||
                        row.type_id >= static_cast<int32_t>(
                            _building_types.size()) ||
                        row.count <= 0 || active == 0) {
                        error = "save_family_expedition_kit_invalid";
                        return false;
                    }
                    family_expedition_kit_buildings().push_back(row);
                }
            }
            family_expeditions_store().cargo_count.push_back(cargo_count);
            family_expeditions_store().kit_building_count.push_back(kit_count);
            uint64_t missing_identity = 0;
            uint32_t missing_count = 0;
            family_expeditions_store().missing_good_begin.push_back(
                static_cast<uint32_t>(family_expedition_missing_good_ids().size()));
            if (schema >= 42) {
                if (!read_le(bytes, cursor, missing_identity) ||
                    !read_le(bytes, cursor, missing_count) ||
                    missing_count > 100000) {
                    error = "save_family_expedition_missing_invalid";
                    return false;
                }
                for (uint32_t m = 0; m < missing_count; ++m) {
                    int32_t good_id = -1;
                    int64_t quantity = 0;
                    if (!read_le(bytes, cursor, good_id) ||
                        !read_le(bytes, cursor, quantity) ||
                        good_id < 0 || quantity < 0 || active == 0) {
                        error = "save_family_expedition_missing_invalid";
                        return false;
                    }
                    family_expedition_missing_good_ids().push_back(good_id);
                    family_expedition_missing_good_quantities().push_back(quantity);
                }
            }
            // A preparing party holds no people and has not committed to a
            // building plan yet, but it may already escrow the goods it has
            // stocked from the source market day by day.
            if (active != 0 && state == EXPEDITION_PREPARING &&
                (payload_count != 0 || kit_count != 0)) {
                error = "save_family_expedition_preparing_payload_invalid";
                return false;
            }
            family_expeditions_store().kit_missing_stock_identity.push_back(
                missing_identity);
            family_expeditions_store().missing_good_count.push_back(missing_count);
            if (active != 0) {
                ++family_expeditions_store().active_count;
                ++_restore.restored_family_expeditions;
            } else {
                family_expeditions_store().free_indices.push_back(index);
            }
            ++_restore.restored_family_expedition_slots;
        }
        _restore.family_expeditions_seen = true;
    } else if (schema >= 33 && section == SAVE_SECTION_TARIFF_HISTORY) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1, kind = -1;
            int64_t base = 0, assessed = 0, collected = 0, requests = 0,
                reserved = 0, paid = 0, cumulative_base = 0,
                cumulative_collected = 0, cumulative_requests = 0,
                cumulative_paid = 0;
            if (!read_le(bytes, cursor, country) || !read_le(bytes, cursor, kind) ||
                !read_le(bytes, cursor, base) || !read_le(bytes, cursor, assessed) ||
                !read_le(bytes, cursor, collected) || !read_le(bytes, cursor, requests) ||
                !read_le(bytes, cursor, reserved) || !read_le(bytes, cursor, paid) ||
                !read_le(bytes, cursor, cumulative_base) ||
                !read_le(bytes, cursor, cumulative_collected) ||
                !read_le(bytes, cursor, cumulative_requests) ||
                !read_le(bytes, cursor, cumulative_paid) || country < 0 ||
                kind < NativeCountryRuntime::TAX_IMPORT ||
                kind > NativeCountryRuntime::TAX_EXPORT || base < 0 || assessed < 0 ||
                collected < 0 || requests < 0 || reserved < 0 || paid < 0 ||
                cumulative_base < 0 || cumulative_collected < 0 ||
                cumulative_requests < 0 || cumulative_paid < 0) {
                error = "save_tariff_history_record_invalid";
                return false;
            }
            _tariff_history.countries.push_back(country);
            _tariff_history.kinds.push_back(kind);
            _tariff_history.bases.push_back(base);
            _tariff_history.assessed.push_back(assessed);
            _tariff_history.collected.push_back(collected);
            _tariff_history.requests.push_back(requests);
            _tariff_history.reserved.push_back(reserved);
            _tariff_history.paid.push_back(paid);
            _tariff_history.cumulative_bases.push_back(cumulative_base);
            _tariff_history.cumulative_collected.push_back(cumulative_collected);
            _tariff_history.cumulative_requests.push_back(cumulative_requests);
            _tariff_history.cumulative_paid.push_back(cumulative_paid);
            ++_restore.restored_tariff_history;
        }
        _restore.tariff_history_seen = true;
    } else if (schema >= 33 && section == SAVE_SECTION_COUNTRY_GOOD) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1, good = -1;
            int64_t import_quantity = 0, export_quantity = 0,
                import_base = 0, export_base = 0,
                import_tariff = 0, export_tariff = 0,
                batch_epoch = -1, batch_import_quantity = 0,
                batch_export_quantity = 0, batch_import_base = 0,
                batch_export_base = 0, batch_import_tariff = 0,
                batch_export_tariff = 0;
            if (!read_le(bytes, cursor, country) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, import_quantity) ||
                !read_le(bytes, cursor, export_quantity) ||
                !read_le(bytes, cursor, import_base) ||
                !read_le(bytes, cursor, export_base) ||
                !read_le(bytes, cursor, import_tariff) ||
                !read_le(bytes, cursor, export_tariff) ||
                !read_le(bytes, cursor, batch_epoch) ||
                !read_le(bytes, cursor, batch_import_quantity) ||
                !read_le(bytes, cursor, batch_export_quantity) ||
                !read_le(bytes, cursor, batch_import_base) ||
                !read_le(bytes, cursor, batch_export_base) ||
                !read_le(bytes, cursor, batch_import_tariff) ||
                !read_le(bytes, cursor, batch_export_tariff) ||
                country < 0 || good < 0 ||
                good >= market_store().good_count || import_quantity < 0 ||
                export_quantity < 0 || import_base < 0 || export_base < 0 ||
                batch_epoch < -1 || batch_epoch > _epoch_id ||
                batch_import_quantity < 0 || batch_export_quantity < 0 ||
                batch_import_base < 0 || batch_export_base < 0) {
                error = "save_country_good_record_invalid";
                return false;
            }
            _country_good_trade.countries.push_back(country);
            _country_good_trade.goods.push_back(good);
            _country_good_trade.import_quantity.push_back(import_quantity);
            _country_good_trade.export_quantity.push_back(export_quantity);
            _country_good_trade.import_base.push_back(import_base);
            _country_good_trade.export_base.push_back(export_base);
            _country_good_trade.import_tariff.push_back(import_tariff);
            _country_good_trade.export_tariff.push_back(export_tariff);
            _country_good_trade.batch_epoch.push_back(batch_epoch);
            _country_good_trade.batch_import_quantity.push_back(
                batch_import_quantity);
            _country_good_trade.batch_export_quantity.push_back(
                batch_export_quantity);
            _country_good_trade.batch_import_base.push_back(batch_import_base);
            _country_good_trade.batch_export_base.push_back(batch_export_base);
            _country_good_trade.batch_import_tariff.push_back(batch_import_tariff);
            _country_good_trade.batch_export_tariff.push_back(batch_export_tariff);
            ++_restore.restored_country_good;
        }
        _restore.country_good_seen = true;
    } else if (schema >= 33 && section == SAVE_SECTION_COUNTRY_PARTNER) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1, partner = -1;
            int64_t import_quantity = 0, export_quantity = 0,
                import_base = 0, export_base = 0, order_count = 0,
                batch_epoch = -1, batch_import_quantity = 0,
                batch_export_quantity = 0, batch_import_base = 0,
                batch_export_base = 0, batch_order_count = 0;
            if (!read_le(bytes, cursor, country) || !read_le(bytes, cursor, partner) ||
                !read_le(bytes, cursor, import_quantity) ||
                !read_le(bytes, cursor, export_quantity) ||
                !read_le(bytes, cursor, import_base) ||
                !read_le(bytes, cursor, export_base) ||
                !read_le(bytes, cursor, order_count) ||
                !read_le(bytes, cursor, batch_epoch) ||
                !read_le(bytes, cursor, batch_import_quantity) ||
                !read_le(bytes, cursor, batch_export_quantity) ||
                !read_le(bytes, cursor, batch_import_base) ||
                !read_le(bytes, cursor, batch_export_base) ||
                !read_le(bytes, cursor, batch_order_count) ||
                country < 0 || partner < 0 || country == partner ||
                import_quantity < 0 || export_quantity < 0 || import_base < 0 ||
                export_base < 0 || order_count < 0 ||
                batch_epoch < -1 || batch_epoch > _epoch_id ||
                batch_import_quantity < 0 || batch_export_quantity < 0 ||
                batch_import_base < 0 || batch_export_base < 0 ||
                batch_order_count < 0) {
                error = "save_country_partner_record_invalid";
                return false;
            }
            _country_partner_trade.countries.push_back(country);
            _country_partner_trade.partners.push_back(partner);
            _country_partner_trade.import_quantity.push_back(import_quantity);
            _country_partner_trade.export_quantity.push_back(export_quantity);
            _country_partner_trade.import_base.push_back(import_base);
            _country_partner_trade.export_base.push_back(export_base);
            _country_partner_trade.order_count.push_back(order_count);
            _country_partner_trade.batch_epoch.push_back(batch_epoch);
            _country_partner_trade.batch_import_quantity.push_back(
                batch_import_quantity);
            _country_partner_trade.batch_export_quantity.push_back(
                batch_export_quantity);
            _country_partner_trade.batch_import_base.push_back(batch_import_base);
            _country_partner_trade.batch_export_base.push_back(batch_export_base);
            _country_partner_trade.batch_order_count.push_back(batch_order_count);
            ++_restore.restored_country_partner;
        }
        _restore.country_partner_seen = true;
    } else if (schema >= 34 && section == SAVE_SECTION_CANAL_QUOTES) {
        for (uint32_t record = 0; record < records; ++record) {
            CanalQuote quote;
            uint8_t active = 0;
            uint32_t cell_count = 0, edge_count = 0;
            if (!read_le(bytes, cursor, quote.token) ||
                !read_le(bytes, cursor, quote.country_handle) ||
                !read_le(bytes, cursor, quote.snapshot_day) ||
                !read_le(bytes, cursor, quote.topology_hash) ||
                !read_le(bytes, cursor, quote.country_generation) ||
                !read_le(bytes, cursor, quote.price_hash) ||
                !read_le(bytes, cursor, quote.source_kind) ||
                !read_le(bytes, cursor, quote.new_edge_count) ||
                !read_le(bytes, cursor, quote.reused_edge_count) ||
                !read_le(bytes, cursor, quote.construction_days) ||
                !read_le(bytes, cursor, quote.cash_required)) {
                error = "save_canal_quote_truncated";
                return false;
            }
            for (int32_t &value : quote.material_good_ids)
                if (!read_le(bytes, cursor, value)) {
                    error = "save_canal_quote_truncated"; return false;
                }
            for (int64_t &value : quote.material_quantities)
                if (!read_le(bytes, cursor, value)) {
                    error = "save_canal_quote_truncated"; return false;
                }
            if (!read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, cell_count) ||
                !read_le(bytes, cursor, edge_count) || active > 1 ||
                quote.token == 0 || quote.country_handle == 0 ||
                quote.snapshot_day < -1 ||
                quote.source_kind < CANAL_SOURCE_SALINE ||
                quote.source_kind > CANAL_SOURCE_FRESHWATER ||
                quote.new_edge_count < 0 || quote.reused_edge_count < 0 ||
                quote.construction_days < 0 || quote.cash_required < 0 ||
                cell_count < 2 || cell_count > 33 || edge_count + 1 != cell_count) {
                error = "save_canal_quote_invalid";
                return false;
            }
            quote.route_cells.resize(cell_count);
            quote.route_edge_dirs.resize(edge_count);
            std::unordered_set<int32_t> unique_cells;
            for (int32_t &cell : quote.route_cells) {
                if (!read_le(bytes, cursor, cell) || cell < 0 || cell >= _cell_count ||
                    !unique_cells.emplace(cell).second) {
                    error = "save_canal_quote_route_invalid"; return false;
                }
            }
            for (int32_t &dir : quote.route_edge_dirs) {
                if (!read_le(bytes, cursor, dir) || dir < 0 || dir >= 6) {
                    error = "save_canal_quote_route_invalid"; return false;
                }
            }
            if (active != 0 && _canal_quote_index.find(quote.token) !=
                    _canal_quote_index.end()) {
                error = "save_canal_quote_duplicate";
                return false;
            }
            const int32_t index = static_cast<int32_t>(_canal_quotes.size());
            _canal_quotes.push_back(std::move(quote));
            if (active != 0) _canal_quote_index[_canal_quotes.back().token] = index;
            ++_restore.restored_canal_quotes;
        }
        _restore.canal_quotes_seen = true;
    } else if (schema >= 34 && section == SAVE_SECTION_CANAL_PROJECTS) {
        for (uint32_t record = 0; record < records; ++record) {
            CanalProject project;
            uint32_t cell_count = 0, edge_count = 0;
            if (!read_le(bytes, cursor, project.handle) ||
                !read_le(bytes, cursor, project.generation) ||
                !read_le(bytes, cursor, project.country_handle) ||
                !read_le(bytes, cursor, project.effective_day) ||
                !read_le(bytes, cursor, project.sequence) ||
                !read_le(bytes, cursor, project.ready_day) ||
                !read_le(bytes, cursor, project.effect_transaction_id) ||
                !read_le(bytes, cursor, project.topology_hash) ||
                !read_le(bytes, cursor, project.cash_paid) ||
                !read_le(bytes, cursor, project.treasury_goods_used) ||
                !read_le(bytes, cursor, project.market_goods_used) ||
                !read_le(bytes, cursor, project.source_kind) ||
                !read_le(bytes, cursor, project.state) ||
                !read_le(bytes, cursor, cell_count) ||
                !read_le(bytes, cursor, edge_count) ||
                project.handle == 0 || project.generation == 0 ||
                project.country_handle == 0 || project.effective_day < 0 ||
                project.sequence < 0 || project.ready_day < project.effective_day ||
                project.effect_transaction_id < 0 || project.cash_paid < 0 ||
                project.treasury_goods_used < 0 || project.market_goods_used < 0 ||
                project.source_kind < CANAL_SOURCE_SALINE ||
                project.source_kind > CANAL_SOURCE_FRESHWATER ||
                project.state < CANAL_PROJECT_BUILDING ||
                project.state > CANAL_PROJECT_FAILED || cell_count > 33 ||
                edge_count > 32 ||
                ((project.state == CANAL_PROJECT_BUILDING ||
                  project.state == CANAL_PROJECT_AWAITING_EFFECT) &&
                 (cell_count < 2 || edge_count + 1 != cell_count)) ||
                ((project.state == CANAL_PROJECT_COMPLETED ||
                  project.state == CANAL_PROJECT_FAILED) &&
                 !((cell_count == 0 && edge_count == 0) ||
                   (cell_count >= 2 && edge_count + 1 == cell_count)))) {
                error = "save_canal_project_invalid";
                return false;
            }
            project.route_cells.resize(cell_count);
            project.route_edge_dirs.resize(edge_count);
            std::unordered_set<int32_t> unique_cells;
            for (int32_t &cell : project.route_cells) {
                if (!read_le(bytes, cursor, cell) || cell < 0 || cell >= _cell_count ||
                    !unique_cells.emplace(cell).second) {
                    error = "save_canal_project_route_invalid"; return false;
                }
            }
            for (int32_t &dir : project.route_edge_dirs) {
                if (!read_le(bytes, cursor, dir) || dir < 0 || dir >= 6) {
                    error = "save_canal_project_route_invalid"; return false;
                }
            }
            if (!_canal_project_index.emplace(project.handle,
                    static_cast<int32_t>(_canal_projects.size())).second) {
                error = "save_canal_project_duplicate";
                return false;
            }
            _canal_projects.push_back(std::move(project));
            ++_restore.restored_canal_projects;
        }
        _restore.canal_projects_seen = true;
    } else if (section == SAVE_SECTION_PRICE_CEILINGS) {
        if (_restore.restored_ceilings + records > _restore.expected_ceilings) {
            error = "save_price_ceiling_count_invalid"; return false;
        }
        for (uint32_t i = 0; i < records; ++i) {
            int32_t market = -1;
            PriceCeilingState state;
            if (!read_le(bytes, cursor, market) || !read_le(bytes, cursor, state.good) ||
                !read_le(bytes, cursor, state.limit) || !read_le(bytes, cursor, state.confirmation_days) ||
                market < 0 || market >= market_store().market_count || state.good < 0 ||
                state.good >= market_store().good_count || state.limit < 1 ||
                state.confirmation_days > _price_ceiling_confirm_days) {
                error = "save_price_ceiling_record_invalid"; return false;
            }
            const int64_t key = int64_t(market) * market_store().good_count + state.good;
            if (key <= _restore.last_ceiling_key) {
                error = "save_price_ceiling_order_invalid"; return false;
            }
            _restore.last_ceiling_key = key;
            market_store().price_ceilings[market].push_back(state);
            ++_restore.restored_ceilings;
        }
        _restore.ceilings_seen = true;
    } else if (schema >= 52 && section == SAVE_SECTION_FISCAL_PEER) {
        if (_restore.expected_fiscal_peer < 0 ||
            _restore.restored_fiscal_peer + static_cast<int64_t>(records) >
                _restore.expected_fiscal_peer) {
            error = "save_fiscal_peer_record_count_invalid";
            return false;
        }
        for (uint32_t i = 0; i < records; ++i) {
            NativeEconomyRuntime::FiscalPeerJournalRecord record;
            uint16_t operation = 0;
            uint8_t result_code = 0, state = 0, reserved0 = 0;
            uint16_t reserved1 = 0;
            if (!read_le(bytes, cursor, record.request_id) ||
                !read_le(bytes, cursor, record.transaction_id) ||
                !read_le(bytes, cursor, record.country_handle) ||
                !read_le(bytes, cursor, record.country_generation) ||
                !read_le(bytes, cursor, record.peer_generation) ||
                !read_le(bytes, cursor, record.committed_peer_generation) ||
                !read_le(bytes, cursor, record.day) ||
                !read_le(bytes, cursor, record.operation_sequence) ||
                !read_le(bytes, cursor, record.continuation_index) ||
                !read_le(bytes, cursor, record.country_slot) ||
                !read_le(bytes, cursor, operation) ||
                !read_le(bytes, cursor, result_code) ||
                !read_le(bytes, cursor, state) ||
                !read_le(bytes, cursor, record.accepted) ||
                !read_le(bytes, cursor, reserved0) ||
                !read_le(bytes, cursor, reserved1) ||
                !read_le(bytes, cursor, record.requested_quantity) ||
                !read_le(bytes, cursor, record.requested_cash) ||
                !read_le(bytes, cursor, record.committed_quantity) ||
                !read_le(bytes, cursor, record.committed_cash)) {
                error = "save_fiscal_peer_record_truncated";
                return false;
            }
            for (char &value : record.reason) {
                uint8_t byte = 0;
                if (!read_le(bytes, cursor, byte)) {
                    error = "save_fiscal_peer_record_truncated";
                    return false;
                }
                value = static_cast<char>(byte);
            }
            record.operation = static_cast<RuntimeEconomyAssetOperation>(operation);
            record.result_code = static_cast<RuntimeEconomyAssetResultCode>(result_code);
            record.state = static_cast<RuntimeEconomyAssetState>(state);
            record.effective_day = record.day;
            record.sequence = record.operation_sequence;
            record.reservation_state = runtime_d7_reservation_state_from_asset(
                record.state, record.result_code, record.reason.data());
            record.terminal_result = runtime_d7_terminal_result_from_asset(
                record.result_code, record.state, record.reason.data());
            record.retry_identity = record.request_id ^
                (static_cast<uint64_t>(record.continuation_index) << 1);
            if (record.result_code == RuntimeEconomyAssetResultCode::REJECTED &&
                runtime_d7_reason_is_stale_reject(record.reason.data())) {
                record.late_ack_rejection_reason = record.reason;
            }
            if (record.request_id == 0 || record.transaction_id == 0 ||
                record.country_handle == 0 ||
                record.country_slot < -1 ||
                record.country_slot >= _epoch_country_count ||
                record.committed_peer_generation < record.peer_generation ||
                record.day < -1 ||
                record.operation < RuntimeEconomyAssetOperation::RESEARCH_PURCHASE ||
                record.operation > RuntimeEconomyAssetOperation::TREASURY_SPEND ||
                record.result_code != RuntimeEconomyAssetResultCode::COMPLETED &&
                    record.result_code != RuntimeEconomyAssetResultCode::REJECTED ||
                record.state != RuntimeEconomyAssetState::COMPLETED &&
                    record.state != RuntimeEconomyAssetState::REJECTED ||
                record.accepted > 1 || record.requested_quantity < 0 ||
                record.requested_cash < 0 || record.committed_quantity < 0 ||
                record.committed_cash < 0 || record.committed_quantity > record.requested_quantity ||
                record.committed_cash > record.requested_cash || reserved0 != 0 || reserved1 != 0) {
                error = "save_fiscal_peer_record_invalid";
                return false;
            }
            if (record.result_code == RuntimeEconomyAssetResultCode::COMPLETED &&
                (record.accepted == 0 || record.country_slot < 0 ||
                 record.country_generation == 0 || record.peer_generation == 0 ||
                 record.committed_quantity <= 0 || record.committed_cash <= 0)) {
                error = "save_fiscal_peer_completed_record_invalid";
                return false;
            }
            if (!_asset_peer_journal.emplace(record.request_id, record).second) {
                error = "save_fiscal_peer_duplicate";
                return false;
            }
            ++_restore.restored_fiscal_peer;
        }
        _restore.fiscal_peer_seen = true;
    } else if (schema >= 52 && section == SAVE_SECTION_RESOURCE_STOCK) {
        if (!_restore.resource_stock_seen) {
            resource_stock_lanes().assign(static_cast<size_t>(
                std::max<int64_t>(0, _restore.expected_resource_rows)), 0);
            resource_lane_generation_lanes().assign(static_cast<size_t>(
                std::max<int64_t>(0, _restore.expected_resource_rows)), 0);
            _restore.resource_stock_seen = true;
        }
        for (uint32_t i = 0; i < records; ++i) {
            int32_t resource = -1;
            int32_t cell = -1;
            int64_t stock = 0;
            uint32_t generation = 0;
            if (!read_le(bytes, cursor, resource) || !read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, stock) || !read_le(bytes, cursor, generation) ||
                resource < 0 || resource >= static_cast<int32_t>(_resource_ids.size()) ||
                cell < 0 || cell >= _cell_count || stock < 0) {
                error = "save_resource_stock_record_invalid";
                return false;
            }
            const int64_t key = static_cast<int64_t>(resource) * _cell_count + cell;
            if (key <= _restore.last_resource_key ||
                key >= static_cast<int64_t>(resource_stock_lanes().size())) {
                error = "save_resource_stock_order_invalid";
                return false;
            }
            _restore.last_resource_key = key;
            resource_stock_lanes()[static_cast<size_t>(key)] = stock;
            resource_lane_generation_lanes()[static_cast<size_t>(key)] = generation;
            ++_restore.restored_resource_rows;
        }
    } else if (schema >= 52 && section == SAVE_SECTION_CADENCE_STATE) {
        if (!_restore.cadence_state_seen) {
            _cell_tier.assign(static_cast<size_t>(_cell_count), 1);
            _cell_next_review_day.assign(static_cast<size_t>(_cell_count), 0);
            _cell_force_wake.assign(static_cast<size_t>(_cell_count), 0);
            _cell_tier_seen_gen.assign(static_cast<size_t>(_cell_count), 0);
            _cell_tier_seen_population.assign(static_cast<size_t>(_cell_count), -1);
            _cell_tier_change_day.assign(static_cast<size_t>(_cell_count),
                                         _last_committed_day);
            _cell_shortage_since_day.assign(static_cast<size_t>(_cell_count), -1);
            _restore.cadence_state_seen = true;
        }
        for (uint32_t i = 0; i < records; ++i) {
            int32_t cell = -1;
            uint8_t tier = 0, force_wake = 0;
            int64_t next_review = 0, seen_population = 0,
                    change_day = 0, shortage_since = 0;
            int32_t effect_shortage = 0, essentials_shortage = 0;
            uint32_t seen_gen = 0;
            if (!read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, tier) ||
                !read_le(bytes, cursor, next_review) ||
                !read_le(bytes, cursor, force_wake) ||
                !read_le(bytes, cursor, seen_gen) ||
                !read_le(bytes, cursor, seen_population) ||
                !read_le(bytes, cursor, change_day) ||
                !read_le(bytes, cursor, shortage_since) ||
                !read_le(bytes, cursor, effect_shortage) ||
                !read_le(bytes, cursor, essentials_shortage) ||
                cell < 0 || cell >= _cell_count || tier > 3 || force_wake > 1 ||
                effect_shortage < 0 || essentials_shortage < 0 ||
                cell != _restore.restored_cadence_cells) {
                error = "save_cadence_state_record_invalid";
                return false;
            }
            const size_t index = static_cast<size_t>(cell);
            _cell_tier[index] = tier;
            _cell_next_review_day[index] = next_review;
            _cell_force_wake[index] = force_wake;
            _cell_tier_seen_gen[index] = seen_gen;
            _cell_tier_seen_population[index] = seen_population;
            _cell_tier_change_day[index] = change_day;
            _cell_shortage_since_day[index] = shortage_since;
            _cell_effect_shortage_q16[index] = effect_shortage;
            _cell_essentials_shortage_q16[index] = essentials_shortage;
            ++_restore.restored_cadence_cells;
        }
        if (cursor < bytes.size()) {
            uint64_t generation = 0;
            if (bytes.size() - cursor != sizeof(uint64_t) ||
                !read_le(bytes, cursor, generation) || generation == 0 ||
                _restore.committed_generation_seen) {
                error = "save_cadence_generation_footer_invalid";
                return false;
            }
            _restore.committed_generation_seen = true;
            _restore.restored_committed_generation = generation;
        }
    } else if (schema >= 53 && section == SAVE_SECTION_D7_PEER_EXT) {
        if (_restore.expected_d7_peer_ext < 0 ||
            _restore.restored_d7_peer_ext + static_cast<int64_t>(records) >
                _restore.expected_d7_peer_ext) {
            error = "save_d7_peer_ext_record_count_invalid";
            return false;
        }
        for (uint32_t i = 0; i < records; ++i) {
            uint64_t request_id = 0;
            uint64_t transaction_id = 0;
            uint64_t session_epoch = 0;
            uint32_t source_domain = 0;
            uint32_t target_domain = 0;
            int64_t effective_day = -1;
            uint64_t sequence = 0;
            uint8_t reservation_state = 0;
            uint8_t terminal_result = 0;
            uint16_t reserved = 0;
            uint64_t retry_identity = 0;
            uint64_t state_hash_before = 0;
            uint64_t state_hash_after = 0;
            std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> late_reason{};
            if (!read_le(bytes, cursor, request_id) ||
                !read_le(bytes, cursor, transaction_id) ||
                !read_le(bytes, cursor, session_epoch) ||
                !read_le(bytes, cursor, source_domain) ||
                !read_le(bytes, cursor, target_domain) ||
                !read_le(bytes, cursor, effective_day) ||
                !read_le(bytes, cursor, sequence) ||
                !read_le(bytes, cursor, reservation_state) ||
                !read_le(bytes, cursor, terminal_result) ||
                !read_le(bytes, cursor, reserved) ||
                !read_le(bytes, cursor, retry_identity) ||
                reserved != 0) {
                error = "save_d7_peer_ext_record_truncated";
                return false;
            }
            for (char &value : late_reason) {
                uint8_t byte = 0;
                if (!read_le(bytes, cursor, byte)) {
                    error = "save_d7_peer_ext_record_truncated";
                    return false;
                }
                value = static_cast<char>(byte);
            }
            if (!read_le(bytes, cursor, state_hash_before) ||
                !read_le(bytes, cursor, state_hash_after) ||
                request_id == 0 || transaction_id == 0) {
                error = "save_d7_peer_ext_record_invalid";
                return false;
            }
            const auto journal = _asset_peer_journal.find(request_id);
            if (journal == _asset_peer_journal.end()) {
                error = "save_d7_peer_ext_missing_base";
                return false;
            }
            if (journal->second.transaction_id != transaction_id) {
                error = "save_d7_peer_ext_transaction_mismatch";
                return false;
            }
            journal->second.session_epoch = session_epoch;
            journal->second.source_domain = source_domain;
            journal->second.target_domain = target_domain;
            journal->second.effective_day = effective_day;
            journal->second.sequence = sequence;
            journal->second.reservation_state =
                static_cast<RuntimeD7ReservationState>(reservation_state);
            journal->second.terminal_result =
                static_cast<RuntimeD7TerminalResult>(terminal_result);
            journal->second.retry_identity = retry_identity;
            journal->second.late_ack_rejection_reason = late_reason;
            journal->second.state_hash_before = state_hash_before;
            journal->second.state_hash_after = state_hash_after;
            ++_restore.restored_d7_peer_ext;
        }
        _restore.d7_peer_ext_seen = true;
    } else if (section == SAVE_SECTION_END ||
               (schema == 33 && section == SAVE_SECTION_END_V33)) {
        if (records != 0 || payload_bytes != 0) {
            error = "save_end_chunk_invalid";
            return false;
        }
        if (!_restore.ceilings_seen || _restore.restored_ceilings != _restore.expected_ceilings) {
            error = "save_price_ceiling_section_missing"; return false;
        }
        _restore.end_seen = true;
    } else {
        error = "save_section_unknown";
        return false;
    }
    if (cursor != bytes.size()) {
        error = "save_chunk_record_count_mismatch";
        return false;
    }
    return true;
}



} // namespace pk
