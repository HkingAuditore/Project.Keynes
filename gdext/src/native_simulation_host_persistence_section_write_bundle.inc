void NativeSimulationHost::build_save_bundle(
        uint64_t request_id,
        const std::vector<RuntimeCommandPacket> &pending_commands) {
    EconomyCostProbe save_probe("save.bundle", _committed_day.load(std::memory_order_acquire));
    if (try_fault_injection("save.barrier.before")) {
        return;
    }
    // The wire format accepts one protocol-capacity command tail. A live
    // backlog may also contain commands drained from earlier ingress batches;
    // reject the save without changing that backlog instead of truncating it.
    if (pending_commands.size() > RUNTIME_COMMAND_QUEUE_CAPACITY) {
        record_save_failure("save_pending_command_capacity_exceeded");
        return;
    }
    // Check this before cross-domain checkpoint identities: bootstrap Country
    // legitimately has no committed day either. Report the actionable cause.
    if (_economy_ecp2_dual_write.load(std::memory_order_acquire) &&
        _economy_production_runtime != nullptr &&
        _economy_production_runtime->last_committed_day() < 0) {
        record_save_failure("save_requires_first_settlement");
        return;
    }
    auto bundle = std::make_shared<RuntimeSaveBundle>();
    bundle->request_id = request_id;
    bundle->bundle_version = RUNTIME_SAVE_BUNDLE_VERSION;
    bundle->runtime_domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    bundle->section_mask = RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE |
        RUNTIME_SAVE_SECTION_DOMAIN_POD;
    bundle->committed_day = _committed_day.load(std::memory_order_acquire);
    bundle->paused = _paused.load(std::memory_order_acquire);
    bundle->speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    bundle->generation = _generation.load(std::memory_order_acquire);
    bundle->state_hash = _state_hash.load(std::memory_order_acquire);
    bundle->environment_generation = _environment_generation.load(
        std::memory_order_acquire);
    bundle->environment_day = _environment_day.load(std::memory_order_acquire);
    bundle->time_debt_days = _time_debt_days.load(std::memory_order_acquire);
    bundle->pending_commands = pending_commands;
    for (const auto &day : _country_observations)
        for (const auto &observation : day.second) {
            auto packet = encode_country_packet(observation);
            packet.envelope.producer_id = COUNTRY_OBSERVATION_ARCHIVE_PRODUCER;
            bundle->pending_commands.push_back(std::move(packet));
        }
    if (!_country_observations.empty()) {
        // The archive has no live submit-order lane. Save the two inboxes
        // in their original order so restore can rebuild the tie-break.
        std::stable_sort(bundle->pending_commands.begin(), bundle->pending_commands.end(),
            [](const auto &a, const auto &b) { return a.submit_order < b.submit_order; });
    }
    for (size_t i = 0; i < _producer_sequences.size(); ++i) {
        bundle->producer_sequences[i] = _producer_sequences[i].load(
            std::memory_order_acquire);
    }
    bundle->economy_fact_event_sequence = _economy_fact_event_sequence;
    bundle->trigger_forwarded_event_id = _trigger_forwarded_event_id;
    bundle->trigger_forward_sequence = _trigger_forward_sequence;
    bundle->economy_command_bytes = _economy_pod_authority.encode_command_continuation(); bundle->trigger_transport_bytes = encode_trigger_transport();
    bundle->fallback_producer_sequence = _fallback_producer_sequence.load(
        std::memory_order_acquire);
    if (const auto environment = environment_snapshot()) {
        bundle->climate_anomaly = environment->climate_anomaly;
    }
    _pod_pipeline.serialize(bundle->domain_pod_bytes);
    const bool include_climate = _climate_authority.store().cell_count != 0;
    if (include_climate) {
        EconomyCostProbe climate_probe("save.climate", bundle->committed_day);
        std::string climate_save_error;
        if (!_climate_authority.serialize(bundle->climate_bytes, climate_save_error)) {
            set_fault(climate_save_error.empty() ? "climate_save_encode_failed" :
                      climate_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_CLIMATE;
    }
    const auto country_checkpoint = std::atomic_load_explicit(
        &_country_checkpoint, std::memory_order_acquire);
    // Under worker Country authority the checkpoint must describe the same
    // committed day as this bundle. A mismatch restores a Country POD that can
    // never plan the next host day (country_day_not_contiguous forever), so
    // reject the save explicitly instead of writing an inconsistent bundle.
    if (country_checkpoint != nullptr &&
        domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
        country_checkpoint->committed_day != bundle->committed_day) {
        const std::string reason = "save_country_checkpoint_day_mismatch:c=" +
            std::to_string(country_checkpoint->committed_day) + ",b=" +
            std::to_string(bundle->committed_day);
        record_save_failure(reason.c_str());
        return;
    }
    if (country_checkpoint != nullptr) {
        // The synchronous checkpoint carries the canonical PKCN business
        // payload. Host protocol state is merged here at the same save
        // boundary, so pending worker packets and terminal receipts cannot
        // drift from the PKCN generation/day/hash they accompany.
        CountryCoreCheckpoint checkpoint = *country_checkpoint;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            std::map<uint64_t, CountryCommandReceipt> states;
            for (const CountryCommandReceipt &receipt : checkpoint.request_states)
                states.emplace(receipt.request_id, receipt);
            std::map<uint64_t, CountryCommandReceipt> terminals;
            for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts)
                terminals.emplace(receipt.request_id, receipt);

            for (const auto &entry : _country_command_states) {
                const CountryCommandReceipt &receipt = entry.second;
                const auto existing = states.find(receipt.request_id);
                if (existing == states.end()) {
                    states.emplace(receipt.request_id, receipt);
                } else if (existing->second.code != receipt.code ||
                           existing->second.effective_day != receipt.effective_day) {
                    const auto &previous = existing->second;
                    if (previous.code == CountryCommandReceiptCode::ACCEPTED &&
                        _country_command_terminals.find(receipt.request_id) !=
                            _country_command_terminals.end() &&
                        previous.producer_id == receipt.producer_id &&
                        previous.sequence == receipt.sequence &&
                        previous.effective_day == receipt.effective_day) {
                        // A restored read replica can retain the admission
                        // receipt after the Host completes the same command.
                        existing->second = receipt;
                        continue;
                    }
                    set_fault("country_save_request_state_conflict");
                    return;
                }
            }
            for (const RuntimeCommandPacket &packet : bundle->pending_commands) {
                if (packet.envelope.domain !=
                        static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
                    packet.envelope.request_id == 0) {
                    continue;
                }
                const auto existing = states.find(packet.envelope.request_id);
                if (existing == states.end()) {
                    CountryCommandReceipt accepted;
                    accepted.request_id = packet.envelope.request_id;
                    accepted.producer_id = is_country_day_observation(packet.envelope)
                        ? 0 : packet.envelope.producer_id;
                    accepted.sequence = packet.envelope.sequence;
                    accepted.effective_day = packet.envelope.effective_day;
                    accepted.generation = checkpoint.generation;
                    accepted.code = CountryCommandReceiptCode::ACCEPTED;
                    states.emplace(accepted.request_id, std::move(accepted));
                } else if (existing->second.code != CountryCommandReceiptCode::ACCEPTED) {
                    set_fault("country_save_pending_receipt_not_accepted");
                    return;
                }
            }
            for (const auto &entry : _country_command_terminals) {
                const CountryCommandReceipt &receipt = entry.second;
                const auto existing = states.find(receipt.request_id);
                if (existing == states.end() || existing->second.code != receipt.code) {
                    set_fault("country_save_terminal_receipt_state_mismatch");
                    return;
                }
                terminals.emplace(receipt.request_id, receipt);
            }
            checkpoint.request_states.clear();
            checkpoint.request_states.reserve(states.size());
            for (const auto &entry : states)
                checkpoint.request_states.push_back(entry.second);
            checkpoint.terminal_receipts.clear();
            checkpoint.terminal_receipts.reserve(terminals.size());
            for (const auto &entry : terminals)
                checkpoint.terminal_receipts.push_back(entry.second);
        }
        std::string country_save_error;
        if (!encode_country_core_checkpoint(checkpoint,
                                            bundle->country_bytes,
                                            country_save_error)) {
            set_fault(country_save_error.empty() ? "country_save_encode_failed" :
                      country_save_error.c_str());
            return;
        }
        bundle->country_pkcn_bytes = checkpoint.canonical_pkcn;
        bundle->section_mask |= RUNTIME_SAVE_SECTION_COUNTRY;
    }
    std::string d7_save_error;
    if (!serialize_country_economy_asset_journal(
            bundle->economy_asset_bytes, d7_save_error)) {
        set_fault(d7_save_error.empty() ? "d7_transaction_journal_encode_failed" :
                  d7_save_error.c_str());
        return;
    }
    if (!bundle->economy_asset_bytes.empty())
        bundle->section_mask |= RUNTIME_SAVE_SECTION_ECONOMY_ASSET;
    RuntimeTriggerPodSaveSection trigger_save;
    std::string trigger_save_error;
    if (_domain_authority_runner.encode_trigger_save(trigger_save,
                                                     trigger_save_error)) {
        bundle->trigger_bytes = std::move(trigger_save.payload);
        bundle->section_mask |= RUNTIME_SAVE_SECTION_TRIGGER;
    }
    if (_modifier_pod_configured) {
        std::vector<RuntimeModifierPodCommand> modifier_pending;
        modifier_pending.reserve(pending_commands.size());
        for (const RuntimeCommandPacket &packet : pending_commands) {
            RuntimeModifierPodCommand command;
            if (decode_modifier_packet(packet, command))
                modifier_pending.push_back(command);
        }
        _modifier_pod_authority.set_pending_command_identities(modifier_pending);
        _modifier_pod_authority.serialize(bundle->modifier_bytes);
        if (bundle->modifier_bytes.empty()) {
            set_fault("modifier_save_encode_failed");
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_MODIFIER;
    }
    {
        std::string events_save_error;
        if (!_events_authority.serialize(bundle->events_bytes, events_save_error)) {
            set_fault(events_save_error.empty() ? "events_save_encode_failed" :
                      events_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_EVENTS;
    }
    {
        constexpr uint32_t GMP1_MARKER = 0x31504d47u; // GMP1
        constexpr uint32_t GMP1_ABI = 1u;
        uint32_t pending_gameplay = 0;
        for (const RuntimeCommandPacket &packet : pending_commands) {
            if (packet.envelope.domain == static_cast<uint16_t>(
                    RuntimeDomainId::GAMEPLAY_EFFECT))
                ++pending_gameplay;
        }
        std::vector<uint8_t> &gmp = bundle->gameplay_effect_bytes;
        gmp.clear();
        d7_append_u32(gmp, GMP1_MARKER);
        d7_append_u32(gmp, GMP1_ABI);
        d7_append_u64(gmp, _gameplay_effect_generation.load(
            std::memory_order_acquire));
        d7_append_u32(gmp, pending_gameplay);
        d7_append_u32(gmp, _gameplay_effect_terminal.load(
            std::memory_order_acquire));
        d7_append_u64(gmp, _gameplay_effect_state_hash.load(
            std::memory_order_acquire));
        bundle->section_mask |= RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT;
    }
    if (_effect_pod_configured) {
        std::string effect_save_error;
        if (!encode_effect_pod_save(bundle->effect_bytes, effect_save_error)) {
            set_fault(effect_save_error.empty() ? "effect_save_encode_failed" :
                      effect_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_EFFECT;
        bundle->effect_transport_bytes = encode_effect_transport();
        bundle->section_mask |= RUNTIME_SAVE_SECTION_EFFECT_TRANSPORT;
    }
    if (_ideology_pod_configured) {
        std::string ideology_save_error;
        if (!encode_ideology_pod_save(bundle->ideology_bytes,
                                      ideology_save_error)) {
            set_fault(ideology_save_error.empty()
                ? "ideology_save_encode_failed"
                : ideology_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_IDEOLOGY;
    }
    // ECP1 is no longer written. Restore has been ECP2-only since the cutover
    // (see NativeSimulationHost::apply_pending_restore: "ECP1 is never an
    // authority restore path"), so every save carried a full second economy
    // encoding that nothing read: 24.7 MiB raw / 0.30 MiB compressed on a
    // 100x64 day-628 save, plus a full encode on the save critical path.
    // RuntimeSaveBundle::economy_pod_bytes stays so ABI-9-era bundles still
    // parse; only new writes stop producing it.
    if (_economy_ecp2_dual_write.load(std::memory_order_acquire) &&
        _economy_production_runtime != nullptr) {
        EconomyCostProbe economy_probe("save.ecp2", bundle->committed_day);
        uint32_t capture_flags = 0;
        if (_economy_ecp2_mid_epoch_save.load(std::memory_order_acquire))
            capture_flags |= ECP2_CAPTURE_ALLOW_MID_EPOCH |
                             ECP2_CAPTURE_INCLUDE_RESUME;
        RuntimeEconomyEcp2State ecp2_state;
        std::string ecp2_capture_error;
        // ECP2 records the Country identity it is bound to, and restore
        // requires it to match the Country restored from this same bundle.
        // Under worker Country authority that is the committed checkpoint
        // above, not the main-thread runtime the economy points at (which
        // stays at its bootstrap state and would never match on load).
        const bool stamp_worker_country =
            country_checkpoint != nullptr &&
            domain_is_worker_authoritative(RuntimeDomainId::COUNTRY);
        EconomyAuthorityTransfer::CountryIdentity country_identity;
        if (stamp_worker_country) {
            country_identity = {country_checkpoint->generation,
                                country_checkpoint->business_state_hash};
        }
        if (!EconomyAuthorityTransfer::capture(*_economy_production_runtime,
                ecp2_state, ecp2_capture_error, capture_flags,
                stamp_worker_country ? &country_identity : nullptr)) {
            // A rejected capture must not publish a bundle missing its Economy section.
            record_save_failure(ecp2_capture_error.empty() ? "economy_ecp2_capture_failed" :
                ecp2_capture_error.c_str());
            return;
        }
        std::string ecp2_encode_error;
        if (!encode_ecp2(ecp2_state, bundle->economy_ecp2_bytes, ecp2_encode_error) ||
                bundle->economy_ecp2_bytes.empty()) {
            set_fault(ecp2_encode_error.empty() ? "economy_ecp2_encode_failed" :
                ecp2_encode_error.c_str());
            return;
        }
        // The checkpoint is captured once and exported to the PKSV `ecp2`
        // section (poll_runtime_save hands these bytes to the economy provider),
        // but it is no longer embedded in the PKSR wire bytes: the container
        // already stores the identical block, and restore prefers the external
        // section. Keeping both cost 52.98 MiB raw / 1.12 MiB compressed per
        // save for the same bytes. RUNTIME_SAVE_SECTION_ECONOMY_ECP2 therefore
        // stays clear; the parser still accepts bundles that carry it.
    }

    if (_world_environment && _executor_military) {
        bundle->military_terrain_bytes = _executor_military->capture_terrain();
        if (!bundle->military_terrain_bytes.empty())
            bundle->section_mask |= RUNTIME_SAVE_SECTION_MILITARY_TERRAIN;
    }
    if (_world_environment) {
        bundle->season_history_bytes = _world_environment->capture_season_history(bundle->committed_day);
        if (!bundle->season_history_bytes.empty())
            bundle->section_mask |= RUNTIME_SAVE_SECTION_SEASON_HISTORY;
        bundle->player_confirmation_bytes = encode_player_confirmation(bundle->committed_day);
        if (!bundle->player_confirmation_bytes.empty())
            bundle->section_mask |= RUNTIME_SAVE_SECTION_PLAYER_CONFIRMATION;
    }

    capture_world_continuation(*bundle);

    // PKSR v2 is an endian-stable runtime envelope. The fixed scalar header
    // carries an explicit ABI/section mask, followed by a bounded pending
    // command tail and producer cursors. The checksum remains the final eight
    // bytes and the complete tail is mandatory for v2 restores.
    const auto wire_started = std::chrono::steady_clock::now();
    size_t wire_reserve = 4 + 4 + 8 * 10 + 1 + 4 + 4 +
        bundle->pending_commands.size() * (8 + 4 + 8 + 8 + 8 + 8 + 2 + 2 + 4 +
                                           RUNTIME_MAX_COMMAND_PAYLOAD) +
        bundle->producer_sequences.size() * 8 + 8 + 24 + 8;
    // 所有 section 已冻结；一次预留，避免拼接大 section 时反复搬移前缀。
    for (const auto *section : {&bundle->domain_pod_bytes, &bundle->climate_bytes,
            &bundle->country_bytes, &bundle->economy_asset_bytes,
            &bundle->trigger_bytes, &bundle->modifier_bytes, &bundle->events_bytes,
            &bundle->gameplay_effect_bytes, &bundle->effect_bytes,
            &bundle->ideology_bytes, &bundle->economy_pod_bytes,
            &bundle->economy_ecp2_bytes, &bundle->effect_transport_bytes,
            &bundle->military_terrain_bytes, &bundle->season_history_bytes, &bundle->player_confirmation_bytes,
            &bundle->vision_bytes, &bundle->bio_bytes, &bundle->climate_calendar_bytes}) {
        const size_t limit = section == &bundle->economy_ecp2_bytes
            ? std::numeric_limits<uint32_t>::max() : 64u * 1024u * 1024u;
        if (section->size() > limit) {
            record_save_failure("save_runtime_section_too_large");
            return;
        }
        wire_reserve += 16u + section->size();
    }
    bundle->bytes.reserve(wire_reserve);
    const auto append_bytes = [&bundle](const void *data, size_t size) {
        const size_t offset = bundle->bytes.size();
        bundle->bytes.resize(offset + size);
        std::memcpy(bundle->bytes.data() + offset, data, size);
    };
    const auto append_u32_le = [&append_bytes](uint32_t value) {
        const std::array<uint8_t, 4> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
            static_cast<uint8_t>((value >> 16u) & 0xffu),
            static_cast<uint8_t>((value >> 24u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u16_le = [&append_bytes](uint16_t value) {
        const std::array<uint8_t, 2> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u64_le = [&append_bytes](uint64_t value) {
        std::array<uint8_t, 8> bytes{};
        for (uint32_t i = 0; i < bytes.size(); ++i)
            bytes[i] = static_cast<uint8_t>((value >> (i * 8u)) & 0xffu);
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_i64_le = [&append_u64_le](int64_t value) {
        append_u64_le(static_cast<uint64_t>(value));
    };
    const auto append_f64_le = [&append_u64_le](double value) {
        uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        append_u64_le(bits);
    };
    const char magic[4] = {'P', 'K', 'S', 'R'};
    const uint32_t version = RUNTIME_SAVE_BUNDLE_VERSION;
    const uint8_t paused = bundle->paused ? 1u : 0u;
    append_bytes(magic, sizeof(magic));
    append_u32_le(version);
    append_u64_le(bundle->request_id);
    append_i64_le(bundle->committed_day);
    append_f64_le(bundle->speed_days_per_second);
    append_bytes(&paused, sizeof(paused));
    append_u64_le(bundle->generation);
    append_u64_le(bundle->state_hash);
    append_u64_le(bundle->environment_generation);
    append_i64_le(bundle->environment_day);
    append_f64_le(bundle->climate_anomaly);
    append_f64_le(bundle->time_debt_days);
    append_u32_le(RUNTIME_DOMAIN_ABI_VERSION);
    append_u32_le(bundle->section_mask);

    const uint32_t pending_count = static_cast<uint32_t>(bundle->pending_commands.size());
    append_u32_le(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        const RuntimeCommandPacket &command = bundle->pending_commands[i];
        const RuntimeCommandEnvelope &envelope = command.envelope;
        append_u64_le(envelope.request_id);
        append_u32_le(envelope.producer_id);
        append_u64_le(envelope.sequence);
        append_u64_le(envelope.observed_generation);
        append_i64_le(envelope.requested_day);
        append_i64_le(envelope.effective_day);
        append_u16_le(envelope.domain);
        append_u16_le(envelope.opcode);
        append_u32_le(envelope.payload_size);
        if (envelope.payload_size > 0) {
            append_bytes(command.payload.data(), envelope.payload_size);
        }
    }
    // A marker separates optional command records from producer cursors. This
    // lets a future PKSR decoder reject a truncated tail instead of treating
    // arbitrary bytes as sequence state.
    constexpr uint32_t PRODUCER_CURSOR_MARKER = 0x31514350u; // "PCQ1"
    append_u32_le(PRODUCER_CURSOR_MARKER);
    for (uint64_t sequence : bundle->producer_sequences)
        append_u64_le(sequence);
    append_u64_le(bundle->fallback_producer_sequence);
    append_u64_le(bundle->economy_fact_event_sequence);
    append_i64_le(bundle->trigger_forwarded_event_id);
    append_u64_le(bundle->trigger_forward_sequence);
    append_u32_le(static_cast<uint32_t>(bundle->economy_command_bytes.size()));
    append_bytes(bundle->economy_command_bytes.data(), bundle->economy_command_bytes.size());
    append_u32_le(static_cast<uint32_t>(bundle->trigger_transport_bytes.size()));
    append_bytes(bundle->trigger_transport_bytes.data(), bundle->trigger_transport_bytes.size());
    constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
    append_u32_le(DOMAIN_SECTION_MARKER);
    append_u32_le(static_cast<uint32_t>(bundle->domain_pod_bytes.size()));
    const uint32_t domain_section_size = static_cast<uint32_t>(bundle->domain_pod_bytes.size());
    if (domain_section_size > 0) {
        append_bytes(bundle->domain_pod_bytes.data(), domain_section_size);
    }
    const uint64_t domain_checksum = economy_save_hash_bytes(
        bundle->domain_pod_bytes.data(), domain_section_size);
    append_u64_le(domain_checksum);

    if (include_climate) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // "CLM2"
        append_u32_le(CLIMATE_SECTION_MARKER);
        const uint32_t climate_section_size = static_cast<uint32_t>(bundle->climate_bytes.size());
        append_u32_le(climate_section_size);
        if (climate_section_size > 0)
            append_bytes(bundle->climate_bytes.data(), climate_section_size);
        uint64_t climate_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < climate_section_size; ++i) {
            climate_checksum ^= static_cast<uint64_t>(bundle->climate_bytes[i]);
            climate_checksum *= 1099511628211ull;
        }
        append_u64_le(climate_checksum);
    }

    if (country_checkpoint != nullptr) {
        constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
        append_u32_le(COUNTRY_SECTION_MARKER);
        const uint32_t country_section_size = static_cast<uint32_t>(
            bundle->country_bytes.size());
        append_u32_le(country_section_size);
        if (country_section_size > 0)
            append_bytes(bundle->country_bytes.data(), country_section_size);
        append_u64_le(country_checkpoint_checksum(bundle->country_bytes.data(),
                                                   country_section_size));
    }

    if (!bundle->economy_asset_bytes.empty()) {
        constexpr uint32_t D7_SECTION_MARKER = 0x31543744u; // D7T1
        append_u32_le(D7_SECTION_MARKER);
        const uint32_t d7_section_size = static_cast<uint32_t>(bundle->economy_asset_bytes.size());
        append_u32_le(d7_section_size);
        append_bytes(bundle->economy_asset_bytes.data(), d7_section_size);
        const uint64_t d7_checksum = economy_save_hash_bytes(
            bundle->economy_asset_bytes.data(), d7_section_size);
        append_u64_le(d7_checksum);
    }

    if (!bundle->trigger_bytes.empty()) {
        constexpr uint32_t TRIGGER_SECTION_MARKER = 0x31445054u; // TPD1
        append_u32_le(TRIGGER_SECTION_MARKER);
        const uint32_t trigger_section_size = static_cast<uint32_t>(bundle->trigger_bytes.size());
        append_u32_le(trigger_section_size);
        append_bytes(bundle->trigger_bytes.data(), trigger_section_size);
        uint64_t trigger_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < trigger_section_size; ++i) {
            trigger_checksum ^= static_cast<uint64_t>(bundle->trigger_bytes[i]);
            trigger_checksum *= 1099511628211ull;
        }
        append_u64_le(trigger_checksum);
    }

    if (!bundle->modifier_bytes.empty()) {
        constexpr uint32_t MODIFIER_SECTION_MARKER = 0x3246444Du; // MDF2
        append_u32_le(MODIFIER_SECTION_MARKER);
        const uint32_t modifier_section_size = static_cast<uint32_t>(
            bundle->modifier_bytes.size());
        append_u32_le(modifier_section_size);
        append_bytes(bundle->modifier_bytes.data(), modifier_section_size);
        uint64_t modifier_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < modifier_section_size; ++i) {
            modifier_checksum ^= static_cast<uint64_t>(bundle->modifier_bytes[i]);
            modifier_checksum *= 1099511628211ull;
        }
        append_u64_le(modifier_checksum);
    }

    if (!bundle->events_bytes.empty()) {
        constexpr uint32_t EVENTS_SECTION_MARKER = 0x31545645u; // EVT1
        append_u32_le(EVENTS_SECTION_MARKER);
        const uint32_t events_section_size = static_cast<uint32_t>(
            bundle->events_bytes.size());
        append_u32_le(events_section_size);
        append_bytes(bundle->events_bytes.data(), events_section_size);
        uint64_t events_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < events_section_size; ++i) {
            events_checksum ^= static_cast<uint64_t>(bundle->events_bytes[i]);
            events_checksum *= 1099511628211ull;
        }
        append_u64_le(events_checksum);
    }

    if (!bundle->gameplay_effect_bytes.empty()) {
        constexpr uint32_t GAMEPLAY_EFFECT_SECTION_MARKER = 0x31504d47u; // GMP1
        append_u32_le(GAMEPLAY_EFFECT_SECTION_MARKER);
        const uint32_t gameplay_effect_section_size = static_cast<uint32_t>(
            bundle->gameplay_effect_bytes.size());
        append_u32_le(gameplay_effect_section_size);
        append_bytes(bundle->gameplay_effect_bytes.data(),
                     gameplay_effect_section_size);
        uint64_t gameplay_effect_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < gameplay_effect_section_size; ++i) {
            gameplay_effect_checksum ^= static_cast<uint64_t>(
                bundle->gameplay_effect_bytes[i]);
            gameplay_effect_checksum *= 1099511628211ull;
        }
        append_u64_le(gameplay_effect_checksum);
    }

    if (!bundle->effect_bytes.empty()) {
        constexpr uint32_t EFFECT_SECTION_MARKER = 0x31504645u; // EFP1
        append_u32_le(EFFECT_SECTION_MARKER);
        const uint32_t effect_section_size = static_cast<uint32_t>(
            bundle->effect_bytes.size());
        append_u32_le(effect_section_size);
        append_bytes(bundle->effect_bytes.data(), effect_section_size);
        uint64_t effect_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < effect_section_size; ++i) {
            effect_checksum ^= static_cast<uint64_t>(bundle->effect_bytes[i]);
            effect_checksum *= 1099511628211ull;
        }
        append_u64_le(effect_checksum);
    }

    if (!bundle->ideology_bytes.empty()) {
        constexpr uint32_t IDEOLOGY_SECTION_MARKER = 0x32504449u; // IDP2
        append_u32_le(IDEOLOGY_SECTION_MARKER);
        const uint32_t ideology_section_size = static_cast<uint32_t>(
            bundle->ideology_bytes.size());
        append_u32_le(ideology_section_size);
        append_bytes(bundle->ideology_bytes.data(), ideology_section_size);
        uint64_t ideology_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < ideology_section_size; ++i) {
            ideology_checksum ^= static_cast<uint64_t>(bundle->ideology_bytes[i]);
            ideology_checksum *= 1099511628211ull;
        }
        append_u64_le(ideology_checksum);
    }

    if (!bundle->economy_pod_bytes.empty()) {
        constexpr uint32_t ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1
        append_u32_le(ECONOMY_POD_SECTION_MARKER);
        const uint32_t economy_section_size = static_cast<uint32_t>(
            bundle->economy_pod_bytes.size());
        append_u32_le(economy_section_size);
        append_bytes(bundle->economy_pod_bytes.data(), economy_section_size);
        const uint64_t economy_checksum = economy_save_hash_bytes(
            bundle->economy_pod_bytes.data(), economy_section_size);
        append_u64_le(economy_checksum);
    }

    if ((bundle->section_mask & RUNTIME_SAVE_SECTION_ECONOMY_ECP2) != 0 &&
            !bundle->economy_ecp2_bytes.empty()) {
        constexpr uint32_t ECONOMY_ECP2_SECTION_MARKER = 0x32504345u; // ECP2
        append_u32_le(ECONOMY_ECP2_SECTION_MARKER);
        const uint32_t ecp2_section_size = static_cast<uint32_t>(
            bundle->economy_ecp2_bytes.size());
        append_u32_le(ecp2_section_size);
        append_bytes(bundle->economy_ecp2_bytes.data(), ecp2_section_size);
        const uint64_t ecp2_checksum = economy_save_hash_bytes(
            bundle->economy_ecp2_bytes.data(), ecp2_section_size);
        append_u64_le(ecp2_checksum);
    }

    for (const auto *section : {&bundle->military_terrain_bytes, &bundle->season_history_bytes, &bundle->player_confirmation_bytes,
            &bundle->vision_bytes, &bundle->bio_bytes, &bundle->climate_calendar_bytes}) {
        if (section->empty()) continue;
        append_u32_le(static_cast<uint32_t>(section->size()));
        append_bytes(section->data(), section->size());
    }
    if (!bundle->effect_transport_bytes.empty()) {
        append_bytes(bundle->effect_transport_bytes.data(), bundle->effect_transport_bytes.size());
    }
    const uint64_t checksum = economy_save_hash_bytes(
        bundle->bytes.data(), bundle->bytes.size());
    bundle->checksum = checksum;
    append_u64_le(bundle->checksum);
    EconomyCostProbe::record("save.wire", bundle->committed_day,
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - wire_started).count(), bundle->bytes.size());

    _save_consumed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(std::move(bundle)),
        std::memory_order_release);
    try_fault_injection("save.barrier.after");
}
