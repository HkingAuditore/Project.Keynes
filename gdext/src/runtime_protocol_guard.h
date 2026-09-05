#pragma once

#include "runtime_pod_protocol.h"

#include <string>

namespace pk {

// Protocol-only regression checks.  This type intentionally has no Host or
// Godot dependency so the fixed-capacity and gate contracts can be validated
// in a native unit/self-test without starting a simulation worker.
class RuntimeProtocolGuard {
public:
    static bool self_test(std::string &error);

private:
    static bool validate_command(const RuntimeCommandPacket &packet,
                                 std::string &error);
    static bool command_less(const RuntimeCommandPacket &lhs,
                             const RuntimeCommandPacket &rhs) noexcept;
};

} // namespace pk
