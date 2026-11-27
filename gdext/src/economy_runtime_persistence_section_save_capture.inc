Dictionary NativeEconomyRuntime::begin_save(int32_t chunk_bytes) {
    Dictionary out;
    if (!_forensics_allow_fatal_export &&
        (_fiscal_reservation_continuation.active ||
         _epoch_begin_post_fiscal_pending)) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_reservation_pending";
        out["country_cursor"] =
            _fiscal_reservation_continuation.country_cursor;
        out["country_count"] =
            _fiscal_reservation_continuation.country_count;
        out["day"] = _fiscal_reservation_continuation.day_index;
        out["phase"] = _fiscal_reservation_continuation.phase;
        out["last_requested"] =
            _fiscal_reservation_continuation.last_requested;
        out["last_reserved"] =
            _fiscal_reservation_continuation.last_reserved;
        out["last_error"] = String::utf8(
            _fiscal_reservation_continuation.last_error.c_str());
        out["epoch_begin_pending"] = _epoch_begin_post_fiscal_pending;
        return out;
    }
    if (!_forensics_allow_fatal_export &&
        _country_research_procurement_continuation.active) {
        out["ok"] = false;
        out["reason"] = "economy_save_research_procurement_pending";
        out["transaction_id"] = static_cast<int64_t>(
            _country_research_procurement_continuation.transaction_id);
        out["phase"] = _country_research_procurement_continuation.phase;
        return out;
    }
    if (!_forensics_allow_fatal_export && _fiscal_settlement_continuation.active) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_settlement_pending";
        out["country_cursor"] = _fiscal_settlement_continuation.country_cursor;
        out["country_count"] = _fiscal_settlement_continuation.country_count;
        out["phase"] = _fiscal_settlement_continuation.phase;
        out["last_unused"] = _fiscal_settlement_continuation.last_unused;
        out["last_collected"] = _fiscal_settlement_continuation.last_collected;
        return out;
    }
    if (!_bootstrapped || (_fatal && !_forensics_allow_fatal_export) || _save.active || _restore.active ||
        (_epoch_active && !_ecp2_allow_mid_epoch_export)) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped"
                         : (_epoch_active ? "save_requires_committed_boundary"
                         : (_fatal ? "economy_fatal" : "save_restore_already_active"));
        return out;
    }
    // A persisted save must not freeze Economy next to Country commands that
    // are still due. An in-memory rollback backup is different: ECP2 apply
    // never touches Country, so the idle gate only blocked restoring a save
    // whose Country state legitimately carries due commands (worker start
    // after load then fell back to the synchronous path).
    if (_country_runtime == nullptr || !country_reads().economy_available() ||
        (!_save_country_identity_override && !_ecp2_rollback_backup_export && !_forensics_allow_fatal_export &&
         country_reads().should_run(_last_committed_day.get()))) {
        out["ok"] = false;
        out["reason"] = "save_requires_idle_country_runtime";
        return out;
    }
    const size_t cells = static_cast<size_t>(_cell_count.get());
    // Name the offending column instead of only the family. The `out["reason"]` string
    // is what reaches the caller, and "economy_save_state_shape_invalid" alone is not
    // actionable -- it cost a full round to find that this was NOT the
    // building/trade pairing check one layer up. `PK_SAVE_SHAPE_PROBE=1` prints the
    // first mismatch; the reason stays the same so callers and tests are unaffected.
    const struct { const char *name; size_t actual; size_t expected; } cell_columns[] = {
        {"market_cell_to_market", market_store().cell_to_market.size(), cells},
        {"environment_temperature_q16", _environment_temperature_q16.size(), cells},
        {"environment_temperature_30d_q16", _environment_temperature_30d_q16.size(), cells},
        {"environment_moisture_q16", _environment_moisture_q16.size(), cells},
        {"environment_plant_available_water_q16", _environment_plant_available_water_q16.size(), cells},
        {"environment_precipitation_q16", _environment_precipitation_q16.size(), cells},
        {"environment_snow_q16", _environment_snow_q16.size(), cells},
        {"environment_weather_q16", _environment_weather_q16.size(), cells},
        {"cell_temperature_annual_q16", _cell_temperature_annual_q16.size(), cells},
        {"cell_temperature_anomaly_q16", _cell_temperature_anomaly_q16.size(), cells},
        {"cell_hazard_today_mask", _cell_hazard_today_mask.size(), cells},
        {"cell_dry_streak_days", _cell_dry_streak_days.size(), cells},
        {"cell_days_since_hazard", _cell_days_since_hazard.size(), cells},
        {"cell_previous_hazard_mask", _cell_previous_hazard_mask.size(), cells},
        {"cell_weather_type", _cell_weather_type.size(), cells},
        {"cell_cover", _cell_cover.size(), cells},
        {"cell_last_settlement_day", _cell_last_settlement_day.size(), cells},
        {"birth_residual_q32", _birth_residual_q32.size(), cells * _ethnicity_ids.size()},
        {"cell_support_ema_q16", _cell_support_ema_q16.size(), cells},
        {"cell_food_output_eq_previous", _cell_food_output_eq_previous.size(), cells},
        {"cell_food_input_eq_previous", _cell_food_input_eq_previous.size(), cells},
        {"cell_food_import_eq_previous", _cell_food_import_eq_previous.size(), cells},
        {"cell_food_export_eq_previous", _cell_food_export_eq_previous.size(), cells},
        {"cell_food_access_eq_previous", _cell_food_access_eq_previous.size(), cells},
        {"cell_food_flow_valid", _cell_food_flow_valid.size(), cells},
        {"cell_settlement_generation", _cell_settlement_generation.size(), cells},
        {"cell_price_stock_gen", _cell_price_stock_gen.size(), cells},
        {"cell_owner_cash_gen", _cell_owner_cash_gen.size(), cells},
        {"cell_population_gen", _cell_population_gen.size(), cells},
        {"cell_building_structure_gen", _cell_building_structure_gen.size(), cells},
        {"cell_technology_gen", _cell_technology_gen.size(), cells},
        {"cell_resource_gen", _cell_resource_gen.size(), cells},
        {"cell_trade_gen", _cell_trade_gen.size(), cells},
    };
    for (const auto &column : cell_columns) {
        if (column.actual == column.expected) continue;
        if (pk::runtime_switch_value(pk::RuntimeSwitch::PK_SAVE_SHAPE_PROBE) != nullptr)
            pk::log_error("[save-shape] %s actual=%zu expected=%zu",
                column.name, column.actual, column.expected);
        break;
    }
    if (market_store().cell_to_market.size() != cells ||
        _environment_temperature_q16.size() != cells ||
        _environment_temperature_30d_q16.size() != cells ||
        _environment_moisture_q16.size() != cells ||
        _environment_plant_available_water_q16.size() != cells ||
        _environment_precipitation_q16.size() != cells ||
        _environment_snow_q16.size() != cells ||
        _environment_weather_q16.size() != cells ||
        _cell_temperature_annual_q16.size() != cells ||
        _cell_temperature_anomaly_q16.size() != cells ||
        _cell_hazard_today_mask.size() != cells ||
        _cell_dry_streak_days.size() != cells ||
        _cell_days_since_hazard.size() != cells ||
        _cell_previous_hazard_mask.size() != cells ||
        _cell_weather_type.size() != cells ||
        _cell_cover.size() != cells ||
        _cell_last_settlement_day.size() != cells ||
        _birth_residual_q32.size() != cells * _ethnicity_ids.size() ||
        _cell_support_ema_q16.size() != cells ||
        _cell_food_output_eq_previous.size() != cells ||
        _cell_food_input_eq_previous.size() != cells ||
        _cell_food_import_eq_previous.size() != cells ||
        _cell_food_export_eq_previous.size() != cells ||
        _cell_food_access_eq_previous.size() != cells ||
        _cell_food_flow_valid.size() != cells ||
        _cell_settlement_generation.size() != cells ||
        _cell_price_stock_gen.size() != cells ||
        _cell_owner_cash_gen.size() != cells ||
        _cell_population_gen.size() != cells ||
        _cell_building_structure_gen.size() != cells ||
        _cell_technology_gen.size() != cells ||
        _cell_resource_gen.size() != cells ||
        _cell_trade_gen.size() != cells) {
        out["ok"] = false;
        out["reason"] = "economy_save_state_shape_invalid";
        return out;
    }
    // Sparse trade/fiscal tables are serialized by parallel columns.  Keep
    // the capture boundary fail-closed so a partially rebuilt aggregate can
    // never make the writer index past one of the newly added batch columns.
    const auto same_shape = [](std::initializer_list<size_t> sizes) {
        if (sizes.size() == 0) return true;
        const size_t expected = *sizes.begin();
        for (const size_t size : sizes) {
            if (size != expected) return false;
        }
        return true;
    };
    if (!same_shape({_tariff_history.countries.size(),
                     _tariff_history.kinds.size(),
                     _tariff_history.bases.size(),
                     _tariff_history.assessed.size(),
                     _tariff_history.collected.size(),
                     _tariff_history.requests.size(),
                     _tariff_history.reserved.size(),
                     _tariff_history.paid.size(),
                     _tariff_history.cumulative_bases.size(),
                     _tariff_history.cumulative_collected.size(),
                     _tariff_history.cumulative_requests.size(),
                     _tariff_history.cumulative_paid.size()}) ||
        !same_shape({_country_good_trade.countries.size(),
                     _country_good_trade.goods.size(),
                     _country_good_trade.import_quantity.size(),
                     _country_good_trade.export_quantity.size(),
                     _country_good_trade.import_base.size(),
                     _country_good_trade.export_base.size(),
                     _country_good_trade.import_tariff.size(),
                     _country_good_trade.export_tariff.size(),
                     _country_good_trade.batch_epoch.size(),
                     _country_good_trade.batch_import_quantity.size(),
                     _country_good_trade.batch_export_quantity.size(),
                     _country_good_trade.batch_import_base.size(),
                     _country_good_trade.batch_export_base.size(),
                     _country_good_trade.batch_import_tariff.size(),
                     _country_good_trade.batch_export_tariff.size()}) ||
        !same_shape({_country_partner_trade.countries.size(),
                     _country_partner_trade.partners.size(),
                     _country_partner_trade.import_quantity.size(),
                     _country_partner_trade.export_quantity.size(),
                     _country_partner_trade.import_base.size(),
                     _country_partner_trade.export_base.size(),
                     _country_partner_trade.order_count.size(),
                     _country_partner_trade.batch_epoch.size(),
                     _country_partner_trade.batch_import_quantity.size(),
                     _country_partner_trade.batch_export_quantity.size(),
                     _country_partner_trade.batch_import_base.size(),
                     _country_partner_trade.batch_export_base.size(),
                     _country_partner_trade.batch_order_count.size()})) {
        out["ok"] = false;
        out["reason"] = "economy_save_state_shape_invalid";
        return out;
    }
    CountryReadView::Snapshot country_snapshot;
    if (!country_reads().copy_economy_snapshot(country_snapshot) ||
        country_snapshot.country_count < 0) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_country_snapshot_unavailable";
        return out;
    }
    const size_t fiscal_country_count = static_cast<size_t>(
        country_snapshot.country_count);
    if (!_fiscal_escrow_by_country.empty() &&
        _fiscal_escrow_by_country.size() != fiscal_country_count) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_escrow_shape_invalid";
        return out;
    }
    // A capture must not serialize need rows whose person was already retired,
    // because restore would prune them and change the row count.
    compact_person_needs();
    _save = {};
    _save.active = true;
    _save.chunk_bytes = std::clamp(chunk_bytes, 64 * 1024, 16 * 1024 * 1024);
    _save.fiscal_country_count = country_snapshot.country_count;
    std::string modifier_error;
    if (_modifier_runtime != nullptr &&
        !modifier_api::serialize_domain(*_modifier_runtime, ModifierApi::ECONOMY,
                                              _save.modifier_bytes,
                                              modifier_error)) {
        _save = {};
        out["ok"] = false;
        out["reason"] = String(modifier_error.c_str());
        return out;
    }
    out["ok"] = true;
    out["chunk_bytes"] = _save.chunk_bytes;
    out["schema_version"] = SCHEMA_VERSION;
    out["catalog_hash"] = _catalog_hash.get();
    out["committed_day"] = _last_committed_day.get();
    // R4-2: generation / state_hash / restore_eligible. Without them the fatal
    // snapshot manifest recorded native_generation=0 and native_state_hash=0 for
    // a 42 MB archive that was in fact written at a committed boundary, while the
    // paired country.pkcn recorded generation=1 and a real hash.
    write_save_identity_report(out);
    return out;
}

Dictionary NativeEconomyRuntime::begin_forensics_save(int32_t chunk_bytes) {
    const bool saved_mid_epoch = _ecp2_allow_mid_epoch_export;
    const bool saved_fatal = _forensics_allow_fatal_export;
    _ecp2_allow_mid_epoch_export = true;
    _forensics_allow_fatal_export = true;
    Dictionary result = begin_save(chunk_bytes);
    _ecp2_allow_mid_epoch_export = saved_mid_epoch;
    _forensics_allow_fatal_export = saved_fatal;
    return result;
}

Dictionary NativeEconomyRuntime::end_save() {
    Dictionary out;
    if (!_save.active) {
        out["ok"] = false;
        out["reason"] = "save_not_active";
        return out;
    }
    if (!_save.end_emitted) {
        out["ok"] = false;
        out["reason"] = "save_stream_not_fully_read";
        return out;
    }
    _save = {};
    out["ok"] = true;
    return out;
}
