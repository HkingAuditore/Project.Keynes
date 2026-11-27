#include "native_simulation_host.h"
#include "native_simulation_host_military.h"
#include "native_simulation_host_support.h"

#include "economy_api.h"
#include "runtime_narrative.h"

#include <algorithm>
#include <cstring>

namespace pk {
using namespace godot;

namespace {

constexpr uint32_t NARRATIVE_PRODUCER = 190;
constexpr uint64_t NARRATIVE_MODIFIER_SOURCE = 0x4e415252;
constexpr int32_t RING_SCALE[] = {65536, 39322, 19661};

int64_t share(int64_t total, int64_t basis_points) {
    return (total / 10000) * basis_points + (total % 10000) * basis_points / 10000;
}

int64_t limited_quantity(const NarrativeEffect &effect, int64_t available) {
    const int64_t maximum = std::max<int64_t>(0, available);
    int64_t requested = effect.value > 0 ? effect.value : share(maximum, effect.ratio);
    if (requested == 0 && effect.value == 0 && effect.ratio > 0 && maximum > 0)
        requested = 1;
    return std::clamp<int64_t>(requested, 0, maximum);
}

template <size_t N>
void copy_identity(std::array<char, N> &target, const std::string &value) {
    const size_t length = std::min(N - 1, value.size());
    std::copy_n(value.begin(), length, target.begin());
}

} // namespace

bool NativeSimulationHost::dispatch_narrative_independence(int64_t day) {
    for (const auto &action : _executor_narrative->take_independence_actions()) {
        if (action.new_owner != 0) {
            if (!_executor_military) return false;
            _executor_military->country_state = _country_pod_authority.borrow_state();
            if (!_executor_military->submit_independence(
                    action.old_owner, action.new_owner, action.cell, day)) return false;
            continue;
        }
        RuntimeCountryCommand command;
        command.request_id = allocate_command_request_id();
        command.sequence = action.sequence;
        command.requested_day = command.effective_day = day;
        command.opcode = CountryApi::COMMAND_CREATE_COUNTRY;
        command.cell = action.cell;
        copy_identity(command.stable_id, action.stable_id);
        copy_identity(command.display_name, action.display_name);
        if (!enqueue_batch_at({encode_country_packet(command)}, nullptr, false)) return false;
    }
    return true;
}

Dictionary NativeSimulationHost::resolve_narrative_choice(int64_t day, const Dictionary &args) {
    auto &narrative = *_executor_narrative;
    const auto input = sample_narrative_day(day);
    Dictionary result = narrative.begin_choice(input, args);
    if (!bool(result.get("ok", false))) return result;

    const Dictionary outcome = result.get("outcome", Dictionary());
    const int64_t effect_day = result["effective_day"];
    const Array effects = outcome.get("effects", Array());
    const auto &record = narrative.choice_record();
    const int32_t cell = record.get("cell_idx", -1);
    const int64_t record_id = record.get("record_id", 0);
    const uint64_t player = narrative.player();
    auto local = input.sample(cell, true);
    int64_t treasury = std::max<int64_t>(0, input.country.treasury_cash);
    std::vector<RuntimeCommandPacket> packets;
    std::vector<EconomyApi::EffectCommand> economy_commands;
    PackedStringArray effect_failures;
    std::vector<std::pair<NarrativeEffect, int64_t>> family_commands;
    auto plan_economy = [&](EconomyApi::EffectCommand command, int64_t index) {
        command.effective_day = effect_day;
        command.sequence = allocate_producer_sequence(NARRATIVE_PRODUCER);
        command.idempotency_key = 0x4e41000000000000ull |
            (static_cast<uint64_t>(record_id) << 16) | uint16_t(index);
        economy_commands.push_back(command);
    };
    const auto add_modifier = [&](const NarrativeEffect &effect, bool local, int32_t target, int32_t ring) {
        const auto found = _modifier_definition_id_by_key_hash.find(
            RuntimeEffectPodAuthority::hash_text(effect.key.c_str()));
        if (found == _modifier_definition_id_by_key_hash.end()) {
            const String reason = String("modifier_request_unknown:") + effect.key.c_str();
            if (!effect_failures.has(reason)) effect_failures.push_back(reason);
            return;
        }
        RuntimeModifierPodCommand command;
        command.source_id = narrative.allocate_modifier_source();
        command.request_id = allocate_command_request_id_for_ingress();
        command.producer_id = NARRATIVE_PRODUCER;
        command.sequence = allocate_producer_sequence(NARRATIVE_PRODUCER);
        command.requested_day = command.effective_day = effect_day;
        command.opcode = static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY);
        command.domain = local ? 2 : 1; // Modifier's Economy and Country domains
        command.scope = local ? 1 : 2; // group (cell) or country entity
        command.group_handle = local ? target : 0;
        command.entity_handle = local ? 0 : player;
        command.target_generation = local ? 0 : player >> 32;
        command.source_type = NARRATIVE_MODIFIER_SOURCE;
        command.definition_id = found->second;
        command.duration_days = effect.duration;
        command.magnitude_q16 = ring == 0 || !effect.falloff ? effect.magnitude :
            std::max<int64_t>(1, (effect.magnitude * RING_SCALE[ring] + 32768) >> 16);
        // A dated effect reads the target identity. Its plan is independent
        // of the environment-generation number for that day.
        packets.push_back(encode_modifier_packet(command));
    };
    const auto &catalog = narrative.catalog();
    for (int64_t index = 0; index < effects.size(); ++index) {
        const auto effect = compile_narrative_effect(effects[index]);
        switch (effect.kind) {
        case NarrativeEffect::CITY_MODIFIER:
            if (cell < 0) break;
            add_modifier(effect, true, cell, 0);
            for (int32_t ring = 1; ring <= std::min(effect.radius, 2); ++ring) {
                for (const int32_t neighbor : local.nearby[ring - 1])
                    add_modifier(effect, true, neighbor, ring);
            }
            break;
        case NarrativeEffect::COUNTRY_MODIFIER:
            if (player != 0) add_modifier(effect, false, -1, 0);
            break;
        case NarrativeEffect::DISCOVER_RESEARCH_SIGNAL: {
            const auto found = std::find(catalog.signal_ids.begin(), catalog.signal_ids.end(), effect.key);
            if (found == catalog.signal_ids.end() || player == 0 || cell < 0) break;
            RuntimeCountryCommand command;
            command.request_id = allocate_command_request_id_for_ingress();
            command.sequence = allocate_producer_sequence(0);
            command.requested_day = command.effective_day = effect_day;
            command.opcode = CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL;
            command.target_handle = player;
            command.cell = cell;
            command.aux = static_cast<int32_t>(found - catalog.signal_ids.begin());
            command.weights_bp.fill(0);
            command.value = 1;
            packets.push_back(encode_country_packet(command));
            break;
        }
        case NarrativeEffect::GRANT_TRAIT:
        case NarrativeEffect::REMOVE_TRAIT: {
            const uint64_t family = local.family;
            if (!_economy_production_runtime || family == 0 || effect.key.empty()) break;
            family_commands.emplace_back(effect, allocate_producer_sequence(NARRATIVE_PRODUCER));
            break;
        }
        case NarrativeEffect::TREASURY_CASH_TO_COHORT:
        case NarrativeEffect::COHORT_CASH_TO_TREASURY: {
            if (local.primary_cohort == 0 || player == 0) break;
            const bool aid = effect.kind == NarrativeEffect::TREASURY_CASH_TO_COHORT;
            auto &balance = aid ? treasury : local.primary_cash;
            const int64_t amount = limited_quantity(effect, balance);
            if (amount == 0) break;
            EconomyApi::EffectCommand command;
            command.opcode = aid ? EconomyApi::COMMAND_TRANSFER_TO_COHORT :
                EconomyApi::COMMAND_TRANSFER_FROM_COHORT;
            command.target_handle = local.primary_cohort;
            command.i64_0 = amount;
            command.i64_1 = player;
            plan_economy(command, index);
            balance -= amount;
            break;
        }
        case NarrativeEffect::ADD_POPULATION: {
            if (local.primary_cohort == 0) break;
            int64_t delta = effect.value;
            if (delta == 0 && effect.ratio != 0 && local.population > 0) {
                delta = share(local.population, effect.ratio);
                if (delta == 0) delta = effect.ratio > 0 ? 1 : -1;
            }
            if (delta == 0) break;
            EconomyApi::EffectCommand command;
            command.opcode = EconomyApi::COMMAND_ADD_POPULATION;
            command.target_handle = local.primary_cohort;
            command.i64_0 = delta;
            plan_economy(command, index);
            local.population = std::max<int64_t>(0, local.population + delta);
            break;
        }
        case NarrativeEffect::COUNTRY_GOOD_TO_MARKET:
        case NarrativeEffect::MARKET_GOOD_TO_COUNTRY:
        case NarrativeEffect::MARKET_ADD_STOCK:
        case NarrativeEffect::MARKET_REMOVE_STOCK: {
            const auto it = std::find(catalog.good_ids.begin(), catalog.good_ids.end(), effect.key);
            if (cell < 0 || local.market_id < 0 || it == catalog.good_ids.end()) break;
            if ((effect.kind == NarrativeEffect::MARKET_ADD_STOCK ||
                 effect.kind == NarrativeEffect::COUNTRY_GOOD_TO_MARKET) &&
                !local.has_local_merchant)
                break;
            EconomyApi::EffectCommand command;
            command.i32_0 = local.market_id;
            command.i32_1 = static_cast<int32_t>(it - catalog.good_ids.begin());
            if (effect.kind == NarrativeEffect::MARKET_ADD_STOCK) {
                command.opcode = EconomyApi::COMMAND_ADD_STOCK;
                command.i64_0 = std::max<int64_t>(1, effect.value);
            } else if (effect.kind == NarrativeEffect::COUNTRY_GOOD_TO_MARKET) {
                const auto reserve = input.country.treasury_goods.find(effect.key);
                if (reserve == input.country.treasury_goods.end()) break;
                command.opcode = EconomyApi::COMMAND_COUNTRY_GOOD_TO_MARKET;
                command.target_handle = player;
                command.i64_0 = limited_quantity(effect, reserve->second);
            } else {
                const bool reclaim = effect.kind == NarrativeEffect::MARKET_GOOD_TO_COUNTRY;
                command.opcode = reclaim ? EconomyApi::COMMAND_MARKET_GOOD_TO_COUNTRY :
                    EconomyApi::COMMAND_REMOVE_STOCK;
                command.target_handle = reclaim ? player : 0;
                command.i64_0 = limited_quantity(effect, local.stock(effect.key));
            }
            if (command.i64_0 > 0) plan_economy(command, index);
            break;
        }
        default: break;
        }
    }
    const Dictionary concession = result.get("concession", Dictionary());
    if (!concession.is_empty()) {
        EconomyApi::EffectCommand payment;
        payment.opcode = EconomyApi::COMMAND_TRANSFER_TO_COHORT;
        payment.target_handle = int64_t(concession["cohort"]);
        payment.i64_0 = int64_t(concession["amount"]);
        payment.i64_1 = player;
        plan_economy(payment, effects.size());
    }
    std::vector<int64_t> requests;
    std::string error;
    const auto admit_economy = [&] {
        if (economy_commands.empty()) return true;
        if (!_economy_production_runtime) {
            error = "narrative_effect_economy_unavailable";
            return false;
        }
        return economy_api::submit_effect_commands_pod(*_economy_production_runtime,
            economy_commands.data(), economy_commands.size(), requests, error);
    };
    const bool admitted = packets.empty() ? admit_economy()
        : enqueue_batch_at(std::move(packets), nullptr, false, admit_economy);
    if (!admitted) {
        effect_failures.push_back(error.empty() ? "narrative_effect_queue_full" : error.c_str());
        result["effect_failures"] = effect_failures;
        return narrative.complete_choice(std::move(result), false);
    }
    for (const auto &[effect, sequence] : family_commands) {
        if (!economy_api::submit_effect_family_trait(*_economy_production_runtime, local.family,
                effect.key, effect.kind == NarrativeEffect::GRANT_TRAIT,
                std::clamp<int64_t>(effect.magnitude, 49152, 81920), effect_day, sequence))
            effect_failures.push_back(String("narrative_family_trait_rejected:") + effect.key.c_str());
    }
    if (!effect_failures.is_empty()) result["effect_failures"] = effect_failures;
    if (!requests.empty()) {
        PackedInt64Array pending;
        for (const auto id : requests) pending.push_back(id);
        result["pending_economy_effects"] = pending;
    }
    const Dictionary meta = record.get("meta", Dictionary());
    if (_economy_production_runtime && String(meta.get("kind", "")) == "rebellion") {
        const Array actions = meta.get("actions", Array());
        const int32_t option = record.get("chosen_option_index", -1);
        if (option >= 0 && option < actions.size()) {
            const bool success = int32_t(record.get("rolled_outcome_index", 1)) == 0;
            const int32_t cell = meta.get("cell", -1);
            const int32_t profession = meta.get("profession", -1);
            const bool applied = economy_api::settle_narrative_unrest(
                *_economy_production_runtime, cell, profession, actions[option], success);
            bool independence_pending = false;
            if (applied) {
                std::vector<NarrativeUnrestRow> rows;
                if (economy_api::narrative_unrest_rows(*_economy_production_runtime, cell, rows)) {
                    independence_pending = std::any_of(rows.begin(), rows.end(),
                        [profession](const auto &row) {
                            return row.profession == profession && (row.flags & 8) != 0;
                        });
                }
            }
            narrative.finish_unrest_choice(applied, independence_pending, effect_day);
        }
    }
    return narrative.complete_choice(std::move(result));
}

} // namespace pk
