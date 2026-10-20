#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

// Committed observations only. Money uses Economy's 1/10000 unit; ratios Q16.
enum class AnnualMetric : uint32_t {
    POPULATION, EMPLOYED, FUNDS, BUILDINGS, SUSPENDED, PENDING_BUILDINGS,
    SETTLEMENTS, TERRITORY, SETTLEMENT_WEIGHT, TECHNOLOGIES, TREASURY,
    SATISFACTION, SURVIVAL, UTILIZATION, ACTIVE_BUILDINGS, JOB_CAPACITY,
    REVENUE, INPUT_COST, WAGES, WAGES_DUE, MAINTENANCE, PROFIT, GDP,
    HOUSEHOLD_INCOME, HOUSEHOLD_EXPENSE, BIRTHS, DEATHS,
    BUSINESS_TAX, INCOME_TAX, CONSUMPTION_TAX, IMPORT_TAX, EXPORT_TAX,
    SUBSIDIES, PRODUCER_SUPPORT, TRADE_VALUE, TRADE_QUANTITY, TRADE_ORDERS,
    OUTPUT, SOLD, DISCARDED, CLIMATE_LOSS, RESEARCH_PURCHASED,
    RESEARCH_CONSUMED, FAMILIES, PERSONS, BUILT, REMOVED,
    SETTLEMENTS_FOUNDED, SETTLEMENTS_LOST, SETTLEMENTS_UPGRADED,
    SETTLEMENTS_DOWNGRADED, TECHNOLOGY_EQUIVALENTS, RESOURCE_EXTRACTED,
    COUNT
};
constexpr size_t ANNUAL_METRIC_COUNT = static_cast<size_t>(AnnualMetric::COUNT);
constexpr int64_t ANNUAL_Q16 = 65536;
constexpr uint32_t ANNUAL_REWARD_PRODUCER = 0x415250; // reserved: ARP
const char *annual_metric_key(size_t index);
bool annual_metric_is_flow(size_t index);

struct AnnualBreakdown {
    int32_t id = -1;
    int64_t count = 0, value = 0, secondary = 0;
};
struct AnnualSettlement {
    int32_t cell = -1, tier = 0;
    int64_t population = 0, buildings = 0, gdp = 0;
};
struct AnnualEconomyFacts {
    uint64_t country_handle = 0, revision = 0;
    int64_t day = -1;
    std::array<int64_t, ANNUAL_METRIC_COUNT> values{};
    std::array<int64_t, 8> tiers{};
    std::array<int64_t, 8> satisfaction_dimensions{};
    std::array<int64_t, 8> dimension_population{};
    std::vector<AnnualBreakdown> industries, professions, goods, resources;
    std::vector<AnnualSettlement> settlements;
};
struct AnnualCountryFacts {
    uint64_t handle = 0;
    std::string name;
    int64_t treasury = 0, territory = 0, research_purchased = 0,
        research_consumed = 0;
    int32_t era = 0;
    std::vector<int32_t> technologies;
};
struct AnnualDevelopmentProfile {
    uint32_t version = 1;
    std::array<int32_t, 7> grade_thresholds{{9400,8600,7500,6000,4500,3000,0}};
    std::array<int32_t, 7> reward_draws{{6,4,3,2,1,0,0}};
    std::array<int32_t, 4> quality_weights{{2000,2000,1500,1500}};
    std::array<int32_t, 4> quality_targets{{62259,64225,62259,55706}};
    std::array<int32_t, 6> progress_weights{{800,600,500,300,300,500}};
    std::array<int32_t, 6> progress_targets{{6554,3277,3277,6554,3277,131072}};
    int32_t active_target = 62259;
    int64_t offer_cost = 393216, max_offer_cost = INT64_MAX;
    int64_t offer_growth_percent = 120;
    std::vector<int32_t> technology_equivalents_q16;
    std::vector<int32_t> technology_eras;
    std::vector<int32_t> era_milestones;
    bool valid() const;
};
struct AnnualDevelopmentReport {
    uint64_t id = 0, country_handle = 0;
    uint32_t scoring_version = 1;
    int64_t year = 0, start_day = 0, end_day = 0;
    int64_t reward_q16 = 0;
    uint64_t reward_sequence = 0;
    int32_t score_bp = 0, grade = 6, cap = -1, era = 0;
    uint8_t complete = 0, reward_settled = 0, presented = 0;
    std::string country_name;
    AnnualEconomyFacts opening, closing;
    std::array<int64_t, ANNUAL_METRIC_COUNT> totals{};
    std::array<int64_t, 4> quality_average{};
    std::array<int32_t, 10> score_parts{};
    std::array<int64_t, 12> monthly_gdp{}, monthly_population{};
    std::vector<int32_t> new_technologies;
    std::vector<AnnualBreakdown> industry_totals, resource_totals;
    int64_t first_gdp = 0, last_gdp = 0, first_people_days = 0,
        last_people_days = 0, first_days = 0, last_days = 0;
};

// NativeSimulationHost owns this reducer. Its mutex is held by the host, never
// by Economy while invoking callbacks. No Godot, clock timers or UI sampling.
class AnnualDevelopmentLedger {
public:
    bool configure(uint64_t handle, int64_t days_per_year, int64_t initial_day,
                   const AnnualDevelopmentProfile &profile, std::string &error);
    bool configured() const { return _handle != 0; }
    uint64_t country_handle() const { return _handle; }
    int64_t days_per_year() const { return _length; }
    int64_t last_day() const { return _last_day; }
    uint64_t revision() const { return _revision; }
    uint64_t ready_report_id() const;
    bool has_pending_reward() const;
    void observe_economy(const AnnualEconomyFacts &facts);
    void seed(const AnnualEconomyFacts &facts, const AnnualCountryFacts &country);
    void commit_day(int64_t day, const AnnualCountryFacts &country,
                    uint64_t draw_sequence);
    const std::vector<AnnualDevelopmentReport> &reports() const { return _reports; }
    const AnnualDevelopmentReport &current() const { return _current; }
    AnnualDevelopmentReport *pending_reward();
    bool settle_reward(uint64_t sequence);
    bool mark_presented(uint64_t id);
    void encode(std::vector<uint8_t> &bytes) const;
    bool restore(const uint8_t *bytes, size_t size, std::string &error);
    static void evaluate(AnnualDevelopmentReport &report,
                         const AnnualDevelopmentReport *previous,
                         const AnnualDevelopmentProfile &profile,
                         uint64_t draw_sequence);
private:
    uint64_t _handle = 0, _revision = 0, _economy_revision = 0;
    int64_t _length = 365, _last_day = -1, _tracked_since = 0;
    AnnualDevelopmentProfile _profile;
    AnnualEconomyFacts _latest;
    AnnualCountryFacts _country;
    AnnualDevelopmentReport _current;
    std::array<int64_t, 4> _quality_sum{};
    int64_t _population_days = 0, _days = 0;
    std::array<int64_t, 8> _dimension_sum{}, _dimension_days{};
    std::vector<AnnualDevelopmentReport> _reports;
    mutable size_t _ready_cursor = 0, _reward_cursor = 0;
    void begin_year(int64_t year);
    void finish_year(uint64_t draw_sequence);
};
bool annual_development_self_test(std::string &error);

} // namespace pk
