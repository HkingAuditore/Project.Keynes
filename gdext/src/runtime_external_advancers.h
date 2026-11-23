#pragma once

// Generated from tools/ci/runtime_advancers.json by check_runtime_advancers.py.
// Inventory only: this table never schedules or moves execution.
#include <array>

namespace pk {
enum class RuntimeAdvancerThread { MAIN, WORKER, EXECUTOR };
// EXECUTOR is worker normally, or the existing inline caller.
struct RuntimeExternalAdvancerDescriptor {
    const char *id;
    RuntimeAdvancerThread thread;
    const char *reads;
    const char *writes;
    const char *trigger;
    const char *source;
    const char *entrypoint;
    const char *host_fields;
};

inline constexpr std::array<RuntimeExternalAdvancerDescriptor, 8> RUNTIME_EXTERNAL_ADVANCERS{{
    {"military", RuntimeAdvancerThread::EXECUTOR, "committed Country and Economy, terrain and prior exploration", "Military state, D+1 intents and military facts", "after species in the whole-day executor", "gdext/src/native_simulation_host_military.cpp", "NativeSimulationHost::stage_military", ""},
    {"natural_resource_recovery", RuntimeAdvancerThread::EXECUTOR, "executor-owned reserves and economy resource deltas", "resource writeback in the native day commit", "native day tail after economy settles", "gdext/src/native_simulation_host_day_tail.cpp", "stage_natural_resource_recovery", ""},
    {"bio_occupancy", RuntimeAdvancerThread::EXECUTOR, "executor-owned climate and reserves; frozen geography; economy introductions; occupancy", "occupancy and observation candidates in the native day commit", "native day tail after resource recovery", "gdext/src/world_ext_bio.cpp", "stage_bio_occupancy", ""},
    {"family", RuntimeAdvancerThread::EXECUTOR, "economy family/cohort/market state; Country and Modifier inputs", "family state; frozen behavior CSR; effect metrics", "economy FAMILY_COMMIT; worker or inline caller", "gdext/src/economy_graph_stage_dispatch.cpp", "RuntimeEconomyGraphStage::FAMILY_COMMIT", ""},
    {"person", RuntimeAdvancerThread::EXECUTOR, "economy family/person state", "person state", "economy PERSON_COMMIT; worker or inline caller", "gdext/src/economy_graph_stage_dispatch.cpp", "RuntimeEconomyGraphStage::PERSON_COMMIT", ""},
    {"vision", RuntimeAdvancerThread::EXECUTOR, "committed Country territory and technology, Military sources and trail, species", "visibility, exploration, fog and D+1 Country observations", "after Military in the whole-day executor", "gdext/src/world_ext_vision.cpp", "NativeSimulationHost::stage_vision", ""},
    {"visual_delivery", RuntimeAdvancerThread::MAIN, "published commit and dirty-family flags", "MapData/display mirrors; renderer uploads", "host frame consumption of commit and display refresh", "Project/project-keynes/scripts/game/world_runtime_host.gd", "_consume_runtime_commit_if_ready", "_runtime_commit_day"},
    {"climate_writeback", RuntimeAdvancerThread::MAIN, "published Climate snapshots", "DataCore slots; MapData mirror", "host consumption of a newer committed Climate day", "Project/project-keynes/scripts/game/world_runtime_host.gd", "_apply_climate_writeback_if_authoritative", "_runtime_climate_writeback_last_day"},
}};
} // namespace pk
