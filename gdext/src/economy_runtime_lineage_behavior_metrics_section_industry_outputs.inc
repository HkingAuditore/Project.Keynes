    // Output-flow twin of sector_count. last_output is already net of
    // output_factor_q16, so this is the only sector aggregate that reacts when a
    // sector coefficient changes -- which is what lets an output-share
    // condition feed back on the effect that raised the coefficient.
    int64_t sector_output[5] = {0, 0, 0, 0, 0};
    int64_t total_output = 0;
    int64_t total_buildings = 0;
    int32_t manufacturing_groups = 0;
    int32_t knowledge_groups = 0;
    int32_t extractive_groups = 0;
    bool can_produce_corn = false;
    int32_t vacant_professions = 0;
    thread_local std::vector<uint8_t> demanded_professions;
    demanded_professions.clear();
    if (requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT))
        demanded_professions.assign(_profession_ids.size(), 0);
    const bool needs_building_scan =
        requested(FAMILY_METRIC_CELL_MANUFACTURING_BUILDING_COUNT) ||
        requested(FAMILY_METRIC_CELL_DISTINCT_SECTOR_COUNT) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_AGRICULTURE_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_EXTRACTIVE_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_MANUFACTURING_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_ENERGY_Q16) ||
        requested(FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_KNOWLEDGE_Q16) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16) ||
        requested(FAMILY_METRIC_CELL_HAS_EXTRACTIVE_RESOURCE) ||
        requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT) ||
        requested(FAMILY_METRIC_CELL_KNOWLEDGE_BUILDING_CLASS_COUNT) ||
        requested(FAMILY_METRIC_CELL_CAN_PRODUCE_CORN);
    const bool building_csr = _building_cell_offsets.size() ==
        static_cast<size_t>(_cell_count.get()) + 1;
    if (needs_building_scan && building_csr) {
        for (int32_t group_index = _building_cell_offsets[cell];
             group_index < _building_cell_offsets[cell + 1]; ++group_index) {
            const auto group = building_view(static_cast<size_t>(static_cast<size_t>(group_index)));
            if (group.count <= 0 || group.type_id < 0 ||
                group.type_id >= static_cast<int32_t>(_building_types.size()))
                continue;
            const int32_t sector = group.type_id < static_cast<int32_t>(
                    _building_economic_sectors.size())
                ? _building_economic_sectors[static_cast<size_t>(group.type_id)] : 2;
            if (sector >= 0 && sector < 5) {
                sector_count[sector] += group.count;
                total_buildings += group.count;
                if (group.last_output > 0) {
                    sector_output[sector] += group.last_output;
                    total_output += group.last_output;
                }
            }
            if (sector == 2) ++manufacturing_groups;
            if (sector == 4) ++knowledge_groups;
            if (sector == 1) ++extractive_groups;
            const BuildingType &type = _building_types[
                static_cast<size_t>(group.type_id)];
            if (requested(FAMILY_METRIC_CELL_CAN_PRODUCE_CORN) && _family_corn_good_id >= 0) {
                for (int32_t output = type.output_begin;
                     output < type.output_begin + type.output_count; ++output) {
                    if (_building_outputs[static_cast<size_t>(output)].good_id ==
                            _family_corn_good_id) {
                        can_produce_corn = true;
                        break;
                    }
                }
            }
            if (requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT))
            for (int32_t edge = type.labor_signal_begin;
                 edge < type.labor_signal_begin + type.labor_signal_count; ++edge) {
                if (edge < 0 || edge >= static_cast<int32_t>(
                        _building_type_labor_signal_professions.size()))
                    continue;
                const int32_t profession = _building_type_labor_signal_professions[
                    static_cast<size_t>(edge)];
                if (profession >= 0 &&
                    static_cast<size_t>(profession) < demanded_professions.size())
                    demanded_professions[static_cast<size_t>(profession)] = 1;
            }
        }
    }
    for (size_t profession = 0; profession < demanded_professions.size(); ++profession) {
        if (demanded_professions[profession] != 0 &&
            (profession >= employed_professions.size() ||
             employed_professions[profession] == 0))
            ++vacant_professions;
    }
    if (requested(FAMILY_METRIC_CELL_MANUFACTURING_BUILDING_COUNT))
        metrics[FAMILY_METRIC_CELL_MANUFACTURING_BUILDING_COUNT] =
            count_q16(manufacturing_groups);
    int32_t distinct_sectors = 0;
    int32_t dominant_sector = -1;
    int64_t dominant_owned = 0;
    for (int32_t sector = 0; sector < 5; ++sector) {
        if (sector_count[sector] <= 0) continue;
        ++distinct_sectors;
        if (sector_count[sector] > dominant_owned ||
            (sector_count[sector] == dominant_owned &&
             (dominant_sector < 0 || sector < dominant_sector))) {
            dominant_owned = sector_count[sector];
            dominant_sector = sector;
        }
    }
    if (requested(FAMILY_METRIC_CELL_DISTINCT_SECTOR_COUNT))
        metrics[FAMILY_METRIC_CELL_DISTINCT_SECTOR_COUNT] =
            count_q16(distinct_sectors);
    if (requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID))
        metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID] =
            dominant_sector < 0 ? -Q16_ONE : count_q16(dominant_sector);
    if (requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16))
        metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16] = total_buildings > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                dominant_owned * Q16_ONE / total_buildings, 0, Q16_ONE)) : 0;
    {
        // Output-share rows. Same bucket layout as sector_count above, but
        // weighted by last_output so a sector coefficient actually moves them.
        const int32_t sector_output_metric_ids[5] = {
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_AGRICULTURE_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_EXTRACTIVE_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_MANUFACTURING_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_ENERGY_Q16,
            FAMILY_METRIC_CELL_SECTOR_OUTPUT_SHARE_KNOWLEDGE_Q16,
        };
        int64_t dominant_output = 0;
        for (int32_t sector = 0; sector < 5; ++sector) {
            const int32_t share = total_output > 0
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    sector_output[sector] * Q16_ONE / total_output, 0, Q16_ONE))
                : 0;
            if (requested(sector_output_metric_ids[sector]))
                metrics[sector_output_metric_ids[sector]] = share;
            if (sector_output[sector] > dominant_output)
                dominant_output = sector_output[sector];
        }
        if (requested(FAMILY_METRIC_CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16))
            metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_OUTPUT_SHARE_Q16] =
                total_output > 0
                    ? static_cast<int32_t>(std::clamp<int64_t>(
                        dominant_output * Q16_ONE / total_output, 0, Q16_ONE))
                    : 0;
    }
    if (requested(FAMILY_METRIC_CELL_DOMINANT_RESOURCE_ID)) {
        const int32_t resource = dominant_resource_at(cell);
        metrics[FAMILY_METRIC_CELL_DOMINANT_RESOURCE_ID] =
            resource < 0 ? -Q16_ONE : count_q16(resource);
    }
    if (requested(FAMILY_METRIC_CELL_DOMINANT_RESOURCE_STOCK_SHARE_Q16))
        metrics[FAMILY_METRIC_CELL_DOMINANT_RESOURCE_STOCK_SHARE_Q16] =
            dominant_resource_stock_share_q16(cell);
    if (requested(FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID) ||
        requested(FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16)) {
        int32_t output_share = 0;
        const int32_t good = dominant_output_good_at(cell, output_share);
        if (requested(FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID))
            metrics[FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID] =
                good < 0 ? -Q16_ONE : count_q16(good);
        if (requested(FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16))
            metrics[FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16] = output_share;
    }
    if (requested(FAMILY_METRIC_CELL_NEIGHBOR_DISTINCT_GOODS)) {
        metrics[FAMILY_METRIC_CELL_NEIGHBOR_DISTINCT_GOODS] =
            cell >= 0 && cell < static_cast<int32_t>(
                _epoch_cell_neighbor_distinct_goods.size())
                ? count_q16(_epoch_cell_neighbor_distinct_goods[
                    static_cast<size_t>(cell)])
                : 0;
    }
