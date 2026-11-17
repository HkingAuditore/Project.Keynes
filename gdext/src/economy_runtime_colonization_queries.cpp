#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include <algorithm>
#include <chrono>
#include <functional>
#include <numeric>
#include <tuple>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
#include "economy_runtime_colonization_internal.h"

void NativeEconomyRuntime::fill_colonization_query_flags(Dictionary &out) const {
    const bool boundary_busy = _epoch_active || _save.active || _restore.active;
    out["busy"] = boundary_busy;
    out["fatal"] = _fatal;
    out["committed"] = !_epoch_active && !_fatal && !_save.active && !_restore.active;
    out["nonbinding"] = _epoch_active;
    out["snapshot_day"] = _current_day.get();
}

Dictionary NativeEconomyRuntime::family_colonization_quotes(
        int64_t country_handle_value, int32_t target_cell,
        int64_t family_filter_value, int32_t source_filter, int32_t offset,
        int32_t limit, const uint8_t *visible, int32_t visible_count,
        uint64_t vision_revision) {
    const auto started = std::chrono::steady_clock::now();
    Dictionary out;
    const uint64_t country_handle = static_cast<uint64_t>(country_handle_value);
    const uint64_t family_filter = static_cast<uint64_t>(family_filter_value);
    // Quotes are a nonbinding UI preview. Frozen cycles still expose the current
    // live/frozen membership so the planner is never blank; start/cancel queue
    // into pending when the epoch is open.
    if (!_bootstrapped || _fatal || _restore.active || _country_runtime == nullptr ||
        !country_reads().valid_handle(country_handle_value)) {
        out["ok"] = false;
        out["code"] = _restore.active ? "economy_busy_retry" :
            _fatal ? "economy_paused" :
            !_bootstrapped ? "economy_not_available" :
            "colonization_country_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    std::vector<int32_t> ignored_route, ignored_costs;
    int32_t ignored_total = 0;
    std::string route_error;
    // This validates target/topology before the one reverse search below.
    if (target_cell < 0 || target_cell >= _cell_count.get()) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    if (visible == nullptr || visible_count != _cell_count.get()) {
        out["ok"] = false;
        out["code"] = "colonization_visibility_unavailable";
        fill_colonization_query_flags(out);
        return out;
    }
    if (visible[target_cell] == 0) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    if (_trade_topology.passable.size() != static_cast<size_t>(_cell_count.get()) ||
        !_trade_topology.ready) {
        out["ok"] = false;
        out["code"] = "colonization_topology_not_ready";
        fill_colonization_query_flags(out);
        return out;
    }
    if (!colonization_target_owner_allowed(country_handle, target_cell)) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    // Frozen cycles may leave the live passable LUT mid-rebuild while quotes
    // are only a nonbinding preview. Keep the list readable; start still
    // revalidates the committed route.
    if (_trade_topology.passable[target_cell] == 0 && !_epoch_active) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    CountryReadView::Snapshot country_snapshot;
    if (!country_reads().copy_economy_snapshot(country_snapshot)) {
        out["ok"] = false; out["code"] = "colonization_country_snapshot_unavailable";
        fill_colonization_query_flags(out);
        return out;
    }
    const int32_t country_slot = country_reads().country_slot_for_cell(
        source_filter >= 0 ? source_filter : target_cell);
    (void)country_slot;
    const uint64_t vision_hash = trace_hash_mix(
        colonization_visibility_hash(visible, visible_count), vision_revision);

    // Run one bounded reverse Dijkstra and retain all reached local source
    // cells. This is the same scratch as single-route validation and never
    // clears a map-sized array.
    if (_colonization_distance.size() != static_cast<size_t>(_cell_count.get())) {
        _colonization_distance.resize(_cell_count.get());
        _colonization_distance_stamp.assign(_cell_count.get(), 0);
        _colonization_parent.resize(_cell_count.get());
        _colonization_parent_stamp.assign(_cell_count.get(), 0);
    }
    if (++_colonization_search_stamp == 0) {
        std::fill(_colonization_distance_stamp.begin(),
                  _colonization_distance_stamp.end(), 0);
        std::fill(_colonization_parent_stamp.begin(),
                  _colonization_parent_stamp.end(), 0);
        _colonization_search_stamp = 1;
    }
    const uint32_t stamp = _colonization_search_stamp;
    const uint8_t cap = water_capability_for_handle(country_handle, false);
    _colonization_route_heap.clear();
    _colonization_distance[target_cell] = 0;
    _colonization_distance_stamp[target_cell] = stamp;
    _colonization_parent[target_cell] = -1;
    _colonization_parent_stamp[target_cell] = stamp;
    _colonization_route_heap.emplace_back(0, target_cell);
    std::push_heap(_colonization_route_heap.begin(),
                   _colonization_route_heap.end(), route_heap_less);
    std::vector<int32_t> reached_sources;
    int32_t expansions = 0;
    while (!_colonization_route_heap.empty() &&
           expansions < COLONIZATION_EXPANSION_BUDGET) {
        std::pop_heap(_colonization_route_heap.begin(),
                      _colonization_route_heap.end(), route_heap_less);
        const auto [distance, cell] = _colonization_route_heap.back();
        _colonization_route_heap.pop_back();
        if (_colonization_distance_stamp[cell] != stamp ||
            _colonization_distance[cell] != distance) continue;
        ++expansions;
        const int64_t owner = country_reads().country_handle_for_cell(cell);
        if (owner == country_handle_value && visible[cell] != 0 &&
            (source_filter < 0 || source_filter == cell))
            reached_sources.push_back(cell);
        collect_transport_successors(cell, cap, true);
        for (size_t i = 0; i < _transport_succ_cells.size(); ++i) {
            const int32_t neighbor = _transport_succ_cells[i];
            if (neighbor < 0 || visible[neighbor] == 0 ||
                _trade_topology.passable[static_cast<size_t>(neighbor)] == 0) continue;
            const int64_t neighbor_owner =
                country_reads().country_handle_for_cell(neighbor);
            if (neighbor_owner != 0 && neighbor_owner != country_handle_value)
                continue;
            const int64_t next = distance + std::max(1, _transport_succ_costs[i]);
            const bool unseen = _colonization_distance_stamp[neighbor] != stamp;
            const bool shorter = !unseen && next < _colonization_distance[neighbor];
            const bool tie = !unseen && next == _colonization_distance[neighbor] &&
                cell < _colonization_parent[neighbor];
            if (!unseen && !shorter && !tie) continue;
            _colonization_distance[neighbor] = next;
            _colonization_distance_stamp[neighbor] = stamp;
            _colonization_parent[neighbor] = cell;
            _colonization_parent_stamp[neighbor] = stamp;
            _colonization_route_heap.emplace_back(next, neighbor);
            std::push_heap(_colonization_route_heap.begin(),
                           _colonization_route_heap.end(), route_heap_less);
        }
    }
    std::sort(reached_sources.begin(), reached_sources.end());
    reached_sources.erase(std::unique(reached_sources.begin(),
                                      reached_sources.end()), reached_sources.end());
    uint64_t dest_kit_identity = 1;
    if (!reached_sources.empty()) {
        ColonizationKitPlan dest_preview;
        plan_colonization_kit(reached_sources.front(), target_cell,
            COLONIZATION_KIT_MIN_OWNER_SLOTS, 1, false, dest_preview);
        dest_kit_identity = dest_preview.dest_identity;
    }
    struct Candidate { uint64_t family; int32_t source; int64_t maximum;
        int32_t cost; int32_t days; uint64_t token; };
    std::vector<Candidate> candidates;
    for (const int32_t source : reached_sources) {
        if (_family_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
            continue;
        ColonizationKitPlan source_preview;
        plan_colonization_kit(source, target_cell, 1, 1, false, source_preview);
        const uint64_t source_stock_identity =
            source_preview.source_stock_identity == 0
            ? 1 : source_preview.source_stock_identity;
        for (int32_t p = _family_cell_offsets[source];
             p < _family_cell_offsets[source + 1]; ++p) {
            const int32_t family = _family_cell_indices[p];
            const uint64_t family_handle = families_store().handle_for_index(family);
            if (family_handle == 0 || source == target_cell ||
                (family_filter != 0 && family_handle != family_filter) ||
                !colonization_destination_family_allowed(family_handle,
                    target_cell)) continue;
            const int64_t maximum_population = family_dispatchable_population_in_cell(
                family_handle, source);
            if (maximum_population <= 0) continue;
            std::vector<int32_t> route;
            std::vector<int32_t> cumulative;
            int32_t cursor = source;
            int64_t running = 0;
            route.push_back(cursor); cumulative.push_back(0);
            uint64_t route_hash = 1469598103934665603ULL;
            route_hash = trace_hash_mix(route_hash, static_cast<uint32_t>(cursor));
            route_hash = trace_hash_mix(route_hash, 0);
            while (cursor != target_cell) {
                if (_colonization_parent_stamp[cursor] != stamp) {
                    route.clear(); break;
                }
                const int32_t from = cursor;
                cursor = _colonization_parent[cursor];
                const size_t before = route.size();
                if (!append_colonization_route_step(
                        from, cursor, cap, _colonization_distance[from],
                        _colonization_distance[cursor], route, cumulative, running)) {
                    route.clear();
                    break;
                }
                for (size_t i = before; i < route.size(); ++i) {
                    route_hash = trace_hash_mix(route_hash,
                        static_cast<uint32_t>(route[i]));
                    route_hash = trace_hash_mix(route_hash,
                        static_cast<uint32_t>(cumulative[i]));
                }
            }
            if (route.empty()) continue;
            uint64_t token = 1469598103934665603ULL;
            for (const uint64_t value : {country_handle, family_handle,
                    static_cast<uint64_t>(static_cast<uint32_t>(source)),
                    static_cast<uint64_t>(static_cast<uint32_t>(target_cell)),
                    _trade_topology.topology_generation, country_snapshot.generation,
                    vision_hash, route_hash, dest_kit_identity,
                    source_stock_identity})
                token = trace_hash_mix(token, value);
            token &= 0x7fffffffffffffffULL;
            if (token == 0) token = 1;
            if (_colonization_quote_cache.size() >= COLONIZATION_QUOTE_CACHE_LIMIT &&
                !has_pending_family_expedition_player_command()) {
                _colonization_quote_cache.clear();
                _colonization_quote_index.clear();
                _colonization_quote_route_cells.clear();
                _colonization_quote_route_costs.clear();
            }
            ColonizationQuoteCacheEntry entry;
            entry.token = token; entry.country_handle = country_handle;
            entry.family_handle = family_handle; entry.source_cell = source;
            entry.target_cell = target_cell;
            entry.maximum_population = maximum_population;
            entry.route_cost = static_cast<int32_t>(running);
            entry.travel_days = std::max(1, (entry.route_cost +
                COLONIZATION_SPEED - 1) / COLONIZATION_SPEED);
            entry.topology_generation = _trade_topology.topology_generation;
            entry.country_generation = country_snapshot.generation;
            entry.vision_hash = vision_hash; entry.route_hash = route_hash;
            entry.dest_kit_identity = dest_kit_identity;
            entry.source_stock_identity = source_stock_identity;
            entry.route_begin = static_cast<uint32_t>(
                _colonization_quote_route_cells.size());
            entry.route_count = static_cast<uint32_t>(route.size());
            _colonization_quote_route_cells.insert(
                _colonization_quote_route_cells.end(), route.begin(), route.end());
            _colonization_quote_route_costs.insert(
                _colonization_quote_route_costs.end(), cumulative.begin(), cumulative.end());
            const auto existing = _colonization_quote_index.find(token);
            if (existing == _colonization_quote_index.end()) {
                _colonization_quote_index[token] = static_cast<int32_t>(
                    _colonization_quote_cache.size());
                _colonization_quote_cache.push_back(entry);
            } else {
                _colonization_quote_cache[existing->second] = entry;
            }
            candidates.push_back({family_handle, source,
                maximum_population, entry.route_cost, entry.travel_days, token});
        }
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a,
            const Candidate &b) {
        return std::tie(a.cost, a.source, a.family) <
               std::tie(b.cost, b.source, b.family);
    });
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(candidates.size(), offset + limit);
    PackedInt64Array families, maximums, tokens, anonymous_maximums;
    PackedInt32Array sources, costs, days, surname_disambiguators;
    PackedStringArray surnames;
    for (int32_t i = offset; i < end; ++i) {
        families.push_back(static_cast<int64_t>(candidates[i].family));
        int32_t family_index = -1;
        if (families_store().valid_handle(candidates[i].family, family_index)) {
            const int32_t surname_id = families_store().surname_id[family_index];
            surnames.push_back(surname_id >= 0 && surname_id <
                    static_cast<int32_t>(_family_surname_text.size())
                ? from_utf8(_family_surname_text[surname_id]) : String());
            surname_disambiguators.push_back(
                families_store().surname_disambiguator[family_index]);
        } else {
            surnames.push_back(String()); surname_disambiguators.push_back(0);
        }
        sources.push_back(candidates[i].source);
        maximums.push_back(candidates[i].maximum);
        anonymous_maximums.push_back(colonization_party_anonymous(
            candidates[i].family, candidates[i].source,
            candidates[i].maximum));
        costs.push_back(candidates[i].cost); days.push_back(candidates[i].days);
        tokens.push_back(static_cast<int64_t>(candidates[i].token));
    }
    out["ok"] = true; out["target_cell"] = target_cell;
    fill_colonization_query_flags(out);
    out["kind"] = country_reads().country_handle_for_cell(target_cell) == 0
        ? String("colonize") : String("relocate");
    out["family_handles"] = families; out["source_cells"] = sources;
    out["surnames"] = surnames;
    out["surname_disambiguators"] = surname_disambiguators;
    out["maximum_populations"] = maximums; out["route_costs"] = costs;
    out["anonymous_maximums"] = anonymous_maximums;
    out["travel_days"] = days; out["quote_tokens"] = tokens;
    out["offset"] = offset; out["limit"] = limit;
    out["total"] = static_cast<int32_t>(candidates.size());
    out["has_more"] = end < static_cast<int32_t>(candidates.size());
    out["expansion_budget"] = COLONIZATION_EXPANSION_BUDGET;
    out["expansions"] = expansions;
    _colonization_route_query_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out["elapsed_ms"] = _colonization_route_query_ms;
    return out;
}

Dictionary NativeEconomyRuntime::family_colonization_quote_detail(
        int64_t quote_token_value, int64_t population) const {
    Dictionary out;
    fill_colonization_query_flags(out);
    if (!_bootstrapped || _fatal || _restore.active) {
        out["ok"] = false;
        out["code"] = _restore.active ? "economy_busy_retry" :
            _fatal ? "economy_paused" : "economy_not_available";
        return out;
    }
    const uint64_t token = static_cast<uint64_t>(quote_token_value);
    const auto found = _colonization_quote_index.find(token);
    if (found == _colonization_quote_index.end()) {
        out["ok"] = false; out["code"] = "colonization_quote_expired";
        return out;
    }
    const ColonizationQuoteCacheEntry &quote =
        _colonization_quote_cache[found->second];
    if (static_cast<size_t>(quote.route_begin) + quote.route_count >
            _colonization_quote_route_cells.size()) {
        out["ok"] = false; out["code"] = "colonization_quote_corrupt";
        return out;
    }
    PackedInt32Array route, cumulative;
    for (uint32_t i = 0; i < quote.route_count; ++i) {
        route.push_back(_colonization_quote_route_cells[quote.route_begin + i]);
        cumulative.push_back(_colonization_quote_route_costs[quote.route_begin + i]);
    }
    out["ok"] = true; out["quote_token"] = quote_token_value;
    out["country_handle"] = static_cast<int64_t>(quote.country_handle);
    out["family_handle"] = static_cast<int64_t>(quote.family_handle);
    out["source_cell"] = quote.source_cell; out["target_cell"] = quote.target_cell;
    out["kind"] = _country_runtime != nullptr &&
        country_reads().country_handle_for_cell(quote.target_cell) == 0
        ? String("colonize") : String("relocate");
    out["maximum_population"] = quote.maximum_population;
    out["anonymous_maximum"] = colonization_party_anonymous(
        quote.family_handle, quote.source_cell, quote.maximum_population);
    out["anonymous_per_family"] = COLONIZATION_ANONYMOUS_PER_FAMILY;
    out["route_cost"] = quote.route_cost; out["travel_days"] = quote.travel_days;
    out["route_cells"] = route; out["cumulative_costs"] = cumulative;
    std::vector<int64_t> profession_totals(_profession_ids.size(), 0);
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        if (edge.family_handle != quote.family_handle) continue;
        int32_t cohort = -1;
        if (!population_store().valid_handle(edge.cohort_handle, cohort) ||
            population_store().page_cell[cohort / COHORT_PAGE_SIZE] !=
                quote.source_cell) continue;
        const int32_t signature = population_store().signature_id[cohort];
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size()))
            continue;
        profession_totals[_signatures[signature].profession_id] += edge.people;
    }
    PackedInt32Array profession_ids;
    PackedInt64Array profession_populations;
    for (int32_t profession = 0; profession < static_cast<int32_t>(
            profession_totals.size()); ++profession) {
        if (profession_totals[profession] <= 0) continue;
        profession_ids.push_back(profession);
        profession_populations.push_back(profession_totals[profession]);
    }
    out["profession_ids"] = profession_ids;
    out["profession_populations"] = profession_populations;
    ColonizationKitPlan kit;
    const int64_t kit_population = population > 0
        ? std::min(population, quote.maximum_population)
        : quote.maximum_population;
    plan_colonization_kit(quote.source_cell, quote.target_cell, kit_population,
        quote.travel_days, false, kit);
    PackedInt32Array kit_building_ids;
    PackedInt64Array kit_building_counts;
    for (const FamilyExpeditionKitBuilding &row : kit.buildings) {
        kit_building_ids.push_back(row.type_id);
        kit_building_counts.push_back(row.count);
    }
    PackedInt32Array kit_missing_goods;
    for (const int32_t good : kit.missing_good_ids)
        kit_missing_goods.push_back(good);
    out["kit_building_ids"] = kit_building_ids;
    out["kit_building_counts"] = kit_building_counts;
    out["kit_supported_population"] = kit.supported_population;
    out["kit_food_coverage_q16"] = kit.food_coverage_q16;
    out["kit_missing_goods"] = kit_missing_goods;
    out["kit_source_stock_identity"] = static_cast<int64_t>(
        kit.source_stock_identity);
    out["kit_partial"] = kit.kit_partial != 0;
    out["kit_place_buildings"] = kit.place_buildings != 0;
    return out;
}

Dictionary NativeEconomyRuntime::family_expeditions(
        int64_t country_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    fill_colonization_query_flags(out);
    std::vector<int32_t> rows;
    for (int32_t i = 0; i < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++i)
        if (family_expeditions_store().active[i] != 0 &&
            family_expeditions_store().country_handle[i] ==
                static_cast<uint64_t>(country_handle_value)) rows.push_back(i);
    std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
        return std::tie(family_expeditions_store().due_day[a],
                        family_expeditions_store().stable_id[a]) <
               std::tie(family_expeditions_store().due_day[b],
                        family_expeditions_store().stable_id[b]);
    });
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(rows.size(), offset + limit);
    PackedInt64Array handles, families, populations, departures, dues,
        missing_identities, anonymous_populations;
    PackedInt32Array sources, targets, costs, states;
    for (int32_t p = offset; p < end; ++p) {
        const int32_t i = rows[p];
        handles.push_back(static_cast<int64_t>(
            family_expeditions_store().handle_for_index(i)));
        families.push_back(static_cast<int64_t>(
            family_expeditions_store().family_handle[i]));
        sources.push_back(family_expeditions_store().source_cell[i]);
        targets.push_back(family_expeditions_store().target_cell[i]);
        populations.push_back(family_expedition_displayed_population(i));
        anonymous_populations.push_back(
            family_expeditions_store().anonymous[i]);
        departures.push_back(family_expeditions_store().departure_day[i]);
        dues.push_back(family_expeditions_store().due_day[i]);
        costs.push_back(family_expeditions_store().route_cost[i]);
        states.push_back(family_expeditions_store().state[i]);
        missing_identities.push_back(static_cast<int64_t>(
            family_expeditions_store().kit_missing_stock_identity[i]));
    }
    out["ok"] = true; out["expedition_handles"] = handles;
    out["family_handles"] = families; out["source_cells"] = sources;
    out["target_cells"] = targets; out["populations"] = populations;
    out["anonymous_populations"] = anonymous_populations;
    out["departure_days"] = departures; out["due_days"] = dues;
    out["route_costs"] = costs; out["states"] = states;
    out["kit_missing_stock_identities"] = missing_identities;
    out["offset"] = offset; out["limit"] = limit;
    out["total"] = static_cast<int32_t>(rows.size());
    out["has_more"] = end < static_cast<int32_t>(rows.size());
    return out;
}

Dictionary NativeEconomyRuntime::family_expedition_snapshot(
        int64_t country_handle_value, int64_t expedition_handle_value) const {
    Dictionary out;
    int32_t expedition = -1;
    if (!family_expeditions_store().valid_handle(
            static_cast<uint64_t>(expedition_handle_value), expedition) ||
        family_expeditions_store().country_handle[expedition] !=
            static_cast<uint64_t>(country_handle_value)) {
        out["ok"] = false; out["code"] = "colonization_expedition_invalid";
        return out;
    }
    PackedInt32Array route, cumulative;
    const uint32_t begin = family_expeditions_store().route_begin[expedition];
    const uint32_t count = family_expeditions_store().route_count[expedition];
    for (uint32_t i = 0; i < count; ++i) {
        route.push_back(family_expedition_route_cells()[begin + i]);
        cumulative.push_back(family_expedition_route_costs()[begin + i]);
    }
    out["ok"] = true; out["expedition_handle"] = expedition_handle_value;
    out["family_handle"] = static_cast<int64_t>(
        family_expeditions_store().family_handle[expedition]);
    out["source_cell"] = family_expeditions_store().source_cell[expedition];
    out["target_cell"] = family_expeditions_store().target_cell[expedition];
    out["population"] = family_expedition_displayed_population(expedition);
    out["family_population"] = family_expeditions_store().population[expedition];
    out["anonymous_population"] = family_expeditions_store().anonymous[expedition];
    out["departure_day"] = family_expeditions_store().departure_day[expedition];
    out["due_day"] = family_expeditions_store().due_day[expedition];
    out["route_cost"] = family_expeditions_store().route_cost[expedition];
    out["speed"] = family_expeditions_store().speed[expedition];
    out["state"] = family_expeditions_store().state[expedition];
    out["effect_transaction_id"] =
        family_expeditions_store().effect_transaction_id[expedition];
    out["route_cells"] = route; out["cumulative_costs"] = cumulative;
    PackedInt32Array cargo_good_ids, cargo_flags, missing_good_ids;
    PackedInt64Array cargo_quantities, missing_good_quantities;
    const uint32_t cargo_begin = family_expeditions_store().cargo_begin[expedition];
    const uint32_t cargo_count = family_expeditions_store().cargo_count[expedition];
    for (uint32_t i = 0; i < cargo_count; ++i) {
        if (cargo_begin + i >= family_expedition_cargo().size()) break;
        const FamilyExpeditionCargoLine &line =
            family_expedition_cargo()[cargo_begin + i];
        cargo_good_ids.push_back(line.good_id);
        cargo_quantities.push_back(line.quantity);
        cargo_flags.push_back(line.flags);
    }
    const uint32_t missing_begin =
        family_expeditions_store().missing_good_begin[expedition];
    const uint32_t missing_count =
        family_expeditions_store().missing_good_count[expedition];
    for (uint32_t i = 0; i < missing_count; ++i) {
        if (missing_begin + i >= family_expedition_missing_good_ids().size())
            break;
        missing_good_ids.push_back(
            family_expedition_missing_good_ids()[missing_begin + i]);
        missing_good_quantities.push_back(
            missing_begin + i < family_expedition_missing_good_quantities().size()
                ? family_expedition_missing_good_quantities()[missing_begin + i]
                : 0);
    }
    out["cargo_good_ids"] = cargo_good_ids;
    out["cargo_quantities"] = cargo_quantities;
    out["cargo_flags"] = cargo_flags;
    out["kit_missing_good_ids"] = missing_good_ids;
    out["kit_missing_good_quantities"] = missing_good_quantities;
    out["kit_missing_stock_identity"] = static_cast<int64_t>(
        family_expeditions_store().kit_missing_stock_identity[expedition]);
    int64_t bridge_required = 0;
    int64_t bridge_missing = 0;
    int64_t material_required = 0;
    int64_t material_missing = 0;
    String blocker;
    if (family_expeditions_store().state[expedition] == EXPEDITION_PREPARING) {
        bridge_required = family_expeditions_store().kit_bridge_required_units[
            expedition];
        material_required = family_expeditions_store().kit_material_required_units[
            expedition];
        // Replan read-only against the live escrow for blocker and candidate
        // diagnostics; the progress denominator comes from the fixed fields
        // above and is therefore available even if this replan is unavailable.
        ColonizationReserveContext reserve;
        std::vector<int64_t> reserved_stock;
        collect_family_expedition_reserved_stock(expedition, reserved_stock);
        reserve.reserved = &reserved_stock;
        reserve.prefer_reserved_candidates = true;
        ColonizationKitPlan kit;
        const int32_t travel = std::max(1,
            (family_expeditions_store().route_cost[expedition] +
             std::max(1, family_expeditions_store().speed[expedition]) - 1) /
            std::max(1, family_expeditions_store().speed[expedition]));
        if (plan_colonization_kit(
                family_expeditions_store().source_cell[expedition],
                family_expeditions_store().target_cell[expedition],
                family_expeditions_store().population[expedition] +
                    family_expeditions_store().anonymous[expedition], travel,
                _epoch_active, kit, false, &reserve)) {
            if (bridge_required <= 0)
                bridge_required = kit.bridge_required_units;
            if (material_required <= 0)
                material_required = kit.material_required_units;
            // Progress is measured from authoritative escrow, never from the
            // current quote's affordable subset.  The quote may change with
            // market stock, while already purchased cargo must remain.
            int64_t acquired_bridge = 0;
            int64_t acquired_material = 0;
            int64_t progress_saturation = 0;
            const uint32_t cargo_begin =
                family_expeditions_store().cargo_begin[expedition];
            const uint32_t cargo_end = std::min<uint32_t>(
                cargo_begin + family_expeditions_store().cargo_count[expedition],
                static_cast<uint32_t>(family_expedition_cargo().size()));
            for (uint32_t i = cargo_begin; i < cargo_end; ++i) {
                const FamilyExpeditionCargoLine &line =
                    family_expedition_cargo()[i];
                if (line.flags != EXPEDITION_CARGO_CONSTRUCTION)
                    acquired_bridge = saturating_add(acquired_bridge,
                        line.quantity, progress_saturation);
                if (line.flags == EXPEDITION_CARGO_CONSTRUCTION)
                    acquired_material = saturating_add(acquired_material,
                        line.quantity, progress_saturation);
            }
            bridge_missing = std::max<int64_t>(0,
                bridge_required - acquired_bridge);
            material_missing = std::max<int64_t>(0,
                material_required - acquired_material);
            // Escrow totals pool every bridge group, so surplus food can hide
            // a clothing or tool shortfall the planner still reports.
            const bool launchable = preparing_kit_launchable(kit,
                family_expeditions_store().population[expedition] +
                    family_expeditions_store().anonymous[expedition]);
            if (!launchable) {
                bridge_missing = std::max(bridge_missing, std::min(
                    std::max<int64_t>(1, bridge_required),
                    std::max<int64_t>(0, kit.bridge_missing_units)));
                material_missing = std::max(material_missing, std::min(
                    std::max<int64_t>(1, material_required),
                    std::max<int64_t>(0, kit.material_missing_units)));
            }
            // One reason, ordered by how final it is: an unreachable material
            // ends the preparation, an empty plan is a target problem, and the
            // two shortfalls are the ordinary day-by-day stockpiling states.
            if (kit.kit_unbuildable != 0)
                blocker = "UNBUILDABLE";
            else if (material_missing > 0)
                blocker = "MATERIALS";
            else if (kit.place_buildings != 0 && kit.buildings.empty())
                blocker = "NO_BUILDINGS";
            else if (bridge_missing > 0)
                blocker = "BRIDGE";
            else if (!launchable)
                blocker = "INCOMPLETE";
            else
                blocker = "READY";
        }
    }
    out["kit_bridge_required_units"] = bridge_required;
    out["kit_bridge_missing_units"] = bridge_missing;
    out["kit_material_required_units"] = material_required;
    out["kit_material_missing_units"] = material_missing;
    out["kit_blocker"] = blocker;
    const FamilyExpeditionProcurementContinuation &procurement =
        _family_expedition_procurement_continuation;
    const bool procurement_pending = procurement.active &&
        procurement.expedition == expedition;
    out["kit_procurement_pending"] = procurement_pending;
    out["kit_procurement_blocked_by_peer"] = procurement.active &&
        procurement.expedition != expedition;
    out["kit_procurement_phase"] = procurement_pending ? procurement.phase : 0;
    out["kit_procurement_good_id"] = procurement_pending ? procurement.good : -1;
    out["kit_procurement_quantity"] =
        procurement_pending ? procurement.quantity : 0;
    out["kit_procurement_started_day"] =
        procurement_pending ? procurement.started_day : -1;
    const auto rejection = _family_expedition_procurement_rejections.find(
        expedition);
    const bool rejected = rejection != _family_expedition_procurement_rejections.end() &&
        rejection->second.generation ==
            family_expeditions_store().generation[expedition];
    out["kit_procurement_rejected_good_id"] =
        rejected ? rejection->second.good : -1;
    out["kit_procurement_rejected_day"] = rejected ? rejection->second.day : -1;
    out["kit_procurement_rejection"] = rejected
        ? String(rejection->second.reason.c_str()) : String();
    return out;
}

Dictionary NativeEconomyRuntime::family_colonization_receipts(
        int64_t country_handle_value, int64_t after_receipt_id,
        int32_t limit) const {
    Dictionary out;
    limit = std::clamp(limit, 1, 256);
    Array receipts;
    int64_t last = after_receipt_id;
    for (const ColonizationReceipt &receipt : _colonization_receipts) {
        if (receipt.receipt_id <= after_receipt_id ||
            receipt.country_handle != static_cast<uint64_t>(country_handle_value))
            continue;
        Dictionary row;
        row["receipt_id"] = receipt.receipt_id;
        row["sequence"] = receipt.sequence;
        row["effective_day"] = receipt.effective_day;
        row["settled_day"] = receipt.settled_day;
        row["expedition_handle"] = static_cast<int64_t>(receipt.expedition_handle);
        row["target_cell"] = receipt.target_cell;
        row["kind"] = receipt.kind;
        row["code"] = String(receipt.code.c_str());
        receipts.push_back(row); last = receipt.receipt_id;
        if (receipts.size() >= limit) break;
    }
    out["ok"] = true; out["receipts"] = receipts;
    out["count"] = receipts.size(); out["last_receipt_id"] = last;
    return out;
}


} // namespace pk
