#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace pk {

struct RuntimeVisionFrame {
    int64_t day = -1;
    uint64_t revision = 0;
    bool fog_enabled = false;
    std::vector<uint8_t> visible;
    std::vector<uint8_t> explored;
    std::vector<uint8_t> fog;
    int32_t source_count = 0;
    int32_t military_source_count = 0;
    int32_t visible_count = 0;
    int32_t explored_count = 0;
    double elapsed_ms = 0;
};

struct VisionResearchState {
    int32_t cell_count = 0;
    std::vector<int32_t> neighbors;
    std::vector<uint8_t> view_height;
    std::vector<uint8_t> view_block;
    std::vector<int32_t> signal_offsets;
    std::vector<int32_t> signal_ids;
    std::vector<int32_t> bit_to_signal = std::vector<int32_t>(32, -1);
    std::vector<uint8_t> eligibility;
    std::vector<int32_t> owners;
    std::vector<int32_t> military_sources;
    std::vector<uint8_t> all_visible;
    std::shared_ptr<const RuntimeVisionFrame> frame;
    int32_t player_slot = -1;
    uint64_t player_handle = 0;
    int32_t remote_technology = -1;
    bool remote = false;
    bool fog_available = false;
    bool fog_enabled = false;
};

// VISUAL command carried by the existing sealed and persisted command queue.
constexpr uint16_t RUNTIME_VISUAL_SET_FOG = 1;

} // namespace pk
