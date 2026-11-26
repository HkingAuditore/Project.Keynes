// Country and Economy asset transport wire records and state conversion.

// K2-B Country/Economy transaction wire contract.  These records are fixed
// size and trivially copyable so the worker can publish them without exposing
// a Godot value or a mutable Economy container.  The business state machine
// is intentionally explicit: after Country has prepared its side, the peer
// may only advance the same transaction identity; it must never create a new
// transaction to retry a post-decision step.
enum class RuntimeEconomyAssetOperation : uint16_t {
    RESEARCH_PURCHASE = 1,
    FISCAL_RESERVE = 2,
    FISCAL_RETURN = 3,
    FISCAL_COLLECT = 4,
    CASH_TO_COHORT = 5,
    CASH_FROM_COHORT = 6,
    GOOD_TO_MARKET = 7,
    GOOD_FROM_MARKET = 8,
    TREASURY_SPEND = 9,
};

// Country/Economy asset backpressure. Every reason here means the request was
// never allocated, or was re-queued intact: no store was mutated, so the caller
// must yield the slice and retry on a later pulse. Treating one of them as an
// economy fatal leaves the epoch half-open, and the next report then shows
// staged mints without their committed owner funds — the misleading
// money_error/goods_error the GM panel used to display instead of the real
// reason. Keep this the single definition; the reason set is consumed by the
// Economy stage drains, the epoch prelude, and the Host worker pulse.
inline bool runtime_country_asset_pending_reason(const std::string &reason) {
    return reason == "country_economy_asset_host_pending" ||
           reason == "country_economy_asset_results_pending" ||
           reason == "country_economy_asset_rejection_retry_pending" ||
           reason == "country_economy_asset_completion_retry_pending" ||
           reason == "country_economy_fiscal_terminal_retry_pending" ||
           reason == "country_economy_asset_result_identity_retry_pending" ||
           reason == "country_economy_asset_country_plan_pending" ||
           reason == "country_economy_asset_territory_claim_pending";
}

enum class RuntimeEconomyAssetState : uint8_t {
    CREATED = 1,
    COUNTRY_PREPARED = 2,
    PEER_PREPARED = 3,
    COMMIT_DECIDED = 4,
    COUNTRY_APPLIED = 5,
    PEER_APPLIED = 6,
    COMPLETED = 7,
    REJECTED = 8,
    AWAITING_PEER_PREPARED = 9,
    AWAITING_PEER_APPLIED = 10,
    FAULTED = 11,
};

enum class RuntimeEconomyAssetResultCode : uint8_t {
    ACCEPTED = 0,
    PENDING = 1,
    PEER_PREPARED = 2,
    COMMIT_DECIDED = 3,
    PEER_APPLIED = 4,
    COMPLETED = 5,
    REJECTED = 6,
    FAULTED = 7,
};

// External D7 reservation vocabulary (fix方案 stage 5). Wire storage keeps the
// finer RuntimeEconomyAssetState values above; reporters and journals project
// those values onto this public state machine:
//   ADMITTED → RESERVED → COMMITTED
//   ADMITTED/RESERVED → RETRY | ROLLED_BACK
//   terminal duplicate → original terminal
//   stale generation/session/late ACK → REJECTED
enum class RuntimeD7ReservationState : uint8_t {
    ADMITTED = 1,
    RESERVED = 2,
    COMMITTED = 3,
    RETRY = 4,
    ROLLED_BACK = 5,
    REJECTED = 6,
};

enum class RuntimeD7TerminalResult : uint8_t {
    NONE = 0,
    COMMITTED = 1,
    RETRY = 2,
    ROLLED_BACK = 3,
    REJECTED = 4,
};

// Stale generation / old session / late ACK reasons project to REJECTED.
// Other terminal failures project to ROLLED_BACK (or RETRY when FAULTED).
inline bool runtime_d7_reason_is_stale_reject(const char *reason) noexcept {
    if (reason == nullptr || reason[0] == '\0') return false;
    return std::strstr(reason, "late") != nullptr ||
        std::strstr(reason, "session") != nullptr ||
        std::strstr(reason, "generation") != nullptr;
}

inline RuntimeD7ReservationState runtime_d7_reservation_state_from_asset(
        RuntimeEconomyAssetState state,
        RuntimeEconomyAssetResultCode code =
            RuntimeEconomyAssetResultCode::ACCEPTED,
        const char *reason = nullptr) noexcept {
    switch (code) {
    case RuntimeEconomyAssetResultCode::COMPLETED:
        return RuntimeD7ReservationState::COMMITTED;
    case RuntimeEconomyAssetResultCode::FAULTED:
        return RuntimeD7ReservationState::RETRY;
    case RuntimeEconomyAssetResultCode::REJECTED:
        if (state == RuntimeEconomyAssetState::FAULTED)
            return RuntimeD7ReservationState::RETRY;
        return runtime_d7_reason_is_stale_reject(reason)
            ? RuntimeD7ReservationState::REJECTED
            : RuntimeD7ReservationState::ROLLED_BACK;
    default:
        break;
    }
    switch (state) {
    case RuntimeEconomyAssetState::CREATED:
    case RuntimeEconomyAssetState::COUNTRY_PREPARED:
        return RuntimeD7ReservationState::ADMITTED;
    case RuntimeEconomyAssetState::PEER_PREPARED:
    case RuntimeEconomyAssetState::COMMIT_DECIDED:
    case RuntimeEconomyAssetState::COUNTRY_APPLIED:
    case RuntimeEconomyAssetState::AWAITING_PEER_PREPARED:
    case RuntimeEconomyAssetState::AWAITING_PEER_APPLIED:
        return RuntimeD7ReservationState::RESERVED;
    case RuntimeEconomyAssetState::PEER_APPLIED:
    case RuntimeEconomyAssetState::COMPLETED:
        return RuntimeD7ReservationState::COMMITTED;
    case RuntimeEconomyAssetState::FAULTED:
        return RuntimeD7ReservationState::RETRY;
    case RuntimeEconomyAssetState::REJECTED:
        return runtime_d7_reason_is_stale_reject(reason)
            ? RuntimeD7ReservationState::REJECTED
            : RuntimeD7ReservationState::ROLLED_BACK;
    default:
        return RuntimeD7ReservationState::REJECTED;
    }
}

inline RuntimeD7TerminalResult runtime_d7_terminal_result_from_asset(
        RuntimeEconomyAssetResultCode code,
        RuntimeEconomyAssetState state,
        const char *reason = nullptr) noexcept {
    switch (code) {
    case RuntimeEconomyAssetResultCode::COMPLETED:
        return RuntimeD7TerminalResult::COMMITTED;
    case RuntimeEconomyAssetResultCode::FAULTED:
        return RuntimeD7TerminalResult::RETRY;
    case RuntimeEconomyAssetResultCode::REJECTED:
        if (state == RuntimeEconomyAssetState::FAULTED)
            return RuntimeD7TerminalResult::RETRY;
        return runtime_d7_reason_is_stale_reject(reason)
            ? RuntimeD7TerminalResult::REJECTED
            : RuntimeD7TerminalResult::ROLLED_BACK;
    default:
        return RuntimeD7TerminalResult::NONE;
    }
}

inline const char *runtime_d7_reservation_state_name(
        RuntimeD7ReservationState state) noexcept {
    switch (state) {
    case RuntimeD7ReservationState::ADMITTED: return "ADMITTED";
    case RuntimeD7ReservationState::RESERVED: return "RESERVED";
    case RuntimeD7ReservationState::COMMITTED: return "COMMITTED";
    case RuntimeD7ReservationState::RETRY: return "RETRY";
    case RuntimeD7ReservationState::ROLLED_BACK: return "ROLLED_BACK";
    case RuntimeD7ReservationState::REJECTED: return "REJECTED";
    default: return "UNKNOWN";
    }
}

inline const char *runtime_d7_terminal_result_name(
        RuntimeD7TerminalResult result) noexcept {
    switch (result) {
    case RuntimeD7TerminalResult::NONE: return "NONE";
    case RuntimeD7TerminalResult::COMMITTED: return "COMMITTED";
    case RuntimeD7TerminalResult::RETRY: return "RETRY";
    case RuntimeD7TerminalResult::ROLLED_BACK: return "ROLLED_BACK";
    case RuntimeD7TerminalResult::REJECTED: return "REJECTED";
    default: return "UNKNOWN";
    }
}

enum class RuntimeEconomyAssetProtocolError : uint16_t {
    NONE = 0,
    PROTOCOL_MISMATCH = 1,
    REQUEST_INVALID = 2,
    REQUEST_UNKNOWN = 3,
    REQUEST_DUPLICATE_MISMATCH = 4,
    RESULT_IDENTITY_MISMATCH = 5,
    RESULT_STATE_INVALID = 6,
    RESULT_DUPLICATE_MISMATCH = 7,
    SESSION_MISMATCH = 8,
    GENERATION_MISMATCH = 9,
    CAPACITY_EXCEEDED = 10,
};

constexpr uint32_t RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION = 1u;
constexpr size_t RUNTIME_ECONOMY_ASSET_REASON_CAPACITY = 64u;

struct RuntimeEconomyAssetRequest {
    uint32_t protocol_version = RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION;
    RuntimeEconomyAssetOperation operation =
        RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    RuntimeEconomyAssetState state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    uint8_t all_or_nothing = 0;
    uint8_t reserved0 = 0;
    uint16_t reserved1 = 0;
    uint64_t session_epoch = 0;
    uint64_t transaction_id = 0;
    uint64_t request_id = 0;
    uint32_t origin_domain = static_cast<uint32_t>(RuntimeDomainId::COUNTRY);
    int64_t origin_epoch = -1;
    int32_t origin_stage = -1;
    uint32_t continuation_index = 0;
    int64_t day = -1;
    uint64_t operation_sequence = 0;
    uint64_t country_generation = 0;
    uint64_t peer_generation = 0;
    uint64_t country_handle = 0;
    int32_t country_slot = -1;
    int32_t target_slot = -1;
    uint64_t target_handle = 0;
    int32_t good_id = -1;
    uint32_t good_count = 0;
    std::array<int32_t, RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY> good_ids{};
    std::array<int64_t, RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY> good_quantities{};
    int64_t requested_quantity = 0;
    int64_t prepared_quantity = 0;
    int64_t requested_cash = 0;
    int64_t reserved_cash = 0;
    int64_t requested_goods_total = 0;
    int64_t reserved_goods_total = 0;
};

struct RuntimeEconomyAssetResult {
    uint32_t protocol_version = RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION;
    RuntimeEconomyAssetResultCode code = RuntimeEconomyAssetResultCode::REJECTED;
    RuntimeEconomyAssetState state = RuntimeEconomyAssetState::REJECTED;
    uint8_t accepted = 0;
    uint8_t reserved0 = 0;
    uint16_t reserved1 = 0;
    uint64_t session_epoch = 0;
    uint64_t transaction_id = 0;
    uint64_t request_id = 0;
    RuntimeEconomyAssetOperation operation =
        RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    uint32_t continuation_index = 0;
    int64_t day = -1;
    uint64_t country_generation = 0;
    uint64_t peer_generation = 0;
    uint64_t committed_peer_generation = 0;
    int32_t country_slot = -1;
    int32_t target_slot = -1;
    int64_t committed_quantity = 0;
    int64_t committed_cash = 0;
    int64_t committed_goods_total = 0;
    std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> reason{};
};

using CountryEconomyAssetRequest = RuntimeEconomyAssetRequest;
using CountryEconomyAssetResult = RuntimeEconomyAssetResult;

struct RuntimeEconomyAssetProtocolStatus {
    uint32_t protocol_version = RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION;
    uint32_t queued_requests = 0;
    uint32_t pending_requests = 0;
    uint32_t terminal_requests = 0;
    uint32_t rejected_results = 0;
    uint32_t faulted_transactions = 0;
    uint32_t recovered_transactions = 0;
    uint32_t duplicate_messages = 0;
    uint64_t session_epoch = 0;
    uint64_t last_transaction_id = 0;
    uint64_t last_request_id = 0;
    RuntimeEconomyAssetProtocolError last_error =
        RuntimeEconomyAssetProtocolError::NONE;
    std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> last_reason{};
};
