#include "world_ext.h"
#include "runtime_switch_registry.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "effect_runtime.h"
#include "effect_instance_forwarder.h"
#include "ideology_runtime.h"
#include "ideology_opinion_bridge.h"
#include "modifier_runtime.h"
#include "native_simulation_host.h"
#include "runtime_ideology_pod.h"
#include "runtime_ideology_read_view.h"

#include <algorithm>
#include <cstdlib>
#include <limits>
#include <optional>

namespace pk {
using namespace godot;

namespace {
NativeIdeologyRuntime *ideology_runtime_from(void *opaque) {
    return static_cast<NativeIdeologyRuntime *>(opaque);
}
const NativeIdeologyRuntime *ideology_runtime_from(const void *opaque) {
    return static_cast<const NativeIdeologyRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "ideology_runtime_unavailable";
    return out;
}

uint64_t worker_request_id(uint32_t producer_id, uint64_t sequence,
        uint16_t opcode, uint64_t country_handle) {
    uint64_t hash = 1469598103934665603ull;
    const auto mix = [&hash](uint64_t value) {
        for (uint32_t byte = 0; byte < 8; ++byte) {
            hash ^= static_cast<uint8_t>((value >> (byte * 8u)) & 0xffu);
            hash *= 1099511628211ull;
        }
    };
    mix(producer_id); mix(sequence); mix(opcode); mix(country_handle);
    return hash == 0 ? 1 : hash;
}

RuntimeIdeologyOpinionSnapshot copy_opinion_snapshot(
        const NativeEconomyRuntime &runtime) {
    // Single conversion point (ideology_opinion_bridge.h): the worker publish and
    // the main-thread accrual must not drift field by field.
    if (!runtime.class_opinion_source_override_enabled_for_test())
        return ideology_opinion_from_economy(
            runtime.country_class_opinion_snapshot());
    return ideology_opinion_from_economy(
        runtime.country_class_opinion_source_snapshot());
}

// "The worker owns IDEOLOGY, or will as soon as its first day commits".
//
// `domain_is_worker_authoritative` alone is the WRONG predicate for a load: the grant is
// DEFERRED (it reads 0x000 until a day commits, see `domain_main_thread_suppressed`), and a load
// happens BEFORE the first commit of the new worker lifetime -- so checking only the live
// grant would skip the import exactly when it is needed and leave the restore to be
// overwritten. A world with no ideology grant (the main-thread path) answers false on
// both counts, which is what keeps that path untouched.
std::shared_ptr<const RuntimeIdeologyReadView> published_ideology(NativeSimulationHost *host) {
    return host && host->effect_adapter_owned() ? host->latest_ideology_read_view() : nullptr;
}

Dictionary read_ideology_country(const RuntimeIdeologyReadView &view, uint64_t handle,
        Dictionary RuntimeIdeologyReadView::CardView::*field) {
    const auto row = view.countries.find(handle);
    return row == view.countries.end() ? unavailable() : (row->second.*field).duplicate(true);
}

bool ideology_worker_owns_or_is_pending(NativeSimulationHost *host) {
    return host != nullptr &&
        host->domain_main_thread_suppressed(RuntimeDomainId::IDEOLOGY);
}

// ── the worker-side IMPORT of a restored save ────────────────────────────────
//
// `capture` / `restore` are main-thread facade calls (below). The worker owns its own
// state machine (`RuntimeIdeologyPodAuthority`) and never learns it was restored from,
// so its next publish replaces the restored rows with its own: measured `idea_rows
// [82,1,0,0] -> []`, the mirrored §9.3 dates `7/8 -> 2/3` (the worker's committed day,
// not the payload's), and a pump that then clears the front.
//
// WHY THIS CHANNEL AND NOT A NEW ONE. The POD already has a state-adoption entry point:
// the host's `restore_ideology_pod_save`, which the runtime save bundle uses and which
// configures a candidate authority from the LIVE catalog before restoring into it. It
// takes the POD's own save bytes, so nothing about the state format is reinvented: the
// restored mirror exports a `RuntimeIdeologyPodSnapshot`, that snapshot is serialized
// with the POD's own writer, and the host installs it. The command channel could not
// carry this: `RuntimeIdeologyPodCommand` is a few scalars, its opcode range is closed
// in the host, and a state import is not a command.
//
// `code` names the outcome either way. `economy_day_inflight` is the only retryable one:
// the worker was inside its semantic day, and the pending flag makes the write-back path
// try again instead of applying a worker snapshot over the restore.
bool import_ideology_pod_state(NativeIdeologyRuntime *runtime,
                               NativeSimulationHost *host, void *country_opaque,
                               ModifierRuntime *economy_modifier,
                               const ModifierRuntime *restored_modifier,
                               std::string &code, std::string &error) {
    code = "not_worker_authoritative";
    error.clear();
    if (runtime == nullptr || host == nullptr) return false;
    if (!ideology_worker_owns_or_is_pending(host)) return false;
    // Both callers hold the executor day boundary during import.
    auto *country = static_cast<NativeCountryRuntime *>(country_opaque);
    if (country == nullptr) {
        code = "ideology_worker_import_country_runtime_unavailable";
        return false;
    }
    RuntimeCountryPodSnapshot country_snapshot;
    if (!country->export_pod_snapshot(country_snapshot, error)) {
        code = "ideology_worker_import_country_snapshot_unavailable";
        return false;
    }
    RuntimeIdeologyPodSnapshot state;
    if (!runtime->export_pod_import_state(state, country_snapshot, error)) {
        code = error.empty() ? "ideology_worker_import_export_failed" : error;
        return false;
    }
    std::vector<uint8_t> bytes;
    RuntimeIdeologyPodAuthority::serialize_snapshot(state, bytes);
    if (bytes.empty()) {
        code = "ideology_worker_import_encode_failed";
        return false;
    }
    std::string restore_error;
    if (!host->restore_ideology_pod_save(bytes.data(), bytes.size(),
                                        restore_error)) {
        error = restore_error;
        code = restore_error.empty() ? "ideology_worker_import_refused"
                                     : restore_error;
        return false;
    }
    // The imported state's generation is ahead of everything this mirror has applied, so
    // any snapshot the ring still holds from BEFORE the import is refused as a generation
    // regression rather than overwriting the load.
    runtime->adopt_pod_snapshot_generation(state.generation);
    if (economy_modifier != nullptr && restored_modifier != nullptr)
        economy_modifier->copy_derived_cell_layer_from(*restored_modifier);
    code = "applied";
    return true;
}
} // namespace

Dictionary DCWorldExt::configure_ideologies(const Dictionary &catalog) {
    if (_ideology_runtime == nullptr) _ideology_runtime = new NativeIdeologyRuntime();
    // TEST-ONLY support-gate bypass, equivalent to `ideology_card_content_test`'s
    // `_support_gate_off`.
    //
    // The popularity gate is a weighted average over the REAL political classes
    // (`support_allows`, runtime_ideology_pod.cpp). A small fixture world staffs one
    // class, so the average is that class's stance and an UNEQUIP is refused with
    // `ideology_support_threshold_not_met` -- correct behaviour for a real game, and a
    // permanent blocker for a test whose subject is the transition machinery rather
    // than the politics. Clearing every stance row makes `stance_count == 0`, which is
    // the documented "no gate" shape (`support_allows` returns true immediately), and
    // it does so for the MAIN THREAD and the POD at once because both are compiled
    // from this same dictionary.
    //
    // Opt-in through the environment so production can never take it by accident:
    // without the variable the catalog passes through untouched.
    Dictionary effective = catalog;
    if (pk::runtime_switch_value(pk::RuntimeSwitch::PK_DISABLE_SUPPORT_GATE) != nullptr) {
        // Clear the stance rows so `support_allows` has nothing to average.
        //
        // `stance_count == 0` is the documented "no gate" shape and it is exactly what
        // the main-thread test's `_support_gate_off` does, so this mirrors an
        // established fixture device instead of inventing one.
        //
        // Tried and REVERTED: lowering the three threshold arrays instead. It reads
        // like the safer change (the stance table the opinion snapshot is built from
        // stays intact), but with relaxed thresholds every seven-card batch run went
        // VOID -- the process stopped at day 1 with no receipts and no summary -- while
        // this version measures 175 checks / 0 failures across the same seven cards.
        const PackedStringArray ids = effective.get(
            "ideology_ids", PackedStringArray());
        const int32_t count = ids.size();
        PackedInt32Array stance_offsets;
        stance_offsets.resize(count + 1);
        for (int32_t i = 0; i <= count; ++i) stance_offsets.set(i, 0);
        effective["stance_offsets"] = stance_offsets;
        effective["stance_class_indices"] = PackedInt32Array();
        effective["stance_adopt_q16"] = PackedInt32Array();
        effective["stance_repeal_q16"] = PackedInt32Array();
        effective["stance_promote_q16"] = PackedInt32Array();
        effective["stance_adopt_min_q16"] = PackedInt32Array();
        effective["stance_repeal_min_q16"] = PackedInt32Array();
        effective["stance_promote_min_q16"] = PackedInt32Array();
        PackedInt32Array thresholds;
        thresholds.resize(count);
        for (int32_t i = 0; i < count; ++i) thresholds.set(i, 0);
        effective["adopt_thresholds_q16"] = thresholds;
        effective["repeal_thresholds_q16"] = thresholds;
        effective["promote_thresholds_q16"] = thresholds;
    }
    ideology_runtime_from(_ideology_runtime)->attach_country_runtime(
        static_cast<NativeCountryRuntime *>(_country_runtime));
    ideology_runtime_from(_ideology_runtime)->attach_economy_runtime(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
    ideology_runtime_from(_ideology_runtime)->attach_effect_runtime(
        static_cast<EffectRuntime *>(_effect_runtime));
    // M2a: equipping a card is a declarative Effect instance write, so it has to
    // go through the same forwarder DCWorldExt uses. Without this the card lands
    // on the main-thread EffectRuntime while the worker owns EFFECT, and the
    // next worker snapshot erases it.
    ideology_runtime_from(_ideology_runtime)->attach_effect_forwarder(
        _effect_forwarder.get());
    ideology_runtime_from(_ideology_runtime)->attach_modifier_runtime(
        static_cast<ModifierRuntime *>(_modifier_runtime));
    Dictionary result = ideology_runtime_from(_ideology_runtime)->configure(effective);
    if (!bool(result.get("ok", false)) || _country_runtime == nullptr)
        return result;
    RuntimeCountryPodSnapshot country;
    RuntimeIdeologyPodCatalog pod_catalog;
    std::string error;
    if (!static_cast<NativeCountryRuntime *>(_country_runtime)->export_pod_snapshot(
            country, error) ||
        !ideology_runtime_from(_ideology_runtime)->export_pod_catalog(
            country, pod_catalog, error)) {
        result["worker_shadow_configured"] = false;
        result["worker_shadow_reason"] = String(error.c_str());
        return result;
    }
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    const bool configured = _runtime_host->configure_ideology_pod(
        pod_catalog, error);
    result["worker_shadow_configured"] = configured;
    result["worker_catalog_hash"] = static_cast<int64_t>(pod_catalog.catalog_hash);
    if (!configured) result["worker_shadow_reason"] = String(error.c_str());
    if (configured && _economy_runtime != nullptr) {
        RuntimeIdeologyOpinionSnapshot opinion = copy_opinion_snapshot(
            *static_cast<NativeEconomyRuntime *>(_economy_runtime));
        std::string opinion_error;
        result["worker_opinion_published"] =
            _runtime_host->publish_ideology_opinion_snapshot(
                opinion, opinion_error);
    }
    return result;
}

Dictionary DCWorldExt::submit_ideology_commands(const Dictionary &batch) {
    if (_ideology_runtime == nullptr) return unavailable();
    // G8: when the worker owns Ideology it is the sole writer. Staging the same
    // batch in the legacy queue first would let the main thread apply it a
    // second time, and the worker snapshot write-back would then overwrite the
    // result with a state that never saw the command twice.
    const bool worker_authoritative = _runtime_host != nullptr &&
        (_runtime_host->effect_adapter_owned() ||
         _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY));
    const PackedInt32Array opcodes = batch.get("opcodes", PackedInt32Array());
    const PackedInt32Array producers = batch.get("producer_ids", PackedInt32Array());
    const PackedInt32Array priorities = batch.get("source_priorities", PackedInt32Array());
    const PackedInt32Array ideology_ids = batch.get("ideology_ids", PackedInt32Array());
    const PackedInt32Array choices = batch.get("choice_indices", PackedInt32Array());
    const PackedInt32Array gates = batch.get("gate_ids", PackedInt32Array());
    const PackedInt64Array days = batch.get("effective_days", PackedInt64Array());
    const PackedInt64Array sequences = batch.get("sequences", PackedInt64Array());
    const PackedInt64Array handles = batch.get("country_handles", PackedInt64Array());
    const PackedInt64Array values = batch.get("values_q16", PackedInt64Array());
    const PackedInt64Array offers = batch.get("offer_generations", PackedInt64Array());
    Dictionary result;
    if (worker_authoritative) {
        // submit_commands() normally validates the column shapes before the
        // mirror loop below indexes them. Skipping it means this path owns the
        // same check.
        const int32_t count = opcodes.size();
        if (count <= 0 || (!producers.is_empty() && producers.size() != count) ||
            priorities.size() != count || days.size() != count ||
            sequences.size() != count || handles.size() != count ||
            ideology_ids.size() != count || values.size() != count ||
            offers.size() != count || choices.size() != count ||
            gates.size() != count) {
            result["ok"] = false;
            result["reason"] = "ideology_command_columns_invalid";
            return result;
        }
        result["ok"] = true;
        result["path"] = "IDEOLOGY_WORKER";
        result["accepted"] = count;
        result["duplicates"] = 0;
        result["pending"] = 0;
    } else {
        result = ideology_runtime_from(_ideology_runtime)->submit_commands(batch);
        if (!bool(result.get("ok", false)) || _runtime_host == nullptr)
            return result;
    }
    // Main-thread ingress to the worker's queue is sealed like every other lane.
    // The worker's own Trigger and Effect stages queue Ideology commands directly.
    int64_t earliest = days.is_empty() ? 0 : *std::min_element(days.ptr(), days.ptr() + days.size());
    auto admission = worker_authoritative ? _runtime_host->admit_command(earliest)
                                          : RuntimeCommandAdmission();
    if (worker_authoritative && !admission.accepted()) return unavailable();
    const int64_t seal_day = worker_authoritative ? _runtime_host->command_seal_day() : 0;
    std::vector<RuntimeIdeologyPodCommand> commands;
    commands.reserve(opcodes.size());
    PackedInt64Array admitted_days;
    for (int32_t index = 0; index < opcodes.size(); ++index) {
        auto &command = commands.emplace_back();
        command.producer_id = producers.is_empty() ? 1u :
            static_cast<uint32_t>(std::max(0, producers[index]));
        command.sequence = static_cast<uint64_t>(std::max<int64_t>(0, sequences[index]));
        command.source_priority = priorities[index];
        command.opcode = static_cast<RuntimeIdeologyPodOpcode>(opcodes[index]);
        command.country_handle = static_cast<uint64_t>(handles[index]);
        command.request_id = worker_request_id(command.producer_id,
            command.sequence, static_cast<uint16_t>(command.opcode),
            command.country_handle);
        command.requested_day = days[index];
        command.effective_day = std::max(days[index], seal_day);
        command.ideology_id = ideology_ids[index];
        command.value_q16 = values[index];
        command.offer_generation = static_cast<uint32_t>(
            std::max<int64_t>(0, offers[index]));
        command.choice_index = choices[index];
        command.gate_id = gates[index];
        admitted_days.push_back(command.effective_day);
    }
    std::string error;
    const bool mirrored = _runtime_host->queue_ideology_pod_commands(commands, error);
    result["worker_shadow_mirrored"] = mirrored;
    if (!mirrored) result["worker_shadow_reason"] = String(error.c_str());
    if (worker_authoritative) {
        result["ok"] = mirrored;
        if (mirrored) {
            result["effective_days"] = admitted_days;
            _runtime_host->wake_for_ideology_response(commands);
        } else result["reason"] = String(error.c_str());
    }
    return result;
}

Dictionary DCWorldExt::publish_ideology_worker_inputs() {
    Dictionary out;
    if (_runtime_host == nullptr || _economy_runtime == nullptr ||
        _runtime_host->effect_adapter_owned()) {
        out["ok"] = false;
        out["code"] = "ideology_worker_inputs_unavailable";
        return out;
    }
    // Stage B: hand the pod the economy's cell tag bitmap (transient, never saved).
    if (const auto tags = static_cast<NativeEconomyRuntime *>(_economy_runtime)
            ->published_tag_snapshot())
        _runtime_host->set_ideology_cell_tags(tags->tag_words, tags->tag_bits);
    RuntimeIdeologyOpinionSnapshot snapshot = copy_opinion_snapshot(
        *static_cast<NativeEconomyRuntime *>(_economy_runtime));
    // Do NOT accrue here.
    //
    // An earlier revision called `settle_points_for_opinion()` at this point to
    // make the main thread level with the revision being published. That was a
    // test-shaped fix leaking into production: this function runs on every graph
    // pulse (native daily, runtime graph, country peer bridge), so it moved point
    // settlement timing and its ledger `day` off the daily cadence that
    // `run_ideology_daily` establishes. Accrual belongs to the Ideology day, not
    // to an input publish.
    //
    // It did not fix the real divergence either: the worker and the main thread
    // settle a different NUMBER of times, and `ledger.trade_q16` pays on every
    // settlement, so the totals genuinely differ. See the report note below.
    NativeIdeologyRuntime *self = _ideology_runtime == nullptr ? nullptr
        : ideology_runtime_from(_ideology_runtime);
    const bool settled_now = false;
    std::string error;
    const bool ok = _runtime_host->publish_ideology_opinion_snapshot(
        snapshot, error);
    if (ok) _ideology_opinion_published_revision = snapshot.revision;
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.c_str());
    out["revision"] = static_cast<int64_t>(snapshot.revision);
    out["committed_day"] = snapshot.committed_day;
    // Parity needs to know whether the worker was handed the SAME opinion
    // revision the main thread last settled against. A mismatch here means the
    // two sides are accruing from different inputs, which is a driver problem,
    // not a business divergence.
    out["main_points_revision"] = _ideology_runtime == nullptr ? -1
        : static_cast<int64_t>(ideology_runtime_from(_ideology_runtime)
            ->points_revision_seen());
    out["settled_now"] = settled_now;
    out["accrue_result"] = self == nullptr ? -1
        : static_cast<int32_t>(self->points_accrual_result());
    return out;
}

Dictionary DCWorldExt::poll_ideology_worker_intent() {
    Dictionary out;
    if (_runtime_host == nullptr) { out["ok"] = false; out["code"] = "runtime_host_unavailable"; return out; }
    RuntimeDomainIntent intent;
    if (!_runtime_host->poll_ideology_pod_intent(intent)) {
        out["ok"] = true; out["available"] = false; return out;
    }
    out["ok"] = true; out["available"] = true;
    out["request_id"] = static_cast<int64_t>(intent.request_id);
    out["transaction_id"] = static_cast<int64_t>(intent.source_id);
    out["target_handle"] = static_cast<int64_t>(intent.target_handle);
    out["target_generation"] = static_cast<int64_t>(intent.target_generation);
    out["effective_day"] = intent.effective_day;
    out["flags"] = static_cast<int64_t>(intent.flags);
    PackedInt64Array payload;
    for (int64_t value : intent.payload) payload.append(value);
    out["payload"] = payload;
    return out;
}

Dictionary DCWorldExt::submit_ideology_worker_ack(const Dictionary &source) {
    Dictionary out;
    if (_runtime_host == nullptr) { out["ok"] = false; out["code"] = "runtime_host_unavailable"; return out; }
    RuntimeDomainAck ack;
    ack.request_id = static_cast<uint64_t>(static_cast<int64_t>(source.get("request_id", 0)));
    ack.transaction_id = static_cast<uint64_t>(static_cast<int64_t>(source.get("transaction_id", 0)));
    ack.target_handle = static_cast<uint64_t>(static_cast<int64_t>(source.get("target_handle", 0)));
    ack.target_generation = static_cast<uint32_t>(static_cast<int64_t>(source.get("target_generation", 0)));
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
    ack.code = static_cast<RuntimeDomainAckCode>(static_cast<int32_t>(source.get("code", 0)));
    ack.effective_day = static_cast<int64_t>(source.get("effective_day", 0));
    std::string error;
    const bool ok = _runtime_host->submit_ideology_pod_ack(ack, error);
    out["ok"] = ok; out["code"] = ok ? "ok" : String(error.c_str());
    return out;
}

Dictionary DCWorldExt::poll_ideology_receipts(int64_t after_receipt_id,
        int32_t limit) const {
    if (const auto view = published_ideology(_runtime_host.get()))
        return view->filter_receipts(after_receipt_id, limit);
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->poll_receipts(
            after_receipt_id, limit);
}


Dictionary DCWorldExt::run_ideology_daily(int64_t day_index) {
    if (_ideology_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr &&
        _runtime_host->domain_main_thread_suppressed(RuntimeDomainId::IDEOLOGY)) {
        Dictionary out;
        out["ok"] = true;
        out["suppressed"] = true;
        out["path"] = "IDEOLOGY_WORKER";
        out["day"] = day_index;
        return out;
    }
    // Pin the reference's actual daily input for SHADOW comparison. Worker
    // catch-up can happen after Economy has published several newer commits;
    // the explicit simulation day joins the inputs without deriving a date
    // from Economy's period or committed_day.
    std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> reference_opinion;
    if (_runtime_host != nullptr && _economy_runtime != nullptr &&
        _runtime_host->ideology_parity_enabled() &&
        _runtime_host->control_state().mode == RuntimeSimulationMode::SHADOW) {
        reference_opinion = _runtime_host->pin_ideology_reference_opinion(
            day_index, copy_opinion_snapshot(
                *static_cast<NativeEconomyRuntime *>(_economy_runtime)));
    }
    if (_runtime_host && _runtime_host->annual_development_enabled()) {
        AnnualDevelopmentReport pending;
        std::string error;
        if (_runtime_host->annual_pending_reward(pending) &&
            ideology_runtime_from(_ideology_runtime)->grant_annual_points(
                pending.country_handle, pending.reward_q16,
                pending.reward_sequence, day_index, error))
            _runtime_host->settle_annual_reward(pending.reward_sequence);
    }
    Dictionary result = ideology_runtime_from(_ideology_runtime)->run_daily(
        day_index, reference_opinion.get());
    // Parity reference: hash the main thread's own state for this day with the
    // SAME function the worker uses. Only meaningful in a live comparison run --
    // with no worker nothing ever compares against it, which the report shows as
    // `ideology_parity_compared_count == 0`.
    //
    // Publish only when the day is actually FINISHED **and settled**.
    //
    // `run_daily` is sliced: a call can return `done=false` with the day still in
    // progress. Publishing then stores a partial state under this day's key while
    // the worker, having committed the whole day, compares against a snapshot
    // that is already stale.
    //
    // `done` alone is not enough either. On the first days the main thread's
    // Economy has not published an opinion revision yet, so `accrue_points`
    // settles nothing and the runtime has no country rows while the worker (whose
    // Economy runs on the worker clock) already has them. That day cannot be
    // compared honestly, so it is not published.
    //
    // Note the predicate is "has EVER settled", not "settled on this call": a day
    // with no new opinion revision legitimately reports `already seen`, and
    // refusing to publish then would starve the comparison for every quiet day.
    const bool settled = ideology_runtime_from(_ideology_runtime)
        ->points_accrual_ever_settled();
    // The reference is published under the same explicit daily input key.
    const bool day_finished = bool(result.get("done", true)) && settled &&
        ideology_runtime_from(_ideology_runtime)->last_day() == day_index;
    // Short-circuit BEFORE the export, not inside the publisher: building a
    // full snapshot is the cost, and a production session must not pay it to
    // have `publish_ideology_reference` immediately refuse (03 idle-zero-cost).
    const bool parity_on = _runtime_host != nullptr &&
        _runtime_host->ideology_parity_enabled();
    if (parity_on && bool(result.get("ok", false)) && day_finished) {
        RuntimeIdeologyPodSnapshot reference;
        if (ideology_runtime_from(_ideology_runtime)
                ->export_pod_business_snapshot(reference)) {
            // A refused reference is a fact about the main thread, not a silent
            // no-op: say so in the daily result so a parity run can tell
            // "nothing to compare" apart from "compared and disagreed".
            result["parity_reference_published"] =
                _runtime_host->publish_ideology_reference(day_index, reference);
            result["parity_reference_countries"] =
                static_cast<int64_t>(reference.countries.size());
        } else {
            result["parity_reference_export_ok"] = false;
        }
    } else if (parity_on && bool(result.get("ok", false))) {
        result["parity_reference_published"] = false;
        result["parity_reference_deferred"] = true;
    }
    return result;
}


Dictionary DCWorldExt::get_city_output_factor_q16(int32_t cell, int32_t good_id) const {
    if (_economy_runtime == nullptr) return unavailable();
    Dictionary out;
    out["ok"] = true;
    out["factor_q16"] = static_cast<NativeEconomyRuntime *>(_economy_runtime)
        ->city_output_factor_for_test(cell, good_id);
    return out;
}

bool DCWorldExt::ideology_should_run(int64_t day_index) const {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY)) {
        return false;
    }
    return _ideology_runtime != nullptr &&
        ideology_runtime_from(_ideology_runtime)->should_run(day_index);
}

bool DCWorldExt::ideology_needs_daily_continuation(int64_t day_index) const {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY))
        return false;
    return _ideology_runtime != nullptr &&
        ideology_runtime_from(_ideology_runtime)->needs_daily_continuation(day_index);
}

Dictionary DCWorldExt::step_ideology_instance_refresh(int64_t day_index) {
    if (_ideology_runtime == nullptr || (_runtime_host && _runtime_host->effect_adapter_owned()))
        return unavailable();
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) return unavailable();
    }
    const bool pending = ideology_runtime_from(_ideology_runtime)->step_effect_instance_refresh(day_index);
    Dictionary out;
    out["ok"] = true;
    out["done"] = !pending;
    out["pending"] = pending;
    out["day"] = day_index;
    return out;
}

Dictionary DCWorldExt::step_ideology_derived_rebuild(int64_t day_index) {
    if (_ideology_runtime == nullptr || (_runtime_host && _runtime_host->effect_adapter_owned()))
        return unavailable();
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host) {
        boundary = _runtime_host->try_lock_economy_input_capture();
        if (!boundary.owns_lock()) return unavailable();
    }
    NativeIdeologyRuntime &runtime = *ideology_runtime_from(_ideology_runtime);
    std::string error;
    int32_t steps = 0;
    bool ok = false;
    do {
        ok = runtime.step_derived_rebuild(day_index, error);
        ++steps;
    } while (!ok && error.empty() && runtime.derived_rebuild_pending() && steps < 4096);
    const bool pending = runtime.derived_rebuild_pending();
    Dictionary out;
    out["ok"] = ok && error.empty();
    out["done"] = ok && !pending;
    out["pending"] = pending;
    out["day"] = day_index;
    out["steps"] = steps;
    if (!error.empty()) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::apply_runtime_ideology_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["applied"] = false;
    if (_ideology_runtime == nullptr || _runtime_host == nullptr) {
        out["code"] = "ideology_runtime_unavailable";
        return out;
    }
    if (_runtime_host->effect_adapter_owned() || !_runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::IDEOLOGY)) {
        out["code"] = "ideology_not_worker_authoritative";
        return out;
    }
    auto boundary_lock = _runtime_host->try_lock_economy_input_capture();
    if (!boundary_lock.owns_lock()) {
        out["ok"] = true;
        out["code"] = "economy_day_inflight";
        return out;
    }
    NativeIdeologyRuntime *self = ideology_runtime_from(_ideology_runtime);
    // The worker Ideology stage cannot run before it has an opinion snapshot.
    // The runtime graph pulse publishes one too, but it may be disabled or out
    // of budget; this per-tick write-back path is the guaranteed hand-off.
    if (_economy_runtime != nullptr &&
        static_cast<NativeEconomyRuntime *>(_economy_runtime)
                ->country_class_opinion_snapshot().revision !=
            _ideology_opinion_published_revision) {
        publish_ideology_worker_inputs();
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_ideology_snapshot(cursor, slot)) {
        out["ok"] = true;
        out["code"] = "ideology_snapshot_unavailable";
        return out;
    }
    // Copy out of the ring before apply so release cannot race a concurrent
    // publish that reclaims the READY slot under the rebuild.
    const RuntimeIdeologyPodSnapshot snapshot =
        _runtime_host->ideology_snapshot_buffer(slot);
    const int64_t generation = static_cast<int64_t>(snapshot.generation);
    const std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> opinion =
        _runtime_host->worker_opinion_snapshot_for_ideology_generation(
            snapshot.generation);
    if (opinion != nullptr) {
        ideology_runtime_from(_ideology_runtime)
            ->set_worker_opinion_inputs(*opinion);
    }
    _runtime_host->release_ideology_snapshot(slot);
    std::string apply_error;
    const bool applied = ideology_runtime_from(_ideology_runtime)
        ->apply_pod_snapshot(snapshot, apply_error);
    // A snapshot older than the generation an IMPORT adopted is not a failure: it was
    // published before the load and the imported state supersedes it. Reporting that as
    // "generation regression" would make a durable load look like a rejected write.
    const bool superseded = !applied &&
        apply_error == "ideology_pod_snapshot_generation_regression" &&
        self->worker_import_last_code() == "applied";
    out["ok"] = applied || superseded;
    out["applied"] = applied;
    out["superseded"] = superseded;
    out["generation"] = generation;
    out["code"] = applied ? "ok"
        : (superseded ? "ideology_pod_snapshot_superseded"
                      : String(apply_error.c_str()));
    return out;
}

#include "world_ext_ideology_section_reports.inc"


Dictionary DCWorldExt::resolve_effect_program_modifier_commands(
        const String &program_key) const {
    if (_effect_runtime == nullptr) return unavailable();
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    const bool found =
        static_cast<const EffectRuntime *>(_effect_runtime)->program_modifier_commands(
            std::string(program_key.utf8().get_data()), commands);
    Dictionary out;
    out["ok"] = found;
    Array rows;
    for (const EffectRuntime::ProgramModifierCommand &command : commands) {
        Dictionary row;
        row["definition_key"] = String(command.definition_key.c_str());
        row["value_q16"] = command.value_q16;
        row["stacks"] = command.stacks;
        row["duration_days"] = command.duration_days;
        rows.push_back(row);
    }
    out["commands"] = rows;
    return out;
}

Dictionary DCWorldExt::reconcile_ideology_effects_for_test(int64_t country_handle) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->reconcile_effects_for_test(country_handle);
}

Dictionary DCWorldExt::apply_ideology_self_snapshot_for_test(int64_t generation) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->apply_self_pod_snapshot_for_test(generation);
}

PackedInt32Array DCWorldExt::query_effect_target_cells(
        int32_t source_cell, int32_t selector_kind, int32_t param0,
        int32_t param1) const {
    PackedInt32Array out;
    if (_economy_runtime == nullptr) return out;
    std::vector<int32_t> cells;
    static_cast<const NativeEconomyRuntime *>(_economy_runtime)
        ->collect_effect_target_cells(source_cell, selector_kind, param0, param1,
            cells);
    out.resize(static_cast<int64_t>(cells.size()));
    for (size_t i = 0; i < cells.size(); ++i)
        out[static_cast<int64_t>(i)] = cells[i];
    return out;
}

int32_t DCWorldExt::query_country_anchor_cell(int32_t country_slot) const {
    if (_economy_runtime == nullptr) return -1;
    return static_cast<const NativeEconomyRuntime *>(_economy_runtime)
        ->country_anchor_cell(country_slot);
}

bool DCWorldExt::effect_program_is_managed(const String &program_key) const {
    if (_effect_runtime == nullptr) return false;
    EffectRuntime::FamilyEffectMetadataPod metadata;
    return static_cast<const EffectRuntime *>(_effect_runtime)
        ->family_effect_metadata_pod(
            std::string(program_key.utf8().get_data()), metadata);
}

Dictionary DCWorldExt::preview_ideology_offer_eligibility(int64_t country_handle) const {
    if (const auto view = published_ideology(_runtime_host.get()))
        return read_ideology_country(*view, static_cast<uint64_t>(country_handle),
            &RuntimeIdeologyReadView::CardView::eligibility);
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->preview_offer_eligibility(country_handle);
}

#include "world_ext_ideology_section_reports_diagnostics.inc"

PackedByteArray DCWorldExt::capture_ideology_state() const {
    if (const auto view = published_ideology(_runtime_host.get())) return view->save;
    return _ideology_runtime == nullptr ? PackedByteArray()
        : ideology_runtime_from(_ideology_runtime)->capture();
}

Dictionary DCWorldExt::restore_ideology_state(const PackedByteArray &bytes) {
    if (_ideology_runtime == nullptr) return unavailable();
    auto *self = ideology_runtime_from(_ideology_runtime);
    const bool worker_owned = ideology_worker_owns_or_is_pending(_runtime_host.get());
    if (!worker_owned) return self->restore(bytes);
    auto boundary = _runtime_host->try_lock_economy_input_capture();
    if (!boundary.owns_lock()) {
        Dictionary out = unavailable();
        out["reason"] = "economy_day_inflight";
        return out;
    }
    Dictionary out = self->restore(bytes);
    if (!bool(out.get("ok", false))) return out;
    const bool executor_projection = _runtime_host->effect_adapter_owned();
    std::string import_code;
    std::string import_error;
    const bool imported = import_ideology_pod_state(self, _runtime_host.get(),
        _country_runtime, !executor_projection && _economy_modifier_view_attached
            ? static_cast<ModifierRuntime *>(_economy_modifier_view) : nullptr,
        static_cast<const ModifierRuntime *>(_modifier_runtime), import_code, import_error);
    self->record_worker_import(import_code, imported, false);
    if (imported && executor_projection) _runtime_host->publish_restored_ideology_view();
    out["worker_import"] = String(import_code.c_str());
    out["worker_imported"] = imported;
    if (!import_error.empty())
        out["worker_import_detail"] = String(import_error.c_str());
    return out;
}

Dictionary DCWorldExt::clear_ideology_state() {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->clear_state();
}

} // namespace pk
