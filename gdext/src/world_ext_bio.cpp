#include "world_ext.h"
#include "world_ext_landmasses.h"
#include "economy_runtime.h"
#include "country_runtime.h"
#include "native_simulation_day_context.h"
#include "runtime_day_tail.h"
#include "runtime_checkpoint_wire.h"
#include "parallel_dispatcher.h"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <queue>
#include <unordered_set>
#include <utility>
#include <vector>

namespace pk {

using namespace godot;

namespace {

constexpr int32_t kLfMountain = 7;
constexpr int32_t kLfPeak = 8;
constexpr int32_t kLfDelta = 9;
constexpr int32_t kLfBadlands = 10;
constexpr int32_t kLfSaltFlat = 11;
constexpr int32_t kLfVolcano = 12;
constexpr int32_t kLfPlateau = 13;
constexpr float kCarrierEps = 0.0001f;
constexpr float kDiffusionKeep = 0.15f;
constexpr float kPersistClimateMargin = 0.12f;

constexpr int32_t kFlagNeedWetlandOrRiver = 1;
constexpr int32_t kFlagNeedHighland = 2;
constexpr int32_t kFlagForbidTropicalForest = 4;
constexpr int32_t kFlagNeedArid = 8;
constexpr int32_t kFlagNeedDryOrHighland = 16;
constexpr int32_t kFlagForbidArid = 32;
constexpr int32_t kFlagForbidWarm = 64;
constexpr int32_t kFlagForbidCold = 128;
constexpr int32_t kFlagNeedWetland = 256;

uint32_t bio_hash(uint32_t seed, uint32_t a, uint32_t b) {
    uint32_t h = seed ^ (a * 0x9e3779b9u) ^ (b * 0x85ebca6bu);
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return h;
}

float bio_unit(uint32_t h) {
    return float(h >> 8) * (1.0f / 16777216.0f);
}

bool veg_allowed(uint8_t veg, uint32_t mask0, uint32_t mask1) {
    if (mask0 == 0u && mask1 == 0u) return true;
    if (veg < 32u) return (mask0 & (1u << veg)) != 0u;
    if (veg < 64u) return (mask1 & (1u << (veg - 32u))) != 0u;
    return false;
}

bool veg_tropical_forest(uint8_t veg) {
    return veg == 12 || veg == 14 || veg == 15 || veg == 24 || veg == 25;
}

bool veg_wetland(uint8_t veg) {
    return veg == 19 || veg == 20 || veg == 21 || veg == 27;
}

bool veg_monsoon_forest(uint8_t veg) {
    return veg == 25;
}

bool veg_arid(uint8_t veg) {
    return veg == 10 || veg == 16 || veg == 17;
}

bool lf_highland(uint8_t lf, float elev) {
    return elev >= 0.40f || lf == 6 || lf == kLfMountain || lf == kLfPeak || lf == kLfPlateau;
}

bool lf_arid(uint8_t lf) {
    return lf == kLfBadlands || lf == kLfSaltFlat;
}

int32_t traversal_cost(uint8_t lf, uint8_t veg, uint8_t water) {
    if (water != 0) return 999;
    if (lf == kLfMountain || lf == kLfPeak || lf == kLfVolcano) return 8;
    if (lf == kLfBadlands || lf == kLfSaltFlat || veg_arid(veg)) return 3;
    if (lf == 6 || lf == kLfPlateau || lf == 15) return 2; // hill / plateau / canyon
    return 1;
}

struct SpeciesView {
    int32_t count = 0;
    std::vector<int32_t> signal_ids;
    std::vector<int32_t> bits;
    std::vector<int32_t> carrier;
    std::vector<int32_t> carrier_alt;
    std::vector<float> temp_lo;
    std::vector<float> temp_hi;
    std::vector<float> moist_lo;
    std::vector<float> moist_hi;
    std::vector<float> elev_lo;
    std::vector<float> elev_hi;
    std::vector<int32_t> veg0;
    std::vector<int32_t> veg1;
    std::vector<int32_t> flags;
    std::vector<int32_t> max_cost;
    std::vector<float> fill_keep;
    std::vector<int32_t> origin_policy;
    std::vector<int32_t> guild;
    std::vector<int32_t> habitat_class;
    std::array<int8_t, 32> bit_to_species{};
};

// One immutable catalog/topology cache per bound map. Component IDs are
// resolved once here so daily passes never parse stable strings or rebuild
// reserve columns across the GDScript boundary.
struct BioNativeConfigState {
    int32_t cell_count = 0;
    int32_t seed = 0;
    SpeciesView species;
    PackedInt32Array neighbors;
    std::vector<int32_t> reserve_slot_ids;
    int32_t water_slot = -1;
    int32_t vegetation_slot = -1;
    int32_t landform_slot = -1;
    int32_t river_slot = -1;
    int32_t temperature_slot = -1;
    int32_t moisture_slot = -1;
    int32_t elevation_slot = -1;
    int32_t province_slot = -1;
    int32_t occupancy_slot = -1;
};

template <typename T, typename Packed>
void copy_packed(const Packed &src, std::vector<T> &dst) {
    dst.resize(size_t(src.size()));
    if (!dst.empty()) std::memcpy(dst.data(), src.ptr(), dst.size() * sizeof(T));
}

bool load_species(const Dictionary &knobs, SpeciesView &sp, String &reason) {
    const PackedInt32Array bits = knobs.get("species_occupancy_bits", PackedInt32Array());
    const PackedInt32Array signals = knobs.get("species_signal_ids", PackedInt32Array());
    const PackedInt32Array carrier = knobs.get("species_carrier_index", PackedInt32Array());
    const PackedInt32Array carrier_alt = knobs.get("species_carrier_alt_index", PackedInt32Array());
    const PackedFloat32Array temp_lo = knobs.get("species_temp_lo", PackedFloat32Array());
    const PackedFloat32Array temp_hi = knobs.get("species_temp_hi", PackedFloat32Array());
    const PackedFloat32Array moist_lo = knobs.get("species_moist_lo", PackedFloat32Array());
    const PackedFloat32Array moist_hi = knobs.get("species_moist_hi", PackedFloat32Array());
    const PackedFloat32Array elev_lo = knobs.get("species_elev_lo", PackedFloat32Array());
    const PackedFloat32Array elev_hi = knobs.get("species_elev_hi", PackedFloat32Array());
    const PackedInt32Array veg0 = knobs.get("species_veg_mask0", PackedInt32Array());
    const PackedInt32Array veg1 = knobs.get("species_veg_mask1", PackedInt32Array());
    const PackedInt32Array flags = knobs.get("species_flags", PackedInt32Array());
    const PackedInt32Array max_cost = knobs.get("species_max_cost", PackedInt32Array());
    const PackedFloat32Array fill_keep = knobs.get("species_fill_keep", PackedFloat32Array());
    const int32_t n = bits.size();
    if (n <= 0 || n > 32 || signals.size() != n || carrier.size() != n ||
        carrier_alt.size() != n || temp_lo.size() != n || temp_hi.size() != n ||
        moist_lo.size() != n || moist_hi.size() != n || elev_lo.size() != n ||
        elev_hi.size() != n || veg0.size() != n || veg1.size() != n ||
        flags.size() != n || max_cost.size() != n || fill_keep.size() != n) {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    sp.count = n;
    sp.bit_to_species.fill(-1);
    copy_packed(signals, sp.signal_ids);
    copy_packed(bits, sp.bits);
    copy_packed(carrier, sp.carrier);
    copy_packed(carrier_alt, sp.carrier_alt);
    copy_packed(temp_lo, sp.temp_lo);
    copy_packed(temp_hi, sp.temp_hi);
    copy_packed(moist_lo, sp.moist_lo);
    copy_packed(moist_hi, sp.moist_hi);
    copy_packed(elev_lo, sp.elev_lo);
    copy_packed(elev_hi, sp.elev_hi);
    copy_packed(veg0, sp.veg0);
    copy_packed(veg1, sp.veg1);
    copy_packed(flags, sp.flags);
    copy_packed(max_cost, sp.max_cost);
    copy_packed(fill_keep, sp.fill_keep);
    for (int32_t species = 0; species < n; ++species) {
        const int32_t bit = sp.bits[size_t(species)];
        if (bit < 0 || bit >= 32 || sp.bit_to_species[size_t(bit)] >= 0) {
            reason = String("bio_species_bit_invalid_or_duplicate");
            return false;
        }
        sp.bit_to_species[size_t(bit)] = int8_t(species);
    }
    const PackedInt32Array origin_policy = knobs.get("species_origin_policy", PackedInt32Array());
    const PackedInt32Array guild = knobs.get("species_guild", PackedInt32Array());
    const PackedInt32Array habitat_class = knobs.get("species_habitat_class", PackedInt32Array());
    if (origin_policy.size() == n) {
        copy_packed(origin_policy, sp.origin_policy);
    } else if (origin_policy.size() == 0) {
        sp.origin_policy.assign(size_t(n), 0);
    } else {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    if (guild.size() == n) {
        copy_packed(guild, sp.guild);
    } else if (guild.size() == 0) {
        sp.guild.assign(size_t(n), 0);
    } else {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    if (habitat_class.size() == n) {
        copy_packed(habitat_class, sp.habitat_class);
    } else if (habitat_class.size() == 0) {
        sp.habitat_class.assign(size_t(n), 0);
    } else {
        reason = String("bio_species_shape_invalid");
        return false;
    }
    return true;
}

bool load_reserve_columns(const Dictionary &knobs, int n, int species_count,
                          const SpeciesView &sp,
                          std::vector<PackedFloat32Array> &columns,
                          String &reason) {
    const Array raw = knobs.get("carrier_reserves", Array());
    columns.clear();
    columns.resize(size_t(raw.size()));
    for (int i = 0; i < raw.size(); ++i) {
        const PackedFloat32Array col = raw[i];
        if (col.size() != n) {
            reason = String("bio_carrier_reserve_shape_invalid");
            return false;
        }
        columns[size_t(i)] = col;
    }
    for (int s = 0; s < species_count; ++s) {
        if (sp.carrier[s] >= int32_t(columns.size()) ||
            sp.carrier_alt[s] >= int32_t(columns.size())) {
            reason = String("bio_carrier_index_out_of_range");
            return false;
        }
    }
    return true;
}

#include "world_ext_bio_section_occupancy_and_habitat_helpers.inc"
#include "world_ext_bio_occupancy_step.h"

} // namespace

struct RuntimeBioState {
    BioOccupancyRound round;
    std::vector<size_t> carrier_resources;
    std::vector<int32_t> introduce_cells;
    std::vector<int32_t> introduce_bits;
};

bool DCWorldExt::seed_runtime_bio(const NativeEconomyRuntime &economy) {
    const auto *config = static_cast<const BioNativeConfigState *>(_bio_native_config_state);
    if (!config || _runtime_host->has_bio_state()) return true;
    const auto &occupancy = _slots[config->occupancy_slot].arr_i32;
    if (occupancy.size() != config->cell_count || economy.cell_count() != config->cell_count)
        return false;

    auto state = std::make_shared<RuntimeBioState>();
    state->round.n = config->cell_count;
    state->round.seed = config->seed;
    state->round.species = config->species;
    copy_packed(occupancy, state->round.previous);
    if (!_runtime_host->restore_bio_seed(state->round.previous)) return false;
    if (!std::equal(state->round.previous.begin(), state->round.previous.end(), occupancy.ptr())) {
        auto &slot = _slots.write[config->occupancy_slot];
        std::copy(state->round.previous.begin(), state->round.previous.end(), slot.arr_i32.ptrw());
        _flush_slot_to_map(config->occupancy_slot);
    }
    const auto &reserves = economy.building_resource_reserve_slots();
    for (const int32_t slot : config->reserve_slot_ids) {
        const auto name = String(_slots[slot].name).utf8();
        const auto resource = std::find(reserves.begin(), reserves.end(), name.get_data());
        if (resource == reserves.end()) return false;
        state->carrier_resources.push_back(static_cast<size_t>(resource - reserves.begin()));
    }
    _runtime_host->attach_bio_state(std::move(state));
    return true;
}

std::vector<uint8_t> NativeSimulationHost::capture_bio_state() const {
    if (!_executor_bio) return {};
    CheckpointWriter out;
    for (const auto cell : _executor_bio->round.previous) out.field(cell);
    return std::move(out.bytes);
}

bool NativeSimulationHost::restore_bio_seed(std::vector<int32_t> &occupancy) const {
    if (!_has_pending_restore ||
        (_pending_restore_bundle.section_mask & RUNTIME_SAVE_SECTION_BIO) == 0) return true;
    const auto &bytes = _pending_restore_bundle.bio_bytes;
    if (bytes.size() != occupancy.size() * sizeof(int32_t)) return false;
    CheckpointReader in{bytes.data(), bytes.size()};
    for (auto &cell : occupancy)
        if (!in.field(cell)) return false;
    return true;
}

const char *NativeSimulationHost::stage_bio_occupancy(DayExecution &day) {
    if (!_executor_bio ||
        day.commit.completed_domain_mask != RUNTIME_ALL_DOMAIN_MASK) return nullptr;
    auto &state = *_executor_bio;
    auto &round = state.round;
    const auto *environment = day.environment;
    const auto &climate = _climate_authority.store();
    const auto day_index = day.plan.context.day;
    const auto count = static_cast<size_t>(round.n);
    if (!environment || !environment->economy_input ||
        environment->day != day_index || climate.committed_day != day_index ||
        climate.temperature_30d_ema.size() != count || climate.moisture.size() != count ||
        climate.vegetation.size() != count || environment->is_water.size() != count ||
        environment->has_river.size() != count || environment->landform.size() != count ||
        environment->cell_elevation.size() != count || environment->province_ids.size() != count ||
        environment->economy_input->neighbors.size() != count * 6u) {
        return "bio_day_tail_input_shape_invalid";
    }

    if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
    const auto &reserves = _economy_production_runtime->worker_resource_reserve_lanes();
    _economy_production_runtime->take_bio_introduces(state.introduce_cells, state.introduce_bits);
    _executor_day_tail->species_introductions_consumed =
        static_cast<int64_t>(state.introduce_cells.size());
    BioOccupancyInputs inputs{environment->is_water.data(), climate.vegetation.data(),
        environment->landform.data(), environment->has_river.data(),
        climate.temperature_30d_ema.data(), climate.moisture.data(), environment->cell_elevation.data(),
        environment->province_ids.data(), environment->economy_input->neighbors.data(),
        state.introduce_cells.data(), state.introduce_bits.data(),
        static_cast<int>(state.introduce_cells.size()), {}};
    inputs.reserves.reserve(state.carrier_resources.size());
    for (const size_t resource : state.carrier_resources)
        inputs.reserves.push_back(reserves.data() + resource * count);

    round.day_index = static_cast<int>(day_index);
    round.run_diffusion = day_index % 8 == 0;
    round.begin();
    do {
        advance_bio_slice(&round, inputs, round.n);
    } while (round.phase != 3 || round.cursor < round.n);
    round.previous.swap(round.output);
    _executor_day_tail->species_diffused_cells = round.diffused_cells;
    _executor_day_tail->occupancy = round.previous;
    return submit_species_observations(day_index, round.newly_cells, round.newly_signals,
                                       _executor_day_tail->species_observations)
        ? nullptr : "species_observations_rejected";
}

void destroy_bio_occupancy_slice_state(void *state) {
    delete static_cast<BioOccupancySliceState *>(state);
}

void destroy_bio_native_config_state(void *state) {
    delete static_cast<BioNativeConfigState *>(state);
}

Dictionary DCWorldExt::_queue_bio_observations(
        int64_t country_handle, int64_t effective_day,
        const PackedInt32Array &cells, const PackedInt32Array &signals) {
    Dictionary out;
    out["ok"] = false;
    if (_country_runtime == nullptr || country_handle == 0 || effective_day < 0) {
        out["reason"] = String("bio_observation_country_unavailable");
        return out;
    }
    const Dictionary filtered = filter_bio_research_observations(cells, signals);
    if (!bool(filtered.get("ok", false))) return filtered;
    const PackedInt32Array eligible_cells = filtered.get(
        "observation_cells", PackedInt32Array());
    const PackedInt32Array eligible_signals = filtered.get(
        "observation_signals", PackedInt32Array());
    if (eligible_cells.is_empty()) {
        out["ok"] = true;
        out["submitted"] = 0;
        return out;
    }
    // Use the canonical Country ingress so SHADOW receives the same discovery
    // commands as the synchronous production runtime. Calling
    // NativeCountryRuntime::submit_observation_batch directly bypassed the
    // Host mirror; the first bio discovery (typically day 7) therefore made
    // country_research_signals diverge permanently.
    const int64_t count = eligible_cells.size();
    PackedInt32Array opcodes, aux, domains, positions;
    PackedInt32Array weight0, weight1, weight2, weight3;
    PackedInt32Array tax_kinds, tax_items, tax_rates, tax_modes;
    PackedInt64Array days, sequences, handles, values;
    PackedStringArray stable_ids, display_names;
    for (PackedInt32Array *array : {
             &opcodes, &aux, &domains, &positions,
             &weight0, &weight1, &weight2, &weight3,
             &tax_kinds, &tax_items, &tax_rates, &tax_modes}) {
        array->resize(count);
    }
    for (PackedInt64Array *array : {
             &days, &sequences, &handles, &values}) {
        array->resize(count);
    }
    stable_ids.resize(count);
    display_names.resize(count);
    for (int64_t i = 0; i < count; ++i) {
        opcodes.set(i, 14); // DISCOVER_COUNTRY_SIGNAL
        days.set(i, effective_day);
        sequences.set(i, i);
        handles.set(i, country_handle);
        aux.set(i, eligible_signals[i]);
        domains.set(i, -1);
        positions.set(i, -1);
        values.set(i, 1);
        tax_kinds.set(i, -1);
        tax_items.set(i, -1);
    }
    Dictionary batch;
    batch["opcodes"] = opcodes;
    batch["effective_days"] = days;
    batch["sequences"] = sequences;
    batch["target_handles"] = handles;
    batch["cell_indices"] = eligible_cells;
    batch["aux_i32"] = aux;
    batch["domain_i32"] = domains;
    batch["position_i32"] = positions;
    batch["weight0_bp"] = weight0;
    batch["weight1_bp"] = weight1;
    batch["weight2_bp"] = weight2;
    batch["weight3_bp"] = weight3;
    batch["value_i64"] = values;
    batch["tax_kinds"] = tax_kinds;
    batch["tax_item_indices"] = tax_items;
    batch["tax_rate_basis_points"] = tax_rates;
    batch["tax_assessment_modes"] = tax_modes;
    batch["stable_ids"] = stable_ids;
    batch["display_names"] = display_names;
    return submit_country_commands(batch);
}

Dictionary DCWorldExt::apply_runtime_species_writeback() {
    Dictionary out;
    out["ok"] = true;
    out["applied"] = false;
    RuntimeCommit commit = _runtime_display_commit;
    if ((!commit.day_tail && (!_runtime_host || !_runtime_host->poll_commit(0, commit))) ||
        !commit.day_tail || commit.day_tail->occupancy.empty()) return out;
    const auto &tail = *commit.day_tail;
    const int slot = component_id(StringName("cell_bio_occupancy_bits"));
    if (slot < 0 || slot >= _slots.size() || _slots[slot].dtype != SlotDType::I32 ||
        _slots[slot].arr_i32.size() != int64_t(tail.occupancy.size())) {
        out["ok"] = false;
        out["reason"] = "bio_writeback_slot_shape_invalid";
    } else {
        std::copy(tail.occupancy.begin(), tail.occupancy.end(), _slots.write[slot].arr_i32.ptrw());
        _flush_slot_to_map(slot);
        out["applied"] = true;
    }
    return out;
}

Dictionary DCWorldExt::configure_bio_occupancy(const Dictionary &config) {
    Dictionary out;
    out["ok"] = false;
    const int32_t n = int32_t(config.get("cell_count", 0));
    const PackedInt32Array neighbors = config.get(
        "neighbor_indices", PackedInt32Array());
    if (n <= 0 || n > 1000000 || neighbors.size() != int64_t(n) * 6) {
        out["reason"] = String("bio_config_shape_invalid");
        return out;
    }
    auto *next = new BioNativeConfigState();
    next->cell_count = n;
    next->seed = int32_t(config.get("seed", 0));
    next->neighbors = neighbors;
    String reason;
    if (!load_species(config, next->species, reason)) {
        delete next;
        out["reason"] = reason;
        return out;
    }
    const PackedStringArray reserve_names = config.get(
        "carrier_slot_names", PackedStringArray());
    next->reserve_slot_ids.reserve(size_t(reserve_names.size()));
    for (int32_t i = 0; i < reserve_names.size(); ++i) {
        const int32_t slot_id = component_id(StringName(reserve_names[i]));
        if (slot_id < 0 || slot_id >= _slots.size() ||
            _slots[slot_id].dtype != SlotDType::F32) {
            delete next;
            out["reason"] = String("bio_config_carrier_slot_missing");
            out["carrier_slot"] = reserve_names[i];
            return out;
        }
        next->reserve_slot_ids.push_back(slot_id);
    }
    for (int32_t s = 0; s < next->species.count; ++s) {
        if (next->species.carrier[size_t(s)] >= int32_t(next->reserve_slot_ids.size()) ||
            next->species.carrier_alt[size_t(s)] >= int32_t(next->reserve_slot_ids.size())) {
            delete next;
            out["reason"] = String("bio_config_carrier_index_out_of_range");
            return out;
        }
    }
    auto resolve = [&](const char *name, SlotDType dtype) -> int32_t {
        const int32_t id = component_id(StringName(name));
        if (id < 0 || id >= _slots.size() || _slots[id].dtype != dtype) return -1;
        return id;
    };
    next->water_slot = resolve("cell_is_water", SlotDType::U8);
    next->vegetation_slot = resolve("cell_vegetation", SlotDType::U8);
    next->landform_slot = resolve("cell_landform", SlotDType::U8);
    next->river_slot = resolve("cell_has_river", SlotDType::U8);
    next->temperature_slot = resolve("cell_temp_30d", SlotDType::F32);
    if (next->temperature_slot < 0)
        next->temperature_slot = resolve("cell_temp", SlotDType::F32);
    next->moisture_slot = resolve("cell_moisture", SlotDType::F32);
    next->elevation_slot = resolve("cell_elevation", SlotDType::F32);
    next->province_slot = resolve("cell_province_id", SlotDType::I32);
    next->occupancy_slot = resolve("cell_bio_occupancy_bits", SlotDType::I32);
    const std::array<int32_t, 9> required = {
        next->water_slot, next->vegetation_slot, next->landform_slot,
        next->river_slot, next->temperature_slot, next->moisture_slot,
        next->elevation_slot, next->province_slot, next->occupancy_slot};
    for (int32_t id : required) {
        if (id < 0) {
            delete next;
            out["reason"] = String("bio_config_core_slot_missing");
            return out;
        }
    }
    if (_bio_occupancy_slice_state != nullptr) {
        destroy_bio_occupancy_slice_state(_bio_occupancy_slice_state);
        _bio_occupancy_slice_state = nullptr;
    }
    if (_bio_native_config_state != nullptr)
        destroy_bio_native_config_state(_bio_native_config_state);
    _bio_native_config_state = next;
    out["ok"] = true;
    out["cell_count"] = n;
    out["species_count"] = next->species.count;
    out["carrier_slot_count"] = int32_t(next->reserve_slot_ids.size());
    return out;
}

Dictionary DCWorldExt::run_bio_province_pass(const Dictionary &knobs) {
    Dictionary out;
    out["ok"] = false;
    const int width = int(knobs.get("width", 0));
    const int height = int(knobs.get("height", 0));
    const int64_t n64 = int64_t(width) * int64_t(height);
    if (width <= 0 || height <= 0 || n64 <= 0 || n64 > 1000000) {
        out["reason"] = String("bio_province_dimensions_invalid");
        return out;
    }
    const int n = int(n64);
    const PackedByteArray water_arr = knobs.get("is_water", PackedByteArray());
    const PackedByteArray landform_arr = knobs.get("landform", PackedByteArray());
    const PackedByteArray vegetation_arr = knobs.get("vegetation", PackedByteArray());
    const PackedInt32Array neighbors = knobs.get("neighbor_indices", PackedInt32Array());
    if (water_arr.size() != n || landform_arr.size() != n || vegetation_arr.size() != n ||
        neighbors.size() != n * 6) {
        out["reason"] = String("bio_province_input_shape_invalid");
        return out;
    }
    const uint8_t *water = water_arr.ptr();
    const uint8_t *lf = landform_arr.ptr();
    const uint8_t *veg = vegetation_arr.ptr();
    const int32_t *nb = neighbors.ptr();

    PackedInt32Array landmass;
    PackedInt32Array province;
    landmass.resize(n);
    province.resize(n);
    int32_t *lm = landmass.ptrw();
    int32_t *pv = province.ptrw();
    std::memset(pv, 0, size_t(n) * sizeof(int32_t));

    const int32_t landmass_count = label_world_landmasses(water, nb, n, lm);
    std::vector<int32_t> stack;
    stack.reserve(size_t(n));

    int32_t province_count = 0;
    for (int cell = 0; cell < n; ++cell) {
        if (water[cell] != 0 || pv[cell] != 0) continue;
        if (traversal_cost(lf[cell], veg[cell], water[cell]) >= 8) continue;
        ++province_count;
        stack.clear();
        stack.push_back(cell);
        pv[cell] = province_count;
        while (!stack.empty()) {
            const int32_t cur = stack.back();
            stack.pop_back();
            const int32_t base = cur * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nxt = nb[base + d];
                if (nxt < 0 || nxt >= n || water[nxt] != 0 || pv[nxt] != 0) continue;
                if (lm[nxt] != lm[cur]) continue;
                if (traversal_cost(lf[nxt], veg[nxt], water[nxt]) >= 8) continue;
                pv[nxt] = province_count;
                stack.push_back(nxt);
            }
        }
    }

    std::queue<int32_t> q;
    for (int cell = 0; cell < n; ++cell) {
        if (pv[cell] > 0) q.push(cell);
    }
    while (!q.empty()) {
        const int32_t cur = q.front();
        q.pop();
        const int32_t base = cur * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nxt = nb[base + d];
            if (nxt < 0 || nxt >= n || water[nxt] != 0 || pv[nxt] != 0) continue;
            if (lm[nxt] != lm[cur]) continue;
            pv[nxt] = pv[cur];
            q.push(nxt);
        }
    }
    for (int cell = 0; cell < n; ++cell) {
        if (water[cell] != 0 || pv[cell] != 0) continue;
        ++province_count;
        pv[cell] = province_count;
    }

    std::vector<int32_t> parent(size_t(province_count + 1), 0);
    for (int32_t i = 1; i <= province_count; ++i) parent[size_t(i)] = i;
    auto find = [&](int32_t x) {
        while (parent[size_t(x)] != x) {
            parent[size_t(x)] = parent[size_t(parent[size_t(x)])];
            x = parent[size_t(x)];
        }
        return x;
    };
    auto unite = [&](int32_t a, int32_t b) {
        a = find(a);
        b = find(b);
        if (a != b) parent[size_t(a)] = b;
    };

    std::vector<int32_t> sizes(size_t(province_count + 1), 0);
    for (int cell = 0; cell < n; ++cell) {
        if (pv[cell] > 0) sizes[size_t(pv[cell])] += 1;
    }
    std::vector<int32_t> border_count(size_t(province_count + 1) * size_t(province_count + 1), 0);
    for (int cell = 0; cell < n; ++cell) {
        const int32_t p = pv[cell];
        if (p <= 0) continue;
        const int32_t base = cell * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nxt = nb[base + d];
            if (nxt < 0 || nxt >= n) continue;
            const int32_t qid = pv[nxt];
            if (qid <= 0 || qid == p) continue;
            border_count[size_t(p) * size_t(province_count + 1) + size_t(qid)] += 1;
        }
    }
    std::vector<int32_t> best_neighbor(size_t(province_count + 1), 0);
    for (int32_t p = 1; p <= province_count; ++p) {
        int32_t best = 0;
        int32_t best_c = 0;
        for (int32_t qid = 1; qid <= province_count; ++qid) {
            if (qid == p) continue;
            const int32_t c = border_count[size_t(p) * size_t(province_count + 1) + size_t(qid)];
            if (c > best_c) {
                best_c = c;
                best = qid;
            }
        }
        best_neighbor[size_t(p)] = best;
    }
    constexpr int32_t kMinProvince = 8;
    for (int32_t p = 1; p <= province_count; ++p) {
        if (sizes[size_t(p)] >= kMinProvince) continue;
        const int32_t nb_p = best_neighbor[size_t(p)];
        if (nb_p > 0) unite(p, nb_p);
    }
    for (int cell = 0; cell < n; ++cell) {
        if (pv[cell] > 0) pv[cell] = find(pv[cell]);
    }
    std::vector<int32_t> remap(size_t(province_count + 1), 0);
    int32_t compact = 0;
    for (int cell = 0; cell < n; ++cell) {
        const int32_t p = pv[cell];
        if (p <= 0) continue;
        if (remap[size_t(p)] == 0) remap[size_t(p)] = ++compact;
        pv[cell] = remap[size_t(p)];
    }

    out["ok"] = true;
    out["path"] = String("gdext");
    out["landmass_ids"] = landmass;
    out["province_ids"] = province;
    out["landmass_count"] = landmass_count;
    out["province_count"] = compact;
    return out;
}

Dictionary DCWorldExt::run_bio_bootstrap_pass(const Dictionary &knobs) {
    // Keep the generation-only topology arrays native between the two stages.
    // The legacy stage entry points remain available for PROBE parity and rollback.
    Dictionary province = run_bio_province_pass(knobs);
    if (!bool(province.get("ok", false))) return province;

    Dictionary seed_knobs = knobs.duplicate(false);
    seed_knobs["landmass_ids"] = province.get("landmass_ids", PackedInt32Array());
    seed_knobs["province_ids"] = province.get("province_ids", PackedInt32Array());
    seed_knobs["seed_missing_species"] = true;
    Dictionary out = run_bio_seed_pass(seed_knobs);
    if (!bool(out.get("ok", false))) return out;

    out["landmass_ids"] = province.get("landmass_ids", PackedInt32Array());
    out["province_ids"] = province.get("province_ids", PackedInt32Array());
    out["landmass_count"] = province.get("landmass_count", 0);
    out["province_count"] = province.get("province_count", 0);
    out["path"] = String("gdext_fused_bootstrap");
    return out;
}

#include "world_ext_bio_section_native_seeding.inc"
#include "world_ext_bio_section_occupancy_progress.inc"

} // namespace pk
