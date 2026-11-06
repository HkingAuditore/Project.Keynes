// Restore the non-authoritative input replica only after validating the saved
// authoritative Country identity. No peer callbacks or Modifier restore occur.
#include "country_runtime.h"

namespace pk {
bool NativeCountryRuntime::restore_compatibility_state(
        const std::vector<uint8_t> &bytes, std::string &error) {
    if (bytes.empty()) return true;
    NativeCountryRuntime candidate(*this);
    candidate._modifier_runtime = nullptr;
    if (!candidate.decode_save_in_place(bytes, error)) return false;
    candidate._modifier_runtime = _modifier_runtime;
    *this = std::move(candidate);
    return true;
}

} // namespace pk
