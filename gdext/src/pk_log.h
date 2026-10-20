#pragma once

// Godot-free logging for translation units that must never touch godot-cpp.
//
// Why this exists
// ---------------
// `tests/runtime_worker_source_scan_test.gd` treats a list of sources as a
// purity contract: these files run on worker threads, and any `godot::` symbol in
// them is a cross-thread call into the engine, which the engine forbids outright.
// The scan is whole-file, so one `godot::UtilityFunctions::print` is enough to
// fail it even if that particular call happens to run on the main thread.
//
// `native_simulation_host.cpp` used `godot::vformat` + `UtilityFunctions::print`
// in 35 places. Two things were wrong with that:
//   1. it blocked the purity rule, and
//   2. `vformat` only understands `{}` placeholders, while every call site wrote
//      printf specifiers (`%d`, `%s`, `%x`) -- so the diagnostics have been
//      printing literal `%d` instead of values for as long as they have existed.
//
// Using `vsnprintf` here fixes both at once: the format strings already are
// printf-style, and stdio is thread-safe.
//
// Deliberately NOT Godot-free-by-accident: no `String`, no `Variant`, no
// `godot::` anywhere in this header. Keep it that way or the scan test will
// start failing on a file nobody expects.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>

namespace pk {

namespace detail {

inline std::mutex &log_mutex() {
    static std::mutex mutex;
    return mutex;
}

// 4 KiB covers every message in this file with room to spare; a longer one is
// truncated rather than reallocated, because a truncated diagnostic still tells
// you where you are.
constexpr int LOG_BUFFER_SIZE = 4096;

inline std::string format_va(const char *fmt, va_list args) {
    if (fmt == nullptr) return std::string();
    char buffer[LOG_BUFFER_SIZE];
    va_list copy;
    va_copy(copy, args);
    const int written = std::vsnprintf(buffer, sizeof(buffer), fmt, copy);
    va_end(copy);
    if (written <= 0) return std::string();
    const size_t length = static_cast<size_t>(written) < sizeof(buffer) - 1
        ? static_cast<size_t>(written)
        : sizeof(buffer) - 1;
    return std::string(buffer, length);
}

inline void write_line(FILE *stream, const char *fmt, va_list args) {
    const std::string line = format_va(fmt, args);
    if (line.empty()) return;
    std::lock_guard<std::mutex> lock(log_mutex());
    std::fwrite(line.data(), 1, line.size(), stream);
    std::fputc('\n', stream);
    std::fflush(stream);
}

}  // namespace detail

// Formats without emitting. Use when the same text has to go to two streams
// (the Godot console hides stderr-only lines, so the fault paths write to both).
inline std::string log_format(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::string out = detail::format_va(fmt, args);
    va_end(args);
    return out;
}

inline void log_info(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    detail::write_line(stdout, fmt, args);
    va_end(args);
}

inline void log_error(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    detail::write_line(stderr, fmt, args);
    va_end(args);
}

// Emits an already-formatted line to one stream.
inline void log_line(const std::string &line, bool to_stderr = false) {
    if (line.empty()) return;
    std::lock_guard<std::mutex> lock(detail::log_mutex());
    FILE *stream = to_stderr ? stderr : stdout;
    std::fwrite(line.data(), 1, line.size(), stream);
    std::fputc('\n', stream);
    std::fflush(stream);
}

}  // namespace pk
