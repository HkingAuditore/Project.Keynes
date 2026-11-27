#pragma once

#include <chrono>

namespace pk::economy_publish_detail {

using Clock = std::chrono::steady_clock;

inline double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

} // namespace pk::economy_publish_detail
