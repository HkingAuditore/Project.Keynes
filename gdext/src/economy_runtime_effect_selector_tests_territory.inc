    // 17. Out-of-range slots and indices never read past their slice.
    for (const int32_t bad_slot : {-1, 2, 9}) {
        if (!expect(rt->country_cell_count(bad_slot) == 0,
                    "territory_count_out_of_range", error)) return false;
        if (!expect(rt->country_cell_at(bad_slot, 0) == -1,
                    "territory_cell_at_out_of_range", error)) return false;
        if (!expect(rt->country_anchor_cell(bad_slot) == -1,
                    "territory_anchor_out_of_range", error)) return false;
    }
    for (const int32_t bad_index : {-1, 15, 99}) {
        if (!expect(rt->country_cell_at(0, bad_index) == -1,
                    "territory_index_out_of_range", error)) return false;
    }

    // 18-19. The territory selector answers with the owner's cells only. A hex
    //        walk from either anchor can never produce the opposite half, so the
    //        expected sets are exact rather than merely capped.
    {
        std::vector<int32_t> expected_left;
        std::vector<int32_t> expected_right;
        for (int32_t cell = 0; cell < kCells; ++cell) {
            if ((cell % kCols) < kTerrainSplitCol) expected_left.push_back(cell);
            else expected_right.push_back(cell);
        }
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
        if (!expect(out == expected_left, "territory_selector_left_set", error))
            return false;
        rt->collect_effect_target_cells(
            cell_id(2, 4), ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
        if (!expect(out == expected_right, "territory_selector_right_set", error))
            return false;
    }

    // 20. Cap keeps the lowest cell ids of the owner, never a foreign cell.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 7, 0, out);
    if (!expect(out.size() == 7, "territory_selector_cap_count", error))
        return false;
    if (!expect(std::is_sorted(out.begin(), out.end()),
                "territory_selector_cap_sorted", error)) return false;
    if (!expect(all_cells_in_left_half(out),
                "territory_selector_cap_in_territory", error)) return false;
    // param0 above the hard ceiling is clamped, same as every other kind.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY,
        ER::SELECTOR_MAX_CELLS + 100, 0, out);
    if (!expect(out.size() == 15, "territory_selector_hard_clamp", error))
        return false;

    // 21. With no tag table installed, a param1 filter must yield nothing rather
    //     than degrade to "every owned cell". Fail-closed matters here: a card
    //     whose tag was renamed would otherwise quietly start hitting the whole
    //     country. SELECTOR_PREDICATE_ANY_CELL over the same snapshot keeps its
    //     grid-wide answer, which is the behaviour existing content depends on.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
    if (!expect(out.empty(), "territory_tag_without_table", error)) return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_PREDICATE_ANY_CELL, 32, 1, out);
    if (!expect(out.size() == 6, "territory_grid_kind_still_wide", error))
        return false;
    // The grid-wide tag kind is fail-closed too: with no table a filtered call
    // yields nothing, while an unfiltered one (param1 == 0) still means "the
    // whole grid" because it asks no tag question at all.
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_TAG_ANY_CELL, 32, 1, out);
    if (!expect(out.empty(), "tag_any_cell_without_table", error)) return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_TAG_ANY_CELL, 32, 0, out);
    if (!expect(out.size() == kCells, "tag_any_cell_unfiltered_no_table", error))
        return false;

    // 22. An unknown tag id is rejected rather than treated as "match all".
    for (const int32_t bad_tag : {5, 77, 4096}) {
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, bad_tag, out);
        if (!expect(out.empty(), "territory_tag_unknown_id", error)) return false;
    }

    // 23. Dropping the index must not change any answer: the linear fallback has
    //     to agree with the CSR byte for byte, or a fixture-built runtime and a
    //     live epoch would behave differently.
    {
        std::vector<int32_t> indexed;
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, indexed);
        const int32_t indexed_count = rt->country_cell_count(0);
        const int32_t indexed_anchor = rt->country_anchor_cell(1);
        rt->_epoch_country_cell_offsets.clear();
        rt->_epoch_country_cells.clear();
        if (!expect(!rt->country_territory_index_ready(),
                    "territory_index_cleared", error)) return false;
        std::vector<int32_t> scanned;
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, scanned);
        if (!expect(scanned == indexed, "territory_fallback_matches_index", error))
            return false;
        if (!expect(rt->country_cell_count(0) == indexed_count,
                    "territory_fallback_count", error)) return false;
        if (!expect(rt->country_anchor_cell(1) == indexed_anchor,
                    "territory_fallback_anchor", error)) return false;
    }

    // 24. Unowned cells belong to nobody. A negative slot must never appear in
    //     any country's slice, and the counts must drop accordingly.
    fill_snapshot();
    for (int32_t cell = 0; cell < kCells; ++cell)
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    for (int32_t col = 0; col < kCols; ++col)
        rt->_epoch_cell_country[static_cast<size_t>(cell_id(0, col))] = -1;
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    if (!expect(rt->country_cell_count(0) == 12, "territory_unowned_left", error))
        return false;
    if (!expect(rt->country_cell_count(1) == 12, "territory_unowned_right", error))
        return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    for (const int32_t cell : out) {
        if (!expect((cell % kCols) < kTerrainSplitCol,
                    "territory_excludes_unowned_row", error)) return false;
        if (!expect((cell / kCols) != 0,
                    "territory_skips_unowned_cells", error)) return false;
    }
    // A country that owns nothing is a legal state, not an error. Country 0 has
    // been emptied while country 1 now owns the whole grid, so the two answers
    // must differ: 0 cells / no anchor for the empty slot, and the full grid for
    // the slot that actually holds the source cell.
    rt->_epoch_cell_country.assign(static_cast<size_t>(kCells), 1);
    rt->rebuild_country_territory_index();
    if (!expect(rt->country_cell_count(0) == 0, "territory_empty_count", error))
        return false;
    if (!expect(rt->country_anchor_cell(0) == -1, "territory_empty_anchor", error))
        return false;
    if (!expect(rt->country_cell_at(0, 0) == -1, "territory_empty_cell_at", error))
        return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    if (!expect(out.size() == static_cast<size_t>(kCells),
                "territory_single_owner_covers_grid", error)) return false;
    // An unowned source cell has no country to enumerate, so the selector keeps
    // the pre-existing "resolve to the anchor only" contract instead of
    // inventing a territory. This is the only path that still returns the source.
    rt->_epoch_cell_country[static_cast<size_t>(kInteriorCell)] = -1;
    rt->rebuild_country_territory_index();
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    if (!expect(out.size() == 1 && out[0] == kInteriorCell,
                "territory_unowned_source_anchor", error)) return false;

    // 25. Territory is an ownership question, so it must survive a missing
    //     building snapshot. The radial kinds correctly return nothing there;
    //     conflating the two would make territory effects vanish between an
    //     epoch capture and the first building refresh.
    fill_snapshot();
    for (int32_t cell = 0; cell < kCells; ++cell)
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    rt->_building_neighbors.clear();
    rt->_building_terrain.clear();
    rt->_building_is_water.clear();
    rt->_building_has_river.clear();
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
    if (!expect(out.size() == 15, "territory_needs_no_building_snapshot", error))
        return false;
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
    if (!expect(out.empty(), "territory_tag_without_table_after_column_clear", error))
        return false;

    // 26. Determinism: territory must be a pure function of the snapshot too.
    fill_snapshot();
    for (int32_t cell = 0; cell < kCells; ++cell)
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    {
        std::vector<int32_t> reference;
        rt->collect_effect_target_cells(
            kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, reference);
        for (int32_t repeat = 0; repeat < 100; ++repeat) {
            rt->collect_effect_target_cells(
                kInteriorCell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
            if (!expect(out == reference, "territory_deterministic", error))
                return false;
        }
    }

    // 27-29. Degenerate snapshots degrade to "no targets" instead of crashing
    //        or indexing past the end of a shorter column.
    fill_snapshot();
    rt->_building_neighbors.clear();
    rt->collect_effect_target_cells(kInteriorCell, ER::SELECTOR_NEIGHBORS_R1, 0, 0, out);
    if (!expect(out.empty(), "selector_missing_neighbors", error)) return false;

    fill_snapshot();
    rt->_building_terrain.clear();
    rt->collect_effect_target_cells(
        kInteriorCell, ER::SELECTOR_SAME_TERRAIN_COMPONENT, 8, 0, out);
    if (!expect(out.empty(), "selector_missing_terrain_column", error)) return false;

    // Out-of-range sources never yield a cell, including the cell_count edge.
    fill_snapshot();
    for (const int32_t bad : {-7, -1, kCells, kCells + 9}) {
        rt->collect_effect_target_cells(bad, ER::SELECTOR_NEIGHBORS_R1, 0, 0, out);
        if (!expect(out.empty(), "selector_source_out_of_range", error)) return false;
    }
