    if (_household_market_phase == 1) {
        _executed_substage = "post_buildings";
        const auto phase_started = Clock::now();
        cursor_start = _household_post_cursor;
        const int32_t end =
            household_post_slice_end(_household_post_cursor);
        const int32_t begin = _household_post_cursor;
        const int32_t count = end - begin;
        _household_post_saturation_scratch.assign(count, 0);
        _household_post_restarted_scratch.assign(count, 0);
        _household_post_failed_scratch.assign(count, 0);
        const int32_t tasks = _worker_enabled && count >= 2 &&
                parallel_has_real_worker_threads()
            ? std::min(count, _worker_task_cap) : 1;
        auto finalize_cells = [&](int32_t relative_begin,
                                  int32_t relative_end) {
            for (int32_t relative = relative_begin;
                 relative < relative_end; ++relative) {
                finalize_household_building_cell(
                    _epoch_building_cells[begin + relative],
                    _household_post_saturation_scratch[relative],
                    _household_post_restarted_scratch[relative],
                    _household_post_failed_scratch[relative]);
            }
        };
        if (tasks > 1) {
            parallel_for_range("pk_economy_household_post", count,
                               tasks, 1, finalize_cells);
        } else {
            finalize_cells(0, count);
        }
        for (int32_t relative = 0; relative < count; ++relative) {
            _saturation_count = saturating_add(
                _saturation_count,
                _household_post_saturation_scratch[relative],
                _saturation_count);
            _recovery_restarted = saturating_add(
                _recovery_restarted,
                _household_post_restarted_scratch[relative],
                _saturation_count);
            _recovery_failed = saturating_add(
                _recovery_failed,
                _household_post_failed_scratch[relative],
                _saturation_count);
        }
        _household_post_cursor = end;
        work_done += end - cursor_start;
        cursor_end = _household_post_cursor;
        building_range_used = true;
        if (_household_post_cursor >= static_cast<int32_t>(
                _epoch_building_cells.size())) {
            _household_post_cursor = 0;
            _household_market_phase = 2;
        }
        _household_slice_phase_ms[HOUSEHOLD_POST_BUILDINGS] +=
            elapsed_ms(phase_started);
        _household_slice_phase_work[HOUSEHOLD_POST_BUILDINGS] +=
            end - begin;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::ContinueFusing;
    }
    if (_household_market_phase == 2) {
        _executed_substage = "reserve_shortfall";
        const auto phase_started = Clock::now();
        cursor_start = _household_post_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_epoch_settlement_cells.size()),
            _household_post_cursor + PUBLISH_ENTRIES_PER_SLICE);
        const int32_t begin = _household_post_cursor;
        const int32_t count = end - begin;
        _household_reserve_shortfall_scratch.assign(count, 0);
        _household_post_saturation_scratch.assign(count, 0);
        const int32_t tasks = _worker_enabled && count >= 2 &&
                parallel_has_real_worker_threads()
            ? std::min(count, _worker_task_cap) : 1;
        auto accumulate_cells = [&](int32_t relative_begin,
                                    int32_t relative_end) {
            for (int32_t relative = relative_begin;
                 relative < relative_end; ++relative) {
                _household_reserve_shortfall_scratch[relative] =
                    production_reserve_shortfall_cell(
                        _epoch_settlement_cells[begin + relative],
                        _household_post_saturation_scratch[relative]);
            }
        };
        if (tasks > 1) {
            parallel_for_range("pk_economy_household_reserve", count,
                               tasks, 1, accumulate_cells);
        } else {
            accumulate_cells(0, count);
        }
        for (int32_t relative = 0; relative < count; ++relative) {
            _saturation_count = saturating_add(
                _saturation_count,
                _household_post_saturation_scratch[relative],
                _saturation_count);
            _production_input_reserve_shortfall = saturating_add(
                _production_input_reserve_shortfall,
                _household_reserve_shortfall_scratch[relative],
                _saturation_count);
        }
        _household_post_cursor = end;
        work_done += end - cursor_start;
        cursor_end = _household_post_cursor;
        cell_range_used = true;
        if (_household_post_cursor >= static_cast<int32_t>(
                _epoch_settlement_cells.size())) {
            _household_post_cursor = 0;
            _household_market_phase = 3;
        }
        _household_slice_phase_ms[HOUSEHOLD_RESERVE_SHORTFALL] +=
            elapsed_ms(phase_started);
        _household_slice_phase_work[HOUSEHOLD_RESERVE_SHORTFALL] +=
            end - begin;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::ContinueFusing;
    }
    if (_household_market_phase == 3) {
        _executed_substage = "income_subsidy";
        const auto phase_started = Clock::now();
        cursor_start = _household_post_cursor;
        const int32_t begin = _household_post_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_epoch_settlement_cells.size()),
            _household_post_cursor + PUBLISH_ENTRIES_PER_SLICE);
        for (; _household_post_cursor < end;
             ++_household_post_cursor) {
            const int32_t cell = _epoch_settlement_cells[_household_post_cursor];
            if ((_epoch_negative_tax_mask & static_cast<uint8_t>(
                    1U << CountryApi::TAX_INCOME)) != 0)
                settle_income_subsidies_for_cell(cell, _saturation_count);
            if ((_epoch_absolute_tax_mask & static_cast<uint8_t>(
                    (1U << CountryApi::TAX_INCOME) |
                    (1U << CountryApi::TAX_BUSINESS))) != 0)
                settle_absolute_daily_taxes_for_cell(cell, _saturation_count);
            ++work_done;
        }
        cursor_end = _household_post_cursor;
        cell_range_used = true;
        if (_household_post_cursor >= static_cast<int32_t>(
                _epoch_settlement_cells.size())) {
            _household_post_cursor = 0;
            _household_market_phase = 4;
        }
        {
            const double subsidy_ms = elapsed_ms(phase_started);
            _household_slice_phase_ms[HOUSEHOLD_INCOME_SUBSIDY] += subsidy_ms;
            _income_subsidy_epoch_ms += subsidy_ms;
        }
        _household_slice_phase_work[HOUSEHOLD_INCOME_SUBSIDY] +=
            end - begin;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::ContinueFusing;
    }
    if (_household_market_phase == 4) {
        _executed_substage = "structural_sort";
        const auto phase_started = Clock::now();
        if (_approximation_cooldown_epochs_left > 0) {
            --_approximation_cooldown_epochs_left;
        } else if (_accuracy_preset != 0 &&
                   _approximation_runtime_mode != 0 &&
                   _approximation_decisions > 0) {
            const bool low_prune_rate =
                _approximation_frontier_candidates <= 0 ||
                _approximation_frontier_pruned * 50 <
                    _approximation_frontier_candidates;
            _approximation_low_prune_epochs = low_prune_rate
                ? _approximation_low_prune_epochs + 1 : 0;
            const bool excessive_certificate_failures =
                _approximation_certificate_failures * 4 >
                    _approximation_decisions;
            if (_approximation_probe_violations > 0 ||
                excessive_certificate_failures ||
                _approximation_low_prune_epochs >= 2) {
                _approximation_cooldown_epochs_left =
                    _accuracy_fallback_cooldown_epochs;
                _approximation_low_prune_epochs = 0;
            }
        }
        _structural_commands.stable_sort(
                         [](const StructuralCommand &a, const StructuralCommand &b) {
            if (a.cell != b.cell) return a.cell < b.cell;
            const int32_t a_phase = a.opcode == STRUCTURAL_BIRTH ? 1 : 0;
            const int32_t b_phase = b.opcode == STRUCTURAL_BIRTH ? 1 : 0;
            if (a_phase != b_phase) return a_phase < b_phase;
            if (a.signature != b.signature) return a.signature < b.signature;
            if (a.sequence != b.sequence) return a.sequence < b.sequence;
            return a.source_slot < b.source_slot;
        });
        work_done += static_cast<int64_t>(_structural_commands.size());
        _household_slice_phase_ms[HOUSEHOLD_STRUCTURAL_SORT] +=
            elapsed_ms(phase_started);
        _household_slice_phase_work[HOUSEHOLD_STRUCTURAL_SORT] +=
            static_cast<int64_t>(_structural_commands.size());
        _household_market_phase = 0;
        publish_shadow_graph_stage_reference(
            RuntimeEconomyGraphStage::HOUSEHOLD_MARKET);
        _stage = Stage::GOVERNMENT_RESEARCH_PROCUREMENT;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::LeftStage;
    }
