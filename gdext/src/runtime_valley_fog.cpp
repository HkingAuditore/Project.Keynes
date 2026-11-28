#include "runtime_valley_fog.h"

#include "runtime_climate_pass_math.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <limits>
#include <utility>

namespace pk {
namespace {

constexpr float HUMIDITY_START = 0.30f;
constexpr float HUMIDITY_FULL = 0.62f;
// The committed wind lane uses surface-wind units. In both calibration seeds
// the ordinary land wind P10 is about 1.2 and P90 about 1.95.
constexpr float WIND_CALM = 1.20f;
constexpr float WIND_DISPERSE = 2.05f;
constexpr float FLAT_THICKNESS = 0.018f;
constexpr float VALLEY_THICKNESS = 0.055f;

float smoothstep(float low, float high, float value) {
    const float t = std::clamp((value - low) / (high - low), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

} // namespace

RuntimeValleyFogTerrain::RuntimeValleyFogTerrain(int32_t width, int32_t height,
        uint64_t terrain_generation, uint64_t map_id, std::vector<int32_t> offset_to_index,
        const std::vector<float> &elevation, const std::vector<uint8_t> &water,
        const std::vector<int32_t> &neighbors)
    : _width(width), _height(height), _terrain_generation(terrain_generation), _map_id(map_id) {
    const size_t count = elevation.size();
    if (width <= 0 || height <= 0 || uint64_t(width) * uint64_t(height) != count ||
        offset_to_index.size() != count || water.size() != count || neighbors.size() != count * 6 ||
        map_id == 0) return;

    // Refuse the whole field if its grid layout is incomplete or ambiguous.
    std::vector<uint8_t> seen(count, 0);
    for (const int32_t cell : offset_to_index) {
        if (cell < 0 || size_t(cell) >= count || seen[cell] || !std::isfinite(elevation[cell])) return;
        seen[cell] = 1;
    }
    _offset_to_index = std::move(offset_to_index);
    _references.resize(count);
    for (size_t cell = 0; cell < count; ++cell) {
        auto &reference = _references[cell];
        const float center = std::clamp(elevation[cell], 0.0f, 1.0f);
        reference.floor = center;
        reference.land = water[cell] == 0;
        if (!reference.land) continue;

        // Two hex rings contain at most 19 unique cells. Use the world's own
        // neighbor table for wrap/crop and deduplicate along short wrap periods.
        std::array<size_t, 19> visited{};
        visited[0] = cell;
        size_t visited_count = 1;
        size_t ring_end = 1;
        size_t parent = 0;
        for (int ring = 0; ring < 2; ++ring) {
            for (; parent < ring_end; ++parent) {
                for (size_t d = 0; d < 6; ++d) {
                    const int32_t candidate = neighbors[visited[parent] * 6 + d];
                    const auto end = visited.begin() + visited_count;
                    if (candidate < 0 || size_t(candidate) >= count || end == visited.end() ||
                        std::find(visited.begin(), end, size_t(candidate)) != end) continue;
                    visited[visited_count++] = size_t(candidate);
                }
            }
            ring_end = visited_count;
        }
        std::array<float, 19> land_heights{};
        size_t land_count = 0;
        float sum = 0.0f;
        for (size_t i = 0; i < visited_count; ++i) {
            const size_t neighbor = visited[i];
            if (water[neighbor] != 0) continue;
            const float h = std::clamp(elevation[neighbor], 0.0f, 1.0f);
            land_heights[land_count++] = h;
            sum += h;
        }
        const size_t lower_quartile = (land_count - 1) / 4;
        std::nth_element(land_heights.begin(), land_heights.begin() + lower_quartile,
            land_heights.begin() + land_count);
        reference.floor = std::min(center, land_heights[lower_quartile]);
        const float relief = sum / float(land_count) - center;
        reference.depression = smoothstep(0.003f, 0.065f, relief);
    }
}

std::shared_ptr<const RuntimeValleyFogFrame> RuntimeValleyFogTerrain::build(uint64_t generation,
        const std::vector<float> &elevation, const std::vector<float> &temperature,
        const std::vector<float> &vapor, const std::vector<float> &wind) const {
    const size_t count = _references.size();
    if (generation == 0 || count == 0 || elevation.size() != count ||
        temperature.size() != count || vapor.size() != count || wind.size() != count) return {};

    auto frame = std::make_shared<RuntimeValleyFogFrame>();
    frame->generation = generation;
    frame->terrain_generation = _terrain_generation;
    frame->map_id = _map_id;
    frame->width = _width;
    frame->height = _height;
    frame->rg.resize(count * 2);
    for (size_t offset = 0; offset < count; ++offset) {
        const size_t cell = size_t(_offset_to_index[offset]);
        if (!std::isfinite(temperature[cell]) || !std::isfinite(vapor[cell]) ||
            !std::isfinite(wind[cell])) return {};
        const auto &reference = _references[cell];
        float density = 0.0f;
        float top = reference.floor;
        if (reference.land) {
            const float capacity = weather_vapor_capacity(
                std::clamp(temperature[cell], 0.0f, 1.0f), elevation[cell]);
            const float humidity = std::max(0.0f, vapor[cell] / capacity);
            const float saturation = smoothstep(HUMIDITY_START, HUMIDITY_FULL, humidity);
            const float calm = 1.0f - smoothstep(WIND_CALM, WIND_DISPERSE, wind[cell]);
            const float potential = saturation * calm;
            density = potential * (0.60f + 0.40f * reference.depression);
            const float thickness = FLAT_THICKNESS +
                (VALLEY_THICKNESS - FLAT_THICKNESS) * reference.depression;
            top = std::min(1.0f, top + thickness * potential);
        }
        frame->rg[offset * 2] = density;
        frame->rg[offset * 2 + 1] = top;
        frame->has_density |= density > 0.0f;
    }
    return frame;
}

bool RuntimeValleyFogTerrain::self_test() {
    // Offset order is deliberately different from the weather lane order.
    const std::vector<int32_t> offsets{1, 2, 0};
    const std::vector<float> elevation{0.70f, 0.60f, 0.10f};
    const std::vector<uint8_t> water{0, 0, 1};
    std::vector<int32_t> neighbors{1, -1, -1, 2, -1, -1,
        2, -1, -1, 0, -1, -1, 0, -1, -1, 1, -1, -1};
    const RuntimeValleyFogTerrain terrain(3, 1, 9, 12, offsets, elevation, water, neighbors);
    const std::vector<float> temp(3, 0.5f), wet(3, 0.35f), dry(3, 0.01f);
    const std::vector<float> calm(3, 1.10f), gust(3, 2.20f);
    const auto fog = terrain.build(1, elevation, temp, wet, calm);
    const auto dry_frame = terrain.build(2, elevation, temp, dry, calm);
    const auto gust_frame = terrain.build(2, elevation, temp, wet, gust);
    const auto rebuilt = terrain.build(1, elevation, temp, wet, calm);
    if (!fog || !dry_frame || !gust_frame || !rebuilt || fog->rg != rebuilt->rg ||
        fog->map_id != 12 || fog->terrain_generation != 9 || fog->generation != 1 ||
        fog->width != 3 || fog->height != 1 || !fog->has_density ||
        fog->rg[0] <= 0.0f || fog->rg[1] <= elevation[1] ||
        fog->rg[2] != 0.0f || fog->rg[3] != elevation[2] ||
        fog->rg[5] >= elevation[0] || dry_frame->has_density || gust_frame->has_density ||
        dry_frame->rg[1] != elevation[1] || gust_frame->rg[1] != elevation[1]) return false;

    const RuntimeValleyFogTerrain invalid(3, 1, 9, 12, {0, 0, 2}, elevation, water, neighbors);
    const auto nan = std::numeric_limits<float>::quiet_NaN();
    return !invalid.build(1, elevation, temp, wet, calm) &&
        !terrain.build(0, elevation, temp, wet, calm) &&
        !terrain.build(1, elevation, temp, wet, {}) &&
        !terrain.build(1, elevation, temp, {0.3f, nan, 0.3f}, calm);
}

} // namespace pk
