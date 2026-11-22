#include "native_simulation_host_military.h"
#include "native_simulation_host.h"
#include "country_api.h"
#include "economy_api.h"
#include "world_ext_internal_military_intents.h"
#include <algorithm>
#include <string>
#include <vector>

namespace pk {

using namespace godot;

// ===========================================================================
// intent submission (military D -> Country/Economy D+1 commands)
// ===========================================================================

bool NativeMilitaryRuntime::submit_military_country_commands(
        const std::vector<MilitaryCountryCommand> &commands,
        std::vector<MilitaryPendingIntent> &pending, std::string &error) {
    if (commands.empty()) return true;
    if (_country_runtime == nullptr) {
        error = "military_country_unavailable";
        return false;
    }
    const int64_t count = static_cast<int64_t>(commands.size());
    if (country_state != nullptr && _runtime_host != nullptr) {
        std::vector<RuntimeCommandPacket> packets;
        packets.reserve(commands.size());
        for (const auto &row : commands) {
            RuntimeCountryCommand command;
            command.request_id = _runtime_host->allocate_command_request_id_for_ingress();
            command.sequence = static_cast<uint64_t>(row.sequence);
            command.requested_day = row.effective_day;
            command.effective_day = row.effective_day;
            command.opcode = static_cast<uint16_t>(row.opcode);
            command.target_handle = row.target_handle;
            command.cell = row.cell;
            command.aux = row.aux;
            command.domain = row.domain;
            command.position = -1;
            command.tax_kind = -1;
            command.tax_item = -1;
            command.value = row.value;
            packets.push_back(encode_country_packet(command));
        }
        std::vector<uint64_t> ids;
        for (const auto &packet : packets) ids.push_back(packet.envelope.request_id);
        if (!_runtime_host->enqueue_batch(std::move(packets))) {
            error = "military_country_submit_rejected";
            return false;
        }
        if (!_military_receipts) _military_receipts = std::make_unique<MilitaryReceiptCursor>();
        for (size_t i = 0; i < commands.size(); ++i) {
            for (auto &row : pending) {
                if (row.authority == 1 && row.sequence == commands[i].sequence)
                    row.request_id = static_cast<int64_t>(ids[i]);
            }
            _military_receipts->after_request_id = std::max(
                _military_receipts->after_request_id, static_cast<int64_t>(ids[i]));
        }
        return true;
    }
    PackedInt32Array opcodes, cells, aux, domains, positions, w0, w1, w2, w3,
        tax_kinds, tax_items, tax_rates, tax_modes;
    PackedInt64Array days, sequences, targets, values;
    PackedStringArray stable_ids, names;
    opcodes.resize(count);
    cells.resize(count);
    aux.resize(count);
    domains.resize(count);
    positions.resize(count);
    w0.resize(count); w1.resize(count); w2.resize(count); w3.resize(count);
    tax_kinds.resize(count);
    tax_items.resize(count);
    tax_rates.resize(count);
    tax_modes.resize(count);
    days.resize(count);
    sequences.resize(count);
    targets.resize(count);
    values.resize(count);
    stable_ids.resize(count);
    names.resize(count);
    for (int64_t i = 0; i < count; ++i) {
        const MilitaryCountryCommand &c = commands[static_cast<size_t>(i)];
        opcodes[i] = c.opcode;
        cells[i] = c.cell;
        aux[i] = c.aux;
        domains[i] = c.domain;
        positions[i] = -1;
        w0[i] = 0; w1[i] = 0; w2[i] = 0; w3[i] = 0;
        tax_kinds[i] = -1;
        tax_items[i] = -1;
        tax_rates[i] = 0;
        tax_modes[i] = 0;
        days[i] = c.effective_day;
        sequences[i] = c.sequence;
        targets[i] = c.target_handle;
        values[i] = c.value;
        stable_ids[i] = String();
        names[i] = String();
    }
    Dictionary batch;
    batch["opcodes"] = opcodes;
    batch["effective_days"] = days;
    batch["sequences"] = sequences;
    batch["target_handles"] = targets;
    batch["cell_indices"] = cells;
    batch["aux_i32"] = aux;
    batch["domain_i32"] = domains;
    batch["position_i32"] = positions;
    batch["weight0_bp"] = w0;
    batch["weight1_bp"] = w1;
    batch["weight2_bp"] = w2;
    batch["weight3_bp"] = w3;
    batch["value_i64"] = values;
    batch["tax_kinds"] = tax_kinds;
    batch["tax_item_indices"] = tax_items;
    batch["tax_rate_basis_points"] = tax_rates;
    batch["tax_assessment_modes"] = tax_modes;
    batch["stable_ids"] = stable_ids;
    batch["display_names"] = names;
    if (!_military_receipts) _military_receipts = std::make_unique<MilitaryReceiptCursor>();
    const Dictionary submitted = country_api::submit_commands(*_country_runtime, batch);
    if (!static_cast<bool>(submitted.get("ok", false))) {
        error = String(submitted.get("code", submitted.get("reason",
            "military_country_submit_rejected"))).utf8().get_data();
        return false;
    }
    // Stamp request ids so the next day's receipt poll can match rows.
    if (submitted.has("request_ids") &&
        submitted["request_ids"].get_type() == Variant::PACKED_INT64_ARRAY) {
        const PackedInt64Array request_ids = submitted["request_ids"];
        for (int64_t i = 0; i < count && i < request_ids.size(); ++i) {
            for (MilitaryPendingIntent &row : pending) {
                if (row.authority != 1 || row.sequence != commands[static_cast<size_t>(i)].sequence)
                    continue;
                row.request_id = request_ids[i];
            }
            if (request_ids[i] > _military_receipts->after_request_id)
                _military_receipts->after_request_id = request_ids[i];
        }
    }
    return true;
}

#include "world_ext_military_economy_ingress.inc"

// ===========================================================================
// receipts (Country command terminals + Economy settlements ->
// MilitaryIntentReceipt). `_military_pending_intents` is a cross-day set:
// a row leaves it only when a receipt is emitted for it (terminal ok/fail or
// timeout), so ENLIST/LEVY always reach MilitaryCore::reconcile_receipts.
// ===========================================================================

namespace {
// A row whose authority never reported back is failed after this many days
// past its effective day (Economy epochs are daily; Country commits are D+1).
constexpr int64_t kMilitaryReceiptTimeoutDays = 8;
} // namespace

void NativeMilitaryRuntime::collect_military_receipts(int64_t day,
                                           std::vector<MilitaryIntentReceipt> &out) {
    out.clear();
    if (_military_pending_intents.empty()) return;
    // Economy rows (authority 2) settle through Economy trace events.
    collect_military_economy_receipts(day, out);
    if (_runtime_host == nullptr) {
        // Without a worker the sync country facade commits on its own day; there
        // is no per-command receipt, so an intent is assumed committed once its
        // effective day has been reached by the country runtime.
        int64_t committed_day = -1;
        if (_country_runtime != nullptr)
            committed_day = country_api::last_committed_day(
                *static_cast<NativeCountryRuntime *>(_country_runtime));
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 1 || row.receipt_pending != 1 ||
                row.effective_day > committed_day) continue;
            row.receipt_pending = 2;
        }
    } else {
        // Worker authority: fold every terminal receipt after the cursor.
        if (!_military_receipts) _military_receipts = std::make_unique<MilitaryReceiptCursor>();
        MilitaryReceiptCursor &cursor = *_military_receipts;
        std::vector<CountryCommandReceipt> receipts;
        _runtime_host->poll_country_command_receipts(
            static_cast<uint64_t>(std::max<int64_t>(0, cursor.after_request_id)), 512, receipts);
        for (const CountryCommandReceipt &receipt : receipts) {
            cursor.after_request_id = std::max<int64_t>(cursor.after_request_id,
                static_cast<int64_t>(receipt.request_id));
            const bool terminal =
                receipt.code == CountryCommandReceiptCode::COMMITTED ||
                receipt.code == CountryCommandReceiptCode::REJECTED_AT_EXECUTION;
            if (!terminal) continue;
            const bool ok = receipt.code == CountryCommandReceiptCode::COMMITTED;
            for (MilitaryPendingIntent &row : _military_pending_intents) {
                if (row.authority != 1 || row.receipt_pending != 1 ||
                    row.request_id != static_cast<int64_t>(receipt.request_id))
                    continue;
                row.receipt_pending = ok ? 2 : 3;
                break;
            }
        }
        // The cursor can skip a terminal that landed before the stamp; look the
        // still-open rows up directly.
        for (MilitaryPendingIntent &row : _military_pending_intents) {
            if (row.authority != 1 || row.receipt_pending != 1 || row.request_id <= 0) continue;
            CountryCommandReceipt receipt;
            if (!_runtime_host->try_country_command_terminal(
                    static_cast<uint64_t>(row.request_id), receipt))
                continue;
            if (receipt.code == CountryCommandReceiptCode::COMMITTED)
                row.receipt_pending = 2;
            else if (receipt.code == CountryCommandReceiptCode::REJECTED_AT_EXECUTION)
                row.receipt_pending = 3;
        }
    }
    // Emit resolved rows (in pending/sequence order), time out stale ones, and
    // compact the set.
    size_t write = 0;
    for (size_t i = 0; i < _military_pending_intents.size(); ++i) {
        MilitaryPendingIntent row = _military_pending_intents[i];
        // Authority 4 rows used to be excluded from the timeout, which meant a
        // lost purchase receipt kept the row (and the core's in-flight order)
        // open forever: a good could never be re-ordered for that holder and
        // the day never looked idle again. A paid purchase is still bounded by
        // the same window; the core settles it as an unmet fill and releases
        // the order.
        if (row.receipt_pending == 1 &&
            day > row.effective_day + kMilitaryReceiptTimeoutDays)
            row.receipt_pending = 3;
        if (row.receipt_pending == 2) {
            auto receipt = military_receipt_from(row, true, row.count, row.amount);
            receipt.request_sequence = row.sequence;
            out.push_back(receipt);
            continue;
        }
        if (row.receipt_pending == 3 || row.receipt_pending == 0) {
            auto receipt = military_receipt_from(row, false, 0, 0);
            receipt.request_sequence = row.sequence;
            out.push_back(receipt);
            continue;
        }
        _military_pending_intents[write++] = row;
    }
    _military_pending_intents.resize(write);
}

void NativeMilitaryRuntime::apply_military_deferred_cash(int64_t day) {
    // SPEND_CASH rows settle on military day D+1. The compatibility helper's
    // reserve/collect pair debits then credits the same treasury. Its receipt
    // is not a terminal cash sink and must not register an Economy burn.
    if (_military_pending_intents.empty()) return;
    NativeEconomyRuntime *economy = _economy_runtime == nullptr ? nullptr
        : static_cast<NativeEconomyRuntime *>(_economy_runtime);
    for (MilitaryPendingIntent &row : _military_pending_intents) {
        if (row.authority != 3 || row.receipt_pending != 1) continue;
        if (row.effective_day > day) continue;
        if (economy == nullptr || !economy_api::military_command_window_open(*economy)) {
            // Retry next day; the timeout fails the row eventually.
            continue;
        }
        const int64_t collected = economy_api::military_collect_cash(*economy,
            static_cast<int64_t>(row.country_handle), row.amount);
        row.amount = collected;
        row.count = collected > 0 ? 1 : 0;
        row.receipt_pending = collected > 0 ? 2 : 3;
    }
}

MilitaryIntentReceipt NativeMilitaryRuntime::military_receipt_from(
        const MilitaryPendingIntent &row, bool ok, int64_t committed_count,
        int64_t committed_amount) {
    MilitaryIntentReceipt receipt;
    receipt.kind = row.kind;
    receipt.ok = ok ? 1 : 0;
    receipt.cell = row.cell;
    receipt.source_id = row.source_id;
    receipt.committed_count = ok ? committed_count : 0;
    receipt.committed_amount = ok ? committed_amount : 0;
    return receipt;
}


} // namespace pk
