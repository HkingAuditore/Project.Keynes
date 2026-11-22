// Included inside NativeEconomyRuntime. Track worker changes and merge them in task order.
    EconomyWorkerChanges *market_mutation_sink() const {
        if (_production_result_sink) return &_production_result_sink->market_changes;
        if (_market_result_sink) return &_market_result_sink->market_changes;
        return nullptr;
    }
    ChangeRegistry &worker_change_registry(EconomyFieldId field) {
        switch (field.domain) {
            case 1: return population_store().changes;
            case 2: return market_store().changes;
            case 3:
                return _formula_owned && field.column == 1
                    ? _formula_owned->resources.changes : _resource_changes_local;
            case 4: return buildings_store().changes;
            case 5: return families_store().changes;
            case 6: return persons_store().changes;
            case 7: return family_influences().changes;
            case 8: return family_expeditions_store().changes;
            case 9: return trade_orders_store().changes;
            case 10: return _building_role_changes;
            case 14:
                switch (field.column) {
                    case 1: return _pending_commands.registry();
                    case 2: return _epoch_commands.registry();
                    case 3: return _structural_commands.registry();
                    case 4: return _family_trait_commands.registry();
                    case 5: return _family_founding_choices.registry();
                    default: throw std::logic_error("economy_worker_command_column_unregistered");
                }
            case 17:
                switch (field.column) {
                    case 1: return _settlements.tier.registry();
                    case 2: return _settlements.name_active.registry();
                    case 3: return _settlements.name_forced.registry();
                    case 4: return _settlements.prosperity_generation.registry();
                    case 5: return _settlements.name_roll_generation.registry();
                    case 6: return _settlements.prefix.registry();
                    case 7: return _settlements.root.registry();
                    case 8: return _settlements.suffix.registry();
                    case 9: return _settlements.disambiguator.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 18:
                switch (field.column) {
                    case 1: return _market_signals.cell_offsets.registry();
                    case 2: return _market_signals.good_ids.registry();
                    case 3: return _market_signals.business_demand_ema.registry();
                    case 4: return _market_signals.offered_supply_ema.registry();
                    case 5: return _market_signals.realized_withdrawal_ema.registry();
                    case 6: return _market_signals.cost_anchor_price.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 19:
                switch (field.column) {
                    case 1: return _labor_signals.cell_offsets.registry();
                    case 2: return _labor_signals.profession_ids.registry();
                    case 3: return _labor_signals.base_living_cost.registry();
                    case 4: return _labor_signals.role_living_cost.registry();
                    case 5: return _labor_signals.contract_wage_ema.registry();
                    case 6: return _labor_signals.paid_wage_ema.registry();
                    case 7: return _labor_signals.job_days.registry();
                    case 8: return _labor_signals.pay_ratio_q16.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 20:
                switch (field.column) {
                    case 1: return _trade_flows.cells.registry();
                    case 2: return _trade_flows.goods.registry();
                    case 3: return _trade_flows.import_ema.registry();
                    case 4: return _trade_flows.export_ema.registry();
                    case 5: return _trade_flows.period_import.registry();
                    case 6: return _trade_flows.period_export.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 21:
                switch (field.column) {
                    case 1: return _country_good_trade.countries.registry();
                    case 2: return _country_good_trade.goods.registry();
                    case 3: return _country_good_trade.import_quantity.registry();
                    case 4: return _country_good_trade.export_quantity.registry();
                    case 5: return _country_good_trade.import_base.registry();
                    case 6: return _country_good_trade.export_base.registry();
                    case 7: return _country_good_trade.import_tariff.registry();
                    case 8: return _country_good_trade.export_tariff.registry();
                    case 9: return _country_good_trade.batch_epoch.registry();
                    case 10: return _country_good_trade.batch_import_quantity.registry();
                    case 11: return _country_good_trade.batch_export_quantity.registry();
                    case 12: return _country_good_trade.batch_import_base.registry();
                    case 13: return _country_good_trade.batch_export_base.registry();
                    case 14: return _country_good_trade.batch_import_tariff.registry();
                    case 15: return _country_good_trade.batch_export_tariff.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 22:
                switch (field.column) {
                    case 1: return _country_partner_trade.countries.registry();
                    case 2: return _country_partner_trade.partners.registry();
                    case 3: return _country_partner_trade.import_quantity.registry();
                    case 4: return _country_partner_trade.export_quantity.registry();
                    case 5: return _country_partner_trade.import_base.registry();
                    case 6: return _country_partner_trade.export_base.registry();
                    case 7: return _country_partner_trade.order_count.registry();
                    case 8: return _country_partner_trade.batch_epoch.registry();
                    case 9: return _country_partner_trade.batch_import_quantity.registry();
                    case 10: return _country_partner_trade.batch_export_quantity.registry();
                    case 11: return _country_partner_trade.batch_import_base.registry();
                    case 12: return _country_partner_trade.batch_export_base.registry();
                    case 13: return _country_partner_trade.batch_order_count.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 23:
                switch (field.column) {
                    case 1: return _tariff_history.countries.registry();
                    case 2: return _tariff_history.kinds.registry();
                    case 3: return _tariff_history.bases.registry();
                    case 4: return _tariff_history.assessed.registry();
                    case 5: return _tariff_history.collected.registry();
                    case 6: return _tariff_history.requests.registry();
                    case 7: return _tariff_history.reserved.registry();
                    case 8: return _tariff_history.paid.registry();
                    case 9: return _tariff_history.cumulative_bases.registry();
                    case 10: return _tariff_history.cumulative_collected.registry();
                    case 11: return _tariff_history.cumulative_requests.registry();
                    case 12: return _tariff_history.cumulative_paid.registry();
                    default: throw std::logic_error("economy_worker_signal_column_unregistered");
                }
            case 25: return market_store().price_ceilings.registry();
            case 27: return _canal_projects.registry();
            case 26:
                switch (field.column) {
                    case 1: return _settlement_full_name_ids.registry();
                    case 2: return _settlement_prefix_ids.registry();
                    case 3: return _settlement_root_ids.registry();
                    case 4: return _settlement_suffix_ids.registry();
                    case 5: return _settlement_name_pack_id.registry();
                    case 6: return _ethnicity_ids.registry();
                    case 7: return _good_ids.registry();
                    case 8: return _plan_ids.registry();
                    case 9: return _profession_ids.registry();
                    default: throw std::logic_error("economy_name_catalog_column_unregistered");
                }
            case 24:
                switch (field.column) {
                    case 1: return _family_founding_offers.registry();
                    case 2: return _family_modifier_bindings.registry();
                    case 3: return _family_trigger_bindings.registry();
                    case 4: return _family_effect_bindings.registry();
                    case 5: return _family_founding_effects.registry();
                    case 6: return _family_split_parents.registry();
                    default: throw std::logic_error("economy_worker_variable_column_unregistered");
                }
            case 16:
                switch (field.column) {
                    case 1: return _birth_residual_q32.registry();
                    case 2: return _cell_building_structure_gen.registry();
                    case 3: return _cell_food_access_eq_previous.registry();
                    case 4: return _cell_food_export_eq_previous.registry();
                    case 5: return _cell_food_flow_valid.registry();
                    case 6: return _cell_food_import_eq_previous.registry();
                    case 7: return _cell_food_input_eq_previous.registry();
                    case 8: return _cell_food_output_eq_previous.registry();
                    case 9: return _cell_last_settlement_day.registry();
                    case 10: return _cell_owner_cash_gen.registry();
                    case 11: return _cell_population_gen.registry();
                    case 12: return _cell_price_stock_gen.registry();
                    case 13: return _cell_settlement_generation.registry();
                    case 14: return _cell_social_pressure_level.registry();
                    case 15: return _cell_support_ema_q16.registry();
                    case 16: return _cell_technology_gen.registry();
                    case 17: return _cell_trade_gen.registry();
                    case 18: return _epoch_country_handles.registry();
                    case 19: return _fiscal_cumulative_bases.registry();
                    case 20: return _fiscal_cumulative_collected.registry();
                    case 21: return _fiscal_cumulative_paid.registry();
                    case 22: return _fiscal_cumulative_requests.registry();
                    case 23: return _fiscal_escrow_by_country.registry();
                    case 24: return _fiscal_last_events.registry();
                    case 25: return _fiscal_previous_country_handles.registry();
                    case 26: return _fiscal_previous_requests.registry();
                    case 27: return _family_milestones_reached.registry();
                    case 28: return _cell_effect_shortage_q16.registry();
                    case 29: return _cell_essentials_shortage_q16.registry();
                    case 30: return _cell_force_wake.registry();
                    case 31: return _cell_next_review_day.registry();
                    case 32: return _cell_shortage_since_day.registry();
                    case 33: return _cell_tier.registry();
                    case 34: return _cell_tier_change_day.registry();
                    case 35: return _cell_tier_seen_gen.registry();
                    case 36: return _cell_tier_seen_population.registry();
                    case 37: return _environment_moisture_q16.registry();
                    case 38: return _environment_plant_available_water_q16.registry();
                    case 39: return _environment_precipitation_q16.registry();
                    case 40: return _environment_snow_q16.registry();
                    case 41: return _environment_temperature_30d_q16.registry();
                    case 42: return _environment_temperature_q16.registry();
                    case 43: return _environment_weather_q16.registry();
                    case 44: return _fiscal_last_assessed.registry();
                    case 45: return _fiscal_last_bases.registry();
                    case 46: return _fiscal_last_collected.registry();
                    case 47: return _fiscal_last_paid.registry();
                    case 48: return _fiscal_last_requests.registry();
                    case 49: return _fiscal_last_reserved.registry();
                    case 50: return _fiscal_last_unmet.registry();
                    case 51: return _maintenance_horizon_days_by_sector.registry();
                    case 52: return _cell_temperature_annual_q16.registry();
                    case 53: return _cell_temperature_anomaly_q16.registry();
                    case 54: return _cell_hazard_today_mask.registry();
                    case 55: return _cell_dry_streak_days.registry();
                    case 56: return _cell_days_since_hazard.registry();
                    case 57: return _cell_previous_hazard_mask.registry();
                    case 58: return _cell_weather_type.registry();
                    case 59: return _cell_cover.registry();
                    case 60: return _fiscal_last_non_tax_outflow.registry();
                    default: throw std::logic_error("economy_worker_native_column_unregistered");
                }
            case 15: return _metadata_changes;
            case 13: return _asset_peer_journal.registry();
            case 12:
                switch (field.column) {
                    case 1: return family_memberships().registry();
                    case 2: return family_ownerships().registry();
                    case 3: return family_trait_rolls().registry();
                    case 4: return person_needs().registry();
                    case 5: return family_expedition_payloads().registry();
                    case 6: return family_expedition_cargo().registry();
                    case 7: return family_expedition_kit_buildings().registry();
                    default: throw std::logic_error("economy_worker_record_column_unregistered");
                }
            case 11:
                switch (field.column) {
                    case 1: return family_expedition_route_cells().registry();
                    case 2: return family_expedition_route_costs().registry();
                    case 3: return family_expedition_person_handles().registry();
                    case 4: return family_expedition_missing_good_ids().registry();
                    case 5: return family_expedition_missing_good_quantities().registry();
                    default: throw std::logic_error("economy_worker_change_side_column_unregistered");
                }

            default: throw std::logic_error("economy_worker_change_domain_unregistered");
        }
    }
    void merge_economy_worker_changes(const EconomyWorkerChanges &changes) {
        // The coordinator visits each private record once in task order.
        // Adding domains must not multiply scans over the same touched list.
        for (const auto &before : changes.preimages)
            worker_change_registry(before.field).capture_before(before.field, before.lane, before.bits);
        for (const auto &range : changes.ranges)
            worker_change_registry(range.field).touch(range.field, range.first, range.count);
    }
