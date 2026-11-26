namespace {

int32_t effect_program_id_for_hash(const RuntimeEffectPodCatalog &catalog,
                                   uint64_t hash) {
    for (size_t i = 0; i < catalog.definitions.size(); ++i) {
        if (catalog.definitions[i].key_hash == hash)
            return static_cast<int32_t>(i);
    }
    return -1;
}

} // namespace

int32_t NativeSimulationHost::effect_pod_program_id_for_key(
        const char *key) const {
    if (!_effect_pod_configured || key == nullptr || key[0] == '\0') return -1;
    return effect_program_id_for_hash(
        _effect_pod_catalog, RuntimeEffectPodAuthority::hash_text(key));
}

CountryPeerResult NativeSimulationHost::resolve_country_technology_effect(
        const CountryPeerIntent &intent) {
    CountryPeerResult result;
    result.protocol_version = intent.protocol_version;
    result.opcode = intent.opcode;
    result.request_id = intent.request_id;
    result.session_epoch = intent.session_epoch;
    result.country_generation = intent.country_generation;
    result.peer_generation = intent.peer_generation;
    result.committed_peer_generation = intent.peer_generation;
    result.day = intent.day;
    result.continuation_index = intent.continuation_index;
    result.country_slot = intent.country_slot;
    result.technology = intent.technology;
    result.target_handle = intent.target_handle;
    const auto reject = [&](const char *reason) {
        result.code = CountryPeerResultCode::REJECTED;
        country_peer_copy_reason(result.reason, reason);
        return result;
    };
    const auto &hashes = _country_pod_catalog.technology_effect_key_hashes;
    if (intent.technology < 0 ||
        static_cast<size_t>(intent.technology) >= hashes.size())
        return reject("country_peer_intent_target_invalid");
    if (intent.effect_instance_id == 0 || intent.effect_generation == 0 ||
        intent.effect_generation != static_cast<uint32_t>(intent.target_handle >> 32U))
        return reject("country_peer_effect_generation_invalid");
    const int32_t program_id = effect_program_id_for_hash(
        _effect_pod_catalog, hashes[static_cast<size_t>(intent.technology)]);
    if (program_id < 0) {
        // No Effect program for this technology: nothing to wait for.
        result.technology_flags = COUNTRY_PEER_EFFECT_EXISTS |
            COUNTRY_PEER_EFFECT_FIRE_ACKED;
        result.code = CountryPeerResultCode::READY;
        return result;
    }
    std::string error;
    if (!ensure_effect_pod_technology_instance(
            static_cast<int64_t>(intent.effect_instance_id),
            intent.effect_generation, program_id, intent.target_handle,
            intent.effect_generation, intent.day, error))
        return reject(error.empty() ? "country_peer_effect_pod_queue_rejected"
                                    : error.c_str());
    result.technology_flags = COUNTRY_PEER_EFFECT_EXISTS;
    if (effect_pod_instance_fire_acked(
            static_cast<int64_t>(intent.effect_instance_id),
            intent.effect_generation)) {
        result.technology_flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
        result.code = CountryPeerResultCode::READY;
    } else {
        result.code = CountryPeerResultCode::PENDING;
    }
    return result;
}

bool NativeSimulationHost::ensure_effect_pod_technology_instance(
        int64_t instance_id, uint32_t generation, int32_t program_id,
        uint64_t target_handle, uint32_t target_generation, int64_t day,
        std::string &error) {
    error.clear();
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    if (instance_id == 0 || generation == 0 || program_id < 0) {
        error = "effect_pod_technology_instance_invalid";
        return false;
    }
    // Already present in the committed POD snapshot — do not re-queue.
    {
        const auto &snapshot = _effect_pod_authority.snapshot();
        for (const auto &instance : snapshot.instances) {
            if (instance.instance_id == instance_id &&
                instance.generation == generation &&
                instance.active != 0) {
                return true;
            }
        }
    }
    RuntimeEffectPodInstanceInput input;
    input.instance_id = instance_id;
    input.generation = generation;
    input.program_id = program_id;
    input.source_type = 0x54454348; // 'TECH'
    input.source_id = instance_id;
    input.source_handle = target_handle;
    input.target_handle = target_handle;
    input.target_generation = target_generation;
    input.level = 0;
    // Effect often soft-skips the same calendar day Country seals. Schedule
    // the first fire for the next sequential Effect day (committed+1), never
    // the already-closed committed day — otherwise plan_day cannot see the
    // instance until a never-fired cadence retry (technology cadence is 3650).
    const int64_t effect_day = _effect_pod_authority.snapshot().committed_day;
    input.next_due_day = effect_day >= 0 ? effect_day + 1 : day;
    input.active = true;
    // Queue only. The main-thread Country peer adapter must never mutate the
    // Effect POD authority: worker plan_day/commit/ack run concurrently and a
    // same-turn upsert races them (instances stuck fire_seq=0 / never fire).
    // Effect stage drain_effect_transport_queues installs before plan/soft-skip.
    if (!queue_effect_pod_instance(input, error)) return false;
    return true;
}

bool NativeSimulationHost::effect_pod_instance_exists(int64_t instance_id,
                                                     uint32_t generation) const {
    if (!_effect_pod_configured || instance_id == 0 || generation == 0)
        return false;
    const auto &snapshot = _effect_pod_authority.snapshot();
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id != instance_id) continue;
        // Same rule as EffectRuntime::has_instance_pod: an inactive instance is
        // still a known identity, the generation is what makes it stale.
        return instance.generation == generation;
    }
    // Not installed yet, but a queued upsert is already a live identity: the
    // transport accepted the row and the worker will install it. Answering
    // "absent" here made every main-thread reader race the transport --
    // the ideology restore rejected a save whose instances were merely queued,
    // and register_person_effect re-upserted (each time with a fresh
    // next_due_day) on every call. A queued *retire* needs no special case: until
    // it drains the instance genuinely still exists, which is what the snapshot
    // branch above already reports.
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    for (const EffectPodInstanceQueueItem &item : _effect_instance_queue) {
        if (item.input.instance_id == instance_id &&
            item.input.generation == generation)
            return true;
    }
    return false;
}

std::string NativeSimulationHost::describe_effect_pod_technology_state(
        int64_t instance_id, uint32_t generation, int32_t program_id,
        int32_t technology) const {
    char text[512]{};
    if (!_effect_pod_configured) return "effect_pod_not_configured";
    const auto &snapshot = _effect_pod_authority.snapshot();
    const RuntimeEffectPodInstance *found = nullptr;
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id == instance_id) { found = &instance; break; }
    }
    int transactions = 0;
    int last_status = -1;
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.source_instance_id != instance_id) continue;
        ++transactions;
        last_status = static_cast<int>(transaction.status);
    }
    std::snprintf(text, sizeof(text),
        "tech=%d program_id=%d instance=%lld gen=%u "
        "present=%d inst_gen=%u active=%d fire_seq=%llu acked_seq=%llu "
        "next_due=%lld tx=%d last_tx_status=%d pod_gen=%llu pod_day=%lld "
        "instances=%zu queued=%zu",
        technology, program_id, static_cast<long long>(instance_id), generation,
        found != nullptr ? 1 : 0,
        found != nullptr ? found->generation : 0u,
        found != nullptr ? static_cast<int>(found->active) : -1,
        static_cast<unsigned long long>(found != nullptr ? found->fire_sequence : 0),
        static_cast<unsigned long long>(
            found != nullptr ? found->last_acked_fire_sequence : 0),
        static_cast<long long>(found != nullptr ? found->next_due_day : -1),
        transactions, last_status,
        static_cast<unsigned long long>(snapshot.generation),
        static_cast<long long>(snapshot.committed_day),
        snapshot.instances.size(), _effect_instance_queue.size());
    return text;
}

bool NativeSimulationHost::effect_pod_instance_fire_acked(
        int64_t instance_id, uint32_t generation) const {
    if (!_effect_pod_configured || instance_id == 0 || generation == 0)
        return false;
    const auto &snapshot = _effect_pod_authority.snapshot();
    const RuntimeEffectPodInstance *found = nullptr;
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id == instance_id &&
            instance.generation == generation) {
            found = &instance;
            break;
        }
    }
    if (found == nullptr || found->fire_sequence == 0) return false;
    if (found->last_acked_fire_sequence >= found->fire_sequence) return true;
    bool saw_acked = false;
    bool saw_rejected = false;
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.source_instance_id != instance_id ||
            transaction.source_generation != generation) {
            continue;
        }
        if (transaction.status != RuntimeEffectPodTransactionStatus::ACKED &&
            transaction.status != RuntimeEffectPodTransactionStatus::REJECTED) {
            return false;
        }
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED)
            saw_acked = true;
        else
            saw_rejected = true;
    }
    if (saw_acked) return true;
    if (saw_rejected) return false;
    return true;
}

uint32_t NativeSimulationHost::resolve_pending_country_effect_peers() {
    if (!_effect_pod_configured) return 0;
    uint32_t promoted = 0;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        for (auto &entry : _country_worker_results) {
            CountryPeerResult &result = entry.second;
            if (result.code != CountryPeerResultCode::PENDING) continue;
            if (result.opcode != CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT &&
                result.opcode != CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT) {
                continue;
            }
            const auto intent_it = _country_worker_intents.find(entry.first);
            if (intent_it == _country_worker_intents.end()) continue;
            const CountryPeerIntent &intent = intent_it->second;
            if (intent.effect_instance_id == 0 || intent.effect_generation == 0)
                continue;
            if (!effect_pod_instance_fire_acked(
                    static_cast<int64_t>(intent.effect_instance_id),
                    intent.effect_generation)) {
                static std::atomic<int> s_unacked_left{24};
                if (s_unacked_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                    const auto &snap = _effect_pod_authority.snapshot();
                    int64_t fire_seq = -1, acked_seq = -1, next_due = -1;
                    for (const auto &inst : snap.instances) {
                        if (inst.instance_id == static_cast<int64_t>(
                                intent.effect_instance_id)) {
                            fire_seq = static_cast<int64_t>(inst.fire_sequence);
                            acked_seq = static_cast<int64_t>(
                                inst.last_acked_fire_sequence);
                            next_due = inst.next_due_day;
                        }
                    }
                    std::string tx;
                    for (const auto &t : snap.transactions) {
                        if (t.source_instance_id !=
                            static_cast<int64_t>(intent.effect_instance_id))
                            continue;
                        char buf[96];
                        std::snprintf(buf, sizeof(buf), " tx%lld:st=%d req=0x%x got=0x%x",
                            static_cast<long long>(t.transaction_id),
                            static_cast<int>(t.status), t.required_ack_mask,
                            t.received_ack_mask);
                        tx += buf;
                    }
                    pk::log_info("[tech-ack-diag/unacked] tech=%d fire_seq=%lld "
                                 "acked_seq=%lld next_due=%lld pod_day=%lld%s",
                                 static_cast<int>(intent.technology),
                                 static_cast<long long>(fire_seq),
                                 static_cast<long long>(acked_seq),
                                 static_cast<long long>(next_due),
                                 static_cast<long long>(snap.committed_day), tx.c_str());
                }
                continue;
            }
            result.code = CountryPeerResultCode::READY;
            result.technology_flags = static_cast<uint8_t>(
                result.technology_flags | COUNTRY_PEER_EFFECT_EXISTS |
                COUNTRY_PEER_EFFECT_FIRE_ACKED);
            _country_worker_terminal_results[entry.first] = result;
            ++promoted;
        }
        if (promoted > 0u) {
            _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
            // P2：把"谁推进了 peer"变成可数量。worker 内闭环是目标形态；
            // 只要 by_main 还在涨，说明这条线仍然依赖主线程泵。
            if (on_worker_thread()) {
                _country_peer_resolved_in_worker.fetch_add(promoted,
                                                          std::memory_order_relaxed);
            } else {
                _country_peer_resolved_by_main.fetch_add(promoted,
                                                         std::memory_order_relaxed);
            }
        }
    }
    if (promoted > 0u) {
        _control_cv.notify_all();
        static int s_promote_left = 16;
        if (s_promote_left-- > 0) {
            pk::log_info(
                "[tech-ack-diag/promote] pending→READY count=%u stall=0x%x",
                promoted, day_stall_reason_mask());
        }
    }
    return promoted;
}
