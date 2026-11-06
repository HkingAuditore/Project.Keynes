#include "native_simulation_day_context.h"
#include "country_ai_runtime.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_country(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &day_commands = day.day_commands;
    auto &admitted_submit_order = day.admitted_submit_order;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    if (stage.domain == RuntimeDomainId::COUNTRY &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u &&
        !plan.context.freeze_reads.register_read(
            runtime_domain_mask(RuntimeDomainId::COUNTRY), plan.context.frozen_input,
            plan.context.day, plan.context.input_generation)) {
        commit.preflight_ok = 0;
        return false;
    }
    if (stage.domain == RuntimeDomainId::COUNTRY &&
        (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW ||
         (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
          (_requested_authority_mask.load(std::memory_order_acquire) &
           runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u))) {
        if (_country_pod_configured) {
            retire_country_ai_ingress(day_commands);
            const int64_t country_committed =
                _country_pod_authority.committed_day();
            // Country packets behind the POD committed day are no longer
            // rejected here: execute_country_worker_stage reschedules them
            // onto the day it is planning. A player stamps effective_day
            // from the UI clock, which trails the worker clock at high
            // speed, so dropping them silently discarded research/tax
            // intents. Only malformed packets can still be terminal-ed,
            // and that happens inside the stage.
            (void)country_committed;
            // Country POD advances its committed_day as soon as the stage
            // succeeds (including commit_rejected_day). A later domain can
            // still fail the whole day and force a Host retry of the same
            // day index. Treat an already-committed Country day as an
            // idempotent success so the retry is not stuck forever on
            // country_day_not_contiguous.
            if (plan.context.day <= country_committed) {
                // Still admit late Country packets onto committed+1 so an
                // idempotent Country skip cannot strand research enqueue
                // that arrived while a later domain forced a same-day retry.
                for (const RuntimeCommandPacket &packet : day_commands) {
                    if (packet.envelope.domain !=
                            static_cast<uint16_t>(
                                RuntimeDomainId::COUNTRY) ||
                        packet.envelope.request_id == 0) {
                        continue;
                    }
                    if (packet.envelope.producer_id == COUNTRY_AI_PRODUCER_ID &&
                        country_ai_for_worker() != nullptr) {
                        continue;
                    }
                    CountryCommandReceipt terminal;
                    if (try_country_command_terminal(
                            packet.envelope.request_id, terminal)) continue;
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
                    command.effective_day = country_committed + 1;
                    (void)_country_pod_authority.queue_command(
                        command, command_error);
                }
                stage.completed = 1;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::COUNTRY);
                ++commit.completed_stage_count;
                _country_pod_ready.store(true, std::memory_order_release);
                return true;
            }
            // Mirror SHADOW's climate_ok gate. Under ACTIVE Climate parks
            // when the worker clock outruns the published environment; if
            // Country still commits that day, the day then fails
            // preflight and the retry dies on country_day_not_contiguous.
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                return true;
            }
            const uint32_t dirty_before = commit.dirty_families;
            const uint64_t work_before = commit.work_units;
            std::string country_error;
            if (execute_country_worker_stage(
                    plan.context.day, plan.context.input_generation,
                    day_commands, commit, country_error,
                    admitted_submit_order)) {
                stage.dirty_families = (commit.dirty_families |
                    dirty_before) &
                    (RUNTIME_DIRTY_COUNTRY_STATE |
                     RUNTIME_DIRTY_COUNTRY_TERRITORY |
                     RUNTIME_DIRTY_COUNTRY_VISUAL_ERA);
                stage.work_units = commit.work_units >= work_before
                    ? commit.work_units - work_before : 0;
                stage.completed = (commit.completed_domain_mask &
                    runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u;
                _country_pod_ready.store(true, std::memory_order_release);
            } else {
                _country_pod_ready.store(false, std::memory_order_release);
                const char *reason = country_error.empty()
                    ? "country_worker_stage_pending" : country_error.c_str();
                for (size_t i = 0; i + 1 < _country_pod_fallback_reason.size();
                     ++i) {
                    _country_pod_fallback_reason[i].store(
                        reason[i], std::memory_order_release);
                    if (reason[i] == '\0') break;
                }
                _country_pod_fallback_reason[
                    _country_pod_fallback_reason.size() - 1]
                    .store('\0', std::memory_order_release);
                static std::atomic<int> s_active_country_errors_left{8};
                if (s_active_country_errors_left.fetch_sub(
                        1, std::memory_order_relaxed) > 0) {
                    std::fprintf(stderr,
                                 "[country][active] day=%lld failed=%s "
                                 "input_generation=%llu\n",
                                 static_cast<long long>(plan.context.day),
                                 reason,
                                 static_cast<unsigned long long>(
                                     plan.context.input_generation));
                    std::fflush(stderr);
                }
                if (country_error == "country_worker_peer_results_pending" ||
                    country_error == "country_peer_results_pending" ||
                    country_error == "country_economy_asset_results_pending") {
                    stage.completed = 0;
                }
                commit.preflight_ok = 0;
            }
            return true;
        }
        RuntimeCountryDayContext country_context;
        country_context.day = plan.context.day;
        country_context.speed_scale = plan.context.speed_scale;
        country_context.input_generation = plan.context.input_generation;
        RuntimeCountryDayCommit country_commit;
        RuntimeCountryPodDiagnostics diagnostics;
        const auto country_snapshot = std::atomic_load_explicit(
            &_country_snapshot, std::memory_order_acquire);
        if (country_snapshot && RuntimeCountryPodAdapter::execute_day(
                *country_snapshot, country_context, country_commit, diagnostics)) {
            std::atomic_store_explicit(&_country_pod_diagnostics,
                std::make_shared<const RuntimeCountryPodDiagnostics>(diagnostics),
                std::memory_order_release);
            stage.dirty_families = country_commit.dirty_families;
            stage.work_units = country_commit.research_work_units;
            stage.completed = country_commit.completed;
            commit.dirty_families |= stage.dirty_families;
            commit.work_units += stage.work_units;
            // ACK is intentionally not counted as a complete domain. The
            // adapter is a SHADOW probe until peer domains are POD-safe.
        } else {
            std::atomic_store_explicit(&_country_pod_diagnostics,
                std::make_shared<const RuntimeCountryPodDiagnostics>(diagnostics),
                std::memory_order_release);
        }
        return true;
    }
    return true;
}
} // namespace pk
