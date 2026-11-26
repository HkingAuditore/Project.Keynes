#include "country_runtime_persistence_includes.inc"

namespace pk {

using namespace godot;

bool NativeCountryRuntime::capture_worker_committed_checkpoint(
        CountryCoreCheckpoint &out, std::string &error) const {
    // Called on the read replica that apply_committed_read_snapshot keeps in
    // step with the worker. Its business state is the worker's committed day,
    // but the command queue, batch/seal flags, peer intents, and the attached
    // Effect/Modifier peers are leftovers of the main-thread copy it was built
    // from: under worker authority they never advance, so encode_save would
    // read them as due work and refuse. The host owns all of that state and
    // merges its own pending commands and receipts into the bundle.
    NativeCountryRuntime committed(*this);
    committed._pending_commands.clear();
    committed._command_batch = {};
    committed._boundary_seal_active = false;
    committed._peer_pending_intents.clear();
    committed._effect_runtime = nullptr;
    committed._modifier_runtime = nullptr;
    committed._economy_runtime = nullptr;
    return committed.capture_core_checkpoint(out, error);
}

bool NativeCountryRuntime::capture_core_checkpoint(
        CountryCoreCheckpoint &out, std::string &error) const {
    CountryCoreCheckpoint checkpoint;
    const CountryPeerProtocolStatus peer_status = peer_protocol_status();
    if (peer_status.pending_intents != 0 || peer_status.queued_intents != 0) {
        error = "country_checkpoint_peer_pending";
        return false;
    }
    if (peer_status.rejected_intents != 0) {
        error = "country_checkpoint_peer_rejected_retry_pending";
        return false;
    }
    if (!encode_save(checkpoint.canonical_pkcn, error)) return false;
    checkpoint.session_epoch = _session_epoch;
    checkpoint.catalog_hash = catalog_hash();
    checkpoint.generation = _generation;
    checkpoint.committed_day = _last_committed_day;
    checkpoint.business_state_hash = compute_state_hash();
    checkpoint.command_watermark = _submit_order;
    checkpoint.next_event_id = _next_event_id;
    checkpoint.next_boundary_id = _next_boundary_id;
    checkpoint.pending_protocol.reserve(_pending_commands.size());
    for (const Command &command : _pending_commands) {
        if (command.request_id == 0) continue;
        checkpoint.pending_protocol.push_back(CountryPendingCommandProtocol{
            command.submit_order, command.request_id, command.producer_id,
            command.observed_generation});
    }
    checkpoint.request_states.reserve(_typed_request_state.size());
    for (const auto &entry : _typed_request_state)
        checkpoint.request_states.push_back(entry.second);
    std::sort(checkpoint.request_states.begin(), checkpoint.request_states.end(),
        [](const CountryCommandReceipt &lhs, const CountryCommandReceipt &rhs) {
            return lhs.request_id < rhs.request_id;
        });
    checkpoint.terminal_receipts.assign(_typed_receipts.begin(),
                                        _typed_receipts.end());
    std::vector<uint8_t> encoded;
    if (!encode_country_core_checkpoint(checkpoint, encoded, error)) return false;
    size_t cursor = encoded.size() - sizeof(uint64_t);
    checkpoint.checkpoint_hash = 0;
    for (uint32_t i = 0; i < sizeof(uint64_t); ++i)
        checkpoint.checkpoint_hash |=
            static_cast<uint64_t>(encoded[cursor + i]) << (i * 8u);
    out = std::move(checkpoint);
    return true;
}

bool NativeCountryRuntime::restore_core_checkpoint(
        const CountryCoreCheckpoint &checkpoint, std::string &error) {
    if (!validate_country_core_checkpoint(checkpoint, error)) return false;
    if (!_configured) {
        error = "country_checkpoint_runtime_unconfigured";
        return false;
    }
    if (checkpoint.catalog_hash != catalog_hash()) {
        error = "country_checkpoint_catalog_mismatch";
        return false;
    }

    NativeCountryRuntime staged(*this);
    auto staged_modifier = _modifier_runtime != nullptr ? modifier_api::copy_runtime(*_modifier_runtime) : decltype(modifier_api::copy_runtime(*_modifier_runtime)){};
    if (_modifier_runtime != nullptr) {
        modifier_api::attach_country_runtime(*staged_modifier, &staged);
        modifier_api::attach_economy_runtime(*staged_modifier, _economy_runtime);
        staged._modifier_runtime = staged_modifier.get();
    }
    if (!staged.restore_core_checkpoint_in_place(checkpoint, error))
        return false;

    ModifierRuntime *live_modifier = _modifier_runtime;
    NativeEconomyRuntime *live_economy = _economy_runtime;
    EffectRuntime *live_effect = _effect_runtime;
    *this = std::move(staged);
    _modifier_runtime = live_modifier;
    _economy_runtime = live_economy;
    _effect_runtime = live_effect;
    if (live_modifier != nullptr) {
        modifier_api::replace_runtime(*live_modifier, std::move(*staged_modifier));
        modifier_api::attach_country_runtime(*live_modifier, this);
        modifier_api::attach_economy_runtime(*live_modifier, live_economy);
    }
    return true;
}

bool NativeCountryRuntime::restore_core_checkpoint_in_place(
        const CountryCoreCheckpoint &checkpoint, std::string &error) {
    if (!decode_save_in_place(checkpoint.canonical_pkcn, error)) return false;

    std::unordered_map<uint64_t, Command *> pending_by_order;
    pending_by_order.reserve(_pending_commands.size());
    for (Command &command : _pending_commands)
        pending_by_order.emplace(command.submit_order, &command);
    for (const CountryPendingCommandProtocol &metadata :
         checkpoint.pending_protocol) {
        const auto found = pending_by_order.find(metadata.submit_order);
        if (found == pending_by_order.end() || found->second->request_id != 0) {
            error = "country_checkpoint_pending_protocol_mismatch";
            return false;
        }
        found->second->request_id = metadata.request_id;
        found->second->producer_id = metadata.producer_id;
        found->second->observed_generation = metadata.observed_generation;
    }
    _typed_request_state.clear();
    for (const CountryCommandReceipt &receipt : checkpoint.request_states)
        _typed_request_state.emplace(receipt.request_id, receipt);
    _typed_receipts.assign(checkpoint.terminal_receipts.begin(),
                           checkpoint.terminal_receipts.end());
    _next_event_id = checkpoint.next_event_id;
    _next_boundary_id = checkpoint.next_boundary_id;
    close_boundary_seal();
    if (checkpoint.session_epoch == std::numeric_limits<uint64_t>::max()) {
        error = "country_checkpoint_session_epoch_exhausted";
        return false;
    }
    _session_epoch = std::max(_session_epoch, checkpoint.session_epoch + 1u);
    if (_generation != checkpoint.generation ||
        _last_committed_day != checkpoint.committed_day ||
        _submit_order != checkpoint.command_watermark ||
        compute_state_hash() != checkpoint.business_state_hash) {
        error = "country_checkpoint_business_state_mismatch";
        return false;
    }
    return true;
}
bool NativeCountryRuntime::copy_technology_domains(
        std::vector<int32_t> &out) const {
    if (!_configured) return false;
    out = _technology_domains;
    return true;
}

uint64_t NativeCountryRuntime::catalog_hash() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_technology_catalog_identity_hash,
               sizeof(_technology_catalog_identity_hash));
    hash_bytes(hash, &_technology_content_binding_hash,
               sizeof(_technology_content_binding_hash));
    hash_bytes(hash, &_technology_trigger_definition_hash,
               sizeof(_technology_trigger_definition_hash));
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _profession_ids) hash_string(hash, id);
    for (const std::string &id : _building_type_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
    for (const std::string &id : _technology_era_reward_pool_ids)
        hash_string(hash, id);
    for (const std::string &id : _research_signal_ids) hash_string(hash, id);
    for (const std::string &id : _political_regime_ids) hash_string(hash, id);
    if (!_political_regime_capability_bits.empty())
        hash_bytes(hash, _political_regime_capability_bits.data(),
                   _political_regime_capability_bits.size() * sizeof(uint32_t));
    if (!_technology_domains.empty())
        hash_bytes(hash, _technology_domains.data(), _technology_domains.size() * sizeof(int32_t));
    if (!_technology_costs.empty())
        hash_bytes(hash, _technology_costs.data(), _technology_costs.size() * sizeof(int64_t));
    if (!_technology_prerequisite_offsets.empty())
        hash_bytes(hash, _technology_prerequisite_offsets.data(),
                   _technology_prerequisite_offsets.size() * sizeof(int32_t));
    if (!_technology_prerequisites.empty())
        hash_bytes(hash, _technology_prerequisites.data(),
                   _technology_prerequisites.size() * sizeof(int32_t));
    if (!_technology_entry_milestone_indices.empty())
        hash_bytes(hash, _technology_entry_milestone_indices.data(),
                   _technology_entry_milestone_indices.size() * sizeof(int32_t));
    if (!_research_signal_requires_provenance.empty())
        hash_bytes(hash, _research_signal_requires_provenance.data(),
                   _research_signal_requires_provenance.size() * sizeof(uint8_t));
    if (!_technology_research_condition_offsets.empty())
        hash_bytes(hash, _technology_research_condition_offsets.data(),
                   _technology_research_condition_offsets.size() * sizeof(int32_t));
    if (!_technology_research_condition_ops.empty())
        hash_bytes(hash, _technology_research_condition_ops.data(),
                   _technology_research_condition_ops.size() * sizeof(int32_t));
    if (!_technology_research_condition_refs.empty())
        hash_bytes(hash, _technology_research_condition_refs.data(),
                   _technology_research_condition_refs.size() * sizeof(int32_t));
    if (!_technology_research_condition_values.empty())
        hash_bytes(hash, _technology_research_condition_values.data(),
                   _technology_research_condition_values.size() * sizeof(int64_t));
    if (!_technology_reveal_condition_offsets.empty())
        hash_bytes(hash, _technology_reveal_condition_offsets.data(),
                   _technology_reveal_condition_offsets.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_ops.empty())
        hash_bytes(hash, _technology_reveal_condition_ops.data(),
                   _technology_reveal_condition_ops.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_refs.empty())
        hash_bytes(hash, _technology_reveal_condition_refs.data(),
                   _technology_reveal_condition_refs.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_values.empty())
        hash_bytes(hash, _technology_reveal_condition_values.data(),
                   _technology_reveal_condition_values.size() * sizeof(int64_t));
    if (!_technology_reveal_signal_offsets.empty())
        hash_bytes(hash, _technology_reveal_signal_offsets.data(),
                   _technology_reveal_signal_offsets.size() * sizeof(int32_t));
    if (!_technology_reveal_signal_technologies.empty())
        hash_bytes(hash, _technology_reveal_signal_technologies.data(),
                   _technology_reveal_signal_technologies.size() * sizeof(int32_t));
    return hash;
}

uint64_t NativeCountryRuntime::compute_state_hash() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_generation, sizeof(_generation));
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        hash_bytes(hash, &_countries.active[slot], sizeof(uint8_t));
        hash_bytes(hash, &_countries.generation[slot], sizeof(uint32_t));
        hash_string(hash, _countries.stable_id[slot]);
        hash_string(hash, _countries.display_name[slot]);
        hash_bytes(hash, &_countries.territory_count[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.cash[slot], sizeof(int64_t));
        hash_bytes(hash, &_countries.state_version[slot], sizeof(uint64_t));
        hash_bytes(hash, &_countries.political_regime_id[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.political_regime_capability_bits[slot], sizeof(uint32_t));
        if (slot < _countries.capital_cell.size())
            hash_bytes(hash, &_countries.capital_cell[slot], sizeof(int32_t));
    }
    if (!_cell_country_slot.empty()) hash_bytes(hash, _cell_country_slot.data(), _cell_country_slot.size() * sizeof(int32_t));
    if (!_country_technologies.empty()) hash_bytes(hash, _country_technologies.data(), _country_technologies.size() * sizeof(uint64_t));
    if (!_country_goods.empty()) hash_bytes(hash, _country_goods.data(), _country_goods.size() * sizeof(int64_t));
    if (!_country_discovered.empty()) hash_bytes(hash, _country_discovered.data(), _country_discovered.size() * sizeof(uint64_t));
    if (!_country_pending_technologies.empty()) hash_bytes(hash, _country_pending_technologies.data(), _country_pending_technologies.size() * sizeof(uint64_t));
    if (!_country_research_signals.empty())
        hash_bytes(hash, _country_research_signals.data(),
                   _country_research_signals.size() * sizeof(uint64_t));
    for (const auto &cells : _country_research_signal_cells)
        if (!cells.empty()) hash_bytes(hash, cells.data(), cells.size() * sizeof(uint64_t));
    for (const auto &entries : _country_research_signal_evidence)
        for (const SignalEvidence &entry : entries)
            // Hash fields individually: native struct padding is not stable across
            // construction/restore and must never affect a persisted-state hash.
            hash_bytes(hash, &entry.signal, sizeof(entry.signal)),
            hash_bytes(hash, &entry.count, sizeof(entry.count)),
            hash_bytes(hash, &entry.first_day, sizeof(entry.first_day)),
            hash_bytes(hash, &entry.last_day, sizeof(entry.last_day)),
            hash_bytes(hash, &entry.first_cell, sizeof(entry.first_cell));
    if (!_country_research_queues.empty()) hash_bytes(hash, _country_research_queues.data(), _country_research_queues.size() * sizeof(int32_t));
    if (!_country_research_queue_lengths.empty()) hash_bytes(hash, _country_research_queue_lengths.data(), _country_research_queue_lengths.size() * sizeof(uint8_t));
    if (!_country_research_weights_bp.empty()) hash_bytes(hash, _country_research_weights_bp.data(), _country_research_weights_bp.size() * sizeof(int32_t));
    if (!_country_research_deferred_points.empty()) hash_bytes(hash, _country_research_deferred_points.data(), _country_research_deferred_points.size() * sizeof(int64_t));
    if (!_country_tax_defaults.empty())
        hash_bytes(hash, _country_tax_defaults.data(),
                   _country_tax_defaults.size() * sizeof(int32_t));
    if (!_country_tax_default_modes.empty())
        hash_bytes(hash, _country_tax_default_modes.data(),
                   _country_tax_default_modes.size() * sizeof(int32_t));
    if (!_country_income_tax_overrides.empty())
        hash_bytes(hash, _country_income_tax_overrides.data(),
                   _country_income_tax_overrides.size() * sizeof(int32_t));
    if (!_country_income_tax_mode_overrides.empty())
        hash_bytes(hash, _country_income_tax_mode_overrides.data(),
                   _country_income_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_consumption_tax_overrides.empty())
        hash_bytes(hash, _country_consumption_tax_overrides.data(),
                   _country_consumption_tax_overrides.size() * sizeof(int32_t));
    if (!_country_consumption_tax_mode_overrides.empty())
        hash_bytes(hash, _country_consumption_tax_mode_overrides.data(),
                   _country_consumption_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_business_tax_overrides.empty())
        hash_bytes(hash, _country_business_tax_overrides.data(),
                   _country_business_tax_overrides.size() * sizeof(int32_t));
    if (!_country_business_tax_mode_overrides.empty())
        hash_bytes(hash, _country_business_tax_mode_overrides.data(),
                   _country_business_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_import_tax_overrides.empty())
        hash_bytes(hash, _country_import_tax_overrides.data(),
                   _country_import_tax_overrides.size() * sizeof(int32_t));
    if (!_country_import_tax_mode_overrides.empty())
        hash_bytes(hash, _country_import_tax_mode_overrides.data(),
                   _country_import_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_export_tax_overrides.empty())
        hash_bytes(hash, _country_export_tax_overrides.data(),
                   _country_export_tax_overrides.size() * sizeof(int32_t));
    if (!_country_export_tax_mode_overrides.empty())
        hash_bytes(hash, _country_export_tax_mode_overrides.data(),
                   _country_export_tax_mode_overrides.size() *
                       sizeof(int32_t));
    uint64_t cell_policy_count = 0;
    for (uint32_t id : _cell_tax_policy_ids)
        if (!cell_tax_policy(id).empty()) ++cell_policy_count;
    hash_bytes(hash, &cell_policy_count, sizeof(cell_policy_count));
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const CellTaxPolicy &policy = cell_tax_policy(
            _cell_tax_policy_ids[static_cast<size_t>(cell)]);
        if (policy.empty()) continue;
        hash_bytes(hash, &cell, sizeof(cell));
        hash_bytes(hash, policy.defaults.data(),
                   policy.defaults.size() * sizeof(int32_t));
        hash_bytes(hash, policy.default_modes.data(),
                   policy.default_modes.size() * sizeof(int32_t));
        const uint64_t entry_count = policy.overrides.size();
        hash_bytes(hash, &entry_count, sizeof(entry_count));
        for (const CellTaxOverride &entry : policy.overrides) {
            hash_bytes(hash, &entry.kind, sizeof(entry.kind));
            hash_string(hash, tax_item_ids(entry.kind)[
                static_cast<size_t>(entry.item)]);
            hash_bytes(hash, &entry.rate, sizeof(entry.rate));
            hash_bytes(hash, &entry.mode, sizeof(entry.mode));
        }
    }
    hash_bytes(hash, &_tax_policy_version, sizeof(_tax_policy_version));
    hash_bytes(hash, &_last_research_day, sizeof(_last_research_day));
    for (const auto &entries : _country_research_progress) {
        for (const auto &entry : entries) {
            hash_bytes(hash, &entry.first, sizeof(entry.first));
            hash_bytes(hash, &entry.second, sizeof(entry.second));
        }
    }
    hash_bytes(hash, &_era_reward_reference.plan_id,
               sizeof(_era_reward_reference.plan_id));
    hash_bytes(hash, &_era_reward_reference.offer_generation,
               sizeof(_era_reward_reference.offer_generation));
    hash_bytes(hash, &_era_reward_reference.milestone_technology,
               sizeof(_era_reward_reference.milestone_technology));
    hash_bytes(hash, &_era_reward_reference.status,
               sizeof(_era_reward_reference.status));
    return hash;
}
uint64_t NativeCountryRuntime::catalog_hash_v3() const {
    uint64_t hash = FNV_OFFSET;
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
    if (!_technology_domains.empty())
        hash_bytes(hash, _technology_domains.data(),
                   _technology_domains.size() * sizeof(int32_t));
    if (!_technology_costs.empty())
        hash_bytes(hash, _technology_costs.data(),
                   _technology_costs.size() * sizeof(int64_t));
    if (!_technology_prerequisite_offsets.empty())
        hash_bytes(hash, _technology_prerequisite_offsets.data(),
                   _technology_prerequisite_offsets.size() *
                       sizeof(int32_t));
    if (!_technology_prerequisites.empty())
        hash_bytes(hash, _technology_prerequisites.data(),
                   _technology_prerequisites.size() * sizeof(int32_t));
    if (!_technology_entry_milestone_indices.empty())
        hash_bytes(hash, _technology_entry_milestone_indices.data(),
                   _technology_entry_milestone_indices.size() * sizeof(int32_t));
    return hash;
}

int64_t NativeCountryRuntime::state_hash_v3_compat() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_generation, sizeof(_generation));
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        hash_bytes(hash, &_countries.active[slot], sizeof(uint8_t));
        hash_bytes(hash, &_countries.generation[slot], sizeof(uint32_t));
        hash_string(hash, _countries.stable_id[slot]);
        hash_string(hash, _countries.display_name[slot]);
        hash_bytes(hash, &_countries.territory_count[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.cash[slot], sizeof(int64_t));
        hash_bytes(hash, &_countries.state_version[slot], sizeof(uint64_t));
    }
    if (!_cell_country_slot.empty())
        hash_bytes(hash, _cell_country_slot.data(),
                   _cell_country_slot.size() * sizeof(int32_t));
    if (!_country_technologies.empty())
        hash_bytes(hash, _country_technologies.data(),
                   _country_technologies.size() * sizeof(uint64_t));
    if (!_country_goods.empty())
        hash_bytes(hash, _country_goods.data(),
                   _country_goods.size() * sizeof(int64_t));
    if (!_country_discovered.empty())
        hash_bytes(hash, _country_discovered.data(),
                   _country_discovered.size() * sizeof(uint64_t));
    if (!_country_pending_technologies.empty())
        hash_bytes(hash, _country_pending_technologies.data(),
                   _country_pending_technologies.size() * sizeof(uint64_t));
    if (!_country_research_queues.empty())
        hash_bytes(hash, _country_research_queues.data(),
                   _country_research_queues.size() * sizeof(int32_t));
    if (!_country_research_queue_lengths.empty())
        hash_bytes(hash, _country_research_queue_lengths.data(),
                   _country_research_queue_lengths.size() * sizeof(uint8_t));
    if (!_country_research_weights_bp.empty())
        hash_bytes(hash, _country_research_weights_bp.data(),
                   _country_research_weights_bp.size() * sizeof(int32_t));
    if (!_country_research_deferred_points.empty())
        hash_bytes(hash, _country_research_deferred_points.data(),
                   _country_research_deferred_points.size() * sizeof(int64_t));
    hash_bytes(hash, &_last_research_day, sizeof(_last_research_day));
    for (const auto &entries : _country_research_progress) {
        for (const auto &entry : entries) {
            hash_bytes(hash, &entry.first, sizeof(entry.first));
            hash_bytes(hash, &entry.second, sizeof(entry.second));
        }
    }
    return static_cast<int64_t>(hash);
}

int64_t NativeCountryRuntime::state_hash() const {
    const bool cache_matches = _state_hash_cache_valid &&
        _state_hash_cache_generation == _generation &&
        _state_hash_cache_research_day == _last_research_day &&
        _state_hash_cache_tax_policy_version == _tax_policy_version &&
        _state_hash_cache_era_reward.plan_id == _era_reward_reference.plan_id &&
        _state_hash_cache_era_reward.offer_generation == _era_reward_reference.offer_generation &&
        _state_hash_cache_era_reward.milestone_technology == _era_reward_reference.milestone_technology &&
        _state_hash_cache_era_reward.status == _era_reward_reference.status;
    if (!cache_matches) {
        _state_hash_cache = compute_state_hash();
        _state_hash_cache_generation = _generation;
        _state_hash_cache_research_day = _last_research_day;
        _state_hash_cache_tax_policy_version = _tax_policy_version;
        _state_hash_cache_era_reward = _era_reward_reference;
        _state_hash_cache_valid = true;
    }
    return static_cast<int64_t>(_state_hash_cache);
}

} // namespace pk
