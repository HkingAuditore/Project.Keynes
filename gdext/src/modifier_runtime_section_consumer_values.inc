bool ModifierRuntime::install_derived_cell_layer(DerivedCellFront front,
                                                 uint64_t expected_generation,
                                                 bool &skipped, std::string &error) {
    skipped = false;
    error.clear();
    if (!_configured) {
        error = "modifier_runtime_not_configured";
        return false;
    }
    // Plan §9.6: a candidate built against an older front must never replace a
    // newer one. Generation 0 means "accept any" and is used by the first
    // install and by tests only.
    if (expected_generation != 0 &&
            expected_generation != _derived_cell_front.generation) {
        error = "derived_cell_layer_stale_generation";
        return false;
    }
    // Plan I13: the same input producing the same contributions is an
    // idempotent no-op, and must NOT bump a version -- otherwise an idle day
    // looks like work (plan §7.4).
    if (front.rows.empty() && _derived_cell_front.rows.empty()) {
        skipped = true;
        ++_derived_layer_install_skips;
        return true;
    }
    if (front.rows.empty() && !_derived_cell_front.rows.empty()) {
        // An explicitly empty candidate CLEARS the layer. This is the plan §17
        // "legal empty result" path: a card whose conditions are all false must
        // retire its previous contribution, not silently keep it.
        _derived_cell_front = DerivedCellFront{};
        _derived_cell_front.generation = ++_derived_layer_generation;
        ++_derived_layer_installs;
        return true;
    }
    // Identity must match the installed front when one exists, so a candidate
    // built against a different world/map/epoch cannot land (plan §9.6).
    if (!_derived_cell_front.rows.empty()) {
        if (front.world_identity != _derived_cell_front.world_identity ||
                front.map_generation != _derived_cell_front.map_generation) {
            error = "derived_cell_layer_identity_mismatch";
            return false;
        }
    }
    // Plan I13: identical content is an idempotent no-op. Comparing the content
    // digest (not the identity fields, and not the generation) is what makes
    // "same input, same contributions" recognisable -- otherwise a world that
    // changes nothing still bumps `layer_stat_version` every day and every cache
    // keyed on it rebuilds, which is exactly the §7.4 idle violation.
    if (!_derived_cell_front.rows.empty() &&
            front.content_digest() == _derived_cell_front.content_digest()) {
        skipped = true;
        ++_derived_layer_install_skips;
        return true;
    }
    front.generation = ++_derived_layer_generation;
    _derived_cell_front = std::move(front);
    ++_derived_layer_installs;
    return true;
}

uint64_t ModifierRuntime::derived_cell_stat_version(const int32_t *stat_ids,
                                                    size_t stat_count) const {
    if (stat_ids == nullptr) return 0;
    // The layer generation participates unconditionally: a front replacement can
    // remove a stat entirely, and a per-stat counter alone cannot express
    // "there used to be rows here". `apply_pod_snapshot` clearing the LEGACY
    // store must not move this value, which is why it is a separate function
    // rather than another term in `stat_bucket_version`.
    uint64_t hash = (1469598103934665603ULL ^ _derived_cell_front.generation) *
        1099511628211ULL;
    for (size_t i = 0; i < stat_count; ++i) {
        const int32_t sid = stat_ids[i];
        const uint64_t version = sid >= 0 &&
                static_cast<size_t>(sid) < _derived_cell_front.stat_versions.size()
            ? _derived_cell_front.stat_versions[static_cast<size_t>(sid)] : 0;
        hash = (hash ^ version) * 1099511628211ULL;
        hash = (hash ^ static_cast<uint64_t>(static_cast<uint32_t>(sid))) *
            1099511628211ULL;
    }
    return hash;
}

float ModifierRuntime::climate_radiative_target(int32_t cell, float base_value) const {
    return static_cast<float>(effective_value(CLIMATE, "climate.cell.radiative_target",
        static_cast<uint64_t>(std::max(0, cell)), 0, base_value));
}

void ModifierRuntime::climate_radiative_terms(int32_t cell, double &add,
                                               double &factor) const {
    add = 0.0;
    factor = 1.0;
    const int32_t sid = stat_id("climate.cell.radiative_target");
    if (!_configured || sid < 0) return;
    const Store &store = _stores[CLIMATE];
    const BucketKey keys[2] = {
        {sid, GLOBAL, 0},
        {sid, ENTITY, static_cast<uint64_t>(std::max(0, cell))},
    };
    for (const BucketKey &key : keys) {
        const auto it = store.buckets.find(key);
        if (it == store.buckets.end()) continue;
        add += it->second.sum_add;
        factor *= bucket_factor(it->second);
    }
}

double ModifierRuntime::country_economy_output_factor(uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.economy_output_factor", country_handle,
                           0, 1.0);
}

double ModifierRuntime::country_sector_output_factor(
        uint64_t country_handle, int32_t economic_sector) const {
    static const char *SECTOR_STATS[5] = {
        "country.output.agriculture_factor",
        "country.output.extractive_factor",
        "country.output.manufacturing_factor",
        "country.output.energy_factor",
        "country.output.knowledge_factor",
    };
    if (economic_sector < 0 || economic_sector >= 5) return 1.0;
    return effective_value(COUNTRY, SECTOR_STATS[economic_sector],
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_research_institution_output_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY,
        "country.research.institution_output_factor",
        country_handle, 0, 1.0);
}

double ModifierRuntime::country_trade_capacity_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.trade.capacity_factor",
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_trade_speed_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.trade.speed_factor",
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_construction_cost_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.construction.cost_factor",
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_construction_time_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.construction.time_factor",
                           country_handle, 0, 1.0);
}

bool ModifierRuntime::apply_technology_effect(uint64_t country_handle,
                                              const std::string &definition_key,
                                              int32_t technology_id,
                                              int64_t day_index,
                                              std::string &error) {
    if (!_configured) {
        error = "modifier_not_configured";
        return false;
    }
    const int32_t definition = definition_id(definition_key);
    if (definition < 0 || _definitions[static_cast<size_t>(definition)].domain != COUNTRY) {
        error = "technology_modifier_definition_unknown";
        return false;
    }
    Command command;
    command.opcode = COMMAND_APPLY;
    command.definition_id = definition;
    command.domain = COUNTRY;
    command.scope = ENTITY;
    command.entity_handle = country_handle;
    command.source_type = 0x54454348ULL; // "TECH"
    command.source_id = static_cast<uint64_t>(technology_id + 1);
    command.duration_days = PERMANENT_EXPIRY;
    command.stacks = 1;
    command.effective_day = day_index;
    Result result;
    apply_command(command, day_index, result);
    if (!result.ok) {
        error = result.reason;
        return false;
    }
    _current_day = std::max(_current_day, day_index);
    return true;
}

bool ModifierRuntime::resolve_definition_terms(
        const std::string &definition_key,
        std::vector<ResolvedTerm> &out) const {
    out.clear();
    for (const Definition &definition : _definitions) {
        if (definition.key != definition_key) continue;
        for (uint32_t offset = 0; offset < definition.term_count; ++offset) {
            const TermDefinition &term = _terms[
                static_cast<size_t>(definition.term_begin) + offset];
            if (term.add != 0.0)
                out.push_back(ResolvedTerm{term.stat_id, ADD, term.add});
            // A term that only multiplies by 1.0 is still meaningful: it NAMES a
            // stat. Dropping it loses the identity, which is how a generated
            // template (`MULTIPLY 1.0`, real magnitude on the command) ended up
            // producing zero plane entries with zero counters. Only a term that
            // is a genuine no-op in BOTH halves is skipped.
            if (term.factor != 1.0 || term.add == 0.0)
                out.push_back(ResolvedTerm{term.stat_id, MULTIPLY, term.factor});
        }
        return true;
    }
    return false;
}

bool ModifierRuntime::has_technology_effect(uint64_t country_handle,
                                            const std::string &definition_key,
                                            int32_t technology_id) const {
    if (!_configured || country_handle == 0 || definition_key.empty() ||
        technology_id < 0)
        return false;
    const int32_t definition = definition_id(definition_key);
    if (definition < 0 || _definitions[static_cast<size_t>(definition)].domain != COUNTRY)
        return false;
    const Store &store = _stores[COUNTRY];
    const UniqueKey unique{definition, ENTITY, country_handle, 0x54454348ULL,
                           static_cast<uint64_t>(technology_id + 1)};
    const auto existing = store.unique_instances.find(unique);
    return existing != store.unique_instances.end() &&
        existing->second < store.active.size() &&
        store.active[existing->second] != 0;
}

bool ModifierRuntime::has_unique_source_entry(int32_t domain,
                                              const std::string &definition_key,
                                              uint64_t entity_handle,
                                              uint64_t source_type,
                                              uint64_t source_id) const {
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT || entity_handle == 0)
        return false;
    const int32_t definition = definition_id(definition_key);
    if (definition < 0 || _definitions[static_cast<size_t>(definition)].domain != domain ||
        _definitions[static_cast<size_t>(definition)].policy == INDEPENDENT)
        return false;
    const Store &store = _stores[domain];
    const UniqueKey unique{definition, ENTITY, entity_handle, source_type, source_id};
    const auto existing = store.unique_instances.find(unique);
    return existing != store.unique_instances.end() &&
        existing->second < store.active.size() &&
        store.active[existing->second] != 0;
}

bool ModifierRuntime::queue_family_group_effect(
        const std::string &definition_key, int32_t settlement_cell,
        uint64_t branch_stable_id, int32_t magnitude_q16,
        int64_t day_index, std::string &error) {
    const int32_t did = definition_id(definition_key);
    if (!_configured || did < 0 || _definitions[did].domain != ECONOMY ||
        _definitions[did].policy == INDEPENDENT) {
        error = "family_modifier_definition_invalid";
        return false;
    }
    if (settlement_cell < 0 || settlement_cell >= _cell_count ||
        branch_stable_id == 0 || magnitude_q16 < 0 ||
        magnitude_q16 > MAX_MAGNITUDE_Q16) {
        error = "family_modifier_target_invalid";
        return false;
    }
    Command command;
    command.opcode = COMMAND_APPLY;
    command.producer = 160;
    command.sequence = static_cast<int64_t>(++_submit_order);
    command.effective_day = std::max<int64_t>(day_index, _current_day);
    command.request_id = _next_request_id++;
    command.definition_id = did;
    command.domain = ECONOMY;
    command.scope = GROUP;
    command.group_handle = static_cast<uint64_t>(settlement_cell);
    command.source_type = 0x46414d494c59ULL; // FAMILY
    command.source_id = branch_stable_id;
    command.duration_days = -1;
    command.stacks = 1;
    command.magnitude_q16 = magnitude_q16;
    command.submit_order = _submit_order;
    _pending_commands.push_back(command);
    _results[command.request_id] = {false, "pending", 0, -1};
    return true;
}

bool ModifierRuntime::queue_family_group_effect_remove(
        const std::string &definition_key, int32_t settlement_cell,
        uint64_t branch_stable_id, int64_t day_index, std::string &error) {
    const int32_t did = definition_id(definition_key);
    if (!_configured || did < 0 || _definitions[did].domain != ECONOMY ||
        _definitions[did].policy == INDEPENDENT) {
        error = "family_modifier_definition_invalid";
        return false;
    }
    if (settlement_cell < 0 || settlement_cell >= _cell_count ||
        branch_stable_id == 0) {
        error = "family_modifier_target_invalid";
        return false;
    }
    Command command;
    command.opcode = COMMAND_REMOVE;
    command.producer = 160;
    command.sequence = static_cast<int64_t>(++_submit_order);
    command.effective_day = std::max<int64_t>(day_index, _current_day);
    command.request_id = _next_request_id++;
    command.definition_id = did;
    command.domain = ECONOMY;
    command.scope = GROUP;
    command.group_handle = static_cast<uint64_t>(settlement_cell);
    command.source_type = 0x46414d494c59ULL; // FAMILY
    command.source_id = branch_stable_id;
    command.duration_days = -1;
    command.stacks = 1;
    command.submit_order = _submit_order;
    _pending_commands.push_back(command);
    _results[command.request_id] = {false, "pending", 0, -1};
    return true;
}

int32_t ModifierRuntime::family_group_effect_magnitude(
        const std::string &definition_key, int32_t settlement_cell,
        uint64_t branch_stable_id) const {
    const int32_t did = definition_id(definition_key);
    if (did < 0 || _definitions[did].domain != ECONOMY) return -1;
    const Store &store = _stores[ECONOMY];
    const UniqueKey key{did, GROUP, static_cast<uint64_t>(settlement_cell),
        0x46414d494c59ULL, branch_stable_id};
    const auto it = store.unique_instances.find(key);
    if (it == store.unique_instances.end() ||
        it->second >= store.active.size() || store.active[it->second] == 0)
        return -1;
    return store.magnitude_q16[it->second];
}

double ModifierRuntime::economy_building_output_factor(uint64_t building_handle,
                                                        uint64_t settlement_cell,
                                                        int32_t economic_sector) const {
    double factor = effective_value(ECONOMY, _building_output_stat_ids[0],
                                    building_handle, settlement_cell, 1.0);
    factor *= effective_value(ECONOMY, _building_output_stat_ids[1], 0,
                              settlement_cell, 1.0);
    const int32_t sector_stat =
        economic_sector == 0 ? _building_output_stat_ids[2]
        : economic_sector == 1 ? _building_output_stat_ids[3]
        : economic_sector == 2 ? _building_output_stat_ids[4]
        : economic_sector == 3 ? _building_output_stat_ids[5]
        : economic_sector == 4 ? _building_output_stat_ids[6]
                               : -1;
    if (sector_stat >= 0)
        factor *= effective_value(ECONOMY, sector_stat, 0, settlement_cell, 1.0);
    return factor;
}

uint64_t ModifierRuntime::building_output_stat_version() const {
    return stat_bucket_version(ECONOMY, _building_output_stat_ids,
                               BUILDING_OUTPUT_STAT_COUNT);
}
