#include "runtime_narrative_context.h"
// Military bridge (owner: B). Godot <-> pk::MilitaryCore.
//
// Military reads the committed day-D view of Country and Economy and updates its own
// store, and emits intent rows that are submitted to Country/Economy through
// their existing command batches with effective day D+1. Receipts come back the
// next military day. Military never writes another domain's state directly.
//
// ---------------------------------------------------------------------------
// `configure_military(catalog, seed)` — catalog keys (contract §3)
// ---------------------------------------------------------------------------
// The GDScript `MilitaryCatalogCompiler` has already resolved every stable
// string id to a dense id and sorted `units` by stable id, so this file only
// converts scales:
//
//   schema                : int, must be 1
//   militia_unit_index    : int, optional; fallback for the militia lookup
//   units[]               : Array[Dictionary]
//       id                : String  (stable id, ascending; PKMI identity)
//       class             : int     0 line, 1 mobile, 2 artillery
//       militia           : bool    exactly one unit must be true
//       era               : int     0..10
//       unlock_bit        : int     index into unlock_tech_ids, -1 = always
//       attack, defense, speed, fortification_ignore : float
//                         -> q16 (65536 == 1.0; fortification_ignore 0..1)
//       training_days     : int
//       equipment[]       : Array[Dictionary] (max 4)
//           category      : int      dense equipment category index
//           min_quality   : int      1..5
//           per_100       : float    goods units per 100 heads -> GOODS_SCALE
//           weight        : float    -> q16 power weight
//       supply_idle       : PackedFloat32Array(6), goods per 100 heads / day
//       supply_combat     : PackedFloat32Array(6), extra goods per 100 / day
//         index order (ABI): 0 ration, 1 fodder, 2 ammunition, 3 fuel,
//                            4 upkeep, 5 equipment
//         -> MILITARY_GOODS_SCALE per 100 heads per day
//   categories[]          : Array[Dictionary]
//       id                : String
//       goods             : PackedInt32Array   dense good ids, quality asc
//       qualities         : PackedInt32Array   matching 1..5 quality levels
//   state_buildings[]     : Array[Dictionary]
//       id, economy_building_id (dense type, -1 unknown), role (0 barracks,
//       1 fortification, 2 war_college), tier, unlock_bit, capacity,
//       fort_bonus (float -> q16), training_speed (float -> q16),
//       upkeep (money/day -> MONEY_SCALE), build_days,
//       material_goods (PackedInt32Array), material_qty (PackedInt64Array,
//       GOODS_SCALE, parallel)
//   supply_goods          : Array(6) of PackedInt32Array (dense good ids)
//   supply_yield_q16      : Array(6) of PackedInt32Array (q16 per unit good)
//   unlock_tech_ids       : PackedInt32Array (dense technology id per bit)
//   economy_good_count    : int
//   soldier_profession_id : int
//   unemployed_profession_id : int
//   ration_need_per_head  : float need units per head/day -> q16
//
// `set_military_terrain` keys: cell_count, width, height, neighbors
// (PackedInt32Array, cell_count * 6), landform, vegetation, cover, is_water,
// has_river, settlement_tier (PackedByteArray per cell).
//
// Command `op` strings: kMilitaryOps below. Each row may also carry
// `int_pairs` (PackedInt32Array of (unit, count) pairs) as the facade's
// pre-normalized form of `units`.
// ---------------------------------------------------------------------------

#include "world_ext.h"

#include "country_api.h"
#include "economy_api.h"
#include "military_core.h"
#include "modifier_api.h"
#include "native_simulation_host.h"
#include "native_simulation_host_military.h"
#include "world_ext_internal_military_intents.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <climits>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace pk {

void sample_narrative_military_country(const MilitaryCore &core, NarrativeCountryView &out) {
    const int32_t slot = core.country_slot_for_handle(out.handle);
    if (slot < 0) return;
    out.military_available = true;
    out.soldiers = core.country_soldiers(slot);
    const auto &armies = core.armies();
    for (size_t army = 0; army < armies.active.size(); ++army)
        if (armies.active[army] && armies.owner_slot[army] == slot)
            out.soldiers_in_armies += armies.cached_headcount[army];
    for (const auto &war : core.wars()) {
        if (war.attacker_handle != out.handle && war.defender_handle != out.handle) continue;
        out.wars.push_back(war.id);
        if (!war.active) continue;
        const int32_t score = war.score_battle_q16 + war.score_annihilation_q16 + war.score_attrition_q16;
        ++out.war_count;
        out.war_score = std::min<int64_t>(out.war_score, war.attacker_slot == slot ? score : -score);
        out.war_losses += war.attacker_losses + war.defender_losses;
    }
    out.at_war = out.war_count > 0;
}



using namespace godot;

NativeMilitaryRuntime::NativeMilitaryRuntime() : _core(std::make_unique<MilitaryCore>()) {}
NativeMilitaryRuntime::~NativeMilitaryRuntime() = default;

std::vector<int32_t> NativeMilitaryRuntime::vision_sources(int32_t country_slot) const {
    std::vector<int32_t> cells;
    if (country_slot < 0) return cells;
    const auto &armies = core().armies();
    for (size_t i = 0; i < armies.active.size(); ++i)
        if (armies.active[i] && armies.owner_slot[i] == country_slot && armies.cell[i] >= 0)
            cells.push_back(armies.cell[i]);
    std::sort(cells.begin(), cells.end());
    cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
    return cells;
}

std::vector<int32_t> NativeMilitaryRuntime::take_vision_trail(int32_t country_slot) {
    auto cells = core().exploration_trail(country_slot);
    if (!cells.empty()) core().clear_exploration_trail(country_slot);
    return cells;
}

void NativeMilitaryRuntime::prepare_exploration(int32_t player_slot,
        const std::vector<uint8_t> &explored, int64_t day, uint64_t revision) {
    if (player_slot >= 0 && core().has_exploration_work())
        core().set_exploration_view(player_slot, explored.data(), explored.size(), day, revision);
}

void NativeMilitaryRuntime::publish(godot::Dictionary report) {
    auto frame = std::make_shared<Published>();
    frame->view = std::make_shared<MilitaryCore>(core());
    frame->archive = encode();
    frame->state_hash = static_cast<int64_t>(core().state_hash() & 0x7fffffffffffffffll);
    frame->last_step_day = _military_last_step_day;
    frame->executor_day = _military_last_background_day;
    frame->sequence = _military_sequence;
    frame->pending_intents = static_cast<int64_t>(_military_pending_intents.size());
    frame->revision = _military_render_revision;
    frame->event_cursor = event_cursor;
    frame->event_tick = event_tick;
    frame->events_forwarded = events_forwarded;
    if (_economy_runtime != nullptr) {
        frame->lane_supported = true;
        frame->lane_pay_supported = economy_api::military_army_lane_pay_supported(*_economy_runtime);
        const auto &armies = core().armies();
        frame->lane_population.assign(armies.active.size(), -1);
        frame->lane_funds.assign(armies.active.size(), -1);
        for (size_t index = 0; index < armies.active.size(); ++index) {
            if (!armies.active[index]) continue;
            const auto handle = core().army_handle(static_cast<int32_t>(index));
            frame->lane_population[index] = economy_api::military_army_population(*_economy_runtime, handle);
            frame->lane_funds[index] = economy_api::military_army_funds(*_economy_runtime, handle);
        }
    }
    frame->result = std::move(report);
    std::atomic_store_explicit(&_published, std::shared_ptr<const Published>(std::move(frame)),
        std::memory_order_release);
}

std::shared_ptr<const NativeMilitaryRuntime::Published> NativeMilitaryRuntime::read() const {
    return std::atomic_load_explicit(&_published, std::memory_order_acquire);
}

bool NativeMilitaryRuntime::forward_events(int64_t day, DCWorldExt *legacy) {
    for (;;) {
        const auto events = core().events_after(static_cast<uint64_t>(event_cursor), 256u);
        if (events.empty()) return true;
        for (size_t begin = 0; begin < events.size(); begin += RUNTIME_EVENTS_MAX_BATCH_RECORDS) {
            const size_t end = std::min(events.size(), begin + RUNTIME_EVENTS_MAX_BATCH_RECORDS);
            std::vector<RuntimeEventsRecord> records;
            records.reserve(end - begin);
            for (size_t i = begin; i < end; ++i) {
                const auto &event = events[i];
                auto &record = records.emplace_back();
                if (!legacy) record.event_id = _runtime_host->allocate_events_ingress_key();
                record.tick = event.day;
                record.type = std::clamp<int32_t>(event.type, 40, 47);
                record.source = 5;
                record.entity_id = static_cast<int32_t>(event.i0);
                record.entity_handle = event.i0;
                record.cell_idx = event.cell;
                record.payload_schema = event.payload_schema;
                record.value_i64 = event.value;
                record.payload_i0 = static_cast<int32_t>(event.i0);
                record.payload_i1 = static_cast<int32_t>(event.i1);
                record.payload_i2 = static_cast<int32_t>(event.i2);
                record.payload_i3 = static_cast<int32_t>(event.i3);
            }
            if (legacy) {
                if (!legacy->publish_legacy_military_events(records)) return false;
            } else {
                std::string error;
                if (!_runtime_host->enqueue_legacy_event_batch(
                        records, day + 1, _runtime_host->report().generation + 1, error))
                    return false;
            }
            events_forwarded += static_cast<int64_t>(records.size());
            event_cursor = static_cast<int64_t>(events[end - 1].id);
            event_tick = events[end - 1].day;
        }
    }
}

const char *NativeMilitaryRuntime::prepare_day(const RuntimeEnvironmentSnapshot &environment) {
    // Military terrain changes at the seasonal refresh boundary. Daily weather
    // also changes cover, but those changes never refreshed military costs.
    if (!environment.climate_season_refresh_ran) return nullptr;
    const auto &current = core().terrain();
    const size_t count = static_cast<size_t>(current.cell_count);
    const auto &landform = environment.military_base_landform.empty() ? current.landform : environment.military_base_landform;
    const auto &tiers = environment.military_settlement_tier.empty() ? current.settlement_tier : environment.military_settlement_tier;
    if (environment.cover.size() != count || environment.vegetation.size() != count ||
        environment.is_water.size() != count || landform.size() != count || tiers.size() != count)
        return "military_season_terrain_shape_invalid";
    if (current.cover == environment.cover && current.vegetation == environment.vegetation &&
        current.landform == landform && current.settlement_tier == tiers &&
        current.is_water == environment.is_water) return nullptr;
    auto terrain = current;
    terrain.cover = environment.cover;
    terrain.vegetation = environment.vegetation;
    terrain.landform = landform;
    terrain.settlement_tier = tiers;
    terrain.is_water = environment.is_water;
    std::string error;
    return core().set_terrain(std::move(terrain), error) ? nullptr : "military_season_terrain_invalid";
}

std::vector<uint8_t> NativeMilitaryRuntime::capture_terrain() const {
    const auto &terrain = core().terrain();
    std::vector<uint8_t> bytes;
    bytes.reserve(static_cast<size_t>(terrain.cell_count) * 5);
    for (const auto *lane : {&terrain.landform, &terrain.vegetation, &terrain.cover,
                            &terrain.is_water, &terrain.settlement_tier})
        bytes.insert(bytes.end(), lane->begin(), lane->end());
    return bytes;
}

bool NativeMilitaryRuntime::restore_terrain(const std::vector<uint8_t> &bytes, std::string &error) {
    const size_t cells = static_cast<size_t>(core().terrain().cell_count);
    if (bytes.size() != cells * 5) {
        error = "military_terrain_checkpoint_size_invalid";
        return false;
    }
    auto terrain = core().terrain();
    auto next = bytes.begin();
    for (auto *lane : {&terrain.landform, &terrain.vegetation, &terrain.cover,
                      &terrain.is_water, &terrain.settlement_tier}) {
        lane->assign(next, next + cells);
        next += cells;
    }
    return core().set_terrain(std::move(terrain), error);
}


#include "world_ext_military_section_bridge_helpers.inc"

// ===========================================================================
// lifecycle
// ===========================================================================

bool NativeMilitaryRuntime::should_run(int64_t day) const {
    const auto *core = &this->core();
    if (!core->configured()) return false;
    // One step per day and never backwards: re-running a day would submit its
    // D+1 intents twice.
    if (day <= _military_last_step_day) return false;
    // A submitted command must always get its day stepped, even when the core
    // would otherwise idle (no policy yet -> should_run false -> deadlock).
    if (_military_forced_run_day >= 0 && day >= _military_forced_run_day) return true;
    // Outstanding bridge rows (a POD population move, a treasury spend awaiting
    // its receipt) can only be settled inside a military day. If the core looks
    // idle while a row is still open, refusing to step deadlocks the row forever
    // (observed: last_step_day frozen at 70 while pending_intents stayed 3).
    for (const MilitaryPendingIntent &row : _military_pending_intents) {
        if (row.receipt_pending == 1) return true;
    }
    return core->should_run(day);
}

int32_t NativeMilitaryRuntime::ensure_military_country_slots() {
    if (country_state == nullptr && _country_runtime == nullptr) return 0;
    CountryEconomySnapshot snapshot;
    if (country_state == nullptr && !country_api::copy_economy_snapshot(*_country_runtime, snapshot)) return 0;
    int32_t active = 0;
    const size_t size = country_state ? country_state->country_active.size()
        : snapshot.country_handles.size();
    for (size_t slot = 0; slot < size; ++slot) {
        const uint64_t handle = country_state ?
            (country_state->country_active[slot] != 0 ?
                (uint64_t(country_state->country_generation[slot]) << 32) | slot : 0)
            : snapshot.country_handles[slot];
        if (handle == 0) continue;
        core().ensure_country_slot(handle);
        ++active;
    }
    return active;
}

Dictionary DCWorldExt::configure_military(const Dictionary &catalog, int64_t seed) {
    if (military_executor_active()) return military_fail("military_executor_owns_state");
    MilitaryCatalog parsed;
    std::string error;
    if (!parse_catalog(catalog, parsed, error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    if (!_military) _military = std::make_shared<NativeMilitaryRuntime>();
    bind_military_dependencies();
    MilitaryCore *core = &_military->core();
    // A catalog reconfiguration must not lose the map: configure() resets the
    // state but keeps the previous terrain, so the same input is reinstalled.
    const MilitaryTerrainInput keep = core->terrain();
    if (!core->configure(std::move(parsed), static_cast<uint64_t>(seed), error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    // Dense technology id per unlock bit, captured once so the daily digest only
    // needs one has_technology() probe per referenced technology.
    _military->_military_unlock_tech_ids = dict_i32_array(catalog, "unlock_tech_ids");
    if (keep.cell_count > 0) {
        std::string terrain_error;
        core->set_terrain(keep, terrain_error);
    }
    _military->_military_last_step_day = -1;
    _military->_military_last_background_day = -1;
    _military->_military_sequence = 0;
    _military->_military_pending_intents.clear();
    _military->_military_forced_run_day = -1;
    _military->_military_economy_event_cursor = -1;
    _military->_military_economy_seen_day = -1;
    _military_render_selected_army = 0;
    if (_military->_military_receipts) _military->_military_receipts->after_request_id = 0;
    // Open a slot for every active country now, so commands submitted before
    // the first stepped military day resolve their issuing country.
    const int32_t countries_opened = _military->ensure_military_country_slots();
    ++_military->_military_render_revision;
    const MilitaryCatalog &configured = core->catalog();
    Dictionary out;
    out["ok"] = true;
    out["reason"] = String();
    out["countries_opened"] = static_cast<int64_t>(countries_opened);
    out["catalog_hash"] = static_cast<int64_t>(configured.hash);
    out["unit_count"] = static_cast<int64_t>(configured.units.size());
    out["category_count"] = static_cast<int64_t>(configured.categories.size());
    out["state_building_count"] = static_cast<int64_t>(configured.state_buildings.size());
    out["unlock_count"] = static_cast<int64_t>(configured.unlock_count);
    out["militia_unit"] = static_cast<int64_t>(configured.militia_unit);
    out["seed"] = seed;
    return out;
}

Dictionary DCWorldExt::set_military_terrain(const Dictionary &terrain) {
    if (military_executor_active()) return military_fail("military_executor_owns_state");
    if (!_military) return military_unavailable();
    MilitaryTerrainInput input;
    input.cell_count = dict_i32(terrain, "cell_count", -1);
    input.width = dict_i32(terrain, "width", 0);
    input.height = dict_i32(terrain, "height", 0);
    input.neighbors = dict_i32_array(terrain, "neighbors");
    input.landform = dict_u8_array(terrain, "landform");
    input.vegetation = dict_u8_array(terrain, "vegetation");
    input.cover = dict_u8_array(terrain, "cover");
    input.is_water = dict_u8_array(terrain, "is_water");
    input.has_river = dict_u8_array(terrain, "has_river");
    input.settlement_tier = dict_u8_array(terrain, "settlement_tier");
    std::string error;
    if (!_military->core().set_terrain(std::move(input), error)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    // Size the reusable digest lanes once per terrain, so the daily capture only
    // fills them and never allocates.
    const int32_t cells = std::max(0, _military->core().terrain().cell_count);
    auto &scratch = _military->_military_digest_scratch;
    scratch.cell_population.assign(static_cast<size_t>(cells), 0);
    scratch.cell_unemployed.assign(static_cast<size_t>(cells), 0);
    scratch.cell_soldiers.assign(static_cast<size_t>(cells), 0);
    scratch.cell_has_merchant.assign(static_cast<size_t>(cells), 0);
    scratch.country_cash.clear();
    scratch.country_annual_revenue.clear();
    scratch.country_unlock_bits.clear();
    scratch.country_stat_q16.clear();
    ++_military->_military_render_revision;
    Dictionary out;
    out["ok"] = true;
    out["reason"] = String();
    out["cell_count"] = static_cast<int64_t>(cells);
    out["width"] = static_cast<int64_t>(_military->core().terrain().width);
    out["height"] = static_cast<int64_t>(_military->core().terrain().height);
    return out;
}

bool DCWorldExt::military_executor_active() const {
    return _military && _runtime_host && _runtime_host->military_executor_active();
}

void DCWorldExt::bind_military_dependencies() {
    _military->country_state = nullptr;
    _military->_runtime_host = _runtime_host.get();
    _military->_country_runtime = static_cast<NativeCountryRuntime *>(_country_runtime);
    _military->_economy_runtime = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    _military->_modifier_runtime = static_cast<ModifierRuntime *>(_modifier_runtime);
}

std::shared_ptr<const MilitaryCore> DCWorldExt::read_military_core() const {
    if (!_military) return {};
    if (military_executor_active()) {
        if (const auto frame = _military->read()) return frame->view;
    }
    return std::shared_ptr<const MilitaryCore>(_military, &_military->core());
}

bool DCWorldExt::military_should_run(int64_t day) const {
    return _military && !military_executor_active() && _military->should_run(day);
}

Dictionary DCWorldExt::run_military_daily(const Dictionary &ctx) {
    if (!_military) return military_unavailable();
    if (military_executor_active()) return military_fail("military_executor_owns_state");
    bind_military_dependencies();
    const int64_t day = dict_i64(ctx, "day_index", -1);
    auto report = _military->run_day(day);
    const auto events_before = _military->events_forwarded;
    if (!_military->forward_events(day, this))
        return military_fail("military_events_submission_failed");
    report["events_forwarded"] = _military->events_forwarded - events_before;
    return report;
}

Dictionary DCWorldExt::run_military_catch_up(const Dictionary &ctx) {
    if (!_military) return military_unavailable();
    if (military_executor_active()) return military_fail("military_executor_owns_state");
    const int64_t day = dict_i64(ctx, "day_index", -1);
    Dictionary out;
    if (day < 0) return military_fail("military_day_invalid");
    // Both executors share the guard, including callers using catch_up.
    if (day <= _military->_military_last_step_day) {
        out["ok"] = true;
        out["path"] = "native_military_catch_up";
        out["skipped"] = true;
        out["reason"] = "military_day_already_stepped";
        out["day_index"] = day;
        return out;
    }
    return run_military_daily(ctx);
}

bool NativeMilitaryRuntime::submit(MilitaryCommand command, std::string &error) {
    command.sequence = static_cast<uint64_t>(++_military_sequence);
    if (command.country != 0 && core().country_slot_for_handle(command.country) < 0)
        ensure_military_country_slots();
    const auto day = command.effective_day;
    if (!core().submit(std::move(command), error)) return false;
    if (_military_forced_run_day < 0 || day < _military_forced_run_day)
        _military_forced_run_day = day;
    return true;
}

bool NativeMilitaryRuntime::submit_independence(
        uint64_t old_owner, uint64_t new_owner, int32_t cell, int64_t day) {
    const bool created = core().country_slot_for_handle(new_owner) < 0;
    ensure_military_country_slots();
    if (created) core().set_ai_country(core().country_slot_for_handle(new_owner), true);
    MilitaryCommand command;
    command.op = MCMD_WAR_DECLARE_FORCED;
    command.country = old_owner;
    command.other = new_owner;
    command.effective_day = day;
    std::string error;
    if (!submit(command, error)) return false;
    command.op = MCMD_GARRISON_TRANSFER_CELL;
    command.cell = cell;
    return submit(std::move(command), error);
}

bool NativeMilitaryRuntime::stamp_commands(MilitaryCommandBatch &batch) const {
    const auto frame = read();
    bool accepted = false;
    for (auto &row : batch.rows) {
        if (!row.error.empty()) continue;
        row.effective_day = std::max(row.command.effective_day, batch.day);
        row.command.effective_day = row.effective_day;
        if (row.caller_sequence > 0) accepted = true;
        else if (!frame) row.error = "military_executor_unavailable";
        else if (frame->view->validate_command(row.command, row.error)) accepted = true;
    }
    return accepted;
}

void NativeMilitaryRuntime::admit(MilitaryCommandBatch &batch) {
    for (auto &row : batch.rows) {
        if (!row.error.empty()) continue;
        row.effective_day = std::max(row.command.effective_day, batch.day);
        row.command.effective_day = row.effective_day;
        if (row.caller_sequence > 0 &&
            (row.command.op == MCMD_STATE_BUILD || row.command.op == MCMD_STATE_DEMOLISH)) {
            queue_player_construction(row);
        } else {
            submit(std::move(row.command), row.error);
        }
    }
    batch.sequence = _military_sequence;
}

Dictionary DCWorldExt::submit_military_commands(const Array &batch) {
    if (!_military) return military_unavailable();
    auto request = std::make_shared<MilitaryCommandBatch>();
    request->rows.reserve(batch.size());
    for (int64_t i = 0; i < batch.size(); ++i) {
        auto &row = request->rows.emplace_back();
        row.index = i;
        if (batch[i].get_type() != Variant::DICTIONARY) {
            row.error = "military_command_not_object";
        } else {
            const Dictionary source = batch[i];
            if (parse_military_command(source, row.command, row.error)) {
                row.command_name = std::string("military.") + String(source["op"]).utf8().get_data();
                row.caller_sequence = source.get("caller_sequence", 0);
                if (row.command.op == MCMD_POLICY_SET_BUDGET ||
                        row.command.op == MCMD_POLICY_SET_PROCUREMENT)
                    row.command.count = row.caller_sequence;
                if (row.command.op == MCMD_TRAIN || row.command.op == MCMD_ARMY_CREATE ||
                    row.command.op == MCMD_ARMY_MOVE || row.command.op == MCMD_ARMY_AREA_CONTROL ||
                    row.command.op == MCMD_ARMY_EXPLORE) {
                    row.command.value = row.caller_sequence;
                }
                if (row.command.op == MCMD_TRAIN && row.caller_sequence > 0)
                    _military->resolve_training_units(source, row.command);
                if (row.command.op == MCMD_CONFIG_SET && source.has("shares")) {
                    row.command.value = row.caller_sequence;
                    _military->resolve_config_shares(source, row.command, row.error);
                }
            }
        }
    }
    const bool executor_owned = military_executor_active();
    if (executor_owned) {
        if (!_runtime_host->submit_military_commands(request))
            return military_fail("military_executor_unavailable");
    } else {
        bind_military_dependencies();
        request->day = _runtime_host && _runtime_host->domain_main_thread_suppressed(RuntimeDomainId::COUNTRY)
            ? _runtime_host->command_seal_day() : _military->_military_last_step_day + 1;
        _military->admit(*request);
    }
    Array rejected;
    PackedInt64Array effective_days;
    for (const auto &row : request->rows) {
        effective_days.push_back(row.error.empty() ? row.effective_day : -1);
        if (row.error.empty()) continue;
        Dictionary entry;
        entry["index"] = row.index;
        entry["reason"] = String(row.error.c_str());
        rejected.push_back(entry);
    }
    const int64_t accepted = batch.size() - rejected.size();
    Dictionary out;
    out["ok"] = rejected.is_empty();
    out["admitted"] = accepted > 0;
    out["accepted"] = accepted;
    out["rejected"] = rejected;
    out["code"] = rejected.is_empty() ? String("ok") :
        batch.size() == 1 ? String(request->rows.front().error.c_str()) :
        String("military_command_rejected");
    out["effective_days"] = effective_days;
    if (accepted > 0) {
        out["effective_day"] = *std::max_element(effective_days.ptr(), effective_days.ptr() + effective_days.size());
        if (executor_owned) {
            out["committed_at_admission"] = request->committed_at_admission;
            out["frozen_at_admission"] = request->frozen_at_admission;
        }
    }
    if (!executor_owned) out["next_sequence"] = request->sequence;
    return out;
}

// ===========================================================================
// queries (cold: HUD, inspector, render feed)
// ===========================================================================

#include "world_ext_military_section_country_views.inc"

#include "world_ext_military_section_army_views.inc"

#include "world_ext_military_section_render_views.inc"

#include "world_ext_military_section_public_queries.inc"

// ===========================================================================
// persistence
// ===========================================================================

#include "world_ext_military_section_checkpoint.inc"

// ===========================================================================
// self test / bench / AI arming
// ===========================================================================

Dictionary DCWorldExt::runtime_military_self_test() {
    Dictionary out;
    std::string report;
    const bool ok = MilitaryCore::self_test(report);
    out["ok"] = ok;
    out["reason"] = String(report.c_str());
    // Bridge-level checks that do not need a world: catalog scaling, op table
    // coverage and term encoding are pure conversions.
    if (ok) {
        MilitaryCatalog probe;
        Dictionary catalog;
        Array units;
        Dictionary unit;
        unit["id"] = String("a_militia");
        unit["class"] = static_cast<int64_t>(0);
        unit["militia"] = true;
        unit["attack"] = 0.5;
        unit["defense"] = 0.6;
        unit["speed"] = 1.0;
        unit["training_days"] = static_cast<int64_t>(0);
        PackedFloat32Array idle;
        idle.resize(MILITARY_SUPPLY_CLASSES);
        idle[0] = 0.25f;
        unit["supply_idle"] = idle;
        units.push_back(unit);
        catalog["units"] = units;
        std::string error;
        if (!parse_catalog(catalog, probe, error)) {
            out["ok"] = false;
            out["reason"] = String(error.c_str());
            return out;
        }
        const MilitaryUnitType &parsed = probe.units.front();
        if (probe.militia_unit != 0 || parsed.attack_q16 != MILITARY_Q / 2 ||
            parsed.training_days != 1 || parsed.idle_per_100_day[0] != MILITARY_GOODS / 4) {
            out["ok"] = false;
            out["reason"] = String("military_catalog_scaling_invalid");
            return out;
        }
        if (op_from_name(String("army.area_control")) != MCMD_ARMY_AREA_CONTROL ||
            op_from_name(String("nope")) != MCMD_NONE) {
            out["ok"] = false;
            out["reason"] = String("military_op_table_invalid");
            return out;
        }
        Array terms;
        Dictionary term;
        term["kind"] = String("lump_sum");
        term["amount"] = 12.5;
        terms.push_back(term);
        std::vector<int32_t> ints;
        std::vector<int64_t> longs;
        if (!encode_peace_terms(terms, ints, longs, error) || ints.size() != 3 ||
            longs.size() != 1 || longs[0] != money_from_units(12.5)) {
            out["ok"] = false;
            out["reason"] = String("military_peace_term_encoding_invalid");
            return out;
        }
    }
    out["bridge"] = out["ok"];
    return out;
}

Dictionary DCWorldExt::run_military_bench(const Dictionary &cfg) {
    int32_t cells = std::max(1, dict_i32(cfg, "cells", 100000));
    int32_t armies = std::clamp(dict_i32(cfg, "armies", 2048), 1, MILITARY_MAX_ARMIES);
    int32_t engagements = std::max(1, dict_i32(cfg, "engagements", 4096));
    int32_t days = std::clamp(dict_i32(cfg, "days", 30), 1, 1000);
    double avg_ms = 0.0, p95_ms = 0.0, max_ms = 0.0;
    std::string report;
    const bool ok = MilitaryCore::bench(cells, armies, engagements, days, avg_ms, p95_ms,
                                        max_ms, report);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(report.c_str());
    out["cells"] = static_cast<int64_t>(cells);
    out["armies"] = static_cast<int64_t>(armies);
    out["engagements"] = static_cast<int64_t>(engagements);
    out["days"] = static_cast<int64_t>(days);
    out["avg_ms"] = avg_ms;
    out["p95_ms"] = p95_ms;
    out["max_ms"] = max_ms;
    return out;
}

Dictionary DCWorldExt::set_military_ai_player_handles(const PackedInt64Array &handles) {
    if (military_executor_active()) return military_fail("military_executor_owns_state");
    if (!_military) return military_unavailable();
    MilitaryCore *core = &_military->core();
    int32_t arming_errors = 0;
    // Make sure every active country owns a slot before slot -> handle lookups.
    _military->ensure_military_country_slots();
    // Every country slot the digest knows becomes AI unless it is a player.
    int32_t country_count = 0;
    if (_country_runtime != nullptr) {
        CountryEconomySnapshot snapshot;
        if (country_api::copy_economy_snapshot(
                *static_cast<NativeCountryRuntime *>(_country_runtime), snapshot))
            country_count = static_cast<int32_t>(snapshot.country_handles.size());
    }
    (void)arming_errors;
    for (int32_t slot = 0; slot < country_count; ++slot) {
        const uint64_t handle = core->country_handle_for_slot(slot);
        bool player = false;
        for (int64_t i = 0; i < handles.size(); ++i) {
            if (static_cast<uint64_t>(handles[i]) == handle) {
                player = true;
                break;
            }
        }
        // AI slot table is sized by the digest at configure time; use the
        // core's own arming entry point so MilitaryCore stays authoritative.
        core->set_ai_country(slot, !player);
    }
    Dictionary out;
    out["ok"] = true;
    out["path"] = "handle_set";
    out["applied"] = static_cast<int64_t>(country_count);
    return out;
}

Dictionary DCWorldExt::set_military_ai_country(int64_t slot, int64_t ai) {
    if (military_executor_active()) return military_fail("military_executor_owns_state");
    if (!_military) return military_unavailable();
    if (slot < 0 || slot >= MILITARY_MAX_ARMIES) return military_fail("military_slot_invalid");
    _military->core().set_ai_country(static_cast<int32_t>(slot), ai != 0);
    Dictionary out;
    out["ok"] = true;
    out["slot"] = slot;
    out["ai"] = ai != 0;
    return out;
}

} // namespace pk
