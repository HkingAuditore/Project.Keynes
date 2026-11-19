#include "runtime_world_environment.h"

#include "economy_api.h"
#include "modifier_api.h"
#include "runtime_climate_authority.h"
#include "runtime_climate_physics.h"
#include "runtime_climate_weather_input.h"
#include "world_ext_season_stage.h"

#include <godot_cpp/classes/random_number_generator.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <string_view>
#include <utility>

namespace pk {
namespace {

using namespace godot;

enum SeasonColumn {
    TERRAIN, LANDFORM, VEGETATION, COVER, WATER, BASE_TERRAIN, RIVER, ELEVATION,
    LATITUDE, RIVER_FLOW, TEMPERATURE, TEMPERATURE_YEAR, MOISTURE, BASE_MOISTURE,
    WATER_BALANCE, SNOW, WIND_X, WIND_Y, SEASON_COLUMN_COUNT
};
constexpr std::array<std::string_view, SEASON_COLUMN_COUNT> SEASON_COLUMNS{{
    "cell_terrain", "cell_landform", "cell_vegetation", "cell_cover",
    "cell_is_water", "cell_base_terrain", "cell_has_river", "cell_elevation",
    "cell_lat_norm", "cell_river_flow", "cell_temp", "cell_temp_365d",
    "cell_moisture", "cell_base_moisture", "cell_water_balance_30d",
    "cell_snow_cover", "cell_wind_x", "cell_wind_y"
}};

template<class Packed, class Value>
void copy_lane(Packed &target, const std::vector<Value> &source) {
    target.resize(static_cast<int64_t>(source.size()));
    if (!source.empty())
        std::memcpy(target.ptrw(), source.data(), source.size() * sizeof(Value));
}

template<class Value, class Packed>
void read_lane(std::vector<Value> &target, const Packed &source) {
    target.resize(static_cast<size_t>(source.size()));
    if (!target.empty())
        std::memcpy(target.data(), source.ptr(), target.size() * sizeof(Value));
}

double pass_interval(double date, double previous) {
    return previous >= 0.0 && date > previous ? std::min(date - previous, 30.0) : 1.0;
}

void take_climate_lanes(RuntimeEnvironmentSnapshot &next, const RuntimeClimateStore &current,
                        const RuntimeClimateKernel::Continuation &extra) {
    if (current.committed_day < 0) return;
    next.terrain = current.terrain;
    next.cover = current.cover;
    next.vegetation = current.vegetation;
    next.cell_temp = current.temperature;
    next.cell_temp_30d = current.temperature_30d_ema;
    next.cell_temp_365d = current.temperature_365d_ema;
    next.cell_moisture = current.moisture;
    next.cell_plant_available_water = current.plant_available_water;
    next.cell_water_balance_30d = current.water_balance_30d;
    next.cell_weather_precip = current.weather_precipitation;
    next.cell_weather_intensity = current.weather_intensity;
    next.cell_weather_type = current.weather_type;
    next.cell_snow_cover = current.snow_cover;
    next.cell_sea_ice_frac_prev = current.sea_ice;
    next.cell_vegetation_vitality = current.vegetation_vitality;
    if (!extra.soil.empty()) next.cell_soil_moisture = extra.soil;
    if (!extra.heat_input.empty()) next.cell_heat_input = extra.heat_input;
    if (!extra.insolation_dev.empty()) next.cell_insolation_dev = extra.insolation_dev;
}

} // namespace

struct RuntimeWorldEnvironment::State {
    explicit State(RuntimeEnvironmentSnapshot &&seed, const Dictionary &config)
        : opening(std::move(seed)), season_knobs(config.get("season", Dictionary())),
          water_lut(config.get("water_lut", PackedByteArray())),
          volcanoes(config.get("volcanoes", PackedByteArray())),
          calendar_committed{int64_t(config.get("climate_year", 0)),
                             int64_t(config.get("rng_state", 0)),
                             double(config.get("climate_anomaly", 0.0))},
          calendar_prepared(calendar_committed),
          days_per_year(std::max(1, int(config.get("days_per_year", 365)))),
          period(std::max(1, int(config.get("season_period", 30)))),
          albedo_stride(std::max(1, int(config.get("albedo_stride", 1)))),
          vegetation_stride(std::max(1, int(config.get("vegetation_stride", 1)))),
          feedback_stride(std::max(1, int(config.get("feedback_stride", 1)))),
          convergence_stride(std::clamp(int(config.get("convergence_stride", 1)), 1, 12)),
          volcano_landform(uint8_t(int(config.get("volcano_landform", 12)))),
          drift(double(config.get("climate_random_drift", 0.01))),
          anomaly_limit(double(config.get("climate_anomaly_max", 0.20))),
          ice_form(double(config.get("ice_form", 0.06))),
          ice_melt(double(config.get("ice_melt", 0.11))) {
        columns[RIVER_FLOW].arr_f32 = config.get("river_flow", PackedFloat32Array());
        rng.instantiate();
        rng->set_seed(uint64_t(int64_t(config.get("rng_seed", 0))));
        rng->set_state(uint64_t(calendar_committed.rng_state));
    }

    const char *refresh_season(RuntimeEnvironmentSnapshot &input, int64_t date,
                               const RuntimeClimateAuthority &climate);

    RuntimeEnvironmentSnapshot opening;
    Dictionary season_knobs;
    PackedByteArray water_lut, volcanoes;
    std::array<Slot, SEASON_COLUMN_COUNT> columns;
    std::shared_ptr<RuntimeEnvironmentSnapshot> prepared;
    std::shared_ptr<const RuntimeSeasonView> season, previous_season;
    RuntimeClimateCalendar calendar_committed, calendar_prepared;
    int days_per_year, period, albedo_stride, vegetation_stride, feedback_stride, convergence_stride;
    uint8_t volcano_landform;
    double drift, anomaly_limit, ice_form, ice_melt;
    Ref<RandomNumberGenerator> rng;
};

RuntimeWorldEnvironment::RuntimeWorldEnvironment(RuntimeEnvironmentSnapshot &&seed,
        const Dictionary &config) : _state(std::make_unique<State>(std::move(seed), config)) {}

RuntimeWorldEnvironment::~RuntimeWorldEnvironment() = default;

const char *RuntimeWorldEnvironment::State::refresh_season(RuntimeEnvironmentSnapshot &input,
        int64_t date, const RuntimeClimateAuthority &climate) {
    auto put_byte = [&](SeasonColumn column, const std::vector<uint8_t> &lane) {
        copy_lane(columns[column].arr_u8, lane);
    };
    auto put_float = [&](SeasonColumn column, const std::vector<float> &lane) {
        copy_lane(columns[column].arr_f32, lane);
    };
    put_byte(TERRAIN, input.terrain);
    put_byte(LANDFORM, input.landform);
    put_byte(VEGETATION, input.vegetation);
    put_byte(COVER, input.cover);
    put_byte(WATER, input.is_water);
    put_byte(BASE_TERRAIN, input.climate_round_input.base_terrain);
    put_byte(RIVER, input.has_river);
    put_float(ELEVATION, input.cell_elevation);
    put_float(LATITUDE, input.cell_lat_norm);
    put_float(TEMPERATURE, input.cell_temp);
    put_float(TEMPERATURE_YEAR, input.cell_temp_365d);
    put_float(MOISTURE, input.cell_moisture);
    put_float(BASE_MOISTURE, input.cell_base_moisture);
    put_float(WATER_BALANCE, input.cell_water_balance_30d);
    put_float(SNOW, input.cell_snow_cover);
    put_float(WIND_X, input.cell_wind_x);
    put_float(WIND_Y, input.cell_wind_y);
    const int season_index = int((date % days_per_year) * 4 / days_per_year);
    season_knobs["season_phase"] = double(season_index) + 0.5;
    SeasonStageArrays arrays(season_knobs);
    copy_lane(arrays.soil, input.cell_soil_moisture);
    copy_lane(arrays.growth_pressure, climate.store().vegetation_growth_pressure);
    const auto component = [](const char *name) -> int {
        const auto i = std::find(SEASON_COLUMNS.begin(), SEASON_COLUMNS.end(), name);
        return i == SEASON_COLUMNS.end() ? -1 : int(i - SEASON_COLUMNS.begin());
    };
    const auto slot = [&](int id) -> Slot & { return columns[static_cast<size_t>(id)]; };
    for (int index = 0; index < 12; ++index) {
        const int stage = season_kernel_stage(index);
        if (stage < 0) continue;
        auto pass = prepare_season_stage(component, slot, season_knobs, arrays, stage);
        if (pass.reason) return pass.reason;
        pass.compute();
    }
    read_lane(input.terrain, columns[TERRAIN].arr_u8);
    read_lane(input.landform, columns[LANDFORM].arr_u8);
    read_lane(input.cover, columns[COVER].arr_u8);
    read_lane(input.cell_moisture, columns[MOISTURE].arr_f32);
    read_lane(input.cell_base_moisture, columns[BASE_MOISTURE].arr_f32);
    read_lane(input.cell_snow_cover, columns[SNOW].arr_f32);
    read_lane(input.cell_soil_moisture, arrays.soil);
    auto view = season ? std::make_shared<RuntimeSeasonView>(*season)
                       : std::make_shared<RuntimeSeasonView>();
    view->day = input.day;
    const size_t count = input.cell_count;
    const size_t span = RuntimeSeasonView::HISTORY_LENGTH;
    const bool first_history = view->biome_history.empty();
    view->biome_history.resize(count * span);
    view->vegetation_history.resize(count * span);
    for (size_t cell = 0; cell < count; ++cell) {
        if (volcanoes.size() == static_cast<int64_t>(count) && volcanoes[cell] != 0) {
            input.landform[cell] = volcano_landform;
            input.military_base_landform[cell] = volcano_landform;
        }
        if (first_history) {
            std::fill_n(view->biome_history.begin() + cell * span, span, input.terrain[cell]);
            std::fill_n(view->vegetation_history.begin() + cell * span, span, input.vegetation[cell]);
        }
        view->biome_history[cell * span + view->history_next] = input.terrain[cell];
        view->vegetation_history[cell * span + view->history_next] = input.vegetation[cell];
    }
    view->history_next = (view->history_next + 1) % span;
    view->landform = input.landform;
    view->base_landform = input.military_base_landform;
    view->base_moisture = input.cell_base_moisture;
    previous_season = std::exchange(season, std::move(view));
    return nullptr;
}

std::shared_ptr<const RuntimeEnvironmentSnapshot> RuntimeWorldEnvironment::prepare(int64_t day,
        uint64_t generation, const RuntimeClimateAuthority &climate,
        const ModifierRuntime *modifiers, const NativeEconomyRuntime *economy,
        bool annual_report, const char *&error) {
    auto &state = *_state;
    if (state.prepared && state.prepared->day == day) return state.prepared;
    auto frame = std::make_shared<RuntimeEnvironmentSnapshot>(state.opening);
    auto &next = *frame;
    const auto &current = climate.store();
    const auto &extra = climate.continuation();
    next.day = day;
    next.generation = generation;
    const int64_t date = day + 1;
    const int64_t phase_date = annual_report && day % state.days_per_year == 0 ? day : date;
    next.season_phase = (double(phase_date % state.days_per_year) / state.days_per_year) * 4.0;
    state.calendar_committed = state.calendar_prepared;
    auto &calendar = state.calendar_prepared;
    const int64_t year = date / state.days_per_year;
    while (calendar.year < year) {
        calendar.anomaly = std::clamp(calendar.anomaly +
            double(state.rng->randf_range(-state.drift, state.drift)), -state.anomaly_limit, state.anomaly_limit);
        calendar.rng_state = static_cast<int64_t>(state.rng->get_state());
        ++calendar.year;
    }
    next.climate_anomaly = calendar.anomaly;
    take_climate_lanes(next, current, extra);
    if (state.season) {
        next.landform = state.season->landform;
        next.military_base_landform = state.season->base_landform;
        next.cell_base_moisture = state.season->base_moisture;
    }

    // CLM2 retains the original cursor order, including the calendar date of
    // the last refresh and the Stage B call count from before daily weather.
    auto &cursors = next.climate_capture_cursors;
    if (extra.capture_cursors.size() == cursors.size())
        cursors = extra.capture_cursors;
    auto &round = next.climate_round_input;
    round.scalars.season_phase = next.season_phase;
    round.scalars.si_dt_days = pass_interval(double(date), cursors[0]);
    round.scalars.thermal_dt_days = pass_interval(double(date), cursors[1]);
    cursors[0] = cursors[1] = cursors[2] = double(date);
    cursors[3] = round.scalars.thermal_dt_days;
    cursors[7] = double(day);
    const int64_t stage_b_call = static_cast<int64_t>(++cursors[8]);
    next.climate_season_refresh_ran = day > 1 &&
        (day - 1) % state.period == 0 && cursors[9] < double(date);
    if (next.climate_season_refresh_ran) {
        const auto physics = climate.copy_committed_physics();
        if (physics && physics->ready) {
            next.cell_wind_x = physics->wind_x;
            next.cell_wind_y = physics->wind_y;
        } else if (!current.physics_state.empty()) {
            pk_async_physics::RuntimeClimatePhysicsState restored;
            std::string restore_error;
            if (pk_async_physics::restore_physics_state(current.physics_state.data(),
                    current.physics_state.size(), restored, restore_error) && restored.ready) {
                next.cell_wind_x = std::move(restored.wind_x);
                next.cell_wind_y = std::move(restored.wind_y);
            }
        }
        error = state.refresh_season(next, date, climate);
        if (error) return {};
        if (economy) {
            const Dictionary settlements = economy_api::named_settlement_snapshot(*economy);
            const PackedInt32Array cells = settlements.get("cell_indices", PackedInt32Array());
            const PackedByteArray tiers = settlements.get("prosperity_tiers", PackedByteArray());
            next.military_settlement_tier.assign(next.cell_count, 0);
            for (int64_t i = 0; i < std::min(cells.size(), tiers.size()); ++i) {
                const int32_t cell = cells[i];
                if (cell >= 0 && static_cast<uint32_t>(cell) < next.cell_count)
                    next.military_settlement_tier[cell] = std::min(int(tiers[i]) + 1, 4);
            }
        }
        cursors[9] = cursors[10] = double(date);
    }
    for (size_t cell = 0; cell < next.terrain.size(); ++cell)
        next.is_water[cell] = state.water_lut[next.terrain[cell]];
    round.landform = next.landform;
    round.is_water = next.is_water;
    round.moisture = next.cell_moisture;
    round.base_moisture = next.cell_base_moisture;
    if (!Math::is_equal_approx(calendar.anomaly, 0.0)) {
        round.scalars.si_t_form = static_cast<float>(std::clamp(
            state.ice_form - 0.10 * calendar.anomaly, 0.0, 1.0));
        round.scalars.si_t_melt = static_cast<float>(std::clamp(
            state.ice_melt - 0.10 * calendar.anomaly, 0.0, 1.0));
    }
    if (modifiers) {
        for (uint32_t cell = 0; cell < next.cell_count; ++cell) {
            double add = 0.0, factor = 1.0;
            modifier_api::climate_radiative_terms(*modifiers, cell, add, factor);
            round.radiative_modifier_add[cell] = static_cast<float>(add);
            round.radiative_modifier_factor[cell] = static_cast<float>(factor);
        }
    }

    if (next.climate_weather) {
        auto weather = std::make_shared<pk_async_climate::WeatherFieldInput>(*next.climate_weather);
        weather->knobs.climate_anomaly = static_cast<float>(calendar.anomaly);
        weather->knobs.refresh_convergence = (day - 1) % state.convergence_stride == 0;
        weather->temp_read = next.cell_temp;
        weather->moisture_read = next.cell_moisture;
        weather->terrain = next.terrain;
        weather->vegetation = next.vegetation;
        next.climate_weather = std::move(weather);
    }
    if (next.climate_weather_distribute) {
        auto distribute = std::make_shared<pk_async_climate::WeatherDistributeInput>(
            *next.climate_weather_distribute);
        distribute->landform = next.landform;
        distribute->soil_moisture = next.cell_soil_moisture;
        next.climate_weather_distribute = std::move(distribute);
    }
    next.climate_albedo.ran = next.climate_albedo.ran && stage_b_call % state.albedo_stride == 0;
    if (next.climate_vegetation && stage_b_call % state.vegetation_stride == 0 &&
            cursors[9] != double(date)) {
        auto vegetation = std::make_shared<pk_async_climate::VegetationDynamicsInput>(*next.climate_vegetation);
        vegetation->is_water = next.is_water;
        vegetation->landform = next.landform;
        vegetation->terrain = next.terrain;
        vegetation->vegetation = next.vegetation;
        vegetation->temp_30d = next.cell_temp_30d;
        vegetation->moisture = next.cell_moisture;
        vegetation->water_balance_30d = next.cell_water_balance_30d;
        vegetation->soil_moisture = next.cell_soil_moisture;
        next.climate_vegetation = std::move(vegetation);
    } else next.climate_vegetation.reset();
    if (next.climate_feedback && stage_b_call % state.feedback_stride == 0) {
        auto feedback = std::make_shared<pk_async_climate::ClimateFeedbackInput>(*next.climate_feedback);
        feedback->knobs.write_weather_veg_pressure = !next.climate_vegetation;
        feedback->is_water = next.is_water;
        feedback->base_moisture = next.cell_base_moisture;
        feedback->soil_moisture = next.cell_soil_moisture;
        next.climate_feedback = std::move(feedback);
    } else next.climate_feedback.reset();

    if (next.economy_input) {
        auto economy_input = std::make_shared<RuntimeEconomyDayInput>(*next.economy_input);
        economy_input->day = day;
        economy_input->geography[0] = next.terrain;
        economy_input->geography[1] = next.landform;
        economy_input->geography[2] = next.vegetation;
        economy_input->geography[3] = next.is_water;
        next.economy_input = std::move(economy_input);
    }
    state.prepared = frame;
    return frame;
}

std::shared_ptr<const RuntimeSeasonView> RuntimeWorldEnvironment::season_view(int64_t day) const {
    const auto &state = *_state;
    return state.season && state.season->day <= day ? state.season : state.previous_season;
}

RuntimeClimateCalendar RuntimeWorldEnvironment::calendar(int64_t day) const {
    const auto &state = *_state;
    return state.prepared && state.prepared->day > day ? state.calendar_committed : state.calendar_prepared;
}

} // namespace pk
