#include "world_ext.h"

#include "economy_api.h"
#include "military_bridge.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <utility>
#include <vector>

namespace pk {

using namespace godot;

namespace {
NativeEconomyRuntime *economy_runtime_from(void *opaque) {
    return static_cast<NativeEconomyRuntime *>(opaque);
}

// EventKind / Opcode values come from the public Economy contract.
// Local names keep the receipt matching code unchanged.
constexpr int32_t kEconomyEventCommandSettled = EconomyApi::EVENT_COMMAND_SETTLED;
constexpr int32_t kEconomyEventStructuralChange = EconomyApi::EVENT_STRUCTURAL_CHANGE;
constexpr int32_t kEconomyEventEpochCommitted = EconomyApi::EVENT_EPOCH_COMMITTED;
constexpr int32_t kEconomyOpTransferToCohort = EconomyApi::COMMAND_TRANSFER_TO_COHORT;
constexpr int32_t kEconomyOpRemoveStock = EconomyApi::COMMAND_REMOVE_STOCK;
constexpr int32_t kEconomyOpAddPopulation = EconomyApi::COMMAND_ADD_POPULATION;
constexpr int32_t kEconomyOpChangeSignature = EconomyApi::COMMAND_CHANGE_SIGNATURE;
constexpr int32_t kEconomyOpConvertCohort = EconomyApi::COMMAND_MILITARY_CONVERT_COHORT;   // B: in-cell signature move
constexpr int32_t kEconomyOpMarketGoodToCountry = EconomyApi::COMMAND_MARKET_GOOD_TO_COUNTRY;
constexpr int32_t kEconomyOpArmyEmbark = EconomyApi::COMMAND_ARMY_EMBARK;      // cell cohort -> army lane
constexpr int32_t kEconomyOpArmyDisembark = EconomyApi::COMMAND_ARMY_DISEMBARK;   // army lane -> cell cohort
constexpr int32_t kEconomyOpArmyMergeLanes = EconomyApi::COMMAND_ARMY_MERGE_LANES;  // src lane -> dst lane
constexpr int32_t kEconomyOpArmyLanePay = EconomyApi::COMMAND_ARMY_LANE_PAY;     // treasury -> army lane wages

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
// Declared in world_ext_military.cpp; this build has all three lane methods.
// Null Economy still answers false / -1; non-null calls use the public API.
bool economy_army_lane_supported(const void *economy) {
    if (economy == nullptr) return false;
    return true;
}

int64_t economy_army_lane_population(void *economy, uint64_t army_handle) {
    if (economy == nullptr) return -1;
    return economy_api::military_army_population(*economy_runtime_from(economy), army_handle);
}

int64_t economy_army_lane_funds(void *economy, uint64_t army_handle) {
    if (economy == nullptr) return -1;
    return economy_api::military_army_funds(*economy_runtime_from(economy), army_handle);
}

bool economy_set_army_ration(void *economy, uint64_t army_handle, int32_t q16) {
    if (economy == nullptr) return false;
    economy_api::set_military_army_ration(*economy_runtime_from(economy), army_handle, q16); return true;
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
    const int32_t written = economy_api::set_military_ration_satisfaction(
        *economy_runtime_from(_economy_runtime), cell_indices, values);
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
        if ((row.authority == 2 || row.authority == 4) && row.receipt_pending == 1) {
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
        if (!boundary.owns_lock() || economy_api::epoch_active(*economy)) return;
    }
    for (auto &row : _military_pending_intents) {
        if (row.authority != 4 || row.receipt_pending != 1) continue;
        int64_t quantity = 0, cash = 0;
        if (!economy_api::military_purchase_receipt(*economy, row.sequence, quantity, cash)) continue;
        row.count = quantity; row.amount = cash;
        row.receipt_pending = 2; // A zero-fill terminal is still acknowledged.
    }
    const Dictionary report = economy_api::trace_report(*economy);
    if (String(report.get("mode", "SELECTIVE")) == String("OFF")) {
        const int64_t committed = economy_api::last_committed_day(*economy);
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
        const int64_t committed = economy_api::last_committed_day(*economy);
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 2 || row.receipt_pending != 1) continue;
            if (row.request_id != 0) continue;
            if (row.effective_day > committed) continue;
            // Do not assume the move happened: read the committed cohort back.
            // Military books only what Economy actually holds at the cell.
            int64_t applied = 0;
            if (row.opcode == kEconomyOpChangeSignature ||
                row.opcode == kEconomyOpConvertCohort) {
                applied = economy_api::military_soldier_heads(*economy, row.cell);
            } else if (row.opcode == kEconomyOpArmyEmbark) {
                // Army personnel lane: the row names the formation
                // (target_cohort = army handle), so the truth is the lane itself.
                // An unsupported economy answers -1: fall back to the requested
                // heads only then, because in that case no lane exists at all and
                // Military stays on the pre-lane accounting.
                const int64_t lane = economy_army_lane_population(
                    economy, static_cast<uint64_t>(row.target_handle));
                if (lane >= 0 && lane == 0) {
                    // A zero lane is not evidence that nothing moved. The row is
                    // drained at a committed day boundary, but its structural
                    // move can still be a day out (and the queue is drained after
                    // the epoch's publish), so settling here would book a real
                    // embarkation as failed and report personnel = 0 for a
                    // formation that is already carrying the heads. Keep the row
                    // open; the receipt timeout fails it if no lane ever appears.
                    continue;
                }
                applied = lane >= 0 ? lane : row.count;
            } else if (row.opcode == kEconomyOpArmyDisembark ||
                       row.opcode == kEconomyOpArmyMergeLanes) {
                // Both remove heads from the named lane, so a lane readback says
                // nothing about how many actually moved; the batch applied
                // atomically, so the requested count is what landed.
                applied = row.count;
            } else if (row.opcode == kEconomyOpArmyLanePay) {
                // Army pay (army-pay contract §3.2): `row.count` carries the
                // lane's cash BEFORE the payment, so the amount that actually
                // landed is the growth since then, clamped to what was asked
                // for. The treasury can only fund part of a payroll (opcode 34
                // collects what the country actually has), and the lane also
                // spends on guest consumption in the same epoch, so a naive
                // requested == applied would over-report: a lane that started
                // at 100, was paid 500 and spent 300 back to 300 must book 200.
                // The read is final: the POD row is applied atomically inside
                // the epoch that drains it, and this loop only runs once that
                // epoch's committed day has been reached, so the balance here is
                // the post-payment one. Settling now also keeps `row.count` from
                // being reinterpreted as a base by a later poll.
                const int64_t funds = economy_army_lane_funds(
                    economy, static_cast<uint64_t>(row.target_handle));
                const int64_t requested = std::max<int64_t>(0, row.amount);
                if (funds < 0) {
                    // Economy has no funds readout at all: no payment path
                    // exists, so the row is a failure rather than a guess.
                    row.count = 0;
                    row.settled_value = 0;
                    row.receipt_pending = 3;
                    continue;
                }
                const int64_t base = std::max<int64_t>(0, row.count);
                applied = std::clamp<int64_t>(std::max<int64_t>(0, funds - base), 0,
                                              requested);
                row.count = applied;
                row.amount = applied;
                row.settled_value = applied;
                row.receipt_pending = applied > 0 ? 2 : 3;
                continue;
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
        return read_page(economy_api::poll_events(*economy, opts));
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
