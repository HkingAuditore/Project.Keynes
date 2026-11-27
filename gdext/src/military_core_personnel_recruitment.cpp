#include "military_core.h"
#include "military_core_personnel_internal.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>
#include <utility>

namespace pk {
using namespace mil;

namespace {
constexpr int64_t kRecruitCheckPeriod = 5;
constexpr int32_t kMinCellPopulationAfterLevy = 5;
constexpr int64_t kPayRatioDesertThreshold = 32768;

struct QuotaCell {
    int32_t cell = -1;
    int64_t open = 0;
    int64_t share = 0;
};

} // namespace

void MilitaryCore::run_recruitment(const MilitaryWorldDigest &digest, std::vector<MilitaryIntent> &out) {
    const bool sampling = (_last_day >= 0) && (_last_day % kRecruitCheckPeriod) == 0;
    if (!sampling) return;
    const int32_t cells = _terrain.cell_count;
    // `pending_enlist` is counted from the moment an ENLIST/LEVY intent is emitted
    // until its receipt arrives. A row can leave the bridge without a successful
    // receipt (timeout, refused submit), and the receipt for a partially applied
    // row never carries the shortfall, so a counter that is only decremented by
    // `committed_count` would keep a cell's posts occupied forever. The pending
    // total therefore lives only inside one receipt window: the outbound count of
    // the previous sample is replaced by the difference the receipts actually
    // applied (reconcile_receipts tracked it in `_report.reconcile_delta`).
    int64_t pending_applied = _report.reconcile_delta;
    for (MilitaryCellState &st : _cell_states) {
        if (st.pending_enlist <= 0) continue;
        if (pending_applied <= 0) {
            st.pending_enlist = 0;
            continue;
        }
        const int64_t keep = std::min(st.pending_enlist, pending_applied);
        st.pending_enlist -= keep;
        pending_applied -= keep;
    }
    static thread_local std::vector<QuotaCell> quota_rows;
    for (size_t slot = 0; slot < _policies.size(); ++slot) {
        MilitaryCountryPolicy &p = _policies[slot];
        const int32_t s = (int32_t)slot;
        const uint64_t handle = _policy_handle[slot];
        if (handle == 0) continue;
        quota_rows.clear();
        int64_t open_sum = 0;
        // Only cells with a state row can hold posts; _cell_states is sorted by
        // cell, so this visits the same cells in the same order as a full scan.
        for (size_t sti = 0; sti < _cell_states.size(); ++sti) {
            MilitaryCellState *st = &_cell_states[sti];
            const int32_t cell = st->cell;
            if (cell < 0 || cell >= cells) continue;
            if ((size_t)cell >= digest.cell_owner_slot.size()) break;
            if (digest.cell_owner_slot[(size_t)cell] != s) continue;
            const int32_t ctrl = controller_of(cell);
            if (ctrl >= 0 && ctrl != s) continue;
            if (st->paused) continue;
            const int64_t posts = posts_for_cell(cell, s);
            if (posts <= 0) continue;
            const int64_t open = std::max<int64_t>(0, posts - present_for_cell(cell) - st->pending_enlist);
            if (open <= 0) continue;
            QuotaCell q;
            q.cell = cell;
            q.open = open;
            quota_rows.push_back(q);
            open_sum += open;
        }
        // `plan` ignores the cell-level `pending_enlist` (already replaced by what
        // the receipts applied); `open` above keeps it so a cell never overshoots
        // its posts while a row is still in flight.
        const int64_t deficit = p.effective_target - country_soldiers(s);
        int64_t plan = 0;
        if (deficit > 0) {
            plan = std::min(deficit, open_sum);
            int64_t assigned = 0;
            for (QuotaCell &q : quota_rows) {
                q.share = mul_div(plan, q.open, open_sum);
                assigned += q.share;
            }
            int64_t rest = plan - assigned;
            for (size_t i = 0; i < quota_rows.size() && rest > 0; ++i) {
                if (quota_rows[i].share < quota_rows[i].open) {
                    quota_rows[i].share += 1;
                    --rest;
                }
            }
        }
        // Re-freeze the per-cell quota for this sample period.
        for (QuotaCell &q : quota_rows) {
            MilitaryCellState *st = cell_state(q.cell, true);
            if (st) st->quota = std::min(q.open, q.share);
        }
        // No early `continue` here: an over-target country still has to reach
        // the auto-discharge / desertion block below (it used to be skipped
        // whenever there was no open post or nothing to recruit).
        const int64_t levy_cap_bp = clamp32(stat_bp(digest, s, MSTAT_LEVY_RATE), 0, 10000);
        for (const QuotaCell &q : quota_rows) {
            if (plan <= 0) break;
            const int64_t quota = plan <= 0 ? 0 : q.share;
            if (quota <= 0) continue;
            MilitaryCellState *st = cell_state(q.cell, true);
            if (!st) continue;
            const int64_t pop = digest.cell_population[(size_t)q.cell];
            const int64_t unemployed = digest.cell_unemployed[(size_t)q.cell];
            const int64_t room = std::max<int64_t>(0, pop - kMinCellPopulationAfterLevy);
            const int64_t volunteers = std::min({quota, std::max<int64_t>(0, unemployed), room});
            if (volunteers > 0) {
                MilitaryIntent in;
                in.kind = MILITARY_INTENT_ENLIST;
                in.cell = q.cell;
                in.country_a = handle;
                in.count = volunteers;
                // Pre-apply the roster exactly like DISCHARGE does and pack the
                // request into source_id: booking only on the receipt left the
                // roster a day behind, so the quota kept recruiting past the
                // posts (economy 16 soldiers against 12 posts).
                in.source_id = military_discharge_source(q.cell, s, volunteers);
                out.push_back(in);
                st->pending_enlist += volunteers;
                const int32_t lot = lot_find_or_create(
                    (uint8_t)MILITARY_LOT_GARRISON, q.cell, s,
                    (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0), 256);
                if (lot >= 0) _lots.count[(size_t)lot] += volunteers;
            }
            // Design 5.4: when the unemployed pool cannot fill the quota the levy
            // draws from the cell's non-merchant, non-owner employee cohorts. The
            // bridge translates that as a CHANGE_SIGNATURE from any non-merchant
            // profession cohort of the cell, so the levy is bounded only by the
            // people that may leave, never by `unemployed`.
            const int64_t missing = quota - volunteers;
            if (missing > 0 && p.levy_enabled) {
                const int64_t levy_cap = std::max<int64_t>(1, mul_div(pop, levy_cap_bp, 10000));
                const int64_t levy = std::min({missing, levy_cap, std::max<int64_t>(0, room - volunteers)});
                if (levy > 0) {
                    MilitaryIntent in;
                    in.kind = MILITARY_INTENT_LEVY;
                    in.cell = q.cell;
                    in.country_a = handle;
                    in.count = levy;
                    in.source_id = military_discharge_source(q.cell, s, levy);
                    out.push_back(in);
                    st->pending_enlist += levy;
                    const int32_t lot = lot_find_or_create(
                        (uint8_t)MILITARY_LOT_GARRISON, q.cell, s,
                        (int16_t)(_catalog.militia_unit >= 0 ? _catalog.militia_unit : 0), 256);
                    if (lot >= 0) _lots.count[(size_t)lot] += levy;
                    MilitaryEvent ev;
                    ev.day = _last_day;
                    ev.type = MILITARY_EVENT_LEVY_APPLIED;
                    ev.cell = q.cell;
                    ev.i0 = (uint64_t)s;
                    ev.i1 = handle;
                    ev.value = levy;
                    push_event(ev);
                }
            }
        }

        // ---- auto discharge (5.5) and desertion, same sample day.
        const int64_t target = p.effective_target;
        const int64_t pay = p.pay_ratio_30_q16;
        int64_t over = country_soldiers(s) - target;
        const bool discharge = over > 0 && p.auto_discharge;
        const bool desert = pay < kPayRatioDesertThreshold;
        if (!discharge && !desert) continue;
        static thread_local std::vector<int32_t> cells_with_soldiers;
        cells_with_soldiers.clear();
        for (size_t i = 0; i < _lots.active.size(); ++i) {
            if (!_lots.active[i]) continue;
            if (_lots.country_slot[i] != s) continue;
            if (_lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
            cells_with_soldiers.push_back(_lots.location[i]);
        }
        std::sort(cells_with_soldiers.begin(), cells_with_soldiers.end());
        cells_with_soldiers.erase(std::unique(cells_with_soldiers.begin(), cells_with_soldiers.end()),
                                  cells_with_soldiers.end());
        // DISCHARGE pre-applies to the lots; the receipt reconciles a shortfall
        // (reconcile_receipts), so source_id carries cell, slot and request.
        auto emit_discharge = [&](int32_t cell, int64_t done) {
            MilitaryIntent in;
            in.kind = MILITARY_INTENT_DISCHARGE;
            in.cell = cell;
            in.country_a = handle;
            in.count = done;
            in.source_id = military_discharge_source(cell, s, done);
            out.push_back(in);
        };
        for (int32_t cell : cells_with_soldiers) {
            if (!discharge) break;
            if (cell < 0 || cell >= cells) continue;
            if (over <= 0) break;
            // Order: militia -> rear garrison -> obsolete; approximated by
            // "lowest unit id first", which puts the militia (id 0) first.
            // source_id packs the request in 16 bits, so a cell never asks for
            // more than MILITARY_DISCHARGE_CHUNK (a truncated request would make
            // the receipt refund the wrong number of heads).
            const int64_t take = std::min<int64_t>(over, MILITARY_DISCHARGE_CHUNK);
            const int64_t done = lot_remove_casualties((uint8_t)MILITARY_LOT_GARRISON, cell, take);
            if (done > 0) {
                over -= done;
                emit_discharge(cell, done);
            }
        }
        if (desert) {
            const uint64_t key = mix_key(mix_key(0x4445534552ull, (uint64_t)s), (uint64_t)_last_day);
            for (int32_t cell : cells_with_soldiers) {
                if (cell < 0 || cell >= cells) continue;
                int64_t garrison = 0;
                military_for_each_lot(*this, (uint8_t)MILITARY_LOT_GARRISON, cell, [&](int32_t i) {
                    if (_lots.country_slot[(size_t)i] == s) garrison += _lots.count[(size_t)i];
                });
                if (garrison <= 0) continue;
                // Daily 0.5% * (1 - pay_ratio), deterministic in (seed, cell, day).
                const int64_t gap_q16 = MILITARY_Q16 - pay;
                int64_t want = mul_div(garrison * 50, gap_q16, MILITARY_Q16 * 10000);
                if (want <= 0) {
                    const int64_t roll = rng_q16(_seed, mix_key(key, (uint64_t)cell), _last_day);
                    if (roll * 10000 < mul_div(50 * 10000, gap_q16, MILITARY_Q16)) want = 1;
                }
                want = std::min<int64_t>(want, MILITARY_DISCHARGE_CHUNK);
                if (want > 0) {
                    const int64_t done = lot_remove_casualties((uint8_t)MILITARY_LOT_GARRISON, cell, want);
                    if (done > 0) emit_discharge(cell, done);
                }
            }
        }
    }
}

} // namespace pk
