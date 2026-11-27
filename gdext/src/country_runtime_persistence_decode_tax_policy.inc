    std::vector<int32_t> tax_defaults(
        static_cast<size_t>(country_count) * TAX_KIND_COUNT, 0);
    std::vector<int32_t> income_tax(
        static_cast<size_t>(country_count) * _profession_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> consumption_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> business_tax(
        static_cast<size_t>(country_count) * _building_type_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> import_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> export_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> tax_default_modes(
        static_cast<size_t>(country_count) * TAX_KIND_COUNT,
        TAX_MODE_PERCENT_BP);
    std::vector<int32_t> income_tax_modes(
        static_cast<size_t>(country_count) * _profession_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> consumption_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> business_tax_modes(
        static_cast<size_t>(country_count) * _building_type_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> import_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> export_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    uint64_t tax_policy_version = 0;
    {
        bool read_ok = false;
        if (legacy_percent_tax_rates) {
            std::vector<int8_t> old_defaults, old_income, old_consumption;
            std::vector<int8_t> old_business, old_import, old_export;
            read_ok = read_vector(bytes, cursor, old_defaults,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) &&
                read_vector(bytes, cursor, old_income,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) &&
                read_vector(bytes, cursor, old_consumption,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, old_business,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) &&
                read_vector(bytes, cursor, old_import,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, old_export,
                    static_cast<uint64_t>(country_count) * _good_ids.size());
            const auto migrate = [](const std::vector<int8_t> &source,
                                    std::vector<int32_t> &target,
                                    bool allow_inherit) {
                target.resize(source.size());
                for (size_t i = 0; i < source.size(); ++i) {
                    target[i] = allow_inherit && source[i] == 127
                        ? TAX_RATE_INHERIT
                        : static_cast<int32_t>(source[i]) * 100;
                }
            };
            if (read_ok) {
                migrate(old_defaults, tax_defaults, false);
                migrate(old_income, income_tax, true);
                migrate(old_consumption, consumption_tax, true);
                migrate(old_business, business_tax, true);
                migrate(old_import, import_tax, true);
                migrate(old_export, export_tax, true);
            }
        } else {
            read_ok = read_vector(bytes, cursor, tax_defaults,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) &&
                read_vector(bytes, cursor, income_tax,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) &&
                read_vector(bytes, cursor, consumption_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, business_tax,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) &&
                read_vector(bytes, cursor, import_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, export_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size());
        }
        if (!read_ok ||
            tax_defaults.size() !=
                static_cast<size_t>(country_count) * TAX_KIND_COUNT ||
            income_tax.size() != static_cast<size_t>(country_count) *
                _profession_ids.size() ||
            consumption_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size() ||
            business_tax.size() != static_cast<size_t>(country_count) *
                _building_type_ids.size() ||
            import_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size() ||
            export_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size()) {
            error = "country_save_tax_shape_invalid";
            return false;
        }
        if (has_tax_assessment_modes) {
            if (!read_vector(bytes, cursor, tax_default_modes,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) ||
                !read_vector(bytes, cursor, income_tax_modes,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) ||
                !read_vector(bytes, cursor, consumption_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                !read_vector(bytes, cursor, business_tax_modes,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) ||
                !read_vector(bytes, cursor, import_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                !read_vector(bytes, cursor, export_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                tax_default_modes.size() !=
                    static_cast<size_t>(country_count) * TAX_KIND_COUNT ||
                income_tax_modes.size() !=
                    static_cast<size_t>(country_count) *
                        _profession_ids.size() ||
                consumption_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size() ||
                business_tax_modes.size() !=
                    static_cast<size_t>(country_count) *
                        _building_type_ids.size() ||
                import_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size() ||
                export_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size()) {
                error = "country_save_tax_mode_shape_invalid";
                return false;
            }
        } else {
            tax_default_modes.assign(
                static_cast<size_t>(country_count) * TAX_KIND_COUNT,
                TAX_MODE_PERCENT_BP);
            income_tax_modes.assign(
                static_cast<size_t>(country_count) * _profession_ids.size(),
                TAX_MODE_INHERIT);
            consumption_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
            business_tax_modes.assign(
                static_cast<size_t>(country_count) *
                    _building_type_ids.size(),
                TAX_MODE_INHERIT);
            import_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
            export_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
        }
        if (!read_le(bytes, cursor, tax_policy_version)) {
            error = "country_save_tax_shape_invalid";
            return false;
        }
        for (size_t i = 0; i < tax_defaults.size(); ++i) {
            if (!tax_assessment_mode_valid(tax_default_modes[i]) ||
                !tax_value_valid(tax_default_modes[i], tax_defaults[i])) {
                error = "country_save_tax_rate_invalid";
                return false;
            }
        }
        const auto override_value_valid =
            [](int32_t mode, int32_t rate, int32_t default_mode) {
                if (rate == TAX_RATE_INHERIT) return mode == TAX_MODE_INHERIT;
                if (mode == TAX_MODE_INHERIT)
                    return tax_assessment_mode_valid(default_mode) &&
                           tax_value_valid(default_mode, rate);
                return tax_assessment_mode_valid(mode) &&
                       tax_value_valid(mode, rate);
            };
        const auto validate_overrides =
            [&](const std::vector<int32_t> &rates,
                const std::vector<int32_t> &modes, int32_t kind,
                int32_t item_count) {
                for (int32_t slot = 0; slot < country_count; ++slot) {
                    const int32_t default_mode = tax_default_modes[
                        static_cast<size_t>(slot) * TAX_KIND_COUNT + kind];
                    for (int32_t item = 0; item < item_count; ++item) {
                        const size_t index =
                            static_cast<size_t>(slot) * item_count + item;
                        if (!override_value_valid(modes[index], rates[index],
                                                  default_mode)) {
                            return false;
                        }
                    }
                }
                return true;
            };
        if (!validate_overrides(income_tax, income_tax_modes, TAX_INCOME,
                                static_cast<int32_t>(_profession_ids.size())) ||
            !validate_overrides(consumption_tax, consumption_tax_modes,
                                TAX_CONSUMPTION,
                                static_cast<int32_t>(_good_ids.size())) ||
            !validate_overrides(
                business_tax, business_tax_modes, TAX_BUSINESS,
                static_cast<int32_t>(_building_type_ids.size())) ||
            !validate_overrides(import_tax, import_tax_modes, TAX_IMPORT,
                                static_cast<int32_t>(_good_ids.size())) ||
            !validate_overrides(export_tax, export_tax_modes, TAX_EXPORT,
                                static_cast<int32_t>(_good_ids.size()))) {
            error = "country_save_tax_rate_invalid";
            return false;
        }
    }
    std::vector<uint32_t> cell_tax_policy_ids(
        static_cast<size_t>(_cell_count), 0);
    std::vector<CellTaxPolicy> cell_tax_policies(1);
    std::unordered_map<uint64_t, std::vector<uint32_t>> local_policy_intern;
    uint64_t saved_cell_policy_count = 0;
    if (!read_le(bytes, cursor, saved_cell_policy_count) ||
        saved_cell_policy_count > static_cast<uint64_t>(_cell_count)) {
        error = "country_save_cell_tax_count_invalid";
        return false;
    }
    int32_t previous_cell_policy = -1;
    for (uint64_t policy_index = 0;
         policy_index < saved_cell_policy_count; ++policy_index) {
        int32_t cell = -1;
        CellTaxPolicy policy;
        if (!read_le(bytes, cursor, cell) || cell <= previous_cell_policy ||
            cell < 0 || cell >= _cell_count ||
            owners[static_cast<size_t>(cell)] < 0) {
            error = "country_save_cell_tax_cell_invalid";
            return false;
        }
        for (int32_t &rate : policy.defaults) {
            if (legacy_percent_tax_rates) {
                int8_t old_rate = 0;
                if (!read_le(bytes, cursor, old_rate)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
                rate = old_rate == 127 ? TAX_RATE_INHERIT
                                       : static_cast<int32_t>(old_rate) * 100;
            } else if (!read_le(bytes, cursor, rate)) {
                error = "country_save_cell_tax_default_invalid";
                return false;
            }
        }
        if (has_tax_assessment_modes) {
            for (int32_t &mode : policy.default_modes) {
                if (!read_le(bytes, cursor, mode)) {
                    error = "country_save_cell_tax_default_mode_invalid";
                    return false;
                }
            }
        } else {
            policy.default_modes.fill(TAX_MODE_INHERIT);
        }
        for (size_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
            const int32_t rate = policy.defaults[kind];
            const int32_t mode = policy.default_modes[kind];
            if (rate == TAX_RATE_INHERIT) {
                if (mode != TAX_MODE_INHERIT &&
                    !tax_assessment_mode_valid(mode)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
            } else if (mode == TAX_MODE_INHERIT) {
                // Value inherits country assessment mode at resolve time;
                // accept either absolute or percent bounds.
                if (!tax_value_valid(TAX_MODE_PERCENT_BP, rate) &&
                    !tax_value_valid(TAX_MODE_ABSOLUTE, rate)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
            } else if (!tax_assessment_mode_valid(mode) ||
                       !tax_value_valid(mode, rate)) {
                error = "country_save_cell_tax_default_invalid";
                return false;
            }
        }
        uint64_t entry_count = 0;
        const uint64_t max_entries = static_cast<uint64_t>(
            _profession_ids.size() + _building_type_ids.size() +
            _good_ids.size() * 3U);
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > max_entries) {
            error = "country_save_cell_tax_entries_invalid";
            return false;
        }
        int32_t previous_kind = -1;
        int32_t previous_item = -1;
        for (uint64_t entry_index = 0; entry_index < entry_count;
             ++entry_index) {
            CellTaxOverride entry;
            std::string item_id;
            if (!read_le(bytes, cursor, entry.kind) ||
                !read_string(bytes, cursor, item_id)) {
                error = "country_save_cell_tax_entry_truncated";
                return false;
            }
            if (legacy_percent_tax_rates) {
                int8_t old_rate = 0;
                if (!read_le(bytes, cursor, old_rate)) {
                    error = "country_save_cell_tax_entry_truncated";
                    return false;
                }
                entry.rate = static_cast<int32_t>(old_rate) * 100;
            } else if (!read_le(bytes, cursor, entry.rate)) {
                error = "country_save_cell_tax_entry_truncated";
                return false;
            }
            if (has_tax_assessment_modes) {
                if (!read_le(bytes, cursor, entry.mode)) {
                    error = "country_save_cell_tax_entry_truncated";
                    return false;
                }
            } else {
                entry.mode = TAX_MODE_INHERIT;
            }
            entry.item = tax_item_index(entry.kind, item_id);
            const bool mode_ok =
                entry.mode == TAX_MODE_INHERIT ||
                tax_assessment_mode_valid(entry.mode);
            const bool rate_ok =
                entry.mode == TAX_MODE_INHERIT
                    ? (tax_value_valid(TAX_MODE_PERCENT_BP, entry.rate) ||
                       tax_value_valid(TAX_MODE_ABSOLUTE, entry.rate))
                    : tax_value_valid(entry.mode, entry.rate);
            if (entry.kind < 0 || entry.kind >= TAX_KIND_COUNT ||
                entry.item < 0 || !mode_ok || !rate_ok ||
                entry.kind < previous_kind ||
                (entry.kind == previous_kind && entry.item <= previous_item)) {
                error = "country_save_cell_tax_entry_invalid";
                return false;
            }
            policy.overrides.push_back(entry);
            previous_kind = entry.kind;
            previous_item = entry.item;
        }
        if (policy.empty()) {
            error = "country_save_cell_tax_empty_policy";
            return false;
        }
        const uint64_t hash = cell_tax_policy_hash(policy);
        uint32_t id_value = 0;
        auto &candidates = local_policy_intern[hash];
        for (uint32_t candidate : candidates) {
            if (cell_tax_policies[candidate] == policy) {
                id_value = candidate;
                break;
            }
        }
        if (id_value == 0) {
            id_value = static_cast<uint32_t>(cell_tax_policies.size());
            cell_tax_policies.push_back(std::move(policy));
            candidates.push_back(id_value);
        }
        cell_tax_policy_ids[static_cast<size_t>(cell)] = id_value;
        previous_cell_policy = cell;
    }
