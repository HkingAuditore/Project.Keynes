#include "country_procurement_intent.h"
#include "country_runtime.h"
#include <godot_cpp/variant/variant.hpp>

namespace pk {
CountryProcurementPort NativeCountryRuntime::procurement_port() {
    return CountryProcurementPort(this);
}

godot::Dictionary CountryProcurementPort::submit(const CountryProcurementIntent &intent) const {
    if (!(intent.order == next_order_key())) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_procurement_intent_order_mismatch";
        return out;
    }
    return _owner->begin_economy_good_from_market(intent.country_handle, intent.good,
        intent.quantity, intent.origin_epoch, intent.origin_stage, 0, intent.cash);
}
} // namespace pk
