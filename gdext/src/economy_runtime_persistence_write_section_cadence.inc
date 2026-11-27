    if (_save.section == SAVE_SECTION_CADENCE_STATE) {
        constexpr int32_t record_bytes = 50;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.cadence_cursor;
        const int32_t end = std::min(_cell_count.get(), begin + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - begin)) *
                        record_bytes);
        for (; _save.cadence_cursor < end; ++_save.cadence_cursor) {
            const size_t cell = static_cast<size_t>(_save.cadence_cursor);
            append_le<int32_t>(payload, _save.cadence_cursor);
            append_le<uint8_t>(payload,
                cell < _cell_tier.size() ? _cell_tier[cell] : uint8_t{1});
            append_le<int64_t>(payload,
                cell < _cell_next_review_day.size()
                    ? _cell_next_review_day[cell] : _last_committed_day.get());
            append_le<uint8_t>(payload,
                cell < _cell_force_wake.size() ? _cell_force_wake[cell] : 0);
            append_le<uint32_t>(payload,
                cell < _cell_tier_seen_gen.size() ? _cell_tier_seen_gen[cell] : 0);
            append_le<int64_t>(payload,
                cell < _cell_tier_seen_population.size()
                    ? _cell_tier_seen_population[cell] : -1);
            append_le<int64_t>(payload,
                cell < _cell_tier_change_day.size()
                    ? _cell_tier_change_day[cell] : _last_committed_day.get());
            append_le<int64_t>(payload,
                cell < _cell_shortage_since_day.size()
                    ? _cell_shortage_since_day[cell] : -1);
            append_le<int32_t>(payload,
                cell < _cell_effect_shortage_q16.size()
                    ? _cell_effect_shortage_q16[cell] : 0);
            append_le<int32_t>(payload,
                cell < _cell_essentials_shortage_q16.size()
                    ? _cell_essentials_shortage_q16[cell] : 0);
        }
        if (_save.cadence_cursor >= _cell_count.get()) {
            // Optional v52 footer. Older v52 streams end after the fixed-size
            // cell records; readers accept both layouts.
            append_le<uint64_t>(payload, _committed_generation);
            // Track-B carries. They are approximation caches, but the next
            // day's result depends on them, so a restored world must resume
            // with the same contents or it diverges from the original.
            append_le<uint32_t>(payload, static_cast<uint32_t>(
                _track_b_investment_cells_pending.size()));
            for (const int32_t cell : _track_b_investment_cells_pending)
                append_le<int32_t>(payload, cell);
            append_le<int64_t>(payload, _track_b_derived_cell_cache_day);
            append_le<uint32_t>(payload, static_cast<uint32_t>(
                _track_b_derived_cell_cache.size()));
            for (const TrackBDerivedCellWork &work : _track_b_derived_cell_cache) {
                append_le<uint8_t>(payload, work.seeded ? 1 : 0);
                append_le<int64_t>(payload, work.edges);
                append_le<uint64_t>(payload, work.startup_calls);
                append_le<uint64_t>(payload, work.enqueued_goods);
                append_le<uint32_t>(payload, static_cast<uint32_t>(work.goods.size()));
                for (size_t i = 0; i < work.goods.size(); ++i) {
                    append_le<int32_t>(payload, work.goods[i]);
                    append_le<int64_t>(payload, work.quantities[i]);
                    append_le<int64_t>(payload,
                        i < work.anchors.size() ? work.anchors[i] : 0);
                }
            }
            // Military writes the garrison ration once per day; the next day's
            // market reads it, so it belongs to the saved boundary.
            uint32_t ration_cells = 0;
            for (const uint8_t present : _military_ration_sat_present)
                ration_cells += present != 0 ? 1u : 0u;
            append_le<uint32_t>(payload, ration_cells);
            for (size_t c = 0; c < _military_ration_sat_present.size(); ++c) {
                if (_military_ration_sat_present[c] == 0) continue;
                append_le<int32_t>(payload, static_cast<int32_t>(c));
                append_le<int32_t>(payload, _military_ration_sat_q16[c]);
            }
            _save.section = SCHEMA_VERSION >= 53
                ? SAVE_SECTION_D7_PEER_EXT
                : SAVE_SECTION_END;
        }
        return make_save_chunk(SAVE_SECTION_CADENCE_STATE,
            static_cast<uint32_t>(_save.cadence_cursor - begin), payload);
    }
