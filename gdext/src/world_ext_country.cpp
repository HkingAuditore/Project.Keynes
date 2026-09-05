#include "world_ext.h"
#include "country_runtime.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"

#include <chrono>

namespace pk {

using namespace godot;

namespace {
NativeCountryRuntime *country_runtime_from(void *opaque) {
    return static_cast<NativeCountryRuntime *>(opaque);
}

const NativeCountryRuntime *country_runtime_from(const void *opaque) {
    return static_cast<const NativeCountryRuntime *>(opaque);
}

Dictionary country_unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "country_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_country(const Dictionary &catalog,
                                         const Dictionary &profile,
                                         int cell_count, int64_t seed) {
    if (_country_runtime == nullptr) _country_runtime = new NativeCountryRuntime();
    if (_modifier_runtime != nullptr)
        static_cast<ModifierRuntime *>(_modifier_runtime)->attach_country_runtime(
            country_runtime_from(_country_runtime));
    if (_effect_runtime != nullptr) {
        static_cast<EffectRuntime *>(_effect_runtime)->attach_country_runtime(
            country_runtime_from(_country_runtime));
        country_runtime_from(_country_runtime)->attach_effect_runtime(
            static_cast<EffectRuntime *>(_effect_runtime));
    }
    country_runtime_from(_country_runtime)->attach_modifier_runtime(
        static_cast<ModifierRuntime *>(_modifier_runtime));
    Dictionary out = country_runtime_from(_country_runtime)->configure(catalog, profile, cell_count, seed);
    if (_economy_runtime != nullptr) {
        static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_country_runtime(
            country_runtime_from(_country_runtime));
        country_runtime_from(_country_runtime)->attach_economy_runtime(
            static_cast<NativeEconomyRuntime *>(_economy_runtime));
    }
    return out;
}

Dictionary DCWorldExt::bootstrap_country(const Dictionary &packet,
                                         const PackedByteArray &is_water) {
    if (_country_runtime == nullptr) return country_unavailable();
    Dictionary out = country_runtime_from(_country_runtime)->bootstrap(packet, is_water);
    if (static_cast<bool>(out.get("ok", false)) &&
        String(out.get("runtime_mode", "ACTIVE")) == "ACTIVE") {
        NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
        const auto publish_start = std::chrono::steady_clock::now();
        const int slot = component_id(StringName("cell_country_slot"));
        if (slot >= 0) {
            write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
        } else {
            runtime->mark_slot_publication(false, 0.0, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    return out;
}

Dictionary DCWorldExt::submit_country_commands(const Dictionary &packed_batch) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->submit_commands(packed_batch);
}

Dictionary DCWorldExt::capture_country_runtime_snapshot() {
    Dictionary out;
    if (_country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_runtime_unavailable";
        return out;
    }
    RuntimeCountryPodSnapshot snapshot;
    std::string error;
    if (!country_runtime_from(_country_runtime)->export_pod_snapshot(snapshot, error)) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_snapshot_capture_failed" : error.c_str();
        return out;
    }
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    if (!_runtime_host->publish_country_snapshot(snapshot)) {
        out["ok"] = false;
        out["code"] = "country_snapshot_validation_failed";
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["committed_day"] = snapshot.committed_day;
    out["country_count"] = static_cast<int>(snapshot.country_count);
    out["cell_count"] = static_cast<int>(snapshot.cell_count);
    out["technology_count"] = static_cast<int>(snapshot.technology_count);
    return out;
}

Dictionary DCWorldExt::capture_country_pod_catalog() {
    Dictionary out;
    if (_country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_runtime_unavailable";
        return out;
    }
    RuntimeCountryPodCatalog catalog;
    std::string error;
    if (!country_runtime_from(_country_runtime)->export_pod_catalog(catalog, error)) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_catalog_capture_failed" : error.c_str();
        return out;
    }
    PackedInt64Array costs;
    costs.resize(static_cast<int64_t>(catalog.technology_costs.size()));
    for (int64_t i = 0; i < costs.size(); ++i) costs.set(i, catalog.technology_costs[static_cast<size_t>(i)]);
    PackedInt32Array domains, flags, prereq_offsets, prerequisites;
    domains.resize(static_cast<int64_t>(catalog.technology_domains.size()));
    flags.resize(static_cast<int64_t>(catalog.technology_flags.size()));
    prereq_offsets.resize(static_cast<int64_t>(catalog.prerequisite_offsets.size()));
    prerequisites.resize(static_cast<int64_t>(catalog.prerequisites.size()));
    for (int64_t i = 0; i < domains.size(); ++i) domains.set(i, catalog.technology_domains[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < flags.size(); ++i) flags.set(i, catalog.technology_flags[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < prereq_offsets.size(); ++i) prereq_offsets.set(i, catalog.prerequisite_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < prerequisites.size(); ++i) prerequisites.set(i, catalog.prerequisites[static_cast<size_t>(i)]);
    PackedInt32Array condition_offsets, condition_ops, condition_refs;
    PackedInt64Array condition_values;
    condition_offsets.resize(static_cast<int64_t>(catalog.research_condition_offsets.size()));
    condition_ops.resize(static_cast<int64_t>(catalog.research_condition_ops.size()));
    condition_refs.resize(static_cast<int64_t>(catalog.research_condition_refs.size()));
    condition_values.resize(static_cast<int64_t>(catalog.research_condition_values.size()));
    for (int64_t i = 0; i < condition_offsets.size(); ++i) condition_offsets.set(i, catalog.research_condition_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_ops.size(); ++i) condition_ops.set(i, catalog.research_condition_ops[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_refs.size(); ++i) condition_refs.set(i, catalog.research_condition_refs[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < condition_values.size(); ++i) condition_values.set(i, catalog.research_condition_values[static_cast<size_t>(i)]);
    PackedInt32Array milestone_offsets, milestone_candidates, milestone_required, entry_milestones;
    milestone_offsets.resize(static_cast<int64_t>(catalog.milestone_offsets.size()));
    milestone_candidates.resize(static_cast<int64_t>(catalog.milestone_candidates.size()));
    milestone_required.resize(static_cast<int64_t>(catalog.milestone_required_counts.size()));
    entry_milestones.resize(static_cast<int64_t>(catalog.entry_milestone_indices.size()));
    for (int64_t i = 0; i < milestone_offsets.size(); ++i) milestone_offsets.set(i, catalog.milestone_offsets[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < milestone_candidates.size(); ++i) milestone_candidates.set(i, catalog.milestone_candidates[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < milestone_required.size(); ++i) milestone_required.set(i, catalog.milestone_required_counts[static_cast<size_t>(i)]);
    for (int64_t i = 0; i < entry_milestones.size(); ++i) entry_milestones.set(i, catalog.entry_milestone_indices[static_cast<size_t>(i)]);
    out["ok"] = true;
    out["catalog_hash"] = static_cast<int64_t>(catalog.catalog_hash);
    out["technology_count"] = static_cast<int>(catalog.technology_count);
    out["technology_words"] = static_cast<int>(catalog.technology_words);
    out["technology_points_good_id"] = catalog.technology_points_good_id;
    out["research_conditions_complete"] = catalog.research_conditions_complete;
    out["technology_costs"] = costs;
    out["technology_domains"] = domains;
    out["technology_flags"] = flags;
    out["prerequisite_offsets"] = prereq_offsets;
    out["prerequisites"] = prerequisites;
    out["milestone_offsets"] = milestone_offsets;
    out["milestone_candidates"] = milestone_candidates;
    out["milestone_required_counts"] = milestone_required;
    out["entry_milestone_indices"] = entry_milestones;
    out["research_condition_offsets"] = condition_offsets;
    out["research_condition_ops"] = condition_ops;
    out["research_condition_refs"] = condition_refs;
    out["research_condition_values"] = condition_values;
    return out;
}

Dictionary DCWorldExt::run_country_slice(const Dictionary &ctx) {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    Dictionary out = runtime->run_slice(ctx);
    if (static_cast<bool>(out.get("ok", false)) &&
        static_cast<bool>(out.get("published_to_slot", false)) &&
        static_cast<int64_t>(out.get("changed_cells", 0)) > 0) {
        const int slot = component_id(StringName("cell_country_slot"));
        const auto publish_start = std::chrono::steady_clock::now();
        if (slot >= 0) {
            const PackedInt32Array indices = out.get("_changed_cell_indices", PackedInt32Array());
            const PackedInt32Array owners = out.get("_changed_cell_owners", PackedInt32Array());
            if (!indices.is_empty() && indices.size() == owners.size())
                write_i32_indexed(slot, indices, owners);
            else
                write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            ++_runtime_graph_flush_slot_count;
            _runtime_graph_visual_diff_cell_count += static_cast<uint64_t>(
                !indices.is_empty() ? indices.size() :
                static_cast<int64_t>(out.get("cell_count", 0)));
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
            out["elapsed_ms"] = static_cast<double>(out.get("elapsed_ms", 0.0)) + publish_ms;
        } else {
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(false, publish_ms, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    out.erase("_changed_cell_indices");
    out.erase("_changed_cell_owners");
    return out;
}

Dictionary DCWorldExt::sync_country_territory_to_map() {
    Dictionary out;
    out["ok"] = false;
    if (_country_runtime == nullptr) {
        out["reason"] = "country_runtime_unavailable";
        return out;
    }
    if (_map_data == nullptr) {
        out["reason"] = "map_data_unbound";
        return out;
    }
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    const int slot = component_id(StringName("cell_country_slot"));
    if (slot < 0) {
        out["reason"] = "country_slot_unavailable";
        return out;
    }
    const auto publish_start = std::chrono::steady_clock::now();
    const PackedInt32Array snapshot = runtime->cell_country_snapshot();
    write_i32_range(slot, 0, snapshot);
    _flush_slot_to_map(slot);
    const double publish_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - publish_start).count();
    ++_runtime_graph_flush_slot_count;
    _runtime_graph_visual_diff_cell_count +=
        static_cast<uint64_t>(snapshot.size());
    _runtime_graph_country_territory_sync_ms = publish_ms;
    runtime->mark_slot_publication(true, publish_ms);
    out["ok"] = true;
    out["cells"] = snapshot.size();
    out["slot_publish_ms"] = publish_ms;
    return out;
}

bool DCWorldExt::country_should_run(int64_t day_index) const {
    return _country_runtime != nullptr && country_runtime_from(_country_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_country_report() const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->report();
}

int64_t DCWorldExt::get_country_state_hash() const {
    return _country_runtime == nullptr ? 0 : country_runtime_from(_country_runtime)->state_hash();
}

Dictionary DCWorldExt::get_country_cell_summary(int cell_idx) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->cell_summary(cell_idx);
}

Dictionary DCWorldExt::get_country_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->country_snapshot(handle);
}

Dictionary DCWorldExt::get_country_treasury_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->treasury_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->research_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_signal_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->research_signal_snapshot(handle);
}

Dictionary DCWorldExt::consume_country_visual_era_dirty_slots() {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->consume_visual_era_dirty_slots();
}

bool DCWorldExt::has_completed_country_technology(
        int64_t handle, int32_t technology_id) const {
    return _country_runtime != nullptr &&
        country_runtime_from(_country_runtime)->has_completed_technology(
            handle, technology_id);
}

Dictionary DCWorldExt::get_country_tax_policy_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->tax_policy_snapshot(handle);
}

Dictionary DCWorldExt::get_country_cell_tax_policy_snapshot(int cell_idx) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->cell_tax_policy_snapshot(cell_idx);
}

Dictionary DCWorldExt::get_country_ui_snapshot(int64_t handle,
                                                int section_mask) const {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    Dictionary summary = runtime->country_summary(handle);
    if (!static_cast<bool>(summary.get("ok", false))) return summary;

    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["section"] = section_mask;
    out["section_mask"] = section_mask;
    out["country_generation"] = static_cast<int64_t>(runtime->generation());
    out["country_state_version"] = summary.get("state_version", 0);
    out["revision"] = summary.get("state_version", 0);
    out["published_day"] = runtime->report().get("last_committed_day", -1);
    out["summary"] = summary;

    Dictionary revisions;
    revisions["country_state_version"] = summary.get("state_version", 0);
    revisions["country_generation"] = static_cast<int64_t>(runtime->generation());

    if ((section_mask & 1) != 0) {
        out["research"] = runtime->research_snapshot(handle);
        out["research_signals"] = runtime->research_signal_snapshot(handle);
    }
    if ((section_mask & 2) != 0) {
        Dictionary country = summary.duplicate(false);
        country["technology_ids"] = runtime->completed_technology_ids(handle);
        out["country_snapshot"] = country;
        out["treasury"] = runtime->treasury_snapshot(handle);
        out["tax_policy"] = runtime->tax_policy_snapshot(handle);
        out["fiscal"] = get_country_fiscal_snapshot(handle);
        Dictionary trade = get_country_trade_snapshot(
            handle, String("summary"), 0, 1);
        out["trade_summary"] = trade;
        const int64_t trade_revision = trade.get("revision", int64_t{0});
        int64_t class_opinion_revision = 0;
        if (_economy_runtime != nullptr) {
            class_opinion_revision = static_cast<int64_t>(
                static_cast<NativeEconomyRuntime *>(_economy_runtime)->
                    country_class_opinion_snapshot().revision);
        }
        out["economy_trade_revision"] = trade_revision;
        out["economy_class_opinion_revision"] = class_opinion_revision;
        revisions["economy_trade_revision"] = trade_revision;
        revisions["economy_class_opinion_revision"] =
            class_opinion_revision;
    }
    if ((section_mask & 4) != 0) {
        Dictionary ideology = get_ideology_snapshot(handle);
        out["ideology"] = ideology;
        const int64_t support_revision = ideology.get(
            "support_revision", int64_t{0});
        out["ideology_support_revision"] = support_revision;
        revisions["ideology_support_revision"] = support_revision;
    }
    out["revision_components"] = revisions;
    return out;
}

Dictionary DCWorldExt::poll_country_events(int64_t after_event_id, int limit) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->poll_events(after_event_id, limit);
}

Dictionary DCWorldExt::reset_country(const String &reason) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->reset(reason);
}

Dictionary DCWorldExt::begin_country_save(int chunk_bytes) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_economy_runtime != nullptr &&
        !static_cast<NativeEconomyRuntime *>(_economy_runtime)->country_save_allowed()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "country_save_requires_committed_economy_boundary";
        return out;
    }
    return country_runtime_from(_country_runtime)->begin_save(chunk_bytes);
}

PackedByteArray DCWorldExt::read_country_save_chunk(int max_bytes) {
    return _country_runtime == nullptr ? PackedByteArray()
        : country_runtime_from(_country_runtime)->read_save_chunk(max_bytes);
}

Dictionary DCWorldExt::end_country_save() {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->end_save();
}

Dictionary DCWorldExt::begin_country_restore() {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_economy_runtime != nullptr &&
        !static_cast<NativeEconomyRuntime *>(_economy_runtime)->country_restore_allowed()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "country_restore_must_precede_economy_bootstrap";
        return out;
    }
    return country_runtime_from(_country_runtime)->begin_restore();
}

Dictionary DCWorldExt::feed_country_restore_chunk(const PackedByteArray &chunk) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->feed_restore_chunk(chunk);
}

Dictionary DCWorldExt::end_country_restore() {
    if (_country_runtime == nullptr) return country_unavailable();
    Dictionary out = country_runtime_from(_country_runtime)->end_restore();
    if (static_cast<bool>(out.get("ok", false))) {
        NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
        const auto publish_start = std::chrono::steady_clock::now();
        const int slot = component_id(StringName("cell_country_slot"));
        if (slot >= 0) {
            write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
        } else {
            runtime->mark_slot_publication(false, 0.0, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    return out;
}

} // namespace pk
