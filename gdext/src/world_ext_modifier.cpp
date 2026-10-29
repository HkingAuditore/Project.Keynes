#include "world_ext.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "modifier_runtime.h"
#include "cell_program_eligibility.h"
#include "ideology_runtime.h"
#include "native_simulation_host.h"

#include <cstring>
#include <limits>
#include <type_traits>
#include <vector>

namespace pk {

using namespace godot;

namespace {
ModifierRuntime *runtime_from(void *opaque) {
    return static_cast<ModifierRuntime *>(opaque);
}
const ModifierRuntime *runtime_from(const void *opaque) {
    return static_cast<const ModifierRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "modifier_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_modifiers(const Dictionary &catalog,
                                           int cell_count) {
    if (_modifier_runtime == nullptr) _modifier_runtime = new ModifierRuntime();
    ModifierRuntime *runtime = runtime_from(_modifier_runtime);
    runtime->attach_country_runtime(static_cast<NativeCountryRuntime *>(_country_runtime));
    runtime->attach_economy_runtime(static_cast<NativeEconomyRuntime *>(_economy_runtime));
    if (_country_runtime != nullptr)
        static_cast<NativeCountryRuntime *>(_country_runtime)->attach_modifier_runtime(runtime);
    if (_economy_runtime != nullptr)
        static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_modifier_runtime(runtime);
    Dictionary result = runtime->configure(catalog, cell_count);
    if (!static_cast<bool>(result.get("ok", false))) return result;
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    RuntimeModifierPodCatalog pod_catalog;
    std::string pod_error;
    const bool pod_ok = runtime->export_pod_catalog(pod_catalog, pod_error) &&
        _runtime_host->configure_modifier_pod(pod_catalog, pod_error);
    if (pod_ok) {
        std::vector<std::pair<uint64_t, int32_t>> key_hashes;
        runtime->export_definition_key_hashes(key_hashes);
        _runtime_host->set_modifier_definition_key_hashes(key_hashes);
    }
    result["modifier_pod_ready"] = pod_ok;
    result["modifier_pod_fallback_reason"] = String(pod_error.c_str());
    result["modifier_pod_catalog_hash"] = pod_ok
        ? static_cast<int64_t>(_runtime_host->modifier_pod_catalog_hash()) : 0;
    return result;
}

Dictionary DCWorldExt::submit_modifier_commands(const Dictionary &packed_batch) {
    if (_modifier_runtime == nullptr) return unavailable();
    ModifierRuntime *runtime = runtime_from(_modifier_runtime);
    const bool worker_authoritative = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::MODIFIER);

    auto encode_and_enqueue = [&](const Dictionary &batch,
                                  const PackedInt64Array &request_ids,
                                  bool require_enqueue) -> Dictionary {
        Dictionary result;
        result["ok"] = true;
        const PackedInt32Array opcodes = batch.get("opcodes", PackedInt32Array());
        const PackedInt32Array producers = batch.get("producer_ids", PackedInt32Array());
        const PackedInt64Array sequences = batch.get("sequences", PackedInt64Array());
        const PackedInt64Array days = batch.get("effective_days", PackedInt64Array());
        const PackedStringArray definitions = batch.get("definition_keys", PackedStringArray());
        const PackedInt32Array domains = batch.get("domains", PackedInt32Array());
        const PackedInt32Array scopes = batch.get("scopes", PackedInt32Array());
        const PackedInt64Array entities = batch.get("entity_handles", PackedInt64Array());
        const PackedInt64Array groups = batch.get("group_handles", PackedInt64Array());
        const PackedInt64Array source_types = batch.get("source_types", PackedInt64Array());
        const PackedInt64Array source_ids = batch.get("source_ids", PackedInt64Array());
        const PackedInt32Array durations = batch.get("duration_days", PackedInt32Array());
        const PackedInt32Array stacks = batch.get("stacks", PackedInt32Array());
        const PackedInt32Array magnitudes = batch.get("magnitude_q16", PackedInt32Array());
        const PackedInt64Array handles = batch.get("modifier_handles", PackedInt64Array());
        const int32_t count = request_ids.size();
        int32_t enqueued = 0;
        std::string enqueue_error;
        const RuntimeThreadReport host_report = _runtime_host->report();
        // Commands that are valid on whichever day they land (rather than
        // against the environment generation observed now) opt out of the
        // worker's input-generation staleness check.
        const bool bind_input_generation =
            !bool(batch.get("unbound_input_generation", false));
        for (int32_t i = 0; i < count; ++i) {
            RuntimeCommandPacket packet;
            packet.envelope.request_id = static_cast<uint64_t>(request_ids[i]);
            packet.envelope.producer_id = static_cast<uint32_t>(producers[i]);
            packet.envelope.sequence = static_cast<uint64_t>(sequences[i]);
            packet.envelope.observed_generation = host_report.generation;
            packet.envelope.requested_day = days[i];
            packet.envelope.effective_day = days[i];
            packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
            packet.envelope.opcode = static_cast<uint16_t>(opcodes[i]);
            packet.envelope.payload_size = RUNTIME_MODIFIER_POD_WIRE_SIZE;
            size_t cursor = 0;
            const auto append = [&packet, &cursor](auto value) {
                using T = decltype(value);
                using U = std::make_unsigned_t<T>;
                U bits = static_cast<U>(value);
                for (size_t byte = 0; byte < sizeof(T); ++byte) {
                    packet.payload[cursor++] = static_cast<uint8_t>(
                        bits & static_cast<U>(0xffu));
                    bits >>= 8u;
                }
            };
            const int32_t definition_id = runtime->definition_id_for_key(
                definitions[i].utf8().get_data());
            const uint64_t entity_handle = static_cast<uint64_t>(entities[i]);
            const uint32_t target_generation = scopes[i] == ModifierRuntime::ENTITY
                ? static_cast<uint32_t>(entity_handle >> 32u) : 0u;
            append(static_cast<uint32_t>(RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION));
            append(static_cast<uint16_t>(domains[i]));
            append(static_cast<uint16_t>(scopes[i]));
            append(definition_id);
            append(entity_handle);
            append(static_cast<uint64_t>(groups[i]));
            append(static_cast<uint64_t>(source_types[i]));
            append(static_cast<uint64_t>(source_ids[i]));
            append(static_cast<int32_t>(durations[i]));
            append(static_cast<int32_t>(stacks[i]));
            append(static_cast<int32_t>(magnitudes[i]));
            append(static_cast<uint64_t>(handles[i]));
            append(target_generation);
            append(bind_input_generation ? host_report.environment_generation
                                         : decltype(host_report.environment_generation){0});
            if (cursor != RUNTIME_MODIFIER_POD_WIRE_SIZE ||
                !_runtime_host->enqueue_modifier_shadow(std::move(packet))) {
                enqueue_error = "modifier_host_enqueue_failed";
                if (require_enqueue) {
                    result["ok"] = false;
                    result["reason"] = String(enqueue_error.c_str());
                    result["modifier_host_enqueued"] = enqueued;
                    return result;
                }
                continue;
            }
            ++enqueued;
        }
        result["request_ids"] = request_ids;
        result["modifier_host_enqueued"] = enqueued;
        result["modifier_shadow_enqueued"] = enqueued;
        result["modifier_shadow_fallback_reason"] = String(enqueue_error.c_str());
        return result;
    };

    if (worker_authoritative) {
        // E8: Host is the sole writer. Never apply to legacy first.
        if (!_runtime_host) {
            Dictionary out;
            out["ok"] = false;
            out["reason"] = "modifier_host_unavailable";
            return out;
        }
        const PackedInt32Array opcodes = packed_batch.get("opcodes", PackedInt32Array());
        const int32_t count = opcodes.size();
        PackedInt64Array request_ids;
        request_ids.resize(count);
        for (int32_t i = 0; i < count; ++i) {
            request_ids.set(i, static_cast<int64_t>(
                _runtime_host->allocate_command_request_id()));
        }
        return encode_and_enqueue(packed_batch, request_ids, true);
    }

    Dictionary result = runtime->submit_commands(packed_batch);
    if (!static_cast<bool>(result.get("ok", false)) || !_runtime_host) return result;
    const PackedInt64Array request_ids = result.get("request_ids", PackedInt64Array());
    Dictionary mirrored = encode_and_enqueue(packed_batch, request_ids, false);
    result["modifier_shadow_enqueued"] = mirrored.get("modifier_host_enqueued", 0);
    result["modifier_shadow_fallback_reason"] =
        mirrored.get("modifier_shadow_fallback_reason", "");
    return result;
}

Dictionary DCWorldExt::run_modifier_daily(int64_t day_index) {
    if (_modifier_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::MODIFIER)) {
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["work_done"] = 0;
        out["commands_applied"] = 0;
        out["expired"] = 0;
        out["stage"] = "modifier_worker_authoritative";
        out["path"] = "MODIFIER_WORKER";
        out["suppressed"] = true;
        return out;
    }
    return runtime_from(_modifier_runtime)->run_daily(day_index);
}

bool DCWorldExt::modifier_should_run(int64_t day_index) const {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::MODIFIER)) {
        return false;
    }
    return _modifier_runtime != nullptr &&
        runtime_from(_modifier_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_modifier_command_result(int64_t request_id) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->command_result(request_id);
}

Dictionary DCWorldExt::list_modifiers(int domain, int64_t entity_handle,
                                      const String &stat_key) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->list_modifiers(
            domain, static_cast<uint64_t>(entity_handle), stat_key);
}

Dictionary DCWorldExt::explain_modifier_stat(int domain, int64_t entity_handle,
                                             int64_t group_handle,
                                             const String &stat_key,
                                             double base_value) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->explain(domain,
            static_cast<uint64_t>(entity_handle), static_cast<uint64_t>(group_handle),
            stat_key, base_value);
}

Dictionary DCWorldExt::build_derived_cell_front_for_test(
        const Dictionary &terms) const {
    Dictionary out;
    const PackedInt32Array stat_ids =
        terms.get("stat_ids", PackedInt32Array());
    const PackedInt32Array cells = terms.get("cells", PackedInt32Array());
    const PackedInt64Array countries =
        terms.get("source_countries", PackedInt64Array());
    const PackedInt32Array operations =
        terms.get("operations", PackedInt32Array());
    const PackedFloat64Array adds = terms.get("adds", PackedFloat64Array());
    const PackedFloat64Array factors =
        terms.get("factors", PackedFloat64Array());
    const PackedInt32Array sources =
        terms.get("magnitude_sources", PackedInt32Array());
    const PackedInt32Array metric_ids =
        terms.get("metric_ids", PackedInt32Array());
    const PackedFloat64Array ramp_scales =
        terms.get("ramp_scales", PackedFloat64Array());
    const double sampler_scale = terms.get("sampler_scale", -1.0);

    const int32_t count = stat_ids.size();
    if (count <= 0 || cells.size() != count) {
        out["ok"] = false;
        out["reason"] = "ramp_test_terms_ragged";
        return out;
    }

    // One contribution per term keeps the fixture honest: the materializer folds
    // whatever list it is given, so a single-term-per-contribution shape is exactly
    // the production shape.
    std::vector<DerivedProgramContribution> contributions;
    contributions.reserve(static_cast<size_t>(count));
    for (int32_t i = 0; i < count; ++i) {
        DerivedProgramContribution program;
        program.source_country = static_cast<uint64_t>(countries[i]);
        program.backend = CellProgramBackend::DerivedCell;
        program.cells.push_back(cells[i]);
        DerivedProgramContribution::Term term;
        term.stat_id = stat_ids[i];
        term.operation = operations[i];
        term.add = adds[i];
        term.factor = factors[i];
        if (sources.size() > i && sources[i] == 1) {
            term.magnitude_source =
                DerivedProgramContribution::MagnitudeSource::RampMetric;
            term.metric_id = metric_ids.size() > i ? metric_ids[i] : -1;
            term.ramp_scale = ramp_scales.size() > i ? ramp_scales[i] : 1.0;
            term.ramp_has_ceil = false;
        }
        program.terms.push_back(term);
        contributions.push_back(std::move(program));
    }

    DerivedCellFront front;
    DerivedMaterializeReport report;
    bool skipped = false;
    DerivedMaterializeOptions options;
    DerivedRampSampler sampler;
    if (sampler_scale >= 0.0) {
        // Deterministic stand-in: sample == cell * sampler_scale. That makes the
        // expected contribution `cell * sampler_scale * ramp_scale`, which a test
        // can compute independently instead of echoing the implementation.
        sampler = [sampler_scale](int32_t metric_id, int32_t cell,
                                  uint64_t source_country) -> double {
            (void)metric_id;
            (void)source_country;
            return static_cast<double>(cell) * sampler_scale;
        };
        options.ramp_sampler = &sampler;
    }
    const bool built = build_derived_cell_front(
        contributions, static_cast<uint64_t>(terms.get("world_identity", 1)),
        static_cast<uint64_t>(terms.get("map_generation", 1)),
        static_cast<int64_t>(terms.get("sample_day", 1)),
        static_cast<uint64_t>(terms.get("epoch_id", 1)),
        static_cast<uint64_t>(terms.get("execution_contract_hash", 1)),
        nullptr, front, report, skipped, options);

    out["ok"] = built;
    out["skipped"] = skipped;
    out["ramp_terms_evaluated"] =
        static_cast<int64_t>(report.ramp_terms_evaluated);
    out["scratch_bytes"] = static_cast<int64_t>(report.scratch_bytes);
    out["scratch_nodes"] = static_cast<int64_t>(report.scratch_nodes);
    out["ramp_terms_deferred"] = static_cast<int64_t>(report.ramp_terms_deferred);
    out["truncated"] = static_cast<int64_t>(report.truncated);
    out["cells_visited"] = static_cast<int64_t>(report.cells_visited);

    // Flatten the produced front into stat order so a test reads values[i] against
    // the i-th requested cell (they are ascending in the fixture).
    PackedFloat64Array values;
    for (const DerivedCellStatRow &row : front.rows) {
        for (const int32_t cell : row.cells) {
            const DerivedCellContribution *slot = row.find(cell);
            values.append(slot == nullptr ? 0.0 : slot->sum_add);
        }
    }
    out["values"] = values;
    Dictionary report_rows;
    report_rows["programs_seen"] = report.programs_seen;
    report_rows["programs_derived"] = report.programs_derived;
    report_rows["commands_folded"] =
        static_cast<int64_t>(report.commands_folded);
    report_rows["rows_emitted"] = static_cast<int64_t>(report.rows_emitted);
    // Container-growth events in the fold. Exact for what it counts; see the field's
    // comment -- this is NOT a malloc counter and does not claim to be.
    report_rows["allocations"] = static_cast<int64_t>(report.allocations);
    // Cell-visits the fold still owes at the last slice boundary. NOT a rename of
    // `cells_visited`: it is its complement, and the two move in opposite directions
    // (measured: the same 40-cell job yields peak 0 in one slice and 39 in forty).
    report_rows["rebuild_backlog_cells"] =
        static_cast<int64_t>(report.rebuild_backlog_cells);
    report_rows["rebuild_backlog_peak_cells"] =
        static_cast<int64_t>(report.rebuild_backlog_peak_cells);
    out["scratch_bytes"] = static_cast<int64_t>(report.scratch_bytes);
    out["scratch_nodes"] = static_cast<int64_t>(report.scratch_nodes);
    out["report"] = report_rows;
    return out;
}

Dictionary DCWorldExt::evaluate_effect_program_magnitude(
        const String &program_key,
        const PackedInt64Array &metric_values) const {
    Dictionary out;
    if (_effect_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "effect_runtime_unavailable";
        return out;
    }
    std::vector<int64_t> values;
    values.reserve(static_cast<size_t>(metric_values.size()));
    for (int32_t i = 0; i < metric_values.size(); ++i)
        values.push_back(metric_values[i]);

    const std::string key(program_key.utf8().get_data());
    int64_t magnitude = 0;
    std::string error;
    // `runtime_from()` is specialised per runtime type and resolves to
    // ModifierRuntime in this translation unit, so the EffectRuntime call needs an
    // explicit cast from the stored void pointer.
    const auto *effect = static_cast<const EffectRuntime *>(_effect_runtime);
    const bool ok = effect->evaluate_program_magnitude_for_metrics(
        key, values.empty() ? nullptr : values.data(),
        static_cast<int32_t>(values.size()), magnitude, error);
    out["ok"] = ok;
    out["magnitude"] = magnitude;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::resolve_modifier_definition_terms(
        const String &definition_key) const {
    if (_modifier_runtime == nullptr) return unavailable();
    std::vector<ModifierRuntime::ResolvedTerm> terms;
    const bool found = runtime_from(_modifier_runtime)->resolve_definition_terms(
        std::string(definition_key.utf8().get_data()), terms);
    Dictionary out;
    out["ok"] = found;
    Array rows;
    for (const ModifierRuntime::ResolvedTerm &term : terms) {
        Dictionary row;
        row["stat_id"] = term.stat_id;
        row["operation"] = term.operation;
        row["value"] = term.value;
        rows.push_back(row);
    }
    out["terms"] = rows;
    return out;
}

Dictionary DCWorldExt::get_modifier_report() const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->report();
}

Dictionary DCWorldExt::poll_modifier_events(int64_t after_event_id,
                                            int limit) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->poll_events(after_event_id, limit);
}

double DCWorldExt::evaluate_modifier_stat(int domain, int64_t entity_handle,
                                          int64_t group_handle,
                                          const String &stat_key,
                                          double base_value) const {
    return _modifier_runtime == nullptr ? base_value
        : runtime_from(_modifier_runtime)->effective_value(domain,
            stat_key.utf8().get_data(), static_cast<uint64_t>(entity_handle),
            static_cast<uint64_t>(group_handle), base_value);
}

int64_t DCWorldExt::register_gameplay_modifier_object(const String &archetype) {
    return _modifier_runtime == nullptr ? 0 : static_cast<int64_t>(
        runtime_from(_modifier_runtime)->register_gameplay_object(
            archetype.utf8().get_data()));
}

Dictionary DCWorldExt::unregister_gameplay_modifier_object(int64_t handle,
                                                           int64_t day_index) {
    if (_modifier_runtime == nullptr) return unavailable();
    Dictionary out;
    out["ok"] = runtime_from(_modifier_runtime)->unregister_gameplay_object(
        static_cast<uint64_t>(handle), day_index);
    out["reason"] = static_cast<bool>(out["ok"]) ? "" :
        "modifier_gameplay_handle_stale";
    return out;
}

Dictionary DCWorldExt::set_gameplay_modifier_base(int64_t handle,
                                                  const String &stat_key,
                                                  double value) {
    if (_modifier_runtime == nullptr) return unavailable();
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->set_gameplay_base(
        static_cast<uint64_t>(handle), stat_key.utf8().get_data(), value, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::get_gameplay_modifier_effective(int64_t handle,
                                                       int64_t group_handle,
                                                       const String &stat_key) const {
    if (_modifier_runtime == nullptr) return unavailable();
    double value = 0.0;
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->gameplay_effective(
        static_cast<uint64_t>(handle), static_cast<uint64_t>(group_handle),
        stat_key.utf8().get_data(), value, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    out["effective_value"] = value;
    return out;
}

PackedByteArray DCWorldExt::capture_modifier_domain(int domain) const {
    PackedByteArray out;
    if (_modifier_runtime == nullptr) return out;
    std::vector<uint8_t> bytes;
    std::string error;
    if (!runtime_from(_modifier_runtime)->serialize_domain(domain, bytes, error))
        return out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

Dictionary DCWorldExt::restore_modifier_domain(int domain,
                                               const PackedByteArray &bytes) {
    if (_modifier_runtime == nullptr) return unavailable();
    std::vector<uint8_t> native(static_cast<size_t>(bytes.size()));
    if (!native.empty()) std::memcpy(native.data(), bytes.ptr(), native.size());
    std::string error;
    // `allow_tax_catalog_extension = true`: the legacy hash only matches when the
    // current catalog is exactly the saved one plus `country.tax.*` stats -- an
    // append no existing instance can reference, so accepting it is safe. The
    // country/economy paths gate the same flag on their own save version; this
    // GDScript-facing entry point has no version to consult, and leaving it
    // defaulted to false made `_legacy_catalog_hash_without_tax` unreachable
    // here, so every tax-stat addition rejected every PKCM/PKGP section.
    const bool ok = runtime_from(_modifier_runtime)->restore_domain(
        domain, native, error, true);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::clear_modifier_domain(int domain) {
    if (_modifier_runtime == nullptr) return unavailable();
    if (domain < 0 || domain >= ModifierRuntime::DOMAIN_COUNT)
        return unavailable();
    runtime_from(_modifier_runtime)->clear_domain(domain);
    Dictionary out;
    out["ok"] = true;
    out["domain"] = domain;
    out["migration"] = "legacy_empty_modifier_store";
    return out;
}

Dictionary DCWorldExt::get_runtime_modifier_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["available"] = false;
    if (!_runtime_host) {
        out["reason"] = "runtime_host_unavailable";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_modifier_snapshot(cursor, slot)) {
        out["ok"] = true;
        out["reason"] = "";
        return out;
    }
    const RuntimeModifierPodSnapshot &snapshot =
        _runtime_host->modifier_snapshot_buffer(slot);
    bool shape_ok = snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _runtime_host->modifier_pod_catalog_hash();
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        shape_ok = shape_ok && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        shape_ok = shape_ok && bucket.domain < 4 && bucket.scope < 3;
    if (!shape_ok) {
        _runtime_host->release_modifier_snapshot(slot);
        out["reason"] = "modifier_snapshot_shape_or_catalog_invalid";
        return out;
    }
    PackedInt64Array domain_versions;
    domain_versions.resize(4);
    for (int32_t i = 0; i < 4; ++i)
        domain_versions.set(i, static_cast<int64_t>(snapshot.domain_versions[i]));
    PackedInt32Array entry_domains, entry_definitions, entry_scopes,
        entry_generations, entry_stacks, entry_magnitudes;
    PackedInt64Array entry_handles, entry_targets, entry_entities, entry_groups,
        entry_source_types, entry_source_ids, entry_applied_days, entry_expiry_days;
    const int64_t entry_count = static_cast<int64_t>(snapshot.entries.size());
    entry_domains.resize(entry_count); entry_definitions.resize(entry_count);
    entry_scopes.resize(entry_count); entry_generations.resize(entry_count);
    entry_stacks.resize(entry_count); entry_magnitudes.resize(entry_count);
    entry_handles.resize(entry_count); entry_targets.resize(entry_count);
    entry_entities.resize(entry_count); entry_groups.resize(entry_count);
    entry_source_types.resize(entry_count); entry_source_ids.resize(entry_count);
    entry_applied_days.resize(entry_count); entry_expiry_days.resize(entry_count);
    for (int64_t i = 0; i < entry_count; ++i) {
        const auto &entry = snapshot.entries[static_cast<size_t>(i)];
        entry_domains.set(i, entry.domain); entry_definitions.set(i, entry.definition_id);
        entry_scopes.set(i, entry.scope); entry_generations.set(i, entry.target_generation);
        entry_stacks.set(i, entry.stacks); entry_magnitudes.set(i, entry.magnitude_q16);
        entry_handles.set(i, static_cast<int64_t>(entry.modifier_handle));
        entry_targets.set(i, static_cast<int64_t>(entry.target_handle));
        entry_entities.set(i, static_cast<int64_t>(entry.entity_handle));
        entry_groups.set(i, static_cast<int64_t>(entry.group_handle));
        entry_source_types.set(i, static_cast<int64_t>(entry.source_type));
        entry_source_ids.set(i, static_cast<int64_t>(entry.source_id));
        entry_applied_days.set(i, entry.applied_day); entry_expiry_days.set(i, entry.expires_day);
    }
    PackedInt32Array bucket_domains, bucket_scopes, bucket_stats, bucket_counts;
    PackedInt64Array bucket_scope_ids;
    PackedFloat64Array bucket_adds, bucket_factors;
    const int64_t bucket_count = static_cast<int64_t>(snapshot.buckets.size());
    bucket_domains.resize(bucket_count); bucket_scopes.resize(bucket_count);
    bucket_stats.resize(bucket_count); bucket_counts.resize(bucket_count);
    bucket_scope_ids.resize(bucket_count); bucket_adds.resize(bucket_count);
    bucket_factors.resize(bucket_count);
    for (int64_t i = 0; i < bucket_count; ++i) {
        const auto &bucket = snapshot.buckets[static_cast<size_t>(i)];
        bucket_domains.set(i, bucket.domain); bucket_scopes.set(i, bucket.scope);
        bucket_stats.set(i, static_cast<int32_t>(bucket.stat_id));
        bucket_counts.set(i, static_cast<int32_t>(bucket.active_count));
        bucket_scope_ids.set(i, static_cast<int64_t>(bucket.scope_id));
        bucket_adds.set(i, bucket.sum_add); bucket_factors.set(i, bucket.product_factor);
    }
    out["ok"] = true; out["available"] = true; out["reason"] = "";
    out["abi_version"] = static_cast<int64_t>(snapshot.abi_version);
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["committed_day"] = snapshot.committed_day;
    out["catalog_hash"] = static_cast<int64_t>(snapshot.catalog_hash);
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["domain_versions"] = domain_versions;
    out["entry_domains"] = entry_domains; out["entry_handles"] = entry_handles;
    out["entry_target_handles"] = entry_targets; out["entry_target_generations"] = entry_generations;
    out["entry_definition_ids"] = entry_definitions; out["entry_scopes"] = entry_scopes;
    out["entry_entity_handles"] = entry_entities; out["entry_group_handles"] = entry_groups;
    out["entry_source_types"] = entry_source_types; out["entry_source_ids"] = entry_source_ids;
    out["entry_stacks"] = entry_stacks; out["entry_magnitude_q16"] = entry_magnitudes;
    out["entry_applied_days"] = entry_applied_days; out["entry_expiry_days"] = entry_expiry_days;
    out["bucket_domains"] = bucket_domains; out["bucket_scopes"] = bucket_scopes;
    out["bucket_stat_ids"] = bucket_stats; out["bucket_scope_ids"] = bucket_scope_ids;
    out["bucket_sum_add"] = bucket_adds; out["bucket_product_factor"] = bucket_factors;
    out["bucket_active_counts"] = bucket_counts;
    _runtime_host->release_modifier_snapshot(slot);
    return out;
}


// Derived cell layer test bridge (plan 22 ADR02).
//
// Deliberately minimal: accept a list of `(stat_id, cell, source_country, add,
// factor)` rows, build a front, install it, and report. Production does NOT use
// this path -- the Economy freeze coordinator builds the candidate in C++ and
// calls `ModifierRuntime::install_derived_cell_layer` directly, exactly as plan
// §4.2 requires. This exists so a Godot test can prove the one property that
// ADR02 hinges on: `apply_runtime_modifier_snapshot` rebuilds `_stores` but must
// leave the derived front intact.
Dictionary DCWorldExt::install_derived_cell_layer_for_test(const Dictionary &front) {
    Dictionary out;
    out["ok"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    const PackedInt32Array stat_ids = front.get("stat_ids", PackedInt32Array());
    const PackedInt32Array cells = front.get("cells", PackedInt32Array());
    const PackedInt64Array sources = front.get("source_countries", PackedInt64Array());
    const PackedFloat64Array adds = front.get("adds", PackedFloat64Array());
    const PackedFloat64Array factors = front.get("factors", PackedFloat64Array());
    const int32_t count = stat_ids.size();
    if (cells.size() != count || sources.size() != count || adds.size() != count ||
            factors.size() != count) {
        out["reason"] = "derived_cell_layer_column_shape_invalid";
        return out;
    }

    DerivedCellFrontBuilder builder;
    builder.reset(static_cast<uint64_t>(front.get("world_identity", 1)),
                  static_cast<uint64_t>(front.get("map_generation", 1)),
                  static_cast<int64_t>(front.get("sample_day", 0)),
                  static_cast<uint64_t>(front.get("epoch_id", 0)),
                  static_cast<uint64_t>(front.get("execution_contract_hash", 0)));
    for (int32_t i = 0; i < count; ++i) {
        if (!builder.add(stat_ids[i], cells[i],
                static_cast<uint64_t>(sources[i]), adds[i], factors[i])) {
            out["reason"] = "derived_cell_layer_row_invalid";
            return out;
        }
    }
    // Bump every stat that received a row, so the layer version reflects real
    // content rather than "the builder ran" (plan §7.4).
    for (int32_t i = 0; i < count; ++i) builder.bump_stat_version(stat_ids[i]);

    DerivedCellFront built;
    const bool produced = builder.install(built);
    const uint64_t expected =
        static_cast<uint64_t>(front.get("expected_generation", 0));
    bool skipped = false;
    std::string error;
    const bool installed = runtime_from(_modifier_runtime)->install_derived_cell_layer(
        std::move(built), expected, skipped, error);
    out["ok"] = installed;
    out["installed"] = installed;
    out["skipped"] = skipped;
    out["produced"] = produced;
    out["reason"] = installed ? String("") : String(error.c_str());
    out["layer_generation"] = static_cast<int64_t>(
        runtime_from(_modifier_runtime)->derived_cell_layer_generation());
    return out;
}

int64_t DCWorldExt::modifier_stat_bucket_version(
        int domain, const PackedInt32Array &stat_ids) const {
    if (_modifier_runtime == nullptr) return 0;
    std::vector<int32_t> wanted;
    wanted.reserve(static_cast<size_t>(stat_ids.size()));
    for (int32_t i = 0; i < stat_ids.size(); ++i) wanted.push_back(stat_ids[i]);
    return static_cast<int64_t>(
        runtime_from(_modifier_runtime)->stat_bucket_version(
            domain, wanted.data(), wanted.size()));
}

Dictionary DCWorldExt::collect_modifier_scope_ids(
        int domain, int scope, const PackedInt32Array &stat_ids) const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    std::vector<int32_t> wanted;
    wanted.reserve(static_cast<size_t>(stat_ids.size()));
    for (int32_t i = 0; i < stat_ids.size(); ++i) wanted.push_back(stat_ids[i]);
    std::vector<uint64_t> scope_ids;
    runtime_from(_modifier_runtime)->collect_scope_ids(
        domain, scope, wanted.data(), wanted.size(), scope_ids);
    PackedInt64Array packed;
    packed.resize(static_cast<int32_t>(scope_ids.size()));
    for (size_t i = 0; i < scope_ids.size(); ++i)
        packed[static_cast<int32_t>(i)] = static_cast<int64_t>(scope_ids[i]);
    out["ok"] = true;
    out["scope_ids"] = packed;
    return out;
}

Dictionary DCWorldExt::collect_modifier_scope_stat_entries(
        int domain, int scope, const PackedInt32Array &stat_ids) const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    std::vector<int32_t> wanted;
    wanted.reserve(static_cast<size_t>(stat_ids.size()));
    for (int32_t i = 0; i < stat_ids.size(); ++i) wanted.push_back(stat_ids[i]);
    std::vector<uint64_t> scope_ids;
    std::vector<int32_t> out_stats;
    runtime_from(_modifier_runtime)->collect_scope_stat_entries(
        domain, scope, wanted.data(), wanted.size(), scope_ids, out_stats);
    PackedInt64Array packed_scopes;
    packed_scopes.resize(static_cast<int32_t>(scope_ids.size()));
    for (size_t i = 0; i < scope_ids.size(); ++i)
        packed_scopes[static_cast<int32_t>(i)] = static_cast<int64_t>(scope_ids[i]);
    PackedInt32Array packed_stats;
    packed_stats.resize(static_cast<int32_t>(out_stats.size()));
    for (size_t i = 0; i < out_stats.size(); ++i)
        packed_stats[static_cast<int32_t>(i)] = out_stats[i];
    out["ok"] = true;
    out["scope_ids"] = packed_scopes;
    out["stat_ids"] = packed_stats;
    return out;
}

Dictionary DCWorldExt::resolve_modifier_stat(const String &stat_key) const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    const std::string key(stat_key.utf8().get_data());
    const int32_t sid =
        runtime_from(_modifier_runtime)->stat_id_for_key(key);
    out["ok"] = sid >= 0;
    out["stat_id"] = static_cast<int64_t>(sid);
    out["clamp_max"] = sid >= 0
        ? runtime_from(_modifier_runtime)->stat_clamp_max(key.c_str(), 0.0) : 0.0;
    return out;
}

Dictionary DCWorldExt::get_cell_program_rollout() const {
    Dictionary out;
    out["ok"] = true;
    // The selector kinds enabled at the CURRENT milestone. `enabled_any` is what a
    // test asks when it only needs "is the derived path driving production yet".
    PackedInt32Array kinds;
    bool any = false;
    for (int32_t kind = 0; kind <= 17; ++kind) {
        if (cell_program_rollout_enabled(kind)) {
            kinds.append(kind);
            any = true;
        }
    }
    out["enabled_kinds"] = kinds;
    out["enabled_any"] = any;
    // `rollout` used to echo the staged enum. The switch is gone (§15.7), so the
    // honest answer is a boolean: is the derived backend expressing every selector it
    // can, with no milestone gate left in between? Kept as a field because fixtures ask
    // for it, and "1" now means "no gate", not "stage 3".
    out["rollout"] = static_cast<int64_t>(1);
    out["rollout_stage_removed"] = true;
    return out;
}

Dictionary DCWorldExt::get_effective_stat_value(const String &stat_key,
                                                 int64_t cell,
                                                 int64_t entity_handle,
                                                 double base_value) const {
    Dictionary out;
    out["ok"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    auto *runtime = static_cast<const ModifierRuntime *>(_modifier_runtime);
    const int32_t stat_id = runtime->stat_id_for_key(std::string(stat_key.utf8().get_data()));
    if (stat_id < 0) {
        out["reason"] = "stat_unknown";
        return out;
    }
    out["ok"] = true;
    out["stat_id"] = stat_id;
    // The production call, so this reports the number the game would see.
    out["value"] = runtime->effective_value(ModifierRuntime::ECONOMY, stat_id,
        static_cast<uint64_t>(entity_handle), static_cast<uint64_t>(cell), base_value);

    // The derived layer's own slice of it, when the cell has one. Reported separately so
    // a test can tell "the derived row contributed" from "the legacy bucket did".
    bool derived_found = false;
    if (cell >= 0) {
        const DerivedCellFront *front = runtime->derived_cell_front();
        if (front != nullptr) {
            const DerivedCellStatRow *row = front->row_for_stat(stat_id);
            if (row != nullptr) {
                const DerivedCellContribution *slot =
                    row->find(static_cast<int32_t>(cell));
                if (slot != nullptr) {
                    derived_found = true;
                    out["derived_add"] = slot->sum_add;
                    out["derived_factor"] = slot->product_nonzero;
                    out["derived_zero_factor_count"] =
                        static_cast<int64_t>(slot->zero_factor_count);
                    out["derived_contributors"] =
                        static_cast<int64_t>(slot->contributor_count);
                    out["derived_source_country"] =
                        static_cast<int64_t>(slot->source_country);
                }
            }
        }
    }
    out["derived_present"] = derived_found;
    return out;
}

Dictionary DCWorldExt::probe_fan_out_ownership(
        int64_t country_handle, int64_t source_cell, int64_t selector_kind,
        int64_t param0, int64_t param1, int64_t dilate_depth) const {
    Dictionary out;
    out["ok"] = false;
    if (_economy_runtime == nullptr || _ideology_runtime == nullptr) {
        out["reason"] = "runtime_unavailable";
        return out;
    }
    auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    auto *ideology = static_cast<NativeIdeologyRuntime *>(_ideology_runtime);
    const int32_t cell = static_cast<int32_t>(source_cell);
    if (cell < 0 || cell >= economy->cell_count()) {
        out["reason"] = "source_cell_out_of_range";
        return out;
    }
    const int32_t p0 = static_cast<int32_t>(param0);
    const int32_t scope = pk::decode_ownership_scope(p0);
    // `resolve_selector_cell_cap`, NOT an ad-hoc `authored > 0 ? authored : 32`.
    //
    // The old fallback meant `param0 = 0` was measured as "32 sources", i.e. the probe
    // could not exercise the UNCAPPED case at all and would have reported
    // "removing the cap costs nothing" from a comparison of 32 against 32. The
    // production OWN_TERRITORY branch resolves the cap the same way
    // (`economy_runtime_family_buff.cpp:2500`), so this also stops the probe from
    // describing behaviour the runtime does not have.
    const int32_t cap = pk::resolve_selector_cell_cap(
        static_cast<int32_t>(selector_kind), pk::ownership_stripped_cap(p0),
        economy->cell_count());

    // Collect the UNFILTERED fan-out exactly as the production path does, then run the
    // shared filter. Doing both halves here is the point: a probe that re-implemented
    // the predicate would prove nothing about the shipped code.
    std::vector<int32_t> raw;
    economy->collect_effect_target_cells(cell,
        static_cast<int32_t>(selector_kind), cap, static_cast<int32_t>(param1), raw,
        param0);
    std::vector<int32_t> kept = raw;
    ideology->apply_fan_out_ownership_filter(cell, scope, kept);

    PackedInt32Array raw_packed;
    for (const int32_t v : raw) raw_packed.append(v);
    PackedInt32Array kept_packed;
    for (const int32_t v : kept) kept_packed.append(v);

    out["ok"] = true;
    out["scope"] = pk::ownership_scope_name(scope);
    out["scope_value"] = scope;
    out["source_cell"] = cell;
    out["source_country"] = economy->cell_country_slot(cell);
    out["raw_cells"] = raw_packed;
    out["kept_cells"] = kept_packed;
    out["raw_count"] = static_cast<int64_t>(raw.size());
    out["kept_count"] = static_cast<int64_t>(kept.size());
    // Optional: run the BATCH dilation over the collected sources. This is the path the
    // kind 14/15 fan-out now takes, so a fixture can time it instead of the per-source
    // loop it replaced.
    if (dilate_depth > 0) {
        std::vector<int32_t> dilated;
        economy->dilate_cell_set(raw, static_cast<int32_t>(dilate_depth), dilated);
        PackedInt32Array dilated_packed;
        for (const int32_t v : dilated) dilated_packed.append(v);
        out["dilated_cells"] = dilated_packed;
        out["dilated_count"] = static_cast<int64_t>(dilated.size());
    }
    out["country_handle"] = country_handle;
    // Why the ring may be empty: the radial kinds bail unless all four columns are
    // sized, and that guard is invisible from outside.
    out["building_context"] = economy->building_context_ready_for_test();
    return out;
}

Dictionary DCWorldExt::probe_cell_program_backend(
        const Dictionary &facts) const {
    CellProgramFacts parsed;
    parsed.target_domain =
        static_cast<int32_t>(facts.get("target_domain", 0));
    parsed.selector_kind =
        static_cast<int32_t>(facts.get("target_selector_kind", -1));
    parsed.lifecycle = static_cast<int32_t>(facts.get("lifecycle", 0));
    parsed.duration_days =
        static_cast<int32_t>(facts.get("duration_days", -1));
    parsed.stack_policy = static_cast<int32_t>(facts.get("stack_policy", 0));
    parsed.max_stacks = static_cast<int32_t>(facts.get("max_stacks", 1));

    // An unknown selector kind is refused outright rather than defaulted into a
    // backend: a card whose selector was renamed must fail visibly (plan §4.4).
    if (!cell_program_selector_supported(parsed.selector_kind)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "selector_kind_not_supported";
        out["selector_kind"] = parsed.selector_kind;
        return out;
    }

    // Optional single command, so a test can exercise the per-command conditions
    // without constructing a whole ProgramSet.
    if (facts.has("command_value_mode")) {
        CellProgramCommandFacts command;
        command.value_mode =
            static_cast<int32_t>(facts.get("command_value_mode", 1));
        command.stack_top_is_constant =
            bool(facts.get("command_stack_top_is_constant", false));
        command.definition_resolved =
            bool(facts.get("command_definition_resolved", false));
        command.all_terms_sum =
            bool(facts.get("command_all_terms_sum", false));
        command.stacks = static_cast<int32_t>(facts.get("command_stacks", 1));
        command.duration_days =
            static_cast<int32_t>(facts.get("command_duration_days", -1));
        // `has_metric_ramp` was MISSING here. It is what separates "the derived
        // layer can express this magnitude" from "it cannot", and leaving it at its
        // default `false` made every ramp probe report
        // `non_constant_value_mode` -- i.e. the probe said "rejected" no matter what
        // the real runtime would decide. Caught while trying to explain why an
        // ACTIVE ramp card produced `seen=0`; the answer was that this bridge, not
        // the runtime, was wrong.
        command.has_metric_ramp =
            bool(facts.get("command_has_metric_ramp", false));
        parsed.commands.push_back(command);
    }

    const CellProgramDecision decision = decide_cell_program_backend(parsed);
    Dictionary out;
    out["ok"] = true;
    out["backend"] = decision.backend == CellProgramBackend::DerivedCell
        ? String("DerivedCell") : String("EffectInstance");
    out["reason"] =
        String(cell_program_legacy_reason_name(decision.reason));
    out["detail"] = String(decision.detail.c_str());
    // Capability and rollout are separate answers; report both so a test can prove
    // they do not collapse into one another.
    out["rollout_enabled"] = cell_program_rollout_enabled(parsed.selector_kind);
    return out;
}

Dictionary DCWorldExt::drain_derived_cell_layer(int64_t day_index) {
    Dictionary out;
    if (_ideology_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "ideology_runtime_unavailable";
        return out;
    }
    // NON-const: draining advances the rebuild.
    auto *ideology = static_cast<NativeIdeologyRuntime *>(_ideology_runtime);
    // Bounded: a rebuild needs at most (contributions / min_batch) steps, and a
    // runaway loop here would hang a day rather than fail it.
    int32_t steps = 0;
    while (ideology->derived_rebuild_pending() && steps < 4096) {
        // A local, not `*new std::string()`: that leaked one string per step.
        std::string step_error;
        ideology->step_derived_rebuild(day_index, step_error);
        ++steps;
    }
    out["ok"] = true;
    out["steps"] = steps;
    out["complete"] = !ideology->derived_rebuild_pending();
    return out;
}

Dictionary DCWorldExt::get_derived_multi_country_report() const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    auto *runtime = static_cast<const ModifierRuntime *>(_modifier_runtime);
    const DerivedCellFront *front = runtime->derived_cell_front();
    if (front == nullptr) {
        out["ok"] = true;
        out["rows"] = 0;
        out["cells"] = 0;
        out["multi_country_cells"] = 0;
        out["max_contributors"] = 0;
        out["countries"] = PackedInt64Array();
        return out;
    }
    int64_t cells = 0;
    int64_t multi = 0;
    int32_t max_contributors = 0;
    // Distinct handles across the whole front, so a caller can see WHICH countries
    // reached the layer, not only how many cells they touched.
    std::vector<uint64_t> handles;
    for (const DerivedCellStatRow &row : front->rows) {
        cells += static_cast<int64_t>(row.cells.size());
        for (const DerivedCellContribution &slot : row.contributions) {
            const int32_t contributors = static_cast<int32_t>(slot.contributor_count);
            if (contributors > max_contributors) max_contributors = contributors;
            if (contributors > 1) ++multi;
            if (slot.source_country != 0)
                handles.push_back(slot.source_country);
        }
    }
    std::sort(handles.begin(), handles.end());
    handles.erase(std::unique(handles.begin(), handles.end()), handles.end());
    PackedInt64Array packed;
    for (const uint64_t handle : handles)
        packed.append(static_cast<int64_t>(handle));

    out["ok"] = true;
    out["rows"] = static_cast<int64_t>(front->rows.size());
    out["cells"] = cells;
    // The number B10 needs: cells reached by MORE than one country.
    out["multi_country_cells"] = multi;
    out["max_contributors"] = max_contributors;
    out["countries"] = packed;
    out["generation"] = static_cast<int64_t>(front->generation);
    return out;
}

Dictionary DCWorldExt::get_derived_materialize_report() const {
    Dictionary out;
    if (_ideology_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "ideology_runtime_unavailable";
        return out;
    }
    // `runtime_from()` is specialised per runtime type, so it cannot be reused
    // here; `_ideology_runtime` is stored as `void *` (world_ext.h:3416) and
    // the concrete type is known from the include.
    const auto *ideology = static_cast<const NativeIdeologyRuntime *>(
        _ideology_runtime);
    if (ideology == nullptr) {
        out["ok"] = false;
        out["reason"] = "ideology_runtime_unavailable";
        return out;
    }
    const DerivedMaterializeReport &report = ideology->derived_materialize_report();
    out["ok"] = true;
    out["programs_seen"] = report.programs_seen;
    out["programs_derived"] = report.programs_derived;
    out["programs_skipped_legacy"] = report.programs_skipped_legacy;
    out["cells_visited"] = report.cells_visited;
    out["commands_folded"] = report.commands_folded;
    out["rows_emitted"] = report.rows_emitted;
    // See the comment on `report_rows["rebuild_backlog_cells"]`: this is the fold's
    // remaining work, not a synonym for `cells_visited`.
    out["rebuild_backlog_cells"] = report.rebuild_backlog_cells;
    out["rebuild_backlog_peak_cells"] = report.rebuild_backlog_peak_cells;
    out["allocations"] = report.allocations;
    out["scratch_bytes"] = static_cast<int64_t>(report.scratch_bytes);
    out["scratch_nodes"] = static_cast<int64_t>(report.scratch_nodes);
    // Hard §12.4 condition: the derived path must never truncate. Surfaced
    // explicitly so a regression fails a test rather than silently dropping
    // targets.
    out["truncated"] = report.truncated;
    out["missing_stat"] = report.missing_stat;
    return out;
}

Dictionary DCWorldExt::get_derived_cell_layer_report() const {
    Dictionary out;
    if (_modifier_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    const DerivedCellFront *layer =
        runtime_from(_modifier_runtime)->derived_cell_front();
    out["ok"] = true;
    out["installed"] = layer != nullptr;
    out["layer_generation"] = static_cast<int64_t>(
        runtime_from(_modifier_runtime)->derived_cell_layer_generation());
    if (layer == nullptr) {
        out["stat_count"] = int64_t{0};
        out["cell_count"] = int64_t{0};
        out["stat_ids"] = PackedInt32Array();
        return out;
    }
    // STRUCTURAL MEMORY (§18.3 "front/candidate/retained/scratch peak").
    //
    // The front is the dominant resident term: one `DerivedCellContribution` plus one
    // cell id per (stat, cell). Reporting the size from the structure rather than from a
    // heap sample keeps it deterministic -- a heap counter would make the number depend
    // on allocator behaviour, which is not what the gate is about.
    //
    // These are BYTES OF THE FRONT, not process RSS. Said plainly so nobody reads 57 KB
    // as "the whole migration costs 57 KB".
    int64_t front_bytes = 0;
    int64_t contribution_count = 0;
    int64_t row_overhead_bytes = 0;
    {
        const auto *modifier = runtime_from(_modifier_runtime);
        const DerivedCellFront *front = modifier->derived_cell_front();
        if (front != nullptr) {
            // ONE formula for both the report and the peak tracker:
            // `pk::derived_cell_front_bytes` in `derived_cell_layer.h`. It also counts
            // `stat_versions`, which this inline copy used to miss -- two size formulas
            // for one structure is the same drift pattern as the kind-16 cap.
            front_bytes = pk::derived_cell_front_bytes(*front);
            for (const DerivedCellStatRow &row : front->rows)
                contribution_count += static_cast<int64_t>(row.contributions.size());
            row_overhead_bytes =
                static_cast<int64_t>(front->rows.size()) *
                static_cast<int64_t>(sizeof(DerivedCellStatRow));
        }
    }
    out["front_bytes"] = front_bytes;
    out["front_row_overhead_bytes"] = row_overhead_bytes;
    out["contribution_count"] = contribution_count;
    out["contribution_bytes"] = static_cast<int64_t>(sizeof(DerivedCellContribution));
    // `stat_versions` is sized by the STAT-ID SPACE, not by the number of rows, so it is
    // reported separately: without this term the identity "front_bytes == cells + contribs
    // + row overhead" no longer closes. Exported so a fixture can verify the whole sum
    // instead of hard-coding the difference.
    out["stat_versions_bytes"] = layer != nullptr
        ? static_cast<int64_t>(layer->stat_versions.size()) *
              static_cast<int64_t>(sizeof(uint64_t))
        : int64_t{0};
    out["bytes_per_contribution"] =
        static_cast<int64_t>(sizeof(int32_t)) +
        static_cast<int64_t>(sizeof(DerivedCellContribution));

    PackedInt32Array stat_ids;
    int64_t cell_count = 0;
    for (const DerivedCellStatRow &row : layer->rows) {
        stat_ids.append(row.stat_id);
        cell_count += static_cast<int64_t>(row.cells.size());
    }
    out["stat_count"] = static_cast<int64_t>(layer->rows.size());
    out["cell_count"] = cell_count;
    out["stat_ids"] = stat_ids;
    out["sample_day"] = layer->sample_day;
    out["epoch_id"] = static_cast<int64_t>(layer->epoch_id);
    return out;
}

Dictionary DCWorldExt::apply_runtime_modifier_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["available"] = false;
    out["applied"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    if (!_runtime_host) {
        out["reason"] = "runtime_host_unavailable";
        return out;
    }
    if (!_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER)) {
        out["ok"] = true;
        out["reason"] = "modifier_not_worker_authoritative";
        return out;
    }
    // Worker Economy reads the shared ModifierRuntime under this boundary for
    // the whole day. Rebuild only between days so effective_value / bucket
    // vectors cannot be torn under the hot loop.
    auto boundary_lock = _runtime_host->try_lock_economy_input_capture();
    if (!boundary_lock.owns_lock()) {
        out["ok"] = true;
        out["reason"] = "economy_day_inflight";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_modifier_snapshot(cursor, slot)) {
        out["ok"] = true;
        out["reason"] = "";
        return out;
    }
    // Copy out of the ring before apply. Modifier release returns the slot to
    // FREE; without a local copy a concurrent publish can rewrite the buffer
    // while legacy Store vectors are still being rebuilt from it.
    const RuntimeModifierPodSnapshot snapshot =
        _runtime_host->modifier_snapshot_buffer(slot);
    const int64_t generation = static_cast<int64_t>(snapshot.generation);
    const int64_t committed_day = snapshot.committed_day;
    const int64_t state_hash = static_cast<int64_t>(snapshot.state_hash);
    _runtime_host->release_modifier_snapshot(slot);
    bool shape_ok = snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _runtime_host->modifier_pod_catalog_hash();
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        shape_ok = shape_ok && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        shape_ok = shape_ok && bucket.domain < 4 && bucket.scope < 3;
    if (!shape_ok) {
        out["reason"] = "modifier_snapshot_shape_or_catalog_invalid";
        return out;
    }
    std::string apply_error;
    const bool applied =
        runtime_from(_modifier_runtime)->apply_pod_snapshot(snapshot, apply_error);
    out["ok"] = applied;
    out["available"] = true;
    out["applied"] = applied;
    out["generation"] = generation;
    out["committed_day"] = committed_day;
    out["state_hash"] = state_hash;
    out["reason"] = applied ? "" : String(apply_error.c_str());
    return out;
}

Dictionary DCWorldExt::runtime_modifier_pod_self_test() const {
    std::string error;
    const bool authority_ok = RuntimeModifierPodAuthority::self_test(error);
    NativeSimulationHost protocol_host;
    const bool protocol_ok = authority_ok && protocol_host.modifier_pod_self_test(&error);
    const bool ok = authority_ok && protocol_ok;
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = ok ? "" : String(error.c_str());
    out["implemented_domain_mask"] = static_cast<int64_t>(
        NativeSimulationHost::implemented_domain_mask());
    return out;
}

float DCWorldExt::modifier_climate_radiative_target(int cell,
                                                    float base_value) const {
    return _modifier_runtime == nullptr ? base_value
        : runtime_from(_modifier_runtime)->climate_radiative_target(cell, base_value);
}

double DCWorldExt::modifier_country_output_factor(int64_t country_handle) const {
    return _modifier_runtime == nullptr ? 1.0
        : runtime_from(_modifier_runtime)->country_economy_output_factor(
            static_cast<uint64_t>(country_handle));
}

int64_t DCWorldExt::ensure_modifier_building_handle(int cell, int type_id,
                                                    int owner_signature_id) {
    return _modifier_runtime == nullptr ? 0 : static_cast<int64_t>(
        runtime_from(_modifier_runtime)->ensure_building_identity(
            cell, type_id, owner_signature_id));
}

double DCWorldExt::modifier_building_output_factor(int64_t building_handle,
                                                   int64_t settlement_cell) const {
    return _modifier_runtime == nullptr ? 1.0
        : runtime_from(_modifier_runtime)->economy_building_output_factor(
            static_cast<uint64_t>(building_handle),
            static_cast<uint64_t>(settlement_cell), 2);
}

} // namespace pk
