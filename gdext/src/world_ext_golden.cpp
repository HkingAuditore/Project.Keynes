#include "world_ext_golden.h"
#include <godot_cpp/variant/variant.hpp>
#include "native_simulation_host.h"
#include "runtime_golden_diagnostics.h"
#include <cstdlib>
#include <cstring>
#include <string>
#include "runtime_switch_registry.h"
namespace pk {
void append_runtime_golden_report(const NativeSimulationHost *host, godot::Dictionary &report) {
    const char *enabled = pk::runtime_switch_value(pk::RuntimeSwitch::PK_GOLDEN_DOMAINS);
    if (enabled == nullptr || std::strcmp(enabled, "1") != 0 || host == nullptr) return;
    report["golden_domains"] = runtime_golden_dictionary(host->golden_snapshot());
}

godot::Dictionary runtime_golden_dictionary(const RuntimeGoldenSnapshot &snapshot) {
    godot::Dictionary out;
    out["enabled"] = true;
    out["ready"] = snapshot.ready;
    out["day"] = snapshot.day;
    godot::Dictionary domains;
    for (const auto &domain : snapshot.domains) {
        godot::Dictionary row;
        row["state_day"] = domain.state_day;
        row["scope"] = domain.scope;
        row["hash"] = godot::String(std::to_string(domain.hash).c_str());
        domains[domain.id] = row;
    }
    out["domains"] = domains;
    if (snapshot.whole_economy_ready)
        out["whole_economy_hash"] = godot::String(std::to_string(
            static_cast<int64_t>(snapshot.whole_economy_hash)).c_str());
    return out;
}
} // namespace pk
