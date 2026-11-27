    // ABI8 remains writable when resource/cursor blocks are absent.
    {
        RuntimeEconomyLedgerState abi8_ledger = fixture_ledger;
        abi8_ledger.resource.clear();
        abi8_ledger.epoch_cursor.clear();
        abi8_ledger.recompute_hash();
        RuntimeEconomyPodAuthority abi8_authority;
        if (!abi8_authority.plan_epoch(input, error)) return false;
        for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
            abi8_authority.set_stage_reference(
                static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
            if (!abi8_authority.advance_stage(error)) return false;
        }
        if (!abi8_authority.commit_epoch(error)) return false;
        abi8_authority.set_authority_mode(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY);
        abi8_authority.set_business_summary(0, 0, 0, 123, 456, 4, 5, 6, 7);
        if (!abi8_authority.import_committed_ledger(abi8_ledger, error) ||
            !abi8_authority.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(abi8_ledger))) {
            return false;
        }
        std::vector<uint8_t> abi8_encoded;
        if (!abi8_authority.encode_ecp1(abi8_encoded, error)) return false;
        RuntimeEconomyPodAuthority abi8_restored;
        if (!abi8_restored.restore_ecp1(abi8_encoded.data(), abi8_encoded.size(),
                                        error)) {
            return false;
        }
        if (abi8_authority.committed_ledger_abi() != 8u ||
            abi8_restored.committed_ledger_abi() != 8u ||
            abi8_restored.state().resource.captured ||
            abi8_restored.state().epoch_cursor.captured ||
            abi8_restored.pod_active_ready() ||
            (abi8_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE232) !=
                ECONOMY_POD_MIRROR_PHASE232) {
            error = "economy_pod_ecp8_backward_compat_failed";
            return false;
        }
    }

    // ABI7 remains writable when family block is absent.
    {
        RuntimeEconomyLedgerState abi7_ledger = fixture_ledger;
        abi7_ledger.family.clear();
        abi7_ledger.resource.clear();
        abi7_ledger.epoch_cursor.clear();
        abi7_ledger.recompute_hash();
        RuntimeEconomyPodAuthority abi7_authority;
        if (!abi7_authority.plan_epoch(input, error)) return false;
        for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
            abi7_authority.set_stage_reference(
                static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
            if (!abi7_authority.advance_stage(error)) return false;
        }
        if (!abi7_authority.commit_epoch(error)) return false;
        abi7_authority.set_authority_mode(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY);
        abi7_authority.set_business_summary(0, 0, 0, 123, 456, 4, 5, 6, 7);
        if (!abi7_authority.import_committed_ledger(abi7_ledger, error) ||
            !abi7_authority.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(abi7_ledger))) {
            return false;
        }
        std::vector<uint8_t> abi7_encoded;
        if (!abi7_authority.encode_ecp1(abi7_encoded, error)) return false;
        RuntimeEconomyPodAuthority abi7_restored;
        if (!abi7_restored.restore_ecp1(abi7_encoded.data(), abi7_encoded.size(),
                                        error)) {
            return false;
        }
        if (abi7_authority.committed_ledger_abi() != 7u ||
            abi7_restored.committed_ledger_abi() != 7u ||
            abi7_restored.state().family.captured ||
            (abi7_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE23) !=
                ECONOMY_POD_MIRROR_PHASE23 ||
            (abi7_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_FAMILY) !=
                0u) {
            error = "economy_pod_ecp7_backward_compat_failed";
            return false;
        }
    }

    // ABI6 remains writable when building/trade blocks are absent.
    {
        RuntimeEconomyLedgerState abi6_ledger = fixture_ledger;
        abi6_ledger.building.clear();
        abi6_ledger.trade_escrow.clear();
        abi6_ledger.family.clear();
        abi6_ledger.resource.clear();
        abi6_ledger.epoch_cursor.clear();
        abi6_ledger.recompute_hash();
        RuntimeEconomyPodAuthority abi6_authority;
        if (!abi6_authority.plan_epoch(input, error)) return false;
        for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
            abi6_authority.set_stage_reference(
                static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
            if (!abi6_authority.advance_stage(error)) return false;
        }
        if (!abi6_authority.commit_epoch(error)) return false;
        abi6_authority.set_authority_mode(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY);
        abi6_authority.set_business_summary(0, 0, 0, 123, 456, 4, 5, 6, 7);
        if (!abi6_authority.import_committed_ledger(abi6_ledger, error) ||
            !abi6_authority.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(abi6_ledger))) {
            return false;
        }
        std::vector<uint8_t> abi6_encoded;
        if (!abi6_authority.encode_ecp1(abi6_encoded, error)) return false;
        RuntimeEconomyPodAuthority abi6_restored;
        if (!abi6_restored.restore_ecp1(abi6_encoded.data(), abi6_encoded.size(),
                                        error)) {
            return false;
        }
        if (abi6_authority.committed_ledger_abi() != 6u ||
            abi6_restored.committed_ledger_abi() != 6u ||
            abi6_restored.state().building.captured ||
            abi6_restored.state().trade_escrow.captured ||
            (abi6_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE22) !=
                ECONOMY_POD_MIRROR_PHASE22 ||
            (abi6_restored.mirror_feature_mask() &
             (ECONOMY_POD_MIRROR_BUILDING | ECONOMY_POD_MIRROR_TRADE_ESCROW)) !=
                0u) {
            error = "economy_pod_ecp6_backward_compat_failed";
            return false;
        }
    }

    // Historical headers end at byte 64. ABI2 adds 56 summary bytes;
    // ABI3 inserts a four-byte authority mode before those summaries. ABI4
    // appends the committed ledger after the summary block at byte 124.
    // ABI5/ABI6/ABI7/ABI8/ABI9 append extended/.../resource-cursor.
    auto write_u32_at = [](std::vector<uint8_t> &bytes, size_t offset,
                           uint32_t value) {
        for (size_t i = 0; i < 4; ++i)
            bytes[offset + i] = static_cast<uint8_t>(value >> (8 * i));
    };
    auto write_u64_at = [](std::vector<uint8_t> &bytes, size_t offset,
                           uint64_t value) {
        for (size_t i = 0; i < 8; ++i)
            bytes[offset + i] = static_cast<uint8_t>(value >> (8 * i));
    };
    auto reseal = [](std::vector<uint8_t> &bytes) {
        const uint32_t payload = static_cast<uint32_t>(bytes.size() - 12);
        for (size_t i = 0; i < 4; ++i)
            bytes[8 + i] = static_cast<uint8_t>(payload >> (8 * i));
        append_u64(bytes, fnv1a(bytes.data(), bytes.size()));
    };
    constexpr size_t abi4_ledger_offset = 124;
    constexpr size_t receipt_wire_size = 24;
    const size_t receipt_bytes =
        authority._terminal_receipts.size() * receipt_wire_size;
    std::vector<uint8_t> abi3_bytes(encoded.begin(), encoded.end() - 8);
    if (abi3_bytes.size() < abi4_ledger_offset + receipt_bytes) {
        error = "economy_pod_ecp4_fixture_layout_invalid";
        return false;
    }
    const size_t receipt_offset = abi3_bytes.size() - receipt_bytes;
    abi3_bytes.erase(abi3_bytes.begin() + abi4_ledger_offset,
                     abi3_bytes.begin() + receipt_offset);
    for (uint32_t old_abi = 1; old_abi <= 3; ++old_abi) {
        std::vector<uint8_t> old_bytes = abi3_bytes;
        if (old_abi < 3)
            old_bytes.erase(old_bytes.begin() + 64, old_bytes.begin() + 68);
        if (old_abi < 2)
            old_bytes.erase(old_bytes.begin() + 64, old_bytes.begin() + 120);
        write_u32_at(old_bytes, 4, old_abi);
        reseal(old_bytes);
        RuntimeEconomyPodAuthority old_restored;
        if (!old_restored.import_committed_ledger(fixture_ledger, error) ||
            !old_restored.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(fixture_ledger))) {
            return false;
        }
        if (!old_restored.restore_ecp1(old_bytes.data(), old_bytes.size(), error))
            return false;
        const RuntimeEconomyAuthorityMode expected_mode = old_abi >= 3
            ? RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY
            : RuntimeEconomyAuthorityMode::LEGACY_SYNC;
        if (old_restored.authority_mode() != expected_mode ||
            old_restored._summary_population != (old_abi >= 2 ? 123 : 0) ||
            old_restored._terminal_receipts.size() !=
                authority._terminal_receipts.size() ||
            old_restored.state_initialized() ||
            old_restored._committed_ledger_state.valid()) {
            error = "economy_pod_legacy_restore_mismatch";
            return false;
        }
    }

    const auto receipts_equal = [](const std::vector<RuntimeEconomyPodReceipt> &left,
                                   const std::vector<RuntimeEconomyPodReceipt> &right) {
        if (left.size() != right.size()) return false;
        for (size_t i = 0; i < left.size(); ++i) {
            if (left[i].request_id != right[i].request_id ||
                left[i].transaction_id != right[i].transaction_id ||
                left[i].opcode != right[i].opcode ||
                left[i].code != right[i].code) {
                return false;
            }
        }
        return true;
    };
    const uint64_t state_hash_before_reject = restored.state_hash();
    const RuntimeEconomyCommittedSnapshot committed_before_reject =
        restored._committed;
    const RuntimeEconomyAuthorityMode mode_before_reject =
        restored._authority_mode;
    const std::vector<RuntimeEconomyPodReceipt> receipts_before_reject =
        restored._terminal_receipts;
    const int64_t summary_population_before_reject =
        restored._summary_population;
    RuntimeEconomyLedgerState ledger_before_reject;
    if (!restored.export_committed_ledger(ledger_before_reject, error))
        return false;

    std::vector<uint8_t> malformed(encoded.begin(), encoded.end() - 8);
    constexpr size_t abi4_ledger_metadata_size = 32;
    const size_t cohort_cells_offset = abi4_ledger_offset +
        abi4_ledger_metadata_size + 12 +
        fixture_ledger.cohort_active.size();
    if (cohort_cells_offset + 8 > malformed.size()) {
        error = "economy_pod_malformed_fixture_layout_invalid";
        return false;
    }
    RuntimeEconomyLedgerState malformed_ledger = fixture_ledger;
    malformed_ledger.cohort_cell[1] = 1;
    malformed_ledger.recompute_hash();
    write_u64_at(malformed, abi4_ledger_offset + 8,
                 malformed_ledger.ledger_hash);
    write_u32_at(malformed, cohort_cells_offset + 4, 1);
    reseal(malformed);
    std::string rejected_error;
    RuntimeEconomyLedgerState ledger_after_reject;
    if (restored.restore_ecp1(malformed.data(), malformed.size(), rejected_error) ||
        rejected_error != "economy_pod_population_page_cell_mismatch" ||
        restored.state_hash() != state_hash_before_reject ||
        restored._committed.generation != committed_before_reject.generation ||
        restored._committed.state_hash != committed_before_reject.state_hash ||
        restored._authority_mode != mode_before_reject ||
        restored._summary_population != summary_population_before_reject ||
        !receipts_equal(restored._terminal_receipts, receipts_before_reject) ||
        !restored.export_committed_ledger(ledger_after_reject, error) ||
        !ledgers_equal(ledger_after_reject, ledger_before_reject)) {
        error = "economy_pod_failed_restore_mutated_state";
        return false;
    }

    RuntimeEconomyLedgerState bad_hash = fixture_ledger;
    bad_hash.ledger_hash ^= 1u;
    if (restored.import_committed_ledger(bad_hash, rejected_error) ||
        rejected_error != "economy_pod_ledger_hash_invalid" ||
        restored.state_hash() != state_hash_before_reject) {
        error = "economy_pod_failed_import_mutated_state";
        return false;
    }
    const uint64_t mirror_hash_before = effective_hash(restored._committed_ledger_state);
    if (restored.import_and_publish_committed_ledger(std::move(bad_hash), rejected_error) ||
        rejected_error != "economy_pod_ledger_hash_invalid" ||
        restored.state_hash() != state_hash_before_reject ||
        effective_hash(restored._committed_ledger_state) != mirror_hash_before) {
        error = "economy_pod_failed_combined_import_mutated_state";
        return false;
    }
    RuntimeEconomyLedgerState combined_fixture = fixture_ledger;
    if (!restored.import_and_publish_committed_ledger(std::move(combined_fixture), error) ||
        !ledgers_equal(restored._committed_ledger_state, fixture_ledger)) {
        error = "economy_pod_combined_import_mirror_mismatch";
        return false;
    }
