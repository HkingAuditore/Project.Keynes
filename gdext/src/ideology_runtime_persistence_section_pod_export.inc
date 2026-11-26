bool NativeIdeologyRuntime::export_pod_catalog(
        const RuntimeCountryPodSnapshot &country,
        RuntimeIdeologyPodCatalog &out, std::string &error) const {
    error.clear();
    if (!_configured || !country.bootstrapped || country.catalog_hash == 0) {
        error = "ideology_pod_export_unavailable";
        return false;
    }
    RuntimeIdeologyPodCatalog catalog;
    catalog.country_catalog_hash = country.catalog_hash;
    // Same world seed on both sides: the worker seeds its offer RNG from this and
    // the country handle, exactly like `init_country_state` does on the main
    // thread.
    catalog.world_seed = _world_seed;
    catalog.class_hash = _political_class_hash;
    catalog.class_count = static_cast<uint32_t>(std::max(0, _political_class_count));
    catalog.technology_count = country.technology_count;
    catalog.research_signal_count = country.research_signal_count;
    catalog.gate_count = static_cast<uint32_t>(std::max(0, _gate_count));
    catalog.ideology_capacity = _ideology_capacity;
    catalog.spirit_capacity = _spirit_capacity;
    catalog.draw_count = _draw_count;
    catalog.offer_cost_q16 = _offer_cost_q16;
    catalog.starting_points_q16 = _starting_points_q16;
    catalog.ideology_capacity_max = _ideology_capacity_max;
    catalog.spirit_capacity_max = _spirit_capacity_max;
    catalog.offer_cost_growth_percent = _offer_cost_growth_percent;
    catalog.offer_cost_max_q16 = _offer_cost_max_q16;
    catalog.reroll_cost_percent = _reroll_cost_percent;
    catalog.point_population_weight_q16 = _point_population_weight_q16;
    catalog.point_building_weight_q16 = _point_building_weight_q16;
    catalog.point_trade_weight_q16 = _point_trade_weight_q16;
    catalog.point_gain_cap_q16 = _point_gain_cap_q16;
    catalog.point_gain_stat_id = -1;
    catalog.route_keys.clear();
    catalog.route_keys.reserve(_route_keys.size());
    for (const std::string &route : _route_keys)
        catalog.route_keys.push_back(route);
    catalog.point_population_factor_stat_id = -1;
    catalog.point_building_factor_stat_id = -1;
    catalog.point_trade_factor_stat_id = -1;
    catalog.opinion_factor_floor_stat_id = -1;
    catalog.understanding_gain_stat_id = -1;
    catalog.reroll_cost_stat_id = -1;
    catalog.school_strength_factor_stat_ids.assign(
        _school_strength_factor_stat_keys.size(), -1);
    if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime)) {
        if (!_point_gain_stat_key.empty())
            catalog.point_gain_stat_id =
                modifier_api::stat_id_for_key(*_modifier_runtime, _point_gain_stat_key);
        catalog.point_population_factor_stat_id = resolve_ideology_stat_id(
            _point_population_factor_stat_key,
            _point_population_factor_stat_id);
        catalog.point_building_factor_stat_id = resolve_ideology_stat_id(
            _point_building_factor_stat_key,
            _point_building_factor_stat_id);
        catalog.point_trade_factor_stat_id = resolve_ideology_stat_id(
            _point_trade_factor_stat_key, _point_trade_factor_stat_id);
        catalog.opinion_factor_floor_stat_id = resolve_ideology_stat_id(
            _opinion_factor_floor_stat_key, _opinion_factor_floor_stat_id);
        // Exporting the catalog is also the one place the main-thread hot path's
        // cached ids get refreshed, so both authorities resolve from the same
        // call and cannot drift apart.
        _understanding_gain_stat_id = -1;
        _reroll_cost_stat_id = -1;
        catalog.understanding_gain_stat_id = resolve_ideology_stat_id(
            _understanding_gain_stat_key, _understanding_gain_stat_id);
        catalog.reroll_cost_stat_id = resolve_ideology_stat_id(
            _reroll_cost_stat_key, _reroll_cost_stat_id);
        // The worker cannot read ModifierRuntime, so the host only needs the ID
        // here to know WHICH bucket to freeze into the opinion snapshot.
        catalog.era_decay_floor_stat_id = resolve_ideology_stat_id(
            _era_decay_floor_stat_key, _era_decay_floor_stat_id);
        catalog.offer_choice_bonus_stat_id = resolve_ideology_stat_id(
            _offer_choice_bonus_stat_key, _offer_choice_bonus_stat_id);
        for (size_t index = 0;
                index < _school_strength_factor_stat_keys.size(); ++index) {
            catalog.school_strength_factor_stat_ids[index] =
                resolve_ideology_stat_id(
                    _school_strength_factor_stat_keys[index],
                    _school_strength_factor_stat_ids[index]);
        }
    }
    catalog.school_keys = _school_keys;
    for (const CapacityUnlock &unlock : _capacity_unlocks)
        catalog.capacity_unlocks.push_back(
            {unlock.technology_id, unlock.ideology_delta, unlock.spirit_delta});
    auto modifier_template = [](const EffectTemplate &templ) {
        RuntimeIdeologyPodModifierTemplate row;
        row.definition_key_hash =
            RuntimeEffectPodAuthority::hash_text(templ.definition_key.c_str());
        row.domain = templ.domain;
        row.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            templ.value_q16 > 0 ? templ.value_q16 : Q16_ONE, 1,
            std::numeric_limits<int32_t>::max()));
        return row;
    };
    auto is_managed_program = [this](const EffectTemplate &templ) {
        if (_effect_runtime != nullptr) {
            const std::string program = effect_program_key(templ.definition_key);
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
                return true;
        }
        return false;
    };
    catalog.owner_influence_weight = _opinion_owner_influence_weight;
    catalog.funds_per_influence = _opinion_funds_per_influence;
    catalog.era_decay_bp = _era_decay_bp;
    catalog.refine_weight_bp = _refine_weight_bp;
    catalog.refine_understanding_q16 = _refine_understanding_q16;
    catalog.era_milestone_technologies = _era_milestone_technologies;
    catalog.max_commands_per_slice = static_cast<uint32_t>(
        std::max(1, _max_commands_per_slice));
    catalog.max_transition_commands = static_cast<uint32_t>(
        std::max(1, _max_transition_commands));
    catalog.max_transition_polls_per_slice = static_cast<uint32_t>(
        std::max(1, _max_transition_polls_per_slice));
    catalog.max_active_visits_per_slice = static_cast<uint32_t>(
        std::max(1, _max_active_visits_per_slice));
    catalog.levels.reserve(_levels.size());
    for (const Level &level : _levels) {
        RuntimeIdeologyPodLevel row;
        row.threshold_q16 = level.threshold_q16;
        row.daily_understanding_q16 = level.daily_understanding_q16;
        row.modifier_begin = static_cast<uint32_t>(catalog.level_modifiers.size());
        for (int32_t i = 0; i < level.persistent_count; ++i) {
            const EffectTemplate &templ = _persistent_templates[
                static_cast<size_t>(level.persistent_begin + i)];
            if (!is_managed_program(templ))
                catalog.level_modifiers.push_back(modifier_template(templ));
        }
        row.modifier_count = static_cast<uint32_t>(
            catalog.level_modifiers.size() - row.modifier_begin);
        for (int32_t i = 0; i < level.on_enter_count; ++i) {
            const EffectTemplate &templ = _on_enter_templates[
                static_cast<size_t>(level.on_enter_begin + i)];
            if (templ.action != EffectRuntime::CUSTOM_DOMAIN_COMMAND ||
                    templ.domain != 6 ||
                    templ.opcode !=
                        EffectRuntime::CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE)
                continue;
            const uint32_t count = static_cast<uint32_t>(std::max<int64_t>(
                1, std::min<int64_t>(65535, templ.value_q16)));
            row.on_enter_free_draws = static_cast<uint16_t>(
                std::min<uint32_t>(65535u,
                    static_cast<uint32_t>(row.on_enter_free_draws) + count));
        }
        catalog.levels.push_back(row);
    }
    catalog.definitions.reserve(_definitions.size());
    for (const Definition &definition : _definitions) {
        RuntimeIdeologyPodDefinition row;
        row.acquisition = definition.acquisition;
        row.copy_left_programs = definition.copy_left_programs;
        row.copyable = definition.copyable;
        row.school_index = definition.school_index < 0
            ? 0 : static_cast<uint8_t>(definition.school_index);
        row.rarity_weight = definition.rarity_weight;
        row.era_index = definition.era_index;
        row.ideology_cost = definition.ideology_cost;
        row.spirit_cost = definition.spirit_cost;
        row.min_spirit_level = definition.min_spirit_level;
        row.level_begin = static_cast<uint32_t>(definition.level_begin);
        row.level_count = static_cast<uint32_t>(definition.level_count);
        row.technology_begin = static_cast<uint32_t>(definition.technology_requirement_begin);
        row.technology_count = static_cast<uint32_t>(definition.technology_requirement_count);
        row.signal_begin = static_cast<uint32_t>(definition.signal_requirement_begin);
        row.signal_count = static_cast<uint32_t>(definition.signal_requirement_count);
        row.gate_begin = static_cast<uint32_t>(definition.gate_requirement_begin);
        row.gate_count = static_cast<uint32_t>(definition.gate_requirement_count);
        row.stance_begin = static_cast<uint32_t>(definition.stance_begin);
        row.stance_count = static_cast<uint32_t>(definition.stance_count);
        row.support_threshold_q16 = definition.support_threshold_q16;
        row.exclusion_group_id = definition.exclusion_group_id;
        row.route_mask = definition.route_mask;
        catalog.definitions.push_back(row);
    }
    catalog.technology_requirements = _technology_requirements;
    catalog.signal_requirements = _signal_requirements;
    catalog.gate_requirements = _gate_requirements;
    catalog.class_stances.reserve(_class_stances.size());
    for (const ClassStance &stance : _class_stances) {
        RuntimeIdeologyPodClassStance row;
        row.class_index = stance.class_index;
        row.stance_q16 = stance.stance_q16;
        row.critical_min_q16 = stance.critical_min_q16;
        catalog.class_stances.push_back(row);
    }
    catalog.synergy_requirements.reserve(_synergy_requirements.size());
    for (const SynergyRequirement &requirement : _synergy_requirements) {
        RuntimeIdeologyPodSynergyRequirement row;
        row.ideology_id = requirement.ideology_id;
        row.minimum_level = requirement.minimum_level;
        row.location_mask = requirement.location_mask;
        catalog.synergy_requirements.push_back(row);
    }
    catalog.synergies.reserve(_synergies.size());
    for (const Synergy &synergy : _synergies) {
        RuntimeIdeologyPodSynergy row;
        row.requirement_begin = static_cast<uint32_t>(synergy.requirement_begin);
        row.requirement_count = static_cast<uint32_t>(synergy.requirement_count);
        row.min_count = static_cast<uint32_t>(synergy.min_count);
        row.modifier_begin = static_cast<uint32_t>(catalog.synergy_modifiers.size());
        for (int32_t i = 0; i < synergy.effect_count; ++i) {
            const EffectTemplate &templ = _synergy_templates[
                static_cast<size_t>(synergy.effect_begin + i)];
            if (!is_managed_program(templ))
                catalog.synergy_modifiers.push_back(modifier_template(templ));
        }
        row.modifier_count = static_cast<uint32_t>(
            catalog.synergy_modifiers.size() - row.modifier_begin);
        catalog.synergies.push_back(row);
    }
    catalog.ideology_synergy_offsets.reserve(_ideology_synergy_offsets.size());
    for (const int32_t offset : _ideology_synergy_offsets)
        catalog.ideology_synergy_offsets.push_back(static_cast<uint32_t>(offset));
    catalog.ideology_synergy_ids = _ideology_synergy_ids;
    RuntimeIdeologyPodAuthority validator;
    if (!validator.configure(catalog, error)) return false;
    catalog.catalog_hash = validator.catalog_hash();
    // The POD recomputes its catalog hash in `configure` from the SAME struct, so this is
    // the identity a POD save/import payload must carry -- `_catalog_hash` is NOT (the two
    // sides hash their catalogs with different functions; see `rng_state`'s seeding note).
    _pod_catalog_hash = catalog.catalog_hash;
    out = std::move(catalog);
    return true;
}


// Main-thread -> POD export. This is the neutral structure both sides can hash:
// `apply_self_pod_snapshot_for_test` used to build it inline, and parity needs the
// same snapshot without applying it.
bool NativeIdeologyRuntime::export_pod_business_snapshot(
        RuntimeIdeologyPodSnapshot &out) const {
    if (!_configured) return false;
    out = RuntimeIdeologyPodSnapshot{};
    out.abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    out.catalog_hash = _catalog_hash;
    out.generation = std::max<uint64_t>(1, _pod_snapshot_generation);
    out.committed_day = _last_day;
    out.round_day = _last_day;
    out.countries.resize(_countries.size());
    for (size_t slot = 0; slot < _countries.size(); ++slot) {
        const CountryState &source = _countries[slot];
        if (source.handle == 0) continue;
        RuntimeIdeologyPodCountryState &target = out.countries[slot];
        target.handle = source.handle;
        target.unlocked_era = source.unlocked_era;
        target.ideology_points_q16 = source.ideology_points_q16;
        target.points_revision = source.points_revision;
        target.rng_state = source.rng_state;
        target.draw_sequence = source.draw_sequence;
        target.free_draws = source.free_draws;
        target.known_bits = source.known_bits;
        target.banned_bits = source.banned_bits;
        target.gate_bits = source.gate_bits;
        target.synergy_bits = source.active_synergy_bits;
        target.offer.generation = source.offer.generation;
        target.offer.ideology_ids = source.offer.ideology_ids;
        target.offer.choice_count = source.offer.choice_count;
        target.offer.active = source.offer.active;
        // Everything `apply_pod_snapshot` reads has to be exported, or applying a
        // snapshot silently zeroes it -- and the business hash would report the
        // main-thread side as "0" for these forever.
        target.lifetime_points_q16 = source.lifetime_points_q16;
        target.trade_paid_day = source.trade_paid_day;
        target.baseline_ready = source.baseline_ready;
        target.baseline_population = source.baseline_population;
        target.baseline_buildings = source.baseline_buildings;
        target.history_count = source.history_count;
        target.history_head = source.history_head;
        target.history_q16 = source.history_q16;
        target.ledger = source.ledger;
        target.ideology_slots_used = source.ideology_slots_used;
        target.spirit_slots_used = source.spirit_slots_used;
        target.opinion_revision = source.opinion_revision;
        target.ideas.resize(_definitions.size());
        for (const IdeaState &idea : source.ideas) {
            if (idea.ideology_id < 0 ||
                    idea.ideology_id >= static_cast<int32_t>(_definitions.size()))
                continue;
            RuntimeIdeologyPodIdeaState &row =
                target.ideas[static_cast<size_t>(idea.ideology_id)];
            row.understanding_q16 = idea.understanding_q16;
            row.level = idea.level;
            row.entered_levels = idea.entered_levels;
            row.generation = idea.generation;
            row.location = static_cast<RuntimeIdeologyPodLocation>(idea.location);
            row.slot_index = idea.slot_index;
        }
    }
    // Business hash, not `compute_state_hash`: the latter folds in generation,
    // cursors and opinion_revision, which differ between main and worker by
    // construction and made every parity comparison a guaranteed mismatch.
    out.state_hash = ideology_business_hash(out);
    return true;
}


// ── worker IMPORT: the state a restored save must make the POD adopt ───────────
//
// WHY THIS EXISTS. `restore()` rebuilds this runtime's rows, and under IDEOLOGY worker
// authority this runtime is a MIRROR: `apply_pod_snapshot` replaces its rows wholesale
// from the next worker publish. So a restore changes only the main thread, and the
// worker's next publish puts its own state back (measured: `idea_rows [82,1,0,0] -> []`,
// §9.3 dates `7/8 -> 2/3`, then a pump with nothing to fold). The import closes that by
// producing exactly what the POD needs to ADOPT the same state -- not a merge: the POD's
// committed day, rows, points, RNG and offer all become the payload's.
//
// WHY THE BUSINESS SNAPSHOT IS NOT ENOUGH. Three things it deliberately omits are
// required for the POD to accept and reproduce the state:
//   1. the POD's CATALOG identity (`_pod_catalog_hash`, not `_catalog_hash`: the two
//      sides hash their catalogs with different functions);
//   2. the live per-slot COUNTRY generation, which `validate_inputs` compares on every
//      plan and which also encodes into the handle (`generation << 32 | slot`);
//   3. the CALENDAR: `apply_pod_snapshot` stamps the two §9.3 dates from
//      `committed_day`, so that field decides whether the mirror keeps the payload's
//      dates or adopts the worker's (`7/8` vs `2/3`).
bool NativeIdeologyRuntime::export_pod_import_state(
        RuntimeIdeologyPodSnapshot &out,
        const RuntimeCountryPodSnapshot &country, std::string &error) const {
    error.clear();
    if (!_configured) { error = "ideology_runtime_not_configured"; return false; }
    if (_pod_catalog_hash == 0) {
        error = "ideology_pod_catalog_identity_unavailable";
        return false;
    }
    if (!country.bootstrapped || country.country_count == 0 ||
        country.country_active.size() != country.country_count ||
        country.country_generation.size() != country.country_count) {
        error = "ideology_pod_import_country_snapshot_invalid";
        return false;
    }
    if (!export_pod_business_snapshot(out)) {
        error = "ideology_runtime_not_configured";
        return false;
    }
    // The POD indexes a country row by `handle & 0xffffffff` and refuses a state whose
    // row count differs from the Country snapshot it plans against (`validate_inputs`),
    // so the mirror's trailing empty rows are trimmed -- but a row that still carries a
    // handle is a country the Country domain does not know about, and dropping it would
    // silently lose a card.
    for (size_t slot = country.country_count; slot < out.countries.size(); ++slot) {
        if (out.countries[slot].handle != 0) {
            error = "ideology_pod_import_country_shape_mismatch";
            return false;
        }
    }
    if (out.countries.size() < country.country_count) {
        error = "ideology_pod_import_country_shape_mismatch";
        return false;
    }
    out.countries.resize(country.country_count);
    for (uint32_t slot = 0; slot < country.country_count; ++slot) {
        RuntimeIdeologyPodCountryState &row = out.countries[slot];
        if (country.country_active[slot] == 0) {
            row = RuntimeIdeologyPodCountryState{};
            continue;
        }
        const uint64_t handle =
            (static_cast<uint64_t>(country.country_generation[slot]) << 32u) | slot;
        if (row.handle != handle) {
            error = "ideology_pod_import_country_handle_mismatch";
            return false;
        }
        row.generation = country.country_generation[slot];
    }
    out.catalog_hash = _pod_catalog_hash;
    // ── the calendar ────────────────────────────────────────────────────────
    // The CONFIRMED day is the day this state was confirmed on, and it is the value
    // `apply_pod_snapshot` maps back onto `_derived_basis_confirmed_day`. Anything else
    // (the worker's own day, or the payload's `_last_day`) moves the mirrored dates.
    const int64_t floor_day = _derived_basis_confirmed_day >= 0
        ? _derived_basis_confirmed_day : _last_day;
    if (floor_day < 0) {
        error = "ideology_pod_import_day_unavailable";
        return false;
    }
    out.committed_day = floor_day;
    out.round_day = -1;
    out.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
    out.pending_cursor = 0;
    out.command_cursor = 0;
    out.active_country_cursor = 0;
    out.active_idea_cursor = 0;
    out.next_submit_order = std::max<uint64_t>(1, _submit_order);
    out.producer_high_watermarks.clear();
    // `_producer_high_watermarks` is an unordered_map and the POD's restore requires
    // STRICTLY ASCENDING producer ids, so the rows are sorted here (the same way
    // `capture()` sorts its own copy) instead of relying on iteration order.
    std::vector<std::pair<int32_t, int64_t>> watermarks(
        _producer_high_watermarks.begin(), _producer_high_watermarks.end());
    std::sort(watermarks.begin(), watermarks.end());
    out.producer_high_watermarks.reserve(watermarks.size());
    for (const auto &entry : watermarks) {
        if (entry.first <= 0) continue;
        RuntimeIdeologyPodProducerWatermark watermark;
        watermark.producer_id = static_cast<uint32_t>(entry.first);
        watermark.sequence = static_cast<uint64_t>(std::max<int64_t>(0, entry.second));
        out.producer_high_watermarks.push_back(watermark);
    }
    // PKID's rows are SETTLED state: a pending transition is persisted on the row, and
    // the row already carries the level and location the transition settles to. So the
    // import carries no transition and no command -- re-emitting one would drive an
    // Effect instance this worker never ordered, on a card whose bindings live on the
    // main thread.
    out.pending_transitions.clear();
    out.commands.clear();
    out.receipts.clear();
    // One generation AHEAD of everything the mirror has applied. A snapshot the ring
    // still holds from before the import then loses the generation race instead of
    // overwriting the restore (`apply_pod_snapshot` refuses a regression).
    out.generation = std::max<uint64_t>(1, _pod_snapshot_generation + 1);
    RuntimeIdeologyPodAuthority::canonicalize_import(out);
    return true;
}


void NativeIdeologyRuntime::record_worker_import(
        const std::string &code, bool applied, bool retryable) {
    ++_worker_import_attempts;
    _worker_import_last_code = code;
    // A refused payload must not become an infinite retry: retrying would ALSO keep the
    // write-back from applying (the pending flag guards the restore), which would freeze
    // the mirror instead of reporting the refusal. Only "the worker held the day
    // boundary" is worth another attempt.
    if (applied || !retryable) _worker_import_pending = false;
}
