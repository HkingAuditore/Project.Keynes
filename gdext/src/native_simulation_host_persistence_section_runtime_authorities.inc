    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_DOMAIN_POD) != 0) {
        constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
        uint32_t marker = 0;
        uint32_t section_size = 0;
        const bool section_header_available = cursor <= payload_end &&
            payload_end - cursor >= 8u;
        if (!section_header_available || !read_u32(cursor, marker) ||
            marker != DOMAIN_SECTION_MARKER ||
            !read_u32(cursor + 4u, section_size) ||
            section_size > 64u * 1024u * 1024u ||
            payload_end - cursor < 16u ||
            section_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_domain_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.domain_pod_bytes.assign(bytes + cursor, bytes + cursor + section_size);
        cursor += section_size;
        uint64_t section_checksum = 0;
        if (!read_u64(cursor, section_checksum)) {
            error = "runtime_bundle_domain_section_checksum_missing";
            return false;
        }
        uint64_t computed_section_checksum = 1469598103934665603ull;
        for (const uint8_t byte : parsed.domain_pod_bytes) {
            computed_section_checksum ^= static_cast<uint64_t>(byte);
            computed_section_checksum *= 1099511628211ull;
        }
        if (computed_section_checksum != section_checksum) {
            error = "runtime_bundle_domain_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_CLIMATE) != 0) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // CLM2
        uint32_t climate_marker = 0;
        uint32_t climate_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, climate_marker) ||
            !read_u32(cursor + 4u, climate_size) ||
            climate_marker != CLIMATE_SECTION_MARKER ||
            climate_size > 64u * 1024u * 1024u ||
            climate_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_climate_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.climate_bytes.assign(bytes + cursor, bytes + cursor + climate_size);
        cursor += climate_size;
        uint64_t climate_checksum = 0;
        if (!read_u64(cursor, climate_checksum)) {
            error = "runtime_bundle_climate_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.climate_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != climate_checksum) {
            error = "runtime_bundle_climate_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_COUNTRY) != 0) {
        constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
        uint32_t country_marker = 0;
        uint32_t country_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, country_marker) ||
            !read_u32(cursor + 4u, country_size) ||
            country_marker != COUNTRY_SECTION_MARKER ||
            country_size > 64u * 1024u * 1024u ||
            country_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_country_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.country_bytes.assign(bytes + cursor, bytes + cursor + country_size);
        cursor += country_size;
        uint64_t country_checksum = 0;
        if (!read_u64(cursor, country_checksum)) {
            error = "runtime_bundle_country_section_checksum_missing";
            return false;
        }
        const uint64_t computed = country_checkpoint_checksum(
            parsed.country_bytes.data(), parsed.country_bytes.size());
        if (computed != country_checksum) {
            error = "runtime_bundle_country_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        CountryCoreCheckpoint checkpoint;
        if (!decode_country_core_checkpoint(parsed.country_bytes.data(),
                                            parsed.country_bytes.size(),
                                            checkpoint, error)) {
            error = "runtime_bundle_country_section_invalid:" + error;
            return false;
        }
        std::unordered_map<uint64_t, CountryCommandReceiptCode> country_states;
        country_states.reserve(checkpoint.request_states.size());
        for (const CountryCommandReceipt &receipt : checkpoint.request_states)
            country_states.emplace(receipt.request_id, receipt.code);
        std::unordered_set<uint64_t> country_terminals;
        country_terminals.reserve(checkpoint.terminal_receipts.size());
        for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts)
            country_terminals.insert(receipt.request_id);
        for (const RuntimeCommandPacket &packet : parsed.pending_commands) {
            if (packet.envelope.domain !=
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY)) {
                continue;
            }
            const auto state = country_states.find(packet.envelope.request_id);
            if (state == country_states.end() ||
                state->second != CountryCommandReceiptCode::ACCEPTED ||
                country_terminals.find(packet.envelope.request_id) !=
                    country_terminals.end()) {
                error = "runtime_bundle_country_pending_receipt_invalid";
                return false;
            }
        }
        parsed.country_pkcn_bytes = checkpoint.canonical_pkcn;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_ASSET) != 0) {
        constexpr uint32_t D7_SECTION_MARKER = 0x31543744u; // D7T1
        uint32_t d7_marker = 0;
        uint32_t d7_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, d7_marker) ||
            !read_u32(cursor + 4u, d7_size) ||
            d7_marker != D7_SECTION_MARKER ||
            d7_size > 64u * 1024u * 1024u ||
            d7_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_d7_transaction_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_asset_bytes.assign(bytes + cursor,
                                          bytes + cursor + d7_size);
        cursor += d7_size;
        uint64_t d7_checksum = 0;
        if (!read_u64(cursor, d7_checksum)) {
            error = "runtime_bundle_d7_transaction_checksum_missing";
            return false;
        }
        uint64_t computed_d7 = 1469598103934665603ull;
        for (const uint8_t byte : parsed.economy_asset_bytes) {
            computed_d7 ^= static_cast<uint64_t>(byte);
            computed_d7 *= 1099511628211ull;
        }
        if (computed_d7 != d7_checksum) {
            error = "runtime_bundle_d7_transaction_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_asset_bytes.size() < 8u ||
            std::memcmp(parsed.economy_asset_bytes.data(), "D7T1", 4u) != 0) {
            error = "runtime_bundle_d7_transaction_marker_invalid";
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_TRIGGER) != 0) {
        constexpr uint32_t TRIGGER_SECTION_MARKER = 0x31445054u; // TPD1
        uint32_t trigger_marker = 0;
        uint32_t trigger_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, trigger_marker) ||
            !read_u32(cursor + 4u, trigger_size) ||
            trigger_marker != TRIGGER_SECTION_MARKER ||
            trigger_size > 64u * 1024u * 1024u ||
            trigger_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_trigger_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.trigger_bytes.assign(bytes + cursor, bytes + cursor + trigger_size);
        cursor += trigger_size;
        uint64_t trigger_checksum = 0;
        if (!read_u64(cursor, trigger_checksum)) {
            error = "runtime_bundle_trigger_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.trigger_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != trigger_checksum) {
            error = "runtime_bundle_trigger_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_MODIFIER) != 0) {
        constexpr uint32_t MODIFIER_SECTION_MARKER = 0x3246444Du; // MDF2
        uint32_t modifier_marker = 0;
        uint32_t modifier_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, modifier_marker) ||
            !read_u32(cursor + 4u, modifier_size) ||
            modifier_marker != MODIFIER_SECTION_MARKER ||
            modifier_size > 64u * 1024u * 1024u ||
            modifier_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_modifier_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.modifier_bytes.assign(bytes + cursor, bytes + cursor + modifier_size);
        cursor += modifier_size;
        uint64_t modifier_checksum = 0;
        if (!read_u64(cursor, modifier_checksum)) {
            error = "runtime_bundle_modifier_section_checksum_missing";
            return false;
        }
        uint64_t computed_modifier = 1469598103934665603ull;
        for (const uint8_t byte : parsed.modifier_bytes) {
            computed_modifier ^= static_cast<uint64_t>(byte);
            computed_modifier *= 1099511628211ull;
        }
        if (computed_modifier != modifier_checksum) {
            error = "runtime_bundle_modifier_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.modifier_bytes.size() < 4u ||
            std::memcmp(parsed.modifier_bytes.data(), "MDF2", 4u) != 0) {
            error = "runtime_bundle_modifier_section_marker_invalid";
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EVENTS) != 0) {
        constexpr uint32_t EVENTS_SECTION_MARKER = 0x31545645u; // EVT1
        uint32_t events_marker = 0;
        uint32_t events_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, events_marker) ||
            !read_u32(cursor + 4u, events_size) ||
            events_marker != EVENTS_SECTION_MARKER ||
            events_size > 64u * 1024u * 1024u ||
            events_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_events_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.events_bytes.assign(bytes + cursor, bytes + cursor + events_size);
        cursor += events_size;
        uint64_t events_checksum = 0;
        if (!read_u64(cursor, events_checksum)) {
            error = "runtime_bundle_events_section_checksum_missing";
            return false;
        }
        uint64_t computed_events = 1469598103934665603ull;
        for (const uint8_t byte : parsed.events_bytes) {
            computed_events ^= static_cast<uint64_t>(byte);
            computed_events *= 1099511628211ull;
        }
        if (computed_events != events_checksum) {
            error = "runtime_bundle_events_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.events_bytes.size() < 4u ||
            std::memcmp(parsed.events_bytes.data(), "EVT1", 4u) != 0) {
            error = "runtime_bundle_events_section_marker_invalid";
            return false;
        }
        RuntimeEventsAuthority candidate;
        std::string events_restore_error;
        if (!candidate.restore(parsed.events_bytes.data(),
                               parsed.events_bytes.size(), events_restore_error)) {
            error = events_restore_error.empty()
                ? "runtime_bundle_events_restore_invalid" : events_restore_error;
            return false;
        }
    }
