#include "economy_runtime.h"

#include <algorithm>
#include <chrono>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

namespace {

// Demand left untouched this long is dropped; an open panel touches its keys
// on every refresh.
constexpr uint64_t READ_VIEW_TTL_US = 5'000'000;
// Re-evaluating unchanged demand is throttled; brand-new keys are served at the
// next committed boundary regardless.
constexpr uint64_t READ_VIEW_MIN_INTERVAL_US = 100'000;
constexpr size_t READ_VIEW_MAX_SUBSCRIPTIONS = 128;

uint64_t read_mix(uint64_t hash, uint64_t value) {
    hash ^= value + 0x9e3779b97f4a7c15ULL + (hash << 6U) + (hash >> 2U);
    return hash;
}

uint64_t steady_now_us() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

} // namespace

void NativeEconomyRuntime::ReadKey::seal() {
    uint64_t h = read_mix(0x52454144ULL, static_cast<uint64_t>(query));
    for (const int64_t value : args) h = read_mix(h, static_cast<uint64_t>(value));
    h = read_mix(h, static_cast<uint64_t>(text.hash()));
    h = read_mix(h, static_cast<uint64_t>(ints.size()));
    for (int64_t i = 0; i < ints.size(); ++i)
        h = read_mix(h, static_cast<uint64_t>(static_cast<uint32_t>(ints[i])));
    hash = h;
}

bool NativeEconomyRuntime::ReadKey::same(const ReadKey &other) const {
    if (hash != other.hash || query != other.query || args != other.args ||
        text != other.text || ints.size() != other.ints.size()) return false;
    for (int64_t i = 0; i < ints.size(); ++i)
        if (ints[i] != other.ints[i]) return false;
    return true;
}

const NativeEconomyRuntime::ReadViewEntry *NativeEconomyRuntime::ReadView::find(
        const ReadKey &key) const {
    auto it = std::lower_bound(entries.begin(), entries.end(), key.hash,
        [](const ReadViewEntry &entry, uint64_t hash) { return entry.key.hash < hash; });
    for (; it != entries.end() && it->key.hash == key.hash; ++it)
        if (it->key.same(key)) return &*it;
    return nullptr;
}

Dictionary NativeEconomyRuntime::evaluate_read_query(const ReadKey &key) {
    const auto &a = key.args;
    const auto i32 = [](int64_t value) { return static_cast<int32_t>(value); };
    switch (key.query) {
    case ReadQuery::POPULATION_CELL_SNAPSHOT:
        return population_cell_snapshot(i32(a[0]), a[1] != 0);
    case ReadQuery::POPULATION_CELL_SUMMARY:
        return population_cell_summary(i32(a[0]));
    case ReadQuery::NAMED_SETTLEMENT_SNAPSHOT:
        return named_settlement_snapshot();
    case ReadQuery::SETTLEMENT_DELTA:
        return settlement_delta(a[0]);
    case ReadQuery::MARKET_CELL_SNAPSHOT:
        return market_cell_snapshot(i32(a[0]));
    case ReadQuery::EXPLAIN_COHORT_SATISFACTION:
        return explain_cohort_satisfaction(a[0]);
    case ReadQuery::CELL_SATISFACTION_ATTRACTIVENESS:
        return cell_satisfaction_attractiveness(i32(a[0]));
    case ReadQuery::FISCAL_SNAPSHOT:
        return fiscal_snapshot(a[0]);
    case ReadQuery::COUNTRY_TRADE_SNAPSHOT:
        return country_trade_snapshot(a[0], key.text, i32(a[1]), i32(a[2]));
    case ReadQuery::TRADE_ORDERS_FOR_CELL:
        return trade_orders_for_cell(i32(a[0]), i32(a[1]), i32(a[2]));
    case ReadQuery::BUILDING_CELL_SNAPSHOT:
        return building_cell_snapshot(i32(a[0]));
    case ReadQuery::TREASURY_CONSTRUCTION_QUOTES:
        return treasury_construction_quotes(a[0], i32(a[1]), key.ints);
    case ReadQuery::CONSTRUCTION_COMMAND_RECEIPTS:
        return construction_command_receipts(a[0], i32(a[1]));
    case ReadQuery::CANAL_ROUTE_QUOTE:
        return canal_route_quote(a[0], i32(a[1]), i32(a[2]), key.ints);
    case ReadQuery::CANAL_ROUTE_QUOTE_DETAIL:
        return canal_route_quote_detail(a[0], a[1]);
    case ReadQuery::CANAL_CONSTRUCTION_RECEIPTS:
        return canal_construction_receipts(a[0], a[1], i32(a[2]));
    case ReadQuery::FAMILY_CELL_SNAPSHOT:
        return family_cell_snapshot(i32(a[0]), i32(a[1]), i32(a[2]));
    case ReadQuery::FAMILY_SNAPSHOT:
        return family_snapshot(a[0]);
    case ReadQuery::FAMILY_TRAITS:
        return family_traits(a[0]);
    case ReadQuery::FAMILY_BRANCHES:
        return family_branches(a[0], i32(a[1]), i32(a[2]));
    case ReadQuery::FAMILY_COLONIZATION_QUOTES:
        return family_colonization_quotes(a[0], i32(a[1]), a[2], i32(a[3]),
            i32(a[4]), i32(a[5]), key.bytes.ptr(), i32(key.bytes.size()),
            static_cast<uint64_t>(a[6]));
    case ReadQuery::FAMILY_COLONIZATION_QUOTE_DETAIL:
        return family_colonization_quote_detail(a[0], a[1]);
    case ReadQuery::FAMILY_EXPEDITIONS:
        return family_expeditions(a[0], i32(a[1]), i32(a[2]));
    case ReadQuery::FAMILY_EXPEDITION_SNAPSHOT:
        return family_expedition_snapshot(a[0], a[1]);
    case ReadQuery::FAMILY_COLONIZATION_RECEIPTS:
        return family_colonization_receipts(a[0], a[1], i32(a[2]));
    case ReadQuery::FAMILY_BRANCH_EFFECTS:
        return family_branch_effects(a[0], i32(a[1]));
    case ReadQuery::FAMILY_FOUNDING_OFFERS:
        return family_founding_offers(i32(a[0]), i32(a[1]));
    case ReadQuery::FAMILY_INDUSTRIES:
        return family_industries(a[0], i32(a[1]), i32(a[2]));
    case ReadQuery::FAMILY_NOTABLE_PEOPLE:
        return family_notable_people(a[0], i32(a[1]), i32(a[2]));
    case ReadQuery::NOTABLE_PERSON_SNAPSHOT:
        return notable_person_snapshot(a[0]);
    case ReadQuery::NOTABLE_PERSON_NEEDS:
        return notable_person_needs(a[0], i32(a[1]), i32(a[2]));
    case ReadQuery::BUILDING_NOTABLE_PEOPLE:
        return building_notable_people(a[0], i32(a[1]), i32(a[2]));
    case ReadQuery::COUNTRY_CLASS_OPINION_SNAPSHOT:
        return country_class_opinion_snapshot_debug();
    case ReadQuery::NONE:
        break;
    }
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "economy_read_query_unknown";
    return out;
}

void NativeEconomyRuntime::read_view_subscribe(const ReadKey &key) {
    const uint64_t now_us = steady_now_us();
    std::lock_guard<std::mutex> lock(_read_subscription_mutex);
    for (ReadSubscription &subscription : _read_subscriptions) {
        if (subscription.key.same(key)) {
            subscription.last_access_us = now_us;
            return;
        }
    }
    if (_read_subscriptions.size() >= READ_VIEW_MAX_SUBSCRIPTIONS) {
        auto oldest = std::min_element(_read_subscriptions.begin(), _read_subscriptions.end(),
            [](const ReadSubscription &lhs, const ReadSubscription &rhs) {
                return lhs.last_access_us < rhs.last_access_us;
            });
        _read_subscriptions.erase(oldest);
        _read_view_evicted_count.fetch_add(1, std::memory_order_relaxed);
    }
    _read_subscriptions.push_back(ReadSubscription{key, now_us, true});
    _read_subscription_count.store(static_cast<uint32_t>(_read_subscriptions.size()),
                                   std::memory_order_release);
}

void NativeEconomyRuntime::serve_read_view() {
    if (!_bootstrapped || _epoch_active || _fatal || _save.active || _restore.active)
        return;
    publish_building_visual_view();
    if (_read_subscription_count.load(std::memory_order_acquire) == 0) return;
    const uint64_t now_us = steady_now_us();
    const auto previous = read_view();
    const bool stale = previous == nullptr || previous->generation != _committed_generation;
    std::vector<ReadKey> keys;
    {
        std::lock_guard<std::mutex> lock(_read_subscription_mutex);
        _read_subscriptions.erase(std::remove_if(_read_subscriptions.begin(),
            _read_subscriptions.end(), [&](const ReadSubscription &subscription) {
                return now_us > subscription.last_access_us &&
                    now_us - subscription.last_access_us > READ_VIEW_TTL_US;
            }), _read_subscriptions.end());
        _read_subscription_count.store(static_cast<uint32_t>(_read_subscriptions.size()),
                                       std::memory_order_release);
        const bool has_new = std::any_of(_read_subscriptions.begin(),
            _read_subscriptions.end(), [](const ReadSubscription &s) { return s.pending; });
        const bool due = stale && now_us - _read_view_last_refresh_us >= READ_VIEW_MIN_INTERVAL_US;
        if (_read_subscriptions.empty() || (!has_new && !due)) {
            if (_read_subscriptions.empty() && previous != nullptr)
                std::atomic_store_explicit(&_read_view,
                    std::shared_ptr<const ReadView>(), std::memory_order_release);
            return;
        }
        keys.reserve(_read_subscriptions.size());
        for (ReadSubscription &subscription : _read_subscriptions) {
            keys.push_back(subscription.key);
            subscription.pending = false;
        }
    }
    const uint64_t started_us = steady_now_us();
    const bool refresh_all = stale &&
        now_us - _read_view_last_refresh_us >= READ_VIEW_MIN_INTERVAL_US;
    const int64_t day = last_committed_day();
    auto next = std::make_shared<ReadView>();
    next->entries.reserve(keys.size());
    uint64_t evaluated = 0;
    for (ReadKey &key : keys) {
        if (previous != nullptr && !refresh_all) {
            if (const ReadViewEntry *entry = previous->find(key)) {
                next->entries.push_back(*entry);
                continue;
            }
        }
        next->entries.push_back(ReadViewEntry{key, evaluate_read_query(key), day,
                                              _committed_generation});
        ++evaluated;
    }
    if (refresh_all) _read_view_last_refresh_us = now_us;
    std::sort(next->entries.begin(), next->entries.end(),
        [](const ReadViewEntry &lhs, const ReadViewEntry &rhs) {
            return lhs.key.hash < rhs.key.hash;
        });
    next->serial = ++_read_view_serial;
    // The view generation is that of its oldest entries, so a serve that only
    // added keys keeps the older ones due for refresh.
    next->generation = refresh_all || previous == nullptr
        ? _committed_generation : previous->generation;
    next->committed_day = refresh_all || previous == nullptr
        ? day : previous->committed_day;
    std::atomic_store_explicit(&_read_view, std::shared_ptr<const ReadView>(std::move(next)),
                               std::memory_order_release);
    const uint64_t spent_us = steady_now_us() - started_us;
    _read_view_serve_count.fetch_add(1, std::memory_order_relaxed);
    _read_view_eval_count.fetch_add(evaluated, std::memory_order_relaxed);
    _read_view_serve_us_total.fetch_add(spent_us, std::memory_order_relaxed);
    uint64_t max_us = _read_view_serve_us_max.load(std::memory_order_relaxed);
    while (spent_us > max_us && !_read_view_serve_us_max.compare_exchange_weak(
               max_us, spent_us, std::memory_order_relaxed)) {}
}

void NativeEconomyRuntime::publish_building_visual_view() {
    const auto current = building_visual_view();
    if (current == nullptr || current->generation != _building_visual_generation ||
        current->cell_count != _cell_count.get()) {
        auto next = std::make_shared<BuildingVisualView>();
        next->generation = _building_visual_generation;
        next->cell_count = _cell_count.get();
        next->cell_offsets = _building_visual_cell_offsets;
        next->type_indices = _building_visual_type_indices;
        next->counts = _building_visual_counts;
        std::atomic_store_explicit(&_building_visual_view,
            std::shared_ptr<const BuildingVisualView>(std::move(next)),
            std::memory_order_release);
    }
    if (_building_visual_dirty_cells.empty()) return;
    std::lock_guard<std::mutex> lock(_building_visual_outbox_mutex);
    _building_visual_outbox.insert(_building_visual_outbox.end(),
        _building_visual_dirty_cells.begin(), _building_visual_dirty_cells.end());
    std::sort(_building_visual_outbox.begin(), _building_visual_outbox.end());
    _building_visual_outbox.erase(std::unique(_building_visual_outbox.begin(),
        _building_visual_outbox.end()), _building_visual_outbox.end());
    _building_visual_dirty_cells.clear();
}

Dictionary NativeEconomyRuntime::building_visual_rows(
        const BuildingVisualView &view, const PackedInt32Array &requested_cells) {
    Dictionary out;
    out["ok"] = false;
    out["building_generation"] = static_cast<int64_t>(view.generation);
    std::vector<int32_t> cells;
    cells.reserve(static_cast<size_t>(requested_cells.size()));
    for (int64_t i = 0; i < requested_cells.size(); ++i) {
        const int32_t cell = requested_cells[i];
        if (cell < 0 || cell >= view.cell_count) {
            out["reason"] = "cell_out_of_range";
            out["invalid_cell"] = cell;
            return out;
        }
        cells.push_back(cell);
    }
    std::sort(cells.begin(), cells.end());
    cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
    const bool has_rows = view.cell_offsets.size() ==
        static_cast<size_t>(view.cell_count) + 1U;
    PackedInt32Array cell_indices;
    PackedInt32Array type_offsets;
    PackedInt32Array type_indices;
    PackedInt64Array counts;
    type_offsets.push_back(0);
    for (const int32_t cell : cells) {
        cell_indices.push_back(cell);
        const int32_t begin = has_rows ? view.cell_offsets[static_cast<size_t>(cell)] : 0;
        const int32_t end = has_rows ? view.cell_offsets[static_cast<size_t>(cell + 1)] : 0;
        for (int32_t row = begin; row < end; ++row) {
            type_indices.push_back(view.type_indices[static_cast<size_t>(row)]);
            counts.push_back(view.counts[static_cast<size_t>(row)]);
        }
        type_offsets.push_back(type_indices.size());
    }
    out["ok"] = true;
    out["cell_indices"] = cell_indices;
    out["type_offsets"] = type_offsets;
    out["type_indices"] = type_indices;
    out["counts"] = counts;
    return out;
}

PackedInt32Array NativeEconomyRuntime::drain_building_visual_outbox() {
    std::lock_guard<std::mutex> lock(_building_visual_outbox_mutex);
    PackedInt32Array cells;
    cells.resize(static_cast<int64_t>(_building_visual_outbox.size()));
    for (int64_t i = 0; i < cells.size(); ++i)
        cells.set(i, _building_visual_outbox[static_cast<size_t>(i)]);
    _building_visual_outbox.clear();
    return cells;
}

void NativeEconomyRuntime::read_view_reset() {
    {
        std::lock_guard<std::mutex> lock(_read_subscription_mutex);
        _read_subscriptions.clear();
        _read_subscription_count.store(0, std::memory_order_release);
    }
    {
        std::lock_guard<std::mutex> lock(_building_visual_outbox_mutex);
        _building_visual_outbox.clear();
    }
    std::atomic_store_explicit(&_read_view, std::shared_ptr<const ReadView>(),
                               std::memory_order_release);
    std::atomic_store_explicit(&_building_visual_view,
        std::shared_ptr<const BuildingVisualView>(), std::memory_order_release);
    _read_view_last_refresh_us = 0;
}

Dictionary NativeEconomyRuntime::read_view_status() const {
    Dictionary out;
    const auto view = read_view();
    const auto visual = building_visual_view();
    out["subscriptions"] = static_cast<int64_t>(
        _read_subscription_count.load(std::memory_order_acquire));
    out["view_entries"] = view ? static_cast<int64_t>(view->entries.size()) : int64_t{0};
    out["view_serial"] = view ? static_cast<int64_t>(view->serial) : int64_t{0};
    out["view_generation"] = view ? static_cast<int64_t>(view->generation) : int64_t{0};
    out["view_committed_day"] = view ? view->committed_day : int64_t{-1};
    out["building_visual_generation"] = visual
        ? static_cast<int64_t>(visual->generation) : int64_t{-1};
    out["serve_count"] = static_cast<int64_t>(
        _read_view_serve_count.load(std::memory_order_relaxed));
    out["eval_count"] = static_cast<int64_t>(
        _read_view_eval_count.load(std::memory_order_relaxed));
    out["serve_us_total"] = static_cast<int64_t>(
        _read_view_serve_us_total.load(std::memory_order_relaxed));
    out["serve_us_max"] = static_cast<int64_t>(
        _read_view_serve_us_max.load(std::memory_order_relaxed));
    out["evicted_count"] = static_cast<int64_t>(
        _read_view_evicted_count.load(std::memory_order_relaxed));
    return out;
}

} // namespace pk
