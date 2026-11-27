bool is_country_day_observation(const RuntimeCommandEnvelope &envelope) {
    return envelope.domain == static_cast<uint16_t>(RuntimeDomainId::COUNTRY) &&
        envelope.producer_id == COUNTRY_OBSERVATION_ARCHIVE_PRODUCER &&
        envelope.opcode == CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL;
}

RuntimeCommandPacket encode_country_packet(const RuntimeCountryCommand &command) {
    RuntimeCommandPacket packet;
    auto &envelope = packet.envelope;
    envelope.request_id = command.request_id;
    envelope.producer_id = command.producer_id;
    envelope.sequence = command.sequence;
    envelope.observed_generation = command.observed_generation;
    envelope.requested_day = command.requested_day;
    envelope.effective_day = command.effective_day;
    envelope.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    envelope.opcode = command.opcode;
    std::vector<uint8_t> payload;
    payload.reserve(COUNTRY_COMMAND_WIRE_SIZE);
    append_command(payload, command);
    envelope.payload_size = static_cast<uint32_t>(payload.size());
    std::copy(payload.begin(), payload.end(), packet.payload.begin());
    packet.submit_order = command.submit_order;
    return packet;
}

bool RuntimeCountryPodAdapter::decode_command(
        const RuntimeCommandPacket &packet, RuntimeCountryCommand &command,
        std::string &error) {
    error.clear();
    const auto &envelope = packet.envelope;
    if (envelope.payload_offset > RUNTIME_MAX_COMMAND_PAYLOAD ||
        envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
        envelope.payload_offset + envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD) {
        error = "invalid_command_payload";
        return false;
    }
    if (envelope.payload_size != COUNTRY_COMMAND_WIRE_SIZE) {
        error = "invalid_country_command_payload_size";
        return false;
    }
    Reader reader{packet.payload.data() + envelope.payload_offset, envelope.payload_size};
    if (!read_command(reader, command) || reader.cursor != reader.size ||
            command.opcode != envelope.opcode) {
        error = "invalid_country_command_payload";
        return false;
    }
    command.request_id = envelope.request_id;
    command.producer_id = envelope.producer_id;
    command.sequence = envelope.sequence;
    command.submit_order = packet.submit_order;
    command.observed_generation = envelope.observed_generation;
    command.requested_day = envelope.requested_day;
    command.effective_day = envelope.effective_day;
    return validate_command(command, error);
}

bool RuntimeCountryPodAdapter::validate_command(
        const RuntimeCountryCommand &command, std::string &error) {
    error.clear();
    // effective_day may be earlier than requested_day when Host clamps an
    // ahead-of-worker UI stamp onto simulation_committed+1. The opposite
    // (effective later than requested) is the trailing-UI reschedule path.
    // Both are intentional; only identity / negative days are hard rejects.
    if (command.request_id == 0 || command.sequence == 0 ||
        command.effective_day < 0 || command.requested_day < 0) {
        error = "invalid_country_command_value";
        return false;
    }
    if (command.opcode == 5 && !runtime_country_research_weights_valid(command.weights_bp)) {
        error = "invalid_research_weights";
        return false;
    }
    if (command.cell < -1 || command.domain < -1 || command.position < -1) {
        error = "invalid_country_command_target";
        return false;
    }
    return true;
}

bool RuntimeCountryPodAdapter::execute_day(
        const RuntimeCountryPodSnapshot &snapshot,
        const RuntimeCountryDayContext &context,
        RuntimeCountryDayCommit &commit,
        RuntimeCountryPodDiagnostics &diagnostics) {
    commit = RuntimeCountryDayCommit{};
    diagnostics = RuntimeCountryPodDiagnostics{};
    if (context.day < 0 || !std::isfinite(context.speed_scale)) {
        commit.error_code = RuntimeCountryPodError::INVALID_CONTEXT;
        runtime_copy_text(diagnostics.blocker, "invalid_context");
        return false;
    }
    std::string error;
    if (!validate_snapshot(snapshot, error)) {
        commit.error_code = RuntimeCountryPodError::NOT_BOOTSTRAPPED;
        runtime_copy_text(diagnostics.blocker, error.c_str());
        return false;
    }
    uint64_t work = 0;
    uint32_t active = 0;
    uint32_t pending = 0;
    // Country maintains this sorted membership index whenever research
    // inputs change.  Iterating it avoids touching dormant countries on every
    // shadow/worker day.  Empty snapshots remain valid for old captures and
    // deliberately use the conservative full scan.
    const auto visit_slot = [&](uint32_t slot) {
        if (snapshot.country_active[slot] == 0) return;
        ++active;
        work += 1;
        const size_t base = static_cast<size_t>(slot) * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            const uint8_t length = snapshot.research_queue_lengths[base + domain];
            pending += length > 0 ? 1u : 0u;
            work += length;
        }
    };
    if (snapshot.research_active_index_valid) {
        for (const int32_t slot : snapshot.research_active_country_slots)
            visit_slot(static_cast<uint32_t>(slot));
    } else {
        for (uint32_t slot = 0; slot < snapshot.country_count; ++slot)
            visit_slot(slot);
    }
    commit.completed = 1;
    commit.preflight_ok = 1;
    commit.ack_required = 1; // Effect/Modifier/Economy ACK adapters are not migrated yet.
    commit.error_code = RuntimeCountryPodError::CROSS_DOMAIN_BARRIER_REQUIRED;
    commit.changed_countries = 0;
    commit.changed_territory_cells = 0;
    commit.research_work_units = work;
    commit.country_generation = snapshot.generation;
    commit.state_hash = snapshot.state_hash ^ static_cast<uint64_t>(context.day);
    if (active > 0) commit.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
    diagnostics.snapshot_generation = snapshot.generation;
    diagnostics.state_hash = commit.state_hash;
    diagnostics.work_units = work;
    diagnostics.active_country_count = active;
    diagnostics.active_index_count = !snapshot.research_active_index_valid
        ? snapshot.country_count
        : static_cast<uint32_t>(snapshot.research_active_country_slots.size());
    diagnostics.pending_checks = pending;
    diagnostics.ack_pending = 1;
    runtime_copy_text(diagnostics.blocker, "cross_domain_ack_adapter_missing");
    return true;
}
