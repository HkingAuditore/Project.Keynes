#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"

namespace pk {

bool NativeSimulationHost::execute_country_worker_stage(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeCommandPacket> &day_commands,
        RuntimeDayCommit &commit, std::string &error,
        uint64_t admitted_submit_order) {
    error.clear();
    if (!_country_pod_configured) return true;
    // P2（设计报告 §3.2.3 第 3 条）：在 COUNTRY stage **入口**就把昨日遗留的
    // PENDING 提升一次。Effect 的 fire 发生在 EFFECT(6) stage，而 COUNTRY 是
    // stage 3，所以同一日历日内不可能闭环 —— 一日延迟是结构性下界。入口处的
    // 这次 promote 让"昨日的 PENDING 在今天的 result 扫描之前就变成 READY"，
    // 而不是等到扫描失败后才补救（那时已经先把 missing 记进 day_wait 了）。
    // 它只是把既有函数多调一次，不改变任何分支语义，也不新增等待。
    (void)resolve_pending_country_effect_peers();
    if (!flush_country_economy_asset_commits(error, 0, false, day)) {
        commit.preflight_ok = 0;
        return false;
    }

    // Convert the sealed Country packet set once for terminal reporting. The
    // worker may reject the whole semantic batch before a POD plan exists, so
    // terminal receipts cannot depend only on RuntimeCountryPodPlan.commands.
    // A malformed packet still gets an execution rejection identified by its
    // transport envelope; it is never silently lost after admission.
    std::vector<RuntimeCountryCommand> sealed_country_commands;
    sealed_country_commands.reserve(day_commands.size());
    for (const RuntimeCommandPacket &packet : day_commands) {
        if (packet.envelope.domain !=
                static_cast<uint16_t>(RuntimeDomainId::COUNTRY)) {
            continue;
        }
        RuntimeCountryCommand command;
        std::string command_error;
        if (!RuntimeCountryPodAdapter::decode_command(
                packet, command, command_error)) {
            command.request_id = packet.envelope.request_id;
            command.producer_id = packet.envelope.producer_id;
            command.sequence = packet.envelope.sequence;
            command.requested_day = packet.envelope.requested_day;
            command.effective_day = packet.envelope.effective_day;
            command.opcode = packet.envelope.opcode;
            command.submit_order = packet.submit_order;
        }
        sealed_country_commands.push_back(command);
    }
    (void)sealed_country_commands;

    if (!_country_pod_plan_active) {
        // Only unwind commands this attempt newly pushed. Packets already in
        // _pending (mid-plan late admit / prior retain) must survive a
        // sibling decode failure or plan_day reject.
        std::vector<uint64_t> newly_queued_ids;
        std::vector<RuntimeCountryCommand> newly_queued_commands;
        newly_queued_ids.reserve(sealed_country_commands.size());
        newly_queued_commands.reserve(sealed_country_commands.size());
        CountryAiRuntime *country_ai = country_ai_for_worker();
        for (const RuntimeCommandPacket &packet : day_commands) {
            if (packet.envelope.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY))
                continue;
            // AI batches submitted by the synchronous adapter before the worker
            // took Country authority: the worker AI replans that day from the
            // same state, so replaying them would only duplicate or go stale.
            if (country_ai != nullptr &&
                packet.envelope.producer_id == COUNTRY_AI_PRODUCER_ID)
                continue;
            CountryCommandReceipt terminal;
            if (try_country_command_terminal(packet.envelope.request_id, terminal))
                continue;
            if (packet.envelope.request_id != 0 &&
                _country_pod_authority.has_pending_request(
                    packet.envelope.request_id)) {
                continue;
            }
            RuntimeCountryCommand command;
            std::string command_error;
            const bool decoded = RuntimeCountryPodAdapter::decode_command(
                packet, command, command_error);
            if (!decoded) {
                // A malformed packet has no POD payload to decode, but its
                // envelope still identifies the accepted request. Preserve
                // that identity so the terminal rejection is queryable
                // instead of disappearing as request_id=0.
                command.request_id = packet.envelope.request_id;
                command.producer_id = packet.envelope.producer_id;
                command.sequence = packet.envelope.sequence;
                command.requested_day = packet.envelope.requested_day;
                command.effective_day = packet.envelope.effective_day;
                command.opcode = packet.envelope.opcode;
                command.submit_order = packet.submit_order;
            }
            // The submitter's clock trails this worker's. Reschedule a late
            // intent onto the day being planned instead of refusing it;
            // requested_day still records what the player asked for.
            if (decoded && command.effective_day < day)
                command.effective_day = day;
            if (!decoded ||
                !_country_pod_authority.queue_command(command, command_error)) {
                error = command_error.empty()
                    ? "country_worker_command_rejected" : command_error;
                _country_pod_authority.remove_pending_commands(newly_queued_ids);
                newly_queued_commands.push_back(command);
                publish_country_command_terminals(
                    newly_queued_commands,
                    CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
                    _country_pod_authority.generation(), error.c_str());
                return false;
            }
            if (command.request_id != 0)
                newly_queued_ids.push_back(command.request_id);
            newly_queued_commands.push_back(command);
        }
        // Country AI: plan day D from the authority committed through D-1.
        // AI commands are tracked separately so a rejection never strands
        // them in _pending (plan_day fails the whole day on any bad command).
        std::vector<uint64_t> ai_ids;
        if (country_ai != nullptr && country_ai->due(day)) {
            std::string snapshot_error;
            if (_country_pod_authority.snapshot(_country_ai_snapshot, snapshot_error)) {
                const auto economy_view = copy_country_ai_economy_view();
                assert(!economy_view.data || economy_view.observe(_country_ai_economy_view_version));
                const auto digest = economy_view.data;
                std::vector<CountryAiCommand> planned;
                if (country_ai->plan(day, _country_ai_snapshot, _country_pod_catalog,
                                     digest.get(), planned)) {
                    for (uint32_t i = 0; i < planned.size(); ++i) {
                        RuntimeCountryCommand command =
                            CountryAiRuntime::to_runtime_command(planned[i], day, i);
                        command.request_id = allocate_command_request_id();
                        std::string queue_error;
                        if (!_country_pod_authority.queue_command(command, queue_error)) {
                            _country_pod_authority.remove_pending_commands(ai_ids);
                            ai_ids.clear();
                            country_ai->reject_staged(day, queue_error.c_str());
                            break;
                        }
                        ai_ids.push_back(command.request_id);
                    }
                }
            }
        }
        bool country_planned = _country_pod_authority.plan_day(
            day, input_generation, _country_pod_plan, error);
        if (!country_planned &&
            country_ai != nullptr &&
            _country_pod_authority.remove_pending_producer(COUNTRY_AI_PRODUCER_ID) > 0) {
            ai_ids.clear();
            if (country_ai != nullptr) country_ai->reject_staged(day, error.c_str());
            error.clear();
            country_planned = _country_pod_authority.plan_day(
                day, input_generation, _country_pod_plan, error);
        }
        if (!country_planned) {
            if (country_ai != nullptr) country_ai->abort(day);
            if (error.empty()) error = "country_worker_plan_failed";
            _country_pod_authority.remove_pending_commands(newly_queued_ids);
            publish_country_command_terminals(
                newly_queued_commands,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
                _country_pod_authority.generation(), error.c_str());
            return false;
        }
        _country_pod_plan_active = true;
        _country_peer_wait_preview_published = false;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            ++_country_worker_seal.boundary_id;
            if (_country_worker_seal.boundary_id == 0)
                _country_worker_seal.boundary_id = 1;
            _country_worker_seal.session_epoch = _country_worker_session_epoch;
            _country_worker_seal.day = day;
            _country_worker_seal.last_admitted_submit_order = admitted_submit_order;
            _country_worker_seal.expected_base_generation =
                _country_pod_plan.header.base_generation;
            _country_worker_seal.catalog_hash = _country_pod_catalog.catalog_hash;
            _country_worker_country_generation =
                _country_pod_plan.header.base_generation;
            _country_worker_day = day;
            _country_worker_continuation_index = 0;
            for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                CountryPeerIntentCode peer_opcode;
                std::string peer_opcode_error;
                if (!map_country_peer_intent(intent, peer_opcode,
                                              peer_opcode_error)) {
                    error = peer_opcode_error.empty()
                        ? "country_worker_peer_intent_invalid"
                        : peer_opcode_error;
                    break;
                }
                CountryPeerIntent peer;
                peer.opcode = peer_opcode;
                peer.request_id = intent.request_id != 0
                    ? intent.request_id : intent.source_id;
                peer.session_epoch = _country_worker_session_epoch;
                peer.country_generation = _country_pod_plan.header.base_generation;
                peer.peer_generation = 0;
                peer.day = intent.effective_day;
                peer.continuation_index = _country_worker_continuation_index;
                peer.country_slot = static_cast<int32_t>(
                    intent.target_handle & 0xffffffffULL);
                peer.technology = intent.payload[0] >= 0
                    ? static_cast<int32_t>(intent.payload[0]) : -1;
                peer.target_handle = intent.target_handle;
                // Stable per (country handle, technology), mirroring the sync
                // NativeCountryRuntime::make_peer_intent. Deriving it from the
                // per-day request id minted a brand-new Effect instance every
                // worker day, so the fire ACK could never be observed across
                // days and the technology stayed pending forever.
                peer.effect_instance_id = peer.technology >= 0
                    ? (((peer.target_handle & 0x00007fffffffffffULL) << 16U) |
                       static_cast<uint64_t>(peer.technology + 1))
                    : peer.request_id;
                peer.effect_generation =
                    static_cast<uint32_t>(peer.target_handle >> 32U);
                peer.idempotency_key = intent.idempotency_key != 0
                    ? intent.idempotency_key : peer.request_id;
                if (peer.request_id == 0) {
                    error = "country_worker_peer_intent_identity_invalid";
                    break;
                }
                if (_country_worker_intents.find(peer.request_id) !=
                    _country_worker_intents.end()) {
                    error = "country_worker_peer_intent_duplicate";
                    break;
                }
                if (_country_worker_intent_queue.size() >=
                    RUNTIME_DOMAIN_INTENT_CAPACITY) {
                    error = "country_worker_intent_capacity_exceeded";
                    break;
                }
                _country_worker_intents[peer.request_id] = peer;
                _country_worker_intent_queue.push_back(peer.request_id);
                ++_country_worker_continuation_index;
            }
            if (error.empty()) {
                _country_worker_protocol.pending_intents = static_cast<uint32_t>(
                    std::min<size_t>(_country_worker_intents.size(),
                                     std::numeric_limits<uint32_t>::max()));
                _country_worker_protocol.queued_intents = static_cast<uint32_t>(
                    std::min<size_t>(_country_worker_intent_queue.size(),
                                     std::numeric_limits<uint32_t>::max()));
                _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
                bind_shadow_country_peer_mirrors_locked();
            }
        }
        if (!error.empty()) {
            _country_pod_authority.discard_plan();
            std::vector<uint64_t> plan_request_ids;
            plan_request_ids.reserve(_country_pod_plan.commands.size());
            for (const RuntimeCountryCommand &command : _country_pod_plan.commands) {
                if (command.request_id != 0)
                    plan_request_ids.push_back(command.request_id);
            }
            _country_pod_authority.remove_pending_commands(plan_request_ids);
            _country_pod_plan_active.store(false, std::memory_order_release);
            _country_peer_wait_preview_published = false;
            publish_country_command_terminals(
                _country_pod_plan.commands,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
                _country_pod_authority.generation(), error.c_str());
            return false;
        }
    } else {
        // An open plan is parked on peers. Fold newly arrived Country packets
        // into plan.next_state so research enqueue is visible via preview
        // publish and lands in the eventual commit — not stranded until day+1.
        //
        // Late-fold applies packets one at a time, so it cannot honour the
        // atomic CONSUME_TREASURY_GOODS(21) + GRANT_TECHNOLOGY(4) era batch:
        // a rejected consume would still let the grant through. Leave those
        // producers' 21/4 packets unfolded; the retain path replays them into
        // the next plan_day, which validates the whole batch atomically.
        std::vector<uint32_t> era_batch_producers;
        // Peace/annex batches (opcodes 23/24/27 with their TRANSFER_TERRITORY
        // clauses) are atomic as well; never late-fold any packet of such a
        // producer so the next plan_day validates the batch as a whole.
        std::vector<uint32_t> peace_batch_producers;
        for (const RuntimeCommandPacket &packet : day_commands) {
            if (packet.envelope.domain ==
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY) &&
                (packet.envelope.opcode == 23 || packet.envelope.opcode == 24 ||
                 packet.envelope.opcode == 27) &&
                std::find(peace_batch_producers.begin(), peace_batch_producers.end(),
                          packet.envelope.producer_id) == peace_batch_producers.end())
                peace_batch_producers.push_back(packet.envelope.producer_id);
        }
        for (const RuntimeCommandPacket &packet : day_commands) {
            if (packet.envelope.domain ==
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY) &&
                packet.envelope.opcode == 21 &&
                std::find(era_batch_producers.begin(), era_batch_producers.end(),
                          packet.envelope.producer_id) == era_batch_producers.end())
                era_batch_producers.push_back(packet.envelope.producer_id);
        }
        for (const RuntimeCommandPacket &packet : day_commands) {
            if (packet.envelope.domain !=
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY)) {
                continue;
            }
            if (packet.envelope.request_id == 0) continue;
            if ((packet.envelope.opcode == 21 || packet.envelope.opcode == 4) &&
                std::find(era_batch_producers.begin(), era_batch_producers.end(),
                          packet.envelope.producer_id) != era_batch_producers.end())
                continue;
            if (std::find(peace_batch_producers.begin(), peace_batch_producers.end(),
                          packet.envelope.producer_id) != peace_batch_producers.end())
                continue;
            if (packet.envelope.producer_id == COUNTRY_AI_PRODUCER_ID &&
                country_ai_for_worker() != nullptr)
                continue;
            CountryCommandReceipt terminal;
            if (try_country_command_terminal(packet.envelope.request_id, terminal))
                continue;
            bool in_open_plan = false;
            for (const RuntimeCountryCommand &planned :
                    _country_pod_plan.commands) {
                if (planned.request_id == packet.envelope.request_id) {
                    in_open_plan = true;
                    break;
                }
            }
            if (in_open_plan) continue;
            if (_country_pod_authority.has_pending_request(
                    packet.envelope.request_id)) {
                continue;
            }
            RuntimeCountryCommand command;
            std::string command_error;
            if (!RuntimeCountryPodAdapter::decode_command(
                    packet, command, command_error)) {
                continue;
            }
            command.effective_day = day;
            if (!country_core_apply_command(
                    _country_pod_plan.next_state, _country_pod_catalog, command,
                    _country_pod_plan, command_error)) {
                publish_country_command_terminals(
                    {command}, CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
                    _country_pod_authority.generation(), command_error.c_str());
                static std::atomic<int> s_late_fold_left{8};
                if (s_late_fold_left.fetch_sub(
                        1, std::memory_order_relaxed) > 0) {
                    pk::log_info(
                        "[country][active] late-fold rejected day=%d "
                        "request=%d reason=%s",
                        day,
                        static_cast<int64_t>(packet.envelope.request_id),
                        command_error.c_str());
                }
                continue;
            }
            _country_pod_plan.commands.push_back(command);
            _country_pod_plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
            _country_pod_plan.header.work_units =
                static_cast<uint64_t>(_country_pod_plan.commands.size());
            // Enqueue / move landed after plan_day already spent today's
            // research allocation. Catch up so the new queue head can spend
            // before peer-wait preview / commit — otherwise starter stock
            // (== first knowledge cost) sits idle until day+1 while the UI
            // already shows 研究中.
            if (command.opcode == 6 || command.opcode == 8) {
                std::string research_error;
                if (!_country_pod_authority.catch_up_research_day(
                        _country_pod_plan.next_state, day, _country_pod_plan,
                        research_error)) {
                    static std::atomic<int> s_late_research_left{8};
                    if (s_late_research_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        pk::log_info(
                            "[country][active] late-fold research catch-up "
                            "failed day=%d reason=%s",
                            day, research_error.c_str());
                    }
                }
            }
            // Force a fresh preview publish on the next peer-wait pass.
            _country_peer_wait_preview_published = false;
            static std::atomic<int> s_late_fold_ok_left{8};
            if (s_late_fold_ok_left.fetch_sub(
                    1, std::memory_order_relaxed) > 0) {
                pk::log_info(
                    "[country][active] late-fold ok day=%d request=%d "
                    "opcode=%d",
                    day,
                    static_cast<int64_t>(packet.envelope.request_id),
                    static_cast<int64_t>(command.opcode));
            }
        }
    }

    if (!_country_pod_plan.economy_requests.empty()) {
        std::vector<RuntimeEconomyAssetRequest> unpublished;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            unpublished.reserve(_country_pod_plan.economy_requests.size());
            for (const RuntimeEconomyAssetRequest &request :
                    _country_pod_plan.economy_requests) {
                if (_country_economy_asset_requests.find(request.request_id) ==
                        _country_economy_asset_requests.end()) {
                    unpublished.push_back(request);
                }
            }
        }
        std::string asset_error;
        if (!publish_country_economy_asset_requests(unpublished, asset_error)) {
            error = asset_error.empty()
                ? "country_worker_economy_request_failed" : asset_error;
            commit.preflight_ok = 0;
            return false;
        }
    }

    std::string origin_error;
    prepare_economy_origin_country_assets(origin_error);
    if (!origin_error.empty()) {
        error = origin_error;
        commit.preflight_ok = 0;
        return false;
    }

    bool economy_asset_waiting = false;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        for (const auto &entry : _country_economy_asset_requests) {
            const RuntimeEconomyAssetRequest &request = entry.second;
            // Economy-origin fiscal/peer assets are prepared here so Country
            // cash staging is ready, but only the later ECONOMY stage can
            // service+terminal them. Waiting on those rows before ECONOMY
            // runs deadlocks the day the first time tax/settlement parks a
            // continuation (Country preflight forever, Economy never resumes).
            if (request.origin_domain ==
                static_cast<uint32_t>(RuntimeDomainId::ECONOMY)) {
                continue;
            }
            if (request.day > day ||
                _country_economy_asset_terminal_results.find(entry.first) !=
                    _country_economy_asset_terminal_results.end()) {
                continue;
            }
            economy_asset_waiting = true;
            break;
        }
    }
    if (economy_asset_waiting) {
        // Do not soft-commit Country to escape this wait. Host liveness must
        // pump peers; soft-commit here previously raced with Climate capacity
        // and stranded research ACKs. Park with a stall bit; timeout → fault.
        note_day_stall(RUNTIME_DAY_STALL_COUNTRY_PEER |
                           RUNTIME_DAY_STALL_FISCAL_PEER,
                       day);
        if (fault_if_peer_stall_timed_out(
                day, "country_economy_asset_peer_stall_timeout")) {
            error = "country_economy_asset_peer_stall_timeout";
            commit.preflight_ok = 0;
            return false;
        }
        error = "country_economy_asset_results_pending";
        commit.preflight_ok = 0;
        commit.continuation_pending = 1;
        return false;
    }

    std::vector<RuntimeDomainAck> acks;
    acks.reserve(_country_pod_plan.intents.size());
    bool waiting = false;
    bool rejected = false;
    std::string rejection_reason;
    uint64_t rejected_request_id = 0;
    CountryPeerIntentCode rejected_opcode =
        CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT;
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
        _country_worker_protocol.pending_intents = static_cast<uint32_t>(
            std::min<size_t>(_country_worker_intents.size(),
                             std::numeric_limits<uint32_t>::max()));
        _country_worker_protocol.queued_intents = static_cast<uint32_t>(
            std::min<size_t>(_country_worker_intent_queue.size(),
                             std::numeric_limits<uint32_t>::max()));
    }
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
    if (waiting) {
        // Soft-commit must not be used to escape peer waits (ring pressure or
        // inspected-PENDING). Uninspected ENSURE needs Host peer pump; wiping
        // or closing the day early parks techs at 待生效. Keep rejected-only
        // soft-commit below; here we park + stall-bit + timeout fault.
        note_day_stall(RUNTIME_DAY_STALL_COUNTRY_PEER |
                           RUNTIME_DAY_STALL_EFFECT_ACK,
                       day);
        // Research enqueue / weight changes already sit in plan.next_state.
        // Preview-publish them so the UI left queue updates while Effect peers
        // are still PENDING — without closing the Country calendar boundary.
        if (!_country_peer_wait_preview_published &&
            ((_country_pod_plan.header.dirty_families &
              RUNTIME_DIRTY_COUNTRY_STATE) != 0u ||
             !_country_pod_plan.commands.empty())) {
            std::string preview_error;
            if (publish_country_plan_preview_snapshot(preview_error)) {
                _country_peer_wait_preview_published = true;
                static std::atomic<int> s_preview_left{8};
                if (s_preview_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                    std::fprintf(stderr,
                                 "[country][active] peer-wait preview day=%lld "
                                 "commands=%llu dirty=0x%x\n",
                                 static_cast<long long>(day),
                                 static_cast<unsigned long long>(
                                     _country_pod_plan.commands.size()),
                                 _country_pod_plan.header.dirty_families);
                    std::fflush(stderr);
                    pk::log_info(
                        "[country][active] peer-wait preview day=%d "
                        "commands=%d",
                        day,
                        static_cast<int64_t>(_country_pod_plan.commands.size()));
                }
            }
        }
        // Drain only envs for this worker day (and earlier). Popping through
        // climate_committed when Climate is ahead erases futures Host already
        // queued for catch-up and leaves the FIFO empty/mismatched.
        if (_environment_ring.pop_while_day_at_most(day) > 0u) {
            _climate_wait_cv.notify_all();
            _control_cv.notify_all();
        }
        if (fault_if_peer_stall_timed_out(
                day, "country_worker_peer_stall_timeout")) {
            error = "country_worker_peer_stall_timeout";
            commit.preflight_ok = 0;
            return false;
        }
        error = "country_worker_peer_results_pending";
        commit.preflight_ok = 0;
        commit.continuation_pending = 1;
        return false;
    }
    if (rejected) {
        // A peer rejection closes the Country semantic boundary. Country-side
        // commands, research consumption and pending activation remain
        // committed, while the peer operation is retained as a next-day retry
        // barrier. This is deliberately different from discard_plan():
        // discarding would replay the same research spend on the next day.
        if (!_country_pod_authority.commit_rejected_day(
                _country_pod_plan, error)) {
            _country_pod_authority.discard_plan();
            _country_pod_plan_active.store(false, std::memory_order_release);
            _country_peer_wait_preview_published = false;
            set_fault(error.empty() ? "country_worker_rejection_commit_failed" :
                      error.c_str());
            if (error.empty()) error = "country_worker_rejection_commit_failed";
            commit.preflight_ok = 0;
            return false;
        }
        publish_country_command_terminals(
            _country_pod_plan.commands, CountryCommandReceiptCode::COMMITTED,
            _country_pod_authority.generation(), nullptr);
        commit_country_ai_day(_country_pod_authority.committed_day());
        _country_pod_plan_active.store(false, std::memory_order_release);
        _country_peer_wait_preview_published = false;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            _country_worker_protocol.has_unreported_rejection = 1;
            _country_worker_protocol.rejected_intents = std::max<uint32_t>(
                1u, _country_worker_protocol.rejected_intents);
            _country_worker_protocol.retry_day = day < INT64_MAX ? day + 1 : day;
            _country_worker_protocol.rejected_request_id = rejected_request_id;
            _country_worker_protocol.rejected_opcode = rejected_opcode;
            country_peer_copy_reason(_country_worker_protocol.rejection_reason,
                                     rejection_reason.c_str());
            for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                const uint64_t request_id = intent.request_id != 0
                    ? intent.request_id : intent.source_id;
                _country_worker_intents.erase(request_id);
                _country_worker_results.erase(request_id);
            }
            _country_worker_intent_queue.erase(
                std::remove_if(_country_worker_intent_queue.begin(),
                               _country_worker_intent_queue.end(),
                    [&](uint64_t request_id) {
                        return _country_worker_intents.find(request_id) ==
                            _country_worker_intents.end();
                    }), _country_worker_intent_queue.end());
            _country_worker_protocol.pending_intents = 0;
            _country_worker_protocol.queued_intents = static_cast<uint32_t>(
                std::min<size_t>(_country_worker_intent_queue.size(),
                                 std::numeric_limits<uint32_t>::max()));
        }
        // Country peers are done; do not wipe Economy fiscal/input stalls —
        // those still park the day until fiscal peers / capture catch up.
        clear_day_stall_bits(RUNTIME_DAY_STALL_COUNTRY_PEER |
                             RUNTIME_DAY_STALL_EFFECT_ACK |
                             RUNTIME_DAY_STALL_IDEOLOGY_ACK);
        for (auto &character : _country_pod_fallback_reason) {
            character.store('\0', std::memory_order_release);
        }
        std::string snapshot_error;
        if (!publish_country_worker_snapshot(
                _country_pod_plan.header.dirty_families, snapshot_error)) {
            error = snapshot_error.empty() ? "country_worker_snapshot_failed" :
                snapshot_error;
            commit.preflight_ok = 0;
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            queue_country_milestone_notifications_locked(
                std::atomic_load_explicit(&_country_snapshot,
                                          std::memory_order_acquire));
        }
        commit.completed_domain_mask |= runtime_domain_mask(
            RuntimeDomainId::COUNTRY);
        commit.dirty_families |= _country_pod_plan.header.dirty_families;
        commit.work_units += _country_pod_plan.header.work_units;
        ++commit.completed_stage_count;
        error.clear();
        return true;
    }
    if (!flush_country_economy_asset_commits(error, 0, false, day)) {
        commit.preflight_ok = 0;
        return false;
    }
    if (!_country_pod_authority.commit_day(_country_pod_plan, acks, error)) {
        _country_pod_authority.discard_plan();
        _country_pod_plan_active.store(false, std::memory_order_release);
        _country_peer_wait_preview_published = false;
        set_fault(error.empty() ? "country_worker_commit_failed" : error.c_str());
        if (error.empty()) error = "country_worker_commit_failed";
        publish_country_command_terminals(
            _country_pod_plan.commands,
            CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
            _country_pod_authority.generation(), error.c_str());
        commit.preflight_ok = 0;
        return false;
    }
    publish_country_command_terminals(
        _country_pod_plan.commands, CountryCommandReceiptCode::COMMITTED,
        _country_pod_authority.generation(), nullptr);
    commit_country_ai_day(_country_pod_authority.committed_day());
    _country_pod_plan_active.store(false, std::memory_order_release);
    _country_peer_wait_preview_published = false;
    // Same as soft-reject path: Country commit must not clear Economy stalls.
    clear_day_stall_bits(RUNTIME_DAY_STALL_COUNTRY_PEER |
                         RUNTIME_DAY_STALL_EFFECT_ACK |
                         RUNTIME_DAY_STALL_IDEOLOGY_ACK);
    for (auto &character : _country_pod_fallback_reason) {
        character.store('\0', std::memory_order_release);
    }
    RuntimeCountryPodSnapshot committed_snapshot;
    std::string snapshot_error;
    if (!_country_pod_authority.snapshot(committed_snapshot, snapshot_error)) {
        error = snapshot_error.empty() ? "country_worker_snapshot_failed" :
            snapshot_error;
        commit.preflight_ok = 0;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        const std::shared_ptr<const RuntimeCountryPodSnapshot> previous =
            _country_committed_snapshot;
        _country_read_view_generation = committed_snapshot.generation;
        _country_read_view_patch_base_generation = previous != nullptr
            ? previous->generation : 0;
        _country_read_view_dirty_families = _country_pod_plan.header.dirty_families;
        _country_read_view_changed_cells.clear();
        _country_read_view_changed_owners.clear();
        const bool same_cell_shape = previous != nullptr &&
            previous->cell_country_slot.size() ==
                committed_snapshot.cell_country_slot.size();
        for (size_t cell = 0; cell < committed_snapshot.cell_country_slot.size();
             ++cell) {
            if (same_cell_shape &&
                previous->cell_country_slot[cell] ==
                    committed_snapshot.cell_country_slot[cell]) {
                continue;
            }
            _country_read_view_changed_cells.push_back(static_cast<int32_t>(cell));
            _country_read_view_changed_owners.push_back(
                committed_snapshot.cell_country_slot[cell]);
        }
        if (!_country_read_view_changed_cells.empty())
            _country_read_view_territory_generation = _country_read_view_generation;
        auto committed_copy = std::make_shared<RuntimeCountryPodSnapshot>(
            std::move(committed_snapshot));
        _country_committed_snapshot = committed_copy;
        _country_worker_country_generation = committed_copy->generation;
        _country_worker_day = committed_copy->committed_day;
        record_country_parity_locked(*committed_copy);
        std::shared_ptr<const RuntimeCountryPodSnapshot> committed_view =
            committed_copy;
        std::atomic_store_explicit(&_country_snapshot, committed_view,
                                   std::memory_order_release);
        std::atomic_store_explicit(&_country_economy_audit_snapshot,
                                   committed_view, std::memory_order_release);
        queue_country_milestone_notifications_locked(committed_view);
        for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
            const uint64_t request_id = intent.request_id != 0
                ? intent.request_id : intent.source_id;
            _country_worker_intents.erase(request_id);
            _country_worker_results.erase(request_id);
        }
        _country_worker_protocol.pending_intents = 0;
        _country_worker_protocol.queued_intents = static_cast<uint32_t>(
            std::min<size_t>(_country_worker_intent_queue.size(),
                             std::numeric_limits<uint32_t>::max()));
        _country_worker_protocol.retry_day = -1;
        _country_worker_protocol.rejected_intents = 0;
        _country_worker_protocol.has_unreported_rejection = 0;
        _country_worker_protocol.rejected_request_id = 0;
        country_peer_copy_reason(_country_worker_protocol.rejection_reason, "");
        const uint64_t boundary_id = _country_worker_seal.boundary_id;
        _country_worker_seal = CountryBoundarySeal{};
        _country_worker_seal.boundary_id = boundary_id;
    }
    commit.completed_domain_mask |= runtime_domain_mask(RuntimeDomainId::COUNTRY);
    commit.dirty_families |= _country_pod_plan.header.dirty_families;
    commit.work_units += _country_pod_plan.header.work_units;
    ++commit.completed_stage_count;
    (void)committed_snapshot;
    return true;
}

} // namespace pk
