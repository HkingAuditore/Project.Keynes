#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"

#include <algorithm>
#include <limits>

namespace pk {

NativeEconomyRuntime::InvestmentSparseFilter NativeEconomyRuntime::prepare_investment_sparse_filter(
        const BuildingInvestmentCellContext &ctx) {
    uint32_t investment_review_stamp = 0;
    const auto cell = ctx.cell;
    const auto country = ctx.country;
    const auto market = ctx.market;
    const auto available_begin = ctx.available_begin;
    const auto available_end = ctx.available_end;
    const auto &cell_request = ctx.cell_request;
    const auto capture_investment_diagnostics = ctx.capture_investment_diagnostics;
    bool sparse_mask_ready = false;
    if (_investment_sparse_mode != 0 &&
        _investment_type_stamp.size() == _building_types.size() &&
        _investment_good_stamp.size() == _good_ids.size() &&
        _investment_good_type_offsets.size() == _good_ids.size() + 1) {
        ++_investment_review_stamp_generation;
        if (_investment_review_stamp_generation == 0) {
            std::fill(_investment_type_stamp.begin(),
                      _investment_type_stamp.end(), 0);
            std::fill(_investment_good_stamp.begin(),
                      _investment_good_stamp.end(), 0);
            _investment_review_stamp_generation = 1;
        }
        investment_review_stamp = _investment_review_stamp_generation;
        _investment_good_queue_scratch.clear();
        auto country_type_available = [&](int32_t type_id) {
            const size_t index = country >= 0
                ? static_cast<size_t>(country) * _building_types.size() +
                    static_cast<size_t>(type_id)
                : std::numeric_limits<size_t>::max();
            return index < _epoch_country_building_available.size() &&
                _epoch_country_building_available[index] != 0;
        };
        auto enqueue_good = [&](int32_t good) {
            if (good < 0 || good >= static_cast<int32_t>(_good_ids.size()) ||
                _investment_good_stamp[good] == investment_review_stamp)
                return;
            _investment_good_stamp[good] = investment_review_stamp;
            _investment_good_queue_scratch.push_back(good);
        };
        auto mark_type = [&](int32_t type_id) {
            if (type_id < 0 ||
                type_id >= static_cast<int32_t>(_building_types.size()) ||
                !country_type_available(type_id) ||
                _investment_type_stamp[type_id] == investment_review_stamp)
                return;
            _investment_type_stamp[type_id] = investment_review_stamp;
            const BuildingType &marked_type = _building_types[type_id];
            for (int32_t edge = 0; edge < marked_type.construction_count;
                 ++edge) {
                const int32_t group = marked_type.construction_begin + edge;
                enqueue_good(_building_construction_goods[group].good_id);
                if (group >= 0 && group + 1 < static_cast<int32_t>(
                        _building_construction_candidate_offsets.size())) {
                    for (int32_t candidate =
                             _building_construction_candidate_offsets[group];
                         candidate < _building_construction_candidate_offsets[group + 1];
                         ++candidate) {
                        enqueue_good(_building_construction_candidates[candidate].good_id);
                    }
                }
            }
        };
        const size_t words_per_market =
            (static_cast<size_t>(market_store().good_count.get()) + 63U) / 64U;
        sparse_mask_ready = market >= 0 &&
            words_per_market <=
                _investment_active_good_words.size();
        if (sparse_mask_ready) {
            for (const int32_t good : _investment_active_goods_scratch)
                enqueue_good(good);
            if (_building_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t group = _building_cell_offsets[cell];
                     group < _building_cell_offsets[cell + 1]; ++group) {
                    const int32_t local_type = buildings_store().type_id[group];
                    mark_type(local_type);
                    if (local_type < 0 ||
                        local_type >= static_cast<int32_t>(
                            _building_types.size())) continue;
                    const BuildingType &local_outputs =
                        _building_types[local_type];
                    for (int32_t output = 0;
                         output < local_outputs.output_count; ++output) {
                        enqueue_good(_building_outputs[
                            local_outputs.output_begin + output].good_id);
                    }
                }
            }
            if (_pending_construction_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t cursor =
                         _pending_construction_cell_offsets[cell];
                     cursor < _pending_construction_cell_offsets[cell + 1];
                     ++cursor) {
                    const int32_t pending_index =
                        _pending_construction_cell_indices[cursor];
                    if (pending_index >= 0 &&
                        pending_index < static_cast<int32_t>(
                            pending_construction_count())) {
                        mark_type(buildings_store().pending_type_id[
                            static_cast<size_t>(pending_index)]);
                    }
                }
            }
            size_t good_cursor = 0;
            while (good_cursor <
                   _investment_good_queue_scratch.size()) {
                const int32_t good =
                    _investment_good_queue_scratch[good_cursor++];
                for (int32_t cursor =
                         _investment_good_type_offsets[good];
                     cursor < _investment_good_type_offsets[good + 1];
                     ++cursor) {
                    mark_type(_investment_good_type_indices[cursor]);
                }
            }
        }
    }
    const bool sparse_full_verification =
        _full_audit_verify_interval_days > 0 &&
        _current_day.get() % _full_audit_verify_interval_days == 0;
    bool sparse_filter_active = _investment_sparse_mode == 2 &&
        !_investment_sparse_runtime_disabled && sparse_mask_ready &&
        !capture_investment_diagnostics && !sparse_full_verification &&
        cell_request.reason != INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP;
    // An empty sparse workset means "no observed signals yet", not
    // "all industries are impossible".  Disable the filter so unlocked
    // greenfield types receive their bounded prior and can bootstrap a
    // previously absent good/profession/building chain.
    if (_investment_active_goods_scratch.empty())
        sparse_filter_active = false;
    if (sparse_filter_active) {
        int32_t selected_available_types = 0;
        const int32_t available_type_count =
            std::max(0, available_end - available_begin);
        for (int32_t available_index = available_begin;
             available_index < available_end; ++available_index) {
            const int32_t type_id =
                _epoch_country_building_type_indices[available_index];
            if (type_id >= 0 &&
                type_id < static_cast<int32_t>(
                    _investment_type_stamp.size()) &&
                _investment_type_stamp[type_id] ==
                    investment_review_stamp) {
                ++selected_available_types;
            }
        }
        if (available_type_count > 0 &&
            static_cast<int64_t>(selected_available_types) * 100 >
                static_cast<int64_t>(available_type_count) * 95) {
            sparse_filter_active = false;
            ++_investment_sparse_dense_fallbacks;
        }
    }
    return {investment_review_stamp, sparse_mask_ready, sparse_filter_active};
}

} // namespace pk
