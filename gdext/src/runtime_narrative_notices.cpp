#include "runtime_narrative.h"

#include "military_bridge.h"
#include "runtime_events_authority.h"

#include <algorithm>

namespace pk {
using namespace godot;

namespace {

struct NoticeDefinition {
    int32_t fact;
    int32_t category;
    const char *id;
    const char *title;
};

constexpr NoticeDefinition NOTICES[] = {
    {1, 3, "vegetation.succession", "植被演替"},
    {2, 3, "terrain.flip", "地形变化"},
    {3, 3, "weather.front_changed", "天气锋面变化"},
    {6, 5, "economy.construction_settled", "营造完工"},
    {7, 4, "economy.trade_arrived", "贸易到货"},
    {8, 0, "economy.social_pressure", "民生压力变化"},
    {9, 6, "country.research_signal_discovered", "科研线索发现"},
    {10, 3, "map.feature_discovered", "地貌发现"},
    {11, 3, "weather.observed", "天气观测"},
    {12, 6, "country.research_evidence_changed", "科研证据变化"},
    {13, 6, "country.research_completed", "科技采纳"},
    {14, 6, "country.technology_practice", "科技实践"},
    {15, 4, "economy.tariff_subsidy_intent", "关税与补贴记账"},
    {18, 0, "unrest.stage.0", "动荡平息"},
    {MILITARY_EVENT_WAR_DECLARED, 1, "military.war_declared.player_attacker", "本国宣战"},
    {MILITARY_EVENT_WAR_ENDED, 1, "military.war_ended", "战争结果"},
    {MILITARY_EVENT_BATTLE_RESOLVED, 1, "military.battle_resolved", "战斗结算"},
    {MILITARY_EVENT_CELL_CONTROL_CHANGED, 1, "military.cell_control_changed", "领土控制权变化"},
    {MILITARY_EVENT_ARMY_DESTROYED, 1, "military.army_destroyed", "部队被歼"},
    {MILITARY_EVENT_COUNTRY_ANNEXED, 1, "military.country_annexed", "吞并"},
    {MILITARY_EVENT_CONVOY_INTERCEPTED, 1, "military.convoy_intercepted", "运输队被截获"},
    {MILITARY_EVENT_LEVY_APPLIED, 1, "military.levy_applied", "征召结算"},
};

bool concerns_player(const NarrativeDay &input, const RuntimeEventsRecord &row) {
    const auto &country = input.country;
    if (country.slot < 0) return false;
    switch (row.type) {
    case MILITARY_EVENT_WAR_ENDED:
        return std::find(country.wars.begin(), country.wars.end(), row.payload_i2) != country.wars.end();
    case MILITARY_EVENT_CELL_CONTROL_CHANGED:
        if (row.payload_i2 == country.slot) return true;
        [[fallthrough]];
    case MILITARY_EVENT_WAR_DECLARED:
    case MILITARY_EVENT_BATTLE_RESOLVED:
    case MILITARY_EVENT_ARMY_DESTROYED:
    case MILITARY_EVENT_CONVOY_INTERCEPTED:
        return row.payload_i0 == country.slot || row.payload_i1 == country.slot;
    case MILITARY_EVENT_COUNTRY_ANNEXED:
        return row.entity_handle == country.handle || row.payload_i1 == country.slot;
    case MILITARY_EVENT_LEVY_APPLIED:
        return row.payload_i0 == country.slot;
    case 7: // Trade arrival names the exporter and importer in these slots.
        return row.payload_i1 == country.slot || row.payload_i2 == country.slot;
    default:
        return row.entity_handle == country.handle ||
            (row.cell_idx >= 0 && input.owner(row.cell_idx) == country.handle);
    }
}

} // namespace

void RuntimeNarrative::enqueue_notice(const NarrativeDay &input, int32_t cell, int32_t category,
        const char *id, const char *title) {
    if ((_pause_mask & (1u << (8 + category))) == 0) return;
    const auto sampled = input.sample(cell, false);
    const String name = String::utf8(sampled.settlement.c_str());
    const String headline = String::utf8(title);
    Dictionary option;
    option["text"] = String::utf8("确认");
    option["eligible"] = true;
    Array options;
    options.push_back(option);
    const int64_t offer_id = (int64_t{1} << 51) | ++_notification_sequence;
    Dictionary offer;
    offer["offer_id"] = offer_id;
    offer["offer_generation"] = offer_id;
    offer["event_id"] = id;
    offer["status"] = "OPEN";
    offer["cell_idx"] = cell;
    offer["settlement_name"] = name;
    offer["day"] = input.day;
    offer["date_text"] = date_text(input.day);
    offer["title"] = headline;
    offer["body_text"] = name.is_empty() ? headline : name + String::utf8(" · ") + headline;
    offer["bypass_pacing"] = true;
    offer["event_category"] = category;
    offer["event_notification"] = true;
    offer["notice_only"] = true;
    offer["options"] = options;
    _queue.push_back(offer);
}

void RuntimeNarrative::fact_notices(const NarrativeDay &input,
        const std::vector<RuntimeEventsRecord> &facts) {
    if (_last_notice_era >= 0 && input.country.era > _last_notice_era)
        enqueue_notice(input, input.country.capital, 7, "country.era_promoted", "时代晋升");
    _last_notice_era = input.country.era;
    for (const auto &row : facts) {
        if (row.event_id <= _last_notification_fact) continue;
        _last_notification_fact = row.event_id;
        if (_pause_mask <= 0xff) continue;
        if (!concerns_player(input, row)) continue;
        if (row.type == 18 && row.payload_i0 != 0) continue; // Escalations have their own choices.
        if (row.type == MILITARY_EVENT_WAR_DECLARED && row.payload_i1 == input.country.slot) {
            enqueue_notice(input, row.cell_idx, 1, "military.war_declared.player_defender", "对玩家宣战");
            continue;
        }
        for (const auto &rule : NOTICES) {
            if (rule.fact != row.type) continue;
            enqueue_notice(input, row.cell_idx, rule.category, rule.id, rule.title);
            break;
        }
    }
}

void RuntimeNarrative::economy_notices(const NarrativeDay &input,
        const std::vector<NarrativeEconomyNotice> &rows) {
    using Kind = NarrativeEconomyNotice;
    for (const auto &row : rows) {
        switch (row.kind) {
        case Kind::CONSTRUCTION:
            enqueue_notice(input, row.cell, 5, "economy.construction_settled", "营造回执");
            break;
        case Kind::INFRASTRUCTURE:
            enqueue_notice(input, row.cell, 5, "economy.infrastructure_settled", "基建回执");
            break;
        case Kind::COLONIZATION:
            enqueue_notice(input, row.cell, 2, "economy.family_colonization_settled", "家族开拓回执");
            break;
        case Kind::POPULATION:
            if (input.owner(row.cell) == input.country.handle)
                enqueue_notice(input, row.cell, 5, "economy.population_changed", "人口增减");
            break;
        }
    }
    promote(input.day);
}

} // namespace pk
