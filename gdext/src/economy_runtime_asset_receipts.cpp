#include "economy_runtime.h"

namespace pk {
uint64_t NativeEconomyRuntime::asset_peer_request_high_watermark() const noexcept {
    uint64_t maximum = 0;
    for (const auto &entry : _asset_peer_journal)
        maximum = std::max(maximum, entry.first);
    return maximum;
}

bool NativeEconomyRuntime::fiscal_peer_journal_matches(
        const RuntimeEconomyAssetRequest &request,
        const FiscalPeerJournalRecord &record, std::string &error) const {
    error.clear();
    if (record.request_id != request.request_id ||
        record.transaction_id != request.transaction_id ||
        record.country_handle != request.country_handle ||
        record.country_generation != request.country_generation ||
        record.peer_generation != request.peer_generation ||
        record.day != request.day ||
        record.operation_sequence != request.operation_sequence ||
        record.continuation_index != request.continuation_index ||
        record.country_slot != request.country_slot ||
        record.operation != request.operation ||
        record.requested_quantity != request.requested_quantity ||
        record.requested_cash != request.requested_cash) {
        error = "country_economy_asset_peer_journal_identity_mismatch";
        return false;
    }
    return true;
}

RuntimeEconomyAssetResult NativeEconomyRuntime::fiscal_peer_result_from_journal(
        const RuntimeEconomyAssetRequest &request,
        const FiscalPeerJournalRecord &record) const {
    RuntimeEconomyAssetResult result;
    result.code = record.result_code;
    result.state = record.state;
    result.accepted = record.accepted;
    result.session_epoch = request.session_epoch;
    result.transaction_id = record.transaction_id;
    result.request_id = record.request_id;
    result.operation = record.operation;
    result.continuation_index = record.continuation_index;
    result.day = record.day;
    result.country_generation = record.country_generation;
    result.peer_generation = record.peer_generation;
    result.committed_peer_generation = record.committed_peer_generation;
    result.country_slot = record.country_slot;
    result.target_slot = request.target_slot;
    result.committed_quantity = record.committed_quantity;
    result.committed_cash = record.committed_cash;
    result.committed_goods_total = 0;
    result.reason = record.reason;
    return result;
}

} // namespace pk
