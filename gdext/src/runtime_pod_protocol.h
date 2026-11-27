#pragma once

// S3：Climate 生产 pass 的共享纯内核缓冲。runtime_climate_passes.h 与本文件一样
// 不依赖 Godot，所以把 ClimateInputBuf 编入环境快照不会破坏"跨线程边界只允许传
// Godot 无关值"这条约束。
#include "runtime_climate_passes.h"
#include "runtime_climate_physics.h"
#include "economy_graph_kernels.h"
#include "runtime_freeze_contract.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <limits>
#include <string>
#include <type_traits>
#include <vector>

namespace pk {

struct CountryPeerContext;

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

// Unified "why this day has not committed" bits. Host / clock / forensics read
// one mask instead of guessing from capacity barriers vs peer soft-stalls.
// climate_capacity = environment input FIFO full (progress may pause; liveness
// must continue). Peer bits require main-thread pumps, never soft-erase.
constexpr uint32_t RUNTIME_DAY_STALL_CLIMATE_CAPACITY = 1u << 0;
constexpr uint32_t RUNTIME_DAY_STALL_COUNTRY_PEER = 1u << 1;
constexpr uint32_t RUNTIME_DAY_STALL_EFFECT_ACK = 1u << 2;
constexpr uint32_t RUNTIME_DAY_STALL_IDEOLOGY_ACK = 1u << 3;
constexpr uint32_t RUNTIME_DAY_STALL_FISCAL_PEER = 1u << 4;
constexpr uint32_t RUNTIME_DAY_STALL_ECONOMY_INPUT = 1u << 5;
// Soft-commit-as-deadlock-escape is forbidden; peer stalls past this wall-time
// become an observable FAULTED stop instead of silent calendar advance.
constexpr uint32_t RUNTIME_SNAPSHOT_RING_SIZE = 3u;
constexpr uint32_t RUNTIME_DIRTY_FAMILY_COUNT = 9u;
constexpr uint32_t RUNTIME_DOMAIN_INTENT_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_DOMAIN_EVENT_CAPACITY = 8192u;
// Country -> Economy asset requests use a separate bounded transport.  The
// request is a semantic transaction record, not a copy of the Economy store;
// large/variable data stays in the main-thread Economy coordinator until the
// operation is explicitly admitted.
constexpr uint32_t RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY = 32u;
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
constexpr uint32_t RUNTIME_SAVE_BUNDLE_VERSION = 5u;
constexpr uint32_t RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE = 1u << 0;
constexpr uint32_t RUNTIME_SAVE_SECTION_DOMAIN_POD = 1u << 1;
constexpr uint32_t RUNTIME_SAVE_SECTION_CLIMATE = 1u << 2;
constexpr uint32_t RUNTIME_SAVE_SECTION_COUNTRY = 1u << 3;
// Stage H owns the first post-Country section bit.  Keep the later reserved
// domain bits distinct so a Trigger section cannot be mistaken for Modifier.
constexpr uint32_t RUNTIME_SAVE_SECTION_TRIGGER = 1u << 4;
constexpr uint32_t RUNTIME_SAVE_SECTION_MODIFIER = 1u << 5;
constexpr uint32_t RUNTIME_SAVE_SECTION_EVENTS = 1u << 6;
// F2-F6 keeps Effect in its own immutable POD section. This is deliberately
// separate from the legacy PKEF facade section and is not an ACTIVE gate.
constexpr uint32_t RUNTIME_SAVE_SECTION_EFFECT = 1u << 7;
constexpr uint32_t RUNTIME_SAVE_SECTION_IDEOLOGY = 1u << 8;
// D7 Country/Economy transaction journal section. Orthogonal to Economy POD
// authority; persists Host peer request/result continuation state only.
constexpr uint32_t RUNTIME_SAVE_SECTION_ECONOMY_ASSET = 1u << 9;
// Economy POD (ECP1) graph authority section. Orthogonal to D7T1 asset journal.
constexpr uint32_t RUNTIME_SAVE_SECTION_ECONOMY_POD = 1u << 10;
// Economy ECP2 full-authority section (PKEC domain remapping + resource wire).
constexpr uint32_t RUNTIME_SAVE_SECTION_ECONOMY_ECP2 = 1u << 11;
// M3 GAMEPLAY_EFFECT transaction state. This section is independent from
// Effect's EFP1 catalog/instance state and Events' EVT1 journal.
constexpr uint32_t RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT = 1u << 12;
constexpr uint32_t RUNTIME_SAVE_SECTION_EFFECT_TRANSPORT = 1u << 13;
constexpr uint32_t RUNTIME_SAVE_SECTION_MILITARY_TERRAIN = 1u << 14;
constexpr uint32_t RUNTIME_SAVE_SECTION_SEASON_HISTORY = 1u << 15;
constexpr uint32_t RUNTIME_SAVE_SECTION_PLAYER_CONFIRMATION = 1u << 16;
constexpr uint32_t RUNTIME_SAVE_SECTION_VISION = 1u << 17;
constexpr uint32_t RUNTIME_SAVE_SECTION_BIO = 1u << 18;
constexpr uint32_t RUNTIME_SAVE_SECTION_CLIMATE_CALENDAR = 1u << 19;

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
    uint64_t admission_generation = 0; // Ingress metadata, not part of the save payload.
    RuntimeCommandEnvelope envelope;
    // Assigned exactly once by the accepting Host queue. It is deliberately
    // outside the legacy wire envelope so PKSR v2 remains readable while the
    // live worker preserves Country's production ordering.
    uint64_t submit_order = 0;
    std::array<uint8_t, RUNTIME_MAX_COMMAND_PAYLOAD> payload{};
};

// Climate 没有 worker command 枚举。B8-6 删掉了曾经的 5 个 opcode
// (NOOP/SET_POLICY/FORCE_STAGE_MASK/REQUEST_VISUAL_ACK/REQUEST_ECONOMY_ACK)：
// 全仓库没有消费者，而它们描述的三件事各有正式通道 ——
//   * policy / stage mask  → 每 tick 环境快照里的 climate_round_scalars 与
//                            stage knobs（唯一策略输入）；
//   * 脏信号               → day commit 的 dirty_families；
//   * 跨域通知             → 既有 RuntimeDomainIntent / ACK ring。
// 命令枚举必须有消费者才存在；预留空枚举只会让协议看起来比实际多一层，
// 而下一轮排查又要花时间证明它确实没人读。

// Events commands use an explicit little-endian payload. APPEND_BATCH carries
// a bounded array of RuntimeEventsIngressRecord values; the worker assigns IDs
// only after it has sorted commands by the shared protocol ordering.
enum class RuntimeEventsCommand : uint16_t {
    APPEND_BATCH = 1,
    ACK_CONSUMER = 2,
    CONFIGURE_CAPACITY = 3,
    CLEAR_RESET = 4,
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

struct RuntimeEconomyDayInput {
    int64_t day = -1;
    uint32_t cell_count = 0;
    // temp, temp30, moisture, PAW, precip, snow, weather, elevation, temp365
    std::array<std::vector<float>, 9> fields;
    std::array<std::vector<uint8_t>, 6> geography; // terrain, landform, vegetation, water, river, visibility
    // weather_type, cover
    std::array<std::vector<uint8_t>, 2> climate_u8;
    std::vector<int32_t> neighbors;
    std::vector<std::vector<float>> reserves;
    std::vector<std::vector<float>> changes;
    std::vector<uint8_t> resource_habitat; // cell_resource_habitat_mask; empty when absent
    bool fog_solved = false;
};

#include "runtime_pod_protocol_environment.inc"
#include "runtime_pod_protocol_daily_barrier.inc"
constexpr uint32_t RUNTIME_DOMAIN_INTENT_HAS_EFFECT_VALUE = 1u << 0;
constexpr uint32_t RUNTIME_EFFECT_INTENT_PROGRAM_REPORT_CAPACITY = 64u;

#include "runtime_pod_protocol_asset_transport.inc"
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
static_assert(std::is_trivially_copyable_v<RuntimeEconomyAssetRequest>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyAssetResult>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyAssetProtocolStatus>);
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

#include "runtime_pod_protocol_country.inc"
static_assert(std::is_trivially_copyable_v<RuntimeCommandEnvelope>);
static_assert(std::is_trivially_copyable_v<RuntimeCommandPacket>);
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

struct RuntimeDayTail;
struct RuntimeGoldenSnapshot;
struct RuntimeFiscalDisplay;

struct RuntimeNotice {
    std::string id, title, settlement;
    int32_t cell = -1;
    int32_t category = 0;
};

struct RuntimeDayRecord {
    RuntimeCommitHeader header;
    std::vector<RuntimeCommandReceipt> receipts;
    std::shared_ptr<const RuntimeGoldenSnapshot> golden;
    std::vector<RuntimeNotice> notices;
    std::shared_ptr<const RuntimeFiscalDisplay> fiscal;
    uint64_t business_hash = 0;
    bool annual_reward_pending = false;
};

struct RuntimeCommit {
    RuntimeCommitHeader header;
    std::vector<RuntimeCommandReceipt> receipts;
    std::shared_ptr<const RuntimeDayTail> day_tail;
};

#include "runtime_pod_thread_report.h"

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
    // CPD2 v2 wraps the exact PKCN payload used by the normal Country provider
    // plus worker protocol metadata. country_pkcn_bytes is not another wire
    // section; it lets the save coordinator reuse the same capture.
    std::vector<uint8_t> country_bytes;
    std::vector<uint8_t> country_pkcn_bytes;
    std::vector<uint8_t> trigger_bytes;
    std::vector<uint8_t> modifier_bytes;
    std::vector<uint8_t> events_bytes;
    std::vector<uint8_t> effect_bytes;
    std::vector<uint8_t> effect_transport_bytes;
    std::vector<uint8_t> gameplay_effect_bytes;
    std::vector<uint8_t> military_terrain_bytes;
    std::vector<uint8_t> season_history_bytes;
    std::vector<uint8_t> player_confirmation_bytes;
    std::vector<uint8_t> vision_bytes, bio_bytes, climate_calendar_bytes;
    // The container writes these as separate PKSV sections using the same capture.
    std::vector<uint8_t> narrative_bytes, military_bytes;
    std::vector<uint8_t> ideology_bytes;
    // Economy POD ECP1 section (graph authority snapshot). No longer written:
    // restore is ECP2-only, so a save would ship a second full economy encoding
    // that nothing reads. Kept so ABI-9-era bundles still parse.
    std::vector<uint8_t> economy_pod_bytes;
    std::vector<uint8_t> economy_command_bytes, trigger_transport_bytes;
    // Economy ECP2 full-authority section. Captured once per save and exported to
    // the PKSV `ecp2` provider section; it is not embedded in the PKSR wire bytes
    // any more, because the container stored the identical block a second time.
    std::vector<uint8_t> economy_ecp2_bytes;
    // D7T1 Host Country/Economy asset journal. Independent of Economy POD
    // section ownership; restores peer continuation without granting Economy
    // ACTIVE authority.
    std::vector<uint8_t> economy_asset_bytes;
    uint64_t economy_fact_event_sequence = 0;
    int64_t trigger_forwarded_event_id = 0;
    uint64_t trigger_forward_sequence = 0;
    std::array<uint64_t, 256> producer_sequences{};
    uint64_t fallback_producer_sequence = 0;
};

} // namespace pk
