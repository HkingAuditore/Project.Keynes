// Canonical population/market diagnostics. Callers hold the complete day
// boundary; this hashes the actual formula stores even before POD ownership.
#include "economy_runtime.h"
#include "runtime_economy_pod.h"
#include "runtime_switch_registry.h"
#include <cstring>
#include <type_traits>
#include <fstream>
#include <iomanip>

namespace pk {
namespace {
struct LogicalHash {
    uint64_t value = 1469598103934665603ull;
    template<class T> void add(T item) {
        static_assert(std::is_arithmetic<T>::value || std::is_enum<T>::value,
                      "hash only explicit logical scalar fields");
        uint64_t bits = 0;
        if constexpr (std::is_floating_point<T>::value)
            std::memcpy(&bits, &item, sizeof(item));
        else bits = static_cast<uint64_t>(item);
        for (unsigned i = 0; i < 8; ++i) {
            value = (value ^ uint8_t(bits >> (i * 8))) * 1099511628211ull;
        }
    }
    template<class Range> void column(const Range &items) {
        add(items.size());
        for (size_t i = 0; i < size_t(items.size()); ++i) add(items[i]);
    }
};

template<class Range> void trace_continuation_column(const char *domain, int64_t day,
        const char *name, const Range &values) {
    const char *path = runtime_switch_value(RuntimeSwitch::PK_SIM_DAY_TRACE);
    if (path == nullptr || !*path) return;
    std::ofstream out(std::string(path) + ".continuation", std::ios::app);
    out << std::setprecision(17) << "CONT|" << domain << "|" << day << "|" << name << "|";
    for (size_t i = 0; i < size_t(values.size()); ++i) out << +values[i] << ",";
    out << "\n";
}

uint64_t population_market_hash(const RuntimeEconomyPopulationStore &population,
        const RuntimeEconomyMarketStore &market, int64_t sample_day,
        int64_t committed_day) {
    // Scope is explicitly population/market columns, not the whole economy.
    LogicalHash hash;
    hash.add(sample_day); hash.add(committed_day);
    trace_continuation_column("ECONOMY", committed_day, "sample_day", std::array<int64_t, 1>{sample_day});
    hash.column(population.cell_first_page);
    trace_continuation_column("ECONOMY", committed_day, "population.cell_first_page", population.cell_first_page);
    hash.column(population.page_next);
    trace_continuation_column("ECONOMY", committed_day, "population.page_next", population.page_next);
    hash.column(population.page_cell);
    trace_continuation_column("ECONOMY", committed_day, "population.page_cell", population.page_cell);
    hash.column(population.free_pages);
    trace_continuation_column("ECONOMY", committed_day, "population.free_pages", population.free_pages);
    hash.column(population.active);
    trace_continuation_column("ECONOMY", committed_day, "population.active", population.active);
    hash.column(population.reserved);
    trace_continuation_column("ECONOMY", committed_day, "population.reserved", population.reserved);
    hash.column(population.reservation_owner);
    trace_continuation_column("ECONOMY", committed_day, "population.reservation_owner", population.reservation_owner);
    hash.column(population.signature_id);
    trace_continuation_column("ECONOMY", committed_day, "population.signature_id", population.signature_id);
    hash.column(population.generation);
    trace_continuation_column("ECONOMY", committed_day, "population.generation", population.generation);
    hash.column(population.population);
    trace_continuation_column("ECONOMY", committed_day, "population.population", population.population);
    hash.column(population.funds);
    trace_continuation_column("ECONOMY", committed_day, "population.funds", population.funds);
    hash.column(population.epoch_income);
    trace_continuation_column("ECONOMY", committed_day, "population.epoch_income", population.epoch_income);
    hash.column(population.epoch_expense);
    trace_continuation_column("ECONOMY", committed_day, "population.epoch_expense", population.epoch_expense);
    hash.column(population.income_ema);
    trace_continuation_column("ECONOMY", committed_day, "population.income_ema", population.income_ema);
    hash.column(population.epoch_tax_paid);
    trace_continuation_column("ECONOMY", committed_day, "population.epoch_tax_paid", population.epoch_tax_paid);
    hash.column(population.epoch_subsidy_received);
    trace_continuation_column("ECONOMY", committed_day, "population.epoch_subsidy_received", population.epoch_subsidy_received);
    hash.column(population.income_baseline_ema);
    trace_continuation_column("ECONOMY", committed_day, "population.income_baseline_ema", population.income_baseline_ema);
    hash.column(population.needs_satisfaction);
    trace_continuation_column("ECONOMY", committed_day, "population.needs_satisfaction", population.needs_satisfaction);
    hash.column(population.worst_need_id);
    trace_continuation_column("ECONOMY", committed_day, "population.worst_need_id", population.worst_need_id);
    hash.column(population.composite_satisfaction);
    trace_continuation_column("ECONOMY", committed_day, "population.composite_satisfaction", population.composite_satisfaction);
    hash.column(population.satisfaction_dims);
    trace_continuation_column("ECONOMY", committed_day, "population.satisfaction_dims", population.satisfaction_dims);
    hash.column(population.worst_dimension_id);
    trace_continuation_column("ECONOMY", committed_day, "population.worst_dimension_id", population.worst_dimension_id);
    hash.column(population.flags);
    trace_continuation_column("ECONOMY", committed_day, "population.flags", population.flags);
    hash.column(population.demography_residual);
    trace_continuation_column("ECONOMY", committed_day, "population.demography_residual", population.demography_residual);
    hash.column(population.owner_employed);
    trace_continuation_column("ECONOMY", committed_day, "population.owner_employed", population.owner_employed);
    hash.column(population.employee_employed);
    trace_continuation_column("ECONOMY", committed_day, "population.employee_employed", population.employee_employed);
    market.visit_registered_columns([&](const auto &column) { hash.column(column); });
    return hash.value;
}
} // namespace

uint64_t NativeEconomyRuntime::golden_population_market_hash(
        int64_t sample_day, int64_t committed_day) const {
    return population_market_hash(population_store(), market_store(),
                                  sample_day, committed_day);
}

uint64_t RuntimeEconomyPodAuthority::golden_population_market_hash() const {
    return population_market_hash(_state.population, _state.market,
                                  _state.sample_day, _state.committed_day);
}

} // namespace pk
