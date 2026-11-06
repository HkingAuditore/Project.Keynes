#include "runtime_climate_kernel.h"

namespace pk {

void RuntimeClimateKernel::capture_continuation(Continuation &out) const {
    out.soil = _distribute_soil_scratch;
    out.insolation_now = _round_out.insolation_now;
    out.insolation_dev = _round_out.insolation_dev;
    out.heat_input = _round_out.heat_input;
    out.day_length = _round_out.day_length;
    out.temp_season_offset = _round_out.temp_season_offset;
    out.conv_inhib = _weather_conv_inhib;
    out.accumulated_snow_days = _distribute_acc_snow_scratch;
    out.pre_snow_cover = _distribute_pre_cover_scratch;
    out.field_init = _weather_field_init_scratch;
    out.field_init_seeded = _weather_field_init_seeded;
}

void RuntimeClimateKernel::restore_continuation(const Continuation &state) {
    _distribute_soil_scratch = state.soil;
    _round_out.insolation_now = state.insolation_now;
    _round_out.insolation_dev = state.insolation_dev;
    _round_out.heat_input = state.heat_input;
    _round_out.day_length = state.day_length;
    _round_out.temp_season_offset = state.temp_season_offset;
    _weather_conv_inhib = state.conv_inhib;
    _distribute_acc_snow_scratch = state.accumulated_snow_days;
    _distribute_pre_cover_scratch = state.pre_snow_cover;
    _weather_field_init_scratch = state.field_init;
    _weather_field_init_seeded = state.field_init_seeded;
    // plan_day snapshots these four lanes before calculating the next day.
    _committed_soil.clear();
    _committed_insolation_now.clear();
    _committed_insolation_dev.clear();
    _committed_heat_input.clear();
}

} // namespace pk
