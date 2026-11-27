#include "world_ext.h"
#include "world_ext_golden.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"
#include "world_ext_simulation_host_internal.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "modifier_runtime.h"
#include "native_parallel_executor.h"
#include "trigger_runtime.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <limits>

namespace pk {

using namespace godot;

#if defined(_WIN32)
#include <windows.h>
#endif

namespace {
using Clock = std::chrono::steady_clock;

// Frequency-invariant measurement support: process CPU time (all threads).
// The fixture probe is used for cross-build A/B; sustained load changes the
// CPU's thermal/boost state and skews wall-clock comparisons by several
// percent, while process CPU time stays comparable.
int64_t process_cpu_us_now() {
#if defined(_WIN32)
    FILETIME creation{};
    FILETIME exit{};
    FILETIME kernel{};
    FILETIME user{};
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user))
        return 0;
    const auto to_us = [](const FILETIME &time) {
        ULARGE_INTEGER value;
        value.LowPart = time.dwLowDateTime;
        value.HighPart = time.dwHighDateTime;
        return static_cast<int64_t>(value.QuadPart / 10);
    };
    return to_us(kernel) + to_us(user);
#else
    return 0;
#endif
}

enum RuntimeDirtyFamily : uint32_t {
    DIRTY_CLOCK = 1u << 0,
    DIRTY_COUNTRY_STATE = 1u << 1,
    DIRTY_COUNTRY_TERRITORY = 1u << 2,
    DIRTY_COUNTRY_VISUAL_ERA = 1u << 3,
    DIRTY_CLIMATE_FIELDS = 1u << 4,
    DIRTY_WEATHER = 1u << 5,
    DIRTY_ECONOMY_UI = 1u << 6,
    DIRTY_EVENTS = 1u << 7,
    DIRTY_OVERLAY = 1u << 8,
};

// Producer 2 on the Trigger POD command lane. Producer 1 is the Dictionary
// bridge in world_ext_trigger.cpp; the lane is drained in a deterministic
// (effective_day, producer_id, sequence, request_id) order, so the two producers
// stay replayable independently.
std::atomic<uint64_t> g_graph_trigger_request_id{1};
std::atomic<uint64_t> g_graph_trigger_sequence{1};

static uint32_t elapsed_us(Clock::time_point start) {
    const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now() - start).count();
    return static_cast<uint32_t>(std::clamp<int64_t>(us, 0, 0xffffffffll));
}

static int64_t make_token(int64_t day, uint32_t status, uint32_t dirty,
                          uint32_t flags) {
    // [63:48] status/flags, [47:32] dirty mask, [31:0] committed day.
    const uint64_t hi = (static_cast<uint64_t>(status & 0xffu) << 56) |
        (static_cast<uint64_t>(flags & 0xffu) << 48) |
        (static_cast<uint64_t>(dirty & 0xffffu) << 32);
    return static_cast<int64_t>(hi | (static_cast<uint64_t>(day) & 0xffffffffull));
}
} // namespace

int DCWorldExt::configure_runtime_graph(const Dictionary &boot_config) {
    NativeParallelExecutor::instance().set_interactive(false);
    _runtime_graph_configured = false;
    _runtime_graph_enabled = bool(boot_config.get("enabled", false));
    _runtime_graph_country_peer_adapter_enabled = _runtime_graph_enabled &&
        bool(boot_config.get("country_peer_adapter_enabled", true));
    _runtime_graph_day = int64_t(boot_config.get("day", -1));
    _runtime_graph_generation = uint64_t(boot_config.get("generation", 0));
    _runtime_graph_dirty_mask = 0;
    _runtime_graph_next_cursor = 0;
    _runtime_graph_pulse_count = 0;
    _runtime_graph_abi_calls = 0;
    _runtime_graph_callback_count = 0;
    _runtime_graph_work_done = 0;
    _runtime_graph_budget_yields = 0;
    _runtime_graph_economy_slices = 0;
    _runtime_graph_economy_commits = 0;
    _runtime_graph_country_peer_service_calls = 0;
    _runtime_graph_country_peer_intents = 0;
    _runtime_graph_country_peer_completed = 0;
    _runtime_graph_country_peer_pending = 0;
    _runtime_graph_country_peer_rejected = 0;
    _runtime_graph_country_peer_faults = 0;
    _runtime_graph_country_peer_fault_reason.clear();
    _runtime_graph_trigger_blocked_pulses = 0;
    _runtime_graph_trigger_blocked_reason.clear();
    _runtime_graph_last_elapsed_us = 0;
    _runtime_graph_last_status = 0;
    _runtime_graph_post_pulse_flush_ms = 0.0;
    _runtime_graph_country_territory_sync_ms = 0.0;
    _runtime_graph_flush_slot_count = 0;
    _runtime_graph_visual_diff_cell_count = 0;
    _runtime_graph_full_flush_count = 0;
    if (_country_runtime != nullptr) {
        static_cast<NativeCountryRuntime *>(_country_runtime)->set_peer_async_mode(
            _runtime_graph_country_peer_adapter_enabled);
    }
    _runtime_graph_configured = true;
    return 0;
}

// Mirror the Host's current grant into the main-thread Country/Economy peers:
// the unique-writer flags, the Host attachment, and Economy's D7 operation
// gates. Economy routes every cross-domain asset by these, and
// service_country_economy_asset_peer is a no-op while Country's flag is off,
// so a grant the peers never observe parks every fiscal/research transaction
// in the Host queue forever. Called from every pulse and right after a worker
// start, because a restore start is granted before its first pulse.
void DCWorldExt::sync_runtime_domain_ownership() {
    const bool country_worker_authoritative = _runtime_host != nullptr &&
        (_runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::COUNTRY) ||
         _runtime_host->country_authority_owner_is_worker());
    const bool economy_worker_authoritative = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY);
    if (_country_runtime != nullptr) {
        static_cast<NativeCountryRuntime *>(_country_runtime)
            ->set_sync_store_writes_forbidden(country_worker_authoritative);
        if (_runtime_host != nullptr) {
            static_cast<NativeCountryRuntime *>(_country_runtime)
                ->attach_simulation_host(_runtime_host.get());
        }
    }
    if (_economy_runtime != nullptr) {
        auto *economy =
            static_cast<NativeEconomyRuntime *>(_economy_runtime);
        economy->set_sync_writes_forbidden(economy_worker_authoritative);
        if (_runtime_host != nullptr) {
            economy->attach_simulation_host(_runtime_host.get());
            _runtime_host->set_economy_sync_writes_forbidden(
                economy_worker_authoritative);
            // Country ACTIVE + Economy sync needs research plus the two
            // market/treasury legs used by local expedition procurement.
            // Full Economy ACTIVE opens every D7 op as before.
            if (economy_worker_authoritative)
                economy->open_all_d7_operation_gates();
            else if (country_worker_authoritative) {
                economy->open_research_purchase_d7_gate();
                economy->open_country_market_purchase_d7_gates();
            }
        }
    }
}

#include "world_ext_runtime_graph_section_runtime_pulse.inc"
Dictionary DCWorldExt::get_runtime_graph_last_economy_report() const {
    return _runtime_graph_last_economy_report;
}

// The runtime graph stops pulsing once the simulation worker owns the day
// loop, so the report captured in `_runtime_graph_last_economy_report` freezes
// at the last pulse. Perf recording asks this accessor once per sampled row
// instead, which keeps the probe columns aligned with the committed day.
// Scalar counters only; nothing here mutates the economy runtime.
Dictionary DCWorldExt::get_runtime_economy_probe_report() const {
    if (_economy_runtime == nullptr) return Dictionary();
    auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    return economy->probe_report();
}

void DCWorldExt::flush_runtime_visuals(uint32_t dirty_mask) {
    const auto started = Clock::now();
    const uint32_t requested = dirty_mask == 0
        ? std::numeric_limits<uint32_t>::max() : dirty_mask;
    const uint32_t pending = _runtime_graph_dirty_mask & requested;
    // Domain commits already publish their concrete slots. Graph-level flush
    // is an acknowledgement boundary only; a second full-table flush caused
    // redundant CoW comparisons and MapData property writes.
    _runtime_graph_dirty_mask &= ~pending;
    if (pending != 0) ++_runtime_graph_generation;
    _runtime_graph_post_pulse_flush_ms =
        static_cast<double>(elapsed_us(started)) / 1000.0;
}

static String runtime_effective_mode_name(RuntimeSimulationMode mode,
        bool authority_ready, uint32_t authoritative_domain_mask) {
    if (mode == RuntimeSimulationMode::SHADOW) return "SHADOW";
    // A partial promotion is still ACTIVE: some domain's days are now produced
    // by the worker and the main thread must consume its commits. Requiring
    // authority_ready here would report OFF for a worker that already owns
    // Climate, and the commit-consumption boundary would never run.
    if (mode == RuntimeSimulationMode::ACTIVE &&
        (authority_ready || authoritative_domain_mask != 0u))
        return "ACTIVE";
    return "OFF";
}

static const char *runtime_worker_state_name(RuntimeWorkerState state) {
    switch (state) {
        case RuntimeWorkerState::STOPPED: return "STOPPED";
        case RuntimeWorkerState::STARTING: return "STARTING";
        case RuntimeWorkerState::RUNNING: return "RUNNING";
        case RuntimeWorkerState::PAUSED: return "PAUSED";
        case RuntimeWorkerState::SAVE_PENDING: return "SAVE_PENDING";
        case RuntimeWorkerState::STOPPING: return "STOPPING";
        case RuntimeWorkerState::FAULTED: return "FAULTED";
    }
    return "UNKNOWN";
}

// Shared field contract for cheap control reads and full diagnostics.
static void append_runtime_control_state(Dictionary &out,
        const NativeSimulationHost::ControlState &host) {
    out["simulation_host_state"] = runtime_worker_state_name(host.state);
    out["state"] = out["simulation_host_state"];
    out["authority_ready"] = host.authority_ready;
    out["simulation_thread_mode"] = runtime_effective_mode_name(
        host.mode, host.authority_ready, host.authoritative_domain_mask);
    out["requested_simulation_thread_mode"] =
        host.mode == RuntimeSimulationMode::ACTIVE ? "ACTIVE" :
        host.mode == RuntimeSimulationMode::SHADOW ? "SHADOW" : "OFF";
    out["simulation_worker_ready"] =
        host.authority_ready || host.authoritative_domain_mask != 0u;
    out["authoritative_domain_mask"] =
        static_cast<int64_t>(host.authoritative_domain_mask);
    out["requested_authority_mask"] = static_cast<int64_t>(host.requested_authority_mask);
    out["whole_graph_requested"] = host.mode == RuntimeSimulationMode::ACTIVE &&
        host.requested_authority_mask == RUNTIME_ALL_DOMAIN_MASK &&
        host.state != RuntimeWorkerState::STOPPED && host.state != RuntimeWorkerState::STOPPING &&
        host.state != RuntimeWorkerState::FAULTED;
    out["climate_worker_authoritative"] =
        (host.authoritative_domain_mask & runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    out["country_worker_authoritative"] =
        (host.authoritative_domain_mask & runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u;
    out["simulation_committed_day"] = host.committed_day;
    out["player_advance_through"] = host.player_advance_through;
    if (const auto &view = host.player_confirmation) {
        out["player_block_reason"] = view->reason ? view->reason : "";
        out["player_block_day"] = view->day;
        out["family_founding_offer"] = view->family_offer.duplicate(true);
        out["ideology_offer_generation"] = view->ideology_generation;
        out["player_popups_suppressed"] = view->hide_popups;
        out["suppress_event_popups"] = view->suppress_event_popups;
    }
    out["interactive"] = host.interactive;
}

Dictionary DCWorldExt::submit_player_confirmation(const String &action, int64_t value,
                                                   int64_t effective_day) {
    using Kind = RuntimePlayerConfirmationRequest::Kind;
    if (_runtime_host && action == "dismiss_ideology" && value > 0)
        return _runtime_host->submit_player_confirmation({Kind::DISMISS_IDEOLOGY, value, effective_day});
    if (_runtime_host && action == "popup_policy" && (value == 0 || value == 1))
        return _runtime_host->submit_player_confirmation({Kind::POPUP_POLICY, value, effective_day});
    if (_runtime_host && action == "event_popup_policy" && (value == 0 || value == 1))
        return _runtime_host->submit_player_confirmation({Kind::EVENT_POPUP_POLICY, value, effective_day});
    Dictionary out;
    out["ok"] = false;
    out["admitted"] = false;
    out["code"] = "player_confirmation_invalid";
    return out;
}

Dictionary DCWorldExt::get_runtime_control_state() const {
    auto host = _runtime_host != nullptr
        ? _runtime_host->control_state() : NativeSimulationHost::ControlState{};
    host.interactive = NativeParallelExecutor::instance().interactive();
    Dictionary out;
    append_runtime_control_state(out, host);
    out["simulation_executor_exited"] = !_runtime_host || _runtime_host->execution_has_stopped();
    return out;
}

void DCWorldExt::set_runtime_qos(bool interactive) {
    if (_runtime_host) _runtime_host->set_interactive(interactive);
    NativeParallelExecutor::instance().set_interactive(interactive);
}

#include "world_ext_runtime_graph_section_thread_report.inc"
#include "world_ext_runtime_graph_section_performance_snapshot.inc"

} // namespace pk
