// Naval travel validation with the shared military self-test fixture.

// Private self-tests included once by military_core_selftest.cpp.
bool test_naval_transport(const MilitaryTerrainInput &, std::string &report) {
    constexpr int32_t kBandRow = 10;                 // water rows 10..(10+band-1)
    constexpr int32_t kNorthShore = kBandRow - 1;    // land row just above the band
    const int32_t shore_north = cell_at(5, kNorthShore);
    std::string error;
    // ---- 1. no technology: water is refused at every tier
    {
        const MilitaryTerrainInput t3 =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformCoast);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4242, error) && core.set_terrain(t3, error),
                 "naval: configure + 3-water strait terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: country slot");
        const int32_t army = core.create_army(0, shore_north);
        ST_CHECK(army >= 0, "naval: army created on the north shore");
        const MilitaryWorldDigest locked = make_naval_digest(t3, 0ull);
        std::vector<int32_t> path;
        ST_CHECK(!core.find_path(army, cell_at(5, kBandRow + 3), locked, path),
                 "naval: no water technology -> find_path refuses a shallow strait");
        ST_CHECK(core.find_path(army, cell_at(9, kNorthShore), locked, path),
                 "naval: no water technology -> land routes are unaffected");
        std::vector<int32_t> cells;
        int32_t days = 0;
        core._last_digest = locked;
        ST_CHECK(!core.preview_path(core.army_handle(army), cell_at(5, kBandRow + 3), cells, days),
                 "naval: no water technology -> preview_path reports unreachable");
        // A lake needs a tier too; being small water does not make it free.
        const MilitaryTerrainInput lake =
            make_hex_terrain_with_water_band(kBandRow, 1, kLandformLake);
        ST_CHECK(core.set_terrain(lake, error), "naval: lake strait terrain");
        const MilitaryWorldDigest locked_lake = make_naval_digest(lake, 0ull);
        ST_CHECK(!core.find_path(army, cell_at(5, kBandRow + 1), locked_lake, path),
                 "naval: no water technology -> a one-cell lake is refused too");
    }
    // ---- 2. lake tier: lakes only, never the sea
    {
        const MilitaryTerrainInput lake =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformLake);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4243, error) && core.set_terrain(lake, error),
                 "naval: lake configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: lake country slot");
        const int32_t army = core.create_army(0, shore_north);
        const MilitaryWorldDigest lake_bits = make_naval_digest(lake, kLakeUnlock);
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, cell_at(5, kBandRow + 3), lake_bits, path),
                 "naval: river technology crosses a 3-cell lake");
        ST_CHECK((int32_t)path.size() == 4, "naval: the lake crossing is 3 water steps + 1 landing");
        const MilitaryTerrainInput shallow =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformCoast);
        ST_CHECK(core.set_terrain(shallow, error), "naval: shallow strait terrain");
        const MilitaryWorldDigest shallow_bits = make_naval_digest(shallow, kLakeUnlock);
        path.clear();
        ST_CHECK(!core.find_path(army, cell_at(5, kBandRow + 3), shallow_bits, path),
                 "naval: the lake tier does not open the shallow sea");
    }
    // ---- 3. shallow tier: any width, but not the far sea
    {
        // Six water cells in a row: the old run-length rule refused anything
        // above three. The tier gate must not care about the distance.
        const MilitaryTerrainInput wide =
            make_hex_terrain_with_water_band(kBandRow, 6, kLandformCoast);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4244, error) && core.set_terrain(wide, error),
                 "naval: six-cell shallow shelf terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: shelf country slot");
        const int32_t army = core.create_army(0, shore_north);
        const MilitaryWorldDigest shallow_bits = make_naval_digest(wide, kShallowUnlock);
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, cell_at(5, kBandRow + 6), shallow_bits, path),
                 "naval: the shallow tier crosses a six-cell shelf (no run limit)");
        ST_CHECK((int32_t)path.size() == 7, "naval: the shelf crossing is 6 water steps + 1 landing");
        const MilitaryTerrainInput far_band =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformOcean);
        ST_CHECK(core.set_terrain(far_band, error), "naval: far-sea strait terrain");
        const MilitaryWorldDigest far_bits = make_naval_digest(far_band, kShallowUnlock);
        path.clear();
        ST_CHECK(!core.find_path(army, cell_at(5, kBandRow + 3), far_bits, path),
                 "naval: the shallow tier does not open the far sea");
    }
    // ---- 4. far tier: the far sea opens, the deep sea does not
    {
        const MilitaryTerrainInput far_band =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformOcean);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4245, error) && core.set_terrain(far_band, error),
                 "naval: far-sea configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: far-sea country slot");
        const int32_t army = core.create_army(0, shore_north);
        const MilitaryWorldDigest far_bits = make_naval_digest(far_band, kFarUnlock);
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, cell_at(5, kBandRow + 3), far_bits, path),
                 "naval: celestial navigation crosses the far sea");
        const MilitaryTerrainInput deep =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformDeepOcean);
        ST_CHECK(core.set_terrain(deep, error), "naval: deep-sea terrain");
        const MilitaryWorldDigest deep_bits = make_naval_digest(deep, kFarUnlock);
        path.clear();
        ST_CHECK(!core.find_path(army, cell_at(5, kBandRow + 3), deep_bits, path),
                 "naval: the far-sea tier does not open the deep sea");
    }
    // ---- 5. deep tier nests over every lower tier
    {
        const MilitaryTerrainInput deep =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformDeepOcean);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4246, error) && core.set_terrain(deep, error),
                 "naval: deep-sea configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: deep-sea country slot");
        const int32_t army = core.create_army(0, shore_north);
        const MilitaryWorldDigest deep_bits = make_naval_digest(deep, kDeepUnlock);
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, cell_at(5, kBandRow + 3), deep_bits, path),
                 "naval: the deep-sea tier crosses the deep sea");
        for (uint8_t landform : {kLandformLake, kLandformCoast, kLandformOcean}) {
            const MilitaryTerrainInput lower =
                make_hex_terrain_with_water_band(kBandRow, 3, landform);
            ST_CHECK(core.set_terrain(lower, error), "naval: nested lower-tier terrain");
            const MilitaryWorldDigest nested = make_naval_digest(lower, kDeepUnlock);
            path.clear();
            ST_CHECK(core.find_path(army, cell_at(5, kBandRow + 3), nested, path),
                     "naval: the deep-sea tier keeps lakes, shallow and far water open");
        }
    }
    // ---- 6. preview_path days include the sea cost (contract §2.2)
    {
        const MilitaryTerrainInput t3 =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformCoast);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4247, error) && core.set_terrain(t3, error),
                 "naval: preview configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: preview country slot");
        const int32_t army = core.create_army(0, shore_north);
        core._last_digest = make_naval_digest(t3, kShallowUnlock);
        std::vector<int32_t> sea_cells;
        int32_t sea_days = 0;
        ST_CHECK(core.preview_path(core.army_handle(army), cell_at(5, kBandRow + 3), sea_cells, sea_days),
                 "naval: preview_path reaches the far shore with the shallow tier");
        ST_CHECK((int32_t)sea_cells.size() == 4 && sea_days == 6,
                 std::string("naval: 3 sea cells + 1 landing preview as 3*1.5+1 = 6 days | got cells=") +
                     std::to_string((int)sea_cells.size()) + " days=" + std::to_string(sea_days));
        std::vector<int32_t> land_cells;
        int32_t land_days = 0;
        ST_CHECK(core.preview_path(core.army_handle(army), cell_at(8, kNorthShore), land_cells, land_days),
                 "naval: preview_path plans a same-shore land route");
        ST_CHECK(land_days == (int32_t)land_cells.size() && land_days > 0,
                 "naval: land steps still preview as one day each");
        ST_CHECK(sea_days > land_days, "naval: a sea move costs more days than the land equivalent");
    }
    // ---- 7. crossing: forced EMBARKED, stance restored on landing, sea
    //         attrition at kSeaAttritionBp (0.2%/day) instead of land loss
    {
        const MilitaryTerrainInput t3 =
            make_hex_terrain_with_water_band(kBandRow, 3, kLandformCoast);
        MilitaryCore core;
        ST_CHECK(core.configure(make_naval_catalog(), 4248, error) && core.set_terrain(t3, error),
                 "naval: movement configure + terrain");
        ST_CHECK(core.ensure_country_slot(handle_for(0)) == 0, "naval: movement country slot");
        MilitaryWorldDigest d = make_naval_digest(t3, kShallowUnlock);
        core._last_digest = d;
        const int32_t army = core.create_army(0, shore_north);
        const int32_t lot = core.lot_find_or_create(MILITARY_LOT_ARMY, army, 0, 0, 256);
        core._lots.count[(size_t)lot] = 5000;
        core.refresh_army_cache(army);
        core._armies.stance[(size_t)army] = (uint8_t)MILITARY_STANCE_ADVANCE;
        std::vector<int32_t> path;
        ST_CHECK(core.find_path(army, cell_at(5, kBandRow + 3), d, path),
                 "naval: movement plans the crossing");
        core.assign_path(army, path);
        const int64_t heads_before = core._armies.cached_headcount[(size_t)army];
        int32_t sea_days = 0;
        int64_t expected_losses = 0;
        for (int32_t day = 0;
             day < 40 && core._armies.path_cursor[(size_t)army] < core._armies.path_len[(size_t)army];
             ++day) {
            const int64_t heads_day_before = core._armies.cached_headcount[(size_t)army];
            core._last_day = day;
            core.run_movement(d);
            const int32_t cell = core._armies.cell[(size_t)army];
            if (cell < 0 || (size_t)cell >= t3.is_water.size() || !t3.is_water[(size_t)cell]) continue;
            ++sea_days;
            ST_CHECK(core._armies.stance[(size_t)army] == (uint8_t)MILITARY_STANCE_EMBARKED,
                     "naval: an army standing on water is EMBARKED");
            // 20bp of the formation per day at sea = 2000 bp100 units of 1e-6.
            expected_losses += mul_div(heads_day_before * (int64_t)20 * 100, 1, 1000000);
        }
        ST_CHECK(sea_days >= 2, "naval: the crossing spent at least two days at sea");
        ST_CHECK(core._armies.cell[(size_t)army] == cell_at(5, kBandRow + 3),
                 "naval: the army landed on the far shore");
        ST_CHECK(core._armies.stance[(size_t)army] == (uint8_t)MILITARY_STANCE_ADVANCE,
                 "naval: landing restores the pre-embarkation stance");
        // 0.2%/day while the formation is on water, and the PLAIN land cell it
        // started from has no environment attrition, so the whole difference is
        // the sea loss.
        const int64_t heads_after = core._armies.cached_headcount[(size_t)army];
        ST_CHECK(expected_losses > 0 && heads_before - heads_after == expected_losses,
                 "naval: sea attrition is 0.2% of the formation per day at sea");
    }
    return true;
}
