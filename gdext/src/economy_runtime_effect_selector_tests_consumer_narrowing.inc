    // Consumer narrowing changes the work done, not the predicates' answers.
    // These expectations come from the fixture's columns, independently of a
    // second call to the optimized sampler. Unsubscribed tags deliberately have
    // no published bits; an absent consumer declaration or an unnamed tag set
    // still means "build all tags".
    {
        fill_snapshot();
        rt->_epoch_country_count = 1;
        for (int32_t cell = 0; cell < kCells; ++cell)
            rt->_building_landform[static_cast<size_t>(cell)] =
                (cell % kCols) >= kTerrainSplitCol ? 1 : 0;
        TargetTagTable tags;
        tags.names = {"landform_one", "resource_zero", "resource_majority"};
        tags.offsets = {0, 1, 2, 3};
        for (const auto &definition : std::array<std::array<int64_t, 3>, 3>{{
                {{10, TARGET_TAG_GTE, kQ16One}},
                {{43, TARGET_TAG_EQ, 0}},
                {{44, TARGET_TAG_GTE, kQ16One * 9 / 10}},
            }}) {
            TargetTagRow row;
            row.metric_id = static_cast<int32_t>(definition[0]);
            row.op = static_cast<int32_t>(definition[1]);
            row.threshold_q16 = definition[2];
            row.clause = 0;
            tags.rows.push_back(row);
        }
        rt->set_target_tags(tags);
        const auto check_bits = [&](bool landform, bool resource, bool majority) {
            for (int32_t cell = 0; cell < kCells; ++cell) {
                const bool left = (cell % kCols) < kTerrainSplitCol;
                if (!expect(rt->cell_has_target_tag(cell, 0) ==
                                (landform && !left),
                            "tag_consumers_landform_exact", error) ||
                    !expect(rt->cell_has_target_tag(cell, 1) ==
                                (resource && left),
                            "tag_consumers_resource_exact", error) ||
                    !expect(rt->cell_has_target_tag(cell, 2) == majority,
                            "tag_consumers_share_exact", error))
                    return false;
            }
            return true;
        };
        if (!check_bits(true, true, true)) return false;

        std::array<std::vector<int64_t>,
            NativeEconomyRuntime::FAMILY_METRIC_COUNT> thresholds{};
        const MetricMask no_metrics;
        rt->set_effect_input_consumers(no_metrics, true, false, thresholds, {0});
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(true, false, false)) return false;
        rt->collect_effect_target_cells(kInteriorCell,
            ER::SELECTOR_TAG_ANY_CELL, 32, 2, out);
        if (!expect(out.empty(), "tag_unsubscribed_query_has_no_bits", error))
            return false;
        rt->collect_effect_target_cells(kInteriorCell,
            ER::SELECTOR_TAG_ANY_CELL, 32, 4, out);
        if (!expect(out.empty(), "tag_unknown_query_has_no_bits", error))
            return false;

        // A direct diagnostic sample is not limited by the consumer tag list.
        // Reuse the output across different cells and masks to catch old values
        // retained in scratch storage, including a deliberately empty request.
        std::array<int64_t, NativeEconomyRuntime::FAMILY_METRIC_COUNT> full{};
        std::array<int64_t, NativeEconomyRuntime::FAMILY_METRIC_COUNT> selected{};
        for (const int32_t cell : {kInteriorCell, cell_id(2, 4), kInteriorCell}) {
            rt->sample_effect_metrics(cell, full.size(), full.data());
            const bool left = (cell % kCols) < kTerrainSplitCol;
            if (!expect(full[10] == (left ? 0 : kQ16One) &&
                        full[43] == (left ? 0 : kQ16One) &&
                        full[44] >= kQ16One * 9 / 10 &&
                        full[44] < kQ16One * 95 / 100,
                        "tag_direct_all_metrics_ignore_consumers", error))
                return false;
            for (const int32_t requested : {10, 43, 44, -1}) {
                selected.fill(-123456);
                MetricMask mask;
                if (requested >= 0) mask.set(requested);
                rt->sample_effect_metrics(cell, selected.size(), selected.data(), mask);
                for (int32_t metric = 0; metric < static_cast<int32_t>(
                        selected.size()); ++metric)
                    if (!expect(selected[metric] ==
                                    (metric == requested ? full[metric] : 0),
                                "tag_metric_mask_exact_and_zeroed", error))
                        return false;
            }
        }

        rt->set_effect_input_consumers(no_metrics, true, false, thresholds, {1, 2});
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(false, true, true)) return false;
        rt->set_effect_input_consumers(no_metrics, true, false, thresholds);
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(true, true, true)) return false;
        rt->set_effect_input_consumers(no_metrics, false, false, thresholds);
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(false, false, false)) return false;
        rt->set_effect_input_consumers(no_metrics, true, false, thresholds, {0});
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(true, false, false)) return false;

        // A fresh, smaller world on this thread must not inherit the previous
        // consumer set or per-resource working storage. With no resources,
        // dominant-resource id is -1 and share is 0, not the previous world's 0/1.
        auto other = std::make_unique<NativeEconomyRuntime>();
        other->_cell_count = 1;
        other->_epoch_country_count = 1;
        other->_epoch_cell_country.assign(1, 0);
        other->_building_landform.assign(1, 1);
        other->set_target_tags(tags);
        if (!expect(other->cell_has_target_tag(0, 0) &&
                    !other->cell_has_target_tag(0, 1) &&
                    !other->cell_has_target_tag(0, 2),
                    "tag_new_world_does_not_reuse_metrics", error))
            return false;
        other->sample_effect_metrics(0, full.size(), full.data());
        if (!expect(full[10] == kQ16One && full[43] == -kQ16One &&
                    full[44] == 0, "tag_new_world_direct_metrics", error))
            return false;
        other->_building_landform[0] = 0;
        other->rebuild_epoch_tag_snapshot();
        if (!expect(!other->cell_has_target_tag(0, 0), "tag_geography_changed", error))
            return false;
        other->set_effect_metric_override(10, kQ16One, true);
        other->rebuild_epoch_tag_snapshot();
        if (!expect(other->cell_has_target_tag(0, 0), "tag_geography_overridden", error))
            return false;
        other->set_effect_metric_override(10, 0, false);
        other->rebuild_epoch_tag_snapshot();
        if (!expect(!other->cell_has_target_tag(0, 0), "tag_geography_override_cleared", error))
            return false;
        if (!check_bits(true, false, false)) return false;

        // Operation counts, rather than elapsed milliseconds, prove that the
        // narrowed request stops computing the two unused catalogue metrics.
        // Keep this after the value assertions: an older library can preserve
        // every answer while lacking the new optimization diagnostics.
        const auto check_work = [&](int64_t metrics, int64_t sampled_cells,
                                    int64_t catalog_metrics) {
            const godot::Dictionary report = rt->report();
            return
                static_cast<int64_t>(report.get("tag_snapshot_requested_metrics", -1)) ==
                    metrics &&
                static_cast<int64_t>(report.get("tag_snapshot_sampled_cells", -1)) ==
                    sampled_cells &&
                static_cast<int64_t>(report.get("tag_catalog_metrics", -1)) ==
                    catalog_metrics;
        };
        tag_work_matches &= check_work(1, kCells, 3);
        rt->set_effect_input_consumers(no_metrics, true, false, thresholds, {1, 2});
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(false, true, true)) return false;
        tag_work_matches &= check_work(2, kCells, 3);
        rt->set_effect_input_consumers(no_metrics, true, false, thresholds);
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(true, true, true)) return false;
        tag_work_matches &= check_work(3, kCells, 3);
        rt->set_effect_input_consumers(no_metrics, false, false, thresholds);
        rt->rebuild_epoch_tag_snapshot();
        if (!check_bits(false, false, false)) return false;
        tag_work_matches &= check_work(0, 0, 0);
    }

    // Profession accumulators are reused by the sampler. Give the same calling
    // thread populated, empty, and differently sized worlds, so clearing an
    // output row alone cannot hide retained population inside those arrays.
    {
        auto people = std::make_unique<NativeEconomyRuntime>();
        people->_cell_count = 2;
        people->_profession_ids.push_back("household_farmer");
        people->_profession_ids.push_back("industrial_worker");
        people->_profession_ids.push_back("cooperative_member");
        people->_signatures.resize(3);
        auto &population = people->population_store();
        population.clear(2);
        for (int32_t profession = 0; profession < 3; ++profession) {
            people->_signatures[static_cast<size_t>(profession)].profession_id = profession;
            const int32_t slot = population.allocate_slot(0, profession);
            if (!expect(slot >= 0, "metric_scratch_population_allocates", error))
                return false;
            const int64_t count = profession == 0 ? 60 : profession == 1 ? 30 : 10;
            population.population.write_scalar(slot, count);
            population.employee_employed.write_scalar(slot, count);
        }
        constexpr std::array<int32_t, 6> ids{{51, 52, 53, 96, 97, 98}};
        const std::array<int64_t, 6> expected{{0, 60 * kQ16One / 100,
            3 * kQ16One, 60 * kQ16One / 100, 30 * kQ16One / 100,
            10 * kQ16One / 100}};
        std::array<int64_t, NativeEconomyRuntime::FAMILY_METRIC_COUNT> values{};
        people->sample_effect_metrics(0, values.size(), values.data());
        for (size_t i = 0; i < ids.size(); ++i)
            if (!expect(values[ids[i]] == expected[i],
                        "metric_scratch_full_profession_values", error))
                return false;
        // Move from a full sample to one requested share, then to an empty cell.
        // Repeat after another world has resized the per-thread scratch below.
        const auto check_people = [&]() {
            MetricMask share;
            share.set(97);
            people->sample_effect_metrics(0, values.size(), values.data(), share);
            for (size_t metric = 0; metric < values.size(); ++metric)
                if (!expect(values[metric] ==
                                (metric == 97 ? 30 * kQ16One / 100 : 0),
                            "metric_scratch_narrow_share_values", error))
                    return false;
            people->sample_effect_metrics(1, values.size(), values.data());
            for (const int32_t metric : ids)
                if (!expect(values[metric] == (metric == 51 ? -kQ16One : 0),
                            "metric_scratch_empty_cell_values", error))
                    return false;
            return true;
        };
        if (!check_people()) return false;
        auto single = std::make_unique<NativeEconomyRuntime>();
        single->_cell_count = 1;
        single->_profession_ids.push_back("cooperative_member");
        single->_signatures.resize(1);
        single->_signatures[0].profession_id = 0;
        auto &single_population = single->population_store();
        single_population.clear(1);
        const int32_t slot = single_population.allocate_slot(0, 0);
        if (!expect(slot >= 0, "metric_scratch_second_world_allocates", error))
            return false;
        single_population.population.write_scalar(slot, 7);
        single_population.employee_employed.write_scalar(slot, 7);
        single->sample_effect_metrics(0, values.size(), values.data());
        const std::array<int64_t, 6> single_expected{{
            0, kQ16One, kQ16One, 0, 0, kQ16One}};
        for (size_t i = 0; i < ids.size(); ++i)
            if (!expect(values[ids[i]] == single_expected[i],
                        "metric_scratch_second_world_values", error))
                return false;
        if (!check_people()) return false;
    }
