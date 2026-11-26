    if (restore_pending && !_pending_restore_bundle.domain_pod_bytes.empty()) {
        std::string pod_restore_error;
        if (!_pod_pipeline.restore(_pending_restore_bundle.domain_pod_bytes.data(),
                                   _pending_restore_bundle.domain_pod_bytes.size(),
                                   pod_restore_error)) {
            set_fault(pod_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        if (_pod_pipeline.restored_legacy_modifier() &&
            _pending_restore_bundle.modifier_bytes.empty()) {
            if (!modifier_candidate_ready) {
                set_fault("modifier_pod_catalog_required_for_pdp3");
                _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
                return false;
            }
            const RuntimeModifierPodState &legacy =
                _pod_pipeline.legacy_modifier_state();
            std::vector<std::pair<uint16_t, RuntimeModifierPodEntry>> entries;
            entries.reserve(legacy.entries.size());
            for (const RuntimeModifierPodEntry &entry : legacy.entries) {
                if (entry.definition_id < 0 ||
                    entry.definition_id >= static_cast<int32_t>(
                        _modifier_pod_catalog.definitions.size())) {
                    set_fault("modifier_pdp3_definition_invalid");
                    _state.store(RuntimeWorkerState::STOPPED,
                                 std::memory_order_release);
                    return false;
                }
                const uint16_t domain = static_cast<uint16_t>(
                    _modifier_pod_catalog.definitions[
                        static_cast<size_t>(entry.definition_id)].domain);
                entries.emplace_back(domain, entry);
            }
            std::array<uint64_t, 4> domain_versions{};
            domain_versions.fill(legacy.revision);
            std::string migration_error;
            if (!modifier_candidate.restore_legacy_entries(
                    entries, legacy.generation, 0, start_day,
                    domain_versions, migration_error)) {
                set_fault(migration_error.empty()
                    ? "modifier_pdp3_migration_failed" : migration_error.c_str());
                _state.store(RuntimeWorkerState::STOPPED,
                             std::memory_order_release);
                return false;
            }
        }
    }
    if (restore_pending && !_pending_restore_bundle.climate_bytes.empty()) {
        std::string climate_restore_error;
        if (!_climate_authority.restore(_pending_restore_bundle.climate_bytes.data(),
                                        _pending_restore_bundle.climate_bytes.size(),
                                        climate_restore_error)) {
            set_fault(climate_restore_error.empty() ? "climate_restore_failed" :
                      climate_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (restore_pending && !_pending_restore_bundle.trigger_bytes.empty()) {
        std::string trigger_restore_error;
        if (!restore_trigger_pod_save(_pending_restore_bundle.trigger_bytes.data(),
                                     _pending_restore_bundle.trigger_bytes.size(),
                                     trigger_restore_error)) {
            set_fault(trigger_restore_error.empty() ? "trigger_restore_failed" :
                      trigger_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (restore_pending && !_pending_restore_bundle.events_bytes.empty()) {
        std::string events_restore_error;
        if (!_events_authority.restore(_pending_restore_bundle.events_bytes.data(),
                                       _pending_restore_bundle.events_bytes.size(),
                                       events_restore_error)) {
            set_fault(events_restore_error.empty() ? "events_restore_failed" :
                      events_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        uint32_t restore_slot = 0;
        if (_events_snapshots.try_begin_write(restore_slot)) {
            _events_snapshots.write_buffer(restore_slot) = _events_authority.snapshot();
            _events_snapshots.publish(restore_slot);
        }
    }
    if (restore_pending && !_pending_restore_bundle.gameplay_effect_bytes.empty()) {
        const std::vector<uint8_t> &gmp =
            _pending_restore_bundle.gameplay_effect_bytes;
        size_t gmp_cursor = 0;
        uint32_t marker = 0;
        uint32_t abi = 0;
        uint64_t generation = 0;
        uint32_t pending = 0;
        uint32_t terminal = 0;
        uint64_t state_hash = 0;
        if (!d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, marker) ||
            !d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, abi) ||
            !d7_read_u64(gmp.data(), gmp.size(), gmp_cursor, generation) ||
            !d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, pending) ||
            !d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, terminal) ||
            !d7_read_u64(gmp.data(), gmp.size(), gmp_cursor, state_hash) ||
            gmp_cursor != gmp.size() || marker != 0x31504d47u || abi != 1u) {
            set_fault("gameplay_effect_gmp1_restore_failed");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        _gameplay_effect_generation.store(generation,
                                          std::memory_order_release);
        _gameplay_effect_pending.store(pending, std::memory_order_release);
        _gameplay_effect_terminal.store(terminal, std::memory_order_release);
        _gameplay_effect_state_hash.store(state_hash,
                                          std::memory_order_release);
    }
    CountryCoreCheckpoint restored_country_checkpoint;
    bool restored_country_checkpoint_valid = false;
    if (restore_pending && !_pending_restore_bundle.country_bytes.empty()) {
        CountryCoreCheckpoint checkpoint;
        std::string country_restore_error;
        if (!decode_country_core_checkpoint(
                _pending_restore_bundle.country_bytes.data(),
                _pending_restore_bundle.country_bytes.size(), checkpoint,
                country_restore_error)) {
            set_fault(country_restore_error.empty()
                ? "country_checkpoint_restore_failed"
                : country_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        auto copy = std::make_shared<CountryCoreCheckpoint>(
            std::move(checkpoint));
        restored_country_checkpoint = *copy;
        restored_country_checkpoint_valid = true;
        std::atomic_store_explicit(&_country_checkpoint,
            std::shared_ptr<const CountryCoreCheckpoint>(std::move(copy)),
            std::memory_order_release);
        // P1-a: verify the country identity the ARCHIVE asked for, now that Country is
        // actually installed.
        //
        // `apply_ecp2_authority` had to skip this comparison (Country was still the
        // freshly bootstrapped one at that point, measured `saved_gen=19 live_gen=1`),
        // and it recorded the expected values instead. Checking here is what keeps the
        // deferred comparison honest: pairing A's Country bytes with B's Economy bytes
        // must fail to start the worker, not load silently.
        if (_economy_production_runtime != nullptr) {
            std::string identity_error;
            if (!EconomyAuthorityTransfer::verify_after_country(
                    *_economy_production_runtime, identity_error)) {
                set_fault(identity_error.empty()
                    ? "economy_country_identity_mismatch"
                    : identity_error.c_str());
                _state.store(RuntimeWorkerState::STOPPED,
                             std::memory_order_release);
                return false;
            }
        }
    }
