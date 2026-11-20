#pragma once
#include <godot_cpp/variant/dictionary.hpp>
namespace pk {
class NativeSimulationHost;
struct RuntimeGoldenSnapshot;
godot::Dictionary runtime_golden_dictionary(const RuntimeGoldenSnapshot &snapshot);
void append_runtime_golden_report(const NativeSimulationHost *host, godot::Dictionary &report);
} // namespace pk
