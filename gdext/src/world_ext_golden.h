#pragma once
#include <godot_cpp/variant/dictionary.hpp>
namespace pk {
class NativeSimulationHost;
void append_runtime_golden_report(const NativeSimulationHost *host, godot::Dictionary &report);
} // namespace pk
