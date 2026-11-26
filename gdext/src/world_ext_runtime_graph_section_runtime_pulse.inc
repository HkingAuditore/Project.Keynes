int64_t DCWorldExt::advance_runtime_pulse(int64_t day, double season_phase,
                                          double speed_scale, int budget_us,
                                          int flags) {
    const auto started = Clock::now();
    ++_runtime_graph_abi_calls;
    if (!_runtime_graph_configured || !_runtime_graph_enabled) {
        sync_runtime_domain_ownership();
        _runtime_graph_last_status = 0;
        _runtime_graph_last_elapsed_us = elapsed_us(started);
        return make_token(day, 0, _runtime_graph_dirty_mask,
                          static_cast<uint32_t>(flags));
    }

    _runtime_graph_day = day;
    const int limit_us = std::max(250, budget_us);
    uint32_t status = 1; // progressed
    uint32_t work = 0;
    uint32_t dirty = 0;
    int iterations = 0;

    auto over_budget = [&]() {
        return static_cast<int>(elapsed_us(started)) >= limit_us;
    };
    auto ctx_for = [&]() {
        Dictionary ctx;
        ctx["day_index"] = day;
        ctx["tick_index"] = static_cast<int64_t>(_runtime_graph_pulse_count);
        ctx["season_phase"] = season_phase;
        ctx["speed_scale"] = speed_scale;
        ctx["slice_budget_ms"] = static_cast<double>(limit_us) / 1000.0;
        ctx["source"] = StringName("native_runtime_graph");
        return ctx;
    };
    auto ran = [&](const Dictionary &result, uint32_t family) {
        ++work;
        const int64_t changed = static_cast<int64_t>(result.get("changed_cells", 0));
        const int64_t changed_countries =
            static_cast<int64_t>(result.get("changed_countries", 0));
        if (changed > 0 || changed_countries > 0 ||
            bool(result.get("published_to_slot", false))) dirty |= family;
        if (bool(result.get("done", false))) status = 2;
    };

    auto ingest_trigger_events = [&]() {
        if (_trigger_runtime == nullptr) return uint32_t{0};
        TriggerRuntime *trigger = static_cast<TriggerRuntime *>(_trigger_runtime);
        const StringName consumer("trigger_runtime");
        const int64_t *stored_cursor = _gameplay_consumer_ack.getptr(consumer);
        int64_t cursor = stored_cursor != nullptr ? *stored_cursor : int64_t{0};
        uint32_t ingested = 0;
        for (const GameplayEventRecord &event : _gameplay_events) {
            if (event.event_id <= cursor) continue;
            TriggerRuntime::EventInput input;
            input.source_id = event.source;
            input.event_id = event.event_id;
            input.day = day;
            input.event_type = event.type;
            input.payload_schema = event.payload_schema;
            input.entity_handle = event.entity_handle != 0
                ? event.entity_handle : static_cast<uint64_t>(std::max(0, event.entity_id));
            input.group_handle = static_cast<uint64_t>(std::max(0, event.cell_idx));
            input.value = event.value_i64;
            input.payload = {event.payload_i0, event.payload_i1,
                             event.payload_i2, event.payload_i3};
            // H8: mirror the same committed fact onto the Trigger POD lane. The
            // worker dedupes by source cursor, so this is safe in SHADOW too,
            // and under ACTIVE it is the only way the worker sees the journal.
            if (_runtime_host != nullptr) {
                RuntimeTriggerCommand command;
                command.request_id = g_graph_trigger_request_id.fetch_add(
                    1, std::memory_order_relaxed);
                command.producer_id = 2u;
                command.sequence = g_graph_trigger_sequence.fetch_add(
                    1, std::memory_order_relaxed);
                command.opcode = RuntimeTriggerCommandOpcode::INGEST_EVENT;
                command.requested_day = day;
                command.effective_day = day;
                command.event.source_id = input.source_id;
                command.event.event_id = input.event_id;
                command.event.day = input.day;
                command.event.event_type = input.event_type;
                command.event.payload_schema = input.payload_schema;
                command.event.entity_handle = input.entity_handle;
                command.event.group_handle = input.group_handle;
                command.event.value = input.value;
                command.event.payload = input.payload;
                std::string queue_error;
                if (!_runtime_host->queue_trigger_pod_command(command, queue_error))
                    break;
            }
            if (trigger_worker_authoritative()) {
                // Sole writer: the worker owns ingest, so do not stage the same
                // event in the facade — the snapshot write-back would then
                // disagree with a facade that saw it twice.
                cursor = input.event_id;
                ++ingested;
                if (ingested >= 512) break;
                continue;
            }
            size_t accepted = 0;
            int64_t last_accepted = 0;
            std::string error;
            if (!trigger->submit_events_pod(&input, 1, accepted,
                                            last_accepted, error) || accepted != 1) {
                break;
            }
            cursor = last_accepted;
            ++ingested;
            if (ingested >= 512) break;
        }
        if (ingested > 0) _gameplay_consumer_ack[consumer] = cursor;
        return ingested;
    };

    // TriggerRuntime::should_run() stays true while its effect queue is not
    // empty. When handoff refuses the head effect (no native adapter for that
    // action, or a peer runtime rejected it) the queue can never drain, and
    // re-entering trigger every iteration burns the whole pulse budget on an
    // effect that will be refused again. Retire trigger for the rest of this
    // pulse as soon as handoff reports blocked, and keep the reason for
    // diagnostics.
    bool trigger_handoff_blocked = false;
    bool country_peer_adapter_fault = false;

    auto service_country_peer_adapter = [&]() {
        if (!_runtime_graph_country_peer_adapter_enabled ||
            _country_runtime == nullptr)
            return uint32_t{0};
        NativeCountryRuntime *country =
            static_cast<NativeCountryRuntime *>(_country_runtime);
        if (!country->peer_async_mode()) country->set_peer_async_mode(true);
        NativeCountryRuntime::PeerAdapterServiceReport peer_report;
        std::string peer_error;
        ++_runtime_graph_country_peer_service_calls;
        if (!country->service_peer_intents_main_thread(
                64, peer_report, peer_error)) {
            ++_runtime_graph_country_peer_faults;
            _runtime_graph_country_peer_fault_reason = peer_error.empty()
                ? "country_peer_adapter_service_failed" : peer_error;
            country_peer_adapter_fault = true;
            return uint32_t{0};
        }
        _runtime_graph_country_peer_intents += peer_report.inspected;
        _runtime_graph_country_peer_completed += peer_report.completed;
        _runtime_graph_country_peer_pending += peer_report.pending;
        _runtime_graph_country_peer_rejected += peer_report.rejected;
        if (peer_report.rejected > 0)
            _runtime_graph_country_peer_fault_reason = peer_report.last_reason;
        return peer_report.inspected;
    };

    // Apply Country/Economy ownership before any should_run / economy gate. If
    // the pulse loop never iterates (budget already spent), peers still must
    // see sync_store_writes_forbidden so they do not wait on a dead facade.
    const bool country_worker_authoritative = _runtime_host != nullptr &&
        (_runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::COUNTRY) ||
         _runtime_host->country_authority_owner_is_worker());
    const bool economy_worker_authoritative = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY);
    // 主线程是否停推某域：含授权窗口（已请求、worker 首日未提交）。下面的日推进和
    // 日屏障都用它；Economy 输入捕获仍只看已生效授权。
    const auto suppressed = [&](RuntimeDomainId domain) {
        return _runtime_host != nullptr &&
            _runtime_host->domain_main_thread_suppressed(domain);
    };
    sync_runtime_domain_ownership();
    // Worker ACTIVE owns economy mutation via compact slices, but MapData /
    // DataCore environment + building context still live on the main thread.
    // Capture frozen input lanes here; do not run mutation stages.
    if (economy_worker_authoritative && _economy_runtime != nullptr) {
        auto capture_day = [&](int64_t capture_day_index) {
            Dictionary cap = capture_economy_day_inputs(capture_day_index);
            if (bool(cap.get("fatal", false))) {
                _runtime_graph_last_economy_report = cap;
                _runtime_graph_economy_capture_fatal_reason =
                    String(cap.get("fatal_reason", "economy_day_input_capture_failed"))
                        .utf8()
                        .get_data();
            } else if (!_runtime_graph_economy_capture_fatal_reason.empty() &&
                       bool(cap.get("ok", false))) {
                _runtime_graph_economy_capture_fatal_reason.clear();
            }
            return cap;
        };
        capture_day(day);
        if (_runtime_host != nullptr) {
            const RuntimeThreadReport host = _runtime_host->report();
            const int64_t need = std::max(
                day,
                std::max(host.economy_pod_committed_day + 1,
                         host.economy_pod_epoch_sample_day));
            auto *economy =
                static_cast<NativeEconomyRuntime *>(_economy_runtime);
            if (need != day && economy->needs_environment_capture(need))
                capture_day(need);
        }
        // Sparse-workset probe. The graph never runs the compact economy slice
        // while the worker owns the domain, so `_runtime_graph_last_economy_report`
        // used to stay empty and the headless CSV lost every economy column.
        // Publish the worker-owned runtime's scalar probe snapshot instead;
        // it reads counters only and never mutates settlement state.
        if (_runtime_graph_economy_capture_fatal_reason.empty()) {
            auto *probe_runtime =
                static_cast<NativeEconomyRuntime *>(_economy_runtime);
            _runtime_graph_last_economy_report = probe_runtime->probe_report();
        }
    }

    // Hand every new committed Economy opinion revision to the worker before
    // the budgeted loop. The Economy capture above can spend the whole pulse
    // budget; a publish placed only inside the loop then never runs and the
    // worker Ideology stage keeps skipping days awaiting the opinion.
    if (_ideology_runtime != nullptr && _economy_runtime != nullptr &&
        _runtime_host != nullptr && !_runtime_host->effect_adapter_owned() &&
        static_cast<NativeEconomyRuntime *>(_economy_runtime)
                ->country_class_opinion_snapshot().revision !=
            _ideology_opinion_published_revision) {
        publish_ideology_worker_inputs();
    }

    // Stable order mirrors the existing GDScript ACK chain and scheduler
    // priorities. Each runtime owns its own persistent range cursor.
    while (iterations++ < 64 && !over_budget()) {
        bool progressed = false;
        Dictionary ctx = ctx_for();
        if (!country_worker_authoritative && !suppressed(RuntimeDomainId::COUNTRY) &&
            _country_runtime != nullptr &&
            static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_country();
            Dictionary country_result = run_country_slice(ctx);
            uint32_t country_dirty = DIRTY_COUNTRY_STATE;
            if (static_cast<int64_t>(country_result.get("changed_cells", 0)) > 0)
                country_dirty |= DIRTY_COUNTRY_TERRITORY | DIRTY_OVERLAY;
            ran(country_result, country_dirty);
            if (_effect_runtime != nullptr) ack_effect_native_country();
            progressed = true;
        }
        const uint32_t peer_work_before = service_country_peer_adapter();
        if (peer_work_before > 0) {
            work += peer_work_before;
            progressed = true;
        }
        if (country_peer_adapter_fault) break;
        if (over_budget()) break;
        const uint32_t ingested_events = ingest_trigger_events();
        if (ingested_events > 0) {
            work += ingested_events;
            progressed = true;
        }
        // H8: under worker authority the worker runs the aggregation/emission
        // day. The main thread stays the Trigger->Effect delivery cursor owner.
        // Gate handoff on a non-empty facade effect queue after writeback — not
        // on should_run()'s day-lag clause, which stays hot whenever the facade
        // clock trails the worker and would re-enter every pulse for nothing.
        const bool trigger_worker_owns_day = suppressed(RuntimeDomainId::TRIGGER_INPUT);
        TriggerRuntime *trigger_runtime = _trigger_runtime != nullptr
            ? static_cast<TriggerRuntime *>(_trigger_runtime) : nullptr;
        const bool trigger_facade_due = trigger_runtime != nullptr &&
            (!_runtime_host || !_runtime_host->effect_adapter_owned()) &&
            (trigger_worker_owns_day
                ? trigger_runtime->pending_effect_count() > 0
                : trigger_runtime->should_run(day));
        if (trigger_runtime != nullptr && !trigger_handoff_blocked &&
            trigger_facade_due) {
            if (!trigger_worker_owns_day) {
                ran(run_trigger_daily(day), DIRTY_EVENTS);
                progressed = true;
            }
            if (_effect_runtime != nullptr) {
                const Dictionary handoff = handoff_trigger_effects(512);
                const int64_t handed_off =
                    static_cast<int64_t>(handoff.get("handed_off", 0));
                if (handed_off > 0) {
                    work += static_cast<uint32_t>(handed_off);
                    dirty |= DIRTY_EVENTS;
                    progressed = true;
                }
                if (bool(handoff.get("blocked", false))) {
                    trigger_handoff_blocked = true;
                    const std::string reason =
                        String(handoff.get("reason", "trigger_effect_handoff_blocked"))
                            .utf8().get_data();
                    const String command_key =
                        String(handoff.get("blocked_command_key", ""));
                    const String definition_key =
                        String(handoff.get("blocked_definition_key", ""));
                    std::string snapshot_reason = reason;
                    if (!command_key.is_empty()) {
                        snapshot_reason += ":";
                        snapshot_reason += command_key.utf8().get_data();
                        snapshot_reason += "/";
                        snapshot_reason += definition_key.utf8().get_data();
                    }
                    if (snapshot_reason != _runtime_graph_trigger_blocked_reason) {
                        _runtime_graph_trigger_blocked_reason = snapshot_reason;
                        UtilityFunctions::push_warning(
                            String("[sim/graph-trigger] handoff blocked day=") +
                            String::num_int64(day) + String(" reason=") +
                            String(reason.c_str()) +
                            String(" command_key=") + command_key +
                            String(" definition_key=") + definition_key +
                            String(" action=") +
                            String::num_int64(int64_t(handoff.get("blocked_action", 0))) +
                            String(" opcode=") +
                            String::num_int64(int64_t(handoff.get("blocked_opcode", 0))) +
                            String(" — trigger effect queue cannot drain; "
                                   "trigger is retired for the rest of each pulse"));
                    }
                }
            }
        }
        if (over_budget()) break;
        // Publish the last committed Economy opinion before synchronous
        // Ideology runs. Economy settles later in this graph, so the worker
        // cannot form an Ideology<->Economy same-day cycle.
        if (_ideology_runtime != nullptr && _economy_runtime != nullptr &&
            _runtime_host != nullptr && !_runtime_host->effect_adapter_owned()) {
            publish_ideology_worker_inputs();
        }
        // G8: publish_ideology_worker_inputs above still runs under worker
        // authority — the worker needs the opinion snapshot either way — but
        // the synchronous day must not.
        const bool ideology_worker_authoritative = suppressed(RuntimeDomainId::IDEOLOGY);
        if (!ideology_worker_authoritative && _ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day)) {
            ran(run_ideology_daily(day), DIRTY_COUNTRY_STATE | DIRTY_EVENTS);
            progressed = true;
        }
        if (over_budget()) break;
        if (_effect_runtime != nullptr) {
            const bool effect_worker_authoritative = suppressed(RuntimeDomainId::EFFECT);
            if (!effect_worker_authoritative &&
                static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) {
                ran(run_effect_daily(day), DIRTY_EVENTS);
                if (!suppressed(RuntimeDomainId::MODIFIER)) {
                    dispatch_effect_native_modifier();
                }
                dispatch_effect_native_gameplay();
                progressed = true;
            }
            // Always dispatch/ACK Country+Economy native adapters. Family
            // colonization enqueues CLAIM+SETTLE onto main EffectRuntime from
            // Economy; EFFECT POD worker evaluation does not cover those
            // program_id=-1 transactions. Skipping dispatch under EFFECT
            // worker authority left expeditions stuck in SETTLING.
            dispatch_effect_native_country();
            dispatch_effect_native_economy();
            // Drain Host Country receipts first. Under COUNTRY worker authority
            // Climate park + hard_ack can otherwise deadlock; after a real drain
            // soft-settle leftovers so founder PREFLIGHTED cannot pin the clock.
            ack_effect_native_country();
            if (country_worker_authoritative)
                settle_orphaned_effect_native_country_acks();
            // Second Economy pass: SETTLE may only proceed after Country CLAIM
            // ACK from the drain/soft-settle above.
            dispatch_effect_native_economy();
            ack_effect_native_economy();
            if (!effect_worker_authoritative) {
                if (!suppressed(RuntimeDomainId::MODIFIER)) {
                    ack_effect_native_modifier();
                }
                ack_effect_native_gameplay();
            }
        }
        if (over_budget()) break;
        const bool modifier_worker_authoritative = suppressed(RuntimeDomainId::MODIFIER);
        if (!modifier_worker_authoritative && _modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_modifier();
            ran(run_modifier_daily(day), DIRTY_COUNTRY_STATE);
            if (_effect_runtime != nullptr) ack_effect_native_modifier();
            progressed = true;
        }
        const uint32_t peer_work_after = service_country_peer_adapter();
        if (peer_work_after > 0) {
            work += peer_work_after;
            progressed = true;
        }
        if (country_peer_adapter_fault) break;
        if (over_budget()) break;
        if (_effect_runtime != nullptr && gameplay_effect_should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_gameplay();
            ran(run_gameplay_effects(day), DIRTY_EVENTS | DIRTY_OVERLAY);
            if (_effect_runtime != nullptr) ack_effect_native_gameplay();
            progressed = true;
        }
        // Economy is the terminal hard-domain in this deterministic chain. A
        // busy Effect/ACK queue may consume the pulse budget, but it must not
        // starve an overdue economy range forever. Let one native economy
        // slice start after the ordered ACK dispatch; the slice itself owns
        // its cursor and the next loop/pulse will resume from that boundary.
        // Economy ACTIVE is owned by NativeSimulationHost's worker.  The
        // runtime graph only captures the frozen input lane above; running the
        // compact mutation slice here would create a second writer on the
        // same NativeEconomyRuntime and can execute an unpreemptible economy
        // range on the main thread.
        if (!suppressed(RuntimeDomainId::ECONOMY) &&
            _economy_runtime != nullptr && economy_should_run(day)) {
            if (_effect_runtime != nullptr) dispatch_effect_native_economy();
            Dictionary economy_result = run_economy_slice_compact(ctx);
            ++_runtime_graph_economy_slices;
            if (bool(economy_result.get("done", false)))
                ++_runtime_graph_economy_commits;
            ran(economy_result, DIRTY_ECONOMY_UI);
            if (_effect_runtime != nullptr) ack_effect_native_economy();
            // Incomplete slices keep the last committed/full diagnostic snapshot.
            // Overwriting every compact cursor slice re-copies a large Dictionary
            // across the pulse boundary for no publish benefit.
            if (bool(economy_result.get("done", false)) ||
                bool(economy_result.get("fatal", false))) {
                _runtime_graph_last_economy_report = economy_result;
            }
            progressed = true;
        }
        if (!progressed) {
            status = 2;
            break;
        }
    }
    if (over_budget()) ++_runtime_graph_budget_yields;
    if (trigger_handoff_blocked) ++_runtime_graph_trigger_blocked_pulses;
    // A runtime may still own a persistent cursor even when this pulse did not
    // hit the wall-clock budget (for example a range cap stopped the loop).
    // Keep the committed-day barrier armed until every hard domain reports idle.
    //
    // Only unfinished daily work may arm it. Ideology explicitly distinguishes
    // local slice continuation from pending peer replies; Trigger and peer
    // polling can carry work into tomorrow. Running out of wall-clock budget
    // alone must still let WorldClock commit the day. Arming on the
    // budget yield alone froze the calendar for as long as trigger stayed
    // busy, because the frozen day kept trigger's own work queued.
    //
    // Worker-owned domains must not arm this barrier: the pulse loop already
    // skips their synchronous day, but legacy facades can keep should_run()
    // hot on stale queues. Operator precedence also used to let Effect/Modifier
    // escape the Country worker gate entirely — that pinned
    // country_day_barrier/economy_day_barrier with economy_slices=0.
    const bool country_worker_owns_barrier =
        country_worker_authoritative || suppressed(RuntimeDomainId::COUNTRY);
    const bool effect_worker_owns_barrier = suppressed(RuntimeDomainId::EFFECT);
    const bool modifier_worker_owns_barrier = suppressed(RuntimeDomainId::MODIFIER);
    const bool pending =
        ideology_needs_daily_continuation(day) ||
        (!country_worker_owns_barrier && _country_runtime != nullptr &&
         static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day)) ||
        (!effect_worker_owns_barrier && _effect_runtime != nullptr &&
         static_cast<EffectRuntime *>(_effect_runtime)->should_run(day)) ||
        (!modifier_worker_owns_barrier && _modifier_runtime != nullptr &&
         static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day)) ||
        (!effect_worker_owns_barrier && _effect_runtime != nullptr &&
         gameplay_effect_should_run(day)) ||
        (!suppressed(RuntimeDomainId::ECONOMY) && _economy_runtime != nullptr &&
         economy_should_run(day));
    if (pending) status = 3;
    if (country_peer_adapter_fault) status = 3;
    _runtime_graph_dirty_mask |= dirty;
    _runtime_graph_next_cursor += work;
    _runtime_graph_work_done += work;
    ++_runtime_graph_pulse_count;
    _runtime_graph_last_status = status;
    _runtime_graph_last_elapsed_us = elapsed_us(started);
    return make_token(day, status, _runtime_graph_dirty_mask,
                      static_cast<uint32_t>(flags));
}
