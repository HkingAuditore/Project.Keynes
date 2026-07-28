#include "world_ext.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "modifier_runtime.h"

#include <cstring>
#include <vector>

namespace pk {

using namespace godot;

namespace {
ModifierRuntime *runtime_from(void *opaque) {
    return static_cast<ModifierRuntime *>(opaque);
}
const ModifierRuntime *runtime_from(const void *opaque) {
    return static_cast<const ModifierRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "modifier_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_modifiers(const Dictionary &catalog,
                                           int cell_count) {
    if (_modifier_runtime == nullptr) _modifier_runtime = new ModifierRuntime();
    ModifierRuntime *runtime = runtime_from(_modifier_runtime);
    runtime->attach_country_runtime(static_cast<NativeCountryRuntime *>(_country_runtime));
    if (_country_runtime != nullptr)
        static_cast<NativeCountryRuntime *>(_country_runtime)->attach_modifier_runtime(runtime);
    if (_economy_runtime != nullptr)
        static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_modifier_runtime(runtime);
    return runtime->configure(catalog, cell_count);
}

Dictionary DCWorldExt::submit_modifier_commands(const Dictionary &packed_batch) {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->submit_commands(packed_batch);
}

Dictionary DCWorldExt::run_modifier_daily(int64_t day_index) {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->run_daily(day_index);
}

bool DCWorldExt::modifier_should_run(int64_t day_index) const {
    return _modifier_runtime != nullptr &&
        runtime_from(_modifier_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_modifier_command_result(int64_t request_id) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->command_result(request_id);
}

Dictionary DCWorldExt::list_modifiers(int domain, int64_t entity_handle,
                                      const String &stat_key) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->list_modifiers(
            domain, static_cast<uint64_t>(entity_handle), stat_key);
}

Dictionary DCWorldExt::explain_modifier_stat(int domain, int64_t entity_handle,
                                             int64_t group_handle,
                                             const String &stat_key,
                                             double base_value) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->explain(domain,
            static_cast<uint64_t>(entity_handle), static_cast<uint64_t>(group_handle),
            stat_key, base_value);
}

Dictionary DCWorldExt::get_modifier_report() const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->report();
}

Dictionary DCWorldExt::poll_modifier_events(int64_t after_event_id,
                                            int limit) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->poll_events(after_event_id, limit);
}

double DCWorldExt::evaluate_modifier_stat(int domain, int64_t entity_handle,
                                          int64_t group_handle,
                                          const String &stat_key,
                                          double base_value) const {
    return _modifier_runtime == nullptr ? base_value
        : runtime_from(_modifier_runtime)->effective_value(domain,
            stat_key.utf8().get_data(), static_cast<uint64_t>(entity_handle),
            static_cast<uint64_t>(group_handle), base_value);
}

int64_t DCWorldExt::register_gameplay_modifier_object(const String &archetype) {
    return _modifier_runtime == nullptr ? 0 : static_cast<int64_t>(
        runtime_from(_modifier_runtime)->register_gameplay_object(
            archetype.utf8().get_data()));
}

Dictionary DCWorldExt::unregister_gameplay_modifier_object(int64_t handle,
                                                           int64_t day_index) {
    if (_modifier_runtime == nullptr) return unavailable();
    Dictionary out;
    out["ok"] = runtime_from(_modifier_runtime)->unregister_gameplay_object(
        static_cast<uint64_t>(handle), day_index);
    out["reason"] = static_cast<bool>(out["ok"]) ? "" :
        "modifier_gameplay_handle_stale";
    return out;
}

Dictionary DCWorldExt::set_gameplay_modifier_base(int64_t handle,
                                                  const String &stat_key,
                                                  double value) {
    if (_modifier_runtime == nullptr) return unavailable();
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->set_gameplay_base(
        static_cast<uint64_t>(handle), stat_key.utf8().get_data(), value, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::get_gameplay_modifier_effective(int64_t handle,
                                                       int64_t group_handle,
                                                       const String &stat_key) const {
    if (_modifier_runtime == nullptr) return unavailable();
    double value = 0.0;
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->gameplay_effective(
        static_cast<uint64_t>(handle), static_cast<uint64_t>(group_handle),
        stat_key.utf8().get_data(), value, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    out["effective_value"] = value;
    return out;
}

PackedByteArray DCWorldExt::capture_modifier_domain(int domain) const {
    PackedByteArray out;
    if (_modifier_runtime == nullptr) return out;
    std::vector<uint8_t> bytes;
    std::string error;
    if (!runtime_from(_modifier_runtime)->serialize_domain(domain, bytes, error))
        return out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

Dictionary DCWorldExt::restore_modifier_domain(int domain,
                                               const PackedByteArray &bytes) {
    if (_modifier_runtime == nullptr) return unavailable();
    std::vector<uint8_t> native(static_cast<size_t>(bytes.size()));
    if (!native.empty()) std::memcpy(native.data(), bytes.ptr(), native.size());
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->restore_domain(domain, native, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::clear_modifier_domain(int domain) {
    if (_modifier_runtime == nullptr) return unavailable();
    if (domain < 0 || domain >= ModifierRuntime::DOMAIN_COUNT)
        return unavailable();
    runtime_from(_modifier_runtime)->clear_domain(domain);
    Dictionary out;
    out["ok"] = true;
    out["domain"] = domain;
    out["migration"] = "legacy_empty_modifier_store";
    return out;
}

float DCWorldExt::modifier_climate_radiative_target(int cell,
                                                    float base_value) const {
    return _modifier_runtime == nullptr ? base_value
        : runtime_from(_modifier_runtime)->climate_radiative_target(cell, base_value);
}

double DCWorldExt::modifier_country_output_factor(int64_t country_handle) const {
    return _modifier_runtime == nullptr ? 1.0
        : runtime_from(_modifier_runtime)->country_economy_output_factor(
            static_cast<uint64_t>(country_handle));
}

int64_t DCWorldExt::ensure_modifier_building_handle(int cell, int type_id,
                                                    int owner_signature_id) {
    return _modifier_runtime == nullptr ? 0 : static_cast<int64_t>(
        runtime_from(_modifier_runtime)->ensure_building_identity(
            cell, type_id, owner_signature_id));
}

double DCWorldExt::modifier_building_output_factor(int64_t building_handle,
                                                   int64_t country_handle) const {
    return _modifier_runtime == nullptr ? 1.0
        : runtime_from(_modifier_runtime)->economy_building_output_factor(
            static_cast<uint64_t>(building_handle),
            static_cast<uint64_t>(country_handle));
}

} // namespace pk
