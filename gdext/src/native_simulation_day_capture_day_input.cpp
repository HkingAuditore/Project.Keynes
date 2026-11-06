#include "native_simulation_day_context.h"
#include "economy_cost_probe.h"
#include "pk_log.h"
#include "runtime_switch_registry.h"
namespace pk {
bool NativeSimulationHost::capture_day_input(DayExecution &day, const RuntimeEnvironmentSnapshot &accepted) {
    auto &admitted_submit_order = day.admitted_submit_order;
    auto &climate_hashed_input = day.climate_hashed_input;
    auto &climate_hashed_input_hash = day.climate_hashed_input_hash;

    const uint64_t prior_generation =
        _input_capture_generation.load(std::memory_order_relaxed);
    const int64_t prior_day =
        _input_capture_day.load(std::memory_order_relaxed);
    if (prior_generation == accepted.generation &&
        prior_day == accepted.day) {
        _input_capture_reused.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    {
        RuntimeInputCaptureManifest manifest{};
        manifest.session_epoch = _country_worker_session_epoch;
        manifest.input_generation = accepted.generation;
        manifest.effective_day = accepted.day;
        manifest.map_generation = accepted.topology_generation;
        manifest.country_generation = _country_read_view_generation;
        manifest.building_generation = accepted.vision_revision;
        manifest.resource_generation = _economy_pod_input_generation.load(
            std::memory_order_relaxed);
        manifest.catalog_hash = accepted.climate_catalog_hash;
        manifest.command_watermark = admitted_submit_order;
        static const bool full_hash = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_RUNTIME_INPUT_HASH_FULL);
            return value && std::strcmp(value, "1") == 0;
        }();
        static const bool verify_hash = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_RUNTIME_INPUT_HASH_VERIFY);
            return value && std::strcmp(value, "1") == 0;
        }();
        const bool reused = !full_hash && climate_hashed_input == &accepted;
        uint64_t manifest_hash = reused ? climate_hashed_input_hash
            : RuntimeClimateKernel::input_hash(accepted);
        if (reused && verify_hash && manifest_hash != RuntimeClimateKernel::input_hash(accepted)) {
            set_fault("runtime_input_hash_reuse_mismatch");
            return false;
        }
        EconomyCostProbe::record("input_manifest.hash_reused", accepted.day, 0.0, reused ? 1 : 0);
        if (std::FILE *trace = sim_day_trace_file()) {
            SimTraceLock trace_lock(trace);
            std::fprintf(trace,
                "[input-capture] day=%lld env_hash=%llu gen=%llu session=%llu map=%llu "
                "country=%llu building=%llu resource=%llu catalog=%llu watermark=%llu\n",
                static_cast<long long>(accepted.day),
                static_cast<unsigned long long>(manifest_hash),
                static_cast<unsigned long long>(manifest.input_generation),
                static_cast<unsigned long long>(manifest.session_epoch),
                static_cast<unsigned long long>(manifest.map_generation),
                static_cast<unsigned long long>(manifest.country_generation),
                static_cast<unsigned long long>(manifest.building_generation),
                static_cast<unsigned long long>(manifest.resource_generation),
                static_cast<unsigned long long>(manifest.catalog_hash),
                static_cast<unsigned long long>(manifest.command_watermark));
            sim_trace_environment_fields(trace, accepted);
        }
        manifest_hash = mix_hash(manifest_hash, manifest.session_epoch);
        manifest_hash = mix_hash(manifest_hash, manifest.input_generation);
        manifest_hash = mix_hash(manifest_hash, static_cast<uint64_t>(manifest.effective_day));
        manifest_hash = mix_hash(manifest_hash, manifest.map_generation);
        manifest_hash = mix_hash(manifest_hash, manifest.country_generation);
        manifest_hash = mix_hash(manifest_hash, manifest.building_generation);
        manifest_hash = mix_hash(manifest_hash, manifest.resource_generation);
        manifest_hash = mix_hash(manifest_hash, manifest.catalog_hash);
        manifest_hash = mix_hash(manifest_hash, manifest.command_watermark);
        manifest.input_hash = manifest_hash;
        manifest.frozen = 1;
        manifest.validated = accepted.topology_validated ? 1 : 0;
        _input_manifest = manifest;
        _input_capture_generation.store(accepted.generation,
                                        std::memory_order_relaxed);
        _input_capture_day.store(accepted.day, std::memory_order_relaxed);
        _input_capture_hash.store(manifest_hash, std::memory_order_relaxed);
        _input_capture_count.fetch_add(1, std::memory_order_relaxed);
    }
    return true;
    }
} // namespace pk
