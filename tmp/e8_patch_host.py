# -*- coding: utf-8 -*-
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CPP = ROOT / "gdext/src/native_simulation_host.cpp"
HDR = ROOT / "gdext/src/native_simulation_host.h"

STAGE_FN = r'''
bool NativeSimulationHost::execute_modifier_worker_stage(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeCommandPacket> &day_commands,
        bool effect_upstream_ok,
        RuntimeDomainAuthorityPlan *authority_plan,
        std::string &authority_error,
        std::string &error) {
    error.clear();
    std::vector<RuntimeModifierPodCommand> modifier_commands;
    modifier_commands.reserve(day_commands.size());
    for (const RuntimeCommandPacket &packet : day_commands) {
        RuntimeModifierPodCommand command;
        if (decode_modifier_packet(packet, command))
            modifier_commands.push_back(command);
    }

    // Effect POD upstream (F7/E8): when Effect stage succeeded with a non-empty
    // catalog, Modifier consumes those intents. SHADOW fixture intents are
    // stripped by the caller when upstream is active. ACTIVE with an empty
    // Effect catalog uses empty intents (no fixture).
    const std::vector<RuntimeDomainIntent> empty_intents;
    const std::vector<RuntimeDomainIntent> &intent_source =
        effect_upstream_ok ? _effect_day_modifier_intents
                           : (authority_plan != nullptr ? authority_plan->intents
                                                       : empty_intents);
    std::vector<RuntimeModifierPodCommand> modifier_intents;
    modifier_intents.reserve(intent_source.size());
    for (const RuntimeDomainIntent &intent : intent_source) {
        if (intent.target_domain !=
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
            continue;
        }
        RuntimeModifierPodCommand command;
        command.request_id =
            intent.request_id != 0 ? intent.request_id : intent.source_id;
        command.producer_id = intent.producer_id;
        command.sequence = intent.sequence;
        command.effective_day = intent.effective_day;
        command.requested_day = intent.effective_day;
        command.opcode = intent.opcode;
        command.domain = intent.payload[1] >= 0 && intent.payload[1] < 4
            ? static_cast<uint16_t>(intent.payload[1]) : 0;
        command.definition_id = intent.payload[0] >= 0
            ? static_cast<int32_t>(intent.payload[0]) : 0;
        command.scope = intent.payload[2] >= 0 && intent.payload[2] <= 2
            ? static_cast<int32_t>(intent.payload[2]) : 2;
        command.entity_handle = intent.target_handle;
        command.target_generation = intent.target_generation;
        command.group_handle = intent.group_handle;
        command.modifier_handle = intent.modifier_handle;
        command.duration_days = intent.duration_days;
        command.stacks = intent.stacks;
        command.magnitude_q16 = intent.magnitude_q16;
        command.source_type = static_cast<uint64_t>(RuntimeDomainId::EFFECT);
        command.source_id = intent.source_id;
        command.input_generation = input_generation;
        modifier_intents.push_back(command);
    }

    auto publish_fallback = [this](const char *reason) {
        size_t i = 0;
        for (; i + 1 < _modifier_pod_fallback_reason.size() &&
                reason != nullptr && reason[i] != '\0'; ++i) {
            _modifier_pod_fallback_reason[i].store(
                reason[i], std::memory_order_release);
        }
        for (; i < _modifier_pod_fallback_reason.size(); ++i) {
            _modifier_pod_fallback_reason[i].store(
                '\0', std::memory_order_release);
        }
    };

    // SHADOW may run the diagnostic domain runner without a Modifier POD
    // catalog. ACTIVE always requires the POD when this stage is invoked.
    if (!_modifier_pod_configured) {
        if (!modifier_commands.empty() || !modifier_intents.empty()) {
            error = "modifier_pod_not_configured";
            publish_fallback(error.c_str());
            _modifier_pod_ready.store(false, std::memory_order_release);
            if (authority_plan != nullptr) {
                _domain_authority_runner.discard_plan();
                if (authority_error.empty()) authority_error = error;
            }
            return false;
        }
        _modifier_pod_ready.store(false, std::memory_order_release);
        publish_fallback("modifier_pod_not_configured");
        if (authority_plan != nullptr) {
            return _domain_authority_runner.commit_day(
                *authority_plan, authority_error);
        }
        error = "modifier_pod_not_configured";
        return false;
    }

    bool modifier_ok = true;
    std::string modifier_error;
    RuntimeModifierPodSnapshot modifier_snapshot;
    RuntimeModifierPodReport modifier_report;
    std::vector<RuntimeDomainAck> modifier_acks;
    double modifier_plan_ms = 0.0;
    const auto plan_started = std::chrono::steady_clock::now();
    modifier_ok = _modifier_pod_authority.plan_day(
        day, input_generation, modifier_commands, modifier_intents,
        modifier_snapshot, modifier_acks, modifier_report, modifier_error);
    modifier_plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_started).count();
    if (!modifier_ok) {
        _modifier_pod_authority.discard_plan();
    }

    bool authority_ok = true;
    if (modifier_ok) {
        if (effect_upstream_ok) {
            if (!modifier_acks.empty() &&
                !_effect_pod_authority.apply_acks(
                    modifier_acks, modifier_error)) {
                modifier_ok = false;
            } else {
                _effect_pod_ack_count.store(
                    static_cast<uint32_t>(modifier_acks.size()),
                    std::memory_order_release);
                _effect_pod_state_hash.store(
                    _effect_pod_authority.snapshot().deterministic_state_hash,
                    std::memory_order_release);
            }
        } else if (authority_plan != nullptr) {
            modifier_ok = _domain_authority_runner.accept_modifier_acks(
                *authority_plan, modifier_acks, modifier_error);
        }
    }

    uint32_t modifier_slot = 0;
    bool modifier_slot_reserved = false;
    if (modifier_ok) {
        if (!_modifier_snapshots.try_begin_write(modifier_slot)) {
            modifier_ok = false;
            modifier_error = "modifier_snapshot_ring_full";
        } else {
            _modifier_snapshots.write_buffer(modifier_slot) = modifier_snapshot;
            modifier_slot_reserved = true;
        }
    }

    const auto replay_started = std::chrono::steady_clock::now();
    if (modifier_ok) {
        modifier_ok = _modifier_pod_authority.commit_day(
            modifier_snapshot, modifier_error);
        if (modifier_ok && authority_plan != nullptr) {
            authority_ok = _domain_authority_runner.commit_day(
                *authority_plan, authority_error);
        }
        if (modifier_ok && authority_ok && modifier_slot_reserved) {
            _modifier_snapshots.publish(modifier_slot);
            modifier_slot_reserved = false;
            _modifier_pod_snapshot_generation.store(
                modifier_snapshot.generation, std::memory_order_release);
        }
    } else {
        authority_ok = false;
        _modifier_pod_authority.discard_plan();
        if (authority_plan != nullptr) {
            _domain_authority_runner.discard_plan();
            if (authority_error.empty()) authority_error = modifier_error;
        }
    }
    if ((!modifier_ok || !authority_ok) && modifier_slot_reserved)
        _modifier_snapshots.release(modifier_slot);
    const double modifier_replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - replay_started).count();

    const bool modifier_committed = modifier_ok && authority_ok;
    _modifier_pod_ready.store(modifier_committed, std::memory_order_release);
    _modifier_pod_plan_ms.store(modifier_plan_ms, std::memory_order_release);
    _modifier_pod_replay_ms.store(modifier_replay_ms, std::memory_order_release);
    _modifier_pod_work_units.store(modifier_report.work_units,
                                   std::memory_order_release);
    _modifier_pod_state_hash.store(
        modifier_committed ? modifier_snapshot.state_hash
                           : _modifier_pod_authority.snapshot().state_hash,
        std::memory_order_release);
    _modifier_pod_ack_count.store(
        modifier_committed ? static_cast<uint32_t>(modifier_acks.size()) : 0u,
        std::memory_order_release);
    const char *reason = modifier_committed ? "" :
        (modifier_error.empty() ? "modifier_pod_plan_failed"
                                : modifier_error.c_str());
    publish_fallback(reason);
    if (!modifier_committed) {
        error = reason;
        return false;
    }
    return true;
}

'''

SHADOW_REPLACEMENT = '''                // F7/E8: Effect POD upstream when catalog is non-empty and the
                // Effect stage succeeded. Strip fixture MODIFIER intents so the
                // domain-runner ACK barrier does not wait on a second Effect
                // writer. Empty cold-start catalogs keep fixture upstream for
                // Modifier E7.
                const bool use_effect_pod_upstream =
                    effect_stage_enabled && _effect_day_stage_ok;
                if (use_effect_pod_upstream) {
                    std::vector<RuntimeDomainIntent> retained_intents;
                    retained_intents.reserve(authority_plan.intents.size());
                    for (const RuntimeDomainIntent &intent : authority_plan.intents) {
                        if (intent.target_domain ==
                            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                            continue;
                        }
                        retained_intents.push_back(intent);
                    }
                    authority_plan.intents.swap(retained_intents);
                    authority_plan.ack_required_mask &=
                        ~runtime_domain_mask(RuntimeDomainId::MODIFIER);
                }
                std::string modifier_error;
                const auto modifier_started = std::chrono::steady_clock::now();
                const bool modifier_ok = execute_modifier_worker_stage(
                    plan.context.day, diagnostic_context.input_generation,
                    day_commands, use_effect_pod_upstream, &authority_plan,
                    authority_error, modifier_error);
                authority_ok = modifier_ok;
                authority_replay_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - modifier_started).count();
                if (!modifier_ok && authority_error.empty())
                    authority_error = modifier_error;
'''

ACTIVE_INSERT = '''        if (stage.domain == RuntimeDomainId::MODIFIER &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u) {
            // Park with Climate the same way Country does: when the worker
            // clock outruns the published environment, do not advance Modifier.
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                continue;
            }
            // Effect upstream for ACTIVE Modifier. F8 is not granted; this only
            // feeds Modifier intents when an Effect POD catalog is configured.
            // Empty catalogs keep empty intents (no SHADOW fixture).
            const bool effect_stage_enabled =
                _effect_pod_configured &&
                !_effect_pod_catalog.definitions.empty();
            bool effect_upstream_ok = false;
            if (effect_stage_enabled) {
                std::string effect_error;
                effect_upstream_ok = execute_effect_worker_stage(
                    plan.context.day, plan.context.input_generation,
                    commit, effect_error);
                _effect_pod_ready.store(effect_upstream_ok,
                                         std::memory_order_release);
                const char *effect_reason = effect_upstream_ok ? "" :
                    (effect_error.empty() ? "effect_pod_plan_failed"
                                          : effect_error.c_str());
                size_t effect_reason_index = 0;
                for (; effect_reason_index + 1 <
                           _effect_pod_fallback_reason.size() &&
                       effect_reason[effect_reason_index] != '\\0';
                     ++effect_reason_index) {
                    _effect_pod_fallback_reason[effect_reason_index].store(
                        effect_reason[effect_reason_index],
                        std::memory_order_release);
                }
                for (; effect_reason_index <
                           _effect_pod_fallback_reason.size();
                     ++effect_reason_index) {
                    _effect_pod_fallback_reason[effect_reason_index].store(
                        '\\0', std::memory_order_release);
                }
            } else {
                _effect_day_modifier_intents.clear();
                _effect_day_stage_ok = false;
            }
            std::string modifier_error;
            std::string unused_authority_error;
            // ACTIVE: no diagnostic domain runner. Failure isolates Modifier —
            // Climate/Country already committed stay.
            if (execute_modifier_worker_stage(
                    plan.context.day, plan.context.input_generation,
                    day_commands, effect_upstream_ok, nullptr,
                    unused_authority_error, modifier_error)) {
                stage.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
                stage.work_units = _modifier_pod_work_units.load(
                    std::memory_order_relaxed);
                stage.completed = 1;
                commit.dirty_families |= stage.dirty_families;
                commit.work_units += stage.work_units;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::MODIFIER);
                ++commit.completed_stage_count;
            } else {
                stage.completed = 0;
            }
            continue;
        }
'''


def patch_header():
    text = HDR.read_text(encoding="utf-8")
    needle = (
        "    bool execute_effect_worker_stage(int64_t day, uint64_t input_generation,\n"
        "                                     RuntimeDayCommit &commit,\n"
        "                                     std::string &error);"
    )
    if "execute_modifier_worker_stage" not in text:
        if needle not in text:
            raise SystemExit("header effect needle missing")
        text = text.replace(
            needle,
            needle
            + "\n"
            + "    // E8: shared Modifier POD stage for SHADOW diagnostics and ACTIVE\n"
            + "    // production. authority_plan is non-null only on SHADOW (fixture ACK /\n"
            + "    // domain-runner commit). ACTIVE passes nullptr. Failure isolates\n"
            + "    // Modifier — callers must not roll back Climate/Country already\n"
            + "    // committed the same day.\n"
            + "    bool execute_modifier_worker_stage(\n"
            + "            int64_t day, uint64_t input_generation,\n"
            + "            const std::vector<RuntimeCommandPacket> &day_commands,\n"
            + "            bool effect_upstream_ok,\n"
            + "            RuntimeDomainAuthorityPlan *authority_plan,\n"
            + "            std::string &authority_error,\n"
            + "            std::string &error);",
            1,
        )

    old = (
        "        // Climate + Country ship ACTIVE-authoritative in production as of\n"
        "        // 2026-09-11 (world_runtime_host.gd requests 0x806 when\n"
        "        // runtime_climate_authority_enabled). Other gameplay domains stay off.\n"
        "        return runtime_domain_mask(RuntimeDomainId::COMMIT)\n"
        "            | runtime_domain_mask(RuntimeDomainId::CLIMATE)\n"
        "            | runtime_domain_mask(RuntimeDomainId::COUNTRY);"
    )
    new = (
        "        // Climate + Country + Modifier ship ACTIVE-authoritative in production\n"
        "        // as of E8 (world_runtime_host.gd requests 0x846 when\n"
        "        // runtime_climate_authority_enabled). Effect remains SHADOW (F8 later).\n"
        "        // Contract: authoritative & MODIFIER => worker is the sole Modifier\n"
        "        // writer; snapshot write-back targets legacy ModifierRuntime (not\n"
        "        // MapData arrays); only modifier_daily is suppressed.\n"
        "        return runtime_domain_mask(RuntimeDomainId::COMMIT)\n"
        "            | runtime_domain_mask(RuntimeDomainId::CLIMATE)\n"
        "            | runtime_domain_mask(RuntimeDomainId::COUNTRY)\n"
        "            | runtime_domain_mask(RuntimeDomainId::MODIFIER);"
    )
    if old not in text:
        if "runtime_domain_mask(RuntimeDomainId::MODIFIER);" in text:
            print("mask already updated")
        else:
            raise SystemExit("mask block missing")
    else:
        text = text.replace(old, new, 1)
    HDR.write_text(text, encoding="utf-8")
    print("header ok")


def patch_cpp():
    text = CPP.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    if "bool NativeSimulationHost::execute_modifier_worker_stage(" not in text:
        for i, line in enumerate(lines):
            if line.startswith("bool NativeSimulationHost::execute_effect_worker_stage("):
                lines[i:i] = [STAGE_FN if STAGE_FN.endswith("\n") else STAGE_FN + "\n"]
                print("stage fn inserted at", i + 1)
                break
        else:
            raise SystemExit("effect stage insert point missing")
        text = "".join(lines)
        lines = text.splitlines(keepends=True)

    # Replace SHADOW inline block by markers
    start = None
    end = None
    for i, line in enumerate(lines):
        if "std::vector<RuntimeModifierPodCommand> modifier_commands;" in line and start is None:
            # ensure this is the SHADOW authority_ok block
            if i > 0 and "if (authority_ok)" in lines[i - 1]:
                start = i
        if start is not None and end is None:
            if "_modifier_pod_fallback_reason[modifier_reason_index].store(" in line and "'\\0'" in line.replace(" ", ""):
                # find closing brace of for-loop then the block ends after the second for
                pass
    # more precise: find start and the line with only "                }" before "} else {" discard_plan
    start = None
    for i, line in enumerate(lines):
        if line.strip() != "std::vector<RuntimeModifierPodCommand> modifier_commands;":
            continue
        # Prefer the SHADOW day-plan block (inside authority_ok), not the
        # extracted stage helper which also declares this vector.
        prev = "".join(lines[max(0, i - 5) : i])
        if "if (authority_ok)" in prev:
            start = i
            break
    if start is None:
        if "&authority_plan," in text and "execute_modifier_worker_stage(" in text:
            print("shadow already replaced")
        else:
            raise SystemExit("shadow start missing")
    else:
        # end at the second fallback store loop's closing brace, inclusive
        end = None
        for i in range(start, min(start + 220, len(lines))):
            if (lines[i].rstrip() == "                }"
                    and i + 1 < len(lines)
                    and lines[i + 1].rstrip() == "            } else {"):
                window = "".join(lines[i - 15 : i + 1])
                if "_modifier_pod_fallback_reason" in window:
                    end = i
                    break
        if end is None:
            raise SystemExit("shadow end missing")
        replacement = SHADOW_REPLACEMENT
        if not replacement.endswith("\n"):
            replacement += "\n"
        lines[start : end + 1] = [replacement]
        print(f"shadow replaced lines {start+1}-{end+1}")
        text = "".join(lines)

    if "stage.domain == RuntimeDomainId::MODIFIER &&" not in text:
        marker = (
            "        if (stage.domain != RuntimeDomainId::COMMIT) continue;\n"
        )
        if marker not in text:
            raise SystemExit("ACTIVE commit marker missing")
        # Fix ACTIVE_INSERT escaped chars - we used '\\0' in the python string which becomes \0 in output - good
        # But we wrote '\\\\0' in some places - fix ACTIVE_INSERT content
        active = ACTIVE_INSERT.replace("\\\\0", "\\0")
        text = text.replace(marker, active + marker, 1)
        print("active stage inserted")
    else:
        print("active stage already present")

    # enqueue
    if "modifier_enqueue_allowed" not in text:
        old = (
            "    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);\n"
            "    if (current != RuntimeWorkerState::STOPPED) {\n"
            "        if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::SHADOW)\n"
            "            return false;\n"
            "        return enqueue(std::move(packet));\n"
            "    }\n"
            "    if (packet.submit_order == 0) {\n"
            "        packet.submit_order = _command_submit_order.fetch_add(\n"
            "            1u, std::memory_order_relaxed) + 1u;\n"
            "    }\n"
            "    std::lock_guard<std::mutex> lock(_control_mutex);\n"
            "    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {\n"
            "        if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::SHADOW)\n"
            "            return false;\n"
            "        return enqueue(std::move(packet));\n"
            "    }\n"
        )
        # Only replace inside enqueue_modifier_shadow — find unique context
        fn = "bool NativeSimulationHost::enqueue_modifier_shadow(RuntimeCommandPacket packet) {\n"
        pos = text.find(fn)
        if pos < 0:
            raise SystemExit("enqueue fn missing")
        region_end = text.find("\nbool NativeSimulationHost::", pos + len(fn))
        region = text[pos:region_end]
        if old not in region:
            raise SystemExit("enqueue body missing")
        new = (
            "    const auto modifier_enqueue_allowed = [this]() {\n"
            "        const RuntimeSimulationMode mode =\n"
            "            _mode.load(std::memory_order_acquire);\n"
            "        if (mode == RuntimeSimulationMode::SHADOW) return true;\n"
            "        // E8: ACTIVE Host is the sole Modifier writer once MODIFIER is\n"
            "        // in the requested authority mask (grant may still be pending).\n"
            "        if (mode == RuntimeSimulationMode::ACTIVE &&\n"
            "            (_requested_authority_mask.load(std::memory_order_acquire) &\n"
            "             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u) {\n"
            "            return true;\n"
            "        }\n"
            "        return false;\n"
            "    };\n"
            "    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);\n"
            "    if (current != RuntimeWorkerState::STOPPED) {\n"
            "        if (!modifier_enqueue_allowed()) return false;\n"
            "        return enqueue(std::move(packet));\n"
            "    }\n"
            "    if (packet.submit_order == 0) {\n"
            "        packet.submit_order = _command_submit_order.fetch_add(\n"
            "            1u, std::memory_order_relaxed) + 1u;\n"
            "    }\n"
            "    std::lock_guard<std::mutex> lock(_control_mutex);\n"
            "    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {\n"
            "        if (!modifier_enqueue_allowed()) return false;\n"
            "        return enqueue(std::move(packet));\n"
            "    }\n"
        )
        region2 = region.replace(old, new, 1)
        text = text[:pos] + region2 + text[region_end:]
        print("enqueue updated")
    else:
        print("enqueue already updated")

    CPP.write_text(text, encoding="utf-8")
    print("cpp ok")


if __name__ == "__main__":
    patch_header()
    patch_cpp()
