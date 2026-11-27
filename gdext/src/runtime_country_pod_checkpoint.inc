bool RuntimeCountryPodAuthority::encode_save(
        RuntimeCountryPodSaveSection &out, std::string &error) const {
    error.clear();
    out = RuntimeCountryPodSaveSection{};
    if (!_bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    std::vector<uint8_t> payload;
    payload.reserve(256u + _state.cell_country_slot.size() * 8u +
                    _state.country_goods.size() * sizeof(int64_t));
    append_u32(payload, COUNTRY_SECTION_MARKER);
    append_u32(payload, COUNTRY_SECTION_ABI);
    append_u64(payload, _state.session_epoch);
    append_u64(payload, _catalog.catalog_hash);
    append_i64(payload, _state.committed_day);
    append_i64(payload, _state.last_research_day);
    append_u64(payload, _state.generation);
    append_u64(payload, _state.state_hash);
    append_u32(payload, _state.cell_count);
    append_u32(payload, _state.country_count);
    append_u32(payload, _state.technology_words);
    append_u32(payload, _state.technology_count);
    append_u32(payload, _state.good_count);
    append_u32(payload, _state.research_signal_words);
    append_u32(payload, _state.research_signal_count);
    append_u8(payload, _state.bootstrapped ? 1u : 0u);
    append_u8(payload, _state.research_active_index_valid ? 1u : 0u);
    append_vector(payload, _state.country_active);
    append_vector(payload, _state.country_generation);
    append_vector(payload, _state.country_state_version);
    append_vector(payload, _state.country_political_regime_ids);
    append_vector(payload, _state.country_political_regime_capabilities);
    append_vector(payload, _state.research_active_country_slots);
    append_vector(payload, _state.territory_count);
    append_vector(payload, _state.country_cash);
    append_vector(payload, _state.country_goods);
    append_vector(payload, _state.cell_country_slot);
    append_vector(payload, _state.territory_offsets);
    append_vector(payload, _state.territory_cells);
    append_vector(payload, _state.country_technologies);
    append_vector(payload, _state.country_discovered);
    append_vector(payload, _state.country_pending_technologies);
    append_vector(payload, _state.country_research_signals);
    append_vector(payload, _state.research_signal_evidence_offsets);
    append_u32(payload, static_cast<uint32_t>(_state.research_signal_evidence.size()));
    for (const auto &entry : _state.research_signal_evidence) {
        append_i32(payload, entry.signal);
        append_i32(payload, entry.count);
        append_i64(payload, entry.first_day);
        append_i64(payload, entry.last_day);
        append_i32(payload, entry.first_cell);
    }
    append_vector(payload, _state.research_queues);
    append_vector(payload, _state.research_queue_lengths);
    append_vector(payload, _state.research_weights_bp);
    append_vector(payload, _state.research_deferred_points);
    append_vector(payload, _state.research_progress);
    append_vector(payload, _state.research_cost_factor);
    append_vector(payload, _state.research_efficiency);
    append_vector(payload, _state.research_peer_flags);
    append_vector(payload, _state.research_auto_purchase);
    append_vector(payload, _state.research_purchased_total);
    append_vector(payload, _state.research_consumed_total);
    append_vector(payload, _state.research_progress_total);
    append_vector(payload, _state.research_completed_total);
    append_vector(payload, _state.is_water);
    append_u32(payload, 0x31494453u); // SID1 identity trailer
    append_u32(payload, _state.profession_count);
    append_u32(payload, _state.building_type_count);
    append_strings(payload, _state.country_stable_ids);
    append_strings(payload, _state.country_display_names);
    append_u32(payload, static_cast<uint32_t>(_pending.size()));
    for (const RuntimeCountryCommand &command : _pending) append_command(payload, command);
    out.payload = std::move(payload);
    out.catalog_hash = _catalog.catalog_hash;
    out.committed_day = _state.committed_day;
    out.generation = _state.generation;
    out.state_hash = _state.state_hash;
    out.descriptor.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    out.descriptor.version = COUNTRY_SECTION_ABI;
    out.descriptor.payload_offset = 0;
    out.descriptor.payload_size = static_cast<uint32_t>(out.payload.size());
    out.descriptor.checksum = checksum(out.payload.data(), out.payload.size());
    return true;
}

bool RuntimeCountryPodAuthority::restore_save(
        const RuntimeCountryPodSaveSection &section,
        const RuntimeCountryPodCatalog &catalog, std::string &error) {
    error.clear();
    if (!validate_catalog(catalog, error)) return false;
    if (section.descriptor.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
        section.descriptor.version != COUNTRY_SECTION_ABI ||
        section.descriptor.payload_size != section.payload.size() ||
        section.descriptor.checksum != checksum(section.payload.data(), section.payload.size())) {
        error = "country_section_checksum_or_abi_mismatch";
        return false;
    }
    Reader reader{section.payload.data(), section.payload.size(), 0};
    uint32_t marker = 0, abi = 0, cell_count = 0, country_count = 0;
    uint32_t technology_words = 0, technology_count = 0, good_count = 0;
    uint32_t research_signal_words = 0, research_signal_count = 0;
    uint64_t session_epoch = 0, catalog_hash = 0, generation = 0, state_hash = 0;
    int64_t committed_day = -1, last_research_day = -1;
    uint8_t bootstrapped = 0, active_index_valid = 0;
    if (!reader.u32(marker) || marker != COUNTRY_SECTION_MARKER ||
        !reader.u32(abi) || abi != COUNTRY_SECTION_ABI ||
        !reader.u64(session_epoch) || !reader.u64(catalog_hash) ||
        !reader.i64(committed_day) || !reader.i64(last_research_day) ||
        !reader.u64(generation) || !reader.u64(state_hash) ||
        !reader.u32(cell_count) || !reader.u32(country_count) ||
        !reader.u32(technology_words) || !reader.u32(technology_count) ||
        !reader.u32(good_count) || !reader.u32(research_signal_words) ||
        !reader.u32(research_signal_count) || !reader.u8(bootstrapped) ||
        !reader.u8(active_index_valid)) {
        error = "country_section_payload_truncated";
        return false;
    }
    if (catalog_hash != catalog.catalog_hash ||
        session_epoch == 0 || generation == 0 || committed_day < -1 ||
        last_research_day > committed_day || bootstrapped == 0 ||
        cell_count == 0 || country_count == 0 ||
        technology_count != catalog.technology_count ||
        technology_words != catalog.technology_words ||
        good_count == 0) {
        error = "country_section_header_mismatch";
        return false;
    }
    RuntimeCountryPodSnapshot restored;
    restored.session_epoch = session_epoch;
    restored.generation = generation;
    restored.state_hash = state_hash;
    restored.catalog_hash = catalog_hash;
    restored.committed_day = committed_day;
    restored.last_research_day = last_research_day;
    restored.cell_count = cell_count;
    restored.country_count = country_count;
    restored.technology_words = technology_words;
    restored.technology_count = technology_count;
    restored.good_count = good_count;
    restored.research_signal_words = research_signal_words;
    restored.research_signal_count = research_signal_count;
    restored.bootstrapped = true;
    restored.research_active_index_valid = active_index_valid != 0;
    const uint32_t max_cells = std::max<uint32_t>(cell_count, 1u << 20u);
    const uint32_t max_countries = std::max<uint32_t>(country_count, 1u << 16u);
    if (!reader.vector(restored.country_active, max_countries) ||
        !reader.vector(restored.country_generation, max_countries) ||
        !reader.vector(restored.country_state_version, max_countries) ||
        !reader.vector(restored.country_political_regime_ids, max_countries) ||
        !reader.vector(restored.country_political_regime_capabilities, max_countries) ||
        !reader.vector(restored.research_active_country_slots, max_countries) ||
        !reader.vector(restored.territory_count, max_countries) ||
        !reader.vector(restored.country_cash, max_countries) ||
        !reader.vector(restored.country_goods, max_countries * std::max<uint32_t>(good_count, 1u)) ||
        !reader.vector(restored.cell_country_slot, max_cells) ||
        !reader.vector(restored.territory_offsets, max_countries + 1u) ||
        !reader.vector(restored.territory_cells, max_cells) ||
        !reader.vector(restored.country_technologies, max_countries * technology_words) ||
        !reader.vector(restored.country_discovered, max_countries * technology_words) ||
        !reader.vector(restored.country_pending_technologies, max_countries * technology_words) ||
        !reader.vector(restored.country_research_signals,
                       max_countries * research_signal_words) ||
        !reader.vector(restored.research_signal_evidence_offsets, max_countries + 1u)) {
        error = "country_section_payload_invalid";
        return false;
    }
    uint32_t evidence_count = 0;
    if (!reader.u32(evidence_count) || evidence_count > max_cells * 16u) {
        error = "country_section_signal_evidence_invalid";
        return false;
    }
    restored.research_signal_evidence.resize(evidence_count);
    for (auto &entry : restored.research_signal_evidence) {
        if (!reader.i32(entry.signal) || !reader.i32(entry.count) ||
            !reader.i64(entry.first_day) || !reader.i64(entry.last_day) ||
            !reader.i32(entry.first_cell)) {
            error = "country_section_signal_evidence_truncated";
            return false;
        }
    }
    if (!reader.vector(restored.research_queues, max_countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT * COUNTRY_QUEUE_SLOTS) ||
        !reader.vector(restored.research_queue_lengths, max_countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) ||
        !reader.vector(restored.research_weights_bp, max_countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) ||
        !reader.vector(restored.research_deferred_points, max_countries) ||
        !reader.vector(restored.research_progress, max_countries * technology_count) ||
        !reader.vector(restored.research_cost_factor, max_countries) ||
        !reader.vector(restored.research_efficiency, max_countries * 4u) ||
        !reader.vector(restored.research_peer_flags, max_countries * technology_count) ||
        !reader.vector(restored.research_auto_purchase, max_countries) ||
        !reader.vector(restored.research_purchased_total, max_countries) ||
        !reader.vector(restored.research_consumed_total, max_countries) ||
        !reader.vector(restored.research_progress_total, max_countries) ||
        !reader.vector(restored.research_completed_total, max_countries) ||
        !reader.vector(restored.is_water, max_cells)) {
        error = "country_section_payload_invalid";
        return false;
    }
    uint32_t identity_marker = 0;
    if (reader.peek_u32(identity_marker) && identity_marker == 0x31494453u) {
        uint32_t discarded = 0;
        if (!reader.u32(discarded) || !reader.u32(restored.profession_count) ||
            !reader.u32(restored.building_type_count) ||
            !reader.strings(restored.country_stable_ids, max_countries) ||
            !reader.strings(restored.country_display_names, max_countries)) {
            error = "country_section_identity_invalid";
            return false;
        }
    }
    uint32_t pending_count = 0;
    if (!reader.u32(pending_count) || pending_count > COUNTRY_COMMAND_CAPACITY) {
        error = "country_section_pending_commands_invalid";
        return false;
    }
    std::vector<RuntimeCountryCommand> restored_pending;
    restored_pending.reserve(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        RuntimeCountryCommand command;
        if (!read_command(reader, command)) {
            error = "country_section_pending_commands_truncated";
            return false;
        }
        std::string command_error;
        if (!RuntimeCountryPodAdapter::validate_command(command, command_error) ||
            command.effective_day <= committed_day) {
            error = "country_section_pending_command_invalid";
            return false;
        }
        restored_pending.push_back(command);
    }
    if (reader.cursor != reader.size) {
        error = "country_section_payload_trailing_bytes";
        return false;
    }
    std::string state_error;
    if (!validate_state(restored, state_error)) {
        error = state_error.empty() ? "country_section_state_invalid" : state_error;
        return false;
    }
    restored.state_hash = hash_business_state(restored);
    if (restored.state_hash != state_hash) {
        error = "country_section_state_hash_mismatch";
        return false;
    }
    // Commit only after every header, vector shape, checksum, and state hash
    // has validated. A failed restore leaves the previous worker state intact.
    _state = std::move(restored);
    country_core_repair_research_active_index(_state);
    _catalog = catalog;
    _pending = std::move(restored_pending);
    _plan_active = false;
    _bootstrapped = true;
    _next_generation = _state.generation + 1u;
    return true;
}
