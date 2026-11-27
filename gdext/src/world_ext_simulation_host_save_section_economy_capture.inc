    if (economy_input_lane_needed) {
        auto economy_input = std::make_shared<RuntimeEconomyDayInput>();
        economy_input->day = snapshot.day;
        economy_input->cell_count = static_cast<uint32_t>(cells);
        const char *fields[] = {"cell_temp", "cell_temp_30d", "cell_moisture",
            "cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
            "cell_weather_intensity", "cell_elevation", "cell_temp_365d"};
        auto copy_slot_f32 = [&](const char *name, std::vector<float> &dest) {
            const int sid = component_id(StringName(name));
            if (sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::F32 &&
                static_cast<size_t>(_slots[sid].arr_f32.size()) == cells) {
                const auto &array = _slots[sid].arr_f32;
                dest.assign(array.ptr(), array.ptr() + array.size());
            }
        };
        for (size_t i = 0; i < economy_input->fields.size(); ++i)
            copy_slot_f32(fields[i], economy_input->fields[i]);
        const char *climate_u8[] = {"cell_weather_type", "cell_cover"};
        for (size_t i = 0; i < economy_input->climate_u8.size(); ++i) {
            const int sid = component_id(StringName(climate_u8[i]));
            if (sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::U8 &&
                static_cast<size_t>(_slots[sid].arr_u8.size()) == cells) {
                const auto &array = _slots[sid].arr_u8;
                economy_input->climate_u8[i].assign(
                    array.ptr(), array.ptr() + array.size());
            }
        }
        const char *geography[] = {"cell_terrain", "cell_landform", "cell_vegetation",
            "cell_is_water", "cell_has_river"};
        for (size_t i = 0; i < 5; ++i) {
            const int sid = component_id(StringName(geography[i]));
            if (sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::U8 &&
                static_cast<size_t>(_slots[sid].arr_u8.size()) == cells) {
                const auto &array = _slots[sid].arr_u8;
                economy_input->geography[i].assign(array.ptr(), array.ptr() + array.size());
            }
        }
        // [neighbor-csr-to-dense 2026-11-02] 环境快照现在可能走 CSR 拓扑
        // (neighbor_offsets = cells+1, neighbor_indices = 总邻居数)，而经济 worker 的
        // 输入契约要求**稠密** cells*6 布局（消费方按 neighbors[cell*6+k] 取值），
        // 且 capture_worker_day_input() 直接用 `neighbors.size() != cells*6` 判失败
        // → world_clock.pause(true)，真机表现就是"日期停在 day 0"。
        // 这里在喂给经济输入时把 CSR 展开成稠密表，缺邻居填 -1（沿用稠密表的哨兵值）。
        economy_input->neighbors = snapshot.neighbor_indices;
        if (economy_input->neighbors.size() != static_cast<size_t>(cells) * 6u &&
            snapshot.neighbor_offsets.size() == static_cast<size_t>(cells) + 1u) {
            std::vector<int32_t> dense(static_cast<size_t>(cells) * 6u, -1);
            for (size_t c = 0; c < static_cast<size_t>(cells); ++c) {
                const int32_t begin = snapshot.neighbor_offsets[c];
                const int32_t end = snapshot.neighbor_offsets[c + 1];
                if (begin < 0 || end < begin) continue;
                size_t slot = 0;
                for (int32_t k = begin; k < end && slot < 6u; ++k, ++slot) {
                    if (static_cast<size_t>(k) >= snapshot.neighbor_indices.size()) break;
                    dense[c * 6u + slot] = snapshot.neighbor_indices[static_cast<size_t>(k)];
                }
            }
            economy_input->neighbors = std::move(dense);
        }
        economy_input->fog_solved = snapshot.fog_solved;
        economy_input->geography[5] = snapshot.visible;
        const auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
        const auto &reserve_slots = economy->building_resource_reserve_slots();
        const auto &extra_slots = economy->building_resource_extra_slots();
        economy_input->reserves.resize(reserve_slots.size());
        economy_input->changes.resize(extra_slots.size());
        if (!economy->worker_natural_resources_configured()) {
            for (size_t r = 0; r < reserve_slots.size(); ++r)
                copy_slot_f32(reserve_slots[r].c_str(), economy_input->reserves[r]);
            for (size_t r = 0; r < extra_slots.size(); ++r)
                copy_slot_f32(extra_slots[r].c_str(), economy_input->changes[r]);
        }
        const int habitat_sid = component_id(StringName("cell_resource_habitat_mask"));
        if (habitat_sid >= 0 && habitat_sid < _slots.size() &&
            _slots[habitat_sid].dtype == SlotDType::U8 &&
            static_cast<size_t>(_slots[habitat_sid].arr_u8.size()) == cells) {
            const auto &array = _slots[habitat_sid].arr_u8;
            economy_input->resource_habitat.assign(array.ptr(), array.ptr() + array.size());
        }
        snapshot.economy_input = std::move(economy_input);
    }
