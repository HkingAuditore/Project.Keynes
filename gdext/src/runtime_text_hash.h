#pragma once

#include <cstdint>

namespace pk {
// FNV-1a over a NUL-terminated catalog key: the one definition shared by the
// Effect program catalog and the Country technology effect keys, so a key
// hashed on the main thread finds its program on the worker.
inline uint64_t runtime_text_hash(const char *text) noexcept {
    uint64_t hash = 1469598103934665603ull;
    if (text == nullptr) return hash;
    for (const unsigned char *c = reinterpret_cast<const unsigned char *>(text);
         *c != 0; ++c) {
        hash ^= *c;
        hash *= 1099511628211ull;
    }
    return hash;
}
} // namespace pk
