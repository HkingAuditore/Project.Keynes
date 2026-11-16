#include "economy_runtime.h"
#include "economy_runtime_persistence_codec.h"
#include "economy_runtime_test_access.h"

#include <memory>

namespace pk {

bool EconomyTargetSelectorTests::run_producer_continuation(std::string &error) {
    auto source = std::make_unique<NativeEconomyRuntime>();
    auto target = std::make_unique<NativeEconomyRuntime>();
    source->_cell_count = 2;
    source->market_store().good_count = 2;
    source->_market_signals.clear(2);
    source->_market_signals.cell_offsets = {0, 1, 2};
    source->_market_signals.good_ids = {0, 1};
    source->_market_signals.business_demand_ema = {3, 4};
    source->_market_signals.offered_supply_ema = {5, 6};
    source->_market_signals.realized_withdrawal_ema = {7, 8};
    source->_market_signals.cost_anchor_price = {100, 200};
    // Supported/discarded sales must not become a fictitious 100% merchant
    // channel after a cold restore. Both generations are read by quotes.
    source->_epoch_producer_sellable_current = {1000, 2000};
    source->_epoch_producer_merchant_sold_current = {200, 0};
    source->_epoch_previous_producer_sellable = {500, 800};
    source->_epoch_previous_producer_merchant_sold = {400, 300};
    source->_save.active = true;
    source->_save.section = persistence_codec::SAVE_SECTION_SIGNALS;
    const auto packed = source->read_save_chunk(65536);
    const std::vector<uint8_t> wire(packed.ptr(), packed.ptr() + packed.size());
    target->_cell_count = 2;
    target->market_store().good_count = 2;
    target->_market_signals.clear(2);
    target->_restore.header_seen = true;
    target->_restore.schema_version = NativeEconomyRuntime::SCHEMA_VERSION;
    if (!target->decode_restore_chunk(wire, error)) return false;
    if (target->_epoch_producer_sellable_current != source->_epoch_producer_sellable_current ||
        target->_epoch_producer_merchant_sold_current != source->_epoch_producer_merchant_sold_current ||
        target->_epoch_previous_producer_sellable != source->_epoch_previous_producer_sellable ||
        target->_epoch_previous_producer_merchant_sold != source->_epoch_previous_producer_merchant_sold) {
        error = "producer_sales_history_cold_restore_lost";
        return false;
    }
    target->prepare_restore_candidate_scratch();
    if (!target->_epoch_producer_sellable_current.empty() ||
        !target->_epoch_producer_merchant_sold_current.empty() ||
        !target->_epoch_previous_producer_sellable.empty() ||
        !target->_epoch_previous_producer_merchant_sold.empty()) {
        error = "producer_sales_history_warm_restore_leaked";
        return false;
    }
    return true;
}

} // namespace pk
