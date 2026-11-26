bool NativeEconomyRuntime::validate_ecp2_candidate(
        const RuntimeEconomyEcp2State &in, std::string &error) const {
    error.clear();
    if ((in.authority_domain_mask & ECP2_DOMAIN_EPOCH_RESUME) != 0) {
        error = "ecp2_mid_epoch_resume_unsupported";
        return false;
    }
    // Resource wire shape is checked HERE, before `end_restore_internal` commits the
    // candidate.
    //
    // `apply_ecp2_authority_internal` feeds every chunk, commits with
    // `end_restore_internal`, and only THEN decodes the resource domain. So a corrupt
    // resource wire used to be discovered after the restore had already been committed,
    // which is exactly the wrong order for a fail-closed path: the caller sees a
    // failure but the live state has already moved. Validating the same bytes upfront
    // makes it a true precondition (same shape rules, no state written).
    {
        const auto resource_it = in.domain_blobs.find(ECP2_DOMAIN_RESOURCE);
        if (resource_it != in.domain_blobs.end() && !resource_it->second.empty()) {
            const std::vector<uint8_t> &blob = resource_it->second;
            size_t wire_offset = 0;
            while (wire_offset + 16u <= blob.size()) {
                const uint8_t *chunk = blob.data() + wire_offset;
                const uint32_t magic = static_cast<uint32_t>(chunk[0]) |
                    (static_cast<uint32_t>(chunk[1]) << 8u) |
                    (static_cast<uint32_t>(chunk[2]) << 16u) |
                    (static_cast<uint32_t>(chunk[3]) << 24u);
                if (magic != SAVE_MAGIC) break;
                const uint32_t payload_size = static_cast<uint32_t>(chunk[12]) |
                    (static_cast<uint32_t>(chunk[13]) << 8u) |
                    (static_cast<uint32_t>(chunk[14]) << 16u) |
                    (static_cast<uint32_t>(chunk[15]) << 24u);
                const size_t chunk_size = 16u + static_cast<size_t>(payload_size);
                if (chunk_size > blob.size() - wire_offset) break;
                wire_offset += chunk_size;
            }
            RuntimeEconomyResourceStore probe;
            probe.resource_count = static_cast<int32_t>(_resource_ids.size());
            probe.cell_count = _cell_count.get();
            const uint32_t expected_lanes = static_cast<uint32_t>(
                static_cast<size_t>(probe.resource_count) * probe.cell_count);
            if (!probe.load_wire(blob.data() + wire_offset,
                                 blob.size() - wire_offset, expected_lanes)) {
                error = "ecp2_resource_wire_invalid";
                return false;
            }
        }
    }
    const bool migrating = runtime_hash_migration_enabled() && in.abi_version == 2u && in.schema_version == 53;
    if (in.abi_version != RUNTIME_ECONOMY_ECP2_ABI_VERSION && !migrating) {
        error = "ecp2_abi_version_incompatible";
        return false;
    }
    if (in.schema_version != RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION) {
        error = "ecp2_schema_version_incompatible";
        return false;
    }
    if (in.envelope.hash_version != (runtime_chunk_hash_enabled() ? 2u : 1u) &&
        !runtime_hash_migration_enabled()) {
        error = "ecp2_hash_version_requires_explicit_migration";
        return false;
    }
    if ((in.authority_domain_mask & ECP2_DOMAIN_ENVELOPE) == 0) {
        error = "ecp2_envelope_missing";
        return false;
    }
    if (!ecp2_has_required_domains(in.authority_domain_mask,
                                   ECP2_DOMAIN_CORE_AUTHORITY)) {
        error = "ecp2_core_domains_missing";
        return false;
    }
    // Current ECP2 always carries PKEC37, including a zero-record chunk for
    // a peaceful world. Absence cannot certify an empty table: older broken
    // captures also omitted nonempty authoritative rows. Reject before any
    // candidate mutation; the direct PKEC62 reader keeps its empty default.
    std::vector<std::vector<uint8_t>> mobilization_chunks;
    ecp2_collect_pkec_chunks_for_section(in.domain_blobs,
        SAVE_SECTION_STRATUM_MOBILIZATION, mobilization_chunks);
    if (mobilization_chunks.empty()) {
        error = "ecp2_stratum_mobilization_section_missing";
        return false;
    }
    const auto owned_state_it = in.domain_blobs.find(ECP2_DOMAIN_OWNED_STATE);
    if ((in.authority_domain_mask & ECP2_DOMAIN_OWNED_STATE) == 0 ||
        owned_state_it == in.domain_blobs.end() ||
        !validate_owned_state_soa(owned_state_it->second)) {
        error = "ecp2_owned_state_missing_or_invalid";
        return false;
    }
    if (!EconomyAuthorityTransfer::validate_continuations(*this, in, error)) return false;
    uint64_t revision = 0;
    std::vector<uint64_t> handles;
    std::vector<int64_t> last_day;
    std::vector<uint8_t> qualified;
    decltype(_class_opinion_buffers)::value_type opinion;
    if (!publication_codec::decode(publication_block(owned_state_it->second),
            revision, handles, last_day, qualified, opinion, _development_metric_types.size()) ||
        opinion.commit_day > in.envelope.last_committed_day) {
        error = "ecp2_publication_state_invalid";
        return false;
    }
    if (_bootstrapped && in.envelope.catalog_hash != 0 &&
        in.envelope.catalog_hash != _catalog_hash.get()) {
        error = "ecp2_catalog_hash_mismatch";
        return false;
    }
    if (_bootstrapped && in.envelope.cell_count > 0 &&
        in.envelope.cell_count != _cell_count.get()) {
        error = "ecp2_cell_count_mismatch";
        return false;
    }
    if (in.envelope.committed_generation == 0) {
        error = "ecp2_committed_generation_invalid";
        return false;
    }
    if (in.envelope.last_committed_day < 0 ||
        in.envelope.current_day < in.envelope.last_committed_day) {
        error = "ecp2_day_order_invalid";
        return false;
    }
    // When optional journal / signal / audit domains claim presence, require
    // a non-empty domain blob. Full row decode stays on the PKEC section path.
    const auto require_domain_blob = [&](uint32_t domain,
                                         const char *missing_reason) {
        if ((in.authority_domain_mask & domain) == 0) return true;
        const auto it = in.domain_blobs.find(domain);
        if (it == in.domain_blobs.end() || it->second.empty()) {
            error = missing_reason;
            return false;
        }
        return true;
    };
    if (!require_domain_blob(ECP2_DOMAIN_COMMANDS,
                             "ecp2_commands_domain_empty") ||
        !require_domain_blob(ECP2_DOMAIN_SIGNALS,
                             "ecp2_signals_domain_empty") ||
        !require_domain_blob(ECP2_DOMAIN_AUDIT,
                             "ecp2_audit_domain_empty")) {
        return false;
    }
    return true;
}



bool NativeEconomyRuntime::capture_ecp2_authority(RuntimeEconomyEcp2State &out,
                                                  std::string &error,
                                                  uint32_t flags) const {
    error.clear();
    out = RuntimeEconomyEcp2State{};
    if (!_bootstrapped || _fatal) {
        error = !_bootstrapped ? "economy_not_bootstrapped" : "economy_fatal";
        return false;
    }
    // Resume v3 contains cursors but no frozen inputs, partial market results,
    // or pending transactions. Exporting it would promise a continuation that
    // cannot be reconstructed. Flags cannot bypass the committed boundary.
    if (_epoch_active) {
        error = "save_requires_committed_boundary";
        return false;
    }

    NativeEconomyRuntime *self = const_cast<NativeEconomyRuntime *>(this);
    RuntimeEconomyLedgerState pre_owned_ledger;
    {
    EconomyCostProbe probe("save.ecp2.ledger", _current_day.get());
    self->capture_committed_ledger_state(pre_owned_ledger);
    const char *ledger_reason = nullptr;
    if (!pre_owned_ledger.valid(&ledger_reason)) {
        error = std::string("ecp2_owned_state_capture_invalid:") +
            (ledger_reason != nullptr ? ledger_reason : "unknown");
        return false;
    }
    }
    const bool saved_allow = self->_ecp2_allow_mid_epoch_export;
    if ((flags & ECP2_CAPTURE_ALLOW_MID_EPOCH) != 0)
        self->_ecp2_allow_mid_epoch_export = true;

    self->_ecp2_rollback_backup_export =
        (flags & ECP2_CAPTURE_ROLLBACK_BACKUP) != 0;
    Dictionary begin = self->begin_save(4 * 1024 * 1024);
    self->_ecp2_rollback_backup_export = false;
    if (!static_cast<bool>(begin.get("ok", false))) {
        self->_ecp2_allow_mid_epoch_export = saved_allow;
        error = String(begin.get("reason", "ecp2_begin_save_failed"))
                    .utf8()
                    .get_data();
        return false;
    }

    out.schema_version = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    out.abi_version = RUNTIME_ECONOMY_ECP2_ABI_VERSION;
    out.envelope.schema_version = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    out.envelope.abi_version = RUNTIME_ECONOMY_ECP2_ABI_VERSION;
    out.envelope.cell_count = _cell_count.get();
    out.envelope.market_count = market_store().market_count.get();
    out.envelope.good_count = market_store().good_count.get();
    out.envelope.catalog_hash = _catalog_hash.get();
    out.envelope.building_catalog_hash = _building_catalog_hash.get();
    out.envelope.settlement_catalog_hash = _settlement_catalog_hash;
    out.envelope.family_catalog_hash = _family_catalog_hash.get();
    out.envelope.person_catalog_hash = _person_catalog_hash.get();
    out.envelope.market_cycle_days = locked_market_cycle_days();
    out.envelope.plan_cycle_days = locked_plan_cycle_days();
    out.envelope.investment_cycle_days = locked_investment_cycle_days();
    out.envelope.epoch_id = _epoch_id.get();
    out.envelope.last_committed_day = _last_committed_day.get();
    out.envelope.current_day = _current_day.get();
    out.envelope.sample_day = _sample_day;
    out.envelope.epoch_days = _epoch_days.get();
    out.envelope.committed_generation = _committed_generation;
    out.envelope.seed = _seed.get();
    out.authority_domain_mask = ECP2_DOMAIN_ENVELOPE;

    {
    EconomyCostProbe probe("save.ecp2.pkec_chunks", _current_day.get());
    while (true) {
        const PackedByteArray chunk = self->read_save_chunk(4 * 1024 * 1024);
        if (chunk.is_empty()) break;
        const int64_t chunk_size = chunk.size();
        if (chunk_size < 16) {
            self->_ecp2_allow_mid_epoch_export = saved_allow;
            error = "ecp2_save_chunk_truncated";
            self->end_save();
            return false;
        }
        const uint8_t *bytes = chunk.ptr();
        const uint16_t section = static_cast<uint16_t>(bytes[6]) |
            static_cast<uint16_t>(static_cast<uint16_t>(bytes[7]) << 8u);
        if (section == SAVE_SECTION_END) continue;
        const uint32_t domain = ecp2_domain_for_pkec_section(section);
        if (domain == 0) continue;
        std::vector<uint8_t> &blob = out.domain_blobs[domain];
        blob.insert(blob.end(), bytes, bytes + static_cast<size_t>(chunk_size));
        out.authority_domain_mask |= domain;
    }
    }

    Dictionary end = self->end_save();
    self->_ecp2_allow_mid_epoch_export = saved_allow;
    if (!static_cast<bool>(end.get("ok", false))) {
        error = String(end.get("reason", "ecp2_end_save_failed")).utf8().get_data();
        return false;
    }

    {
    EconomyCostProbe probe("save.ecp2.resource", _current_day.get());
    RuntimeEconomyResourceStore resource_store;
    resource_store.resource_count =
        static_cast<int32_t>(_resource_ids.size());
    resource_store.cell_count = _cell_count.get();
    resource_store.stock = resource_stock_lanes();
    if (_resource_store_alias != nullptr)
        resource_store.cell_generation = _resource_store_alias->cell_generation;
    else
        resource_store.cell_generation = _cell_resource_gen;
    std::vector<uint8_t> resource_wire;
    resource_store.append_wire(resource_wire);
    out.domain_blobs[ECP2_DOMAIN_RESOURCE] = std::move(resource_wire);
    out.authority_domain_mask |= ECP2_DOMAIN_RESOURCE;
    }

    // OwnedState is authoritative; PKEC remains the compatibility decoder.
    {
    EconomyCostProbe probe("save.ecp2.owned_state", _current_day.get());
    std::vector<uint8_t> owned_state_wire;
    encode_owned_state_soa(pre_owned_ledger, owned_state_wire);
    static const bool verify_codec = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_SAVE_CODEC_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (verify_codec) {
        std::vector<uint8_t> reference;
        encode_owned_state_soa(pre_owned_ledger, reference, false);
        if (owned_state_wire != reference) {
            error = "ecp2_owned_state_codec_mismatch";
            return false;
        }
    }
    if (owned_state_wire.empty()) {
        error = "ecp2_owned_state_capture_empty";
        return false;
    }
    append_publication_block(owned_state_wire, publication_codec::encode(
        _class_opinion_revision, _development_fact_country_handles,
        _development_fact_last_day, _development_fact_qualified,
        country_class_opinion_snapshot()));
    EconomyAuthorityTransfer::append_continuations(*this, owned_state_wire);
    out.domain_blobs[ECP2_DOMAIN_OWNED_STATE] = std::move(owned_state_wire);
    out.authority_domain_mask |= ECP2_DOMAIN_OWNED_STATE;
    }
    return true;
}

bool NativeEconomyRuntime::apply_ecp2_authority_internal(
        const RuntimeEconomyEcp2State &in, std::string &error) {
    error.clear();
    if (!validate_ecp2_candidate(in, error)) return false;

    uint64_t restored_revision = 0;
    std::vector<uint64_t> restored_handles;
    std::vector<int64_t> restored_last_day;
    std::vector<uint8_t> restored_qualified;
    decltype(_class_opinion_buffers)::value_type restored_opinion;
    if (!publication_codec::decode(publication_block(in.domain_blobs.at(ECP2_DOMAIN_OWNED_STATE)),
            restored_revision, restored_handles, restored_last_day, restored_qualified,
            restored_opinion, _development_metric_types.size())) {
        error = "ecp2_publication_state_invalid";
        return false;
    }
    if (!begin_restore_internal(error)) return false;
    // Live was preserved through begin_restore; only now open the candidate
    // rebuild surface (caller already holds a rollback backup when live was
    // previously bootstrapped).
    prepare_restore_candidate_scratch();

    std::vector<std::vector<uint8_t>> ordered_chunks;
    // Every optional extension section must be inside this range; END (31)
    // maps to no ECP2 domain, so visiting it here collects nothing and the
    // terminator is appended below.
    for (uint16_t section = SAVE_SECTION_HEADER;
         section <= SAVE_SECTION_LAST_EXTENSION; ++section) {
        ecp2_collect_pkec_chunks_for_section(in.domain_blobs, section,
                                             ordered_chunks);
    }
    {
        std::vector<std::vector<uint8_t>> end_chunks;
        ecp2_collect_pkec_chunks_for_section(in.domain_blobs, SAVE_SECTION_END,
                                             end_chunks);
        if (end_chunks.empty()) {
            std::vector<uint8_t> payload;
            const godot::PackedByteArray end_chunk =
                make_save_chunk(SAVE_SECTION_END, 0, payload);
            ordered_chunks.emplace_back(
                static_cast<size_t>(end_chunk.size()));
            std::memcpy(ordered_chunks.back().data(), end_chunk.ptr(),
                        ordered_chunks.back().size());
        } else {
            ordered_chunks.insert(ordered_chunks.end(),
                                  end_chunks.begin(), end_chunks.end());
        }
    }

    for (const std::vector<uint8_t> &bytes : ordered_chunks) {
        godot::PackedByteArray chunk;
        chunk.resize(static_cast<int64_t>(bytes.size()));
        if (!bytes.empty())
            std::memcpy(chunk.ptrw(), bytes.data(), bytes.size());
        const Dictionary fed = feed_restore_chunk(chunk);
        if (!static_cast<bool>(fed.get("ok", false))) {
            error = String(fed.get("reason", "ecp2_restore_chunk_failed"))
                        .utf8()
                        .get_data();
            _restore = {};
            return false;
        }
    }

    if (!end_restore_internal(error)) {
        _restore = {};
        return false;
    }

    const auto resource_it = in.domain_blobs.find(ECP2_DOMAIN_RESOURCE);
    if (resource_it != in.domain_blobs.end() &&
        !resource_it->second.empty()) {
        // The resource domain may contain both the optional PKEC resource
        // section and the typed ABI9 resource wire. Strip framed PKEC chunks
        // before decoding the raw wire payload.
        size_t resource_wire_offset = 0;
        const std::vector<uint8_t> &resource_blob = resource_it->second;
        while (resource_wire_offset + 16u <= resource_blob.size()) {
            const uint8_t *chunk = resource_blob.data() + resource_wire_offset;
            const uint32_t magic = static_cast<uint32_t>(chunk[0]) |
                (static_cast<uint32_t>(chunk[1]) << 8u) |
                (static_cast<uint32_t>(chunk[2]) << 16u) |
                (static_cast<uint32_t>(chunk[3]) << 24u);
            if (magic != SAVE_MAGIC) break;
            const uint32_t payload_size = static_cast<uint32_t>(chunk[12]) |
                (static_cast<uint32_t>(chunk[13]) << 8u) |
                (static_cast<uint32_t>(chunk[14]) << 16u) |
                (static_cast<uint32_t>(chunk[15]) << 24u);
            const size_t chunk_size = 16u + static_cast<size_t>(payload_size);
            if (chunk_size > resource_blob.size() - resource_wire_offset) break;
            resource_wire_offset += chunk_size;
        }
        RuntimeEconomyResourceStore store;
        store.resource_count = static_cast<int32_t>(_resource_ids.size());
        store.cell_count = _cell_count.get();
        // A freshly configured restore target has no captured resource lanes
        // yet. Validate the incoming wire against the catalog/world shape,
        // not the destination's previous (possibly empty) snapshot.
        const uint32_t expected_lanes = static_cast<uint32_t>(
            static_cast<size_t>(store.resource_count) * store.cell_count);
        if (!store.load_wire(resource_blob.data() + resource_wire_offset,
                             resource_blob.size() - resource_wire_offset,
                             expected_lanes)) {
            error = "ecp2_resource_wire_invalid";
            _restore = {};
            return false;
        }
        if (_resource_store_alias != nullptr) {
            _resource_store_alias->stock = store.stock;
            _resource_store_alias->cell_generation = store.cell_generation;
        } else {
            _resource_snapshot = store.stock;
            _cell_resource_gen = store.cell_generation;
        }
        // Preserve integer stock until the matching world capture.
        _resource_stock_restored_pending_capture = true;
    }
    // Install publications and resource continuation without advancing either producer.
    _development_fact_country_handles = std::move(restored_handles);
    _development_fact_last_day = std::move(restored_last_day);
    _development_fact_qualified = std::move(restored_qualified);
    _class_opinion_buffers = {};
    _class_opinion_buffers[0] = std::move(restored_opinion);
    _class_opinion_committed_buffer = 0;
    _class_opinion_revision = restored_revision;
    if (!EconomyAuthorityTransfer::restore_continuations(*this, in, error)) return false;
    if (!validate_restored_committed_snapshot(error)) {
        _restore = {};
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::apply_ecp2_authority(
        const RuntimeEconomyEcp2State &in, std::string &error) {
    error.clear();

    if (_epoch_active) {
        error = "restore_requires_committed_boundary";
        return false;
    }

    // Fixed restore flow (stage 4):
    // decode candidate (caller) → semantic validation → backup live →
    // canonical rebuild into candidate scratch → isolated snapshot validation
    // → commit (keep candidate) / atomic rollback via re-apply of backup.
    std::string validate_error;
    if (!validate_ecp2_candidate(in, validate_error)) {
        error = validate_error;
        set_restore_rejected_reason(error);
        return false;
    }

    const uint64_t live_generation = _committed_generation;
    const int64_t live_committed_day = _last_committed_day.get();
    const int64_t live_state_hash =
        _bootstrapped ? state_hash() : 0;

    RuntimeEconomyEcp2State backup;
    bool backup_ready = false;
    if (_bootstrapped) {
        uint32_t capture_flags = ECP2_CAPTURE_ROLLBACK_BACKUP;
        if (_epoch_active) {
            capture_flags |= ECP2_CAPTURE_ALLOW_MID_EPOCH |
                             ECP2_CAPTURE_INCLUDE_RESUME;
        }
        std::string backup_error;
        if (!capture_ecp2_authority(backup, backup_error, capture_flags)) {
            // The backup makes the apply atomic, so a missing one is a real loss --
            // but only for the ONE known situation where the live state is legitimately
            // not capturable yet, and where refusing would make loading a save
            // impossible instead of safer.
            //
            // That situation is the worker bootstrap: `native_simulation_host.cpp`
            // applies the ECP2 bundle to the economy runtime FIRST and installs it into
            // the POD authority afterwards, so this capture reads a live state whose POD
            // mirror is still empty (measured:
            // `[save-shape] market_cell_to_market actual=0 expected=192`). Any OTHER
            // failure -- a genuinely corrupt live state, a mid-apply leftover, a hash
            // mismatch -- still fails closed exactly as before: silently applying over
            // an unknown live state is how a rollback stops meaning anything.
            //
            // Allowlist, not "always": the previous revision skipped the backup on every
            // failure, which is wider than the evidence justified.
            //
            // The two codes that mean "the POD mirror has not been restored yet":
            //   * `economy_save_state_shape_invalid` -- `begin_save` refused because a
            //     derived column was still empty (`market_cell_to_market 0 vs 192`).
            //   * `ecp2_owned_state_capture_invalid:<ledger shape>` -- the owned ledger
            //     could not be validated, i.e. the mirror is half-installed.
            // Both can only happen before the POD state exists; a genuinely corrupt live
            // state has different codes and still fails closed below.
            const bool pod_mirror_not_restored =
                backup_error == "economy_save_state_shape_invalid" ||
                backup_error.rfind("ecp2_owned_state_capture_invalid", 0) == 0;
            if (!pod_mirror_not_restored) {
                error = "ecp2_atomic_backup_failed:" + backup_error;
                set_restore_rejected_reason(error);
                return false;
            }
            _last_restore_backup_skipped_reason = backup_error;
        } else {
            backup_ready = true;
        }
    }

    std::string apply_error;
    if (apply_ecp2_authority_internal(in, apply_error)) {
        _restore_rejected_reason.clear();
        return true;
    }

    // Ensure the restore session is idle before rollback rebuild.
    _restore = {};
    if (backup_ready) {
        std::string rollback_error;
        if (apply_ecp2_authority_internal(backup, rollback_error)) {
            error = apply_error + ";rolled_back";
            // Live committed identity must match the pre-apply snapshot after
            // a successful rollback.
            if (_committed_generation != live_generation ||
                _last_committed_day.get() != live_committed_day ||
                (_bootstrapped && state_hash() != live_state_hash)) {
                error += ";rollback_identity_drift";
            }
        } else {
            error = apply_error + ";rollback_failed:" + rollback_error;
        }
    } else {
        error = apply_error;
    }
    set_restore_rejected_reason(error);
    return false;
}
