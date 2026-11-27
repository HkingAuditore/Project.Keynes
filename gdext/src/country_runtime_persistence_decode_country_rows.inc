    std::string id;
    for (const std::string &expected : _good_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }
    for (const std::string &expected : _profession_ids)
        if (!read_string(bytes, cursor, id) || id != expected) {
            error = "catalog_hash_mismatch";
            return false;
        }
    for (const std::string &expected : _building_type_ids)
        if (!read_string(bytes, cursor, id) || id != expected) {
            error = "catalog_hash_mismatch";
            return false;
        }
    for (const std::string &expected : _technology_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }
    for (const std::string &expected : _research_signal_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }

    CountryStore countries;
    countries.active.resize(country_count);
    countries.generation.resize(country_count);
    countries.stable_id.resize(country_count);
    countries.display_name.resize(country_count);
    countries.territory_count.resize(country_count);
    countries.cash.resize(country_count);
    countries.state_version.resize(country_count);
    countries.political_regime_id.resize(country_count, 0);
    countries.political_regime_capability_bits.resize(country_count, 0);
    countries.capital_cell.resize(country_count, -1);
    std::unordered_set<std::string> stable_ids;
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (!read_le(bytes, cursor, countries.active[slot]) || !read_le(bytes, cursor, countries.generation[slot]) ||
            !read_string(bytes, cursor, countries.stable_id[slot]) || !read_string(bytes, cursor, countries.display_name[slot]) ||
            !read_le(bytes, cursor, countries.territory_count[slot]) || !read_le(bytes, cursor, countries.cash[slot]) ||
            !read_le(bytes, cursor, countries.state_version[slot])) { error = "country_save_country_record_truncated"; return false; }
        if (version >= 15) {
            if (!read_le(bytes, cursor, countries.political_regime_id[slot]) ||
                !read_le(bytes, cursor, countries.political_regime_capability_bits[slot])) {
                error = "country_save_country_record_truncated";
                return false;
            }
            if (countries.political_regime_id[slot] < 0 ||
                static_cast<size_t>(countries.political_regime_id[slot]) >= _political_regime_ids.size() ||
                countries.political_regime_capability_bits[slot] !=
                    _political_regime_capability_bits[static_cast<size_t>(countries.political_regime_id[slot])]) {
                error = "country_save_political_regime_invalid";
                return false;
            }
            if (version >= 16 &&
                !read_le(bytes, cursor, countries.capital_cell[slot])) {
                error = "country_save_country_record_truncated";
                return false;
            }
        } else {
            const auto legacy = _political_regime_index.find("local_council");
            countries.political_regime_id[slot] = legacy == _political_regime_index.end() ? 0 : legacy->second;
            countries.political_regime_capability_bits[slot] =
                countries.political_regime_id[slot] >= 0 &&
                static_cast<size_t>(countries.political_regime_id[slot]) < _political_regime_capability_bits.size()
                ? _political_regime_capability_bits[static_cast<size_t>(countries.political_regime_id[slot])] : 0u;
        }
        // v14 admits annexed (inactive) records: they keep their identity and
        // bumped generation, own no territory and hold no treasury.
        const bool inactive_record = countries.active[slot] == 0;
        if ((inactive_record && (version < 14 || countries.territory_count[slot] != 0 ||
                                 countries.cash[slot] != 0)) ||
            countries.active[slot] > 1 ||
            countries.generation[slot] == 0 || countries.stable_id[slot].empty() ||
            countries.display_name[slot].empty() ||
            (!inactive_record && countries.territory_count[slot] <= 0) ||
            countries.cash[slot] < 0 ||
            !stable_ids.insert(countries.stable_id[slot]).second) { error = "country_save_country_record_invalid"; return false; }
    }
    std::vector<int32_t> owners;
    std::vector<uint64_t> technologies;
    std::vector<int64_t> goods;
    if (!read_vector(bytes, cursor, owners, static_cast<uint64_t>(_cell_count)) || owners.size() != static_cast<size_t>(_cell_count) ||
        !read_vector(bytes, cursor, technologies, static_cast<uint64_t>(country_count) * _technology_words) ||
        technologies.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, goods, static_cast<uint64_t>(country_count) * _good_ids.size()) ||
        goods.size() != static_cast<size_t>(country_count) * _good_ids.size()) { error = "country_save_matrix_shape_invalid"; return false; }
    std::vector<uint64_t> discovered, pending, signals;
    std::vector<int32_t> research_queues, research_weights;
    std::vector<uint8_t> research_queue_lengths, auto_purchase;
    std::vector<int64_t> deferred_points, purchased_total,
        consumed_total, progress_total, completed_total;
    int64_t last_research_day = -1;
    const uint64_t countries_u64 = static_cast<uint64_t>(country_count);
    if (!read_vector(bytes, cursor, discovered, countries_u64 * _technology_words) ||
        discovered.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, pending, countries_u64 * _technology_words) ||
        pending.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, signals, countries_u64 * _research_signal_words) ||
        signals.size() != static_cast<size_t>(country_count) * _research_signal_words) {
        error = "country_save_research_shape_invalid";
        return false;
    }
    uint64_t signal_cell_country_count = 0;
    if (!read_le(bytes, cursor, signal_cell_country_count) ||
        signal_cell_country_count != countries_u64) {
        error = "country_save_signal_cells_shape_invalid";
        return false;
    }
    std::vector<std::vector<uint64_t>> signal_cells(static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (!read_vector(bytes, cursor, signal_cells[static_cast<size_t>(slot)],
                         static_cast<uint64_t>(_cell_count) *
                             std::max<int32_t>(signal_count, 1))) {
            error = "country_save_signal_cells_shape_invalid";
            return false;
        }
        if (!std::is_sorted(signal_cells[static_cast<size_t>(slot)].begin(),
                            signal_cells[static_cast<size_t>(slot)].end()) ||
            std::adjacent_find(signal_cells[static_cast<size_t>(slot)].begin(),
                               signal_cells[static_cast<size_t>(slot)].end()) !=
                signal_cells[static_cast<size_t>(slot)].end()) {
            error = "country_save_signal_cells_invalid";
            return false;
        }
        for (uint64_t key : signal_cells[static_cast<size_t>(slot)]) {
            const int32_t signal = static_cast<int32_t>(key >> 32U);
            const int32_t cell = static_cast<int32_t>(key & 0xffffffffU);
            if (signal < 0 || signal >= signal_count || cell < 0 || cell >= _cell_count) {
                error = "country_save_signal_cells_invalid";
                return false;
            }
        }
    }
    uint64_t signal_evidence_country_count = 0;
    if (!read_le(bytes, cursor, signal_evidence_country_count) ||
        signal_evidence_country_count != countries_u64) {
        error = "country_save_signal_evidence_shape_invalid";
        return false;
    }
    std::vector<std::vector<SignalEvidence>> signal_evidence(
        static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        uint64_t entry_count = 0;
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > static_cast<uint64_t>(signal_count)) {
            error = "country_save_signal_evidence_shape_invalid";
            return false;
        }
        int32_t previous_signal = -1;
        for (uint64_t entry_index = 0; entry_index < entry_count; ++entry_index) {
            SignalEvidence entry;
            if (!read_le(bytes, cursor, entry.signal) || !read_le(bytes, cursor, entry.count) ||
                !read_le(bytes, cursor, entry.first_day) || !read_le(bytes, cursor, entry.last_day) ||
                !read_le(bytes, cursor, entry.first_cell) || entry.signal <= previous_signal ||
                entry.signal < 0 || entry.signal >= signal_count || entry.count <= 0 ||
                entry.first_day < 0 || entry.last_day < entry.first_day ||
                entry.first_cell < 0 || entry.first_cell >= _cell_count) {
                error = "country_save_signal_evidence_invalid";
                return false;
            }
            signal_evidence[static_cast<size_t>(slot)].push_back(entry);
            previous_signal = entry.signal;
        }
    }
    if (!read_vector(bytes, cursor, research_queues, countries_u64 * 32U) ||
        research_queues.size() != static_cast<size_t>(country_count) * 32U ||
        !read_vector(bytes, cursor, research_queue_lengths, countries_u64 * 4U) ||
        research_queue_lengths.size() != static_cast<size_t>(country_count) * 4U ||
        !read_vector(bytes, cursor, research_weights, countries_u64 * 4U) ||
        research_weights.size() != static_cast<size_t>(country_count) * 4U ||
        !read_vector(bytes, cursor, auto_purchase, countries_u64) ||
        auto_purchase.size() != static_cast<size_t>(country_count) ||
        !read_vector(bytes, cursor, deferred_points, countries_u64) ||
        !read_vector(bytes, cursor, purchased_total, countries_u64) ||
        !read_vector(bytes, cursor, consumed_total, countries_u64) ||
        !read_vector(bytes, cursor, progress_total, countries_u64) ||
        !read_vector(bytes, cursor, completed_total, countries_u64) ||
        deferred_points.size() != static_cast<size_t>(country_count) ||
        purchased_total.size() != static_cast<size_t>(country_count) ||
        consumed_total.size() != static_cast<size_t>(country_count) ||
        progress_total.size() != static_cast<size_t>(country_count) ||
        completed_total.size() != static_cast<size_t>(country_count) ||
        !read_le(bytes, cursor, last_research_day)) {
        error = "country_save_research_shape_invalid";
        return false;
    }
    uint64_t progress_country_count = 0;
    if (!read_le(bytes, cursor, progress_country_count) ||
        progress_country_count != countries_u64) {
        error = "country_save_research_progress_shape_invalid";
        return false;
    }
    std::vector<std::vector<std::pair<int32_t, int64_t>>> research_progress(
        static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        uint64_t entry_count = 0;
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > static_cast<uint64_t>(_technology_ids.size())) {
            error = "country_save_research_progress_shape_invalid";
            return false;
        }
        int32_t previous_tech = -1;
        for (uint64_t entry = 0; entry < entry_count; ++entry) {
            int32_t tech = -1;
            int64_t value = 0;
            if (!read_le(bytes, cursor, tech) || !read_le(bytes, cursor, value) ||
                tech <= previous_tech || tech >= tech_count || value <= 0 ||
                value > max_storable_research_progress(tech)) {
                error = "country_save_research_progress_invalid";
                return false;
            }
            research_progress[static_cast<size_t>(slot)].push_back({tech, value});
            previous_tech = tech;
        }
    }
    for (int32_t slot = 0; slot < country_count; ++slot) {
        int32_t weight_total = 0;
        for (int32_t domain = 0; domain < 4; ++domain) {
            const size_t index = static_cast<size_t>(slot) * 4U + domain;
            if (research_queue_lengths[index] > 8 ||
                research_weights[index] < 0 || research_weights[index] > 10000) {
                error = "country_save_research_policy_invalid";
                return false;
            }
            weight_total += research_weights[index];
        }
        if (weight_total != 10000 || auto_purchase[static_cast<size_t>(slot)] > 1 ||
            deferred_points[static_cast<size_t>(slot)] < 0) {
            error = "country_save_research_policy_invalid";
            return false;
        }
    }
    std::vector<int32_t> territory_counts(static_cast<size_t>(country_count), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t owner = owners[static_cast<size_t>(cell)];
        if (owner < NEUTRAL_SLOT || owner >= country_count ||
            (owner >= 0 && !_is_water.empty() && _is_water[static_cast<size_t>(cell)] != 0)) {
            error = "country_save_territory_invalid"; return false;
        }
        if (owner >= 0) ++territory_counts[static_cast<size_t>(owner)];
    }
    if (territory_counts != countries.territory_count) { error = "country_save_territory_count_mismatch"; return false; }
    for (int64_t quantity : goods) if (quantity < 0) { error = "country_save_treasury_negative"; return false; }
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (countries.active[static_cast<size_t>(slot)] != 0) continue;
        for (size_t good = 0; good < _good_ids.size(); ++good) {
            if (goods[static_cast<size_t>(slot) * _good_ids.size() + good] != 0) {
                error = "country_save_inactive_country_treasury";
                return false;
            }
        }
    }
