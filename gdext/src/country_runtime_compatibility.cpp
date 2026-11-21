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
    // PKCN restores the Economy input replica. The Effect request identities
    // were restored from CPD2 and may still refer to pending Host commands.
    candidate._effect_command_idempotency = std::move(_effect_command_idempotency);
    candidate._effect_command_results = std::move(_effect_command_results);
    candidate._effect_host_request_map = std::move(_effect_host_request_map);
    candidate._effect_host_receipt_cursor = _effect_host_receipt_cursor;
    candidate._next_effect_request_id = _next_effect_request_id;
    *this = std::move(candidate);
    return true;
}

} // namespace pk
