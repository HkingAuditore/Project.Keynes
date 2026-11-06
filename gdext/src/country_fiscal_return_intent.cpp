#include "country_fiscal_return_intent.h"
#include "country_runtime.h"
#include <godot_cpp/variant/variant.hpp>

namespace pk {
CountryFiscalReturnPort NativeCountryRuntime::fiscal_return_port() {
    return CountryFiscalReturnPort(this);
}

CountryFiscalReturnIntent::OrderKey CountryFiscalReturnPort::next_order_key() const {
    return {std::max<int64_t>(0, _owner->_last_committed_day + 1),
        _owner->_economy_asset_operation_sequence + 1,
        _owner->_next_economy_asset_transaction_id == 0 ? 1 : _owner->_next_economy_asset_transaction_id};
}

godot::Dictionary CountryFiscalReturnPort::submit(const CountryFiscalReturnIntent &intent) const {
    // Inline consumption is already totally ordered. Do not allocate a second
    // sequence or enqueue work past the caller's escrow/conservation boundary.
    if (!(intent.order == next_order_key())) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_fiscal_return_intent_order_mismatch";
        return out;
    }
    return _owner->begin_economy_fiscal_return(intent.country_handle, intent.offered,
        intent.origin_epoch, intent.origin_stage);
}

int64_t CountryFiscalReturnPort::resolve_cash(const CountryFiscalCashIntent &intent) const {
    // submit -> prepared -> committed -> applied, all under the Country owner.
    return _owner->complete_economy_asset_compatibility(submit_cash(intent));
}

godot::Dictionary CountryFiscalReturnPort::submit_cash(const CountryFiscalCashIntent &intent) const {
    if (!(intent.order == next_order_key())) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_fiscal_cash_intent_order_mismatch";
        return out;
    }
    if (intent.kind == CountryFiscalCashIntent::Kind::RESERVE)
        return _owner->begin_economy_fiscal_reserve(intent.country_handle, intent.amount,
            intent.origin_epoch, intent.origin_stage);
    return _owner->begin_economy_fiscal_collect(intent.country_handle, intent.amount,
        intent.origin_epoch, intent.origin_stage);
}

godot::Dictionary CountryFiscalReturnPort::submit_transfer(const TransferIntent &intent) const {
    if (!(intent.order == next_order_key())) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_transfer_intent_order_mismatch";
        return out;
    }
    switch (intent.kind) {
        case TransferIntent::Kind::CASH_TO_COHORT:
            return _owner->begin_economy_cash_to_cohort(intent.country_handle,
                intent.quantity, intent.origin_epoch, intent.origin_stage);
        case TransferIntent::Kind::CASH_FROM_COHORT:
            return _owner->begin_economy_cash_from_cohort(intent.country_handle,
                intent.quantity, intent.origin_epoch, intent.origin_stage);
        case TransferIntent::Kind::GOOD_TO_MARKET:
            return _owner->begin_economy_good_to_market(intent.country_handle, intent.good,
                intent.quantity, intent.origin_epoch, intent.origin_stage);
        case TransferIntent::Kind::GOOD_FROM_MARKET:
            return _owner->begin_economy_good_from_market(intent.country_handle, intent.good,
                intent.quantity, intent.origin_epoch, intent.origin_stage);
    }
    return {};
}

godot::Dictionary CountryFiscalReturnPort::submit_research(const ResearchIntent &intent) const {
    if (!(intent.order == next_order_key())) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_research_intent_order_mismatch";
        return out;
    }
    return _owner->begin_economy_research_purchase(intent.country_handle,
        intent.quantity, intent.cash, intent.origin_epoch, intent.origin_stage);
}

godot::Dictionary CountryFiscalReturnPort::submit_spend(const SpendIntent &intent) const {
    if (!(intent.order == next_order_key())) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_spend_intent_order_mismatch";
        return out;
    }
    return _owner->begin_economy_treasury_spend(intent.country_handle,
        intent.goods, intent.quantities, intent.cash, intent.origin_epoch, intent.origin_stage);
}

godot::Dictionary CountryFiscalReturnPort::prepared(
        const ReceiptKey &key, bool accepted, const char *reason) const {
    return _owner->acknowledge_economy_asset_peer_prepared(key.transaction_id,
        key.session_epoch, key.country_generation, key.peer_generation,
        accepted, godot::String(reason));
}

godot::Dictionary CountryFiscalReturnPort::apply(uint64_t transaction_id) const {
    return _owner->commit_economy_asset_transaction(transaction_id);
}

godot::Dictionary CountryFiscalReturnPort::applied(
        const ReceiptKey &key, bool accepted, const char *reason) const {
    return _owner->acknowledge_economy_asset_peer_applied(key.transaction_id,
        key.session_epoch, key.country_generation, key.peer_generation,
        accepted, godot::String(reason));
}
} // namespace pk
