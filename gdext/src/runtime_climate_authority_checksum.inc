// CLM2 payload checksum shared by the codec and compatibility tests.

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t checksum(const uint8_t *bytes, size_t size) {
    uint64_t value = FNV_OFFSET;
    for (size_t i = 0; i < size; ++i) {
        value ^= bytes[i];
        value *= FNV_PRIME;
    }
    return value;
}
