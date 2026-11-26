void RuntimeModifierPodAuthority::serialize(std::vector<uint8_t> &out) const {
    out.clear();
    out.insert(out.end(), {'M', 'D', 'F', '2'});
    append_le(out, RUNTIME_MODIFIER_POD_ABI_VERSION);
    append_le(out, _catalog.catalog_hash);
    append_le(out, _current.generation);
    append_le(out, _current.state_hash);
    append_le(out, _current.committed_day);
    for (const DomainState &domain : _current.domains) append_le(out, domain.version);
    const auto append_entry = [&out](const RuntimeModifierPodEntry &entry) {
        append_le(out, entry.modifier_handle);
        append_le(out, entry.target_handle);
        append_le(out, entry.target_generation);
        append_le(out, entry.definition_id);
        append_le(out, entry.scope);
        append_le(out, entry.entity_handle);
        append_le(out, entry.group_handle);
        append_le(out, entry.source_type);
        append_le(out, entry.source_id);
        append_le(out, entry.stacks);
        append_le(out, entry.magnitude_q16);
        append_le(out, entry.applied_day);
        append_le(out, entry.expires_day);
    };
    for (const DomainState &domain : _current.domains) {
        append_le(out, static_cast<uint32_t>(domain.entries.size()));
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            const uint32_t generation = i < domain.handle_generations.size()
                ? domain.handle_generations[i] : 0;
            append_le(out, generation);
            const uint8_t active = domain.entries[i].modifier_handle != 0 ? 1u : 0u;
            append_le(out, active);
            if (active != 0) append_entry(domain.entries[i]);
        }
        append_le(out, static_cast<uint32_t>(domain.free_indices.size()));
        for (const uint32_t index : domain.free_indices) append_le(out, index);
        append_le(out, static_cast<uint32_t>(domain.expiry_queue.size()));
        for (const uint32_t index : domain.expiry_queue) append_le(out, index);
    }
    const uint32_t pending_count = static_cast<uint32_t>(std::min<size_t>(
        _pending_identities.size(), RUNTIME_MODIFIER_POD_MAX_ENTRIES));
    append_le(out, pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        const RuntimeModifierPodCommand &command = _pending_identities[i];
        append_le(out, command.request_id);
        append_le(out, command.producer_id);
        append_le(out, command.sequence);
        append_le(out, command.effective_day);
        append_le(out, command.opcode);
        append_le(out, command.domain);
    }
    const uint64_t checksum = hash_bytes(FNV_OFFSET, out.data(), out.size());
    append_le(out, checksum);
}

bool RuntimeModifierPodAuthority::restore(const uint8_t *data, size_t size,
                                          std::string &error) {
    clear_error(error);
    if (data == nullptr || size < 4u + 4u + 8u * 6u + 8u ||
        size > MAX_SERIALIZED_BYTES || std::memcmp(data, "MDF2", 4) != 0) {
        error = "modifier_pod_save_invalid";
        return false;
    }
    const size_t encoded_at = size - sizeof(uint64_t);
    size_t check_cursor = encoded_at;
    uint64_t encoded = 0;
    if (!read_le(data, size, check_cursor, encoded) ||
        hash_bytes(FNV_OFFSET, data, encoded_at) != encoded) {
        error = "modifier_pod_save_checksum_failed";
        return false;
    }
    size_t cursor = 4u;
    uint32_t abi = 0;
    uint64_t catalog_hash = 0, generation = 0, saved_state_hash = 0;
    int64_t committed_day = -1;
    std::array<uint64_t, 4> versions{};
    if (!read_le(data, size, cursor, abi) || !read_le(data, size, cursor, catalog_hash) ||
        !read_le(data, size, cursor, generation) ||
        !read_le(data, size, cursor, saved_state_hash) ||
        !read_le(data, size, cursor, committed_day)) {
        error = "modifier_pod_save_truncated";
        return false;
    }
    for (uint64_t &version : versions) {
        if (!read_le(data, size, cursor, version)) {
            error = "modifier_pod_save_truncated";
            return false;
        }
    }
    if (!_configured || abi != RUNTIME_MODIFIER_POD_ABI_VERSION ||
        catalog_hash != _catalog.catalog_hash) {
        error = "modifier_pod_save_catalog_mismatch";
        return false;
    }

    State restored;
    restored.generation = generation;
    restored.committed_day = committed_day;
    const auto read_entry = [this, data, size, &cursor](RuntimeModifierPodEntry &entry) {
        return read_le(data, size, cursor, entry.modifier_handle) &&
            read_le(data, size, cursor, entry.target_handle) &&
            read_le(data, size, cursor, entry.target_generation) &&
            read_le(data, size, cursor, entry.definition_id) &&
            read_le(data, size, cursor, entry.scope) &&
            read_le(data, size, cursor, entry.entity_handle) &&
            read_le(data, size, cursor, entry.group_handle) &&
            read_le(data, size, cursor, entry.source_type) &&
            read_le(data, size, cursor, entry.source_id) &&
            read_le(data, size, cursor, entry.stacks) &&
            read_le(data, size, cursor, entry.magnitude_q16) &&
            read_le(data, size, cursor, entry.applied_day) &&
            read_le(data, size, cursor, entry.expires_day);
    };
    for (size_t d = 0; d < restored.domains.size(); ++d) {
        DomainState &domain = restored.domains[d];
        domain.version = versions[d];
        uint32_t slot_count = 0;
        if (!read_le(data, size, cursor, slot_count) ||
            slot_count > RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
            error = "modifier_pod_save_count_invalid";
            return false;
        }
        domain.entries.resize(slot_count);
        domain.handle_generations.resize(slot_count);
        for (uint32_t slot = 0; slot < slot_count; ++slot) {
            uint8_t active = 0;
            if (!read_le(data, size, cursor, domain.handle_generations[slot]) ||
                !read_le(data, size, cursor, active) || active > 1u) {
                error = "modifier_pod_save_entry_truncated";
                return false;
            }
            if (active != 0 && !read_entry(domain.entries[slot])) {
                error = "modifier_pod_save_entry_truncated";
                return false;
            }
            if (active == 0) {
                domain.entries[slot] = RuntimeModifierPodEntry{};
            } else {
                RuntimeModifierPodEntry &entry = domain.entries[slot];
                entry.domain = static_cast<uint16_t>(d);
                const uint32_t encoded_slot = static_cast<uint32_t>(
                    entry.modifier_handle & 0xffffffffull);
                const uint32_t encoded_generation = static_cast<uint32_t>(
                    entry.modifier_handle >> 32u);
                if (encoded_slot != slot || encoded_generation == 0 ||
                    domain.handle_generations[slot] != encoded_generation ||
                    entry.definition_id < 0 ||
                    entry.definition_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
                    _catalog.definitions[static_cast<size_t>(entry.definition_id)].domain !=
                        static_cast<int32_t>(d) || entry.scope < 0 || entry.scope > 2 ||
                    entry.stacks <= 0 || entry.stacks > _catalog.definitions[
                        static_cast<size_t>(entry.definition_id)].max_stacks ||
                    entry.magnitude_q16 < 0 ||
                    entry.magnitude_q16 > MAX_MAGNITUDE_Q16 ||
                    (entry.expires_day != -1 && entry.expires_day < entry.applied_day)) {
                    error = "modifier_pod_save_entry_invalid";
                    return false;
                }
                entry.value_q16 = entry.magnitude_q16;
            }
        }
        uint32_t free_count = 0;
        if (!read_le(data, size, cursor, free_count) || free_count > slot_count) {
            error = "modifier_pod_save_free_list_invalid";
            return false;
        }
        domain.free_indices.resize(free_count);
        std::vector<uint8_t> free_seen(slot_count, 0);
        for (uint32_t &index : domain.free_indices) {
            if (!read_le(data, size, cursor, index) || index >= slot_count ||
                free_seen[index] != 0 || domain.entries[index].modifier_handle != 0) {
                error = "modifier_pod_save_free_list_invalid";
                return false;
            }
            free_seen[index] = 1;
        }
        uint32_t expiry_count = 0;
        if (!read_le(data, size, cursor, expiry_count) || expiry_count > slot_count) {
            error = "modifier_pod_save_expiry_invalid";
            return false;
        }
        domain.expiry_queue.resize(expiry_count);
        for (uint32_t &index : domain.expiry_queue) {
            if (!read_le(data, size, cursor, index) || index >= slot_count ||
                domain.entries[index].modifier_handle == 0 ||
                domain.entries[index].expires_day < 0) {
                error = "modifier_pod_save_expiry_invalid";
                return false;
            }
        }
        std::vector<uint32_t> canonical = domain.expiry_queue;
        rebuild_expiry_queue(domain);
        if (canonical != domain.expiry_queue) {
            error = "modifier_pod_save_expiry_order_invalid";
            return false;
        }
    }
    uint32_t pending_count = 0;
    if (!read_le(data, size, cursor, pending_count) ||
        pending_count > RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
        error = "modifier_pod_save_pending_invalid";
        return false;
    }
    std::vector<RuntimeModifierPodCommand> pending;
    pending.reserve(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        RuntimeModifierPodCommand command;
        if (!read_le(data, size, cursor, command.request_id) ||
            !read_le(data, size, cursor, command.producer_id) ||
            !read_le(data, size, cursor, command.sequence) ||
            !read_le(data, size, cursor, command.effective_day) ||
            !read_le(data, size, cursor, command.opcode) ||
            !read_le(data, size, cursor, command.domain)) {
            error = "modifier_pod_save_pending_truncated";
            return false;
        }
        pending.push_back(command);
    }
    if (cursor != encoded_at) {
        error = "modifier_pod_save_trailing_bytes";
        return false;
    }
    restored.state_hash = state_hash(restored);
    if (restored.state_hash != saved_state_hash) {
        error = "modifier_pod_save_state_hash_failed";
        return false;
    }
    _current = std::move(restored);
    _next = _current;
    _pending_identities = std::move(pending);
    build_snapshot(_current, _snapshot);
    _report.generation = _current.generation;
    _report.state_hash = _snapshot.state_hash;
    _plan_ready = false; _view_cursor = {};
    return true;
}

bool RuntimeModifierPodAuthority::restore_legacy_entries(
        const std::vector<std::pair<uint16_t, RuntimeModifierPodEntry>> &entries,
        uint64_t generation, uint64_t saved_state_hash, int64_t committed_day,
        const std::array<uint64_t, 4> &domain_versions, std::string &error) {
    clear_error(error);
    if (!_configured || entries.size() > RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
        error = "modifier_pod_legacy_restore_invalid";
        return false;
    }
    State restored;
    restored.generation = generation;
    restored.committed_day = committed_day;
    for (size_t d = 0; d < restored.domains.size(); ++d)
        restored.domains[d].version = domain_versions[d];
    for (const auto &pair : entries) {
        const uint16_t domain_id = pair.first;
        const RuntimeModifierPodEntry &entry = pair.second;
        if (domain_id >= 4 || entry.modifier_handle == 0 ||
            entry.definition_id < 0 ||
            entry.definition_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            _catalog.definitions[static_cast<size_t>(entry.definition_id)].domain !=
                static_cast<int32_t>(domain_id)) {
            error = "modifier_pod_legacy_entry_invalid";
            return false;
        }
        DomainState &domain = restored.domains[domain_id];
        const uint32_t slot = static_cast<uint32_t>(entry.modifier_handle & 0xffffffffull);
        const uint32_t generation_bits = static_cast<uint32_t>(entry.modifier_handle >> 32u);
        if (generation_bits == 0 || slot >= RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
            error = "modifier_pod_legacy_handle_invalid";
            return false;
        }
        if (domain.entries.size() <= slot) {
            domain.entries.resize(static_cast<size_t>(slot) + 1u);
            domain.handle_generations.resize(static_cast<size_t>(slot) + 1u, 0);
        }
        if (domain.entries[slot].modifier_handle != 0) {
            error = "modifier_pod_legacy_handle_duplicate";
            return false;
        }
        domain.entries[slot] = entry;
        domain.entries[slot].domain = domain_id;
        domain.entries[slot].value_q16 = entry.magnitude_q16;
        domain.handle_generations[slot] = generation_bits;
    }
    for (DomainState &domain : restored.domains) {
        for (uint32_t index = 0; index < domain.entries.size(); ++index) {
            if (domain.entries[index].modifier_handle == 0)
                domain.free_indices.push_back(index);
        }
        rebuild_expiry_queue(domain);
    }
    restored.state_hash = state_hash(restored);
    if (saved_state_hash != 0 && restored.state_hash != saved_state_hash) {
        error = "modifier_pod_legacy_state_hash_failed";
        return false;
    }
    _current = std::move(restored);
    _next = _current;
    _pending_identities.clear();
    build_snapshot(_current, _snapshot);
    _report.generation = _current.generation;
    _report.state_hash = _snapshot.state_hash;
    _plan_ready = false; _view_cursor = {};
    return true;
}
