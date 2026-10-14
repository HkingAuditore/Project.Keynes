#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_hash.h"
#include "runtime_economy_family_side_tables.h"

#include <algorithm>
#include <limits>
#include <tuple>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

std::shared_ptr<const CountryAiEconomyDigest> NativeEconomyRuntime::country_ai_digest() const {
    std::lock_guard<std::mutex> lock(_country_ai->mutex);
    return _country_ai->digest;
}

void NativeEconomyRuntime::set_country_ai_family_preferences(
        std::vector<CountryAiFamilyPreferenceRow> rows) {
    std::sort(rows.begin(), rows.end(), [](const auto &l, const auto &r) {
        return l.country_handle < r.country_handle;
    });
    auto frozen = rows.empty() ? nullptr
        : std::make_shared<const std::vector<CountryAiFamilyPreferenceRow>>(std::move(rows));
    std::lock_guard<std::mutex> lock(_country_ai->mutex);
    _country_ai->family_preferences = std::move(frozen);
}

void NativeEconomyRuntime::queue_country_ai_colonization(
        std::vector<CountryAiColonizationIntent> intents) {
    if (intents.empty()) return;
    std::lock_guard<std::mutex> lock(_country_ai->mutex);
    for (CountryAiColonizationIntent &intent : intents)
        _country_ai->colonization_inbox.push_back(std::move(intent));
}

void NativeEconomyRuntime::export_country_ai_pending(
        std::vector<CountryAiColonizationIntent> &intents,
        std::vector<CountryAiColonizationStat> &stats,
        int64_t &receipt_cursor) const {
    std::lock_guard<std::mutex> lock(_country_ai->mutex);
    intents = _country_ai->colonization_inbox;
    stats = _country_ai->colonization_stats;
    receipt_cursor = _country_ai->receipt_cursor;
}

void NativeEconomyRuntime::import_country_ai_pending(
        std::vector<CountryAiColonizationIntent> intents,
        std::vector<CountryAiColonizationStat> stats,
        int64_t receipt_cursor) {
    std::sort(stats.begin(), stats.end(), [](const auto &l, const auto &r) {
        return l.country_handle < r.country_handle;
    });
    std::lock_guard<std::mutex> lock(_country_ai->mutex);
    _country_ai->colonization_inbox = std::move(intents);
    _country_ai->colonization_stats = std::move(stats);
    _country_ai->receipt_cursor = receipt_cursor;
}

namespace {

// Caller holds the CountryAiShared mutex. `started` counts queued commands;
// an execution rejection moves one queued command into `failures`.
void add_colonization_stat(std::vector<NativeEconomyRuntime::CountryAiColonizationStat> &stats,
                           uint64_t handle, int32_t started, int32_t failures) {
    auto it = std::lower_bound(stats.begin(), stats.end(), handle,
        [](const auto &s, uint64_t h) { return s.country_handle < h; });
    if (it == stats.end() || it->country_handle != handle)
        it = stats.insert(it, NativeEconomyRuntime::CountryAiColonizationStat{handle, 0, 0});
    it->started = static_cast<uint32_t>(std::max<int64_t>(0, int64_t{it->started} + started));
    it->failures += static_cast<uint32_t>(std::max(0, failures));
}

} // namespace

void NativeEconomyRuntime::publish_country_ai_digest() {
    if (_epoch_country_count <= 0 ||
        _epoch_country_handles.size() != static_cast<size_t>(_epoch_country_count))
        return;
    {
        std::lock_guard<std::mutex> lock(_country_ai->mutex);
        int64_t cursor = _country_ai->receipt_cursor;
        for (const ColonizationReceipt &receipt : _colonization_receipts) {
            if (receipt.receipt_id <= _country_ai->receipt_cursor) continue;
            cursor = std::max(cursor, receipt.receipt_id);
            if (receipt.kind == 7 && receipt.country_handle != 0 &&
                (receipt.sequence & COUNTRY_AI_COLONIZATION_SEQUENCE_TAG) != 0)
                add_colonization_stat(_country_ai->colonization_stats,
                                      receipt.country_handle, -1, 1);
        }
        _country_ai->receipt_cursor = cursor;
    }
    const size_t countries = static_cast<size_t>(_epoch_country_count);
    struct Acc {
        int64_t population = 0;
        int64_t satisfaction_weighted = 0;
        int64_t essentials_weighted = 0;
        int64_t tax_paid = 0;
        int64_t subsidy = 0;
        int64_t income = 0;
        int64_t expense = 0;
        int32_t families = 0;
        int32_t expeditions = 0;
        int64_t k_eff = 0;
        int64_t k_geo = 0;
        int64_t load_weighted = 0;
        int64_t hungry = 0;
    };
    std::vector<Acc> acc(countries);
    const auto country_of_cell = [&](int32_t cell) -> int32_t {
        if (cell < 0 || static_cast<size_t>(cell) >= _epoch_cell_country.size()) return -1;
        const int32_t slot = _epoch_cell_country[static_cast<size_t>(cell)];
        return slot >= 0 && static_cast<size_t>(slot) < countries ? slot : -1;
    };
    const RuntimeEconomyPopulationStore &pop = population_store();
    const int32_t slots = static_cast<int32_t>(pop.active.size());
    std::vector<int64_t> cell_people(_epoch_cell_country.size(), 0);
    for (int32_t slot = 0; slot < slots; ++slot) {
        if (pop.active[slot] == 0) continue;
        const int64_t people = std::max<int64_t>(0, pop.population[slot]);
        if (people <= 0) continue;
        const int32_t cell = pop.page_cell[slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE];
        const int32_t country = country_of_cell(cell);
        if (country < 0) continue;
        cell_people[static_cast<size_t>(cell)] += people;
        Acc &a = acc[static_cast<size_t>(country)];
        a.population += people;
        a.satisfaction_weighted += people * static_cast<int64_t>(pop.composite_satisfaction[slot]);
        a.essentials_weighted += people * static_cast<int64_t>(pop.needs_satisfaction[slot]);
        if (static_cast<int32_t>(pop.needs_satisfaction[slot]) < COUNTRY_AI_HUNGRY_ESSENTIALS_Q16)
            a.hungry += people;
        const int64_t days = cell_elapsed_days(cell);
        a.tax_paid += pop.epoch_tax_paid[slot] / days;
        a.subsidy += pop.epoch_subsidy_received[slot] / days;
        a.income += pop.epoch_income[slot] / days;
        a.expense += pop.epoch_expense[slot] / days;
    }
    for (size_t cell = 0; cell < cell_people.size(); ++cell) {
        const int32_t country = country_of_cell(static_cast<int32_t>(cell));
        if (country < 0) continue;
        Acc &a = acc[static_cast<size_t>(country)];
        const int64_t k_eff = cell < _cell_carrying_k_eff.size() ? _cell_carrying_k_eff[cell] : 0;
        a.k_eff += std::max<int64_t>(0, k_eff);
        if (cell < _cell_carrying_k_geo.size()) a.k_geo += std::max<int64_t>(0, _cell_carrying_k_geo[cell]);
        const int64_t people = cell_people[cell];
        if (people <= 0) continue;
        const int64_t load = k_eff > 0
            ? std::min<int64_t>(Q16_ONE * 4, people * Q16_ONE / k_eff) : Q16_ONE * 4;
        a.load_weighted += people * load;
    }
    const auto &families = families_store();
    for (size_t f = 0; f < families.active.size(); ++f) {
        if (families.active[f] == 0) continue;
        const int32_t country = country_of_cell(families.home_cell[f]);
        if (country >= 0) ++acc[static_cast<size_t>(country)].families;
    }
    const auto &expeditions = family_expeditions_store();
    std::vector<std::pair<uint64_t, int32_t>> expedition_counts;
    for (size_t e = 0; e < expeditions.active.size(); ++e) {
        if (expeditions.active[e] == 0) continue;
        const uint8_t state = expeditions.state[e];
        if (state != EXPEDITION_OUTBOUND && state != EXPEDITION_PREPARING &&
            state != EXPEDITION_SETTLING) continue;
        const uint64_t handle = expeditions.country_handle[e];
        for (size_t c = 0; c < countries; ++c)
            if (_epoch_country_handles[c] == handle) { ++acc[c].expeditions; break; }
    }
    auto digest = std::make_shared<CountryAiEconomyDigest>();
    digest->commit_day = _current_day.get();
    digest->rows.reserve(countries);
    std::vector<CountryAiColonizationStat> stats;
    {
        std::lock_guard<std::mutex> lock(_country_ai->mutex);
        stats = _country_ai->colonization_stats;
        digest->revision = ++_country_ai->digest_revision;
    }
    for (size_t c = 0; c < countries; ++c) {
        const uint64_t handle = _epoch_country_handles[c];
        if (handle == 0) continue;
        const Acc &a = acc[c];
        CountryAiEconomyRow row;
        row.country_handle = handle;
        row.population = a.population;
        // composite/needs satisfaction columns are Q16 stored as uint16.
        row.satisfaction_q16 = a.population > 0
            ? static_cast<int32_t>(std::min<int64_t>(Q16_ONE, a.satisfaction_weighted / a.population)) : 0;
        row.essentials_q16 = a.population > 0
            ? static_cast<int32_t>(std::min<int64_t>(Q16_ONE, a.essentials_weighted / a.population)) : 0;
        row.tax_paid = a.tax_paid;
        row.subsidy_received = a.subsidy;
        row.income = a.income;
        row.expense = a.expense;
        row.family_count = a.families;
        row.expeditions_active = a.expeditions;
        row.carrying_k_eff = a.k_eff;
        row.carrying_k_geo = a.k_geo;
        row.carrying_load_q16 = a.population > 0
            ? static_cast<int32_t>(a.load_weighted / a.population) : 0;
        row.hungry_share_q16 = a.population > 0
            ? static_cast<int32_t>(a.hungry * Q16_ONE / a.population) : 0;
        const auto it = std::lower_bound(stats.begin(), stats.end(), handle,
            [](const CountryAiColonizationStat &s, uint64_t h) { return s.country_handle < h; });
        if (it != stats.end() && it->country_handle == handle) {
            row.ai_colonization_failures = it->failures;
            row.ai_colonization_started = it->started;
        }
        digest->rows.push_back(row);
    }
    std::sort(digest->rows.begin(), digest->rows.end(), [](const auto &l, const auto &r) {
        return l.country_handle < r.country_handle;
    });
    digest->food_building_types.assign(_building_types.size(), 0);
    for (size_t t = 0; t < _building_types.size(); ++t) {
        const BuildingType &type = _building_types[t];
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[static_cast<size_t>(type.output_begin + i)].good_id;
            if (good >= 0 && static_cast<size_t>(good) < _survival_food_good_mask.size() &&
                _survival_food_good_mask[static_cast<size_t>(good)] != 0) {
                digest->food_building_types[t] = 1;
                break;
            }
        }
    }
    digest->cell_population = std::move(cell_people);
    std::lock_guard<std::mutex> lock(_country_ai->mutex);
    _country_ai->digest = std::move(digest);
}

void NativeEconomyRuntime::process_country_ai_colonization_intents(int64_t day_index) {
    std::vector<CountryAiColonizationIntent> intents;
    {
        std::lock_guard<std::mutex> lock(_country_ai->mutex);
        if (_country_ai->colonization_inbox.empty()) return;
        intents.swap(_country_ai->colonization_inbox);
    }
    std::stable_sort(intents.begin(), intents.end(), [](const auto &l, const auto &r) {
        return std::tie(l.day, l.country_handle, l.target_cell) <
               std::tie(r.day, r.country_handle, r.target_cell);
    });
    std::vector<CountryAiColonizationStat> deltas;
    const auto note = [&](uint64_t handle, bool started) {
        for (CountryAiColonizationStat &s : deltas) {
            if (s.country_handle != handle) continue;
            started ? ++s.started : ++s.failures;
            return;
        }
        CountryAiColonizationStat s;
        s.country_handle = handle;
        started ? ++s.started : ++s.failures;
        deltas.push_back(s);
    };
    const int32_t cells = _cell_count.get();
    std::vector<uint8_t> visible;
    for (const CountryAiColonizationIntent &intent : intents) {
        if (intent.target_cell < 0 || intent.target_cell >= cells ||
            _country_runtime == nullptr ||
            !_country_runtime->valid_handle(static_cast<int64_t>(intent.country_handle))) {
            note(intent.country_handle, false);
            continue;
        }
        visible.assign(static_cast<size_t>(cells), 0);
        for (const int32_t cell : intent.visible_cells)
            if (cell >= 0 && cell < cells) visible[static_cast<size_t>(cell)] = 1;
        // Vision revision is the intent day so quote tokens are reproducible.
        const Dictionary quotes = family_colonization_quotes(
            static_cast<int64_t>(intent.country_handle), intent.target_cell, 0, -1, 0, 8,
            visible.data(), cells, static_cast<uint64_t>(intent.day));
        if (!static_cast<bool>(quotes.get("ok", false)) ||
            static_cast<int64_t>(quotes.get("total", 0)) <= 0) {
            note(intent.country_handle, false);
            continue;
        }
        const PackedInt64Array family_handles = quotes.get("family_handles", PackedInt64Array());
        const PackedInt32Array sources = quotes.get("source_cells", PackedInt32Array());
        const PackedInt64Array maximums = quotes.get("maximum_populations", PackedInt64Array());
        const PackedInt32Array costs = quotes.get("route_costs", PackedInt32Array());
        const PackedInt64Array tokens = quotes.get("quote_tokens", PackedInt64Array());
        // Quotes are sorted by route cost, which prefers the nearest (often
        // tiniest) branch. Pick the largest viable party so AI colonies can
        // staff kit buildings instead of founding three-person dead ends.
        const bool reinforce_target =
            _country_runtime->country_handle_for_cell(intent.target_cell) ==
            static_cast<int64_t>(intent.country_handle);
        int64_t best_i = -1;
        int64_t best_population = -1;
        int32_t best_cost = std::numeric_limits<int32_t>::max();
        for (int64_t i = 0; i < family_handles.size(); ++i) {
            const int64_t maximum = maximums[i];
            if (maximum < intent.min_population) continue;
            const int64_t share = maximum * std::max(0, intent.population_share_bp) / 10000;
            const int64_t population = std::clamp<int64_t>(share, intent.min_population, maximum);
            if (pending_family_expedition_target_taken(intent.country_handle, intent.target_cell) ||
                family_population_in_cell(static_cast<uint64_t>(family_handles[i]), sources[i]) <=
                    population)
                continue;
            // Relocate must not strip a healthy source city below the AI floor;
            // otherwise reinforce just moves the dead-end problem around.
            if (reinforce_target) {
                const int32_t src = sources[i];
                const int64_t source_cell_pop =
                    src >= 0 && static_cast<size_t>(src) < _cell_population_total.size()
                        ? _cell_population_total[static_cast<size_t>(src)] : 0;
                if (source_cell_pop - population < intent.min_population) continue;
            }
            const int32_t cost = i < costs.size() ? costs[i] : std::numeric_limits<int32_t>::max();
            if (best_i >= 0 && (population < best_population ||
                    (population == best_population && cost >= best_cost)))
                continue;
            best_i = i;
            best_population = population;
            best_cost = cost;
        }
        bool queued = false;
        if (best_i >= 0) {
            Command command;
            command.opcode = COMMAND_START_FAMILY_EXPEDITION;
            command.effective_day = day_index;
            command.sequence = COUNTRY_AI_COLONIZATION_SEQUENCE_TAG |
                static_cast<int64_t>(intent.sequence &
                    static_cast<uint64_t>(COUNTRY_AI_COLONIZATION_SEQUENCE_TAG - 1));
            command.target_handle = static_cast<uint64_t>(family_handles[best_i]);
            command.i32_0 = sources[best_i];
            command.i32_1 = intent.target_cell;
            command.i64_0 = best_population;
            command.i64_1 = tokens[best_i];
            command.submit_order = _next_submit_order++;
            _pending_commands.push_back(command);
            queued = true;
        }
        note(intent.country_handle, queued);
    }
    if (deltas.empty()) return;
    std::lock_guard<std::mutex> lock(_country_ai->mutex);
    for (const CountryAiColonizationStat &d : deltas)
        add_colonization_stat(_country_ai->colonization_stats, d.country_handle,
                              static_cast<int32_t>(d.started), static_cast<int32_t>(d.failures));
}

int32_t NativeEconomyRuntime::family_founding_ai_choice(const FamilyFoundingOffer &offer) const {
    if (offer.candidates.empty() || offer.cell < 0 ||
        static_cast<size_t>(offer.cell) >= _epoch_cell_country.size())
        return -1;
    const int32_t slot = _epoch_cell_country[static_cast<size_t>(offer.cell)];
    if (slot < 0 || static_cast<size_t>(slot) >= _epoch_country_handles.size()) return -1;
    std::shared_ptr<const std::vector<CountryAiFamilyPreferenceRow>> prefs;
    {
        std::lock_guard<std::mutex> lock(_country_ai->mutex);
        prefs = _country_ai->family_preferences;
    }
    if (!prefs) return -1;
    const uint64_t handle = _epoch_country_handles[static_cast<size_t>(slot)];
    const auto it = std::lower_bound(prefs->begin(), prefs->end(), handle,
        [](const CountryAiFamilyPreferenceRow &r, uint64_t h) { return r.country_handle < h; });
    if (it == prefs->end() || it->country_handle != handle) return -1;
    const auto &w = it->weights;
    int64_t max_revenue = 1;
    int64_t max_founders = 1;
    struct Facts { int64_t margin = 0; int64_t revenue = 0; int64_t founders = 0; };
    std::vector<Facts> facts(offer.candidates.size());
    for (size_t i = 0; i < offer.candidates.size(); ++i) {
        const FamilyFoundingCandidate &c = offer.candidates[i];
        const int32_t group = building_index_for_handle(c.building_handle);
        if (group >= 0) {
            const auto row = building_at(static_cast<size_t>(group));
            facts[i].margin = std::clamp<int64_t>(row.realized_profit_margin_q16, -Q16_ONE, Q16_ONE);
            facts[i].revenue = std::max<int64_t>(0, row.last_revenue);
        }
        facts[i].founders = std::max<int64_t>(0, c.founders);
        max_revenue = std::max(max_revenue, facts[i].revenue);
        max_founders = std::max(max_founders, facts[i].founders);
    }
    int32_t best = -1;
    int64_t best_score = 0;
    for (size_t i = 0; i < offer.candidates.size(); ++i) {
        uint64_t hash = 1469598103934665603ULL;
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
        hash = trace_hash_mix(hash, 0x4149464fULL); // "AIFO"
        hash = trace_hash_mix(hash, static_cast<uint64_t>(offer.offer_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(i));
        const int64_t jitter = static_cast<int64_t>(hash % static_cast<uint64_t>(Q16_ONE));
        const int64_t revenue_q16 = facts[i].revenue * Q16_ONE / max_revenue;
        const int64_t founders_q16 = facts[i].founders * Q16_ONE / max_founders;
        const int64_t score = (static_cast<int64_t>(w[0]) * facts[i].margin +
                               static_cast<int64_t>(w[1]) * revenue_q16 +
                               static_cast<int64_t>(w[2]) * founders_q16 +
                               static_cast<int64_t>(w[3]) * jitter) / 10000;
        if (best < 0 || score > best_score) {
            best = static_cast<int32_t>(i);
            best_score = score;
        }
    }
    return best;
}

} // namespace pk
