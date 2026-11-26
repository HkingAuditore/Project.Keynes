    if (_modifier_runtime != nullptr) {
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const uint64_t country_handle =
                _epoch_country_handles[static_cast<size_t>(country)];
            const auto freeze_tax_group = [&](const std::vector<int32_t> &stat_ids,
                                              std::vector<int32_t> &rates,
                                              const std::vector<int32_t> &modes,
                                              size_t item_count) {
                if (item_count == 0) return;
                const size_t begin = static_cast<size_t>(country) * item_count;
                std::vector<int32_t> percent_stat_ids;
                std::vector<int32_t> percent_bases;
                std::vector<size_t> percent_indices;
                percent_stat_ids.reserve(item_count);
                percent_bases.reserve(item_count);
                percent_indices.reserve(item_count);
                for (size_t item = 0; item < item_count; ++item) {
                    const size_t index = begin + item;
                    if (index >= modes.size() ||
                        modes[index] ==
                            CountryApi::TAX_MODE_ABSOLUTE) {
                        continue;
                    }
                    percent_stat_ids.push_back(stat_ids[item]);
                    percent_bases.push_back(rates[index]);
                    percent_indices.push_back(index);
                }
                if (percent_stat_ids.empty()) return;
                std::vector<int32_t> effective = percent_bases;
                modifier_api::effective_values(*_modifier_runtime,
                    ModifierApi::COUNTRY, percent_stat_ids.data(),
                    country_handle, percent_bases.data(), effective.data(),
                    percent_stat_ids.size());
                for (size_t i = 0; i < percent_indices.size(); ++i) {
                    rates[percent_indices[i]] = static_cast<int32_t>(
                        std::clamp<int64_t>(
                            effective[i],
                            CountryApi::TAX_RATE_MIN_BP,
                            CountryApi::TAX_RATE_MAX_BP));
                }
            };
            freeze_tax_group(_income_tax_stat_ids, _epoch_income_tax_rates,
                             _epoch_income_tax_modes, _profession_ids.size());
            freeze_tax_group(_consumption_tax_stat_ids,
                             _epoch_consumption_tax_rates,
                             _epoch_consumption_tax_modes, _good_ids.size());
            freeze_tax_group(_business_tax_stat_ids, _epoch_business_tax_rates,
                             _epoch_business_tax_modes, _building_types.size());
            freeze_tax_group(_import_tax_stat_ids, _epoch_import_tax_rates,
                             _epoch_import_tax_modes, _good_ids.size());
            freeze_tax_group(_export_tax_stat_ids, _epoch_export_tax_rates,
                             _epoch_export_tax_modes, _good_ids.size());
            _epoch_country_output_factor_q16[static_cast<size_t>(country)] =
                modifier_factor_q16(modifier_api::country_economy_output_factor(*_modifier_runtime,
                    country_handle));
            for (int32_t sector = 0; sector < 5; ++sector)
                _epoch_country_sector_output_factor_q16[
                    static_cast<size_t>(country) * 5U + sector] =
                    modifier_factor_q16(
                        modifier_api::country_sector_output_factor(*_modifier_runtime,
                            _epoch_country_handles[static_cast<size_t>(country)],
                            sector));
            _epoch_country_research_output_factor_q16[country] =
                modifier_factor_q16(
                    modifier_api::country_research_institution_output_factor(*_modifier_runtime,
                        _epoch_country_handles[static_cast<size_t>(country)]));
            for (size_t family = 0;
                 family < _country_family_output_stat_ids.size(); ++family) {
                _epoch_country_family_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_family_output_stat_ids.size() + family] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_family_output_stat_ids[family], country_handle,
                        0, 1.0));
            }
            for (size_t good = 0;
                 good < _country_good_output_stat_ids.size(); ++good) {
                _epoch_country_good_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_good_output_stat_ids.size() + good] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_good_output_stat_ids[good], country_handle,
                        0, 1.0));
                _epoch_country_good_input_factor_q16[
                    static_cast<size_t>(country) * _good_ids.size() + good] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_good_input_stat_ids[good], country_handle,
                        0, 1.0));
                _epoch_country_good_consumption_factor_q16[
                    static_cast<size_t>(country) * _good_ids.size() + good] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_good_consumption_stat_ids[good], country_handle,
                        0, 1.0));
            }
            for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
                const size_t index = static_cast<size_t>(country) *
                    _resource_ids.size() + resource;
                _epoch_country_resource_use_factor_q16[index] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_resource_use_stat_ids[resource], country_handle,
                        0, 1.0));
                _epoch_country_resource_generation_factor_q16[index] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_resource_generation_stat_ids[resource],
                        country_handle, 0, 1.0));
            }
            // X16: per-profession tax tolerance (Q16, clamped to [0.5, 3.0]) and
            // satisfaction bias (bp, clamped to [-2500, 2500]).
            //
            // Clamped HERE rather than at the reader so the frozen epoch value is the
            // one the game actually uses: a card that stacks to 5x cannot overflow the
            // Q16 multiply later, and a bias cannot push satisfaction past the design
            // envelope.
            // Per-political-class satisfaction bias (`economy.class.<id>.satisfaction_bp`).
            // Evaluated once per country and folded into every profession of that class
            // (and into `_epoch_country_general_satisfaction_bp` for unemployed cohorts).
            std::vector<int32_t> class_satisfaction_bp(_political_class_ids.size(), 0);
            int32_t general_class_bias_bp = 0;
            for (size_t class_index = 0; class_index < _political_class_ids.size();
                 ++class_index) {
                const int32_t class_stat =
                    class_index < _political_class_satisfaction_bp_stat_ids.size()
                        ? _political_class_satisfaction_bp_stat_ids[class_index] : -1;
                int32_t class_bias = 0;
                if (class_stat >= 0) {
                    class_bias = static_cast<int32_t>(std::clamp<int64_t>(
                        static_cast<int64_t>(std::llround(
                            modifier_api::effective_value(*_modifier_runtime,
                                ModifierApi::COUNTRY, class_stat,
                                country_handle, 0, 0.0))),
                        -2500, 2500));
                }
                class_satisfaction_bp[class_index] = class_bias;
                if (_political_class_ids[class_index] == "general") {
                    general_class_bias_bp = class_bias;
                }
            }
            if (static_cast<size_t>(country) <
                    _epoch_country_general_satisfaction_bp.size()) {
                _epoch_country_general_satisfaction_bp[static_cast<size_t>(country)] =
                    general_class_bias_bp;
            }
            for (size_t profession = 0; profession < _profession_ids.size();
                 ++profession) {
                const size_t index = static_cast<size_t>(country) *
                    _profession_ids.size() + profession;
                const int32_t tolerance_stat =
                    profession < _profession_tax_tolerance_stat_ids.size()
                        ? _profession_tax_tolerance_stat_ids[profession] : -1;
                const int32_t bias_stat =
                    profession < _profession_satisfaction_bp_stat_ids.size()
                        ? _profession_satisfaction_bp_stat_ids[profession] : -1;
                int32_t tolerance_q16 = Q16_ONE;
                if (tolerance_stat >= 0)
                    tolerance_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                        modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                            ModifierApi::COUNTRY, tolerance_stat,
                            country_handle, 0, 1.0)),
                        Q16_ONE / 2, 3 * Q16_ONE));
                int64_t combined_bias_bp = 0;
                if (bias_stat >= 0)
                    combined_bias_bp += static_cast<int64_t>(std::llround(
                        modifier_api::effective_value(*_modifier_runtime,
                            ModifierApi::COUNTRY, bias_stat,
                            country_handle, 0, 0.0)));
                if (profession < _profession_political_class_index.size()) {
                    const int32_t class_index =
                        _profession_political_class_index[profession];
                    if (class_index >= 0 &&
                            static_cast<size_t>(class_index) <
                                class_satisfaction_bp.size()) {
                        combined_bias_bp +=
                            class_satisfaction_bp[static_cast<size_t>(class_index)];
                    }
                }
                const int32_t bias_bp = static_cast<int32_t>(
                    std::clamp<int64_t>(combined_bias_bp, -2500, 2500));
                _epoch_country_profession_tax_tolerance_q16[index] = tolerance_q16;
                _epoch_country_profession_satisfaction_bp[index] = bias_bp;
                // X16 PROBE (temporary). Answers "why does the frozen table stay at the
                // default while the Modifier read is correct?" without guessing:
                //
                //   this          -- which NativeEconomyRuntime actually ran the freeze
                //   modifier      -- whether it had a ModifierRuntime at that moment
                //   stat / raw    -- the resolved id and what effective_value returned
                //   epoch_id      -- which epoch this row belongs to
                //
                // Compared against the same line printed by
                // `get_epoch_profession_report`, this separates "the report reads a
                // different instance" from "the freeze ran before Modifier had the row".
                static int64_t x16_freeze_probe_last_epoch = -1;
                if (pk::runtime_switch_value(pk::RuntimeSwitch::PK_X16_PROBE) != nullptr &&
                    profession == 0 && _epoch_id != x16_freeze_probe_last_epoch) {
                    x16_freeze_probe_last_epoch = _epoch_id;
                    const double raw = tolerance_stat >= 0
                        ? modifier_api::effective_value(*_modifier_runtime,
                            ModifierApi::COUNTRY, tolerance_stat,
                            country_handle, 0, 1.0)
                        : 1.0;
                    pk::log_error("[x16-freeze] this=%p modifier=%p country=%d "
                        "handle=%lld epoch_id=%lld profession=%zu stat=%d raw=%.5f "
                        "frozen=%d",
                        static_cast<const void *>(this),
                        static_cast<const void *>(_modifier_runtime),
                        country, static_cast<long long>(country_handle),
                        static_cast<long long>(_epoch_id), profession,
                        tolerance_stat, raw, tolerance_q16);
                }
            }
            const auto freeze_geography = [&](const std::vector<int32_t> &stat_ids,
                    size_t geography_count, std::vector<int32_t> &target) {
                const size_t row_width = geography_count * 5U;
                for (size_t index = 0; index < row_width; ++index)
                    target[static_cast<size_t>(country) * row_width + index] =
                        modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                            ModifierApi::COUNTRY, stat_ids[index],
                            country_handle, 0, 1.0));
            };
            freeze_geography(_country_terrain_sector_output_stat_ids,
                _modifier_terrain_ids.size(),
                _epoch_country_terrain_sector_output_factor_q16);
            freeze_geography(_country_landform_sector_output_stat_ids,
                _modifier_landform_ids.size(),
                _epoch_country_landform_sector_output_factor_q16);
            _epoch_country_production_input_factor_q16[country] =
                modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::COUNTRY, _country_production_input_stat_id,
                    country_handle, 0, 1.0));
            _epoch_country_household_consumption_factor_q16[country] =
                modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::COUNTRY,
                    _country_household_consumption_stat_id,
                    country_handle, 0, 1.0));
            if (_country_population_death_stat_id >= 0)
                _epoch_country_death_factor_q16[country] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_population_death_stat_id,
                        country_handle, 0, 1.0));
            _epoch_country_resource_global_use_factor_q16[country] =
                modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::COUNTRY, _country_resource_use_stat_id,
                    country_handle, 0, 1.0));
            // R-4 metric 69 is filled AFTER this loop, see the single-pass block
            // below: computing it here would be O(countries x cells x cohorts) per
            // epoch, and this loop already runs once per country.
            for (size_t building = 0;
                 building < _country_building_output_stat_ids.size(); ++building) {
                _epoch_country_building_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_building_output_stat_ids.size() + building] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_building_output_stat_ids[building], country_handle,
                        0, 1.0));
            }
            for (size_t climate = 0;
                 climate < _country_climate_loss_stat_ids.size(); ++climate) {
                _epoch_country_climate_loss_factor_q16[
                    static_cast<size_t>(country) * 4U + climate] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_climate_loss_stat_ids[climate], country_handle,
                        0, 1.0));
            }
            const size_t profile_climate_count =
                _production_climate_profile_ids.size() * 4U;
            for (size_t profile_climate = 0;
                 profile_climate < profile_climate_count; ++profile_climate) {
                _epoch_country_climate_profile_loss_factor_q16[
                    static_cast<size_t>(country) * profile_climate_count +
                        profile_climate] =
                    modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                        ModifierApi::COUNTRY,
                        _country_climate_profile_loss_stat_ids[profile_climate],
                        country_handle, 0, 1.0));
            }
            _epoch_country_trade_capacity_factor_q16[country] =
                modifier_factor_q16(
                    modifier_api::country_trade_capacity_factor(*_modifier_runtime,
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_trade_speed_factor_q16[country] =
                modifier_factor_q16(
                    modifier_api::country_trade_speed_factor(*_modifier_runtime,
                        _epoch_country_handles[static_cast<size_t>(country)]));
            // Per-good trade factors, filled the same way as the
            // `country.output.good.*` block above: stat id -1 means "this good
            // declares nothing", which leaves the Q16_ONE from the epoch assign.
            // Shape guard: both vectors are resolved in `_good_ids` order, so a
            // mismatch means configuration did not run; skip rather than index
            // out of range (neutral factors, same as an absent stat).
            if (_country_good_trade_capacity_stat_ids.size() == _good_ids.size() &&
                _country_good_trade_speed_stat_ids.size() == _good_ids.size()) {
                for (size_t good = 0; good < _good_ids.size(); ++good) {
                    const size_t good_index = static_cast<size_t>(country) *
                        _good_ids.size() + good;
                    const int32_t capacity_stat =
                        _country_good_trade_capacity_stat_ids[good];
                    if (capacity_stat >= 0)
                        _epoch_country_good_trade_capacity_factor_q16[good_index] =
                            modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                                ModifierApi::COUNTRY, capacity_stat, country_handle,
                                0, 1.0));
                    const int32_t speed_stat =
                        _country_good_trade_speed_stat_ids[good];
                    if (speed_stat >= 0)
                        _epoch_country_good_trade_speed_factor_q16[good_index] =
                            modifier_factor_q16(modifier_api::effective_value(*_modifier_runtime,
                                ModifierApi::COUNTRY, speed_stat, country_handle,
                                0, 1.0));
                }
            }
            _epoch_country_construction_cost_factor_q16[country] =
                modifier_factor_q16(
                    modifier_api::country_construction_cost_factor(*_modifier_runtime,
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_construction_time_factor_q16[country] =
                modifier_factor_q16(
                    modifier_api::country_construction_time_factor(*_modifier_runtime,
                        _epoch_country_handles[static_cast<size_t>(country)]));
        }
    }
