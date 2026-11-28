#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_runtime_publish_internal.h"

#include <algorithm>

namespace pk {

using economy_publish_detail::Clock;
using economy_publish_detail::elapsed_ms;

void NativeEconomyRuntime::publish_commit_slice(int64_t &work_done) {
    // The old implementation performed every commit-side cell mutation in
    // one call. Keep the exact order, but retain the cursor across calls so
    // a large settlement set cannot create an unbounded native range.
    if (!_publish_commit_initialized) {
        const auto commit_prepare_started = Clock::now();
        _committed_cells.swap(_staging_cells);
        commit_incremental_audit_shadow();
        update_settlements_for_changed_cells();
        _publish_commit_initialized = true;
        _publish_cursor = 0;
        const double commit_prepare_ms = elapsed_ms(commit_prepare_started);
        _publish_commit_prepare_ms += commit_prepare_ms;
        _publish_commit_prepare_slice_ms += commit_prepare_ms;
    }
    const auto commit_cells_started = Clock::now();
    const size_t start = _publish_cursor;
    const size_t end = std::min(
        _epoch_settlement_cells.size(),
        start + static_cast<size_t>(PUBLISH_COMMIT_ENTRIES_PER_SLICE));
    const int32_t cell_count = _cell_count.get();
    const size_t cell_count_u = static_cast<size_t>(std::max(0, cell_count));
    const auto &markets = market_store();
    const int32_t market_count = markets.market_count.get();
    const int32_t good_count = markets.good_count.get();
    const size_t cell_to_market_size = markets.cell_to_market.size();
    const int32_t *cell_to_market_data = markets.cell_to_market.data();
    const size_t shortage_lanes_size = markets.last_shortage_q16.size();
    const uint16_t *shortage_lanes_data = markets.last_shortage_q16.data();
    const int32_t essential_count = static_cast<int32_t>(_good_is_essential.size());
    const uint8_t *essential_data = _good_is_essential.data();
    const size_t effect_shortage_size = _cell_effect_shortage_q16.size();
    const size_t essentials_shortage_size = _cell_essentials_shortage_q16.size();
    const size_t abundance_size = _cell_resource_abundance_q16.size();
    const auto &stock_lanes = resource_stock_lanes();
    const auto &rem_lanes = resource_remaining_lanes();
    const size_t stock_lanes_size = stock_lanes.size();
    const size_t rem_lanes_size = rem_lanes.size();
    const int64_t *stock_lanes_data = stock_lanes.data();
    const int64_t *rem_lanes_data = rem_lanes.data();
    const int32_t resource_count = static_cast<int32_t>(_resource_ids.size());
    // Cell-aggregate readings: shortage, trade events, essentials
    // shortage, rain and resource abundance. Built once per slice as a
    // MetricMask so the selection stays expressible once the table passes id 63.
    MetricMask aggregate_effect_metrics;
    aggregate_effect_metrics.set(FAMILY_METRIC_CELL_RESOURCE_SHORTAGE_Q16);
    aggregate_effect_metrics.set(FAMILY_METRIC_CELL_TRADE_EVENTS);
    aggregate_effect_metrics.set(FAMILY_METRIC_CELL_POPULATION);
    aggregate_effect_metrics.set(FAMILY_METRIC_CELL_ESSENTIALS_SHORTAGE_Q16);
    aggregate_effect_metrics.set(FAMILY_METRIC_CELL_RESOURCE_ABUNDANCE_Q16);
    const uint64_t metric_rev = family_effect_metric_revision(2);
    auto *sink = market_mutation_sink();
    for (; _publish_cursor < end; ++_publish_cursor) {
        const int32_t cell = _epoch_settlement_cells[_publish_cursor];
        if (cell < 0 || cell >= cell_count) continue;
        const size_t cell_u = static_cast<size_t>(cell);
        _cell_last_settlement_day.write_scalar(cell, _sample_day, sink);
        _cell_settlement_generation.write_scalar(cell, _cell_settlement_generation[cell] + 1, sink);
        _cell_price_stock_gen.write_scalar(cell, _cell_price_stock_gen[cell] + 1, sink);
        _cell_owner_cash_gen.write_scalar(cell, _cell_owner_cash_gen[cell] + 1, sink);
        _cell_population_gen.write_scalar(cell, _cell_population_gen[cell] + 1, sink);
        _cell_resource_gen.write_scalar(cell, _cell_resource_gen[cell] + uint32_t{1});
        if (cell_u < cell_to_market_size && cell_u < effect_shortage_size) {
            const int32_t market = cell_to_market_data[cell_u];
            int32_t shortage_q16 = 0;
            int32_t essentials_q16 = 0;
            if (market >= 0 && market < market_count && good_count > 0) {
                const size_t base = static_cast<size_t>(market) * static_cast<size_t>(good_count);
                if (base < shortage_lanes_size) {
                    const int32_t avail_goods = static_cast<int32_t>(
                        std::min<size_t>(static_cast<size_t>(good_count), shortage_lanes_size - base));
                    const uint16_t *row = shortage_lanes_data + base;
                    for (int32_t good = 0; good < avail_goods; ++good) {
                        const int32_t lane_shortage = static_cast<int32_t>(row[good]);
                        if (lane_shortage > shortage_q16) shortage_q16 = lane_shortage;
                        if (good < essential_count && essential_data[good] != 0 &&
                            lane_shortage > essentials_q16) {
                            essentials_q16 = lane_shortage;
                        }
                    }
                }
            }
            const int32_t clamped_shortage = std::clamp<int32_t>(
                shortage_q16, 0, static_cast<int32_t>(Q16_ONE));
            if (_cell_effect_shortage_q16[cell_u] != clamped_shortage) {
                _cell_effect_shortage_q16.write_scalar(cell_u, clamped_shortage, sink);
            }
            if (cell_u < essentials_shortage_size) {
                const int32_t clamped_essentials = std::clamp<int32_t>(
                    essentials_q16, 0, static_cast<int32_t>(Q16_ONE));
                if (_cell_essentials_shortage_q16[cell_u] != clamped_essentials) {
                    _cell_essentials_shortage_q16.write_scalar(cell_u, clamped_essentials, sink);
                }
            }
        }
        if (cell_u < abundance_size && cell_count > 0 && stock_lanes_size > 0) {
            int64_t total = 0;
            int32_t counted = 0;
            int64_t sat = 0;
            size_t idx = cell_u;
            for (int32_t resource = 0; resource < resource_count && idx < stock_lanes_size;
                 ++resource, idx += cell_count_u) {
                const int64_t stock = stock_lanes_data[idx];
                if (stock <= 0) continue;
                const int64_t remaining =
                    idx < rem_lanes_size ? std::max<int64_t>(0, rem_lanes_data[idx]) : stock;
                total = saturating_add(total, mul_div_sat(remaining, Q16_ONE, stock, sat), sat);
                ++counted;
            }
            _cell_resource_abundance_q16[cell_u] =
                counted > 0 ? static_cast<int32_t>(std::clamp<int64_t>(
                    total / counted, 0, Q16_ONE)) : Q16_ONE;
        }
        refresh_family_effect_metrics_for_cell(cell, metric_rev, aggregate_effect_metrics);
    }
    const double commit_cells_ms = elapsed_ms(commit_cells_started);
    _publish_commit_cells_ms += commit_cells_ms;
    _publish_commit_cells_slice_ms += commit_cells_ms;
    work_done += static_cast<int64_t>(end - start);
    if (_publish_cursor < _epoch_settlement_cells.size()) {
        // Do not run any post-commit side effects until every cell has been
        // committed. This is the same committed barrier as before.
    } else {
        const auto commit_finalize_started = Clock::now();
        publish_social_pressure_facts();
        EconomyCostProbe::record("publish.commit.social", _current_day.get(),
                                 elapsed_ms(commit_finalize_started));
        const auto finalize_t1 = Clock::now();
        publish_technology_practice_facts();
        EconomyCostProbe::record("publish.commit.technology", _current_day.get(),
                                 elapsed_ms(finalize_t1));
        const auto finalize_t2 = Clock::now();
        publish_country_development_facts();
        EconomyCostProbe::record("publish.commit.development", _current_day.get(),
                                 elapsed_ms(finalize_t2));
        const auto finalize_t3 = Clock::now();
        publish_country_ai_digest();
        publish_annual_development_facts();
        EconomyCostProbe::record("publish.commit.ai_digest", _current_day.get(),
                                 elapsed_ms(finalize_t3));
        const auto finalize_t4 = Clock::now();
        commit_food_flow_snapshot();
        EconomyCostProbe::record("publish.commit.food_flow", _current_day.get(),
                                 elapsed_ms(finalize_t4));
        const auto finalize_t5 = Clock::now();
        _rolling_processed_cells = static_cast<int32_t>(_epoch_settlement_cells.size());
        _rolling_deferred_cells = std::max(
            0, _rolling_due_cells - _rolling_processed_cells);
        _last_committed_day = _sample_day;
        _commit_day = _current_day.get();
        // K6: reflect committed resource consumption into resource_stock_lanes()
        // so PKEC/ECP2 checkpoints persist closing stock instead of stale opening
        // stock on non-worker paths (worker path already updates via write_worker_resource_stock).
        if (!_worker_resource_seeded && !_resource_touched_lanes.empty()) {
            auto &stock_lanes = resource_stock_lanes();
            const auto &delta_lanes = resource_delta_lanes();
            for (const size_t lane : _resource_touched_lanes) {
                if (lane >= stock_lanes.size() || lane >= delta_lanes.size()) continue;
                const int64_t delta = delta_lanes[lane];
                if (delta >= 0) continue;
                const int64_t updated = std::max<int64_t>(0,
                    saturating_add(stock_lanes[lane], delta, _saturation_count));
                stock_lanes.write_scalar(lane, updated);
            }
        }
        // X13a: this is the last committed hazard mask. Keeping it in the
        // commit tail makes save/restore and the next day's edge exact.
        // Skip unchanged cells so quiet days do not dirty the entire map.
        if (_cell_previous_hazard_mask.size() ==
                static_cast<size_t>(_cell_count.get()) &&
            _cell_hazard_today_mask.size() ==
                static_cast<size_t>(_cell_count.get())) {
            const int32_t hazard_cells = _cell_count.get();
            for (int32_t cell = 0; cell < hazard_cells; ++cell) {
                const uint32_t today_mask = _cell_hazard_today_mask[cell];
                if (_cell_previous_hazard_mask[cell] != today_mask) {
                    _cell_previous_hazard_mask.write_scalar(cell, today_mask, sink);
                }
            }
        }
        if (++_committed_generation == 0) _committed_generation = 1;
        // X8 reads the committed production shape. Refresh immediately before
        // the digest so every metric-87 consumer sees this commit's answer.
        refresh_neighbor_distinct_goods_metrics();
        // P1-A: the only place the Effect input digest is recomputed. It has to
        // be the commit tail -- the per-cell columns and the tag bits are final
        // here, and "the day advanced" is not the same as "the input changed".
        refresh_effect_input_digest();
        _resource_deltas_ready = std::any_of(
            _resource_touched_lanes.begin(), _resource_touched_lanes.end(),
            [&](size_t index) {
                return index < resource_delta_lanes().size() &&
                    resource_delta_lanes()[index] != 0;
            });
        fold_worker_resource_deltas();
        _epoch_commands.clear();
        _structural_commands.clear();
        _epoch_market_ids.clear();
        _epoch_settlement_cells.clear();
        _epoch_building_cells.clear();
        _epoch_plan_cells.clear();
        trace_commit_epoch(0, 0, 0);
        _epoch_active = false;
        // Mid-epoch Effect submits land in _pending_commands. Drain them now
        // so PREFLIGHTED Effect transactions can ACK without waiting for a
        // calendar day the hard_ack barrier would otherwise refuse to grant.
        drain_due_effect_pending_commands();
        _stage = _trade_plan.phase == TradePlanStore::IDLE
            ? Stage::AGGREGATE_PUBLISH : Stage::TRADE_PLANNING;
        _publish_phase = PublishPhase::DONE;
        _publish_commit_initialized = false;
        _publish_cursor = 0;
        EconomyCostProbe::record("publish.commit.finalize_tail", _current_day.get(),
                                 elapsed_ms(finalize_t5));
        const double commit_finalize_ms = elapsed_ms(commit_finalize_started);
        _publish_commit_finalize_ms += commit_finalize_ms;
        _publish_commit_finalize_slice_ms += commit_finalize_ms;
        ++work_done;
    }
}

} // namespace pk
