    if (waiting) {
        {
            static std::atomic<int> s_wait_diag_left{12};
            if (s_wait_diag_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::lock_guard<std::mutex> lock(_country_transport_mutex);
                std::string detail;
                for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                    const uint64_t request_id = intent.request_id != 0
                        ? intent.request_id : intent.source_id;
                    const auto r = _country_worker_results.find(request_id);
                    const auto i = _country_worker_intents.find(request_id);
                    char buf[200];
                    std::snprintf(buf, sizeof(buf),
                        " [op=%u tech=%lld req=%llx result=%d intent=%d inst=%llx gen=%u]",
                        static_cast<unsigned>(intent.opcode),
                        static_cast<long long>(intent.payload[0]),
                        static_cast<unsigned long long>(request_id),
                        r == _country_worker_results.end() ? -1
                            : static_cast<int>(r->second.code),
                        i == _country_worker_intents.end() ? 0 : 1,
                        static_cast<unsigned long long>(
                            i == _country_worker_intents.end() ? 0
                                : i->second.effect_instance_id),
                        i == _country_worker_intents.end() ? 0u
                            : i->second.effect_generation);
                    detail += buf;
                }
                pk::log_info("[tech-ack-diag/wait] day=%lld intents=%zu queued=%zu%s",
                             static_cast<long long>(day),
                             _country_pod_plan.intents.size(),
                             _country_worker_intent_queue.size(), detail.c_str());
            }
        }
        // Effect may have catchup-fired after the Host pump left PENDING
        // (PENDING is not re-queued). Promote same-day before parking.
        if (resolve_pending_country_effect_peers() > 0u) {
            waiting = false;
            rejected = false;
            acks.clear();
            {
                std::lock_guard<std::mutex> lock(_country_transport_mutex);
                bind_shadow_country_peer_mirrors_locked();
                for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                    const uint64_t request_id = intent.request_id != 0
                        ? intent.request_id : intent.source_id;
                    const auto result_it = _country_worker_results.find(request_id);
                    if (result_it == _country_worker_results.end() ||
                        result_it->second.code == CountryPeerResultCode::PENDING) {
                        waiting = true;
                        continue;
                    }
                    const CountryPeerResult &result = result_it->second;
                    RuntimeDomainAck ack;
                    ack.request_id = request_id;
                    ack.transaction_id = request_id;
                    ack.target_handle = intent.target_handle;
                    ack.target_generation = intent.target_generation;
                    ack.domain = intent.target_domain;
                    ack.effective_day = intent.effective_day;
                    ack.producer_id = intent.producer_id;
                    ack.sequence = intent.sequence;
                    ack.technology_flags = result.technology_flags;
                    if (result.code == CountryPeerResultCode::READY ||
                        result.code == CountryPeerResultCode::APPLIED) {
                        ack.code = RuntimeDomainAckCode::OK;
                    } else {
                        ack.code = result.code == CountryPeerResultCode::STALE
                            ? RuntimeDomainAckCode::STALE_GENERATION
                            : RuntimeDomainAckCode::REJECTED;
                        rejected = true;
                        rejection_reason = result.reason.data();
                        if (rejected_request_id == 0) {
                            rejected_request_id = request_id;
                            rejected_opcode = static_cast<CountryPeerIntentCode>(
                                intent.opcode);
                        }
                    }
                    acks.push_back(ack);
                }
            }
        }
    }
