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
#include "runtime_golden_diagnostics.h"
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

bool NativeSimulationHost::enqueue(RuntimeCommandPacket packet) {
    std::vector<RuntimeCommandPacket> packets;
    packets.reserve(1);
    packets.push_back(std::move(packet));
    return enqueue_batch(std::move(packets));
}

bool NativeSimulationHost::enqueue_batch(
        std::vector<RuntimeCommandPacket> packets,
        std::vector<int64_t> *effective_days) {
    return enqueue_batch_at(std::move(packets), effective_days, true);
}

RuntimeCommandAdmission NativeSimulationHost::admit_command(int64_t &effective_day) {
    if (on_worker_thread()) return RuntimeCommandAdmission(true);
    RuntimeCommandAdmission admission(_command_producer_mutex, _command_seal);
    const auto current = state();
    if (_world_environment && (current == RuntimeWorkerState::FAULTED ||
            current == RuntimeWorkerState::STOPPED || current == RuntimeWorkerState::STOPPING ||
            _stop_requested.load(std::memory_order_acquire))) return {};
    if (_world_environment && effective_day >= 0)
        effective_day = std::max(effective_day, command_seal_day());
    return admission;
}

bool NativeSimulationHost::try_freeze_command_inputs(int64_t day) {
    std::lock_guard<std::mutex> control(_control_mutex);
    if (player_requests_pending_locked()) return false;
    int64_t seal = _command_seal.load(std::memory_order_acquire);
    if ((seal & 1) != 0) return false;
    return _command_seal.compare_exchange_strong(seal, day * 2,
        std::memory_order_acq_rel, std::memory_order_acquire);
}

bool NativeSimulationHost::enqueue_batch_at(
        std::vector<RuntimeCommandPacket> packets,
        std::vector<int64_t> *effective_days, bool seal,
        const std::function<bool()> &admit_peer) {
    if (effective_days != nullptr) effective_days->clear();
    if (packets.empty()) return false;
    // A day that already owns the execution boundary must finish delivering
    // its consequences even if stop revoked admission for future days.
    const bool executor = on_worker_thread();
    const bool settling = executor && _worker_day_inflight.load(std::memory_order_acquire) != 0;
    const auto accepts = [settling](RuntimeWorkerState state) {
        return state != RuntimeWorkerState::STOPPED &&
            state != RuntimeWorkerState::FAULTED &&
            (settling || state != RuntimeWorkerState::STOPPING);
    };
    if (!accepts(_state.load(std::memory_order_acquire))) return false;

    int64_t earliest = std::max<int64_t>(0, std::min_element(packets.begin(), packets.end(),
        [](const auto &a, const auto &b) {
            return a.envelope.effective_day < b.envelope.effective_day;
        })->envelope.effective_day);
    auto admission = admit_command(earliest);
    if (!admission.accepted() || !accepts(_state.load(std::memory_order_acquire)) ||
        (!settling && _stop_requested.load(std::memory_order_acquire))) return false;
    const uint64_t write = _command_enqueue_pos.load(std::memory_order_relaxed);
    const uint64_t read = _command_dequeue_pos.load(std::memory_order_acquire);
    const size_t executor_pending = executor ? _executor_inbox.size() : 0;
    if (packets.size() > RUNTIME_COMMAND_QUEUE_CAPACITY ||
        write - read + executor_pending > RUNTIME_COMMAND_QUEUE_CAPACITY - packets.size()) {
        _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    if (admit_peer && !admit_peer()) return false;
    // The executor may enqueue a consequence of today's settlement at its
    // exact D+1 date. External input captures the fence while admitting.
    const int64_t seal_day = seal ? command_seal_day() : 0;
    if (effective_days != nullptr) effective_days->reserve(packets.size());
    for (size_t index = 0; index < packets.size(); ++index) {
        RuntimeCommandPacket &packet = packets[index];
        packet.envelope.effective_day = std::max(packet.envelope.effective_day, seal_day);
        if (effective_days != nullptr)
            effective_days->push_back(packet.envelope.effective_day);
        if (packet.submit_order == 0) {
            packet.submit_order = _command_submit_order.fetch_add(
                1u, std::memory_order_relaxed) + 1u;
        }
        packet.admission_generation = _generation.load(std::memory_order_acquire);
        if (executor) {
            _executor_inbox.push_back(std::move(packet));
        } else {
            const uint64_t position = write + static_cast<uint64_t>(index);
            _command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY].packet = std::move(packet);
        }
    }
    if (!executor)
        _command_enqueue_pos.store(write + packets.size(), std::memory_order_release);
    _last_command_admitted_us.store(now_us(), std::memory_order_release);
    _control_cv.notify_one();
    return true;
}

void NativeSimulationHost::reserve_command_request_ids_through(uint64_t maximum) noexcept {
    const bool executor = (maximum & EXECUTOR_REQUEST_ID_TAG) != 0;
    std::atomic<uint64_t> &counter = executor ? _executor_request_id : _command_request_id;
    if (executor) maximum &= ~EXECUTOR_REQUEST_ID_TAG;
    uint64_t observed = counter.load(std::memory_order_acquire);
    while (observed < maximum &&
           !counter.compare_exchange_weak(
               observed, maximum, std::memory_order_acq_rel,
               std::memory_order_acquire)) {}
}

uint64_t NativeSimulationHost::allocate_command_request_id() {
    // 日执行者里取号的次数只由日内逻辑决定，不受主线程什么时候入队影响。
    if (on_worker_thread())
        return (_executor_request_id.fetch_add(1u, std::memory_order_relaxed) + 1u) |
            EXECUTOR_REQUEST_ID_TAG;
    return allocate_command_request_id_for_ingress();
}

uint64_t NativeSimulationHost::allocate_command_request_id_for_ingress() {
    uint64_t value = _command_request_id.fetch_add(
        1u, std::memory_order_relaxed) + 1u;
    if (value == 0) {
        value = _command_request_id.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
    }
    return value;
}

bool NativeSimulationHost::enqueue_modifier_shadow(RuntimeCommandPacket packet) {
    if (packet.envelope.domain !=
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) return false;
    const auto modifier_enqueue_allowed = [this]() {
        const RuntimeSimulationMode mode =
            _mode.load(std::memory_order_acquire);
        if (mode == RuntimeSimulationMode::SHADOW) return true;
        // E8: ACTIVE Host is the sole Modifier writer once MODIFIER is
        // in the requested authority mask (grant may still be pending).
        if (mode == RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u) {
            return true;
        }
        return false;
    };
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current != RuntimeWorkerState::STOPPED) {
        if (!modifier_enqueue_allowed()) return false;
        return enqueue(std::move(packet));
    }
    if (packet.submit_order == 0) {
        packet.submit_order = _command_submit_order.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
    }
    std::unique_lock<std::mutex> lock(_control_mutex);
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {
        lock.unlock();
        if (!modifier_enqueue_allowed()) return false;
        return enqueue(std::move(packet));
    }
    if (_prestart_modifier_commands.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    _prestart_modifier_commands.push_back(std::move(packet));
    return true;
}

uint64_t NativeSimulationHost::allocate_producer_sequence(uint32_t producer_id) {
    if (producer_id < _producer_sequences.size()) {
        return _producer_sequences[producer_id].fetch_add(1, std::memory_order_relaxed) + 1;
    }
    return _fallback_producer_sequence.fetch_add(1, std::memory_order_relaxed) + 1;
}

void NativeSimulationHost::register_country_acceptance(const RuntimeCommandPacket &packet) {
    const auto &envelope = packet.envelope;
    if (envelope.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
            envelope.request_id == 0) return;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    CountryCommandReceipt receipt;
    receipt.request_id = envelope.request_id;
    receipt.producer_id = envelope.producer_id;
    receipt.sequence = envelope.sequence;
    receipt.effective_day = envelope.effective_day;
    receipt.generation = packet.admission_generation;
    _country_command_states.try_emplace(receipt.request_id, std::move(receipt));
}

void NativeSimulationHost::drain_command_inbox_through(
        std::vector<RuntimeCommandPacket> &out, uint64_t end) {
    // The acquired cursor is a complete batch boundary. Later admissions
    // belong to the next drain. The producer may reuse slots only after the
    // corresponding packet has been moved out of the ring.
    const uint64_t begin = _command_dequeue_pos.load(std::memory_order_relaxed);
    for (uint64_t position = begin; position < end; ++position) {
        auto &packet = _command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY].packet;
        register_country_acceptance(packet);
        out.push_back(std::move(packet));
    }
    _command_dequeue_pos.store(end, std::memory_order_release);
    for (auto &packet : _executor_inbox) {
        register_country_acceptance(packet);
        out.push_back(std::move(packet));
    }
    _executor_inbox.clear();
}

bool NativeSimulationHost::push_receipt(const RuntimeCommandReceipt &receipt) {
    const uint64_t write = _receipt_write.load(std::memory_order_relaxed);
    const uint64_t read = _receipt_read.load(std::memory_order_acquire);
    if (write - read >= RUNTIME_RECEIPT_QUEUE_CAPACITY) {
        _receipt_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    _receipts[write % RUNTIME_RECEIPT_QUEUE_CAPACITY] = receipt;
    _receipt_write.store(write + 1, std::memory_order_release);
    return true;
}

bool NativeSimulationHost::poll_receipt(RuntimeCommandReceipt &out) {
    const uint64_t read = _receipt_read.load(std::memory_order_relaxed);
    const uint64_t write = _receipt_write.load(std::memory_order_acquire);
    if (read == write) return false;
    out = _receipts[read % RUNTIME_RECEIPT_QUEUE_CAPACITY];
    _receipt_read.store(read + 1, std::memory_order_release);
    return true;
}

CountryAiRuntime *NativeSimulationHost::country_ai_for_worker() const noexcept {
    CountryAiRuntime *runtime = _country_ai_runtime.load(std::memory_order_acquire);
    if (runtime == nullptr) return nullptr;
    // SHADOW mirrors the synchronous adapter's AI commands; only ACTIVE with
    // Country authority plans on the worker.
    if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::ACTIVE ||
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::COUNTRY)) == 0u)
        return nullptr;
    return runtime->active() ? runtime : nullptr;
}

void NativeSimulationHost::commit_country_ai_day(int64_t day) {
    CountryAiRuntime *runtime = country_ai_for_worker();
    if (runtime == nullptr) return;
    CountryAiCommitResult result = runtime->commit(day);
    if (_economy_production_runtime == nullptr) return;
    if (result.family_preferences_changed)
        _economy_production_runtime->set_country_ai_family_preferences(
            std::move(result.family_preferences));
    if (!result.colonization.empty())
        _economy_production_runtime->queue_country_ai_colonization(
            std::move(result.colonization));
    for (const auto &policy : result.procurement)
        _economy_production_runtime->queue_research_procurement_policy(
            policy.country_handle, policy.research_share_bp, policy.day,
            static_cast<int64_t>(policy.sequence));
}

void NativeSimulationHost::publish_country_command_terminals(
        const std::vector<RuntimeCountryCommand> &commands,
        CountryCommandReceiptCode code, uint64_t generation,
        const char *reason, bool include_superseded_ai) {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    for (const RuntimeCountryCommand &command : commands) {
        // Worker-local AI has no admitted packet to retire. SHADOW's mirrored
        // sync AI does: keep its terminal internally so successful commands do
        // not repeat forever. poll_country_command_receipts filters AI from
        // the player stream independently of this transport lifecycle.
        if (command.producer_id == COUNTRY_AI_PRODUCER_ID &&
            !include_superseded_ai &&
            _country_command_states.find(command.request_id) ==
                _country_command_states.end()) continue;
        if (command.request_id == 0 ||
            _country_command_terminals.find(command.request_id) !=
                _country_command_terminals.end()) {
            continue;
        }
        CountryCommandReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.producer_id = command.producer_id;
        receipt.sequence = command.sequence;
        receipt.effective_day = command.effective_day;
        receipt.generation = generation;
        receipt.code = code;
        if (reason != nullptr) receipt.reason = reason;
        _country_command_states[receipt.request_id] = receipt;
        if (receipt.producer_id != COUNTRY_AI_PRODUCER_ID)
            _country_command_publications.push_back(receipt.request_id);
        _country_command_terminals.emplace(receipt.request_id,
                                           std::move(receipt));
    }
}

void NativeSimulationHost::retire_country_ai_ingress(
        const std::vector<RuntimeCommandPacket> &packets) {
    if (country_ai_for_worker() == nullptr) return;
    std::vector<RuntimeCountryCommand> superseded;
    for (const RuntimeCommandPacket &packet : packets) {
        const auto &envelope = packet.envelope;
        if (envelope.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
            envelope.producer_id != COUNTRY_AI_PRODUCER_ID || envelope.request_id == 0)
            continue;
        RuntimeCountryCommand command;
        command.request_id = envelope.request_id;
        command.producer_id = envelope.producer_id;
        command.sequence = envelope.sequence;
        command.effective_day = envelope.effective_day;
        superseded.push_back(command);
    }
    if (superseded.empty()) return;
    // 主线程 AI 的旧包已被既有 worker 重规划路径取代，必须明确收尾。
    // 不伪造已执行，不让旧 ACCEPTED 包永久阻塞 OwnedState 的安全切换。
    publish_country_command_terminals(superseded,
        CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
        _country_pod_authority.generation(), "country_ai_superseded_by_worker", true);
}

bool NativeSimulationHost::poll_country_command_receipts(
        uint64_t after_request_id, uint32_t limit,
        std::vector<CountryCommandReceipt> &out) {
    out.clear();
    const uint32_t bounded_limit = std::min<uint32_t>(limit, 4096u);
    if (bounded_limit == 0) return true;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    auto it = _country_command_terminals.upper_bound(after_request_id);
    for (; it != _country_command_terminals.end() &&
           out.size() < bounded_limit; ++it) {
        if (it->second.producer_id == COUNTRY_AI_PRODUCER_ID) continue;
        out.push_back(it->second);
    }
    return true;
}

void NativeSimulationHost::poll_country_command_publications(
        uint64_t after_sequence, uint32_t limit,
        std::vector<CountryCommandReceipt> &out) {
    out.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const size_t begin = std::min<uint64_t>(after_sequence, _country_command_publications.size());
    const size_t end = std::min(_country_command_publications.size(),
        begin + std::min<uint32_t>(limit, 4096u));
    out.reserve(end - begin);
    for (size_t i = begin; i < end; ++i)
        out.push_back(_country_command_terminals.at(_country_command_publications[i]));
}

bool NativeSimulationHost::try_country_command_terminal(
        uint64_t request_id, CountryCommandReceipt &out) {
    if (request_id == 0) return false;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto found = _country_command_terminals.find(request_id);
    if (found == _country_command_terminals.end()) return false;
    out = found->second;
    return true;
}

bool NativeSimulationHost::poll_commit(uint64_t after_generation, RuntimeCommit &out) {
    const auto latest = std::atomic_load_explicit(&_latest_commit,
                                                  std::memory_order_acquire);
    if (!latest || latest->header.generation <= after_generation) return false;
    out = *latest;
    return true;
}

RuntimeDayPlan NativeSimulationHost::build_day_plan(
        int64_t day, double speed_scale,
        const RuntimeEnvironmentSnapshot *environment,
        uint64_t command_watermark) const {
    RuntimeDayPlan plan;
    plan.context.day = day;
    plan.context.season_phase = environment != nullptr
        ? environment->season_phase : 0.0;
    plan.context.speed_scale = speed_scale;
    plan.context.input_generation = environment != nullptr
        ? environment->generation : 0;
    plan.context.frozen_input.session_epoch = _country_worker_session_epoch;
    plan.context.frozen_input.day = day;
    plan.context.frozen_input.generation = plan.context.input_generation;
    plan.context.frozen_input.command_watermark = command_watermark;
    plan.context.frozen_input.committed = environment != nullptr ? 1u : 0u;
    plan.context.frozen_input.in_flight = 0u;
    plan.context.environment = environment;

    constexpr auto order = runtime_domain_stage_order();
    for (uint32_t i = 0; i < plan.stage_count; ++i)
        plan.stages[i].domain = order[i];
    return plan;
}


void NativeSimulationHost::publish_day(
        int64_t from_day, int64_t day,
        const RuntimeDayCommit &day_commit,
        const std::vector<RuntimeCommandReceipt> &day_receipts) {
    if (try_fault_injection("day.commit.before")) {
        return;
    }
    commit_annual_worker_day(day);
    const uint64_t next_hash = mix_hash(
        _state_hash.load(std::memory_order_relaxed), static_cast<uint64_t>(day));
    _state_hash.store(next_hash, std::memory_order_release);
    std::FILE *day_trace = sim_day_trace_file();
    if (day_trace != nullptr) {
        SimTraceLock trace_lock(day_trace);
        std::fprintf(day_trace,
            "[sim-day-trace] day=%lld input_day=%lld input_hash=%llu env_day=%lld "
            "econ_day=%lld econ_sample=%lld econ_hash=%llu climate_hash=%llu "
            "trigger_hash=%llu modifier_hash=%llu effect_hash=%llu\n",
            static_cast<long long>(day),
            static_cast<long long>(_input_capture_day.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_input_capture_hash.load(std::memory_order_acquire)),
            static_cast<long long>(_environment_day.load(std::memory_order_acquire)),
            static_cast<long long>(_economy_pod_committed_day.load(std::memory_order_acquire)),
            static_cast<long long>(_economy_pod_epoch_sample_day.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_economy_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_climate_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_trigger_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_modifier_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_effect_pod_state_hash.load(std::memory_order_acquire)));
        const auto &econ_state = _economy_pod_authority.state();
        std::fprintf(day_trace,
            "[econ-data] day=%lld gen=%llu pop=%llu funds=%llu active=%llu stock=%llu price=%llu demand=%llu resource=%llu\n",
            static_cast<long long>(day),
            static_cast<unsigned long long>(econ_state.state_generation),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.population.population)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.population.funds)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.population.active)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.market.stock)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.market.price)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.market.demand_ema)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.resources.stock)));
        std::fflush(day_trace);
    }
    // The authoritative header advances on every day, independent of the
    // visual payload's throttle and buffer occupancy.
    const uint64_t generation = _generation.load(std::memory_order_relaxed) + 1;
    constexpr std::array<uint32_t, RUNTIME_DIRTY_FAMILY_COUNT> FAMILY_BITS{
        RUNTIME_DIRTY_CLOCK,
        RUNTIME_DIRTY_COUNTRY_STATE,
        RUNTIME_DIRTY_COUNTRY_TERRITORY,
        RUNTIME_DIRTY_COUNTRY_VISUAL_ERA,
        RUNTIME_DIRTY_CLIMATE_FIELDS,
        RUNTIME_DIRTY_WEATHER,
        RUNTIME_DIRTY_ECONOMY_UI,
        RUNTIME_DIRTY_EVENTS,
        RUNTIME_DIRTY_OVERLAY,
    };
    const auto previous = std::atomic_load_explicit(&_latest_commit,
                                                    std::memory_order_acquire);
    auto published = std::make_shared<RuntimeCommit>();
    RuntimeCommitHeader &header = published->header;
    const uint64_t produced_at_us = now_us();
    header.generation = generation;
    header.from_day = from_day;
    header.committed_day = day;
    header.produced_at_us = produced_at_us;
    header.dirty_families = day_commit.dirty_families;
    header.state_hash = next_hash;
    header.command_receipt_count = static_cast<uint32_t>(
        std::min<size_t>(day_receipts.size(), std::numeric_limits<uint32_t>::max()));
    if (previous) header.dirty_family_generations = previous->header.dirty_family_generations;
    for (size_t family_index = 0; family_index < FAMILY_BITS.size(); ++family_index) {
        if ((day_commit.dirty_families & FAMILY_BITS[family_index]) != 0)
            header.dirty_family_generations[family_index] = generation;
    }
    published->receipts = day_receipts;
    if (_executor_vision && (!_executor_day_tail || !_executor_day_tail->vision) &&
        previous && previous->day_tail && previous->day_tail->vision) {
        if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
        _executor_day_tail->vision = previous->day_tail->vision;
    }
    const char *golden = runtime_switch_value(RuntimeSwitch::PK_GOLDEN_DOMAINS);
    if (golden != nullptr && std::strcmp(golden, "1") == 0) {
        if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
        _executor_day_tail->golden = std::make_shared<RuntimeGoldenSnapshot>(capture_golden_snapshot(day));
    }
    if (_world_environment) {
        if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
        _executor_day_tail->country = country_worker_read_view(0);
        if (_modifier_pod_configured) {
            const auto &modifier = _modifier_pod_authority.snapshot();
            const auto old = previous && previous->day_tail ? previous->day_tail->modifier : nullptr;
            _executor_day_tail->modifier = old && old->generation == modifier.generation
                ? old : std::make_shared<const RuntimeModifierPodSnapshot>(modifier);
        }
        auto climate = std::make_shared<RuntimeClimateSnapshot>();
        capture_climate_display(*climate);
        climate->generation = _climate_writeback_sequence.fetch_add(1, std::memory_order_relaxed) + 1;
        climate->dirty_families = day_commit.dirty_families;
        _executor_day_tail->climate = std::move(climate);
    }
    if (_world_environment) publish_cell_lut_changes(*_executor_day_tail,
        previous ? previous->day_tail.get() : nullptr);
    int64_t year_length = 0;
    bool annual_reward_pending = false;
    if (_world_environment && annual_development_enabled()) {
        std::lock_guard<std::mutex> annual(_annual_mutex);
        year_length = _annual_ledger.days_per_year();
        annual_reward_pending = _annual_ledger.has_pending_reward();
    }
    const auto fiscal = year_length > 0 ? capture_economy_display(day, year_length,
        *_executor_day_tail, previous ? previous->day_tail.get() : nullptr) : nullptr;
    published->day_tail = std::move(_executor_day_tail);
    publish_military_day();
    if (published->day_tail && published->day_tail->era_reward)
        std::atomic_store(&_published_era_reward, published->day_tail->era_reward);
    if (published->day_tail && published->day_tail->narrative)
        std::atomic_store(&_published_narrative, published->day_tail->narrative);
    if (published->day_tail && published->day_tail->era_advancement)
        std::atomic_store(&_published_era_advancement, published->day_tail->era_advancement);
    finish_player_confirmation_day(day);
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        _committed_day.store(day, std::memory_order_release);
        _generation.store(generation, std::memory_order_release);
        std::atomic_store_explicit(&_latest_commit,
            std::shared_ptr<const RuntimeCommit>(published),
            std::memory_order_release);
    }
    if (_world_environment) {
        uint64_t business = mix_hash(
            _climate_pod_state_hash.load(std::memory_order_relaxed),
            _economy_pod_state_hash.load(std::memory_order_relaxed));
        for (auto *hash : {&_trigger_pod_state_hash, &_ideology_pod_state_hash,
                &_effect_pod_state_hash, &_modifier_pod_state_hash, &_events_pod_state_hash})
            business = mix_hash(business, hash->load(std::memory_order_relaxed));
        business = mix_hash(business, published->day_tail->country.state_hash);
        publish_display_batch(published, {header, published->receipts, published->day_tail->golden,
            published->day_tail->notices, fiscal, business, annual_reward_pending});
    }
    _control_cv.notify_all();
    _last_commit_produced_at_us.store(produced_at_us, std::memory_order_release);
    try_fault_injection("day.commit.after");
}

void NativeSimulationHost::publish_economy_tax_diag(
        const std::string &yield_reason, uint32_t slices) {
    const auto store_text = [](auto &dst, const char *text) {
        const char *value = text != nullptr ? text : "";
        size_t i = 0;
        for (; i + 1 < dst.size() && value[i] != '\0'; ++i)
            dst[i].store(value[i], std::memory_order_relaxed);
        for (; i < dst.size(); ++i)
            dst[i].store('\0', std::memory_order_relaxed);
    };
    NativeEconomyRuntime::TaxSchedDiag diag;
    char stage[32] = {};
    char substage[40] = {};
    if (_economy_production_runtime != nullptr) {
        _economy_production_runtime->copy_tax_sched_diag(
            diag, stage, sizeof(stage), substage, sizeof(substage));
    }
    store_text(_economy_yield_reason, yield_reason.c_str());
    store_text(_economy_stage_name, stage);
    store_text(_economy_substage_name, substage);
    _economy_epoch_fiscal_ms.store(diag.epoch_fiscal_ms, std::memory_order_relaxed);
    _economy_fiscal_settlement_ms.store(
        diag.fiscal_settlement_ms, std::memory_order_relaxed);
    _economy_income_subsidy_ms.store(
        diag.income_subsidy_ms, std::memory_order_relaxed);
    _economy_negative_tax_mask.store(diag.negative_tax_mask, std::memory_order_relaxed);
    _economy_active_tax_mask.store(diag.active_tax_mask, std::memory_order_relaxed);
    _economy_attempt_slices.store(slices, std::memory_order_relaxed);
}

} // namespace pk
