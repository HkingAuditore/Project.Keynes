#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
bool NativeSimulationHost::stage_gameplay_effect(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &plan = day.plan;
    auto &day_commands = day.day_commands;
    auto &commit = day.commit;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    auto &gameplay_event_commands = day.gameplay_event_commands;
    if (stage.domain == RuntimeDomainId::GAMEPLAY_EFFECT &&
        _mode.load(std::memory_order_acquire) ==
            RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT)) != 0u) {
        if (climate_authority_requested && !active_climate_ok) {
            stage.completed = 0;
            return true;
        }
        // Gameplay commands arrive as typed RuntimeCommandPacket rows.
        // The worker owns admission, deterministic ordering and terminal
        // accounting here; publication of the resulting event is handled
        // by the subsequent EVENTS stage. No Godot value is touched.
        uint32_t terminal = 0;
        uint32_t events_terminal = 0;
        uint64_t effect_hash = 1469598103934665603ull;
        bool gameplay_effect_ok = true;
        std::vector<RuntimeIdeologyPodCommand> ideology_commands;
        for (const RuntimeCommandPacket &packet : day_commands) {
            if (packet.envelope.domain != static_cast<uint16_t>(
                    RuntimeDomainId::GAMEPLAY_EFFECT) ||
                packet.envelope.effective_day > plan.context.day) {
                continue;
            }
            const bool payload_bounds =
                packet.envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                packet.envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                packet.envelope.payload_offset <=
                    RUNTIME_MAX_COMMAND_PAYLOAD - packet.envelope.payload_size;
            const uint8_t *payload = payload_bounds
                ? packet.payload.data() + packet.envelope.payload_offset : nullptr;
            const size_t payload_size = payload_bounds
                ? packet.envelope.payload_size : 0u;
            size_t cursor = 0;
            int32_t action = 0;
            int32_t target_domain = 0;
            int32_t opcode = 0;
            int64_t effective_day = -1;
            uint64_t target_handle = 0;
            uint32_t target_generation = 0;
            int64_t value_i64 = 0;
            std::array<int64_t, 4> typed_payload{};
            uint64_t idempotency_key = 0;
            const bool decoded = payload_bounds &&
                d7_read_i32(payload, payload_size, cursor, action) &&
                d7_read_i32(payload, payload_size, cursor, target_domain) &&
                d7_read_i32(payload, payload_size, cursor, opcode) &&
                d7_read_i64(payload, payload_size, cursor, effective_day) &&
                d7_read_u64(payload, payload_size, cursor, target_handle) &&
                d7_read_u32(payload, payload_size, cursor, target_generation) &&
                d7_read_i64(payload, payload_size, cursor, value_i64) &&
                d7_read_i64(payload, payload_size, cursor, typed_payload[0]) &&
                d7_read_i64(payload, payload_size, cursor, typed_payload[1]) &&
                d7_read_i64(payload, payload_size, cursor, typed_payload[2]) &&
                d7_read_i64(payload, payload_size, cursor, typed_payload[3]) &&
                d7_read_u64(payload, payload_size, cursor, idempotency_key) &&
                cursor == payload_size;
            const bool publishes_event =
                (action == 4 && target_domain == 3) ||
                (action == 5 && target_domain == 4);
            const bool grants_ideology_free_draw =
                action == 6 && target_domain == 6 &&
                opcode == 3 && value_i64 > 0 && value_i64 <= 65535;
            if (!decoded || (!publishes_event && !grants_ideology_free_draw) ||
                opcode <= 0 ||
                effective_day != packet.envelope.effective_day ||
                target_handle == 0 || target_generation == 0 ||
                idempotency_key == 0) {
                gameplay_effect_ok = false;
                break;
            }
            if (grants_ideology_free_draw) {
                // Custom-domain free-draw grant. This does not append an
                // Events packet: the target domain is Ideology, and the
                // grant is durable in the Ideology POD. The request id is
                // the Effect transaction's idempotency key so replay after
                // a staged failure cannot grant twice.
                RuntimeIdeologyPodCommand ideology_command;
                ideology_command.request_id = idempotency_key;
                ideology_command.producer_id = packet.envelope.producer_id;
                ideology_command.sequence = packet.envelope.sequence;
                ideology_command.submit_order = packet.submit_order;
                ideology_command.requested_day =
                    packet.envelope.requested_day;
                ideology_command.effective_day = effective_day;
                ideology_command.opcode =
                    RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW;
                ideology_command.country_handle = target_handle;
                ideology_command.value_q16 = value_i64;
                ideology_commands.push_back(ideology_command);
                ++terminal;
                effect_hash = mix_hash(effect_hash,
                                       packet.envelope.request_id);
                effect_hash = mix_hash(effect_hash,
                                       packet.envelope.sequence);
                effect_hash = mix_hash(effect_hash,
                                       packet.envelope.opcode);
                effect_hash = mix_hash(effect_hash,
                                       packet.envelope.payload_size);
                for (uint32_t i = 0; i < packet.envelope.payload_size; ++i)
                    effect_hash = mix_hash(effect_hash, packet.payload[i]);
                continue;
            }
            RuntimeCommandPacket event_packet{};
            event_packet.envelope.request_id = packet.envelope.request_id;
            event_packet.envelope.producer_id = packet.envelope.producer_id;
            event_packet.envelope.sequence = packet.envelope.sequence;
            event_packet.envelope.observed_generation =
                packet.envelope.observed_generation;
            event_packet.envelope.requested_day = packet.envelope.requested_day;
            event_packet.envelope.effective_day = effective_day;
            event_packet.envelope.domain = static_cast<uint16_t>(
                RuntimeDomainId::EVENTS);
            event_packet.envelope.opcode = static_cast<uint16_t>(
                RuntimeEventsCommand::APPEND_BATCH);
            std::vector<uint8_t> event_payload;
            event_payload.reserve(88u);
            const auto put_u32 = [&event_payload](uint32_t value) {
                for (uint32_t i = 0; i < 4u; ++i)
                    event_payload.push_back(static_cast<uint8_t>(
                        (value >> (i * 8u)) & 0xffu));
            };
            const auto put_u64 = [&event_payload](uint64_t value) {
                for (uint32_t i = 0; i < 8u; ++i)
                    event_payload.push_back(static_cast<uint8_t>(
                        (value >> (i * 8u)) & 0xffu));
            };
            const auto put_i32 = [&put_u32](int32_t value) {
                put_u32(static_cast<uint32_t>(value));
            };
            const auto put_i64 = [&put_u64](int64_t value) {
                put_u64(static_cast<uint64_t>(value));
            };
            put_u32(RUNTIME_EVENTS_ABI_VERSION);
            put_u32(1u);
            put_i64(effective_day);
            put_i32(95);
            put_i32(opcode);
            put_i32(4); // PK_EVENT_SOURCE_EFFECT
            put_i32(0);
            put_u64(target_handle);
            put_i32(static_cast<int32_t>(typed_payload[0]));
            put_i32(static_cast<int32_t>(typed_payload[1]));
            put_i32(static_cast<int32_t>(typed_payload[2]));
            put_i64(value_i64);
            put_i32(static_cast<int32_t>(typed_payload[0]));
            put_i32(static_cast<int32_t>(typed_payload[1]));
            put_i32(static_cast<int32_t>(typed_payload[2]));
            put_i32(static_cast<int32_t>(typed_payload[3]));
            put_u64(idempotency_key);
            event_packet.envelope.payload_size = static_cast<uint32_t>(
                event_payload.size());
            if (event_payload.size() > event_packet.payload.size()) {
                gameplay_effect_ok = false;
                break;
            }
            std::memcpy(event_packet.payload.data(), event_payload.data(),
                        event_payload.size());
            gameplay_event_commands.push_back(event_packet);
            ++terminal;
            ++events_terminal;
            effect_hash = mix_hash(effect_hash, packet.envelope.request_id);
            effect_hash = mix_hash(effect_hash, packet.envelope.sequence);
            effect_hash = mix_hash(effect_hash, packet.envelope.opcode);
            // GAMEPLAY_EFFECT packets carry the fixed typed ingress row
            // (action/domain/opcode/day/target/value/payload/key). Hash
            // the bytes as part of the worker state so receipts cannot
            // report success for an envelope whose typed body was lost.
            effect_hash = mix_hash(effect_hash, packet.envelope.payload_size);
            for (uint32_t i = 0; i < packet.envelope.payload_size; ++i)
                effect_hash = mix_hash(effect_hash, packet.payload[i]);
        }
        if (!gameplay_effect_ok) {
            gameplay_event_commands.clear();
            _gameplay_effect_pending.store(terminal + 1u,
                                           std::memory_order_release);
            _gameplay_effect_terminal.store(0, std::memory_order_release);
            stage.completed = 0;
            commit.preflight_ok = 0;
            return true;
        }
        if (!ideology_commands.empty()) {
            std::string ideology_queue_error;
            if (!queue_ideology_pod_commands(
                    ideology_commands, ideology_queue_error)) {
                gameplay_event_commands.clear();
                _gameplay_effect_pending.store(terminal + 1u,
                                               std::memory_order_release);
                _gameplay_effect_terminal.store(0,
                                                std::memory_order_release);
                stage.completed = 0;
                commit.preflight_ok = 0;
                return true;
            }
        }
        _gameplay_effect_generation.fetch_add(1, std::memory_order_release);
        _gameplay_effect_pending.store(0, std::memory_order_release);
        _gameplay_effect_terminal.store(terminal, std::memory_order_release);
        _gameplay_effect_state_hash.store(effect_hash,
                                           std::memory_order_release);
        stage.work_units = std::max<uint64_t>(1u, terminal);
        stage.dirty_families = events_terminal != 0
            ? RUNTIME_DIRTY_EVENTS : 0;
        stage.completed = 1;
        commit.work_units += stage.work_units;
        commit.dirty_families |= stage.dirty_families;
        commit.completed_domain_mask |=
            runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT);
        ++commit.completed_stage_count;
        if (terminal > 0u) {
            _active_evidence_mask.fetch_or(
                runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT),
                std::memory_order_release);
        }
        return true;
    }
    return true;
}
} // namespace pk
