#pragma once

#include <string>

namespace pk {

// Synthetic native fixtures share the existing runtime friendship. Keeping
// their entry points here avoids exposing test declarations to every consumer
// of the runtime header.
struct EconomyTargetSelectorTests {
    static bool run(std::string &error);
    static bool run_country_epoch_cache(std::string &error);
    static bool run_building_chain_metrics(std::string &error);
    static bool run_building_investment_review(std::string &error);
    static bool run_golden_population_market(std::string &error);
    static bool run_owned_stock_audit(std::string &error);
    static bool run_producer_continuation(std::string &error);
};

} // namespace pk
