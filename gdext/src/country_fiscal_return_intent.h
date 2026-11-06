#pragma once
#include <cstdint>

namespace godot { class Dictionary; class PackedInt32Array; class PackedInt64Array; }
namespace pk {
class NativeCountryRuntime;

// The synchronous owner consumes one intent at the existing call boundary.
// Worker requests retain RuntimeEconomyAssetRequest and its existing queue.
struct CountryFiscalReturnIntent {
    struct OrderKey {
        int64_t day;
        uint64_t sequence;
        uint64_t request_id;
        bool operator==(const OrderKey &other) const {
            return day == other.day && sequence == other.sequence && request_id == other.request_id;
        }
    };
    OrderKey order;
    int64_t country_handle;
    int64_t offered;
    int64_t origin_epoch;
    int32_t origin_stage;
};

// Reserve/collect share the same synchronous journal and completion phases.
struct CountryFiscalCashIntent {
    enum class Kind { RESERVE, COLLECT };
    CountryFiscalReturnIntent::OrderKey order;
    Kind kind;
    int64_t country_handle;
    int64_t amount;
    int64_t origin_epoch;
    int32_t origin_stage;
};

class CountryFiscalReturnPort {
public:
    struct TransferIntent {
        enum class Kind { CASH_TO_COHORT, CASH_FROM_COHORT, GOOD_TO_MARKET, GOOD_FROM_MARKET };
        CountryFiscalReturnIntent::OrderKey order;
        Kind kind;
        int64_t country_handle;
        int32_t good;
        int64_t quantity;
        int64_t origin_epoch;
        int32_t origin_stage;
    };
    TransferIntent cash_to_cohort(int64_t handle, int64_t amount, int64_t epoch, int32_t stage) const {
        return {next_order_key(), TransferIntent::Kind::CASH_TO_COHORT, handle, -1, amount, epoch, stage};
    }
    TransferIntent cash_from_cohort(int64_t handle, int64_t amount, int64_t epoch, int32_t stage) const {
        return {next_order_key(), TransferIntent::Kind::CASH_FROM_COHORT, handle, -1, amount, epoch, stage};
    }
    TransferIntent good_to_market(int64_t handle, int32_t good, int64_t amount, int64_t epoch, int32_t stage) const {
        return {next_order_key(), TransferIntent::Kind::GOOD_TO_MARKET, handle, good, amount, epoch, stage};
    }
    TransferIntent good_from_market(int64_t handle, int32_t good, int64_t amount, int64_t epoch, int32_t stage) const {
        return {next_order_key(), TransferIntent::Kind::GOOD_FROM_MARKET, handle, good, amount, epoch, stage};
    }
    godot::Dictionary submit_transfer(const TransferIntent &intent) const;
    struct ResearchIntent {
        CountryFiscalReturnIntent::OrderKey order;
        int64_t country_handle, quantity, cash, origin_epoch;
        int32_t origin_stage;
    };
    struct SpendIntent {
        CountryFiscalReturnIntent::OrderKey order;
        int64_t country_handle;
        const godot::PackedInt32Array &goods;
        const godot::PackedInt64Array &quantities;
        int64_t cash, origin_epoch;
        int32_t origin_stage;
    };
    ResearchIntent research_intent(int64_t handle, int64_t quantity, int64_t cash, int64_t epoch, int32_t stage) const {
        return {next_order_key(), handle, quantity, cash, epoch, stage};
    }
    // Borrowed arrays are consumed inline, never retained by this port.
    SpendIntent spend_intent(int64_t handle, const godot::PackedInt32Array &goods,
            const godot::PackedInt64Array &quantities, int64_t cash, int64_t epoch, int32_t stage) const {
        return {next_order_key(), handle, goods, quantities, cash, epoch, stage};
    }
    godot::Dictionary submit_research(const ResearchIntent &intent) const;
    godot::Dictionary submit_spend(const SpendIntent &intent) const;
    struct ReceiptKey {
        uint64_t transaction_id;
        uint64_t session_epoch;
        uint64_t country_generation;
        uint64_t peer_generation;
    };
    explicit CountryFiscalReturnPort(NativeCountryRuntime *owner) : _owner(owner) {}
    CountryFiscalReturnIntent::OrderKey next_order_key() const;
    godot::Dictionary submit(const CountryFiscalReturnIntent &intent) const;
    CountryFiscalCashIntent reserve_intent(int64_t handle, int64_t amount, int64_t epoch, int32_t stage) const {
        return {next_order_key(), CountryFiscalCashIntent::Kind::RESERVE, handle, amount, epoch, stage};
    }
    CountryFiscalCashIntent collect_intent(int64_t handle, int64_t amount, int64_t epoch, int32_t stage) const {
        return {next_order_key(), CountryFiscalCashIntent::Kind::COLLECT, handle, amount, epoch, stage};
    }
    // Synchronous no-peer accounting preserves the legacy reserve/collect lifecycle.
    int64_t resolve_cash(const CountryFiscalCashIntent &intent) const;
    godot::Dictionary submit_cash(const CountryFiscalCashIntent &intent) const;
    godot::Dictionary prepared(const ReceiptKey &key, bool accepted, const char *reason) const;
    godot::Dictionary apply(uint64_t transaction_id) const;
    godot::Dictionary applied(const ReceiptKey &key, bool accepted, const char *reason) const;
private:
    NativeCountryRuntime *_owner;
};
} // namespace pk
