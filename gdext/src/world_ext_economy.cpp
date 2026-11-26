#include "economy_authority_transfer.h"
#include "world_ext.h"

#include "economy_runtime.h"
#include "economy_csv_recorder.h"
#include "country_runtime.h"
#include "modifier_runtime.h"
#include "trigger_runtime.h"
#include "effect_runtime.h"
#include "native_simulation_host.h"
#include "runtime_economy_boundary_request.h"
#include "runtime_economy_ecp2.h"
#include "pk_build_id.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <mutex>

namespace pk {

namespace {
uint64_t ecp2_wire_hash(const godot::PackedByteArray &bytes) {
    uint64_t hash = 1469598103934665603ull;
    // The ECP2 content hash covers the bytes after the fixed 24-byte header.
    for (int64_t i = 24; i < bytes.size(); ++i) {
        hash ^= static_cast<uint64_t>(bytes[i]);
        hash *= 1099511628211ull;
    }
    return hash;
}
}

using namespace godot;

namespace {

using BridgeClock = std::chrono::steady_clock;

double bridge_elapsed_ms(BridgeClock::time_point started) {
    return std::chrono::duration<double, std::milli>(
        BridgeClock::now() - started).count();
}

NativeEconomyRuntime *runtime_from(void *opaque) {
    return static_cast<NativeEconomyRuntime *>(opaque);
}

Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "economy_not_configured";
    return out;
}

Dictionary forward_economy_boundary_request(NativeSimulationHost &host,
                                        RuntimeEconomyBoundaryRequest request) {
    return host.submit_economy_boundary_request(std::make_shared<RuntimeEconomyBoundaryRequest>(std::move(request)));
}

using ReadQuery = NativeEconomyRuntime::ReadQuery;
using ReadKey = NativeEconomyRuntime::ReadKey;

ReadKey read_key(ReadQuery query, std::initializer_list<int64_t> args) {
    ReadKey key;
    key.query = query;
    size_t index = 0;
    for (const int64_t value : args)
        if (index < key.args.size()) key.args[index++] = value;
    return key;
}

// Same transient contract as colonization "busy": callers keep their previous
// rows and retry on the next refresh.
Dictionary read_view_pending() {
    Dictionary out;
    out["ok"] = false;
    out["code"] = "economy_busy_retry";
    out["reason"] = "economy_read_view_pending";
    out["busy"] = true;
    out["committed"] = false;
    out["nonbinding"] = true;
    out["fatal"] = false;
    out["read_view_pending"] = true;
    out["read_view_source"] = "pending";
    return out;
}

bool economy_live_readable(const NativeSimulationHost *host,
                           const NativeEconomyRuntime *runtime,
                           std::unique_lock<std::mutex> &boundary) {
    boundary = host->try_lock_economy_read_boundary();
    return boundary.owns_lock() && !runtime->epoch_active();
}

// Unowned stores serve diagnostic queries directly. The formal executor answers
// queries from its own published view, including while paused.
template <class Live>
Dictionary committed_read(NativeSimulationHost *host,
                          NativeEconomyRuntime *runtime, ReadKey key,
                          Live &&live) {
    if (host == nullptr || !host->economy_worker_owns_execution()) return live();
    key.seal();
    const bool subscribed = runtime->read_view_subscribe(key);
    const auto view = runtime->read_view();
    if (subscribed || (view && view->committed_day < host->committed_day_value()))
        host->request_economy_read_view();
    if (view != nullptr) {
        if (const NativeEconomyRuntime::ReadViewEntry *entry = view->find(key)) {
            Dictionary out = entry->value.duplicate(true);
            out["read_view_source"] = "committed_view";
            out["read_view_pending"] = false;
            out["read_view_day"] = entry->committed_day;
            out["read_view_serial"] = static_cast<int64_t>(view->serial);
            return out;
        }
    }
    return read_view_pending();
}

bool read_generation_u64(const Dictionary &generation, const char *key,
                         uint64_t &out, std::string &error) {
    const StringName field(key);
    if (!generation.has(field)) {
        out = 0;
        return true;
    }
    const Variant value = generation.get(field, Variant());
    if (value.get_type() != Variant::INT) {
        error = std::string("economy_input_generation_field_not_integer:") + key;
        return false;
    }
    const int64_t signed_value = static_cast<int64_t>(value);
    if (signed_value < 0) {
        error = std::string("economy_input_generation_field_negative:") + key;
        return false;
    }
    out = static_cast<uint64_t>(signed_value);
    return true;
}

bool read_generation_sample_day(const Dictionary &generation, int64_t day_index,
                                int64_t &out, std::string &error) {
    const StringName field("sample_day");
    if (!generation.has(field)) {
        out = day_index;
        return true;
    }
    const Variant value = generation.get(field, Variant());
    if (value.get_type() != Variant::INT) {
        error = "economy_input_generation_sample_day_not_integer";
        return false;
    }
    out = static_cast<int64_t>(value);
    if (out != day_index) {
        error = "economy_input_generation_sample_day_mismatch";
        return false;
    }
    return true;
}

bool parse_economy_input_generation(int64_t day_index,
                                    const Dictionary &generation,
                                    EconomyInputGeneration &out,
                                    std::string &error) {
    out = {};
    if (!read_generation_sample_day(generation, day_index, out.sample_day, error) ||
        !read_generation_u64(generation, "epoch_id", out.epoch_id, error) ||
        !read_generation_u64(generation,
            generation.has(StringName("map_generation"))
                ? "map_generation" : "topology_generation",
            out.map_generation, error) ||
        !read_generation_u64(generation, "building_generation",
                             out.building_generation, error) ||
        !read_generation_u64(generation, "country_generation",
                             out.country_generation, error) ||
        !read_generation_u64(generation, "resource_generation",
                             out.resource_generation, error)) {
        return false;
    }
    return true;
}

Dictionary economy_input_generation_dictionary(
        const EconomyInputGeneration &generation) {
    Dictionary out;
    out["sample_day"] = generation.sample_day;
    out["epoch_id"] = static_cast<int64_t>(generation.epoch_id);
    out["map_generation"] = static_cast<int64_t>(generation.map_generation);
    out["building_generation"] =
        static_cast<int64_t>(generation.building_generation);
    out["country_generation"] =
        static_cast<int64_t>(generation.country_generation);
    out["resource_generation"] =
        static_cast<int64_t>(generation.resource_generation);
    return out;
}

} // namespace

Dictionary DCWorldExt::get_economy_checkpoint_format() const {
    Dictionary out;
    out["abi_version"] = RUNTIME_ECONOMY_ECP2_ABI_VERSION;
    out["schema_version"] = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    out["hash_version"] = runtime_chunk_hash_enabled() ? 2 : 1;
    return out;
}

Dictionary DCWorldExt::configure_economy(const Dictionary &catalog,
                                         const Dictionary &profile,
                                         int cell_count,
                                         int64_t seed) {
    _economy_read_report_cache.clear();
    invalidate_economy_input_capture_cache(true);
    // Headless/focused callers that have no explicit country package still
    // receive the same default-country bootstrap as production. MapGenerator
    // configures country first with the real water mask, so this path is only
    // the documented missing-country-data fallback.
    if (_country_runtime == nullptr) {
        _country_runtime = new NativeCountryRuntime();
        Dictionary country_profile;
        country_profile["country_runtime_mode"] = "ACTIVE";
        PackedStringArray starting;
        const PackedStringArray technologies = catalog.get("technology_ids", PackedStringArray());
        for (const char *id : {"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control"})
            if (technologies.has(id)) starting.push_back(id);
        country_profile["starting_technology_ids"] = starting;
        Dictionary configured = static_cast<NativeCountryRuntime *>(_country_runtime)->configure(
            catalog, country_profile, cell_count, seed);
        if (!static_cast<bool>(configured.get("ok", false))) return configured;
        if (_effect_runtime != nullptr)
            static_cast<NativeCountryRuntime *>(_country_runtime)->attach_effect_runtime(
                static_cast<EffectRuntime *>(_effect_runtime));
        // bootstrap() installs the restored technology Effect instances, so the
        // forwarder has to be in place before that call, not after it.
        static_cast<NativeCountryRuntime *>(_country_runtime)->attach_effect_forwarder(
            _effect_forwarder.get());
        // Same attachment as configure_country: without it, technologies that
        // carry a Modifier stay pending forever on this fallback path.
        if (_modifier_runtime != nullptr)
            static_cast<ModifierRuntime *>(_modifier_runtime)->attach_country_runtime(
                static_cast<NativeCountryRuntime *>(_country_runtime));
        static_cast<NativeCountryRuntime *>(_country_runtime)->attach_modifier_runtime(
            static_cast<ModifierRuntime *>(_modifier_runtime));
        PackedByteArray all_land;
        all_land.resize(cell_count);
        all_land.fill(0);
        Dictionary bootstrapped = static_cast<NativeCountryRuntime *>(_country_runtime)->bootstrap(
            Dictionary(), all_land);
        if (!static_cast<bool>(bootstrapped.get("ok", false))) return bootstrapped;
    }
    if (_economy_csv_recorder != nullptr)
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder)->request_stop();
    if (_economy_runtime == nullptr) _economy_runtime = new NativeEconomyRuntime();
    if (_modifier_runtime != nullptr)
        static_cast<ModifierRuntime *>(_modifier_runtime)->attach_economy_runtime(
            runtime_from(_economy_runtime));
    runtime_from(_economy_runtime)->attach_country_runtime(
        static_cast<NativeCountryRuntime *>(_country_runtime));
    if (_country_runtime != nullptr)
        static_cast<NativeCountryRuntime *>(_country_runtime)->attach_economy_runtime(
            runtime_from(_economy_runtime));
    runtime_from(_economy_runtime)->attach_modifier_runtime(
        static_cast<ModifierRuntime *>(_modifier_runtime));
    _economy_modifier_view_attached = false;
    runtime_from(_economy_runtime)->attach_trigger_runtime(
        static_cast<TriggerRuntime *>(_trigger_runtime));
    if (_effect_runtime != nullptr)
        runtime_from(_economy_runtime)->attach_effect_runtime(
            static_cast<EffectRuntime *>(_effect_runtime));
    // Tag predicates are effect-catalog data read by the economy's target
    // selector. Pushed on both attach paths because the two runtimes can be
    // configured in either order; an empty table here is overwritten by the
    // effect configure path once the catalog lands.
    if (_effect_runtime != nullptr)
        runtime_from(_economy_runtime)->set_target_tags(
            static_cast<EffectRuntime *>(_effect_runtime)->target_tags());
    // Economy can be configured before or after the Effect catalog; attach the
    // forwarder here as well as in the Effect configure path so the family
    // write path never runs without it once both exist.
    runtime_from(_economy_runtime)->attach_effect_forwarder(
        _effect_forwarder.get());
    _economy_last_notified_event_id = 0;
    invalidate_economy_read_view();
    return runtime_from(_economy_runtime)->configure(catalog, profile, cell_count, seed);
}

Dictionary DCWorldExt::bootstrap_economy(const Dictionary &population_packet,
                                         const Dictionary &market_packet) {
    _economy_read_report_cache.clear();
    invalidate_economy_input_capture_cache(true);
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    Dictionary result = runtime_from(_economy_runtime)->bootstrap(population_packet, market_packet);
        if (bool(result.get("ok", false)))
        _economy_read_report_cache = runtime_from(_economy_runtime)->report();
    invalidate_economy_read_view();
    return result;
}

void DCWorldExt::invalidate_economy_read_view() {
    _building_visual_pending_cells.clear();
    if (_economy_runtime != nullptr) runtime_from(_economy_runtime)->read_view_reset();
}

Dictionary DCWorldExt::submit_economy_commands(const Dictionary &packed_batch) {
    // Phase-2.4.5: refuse legacy ingress whenever StageOps is the effective
    // production writer, even before economy is configured.
    if (_runtime_host != nullptr &&
        _runtime_host->economy_production_writer_effective() ==
            EconomyProductionWriter::STAGE_OPS) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "economy_legacy_ingress_disabled";
        return out;
    }
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    // Production opcode admission stays on NativeEconomyRuntime until the full
    // 23-opcode POD extraction lands. Host POD queue is Phase 4 scaffolding.
    return runtime_from(_economy_runtime)->submit_commands(packed_batch);
}

Dictionary DCWorldExt::submit_economy_pod_commands(const Dictionary &packed_batch) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const PackedInt64Array request_ids =
        packed_batch.get("request_ids", PackedInt64Array());
    const PackedInt32Array opcodes =
        packed_batch.get("opcodes", PackedInt32Array());
    const PackedInt64Array transactions =
        packed_batch.get("transaction_ids", PackedInt64Array());
    const PackedInt64Array session_epochs =
        packed_batch.get("session_epochs", PackedInt64Array());
    const PackedInt64Array economy_generations =
        packed_batch.get("economy_generations", PackedInt64Array());
    const PackedInt64Array payload0s =
        packed_batch.get("payload0s", PackedInt64Array());
    const PackedInt64Array payload1s =
        packed_batch.get("payload1s", PackedInt64Array());
    const PackedInt64Array payload2s =
        packed_batch.get("payload2s", PackedInt64Array());
    const PackedInt32Array target_cells =
        packed_batch.get("target_cells", PackedInt32Array());
    const PackedInt64Array target_countries =
        packed_batch.get("target_countries", PackedInt64Array());
    const PackedInt64Array target_cohorts =
        packed_batch.get("target_cohorts", PackedInt64Array());
    const PackedInt64Array target_buildings =
        packed_batch.get("target_buildings", PackedInt64Array());
    const int64_t n = request_ids.size();
    if (opcodes.size() != n) {
        out["ok"] = false;
        out["code"] = "economy_pod_command_batch_size_mismatch";
        return out;
    }
    PackedInt64Array accepted_ids;
    for (int64_t i = 0; i < n; ++i) {
        RuntimeEconomyPodCommand command;
        command.request_id = static_cast<uint64_t>(request_ids[i]);
        command.opcode = opcodes[static_cast<int>(i)];
        if (i < transactions.size())
            command.transaction_id = static_cast<uint64_t>(transactions[i]);
        if (i < session_epochs.size())
            command.session_epoch = static_cast<uint64_t>(session_epochs[i]);
        if (i < economy_generations.size())
            command.economy_generation =
                static_cast<uint64_t>(economy_generations[i]);
        if (i < payload0s.size()) command.payload0 = payload0s[static_cast<int>(i)];
        if (i < payload1s.size()) command.payload1 = payload1s[static_cast<int>(i)];
        if (i < payload2s.size()) command.payload2 = payload2s[static_cast<int>(i)];
        if (i < target_cells.size())
            command.target_cell = target_cells[static_cast<int>(i)];
        if (i < target_countries.size())
            command.target_country = target_countries[static_cast<int>(i)];
        if (i < target_cohorts.size())
            command.target_cohort = target_cohorts[static_cast<int>(i)];
        if (i < target_buildings.size())
            command.target_building = target_buildings[static_cast<int>(i)];
        std::string error;
        if (!_runtime_host->submit_economy_pod_command(command, error)) {
            out["ok"] = false;
            out["code"] = error.empty() ? "economy_pod_command_rejected"
                                        : error.c_str();
            out["accepted_request_ids"] = accepted_ids;
            return out;
        }
        accepted_ids.push_back(request_ids[i]);
    }
    out["ok"] = true;
    out["accepted_request_ids"] = accepted_ids;
    return out;
}

Dictionary DCWorldExt::poll_economy_pod_receipts(int max_items) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const int limit = std::clamp(max_items, 0, 4096);
    Array rows;
    for (int i = 0; i < limit; ++i) {
        RuntimeEconomyPodReceipt receipt;
        if (!_runtime_host->poll_economy_pod_receipt(receipt)) break;
        Dictionary row;
        row["request_id"] = static_cast<int64_t>(receipt.request_id);
        row["transaction_id"] = static_cast<int64_t>(receipt.transaction_id);
        row["session_epoch"] = static_cast<int64_t>(receipt.session_epoch);
        row["economy_generation"] =
            static_cast<int64_t>(receipt.economy_generation);
        row["opcode"] = receipt.opcode;
        row["code"] = static_cast<int>(receipt.code);
        row["reason"] = String(receipt.reason);
        rows.push_back(row);
    }
    out["ok"] = true;
    out["receipts"] = rows;
    return out;
}

Dictionary DCWorldExt::run_economy_slice(const Dictionary &ctx) {
    return run_economy_slice_internal(ctx, false);
}

Dictionary DCWorldExt::run_economy_slice_compact(const Dictionary &ctx) {
    return run_economy_slice_internal(ctx, true);
}

Dictionary DCWorldExt::capture_economy_day_inputs(int64_t day_index) {
    if (_runtime_host != nullptr &&
        (_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY) ||
         _runtime_host->economy_input_requested_day() >= 0)) {
        auto boundary = _runtime_host->try_lock_economy_input_capture();
        Dictionary pending;
        pending["ok"] = false;
        pending["fatal"] = false;
        pending["captured"] = false;
        if (!boundary.owns_lock()) return pending;
        int64_t requested = _runtime_host->economy_input_requested_day();
        if (requested < 0) {
            // 主线程发布下一日环境前可预先冻结同一批 slots；只允许严格
            // 下一日且 worker 无在途日，不能改写一个已开始的 epoch。
            // worker 拥有 Economy 时不预采：它从环境帧自采，并叠上当天已提交的
            // Climate；这里读的主线程槽落后几天取决于时序，预采后 worker 会跳过自采。
            if (day_index < 0 || _economy_runtime == nullptr ||
                _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY))
                return pending;
            const auto report = _runtime_host->report();
            if (report.worker_day_inflight != 0 ||
                day_index != report.committed_day + 1 ||
                runtime_from(_economy_runtime)->epoch_active()) return pending;
            requested = day_index;
        }
        Dictionary result = begin_or_reuse_economy_input_epoch(requested, Dictionary());
        if (bool(result.get("ok", false)))
            _runtime_host->complete_economy_input_capture();
        return result;
    }
    if (day_index < 0) return Dictionary();
    return begin_or_reuse_economy_input_epoch(day_index, Dictionary());
}

#include "world_ext_economy_section_epoch_execution.inc"

PackedInt32Array DCWorldExt::get_economy_live_cells() {
    if (_economy_runtime == nullptr) return PackedInt32Array();
    return runtime_from(_economy_runtime)->economy_live_cells_query();
}

Dictionary DCWorldExt::get_economy_committed_audit_report() const {
    if (_economy_runtime == nullptr) {
        Dictionary out;
        out["available"] = false;
        return out;
    }
    return runtime_from(_economy_runtime)->committed_audit_report();
}

#include "world_ext_economy_section_metric_probes.inc"

Dictionary DCWorldExt::get_economy_report() const {    if (_economy_runtime == nullptr) {
        // R1-6: build_id must answer before an economy runtime exists.
        return economy_unavailable_report();
    }
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_read_boundary();
        if (!boundary.owns_lock()) {
            Dictionary cached = _economy_read_report_cache.duplicate(true);
            cached["report_boundary_pending"] = true;
            cached["report_available"] = !_economy_read_report_cache.is_empty();
            // Same reason as the cold path: the cached report may be empty while
            // the worker holds the boundary, and the build id never depends on it.
            cached["build_id"] = String::utf8(pk::pk_build_id());
            return cached;
        }
    }
    // This is still the compatibility DETAIL report, not a post-command
    // EconomyCommitView. Its arrays are inspected only at a stable boundary.
    _economy_read_report_cache = runtime_from(_economy_runtime)->report();
    Dictionary result = _economy_read_report_cache.duplicate(true);
    result["report_boundary_pending"] = false;
    result["report_available"] = true;
    return result;
}

#include "world_ext_economy_section_market_and_population.inc"

Dictionary DCWorldExt::get_cell_mobilization_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::CELL_MOBILIZATION_SNAPSHOT, {cell_idx}),
        [&] { return runtime->cell_mobilization_snapshot(cell_idx); });
}

Dictionary DCWorldExt::get_country_mobilization_summary(int country_slot) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::COUNTRY_MOBILIZATION_SUMMARY, {country_slot}),
        [&] { return runtime->country_mobilization_summary(country_slot); });
}

Dictionary DCWorldExt::get_mobilization_odds(
        int cell_idx, int profession, int action, int64_t spend_bp) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution() &&
        !economy_live_readable(_runtime_host.get(), runtime, boundary))
        return read_view_pending();
    return runtime->mobilization_odds(cell_idx, profession, action, spend_bp);
}

bool DCWorldExt::apply_mobilization_result(
        int cell_idx, int profession, int action, bool success) {
    if (_economy_runtime == nullptr) return false;
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return runtime->apply_mobilization_result(cell_idx, profession, action,
                                              success);
}

Dictionary DCWorldExt::resolve_player_mobilization(const Dictionary &choice) {
    if (_economy_runtime == nullptr) return unavailable();
    auto *runtime = runtime_from(_economy_runtime);
    const bool worker_owned = _runtime_host != nullptr &&
        _runtime_host->economy_worker_owns_execution();
    std::unique_lock<std::mutex> boundary;
    if (worker_owned && !economy_live_readable(_runtime_host.get(), runtime, boundary))
        return read_view_pending();
    return runtime->resolve_player_mobilization(choice);
}

#include "world_ext_economy_section_trade_and_fiscal.inc"

#include "world_ext_economy_section_buildings.inc"

Dictionary DCWorldExt::get_family_cell_snapshot(
        int cell_idx, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_CELL_SNAPSHOT, {cell_idx, offset, limit}),
        [&] { return runtime->family_cell_snapshot(cell_idx, offset, limit); });
}

Dictionary DCWorldExt::get_family_snapshot(int64_t family_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_SNAPSHOT, {family_handle}),
        [&] { return runtime->family_snapshot(family_handle); });
}

Dictionary DCWorldExt::get_family_traits(int64_t family_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_TRAITS, {family_handle}),
        [&] { return runtime->family_traits(family_handle); });
}

Dictionary DCWorldExt::get_family_branches(
        int64_t family_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_BRANCHES, {family_handle, offset, limit}),
        [&] { return runtime->family_branches(family_handle, offset, limit); });
}

#include "world_ext_economy_section_canals.inc"

#include "world_ext_economy_section_colonization.inc"

// Era advancement / national procurement budget. The setters only append to
// a mutex-guarded inbox inside NativeEconomyRuntime; the Economy owner thread
// (sync path or worker) applies it at the next epoch begin. This is safe in
// ACTIVE worker mode without taking the economy boundary.
Dictionary DCWorldExt::set_country_procurement_policy(
        int64_t country_handle, bool enabled, int treasury_share_bp,
        int research_share_bp, int64_t effective_day, int64_t sequence,
        int era_share_bp, int colonization_share_bp) {
    if (_economy_runtime == nullptr) return unavailable();
    return economy_api::set_country_procurement_policy(*runtime_from(_economy_runtime),
        country_handle, enabled, treasury_share_bp, research_share_bp,
        effective_day, sequence, era_share_bp, colonization_share_bp);
}

Dictionary DCWorldExt::set_era_procurement_target(
        int64_t country_handle, bool active, const PackedInt32Array &good_indices,
        const PackedInt64Array &required_quantities, int64_t effective_day,
        int64_t sequence) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->set_era_procurement_target(
        country_handle, active, good_indices, required_quantities,
        effective_day, sequence);
}

Dictionary DCWorldExt::country_procurement_snapshot(int64_t country_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::COUNTRY_PROCUREMENT_SNAPSHOT, {country_handle}),
        [&] { return runtime->country_procurement_snapshot(country_handle); });
}

#include "world_ext_economy_section_lineage_records.inc"

void DCWorldExt::append_economy_read_view_perf(Dictionary &out) const {
    if (_economy_runtime == nullptr) return;
    const Dictionary status = runtime_from(_economy_runtime)->read_view_status();
    out["economy_read_view_subscriptions"] = status.get("subscriptions", 0);
    out["economy_read_view_serve_count"] = status.get("serve_count", 0);
    out["economy_read_view_eval_count"] = status.get("eval_count", 0);
    out["economy_read_view_serve_us_total"] = status.get("serve_us_total", 0);
    out["economy_read_view_serve_us_max"] = status.get("serve_us_max", 0);
    out["economy_read_view_evicted_count"] = status.get("evicted_count", 0);
}

Dictionary DCWorldExt::get_economy_read_view_status() const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    Dictionary out = runtime->read_view_status();
    const NativeSimulationHost *host = _runtime_host.get();
    const bool worker_owned = host != nullptr && host->economy_worker_owns_execution();
    bool live_readable = !worker_owned;
    if (worker_owned) {
        std::unique_lock<std::mutex> boundary;
        live_readable = economy_live_readable(host, runtime, boundary);
    }
    out["ok"] = true;
    out["worker_owned"] = worker_owned;
    out["live_readable"] = live_readable;
    return out;
}


Dictionary DCWorldExt::run_economy_production_climate_math_probe(
        const Dictionary &vectors) const {
    if (_economy_runtime == nullptr) {
        NativeEconomyRuntime probe_runtime;
        return probe_runtime.production_climate_math_probe(vectors);
    }
    return runtime_from(_economy_runtime)->production_climate_math_probe(vectors);
}

int64_t DCWorldExt::get_economy_state_hash() const {
    return _economy_runtime == nullptr ? 0 : runtime_from(_economy_runtime)->state_hash();
}

Dictionary DCWorldExt::run_economy_stage_ops_day(int64_t day_index) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    // Match run_economy_slice_internal: same-day env/building capture must land
    // before epoch open, or prelude parks as pending_input forever.
    const Dictionary cap =
        begin_or_reuse_economy_input_epoch(day_index, Dictionary());
    if (bool(cap.get("fatal", false))) {
        out["ok"] = false;
        out["done"] = true;
        out["fatal"] = true;
        out["day_index"] = day_index;
        out["reason"] = String(
            cap.get("fatal_reason", "economy_day_input_capture_failed"));
        out["message"] = out["reason"];
        out["stage"] = String(cap.get("stage", "economy_day_inputs"));
        return out;
    }
    std::string error;
    const bool ok =
        runtime_from(_economy_runtime)->run_stage_ops_day(day_index, error);
    out["ok"] = ok;
    out["done"] = ok;
    out["fatal"] = !ok;
    out["day_index"] = day_index;
    out["input_capture_reused"] = cap.get("input_capture_reused", false);
    out["input_captured"] = cap.get("captured", false);
    if (!ok) {
        out["reason"] = String(error.c_str());
        out["message"] = String(error.c_str());
    }
    return out;
}

void DCWorldExt::set_economy_stage_ops_soak_parity_ok(bool ok) {
    if (!_runtime_host) {
        _runtime_host = std::make_unique<NativeSimulationHost>();
    }
    _runtime_host->set_economy_stage_ops_soak_parity_ok(ok);
}

bool DCWorldExt::get_economy_stage_ops_soak_parity_ok() const {
    return _runtime_host != nullptr &&
           _runtime_host->economy_stage_ops_soak_parity_ok();
}

Dictionary DCWorldExt::inject_economy_cadence_timing(double market_cycle_ms,
                                                     double slow_cycle_ms,
                                                     double investment_cycle_ms) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->inject_cadence_timing(
        market_cycle_ms, slow_cycle_ms, investment_cycle_ms);
}

Dictionary DCWorldExt::reset_economy(const String &reason) {
    if (_economy_csv_recorder != nullptr)
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder)->request_stop();
    if (_economy_runtime == nullptr) {
        Dictionary out;
        out["ok"] = true;
        out["reason"] = reason;
        return out;
    }
    _economy_last_notified_event_id = 0;
    Dictionary out = runtime_from(_economy_runtime)->reset(reason);
    invalidate_economy_read_view();
    if (static_cast<bool>(out.get("ok", false))) {
        invalidate_economy_input_capture_cache(true);
        _economy_read_report_cache = runtime_from(_economy_runtime)->report();
    }
    return out;
}

#include "world_ext_economy_section_recorder.inc"

#include "world_ext_economy_section_checkpoint.inc"

#include "world_ext_economy_section_events.inc"

} // namespace pk
