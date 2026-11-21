#include "country_api.h"
#include "economy_api.h"
#include "military_core.h"
#include "native_simulation_host.h"
#include "native_simulation_host_military.h"

#include <algorithm>
#include <godot_cpp/variant/string.hpp>

namespace pk {

void NativeMilitaryRuntime::resolve_training_units(
        const godot::Dictionary &source, MilitaryCommand &command) const {
    const auto frame = read();
    if (!frame) return;
    const auto &units = frame->view->catalog().units;
    const auto unit_index = [&](const char *key, int32_t numeric) {
        const godot::Variant value = source.get(key, numeric);
        if (value.get_type() != godot::Variant::STRING &&
            value.get_type() != godot::Variant::STRING_NAME) return numeric;
        const std::string id = godot::String(value).utf8().get_data();
        const auto found = std::find_if(units.begin(), units.end(),
            [&](const MilitaryUnitType &unit) { return unit.id == id; });
        return found == units.end() ? -1 : static_cast<int32_t>(found - units.begin());
    };
    command.unit_from = unit_index("unit_from", command.unit_from);
    command.unit_to = unit_index("unit_to", command.unit_to);
}

bool NativeMilitaryRuntime::resolve_config_shares(
        const godot::Dictionary &source, MilitaryCommand &command, std::string &error) const {
    if (!source.has("shares")) return true;
    const godot::Variant value = source["shares"];
    if (value.get_type() != godot::Variant::DICTIONARY) {
        error = "command_bad_shares";
        return false;
    }
    const auto frame = read();
    if (!frame && _runtime_host != nullptr && _runtime_host->military_executor_active()) {
        error = "military_executor_unavailable";
        return false;
    }
    const godot::Dictionary changes = value;
    const auto &units = (frame ? frame->view->catalog() : core().catalog()).units;
    command.ints.clear();
    for (size_t i = 0; i < units.size(); ++i) {
        const godot::String id(units[i].id.c_str());
        if (!changes.has(id)) continue;
        const godot::Variant share = changes[id];
        if (share.get_type() != godot::Variant::INT ||
            static_cast<int64_t>(share) < 0 || static_cast<int64_t>(share) > 10000) {
            error = "command_bad_share_bp";
            return false;
        }
        command.ints.push_back(static_cast<int32_t>(i));
        command.ints.push_back(static_cast<int32_t>(share));
    }
    if (changes.size() != static_cast<int64_t>(command.ints.size() / 2)) {
        error = "command_bad_unit";
        return false;
    }
    command.count = 1;
    return true;
}

void NativeMilitaryRuntime::queue_player_construction(MilitaryCommandBatch::Row &row) {
    const auto &command = row.command;
    if (_economy_runtime == nullptr || _runtime_host == nullptr || country_state == nullptr) {
        row.error = "military_executor_unavailable";
        return;
    }
    if (!core().validate_command(row.command, row.error)) return;
    const auto &building = core().catalog().state_buildings[command.unit_to];
    const int32_t type = building.economy_building_id;
    if (type < 0) {
        row.error = "military_state_building_unmapped";
        return;
    }
    const bool demolishing = command.op == MCMD_STATE_DEMOLISH;
    const auto country = static_cast<int64_t>(command.country);
    const godot::Dictionary queued = demolishing
        ? economy_api::queue_treasury_sponsored_demolish(*_economy_runtime, country,
            command.cell, type, 1, command.effective_day, row.caller_sequence, false, true)
        : economy_api::queue_treasury_sponsored_build(*_economy_runtime, country,
            command.cell, type, command.effective_day, row.caller_sequence, false, true);
    if (!static_cast<bool>(queued.get("ok", false))) {
        row.error = godot::String(queued.get("code", "command_rejected")).utf8().get_data();
        return;
    }
    ++_military_sequence;
}

const char *NativeMilitaryRuntime::preflight_construction(const RuntimeCountryPodSnapshot &state,
        uint64_t country, int32_t cell, int32_t type, bool demolishing,
        int64_t day, int32_t &building, int32_t &slot) const {
    const auto &buildings = core().catalog().state_buildings;
    const auto found = std::find_if(buildings.begin(), buildings.end(),
        [type](const MilitaryStateBuilding &row) { return row.economy_building_id == type; });
    if (found == buildings.end() || cell < 0 || cell >= core().terrain().cell_count)
        return "military_state_building_unmapped";
    building = static_cast<int32_t>(found - buildings.begin());
    slot = -1;
    if (demolishing) return nullptr;

    const int32_t bit = found->unlock_bit;
    if (bit >= 0) {
        const uint32_t country_slot = static_cast<uint32_t>(country);
        const int32_t tech = bit < static_cast<int32_t>(_military_unlock_tech_ids.size())
            ? _military_unlock_tech_ids[bit] : -1;
        if (country_slot >= state.country_count || tech < 0 ||
            tech >= static_cast<int32_t>(state.technology_count) ||
            (state.country_technologies[static_cast<size_t>(country_slot) *
                 state.technology_words + (tech >> 6)] & (uint64_t{1} << (tech & 63))) == 0)
            return "technology_locked";
    }
    // Reuse slots whose former order completes at this boundary. The core
    // expires those slots when it applies today's orders.
    const auto &states = core().cell_states();
    const auto state_row = std::lower_bound(states.begin(), states.end(), cell,
        [](const MilitaryCellState &row, int32_t key) { return row.cell < key; });
    const MilitaryCellState *cell_state =
        state_row == states.end() || state_row->cell != cell ? nullptr : &*state_row;
    const auto due_echoes = std::count_if(core()._pending.begin(), core()._pending.end(),
        [&](const MilitaryCommand &command) {
            return command.op == MCMD_STATE_BUILD && command.cell == cell &&
                command.effective_day <= day;
        });
    int32_t free_slots = 0;
    for (int32_t i = 0; i < MILITARY_STATE_BUILD_SLOTS; ++i) {
        if (cell_state == nullptr || cell_state->construction_building[i] < 0 ||
            (due_echoes == 0 && cell_state->construction_done_day[i] <= day)) {
            if (slot < 0) slot = i;
            ++free_slots;
        }
    }
    return free_slots > due_echoes ? nullptr : "military_construction_schedule_full";
}

void NativeMilitaryRuntime::commit_construction(
        int32_t cell, int32_t building, int32_t slot, int64_t day, int64_t ready_day) {
    if (slot >= 0) {
        MilitaryCellState &state = *core().cell_state(cell, true);
        state.construction_building[slot] = building;
        state.construction_done_day[slot] = ready_day;
    }
    if (_military_forced_run_day < 0 || day < _military_forced_run_day)
        _military_forced_run_day = day;
}

std::vector<MilitaryPlayerCommandRejection> NativeMilitaryRuntime::take_player_rejections() {
    return core().take_player_command_rejections();
}

} // namespace pk
