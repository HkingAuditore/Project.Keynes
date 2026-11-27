#include "runtime_narrative.h"

#include "runtime_events_authority.h"

#include <algorithm>
#include <utility>

namespace pk {
using namespace godot;

namespace {
constexpr int32_t MOBILIZATION_FACT = 18;
constexpr int32_t CAPITAL = 2;
constexpr int32_t INDEPENDENCE = 8;
constexpr int32_t IGNORE = 3;
constexpr int32_t ABANDON = 5;

String text(const std::string &value) { return String::utf8(value.c_str()); }
} // namespace

void RuntimeNarrative::queue_independence(int32_t cell, uint64_t owner) {
    for (const auto &item : _independence)
        if (item.cell == cell) return;
    _independence.push_back({cell, owner, _last_unrest_day,
        "rebel." + std::to_string(cell) + "." + std::to_string(_last_unrest_day)});
}

std::vector<NarrativeIndependenceAction> RuntimeNarrative::take_independence_actions() {
    return std::exchange(_independence_actions, {});
}

std::vector<int32_t> RuntimeNarrative::take_independence_clears() {
    return std::exchange(_independence_clears, {});
}

void RuntimeNarrative::advance_independence(const NarrativeDay &input) {
    std::vector<Independence> remaining;
    for (auto &item : _independence) {
        const uint64_t owner = input.owner(item.cell);
        if (owner != item.owner) {
            if (owner != 0) {
                _independence_actions.push_back({item.cell, item.owner, owner,
                    ++_unrest_sequence, {}, {}});
                if (item.owner == _country)
                    enqueue_notice(input, item.cell, 0, "stratum_unrest.independence", "独立建国");
            }
        } else if (input.day <= item.queued) {
            remaining.push_back(std::move(item));
        } else if (!item.submitted && input.territory_count(owner) > 1) {
            auto sample = input.sample(item.cell, false);
            if (sample.settlement.empty()) sample.settlement = "边地";
            _independence_actions.push_back({item.cell, item.owner, 0, ++_unrest_sequence,
                item.stable_id, sample.settlement + "自治"});
            item.submitted = true;
            remaining.push_back(std::move(item));
        } else if (!item.submitted) {
            // The last territory cannot leave the country. Cancel the request,
            // tell the player, and ask the host to clear the independence bit at
            // the next day's prepare boundary. The item is dropped: the city
            // stays with its current owner.
            if (item.owner == _country)
                enqueue_notice(input, item.cell, 0, "stratum_unrest.last_city_held",
                               "最后一城不能独立");
            if (std::find(_independence_clears.begin(), _independence_clears.end(),
                    item.cell) == _independence_clears.end())
                _independence_clears.push_back(item.cell);
        }
    }
    _independence = std::move(remaining);
}

void RuntimeNarrative::unrest(const NarrativeDay &input,
        const std::vector<RuntimeEventsRecord> &facts) {
    _last_unrest_day = input.day;
    std::vector<UnrestPending> stages;
    const auto stage = [&](int32_t cell, int32_t profession, int32_t value) {
        for (auto &item : stages) {
            if (item.cell == cell && item.profession == profession) {
                item.stage = value;
                return;
            }
        }
        stages.push_back({cell, profession, value, _country});
    };
    std::vector<NarrativeUnrestRow> rows;
    for (const auto &fact : facts) {
        if (fact.type != MOBILIZATION_FACT || fact.event_id <= _last_unrest_fact) continue;
        _last_unrest_fact = fact.event_id;
        const int32_t cell = fact.cell_idx;
        const int32_t profession = fact.payload_i2;
        if (cell < 0 || profession < 0) continue;
        const auto owner = input.owner(cell);
        if (owner == 0 || int32_t(owner) != fact.payload_i3) continue;
        if ((fact.flags & INDEPENDENCE) != 0) {
            const auto pending_independence = [&] {
                if (!input.unrest_rows(cell, rows)) return false;
                return std::any_of(rows.begin(), rows.end(), [&](const auto &row) {
                    return row.profession == profession && (row.flags & INDEPENDENCE) != 0;
                });
            };
            if (!_recover_unrest || pending_independence()) queue_independence(cell, owner);
        } else if (owner == _country && !_recover_unrest && !(fact.flags & CAPITAL) &&
                   fact.payload_i0 > fact.payload_i1) {
            stage(cell, profession, fact.payload_i0);
        }
    }
    if (_recover_unrest && input.country.slot >= 0) {
        _recover_unrest = false;
        for (const int32_t cell : input.country.territory) {
            if (cell == input.country.capital) continue;
            if (!input.unrest_rows(cell, rows)) {
                _recover_unrest = true;
                continue;
            }
            for (const auto &row : rows) {
                if (row.flags & INDEPENDENCE) queue_independence(cell, _country);
                else if (row.stage > 0 && row.profession >= 0 && row.cooldown <= input.day)
                    stage(cell, row.profession, row.stage);
            }
        }
    }

    auto checks = std::move(_unrest_checks);
    _unrest_checks.clear();
    for (const auto &check : checks) {
        if (check.owner != _country || check.owner != input.owner(check.cell)) continue;
        if (!input.unrest_rows(check.cell, rows)) {
            _unrest_checks.push_back(check);
            continue;
        }
        for (const auto &row : rows) {
            if (row.profession != check.profession) continue;
            if (row.flags & INDEPENDENCE) queue_independence(check.cell, check.owner);
            else if (row.stage > check.stage) stage(check.cell, check.profession, row.stage);
            else _unrest_checks.push_back(check);
            break;
        }
    }

    advance_independence(input);
    for (const auto &item : stages) {
        const std::string chain = "rebellion:" + std::to_string(item.cell) + ":" +
            std::to_string(item.profession);
        const auto same = [&](const Dictionary &offer) {
            const Dictionary meta = offer.get("meta", Dictionary());
            return narrative_key(offer.get("chain_id", "")) == chain &&
                int32_t(meta.get("stage", 0)) == item.stage;
        };
        if (same(_active) || std::any_of(_queue.begin(), _queue.end(), same)) continue;
        const int32_t stage_index = std::clamp(item.stage, 1, 4) - 1;
        const auto &actions = _catalog.unrest_actions[stage_index];
        Array probabilities, costs, action_list;
        for (int32_t action : actions) {
            const auto odds = input.unrest_odds(item.cell, item.profession, action);
            const int32_t probability = action == IGNORE ? 0 : action == ABANDON ? 65536 : odds.probability;
            PackedInt32Array pair;
            pair.push_back(probability);
            pair.push_back(65536 - probability);
            probabilities.push_back(pair);
            costs.push_back(odds.cost_bp);
            action_list.push_back(action);
        }
        const std::string profession = size_t(item.profession) < input.professions.size()
            ? input.professions[item.profession] : std::string();
        const int32_t variant = profession == "soldier" ? 1 : profession == "merchant" ? 2 : 0;
        Dictionary meta;
        meta["kind"] = "rebellion";
        meta["cell"] = item.cell;
        meta["profession"] = item.profession;
        meta["stage"] = item.stage;
        meta["owner_handle"] = static_cast<int64_t>(_country);
        meta["actions"] = action_list;
        meta["cost_bps"] = costs;
        meta["profession_name"] = _catalog.unrest_profession_names.get(text(profession),
            profession.empty() ? String::utf8("本地阶层") : text(profession));
        const uint64_t salt = narrative_hash(_seed, input.day, _country, item.cell,
            item.profession * 31 + item.stage) & 0x7fffffff;
        enqueue(_catalog.unrest[variant][stage_index], input, item.cell, chain, true,
            meta, salt, probabilities);
    }
}

void RuntimeNarrative::finish_unrest_choice(bool applied, bool independence_pending, int64_t day) {
    const Dictionary meta = _choice_record.get("meta", Dictionary());
    if (!applied || String(meta.get("kind", "")) != "rebellion") return;
    const int32_t cell = meta.get("cell", -1);
    const int32_t profession = meta.get("profession", -1);
    const int32_t stage = meta.get("stage", 1);
    const uint64_t owner = int64_t(meta.get("owner_handle", 0));
    const int32_t option = _choice_record.get("chosen_option_index", -1);
    const Array actions = meta.get("actions", Array());
    if (option < 0 || option >= actions.size()) return;
    const bool success = int64_t(_choice_record.get("rolled_outcome_index", 1)) == 0;
    // Economy owns the independence transition. Narrative only consumes the
    // committed flag returned after the action has been applied.
    if (independence_pending) {
        _last_unrest_day = day;
        queue_independence(cell, owner);
    }
    else if (!success) _unrest_checks.push_back({cell, profession, stage, owner});
}
} // namespace pk
