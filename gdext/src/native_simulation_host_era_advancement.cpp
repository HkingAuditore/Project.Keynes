#include "native_simulation_day_context.h"
#include "native_simulation_host_support.h"

#include "country_api.h"
#include "economy_api.h"
#include "effect_runtime.h"
#include "runtime_era_advancement.h"
#include "runtime_era_reward.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace pk {
using namespace godot;

namespace {
using Phase = RuntimeEraAdvancement::Phase;

Dictionary result(bool ok, const char *code, const char *message = "") {
    Dictionary out;
    out["ok"] = ok;
    out["code"] = code;
    out["message"] = String::utf8(message);
    return out;
}

Dictionary era_at(const RuntimeEraAdvancement &state, int32_t index) {
    return index >= 0 && index < state.catalog.size() ? Dictionary(state.catalog[index])
                                                       : Dictionary();
}

struct EraInputs {
    const RuntimeCountryPodSnapshot &country;
    int32_t slot;
    int64_t population;
    int64_t buildings;
    Dictionary budget;
    bool reward_pending;

    bool has_technology(int32_t tech, bool include_pending = false) const {
        if (tech < 0 || static_cast<uint32_t>(tech) >= country.technology_count) return false;
        const size_t word = size_t(slot) * country.technology_words + tech / 64;
        const uint64_t mask = uint64_t{1} << (tech % 64);
        return (country.country_technologies[word] & mask) ||
            (include_pending && (country.country_pending_technologies[word] & mask));
    }

    int64_t stock(int32_t good) const {
        if (good < 0 || static_cast<uint32_t>(good) >= country.good_count) return 0;
        return country.country_goods[size_t(slot) * country.good_count + good];
    }
};

int32_t country_slot(const RuntimeCountryPodSnapshot *country, uint64_t handle) {
    const uint32_t slot = static_cast<uint32_t>(handle);
    if (!country || slot >= country->country_count || !country->country_active[slot] ||
        country->country_generation[slot] != uint32_t(handle >> 32)) return -1;
    return static_cast<int32_t>(slot);
}

int32_t current_era(const RuntimeEraAdvancement &state, const EraInputs &input) {
    int32_t era = 0;
    for (int32_t i = 1; i < state.catalog.size(); ++i)
        if (input.has_technology(era_at(state, i).get("milestone", -1))) era = i;
    return era;
}

Array procurement_goods(const RuntimeEraAdvancement &state, int32_t target) {
    return era_at(state, target).get("goods", Array());
}

int64_t requirement(const Dictionary &good, int32_t territory) {
    return int64_t(good.get("floor", 0)) +
           int64_t(good.get("per_cell", 0)) * std::max(1, territory);
}

bool prelude_complete(const RuntimeEraAdvancement &state, const EraInputs &input, int32_t target) {
    return target != 1 || input.has_technology(era_at(state, 0).get("milestone", -1));
}

Dictionary policy_view(const RuntimeEraAdvancement::Policy &policy) {
    Dictionary out;
    out["treasury_share_bp"] = policy.treasury;
    out["research_share_bp"] = policy.research;
    out["era_share_bp"] = policy.era;
    out["colonization_share_bp"] = policy.colonization;
    return out;
}

RuntimeEraAdvancement::Policy read_policy(const Dictionary &value) {
    return {value.get("treasury_share_bp", 200), value.get("research_share_bp", 5000),
            value.get("era_share_bp", -1), value.get("colonization_share_bp", -1)};
}

std::shared_ptr<const RuntimeEraAdvancementView> make_view(
        const RuntimeEraAdvancement &state, const EraInputs &input) {
    auto view = std::make_shared<RuntimeEraAdvancementView>();
    view->state = state.business_state();
    view->save = state.save();
    const int32_t era = current_era(state, input);
    const int32_t next_era = era + 1 < state.catalog.size() ? era + 1 : -1;
    const Dictionary current = era_at(state, era), next = era_at(state, next_era);
    const int32_t target = state.phase == Phase::IDLE ? next_era : state.target;
    const int32_t territory = input.country.territory_count[input.slot];
    Array conditions;
    int32_t met = 0;
    bool technology_met = false;
    if (next_era > 0) {
        const PackedInt32Array tech = current.get("technology", PackedInt32Array());
        int64_t complete = 0;
        for (const int32_t id : tech) complete += input.has_technology(id);
        const int64_t tech_target = static_cast<int64_t>(std::ceil(tech.size() * state.technology_ratio));
        const PackedInt64Array floors = next["condition_floor"];
        const PackedInt64Array per_cell = next["condition_per_cell"];
        const PackedStringArray labels = next["condition_labels"];
        const int64_t values[] = {complete, input.population, input.buildings, state.trade};
        const char *keys[] = {"tech", "population", "buildings", "trade"};
        const char *units[] = {" 项", " 人", " 座", " 次"};
        technology_met = !tech.is_empty() && complete >= tech_target;
        for (int32_t i = 0; i < 4; ++i) {
            const int64_t needed = i == 0 ? tech_target : floors[i] + per_cell[i] * std::max(1, territory);
            const bool qualifies = i == 0 ? technology_met : values[i] >= needed;
            Dictionary row;
            row["key"] = keys[i];
            row["label"] = labels[i];
            row["current"] = values[i];
            row["target"] = needed;
            row["met"] = qualifies;
            row["text"] = String::num_int64(values[i]) + " / " + String::num_int64(needed) + String::utf8(units[i]);
            if (i == 0) row["mandatory"] = true;
            conditions.push_back(row);
            met += qualifies;
        }
    }
    const bool can_start = next_era > 0 && state.phase == Phase::IDLE &&
        technology_met && met >= state.conditions_required;
    Array costs;
    double progress = 0.0;
    bool stocked = true;
    const Array basket = procurement_goods(state, target);
    for (int64_t i = 0; i < basket.size(); ++i) {
        const Dictionary good = basket[i];
        const int64_t need = state.phase == Phase::IDLE
            ? requirement(good, territory) : state.required[i];
        const int64_t have = input.stock(good.get("index", -1));
        const double ratio = std::clamp(double(have) / std::max<int64_t>(1, need), 0.0, 1.0);
        Dictionary row;
        row["good_id"] = good.get("good_id", "");
        row["name"] = good.get("name", good.get("good_id", ""));
        row["required"] = need;
        row["in_treasury"] = have;
        row["ratio"] = ratio;
        costs.push_back(row);
        progress += ratio;
        stocked = stocked && have >= need;
    }

    Dictionary budget = policy_view(state.policy);
    for (const char *channel : {"national", "era", "colonization"}) {
        const String key = String(channel) + "_daily";
        budget[key] = input.budget.get(key + String("_budget"), 0);
    }
    auto &out = view->model;
    out["ok"] = true;
    out["current_era_index"] = era;
    out["current_era_name"] = current.get("name", "");
    out["next_era_index"] = next_era;
    out["next_era_name"] = next.get("name", "");
    out["status"] = next_era < 0 ? "max" : (state.phase != Phase::IDLE
        ? state.phase_name() : (can_start ? "ready" : "locked"));
    out["conditions"] = conditions;
    out["conditions_met"] = met;
    out["conditions_required"] = state.conditions_required;
    out["can_start"] = can_start;
    out["territory_count"] = territory;
    out["frozen_territory_count"] = state.frozen_territory;
    out["costs"] = costs;
    out["progress"] = state.phase == Phase::COMPLETING ? 1.0 :
        (state.phase != Phase::IDLE && !costs.is_empty() ? progress / costs.size() : 0.0);
    out["buffs_preview"] = era_at(state, target).get(
        prelude_complete(state, input, target) ? "buffs" : "buffs_with_prelude", PackedStringArray());
    out["budget"] = budget;
    if (state.phase == Phase::PURCHASING && stocked && !costs.is_empty()) {
        if (input.reward_pending)
            out["blocked_reason"] = String::utf8("请先领取待处理的时代奖励，物资已备齐后将自动完成晋升。");
        else if (!prelude_complete(state, input, target))
            out["blocked_reason"] = String::utf8("前置时代里程碑正在生效，完成后将自动晋升。");
    }
    return view;
}

bool reward_pending(const EffectRuntime &effect) {
    const String status = effect.era_reward_offer_snapshot().get("status", "NONE");
    return status == "OPEN" || status == "SELECTED_PENDING" || status == "ERROR";
}

Dictionary submit_policy(NativeEconomyRuntime &economy, RuntimeEraAdvancement &state,
        const RuntimeEraAdvancement::Policy &policy, int64_t day, int64_t sequence) {
    Dictionary out = economy_api::set_country_procurement_policy(economy,
        state.country, true, policy.treasury, policy.research, day, sequence,
        policy.era, policy.colonization);
    if (bool(out.get("ok", false))) {
        state.last_policy_day = day;
        state.policy = policy;
        out["message"] = String::utf8("国家购买预算已更新。");
    }
    return out;
}

bool submit_target(NativeEconomyRuntime &economy, RuntimeEraAdvancement &state,
        bool active, int64_t day, int64_t sequence) {
    PackedInt32Array good_ids;
    if (active) {
        const Array basket = procurement_goods(state, state.target);
        for (int64_t i = 0; i < basket.size(); ++i) {
            const Dictionary row = basket[i];
            good_ids.push_back(int32_t(row.get("index", -1)));
        }
    }
    const Dictionary out = economy_api::set_era_procurement_target(economy,
        state.country, active, good_ids, active ? state.required : PackedInt64Array(),
        day, sequence);
    const bool queued = out.get("ok", false);
    if (queued) state.last_target_day = day;
    return queued;
}
} // namespace

const char *RuntimeEraAdvancement::phase_name() const {
    switch (phase) {
        case Phase::PURCHASING: return "purchasing";
        case Phase::PAUSED: return "paused";
        case Phase::COMPLETING: return "completing";
        case Phase::IDLE: return "";
    }
    return "";
}

void RuntimeEraAdvancement::clear_purchase() {
    phase = Phase::IDLE;
    target = -1;
    frozen_territory = 0;
    goods.clear();
    required.clear();
    completion_day = -1;
    prelude_granted = false;
}

Dictionary RuntimeEraAdvancement::business_state() const {
    Dictionary out = policy_view(policy);
    out["version"] = 1;
    out["phase"] = phase_name();
    out["target_era"] = target;
    out["frozen_territory"] = frozen_territory;
    out["required_good_ids"] = goods;
    out["required_quantities"] = required;
    out["known_era"] = known_era;
    out["trade_era"] = trade_era;
    out["trade_accumulated"] = trade;
    out["completion_day"] = completion_day;
    out["prelude_granted"] = prelude_granted;
    return out;
}

Dictionary RuntimeEraAdvancement::save() const {
    Dictionary out = business_state();
    out["next_sequence"] = next_sequence;
    out["target_effective_day"] = last_target_day;
    out["policy_effective_day"] = last_policy_day;
    out["trade_baseline_ready"] = last_trade_total >= 0;
    return out;
}

void RuntimeEraAdvancement::restore(const Dictionary &saved) {
    clear_purchase();
    known_era = saved.get("known_era", -1);
    trade_era = saved.get("trade_era", -1);
    trade = saved.get("trade_accumulated", 0);
    policy = read_policy(saved);
    last_trade_total = -1;
    next_sequence = saved.get("next_sequence", 1);
    last_target_day = saved.get("target_effective_day", -1);
    last_policy_day = saved.get("policy_effective_day", -1);
    const String stored_phase = saved.get("phase", "");
    const int32_t stored_target = saved.get("target_era", -1);
    const PackedStringArray stored_goods = saved.get("required_good_ids", PackedStringArray());
    const PackedInt64Array stored_required = saved.get("required_quantities", PackedInt64Array());
    if (stored_target < 1 || stored_target >= catalog.size() || stored_goods.is_empty() ||
        stored_goods.size() != stored_required.size() ||
        stored_goods.size() != procurement_goods(*this, stored_target).size()) return;
    if (stored_phase == "purchasing") phase = Phase::PURCHASING;
    else if (stored_phase == "paused") phase = Phase::PAUSED;
    else if (stored_phase == "completing") phase = Phase::COMPLETING;
    else return;
    target = stored_target;
    goods = stored_goods;
    required = stored_required;
    frozen_territory = saved.get("frozen_territory", 0);
    completion_day = saved.get("completion_day", -1);
    prelude_granted = saved.get("prelude_granted", false);
}

std::shared_ptr<const RuntimeEraAdvancementView> NativeSimulationHost::latest_era_advancement() const {
    return std::atomic_load(&_published_era_advancement);
}

bool NativeSimulationHost::install_era_advancement_setup() {
    if (!_effect_adapter_runtime) return true;
    for (auto *pending : {&_era_advancement_bind, &_era_advancement_restore}) {
        if (!*pending) continue;
        auto request = std::move(*pending);
        execute_era_advancement_request(*request);
        if (!bool(request->result.get("ok", false))) {
            const String code = request->result.get("code", "era_advancement_setup_failed");
            set_fault(code.utf8().get_data());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    return true;
}

bool NativeSimulationHost::submit_era_milestone(RuntimeEraAdvancement &state,
        int32_t era, int64_t requested, int64_t effective, int64_t sequence, bool consume_goods) {
    std::vector<RuntimeCommandPacket> packets;
    const auto command = [&](uint16_t opcode, int32_t aux, int64_t value) {
        RuntimeCountryCommand row;
        // These belong to the player's existing Country command stream.
        row.request_id = allocate_command_request_id_for_ingress();
        row.sequence = static_cast<uint64_t>(std::max<int64_t>(1, sequence));
        row.requested_day = requested;
        row.effective_day = effective;
        row.opcode = opcode;
        row.target_handle = state.country;
        row.aux = aux;
        row.value = value;
        row.weights_bp.fill(0);
        packets.push_back(encode_country_packet(row));
    };
    if (consume_goods) {
        const Array basket = procurement_goods(state, era);
        for (int64_t i = 0; i < basket.size(); ++i) {
            const Dictionary row = basket[i];
            if (state.required[i] > 0)
                command(CountryApi::COMMAND_CONSUME_TREASURY_GOODS, row["index"], state.required[i]);
        }
    }
    command(CountryApi::COMMAND_GRANT_TECHNOLOGY, era_at(state, era).get("milestone", -1), 0);
    return enqueue_batch_at(std::move(packets), nullptr, false);
}

void NativeSimulationHost::execute_era_advancement_request(RuntimeEraRewardRequest &request) {
    using Kind = RuntimeEraRewardRequest::Kind;
    request.result = result(false, "session_unavailable", "玩家国家尚未就绪，请稍后再试。");
    const auto *country = _country_pod_authority.borrow_state();
    const int32_t slot = country_slot(country, request.country_handle);
    if (slot < 0 || !_economy_production_runtime) return;
    auto &economy = *_economy_production_runtime;
    if (request.kind == Kind::BIND_ADVANCEMENT) {
        const Array catalog = request.advancement.get("eras", Array());
        if (catalog.is_empty()) return;
        if (!_era_advancement || _era_advancement->country != request.country_handle)
            _era_advancement = std::make_shared<RuntimeEraAdvancement>();
        auto &state = *_era_advancement;
        state.country = request.country_handle;
        state.catalog = catalog;
        state.conditions_required = request.advancement.get("conditions_required", 3);
        state.technology_ratio = request.advancement.get("technology_ratio", 0.6);
        const Dictionary regimes = request.advancement.get("political_regimes", Dictionary());
        if (!regimes.is_empty()) {
            std::vector<std::vector<int32_t>> definitions;
            for (const auto &id : _country_pod_catalog.political_regime_ids) {
                std::vector<int32_t> row;
                const PackedStringArray keys = regimes.get(String(id.c_str()), PackedStringArray());
                for (const String &key : keys) {
                    const auto found = _modifier_definition_id_by_key_hash.find(
                        RuntimeEffectPodAuthority::hash_text(key.utf8().get_data()));
                    if (found == _modifier_definition_id_by_key_hash.end()) {
                        request.result = result(false, "regime_modifier_definition_unknown");
                        return;
                    }
                    row.push_back(found->second);
                }
                definitions.push_back(std::move(row));
            }
            state.regime_definitions = std::move(definitions);
            state.observed_regime = -1;
        }
        request.result = result(true, "ok");
    }
    if (!_era_advancement || _era_advancement->country != request.country_handle) return;
    auto &state = *_era_advancement;
    const auto economy_summary = economy_api::era_advancement_economy_summary(economy, state.country);
    const EraInputs input{*country, slot, economy_summary.get("population", 0),
        economy_summary.get("building_units", 0),
        economy_api::country_procurement_snapshot(economy, state.country),
        reward_pending(*_effect_adapter_runtime)};
    const int64_t day = request.command() ? request.effective_day : command_seal_day();
    state.next_sequence = std::max(state.next_sequence, request.advancement_sequence + 1);
    const int64_t sequence = request.advancement_sequence;
    const auto grant_prelude = [&] {
        if (state.target != 1 ||
            input.has_technology(era_at(state, 0).get("milestone", -1), true) ||
            submit_era_milestone(state, 0, day, day + 1, state.next_sequence++, false))
            state.prelude_granted = true;
    };
    switch (request.kind) {
        case Kind::BIND_ADVANCEMENT:
            if (state.known_era < 0) {
                state.known_era = current_era(state, input);
                state.trade_era = state.known_era;
            }
            if (sequence > 0)
                request.result = submit_policy(economy, state, state.policy, day, sequence);
            break;
        case Kind::RESTORE_ADVANCEMENT: {
            state.restore(request.advancement);
            // Economy restored its budgets and ordered requests from ECP2.
            if (bool(request.advancement.get("trade_baseline_ready", false)))
                state.last_trade_total = input.budget.get("trade_orders_total", -1);
            request.result = result(true, "ok");
            break;
        }
        case Kind::SET_ADVANCEMENT_POLICY: {
            request.result = submit_policy(economy, state, read_policy(request.advancement), day, sequence);
            break;
        }
        case Kind::START_ADVANCEMENT: {
            const auto view = make_view(state, input);
            const String status = view->model["status"];
            if (status == "max") {
                request.result = result(false, "era_advance_max", "已到达最高时代。");
            } else if (state.phase != Phase::IDLE) {
                request.result = result(false, "era_advance_in_progress", "时代晋升已在进行中。");
            } else if (!bool(view->model["can_start"])) {
                request.result = result(false, "era_advance_conditions_unmet", "晋升条件未满足。");
            } else {
                state.target = current_era(state, input) + 1;
                state.frozen_territory = std::max(1, input.country.territory_count[slot]);
                const Array basket = procurement_goods(state, state.target);
                for (int64_t i = 0; i < basket.size(); ++i) {
                    const Dictionary row = basket[i];
                    state.goods.push_back(row["good_id"]);
                    state.required.push_back(requirement(row, state.frozen_territory));
                }
                if (submit_target(economy, state, true, day, sequence)) {
                    state.phase = Phase::PURCHASING;
                    grant_prelude();
                    request.result = result(true, "era_advance_started",
                        "时代晋升已开始，国家将按购买预算持续收购所需物资。");
                } else {
                    state.clear_purchase();
                    request.result = result(false, "era_procurement_target_rejected");
                }
            }
            break;
        }
        case Kind::PAUSE_ADVANCEMENT:
        case Kind::RESUME_ADVANCEMENT: {
            const bool resume = request.kind == Kind::RESUME_ADVANCEMENT;
            const Phase expected = resume ? Phase::PAUSED : Phase::PURCHASING;
            if (state.phase != expected) {
                request.result = resume
                    ? result(false, "era_advance_not_paused", "时代收购没有处于暂停状态。")
                    : result(false, "era_advance_not_purchasing", "当前没有进行中的收购。");
            } else if (submit_target(economy, state, resume, day, sequence)) {
                state.phase = resume ? Phase::PURCHASING : Phase::PAUSED;
                request.result = resume
                    ? result(true, "era_advance_resumed", "时代收购已继续。")
                    : result(true, "era_advance_paused", "时代收购已暂停，已购物资保留在国库。");
            }
            break;
        }
        default:
            break;
    }
    if (request.kind != Kind::BIND_ADVANCEMENT && request.kind != Kind::RESTORE_ADVANCEMENT &&
            bool(request.result.get("ok", false))) request.result["effective_day"] = day;
    if (request.command() == nullptr)
        std::atomic_store(&_published_era_advancement, make_view(state, input));
}

bool NativeSimulationHost::settle_player_regime(
        RuntimeEraAdvancement &state, int32_t regime, int64_t day) {
    if (regime < 0 || static_cast<size_t>(regime) >= state.regime_definitions.size() ||
        regime == state.observed_regime) return true;
    constexpr uint64_t source = 0x5245474d; // REGM
    constexpr uint32_t producer = 191;
    constexpr uint16_t domain = 1;
    constexpr int32_t scope = 2;
    const auto &desired = state.regime_definitions[regime];
    std::vector<int32_t> installed;
    std::vector<uint64_t> handles;
    for (const auto &row : _modifier_pod_authority.snapshot().entries) {
        if (row.modifier_handle != 0 && row.domain == domain && row.scope == scope &&
            row.entity_handle == state.country && row.source_type == source) {
            installed.push_back(row.definition_id);
            handles.push_back(row.modifier_handle);
        }
    }
    if (std::is_permutation(installed.begin(), installed.end(), desired.begin(), desired.end())) {
        state.observed_regime = regime;
        return true;
    }
    std::vector<RuntimeCommandPacket> commands;
    const auto add = [&](RuntimeModifierPodCommand command, RuntimeModifierPodOpcode opcode) {
        command.request_id = allocate_command_request_id_for_ingress();
        command.sequence = allocate_producer_sequence(producer);
        command.producer_id = producer;
        command.requested_day = day;
        command.effective_day = day;
        command.domain = domain;
        command.opcode = static_cast<uint16_t>(opcode);
        commands.push_back(encode_modifier_packet(command));
    };
    for (const uint64_t handle : handles) {
        RuntimeModifierPodCommand command;
        command.modifier_handle = handle;
        add(command, RuntimeModifierPodOpcode::REMOVE);
    }
    for (const int32_t id : desired) {
        RuntimeModifierPodCommand command;
        command.definition_id = id;
        command.scope = scope;
        command.entity_handle = state.country;
        command.target_generation = static_cast<uint32_t>(state.country >> 32);
        command.source_type = source;
        add(command, RuntimeModifierPodOpcode::APPLY);
    }
    if (!commands.empty() && !enqueue_batch_at(std::move(commands), nullptr, false)) return false;
    return true;
}

const char *NativeSimulationHost::stage_era_advancement(DayExecution &day) {
    if (!_era_advancement || !_economy_production_runtime) return nullptr;
    auto &state = *_era_advancement;
    auto &economy = *_economy_production_runtime;
    const auto *country = _country_pod_authority.borrow_state();
    const int32_t slot = country_slot(country, state.country);
    if (slot < 0) return nullptr;
    const auto summary = economy_api::era_advancement_economy_summary(economy, state.country);
    const EraInputs input{*country, slot, summary.get("population", 0), summary.get("building_units", 0),
        economy_api::country_procurement_snapshot(economy, state.country),
        reward_pending(*_effect_adapter_runtime)};
    const int64_t now = day.plan.context.day;
    if (!settle_player_regime(state, country->country_political_regime_ids[slot], now + 1))
        return "political_regime_modifier_enqueue_failed";
    const int64_t total = input.budget.get("trade_orders_total", -1);
    if (total >= 0) {
        if (state.last_trade_total >= 0 && total >= state.last_trade_total)
            state.trade += total - state.last_trade_total;
        state.last_trade_total = total;
    }
    const int32_t era = current_era(state, input);
    if (state.known_era < 0 || era > state.known_era) {
        if (state.known_era >= 0 && (state.phase == Phase::PURCHASING || state.phase == Phase::PAUSED))
            submit_target(economy, state, false, now + 1, state.next_sequence++);
        if (state.known_era >= 0) state.clear_purchase();
        state.known_era = era;
        if (state.trade_era != era) state.trade = 0;
        state.trade_era = era;
    }
    if (state.phase == Phase::COMPLETING) {
        const bool pending = input.has_technology(era_at(state, state.target).get("milestone", -1), true);
        constexpr int64_t COMPLETION_TIMEOUT = 5;
        if (!pending && state.completion_day >= 0 && now - state.completion_day > COMPLETION_TIMEOUT) {
            if (submit_target(economy, state, true, now + 1, state.next_sequence++)) {
                state.phase = Phase::PURCHASING;
                state.completion_day = -1;
            }
        }
    } else if (state.phase == Phase::PURCHASING) {
        // Preserve the dates of the previous committed-day consumer. Its
        // Economy target used D+1, and Country sealed that request for D+2.
        if (!state.prelude_granted &&
            (state.target != 1 || input.has_technology(era_at(state, 0).get("milestone", -1), true) ||
             submit_era_milestone(state, 0, now + 1, now + 2, state.next_sequence++, false)))
            state.prelude_granted = true;
        bool stocked = !state.required.is_empty();
        const Array basket = procurement_goods(state, state.target);
        for (int64_t i = 0; i < basket.size() && stocked; ++i) {
            const Dictionary row = basket[i];
            stocked = input.stock(row["index"]) >= state.required[i];
        }
        if (stocked && !input.reward_pending && prelude_complete(state, input, state.target) &&
            submit_era_milestone(state, state.target, now + 1, now + 2,
                                 state.next_sequence++, true)) {
            state.phase = Phase::COMPLETING;
            state.completion_day = now;
            submit_target(economy, state, false, now + 1, state.next_sequence++);
        }
    }
    _executor_day_tail->era_advancement = make_view(state, input);
    return nullptr;
}

} // namespace pk
