#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <type_traits>
#include <vector>

namespace pk {

template <size_t N>
inline void runtime_copy_text(char (&destination)[N], const char *source) noexcept {
    static_assert(N > 0, "runtime diagnostic buffers must not be empty");
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < N && source[index] != '\0'; ++index)
            destination[index] = source[index];
    }
    destination[index] = '\0';
    for (++index; index < N; ++index) destination[index] = '\0';
}

// These types are deliberately independent of Godot.  They are the only
// values allowed to cross the NativeSimulationHost thread boundary.
constexpr uint32_t RUNTIME_COMMAND_QUEUE_CAPACITY = 4096u;
constexpr uint32_t RUNTIME_RECEIPT_QUEUE_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_MAX_COMMAND_PAYLOAD = 1024u;
constexpr uint32_t RUNTIME_SNAPSHOT_RING_SIZE = 3u;
constexpr uint32_t RUNTIME_DIRTY_FAMILY_COUNT = 9u;
constexpr uint32_t RUNTIME_DOMAIN_INTENT_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_DOMAIN_EVENT_CAPACITY = 8192u;
// Stage layout v3 adds an explicit input-capture barrier and gives Climate
// its own domain bit.  Keep this independent from the legacy host envelope.
constexpr uint32_t RUNTIME_DOMAIN_STAGE_COUNT = 12u;
constexpr uint32_t RUNTIME_ALL_DOMAIN_MASK =
    (1u << RUNTIME_DOMAIN_STAGE_COUNT) - 1u;
constexpr uint32_t RUNTIME_DOMAIN_ABI_VERSION = 1u;
// POD section ABI is independently versioned from the legacy host envelope;
// the latter remains v1 so existing command/commit clients can continue to
// consume SHADOW diagnostics while the worker state wire shape evolves.
constexpr uint32_t RUNTIME_DOMAIN_POD_ABI_VERSION = 3u;
// PKSR is the immutable runtime envelope inside the PKSV v2 container.  A
// version bump is intentional: v1 did not carry an explicit ABI/section
// header and must be rejected instead of being guessed at restore time.
constexpr uint32_t RUNTIME_SAVE_BUNDLE_VERSION = 2u;
constexpr uint32_t RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE = 1u << 0;
constexpr uint32_t RUNTIME_SAVE_SECTION_DOMAIN_POD = 1u << 1;
constexpr uint32_t RUNTIME_SAVE_SECTION_CLIMATE = 1u << 2;

static_assert(RUNTIME_COMMAND_QUEUE_CAPACITY == 4096u,
              "runtime command queue capacity is part of the ABI");
static_assert(RUNTIME_RECEIPT_QUEUE_CAPACITY == 8192u,
              "runtime receipt queue capacity is part of the ABI");
static_assert(RUNTIME_MAX_COMMAND_PAYLOAD == 1024u,
              "runtime command payload limit is part of the ABI");

static_assert(RUNTIME_DOMAIN_STAGE_COUNT == 12u,
              "runtime domain barrier must contain exactly twelve stages");

enum class RuntimeWorkerState : uint8_t {
    STOPPED = 0,
    STARTING = 1,
    RUNNING = 2,
    PAUSED = 3,
    SAVE_PENDING = 4,
    STOPPING = 5,
    FAULTED = 6,
};

enum class RuntimeSimulationMode : uint8_t {
    OFF = 0,
    SHADOW = 1,
    ACTIVE = 2,
};

enum RuntimeDirtyFamily : uint32_t {
    RUNTIME_DIRTY_CLOCK = 1u << 0,
    RUNTIME_DIRTY_COUNTRY_STATE = 1u << 1,
    RUNTIME_DIRTY_COUNTRY_TERRITORY = 1u << 2,
    RUNTIME_DIRTY_COUNTRY_VISUAL_ERA = 1u << 3,
    RUNTIME_DIRTY_CLIMATE_FIELDS = 1u << 4,
    RUNTIME_DIRTY_WEATHER = 1u << 5,
    RUNTIME_DIRTY_ECONOMY_UI = 1u << 6,
    RUNTIME_DIRTY_EVENTS = 1u << 7,
    RUNTIME_DIRTY_OVERLAY = 1u << 8,
};

struct RuntimeCommandEnvelope {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    uint16_t domain = 0;
    uint16_t opcode = 0;
    uint32_t payload_offset = 0;
    uint32_t payload_size = 0;
};

struct RuntimeCommandPacket {
    RuntimeCommandEnvelope envelope;
    std::array<uint8_t, RUNTIME_MAX_COMMAND_PAYLOAD> payload{};
};

enum class RuntimeReceiptCode : uint16_t {
    OK = 0,
    INVALID_PAYLOAD = 1,
    INVALID_VALUE = 2,
    PREFLIGHT_REJECTED = 3,
    WORKER_FAULTED = 4,
    QUEUE_CAPACITY_EXCEEDED = 5,
};

struct RuntimeCommandReceipt {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    int64_t effective_day = 0;
    uint64_t generation = 0;
    RuntimeReceiptCode code = RuntimeReceiptCode::OK;
};

// Self-describing section descriptor used inside PKSR v2. The payload itself
// is an immutable byte span owned by RuntimeSaveBundle; no worker pointer is
// ever serialized or exposed to Godot.
struct RuntimeDomainSaveSection {
    uint16_t domain = 0;
    uint16_t version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    uint32_t payload_offset = 0;
    uint32_t payload_size = 0;
    uint64_t checksum = 0;
};

struct RuntimeEnvironmentSnapshot {
    // Compiled on the Godot/main-thread capture boundary. A worker accepts a
    // frame only when it targets the same ABI/catalog/map shape it bootstrapped
    // with; source objects and profile strings never cross this boundary.
    uint32_t climate_catalog_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    uint64_t climate_catalog_hash = 0;
    uint32_t climate_map_width = 0;
    uint32_t climate_map_height = 0;
    uint64_t generation = 0;
    int64_t day = 0;
    // Sparse fixtures remain legal for diagnostics while the migration is in
    // SHADOW. Production frames set this flag so the worker rejects any
    // missing lane instead of synthesizing a per-cell default.
    bool climate_input_complete = false;
    float dt_days = 1.0f;
    uint32_t cell_count = 0;
    bool topology_validated = false;
    double season_phase = 0.0;
    double climate_anomaly = 0.0;
    uint64_t vision_revision = 0;
    uint64_t topology_generation = 0;
    bool fog_solved = false;
    std::vector<float> cell_temp;
    std::vector<float> cell_temp_30d;
    std::vector<float> cell_temp_365d;
    std::vector<float> cell_temp_baseline_year;
    std::vector<float> cell_base_moisture;
    std::vector<float> cell_moisture;
    std::vector<float> cell_plant_available_water;
    std::vector<float> cell_soil_moisture;
    std::vector<float> cell_water_balance_30d;
    std::vector<float> cell_weather_precip;
    std::vector<float> cell_snow_cover;
    std::vector<float> cell_weather_intensity;
    std::vector<float> cell_weather_vapor;
    std::vector<float> cell_weather_cloud_water;
    std::vector<float> cell_weather_cloud;
    std::vector<uint8_t> cell_weather_type;
    std::vector<uint8_t> cell_weather_transition;
    std::vector<float> cell_sea_ice_frac_prev;
    std::vector<float> cell_river_discharge_30d;
    std::vector<float> cell_vegetation_vitality;
    std::vector<float> cell_insolation_dev;
    std::vector<float> cell_heat_input;
    std::vector<float> cell_wind_x;
    std::vector<float> cell_wind_y;
    std::vector<float> cell_wind_speed;
    std::vector<float> cell_ocean_current_x;
    std::vector<float> cell_ocean_current_y;
    std::vector<float> cell_air_mass_temp_anomaly;
    std::vector<float> cell_ocean_thermal_anomaly;
    std::vector<float> cell_local_thermal_anomaly;
    std::vector<float> cell_temperature_transport_anomaly;
    std::vector<uint8_t> cell_ema_initialized;
    std::vector<float> cell_elevation;
    std::vector<float> cell_lat_norm;
    std::vector<float> cell_geometry_area;
    std::vector<float> cell_wind_band;
    std::vector<float> cell_ocean_heat_capacity;
    // Either CSR (neighbor_offsets + neighbor_indices) or the legacy fixed
    // six-neighbour layout may be supplied by the main-thread capture path.
    // Worker code consumes only the copied native vectors.
    std::vector<int32_t> neighbor_offsets;
    std::vector<int32_t> neighbor_indices;
    std::vector<int32_t> hydro_parent;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> vegetation;
    std::vector<uint8_t> cover;
    std::vector<uint8_t> is_water;
    std::vector<uint8_t> has_river;
    std::vector<uint8_t> canal_edge_mask;
    std::vector<float> canal_water;
    std::vector<uint8_t> trade_passable_lut;
    std::vector<int32_t> trade_move_cost_lut;
    std::vector<uint8_t> visible;
    std::vector<float> building_resource_reserve;
    std::vector<float> building_resource_extra;
};

// Shared validation for the main-thread facade and the worker publish gate.
// This function is intentionally Godot-free so tests can exercise the exact
// boundary without constructing a DCWorldExt object.
bool validate_runtime_environment_snapshot(const RuntimeEnvironmentSnapshot &snapshot,
                                           std::string &error);

// Fixed order for the native daily barrier.  The enum and the array below are
// deliberately independent from Godot scheduler names; domain migration can
// therefore add a POD handler without changing the worker protocol.
enum class RuntimeDomainId : uint16_t {
    INPUT_CAPTURE = 1,
    CLIMATE = 2,
    COUNTRY = 3,
    TRIGGER_INPUT = 4,
    IDEOLOGY = 5,
    EFFECT = 6,
    MODIFIER = 7,
    GAMEPLAY_EFFECT = 8,
    ECONOMY = 9,
    EVENTS = 10,
    VISUAL = 11,
    COMMIT = 12,
};

static_assert((1u << static_cast<uint16_t>(RuntimeDomainId::CLIMATE)) !=
              (1u << static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT)),
              "Climate and Trigger input must have distinct capability bits");
static_assert(RUNTIME_ALL_DOMAIN_MASK == 0xFFFu,
              "ABI v3 capability mask must cover all twelve stages");

// Stable stage order shared by every worker implementation. Keeping this in
// the protocol (rather than duplicating an array in each domain) makes a
// shadow world and an active world use the same barrier even while individual
// handlers are being migrated.
constexpr std::array<RuntimeDomainId, RUNTIME_DOMAIN_STAGE_COUNT>
runtime_domain_stage_order() {
    return {
        RuntimeDomainId::INPUT_CAPTURE,
        RuntimeDomainId::CLIMATE,
        RuntimeDomainId::COUNTRY,
        RuntimeDomainId::TRIGGER_INPUT,
        RuntimeDomainId::IDEOLOGY,
        RuntimeDomainId::EFFECT,
        RuntimeDomainId::MODIFIER,
        RuntimeDomainId::GAMEPLAY_EFFECT,
        RuntimeDomainId::ECONOMY,
        RuntimeDomainId::EVENTS,
        RuntimeDomainId::VISUAL,
        RuntimeDomainId::COMMIT,
    };
}

constexpr uint32_t runtime_domain_mask(RuntimeDomainId domain) {
    const uint16_t value = static_cast<uint16_t>(domain);
    return value >= 1u && value <= RUNTIME_DOMAIN_STAGE_COUNT
        ? (1u << (value - 1u)) : 0u;
}

static_assert(RUNTIME_DOMAIN_STAGE_COUNT == 12u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::INPUT_CAPTURE) == 1u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::CLIMATE) == 2u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::COUNTRY) == 3u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT) == 4u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::COMMIT) == 12u);
static_assert(runtime_domain_mask(RuntimeDomainId::CLIMATE) !=
              runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT));
static_assert(RUNTIME_ALL_DOMAIN_MASK ==
              ((1u << RUNTIME_DOMAIN_STAGE_COUNT) - 1u));

struct RuntimeDayContext {
    int64_t day = 0;
    double season_phase = 0.0;
    double speed_scale = 1.0;
    uint64_t input_generation = 0;
    // Points at a worker-owned immutable snapshot for the duration of one
    // day. It is never retained by a domain after the day barrier returns.
    const RuntimeEnvironmentSnapshot *environment = nullptr;
};

// Common metadata carried by every real domain plan/commit.  The record is
// POD-only; dynamic payloads remain in the owning immutable snapshot or in a
// preallocated intent arena.
struct RuntimeDomainHeader {
    uint16_t domain = 0;
    uint16_t abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint64_t state_hash = 0;
    uint64_t work_units = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint8_t preflight_ok = 1;
    uint8_t reserved[3]{};
    char fallback_reason[64]{};
};

struct RuntimeDomainPlan {
    RuntimeDomainId domain = RuntimeDomainId::COUNTRY;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint8_t completed = 0;
};

struct RuntimeDayPlan {
    RuntimeDayContext context;
    std::array<RuntimeDomainPlan, RUNTIME_DOMAIN_STAGE_COUNT> stages{};
    uint32_t stage_count = RUNTIME_DOMAIN_STAGE_COUNT;
};

// Compact worker-local result. Dynamic visual intents and command receipts are
// copied to RuntimeCommit separately, so this summary stays trivially copyable.
struct RuntimeDayCommit {
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint32_t completed_stage_count = 0;
    uint32_t completed_domain_mask = 0;
    uint64_t state_hash = 0;
    uint8_t preflight_ok = 1;
};

// Domain ABI result. A handler must fill this record without constructing a
// Godot value. `preflight_ok=0` is a deterministic barrier failure; the host
// turns it into a command receipt/fault according to the domain policy.
struct RuntimeDomainCommit {
    RuntimeDomainId domain = RuntimeDomainId::COUNTRY;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint64_t state_hash = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
    char fallback_reason[64]{};
};

// Shared cross-domain POD records. Keeping one definition in the protocol
// prevents each adapter from silently inventing different ACK or intent
// semantics while the domains are migrated one at a time.
enum class RuntimeDomainAckCode : uint16_t {
    OK = 0,
    RETRY = 1,
    REJECTED = 2,
    STALE_GENERATION = 3,
};

struct RuntimeDomainAck {
    uint64_t request_id = 0;
    uint64_t transaction_id = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    uint16_t domain = 0;
    RuntimeDomainAckCode code = RuntimeDomainAckCode::OK;
    int64_t effective_day = 0;
};

struct RuntimeDomainIntent {
    uint16_t source_domain = 0;
    uint16_t target_domain = 0;
    uint16_t opcode = 0;
    uint16_t flags = 0;
    uint64_t source_id = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t value = 0;
    int64_t effective_day = 0;
    std::array<int64_t, 4> payload{};
};

struct RuntimeDomainTiming {
    uint64_t work_units = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint64_t state_hash = 0;
    double elapsed_ms = 0.0;
};

struct RuntimeDomainReport {
    RuntimeDomainId domain = RuntimeDomainId::COMMIT;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
    uint8_t fallback = 0;
    uint8_t reserved = 0;
    char fallback_reason[64]{};
    RuntimeDomainTiming timing{};
};

struct RuntimeDomainSnapshot {
    RuntimeDomainHeader header{};
    std::vector<uint8_t> payload;
};

static_assert(std::is_trivially_copyable_v<RuntimeDomainAck>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainIntent>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainTiming>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainReport>);

// Economy is the first large cross-domain migration target. These records are
// intentionally handle/index based: all strings, Dictionaries and catalog
// lookups stay on the main-thread facade or cold bootstrap path.
struct RuntimeEconomyDayContext {
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t country_generation = 0;
    uint64_t modifier_generation = 0;
    const RuntimeEnvironmentSnapshot *environment = nullptr;
};

struct RuntimeEconomyDayCommit {
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint64_t state_hash = 0;
    uint32_t changed_cells = 0;
    uint32_t changed_cohorts = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
};

// Country-domain ABI used by the Phase B adapter.  These records are
// deliberately smaller than the Godot-facing country report: a worker may
// pass them between fixed stages without constructing dynamic Godot values.
// The adapter is currently opt-in; the legacy facade remains authoritative
// until all country command/economy barriers are migrated.
struct RuntimeCountryDayContext {
    int64_t day = 0;
    double speed_scale = 1.0;
    uint64_t input_generation = 0;
};

enum class RuntimeCountryPodError : uint16_t {
    NONE = 0,
    NOT_BOOTSTRAPPED = 1,
    INVALID_CONTEXT = 2,
    COMMAND_BATCH_PENDING = 3,
    CROSS_DOMAIN_BARRIER_REQUIRED = 4,
};

struct RuntimeCountryDayCommit {
    uint32_t dirty_families = 0;
    uint32_t changed_countries = 0;
    uint32_t changed_territory_cells = 0;
    uint64_t research_work_units = 0;
    uint64_t state_hash = 0;
    uint64_t country_generation = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 0;
    uint8_t ack_required = 0;
    uint8_t reserved = 0;
    RuntimeCountryPodError error_code = RuntimeCountryPodError::NONE;
};

// Immutable, worker-safe country input.  This is intentionally a numeric
// projection of NativeCountryRuntime: strings, Godot values and peer-runtime
// pointers never cross the simulation thread boundary.  The vectors are
// copied once at a main-thread capture boundary and then treated as const by
// the POD adapter.
struct RuntimeCountryPodSnapshot {
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    int64_t committed_day = -1;
    uint32_t cell_count = 0;
    uint32_t country_count = 0;
    uint32_t technology_words = 0;
    uint32_t technology_count = 0;
    uint32_t good_count = 0;
    uint32_t research_signal_words = 0;
    uint32_t research_signal_count = 0;
    // Catalog identity is captured with the immutable country projection. A
    // worker must reject a snapshot whose catalog is not the one it was
    // bootstrapped against; strings and Godot catalog objects never cross the
    // worker boundary.
    uint64_t catalog_hash = 0;
    bool bootstrapped = false;
    bool research_active_index_valid = false;
    std::vector<uint8_t> country_active;
    std::vector<uint32_t> country_generation;
    // Sorted dense slots whose research state can make progress on the next
    // day.  This is a derived membership index captured from Country's
    // native hot loop; an empty vector is accepted for compatibility and
    // means the adapter must conservatively scan all country slots.
    std::vector<int32_t> research_active_country_slots;
    std::vector<int32_t> territory_count;
    std::vector<uint64_t> country_state_version;
    std::vector<int64_t> country_cash;
    std::vector<int64_t> country_goods;
    std::vector<int32_t> cell_country_slot;
    std::vector<int32_t> territory_offsets;
    std::vector<int32_t> territory_cells;
    std::vector<uint64_t> country_technologies;
    std::vector<uint64_t> country_discovered;
    std::vector<uint64_t> country_pending_technologies;
    std::vector<uint64_t> country_research_signals;
    std::vector<int32_t> research_signal_evidence_offsets;
    struct SignalEvidence {
        int32_t signal = -1;
        int32_t count = 0;
        int64_t first_day = -1;
        int64_t last_day = -1;
        int32_t first_cell = -1;
    };
    std::vector<SignalEvidence> research_signal_evidence;
    std::vector<int32_t> research_queues;
    std::vector<uint8_t> research_queue_lengths;
    std::vector<int32_t> research_weights_bp;
    std::vector<int64_t> research_daily_budgets;
    std::vector<int64_t> research_deferred_points;
    std::vector<int64_t> research_progress_total;
    std::vector<int64_t> research_completed_total;
    // Per-technology progress is required for deterministic plan/replay. The
    // legacy probe only exported aggregate totals; a worker authority must
    // reject captures that omit this matrix.
    std::vector<int64_t> research_progress;
    std::vector<uint8_t> research_auto_purchase;
    std::vector<int64_t> research_purchased_total;
    std::vector<int64_t> research_consumed_total;
    std::vector<uint8_t> is_water;
};

// Numeric, immutable catalog compiled by the main-thread facade before a
// worker is started. Strings and Godot catalog objects never cross the worker
// boundary. The condition CSR is explicit so a worker can reject an
// incomplete capture instead of guessing at reference semantics.
struct RuntimeCountryPodCatalog {
    uint64_t catalog_hash = 0;
    uint32_t technology_count = 0;
    uint32_t technology_words = 0;
    int32_t technology_points_good_id = -1;
    bool research_conditions_complete = false;
    std::vector<int64_t> technology_costs;
    std::vector<int32_t> technology_domains;
    std::vector<int32_t> technology_flags;
    std::vector<int32_t> prerequisite_offsets;
    std::vector<int32_t> prerequisites;
    std::vector<int32_t> milestone_offsets;
    std::vector<int32_t> milestone_candidates;
    std::vector<int32_t> milestone_required_counts;
    std::vector<int32_t> entry_milestone_indices;
    std::vector<int32_t> research_condition_offsets;
    std::vector<int32_t> research_condition_ops;
    std::vector<int32_t> research_condition_refs;
    std::vector<int64_t> research_condition_values;
};

struct RuntimeCountryPodDiagnostics {
    uint64_t snapshot_generation = 0;
    uint64_t state_hash = 0;
    uint64_t work_units = 0;
    uint32_t active_country_count = 0;
    uint32_t active_index_count = 0;
    uint32_t pending_checks = 0;
    uint32_t changed_country_count = 0;
    uint32_t changed_cell_count = 0;
    uint8_t ack_pending = 0;
    char blocker[64]{};
};

// Country command payload used by the Phase B adapter.  This is deliberately
// a fixed-size, string-free record: stable/display names and catalog ids are
// resolved on the Godot facade before a command crosses the worker boundary.
// The record is also useful to the synchronous reference path because it makes
// the validation contract identical before the full Country store is moved
// behind NativeSimulationHost.
constexpr uint32_t RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY = 256u;
constexpr uint32_t RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT = 4u;

struct RuntimeCountryCommand {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    uint16_t opcode = 0;
    uint16_t reserved = 0;
    uint64_t target_handle = 0;
    int32_t cell = -1;
    int32_t aux = -1;
    int32_t domain = -1;
    int32_t position = -1;
    std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> weights_bp{
        {2500, 2500, 2500, 2500}};
    int32_t tax_kind = -1;
    int32_t tax_item = -1;
    int32_t tax_rate_basis_points = 0;
    int32_t tax_assessment_mode = 0;
    int64_t value = 0;
};

struct RuntimeCountryCommandBatch {
    uint32_t count = 0;
    std::array<RuntimeCountryCommand,
               RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY> commands{};
};

inline bool runtime_country_research_weights_valid(
        const std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> &weights) noexcept {
    int64_t total = 0;
    for (const int32_t weight : weights) {
        if (weight < 0 || weight > 10000) return false;
        total += weight;
    }
    return total == 10000;
}

static_assert(std::is_trivially_copyable_v<RuntimeCommandEnvelope>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainHeader>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainSaveSection>);
static_assert(std::is_trivially_copyable_v<RuntimeDayContext>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainPlan>);
static_assert(std::is_trivially_copyable_v<RuntimeDayPlan>);
static_assert(std::is_trivially_copyable_v<RuntimeDayCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyDayContext>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyDayCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryDayContext>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryDayCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryCommand>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryCommandBatch>);

struct RuntimeCommitHeader {
    uint64_t generation = 0;
    int64_t from_day = 0;
    int64_t committed_day = 0;
    uint64_t produced_at_us = 0;
    uint32_t dirty_families = 0;
    uint64_t state_hash = 0;
    uint32_t command_receipt_count = 0;
    // Last commit generation that touched each dirty family, indexed by the
    // bit position in RuntimeDirtyFamily.  Keeping this in the immutable
    // header lets the main thread discard an old family patch independently
    // from newer clock/economy/event publications.
    std::array<uint64_t, RUNTIME_DIRTY_FAMILY_COUNT> dirty_family_generations{};
};

struct RuntimeVisualIntent {
    uint32_t family = 0;
    uint32_t cell_index = 0;
    uint32_t field_id = 0;
    int32_t value_i32 = 0;
    float value_f32 = 0.0f;
};

struct RuntimeCommit {
    RuntimeCommitHeader header;
    std::vector<RuntimeVisualIntent> visual_intents;
    std::vector<RuntimeCommandReceipt> receipts;
};

struct RuntimeThreadReport {
    uint32_t domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    uint32_t pod_domain_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    RuntimeWorkerState state = RuntimeWorkerState::STOPPED;
    RuntimeSimulationMode mode = RuntimeSimulationMode::OFF;
    bool graph_coverage_complete = false;
    // Coverage is a prerequisite, not proof that the worker owns gameplay
    // authority.  This remains false until every daily domain has a native
    // POD handler and the worker has completed the full barrier.
    bool authority_ready = false;
    uint32_t required_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    uint32_t implemented_domain_mask = 0;
    uint32_t missing_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    char graph_coverage_state[32]{};
    char coverage_blocker[64]{};
    bool interactive = false;
    bool paused = true;
    double speed_days_per_second = 0.0;
    int64_t committed_day = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t last_commit_produced_at_us = 0;
    uint64_t last_visual_publish_at_us = 0;
    double snapshot_staleness_ms = 0.0;
    // Main-thread visual timings are fed back through the facade. They stay in
    // the POD report so CSV/diagnostic consumers have one stable namespace.
    double ui_input_to_feedback_ms = 0.0;
    double visual_apply_ms = 0.0;
    double gpu_upload_ms = 0.0;
    // Facade calls are intentionally non-blocking.  Keep this explicit in
    // the report so a future bridge cannot silently introduce a wait.
    uint64_t main_wait_on_sim_us = 0;
    uint64_t environment_generation = 0;
    int64_t environment_day = 0;
    uint32_t environment_cell_count = 0;
    bool environment_topology_validated = false;
    uint64_t invalid_environment_rejected = 0;
    uint64_t stale_environment_rejected = 0;
    uint64_t command_queue_capacity_exceeded = 0;
    uint64_t receipt_queue_capacity_exceeded = 0;
    uint64_t snapshot_publish_drop_count = 0;
    uint64_t snapshot_publish_throttled_count = 0;
    uint64_t worker_fault_count = 0;
    uint64_t completed_days = 0;
    uint32_t day_stage_count = 0;
    uint32_t day_completed_stage_count = 0;
    uint64_t day_work_units = 0;
    // SHADOW-only worker ABI diagnostics. These fields describe the pure POD
    // pipeline even while implemented_domain_mask correctly remains partial.
    uint32_t pod_completed_domain_mask = 0;
    uint32_t pod_completed_stage_count = 0;
    uint64_t pod_work_units = 0;
    uint32_t pod_intent_count = 0;
    uint32_t pod_fallback_count = 0;
    // Consolidated SHADOW domain-authority runner metrics. These are
    // diagnostic only; implemented_domain_mask remains the promotion gate.
    uint32_t domain_authority_planned_mask = 0;
    uint32_t domain_authority_committed_mask = 0;
    uint32_t domain_authority_ack_count = 0;
    uint64_t domain_authority_input_hash = 0;
    uint64_t domain_authority_state_hash = 0;
    double domain_authority_plan_ms = 0.0;
    double domain_authority_replay_ms = 0.0;
    char domain_authority_fallback_reason[64]{};
    uint32_t domain_stage_fallback_count = 0;
    char domain_stage_fallback_reason[64]{};
    bool climate_pod_ready = false;
    double climate_pod_plan_ms = 0.0;
    double climate_pod_replay_ms = 0.0;
    uint64_t climate_pod_work_units = 0;
    uint32_t climate_pod_changed_cells = 0;
    uint64_t climate_pod_state_hash = 0;
    uint64_t climate_pod_reference_hash = 0;
    bool climate_pod_parity_compared = false;
    bool climate_pod_parity_matched = false;
    uint64_t climate_pod_parity_mismatch_count = 0;
    char climate_pod_parity_reason[64]{};
    int64_t climate_parity_day = -1;
    uint16_t climate_parity_stage = 0;
    uint32_t climate_parity_cell = 0;
    uint64_t climate_parity_input_generation = 0;
    uint64_t climate_parity_base_generation = 0;
    uint64_t climate_parity_trace_hash = 0;
    char climate_parity_field[48]{};
    char climate_parity_reference_bits[24]{};
    char climate_parity_worker_bits[24]{};
    char climate_pod_fallback_reason[64]{};
    uint32_t command_queue_depth = 0;
    uint32_t receipt_queue_depth = 0;
    double time_debt_days = 0.0;
    uint32_t climate_trace_depth = 0;
    int64_t climate_trace_front_day = -1;
    int64_t climate_trace_lag_days = 0;
    uint64_t climate_trace_latest_hash = 0;
    uint64_t climate_trace_capacity_exceeded = 0;
    uint64_t climate_trace_consumed = 0;
    uint64_t climate_trace_missing = 0;
    uint32_t climate_trace_captured = 0;
    uint32_t climate_trace_reference_ready = 0;
    uint32_t climate_trace_consumable = 0;
    uint64_t climate_trace_reference_rejected = 0;
    uint64_t climate_trace_reference_pending = 0;
      uint32_t executor_workers = 0;
      uint64_t country_pod_snapshot_generation = 0;
      uint64_t country_pod_state_hash = 0;
      uint64_t country_pod_work_units = 0;
      uint32_t country_pod_active_country_count = 0;
      uint32_t country_pod_active_index_count = 0;
      uint32_t country_pod_pending_checks = 0;
      bool country_pod_ack_pending = false;
      char country_pod_blocker[64]{};
      char fault_code[64]{};
};

// The bundle is immutable after publication.  It deliberately contains only
// bytes and scalar metadata so the Godot facade can copy it without exposing
// any runtime store or Godot object to the worker.
struct RuntimeSaveBundle {
    uint64_t request_id = 0;
    int64_t committed_day = 0;
    bool paused = true;
    double speed_days_per_second = 0.0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t environment_generation = 0;
    int64_t environment_day = 0;
    double climate_anomaly = 0.0;
    double time_debt_days = 0.0;
    uint32_t bundle_version = RUNTIME_SAVE_BUNDLE_VERSION;
    uint32_t runtime_domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    uint32_t section_mask = RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE;
    uint64_t checksum = 0;
    std::vector<uint8_t> bytes;
    // Commands that were already accepted by the host but had not reached a
    // day boundary when SAVE_REQUEST was observed. They stay in protocol order
    // and are restored into the worker's pending list before the next day.
    std::vector<RuntimeCommandPacket> pending_commands;
    std::vector<uint8_t> domain_pod_bytes;
    // Independent climate section. It is immutable bytes encoded by the
    // worker at a completed day barrier; Godot only copies/writes these bytes.
    std::vector<uint8_t> climate_bytes;
    std::array<uint64_t, 256> producer_sequences{};
    uint64_t fallback_producer_sequence = 0;
};

} // namespace pk
