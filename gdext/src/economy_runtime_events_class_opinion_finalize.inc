    auto finalize_class_snapshot = [&]() {
        uint64_t zero_population_rows = 0;
        for (size_t row = 0; row < class_row_count; ++row) {
            const int64_t population =
                class_snapshot.population[row];
            if (population <= 0) {
                ++zero_population_rows;
                class_snapshot.satisfaction_q16[row] = 0;
                continue;
            }
            class_snapshot.satisfaction_q16[row] =
                static_cast<int32_t>(std::clamp<int64_t>(
                    class_snapshot.satisfaction_weighted[row] /
                        population, 0, Q16_ONE));
        }
        const auto general_class = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), std::string("general"));
        const int32_t general_class_index =
            general_class != _political_class_ids.end() &&
                *general_class == "general"
            ? static_cast<int32_t>(general_class - _political_class_ids.begin())
            : -1;
        const bool class_rows_valid = general_class_index >= 0 &&
            static_cast<int64_t>(class_snapshot.satisfaction_q16.size()) ==
                static_cast<int64_t>(class_snapshot.country_count) *
                    class_snapshot.class_count &&
            static_cast<int64_t>(class_snapshot.population.size()) ==
                static_cast<int64_t>(class_snapshot.country_count) *
                    class_snapshot.class_count &&
            static_cast<int64_t>(class_snapshot.satisfaction_weighted.size()) ==
                static_cast<int64_t>(class_snapshot.country_count) *
                    class_snapshot.class_count;
        auto mix_metric_hash = [](uint64_t hash, uint64_t value) {
            hash ^= value;
            hash *= 1099511628211ULL;
            return hash;
        };
        uint64_t metric_hash = 1469598103934665603ULL;
        metric_hash = mix_metric_hash(metric_hash,
            static_cast<uint64_t>(class_snapshot.country_count));
        metric_hash = mix_metric_hash(metric_hash,
            static_cast<uint64_t>(class_snapshot.class_count));
        metric_hash = mix_metric_hash(metric_hash,
            static_cast<uint64_t>(general_class_index));
        for (int32_t country = 0; country < class_snapshot.country_count;
             ++country) {
            int64_t class_value = 0;
            if (class_rows_valid) {
                const size_t general_row = static_cast<size_t>(country) *
                    static_cast<size_t>(class_snapshot.class_count) +
                    static_cast<size_t>(general_class_index);
                class_value = class_snapshot.satisfaction_q16[general_row];
            }
            int64_t country_population = 0;
            int64_t country_weighted = 0;
            for (int32_t political_class = 0;
                 political_class < class_snapshot.class_count;
                 ++political_class) {
                const size_t row = static_cast<size_t>(country) *
                    static_cast<size_t>(class_snapshot.class_count) +
                    static_cast<size_t>(political_class);
                if (row >= class_snapshot.population.size() ||
                    row >= class_snapshot.satisfaction_weighted.size())
                    break;
                country_population = saturating_add(country_population,
                    std::max<int64_t>(0, class_snapshot.population[row]),
                    _saturation_count);
                country_weighted = saturating_add(country_weighted,
                    std::max<int64_t>(0,
                        class_snapshot.satisfaction_weighted[row]),
                    _saturation_count);
            }
            const int64_t weighted_value = country_population > 0
                ? std::clamp<int64_t>(
                    country_weighted / country_population, 0, Q16_ONE)
                : 0;
            metric_hash = mix_metric_hash(metric_hash,
                static_cast<uint64_t>(class_value));
            metric_hash = mix_metric_hash(metric_hash,
                static_cast<uint64_t>(weighted_value));
        }
        class_snapshot.class_metric_content_hash = metric_hash;
        // Material-incidence shares. Written into the SAME buffer that is about
        // to be committed, so Idology never sees a half-filled table: either the
        // whole row set is derived from this publish, or (measured=false) the
        // country is reported as not measurable at all.
        class_snapshot.incidence_channel_count = incidence_stride;
        class_snapshot.incidence_measured.assign(
            static_cast<size_t>(std::max(0, class_snapshot.country_count)), 0);
        class_snapshot.class_incidence_q16.assign(
            class_row_count * static_cast<size_t>(incidence_stride), 0);
        const auto q16_share = [&](int64_t flow, int64_t total) -> int32_t {
            if (flow <= 0 || total <= 0) return 0;
            return static_cast<int32_t>(std::clamp<int64_t>(
                mul_div_sat(flow, Q16_ONE, total, _saturation_count), 0, Q16_ONE));
        };
        for (size_t row = 0; row < class_row_count; ++row) {
            const int64_t income = incidence_income[row];
            if (income <= 0) continue;
            int32_t *share = &class_snapshot.class_incidence_q16[
                row * static_cast<size_t>(incidence_stride)];
            for (int32_t sector = 0; sector < EconomyApi::kIncidenceSectorCount;
                 ++sector)
                share[sector] = q16_share(
                    incidence_sector_income[
                        row * static_cast<size_t>(EconomyApi::kIncidenceSectorCount) +
                        static_cast<size_t>(sector)], income);
            share[6] = q16_share(incidence_input_cost[row], income);
            share[7] = q16_share(incidence_owner_surplus[row], income);
            share[8] = q16_share(incidence_merchant_income[row], income);
            // Demographic channels are universal: a birth or death factor is not
            // borne by one class more than another, so the share is 1.0 and the
            // catalog-side elasticity decides how much it is worth.
            share[EconomyApi::kIncidenceBirthChannel] = Q16_ONE;
            share[EconomyApi::kIncidenceDeathChannel] = Q16_ONE;
            if (incidence_need_count <= 0) continue;
            int64_t need_total = 0;
            for (int32_t need = 0; need < incidence_need_count; ++need)
                need_total = saturating_add(need_total,
                    incidence_need_spend[
                        row * static_cast<size_t>(incidence_need_count) +
                        static_cast<size_t>(need)], _saturation_count);
            for (int32_t need = 0; need < incidence_need_count; ++need)
                share[EconomyApi::kIncidencePrefixChannelCount + need] = q16_share(
                    incidence_need_spend[
                        row * static_cast<size_t>(incidence_need_count) +
                        static_cast<size_t>(need)], need_total);
        }
        for (int32_t country = 0; country < class_snapshot.country_count; ++country) {
            if (country >= static_cast<int32_t>(
                    class_snapshot.incidence_measured.size()))
                break;
            uint8_t measured = 0;
            for (int32_t political_class = 0;
                 political_class < class_snapshot.class_count; ++political_class) {
                const size_t row = static_cast<size_t>(country) *
                    static_cast<size_t>(class_snapshot.class_count) +
                    static_cast<size_t>(political_class);
                if (row < incidence_income.size() && incidence_income[row] > 0) {
                    measured = 1;
                    break;
                }
            }
            class_snapshot.incidence_measured[static_cast<size_t>(country)] = measured;
        }
        _class_opinion_cells_scanned += cells_scanned;
        _class_opinion_slots_scanned += slots_scanned;
        _last_class_opinion_cells_scanned = cells_scanned;
        _last_class_opinion_slots_scanned = slots_scanned;
        _class_opinion_zero_population_rows += zero_population_rows;
        _last_class_opinion_zero_population_rows = zero_population_rows;
        _class_opinion_ms = elapsed_ms(class_opinion_started);
        _class_opinion_committed_buffer =
            1 - _class_opinion_committed_buffer;
    };
