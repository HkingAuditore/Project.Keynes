#pragma once
#include "country_fiscal_return_intent.h"

namespace pk {
struct CountryProcurementIntent {
    CountryFiscalReturnIntent::OrderKey order;
    int64_t country_handle;
    int32_t good;
    int64_t quantity;
    int64_t origin_epoch;
    int32_t origin_stage;
    int64_t cash;
};

// The same Country asset journal owns preparation, Apply and acknowledgement.
// Only the initial request differs from the fiscal return protocol.
class CountryProcurementPort : public CountryFiscalReturnPort {
public:
    explicit CountryProcurementPort(NativeCountryRuntime *owner)
        : CountryFiscalReturnPort(owner), _owner(owner) {}
    godot::Dictionary submit(const CountryProcurementIntent &intent) const;
private:
    NativeCountryRuntime *_owner;
};
} // namespace pk
