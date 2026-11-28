#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace pk {

struct RuntimeValleyFogFrame {
    uint64_t generation = 0;
    uint64_t terrain_generation = 0;
    uint64_t map_id = 0;
    int32_t width = 0;
    int32_t height = 0;
    bool has_density = false;
    // Offset rows, interleaved normalized density and normalized fog top.
    std::vector<float> rg;
};

// Derived display-only data. Its topology and geographical lanes are frozen
// when the world's environment is installed.
class RuntimeValleyFogTerrain {
public:
    RuntimeValleyFogTerrain(int32_t width, int32_t height, uint64_t terrain_generation,
        uint64_t map_id, std::vector<int32_t> offset_to_index, const std::vector<float> &elevation,
        const std::vector<uint8_t> &water, const std::vector<int32_t> &neighbors);

    std::shared_ptr<const RuntimeValleyFogFrame> build(uint64_t generation,
        const std::vector<float> &elevation, const std::vector<float> &temperature,
        const std::vector<float> &vapor, const std::vector<float> &wind) const;

    static bool self_test();

private:
    struct Reference {
        float floor = 0.0f;
        float depression = 0.0f;
        bool land = false;
    };

    int32_t _width = 0;
    int32_t _height = 0;
    uint64_t _terrain_generation = 0;
    uint64_t _map_id = 0;
    std::vector<int32_t> _offset_to_index;
    std::vector<Reference> _references;
};

} // namespace pk
