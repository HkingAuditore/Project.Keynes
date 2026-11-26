// Shared helpers used by the native per-domain authority stages.

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;

void copy_text(char (&destination)[64], const char *source) noexcept {
    size_t i = 0;
    if (source != nullptr) {
        for (; i + 1u < sizeof(destination) && source[i] != '\0'; ++i)
            destination[i] = source[i];
    }
    destination[i] = '\0';
    for (++i; i < sizeof(destination); ++i) destination[i] = '\0';
}

double elapsed_ms(const std::chrono::steady_clock::time_point start) noexcept {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
}
