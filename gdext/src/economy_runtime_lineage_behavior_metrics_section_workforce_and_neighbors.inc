    // Scratch is private to the calling thread, and no reader retains it.
    // Clear the logical sizes on every call so a different metric mask or
    // another world on the same thread cannot reuse previous-cell values.
    // The optional recursive full-metric check runs after these arrays' last use.
    thread_local std::vector<uint8_t> employed_professions;
    employed_professions.clear();
    // X3: the profession mix needs per-profession population, which is the same
    // walk the unemployment rows already do. One extra accumulator beats a
    // second pass over the cell's cohorts.
    const bool wants_dominant_profession =
        requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_ID) ||
        requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_SHARE_Q16) ||
        requested(FAMILY_METRIC_CELL_PROFESSION_COUNT);
    const bool wants_profession_shares =
        requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_FARMER_Q16) ||
        requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_INDUSTRIAL_Q16) ||
        requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_COOPERATIVE_Q16);
    const bool wants_profession_mix =
        wants_dominant_profession || wants_profession_shares;
    thread_local std::vector<int64_t> profession_people;
    thread_local std::vector<int64_t> employed_profession_people;
    profession_people.clear();
    employed_profession_people.clear();
    if ((requested(FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16) ||
        requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT) ||
        requested(FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16) ||
        wants_profession_mix) &&
        static_cast<size_t>(cell) < population_store().cell_first_page.size() &&
        population_store().cell_first_page[cell] >= 0) {
        if (requested(FAMILY_METRIC_CELL_VACANT_PROFESSION_COUNT))
            employed_professions.assign(_profession_ids.size(), 0);
        if (wants_profession_mix)
            profession_people.assign(_profession_ids.size(), 0);
        if (wants_dominant_profession)
            employed_profession_people.assign(_profession_ids.size(), 0);
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t people = std::max<int64_t>(0, population_store().population[slot]);
            cell_population += people;
            const int64_t employed = std::max<int64_t>(0,
                population_store().owner_employed[slot]) +
                std::max<int64_t>(0, population_store().employee_employed[slot]);
            cell_employed += employed;
            cell_funds += std::max<int64_t>(0, population_store().funds[slot]);
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[slot]);
            if (signature < 0 ||
                signature >= static_cast<int32_t>(_signatures.size()))
                return;
            const int32_t profession = _signatures[
                static_cast<size_t>(signature)].profession_id;
            if (profession < 0) return;
            if (static_cast<size_t>(profession) < profession_people.size())
                profession_people[static_cast<size_t>(profession)] += people;
            if (employed <= 0) return;
            if (static_cast<size_t>(profession) < employed_professions.size())
                employed_professions[static_cast<size_t>(profession)] = 1;
            if (static_cast<size_t>(profession) <
                    employed_profession_people.size())
                employed_profession_people[static_cast<size_t>(profession)] +=
                    people;
        });
    }
    if (wants_dominant_profession) {
        int64_t total_people = 0;
        int64_t best_people = 0;
        int32_t best_profession = -1;
        int32_t profession_count = 0;
        for (size_t profession = 0;
             profession < employed_profession_people.size(); ++profession) {
            const int64_t people = employed_profession_people[profession];
            if (people <= 0) continue;
            ++profession_count;
            total_people += people;
            if (people > best_people) {
                best_people = people;
                best_profession = static_cast<int32_t>(profession);
            }
        }
        if (requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_ID))
            metrics[FAMILY_METRIC_CELL_DOMINANT_PROFESSION_ID] =
                best_profession < 0 ? -Q16_ONE : count_q16(best_profession);
        if (requested(FAMILY_METRIC_CELL_DOMINANT_PROFESSION_SHARE_Q16))
            metrics[FAMILY_METRIC_CELL_DOMINANT_PROFESSION_SHARE_Q16] =
                total_people > 0
                    ? std::clamp<int64_t>(best_people * Q16_ONE / total_people,
                        0, Q16_ONE)
                    : 0;
        if (requested(FAMILY_METRIC_CELL_PROFESSION_COUNT))
            metrics[FAMILY_METRIC_CELL_PROFESSION_COUNT] = count_q16(profession_count);
    }
    if (wants_profession_shares) {
        int64_t total_people = 0;
        int64_t farmer_people = 0;
        int64_t industrial_people = 0;
        int64_t cooperative_people = 0;
        for (size_t profession = 0; profession < profession_people.size();
             ++profession) {
            const int64_t people = profession_people[profession];
            if (people <= 0) continue;
            total_people += people;
            const std::string &profession_id =
                _profession_ids[static_cast<size_t>(profession)];
            if (profession_id == "household_farmer" ||
                    profession_id == "subsistence_farmer" ||
                    profession_id == "tenant_farmer" ||
                    profession_id == "sharecropper" ||
                    profession_id == "agricultural_worker" ||
                    profession_id == "serf")
                farmer_people += people;
            if (profession_id == "industrial_worker")
                industrial_people += people;
            if (profession_id == "cooperative_member")
                cooperative_people += people;
        }
        const auto share = [total_people](int64_t people) {
            return total_people > 0
                ? std::clamp<int64_t>(people * Q16_ONE / total_people,
                    0, Q16_ONE)
                : 0;
        };
        if (requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_FARMER_Q16))
            metrics[FAMILY_METRIC_CELL_PROFESSION_SHARE_FARMER_Q16] =
                share(farmer_people);
        if (requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_INDUSTRIAL_Q16))
            metrics[FAMILY_METRIC_CELL_PROFESSION_SHARE_INDUSTRIAL_Q16] =
                share(industrial_people);
        if (requested(FAMILY_METRIC_CELL_PROFESSION_SHARE_COOPERATIVE_Q16))
            metrics[FAMILY_METRIC_CELL_PROFESSION_SHARE_COOPERATIVE_Q16] =
                share(cooperative_people);
    }
    // X2: the neighbourhood's population. O(6), so it is safe in the hot path;
    // a missing or stale neighbour graph reads 0 rather than guessing.
    if (requested(FAMILY_METRIC_CELL_NEIGHBOR_POPULATION_Q16)) {
        int64_t neighbor_population = 0;
        if (_building_neighbors.size() ==
                static_cast<size_t>(_cell_count.get()) * 6) {
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 + static_cast<size_t>(direction)];
                if (neighbor < 0 ||
                    neighbor >= static_cast<int32_t>(_committed_cells.size()))
                    continue;
                neighbor_population += std::max<int64_t>(
                    0, _committed_cells[static_cast<size_t>(neighbor)].population);
            }
        }
        int64_t neighbor_saturate = 0;
        metrics[FAMILY_METRIC_CELL_NEIGHBOR_POPULATION_Q16] = saturating_mul(
            neighbor_population, Q16_ONE, neighbor_saturate);
    }
    // X2 extension: count neighbours that are agriculture pillars, using the
    // same "agriculture output share >= 50%" definition as
    // `cell.sector.agriculture`. Reading the current building rows avoids
    // depending on the previous epoch's tag snapshot while that snapshot is
    // being rebuilt.
    if (requested(FAMILY_METRIC_CELL_NEIGHBOR_AGRICULTURE_COUNT)) {
        int32_t agriculture_neighbors = 0;
        const bool neighbor_graph_ready = _building_neighbors.size() ==
            static_cast<size_t>(_cell_count.get()) * 6;
        const bool building_csr_ready = _building_cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get()) + 1;
        if (neighbor_graph_ready && building_csr_ready) {
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 +
                    static_cast<size_t>(direction)];
                if (neighbor < 0 || neighbor == cell ||
                    neighbor >= static_cast<int32_t>(_cell_count.get()))
                    continue;
                int64_t total_output = 0;
                int64_t agriculture_output = 0;
                for (int32_t group_index = _building_cell_offsets[neighbor];
                     group_index < _building_cell_offsets[neighbor + 1];
                     ++group_index) {
                    const auto group = building_view(
                        static_cast<size_t>(group_index));
                    if (group.count <= 0 || group.last_output <= 0 ||
                        group.type_id < 0 ||
                        group.type_id >= static_cast<int32_t>(
                            _building_economic_sectors.size()))
                        continue;
                    total_output += group.last_output;
                    if (_building_economic_sectors[
                            static_cast<size_t>(group.type_id)] == 0)
                        agriculture_output += group.last_output;
                }
                if (total_output > 0 &&
                    agriculture_output >= (total_output + 1) / 2)
                    ++agriculture_neighbors;
            }
        }
        metrics[FAMILY_METRIC_CELL_NEIGHBOR_AGRICULTURE_COUNT] =
            count_q16(agriculture_neighbors);
    }
