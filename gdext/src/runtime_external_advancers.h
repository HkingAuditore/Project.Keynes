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

inline constexpr std::array<RuntimeExternalAdvancerDescriptor, 7> RUNTIME_EXTERNAL_ADVANCERS{{
    {"military", RuntimeAdvancerThread::MAIN, "committed Country/Economy; terrain", "military runtime; next-day intents; military events", "host frame catchup of observed committed days", "Project/project-keynes/scripts/game/world_runtime_host.gd", "_drain_runtime_military_commits", "_runtime_military_last_commit_day;_runtime_military_pending_target_day"},
    {"natural_resource_recovery", RuntimeAdvancerThread::MAIN, "resource reserves; climate/terrain/vegetation inputs", "resource slots; MapData mirror", "host frame catchup of observed committed days", "Project/project-keynes/scripts/game/world_runtime_host.gd", "_drain_runtime_natural_resource_commits", "_runtime_natural_resource_last_commit_day;_runtime_natural_resource_pending_target_day"},
    {"family", RuntimeAdvancerThread::EXECUTOR, "economy family/cohort/market state; Country and Modifier inputs", "family state; frozen behavior CSR; effect metrics", "economy FAMILY_COMMIT; worker or inline caller", "gdext/src/economy_graph_stage_dispatch.cpp", "RuntimeEconomyGraphStage::FAMILY_COMMIT", ""},
    {"person", RuntimeAdvancerThread::EXECUTOR, "economy family/person state", "person state", "economy PERSON_COMMIT; worker or inline caller", "gdext/src/economy_graph_stage_dispatch.cpp", "RuntimeEconomyGraphStage::PERSON_COMMIT", ""},
    {"vision", RuntimeAdvancerThread::MAIN, "committed Country territory; terrain; bio occupancy; research signals", "visibility/exploration/fog; Country observation intents", "host vision refresh on world/country changes", "Project/project-keynes/scripts/game/world_runtime_host.gd", "_refresh_vision", ""},
    {"visual_delivery", RuntimeAdvancerThread::MAIN, "published commit and dirty-family patches", "MapData/display mirrors; renderer uploads", "host frame consumption of commit and visual patches", "Project/project-keynes/scripts/game/world_runtime_host.gd", "_consume_runtime_commit_if_ready", "_runtime_commit_day;_runtime_commit_family_cursors"},
    {"climate_writeback", RuntimeAdvancerThread::MAIN, "published Climate snapshots", "DataCore slots; MapData mirror", "host consumption of a newer committed Climate day", "Project/project-keynes/scripts/game/world_runtime_host.gd", "_apply_climate_writeback_if_authoritative", "_runtime_climate_writeback_last_day"},
}};
} // namespace pk
