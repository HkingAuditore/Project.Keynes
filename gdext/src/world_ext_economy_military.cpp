#include "world_ext.h"

#include "economy_runtime.h"
#include "military_bridge.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <type_traits>
#include <utility>
#include <vector>

namespace pk {

using namespace godot;

namespace {
NativeEconomyRuntime *economy_runtime_from(void *opaque) {
    return static_cast<NativeEconomyRuntime *>(opaque);
}

// NativeEconomyRuntime::EventKind / Opcode values (economy_runtime.h). Kept as
// literals so this TU only depends on the public poll_events() surface.
constexpr int32_t kEconomyEventCommandSettled = 1;
constexpr int32_t kEconomyEventStructuralChange = 3;
constexpr int32_t kEconomyEventEpochCommitted = 10;
constexpr int32_t kEconomyOpTransferToCohort = 1;
constexpr int32_t kEconomyOpRemoveStock = 5;
constexpr int32_t kEconomyOpAddPopulation = 6;
constexpr int32_t kEconomyOpChangeSignature = 8;
constexpr int32_t kEconomyOpConvertCohort = 24;   // B: in-cell signature move
constexpr int32_t kEconomyOpMarketGoodToCountry = 13;
constexpr int32_t kEconomyOpArmyEmbark = 30;      // cell cohort -> army lane
constexpr int32_t kEconomyOpArmyDisembark = 31;   // army lane -> cell cohort
constexpr int32_t kEconomyOpArmyMergeLanes = 32;  // src lane -> dst lane

// ---- Army personnel lane probe (army-personnel contract §1.4) -------------
// The lane bindings live on NativeEconomyRuntime, which is owned by the Economy
// engineer and may not exist yet in this tree (two concurrent engineers, one
// DLL). Detect them at compile time instead of failing to link: that is the C++
// equivalent of the GDScript `has_method` guard, so the bridge keeps running on
// a build whose economy has no army lane and reports "unsupported" instead of
// calling into a method that does not exist.
template <typename T, typename = void>
struct HasArmyLanePopulation : std::false_type {};
template <typename T>
struct HasArmyLanePopulation<T,
    std::void_t<decltype(std::declval<T &>().military_army_population(
        std::declval<uint64_t>()))>> : std::true_type {};

template <typename T, typename = void>
struct HasArmyLaneRation : std::false_type {};
template <typename T>
struct HasArmyLaneRation<T,
    std::void_t<decltype(std::declval<T &>().set_military_army_ration(
        std::declval<uint64_t>(), std::declval<int32_t>()))>> : std::true_type {};

template <typename T>
int64_t lane_population_of(T *runtime, uint64_t army_handle) {
    if constexpr (HasArmyLanePopulation<T>::value) {
        return static_cast<int64_t>(runtime->military_army_population(army_handle));
    } else {
        (void)runtime;
        (void)army_handle;
        return -1;
    }
}

template <typename T>
bool set_lane_ration_of(T *runtime, uint64_t army_handle, int32_t q16) {
    if constexpr (HasArmyLaneRation<T>::value) {
        runtime->set_military_army_ration(army_handle, q16);
        return true;
    } else {
        (void)runtime;
        (void)army_handle;
        (void)q16;
        return false;
    }
}

struct EconomyEventPage {
    PackedInt64Array event_id, epoch_id, sample_day, commit_day, subject_id;
    PackedInt32Array kind, cell, subject_i0, subject_i1;
    PackedInt64Array value0, value1, value2;
    int64_t count = 0;
};

EconomyEventPage read_page(const Dictionary &page) {
    EconomyEventPage out;
    out.event_id = page.get("event_id", PackedInt64Array());
    out.epoch_id = page.get("epoch_id", PackedInt64Array());
    out.sample_day = page.get("sample_day", PackedInt64Array());
    out.commit_day = page.get("commit_day", PackedInt64Array());
    out.subject_id = page.get("subject_id", PackedInt64Array());
    out.kind = page.get("kind", PackedInt32Array());
    out.cell = page.get("cell", PackedInt32Array());
    out.subject_i0 = page.get("subject_i0", PackedInt32Array());
    out.subject_i1 = page.get("subject_i1", PackedInt32Array());
    out.value0 = page.get("value0", PackedInt64Array());
    out.value1 = page.get("value1", PackedInt64Array());
    out.value2 = page.get("value2", PackedInt64Array());
    out.count = std::min<int64_t>({out.event_id.size(), out.epoch_id.size(),
        out.subject_id.size(), out.subject_i0.size(), out.subject_i1.size(),
        out.value0.size(), out.value1.size(), out.value2.size(),
        out.sample_day.size(), out.commit_day.size()});
    return out;
}

// The economy command fields echoed by EVENT_COMMAND_SETTLED
// (economy_runtime.cpp apply_command trace_append): subject_id = sequence,
// subject_i0 = opcode, subject_i1 = i32_1, value0 = applied value,
// value1 = i64_0, value2 = i64_1.
int64_t expected_i64_0(int32_t opcode, int64_t count, int64_t amount) {
    switch (opcode) {
    case kEconomyOpAddPopulation: return -std::max<int64_t>(0, count);
    case kEconomyOpTransferToCohort: return amount;
    default: return count;
    }
}
} // namespace

// ---- Army personnel lane bridge helpers (army-personnel contract §1.4) -----
// Declared in world_ext_military.cpp (this TU is the only one that may look at
// the Economy bindings). `supported` answers false, the population probe -1 and
// the ration publish false whenever the loaded economy has no lane bindings, so
// Military degrades to the pre-lane model instead of trapping.
bool economy_army_lane_supported(const void *economy) {
    if (economy == nullptr) return false;
    return HasArmyLanePopulation<NativeEconomyRuntime>::value;
}

int64_t economy_army_lane_population(void *economy, uint64_t army_handle) {
    if (economy == nullptr) return -1;
    return lane_population_of(economy_runtime_from(economy), army_handle);
}

bool economy_set_army_ration(void *economy, uint64_t army_handle, int32_t q16) {
    if (economy == nullptr) return false;
    return set_lane_ration_of(economy_runtime_from(economy), army_handle, q16);
}

// Economy-side military hooks (design §5.1). Everything here is a
// main-thread publish of data Military already owns; no economy state is
// advanced and no day is scheduled.
Dictionary DCWorldExt::set_military_ration_satisfaction(
        const PackedInt32Array &cells, const PackedInt32Array &q16) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_not_configured";
        out["written"] = static_cast<int64_t>(0);
        return out;
    }
    const int64_t input = cells.size();
    if (q16.size() != input) {
        out["ok"] = false;
        out["reason"] = "military_ration_column_size_mismatch";
        out["written"] = static_cast<int64_t>(0);
        return out;
    }
    // Two flat copies, no per-cell Variant: this is called once per Military
    // day and must not allocate inside a hot loop.
    std::vector<int32_t> cell_indices;
    std::vector<int32_t> values;
    cell_indices.resize(static_cast<size_t>(input));
    values.resize(static_cast<size_t>(input));
    for (int64_t i = 0; i < input; ++i) {
        cell_indices[static_cast<size_t>(i)] = cells[i];
        values[static_cast<size_t>(i)] = q16[i];
    }
    const int32_t written = economy_runtime_from(_economy_runtime)
        ->set_military_ration_satisfaction(cell_indices, values);
    out["ok"] = true;
    out["written"] = static_cast<int64_t>(written);
    return out;
}

// ---------------------------------------------------------------------------
// Economy command receipts for Military intents (authority 2).
//
// Economy has no per-command receipt for legacy `submit_economy_commands`
// rows, so the bridge folds the existing committed trace stream:
//   * EVENT_COMMAND_SETTLED (one per applied command, in the same committed
//     batch as its epoch) identifies the row by (sequence, opcode, i32_1,
//     i64_0[, i64_1]) and carries the applied value: TRANSFER_TO_COHORT cash,
//     MARKET_GOOD_TO_COUNTRY / REMOVE_STOCK goods actually moved,
//     ADD_POPULATION actual (negative) population delta.
//   * CHANGE_SIGNATURE only queues a structural move at ledger time, so its
//     applied head count is the EVENT_STRUCTURAL_CHANGE of the epoch that
//     commits the move (subject = source cohort handle, subject_i0 = target
//     signature, subject_i1 = destination cell, value0 = moved heads). That row
//     is matched on its own fields: settlement and structural commit of one
//     command can land in different poll windows.
//   * EVENT_EPOCH_COMMITTED tells the bridge an epoch with sample_day >=
//     effective_day committed; a row still unsettled after that was rejected
//     at epoch open (stale handle / invalid target) and fails.
// Rows never seen (busy worker boundary, evicted trace) keep waiting until the
// bridge timeout in collect_military_receipts fails them. With economy trace
// mode OFF there is no stream: rows resolve optimistically with the requested
// quantity once Economy's last_committed_day reaches their effective day.
// ---------------------------------------------------------------------------
void DCWorldExt::collect_military_economy_receipts(
        int64_t day, std::vector<MilitaryIntentReceipt> &out) {
    (void)day;
    (void)out;  // rows are marked resolved; the caller emits receipts in order
    if (_economy_runtime == nullptr) return;
    bool any_open = false;
    for (const MilitaryPendingIntent &row : _military_pending_intents) {
        if (row.authority == 2 && row.receipt_pending == 1) {
            any_open = true;
            break;
        }
    }
    if (!any_open) return;
    NativeEconomyRuntime *economy = economy_runtime_from(_economy_runtime);
    // Worker-owned Economy: the committed batch deque is only readable while
    // holding the authority boundary between epochs. Busy -> retry next day.
    std::unique_lock<std::mutex> boundary;
    if (_runtime_host != nullptr && _runtime_host->economy_worker_owns_execution()) {
        boundary = _runtime_host->try_lock_economy_read_boundary();
        if (!boundary.owns_lock() || economy->epoch_active()) return;
    }
    const Dictionary report = economy->trace_report();
    if (String(report.get("mode", "SELECTIVE")) == String("OFF")) {
        const int64_t committed = economy->last_committed_day();
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 2 || row.receipt_pending != 1) continue;
            if (row.effective_day > committed) continue;
            row.receipt_pending = 2;  // approximation: requested == applied
        }
        return;
    }
    // Rows handed to the Economy POD queue (whole-graph ACTIVE) are applied
    // atomically inside the worker's own day and never publish a legacy
    // command-settled trace, so they settle on the committed-day boundary with
    // the requested quantity. They carry no request id (legacy ingress rows do).
    {
        const int64_t committed = economy->last_committed_day();
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 2 || row.receipt_pending != 1) continue;
            if (row.request_id != 0) continue;
            if (row.effective_day > committed) continue;
            // Do not assume the move happened: read the committed cohort back.
            // Military books only what Economy actually holds at the cell.
            int64_t applied = 0;
            if (row.opcode == kEconomyOpChangeSignature ||
                row.opcode == kEconomyOpConvertCohort) {
                applied = economy->military_soldier_heads(row.cell);
            } else if (row.opcode == kEconomyOpArmyEmbark) {
                // Army personnel lane: the row names the formation
                // (target_cohort = army handle), so the truth is the lane itself.
                // An unsupported economy answers -1: fall back to the requested
                // heads only then, because in that case no lane exists at all and
                // Military stays on the pre-lane accounting.
                const int64_t lane = economy_army_lane_population(
                    economy, static_cast<uint64_t>(row.target_handle));
                applied = lane >= 0 ? lane : row.count;
            } else if (row.opcode == kEconomyOpArmyDisembark ||
                       row.opcode == kEconomyOpArmyMergeLanes) {
                // Both remove heads from the named lane, so a lane readback says
                // nothing about how many actually moved; the batch applied
                // atomically, so the requested count is what landed.
                applied = row.count;
            } else if (row.count > 0) {
                applied = row.count;
            }
            applied = std::min<int64_t>(applied, row.count);
            row.count = applied;
            row.settled_value = applied;
            row.receipt_pending = applied > 0 ? 2 : 3;
        }
    }
    const int64_t after = std::max<int64_t>(0, _military_economy_event_cursor);
    const auto poll_kind = [&](int32_t kind) {
        Dictionary opts;
        opts["after_event_id"] = after;
        opts["kind"] = kind;
        opts["max_events"] = static_cast<int64_t>(65536);
        opts["consumer_id"] = StringName("military_bridge");
        return read_page(economy->poll_events(opts));
    };
    // All three pages are read under the same boundary, so they describe the
    // same set of committed batches.
    const EconomyEventPage settled = poll_kind(kEconomyEventCommandSettled);
    const EconomyEventPage structural = poll_kind(kEconomyEventStructuralChange);
    const EconomyEventPage epochs = poll_kind(kEconomyEventEpochCommitted);
    // 1. Command settlements.
    for (int64_t i = 0; i < settled.count; ++i) {
        const int64_t sequence = settled.subject_id[i];
        const int32_t opcode = settled.subject_i0[i];
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 2 || row.receipt_pending != 1 || row.settled_epoch != 0)
                continue;
            if (row.sequence != sequence || row.opcode != opcode) continue;
            if (settled.commit_day[i] < row.effective_day) continue;
            if (settled.value1[i] != expected_i64_0(opcode, row.count, row.amount)) continue;
            const int32_t expected_i1 =
                (opcode == kEconomyOpChangeSignature) ? row.cell
                : (opcode == kEconomyOpRemoveStock || opcode == kEconomyOpMarketGoodToCountry)
                    ? row.good : 0;
            if (settled.subject_i1[i] != expected_i1) continue;
            if (opcode == kEconomyOpTransferToCohort &&
                settled.value2[i] != static_cast<int64_t>(row.country_handle))
                continue;
            row.settled_epoch = std::max<int64_t>(1, settled.epoch_id[i]);
            switch (opcode) {
            case kEconomyOpTransferToCohort:
                row.amount = std::max<int64_t>(0, settled.value0[i]);
                row.receipt_pending = row.amount > 0 ? 2 : 3;
                break;
            case kEconomyOpAddPopulation:
                row.count = std::max<int64_t>(0, -settled.value0[i]);
                row.receipt_pending = row.count > 0 ? 2 : 3;
                break;
            case kEconomyOpRemoveStock:
            case kEconomyOpMarketGoodToCountry:
                row.count = std::max<int64_t>(0, settled.value0[i]);
                row.receipt_pending = row.count > 0 ? 2 : 3;
                break;
            case kEconomyOpChangeSignature:
                // Applied heads arrive with the structural commit below.
                row.settled_value = 0;
                break;
            default:
                row.receipt_pending = 2;
                break;
            }
            break;
        }
    }
    // 2. Structural moves for CHANGE_SIGNATURE rows.
    //
    // A CHANGE_SIGNATURE command is queued by the ledger stage and only moves
    // people in the later STRUCTURAL_COMMIT stage, so its settlement event and
    // the structural row can fall into different batches that a single day's
    // poll window does not join (busy worker boundary, evicted batch). The
    // structural row alone is unambiguous: it carries the source cohort handle,
    // the target signature, the destination cell and the moved head count, and
    // the evidence cursor keeps it visible until the row is resolved. Rows are
    // therefore matched on those four fields; `settled_epoch` is recorded for
    // bookkeeping only and is no longer a matching precondition.
    for (int64_t i = 0; i < structural.count; ++i) {
        const int64_t handle = structural.subject_id[i];
        const int32_t signature = structural.subject_i0[i];
        const int64_t epoch = structural.epoch_id[i];
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 2 || row.receipt_pending != 1) continue;
            if (row.opcode != kEconomyOpChangeSignature) continue;
            if (row.target_handle != handle || row.target_signature != signature) continue;
            if (structural.subject_i1[i] != row.cell) continue;
            // One structural event per queued command, in sequence order.
            row.settled_epoch = std::max<int64_t>(1, epoch);
            row.settled_value = std::max<int64_t>(0, structural.value0[i]);
            row.count = row.settled_value;
            row.receipt_pending = row.count > 0 ? 2 : 3;
            break;
        }
    }
    // 3. Epoch boundaries. A committed event batch is atomic (settlement,
    // structural and EPOCH_COMMITTED events of one epoch publish together), so
    // once an epoch's EPOCH_COMMITTED (subject_id = epoch id) is visible:
    //   * a CHANGE_SIGNATURE row already settled, whose epoch is committed and
    //     that never got a structural move, applied nothing (profession
    //     unavailable / source drained) -> failed (the core refunds the heads);
    //   * a row due by that epoch's sample day that never settled was rejected
    //     at epoch open (stale handle / invalid target) -> failed.
    // Everything waits for `_military_economy_seen_day >= effective_day`, so a
    // row of a later day is never closed by an earlier epoch.
    int64_t max_epoch_seen = 0;
    for (int64_t i = 0; i < epochs.count; ++i) {
        _military_economy_seen_day = std::max<int64_t>(
            _military_economy_seen_day, epochs.sample_day[i]);
        max_epoch_seen = std::max(max_epoch_seen, epochs.subject_id[i]);
    }
    for (MilitaryPendingIntent &row : _military_pending_intents) {
        if (row.authority != 2 || row.receipt_pending != 1) continue;
        if (_military_economy_seen_day < row.effective_day) continue;
        if (row.settled_epoch != 0) {
            if (row.opcode != kEconomyOpChangeSignature) continue;
            if (row.settled_epoch > max_epoch_seen) continue;
        }
        row.count = 0;
        row.receipt_pending = 3;
    }
    _military_economy_event_cursor = std::max<int64_t>(after,
        static_cast<int64_t>(report.get("newest_event_id", 0)));
}

} // namespace pk
