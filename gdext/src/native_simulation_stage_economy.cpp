#include <cassert>
#include "native_simulation_day_context.h"
#include "economy_runtime.h"
#include "economy_authority_transfer.h"
#include "pk_log.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {

static void append_economy_fact_event_packets(
        const std::vector<NativeEconomyRuntime::CommittedGameplayFact> &facts,
        int64_t day, uint64_t &sequence, std::vector<RuntimeCommandPacket> &out) {
    size_t index = 0;
    while (index < facts.size()) {
        std::vector<uint8_t> payload;
        payload.reserve(8u + RUNTIME_EVENTS_MAX_BATCH_RECORDS * 76u);
        const auto put_u32 = [&payload](uint32_t value) {
            for (int i = 0; i < 4; ++i)
                payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
        };
        const auto put_u64 = [&payload](uint64_t value) {
            for (int i = 0; i < 8; ++i)
                payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
        };
        put_u32(RUNTIME_EVENTS_ABI_VERSION);
        put_u32(0u);
        uint32_t rows = 0;
        for (; index < facts.size() && rows < RUNTIME_EVENTS_MAX_BATCH_RECORDS; ++index) {
            const NativeEconomyRuntime::CommittedGameplayFact &fact = facts[index];
            int32_t event_type = 0;
            int32_t payload_schema = 0;
            if (fact.kind == NativeEconomyRuntime::GAMEPLAY_FACT_CONSTRUCTION_COMPLETED ||
                !NativeEconomyRuntime::gameplay_fact_event(fact.kind, event_type,
                                                           payload_schema))
                continue;
            put_u64(static_cast<uint64_t>(day));
            put_u32(9u);
            put_u32(static_cast<uint32_t>(event_type));
            put_u32(1u);
            put_u32(static_cast<uint32_t>(fact.flags));
            put_u64(fact.entity_handle);
            put_u32(static_cast<uint32_t>(fact.entity_id));
            put_u32(static_cast<uint32_t>(fact.cell));
            put_u32(static_cast<uint32_t>(payload_schema));
            put_u64(static_cast<uint64_t>(fact.value));
            for (int32_t value : fact.payload) put_u32(static_cast<uint32_t>(value));
            put_u64(0u);
            ++rows;
        }
        if (rows == 0) continue;
        for (int i = 0; i < 4; ++i)
            payload[4 + i] = static_cast<uint8_t>((rows >> (i * 8)) & 0xffu);
        RuntimeCommandPacket packet{};
        ++sequence;
        packet.envelope.request_id = 0xEC0F000000000000ull | sequence;
        packet.envelope.producer_id = 78u;
        packet.envelope.sequence = sequence;
        packet.envelope.requested_day = day;
        packet.envelope.effective_day = day;
        packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
        packet.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
        packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
        if (payload.size() > packet.payload.size()) continue;
        std::memcpy(packet.payload.data(), payload.data(), payload.size());
        out.push_back(packet);
    }
}

bool NativeSimulationHost::stage_economy(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &environment = day.environment;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    auto &gameplay_event_commands = day.gameplay_event_commands;
    if (stage.domain == RuntimeDomainId::ECONOMY &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::ECONOMY)) != 0u &&
        !plan.context.freeze_reads.register_read(
            runtime_domain_mask(RuntimeDomainId::ECONOMY), plan.context.frozen_input,
            plan.context.day, plan.context.input_generation)) {
        commit.preflight_ok = 0;
        return false;
    }
    if (stage.domain == RuntimeDomainId::ECONOMY &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::ECONOMY)) != 0u) {
        AtomicCounterScope economy_scope(_economy_inflight_mutations);
        // ACTIVE Economy production: compact_slice (default) or StageOps
        // Host day loop when effective writer is STAGE_OPS (opt-in; start
        // gate still refuses until BOUNDED_KERNELS lands).
        if (climate_authority_requested && !active_climate_ok) {
            // No peer wake source — arm a stall so day-wait timeout can fire
            // instead of parking forever with stall=0x0.
            note_day_stall(RUNTIME_DAY_STALL_FISCAL_PEER, plan.context.day);
            {
                static int s_econ_climate_gate_left = 8;
                if (s_econ_climate_gate_left-- > 0) {
                    pk::log_info(
                        "[economy-climate-gate] day=%d climate_ok=0 "
                        "stall=0x%x ring=%d",
                        plan.context.day,
                        static_cast<int64_t>(day_stall_reason_mask()),
                        static_cast<int64_t>(_environment_ring.size()));
                }
            }
            stage.completed = 0;
            return true;
        }
        if (_economy_production_runtime == nullptr) {
            // Fail open: leave incomplete so the full mask does not grant
            // ECONOMY suppression without a production runner.
            note_day_stall(RUNTIME_DAY_STALL_FISCAL_PEER, plan.context.day);
            stage.completed = 0;
            return true;
        }
        const EconomyProductionWriter production_writer =
            economy_production_writer_effective();
        open_granted_economy_d7_gates(*this, *_economy_production_runtime);
        const auto economy_attempt_started = std::chrono::steady_clock::now();
        std::string economy_error;
        bool economy_day_done = false;
        uint64_t economy_work = 0;
        bool economy_fatal = false;
        bool economy_pending_input = false;
        if (environment && environment->economy_input &&
            !_economy_production_runtime->epoch_active() &&
            (_economy_production_runtime->needs_environment_capture(plan.context.day) ||
             _economy_production_runtime->needs_building_context_capture(plan.context.day))) {
            // The main-thread climate slots copied into economy_input only
            // catch up when this worker's climate writeback is applied, so
            // how many days they lag depends on machine speed. When Climate
            // already committed this day here, read its store instead.
            const RuntimeEconomyDayInput *economy_day_input =
                environment->economy_input.get();
            RuntimeEconomyDayInput worker_climate_input;
            RuntimeClimateCommittedView climate_view;
            if (climate_authority_requested && active_climate_ok &&
                _climate_authority.copy_committed_view(plan.context.day,
                    economy_day_input->cell_count, economy_day_input->fields[0].size(),
                    climate_view)) {
                assert(_climate_authority.observe_economy_view(climate_view));
                worker_climate_input = *economy_day_input;
                for (size_t field = 0; field < 7; ++field)
                    worker_climate_input.fields[field] = std::move(climate_view.fields[field]);
                worker_climate_input.fields[8] = std::move(climate_view.fields[7]);
                worker_climate_input.climate_u8[0] = std::move(climate_view.categories[0]);
                worker_climate_input.climate_u8[1] = std::move(climate_view.categories[1]);
                if (climate_view.categories[2].size() == economy_day_input->fields[0].size())
                    worker_climate_input.geography[0] = std::move(climate_view.categories[2]);
                if (climate_view.categories[3].size() == economy_day_input->fields[0].size())
                    worker_climate_input.geography[2] = std::move(climate_view.categories[3]);
                economy_day_input = &worker_climate_input;
            }
            if (std::FILE *trace = sim_day_trace_file()) {
                SimTraceLock trace_lock(trace);
                std::fprintf(trace, "[economy-input] day=%lld worker_climate=%d",
                    static_cast<long long>(plan.context.day),
                    economy_day_input == &worker_climate_input ? 1 : 0);
                for (size_t i = 0; i < economy_day_input->fields.size(); ++i)
                    std::fprintf(trace, " f%zu=%llu", i, static_cast<unsigned long long>(
                        sim_trace_vector_hash(economy_day_input->fields[i])));
                for (size_t i = 0; i < economy_day_input->geography.size(); ++i)
                    std::fprintf(trace, " g%zu=%llu", i, static_cast<unsigned long long>(
                        sim_trace_vector_hash(economy_day_input->geography[i])));
                for (size_t r = 0; r < economy_day_input->reserves.size(); ++r)
                    std::fprintf(trace, " r%zu=%llu c%zu=%llu", r,
                        static_cast<unsigned long long>(sim_trace_vector_hash(economy_day_input->reserves[r])),
                        r, static_cast<unsigned long long>(sim_trace_vector_hash(economy_day_input->changes[r])));
                std::fprintf(trace, " env=%d build=%d\n",
                    _economy_production_runtime->needs_environment_capture(plan.context.day) ? 1 : 0,
                    _economy_production_runtime->needs_building_context_capture(plan.context.day) ? 1 : 0);
            }
            if (economy_day_input->day != plan.context.day ||
                !_economy_production_runtime->capture_worker_day_input(
                    *economy_day_input, economy_error)) {
                set_fault(economy_error.empty() ? "economy_worker_input_day_mismatch" : economy_error.c_str());
                stage.completed = 0;
                commit.preflight_ok = 0;
                return true;
            }
        }
        const auto economy_asset_pending_reason = [](const std::string &reason) {
            return runtime_country_asset_pending_reason(reason) ||
                reason == "fiscal_reserve_peer_results" ||
                // Mid-epoch fiscal return/collect uses the same origin-asset
                // prepare loop as epoch-open reserve. Omitting this reason
                // soft-completes ECONOMY without prepare and deadlocks the
                // next Country stage waiting for an Economy terminal.
                reason == "fiscal_peer_results" ||
                reason == "fiscal_settlement_peer_pending" ||
                reason == "country_research_peer_results" ||
                reason == "economy_stage_ops_prelude_pending_input";
        };
        // Country prepares Economy-origin assets in its own stage, which
        // runs earlier in the day plan. An enqueue that lands during this
        // ECONOMY visit must prepare+service in-place or the worker parks
        // on CV with a full Climate ring and WorldClock never advances.
        // Tax settlement can need one peer txn per country × return/collect
        // (≥12 on a 6-country map); keep preparing until the fiscal peer
        // barrier clears or we hit a hard safety cap.
        constexpr int kMaxEconomyAssetRounds = 64;
        for (int asset_round = 0; asset_round < kMaxEconomyAssetRounds;
             ++asset_round) {
            economy_pending_input = false;
            economy_fatal = false;
            economy_day_done = false;
            if (production_writer == EconomyProductionWriter::STAGE_OPS) {
                for (int slice = 0; slice < 64; ++slice) {
                    bool slice_done = false;
                    bool pending_input = false;
                    if (!worker_run_stage_ops_slice(
                            plan.context.day, plan.context.input_generation,
                            economy_error, &slice_done, &pending_input)) {
                        economy_fatal = true;
                        break;
                    }
                    if (pending_input) {
                        economy_pending_input = true;
                        break;
                    }
                    ++economy_work;
                    if (slice_done) {
                        economy_day_done = true;
                        break;
                    }
                }
            } else {
                for (int slice = 0; slice < 64; ++slice) {
                    bool slice_done = false;
                    bool pending_input = false;
                    if (!_economy_production_runtime->worker_run_compact_slice(
                            plan.context.day, economy_error, &slice_done,
                            &pending_input)) {
                        economy_fatal = true;
                        break;
                    }
                    if (pending_input) {
                        economy_pending_input = true;
                        break;
                    }
                    ++economy_work;
                    if (slice_done) {
                        economy_day_done = true;
                        break;
                    }
                }
            }
            if (economy_fatal || !economy_pending_input) break;
            if (!economy_asset_pending_reason(economy_error)) break;
            // The Country plan window can only close in the next Country
            // stage. Nothing was enqueued, so re-running prepare here just
            // burns the round budget; soft-complete and let the next pulse
            // retry the parked Economy stage.
            if (economy_error == "country_economy_asset_country_plan_pending")
                break;
            std::string prepare_error;
            const uint32_t prepared =
                prepare_economy_origin_country_assets(prepare_error);
            if (!prepare_error.empty()) {
                economy_error = prepare_error;
                economy_fatal = true;
                break;
            }
            // Prepare only publishes COUNTRY_PREPARED into the poll queue.
            // StageOps research drain services at the start of the next
            // advance; if that round still parks, an explicit service here
            // closes the same-day Host peer before Climate capacity fills.
            if (_economy_production_runtime != nullptr) {
                std::string service_error;
                if (!EconomyAuthorityTransfer::service_country_requests(
                             *_economy_production_runtime, 64, service_error) &&
                    !runtime_country_asset_pending_reason(service_error) &&
                    !service_error.empty()) {
                    economy_error = service_error;
                    economy_fatal = true;
                    break;
                }
            }
            if (prepared == 0u) {
                // Request may already be COUNTRY_PREPARED/pollable from an
                // earlier prepare. Keep slicing so service can terminal it
                // instead of parking the day with an in-flight asset.
                continue;
            }
        }
        publish_economy_tax_diag(
            economy_error, static_cast<uint32_t>(economy_work));
        if (economy_fatal) {
            std::fprintf(stderr, "[economy-worker-fatal] day=%lld phase=%u stage=%u reason=%s\n",
                static_cast<long long>(plan.context.day), static_cast<unsigned>(_stage_ops_day_phase),
                _economy_pod_authority.planned_stage_index(), economy_error.c_str());
            set_fault(economy_error.empty()
                          ? (production_writer ==
                                     EconomyProductionWriter::STAGE_OPS
                                 ? "economy_worker_stage_ops_fatal"
                                 : "economy_worker_compact_fatal")
                          : economy_error.c_str());
            stage.completed = 0;
            commit.preflight_ok = 0;
            return true;
        }
        if (economy_pending_input) {
            if (economy_error == "same_day_environment_not_captured" ||
                economy_error == "same_day_building_context_not_captured") {
                _economy_input_requested_day.store(plan.context.day,
                    std::memory_order_release);
                note_day_stall(RUNTIME_DAY_STALL_ECONOMY_INPUT,
                               plan.context.day);
                stage.completed = 0;
                return true;
            }
            if (economy_asset_pending_reason(economy_error)) {
                // Park ECONOMY with a stall bit. Do not soft-complete the
                // domain as done — that was a deadlock escape that hid
                // fiscal peers. Drain Climate-absorbed env slots so Host
                // capacity recovers while liveness pumps peers.
                note_day_stall(RUNTIME_DAY_STALL_FISCAL_PEER,
                               plan.context.day);
                const int64_t climate_committed =
                    _climate_authority.committed_day();
                if (climate_committed >= 0 &&
                    _environment_ring.pop_while_day_at_most(
                        climate_committed) > 0u) {
                    _climate_wait_cv.notify_all();
                    _control_cv.notify_all();
                }
                if (fault_if_peer_stall_timed_out(
                        plan.context.day,
                        "economy_fiscal_peer_stall_timeout")) {
                    stage.completed = 0;
                    commit.preflight_ok = 0;
                    return true;
                }
                {
                    static int s_fiscal_stall_left = 12;
                    if (s_fiscal_stall_left-- > 0) {
                        pk::log_info(
                            "[economy-fiscal-stall] day=%d reason=%s "
                            "stall=0x%x work=%d ring=%d climate_committed=%d",
                            plan.context.day,
                            std::string(economy_error.c_str()).c_str(),
                            static_cast<int64_t>(day_stall_reason_mask()),
                            static_cast<int64_t>(economy_work),
                            static_cast<int64_t>(_environment_ring.size()),
                            climate_committed);
                    }
                }
                commit.continuation_pending = 1;
                stage.dirty_families = RUNTIME_DIRTY_ECONOMY_UI;
                stage.work_units = economy_work;
                stage.completed = 0;
                return true;
            }
            // Any other pending_input must still arm a stall bit. Parking
            // with stall=0x0 + missing=ECONOMY waits on CV with no wake
            // source, fills the Climate ring, and freezes WorldClock.
            note_day_stall(RUNTIME_DAY_STALL_FISCAL_PEER, plan.context.day);
            {
                static int s_unknown_pending_left = 12;
                if (s_unknown_pending_left-- > 0) {
                    pk::log_info(
                        "[economy-pending-stall] day=%d reason=%s "
                        "stall=0x%x work=%d ring=%d",
                        plan.context.day,
                        std::string(economy_error.empty()
                                          ? "pending_input"
                                          : economy_error.c_str()).c_str(),
                        static_cast<int64_t>(day_stall_reason_mask()),
                        static_cast<int64_t>(economy_work),
                        static_cast<int64_t>(_environment_ring.size()));
                }
            }
            if (fault_if_peer_stall_timed_out(
                    plan.context.day,
                    "economy_pending_input_stall_timeout")) {
                stage.completed = 0;
                commit.preflight_ok = 0;
                return true;
            }
            commit.continuation_pending = 1;
            stage.dirty_families = RUNTIME_DIRTY_ECONOMY_UI;
            stage.work_units = economy_work;
            stage.completed = 0;
            return true;
        }
        {
            // Apply any terminals produced by the same-day asset service
            // before later domains / M5 observe Country cash.
            std::string flush_error;
            if (!flush_country_economy_asset_commits(flush_error)) {
                set_fault(flush_error.empty()
                    ? "country_economy_asset_flush_failed"
                    : flush_error.c_str());
                stage.completed = 0;
                commit.preflight_ok = 0;
                return true;
            }
        }
        // slice done 也可能表示空闲或前置领域尚未就绪，不能伪造 epoch 提交。
        const auto economy_formulas_finished = std::chrono::steady_clock::now();
        _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_FORMULAS);
        economy_day_done = economy_day_done &&
            !_economy_production_runtime->epoch_active() &&
            _economy_production_runtime->last_committed_day() >= 0;
        // Soft-complete even a partial pulse (epoch still in progress) so
        // the per-domain grant can include ECONOMY; continuation resumes on
        // the next worker day the same way sync pulses resume.
        stage.dirty_families = RUNTIME_DIRTY_ECONOMY_UI;
        stage.work_units = economy_work;
        stage.completed = 1;
        commit.dirty_families |= stage.dirty_families;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::ECONOMY);
        ++commit.completed_stage_count;
        // The synchronous fact bridge is skipped while the worker owns the
        // economy, so committed facts are drained here even when no Events
        // journal will take them.
        {
            std::vector<NativeEconomyRuntime::CommittedGameplayFact> facts;
            if (_economy_production_runtime->drain_committed_gameplay_facts(facts) &&
                !facts.empty() &&
                (_requested_authority_mask.load(std::memory_order_acquire) &
                 runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u) {
                append_economy_fact_event_packets(facts, plan.context.day,
                                                  _economy_fact_event_sequence,
                                                  gameplay_event_commands);
            }
        }
        if (economy_work > 0u) {
            _active_evidence_mask.fetch_or(
                runtime_domain_mask(RuntimeDomainId::ECONOMY),
                std::memory_order_release);
        }
        _economy_pod_ready.store(true, std::memory_order_release);
        _economy_pod_committed.store(economy_day_done,
                                     std::memory_order_release);
        if (economy_day_done &&
            _country_worker_protocol.pending_intents == 0) {
            clear_day_stall_peer_bits();
        }
        _economy_pod_authority_ready.store(true, std::memory_order_release);
        _economy_pod_committed_day.store(
            economy_day_done ? _economy_production_runtime->last_committed_day()
                             : _economy_pod_committed_day.load(
                                   std::memory_order_relaxed),
            std::memory_order_release);
        _economy_pod_epoch_sample_day.store(plan.context.day,
                                            std::memory_order_release);
        // POD hash is published after committed ledger import below; legacy source hash stays in the ledger record.
        _economy_pod_operation_gate_mask.store(
            _economy_production_runtime->d7_operation_gate_mask(),
            std::memory_order_release);
        // Only a fully committed epoch may cross the legacy/POD boundary.
        // In-progress slices retain their private mutable SoA in the
        // production runtime and never become observable POD state.
        if (economy_day_done &&
            _economy_pod_authority.committed_ledger_state().generation !=
                _economy_production_runtime->committed_generation()) {
            bool ledger_published = false;
            if (_economy_production_runtime->formula_owned_bound()) {
                // N10 Owned identity export: POD `state()` is the very
                // OwnedState the production runtime is bound to, so a NER
                // capture → POD import would replace the bound object.
                // Flush the domain mirrors into the Owned committed blocks
                // and republish the snapshot from that live state instead.
                _economy_production_runtime
                    ->flush_formula_owned_domain_mirrors();
                _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_MIRROR_CAPTURE);
                ledger_published =
                    _economy_pod_authority.publish_owned_committed_mirror(
                        _economy_production_runtime->committed_generation(),
                        _economy_production_runtime->current_day(),
                        economy_error);
                _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_MIRROR_PUBLISH);
            } else {
                RuntimeEconomyLedgerState &ledger_state =
                    _economy_mirror_capture_scratch;
                const auto capture_started = std::chrono::steady_clock::now();
                _economy_production_runtime
                    ->capture_committed_ledger_state(ledger_state,
                        production_writer == EconomyProductionWriter::STAGE_OPS
                            ? _economy_replay_stage_hash[RUNTIME_ECONOMY_GRAPH_STAGE_COUNT - 1].load(
                                  std::memory_order_acquire) : 0,
                        false);
                _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_MIRROR_CAPTURE);
                const auto import_started = std::chrono::steady_clock::now();
                ledger_published =
                    _economy_pod_authority.import_and_publish_captured_ledger(
                        ledger_state, economy_error);
                _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_MIRROR_PUBLISH);
                static thread_local unsigned mirror_samples = 0;
                if (mirror_samples++ < 8) {
                    std::fprintf(stderr, "[economy-mirror-cost] day=%lld capture_ms=%.3f import_ms=%.3f\n",
                        static_cast<long long>(plan.context.day),
                        std::chrono::duration<double, std::milli>(import_started - capture_started).count(),
                        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - import_started).count());
                }
            }
            if (!ledger_published) {
                // Reject the boundary visibly. An incomplete stage is not
                // a safe ownership handoff and must not hide invalid state.
                // Clear ECONOMY from the completed mask — leaving it set
                // produces missing=0x0 + preflight_ok=0, which force-advances
                // over a failed ledger and desyncs the climate FIFO.
                const char *ledger_fault = economy_error.empty()
                    ? "economy_pod_committed_ledger_capture_invalid"
                    : economy_error.c_str();
                publish_economy_tax_diag(ledger_fault,
                    static_cast<uint32_t>(economy_work));
                set_fault(ledger_fault);
                commit.completed_domain_mask &=
                    ~runtime_domain_mask(RuntimeDomainId::ECONOMY);
                if (commit.completed_stage_count > 0u)
                    --commit.completed_stage_count;
                stage.completed = 0;
                commit.preflight_ok = 0;
                return true;
            }
            // M6: mirror readiness never changes the production writer
            // implicitly.  The caller must request switch_economy_authority
            // at a later, observable epoch boundary; this prevents a
            // silent dual-writer handoff in the middle of a day.
        }
        _day_waterfall.mark(RuntimeDayWaterfall::DOMAIN_ECONOMY);
        if (economy_day_done) {
            _economy_pod_state_hash.store(_economy_pod_authority.state_hash(), std::memory_order_release);
        }
        _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_POD_HASH);
        if (plan.context.day % 100 == 0) {
            double stages_ms = 0;
            for (const auto &ms : _economy_replay_stage_ms) stages_ms += ms.load(std::memory_order_relaxed);
            std::fprintf(stderr, "[economy-boundary-cost] day=%lld formulas_ms=%.3f stages_ms=%.3f mirror_ms=%.3f\n",
                static_cast<long long>(plan.context.day),
                std::chrono::duration<double, std::milli>(economy_formulas_finished - economy_attempt_started).count(),
                stages_ms,
                std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - economy_formulas_finished).count());
        }
        // Phase 5: publish production snapshot into the Economy POD ring.
        {
            uint32_t ring_index = 0;
            if (_economy_pod_authority.snapshot_ring().try_begin_write(
                    ring_index)) {
                RuntimeEconomySnapshotPayload &payload =
                    _economy_pod_authority.snapshot_ring().write_buffer(
                        ring_index);
                payload = RuntimeEconomySnapshotPayload{};
                payload.header.session_epoch = 1;
                payload.header.generation =
                    _economy_pod_generation.load(std::memory_order_relaxed);
                payload.header.committed_day =
                    economy_day_done ? _economy_production_runtime->last_committed_day()
                                     : _economy_pod_committed_day.load(
                                           std::memory_order_relaxed);
                payload.header.epoch_sample_day = plan.context.day;
                payload.header.state_hash =
                    _economy_pod_state_hash.load(std::memory_order_relaxed);
                payload.header.operation_gate_mask =
                    _economy_pod_operation_gate_mask.load(
                        std::memory_order_relaxed);
                payload.header.committed = economy_day_done;
                payload.header.authority_ready = true;
                payload.operation_gate_mask =
                    payload.header.operation_gate_mask;
                payload.authority_mode = static_cast<uint32_t>(
                    _economy_pod_authority.authority_mode());
                int64_t pop_err = 0, money_err = 0, goods_err = 0;
                int64_t changed_cells = 0, changed_cohorts = 0;
                uint32_t dirty_family_mask = 0;
                _economy_production_runtime->fill_economy_audit_snapshot(
                    pop_err, money_err, goods_err, dirty_family_mask,
                    changed_cells, changed_cohorts);
                payload.population_error = pop_err;
                payload.money_error = money_err;
                payload.goods_error = goods_err;
                payload.header.population_error = pop_err;
                payload.header.money_error = money_err;
                payload.header.goods_error = goods_err;
                payload.header.changed_cells =
                    static_cast<uint32_t>(std::max<int64_t>(0, changed_cells));
                payload.header.changed_cohorts =
                    static_cast<uint32_t>(std::max<int64_t>(0, changed_cohorts));
                payload.dirty_family_mask = dirty_family_mask;
                _economy_production_runtime->fill_economy_business_summary(
                    payload.summary_population, payload.summary_funds,
                    payload.summary_markets, payload.summary_buildings,
                    payload.summary_cohorts, payload.summary_families);
                _economy_pod_authority.set_business_summary(
                    pop_err, money_err, goods_err,
                    payload.summary_population, payload.summary_funds,
                    payload.summary_markets, payload.summary_buildings,
                    payload.summary_cohorts, payload.summary_families);
                _economy_pod_authority.snapshot_ring().publish(ring_index);
            }
        }
        _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_SNAPSHOT);
        // POD command execute via apply_command, then drain receipts.
        _economy_pod_authority.sync_identity(
            1u, _economy_production_runtime->committed_generation());
        const uint32_t command_mutations =
            _economy_pod_authority.commit_pending_commands();
        // Phase-3: verify owned mirror hash/shape before full recapture.
        if (command_mutations > 0u &&
            !_economy_production_runtime->epoch_active() &&
            _economy_production_runtime->formula_owned_bound()) {
            // N10: bound means POD and NER share the same OwnedState, so a
            // NER capture would only be compared against itself. Refresh
            // the Owned committed blocks and republish the snapshot.
            _economy_production_runtime
                ->flush_formula_owned_domain_mirrors();
            if (!_economy_pod_authority.publish_owned_committed_mirror(
                    _economy_production_runtime->committed_generation(),
                    _economy_production_runtime->current_day(),
                    economy_error)) {
                const char *recapture_fault =
                    economy_error.empty()
                        ? "economy_pod_command_recapture_failed"
                        : economy_error.c_str();
                publish_economy_tax_diag(recapture_fault,
                    static_cast<uint32_t>(economy_work));
                set_fault(recapture_fault);
                commit.completed_domain_mask &=
                    ~runtime_domain_mask(RuntimeDomainId::ECONOMY);
                if (commit.completed_stage_count > 0u)
                    --commit.completed_stage_count;
                stage.completed = 0;
                commit.preflight_ok = 0;
                return true;
            }
            _economy_pod_command_verify_count.fetch_add(
                command_mutations, std::memory_order_relaxed);
            _economy_pod_state_hash.store(
                _economy_pod_authority.state_hash(),
                std::memory_order_release);
        } else if (command_mutations > 0u &&
                   !_economy_production_runtime->epoch_active()) {
            RuntimeEconomyLedgerState ledger_state;
            _economy_production_runtime->capture_committed_ledger_state(
                ledger_state);
            if (!ledger_state.valid()) {
                publish_economy_tax_diag(
                    "economy_pod_command_recapture_failed",
                    static_cast<uint32_t>(economy_work));
                set_fault("economy_pod_command_recapture_failed");
                commit.completed_domain_mask &=
                    ~runtime_domain_mask(RuntimeDomainId::ECONOMY);
                if (commit.completed_stage_count > 0u)
                    --commit.completed_stage_count;
                stage.completed = 0;
                commit.preflight_ok = 0;
                return true;
            }
            ledger_state.recompute_hash();
            const uint64_t ner_ledger_hash = ledger_state.computed_hash();
            RuntimeEconomyLedgerState owned_export;
            std::string verify_error;
            const bool export_ok =
                _economy_pod_authority.export_committed_ledger(
                    owned_export, verify_error);
            if (export_ok) owned_export.recompute_hash();
            const bool shape_ok =
                export_ok &&
                owned_export.cohort_funds.size() ==
                    ledger_state.cohort_funds.size() &&
                owned_export.market_stock.size() ==
                    ledger_state.market_stock.size() &&
                owned_export.cohort_population.size() ==
                    ledger_state.cohort_population.size();
            if (shape_ok &&
                owned_export.computed_hash() == ner_ledger_hash) {
                _economy_pod_command_verify_count.fetch_add(
                    command_mutations, std::memory_order_relaxed);
            } else {
                if (!export_ok ||
                    !_economy_pod_authority.import_committed_ledger(
                        ledger_state, economy_error) ||
                    !_economy_pod_authority.capture_committed_ledger_state(
                        std::move(ledger_state))) {
                    const char *recapture_fault =
                        economy_error.empty()
                            ? "economy_pod_command_recapture_failed"
                            : economy_error.c_str();
                    publish_economy_tax_diag(recapture_fault,
                        static_cast<uint32_t>(economy_work));
                    set_fault(recapture_fault);
                    commit.completed_domain_mask &=
                        ~runtime_domain_mask(RuntimeDomainId::ECONOMY);
                    if (commit.completed_stage_count > 0u)
                        --commit.completed_stage_count;
                    stage.completed = 0;
                    commit.preflight_ok = 0;
                    return true;
                }
                _economy_pod_command_recapture_count.fetch_add(
                    command_mutations, std::memory_order_relaxed);
            }
            _economy_pod_state_hash.store(
                _economy_pod_authority.state_hash(),
                std::memory_order_release);
        }
        {
            RuntimeEconomyPodReceipt receipt;
            uint32_t ack_n = 0;
            while (ack_n < 64u &&
                   _economy_pod_authority.poll_receipt(receipt)) {
                ++ack_n;
            }
            commit.work_units += ack_n;
        }
        _day_waterfall.mark(RuntimeDayWaterfall::ECONOMY_COMMANDS);
        // ACTIVE_WITH_PARITY: after a completed epoch, replay StageOps
        // (mutate=false) against frozen stage refs from compact slices.
        // Incomplete pulses skip — refs would be partial.
        if (economy_day_done && economy_parity_shadow_enabled()) {
            std::string parity_error;
            const uint32_t economy_cells = static_cast<uint32_t>(
                std::max(0, _economy_production_runtime->cell_count()));
            const uint64_t input_generation =
                plan.context.input_generation != 0
                    ? plan.context.input_generation
                    : static_cast<uint64_t>(std::max<int64_t>(
                          1, plan.context.day + 1));
            if (economy_cells > 0u) {
                (void)execute_economy_worker_stage(
                    plan.context.day, input_generation, economy_cells,
                    _economy_pod_country_generation.load(
                        std::memory_order_relaxed),
                    input_generation, parity_error);
            }
        }
        return true;
    }
    return true;
}
} // namespace pk
