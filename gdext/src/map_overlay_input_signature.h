#pragma once

#include <array>
#include <cstdint>
#include <cstring>

namespace pk {

// Presentation only. Mix the bits of every published float in cell order.
// Keep two 64-bit accumulators; the keys never enter a save or a simulation hash.
struct MapOverlayInputSignature {
    std::array<uint64_t, 2> words{14695981039346656037ull, 0x9e3779b97f4a7c15ull};

    void add(float value) {
        uint32_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        words[0] = (words[0] ^ bits) * 1099511628211ull;
        words[1] = (words[1] + bits) * 0x9e3779b185ebca87ull;
    }
};

} // namespace pk
