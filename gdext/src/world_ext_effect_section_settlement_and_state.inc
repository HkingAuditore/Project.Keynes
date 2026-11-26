Dictionary DCWorldExt::settle_split_authority_effects(int64_t day_index) {
    Dictionary out;
    out["ok"] = true;
    out["active"] = false;
    out["settled_transactions"] = 0;
    out["submitted_rows"] = 0;
    out["pending_bindings"] = 0;
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr) {
        out["reason"] = "effect_runtime_unavailable";
        return out;
    }
    if (_runtime_host == nullptr) {
        out["reason"] = "runtime_host_unavailable";
        return out;
    }
    // THE predicate. It is the same one `run_effect_daily` (right above) and
    // `dispatch_effect_native_modifier` (right below) test to decide they have no
    // main-thread work, so the settle and the suppression can never disagree:
    // whenever the adapter ran, the settle is inert.
    if (!_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT)) {
        out["reason"] = "split_settle_effect_not_worker_authoritative";
        return out;
    }
    // 0xFDF (worker EFFECT, main-thread MODIFIER) is a DIFFERENT hole: there the
    // main-thread adapter still owns and applies the rows, so settling would be
    // exactly the double-apply that produced 1.03 squared. Deliberately inert,
    // not half-applied.
    if (!_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER)) {
        out["reason"] = "split_settle_modifier_not_worker_authoritative";
        return out;
    }
    out["active"] = true;
    out["reason"] = String();
    EffectRuntime *effect = runtime_from(_effect_runtime);
    ModifierRuntime *modifier = static_cast<ModifierRuntime *>(_modifier_runtime);

    // ── ACK ─────────────────────────────────────────────────────────────────
    // A row counts as settled only when the WORKER's committed store holds it.
    // The waterline (`committed_day > submitted_day`) makes absence meaningful:
    // before the worker has run a day, "not there yet" and "never applied" are
    // the same observation.
    std::vector<int64_t> confirmed;
    const int32_t pending = effect->worker_modifier_binding_count();
    out["pending_bindings"] = pending;
    if (pending > 0) {
        uint32_t slot = 0;
        if (_runtime_host->try_acquire_modifier_snapshot(0, slot)) {
            const RuntimeModifierPodSnapshot snapshot =
                _runtime_host->modifier_snapshot_buffer(slot);
            for (int32_t index = 0; index < pending; ++index) {
                const EffectRuntime::ModifierBinding *binding =
                    effect->worker_modifier_binding(index);
                if (binding == nullptr || binding->row_count <= 0) continue;
                if (snapshot.committed_day <= binding->submitted_day) continue;
                bool all = true;
                for (int32_t offset = 0; offset < binding->row_count; ++offset) {
                    const EffectRuntime::ModifierRow *row = effect->worker_modifier_row(
                        binding->row_begin + offset);
                    if (row == nullptr) { all = false; break; }
                    const int32_t definition_id =
                        modifier->definition_id_for_key(row->definition_key);
                    bool present = false;
                    for (const RuntimeModifierPodEntry &entry : snapshot.entries) {
                        if (entry.modifier_handle == 0) continue;
                        if (entry.domain != static_cast<uint32_t>(row->domain)) continue;
                        if (entry.definition_id != definition_id) continue;
                        if (entry.scope != row->scope) continue;
                        if (entry.entity_handle != row->entity_handle) continue;
                        if (entry.group_handle != row->group_handle) continue;
                        if (entry.source_type != row->source_type) continue;
                        if (entry.source_id != row->source_id) continue;
                        present = true;
                        break;
                    }
                    if (present != row->expect_present) { all = false; break; }
                }
                if (all) confirmed.push_back(binding->transaction_id);
            }
            _runtime_host->release_modifier_snapshot(slot);
        }
    }
    if (!confirmed.empty())
        out["settled_transactions"] = effect->acknowledge_worker_modifier_rows(confirmed);

    // ── SUBMIT ──────────────────────────────────────────────────────────────
    // The rows are mapped by `EffectRuntime::map_modifier_row` -- the same
    // function `dispatch_native_modifier` uses -- and enqueued through the
    // production Modifier ingress, so there is no second encoder either.
    std::vector<EffectRuntime::ModifierBinding> bindings;
    // The submission watermark must not run ahead of what the worker has actually
    // committed, or the ACK waterline (`committed_day > submitted_day`) could
    // never be reached on a main thread that runs ahead of the worker.
    const int64_t settle_day = std::min<int64_t>(day_index, effect->committed_day());
    const std::vector<EffectRuntime::ModifierRow> rows =
        effect->collect_worker_modifier_rows(settle_day, bindings);
    if (rows.empty()) return out;
    PackedInt32Array opcodes, producers, domains, scopes, durations, stacks, magnitudes;
    PackedInt64Array sequences, days, entities, groups, source_types, source_ids, handles;
    PackedStringArray definition_keys;
    for (const EffectRuntime::ModifierRow &row : rows) {
        opcodes.push_back(row.opcode);
        producers.push_back(row.producer);
        sequences.push_back(row.sequence);
        days.push_back(row.effective_day);
        definition_keys.push_back(String(row.definition_key.c_str()));
        domains.push_back(row.domain);
        scopes.push_back(row.scope);
        entities.push_back(static_cast<int64_t>(row.entity_handle));
        groups.push_back(static_cast<int64_t>(row.group_handle));
        source_types.push_back(static_cast<int64_t>(row.source_type));
        source_ids.push_back(static_cast<int64_t>(row.source_id));
        durations.push_back(row.duration_days);
        stacks.push_back(row.stacks);
        magnitudes.push_back(row.magnitude_q16);
        handles.push_back(0);
    }
    Dictionary batch;
    batch["opcodes"] = opcodes;
    batch["producer_ids"] = producers;
    batch["sequences"] = sequences;
    batch["effective_days"] = days;
    batch["definition_keys"] = definition_keys;
    batch["domains"] = domains;
    batch["scopes"] = scopes;
    batch["entity_handles"] = entities;
    batch["group_handles"] = groups;
    batch["source_types"] = source_types;
    batch["source_ids"] = source_ids;
    batch["duration_days"] = durations;
    batch["stacks"] = stacks;
    batch["magnitude_q16"] = magnitudes;
    batch["modifier_handles"] = handles;
    // A settled row is valid on whichever day the worker lands it; binding it to
    // the environment generation observed here would let the worker's staleness
    // check drop it.
    batch["unbound_input_generation"] = true;
    const Dictionary submitted = submit_modifier_commands(batch);
    if (!bool(submitted.get("ok", false))) {
        std::vector<int64_t> failed;
        failed.reserve(bindings.size());
        for (const EffectRuntime::ModifierBinding &binding : bindings)
            failed.push_back(binding.transaction_id);
        effect->discard_worker_modifier_rows(failed);
        out["ok"] = false;
        out["reason"] = submitted.get("reason", "split_settle_modifier_enqueue_failed");
        return out;
    }
    out["submitted_rows"] = static_cast<int64_t>(rows.size());
    return out;
}

Dictionary DCWorldExt::apply_runtime_effect_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["applied"] = false;
    if (_effect_runtime == nullptr || _runtime_host == nullptr) {
        out["code"] = "effect_runtime_unavailable";
        return out;
    }
    if (_runtime_host->effect_adapter_owned()) {
        out["ok"] = true;
        out["code"] = "effect_adapter_executor_owned";
        return out;
    }
    if (!_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT)) {
        out["code"] = "effect_not_worker_authoritative";
        return out;
    }
    // Production hook #1 for the split settle: this is the one main-thread call
    // that runs every frame under 0xFEF (the worker owns EFFECT, so the ideology
    // equip's batch is planned here and has no other settler). It runs BEFORE the
    // write-back, which is safe because `apply_pod_snapshot` preserves both the
    // ideology batches and the rows this settles.
    out["split_settle"] = settle_split_authority_effects(
        _effect_runtime != nullptr
            ? runtime_from(_effect_runtime)->committed_day()
            : int64_t{0});
    // Worker Economy holds this boundary for the whole day and may enqueue
    // colonization/canal builtins into the shared EffectRuntime. Skip apply
    // while the day is inflight; the host keeps the same after_generation and
    // retries on the next main-thread tick.
    auto boundary_lock = _runtime_host->try_lock_economy_input_capture();
    if (!boundary_lock.owns_lock()) {
        out["ok"] = true;
        out["code"] = "economy_day_inflight";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_effect_snapshot(cursor, slot)) {
        out["ok"] = true;
        out["code"] = "effect_snapshot_unavailable";
        return out;
    }
    // Copy out of the ring before apply so a concurrent worker publish that
    // steals a READY slot cannot mutate vectors under the legacy rebuild.
    const RuntimeEffectPodSnapshot snapshot =
        _runtime_host->effect_snapshot_buffer(slot);
    const int64_t generation = static_cast<int64_t>(snapshot.generation);
    _runtime_host->release_effect_snapshot(slot);
    std::string apply_error;
    const bool applied = runtime_from(_effect_runtime)->apply_pod_snapshot(
        snapshot, apply_error);
    out["ok"] = applied;
    out["applied"] = applied;
    out["generation"] = generation;
    out["code"] = applied ? "ok" : String(apply_error.c_str());
    return out;
}

Dictionary DCWorldExt::dispatch_effect_native_modifier() {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT)) {
        Dictionary out;
        out["ok"] = true;
        out["suppressed"] = true;
        out["path"] = "EFFECT_WORKER";
        // Production hook #2: exactly the call that WOULD have drained the rows if
        // the adapter were live. Under split authority it is suppressed, so the
        // settle takes its place -- guarded by the same EFFECT predicate above.
        out["split_settle"] = settle_split_authority_effects(
            _effect_runtime != nullptr
                ? runtime_from(_effect_runtime)->committed_day()
                : int64_t{0});
        return out;
    }
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_modifier(
        static_cast<ModifierRuntime *>(_modifier_runtime));
}

Dictionary DCWorldExt::ack_effect_native_modifier() {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT)) {
        Dictionary out;
        out["ok"] = true;
        out["suppressed"] = true;
        out["path"] = "EFFECT_WORKER";
        return out;
    }
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_modifier(
        static_cast<ModifierRuntime *>(_modifier_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_country() {
    // Do not suppress under EFFECT worker authority. Catalog Effect evaluation
    // may be worker-owned, but family colonization CLAIM+SETTLE transactions are
    // enqueued onto the main EffectRuntime from Economy. Skipping this adapter
    // leaves expeditions stuck in SETTLING forever.
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    // Same worker boundary as the Economy twin below: the worker owns
    // NativeEconomyRuntime while it runs a day and pulls SETTLE through this
    // same EffectRuntime, so an idle-boundary pass from this thread races it.
    // Never block (the worker may be parked on main-thread input); a deferred
    // call is retried by the next runtime-graph adapter pass.
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) {
            return economy_adapter_deferred();
        }
    }
    return dispatch_effect_native_country_unlocked();
}

Dictionary DCWorldExt::dispatch_effect_native_country_unlocked() {
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr && _runtime_host->effect_adapter_owned())
        return Dictionary();
    return runtime_from(_effect_runtime)->dispatch_native_country(
        static_cast<NativeCountryRuntime *>(_country_runtime));
}

Dictionary DCWorldExt::ack_effect_native_country() {
    // Mirror dispatch_effect_native_country: Host receipt drain must keep
    // running for externally enqueued Country commands under EFFECT ACTIVE.
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    // Same boundary as dispatch: ACK rewrites EffectRuntime bindings that the
    // worker's SETTLE pull also touches.
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) {
            return economy_adapter_deferred();
        }
    }
    return ack_effect_native_country_unlocked();
}

Dictionary DCWorldExt::ack_effect_native_country_unlocked() {
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr && _runtime_host->effect_adapter_owned())
        return Dictionary();
    return runtime_from(_effect_runtime)->ack_native_country(
        static_cast<NativeCountryRuntime *>(_country_runtime));
}

Dictionary DCWorldExt::settle_orphaned_effect_native_country_acks() {
    if (_effect_runtime == nullptr) return unavailable();
    // Soft-settle also drains Country receipts, so it needs the same boundary.
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) {
            return economy_adapter_deferred();
        }
    }
    return settle_orphaned_effect_native_country_acks_unlocked();
}

Dictionary DCWorldExt::settle_orphaned_effect_native_country_acks_unlocked() {
    if (_effect_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr && _runtime_host->effect_adapter_owned())
        return Dictionary();
    return runtime_from(_effect_runtime)->settle_orphaned_native_country_acks();
}

Dictionary DCWorldExt::dispatch_effect_native_economy() {
    // Same exception as Country: colonization SETTLE waits on this adapter and
    // is not covered by the EFFECT POD worker plan stage.
    if (_effect_runtime == nullptr || _economy_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr && _runtime_host->effect_adapter_owned())
        return Dictionary();
    // Under Economy worker execution the worker mutates NativeEconomyRuntime
    // and pulls SETTLE through this same EffectRuntime inside its day
    // transaction. An idle-boundary SETTLE applied from this thread races the
    // worker's epoch-begin audit (opening totals vs shadow) and trips
    // incremental_audit_mismatch. Enter only between worker days; never block,
    // the worker may hold the boundary while parked on main-thread input. A
    // deferred call is replayed by the next input capture, which holds the
    // boundary.
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) {
            return economy_adapter_deferred();
        }
    }
    return dispatch_effect_native_economy_unlocked();
}

Dictionary DCWorldExt::dispatch_effect_native_economy_unlocked() {
    return runtime_from(_effect_runtime)->dispatch_native_economy(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
}

Dictionary DCWorldExt::ack_effect_native_economy() {
    if (_effect_runtime == nullptr || _economy_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr && _runtime_host->effect_adapter_owned())
        return Dictionary();
    // Same worker boundary as dispatch: ACK reads Economy effect results and
    // rewrites EffectRuntime bindings the worker's SETTLE pull also touches.
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) {
            return economy_adapter_deferred();
        }
    }
    return ack_effect_native_economy_unlocked();
}

Dictionary DCWorldExt::ack_effect_native_economy_unlocked() {
    return runtime_from(_effect_runtime)->ack_native_economy(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_gameplay() {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT)) {
        Dictionary out;
        out["ok"] = true;
        out["suppressed"] = true;
        out["path"] = "EFFECT_WORKER";
        return out;
    }
    if (_effect_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_gameplay(this);
}

Dictionary DCWorldExt::ack_effect_native_gameplay() {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT)) {
        Dictionary out;
        out["ok"] = true;
        out["suppressed"] = true;
        out["path"] = "EFFECT_WORKER";
        return out;
    }
    if (_effect_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_gameplay(this);
}

Dictionary DCWorldExt::get_effect_native_adapter_report() const {
    if (_runtime_host && _runtime_host->effect_adapter_owned()) {
        const auto view = _runtime_host->latest_effect_read_view();
        return view ? view->adapters.duplicate(false) : Dictionary();
    }
    Dictionary out;
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) {
            // Economy worker is mid-day and may be mutating the shared
            // EffectRuntime/Economy queues; report non-idle so the caller
            // queues a retry rather than racing or skipping the adapter pass.
            out["deferred"] = true;
            out["country_pending"] = false;
            out["economy_pending"] = false;
            out["gameplay_pending"] = false;
            out["colonization_pending"] = false;
            out["country_pending_count"] = 0;
            out["economy_pending_count"] = 0;
            out["gameplay_pending_count"] = 0;
            out["idle"] = false;
            return out;
        }
    }
    const bool country_pending = _country_runtime != nullptr &&
        static_cast<const NativeCountryRuntime *>(_country_runtime)
            ->has_pending_effect_commands();
    const bool economy_pending = _economy_runtime != nullptr &&
        static_cast<const NativeEconomyRuntime *>(_economy_runtime)
            ->has_pending_effect_commands();
    const bool gameplay_pending = !_effect_gameplay_commands.empty();
    const bool colonization_pending = _effect_runtime != nullptr &&
        runtime_from(_effect_runtime)->has_pending_family_colonization_transactions();
    out["country_pending"] = country_pending;
    out["economy_pending"] = economy_pending;
    out["gameplay_pending"] = gameplay_pending;
    out["colonization_pending"] = colonization_pending;
    out["country_pending_count"] = country_pending ? 1 : 0;
    out["economy_pending_count"] = economy_pending ? 1 : 0;
    out["gameplay_pending_count"] = static_cast<int64_t>(
        _effect_gameplay_commands.size());
    out["idle"] = !country_pending && !economy_pending && !gameplay_pending &&
        !colonization_pending;
    return out;
}

bool DCWorldExt::effect_should_run(int64_t day_index) const {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT)) {
        return false;
    }
    return _effect_runtime != nullptr &&
        runtime_from(_effect_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::poll_effect_transactions(int64_t after_transaction_id,
                                                int limit) const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->poll_transactions(after_transaction_id, limit);
}

Dictionary DCWorldExt::preflight_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->preflight_transactions(batch);
}

Dictionary DCWorldExt::commit_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->commit_transactions(batch);
}

Dictionary DCWorldExt::ack_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->ack_transactions(batch);
}

Dictionary DCWorldExt::explain_effect(int64_t instance_id) const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->explain(instance_id);
}

Dictionary DCWorldExt::get_effect_report() const {
    if (_runtime_host && _runtime_host->effect_adapter_owned()) {
        const auto view = _runtime_host->latest_effect_read_view();
        return view ? view->report.duplicate(false) : Dictionary();
    }
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->report();
}

PackedByteArray DCWorldExt::capture_effect_state() const {
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host && _runtime_host->effect_adapter_owned()) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) return PackedByteArray();
    }
    return _effect_runtime == nullptr ? PackedByteArray()
        : runtime_from(_effect_runtime)->capture();
}

Dictionary DCWorldExt::restore_effect_state(const PackedByteArray &bytes) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->restore(bytes);
}

Dictionary DCWorldExt::clear_effect_state() {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->clear_state();
}
