#include "modifier_runtime.h"

#include <algorithm>
#include <cmath>

namespace pk {

double ModifierRuntime::effective_value(int32_t domain, int32_t sid,
                                        uint64_t entity_handle,
                                        uint64_t group_handle,
                                        double base_value) const {
    return effective_value_with_front(domain, sid, entity_handle, group_handle,
                                      base_value, &_derived_cell_front);
}

double ModifierRuntime::effective_value_with_front(int32_t domain, int32_t sid,
        uint64_t entity_handle, uint64_t group_handle, double base_value,
        const DerivedCellFront *front) const {
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT || sid < 0 ||
        sid >= static_cast<int32_t>(_stats.size()) || _stats[sid].domain != domain ||
        !std::isfinite(base_value)) return base_value;
    const Store &store = _stores[domain];
    ++store.query_count;
    double add = 0.0;
    double factor = 1.0;
    const BucketKey keys[3] = {{sid, GLOBAL, 0}, {sid, GROUP, group_handle},
                               {sid, ENTITY, entity_handle}};
    for (int i = 0; i < 3; ++i) {
        if (i == 1 && group_handle == 0 && domain != ECONOMY) continue;
        const auto it = store.buckets.find(keys[i]);
        if (it == store.buckets.end()) continue;
        ++store.bucket_reads;
        add += it->second.sum_add;
        factor *= bucket_factor(it->second);
    }
    // ── Derived cell layer merge (plan 22 §5.1) ────────────────────────────
    //
    // The derived contribution joins the SAME sum/product as every other
    // contribution, BEFORE the final clamp. §5.1 rejects the alternative
    // (`clamp((legacy_effective + derived_add) * derived_factor)`) because the
    // legacy value already multiplied its own factors and may already have been
    // clamped, so no arithmetic can recover the correct combination.
    //
    // Which handle carries the cell: every shipped reader passes the settlement
    // cell as `group_handle` with `entity_handle == 0`
    // (`economy_runtime.cpp:7082-7083`, `modifier_runtime.cpp:1785-1786`). So a
    // derived row is looked up by `group_handle` -- never by `entity_handle`,
    // which is the building/entity identity and would silently never match.
    //
    // Fast bypass: `_derived_cell_front.rows.empty()` is the common case (no
    // card equipped, or the migration off), and it keeps every existing reader
    // bit-identical to the pre-layer behaviour.
    // `group_handle != 0` used to guard this, and that was a REAL BUG: the group
    // handle is the CELL (`:1434-1438` above says so), and cell 0 is a legitimate
    // cell. Measured on a 1600-cell country with a card equipped:
    //
    //   cell 0: derived row present, derived_add 0.05, effective value 1.0
    //   cell 1: derived row present, derived_add 0.05, effective value 1.05
    //
    // So every card silently did nothing on its country's first cell.
    //
    // Why removing the guard is safe:
    //   * every ECONOMY-domain caller passes `entity 0, group = cell`
    //     (`economy_runtime.cpp:4391,4394`, `economy_runtime_family_buff.cpp:7127`),
    //     so group 0 means cell 0, not "no group";
    //   * every COUNTRY-domain caller passes `group 0` meaning "no group"
    //     (`country_runtime.cpp:2433`, `economy_runtime.cpp:5621,5631,...`), and this
    //     branch is gated on `domain == ECONOMY`, so they never reach it;
    //   * `effective_values` (the bulk reader, `:1480`) hardcodes group 0, but all
    //     three of its callers use the COUNTRY domain (`economy_runtime.cpp:5579,
    //     5932,5982`), so it is unaffected too.
    if (domain == ECONOMY && front != nullptr && !front->rows.empty()) {
        const DerivedCellStatRow *row = front->row_for_stat(sid);
        if (row != nullptr) {
            const DerivedCellContribution *slot =
                row->find(static_cast<int32_t>(group_handle));
            if (slot != nullptr) {
                add += slot->sum_add;
                // Plan §5.5: a zero factor must annihilate the product, exactly
                // like `bucket_factor`. Multiplying by `product_nonzero` alone
                // would silently ignore a "-100%" card.
                if (slot->zero_factor_count > 0) {
                    factor = 0.0;
                } else {
                    factor *= slot->product_nonzero;
                }
            }
        }
    }
    double value = (base_value + add) * factor;
    if (!std::isfinite(value)) value = value < 0.0 ? _stats[sid].min_value : _stats[sid].max_value;
    return std::clamp(value, _stats[sid].min_value, _stats[sid].max_value);
}

double ModifierRuntime::effective_value(int32_t domain, const char *key,
                                        uint64_t entity_handle,
                                        uint64_t group_handle,
                                        double base_value) const {
    return effective_value(domain, stat_id(key), entity_handle, group_handle, base_value);
}

void ModifierRuntime::restore_derived_cell_layer(DerivedCellFront front) {
    _derived_layer_generation = front.generation;
    _derived_cell_front = std::move(front);
}

void ModifierRuntime::copy_derived_cell_layer_from(const ModifierRuntime &source) {
    const auto &front = source._derived_cell_front;
    if (_derived_cell_front.generation == front.generation &&
        _derived_cell_front.world_identity == front.world_identity &&
        _derived_cell_front.map_generation == front.map_generation) return;
    // Copy an empty front as well: removing the last contribution must reach
    // the consumer with the same generation as an ordinary replacement.
    _derived_cell_front = front;
    _derived_layer_generation = source._derived_layer_generation;
}

void ModifierRuntime::reset_runtime_state(int32_t cell_count) {
    _cell_count = cell_count;
    _current_day = -1;
    _pod_snapshot_generation = 0;
    _pending_commands.clear();
    _results.clear();
    _events.clear();
    _next_request_id = 1;
    _next_event_id = 1;
    _submit_order = 0;
    _journal_overflow = 0;
    _commands_applied = 0;
    _commands_rejected = 0;
    _expired = 0;
    _last_command_ms = 0.0;
    _last_expiry_ms = 0.0;
    _last_publish_ms = 0.0;
    _last_bucket_update_ms = 0.0;
    _last_bucket_rebuild_ms = 0.0;
    _bucket_update_ms_total = 0.0;
    _bucket_rebuild_ms_total = 0.0;
    _error_counts.clear();
    _derived_cell_front = DerivedCellFront{};
    _derived_layer_generation = 0;
    _derived_layer_installs = 0;
    _derived_layer_install_skips = 0;
    _derived_layer_int8_bytes = 0.0;
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) clear_domain(domain);
    _gameplay_base_by_stat.assign(_stats.size(), {});
}

} // namespace pk
