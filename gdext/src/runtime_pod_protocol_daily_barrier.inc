// Fixed native day order, plans, commits and cross-domain intents.

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

// 12 域 stage 的稳定短名（诊断/遥测用）。与 runtime_domain_stage_order() 同序，
// 也与 fault-injection 的 tag 同名，这样 stage_ms 字典的键和日志里的点名对得上。
constexpr const char *runtime_domain_stage_key(RuntimeDomainId domain) {
    switch (domain) {
    case RuntimeDomainId::INPUT_CAPTURE: return "input_capture";
    case RuntimeDomainId::CLIMATE: return "climate";
    case RuntimeDomainId::COUNTRY: return "country";
    case RuntimeDomainId::TRIGGER_INPUT: return "trigger_input";
    case RuntimeDomainId::IDEOLOGY: return "ideology";
    case RuntimeDomainId::EFFECT: return "effect";
    case RuntimeDomainId::MODIFIER: return "modifier";
    case RuntimeDomainId::GAMEPLAY_EFFECT: return "gameplay_effect";
    case RuntimeDomainId::ECONOMY: return "economy";
    case RuntimeDomainId::EVENTS: return "events";
    case RuntimeDomainId::VISUAL: return "visual";
    case RuntimeDomainId::COMMIT: return "commit";
    }
    return "unknown";
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
    RuntimeFrozenInputVersion frozen_input;
    RuntimeFreezeReadSet freeze_reads;
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
    // Country/Economy peer barriers may leave the day incomplete while the
    // worker keeps ownership. The host uses this to keep the day open without
    // advancing the authoritative committed watermark.
    uint8_t continuation_pending = 0;
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
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    // Country peer ACKs may carry the committed technology state so the
    // worker can complete a pending activation without reaching into the
    // Effect/Modifier store. Other domains leave this at zero.
    uint8_t technology_flags = 0;
    uint8_t reserved_technology_flags[7]{};
};

constexpr uint16_t RUNTIME_DOMAIN_INTENT_DEFERRED = 1u << 0;
constexpr uint16_t RUNTIME_DOMAIN_INTENT_REQUIRES_ACK = 1u << 1;

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
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    // Fixed Modifier command lanes. Generic domains may leave these at their
    // defaults; Effect uses them so duration/stack/magnitude survive the POD
    // handoff without an opaque byte payload.
    int32_t duration_days = -2;
    int32_t stacks = 1;
    int32_t magnitude_q16 = 65536;
    int32_t reserved = 0;
    uint64_t group_handle = 0;
    uint64_t modifier_handle = 0;
    // Effect fills these lanes with the typed action (1..6) and the stable
    // command idempotency identity. Other domains leave them at zero.
    uint16_t effect_action = 0;
    uint16_t reserved_effect = 0;
    // Set by Effect when `value` came from an emitted command, including the
    // legitimate zero value. Adapters must not infer presence from `value != 0`.
    uint32_t reserved_effect_flags = 0;
    uint64_t idempotency_key = 0;
};
