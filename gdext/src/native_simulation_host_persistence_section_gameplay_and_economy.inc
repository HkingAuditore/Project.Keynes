    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT) != 0) {
        constexpr uint32_t GMP1_MARKER = 0x31504d47u; // GMP1
        uint32_t marker = 0;
        uint32_t section_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, marker) ||
            !read_u32(cursor + 4u, section_size) || marker != GMP1_MARKER ||
            section_size != 32u || section_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_gameplay_effect_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.gameplay_effect_bytes.assign(bytes + cursor,
                                            bytes + cursor + section_size);
        cursor += section_size;
        uint64_t stored_checksum = 0;
        if (!read_u64(cursor, stored_checksum)) {
            error = "runtime_bundle_gameplay_effect_checksum_missing";
            return false;
        }
        uint64_t computed_checksum = 1469598103934665603ull;
        for (const uint8_t byte : parsed.gameplay_effect_bytes) {
            computed_checksum ^= static_cast<uint64_t>(byte);
            computed_checksum *= 1099511628211ull;
        }
        if (computed_checksum != stored_checksum) {
            error = "runtime_bundle_gameplay_effect_checksum_failed";
            return false;
        }
        cursor += 8u;
        size_t gmp_cursor = 0;
        uint32_t inner_marker = 0;
        uint32_t abi = 0;
        uint64_t generation = 0;
        uint32_t pending = 0;
        uint32_t terminal = 0;
        uint64_t state_hash = 0;
        if (!d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, inner_marker) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, abi) ||
            !d7_read_u64(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, generation) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, pending) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, terminal) ||
            !d7_read_u64(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, state_hash) || gmp_cursor != section_size ||
            inner_marker != GMP1_MARKER || abi != 1u) {
            error = "runtime_bundle_gameplay_effect_payload_invalid";
            return false;
        }
        uint32_t actual_pending = 0;
        for (const RuntimeCommandPacket &packet : parsed.pending_commands) {
            if (packet.envelope.domain == static_cast<uint16_t>(
                    RuntimeDomainId::GAMEPLAY_EFFECT))
                ++actual_pending;
        }
        if (pending != actual_pending) {
            error = "runtime_bundle_gameplay_effect_pending_mismatch";
            return false;
        }
        (void)generation;
        (void)terminal;
        (void)state_hash;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EFFECT) != 0) {
        constexpr uint32_t EFFECT_SECTION_MARKER = 0x31504645u; // EFP1
        uint32_t effect_marker = 0;
        uint32_t effect_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, effect_marker) ||
            !read_u32(cursor + 4u, effect_size) ||
            effect_marker != EFFECT_SECTION_MARKER ||
            effect_size > 64u * 1024u * 1024u ||
            effect_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_effect_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.effect_bytes.assign(bytes + cursor, bytes + cursor + effect_size);
        cursor += effect_size;
        uint64_t effect_checksum = 0;
        if (!read_u64(cursor, effect_checksum)) {
            error = "runtime_bundle_effect_section_checksum_missing";
            return false;
        }
        uint64_t computed_effect = 1469598103934665603ull;
        for (const uint8_t byte : parsed.effect_bytes) {
            computed_effect ^= static_cast<uint64_t>(byte);
            computed_effect *= 1099511628211ull;
        }
        if (computed_effect != effect_checksum) {
            error = "runtime_bundle_effect_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.effect_bytes.size() < 4u ||
            std::memcmp(parsed.effect_bytes.data(), "EFP1", 4u) != 0) {
            error = "runtime_bundle_effect_section_marker_invalid";
            return false;
        }
        if (!_effect_pod_configured) {
            error = "runtime_bundle_effect_catalog_missing";
            return false;
        }
        RuntimeEffectPodAuthority candidate;
        std::string effect_restore_error;
        if (!candidate.configure(_effect_pod_catalog, effect_restore_error) ||
            !candidate.restore(parsed.effect_bytes.data(),
                               parsed.effect_bytes.size(), effect_restore_error)) {
            error = effect_restore_error.empty()
                ? "runtime_bundle_effect_restore_invalid" : effect_restore_error;
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_IDEOLOGY) != 0) {
        constexpr uint32_t IDEOLOGY_SECTION_MARKER = 0x32504449u; // IDP2
        uint32_t ideology_marker = 0;
        uint32_t ideology_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, ideology_marker) ||
            !read_u32(cursor + 4u, ideology_size) ||
            ideology_marker != IDEOLOGY_SECTION_MARKER ||
            ideology_size > 64u * 1024u * 1024u ||
            ideology_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_ideology_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.ideology_bytes.assign(bytes + cursor, bytes + cursor + ideology_size);
        cursor += ideology_size;
        uint64_t ideology_checksum = 0;
        if (!read_u64(cursor, ideology_checksum)) {
            error = "runtime_bundle_ideology_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.ideology_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != ideology_checksum) {
            error = "runtime_bundle_ideology_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.ideology_bytes.size() < 4u ||
            std::memcmp(parsed.ideology_bytes.data(), "IDP2", 4u) != 0) {
            error = "runtime_bundle_ideology_section_marker_invalid";
            return false;
        }
        // The ideology POD catalog is derived from the Country POD snapshot,
        // so it can only be configured after PKCN restores — and PKSR restores
        // before PKCN. When the catalog is not configured yet, the checksum and
        // marker above still reject corrupt bytes; the catalog-dependent dry
        // run is deferred to worker start, which restores IDP2 against the
        // then-configured catalog and faults before any day runs if it fails.
        if (_ideology_pod_configured) {
            RuntimeIdeologyPodAuthority candidate;
            std::string ideology_restore_error;
            if (!candidate.configure(_ideology_pod_catalog,
                                     ideology_restore_error) ||
                !candidate.restore(parsed.ideology_bytes.data(),
                                   parsed.ideology_bytes.size(),
                                   ideology_restore_error)) {
                error = ideology_restore_error.empty()
                    ? "runtime_bundle_ideology_restore_invalid"
                    : ideology_restore_error;
                return false;
            }
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_POD) != 0) {
        constexpr uint32_t ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1
        uint32_t economy_marker = 0;
        uint32_t economy_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, economy_marker) ||
            !read_u32(cursor + 4u, economy_size) ||
            economy_marker != ECONOMY_POD_SECTION_MARKER ||
            economy_size > 64u * 1024u * 1024u ||
            economy_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_economy_pod_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_pod_bytes.assign(bytes + cursor,
                                        bytes + cursor + economy_size);
        cursor += economy_size;
        uint64_t economy_checksum = 0;
        if (!read_u64(cursor, economy_checksum)) {
            error = "runtime_bundle_economy_pod_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.economy_pod_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != economy_checksum) {
            error = "runtime_bundle_economy_pod_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_pod_bytes.size() < 4u ||
            std::memcmp(parsed.economy_pod_bytes.data(), "ECP1", 4u) != 0) {
            error = "runtime_bundle_economy_pod_section_marker_invalid";
            return false;
        }
        RuntimeEconomyPodAuthority candidate;
        std::string economy_restore_error;
        if (!candidate.restore_ecp1(parsed.economy_pod_bytes.data(),
                                    parsed.economy_pod_bytes.size(),
                                    economy_restore_error)) {
            error = economy_restore_error.empty()
                ? "runtime_bundle_economy_pod_restore_invalid"
                : economy_restore_error;
            return false;
        }
    }
    // The economy checkpoint may travel embedded in the bundle (writers before
    // the ECP2 de-duplication) or as the PKSV `ecp2` section only (current
    // writers). Both end up in parsed.economy_ecp2_bytes; the external form is
    // already covered by the container section hash.
    RuntimeEconomyEcp2State candidate_ecp2;
    std::string economy_ecp2_restore_error;
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_ECP2) != 0) {
        constexpr uint32_t ECONOMY_ECP2_SECTION_MARKER = 0x32504345u; // ECP2
        uint32_t economy_marker = 0;
        uint32_t economy_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, economy_marker) ||
            !read_u32(cursor + 4u, economy_size) ||
            economy_marker != ECONOMY_ECP2_SECTION_MARKER ||
            economy_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_economy_ecp2_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_ecp2_bytes.assign(bytes + cursor,
                                         bytes + cursor + economy_size);
        cursor += economy_size;
        uint64_t economy_checksum = 0;
        if (!read_u64(cursor, economy_checksum)) {
            error = "runtime_bundle_economy_ecp2_section_checksum_missing";
            return false;
        }
        const uint64_t computed = economy_save_hash_bytes(
            parsed.economy_ecp2_bytes.data(), parsed.economy_ecp2_bytes.size());
        if (computed != economy_checksum) {
            error = "runtime_bundle_economy_ecp2_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_ecp2_bytes.size() < 4u ||
            std::memcmp(parsed.economy_ecp2_bytes.data(), "ECP2", 4u) != 0) {
            error = "runtime_bundle_economy_ecp2_section_marker_invalid";
            return false;
        }
        if (!decode_ecp2(parsed.economy_ecp2_bytes.data(),
                         parsed.economy_ecp2_bytes.size(), candidate_ecp2,
                         economy_ecp2_restore_error)) {
            // Old writers silently capped this section at 64 MiB, but PKSV
            // retained the complete frozen checkpoint as its separate ecp2
            // section. Recover only that exact prefix, after the original
            // bundle/section checksums and the complete ECP2 hash validate.
            constexpr size_t legacy_limit = 64u * 1024u * 1024u;
            if (economy_ecp2_restore_error != "ecp2_content_hash_mismatch" ||
                parsed.economy_ecp2_bytes.size() != legacy_limit ||
                external_ecp2 == nullptr || external_ecp2_size <= legacy_limit ||
                external_ecp2_size > std::numeric_limits<uint32_t>::max() ||
                std::memcmp(parsed.economy_ecp2_bytes.data(), external_ecp2,
                            legacy_limit) != 0) {
                error = economy_ecp2_restore_error.empty()
                    ? "runtime_bundle_economy_ecp2_restore_invalid"
                    : economy_ecp2_restore_error;
                return false;
            }
            if (!decode_ecp2(external_ecp2, external_ecp2_size, candidate_ecp2,
                             economy_ecp2_restore_error)) {
                error = economy_ecp2_restore_error;
                return false;
            }
            parsed.economy_ecp2_bytes.assign(external_ecp2, external_ecp2 + external_ecp2_size);
            if (recovered_truncated_ecp2) *recovered_truncated_ecp2 = true;
        }
    } else if (external_ecp2 != nullptr && external_ecp2_size > 0) {
        if (external_ecp2_size < 4u ||
            std::memcmp(external_ecp2, "ECP2", 4u) != 0) {
            error = "runtime_bundle_economy_ecp2_section_marker_invalid";
            return false;
        }
        if (!decode_ecp2(external_ecp2, external_ecp2_size, candidate_ecp2,
                         economy_ecp2_restore_error)) {
            error = economy_ecp2_restore_error.empty()
                ? "runtime_bundle_economy_ecp2_restore_invalid"
                : economy_ecp2_restore_error;
            return false;
        }
        parsed.economy_ecp2_bytes.assign(external_ecp2,
                                         external_ecp2 + external_ecp2_size);
    }
    if (!parsed.economy_ecp2_bytes.empty() &&
        !ecp2_has_required_domains(candidate_ecp2.authority_domain_mask,
                                   ECP2_DOMAIN_CORE_AUTHORITY)) {
        error = "runtime_bundle_economy_ecp2_core_domains_missing";
        return false;
    }
