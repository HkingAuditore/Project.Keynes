#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "economy_hash.h"
#include "economy_runtime_persistence_codec.h"
#include "economy_runtime_owned_state_codec.h"
#include "economy_runtime_publication_codec.h"
#include "economy_authority_transfer.h"
#include "effect_runtime.h"
#include "modifier_api.h"
#include "runtime_economy_ecp2.h"
#include "pk_log.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <unordered_map>
#include <unordered_set>

namespace pk {

using namespace godot;
using namespace persistence_codec;

#include "economy_runtime_persistence_section_save_capture.inc"

Dictionary NativeEconomyRuntime::begin_restore() {
    Dictionary out;
    if (!_configured || _epoch_active || _save.active || _restore.active ||
        _fiscal_reservation_continuation.active ||
        _epoch_begin_post_fiscal_pending ||
        _fiscal_settlement_continuation.active ||
        _country_research_procurement_continuation.active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "configure_catalog_before_restore"
                         : (_fiscal_reservation_continuation.active ||
                            _epoch_begin_post_fiscal_pending
                             ? "restore_fiscal_reservation_pending"
                         : (_fiscal_settlement_continuation.active
                             ? "restore_fiscal_settlement_pending"
                         : (_country_research_procurement_continuation.active
                             ? "restore_research_procurement_pending"
                         : (_epoch_active ? "restore_requires_committed_boundary"
                             : "save_restore_already_active"))));
        if (_fiscal_reservation_continuation.active ||
            _epoch_begin_post_fiscal_pending) {
            out["country_cursor"] =
                _fiscal_reservation_continuation.country_cursor;
            out["country_count"] =
                _fiscal_reservation_continuation.country_count;
            out["day"] = _fiscal_reservation_continuation.day_index;
            out["phase"] = _fiscal_reservation_continuation.phase;
            out["epoch_begin_pending"] = _epoch_begin_post_fiscal_pending;
        } else if (_fiscal_settlement_continuation.active) {
            out["country_cursor"] =
                _fiscal_settlement_continuation.country_cursor;
            out["country_count"] =
                _fiscal_settlement_continuation.country_count;
            out["phase"] = _fiscal_settlement_continuation.phase;
            out["last_unused"] =
                _fiscal_settlement_continuation.last_unused;
            out["last_collected"] =
                _fiscal_settlement_continuation.last_collected;
        }
        set_restore_rejected_reason(
            String(out["reason"]).utf8().get_data());
        return out;
    }
    // The public chunked restore API is itself an ECP2 transaction boundary.
    // Prepare the candidate surface here so callers using the documented
    // begin -> feed -> end sequence do not need the internal migrate helper.
    // The caller's live state remains recoverable through the restore backup
    // established by begin_restore_internal().
    _restore = {};
    _restore.active = true;
    _restore.scratch_prepared = false;
    prepare_restore_candidate_scratch();
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["scratch_prepared"] = true;
    out["requires_ecp2"] = true;
    return out;
}


void NativeEconomyRuntime::set_restore_rejected_reason(
        const std::string &reason) {
    _restore_rejected_reason = reason;
}

Dictionary NativeEconomyRuntime::feed_restore_chunk(const PackedByteArray &chunk) {
    Dictionary out;
    if (!_restore.active || _restore.failed || _restore.end_seen || chunk.is_empty()) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                                            : (_restore.end_seen ? "restore_end_already_seen"
                                                                 : "restore_chunk_empty"));
        set_restore_rejected_reason(
            String(out["reason"]).utf8().get_data());
        return out;
    }
    if (!_restore.scratch_prepared) {
        out["ok"] = false;
        out["reason"] = "restore_scratch_not_prepared";
        set_restore_rejected_reason("restore_scratch_not_prepared");
        return out;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(chunk.size()));
    std::memcpy(bytes.data(), chunk.ptr(), bytes.size());
    std::string error;
    if (!decode_restore_chunk(bytes, error)) {
        _restore.failed = true;
        _restore.error = error;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        set_restore_rejected_reason(error);
        return out;
    }
    out["ok"] = true;
    out["header_seen"] = _restore.header_seen;
    out["end_seen"] = _restore.end_seen;
    out["restored_pages"] = _restore.restored_pages;
    out["restored_markets"] = _restore.restored_markets;
    out["restored_cells"] = _restore.restored_cells;
    out["restored_commands"] = _restore.restored_commands;
    out["restored_audits"] = _restore.restored_audits;
    out["restored_signals"] = _restore.restored_signals;
    out["restored_labor_signals"] = _restore.restored_labor_signals;
    out["restored_trade_orders"] = _restore.restored_trade_orders;
    out["restored_trade_flows"] = _restore.restored_trade_flows;
    out["restored_persons"] = _restore.restored_persons;
    out["restored_person_needs"] = _restore.restored_person_needs;
    return out;
}

Dictionary NativeEconomyRuntime::end_restore() {
#include "economy_runtime_persistence_section_restore_validation.inc"
#include "economy_runtime_persistence_section_restore_inventory.inc"
#include "economy_runtime_persistence_section_restore_peers_and_publish.inc"
}

bool NativeEconomyRuntime::begin_restore_internal(std::string &error) {
    error.clear();
    const Dictionary out = begin_restore();
    if (!static_cast<bool>(out.get("ok", false))) {
        error = String(out.get("reason", "restore_begin_failed")).utf8().get_data();
        set_restore_rejected_reason(error);
        return false;
    }
    return true;
}
bool NativeEconomyRuntime::end_restore_internal(std::string &error) {
    error.clear();
    const Dictionary out = end_restore();
    if (!static_cast<bool>(out.get("ok", false))) {
        error = String(out.get("reason", "restore_end_failed")).utf8().get_data();
        set_restore_rejected_reason(error);
        return false;
    }
    return true;
}

// The deferred half of the country-identity check (see `_accept_stale_country_identity`).
//
// `apply_ecp2_authority` skips `country_hash != expected_country_hash` when Country has
// not been installed yet, and records what the archive ASKED for. This compares that
// record against the live Country runtime, which by now holds the archive's real
// checkpoint. Pairing A's Country bytes with B's Economy bytes therefore still fails --
// the important half of "restore is atomic" is not lost, only moved.
bool NativeEconomyRuntime::verify_deferred_country_identity(
        std::string &error) const {
    error.clear();
    if (!_deferred_country_identity_recorded) return true;
    if (_country_runtime == nullptr) {
        error = "economy_deferred_country_runtime_missing";
        return false;
    }
    const uint64_t live_generation =
        static_cast<uint64_t>(country_reads().generation());
    const uint64_t live_hash = static_cast<uint64_t>(country_reads().state_hash());
    if (live_generation != _deferred_country_generation ||
        live_hash != _deferred_country_state_hash) {
        // Name both sides: a mismatch without the two identities is unactionable, and
        // this failure is exactly the one that used to be invisible.
        char detail[128];
        std::snprintf(detail, sizeof(detail),
                      "economy_country_identity_mismatch:expected_gen=%llu_"
                      "hash=%llu:live_gen=%llu_hash=%llu",
                      static_cast<unsigned long long>(_deferred_country_generation),
                      static_cast<unsigned long long>(_deferred_country_state_hash),
                      static_cast<unsigned long long>(live_generation),
                      static_cast<unsigned long long>(live_hash));
        error = detail;
        return false;
    }
    return true;
}

#include "economy_runtime_persistence_section_ecp2_authority.inc"
} // namespace pk
