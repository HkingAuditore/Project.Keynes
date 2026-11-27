    // ── Tag predicates (target_tag.h) ───────────────────────────────────────
    //
    // The fixture already separates the two halves by dominant resource
    // (iron on the left, corn on the right) and by terrain. Landform is planted
    // here as a second, independent axis so a tag that ANDs the two axes cannot
    // accidentally match: left is landform 0, right is landform 1.

    // 30. Table validation. Each malformed shape must be rejected with its own
    //     reason -- a table that half-validates would crash the sampler instead.
    {
        auto make_row = [](int32_t metric, int32_t op, int64_t threshold,
                           int32_t clause) {
            TargetTagRow row;
            row.metric_id = metric;
            row.op = op;
            row.threshold_q16 = threshold;
            row.clause = clause;
            return row;
        };
        auto make_table = [&](TargetTagTable &table) {
             table.clear();
             table.names.push_back("iron");
             table.names.push_back("landform_one");
             table.offsets = {0, 1, 2};
             table.rows.push_back(make_row(43, TARGET_TAG_EQ, 0, 0));
             table.rows.push_back(make_row(10, TARGET_TAG_GTE, kQ16One, 0));
             return table;
        };
        TargetTagTable good;
        make_table(good);
        std::string reason;
        if (!expect(good.valid(reason), "tag_table_valid_accepts_well_formed", error))
            return false;
        if (!expect(good.count() == 2, "tag_table_count", error)) return false;

        TargetTagTable empty_table;
        if (!expect(empty_table.valid(reason), "tag_table_valid_accepts_empty", error))
            return false;

        // offsets must cover the names and land exactly on the row count.
        TargetTagTable bad_offsets = good;
        bad_offsets.offsets = {0, 1};
        if (!expect(!bad_offsets.valid(reason) &&
                    reason == "target_tag_offsets_shape_invalid",
                    "tag_table_rejects_offsets_shape", error)) return false;

        TargetTagTable bad_tail = good;
        bad_tail.offsets = {0, 1, 5};
        if (!expect(!bad_tail.valid(reason) &&
                    reason == "target_tag_offsets_bounds_invalid",
                    "tag_table_rejects_offsets_bounds", error)) return false;

        // A tag with no rows matches nothing, which reads as "my card is
        // broken". Reject it at compile time instead.
        TargetTagTable empty_tag = good;
        empty_tag.offsets = {0, 0, 2};
        if (!expect(!empty_tag.valid(reason) &&
                    reason == "target_tag_has_no_rows",
                    "tag_table_rejects_empty_tag", error)) return false;

        // Clauses must not decrease: matches() reads a smaller id as a new
        // clause and would silently turn AND into OR.
        TargetTagTable bad_clause = good;
        bad_clause.offsets = {0, 2, 2};
        bad_clause.rows[0].clause = 3;
        bad_clause.rows[1].clause = 1;
        if (!expect(!bad_clause.valid(reason) &&
                    reason == "target_tag_clause_not_sorted",
                    "tag_table_rejects_unsorted_clause", error)) return false;

        TargetTagTable bad_metric = good;
        bad_metric.rows[0].metric_id = -3;
        if (!expect(!bad_metric.valid(reason) &&
                    reason == "target_tag_metric_id_invalid",
                    "tag_table_rejects_negative_metric", error)) return false;

        TargetTagTable bad_op = good;
        bad_op.rows[0].op = TARGET_TAG_OP_COUNT;
        if (!expect(!bad_op.valid(reason) &&
                    reason == "target_tag_op_invalid",
                    "tag_table_rejects_bad_op", error)) return false;

        TargetTagTable duplicate = good;
        duplicate.names[1] = "iron";
        if (!expect(!duplicate.valid(reason) &&
                    reason == "target_tag_name_duplicate",
                    "tag_table_rejects_duplicate_name", error)) return false;

        // Half-written catalogs: rows/offsets without any names.
        TargetTagTable orphan_rows;
        orphan_rows.offsets = {0};
        orphan_rows.rows.push_back(make_row(43, TARGET_TAG_EQ, 0, 0));
        if (!expect(!orphan_rows.valid(reason) &&
                    reason == "target_tag_offsets_without_tags",
                    "tag_table_rejects_orphan_rows", error)) return false;
    }

    // 31-32. End-to-end through real metric sampling. Four tags over two axes:
    //        iron-only, landform-only, either (two clauses -> OR), and
    //        both-at-once (one clause, two rows -> AND, which is unsatisfiable
    //        on this fixture and therefore the sharpest AND test there is).
    //        Two more tags carry three rows in a single clause, because the card
    //        compiler can now fold 3+ tags into one synthetic tag (L4-12) and
    //        "AND over two rows" would not catch a loop that stops early.
    fill_snapshot();
    for (int32_t cell = 0; cell < kCells; ++cell) {
        rt->_epoch_cell_country[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
        // Landform 1 on the right half only, on the opposite axis to ownership
        // in one direction and aligned in the other: an implementation that
        // confuses "owned" with "tagged" fails a different assertion than one
        // that confuses the two axes.
        rt->_building_landform[static_cast<size_t>(cell)] =
            (cell % kCols) < kTerrainSplitCol ? 0 : 1;
    }
    rt->_epoch_country_count = 2;
    rt->rebuild_country_territory_index();
    {
        TargetTagTable tags;
        tags.names.push_back("iron");          // 0: resource id == iron
        tags.names.push_back("landform_one");  // 1: landform >= 1
        tags.names.push_back("either");        // 2: OR of the two above
        tags.names.push_back("impossible");    // 3: iron AND landform >= 1
        tags.names.push_back("three_way");     // 4: 3 rows, all satisfiable left
        tags.names.push_back("three_way_blocked");  // 5: 3 rows, third is false
        tags.offsets = {0, 1, 2, 4, 6, 9, 12};
        auto push = [&](int32_t metric, int32_t op, int64_t threshold,
                        int32_t clause) {
            TargetTagRow row;
            row.metric_id = metric;
            row.op = op;
            row.threshold_q16 = threshold;
            row.clause = clause;
            tags.rows.push_back(row);
        };
        // iron has dense id 0, so EQ(43, 0).
        push(43, TARGET_TAG_EQ, 0, 0);
        push(10, TARGET_TAG_GTE, kQ16One, 0);
        push(43, TARGET_TAG_EQ, 0, 0);
        push(10, TARGET_TAG_GTE, kQ16One, 1);
        push(43, TARGET_TAG_EQ, 0, 0);
        push(10, TARGET_TAG_GTE, kQ16One, 0);
        // Three rows, one clause. Left half: dominant resource is iron (43==0),
        // landform is 0, and the dominant stock share is 100/110 = 0.909.
        // The two tags differ only in the third row's threshold, so the only
        // way they can disagree is if the third row is actually evaluated.
        push(43, TARGET_TAG_EQ, 0, 0);
        push(10, TARGET_TAG_EQ, 0, 0);
        push(44, TARGET_TAG_GTE, kQ16One * 9 / 10, 0);
        push(43, TARGET_TAG_EQ, 0, 0);
        push(10, TARGET_TAG_EQ, 0, 0);
        push(44, TARGET_TAG_GTE, kQ16One * 95 / 100, 0);
        std::string tag_reason;
        if (!expect(tags.valid(tag_reason), "tag_fixture_valid", error))
            return false;
        rt->set_target_tags(tags);

        const int32_t left_cell = kInteriorCell;   // row 2, col 2 -> country 0
        const int32_t right_cell = cell_id(2, 4);  // row 2, col 4 -> country 1
        if (!expect(rt->target_tag_count() == 6, "tag_count_from_table", error))
            return false;

        // The bitset must agree with the selector: same source of truth, so a
        // mismatch means the memoised view diverged from the query path.
        if (!expect(rt->cell_has_target_tag(left_cell, 0), "tag_iron_left", error))
            return false;
        if (!expect(!rt->cell_has_target_tag(right_cell, 0),
                    "tag_iron_right_absent", error)) return false;
        if (!expect(rt->cell_has_target_tag(right_cell, 1),
                    "tag_landform_right", error)) return false;
        if (!expect(!rt->cell_has_target_tag(left_cell, 1),
                    "tag_landform_left_absent", error)) return false;
        // OR across clauses: every cell matches exactly one of the two axes.
        for (int32_t cell = 0; cell < kCells; ++cell)
            if (!expect(rt->cell_has_target_tag(cell, 2),
                        "tag_either_covers_grid", error)) return false;
        // AND within one clause: iron is left-only and landform 1 is
        // right-only, so the conjunction is unsatisfiable.
        for (int32_t cell = 0; cell < kCells; ++cell)
            if (!expect(!rt->cell_has_target_tag(cell, 3),
                        "tag_and_within_clause", error)) return false;

        // Three rows in one clause. `three_way` holds on exactly the left half
        // (six columns split 3/3, five rows); `three_way_blocked` differs only
        // in the third row's threshold, so any implementation that ANDs the
        // first two rows and stops would answer 15 for both.
        int32_t three_way_hits = 0;
        int32_t blocked_hits = 0;
        for (int32_t cell = 0; cell < kCells; ++cell) {
            if (rt->cell_has_target_tag(cell, 4)) ++three_way_hits;
            if (rt->cell_has_target_tag(cell, 5)) ++blocked_hits;
        }
        if (!expect(three_way_hits == 15, "tag_three_row_and_hits", error))
            return false;
        if (!expect(blocked_hits == 0, "tag_three_row_and_drops_third_row",
                    error)) return false;
        // ... and the same three-row tag through the selector, because the
        // bitset and the query path are two readers of one table.
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 5, out);
        if (!expect(out.size() == 15, "tag_three_row_selector", error))
            return false;
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 6, out);
        if (!expect(out.empty(), "tag_three_row_selector_blocked", error))
            return false;

        // 32. param1 is the 1-based tag id, and the tag filter is applied
        //     *inside* the owner's territory, so the same tag yields disjoint
        //     answers for the two countries.
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
        if (!expect(out.size() == 15, "tag_iron_own_territory_count", error))
            return false;
        if (!expect(all_cells_in_left_half(out), "tag_iron_own_territory_half",
                    error)) return false;
        rt->collect_effect_target_cells(
            right_cell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
        if (!expect(out.empty(), "tag_iron_foreign_territory_empty", error))
            return false;
        rt->collect_effect_target_cells(
            right_cell, ER::SELECTOR_OWN_TERRITORY, 32, 2, out);
        if (!expect(out.size() == 15, "tag_landform_own_territory_count", error))
            return false;
        for (const int32_t cell : out)
            if (!expect((cell % kCols) >= kTerrainSplitCol,
                        "tag_landform_own_territory_half", error)) return false;
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_OWN_TERRITORY, 32, 3, out);
        if (!expect(out.size() == 15, "tag_either_own_territory_count", error))
            return false;
        if (!expect(all_cells_in_left_half(out), "tag_either_own_territory_half",
                    error)) return false;
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_OWN_TERRITORY, 32, 4, out);
        if (!expect(out.empty(), "tag_impossible_empty", error)) return false;
        // param1 == 0 still means "no filter", unchanged by the tag table.
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_OWN_TERRITORY, 32, 0, out);
        if (!expect(out.size() == 15, "tag_no_filter_still_whole_territory", error))
            return false;

        // 32b. SELECTOR_TAG_ANY_CELL is the grid-wide twin of the same tag
        //      vocabulary. The decisive assertion is the first one: the very
        //      call that returned *empty* for OWN_TERRITORY from a foreign
        //      anchor (above, tag_iron_foreign_territory_empty) must return the
        //      full matching set here. If the two kinds ever share an
        //      implementation, one of the two fails.
        rt->collect_effect_target_cells(
            right_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 1, out);
        if (!expect(out.size() == 15, "tag_any_cell_ignores_owner", error))
            return false;
        if (!expect(all_cells_in_left_half(out), "tag_any_cell_iron_half", error))
            return false;
        // Same tag, opposite half, opposite anchor: the answer follows the tag
        // only, never the source cell.
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 2, out);
        if (!expect(out.size() == 15, "tag_any_cell_landform_count", error))
            return false;
        for (const int32_t cell : out)
            if (!expect((cell % kCols) >= kTerrainSplitCol,
                        "tag_any_cell_landform_half", error)) return false;
        // OR across clauses still means OR when the scope is the grid.
        rt->collect_effect_target_cells(
            right_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 3, out);
        if (!expect(out.size() == kCells, "tag_any_cell_either_covers_grid", error))
            return false;
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 4, out);
        if (!expect(out.empty(), "tag_any_cell_impossible_empty", error))
            return false;
        // param1 == 0 -> every cell on the grid, i.e. the whole map without a
        // territory restriction. This is what "所有海岸格" compiles to.
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 0, out);
        if (!expect(out.size() == kCells, "tag_any_cell_no_filter_whole_grid", error))
            return false;
        // Unknown tag ids fail closed instead of widening to the whole grid.
        // 7, not 5: param1 is the 1-based tag id and the fixture now carries
        // six tags, so 7 is the first id past the end.
        for (const int32_t bad_tag : {7, 77, 4096}) {
            rt->collect_effect_target_cells(
                left_cell, ER::SELECTOR_TAG_ANY_CELL, 32, bad_tag, out);
            if (!expect(out.empty(), "tag_any_cell_unknown_id", error)) return false;
        }
        // The cap keeps the lowest matching ids and stays sorted, and param0
        // above the ceiling is clamped exactly like the other kinds.
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_TAG_ANY_CELL, 7, 1, out);
        if (!expect(out.size() == 7, "tag_any_cell_cap_count", error)) return false;
        if (!expect(std::is_sorted(out.begin(), out.end()),
                    "tag_any_cell_cap_sorted", error)) return false;
        if (!expect(all_cells_in_left_half(out), "tag_any_cell_cap_in_tag", error))
            return false;
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_TAG_ANY_CELL,
            ER::SELECTOR_MAX_CELLS + 100, 1, out);
        if (!expect(out.size() == 15, "tag_any_cell_hard_clamp", error))
            return false;
        // A grid-wide card has no meaningful anchor, so the answer must not
        // depend on which cell happened to carry it.
        {
            std::vector<int32_t> reference;
            rt->collect_effect_target_cells(
                left_cell, ER::SELECTOR_TAG_ANY_CELL, 32, 3, reference);
            for (const int32_t anchor : {0, cell_id(0, 0), cell_id(4, 5),
                     cell_id(2, 4)}) {
                rt->collect_effect_target_cells(
                    anchor, ER::SELECTOR_TAG_ANY_CELL, 32, 3, out);
                if (!expect(out == reference,
                            "tag_any_cell_anchor_independent", error))
                    return false;
            }
        }

        // 33. Cap interacts with the tag: with only 4 matches allowed the
        //     selector must keep the lowest owned matching cells.
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_OWN_TERRITORY, 4, 1, out);
        if (!expect(out.size() == 4, "tag_cap_count", error)) return false;
        if (!expect(std::is_sorted(out.begin(), out.end()), "tag_cap_sorted", error))
            return false;

        // 34. Determinism across the memoised bitset.
        std::vector<int32_t> reference;
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_OWN_TERRITORY, 32, 1, reference);
        for (int32_t repeat = 0; repeat < 100; ++repeat) {
            rt->collect_effect_target_cells(
                left_cell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
            if (!expect(out == reference, "tag_deterministic", error)) return false;
        }

        // 35. A new table must invalidate the bitset. Tag 0 rewritten to
        //     "landform >= 1" would otherwise keep answering from the old bits.
        TargetTagTable rewritten;
        rewritten.names.push_back("landform_one");
        rewritten.offsets = {0, 1};
        TargetTagRow row;
        row.metric_id = 10;
        row.op = TARGET_TAG_GTE;
        row.threshold_q16 = kQ16One;
        row.clause = 0;
        rewritten.rows.push_back(row);
        rt->set_target_tags(rewritten);
        if (!expect(!rt->cell_has_target_tag(left_cell, 0),
                    "tag_table_swap_invalidates_bits", error)) return false;
        if (!expect(rt->cell_has_target_tag(right_cell, 0),
                    "tag_table_swap_recomputes", error)) return false;
        // And a table that declares nothing switches the filter back off
        // without leaving a bitset behind.
        rt->set_target_tags(TargetTagTable{});
        if (!expect(rt->target_tag_count() == 0, "tag_table_cleared", error))
            return false;
        if (!expect(!rt->cell_has_target_tag(left_cell, 0),
                    "tag_table_cleared_probe", error)) return false;
        rt->collect_effect_target_cells(
            left_cell, ER::SELECTOR_OWN_TERRITORY, 32, 1, out);
        if (!expect(out.empty(), "tag_table_cleared_selector", error)) return false;
    }
