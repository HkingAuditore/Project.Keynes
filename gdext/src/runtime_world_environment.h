#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

class ModifierRuntime;
class NativeEconomyRuntime;
class RuntimeClimateAuthority;
struct RuntimeEnvironmentSnapshot;

struct RuntimeClimateCalendar {
    int64_t year = 0;
    int64_t rng_state = 0;
    double anomaly = 0.0;
};

struct RuntimeSeasonView {
    static constexpr size_t HISTORY_LENGTH = 8;
    int64_t day = -1;
    std::vector<float> base_moisture;
    std::vector<uint8_t> landform, base_landform;
    std::vector<uint8_t> biome_history, vegetation_history;
    size_t history_next = 0;
};

// The startup adapter supplies the opening geography and immutable profile.
// Subsequent inputs are derived here from the last committed simulation day.
class RuntimeWorldEnvironment {
public:
    RuntimeWorldEnvironment(RuntimeEnvironmentSnapshot &&seed,
                            const godot::Dictionary &config);
    ~RuntimeWorldEnvironment();
    std::shared_ptr<const RuntimeEnvironmentSnapshot> prepare(
        int64_t day, uint64_t generation, const RuntimeClimateAuthority &climate,
        const ModifierRuntime *modifiers, const NativeEconomyRuntime *economy,
        bool annual_report, const char *&error);

    std::shared_ptr<const RuntimeSeasonView> season_view(int64_t day) const;
    std::vector<uint8_t> capture_season_history(int64_t day) const;
    bool restore_season_history(const std::vector<uint8_t> &bytes, int64_t day);
    RuntimeClimateCalendar calendar(int64_t day) const;
    const RuntimeEnvironmentSnapshot &narrative_geography() const;
    const std::vector<uint8_t> &opening_landform() const;
    const uint8_t *water_terrain_lookup() const;

private:
    struct State;
    std::unique_ptr<State> _state;
};

} // namespace pk
