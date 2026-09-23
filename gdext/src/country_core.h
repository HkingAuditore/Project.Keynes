#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace pk {

// K2-A peer protocol.  The Country research algorithm consumes one immutable
// context and emits typed intents; it does not reach into Effect/Modifier or
// Economy stores while walking research queues.  The synchronous facade uses
// the same records with a local adapter.  A worker adapter may retain the
// records until the corresponding peer result arrives.
constexpr uint32_t COUNTRY_PEER_PROTOCOL_VERSION = 1u;
constexpr size_t COUNTRY_PEER_REASON_CAPACITY = 64u;

enum class CountryPeerIntentCode : uint16_t {
    ENSURE_TECHNOLOGY_EFFECT = 1,
    NUDGE_TECHNOLOGY_EFFECT = 2,
    APPLY_TECHNOLOGY_MODIFIER = 3,
    NOTIFY_ERA_REWARD = 4,
    NOTIFY_ECONOMY_MILESTONE = 5,
};

enum class CountryPeerResultCode : uint8_t {
    READY = 0,
    PENDING = 1,
    APPLIED = 2,
    REJECTED = 3,
    STALE = 4,
};

enum CountryPeerTechnologyStateFlags : uint8_t {
    COUNTRY_PEER_EFFECT_EXISTS = 1u << 0u,
    COUNTRY_PEER_EFFECT_FIRE_ACKED = 1u << 1u,
    COUNTRY_PEER_MODIFIER_APPLIED = 1u << 2u,
};

struct CountryPeerTechnologyState {
    int32_t country_slot = -1;
    int32_t technology = -1;
    uint64_t target_handle = 0;
    uint64_t effect_instance_id = 0;
    uint32_t effect_generation = 0;
    uint8_t flags = 0;

    bool has(uint8_t flag) const noexcept { return (flags & flag) != 0; }
};

// This is a capture object, not an authority.  Its vectors are immutable once
// passed to a research step.  `technology_states` is sparse and sorted by
// (country_slot, technology), so pending activation does not require a dense
// country-by-technology matrix.
struct CountryPeerContext {
    uint32_t protocol_version = COUNTRY_PEER_PROTOCOL_VERSION;
    uint64_t session_epoch = 0;
    uint64_t country_generation = 0;
    uint64_t modifier_generation = 0;
    uint64_t effect_generation = 0;
    uint64_t economy_generation = 0;
    int64_t day = -1;
    uint32_t continuation_index = 0;
    uint8_t effect_enabled = 0;
    uint8_t modifier_enabled = 0;
    uint8_t economy_enabled = 0;
    uint8_t effect_should_run = 0;
    uint8_t modifier_should_run = 0;
    double max_research_cost_factor = 4.0;
    std::vector<double> research_cost_factor;
    std::vector<double> research_efficiency;
    std::vector<CountryPeerTechnologyState> technology_states;
};

// Every intent carries the identity of the Country boundary that produced it.
// `peer_generation` is the captured peer-domain watermark; it is checked when
// a worker result is consumed so a delayed ACK cannot mutate a newer boundary.
struct CountryPeerIntent {
    uint32_t protocol_version = COUNTRY_PEER_PROTOCOL_VERSION;
    CountryPeerIntentCode opcode = CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT;
    uint64_t request_id = 0;
    uint64_t session_epoch = 0;
    uint64_t country_generation = 0;
    uint64_t peer_generation = 0;
    int64_t day = -1;
    uint32_t continuation_index = 0;
    int32_t country_slot = -1;
    int32_t technology = -1;
    uint64_t target_handle = 0;
    uint64_t effect_instance_id = 0;
    uint32_t effect_generation = 0;
    uint64_t idempotency_key = 0;
};

struct CountryPeerResult {
    uint32_t protocol_version = COUNTRY_PEER_PROTOCOL_VERSION;
    CountryPeerResultCode code = CountryPeerResultCode::REJECTED;
    CountryPeerIntentCode opcode = CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT;
    uint64_t request_id = 0;
    uint64_t session_epoch = 0;
    uint64_t country_generation = 0;
    // Generation captured after the peer has applied (or durably rejected)
    // the intent.  `peer_generation` remains the input watermark from the
    // intent so delayed ACKs can be checked against the original request.
    uint64_t committed_peer_generation = 0;
    uint64_t peer_generation = 0;
    int64_t day = -1;
    uint32_t continuation_index = 0;
    int32_t country_slot = -1;
    int32_t technology = -1;
    uint64_t target_handle = 0;
    uint8_t technology_flags = 0;
    std::array<char, COUNTRY_PEER_REASON_CAPACITY> reason{};

    bool ok() const noexcept {
        return code == CountryPeerResultCode::READY ||
            code == CountryPeerResultCode::PENDING ||
            code == CountryPeerResultCode::APPLIED;
    }
    bool has(uint8_t flag) const noexcept {
        return (technology_flags & flag) != 0;
    }
};

// The protocol state is separate from Country business state. It controls
// whether a boundary may wait, report a peer rejection, retry on a later day,
// or be captured into CPD2. Rejected work remains an in-memory retry barrier;
// CPD2 capture must refuse it instead of silently dropping the retry metadata.
struct CountryPeerProtocolStatus {
    uint32_t protocol_version = COUNTRY_PEER_PROTOCOL_VERSION;
    uint8_t async_mode = 0;
    uint32_t pending_intents = 0;
    uint32_t queued_intents = 0;
    uint32_t rejected_intents = 0;
    uint8_t has_unreported_rejection = 0;
    int64_t retry_day = -1;
    uint64_t rejected_request_id = 0;
    CountryPeerIntentCode rejected_opcode =
        CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT;
    std::array<char, COUNTRY_PEER_REASON_CAPACITY> rejection_reason{};

    bool has_save_barrier() const noexcept {
        return pending_intents != 0 || queued_intents != 0 ||
            rejected_intents != 0;
    }
};

uint64_t country_peer_request_id(uint64_t session_epoch,
                                 uint64_t country_generation,
                                 int64_t day,
                                 uint32_t continuation_index,
                                 int32_t country_slot,
                                 int32_t technology,
                                 CountryPeerIntentCode opcode) noexcept;

void country_peer_copy_reason(
    std::array<char, COUNTRY_PEER_REASON_CAPACITY> &destination,
    const char *source) noexcept;

// Shared Country research math.  These functions intentionally contain no
// Godot/runtime references so the synchronous reference authority and the POD
// authority cannot drift in the completion-day calculation.  The callers own
// queue traversal, prerequisite predicates and peer intents; this layer owns
// only the fixed-point/integer arithmetic and deterministic remainder order.
constexpr uint32_t COUNTRY_RESEARCH_DOMAIN_COUNT = 4u;

struct CountryResearchAllocation {
    std::array<int64_t, COUNTRY_RESEARCH_DOMAIN_COUNT> shares{{0, 0, 0, 0}};
    std::array<int64_t, COUNTRY_RESEARCH_DOMAIN_COUNT> remainders{{0, 0, 0, 0}};
    int64_t available = 0;
    int64_t assigned = 0;
    int64_t remainder_units = 0;
};

CountryResearchAllocation country_allocate_research_points(
    int64_t available,
    const std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> &weights,
    uint64_t *remainder_iterations = nullptr) noexcept;

// Empty queues cannot spend. Move their shares onto domains that have a
// queue, in proportion to those domains' weights, so a single queued
// technology receives the whole treasury instead of leaving it stranded on
// idle domains. A non-empty queue that later cannot advance still keeps its
// own share for the deferred-stock path.
void country_redirect_idle_research_shares(
    CountryResearchAllocation &allocation,
    const std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> &weights,
    const std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> &queue_lengths) noexcept;

struct CountryResearchProgress {
    bool valid = false;
    int64_t effective_cost = 0;
    int64_t remaining = 0;
    int64_t spend_needed = 0;
    int64_t spend = 0;
    int64_t progress_gain = 0;
    bool completed = false;
};

int64_t country_effective_research_cost(
    int64_t base_cost, double cost_factor) noexcept;

CountryResearchProgress country_advance_research_progress(
    int64_t progress, int64_t base_cost, double cost_factor,
    double efficiency, int64_t available_points) noexcept;

enum class CountryCommandReceiptCode : uint8_t {
    ADMISSION_REJECTED = 0,
    ACCEPTED = 1,
    COMMITTED = 2,
    REJECTED_AT_EXECUTION = 3,
};

struct CountryTypedCommand {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    uint16_t opcode = 0;
    uint64_t target_handle = 0;
    int32_t cell = -1;
    int32_t aux = -1;
    int32_t domain = -1;
    int32_t position = -1;
    int32_t weights_bp[4] = {0, 0, 0, 0};
    int32_t tax_kind = -1;
    int32_t tax_item = -1;
    int32_t tax_rate_basis_points = 0;
    int32_t tax_assessment_mode = 0;
    int64_t value = 0;
    std::string stable_id;
    std::string display_name;
    // Assigned by the accepting owner. Transport chunking must never replace
    // this semantic admission order.
    uint64_t submit_order = 0;
};

struct CountryCommandReceipt {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    int64_t effective_day = 0;
    uint64_t generation = 0;
    CountryCommandReceiptCode code = CountryCommandReceiptCode::ACCEPTED;
    std::string reason;
};

struct CountryPendingCommandProtocol {
    uint64_t submit_order = 0;
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t observed_generation = 0;
};

constexpr uint32_t COUNTRY_CHECKPOINT_ABI_VERSION = 2u;
constexpr uint32_t COUNTRY_CHECKPOINT_SCHEMA_VERSION = 13u;

// CPD2 wraps the exact canonical PKCN payload captured at the save boundary.
// The protocol tail preserves command/receipt identity without changing PKCN
// v13 or making transport metadata part of the business state hash.
struct CountryCoreCheckpoint {
    uint32_t abi_version = COUNTRY_CHECKPOINT_ABI_VERSION;
    uint32_t country_schema_version = COUNTRY_CHECKPOINT_SCHEMA_VERSION;
    uint64_t session_epoch = 0;
    uint64_t catalog_hash = 0;
    uint64_t generation = 0;
    int64_t committed_day = -1;
    uint64_t business_state_hash = 0;
    uint64_t command_watermark = 0;
    uint64_t next_event_id = 1;
    uint64_t next_boundary_id = 1;
    uint64_t checkpoint_hash = 0;
    std::vector<uint8_t> canonical_pkcn;
    std::vector<CountryPendingCommandProtocol> pending_protocol;
    std::vector<CountryCommandReceipt> request_states;
    std::vector<CountryCommandReceipt> terminal_receipts;
};

uint64_t country_checkpoint_checksum(const uint8_t *bytes, size_t size) noexcept;
bool validate_country_core_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                      std::string &error);
bool encode_country_core_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                    std::vector<uint8_t> &out,
                                    std::string &error);
bool decode_country_core_checkpoint(const uint8_t *bytes, size_t size,
                                    CountryCoreCheckpoint &out,
                                    std::string &error);

struct CountryBoundarySeal {
    uint64_t session_epoch = 0;
    uint64_t boundary_id = 0;
    int64_t day = -1;
    uint64_t last_admitted_submit_order = 0;
    uint64_t expected_base_generation = 0;
    uint64_t catalog_hash = 0;
};

// Godot-free result of one cooperative Country boundary step. The synchronous
// facade and the simulation worker both consume this contract; neither owns a
// second command/research algorithm.
enum class CountryCoreStepStatus : uint8_t {
    PROGRESS = 0,
    NEED_PEER_RESULTS = 1,
    BOUNDARY_COMMITTED = 2,
    DAY_QUIESCENT = 3,
    REJECTED = 4,
    FAULTED = 5,
    OFF = 6,
};

struct CountryCoreStepResult {
    CountryCoreStepStatus status = CountryCoreStepStatus::DAY_QUIESCENT;
    bool ok = true;
    bool done = true;
    bool semantic_commit = false;
    bool day_barrier = false;
    bool published_to_slot = false;
    std::string stage = "idle";
    std::string path = "native_active";
    std::string reason;
    double preflight_ms = 0.0;
    double apply_ms = 0.0;
    double publish_ms = 0.0;
    double elapsed_ms = 0.0;
    int64_t cursor_start = 0;
    int64_t cursor_end = 0;
    int64_t cursor_total = 0;
    double progress_ratio = 1.0;
    int32_t changed_cells = 0;
    int32_t changed_countries = 0;
    int64_t observation_batch_input = 0;
    int64_t observation_batch_added = 0;
    CountryBoundarySeal seal;
    std::vector<int32_t> changed_cell_indices;
    std::vector<int32_t> changed_cell_owners;
};

const char *country_core_step_status_name(CountryCoreStepStatus status);

} // namespace pk
