#include "native_simulation_host.h"

#include "economy_runtime.h"
#include "runtime_economy_display.h"
#include "world_ext_golden.h"
#include "runtime_vision.h"
#include "runtime_world_environment.h"
#include "world_ext_internal_cell_luts.h"

#include <utility>

namespace pk {

const char *NativeSimulationHost::stage_natural_resource_recovery(DayExecution &) {
    auto *economy = _economy_production_runtime;
    if (economy == nullptr || !economy_worker_owns_execution() ||
        !economy->worker_natural_resources_configured()) return nullptr;
    if (!economy->worker_resource_seeded()) return "resource_day_tail_not_seeded";

    // Production reads the recovered stock in the Economy stage, which also
    // folds in its extraction and cultivation. Finish that day's resource
    // publication here without asking a view consumer to drain the deltas.
    std::vector<size_t> lanes;
    std::vector<int64_t> deltas;
    economy->drain_building_resource_deltas(lanes, deltas);
    _executor_day_tail = std::make_shared<RuntimeDayTail>();
    _executor_day_tail->resource_recovery_cells = economy->worker_resource_recovered_cells();
    economy->take_worker_resource_mirror_cells(_executor_resource_display_cells);
    return nullptr;
}

void NativeSimulationHost::merge_resource_display_patch(RuntimeResourceDisplayPatch &patch) const {
    if (_executor_resource_display_cells.empty()) return;
    const auto *economy = _economy_production_runtime;
    const size_t count = static_cast<size_t>(economy->cell_count());
    const auto &reserve = economy->worker_resource_reserve_lanes();
    const auto &extra = economy->worker_resource_extra_lanes();
    const size_t resource_count = economy->building_resource_reserve_slots().size();
    for (const int32_t cell : _executor_resource_display_cells) {
        const auto [entry, inserted] = patch.offsets.try_emplace(cell, patch.reserve.size());
        const size_t offset = entry->second;
        if (inserted) {
            patch.cells.push_back(cell);
            patch.reserve.resize(offset + resource_count);
            patch.extra.resize(offset + resource_count);
        }
        for (size_t resource = 0; resource < resource_count; ++resource) {
            const size_t lane = resource * count + cell;
            patch.reserve[offset + resource] = reserve[lane];
            patch.extra[offset + resource] = extra[lane];
        }
    }
}

bool NativeSimulationHost::has_resource_display_patch() const {
    std::lock_guard<std::mutex> lock(_resource_display_mutex);
    return !_resource_display_patch.cells.empty();
}

RuntimeResourceDisplayPatch NativeSimulationHost::take_resource_display_patch() {
    std::lock_guard<std::mutex> lock(_resource_display_mutex);
    return std::exchange(_resource_display_patch, {});
}

namespace {

godot::Dictionary pack_record(const RuntimeDayRecord &record) {
    godot::Dictionary daily;
    daily["day"] = record.header.committed_day;
    daily["generation"] = static_cast<int64_t>(record.header.generation);
    daily["state_hash"] = static_cast<int64_t>(record.header.state_hash);
    daily["business_hash"] = static_cast<int64_t>(record.business_hash);
    daily["annual_reward_pending"] = record.annual_reward_pending;
    daily["produced_at_us"] = static_cast<int64_t>(record.header.produced_at_us);
    if (record.fiscal) {
        daily["fiscal"] = record.fiscal->fiscal;
        daily["treasury_cash"] = record.fiscal->cash;
    }
    if (record.golden) daily["golden"] = runtime_golden_dictionary(*record.golden);
    return daily;
}

godot::Array pack_notices(const RuntimeDayRecord &record) {
    godot::Array rows;
    for (const auto &notice : record.notices) {
        godot::Dictionary row;
        row["event_id"] = godot::String(notice.id.c_str());
        row["title"] = godot::String::utf8(notice.title.c_str());
        row["settlement_name"] = godot::String::utf8(notice.settlement.c_str());
        row["cell_idx"] = notice.cell;
        row["event_category"] = notice.category;
        row["day"] = record.header.committed_day;
        row["notice_only"] = true;
        rows.push_back(row);
    }
    return rows;
}

godot::Array pack_colonization_receipts(const NativeEconomyRuntime &economy, int64_t country, int64_t day) {
    godot::Array result;
    int64_t after = 0;
    constexpr int32_t page_size = 256;
    do {
        const auto page = economy.family_colonization_receipts(country, after, page_size);
        const godot::Array rows = page["receipts"];
        for (int64_t i = 0; i < rows.size(); ++i) {
            godot::Dictionary row = rows[i];
            if (int64_t(row["settled_day"]) != day) continue;
            row["country_handle"] = country;
            result.push_back(row);
        }
        if (rows.size() < page_size) break;
        after = page["last_receipt_id"];
    } while (true);
    return result;
}

godot::Array append_receipts(const godot::Array &older, const godot::Array &newer) {
    if (older.is_empty()) return newer;
    if (newer.is_empty()) return older;
    auto result = older.duplicate();
    result.append_array(newer);
    return result;
}

} // namespace

godot::Array pack_runtime_receipts(const std::vector<RuntimeCommandReceipt> &receipts) {
    godot::Array rows;
    for (const auto &receipt : receipts) {
        godot::Dictionary row;
        row["request_id"] = static_cast<int64_t>(receipt.request_id);
        row["producer_id"] = static_cast<int>(receipt.producer_id);
        row["sequence"] = static_cast<int64_t>(receipt.sequence);
        row["effective_day"] = receipt.effective_day;
        row["generation"] = static_cast<int64_t>(receipt.generation);
        row["code"] = static_cast<int>(receipt.code);
        rows.push_back(row);
    }
    return rows;
}

void NativeSimulationHost::publish_display_batch(std::shared_ptr<const RuntimeCommit> commit,
                                                 const RuntimeDayRecord &record) {
    auto row = pack_record(record);
    const auto notices = pack_notices(record);
    const auto receipts = pack_runtime_receipts(record.receipts);
    godot::Array construction_receipts, colonization_receipts;
    if (_economy_production_runtime) {
        construction_receipts = _economy_production_runtime->construction_command_receipts(
            0, 256, record.header.committed_day)["receipts"];
        const auto player = confirmation_country();
        if (player != 0)
            colonization_receipts = pack_colonization_receipts(
                *_economy_production_runtime, static_cast<int64_t>(player), record.header.committed_day);
    }
    const auto gdp = commit->day_tail->gdp ? commit->day_tail->gdp->pack() : godot::Dictionary();
    row["receipts"] = receipts;
    if (!notices.is_empty()) {
        row["notices"] = notices;
        auto history = _display_notices.duplicate();
        for (int64_t i = 0; i < notices.size(); ++i) history.push_front(notices[i]);
        if (history.size() > 256) history.resize(256);
        _display_notices = std::move(history);
    }
    if (record.fiscal) {
        if (!_display_finances) _display_finances = std::make_shared<RuntimeFiscalHistory>();
        _display_finances->record(record.header.committed_day, *record.fiscal);
    }
    const auto fiscal = _display_finances ? _display_finances->pack() : godot::Dictionary();
    auto older = std::atomic_load(&_published_display);
    do {
        auto batch = std::make_shared<RuntimeDisplayBatch>();
        batch->commit = commit;
        batch->records = older ? older->records.duplicate() : godot::Array();
        batch->records.push_back(row);
        batch->notices = _display_notices;
        batch->receipts = receipts;
        batch->construction_receipts = older
            ? append_receipts(older->construction_receipts, construction_receipts) : construction_receipts;
        batch->colonization_receipts = older
            ? append_receipts(older->colonization_receipts, colonization_receipts) : colonization_receipts;
        batch->gdp = gdp;
        batch->fiscal_history = fiscal;
        if (older) {
            batch->resources = older->resources;
            batch->cell_flags = older->cell_flags;
        }
        merge_resource_display_patch(batch->resources);
        batch->cell_flags.resize(_executor_cell_lut_pending.size());
        for (size_t cell = 0; cell < batch->cell_flags.size(); ++cell) {
            const uint8_t change = batch->cell_flags[cell] |= _executor_cell_lut_pending[cell];
            if (change & 1) batch->changed_cells.push_back(static_cast<int32_t>(cell));
            if (change & 2) batch->changed_classes.push_back(static_cast<int32_t>(cell));
        }
        // A consumer can remove the previous batch while the producer builds
        // this one. Rebuild from the new prefix only when that take wins.
        if (std::atomic_compare_exchange_strong(&_published_display, &older,
                std::shared_ptr<const RuntimeDisplayBatch>(std::move(batch)))) break;
    } while (true);
    _executor_resource_display_cells.clear();
}

std::shared_ptr<const RuntimeDisplayBatch> NativeSimulationHost::take_day_publications(uint64_t after) {
    auto batch = std::atomic_load(&_published_display);
    while (batch && batch->commit->header.generation > after) {
        if (std::atomic_compare_exchange_weak(&_published_display, &batch,
                std::shared_ptr<const RuntimeDisplayBatch>())) {
            {
                std::lock_guard<std::mutex> control(_control_mutex);
                _display_consumed_day.store(batch->commit->header.committed_day, std::memory_order_release);
            }
            _control_cv.notify_all();
            return batch;
        }
    }
    return {};
}

void NativeSimulationHost::reset_display_batch() {
    std::atomic_store(&_published_display, std::shared_ptr<const RuntimeDisplayBatch>());
    _display_finances.reset();
    _display_notices = {};
}

std::shared_ptr<const RuntimeClimateSnapshot> NativeSimulationHost::latest_climate_display() const {
    const auto latest = std::atomic_load(&_latest_commit);
    return latest && latest->day_tail ? latest->day_tail->climate : nullptr;
}

void NativeSimulationHost::publish_cell_lut_changes(RuntimeDayTail &tail, const RuntimeDayTail *previous) {
    const auto &state = tail.climate->payload;
    const size_t count = state.cell_count;
    if (state.terrain.size() != count || state.vegetation.size() != count ||
        state.cover.size() != count || state.weather_type.size() != count) return;

    const auto &opening_landform = _world_environment->opening_landform();
    const auto &prior = previous && previous->climate ? &previous->climate->payload : nullptr;
    const auto &old_age = previous ? &previous->cell_luts.transition_age : nullptr;
    const bool initialized = _cell_lut_words.size() == count;
    _cell_lut_words.resize(count);
    _executor_cell_lut_pending.assign(count, 0);
    auto &frame = tail.cell_luts;
    frame.previous_vitality.resize(count);
    frame.transition_age.resize(count);
    const uint8_t *water = _world_environment->water_terrain_lookup();
    for (size_t cell = 0; cell < count; ++cell) {
        const uint8_t terrain = state.terrain[cell];
        const uint8_t vegetation = state.vegetation[cell];
        const uint8_t fog = tail.vision && tail.vision->fog_enabled ? tail.vision->fog[cell] : 255;
        const uint8_t landform = tail.climate->season && tail.climate->season->landform.size() == count
            ? tail.climate->season->landform[cell] : opening_landform[cell];
        const float temp = state.temperature[cell];
        const float moisture = state.moisture[cell];
        const float snow = state.snow_cover[cell];
        const float vitality = state.vegetation_vitality[cell];
        const auto cur_vitality = uint8_t(pk_q01_byte(vitality));
        const bool has_prior = prior && prior->vegetation.size() == count && old_age && old_age->size() == count;
        const uint8_t prev_veg = has_prior ? prior->vegetation[cell] : vegetation;
        const auto prev_vitality = has_prior
            ? uint8_t(pk_q01_byte(prior->vegetation_vitality[cell])) : cur_vitality;
        const auto age = uint8_t(prev_veg != vegetation ? 255 : has_prior
            ? std::max(0, int((*old_age)[cell]) - 18) : 0);
        frame.previous_vitality[cell] = prev_vitality;
        frame.transition_age[cell] = age;

        const uint32_t classes = uint32_t(terrain) | (uint32_t(vegetation) << 8) |
            (uint32_t(state.cover[cell]) << 16) | (uint32_t(fog) << 24);
        const uint32_t dynamics = pk_atlas_sig_dynamic(temp, moisture, snow, vitality,
            state.sea_ice[cell], water[terrain] != 0);
        const uint32_t ecology = pk_atlas_sig_ecology(temp, moisture, snow, vitality, vegetation,
            water[terrain] != 0, age, prev_vitality, 0);
        const uint32_t weather = uint32_t(state.weather_type[cell]) |
            (uint32_t(pk_q01_byte(state.weather_intensity[cell])) << 8) |
            (uint32_t(pk_q01_byte(state.cloud_cover[cell])) << 16) |
            (uint32_t(pk_q01_byte(state.vapor[cell])) << 24);
        const auto &season = previous && previous->climate ? previous->climate->season : nullptr;
        const uint8_t old_landform = season && season->landform.size() == count
            ? season->landform[cell] : opening_landform[cell];
        const std::array<uint32_t, 4> words{classes, dynamics, ecology, weather};
        if (!initialized || classes != _cell_lut_words[cell][0] || old_landform != landform)
            _executor_cell_lut_pending[cell] |= 3;
        else if (words != _cell_lut_words[cell] || age != 0)
            _executor_cell_lut_pending[cell] |= 1;
        _cell_lut_words[cell] = words;
    }
}

void NativeSimulationHost::reset_day_tail_for_world_change() {
    _world_environment.reset();
    _executor_narrative.reset();
    _restored_narrative = godot::Dictionary();
    std::atomic_store(&_published_narrative, std::shared_ptr<const RuntimeNarrativeView>());
    _clock_requested_day.store(-1, std::memory_order_release);
    _executor_bio.reset();
    _executor_vision.reset();
    if (const auto last = std::atomic_load(&_latest_commit); last && last->day_tail) {
        auto header = std::make_shared<RuntimeCommit>(*last);
        header->day_tail.reset();
        std::atomic_store(&_latest_commit, std::shared_ptr<const RuntimeCommit>(std::move(header)));
    }
    _executor_day_tail.reset();
    _executor_resource_display_cells.clear();
    reset_display_batch();
    _cell_lut_words.clear();
    _executor_cell_lut_pending.clear();
    take_resource_display_patch();
}

} // namespace pk
