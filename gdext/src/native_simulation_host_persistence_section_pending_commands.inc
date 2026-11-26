    for (uint32_t i = 0; i < command_count; ++i) {
        RuntimeCommandPacket packet;
        RuntimeCommandEnvelope &envelope = packet.envelope;
        uint64_t requested_day_bits = 0;
        uint64_t effective_day_bits = 0;
        if (!read_u64(cursor, envelope.request_id) ||
            !read_u32(cursor + 8u, envelope.producer_id) ||
            !read_u64(cursor + 12u, envelope.sequence) ||
            !read_u64(cursor + 20u, envelope.observed_generation) ||
            !read_u64(cursor + 28u, requested_day_bits) ||
            !read_u64(cursor + 36u, effective_day_bits) ||
            !read_u16(cursor + 44u, envelope.domain) ||
            !read_u16(cursor + 46u, envelope.opcode) ||
            !read_u32(cursor + 48u, envelope.payload_size)) {
            error = "runtime_bundle_command_truncated";
            return false;
        }
        std::memcpy(&envelope.requested_day, &requested_day_bits,
                    sizeof(envelope.requested_day));
        std::memcpy(&envelope.effective_day, &effective_day_bits,
                    sizeof(envelope.effective_day));
        envelope.payload_offset = 0;
        cursor += 52u;
        if (envelope.request_id == 0 || envelope.requested_day < 0 ||
            envelope.effective_day < 0 || envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
            envelope.domain > static_cast<uint16_t>(RuntimeDomainId::COMMIT) ||
            envelope.opcode == 0 ||
            cursor > payload_end || envelope.payload_size > payload_end - cursor) {
            error = "runtime_bundle_command_invalid";
            return false;
        }
        if (envelope.payload_size > 0) {
            std::memcpy(packet.payload.data(), bytes + cursor,
                        envelope.payload_size);
        }
        if (!is_country_day_observation(envelope) &&
                ++regular_commands > RUNTIME_COMMAND_QUEUE_CAPACITY) {
            error = "runtime_bundle_command_count_invalid";
            return false;
        }
        cursor += envelope.payload_size;
        parsed.pending_commands.push_back(std::move(packet));
    }
    uint32_t marker = 0;
    if (!read_u32(cursor, marker) || marker != PRODUCER_CURSOR_MARKER) {
        error = "runtime_bundle_producer_cursor_missing";
        return false;
    }
    cursor += 4u;
    for (uint64_t &sequence : parsed.producer_sequences) {
        if (!read_u64(cursor, sequence)) {
            error = "runtime_bundle_producer_cursor_truncated";
            return false;
        }
        cursor += 8u;
    }
    if (!read_u64(cursor, parsed.fallback_producer_sequence)) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    cursor += 8u;
    uint64_t forwarded_event_id = 0;
    if (!read_u64(cursor, parsed.economy_fact_event_sequence) ||
        !read_u64(cursor + 8u, forwarded_event_id) ||
        !read_u64(cursor + 16u, parsed.trigger_forward_sequence) ||
        forwarded_event_id > static_cast<uint64_t>(INT64_MAX)) {
        error = "runtime_bundle_event_transport_invalid"; return false;
    }
    parsed.trigger_forwarded_event_id = static_cast<int64_t>(forwarded_event_id);
    cursor += 24u;
    uint32_t command_bytes = 0;
    if (!read_u32(cursor, command_bytes) || cursor > payload_end || payload_end - cursor < 4u || command_bytes > payload_end - cursor - 4u) {
        error = "runtime_bundle_economy_commands_truncated"; return false;
    }
    cursor += 4u;
    parsed.economy_command_bytes.assign(bytes + cursor, bytes + cursor + command_bytes);
    cursor += command_bytes;
    RuntimeEconomyPodAuthority command_candidate;
    if (!command_candidate.restore_command_continuation(parsed.economy_command_bytes, error)) return false;
    uint32_t transport_bytes = 0;
    if (!read_u32(cursor, transport_bytes) || cursor > payload_end || payload_end - cursor < 4u || transport_bytes > payload_end - cursor - 4u) {
        error = "runtime_bundle_trigger_transport_truncated"; return false;
    }
    cursor += 4u;
    parsed.trigger_transport_bytes.assign(bytes + cursor, bytes + cursor + transport_bytes);
    cursor += transport_bytes;
    if (!restore_trigger_transport(parsed.trigger_transport_bytes, error, false)) return false;
