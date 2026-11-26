            for (int64_t step = 0; step < target_days; ++step) {
                if (_stop_requested.load(std::memory_order_acquire) ||
                    player_confirmation_block()) break;
                const int64_t from_day = _committed_day.load(std::memory_order_acquire);
                const int64_t day = from_day + 1;
                // Keep the authority switch closed across the whole semantic
                // day transaction through publication and generation release.
                // Counting only execute_day_plan() leaves publication unprotected.
                _worker_timing.set(RuntimeWorkerTiming::BOUNDARY_WAIT);
                std::unique_lock<std::mutex> boundary_lock(
                    _economy_authority_boundary_mutex, std::try_to_lock);
                if (!boundary_lock.owns_lock()) {
                    _worker_timing.observe_main_wait(day, RuntimeWorkerTiming::OTHER);
                    boundary_lock.lock();
                    _worker_timing.finish_main_wait();
                }
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                if (_world_environment && !retained_day_pending &&
                    (_save_requested.load(std::memory_order_acquire) ||
                     (!player_response_admits(day) &&
                      (_calendar_suspended.load(std::memory_order_acquire) ||
                       _clock_requested_day.load(std::memory_order_acquire) < day)))) break;
                AtomicCounterScope day_scope(_worker_day_inflight);
                if (try_fault_injection("worker.inflight.before")) {
                    break;
                }
                if (_world_environment && !try_freeze_command_inputs(day)) break;
                const bool narrative_commands = prepare_narrative_day(day);
                if (state() == RuntimeWorkerState::FAULTED) break;
                if (country_delivery_boundary || narrative_commands) drain_commands();
                day_receipts.clear();
                if (pending_commands_dirty) {
                    std::stable_sort(pending_commands.begin() +
                        static_cast<ptrdiff_t>(pending_begin), pending_commands.end(),
                    command_packet_before);
                    pending_commands_dirty = false;
                }
                size_t consumed_commands = pending_begin;
                std::vector<RuntimeCommandPacket> day_commands;
                day_commands.reserve(16u);
                uint64_t admitted_submit_order = 0;
                for (size_t index = pending_begin;
                     index < pending_commands.size(); ++index) {
                    admitted_submit_order = std::max(
                        admitted_submit_order,
                        pending_commands[index].submit_order);
                }
                for (; consumed_commands < pending_commands.size(); ++consumed_commands) {
                    const RuntimeCommandPacket &command = pending_commands[consumed_commands];
                    if (command.envelope.effective_day > day) break;
                    day_commands.push_back(command);
                    RuntimeCommandReceipt receipt;
                    receipt.request_id = command.envelope.request_id;
                    receipt.producer_id = command.envelope.producer_id;
                    receipt.sequence = command.envelope.sequence;
                    receipt.effective_day = std::max(command.envelope.effective_day, day);
                    receipt.generation = _generation.load(std::memory_order_relaxed) + 1;
                    const bool domain_valid =
                        command.envelope.domain >= static_cast<uint16_t>(RuntimeDomainId::INPUT_CAPTURE) &&
                        command.envelope.domain <= static_cast<uint16_t>(RuntimeDomainId::COMMIT);
                    const bool events_probe = domain_valid &&
                        static_cast<RuntimeDomainId>(command.envelope.domain) ==
                            RuntimeDomainId::EVENTS &&
                        (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW ||
                         _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE) &&
                        _events_probe_enabled.load(std::memory_order_acquire);
                    const bool modifier_shadow = domain_valid &&
                        static_cast<RuntimeDomainId>(command.envelope.domain) ==
                            RuntimeDomainId::MODIFIER &&
                        _mode.load(std::memory_order_acquire) ==
                            RuntimeSimulationMode::SHADOW &&
                        _modifier_pod_configured;
                    const bool domain_implemented = domain_valid &&
                        ((implemented_domain_mask() & runtime_domain_mask(
                            static_cast<RuntimeDomainId>(command.envelope.domain))) != 0u ||
                         events_probe || modifier_shadow);
                    const bool payload_valid =
                        command.envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_offset + command.envelope.payload_size <=
                            RUNTIME_MAX_COMMAND_PAYLOAD;
                    RuntimeModifierPodCommand modifier_command;
                    const bool modifier_payload_valid = !modifier_shadow ||
                        (decode_modifier_packet(command, modifier_command) &&
                         modifier_packet_shape_valid(modifier_command));
                    if (!payload_valid || !modifier_payload_valid) {
                        receipt.code = RuntimeReceiptCode::INVALID_PAYLOAD;
                    } else if (!domain_implemented || command.envelope.opcode == 0) {
                        // Unknown domain/opcode is a deterministic preflight
                        // rejection. It remains a receipt, never a dropped
                        // command, so callers can reconcile their request.
                        receipt.code = RuntimeReceiptCode::PREFLIGHT_REJECTED;
                    } else {
                        receipt.code = RuntimeReceiptCode::OK;
                    }
                    day_receipts.push_back(receipt);
                }
                // 与 build_day_plan 钉死同一份输入：同日重试不得换 latest。
                // 跨日时（environment.day < worker 下一拍）再从 FIFO 取最旧。
                if (!active_environment ||
                    active_environment->day < day) {
                    active_environment = executor_environment_for_day(day);
                }
                const auto &environment = active_environment;
                // 在执行前采样唤醒游标，避免执行期间已到达的 peer ACK 被漏掉。
                const uint64_t attempt_trace_signal =
                    _climate_trace_signal.load(std::memory_order_acquire);
                const uint64_t attempt_peer_signal =
                    _country_peer_signal.load(std::memory_order_acquire);
                const uint64_t attempt_environment_signal =
                    _environment_generation.load(std::memory_order_acquire);
                const uint64_t attempt_economy_signal =
                    _economy_input_signal.load(std::memory_order_acquire);
                _worker_timing.set(RuntimeWorkerTiming::EXECUTE);
                _day_waterfall.begin(day);
                RuntimeDayPlan day_plan = build_day_plan(
                    day, speed, environment.get(), admitted_submit_order);
                _day_waterfall.mark(RuntimeDayWaterfall::BUILD_PLAN);
                const auto day_attempt_started = std::chrono::steady_clock::now();
                _inline_day_pending.store(true, std::memory_order_release);
                const RuntimeDayCommit day_commit = execute_day_plan(
                    day_plan, environment.get(), day_commands, day_receipts,
                    admitted_submit_order);
                _day_waterfall.mark(RuntimeDayWaterfall::POST_LOOP);
                if (day % 100 == 0) {
                    std::fprintf(stderr, "[runtime-day-cost] day=%lld ok=%u ms=%.3f\n",
                        static_cast<long long>(day), static_cast<unsigned>(day_commit.preflight_ok),
                        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - day_attempt_started).count());
                }
                bool country_commands_terminal = !day_commands.empty();
                if (country_commands_terminal) {
                    std::lock_guard<std::mutex> country_lock(
                        _country_transport_mutex);
                    for (const RuntimeCommandPacket &command : day_commands) {
                        if (command.envelope.domain != static_cast<uint16_t>(
                                RuntimeDomainId::COUNTRY) ||
                            command.envelope.request_id == 0 ||
                            _country_command_terminals.find(
                                command.envelope.request_id) ==
                                _country_command_terminals.end()) {
                            country_commands_terminal = false;
                            break;
                        }
                    }
                }
                // Command ownership transfers only after the semantic day
                // commits, or after Country has published a deterministic
                // terminal rejection. A missing/future Climate frame retries
                // the same day; consuming commands before that preflight
                // silently lost one-shot Effect/Bio ingress.
                if (day_commit.preflight_ok != 0 ||
                    country_commands_terminal) {
                    for (const RuntimeCommandReceipt &receipt : day_receipts)
                        push_receipt(receipt);
                    if (consumed_commands > pending_begin) {
                        // Country may idempotent-skip an already-committed day
                        // while Effect ACK packets still sit in day_commands.
                        // Dropping those on a successful M5 day leaves
                        // PREFLIGHTED transactions without a Host receipt.
                        std::vector<RuntimeCommandPacket> retain_country;
                        if (day_commit.preflight_ok != 0 &&
                            !country_commands_terminal) {
                            std::lock_guard<std::mutex> country_lock(
                                _country_transport_mutex);
                            for (size_t index = pending_begin;
                                 index < consumed_commands; ++index) {
                                const RuntimeCommandPacket &command =
                                    pending_commands[index];
                                if (command.envelope.domain !=
                                        static_cast<uint16_t>(
                                            RuntimeDomainId::COUNTRY) ||
                                    command.envelope.request_id == 0) {
                                    continue;
                                }
                                if (_country_command_terminals.find(
                                        command.envelope.request_id) ==
                                    _country_command_terminals.end()) {
                                    retain_country.push_back(command);
                                }
                            }
                        }
                        pending_begin = consumed_commands;
                        compact_pending_commands();
                        if (!retain_country.empty()) {
                            pending_commands.insert(
                                pending_commands.begin() +
                                    static_cast<ptrdiff_t>(pending_begin),
                                std::make_move_iterator(retain_country.begin()),
                                std::make_move_iterator(retain_country.end()));
                        }
                        publish_pending_count();
                    }
                }
                _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RECEIPTS);
                if (day_commit.preflight_ok == 0) {
                    // execute_day_plan may already have set_fault (ledger /
                    // compact fatal). Do not arm fiscal or prepare on a dead
                    // worker — that printed empty yield= and hid the real code.
                    if (_state.load(std::memory_order_acquire) ==
                        RuntimeWorkerState::FAULTED) {
                        break;
                    }
                    const uint32_t missing = _requested_authority_mask.load(
                        std::memory_order_acquire) & ~day_commit.completed_domain_mask;
                    // Cold-path diagnostic: expose which domain parks the day
                    // while preflight_ok stays 0. Only runs on the failure
                    // branch and is throttled to the first few occurrences, so
                    // healthy days pay nothing but a compare.
                    {
                        static std::atomic<int> s_day_diag_tick{0};
                        const int tick = s_day_diag_tick.fetch_add(
                            1, std::memory_order_relaxed);
                        if (tick < 24 && tick % 4 == 0) {
                            std::string stage_text;
                            for (uint32_t si = 0; si < day_plan.stage_count; ++si) {
                                stage_text += runtime_domain_fault_tag(
                                    day_plan.stages[si].domain);
                                stage_text += ":";
                                stage_text += std::to_string(
                                    static_cast<unsigned>(
                                        day_plan.stages[si].completed));
                                stage_text += " ";
                            }
                            const int64_t env_day = environment != nullptr
                                ? environment->day : int64_t{-1};
                            const uint64_t env_gen = environment != nullptr
                                ? environment->generation : uint64_t{0};
                            // Plain string concatenation: MSVC's printf format
                            // checker mis-counts arguments in concatenated
                            // literals, so hand it a single "%s".
                            std::string diag;
                            diag += "[runtime-day-diag] day=" +
                                std::to_string(static_cast<long long>(day));
                            diag += " preflight=" + std::to_string(
                                static_cast<unsigned>(day_commit.preflight_ok));
                            diag += " missing=" + std::to_string(
                                static_cast<unsigned long long>(missing));
                            diag += " completed=" + std::to_string(
                                static_cast<unsigned long long>(
                                    day_commit.completed_domain_mask));
                            diag += " stages=" + std::to_string(
                                static_cast<unsigned>(
                                    day_commit.completed_stage_count)) +
                                "/" + std::to_string(
                                static_cast<unsigned>(day_plan.stage_count));
                            diag += " env_day=" + std::to_string(
                                static_cast<long long>(env_day));
                            diag += " env_gen=" + std::to_string(
                                static_cast<unsigned long long>(env_gen));
                            diag += " plan_day=" + std::to_string(
                                static_cast<long long>(day_plan.context.day));
                            diag += " plan_gen=" + std::to_string(
                                static_cast<unsigned long long>(
                                    day_plan.context.input_generation));
                            diag += " climate_store_day=" + std::to_string(
                                static_cast<long long>(
                                    _climate_authority.store().committed_day));
                            diag += " ring=" + std::to_string(
                                static_cast<unsigned long long>(
                                    _environment_ring.size()));
                            diag += " stages=" + stage_text + "\n";
                            std::fprintf(stderr, "%s", diag.c_str());
                        }
                    }
                    // Full domain coverage with preflight_ok=0 is a spurious
                    // barrier: parking here leaves future Climate envs stuck in
                    // a full ring and nails WorldClock on capacity forever.
                    if (missing == 0u &&
                        _requested_authority_mask.load(std::memory_order_acquire) !=
                            0u) {
                        static std::atomic<int> s_full_mask_preflight_left{8};
                        const int64_t climate_committed =
                            _climate_authority.store().committed_day;
                        if (s_full_mask_preflight_left.fetch_sub(
                                1, std::memory_order_relaxed) > 0) {
                            pk::log_info(
                                "[runtime-day-wait] day=%lld missing=0x0 "
                                "forcing advance (spurious preflight_ok=0) "
                                "ring=%zu climate_committed=%lld continuation=%d "
                                "stall=0x%x",
                                static_cast<long long>(day),
                                _environment_ring.size(),
                                static_cast<long long>(climate_committed),
                                static_cast<int>(day_commit.continuation_pending),
                                day_stall_reason_mask());
                        }
                        // Only drop envs for this worker day (and earlier).
                        // Never drain through climate_committed when it is
                        // ahead — that erases futures Host already queued for
                        // catch-up days and leaves the FIFO empty/mismatched,
                        // after which Host sticks on capacity forever.
                        if (_environment_ring.pop_while_day_at_most(day) > 0u) {
                            _climate_wait_cv.notify_all();
                            _control_cv.notify_all();
                        }
                        clear_day_stall_peer_bits();
                        // Force the next iteration to re-peek FIFO instead of
                        // retaining a drained shared_ptr as active_environment.
                        active_environment.reset();
                        // Fall through to the success path below.
                    } else {
                    // 主线程唯一能读到「今天缺哪个域」的地方。stall 位只描述外部
                    // 等待（环满 / peer / 经济输入），缺口既不设位也不发 CV 时它恒
                    // 为 0x0，日志里只剩一句无声的冻结；这四个值把缺口钉住。
                    _day_wait_day.store(day, std::memory_order_release);
                    _day_wait_missing_mask.store(missing, std::memory_order_release);
                    _day_wait_env_day.store(
                        environment != nullptr ? environment->day : int64_t{-1},
                        std::memory_order_release);
                    _day_wait_ring.store(static_cast<uint32_t>(_environment_ring.size()),
                                         std::memory_order_release);
                    if (logged_pending_day != day || logged_pending_mask != missing) {
                        logged_pending_day = day;
                        logged_pending_mask = missing;
                        std::fprintf(stderr, "[runtime-day-wait] day=%lld env_day=%lld missing=0x%x stall=0x%x economy_input=%lld\n",
                            static_cast<long long>(day),
                            static_cast<long long>(environment ? environment->day : -1),
                            missing,
                            day_stall_reason_mask(),
                            static_cast<long long>(economy_input_requested_day()));
                        char country_fallback[64];
                        size_t fb = 0;
                        for (; fb + 1 < sizeof(country_fallback) &&
                               fb < _country_pod_fallback_reason.size(); ++fb) {
                            country_fallback[fb] =
                                _country_pod_fallback_reason[fb].load(
                                    std::memory_order_acquire);
                            if (country_fallback[fb] == '\0') break;
                        }
                        country_fallback[fb] = '\0';
                        pk::log_info(
                            "[runtime-day-wait] day=%lld env_day=%lld missing=0x%x "
                            "stall=0x%x economy_input=%lld ring=%zu country=%s",
                            static_cast<long long>(day),
                            static_cast<long long>(environment ? environment->day : -1),
                            missing, day_stall_reason_mask(),
                            static_cast<long long>(economy_input_requested_day()),
                            _environment_ring.size(),
                            country_fallback);
                        // Economy incomplete with no stall bit has no CV wake
                        // source once Climate capacity fills. Arm a peer stall
                        // so the timeout fault surfaces instead of a silent hang.
                        if ((missing & runtime_domain_mask(
                                 RuntimeDomainId::ECONOMY)) != 0u &&
                            (day_stall_reason_mask() &
                             (RUNTIME_DAY_STALL_COUNTRY_PEER |
                              RUNTIME_DAY_STALL_EFFECT_ACK |
                              RUNTIME_DAY_STALL_FISCAL_PEER |
                              RUNTIME_DAY_STALL_ECONOMY_INPUT)) == 0u) {
                            note_day_stall(RUNTIME_DAY_STALL_FISCAL_PEER, day);
                            // Same drain as Economy fiscal-pending: free Host
                            // capacity so peer/fiscal pumps can make progress.
                            const int64_t climate_committed =
                                _climate_authority.store().committed_day;
                            if (climate_committed >= 0 &&
                                _environment_ring.pop_while_day_at_most(
                                    climate_committed) > 0u) {
                                _climate_wait_cv.notify_all();
                                _control_cv.notify_all();
                            }
                            char yield_reason[48];
                            size_t yi = 0;
                            for (; yi + 1 < sizeof(yield_reason) &&
                                   yi < _economy_yield_reason.size(); ++yi) {
                                yield_reason[yi] = _economy_yield_reason[yi].load(
                                    std::memory_order_relaxed);
                                if (yield_reason[yi] == '\0') break;
                            }
                            yield_reason[yi] = '\0';
                            pk::log_info(
                                "[runtime-day-wait] day=%lld armed fiscal stall "
                                "for economy-missing-without-stall ring=%zu "
                                "yield=%s climate_committed=%lld",
                                static_cast<long long>(day),
                                _environment_ring.size(),
                                std::string(yield_reason).c_str(),
                                static_cast<long long>(climate_committed));
                        }
                    }
                    if (_state.load(std::memory_order_acquire) ==
                        RuntimeWorkerState::FAULTED) {
                        break;
                    }
                    // An input/reference barrier failure must not advance the
                    // committed clock. Wait for the main thread to publish
                    // the matching reference or for a control message; this
                    // is a condition-variable wait, not a polling sleep.
                    if (day_commit.continuation_pending == 0) {
                        _time_debt_days.store(std::min(100.0,
                            _time_debt_days.load(std::memory_order_relaxed) + 1.0),
                            std::memory_order_release);
                    }
                    // Same-day Economy→Country asset prepare must happen before
                    // parking. Otherwise Climate ring stays full, main cannot
                    // publish, and country_peer_signal never fires.
                    std::string prepare_error;
                    const uint32_t prepared_before_wait =
                        prepare_economy_origin_country_assets(prepare_error);
                    _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RETRY);
                    if (!prepare_error.empty()) {
                        set_fault(prepare_error.c_str());
                        break;
                    }
                    // 捕获输入时主线程必须可取得边界锁；等待期间没有公式写入。
                    boundary_lock.unlock();
                    if (prepared_before_wait > 0u) {
                        // Origin assets are now pollable; retry this day without
                        // waiting for an external wake that may never arrive.
                        break;
                    }
                    // Country plan rejected a research enqueue (queue full /
                    // already queued) and published terminals. The bad command
                    // is consumed; parking forever with stall=0x0 freezes the
                    // calendar. Retry immediately.
                    if ((missing & runtime_domain_mask(
                             RuntimeDomainId::COUNTRY)) != 0u &&
                        country_commands_terminal) {
                        char reject_reason[64];
                        size_t rb = 0;
                        for (; rb + 1 < sizeof(reject_reason) &&
                               rb < _country_pod_fallback_reason.size(); ++rb) {
                            reject_reason[rb] =
                                _country_pod_fallback_reason[rb].load(
                                    std::memory_order_acquire);
                            if (reject_reason[rb] == '\0') break;
                        }
                        reject_reason[rb] = '\0';
                        if (std::strcmp(reject_reason,
                                        "country_research_queue_full") == 0 ||
                            std::strcmp(reject_reason,
                                        "country_research_already_queued") ==
                                0) {
                            break;
                        }
                    }
                    const auto next_input = _environment_ring.peek_oldest();
                    const bool stale_input_consumed = environment != nullptr &&
                        environment->day < day && next_input != nullptr &&
                        next_input->generation != environment->generation;
                    const uint64_t trace_signal = attempt_trace_signal;
                    // Under ACTIVE Climate authority there is no trace signal
                    // to wait for: production is suppressed and the only input
                    // that can unblock the day is a fresh environment publish
                    // from the main thread. Waiting on the trace alone would
                    // park the worker forever the first time the environment
                    // is not yet available.
                    const uint64_t environment_signal = attempt_environment_signal;
                    const uint64_t country_peer_signal = attempt_peer_signal;
                    std::unique_lock<std::mutex> lock(_control_mutex);
                    _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RETRY);
                    _day_waterfall.finish(false, day_commit.completed_domain_mask);
                    _worker_timing.set(RuntimeWorkerTiming::INPUT_RETRY_WAIT);
                    // Timed wait: peer-stall timeout must be polled while the
                    // Climate ring is full and no CV signal arrives.
                    constexpr auto kDayWaitSlice =
                        std::chrono::milliseconds(250);
                    const bool missing_environment = climate_driven && !_world_environment &&
                        (!environment || environment->day != day);
                    constexpr uint32_t peer_waits = RUNTIME_DAY_STALL_ECONOMY_INPUT |
                        RUNTIME_DAY_STALL_COUNTRY_PEER | RUNTIME_DAY_STALL_EFFECT_ACK |
                        RUNTIME_DAY_STALL_IDEOLOGY_ACK | RUNTIME_DAY_STALL_FISCAL_PEER;
                    const bool waits_for_main = (day_stall_reason_mask() & peer_waits) != 0u ||
                        (!climate_driven && (missing & runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u);
                    _control_cv.wait_for(lock, kDayWaitSlice, [&] {
                        // Match the save admission condition above. A pending
                        // save cannot consume an unfinished environment day;
                        // waking on the request alone spins and starves the
                        // main-thread input capture needed to finish that day.
                        const bool save_can_run =
                            _save_requested.load(std::memory_order_acquire) &&
                            !has_pending_climate_input() &&
                            !(active_environment && active_environment->day == day);
                        const bool ready = _stop_requested.load(std::memory_order_acquire) ||
                            save_can_run || player_requests_pending_locked() ||
                            (!climate_driven && _paused.load(std::memory_order_acquire)) ||
                            stale_input_consumed ||
                            _climate_trace_signal.load(std::memory_order_acquire) !=
                                trace_signal ||
                            _environment_generation.load(
                                std::memory_order_acquire) != environment_signal ||
                            _country_peer_signal.load(std::memory_order_acquire) !=
                                country_peer_signal ||
                            _economy_input_signal.load(std::memory_order_acquire) !=
                                attempt_economy_signal ||
                            (!climate_driven &&
                             _climate_trace.consumable_depth() != 0);
                        if (!ready && missing_environment) {
                            if (_paused.load(std::memory_order_acquire))
                                _worker_timing.finish_main_wait();
                            else
                                _worker_timing.observe_main_wait(day, RuntimeWorkerTiming::ENVIRONMENT_INPUT);
                        } else if (!ready && waits_for_main) {
                            _worker_timing.observe_main_wait(day, RuntimeWorkerTiming::OTHER);
                        }
                        return ready;
                    });
                    _worker_timing.finish_main_wait();
                    _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                    log_slow_peer(day);
                    break;
                    } // missing != 0
                }
                if (day_commit.completed_stage_count == day_plan.stage_count &&
                    day_plan.stage_count == RUNTIME_DOMAIN_STAGE_COUNT &&
                    day_commit.completed_domain_mask == RUNTIME_ALL_DOMAIN_MASK &&
                    implemented_domain_mask() == RUNTIME_ALL_DOMAIN_MASK) {
                    _graph_coverage_complete.store(true, std::memory_order_release);
                    _authority_control.mark_graph_ready();
                }
                // Per-domain grant. A domain is promoted once this day's commit
                // covers it, independently of whether the whole graph is
                // complete. Granting only the requested subset keeps a domain
                // the caller did not ask for on the main thread even when its
                // handler happens to exist.
                if (_mode.load(std::memory_order_acquire) ==
                        RuntimeSimulationMode::ACTIVE) {
                    const uint32_t wanted =
                        _requested_authority_mask.load(std::memory_order_acquire);
                    if (wanted != 0u &&
                        (day_commit.completed_domain_mask & wanted) == wanted) {
                        publish_authority_grant(wanted);
                    }
                    // Publish the committed Climate state for main-thread
                    // write-back. Ordered before the authority grant becomes
                    // observable to a reader that has not seen a day yet: the
                    // schedule gate suppresses production the moment the grant
                    // lands, so the first suppressed tick must already have a
                    // snapshot to consume.
                    if (!_world_environment && (wanted & runtime_domain_mask(RuntimeDomainId::CLIMATE))
                            != 0u) {
                        // Only a day Climate actually advanced may be
                        // published. The worker clock is free to run ahead of
                        // the main thread, and on those idle days the store is
                        // unchanged; handing the main thread a fresh cursor for
                        // it would make it re-apply the same state every day and
                        // report a healthy write-back cadence while Climate was
                        // in fact standing still. That is exactly how a stalled
                        // Climate stayed invisible behind writeback_days.
                        const int64_t climate_day =
                            _climate_authority.store().committed_day;
                        uint32_t slot = 0;
                        if (climate_day > _climate_writeback_last_day.load(
                                std::memory_order_relaxed) &&
                            _climate_writeback.try_begin_write(slot)) {
                            RuntimeClimateSnapshot &out =
                                _climate_writeback.write_buffer(slot);
                            capture_climate_display(out);
                            // Own monotonic sequence, not the commit
                            // generation: the commit generation is bumped later
                            // inside publish_day, so reading it here would
                            // hand out a stale cursor and the main thread would
                            // re-apply the same day.
                            out.generation = _climate_writeback_sequence.fetch_add(
                                1, std::memory_order_relaxed) + 1u;
                            // Climate's day, not the worker clock's: this is the
                            // day whose state the buffer carries.
                            out.committed_day = climate_day;
                            out.dirty_families = day_commit.dirty_families;
                            _climate_writeback.publish(slot);
                            _climate_writeback_last_day.store(
                                climate_day, std::memory_order_relaxed);
                        }
                    }
                }
                _day_waterfall.mark(RuntimeDayWaterfall::WORKER_CLIMATE_WRITEBACK);
                _last_day_stage_count.store(day_plan.stage_count,
                                            std::memory_order_release);
                _last_day_completed_stages.store(day_commit.completed_stage_count,
                                                 std::memory_order_release);
                _last_day_work_units.store(day_commit.work_units,
                                           std::memory_order_release);
                _completed_days.fetch_add(1, std::memory_order_relaxed);
                publish_day(from_day, day, day_commit, day_receipts);
                _inline_day_pending.store(false, std::memory_order_release);
                // Still inside the boundary: the post-command committed state
                // is stable, so this is where main-thread read demand is served.
                if (_economy_production_runtime != nullptr &&
                    economy_worker_owns_execution())
                    _economy_production_runtime->serve_read_view();
                _day_waterfall.mark(RuntimeDayWaterfall::WORKER_PUBLISH_DAY);
                _day_waterfall.finish(true, day_commit.completed_domain_mask);
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                // Control messages are intentionally checked at the day
                // barrier as well as the outer loop.  A long catch-up batch
                // must yield promptly to SAVE/PAUSE/STOP instead of spending
                // the whole debt budget before servicing the request.
                if (_save_requested.load(std::memory_order_acquire) ||
                    _paused.load(std::memory_order_acquire) ||
                    _stop_requested.load(std::memory_order_acquire)) {
                    break;
                }
            }
