Dictionary DCWorldExt::get_economy_event_schema() const {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->event_schema();
}

Dictionary DCWorldExt::set_economy_trace_filter(const Dictionary &filter) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->set_trace_filter(filter);
}

Dictionary DCWorldExt::set_economy_inspector_trace_cell(int cell_idx) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->set_inspector_trace_cell(cell_idx);
}

Dictionary DCWorldExt::poll_economy_events(const Dictionary &opts) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    // The committed event-batch deque is pushed/evicted by the economy owner
    // thread at every epoch publish. When the worker owns economy execution,
    // walking it from the main thread without the authority boundary is a data
    // race (intermittent access violation in poll_events). Read it only while
    // holding the boundary between epochs; otherwise report an empty, busy
    // page — consumers keep their cursor and retry next frame.
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        std::unique_lock<std::mutex> boundary;
        if (!economy_live_readable(_runtime_host.get(), runtime, boundary)) {
            Dictionary out;
            out["ok"] = true;
            out["busy"] = true;
            out["count"] = 0;
            out["event_id"] = PackedInt64Array();
            out["kind"] = PackedInt32Array();
            out["last_event_id"] = static_cast<int64_t>(
                opts.get("after_event_id", 0));
            out["consumer_id"] = opts.get("consumer_id", StringName("default"));
            out["gap"] = false;
            return out;
        }
        return runtime->poll_events(opts);
    }
    return runtime->poll_events(opts);
}

Dictionary DCWorldExt::ack_economy_events(StringName consumer_id,
                                          int64_t up_to_event_id) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->ack_events(consumer_id, up_to_event_id);
}

Dictionary DCWorldExt::get_economy_trace_report() const {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->trace_report();
}

Dictionary DCWorldExt::begin_economy_event_archive(int chunk_bytes) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->begin_event_archive(chunk_bytes);
}

PackedByteArray DCWorldExt::read_economy_event_archive_chunk(int max_bytes) {
    return _economy_runtime == nullptr ? PackedByteArray()
        : runtime_from(_economy_runtime)->read_event_archive_chunk(max_bytes);
}

Dictionary DCWorldExt::end_economy_event_archive() {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->end_event_archive();
}
