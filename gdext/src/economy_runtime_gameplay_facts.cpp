#include "economy_runtime.h"

namespace pk {

bool NativeEconomyRuntime::drain_committed_gameplay_facts(
        std::vector<CommittedGameplayFact> &out) {
    if (_committed_gameplay_facts.empty()) return false;
    out.swap(_committed_gameplay_facts);
    _committed_gameplay_facts.clear();
    return true;
}

bool NativeEconomyRuntime::gameplay_fact_event(int32_t kind, int32_t &event_type,
                                               int32_t &payload_schema) {
    switch (kind) {
        case GAMEPLAY_FACT_CONSTRUCTION_COMPLETED: event_type = 6; payload_schema = 3; break;
        case GAMEPLAY_FACT_TRADE_ARRIVED: event_type = 7; payload_schema = 8; break;
        case GAMEPLAY_FACT_TARIFF_SUBSIDY_INTENT: event_type = 15; payload_schema = 8; break;
        case GAMEPLAY_FACT_SOCIAL_PRESSURE: event_type = 8; payload_schema = 5; break;
        case GAMEPLAY_FACT_TECHNOLOGY_PRACTICE: event_type = 14; payload_schema = 7; break;
        case GAMEPLAY_FACT_TECHNOLOGY_CONTACT: event_type = 16; payload_schema = 7; break;
        case GAMEPLAY_FACT_REPEATED_CROP_FAILURE: event_type = 11; payload_schema = 9; break;
        case GAMEPLAY_FACT_COUNTRY_DEVELOPMENT_METRIC: event_type = 17; payload_schema = 10; break;
        case GAMEPLAY_FACT_STRATUM_MOBILIZATION: event_type = 18; payload_schema = 26; break;
        default: event_type = 0; payload_schema = 0; return false;
    }
    return true;
}

} // namespace pk
