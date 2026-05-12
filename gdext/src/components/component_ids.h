#pragma once

// Component IDs mirrored from `scripts/data_core/component_ids.gd`.
//
// IMPORTANT: this header MUST stay in sync with the GDScript-side
// `DCComponentIds` autoload. The numeric values are NOT load-bearing on the
// C++ side — DCWorldExt looks up component slots by the StringName name at
// `register_component()` time, just like the GDScript version. These constants
// exist purely so C++ hot-loop code reads as `CELL_TEMP` instead of a magic
// integer.
//
// When adding a new component:
//   1. add the constant + StringName below
//   2. add it to DCComponentIds.gd
//   3. register it from GDScript via `world.register_component(...)`
//      (DCWorldExt is a thin wrapper around the same registry, so a single
//       call site suffices)

#include <godot_cpp/variant/string_name.hpp>

namespace pk {

// ---- cell-level components (climate / terrain / ocean / weather mirrors) ----
inline constexpr int CELL_TEMP                       = 0;
inline constexpr int CELL_MOISTURE                   = 1;
inline constexpr int CELL_SNOW_COVER                 = 2;
inline constexpr int CELL_WEATHER_INTENSITY          = 3;
inline constexpr int CELL_CLIMATE_DIRTY              = 4;
inline constexpr int CELL_ELEVATION                  = 5;
inline constexpr int CELL_LATITUDE_DEG               = 6;
inline constexpr int CELL_IS_WATER                   = 7;
inline constexpr int CELL_IS_OCEAN                   = 8;
inline constexpr int CELL_OCEAN_TEMP                 = 9;
inline constexpr int CELL_OCEAN_SALINITY             = 10;
inline constexpr int CELL_SEA_ICE                    = 11;
inline constexpr int CELL_VEGETATION                 = 12;
inline constexpr int CELL_TERRAIN                    = 13;
inline constexpr int CELL_WIND_VECTOR                = 14; // stride=2 (x,y)
inline constexpr int CELL_WEATHER_VAPOR              = 15;
inline constexpr int CELL_WEATHER_CONVERGENCE        = 16;
inline constexpr int CELL_WEATHER_INSTABILITY        = 17;
inline constexpr int CELL_WEATHER_FIELD_INIT         = 18;
inline constexpr int CELL_AIR_MASS_TEMP_ANOMALY      = 19;
inline constexpr int CELL_HAS_RIVER                  = 20;

// ---- weather-front-level components (the second pool) ----
inline constexpr int FRONT_INTENSITY                 = 21;
inline constexpr int FRONT_RADIUS                    = 22;
inline constexpr int FRONT_POSITION                  = 23; // stride=2

// ---- pool names (StringName helpers; instantiated lazily) ----
inline godot::StringName pool_cells()         { return godot::StringName("cells"); }
inline godot::StringName pool_weather_fronts(){ return godot::StringName("weather_fronts"); }

} // namespace pk
