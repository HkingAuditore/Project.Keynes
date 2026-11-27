Dictionary DCWorldExt::begin_economy_save(int chunk_bytes) {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->begin_save(chunk_bytes);
}

Dictionary DCWorldExt::begin_economy_forensics_save(int chunk_bytes) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->begin_forensics_save(chunk_bytes);
}

PackedByteArray DCWorldExt::read_economy_save_chunk(int max_bytes) {
    if (_economy_runtime == nullptr) return {};
    return runtime_from(_economy_runtime)->read_save_chunk(max_bytes);
}

Dictionary DCWorldExt::end_economy_save() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->end_save();
}

Dictionary DCWorldExt::capture_economy_ecp2(int flags) const {
    Dictionary out;
    if (_runtime_host && (_runtime_host->state() != RuntimeWorkerState::STOPPED ||
                          !_runtime_host->execution_has_stopped())) {
        out["ok"] = false;
        out["reason"] = "economy_ecp2_requires_stopped_executor";
        return out;
    }
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_runtime_unavailable";
        return out;
    }
    RuntimeEconomyEcp2State state;
    std::string error;
    // The PKSV ecp2 section is written here, after request_runtime_save has
    // published the Country checkpoint for the same save. Under worker
    // Country authority that checkpoint (not the stale attached runtime) is
    // the Country restored on load, so the Economy header must name it.
    NativeEconomyRuntime *economy = runtime_from(_economy_runtime);
    uint64_t country_generation = 0;
    uint64_t country_hash = 0;
    const bool stamp_worker_country = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
        _runtime_host->country_checkpoint_identity(country_generation, country_hash);
    const EconomyAuthorityTransfer::CountryIdentity country_identity{
        country_generation, country_hash};
    const bool captured = EconomyAuthorityTransfer::capture(*economy,
        state, error, static_cast<uint32_t>(std::max(0, flags)),
        stamp_worker_country ? &country_identity : nullptr);
    if (!captured) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    std::vector<uint8_t> encoded;
    if (!encode_ecp2(state, encoded, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    PackedByteArray bytes;
    bytes.resize(static_cast<int64_t>(encoded.size()));
    if (!encoded.empty()) std::memcpy(bytes.ptrw(), encoded.data(), encoded.size());
    out["ok"] = true;
    out["schema_version"] = state.schema_version;
    out["format"] = "ECP2";
    out["authority"] = "economy_owned_state_soa";
    out["authority_domain_mask"] = static_cast<int64_t>(state.authority_domain_mask);
    out["content_hash"] = static_cast<int64_t>(ecp2_wire_hash(bytes));
    out["catalog_hash"] = state.envelope.catalog_hash;
    out["committed_generation"] = static_cast<int64_t>(state.envelope.committed_generation);
    out["committed_day"] = state.envelope.last_committed_day;
    out["current_day"] = state.envelope.current_day;
    out["mid_epoch"] = (state.authority_domain_mask & ECP2_DOMAIN_EPOCH_RESUME) != 0;
    out["resume_stage"] = state.resume.native_stage;
    out["resume_cell_cursor"] = static_cast<int64_t>(state.resume.cell_cursor);
    out["bytes"] = bytes;
    out["byte_count"] = bytes.size();
    return out;
}

Dictionary DCWorldExt::restore_economy_ecp2(const PackedByteArray &bytes) {
    Dictionary out;
    if (_runtime_host && (_runtime_host->state() != RuntimeWorkerState::STOPPED ||
                          !_runtime_host->execution_has_stopped())) {
        out["ok"] = false;
        out["reason"] = "economy_ecp2_requires_stopped_executor";
        return out;
    }
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_runtime_unavailable";
        return out;
    }
    // Reject bare PKEC / ECP1 payloads at the host boundary.
    if (bytes.size() >= 4) {
        const uint32_t marker = static_cast<uint32_t>(bytes[0]) |
            (static_cast<uint32_t>(bytes[1]) << 8u) |
            (static_cast<uint32_t>(bytes[2]) << 16u) |
            (static_cast<uint32_t>(bytes[3]) << 24u);
        if (marker != RUNTIME_ECONOMY_ECP2_MARKER) {
            out["ok"] = false;
            if (marker == 0x31504345u) // "ECP1"
                out["reason"] = "restore_rejects_ecp1";
            else if (marker == 0x43454b50u) // "PKEC"
                out["reason"] = "restore_rejects_pkec";
            else
                out["reason"] = "restore_requires_ecp2";
            out["restore_rejected_reason"] = out["reason"];
            return out;
        }
    } else {
        out["ok"] = false;
        out["reason"] = "restore_requires_ecp2";
        out["restore_rejected_reason"] = out["reason"];
        return out;
    }
    RuntimeEconomyEcp2State state;
    std::string error;
    if (!decode_ecp2(bytes.ptr(), static_cast<size_t>(bytes.size()), state, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        out["restore_rejected_reason"] = out["reason"];
        return out;
    }
    if (!runtime_from(_economy_runtime)->apply_ecp2_authority(state, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        out["restore_rejected_reason"] = String(
            runtime_from(_economy_runtime)->restore_rejected_reason().c_str());
        return out;
    }
    invalidate_economy_input_capture_cache(true);
    invalidate_economy_read_view();
    _economy_read_report_cache = runtime_from(_economy_runtime)->report();
    out["ok"] = true;
    out["schema_version"] = state.schema_version;
    out["format"] = "ECP2";
    out["authority"] = "economy_owned_state_soa";
    out["authority_domain_mask"] = static_cast<int64_t>(state.authority_domain_mask);
    // The decoder has already verified this hash; expose it for audit and
    // save/restore continuity diagnostics.
    out["content_hash"] = static_cast<int64_t>(state.content_hash);
    out["committed_day"] = state.envelope.last_committed_day;
    out["current_day"] = state.envelope.current_day;
    out["mid_epoch"] = (state.authority_domain_mask & ECP2_DOMAIN_EPOCH_RESUME) != 0;
    out["restore_rejected_reason"] = "";
    return out;
}

Dictionary DCWorldExt::begin_economy_restore() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    // Public streaming restore is ECP2-gated: begin_restore no longer clears
    // live state, and feed rejects until an ECP2/migrate path prepares scratch.
    Dictionary out = runtime_from(_economy_runtime)->begin_restore();
    if (static_cast<bool>(out.get("ok", false)))
        invalidate_economy_input_capture_cache(true);
    return out;
}


String DCWorldExt::get_economy_restore_rejected_reason() const {
    if (_economy_runtime == nullptr) return String();
    return String(
        runtime_from(_economy_runtime)->restore_rejected_reason().c_str());
}

Dictionary DCWorldExt::feed_economy_restore_chunk(const PackedByteArray &chunk) {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->feed_restore_chunk(chunk);
}

Dictionary DCWorldExt::end_economy_restore() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    Dictionary out = runtime_from(_economy_runtime)->end_restore();
    invalidate_economy_read_view();
    if (static_cast<bool>(out.get("ok", false))) {
        invalidate_economy_input_capture_cache(true);
        _economy_read_report_cache = runtime_from(_economy_runtime)->report();
    }
    return out;
}
