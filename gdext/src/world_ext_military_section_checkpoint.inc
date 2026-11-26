std::vector<uint8_t> NativeMilitaryRuntime::encode() const {
    const std::vector<uint8_t> core_bytes = core().encode();
    std::vector<uint8_t> out;
    out.reserve(core_bytes.size() + 8 * (_military_pending_intents.size() * 9 + 4) + 64);
    const auto append_u32 = [](std::vector<uint8_t> &buffer, uint32_t value) {
        for (int i = 0; i < 4; ++i) buffer.push_back(static_cast<uint8_t>(value >> (i * 8)));
    };
    const auto append_u64 = [](std::vector<uint8_t> &buffer, uint64_t value) {
        for (int i = 0; i < 8; ++i) buffer.push_back(static_cast<uint8_t>(value >> (i * 8)));
    };
    append_u32(out, kMilitaryBridgeMagic);
    append_u32(out, kMilitaryBridgeWrapperVersion);
    append_u32(out, static_cast<uint32_t>(core_bytes.size()));
    out.insert(out.end(), core_bytes.begin(), core_bytes.end());
    append_u64(out, static_cast<uint64_t>(std::max<int64_t>(0, _military_sequence)));
    append_u64(out, static_cast<uint64_t>(std::max<int64_t>(-1, _military_last_step_day)));
    if (_military_receipts) {
        append_u64(out, static_cast<uint64_t>(
            std::max<int64_t>(0, _military_receipts->after_request_id)));
    } else {
        append_u64(out, 0);
    }
    append_u64(out, _military_pod_request);
    append_u32(out, static_cast<uint32_t>(_military_pending_intents.size()));
    for (const MilitaryPendingIntent &row : _military_pending_intents) {
        append_u32(out, row.kind);
        append_u32(out, static_cast<uint32_t>(row.authority));
        append_u32(out, static_cast<uint32_t>(row.cell));
        append_u32(out, static_cast<uint32_t>(row.good));
        append_u64(out, row.source_id);
        append_u64(out, row.country_handle);
        append_u64(out, static_cast<uint64_t>(row.count));
        append_u64(out, static_cast<uint64_t>(row.amount));
        append_u64(out, static_cast<uint64_t>(row.sequence));
        append_u64(out, static_cast<uint64_t>(row.request_id));
        append_u64(out, static_cast<uint64_t>(row.effective_day));
        append_u32(out, row.receipt_pending);
        append_u64(out, static_cast<uint64_t>(row.target_handle));
        append_u32(out, static_cast<uint32_t>(row.target_signature));
        append_u32(out, static_cast<uint32_t>(row.opcode));
    }
    return out;
}

Dictionary NativeMilitaryRuntime::restore(const PackedByteArray &bytes) {
    if (bytes.is_empty()) return military_fail("pkmi_empty");
    const uint8_t *data = bytes.ptr();
    const size_t size = static_cast<size_t>(bytes.size());
    size_t at = 0;
    const auto read_u32 = [&](uint32_t &value) {
        if (size - at < 4) return false;
        value = 0;
        for (int i = 0; i < 4; ++i) value |= static_cast<uint32_t>(data[at++]) << (i * 8);
        return true;
    };
    const auto read_u64 = [&](uint64_t &value) {
        if (size - at < 8) return false;
        value = 0;
        for (int i = 0; i < 8; ++i) value |= static_cast<uint64_t>(data[at++]) << (i * 8);
        return true;
    };
    uint32_t magic = 0, version = 0, core_size = 0;
    if (!read_u32(magic) || magic != kMilitaryBridgeMagic)
        return military_fail("pkmi_wrapper_magic_invalid");
    if (!read_u32(version) || version != kMilitaryBridgeWrapperVersion)
        return military_fail("pkmi_wrapper_version_mismatch_expected_4");
    if (!read_u32(core_size) || size - at < core_size) return military_fail("pkmi_wrapper_truncated");
    std::string error;
    if (!core().restore(data + at, core_size, error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    at += core_size;
    uint64_t sequence = 0, last_day = 0, receipt_cursor = 0;
    if (!read_u64(sequence) || !read_u64(last_day) || !read_u64(receipt_cursor))
        return military_fail("pkmi_wrapper_truncated");
    _military_sequence = static_cast<int64_t>(std::min<uint64_t>(sequence,
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max())));
    _military_last_step_day = static_cast<int64_t>(last_day);
    if (!_military_receipts) _military_receipts = std::make_unique<MilitaryReceiptCursor>();
    _military_receipts->after_request_id = static_cast<int64_t>(receipt_cursor);
    uint64_t request_cursor = 0; if (!read_u64(request_cursor) || request_cursor == 0) return military_fail("pkmi_request_cursor_invalid"); _military_pod_request = request_cursor;
    uint32_t pending_count = 0;
    if (!read_u32(pending_count) || pending_count > (1u << 20))
        return military_fail("pkmi_pending_invalid");
    _military_pending_intents.clear();
    _military_pending_intents.reserve(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        uint32_t kind = 0, authority = 0, cell = 0, good = 0, receipt_pending = 0;
        uint64_t source_id = 0, country = 0, count = 0, amount = 0, seq = 0, request = 0, day = 0;
        if (!read_u32(kind) || !read_u32(authority) || !read_u32(cell) || !read_u32(good) ||
            !read_u64(source_id) || !read_u64(country) || !read_u64(count) ||
            !read_u64(amount) || !read_u64(seq) || !read_u64(request) || !read_u64(day) ||
            !read_u32(receipt_pending))
            return military_fail("pkmi_wrapper_truncated");
        uint64_t target_handle = 0;
        uint32_t target_signature = 0xffffffffu, opcode = 0;
        if (version >= 2u &&
            (!read_u64(target_handle) || !read_u32(target_signature) || !read_u32(opcode)))
            return military_fail("pkmi_wrapper_truncated");
        MilitaryPendingIntent row;
        row.target_handle = static_cast<int64_t>(target_handle);
        row.target_signature = static_cast<int32_t>(target_signature);
        row.opcode = static_cast<int32_t>(opcode);
        row.kind = static_cast<uint16_t>(kind);
        row.authority = static_cast<uint8_t>(authority);
        row.cell = static_cast<int32_t>(cell);
        row.good = static_cast<int32_t>(good);
        row.source_id = source_id;
        row.country_handle = country;
        row.count = static_cast<int64_t>(count);
        row.amount = static_cast<int64_t>(amount);
        row.sequence = static_cast<int64_t>(seq);
        row.request_id = static_cast<int64_t>(request);
        row.effective_day = static_cast<int64_t>(day);
        row.receipt_pending = static_cast<uint8_t>(receipt_pending);
        _military_pending_intents.push_back(row);
    }
    // Economy settlement fold restarts over the retained trace window; rows
    // are matched by their (saved, monotone) command sequence. v1 rows carry
    // no opcode and resolve through the receipt timeout.
    _military_economy_event_cursor = -1;
    _military_economy_seen_day = -1;
    _military_forced_run_day = -1;
    ++_military_render_revision;
    const MilitaryReport &report = core().report();
    Dictionary out;
    out["ok"] = true;
    out["reason"] = String();
    out["day"] = report.day;
    out["last_step_day"] = _military_last_step_day;
    out["pending_intents"] = static_cast<int64_t>(_military_pending_intents.size());
    out["sequence_cursor"] = _military_sequence;
    out["state_hash"] = static_cast<int64_t>(
        core().state_hash() & 0x7fffffffffffffffll);
    return out;
}

PackedByteArray DCWorldExt::encode_military_state() const {
    if (!_military) return {};
    const auto frame = military_executor_active() ? _military->read() : nullptr;
    const std::vector<uint8_t> wire = frame ? frame->archive : _military->encode();
    PackedByteArray out;
    out.resize(static_cast<int64_t>(wire.size()));
    if (!wire.empty()) std::memcpy(out.ptrw(), wire.data(), wire.size());
    return out;
}

Dictionary DCWorldExt::restore_military_state(const PackedByteArray &bytes) {
    if (!_military) return military_unavailable();
    if (military_executor_active()) return military_fail("military_executor_owns_state");
    auto result = _military->restore_checkpoint(bytes);
    if (bool(result.get("ok", false))) _military_render_selected_army = 0;
    return result;
}
