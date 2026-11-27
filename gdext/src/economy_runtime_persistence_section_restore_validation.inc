    Dictionary out;
    if (!_restore.active || _restore.failed || !_restore.header_seen || !_restore.end_seen) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                         : (!_restore.header_seen ? "restore_header_missing" : "restore_end_missing"));
        set_restore_rejected_reason(
            String(out["reason"]).utf8().get_data());
        return out;
    }
    // The message below used to print only four counters, so a mismatch in any
    // of the other ~40 sections read as "everything complete, still rejected".
    const auto s = _restore.schema_version;
    const char *first_incomplete =
        _restore.restored_pages != _restore.expected_pages ? "pages" :
        _restore.restored_markets != market_store().market_count.get() ? "markets" :
        _restore.restored_cells != _cell_count.get() ? "cells" :
        _restore.restored_commands != _restore.expected_commands ? "commands" :
        _restore.restored_buildings != _restore.expected_buildings ? "buildings" :
        _restore.restored_construction != _restore.expected_construction ? "construction" :
        _restore.restored_audits != _restore.expected_audits ? "audits" :
        _restore.restored_signals != _restore.expected_signals ? "signals" :
        _restore.restored_labor_signals != _restore.expected_labor_signals ? "labor_signals" :
        _restore.restored_trade_orders != _restore.expected_trade_orders ? "trade_orders" :
        _restore.restored_trade_flows != _restore.expected_trade_flows ? "trade_flows" :
        (s >= 33 && (!_restore.tariff_history_seen ||
            _restore.restored_tariff_history != _restore.expected_tariff_history)) ? "tariff_history" :
        (s >= 33 && (!_restore.country_good_seen ||
            _restore.restored_country_good != _restore.expected_country_good)) ? "country_good" :
        (s >= 33 && (!_restore.country_partner_seen ||
            _restore.restored_country_partner != _restore.expected_country_partner)) ? "country_partner" :
        (s >= 34 && (!_restore.canal_quotes_seen ||
            _restore.restored_canal_quotes != _restore.expected_canal_quotes)) ? "canal_quotes" :
        (s >= 34 && (!_restore.canal_projects_seen ||
            _restore.restored_canal_projects != _restore.expected_canal_projects)) ? "canal_projects" :
        (s >= 20 && !_restore.modifier_seen) ? "modifier" :
        (s >= 23 && !_restore.fiscal_seen) ? "fiscal" :
        (s >= 52 && (_restore.expected_fiscal < 0 ||
            _restore.restored_fiscal != _restore.expected_fiscal)) ? "fiscal_rows" :
        (s >= 52 && (!_restore.fiscal_peer_seen ||
            _restore.restored_fiscal_peer != _restore.expected_fiscal_peer)) ? "fiscal_peer" :
        (s >= 53 && _restore.expected_d7_peer_ext > 0 && (!_restore.d7_peer_ext_seen ||
            _restore.restored_d7_peer_ext != _restore.expected_d7_peer_ext)) ? "d7_peer_ext" :
        (s >= 52 && _restore.resource_stock_seen &&
            _restore.restored_resource_rows != _restore.expected_resource_rows) ? "resource_rows" :
        (s >= 24 && !_restore.settlement_names_seen) ? "settlement_names" :
        (s >= 26 && (!_restore.family_records_seen || !_restore.family_membership_seen ||
            !_restore.family_ownership_seen)) ? "family" :
        (s >= 27 && (!_restore.person_records_seen || !_restore.person_needs_seen ||
            _restore.restored_persons != _restore.expected_persons ||
            _restore.restored_person_needs != _restore.expected_person_needs)) ? "persons" :
        (s >= 29 && (!_restore.family_traits_seen || !_restore.family_influences_seen ||
            !_restore.family_trait_commands_seen ||
            _restore.restored_family_traits != _restore.expected_family_traits ||
            _restore.restored_family_influences != _restore.expected_family_influences ||
            _restore.restored_family_trait_commands !=
                _restore.expected_family_trait_commands)) ? "family_traits" : nullptr;
    if (_restore.restored_pages != _restore.expected_pages ||
        _restore.restored_markets != market_store().market_count.get() ||
        _restore.restored_cells != _cell_count.get() ||
        _restore.restored_commands != _restore.expected_commands ||
        _restore.restored_buildings != _restore.expected_buildings ||
        _restore.restored_construction != _restore.expected_construction ||
        _restore.restored_audits != _restore.expected_audits ||
        _restore.restored_signals != _restore.expected_signals ||
        _restore.restored_labor_signals != _restore.expected_labor_signals ||
        _restore.restored_trade_orders != _restore.expected_trade_orders ||
        _restore.restored_trade_flows != _restore.expected_trade_flows ||
        (_restore.schema_version >= 33 &&
         (!_restore.tariff_history_seen ||
          _restore.restored_tariff_history != _restore.expected_tariff_history ||
          !_restore.country_good_seen ||
          _restore.restored_country_good != _restore.expected_country_good ||
          !_restore.country_partner_seen ||
          _restore.restored_country_partner != _restore.expected_country_partner)) ||
        (_restore.schema_version >= 34 &&
         (!_restore.canal_quotes_seen ||
          _restore.restored_canal_quotes != _restore.expected_canal_quotes ||
          !_restore.canal_projects_seen ||
          _restore.restored_canal_projects != _restore.expected_canal_projects)) ||
        (_restore.schema_version >= 20 && !_restore.modifier_seen) ||
        (_restore.schema_version >= 23 && !_restore.fiscal_seen) ||
        (_restore.schema_version >= 52 &&
         (_restore.expected_fiscal < 0 ||
          _restore.restored_fiscal != _restore.expected_fiscal ||
          !_restore.fiscal_peer_seen ||
          _restore.restored_fiscal_peer != _restore.expected_fiscal_peer)) ||
        (_restore.schema_version >= 53 &&
         _restore.expected_d7_peer_ext > 0 &&
         (!_restore.d7_peer_ext_seen ||
          _restore.restored_d7_peer_ext != _restore.expected_d7_peer_ext)) ||
        (_restore.schema_version >= 52 && _restore.resource_stock_seen &&
         _restore.restored_resource_rows != _restore.expected_resource_rows) ||
        (_restore.schema_version >= 24 &&
         !_restore.settlement_names_seen) ||
        (_restore.schema_version >= 26 &&
         (!_restore.family_records_seen || !_restore.family_membership_seen ||
          !_restore.family_ownership_seen)) ||
        (_restore.schema_version >= 27 &&
         (!_restore.person_records_seen || !_restore.person_needs_seen ||
           _restore.restored_persons != _restore.expected_persons ||
           _restore.restored_person_needs !=
               _restore.expected_person_needs)) ||
        (_restore.schema_version >= 29 &&
         (!_restore.family_traits_seen || !_restore.family_influences_seen ||
          !_restore.family_trait_commands_seen ||
          _restore.restored_family_traits !=
              _restore.expected_family_traits ||
          _restore.restored_family_influences !=
              _restore.expected_family_influences ||
          _restore.restored_family_trait_commands !=
              _restore.expected_family_trait_commands))) {
        out["ok"] = false;
        out["first_incomplete"] = String(first_incomplete != nullptr ? first_incomplete : "unknown");
        out["reason"] = String("restore_section_incomplete first=") +
            String(first_incomplete != nullptr ? first_incomplete : "unknown") +
            String(" pages=") + String::num_int64(_restore.restored_pages) + String("/") + String::num_int64(_restore.expected_pages) + String(" buildings=") + String::num_int64(_restore.restored_buildings) + String("/") + String::num_int64(_restore.expected_buildings) + String(" construction=") + String::num_int64(_restore.restored_construction) + String("/") + String::num_int64(_restore.expected_construction) + String(" trade_orders=") + String::num_int64(_restore.restored_trade_orders) + String("/") + String::num_int64(_restore.expected_trade_orders);
        out["expected_pages"] = _restore.expected_pages;
        out["restored_pages"] = _restore.restored_pages;
        out["expected_buildings"] = _restore.expected_buildings;
        out["restored_buildings"] = _restore.restored_buildings;
        out["expected_construction"] = _restore.expected_construction;
        out["restored_construction"] = _restore.restored_construction;
        out["expected_trade_orders"] = _restore.expected_trade_orders;
        out["restored_trade_orders"] = _restore.restored_trade_orders;
        out["expected_trade_flows"] = _restore.expected_trade_flows;
        out["restored_trade_flows"] = _restore.restored_trade_flows;
        out["expected_tariff_history"] = _restore.expected_tariff_history;
        out["restored_tariff_history"] = _restore.restored_tariff_history;
        out["expected_fiscal"] = _restore.expected_fiscal;
        out["restored_fiscal"] = _restore.restored_fiscal;
        set_restore_rejected_reason(
            String(out["reason"]).utf8().get_data());
        return out;
    }
    if (!_restore.family_expeditions_seen ||
        _restore.restored_family_expedition_slots !=
            _restore.expected_family_expedition_slots ||
        _restore.restored_family_expeditions !=
            _restore.expected_family_expeditions) {
        out["ok"] = false;
        out["reason"] = "restore_family_expedition_section_incomplete";
        set_restore_rejected_reason("restore_family_expedition_section_incomplete");
        return out;
    }
    if (!_restore.family_founding_seen ||
        _restore.expected_family_founding_records < 0 ||
        _restore.restored_family_founding_records !=
            _restore.expected_family_founding_records) {
        out["ok"] = false;
        out["reason"] = "restore_family_founding_section_incomplete";
        set_restore_rejected_reason("restore_family_founding_section_incomplete");
        return out;
    }
    {
        std::string founding_error;
        if (!validate_restored_family_founding(founding_error)) {
            out["ok"] = false;
            out["reason"] = String(founding_error.c_str());
            set_restore_rejected_reason(founding_error.c_str());
            return out;
        }
    }
    const auto trade_key = [](int32_t first, int32_t second) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(first)) << 32) |
            static_cast<uint32_t>(second);
    };
    std::unordered_set<uint64_t> aggregate_keys;
    aggregate_keys.reserve(_country_good_trade.countries.size());
    for (size_t i = 0; i < _country_good_trade.countries.size(); ++i) {
        if (!aggregate_keys.emplace(trade_key(_country_good_trade.countries[i],
                _country_good_trade.goods[i])).second) {
            out["ok"] = false;
            out["reason"] = "restore_country_good_duplicate";
            return out;
        }
    }
    aggregate_keys.clear();
    aggregate_keys.reserve(_country_partner_trade.countries.size());
    for (size_t i = 0; i < _country_partner_trade.countries.size(); ++i) {
        if (!aggregate_keys.emplace(trade_key(
                _country_partner_trade.countries[i],
                _country_partner_trade.partners[i])).second) {
            out["ok"] = false;
            out["reason"] = "restore_country_partner_duplicate";
            return out;
        }
    }
    aggregate_keys.clear();
