#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "effect_runtime.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <limits>
#include <vector>

namespace pk {

bool NativeEconomyRuntime::run_epoch_open_prelude_drain(
        int64_t day_index, int64_t &work_done, std::string &error,
        bool *pending_input, bool *idle_done) {
    error.clear();
    work_done = 0;
    if (pending_input != nullptr) {
        *pending_input = false;
    }
    if (idle_done != nullptr) {
        *idle_done = false;
    }
    if (!_bootstrapped || _fatal) {
        return true;
    }
    // Both compact and StageOps must advance the observed day before epoch
    // preparation: spread/cache phases read it while freezing derived demand.
    // Advancing only at the end of open_epoch makes StageOps reuse yesterday's
    // phase and changes real prices and household purchases after day zero.
    _current_day = std::max(_current_day.get(), day_index);
    // A day can only be opened against a shaped market matrix. If the store the
    // graph stages are about to read is empty or mis-strided, say so with the
    // day, the ownership and the sizes *before* a stage read throws an
    // out-of-range that names only one lane. Silent while the store is healthy.
    {
        const size_t markets = static_cast<size_t>(
            std::max(0, market_store().market_count.get()));
        const size_t goods = static_cast<size_t>(
            std::max(0, market_store().good_count.get()));
        if (market_store().market_count.get() <= 0 || goods <= 0 ||
            market_store().stock.size() != markets * goods ||
            market_store().cell_to_market.size() !=
                static_cast<size_t>(std::max(0, _cell_count.get()))) {
            std::fprintf(stderr,
                "[economy-day-store-shape] request_day=%lld epoch_active=%d "
                "last_committed=%lld backing=%s cell_count=%d market_count=%d "
                "good_count=%d stock=%zu(expect=%zu) cell_to_market=%zu "
                "local_stock=%zu local_markets=%d\n",
                static_cast<long long>(day_index), _epoch_active ? 1 : 0,
                static_cast<long long>(_last_committed_day.get()),
                formula_owned_bound() ? "owned_state" : "ner_local",
                _cell_count.get(), market_store().market_count.get(),
                market_store().good_count.get(), market_store().stock.size(),
                markets * goods, market_store().cell_to_market.size(),
                _market_local.stock.size(), _market_local.market_count.get());
            std::fflush(stderr);
        }
    }
    if (_epoch_active) {
        return true;
    }

    const auto mark_pending = [&](const std::string &reason) {
        if (pending_input != nullptr) {
            *pending_input = true;
        }
        error = reason;
    };
    const auto is_asset_pending = [](const std::string &reason) {
        return runtime_country_asset_pending_reason(reason);
    };

    constexpr int kMaxSteps = 1 << 16;
    for (int step = 0; step < kMaxSteps && !_epoch_active && !_fatal; ++step) {
        if (!service_country_economy_asset_peer(64, error)) {
            if (is_asset_pending(error)) {
                _executed_stage = Stage::EPOCH_BEGIN;
                _executed_substage = "country_asset_peer_pending";
                mark_pending(error);
                return true;
            }
            fail(error.empty() ? "country_economy_fiscal_peer_failed" : error);
            return false;
        }

        if (_fiscal_reservation_continuation.active ||
            _epoch_begin_post_fiscal_pending) {
            _executed_stage = Stage::EPOCH_BEGIN;
            _executed_substage = _fiscal_reservation_continuation.active
                                     ? "fiscal_reserve"
                                     : "fiscal_finalize";
            const int64_t fiscal_day = _epoch_begin_pending_day >= 0
                                           ? _epoch_begin_pending_day
                                           : day_index;
            if (_fiscal_reservation_continuation.active) {
                if (!advance_fiscal_reservation(error)) {
                    fail(error.empty() ? "fiscal_reservation_failed" : error);
                    return false;
                }
                ++work_done;
                if (_fiscal_reservation_continuation.active) {
                    // True Country-peer wait parks; otherwise keep draining
                    // remaining countries in this call (compact yields).
                    if (_fiscal_reservation_continuation.pending_request_id !=
                        0) {
                        mark_pending("fiscal_reserve_peer_results");
                        return true;
                    }
                    continue;
                }
            }
            if (!_fiscal_reservation_continuation.active &&
                _epoch_begin_post_fiscal_pending) {
                if (!finish_epoch_start_after_fiscal(fiscal_day, error)) {
                    fail(error.empty() ? "fiscal_begin_finalize_failed" : error);
                    return false;
                }
                ++work_done;
            }
            continue;
        }

        if (!should_run(day_index)) {
            if (idle_done != nullptr) {
                *idle_done = true;
            }
            return true;
        }

        auto pull_due_family_settlements = [this]() {
            EconomyCostProbe probe("epoch.family_dispatch", _current_day.get());
            if (_effect_runtime != nullptr) {
                _effect_runtime->dispatch_native_economy(this);
            }
            recover_lost_family_settlement_commands();
        };
        pull_due_family_settlements();
        if (!process_due_canal_projects(day_index, error) ||
            !process_due_family_expeditions(day_index, error)) {
            fail(error);
            return false;
        }
        pull_due_family_settlements();

        const bool cycle_due = day_index > _last_committed_day.get();
        if (cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            _executed_stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) {
                fail(error);
                return false;
            }
            _stage = Stage::EPOCH_BEGIN;
        }
        if (!cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            _executed_stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) {
                fail(error);
                return false;
            }
            if (!_fatal && _trade_plan.phase == TradePlanStore::IDLE) {
                _stage = Stage::IDLE;
            }
            if (idle_done != nullptr) {
                *idle_done = true;
            }
            return true;
        }

        _stage = Stage::EPOCH_BEGIN;
        _executed_stage = Stage::EPOCH_BEGIN;
        if (!start_epoch(day_index, error)) {
            if (error == "same_day_environment_not_captured" ||
                error == "same_day_building_context_not_captured" ||
                // 分片构建未完成是软屏障，与 compact 路径一致
                // （economy_runtime_stage_execution.cpp:283-296）。
                error == "city_factor_shard_pending") {
                _stage = Stage::IDLE;
                _executed_stage = Stage::IDLE;
                mark_pending(error);
                return true;
            }
            fail(error);
            return false;
        }
        // start_epoch may return after admitting fiscal reservation without
        // setting _epoch_active. Keep draining in this call so one StageOps
        // day matches compact multi-slice fiscal open.
        if (_epoch_active) {
            return true;
        }
        if (_fiscal_reservation_continuation.active ||
            _epoch_begin_post_fiscal_pending) {
            ++work_done;
            continue;
        }
        if (idle_done != nullptr) {
            *idle_done = true;
        }
        return true;
    }

    if (_fatal) {
        error = error.empty() ? "epoch_open_prelude_fatal" : error;
        return false;
    }
    if (!_epoch_active) {
        error = "epoch_open_prelude_guard_exhausted";
        fail(error);
        return false;
    }
    return true;
}

} // namespace pk
