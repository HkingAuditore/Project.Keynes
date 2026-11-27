Dictionary NativeCountryRuntime::begin_economy_treasury_spend(
        int64_t country_handle, const PackedInt32Array &good_ids,
        const PackedInt64Array &quantities, int64_t cash,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_TREASURY_SPEND;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_cash = cash;
    transaction.requested_goods_total = 0;
    transaction.all_or_nothing = true;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }

    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (cash < 0 || good_ids.size() != quantities.size() ||
        good_ids.size() > 4096 ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_treasury_async_target_invalid");

    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    transaction.good_ids.reserve(static_cast<size_t>(good_ids.size()));
    transaction.good_quantities.reserve(static_cast<size_t>(quantities.size()));
    const size_t base = static_cast<size_t>(slot) * _good_ids.size();
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available_cash < cash)
        return reject("country_treasury_async_cash_insufficient");
    for (int64_t i = 0; i < good_ids.size(); ++i) {
        const int32_t good_id = good_ids[i];
        const int64_t quantity = quantities[i];
        if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
            quantity < 0)
            return reject("country_treasury_async_good_invalid");
        for (const int32_t prior : transaction.good_ids)
            if (prior == good_id)
                return reject("country_treasury_async_duplicate_good");
        if (transaction.requested_goods_total >
                std::numeric_limits<int64_t>::max() - quantity)
            return reject("country_treasury_async_quantity_overflow");
        const size_t index = base + static_cast<size_t>(good_id);
        const int64_t available = _country_goods[index] -
            _economy_asset_reserved_goods[index];
        if (available < quantity)
            return reject("country_treasury_async_goods_insufficient");
        transaction.good_ids.push_back(good_id);
        transaction.good_quantities.push_back(quantity);
        transaction.requested_goods_total += quantity;
        transaction.reserved_goods_total += quantity;
        if (i == 0) transaction.good_id = good_id;
    }
    transaction.reserved_cash = cash;
    transaction.prepared_quantity = transaction.requested_goods_total;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] += cash;
    for (size_t i = 0; i < transaction.good_ids.size(); ++i)
        _economy_asset_reserved_goods[base + static_cast<size_t>(
            transaction.good_ids[i])] += transaction.good_quantities[i];
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::acknowledge_economy_asset_peer_prepared(
        uint64_t transaction_id, uint64_t session_epoch,
        uint64_t country_generation, uint64_t peer_generation,
        bool accepted, const String &reason) {
    auto it = _economy_asset_transactions_in_flight.find(transaction_id);
    if (it == _economy_asset_transactions_in_flight.end()) {
        EconomyAssetTransaction terminal;
        for (auto history = _economy_asset_transaction_history.rbegin();
             history != _economy_asset_transaction_history.rend(); ++history) {
            if (history->transaction_id == transaction_id) {
                terminal = *history;
                Dictionary out = economy_asset_transaction_dictionary(terminal);
                out["replayed"] = true;
                return out;
            }
        }
        return economy_asset_failure("country_treasury_async_transaction_unknown");
    }
    EconomyAssetTransaction &transaction = it->second;
    if (transaction.status == ECONOMY_ASSET_PEER_PREPARED && accepted) {
        if (session_epoch != transaction.session_epoch ||
            country_generation != transaction.country_generation_before ||
            peer_generation != transaction.peer_generation)
            return economy_asset_failure(
                "country_treasury_async_prepare_duplicate_mismatch");
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["replayed"] = true;
        return out;
    }
    if (transaction.status != ECONOMY_ASSET_AWAITING_PEER_PREPARED)
        return economy_asset_failure("country_treasury_async_prepare_state_invalid");
    if (session_epoch != transaction.session_epoch ||
        country_generation != transaction.country_generation_before ||
        peer_generation == 0)
        return economy_asset_failure("country_treasury_async_prepare_identity_mismatch");
    auto release_reservation = [&]() {
        if (transaction.country_slot < 0) return;
        const size_t slot = static_cast<size_t>(transaction.country_slot);
        _economy_asset_reserved_cash[slot] -= transaction.reserved_cash;
        const size_t base = slot * _good_ids.size();
        for (size_t i = 0; i < transaction.good_ids.size(); ++i)
            _economy_asset_reserved_goods[base + static_cast<size_t>(
                transaction.good_ids[i])] -= transaction.good_quantities[i];
        if (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE &&
            slot < _economy_asset_reserved_research_points.size())
            _economy_asset_reserved_research_points[slot] -=
                transaction.prepared_quantity;
        transaction.reserved_cash = 0;
        transaction.reserved_goods_total = 0;
    };
    if (!accepted) {
        release_reservation();
        transaction.rejection_reason = reason.is_empty()
            ? "country_treasury_async_peer_prepare_rejected"
            : reason.utf8().get_data();
        finish_economy_asset_transaction(transaction, false,
            transaction.rejection_reason.c_str());
        return economy_asset_transaction_snapshot(transaction_id);
    }
    transaction.peer_generation = peer_generation;
    transaction.status = ECONOMY_ASSET_PEER_PREPARED;
    Dictionary out = economy_asset_transaction_dictionary(transaction);
    out["ok"] = true;
    return out;
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_reserve(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_FISCAL_RESERVE;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = requested;
    transaction.requested_cash = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_fiscal_async_reserve_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available <= 0)
        return reject("country_fiscal_async_reserve_cash_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.reserved_cash = transaction.prepared_quantity;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] +=
        transaction.reserved_cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_cash_credit(
        AssetOperation operation, int64_t country_handle, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id,
        const char *invalid_reason) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = operation;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = offered;
    transaction.requested_cash = offered;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject(invalid_reason);
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    transaction.prepared_quantity = std::min(
        offered, std::numeric_limits<int64_t>::max() -
            transaction.country_cash_before);
    if (transaction.prepared_quantity <= 0)
        return reject("country_fiscal_async_credit_capacity_exhausted");
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_return(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_FISCAL_RETURN, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_fiscal_async_return_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_collect(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_FISCAL_COLLECT, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_fiscal_async_collect_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_CASH_TO_COHORT;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = requested;
    transaction.requested_cash = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_cash_to_cohort_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available <= 0)
        return reject("country_cash_to_cohort_async_cash_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.reserved_cash = transaction.prepared_quantity;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] +=
        transaction.reserved_cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_CASH_FROM_COHORT, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_cash_from_cohort_async_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_GOOD_TO_MARKET;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.good_id = good_id;
    transaction.requested_quantity = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_good_to_market_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const size_t index = static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(good_id);
    transaction.country_good_before = _country_goods[index];
    const int64_t available = transaction.country_good_before -
        _economy_asset_reserved_goods[index];
    if (available <= 0)
        return reject("country_good_to_market_async_goods_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.good_ids.push_back(good_id);
    transaction.good_quantities.push_back(transaction.prepared_quantity);
    transaction.requested_goods_total = requested;
    transaction.reserved_goods_total = transaction.prepared_quantity;
    _economy_asset_reserved_goods[index] += transaction.prepared_quantity;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id,
        int64_t cash) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_GOOD_FROM_MARKET;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.good_id = good_id;
    transaction.requested_quantity = offered;
    transaction.requested_cash = cash;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (offered <= 0 || cash < 0 || good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_good_from_market_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available_cash < cash)
        return reject("country_good_from_market_async_cash_insufficient");
    const size_t index = static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(good_id);
    transaction.country_good_before = _country_goods[index];
    transaction.prepared_quantity = std::min(
        offered, std::numeric_limits<int64_t>::max() -
            transaction.country_good_before);
    if (transaction.prepared_quantity <= 0)
        return reject("country_good_from_market_async_capacity_exhausted");
    transaction.good_ids.push_back(good_id);
    transaction.good_quantities.push_back(transaction.prepared_quantity);
    transaction.requested_goods_total = offered;
    transaction.reserved_cash = cash;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] += cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_research_purchase(
        int64_t country_handle, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_RESEARCH_PURCHASE;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = quantity;
    transaction.requested_cash = total_cost;
    transaction.requested_goods_total = quantity;
    transaction.all_or_nothing = true;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }

    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    int32_t slot = -1;
    if (quantity <= 0 || total_cost < 0 ||
        _technology_points_good_id < 0 ||
        _technology_points_good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_research_purchase_async_target_invalid");

    transaction.country_slot = slot;
    transaction.good_id = _technology_points_good_id;
    transaction.country_generation_before = _generation;
    const size_t country_slot = static_cast<size_t>(slot);
    const size_t good_index = country_slot * _good_ids.size() +
        static_cast<size_t>(_technology_points_good_id);
    transaction.country_cash_before = _countries.cash[country_slot];
    transaction.country_good_before = _country_goods[good_index];
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[country_slot];
    const int64_t reserved_points =
        _economy_asset_reserved_research_points[country_slot];
    const int64_t points_capacity = std::numeric_limits<int64_t>::max() -
        transaction.country_good_before;
    const int64_t purchased_capacity = std::numeric_limits<int64_t>::max() -
        _country_research_purchased_total[country_slot];
    if (available_cash < total_cost || reserved_points > points_capacity ||
        quantity > points_capacity - reserved_points ||
        quantity > purchased_capacity)
        return reject("country_research_purchase_async_resources_insufficient");

    transaction.good_ids.push_back(_technology_points_good_id);
    transaction.good_quantities.push_back(quantity);
    transaction.prepared_quantity = quantity;
    transaction.reserved_cash = total_cost;
    _economy_asset_reserved_cash[country_slot] += total_cost;
    _economy_asset_reserved_research_points[country_slot] += quantity;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}
