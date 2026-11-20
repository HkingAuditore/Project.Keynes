#pragma once

#include <cstdint>

namespace pk {

// Water tiers shared by the economy trade corridors and the military crossing
// gate. A cell's tier comes from its landform: lake -> shallow -> far -> deep.
// The values deliberately equal NativeEconomyRuntime::WATER_CLASS_* so both
// domains answer "what kind of water is this cell" with one table.
enum WaterTier : uint8_t {
    WATER_TIER_NONE = 0,
    WATER_TIER_LAKE = 1,
    WATER_TIER_SHALLOW = 2,
    WATER_TIER_FAR = 3,
    WATER_TIER_DEEP = 4,
};

// LandformType ids of the four water landforms (scripts/geography/landform_type.gd).
constexpr uint8_t kWaterLandformDeepOcean = 0;
constexpr uint8_t kWaterLandformOcean = 1;
constexpr uint8_t kWaterLandformCoast = 2;
constexpr uint8_t kWaterLandformLake = 3;

// Land forms answer WATER_TIER_NONE; callers must already know the cell is water
// (the landform table alone cannot tell a dry PLAIN from a flooded one).
inline uint8_t water_tier_from_landform(uint8_t landform) {
    switch (landform) {
        case kWaterLandformDeepOcean: return WATER_TIER_DEEP;
        case kWaterLandformOcean: return WATER_TIER_FAR;
        case kWaterLandformCoast: return WATER_TIER_SHALLOW;
        case kWaterLandformLake: return WATER_TIER_LAKE;
        default: return WATER_TIER_NONE;
    }
}

}  // namespace pk
