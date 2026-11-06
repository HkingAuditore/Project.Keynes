#include "economy_runtime.h"
#include "country_runtime.h"
// Army pay's worker route drives the Country economy-asset peer synchronously
// (prepare -> service -> finish in one epoch), which needs the host's concrete
// type, exactly like economy_runtime.cpp.
#include "economy_host_port.h"

#include <godot_cpp/variant/variant.hpp>
#include <algorithm>
#include <limits>

// Economy side of the army personnel lane.
// Contract: docs/plans/army-personnel-implementation-contract.md §1.
//
// Two rules from docs/cpp-dots-runtime/military-recruitment-pipeline.md decide
// the shape of this file:
//  1. Population is never written directly. A lane transfer only *queues* a
//     structural command; the cohort side of the move happens in
//     commit_structural_army_lane(), i.e. on the ordinary structural path that
//     keeps slot/page bookkeeping and the POD ledger shape valid.
//  2. The same command can reach the switch twice (POD plan plus the epoch
//     drain), so every opcode is deduplicated by `sequence` exactly like the
//     military cohort convert (opcode 24).

namespace pk {

// File-local Q16 one: the store is standalone and the runtime constants are
// nested, so both sides share this alias instead of repeating the literal.
constexpr int32_t kLaneQ16One = ArmyPersonnelStore::LANE_Q16_ONE;

// ───────────────────────────── ArmyPersonnelStore ─────────────────────────────

void ArmyPersonnelStore::clear() {
    active.clear();
    handle.clear();
    country_handle.clear();
    cell.clear();
    profession_id.clear();
    plan_id.clear();
    signature_id.clear();
    population.clear();
    funds.clear();
    epoch_income.clear();
    epoch_expense.clear();
    satisfaction_q16.clear();
    survival_q16.clear();
    ration_q16.clear();
    family_offset.clear();
    family_len.clear();
    person_offset.clear();
    person_len.clear();
    family_handles.clear();
    family_people.clear();
    family_funds.clear();
    person_handles.clear();
    _buckets.clear();
    _mask = 0;
}

int32_t ArmyPersonnelStore::find(uint64_t army_handle) const {
    if (army_handle == 0 || _buckets.empty()) return NO_ROW;
    size_t bucket = static_cast<size_t>(army_handle * 0x9E3779B97F4A7C15ULL) & _mask;
    for (size_t probe = 0; probe <= _mask; ++probe) {
        const int32_t row = _buckets[bucket];
        if (row == NO_ROW) return NO_ROW;
        if (valid_row(row) && handle[static_cast<size_t>(row)] == army_handle)
            return row;
        bucket = (bucket + 1) & _mask;
    }
    return NO_ROW;
}

void ArmyPersonnelStore::push_empty_row(uint64_t army_handle) {
    active.push_back(1);
    handle.push_back(army_handle);
    country_handle.push_back(0);
    cell.push_back(-1);
    profession_id.push_back(-1);
    plan_id.push_back(-1);
    signature_id.push_back(-1);
    population.push_back(0);
    funds.push_back(0);
    epoch_income.push_back(0);
    epoch_expense.push_back(0);
    satisfaction_q16.push_back(kLaneQ16One - 1);
    survival_q16.push_back(kLaneQ16One - 1);
    ration_q16.push_back(kLaneQ16One);
    family_offset.push_back(static_cast<int32_t>(family_handles.size()));
    family_len.push_back(0);
    person_offset.push_back(static_cast<int32_t>(person_handles.size()));
    person_len.push_back(0);
}

void ArmyPersonnelStore::rebuild_index() {
    size_t capacity = 8;
    while (capacity < static_cast<size_t>(size()) * 2 + 2) capacity <<= 1;
    _buckets.assign(capacity, NO_ROW);
    _mask = capacity - 1;
    for (int32_t row = 0; row < size(); ++row) {
        if (active[static_cast<size_t>(row)] == 0) continue;
        const uint64_t key = handle[static_cast<size_t>(row)];
        size_t bucket = static_cast<size_t>(key * 0x9E3779B97F4A7C15ULL) & _mask;
        while (_buckets[bucket] != NO_ROW) bucket = (bucket + 1) & _mask;
        _buckets[bucket] = row;
    }
}

int32_t ArmyPersonnelStore::ensure(uint64_t army_handle) {
    if (army_handle == 0) return NO_ROW;
    const int32_t found = find(army_handle);
    if (found != NO_ROW) return found;
    if (size() >= MAX_ROWS) return NO_ROW;
    push_empty_row(army_handle);
    if (_buckets.empty() || static_cast<size_t>(size()) * 2 >= _mask + 1) {
        rebuild_index();
    } else {
        size_t bucket = static_cast<size_t>(army_handle * 0x9E3779B97F4A7C15ULL) & _mask;
        while (_buckets[bucket] != NO_ROW) bucket = (bucket + 1) & _mask;
        _buckets[bucket] = size() - 1;
    }
    return size() - 1;
}

void ArmyPersonnelStore::release(int32_t row) {
    if (!valid_row(row)) return;
    const size_t i = static_cast<size_t>(row);
    const int32_t fam_off = family_offset[i];
    const int32_t fam_len = family_len[i];
    const int32_t per_off = person_offset[i];
    const int32_t per_len = person_len[i];
    // Segments are packed in row order only by accident; erase the released
    // row's segment and slide every later segment down so the CSR stays exact.
    if (fam_len > 0 && fam_off >= 0 &&
        static_cast<size_t>(fam_off + fam_len) <= family_handles.size()) {
        family_handles.erase(family_handles.begin() + fam_off,
                             family_handles.begin() + fam_off + fam_len);
        family_people.erase(family_people.begin() + fam_off,
                            family_people.begin() + fam_off + fam_len);
        family_funds.erase(family_funds.begin() + fam_off,
                           family_funds.begin() + fam_off + fam_len);
        for (int32_t other = 0; other < size(); ++other) {
            if (family_offset[static_cast<size_t>(other)] > fam_off)
                family_offset[static_cast<size_t>(other)] -= fam_len;
        }
    }
    if (per_len > 0 && per_off >= 0 &&
        static_cast<size_t>(per_off + per_len) <= person_handles.size()) {
        person_handles.erase(person_handles.begin() + per_off,
                             person_handles.begin() + per_off + per_len);
        for (int32_t other = 0; other < size(); ++other) {
            if (person_offset[static_cast<size_t>(other)] > per_off)
                person_offset[static_cast<size_t>(other)] -= per_len;
        }
    }
    const int32_t last = size() - 1;
    if (row != last) {
        const size_t j = static_cast<size_t>(last);
        const size_t hole = static_cast<size_t>(row);
        active[hole] = active[j];
        handle[hole] = handle[j];
        country_handle[hole] = country_handle[j];
        cell[hole] = cell[j];
        profession_id[hole] = profession_id[j];
        plan_id[hole] = plan_id[j];
        signature_id[hole] = signature_id[j];
        population[hole] = population[j];
        funds[hole] = funds[j];
        epoch_income[hole] = epoch_income[j];
        epoch_expense[hole] = epoch_expense[j];
        satisfaction_q16[hole] = satisfaction_q16[j];
        survival_q16[hole] = survival_q16[j];
        ration_q16[hole] = ration_q16[j];
        family_offset[hole] = family_offset[j];
        family_len[hole] = family_len[j];
        person_offset[hole] = person_offset[j];
        person_len[hole] = person_len[j];
    }
    active.pop_back();
    handle.pop_back();
    country_handle.pop_back();
    cell.pop_back();
    profession_id.pop_back();
    plan_id.pop_back();
    signature_id.pop_back();
    population.pop_back();
    funds.pop_back();
    epoch_income.pop_back();
    epoch_expense.pop_back();
    satisfaction_q16.pop_back();
    survival_q16.pop_back();
    ration_q16.pop_back();
    family_offset.pop_back();
    family_len.pop_back();
    person_offset.pop_back();
    person_len.pop_back();
    rebuild_index();
}

int64_t ArmyPersonnelStore::total_population() const {
    int64_t total = 0;
    for (int32_t row = 0; row < size(); ++row) {
        if (active[static_cast<size_t>(row)] == 0) continue;
        total += std::max<int64_t>(0, population[static_cast<size_t>(row)]);
    }
    return total;
}

int64_t ArmyPersonnelStore::total_funds() const {
    int64_t total = 0;
    for (int32_t row = 0; row < size(); ++row) {
        if (active[static_cast<size_t>(row)] == 0) continue;
        total += std::max<int64_t>(0, funds[static_cast<size_t>(row)]);
    }
    return total;
}

// ─────────────────────── NativeEconomyRuntime: lane commands ──────────────────

int64_t NativeEconomyRuntime::army_lane_country_handle(int32_t cell) const {
    if (_country_runtime == nullptr) return 0;
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    return _country_runtime->country_handle_for_cell(cell);
}

bool NativeEconomyRuntime::queue_or_commit_army_lane(const StructuralCommand &record,
                                                     std::string &error,
                                                     int64_t &moved) {
    moved = 0;
    if (_epoch_active) {
        // The structural stage still runs later in this epoch, so the ordinary
        // deferred path is both correct and in-order.
        _structural_commands.push_back(record);
        moved = record.population;
        return true;
    }
    // Between epochs (the POD command drain at a committed day boundary) that
    // day's structural stage is already behind us, so queueing would only be
    // picked up by the NEXT epoch. That is a full day of latency the lane
    // contract does not allow (the D+1 batch must be visible on D+1), so run the
    // very same structural record through the very same structural path now.
    int64_t committed = 0;
    if (!commit_structural_army_lane(record, error, &committed)) return false;
    moved = committed;
    return true;
}

bool NativeEconomyRuntime::apply_army_lane_command(const Command &cmd,
                                                   std::string &error,
                                                   int64_t &settled) {
    settled = 0;
    // Same idempotency contract as COMMAND_MILITARY_CONVERT_COHORT: the POD plan
    // and the epoch drain both reach this switch, so a repeated sequence must
    // not move people twice.
    static thread_local int64_t recent_seq[64] = {};
    static thread_local size_t recent_at = 0;
    if (cmd.sequence != 0) {
        for (int64_t seen : recent_seq) {
            if (seen == cmd.sequence) return true;
        }
        recent_seq[recent_at % 64] = cmd.sequence;
        ++recent_at;
    }
    switch (cmd.opcode) {
    case COMMAND_ARMY_EMBARK: {
        const int32_t cell = cmd.i32_0;
        const int32_t signature = cmd.i32_1;
        const uint64_t army = cmd.target_handle;
        const int64_t heads = std::max<int64_t>(0, cmd.i64_0);
        if (army == 0) {
            error = "army_embark_handle_missing";
            return false;
        }
        if (cell < 0 || cell >= _cell_count.get() || signature < 0 ||
            signature >= static_cast<int32_t>(_signatures.size())) {
            error = "army_embark_target_invalid";
            return false;
        }
        if (heads <= 0) return true;
        const int32_t source = population_store().find_signature(
            cell, static_cast<uint32_t>(signature));
        if (source < 0 || population_store().active[source] == 0) {
            // Nothing to embark: the cohort is gone (already moved, or never
            // existed). Stable-sequence semantics make this a deterministic
            // no-op rather than a fatal.
            return true;
        }
        const int64_t available =
            std::max<int64_t>(0, population_store().population[source]);
        const int64_t moved = std::min(heads, available);
        if (moved <= 0) return true;
        // The cohort side runs on the structural path; `funds` carries the army
        // handle (never a slot id) and `signature` names the source cohort so
        // the commit can re-resolve it if the slot moved.
        const StructuralCommand record{STRUCTURAL_ARMY_EMBARK, source, cell,
                                       signature, moved,
                                       static_cast<int64_t>(army),
                                       cmd.sequence};
        int64_t committed_heads = 0;
        if (!queue_or_commit_army_lane(record, error, committed_heads)) return false;
        settled = committed_heads;
        return true;
    }
    case COMMAND_ARMY_DISEMBARK: {
        const int32_t cell = cmd.i32_0;
        const int32_t signature = cmd.i32_1;
        const uint64_t army = cmd.target_handle;
        const int64_t heads = std::max<int64_t>(0, cmd.i64_0);
        if (army == 0) {
            error = "army_disembark_handle_missing";
            return false;
        }
        if (cell < 0 || cell >= _cell_count.get() || signature < 0 ||
            signature >= static_cast<int32_t>(_signatures.size())) {
            error = "army_disembark_target_invalid";
            return false;
        }
        const int32_t row = _army_personnel.find(army);
        if (row == ArmyPersonnelStore::NO_ROW) {
            error = "army_disembark_lane_missing";
            return false;
        }
        const int64_t available = std::max<int64_t>(
            0, _army_personnel.population[static_cast<size_t>(row)]);
        const int64_t moved = std::min(heads, available);
        if (moved <= 0) return true;
        const StructuralCommand record{STRUCTURAL_ARMY_DISEMBARK, -1, cell,
                                       signature, moved,
                                       static_cast<int64_t>(army),
                                       cmd.sequence};
        int64_t committed_heads = 0;
        if (!queue_or_commit_army_lane(record, error, committed_heads)) return false;
        settled = committed_heads;
        return true;
    }
    case COMMAND_ARMY_MERGE_LANES: {
        // Lane -> lane only: no cohort is touched, so this needs no structural
        // record. src = target_cohort, dst = payload1.
        const uint64_t src_handle = cmd.target_handle;
        const uint64_t dst_handle = static_cast<uint64_t>(cmd.i64_1);
        if (src_handle == 0 || dst_handle == 0) {
            error = "army_merge_handle_missing";
            return false;
        }
        if (src_handle == dst_handle) return true;
        const int32_t src = _army_personnel.find(src_handle);
        if (src == ArmyPersonnelStore::NO_ROW) {
            error = "army_merge_source_lane_missing";
            return false;
        }
        const int32_t dst = _army_personnel.ensure(dst_handle);
        if (dst == ArmyPersonnelStore::NO_ROW) {
            error = "army_merge_destination_allocation_failed";
            return false;
        }
        const size_t s = static_cast<size_t>(src);
        const size_t d = static_cast<size_t>(dst);
        const int64_t src_pop = std::max<int64_t>(0, _army_personnel.population[s]);
        const int64_t src_funds = _army_personnel.funds[s];
        const int64_t dst_pop = std::max<int64_t>(0, _army_personnel.population[d]);
        if (_army_personnel.population[d] == 0 &&
            _army_personnel.country_handle[d] == 0) {
            // Destination lane was just created: inherit the source identity so
            // the merged people keep a country and a consumption plan.
            _army_personnel.country_handle[d] = _army_personnel.country_handle[s];
            _army_personnel.cell[d] = _army_personnel.cell[s];
            _army_personnel.profession_id[d] = _army_personnel.profession_id[s];
            _army_personnel.plan_id[d] = _army_personnel.plan_id[s];
            _army_personnel.signature_id[d] = _army_personnel.signature_id[s];
            _army_personnel.ration_q16[d] = _army_personnel.ration_q16[s];
        }
        const int64_t merged_pop = dst_pop + src_pop;
        if (merged_pop > 0) {
            const auto blend = [&](int32_t dst_value, int32_t src_value) {
                const int64_t weighted = saturating_add(
                    mul_div_sat(dst_value, dst_pop, 1, _saturation_count),
                    mul_div_sat(src_value, src_pop, 1, _saturation_count),
                    _saturation_count);
                return static_cast<int32_t>(
                    std::clamp<int64_t>(weighted / merged_pop, 0, kLaneQ16One - 1));
            };
            _army_personnel.satisfaction_q16[d] = blend(
                _army_personnel.satisfaction_q16[d],
                _army_personnel.satisfaction_q16[s]);
            _army_personnel.survival_q16[d] = blend(
                _army_personnel.survival_q16[d], _army_personnel.survival_q16[s]);
        }
        _army_personnel.population[d] = merged_pop;
        _army_personnel.funds[d] = saturating_add(
            _army_personnel.funds[d], src_funds, _saturation_count);
        _army_personnel.epoch_income[d] = saturating_add(
            _army_personnel.epoch_income[d], _army_personnel.epoch_income[s],
            _saturation_count);
        _army_personnel.epoch_expense[d] = saturating_add(
            _army_personnel.epoch_expense[d], _army_personnel.epoch_expense[s],
            _saturation_count);
        // Family / notable-person sub-ledgers travel with the people. v1 never
        // populates them, but the merge must not silently drop them.
        const int32_t fam_begin = _army_personnel.family_offset[s];
        const int32_t fam_count = _army_personnel.family_len[s];
        if (fam_count > 0) {
            _army_personnel.family_offset[d] =
                static_cast<int32_t>(_army_personnel.family_handles.size());
            for (int32_t k = 0; k < fam_count; ++k) {
                const size_t at = static_cast<size_t>(fam_begin + k);
                if (at >= _army_personnel.family_handles.size()) break;
                _army_personnel.family_handles.push_back(_army_personnel.family_handles[at]);
                _army_personnel.family_people.push_back(_army_personnel.family_people[at]);
                _army_personnel.family_funds.push_back(_army_personnel.family_funds[at]);
                ++_army_personnel.family_len[d];
            }
        }
        const int32_t per_begin = _army_personnel.person_offset[s];
        const int32_t per_count = _army_personnel.person_len[s];
        if (per_count > 0) {
            _army_personnel.person_offset[d] =
                static_cast<int32_t>(_army_personnel.person_handles.size());
            for (int32_t k = 0; k < per_count; ++k) {
                const size_t at = static_cast<size_t>(per_begin + k);
                if (at >= _army_personnel.person_handles.size()) break;
                _army_personnel.person_handles.push_back(_army_personnel.person_handles[at]);
                ++_army_personnel.person_len[d];
            }
        }
        _army_personnel.family_len[s] = 0;
        _army_personnel.person_len[s] = 0;
        _army_personnel.population[s] = 0;
        _army_personnel.funds[s] = 0;
        _army_personnel.epoch_income[s] = 0;
        _army_personnel.epoch_expense[s] = 0;
        _army_personnel.release(src);
        settled = src_pop;
        return true;
    }
    case COMMAND_ARMY_SPLIT_LANES: {
        // Lane -> lane (army-personnel contract 2 §1.1), the partial version of
        // the merge above: `heads` people (payload0) and their proportional cash
        // leave the source lane and join the destination lane, which is created
        // on demand (country/cell copied from the source). Like 32 no cohort is
        // touched, so this needs no structural record; and like 32 it is already
        // covered by the sequence dedupe at the top of this function.
        //
        // Conservation is exact: the source is only ever debited by what the
        // destination was credited with, so population and funds summed over
        // both lanes are unchanged to the last unit (rounding stays on the
        // source, never burned).
        const uint64_t src_handle = cmd.target_handle;
        // Handles are `gen << 32 | slot` with gen >= 1, so a non-positive
        // payload1 can never name an army: refuse it instead of allocating a
        // lane under a cast-to-uint64 garbage key.
        const int64_t dst_raw = cmd.i64_1;
        const uint64_t dst_handle = static_cast<uint64_t>(dst_raw);
        if (src_handle == 0) {
            error = "army_split_source_handle_missing";
            return false;
        }
        if (dst_raw <= 0) {
            error = "army_split_destination_handle_missing";
            return false;
        }
        if (src_handle == dst_handle) return true;
        const int32_t src = _army_personnel.find(src_handle);
        if (src == ArmyPersonnelStore::NO_ROW) {
            error = "army_split_source_lane_missing";
            return false;
        }
        const size_t s = static_cast<size_t>(src);
        const int64_t src_pop = std::max<int64_t>(0, _army_personnel.population[s]);
        const int64_t heads = cmd.i64_0;
        const int64_t moved = heads <= 0 ? src_pop : std::min(heads, src_pop);
        if (heads > 0 && moved <= 0) return true;   // lane not filled yet
        // payload0 <= 0 asks for the whole lane: transfer semantics.
        const bool whole_lane = heads <= 0 || moved >= src_pop;

        const bool dst_known =
            _army_personnel.find(dst_handle) != ArmyPersonnelStore::NO_ROW;
        const int32_t dst = _army_personnel.ensure(dst_handle);
        if (dst == ArmyPersonnelStore::NO_ROW) {
            error = "army_split_destination_allocation_failed";
            return false;
        }
        const size_t d = static_cast<size_t>(dst);
        const int64_t dst_pop = std::max<int64_t>(0, _army_personnel.population[d]);
        if (!dst_known ||
            (dst_pop == 0 && _army_personnel.country_handle[d] == 0)) {
            // Fresh destination: it has no identity of its own, so it takes the
            // source's country and cell (contract) plus the consumption identity
            // the guest-consumption stage needs. A lane that merely lost its
            // people to a disembark keeps its own cell on purpose.
            _army_personnel.country_handle[d] = _army_personnel.country_handle[s];
            _army_personnel.cell[d] = _army_personnel.cell[s];
            _army_personnel.profession_id[d] = _army_personnel.profession_id[s];
            _army_personnel.plan_id[d] = _army_personnel.plan_id[s];
            _army_personnel.signature_id[d] = _army_personnel.signature_id[s];
            _army_personnel.ration_q16[d] = _army_personnel.ration_q16[s];
        }
        // Money follows people, floor division, remainder stays on the source.
        // `whole_lane` never divides by a zero population (a drained lane moves
        // whatever cash it still holds, which is 32's behaviour).
        const int64_t src_funds = _army_personnel.funds[s];
        const int64_t moved_funds = whole_lane
            ? src_funds
            : mul_div_sat(src_funds, moved, src_pop, _saturation_count);
        const int64_t src_income = _army_personnel.epoch_income[s];
        const int64_t moved_income = whole_lane
            ? src_income
            : mul_div_sat(src_income, moved, src_pop, _saturation_count);
        const int64_t src_expense = _army_personnel.epoch_expense[s];
        const int64_t moved_expense = whole_lane
            ? src_expense
            : mul_div_sat(src_expense, moved, src_pop, _saturation_count);
        const int64_t merged_pop = dst_pop + moved;
        if (merged_pop > 0) {
            // Population-weighted blend, identical to the merge (32): the
            // destination's own people keep their satisfaction, the newcomers
            // bring the source's.
            const auto blend = [&](int32_t dst_value, int32_t src_value) {
                const int64_t weighted = saturating_add(
                    mul_div_sat(dst_value, dst_pop, 1, _saturation_count),
                    mul_div_sat(src_value, moved, 1, _saturation_count),
                    _saturation_count);
                return static_cast<int32_t>(
                    std::clamp<int64_t>(weighted / merged_pop, 0, kLaneQ16One - 1));
            };
            _army_personnel.satisfaction_q16[d] = blend(
                _army_personnel.satisfaction_q16[d],
                _army_personnel.satisfaction_q16[s]);
            _army_personnel.survival_q16[d] = blend(
                _army_personnel.survival_q16[d], _army_personnel.survival_q16[s]);
        }
        _army_personnel.population[d] = saturating_add(
            _army_personnel.population[d], moved, _saturation_count);
        _army_personnel.funds[d] = saturating_add(
            _army_personnel.funds[d], moved_funds, _saturation_count);
        _army_personnel.epoch_income[d] = saturating_add(
            _army_personnel.epoch_income[d], moved_income, _saturation_count);
        _army_personnel.epoch_expense[d] = saturating_add(
            _army_personnel.epoch_expense[d], moved_expense, _saturation_count);
        // The debit is exact subtraction of what was credited, never a second
        // rounding: that is what makes the two-lane sum invariant.
        _army_personnel.population[s] = src_pop - moved;
        _army_personnel.funds[s] = src_funds - moved_funds;
        _army_personnel.epoch_income[s] = src_income - moved_income;
        _army_personnel.epoch_expense[s] = src_expense - moved_expense;
        // Family / notable-person sub-ledgers (contract §3: stored and merged,
        // never produced in v1). A whole-lane move carries the segment across
        // unless the destination already owns one (never overwrite); a partial
        // split leaves it on the source, which still holds the remaining people
        // and therefore their sub-accounts.
        const bool src_has_subledger =
            _army_personnel.family_len[s] > 0 || _army_personnel.person_len[s] > 0;
        bool subledger_handed_over = false;
        if (whole_lane && src_has_subledger &&
            _army_personnel.family_len[d] == 0 &&
            _army_personnel.person_len[d] == 0) {
            const int32_t fam_begin = _army_personnel.family_offset[s];
            const int32_t fam_count = _army_personnel.family_len[s];
            _army_personnel.family_offset[d] =
                static_cast<int32_t>(_army_personnel.family_handles.size());
            for (int32_t k = 0; k < fam_count; ++k) {
                const size_t at = static_cast<size_t>(fam_begin + k);
                if (at >= _army_personnel.family_handles.size()) break;
                _army_personnel.family_handles.push_back(
                    _army_personnel.family_handles[at]);
                _army_personnel.family_people.push_back(
                    _army_personnel.family_people[at]);
                _army_personnel.family_funds.push_back(
                    _army_personnel.family_funds[at]);
                ++_army_personnel.family_len[d];
            }
            const int32_t per_begin = _army_personnel.person_offset[s];
            const int32_t per_count = _army_personnel.person_len[s];
            _army_personnel.person_offset[d] =
                static_cast<int32_t>(_army_personnel.person_handles.size());
            for (int32_t k = 0; k < per_count; ++k) {
                const size_t at = static_cast<size_t>(per_begin + k);
                if (at >= _army_personnel.person_handles.size()) break;
                _army_personnel.person_handles.push_back(
                    _army_personnel.person_handles[at]);
                ++_army_personnel.person_len[d];
            }
            _army_personnel.family_len[s] = 0;
            _army_personnel.person_len[s] = 0;
            subledger_handed_over = true;
        }
        if (_army_personnel.population[s] <= 0 && _army_personnel.funds[s] == 0 &&
            (!src_has_subledger || subledger_handed_over)) {
            // Fully drained source (e.g. the whole lane moved): release the row
            // exactly like a disembark that empties its lane. A source that
            // still owns a sub-ledger keeps its row so nothing is dropped.
            _army_personnel.population[s] = 0;
            _army_personnel.funds[s] = 0;
            _army_personnel.epoch_income[s] = 0;
            _army_personnel.epoch_expense[s] = 0;
            _army_personnel.release(src);
        }
        settled = moved;
        return true;
    }
    case COMMAND_ARMY_LANE_PAY: {
        // Army pay (army-pay contract §1): the wages of the people who actually
        // march with the formation, paid into the lane instead of the garrison
        // cell they left behind. Three rules shape this:
        //  1. Never mint. The cash comes from the existing conserved
        //     treasury debit (one committed fiscal reserve), so the treasury loses
        //     exactly what the lane gains; there is no second issuance path.
        //  2. The command names the lane by ARMY HANDLE (target_cohort), the
        //     same key 30-33 use; `settled` reports the amount actually moved so
        //     the receipt fold can compare it with the requested amount.
        //  3. Already covered by the `sequence` dedupe at the top of this
        //     function: the POD plan and the epoch drain both reach this switch,
        //     and paying twice would double the payroll.
        const uint64_t army = cmd.target_handle;
        const int64_t country = cmd.i64_1;
        const int64_t requested = std::max<int64_t>(0, cmd.i64_0);
        if (army == 0) {
            error = "army_lane_pay_handle_missing";
            return false;
        }
        if (country == 0) {
            error = "army_lane_pay_country_missing";
            return false;
        }
        const int32_t row = _army_personnel.find(army);
        if (row == ArmyPersonnelStore::NO_ROW) {
            // No lane: the formation never mustered people here (or was already
            // disbanded). A stable no-op with settled 0 — the receipt reports a
            // failed payment rather than an economy fatal.
            error = "army_lane_pay_lane_missing";
            return false;
        }
        if (requested <= 0) return true;
        // Pay through the conserved "treasury -> non-tax expenditure" path
        // (army-pay contract §1.1): the treasury loses exactly what the lane
        // gains, and nothing is minted. Two execution shapes, picked by whether
        // Country still accepts synchronous store writes:
        //
        //  * SYNC Country (single-threaded, no worker domination):
        //    Commit one fiscal reserve, then credit the lane in this call.
        //    FISCAL_COLLECT credits Country; it is not a payment confirmation.
        //    The legacy deferred-upkeep helper has a separate, unchanged contract.
        //  * WORKER Country (whole-graph ACTIVE): that synchronous escrow refuses
        //    with `country_worker_unique_writer`. The cohort-cash coordinator solves
        //    exactly this problem for cohorts, and it does so SYNCHRONOUSLY on the
        //    worker thread (prepare -> service peer -> finish), which is why it
        //    keeps the epoch's audit intact. The lane is credited by the peer's
        //    side effect, keyed by the formation handle, so the money is conserved
        //    inside one window.
        //
        // Never route through `block_or_enqueue_country_worker_asset`: that
        // enqueues work the peer settles on its own cadence, splitting the debit
        // and the credit across audit windows (observed as
        // `money_conservation_failed`).
        int64_t moved = 0;
        std::string cash_error;
        if (_country_runtime != nullptr && _country_runtime->economy_available() &&
            _country_runtime->sync_store_writes_forbidden() &&
            _simulation_host != nullptr &&
            _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
            (_d7_operation_gate_mask &
             (1u << static_cast<uint32_t>(
                 NativeCountryRuntime::ECONOMY_ASSET_TREASURY_SPEND))) != 0u) {
            if (!pay_army_lane_from_worker_country(army, country, requested, moved,
                                                   cash_error)) {
                error = cash_error.empty() ? "army_lane_pay_worker_route_failed"
                                           : cash_error;
                return false;
            }
        } else {
            if (_country_runtime == nullptr || !_country_runtime->economy_available()) {
                error = "army_lane_pay_country_unavailable";
                return false;
            }
            // Complete the same debit protocol as the old reserve half. Do not
            // credit Country back before paying the lane: that would mint cash.
            const auto debit = [&]() -> int64_t {
                const auto port = _country_runtime->fiscal_return_port();
                const auto begun = port.submit_cash(port.reserve_intent(
                    country, requested, -1, -1));
                if (!static_cast<bool>(begun.get("ok", false))) return 0;
                const uint64_t id = static_cast<int64_t>(begun.get("transaction_id", 0));
                const uint64_t session = static_cast<int64_t>(begun.get("session_epoch", 0));
                const uint64_t generation = static_cast<int64_t>(begun.get("country_generation", 0));
                if (id == 0 || session == 0 || generation == 0) return 0;
                const auto prepared = port.prepared({id, session, generation, id}, true, "");
                if (!static_cast<bool>(prepared.get("ok", false))) return 0;
                const auto committed = port.apply(id);
                if (!static_cast<bool>(committed.get("ok", false))) return 0;
                const auto applied = port.applied({id, session, generation, id}, true, "");
                return static_cast<bool>(applied.get("ok", false)) &&
                        godot::String(applied.get("status_name", "")) == "completed"
                    ? static_cast<int64_t>(applied.get("committed_quantity", 0)) : 0;
            };
            moved = debit();
            if (moved <= 0) {
                // The treasury could not fund any of it (or Country is unavailable).
                // Nothing was booked, so the lane must not grow by a single unit.
                error = "army_lane_pay_treasury_empty";
                return false;
            }
            const size_t r = static_cast<size_t>(row);
            _army_personnel.funds[r] = saturating_add(
                _army_personnel.funds[r], moved, _saturation_count);
            _army_personnel.epoch_income[r] = saturating_add(
                _army_personnel.epoch_income[r], moved, _saturation_count);
            trace_record_cashflow(_army_personnel.cell[r], army, CASHFLOW_TRANSFER,
                                  0, moved);
        }
        settled = moved;
        return moved > 0;
    }
    default:
        error = "army_lane_command_unsupported";
        return false;
    }
}

// ─────────────────── NativeEconomyRuntime: structural commit ─────────────────

bool NativeEconomyRuntime::pay_army_lane_from_worker_country(
        uint64_t army_handle, int64_t country_handle, int64_t requested,
        int64_t &moved, std::string &error) {
    moved = 0;
    error.clear();
    if (army_handle == 0 || country_handle == 0 || requested <= 0) {
        error = "army_lane_pay_request_invalid";
        return false;
    }
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) {
        error = "army_lane_pay_lane_missing";
        return false;
    }
    if (_simulation_host == nullptr || _country_runtime == nullptr) {
        error = "army_lane_pay_worker_boundary_unavailable";
        return false;
    }
    if (!_simulation_host->on_worker_thread()) {
        error = "army_lane_pay_worker_boundary_invalid";
        return false;
    }
    // Same synchronous peer cycle the cohort cash lane uses (coordinate_country_
    // cohort_cash): prepare on Country's POD authority, let this runtime's own
    // executor apply the Economy side, then finish. Running all three inside one
    // epoch is what keeps the debit and the credit in the same audit window; the
    // enqueue-only route would let them land in different ones.
    RuntimeEconomyAssetRequest request;
    request.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
    request.origin_epoch = _epoch_id.get();
    request.origin_stage = static_cast<int32_t>(_stage);
    request.day = _current_day.get();
    request.country_handle = static_cast<uint64_t>(country_handle);
    request.target_slot = -1;
    request.target_handle = army_handle;   // <- the lane to credit on the peer side
    request.peer_generation = _committed_generation;
    request.requested_cash = requested;
    request.requested_quantity = requested;
    if (!_simulation_host->prepare_worker_cohort_cash(request, error)) return false;
    if (!service_country_economy_asset_peer(RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY,
                                            error))
        return false;
    RuntimeEconomyAssetResult terminal;
    if (!_simulation_host->finish_worker_country_asset(request.request_id, terminal,
                                                       error))
        return false;
    moved = std::max<int64_t>(0, std::min(requested, terminal.committed_cash));
    if (moved <= 0) {
        error = "army_lane_pay_treasury_empty";
        return false;
    }
    // The peer side already credited the lane through apply_peer_asset_side_effects
    // (TREASURY_SPEND with a formation handle). Only the cashflow trace is booked
    // here, and only when the side effect did not already do it.
    return true;
}

bool NativeEconomyRuntime::commit_structural_army_lane(const StructuralCommand &cmd,
                                                       std::string &error,
                                                       int64_t *moved_out) {
    if (moved_out != nullptr) *moved_out = 0;
    const uint64_t army = static_cast<uint64_t>(cmd.funds);
    if (army == 0) return true;
    if (cmd.cell < 0 || cmd.cell >= _cell_count.get() || cmd.signature < 0 ||
        cmd.signature >= static_cast<int32_t>(_signatures.size())) {
        error = "structural_army_lane_target_invalid";
        return false;
    }
    const int64_t requested = std::max<int64_t>(0, cmd.population);
    if (requested <= 0) return true;
    // The cohort fill/ownership reconcile and the merchant-range rebuild of this
    // cell only run from the structural stage. A record committed inline (POD
    // drain between epochs) must therefore ask for that reconcile explicitly;
    // inside an epoch the touched list already reaches it before it is cleared.
    const auto defer_reconcile_if_idle = [&]() {
        if (!_epoch_active) _deferred_population_reconcile_cells.push_back(cmd.cell);
    };

    if (cmd.opcode == STRUCTURAL_ARMY_EMBARK) {
        // Re-resolve the source cohort from (cell, signature): the recorded slot
        // is a hint only, and a producer from another context never owns one.
        int32_t source = cmd.source_slot;
        const bool slot_ok = source >= 0 &&
            source < static_cast<int32_t>(population_store().active.size()) &&
            population_store().active[source] != 0;
        // A hint that still names a live slot may name a DIFFERENT cohort when an
        // earlier command in the same batch released and reallocated it, so the
        // signature must agree before the slot is trusted.
        if (!slot_ok || population_store().signature_id[source] !=
                static_cast<uint32_t>(cmd.signature)) {
            source = population_store().find_signature(
                cmd.cell, static_cast<uint32_t>(cmd.signature));
        }
        if (source < 0 ||
            source >= static_cast<int32_t>(population_store().active.size()) ||
            population_store().active[source] == 0) {
            // The cohort was already drained by an earlier command in the same
            // batch: deterministic no-op, never a fatal.
            return true;
        }
        const int64_t source_pop =
            std::max<int64_t>(0, population_store().population[source]);
        const int64_t moved = std::min(requested, source_pop);
        if (moved <= 0) return true;
        // Money follows people proportionally; the remainder stays on the
        // source cohort (contract §1.2).
        const int64_t source_funds = population_store().funds[source];
        const int64_t moved_funds = moved == source_pop
            ? source_funds
            : mul_div_sat(source_funds, moved, source_pop, _saturation_count);
        const int64_t moved_income = moved == source_pop
            ? population_store().epoch_income[source]
            : mul_div_sat(population_store().epoch_income[source], moved,
                          source_pop, _saturation_count);
        const int64_t moved_expense = moved == source_pop
            ? population_store().epoch_expense[source]
            : mul_div_sat(population_store().epoch_expense[source], moved,
                          source_pop, _saturation_count);
        const uint16_t moved_satisfaction = population_store().needs_satisfaction[source];
        const uint16_t moved_composite = population_store().composite_satisfaction[source];
        const int64_t source_handle =
            static_cast<int64_t>(population_store().handle_for_slot(source));
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[source]);
        const int32_t profession = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].profession_id : -1;
        const int32_t plan = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].plan_id : -1;

        const int32_t row = _army_personnel.ensure(army);
        if (row == ArmyPersonnelStore::NO_ROW) {
            error = "army_lane_allocation_failed";
            return false;
        }
        const size_t r = static_cast<size_t>(row);
        if (_army_personnel.population[r] <= 0) {
            // Fresh lane: identity, country and consumption plan come from the
            // cohort that just boarded.
            _army_personnel.cell[r] = cmd.cell;
            _army_personnel.country_handle[r] = static_cast<uint64_t>(
                army_lane_country_handle(cmd.cell));
            _army_personnel.profession_id[r] = profession;
            _army_personnel.plan_id[r] = plan;
            _army_personnel.signature_id[r] = signature;
            _army_personnel.satisfaction_q16[r] = moved_composite;
            _army_personnel.survival_q16[r] = moved_satisfaction;
        } else {
            const int64_t before_pop = std::max<int64_t>(0, _army_personnel.population[r]);
            const int64_t after_pop = before_pop + moved;
            if (after_pop > 0) {
                const int64_t weighted = saturating_add(
                    mul_div_sat(_army_personnel.satisfaction_q16[r], before_pop, 1,
                                _saturation_count),
                    mul_div_sat(moved_composite, moved, 1, _saturation_count),
                    _saturation_count);
                _army_personnel.satisfaction_q16[r] = static_cast<int32_t>(
                    std::clamp<int64_t>(weighted / after_pop, 0, kLaneQ16One - 1));
                const int64_t survival_weighted = saturating_add(
                    mul_div_sat(_army_personnel.survival_q16[r], before_pop, 1,
                                _saturation_count),
                    mul_div_sat(moved_satisfaction, moved, 1, _saturation_count),
                    _saturation_count);
                _army_personnel.survival_q16[r] = static_cast<int32_t>(
                    std::clamp<int64_t>(survival_weighted / after_pop, 0, kLaneQ16One - 1));
            }
        }
        _army_personnel.population[r] = saturating_add(
            _army_personnel.population[r], moved, _saturation_count);
        _army_personnel.funds[r] = saturating_add(
            _army_personnel.funds[r], moved_funds, _saturation_count);
        _army_personnel.epoch_income[r] = saturating_add(
            _army_personnel.epoch_income[r], moved_income, _saturation_count);
        _army_personnel.epoch_expense[r] = saturating_add(
            _army_personnel.epoch_expense[r], moved_expense, _saturation_count);

        // Cohort side, on the structural path (slot/page bookkeeping included).
        audit_touch_population_lane(source);
        population_store().population.write_scalar(
            source, source_pop - moved, market_mutation_sink());
        population_store().funds.write_scalar(
            source, source_funds - moved_funds, market_mutation_sink());
        population_store().epoch_income.write_scalar(
            source, population_store().epoch_income[source] - moved_income,
            market_mutation_sink());
        population_store().epoch_expense.write_scalar(
            source, population_store().epoch_expense[source] - moved_expense,
            market_mutation_sink());
        const int64_t remaining_pop = population_store().population[source];
        if (remaining_pop == 0) {
            // Any rounding residue is money, not an implicit burn.
            const int64_t residue = population_store().funds[source];
            const int64_t country_handle = army_lane_country_handle(cmd.cell);
            int64_t transferred = 0;
            std::string cohort_cash_error;
            if (!coordinate_country_cohort_cash(
                    source, country_handle,
                    NativeCountryRuntime::ECONOMY_ASSET_CASH_FROM_COHORT,
                    residue, transferred, cohort_cash_error)) {
                error = cohort_cash_error.empty()
                    ? "country_treasury_residue_transfer_failed"
                    : cohort_cash_error;
                return false;
            }
            if (transferred != residue) {
                // Same soft-unavailable path as commit_structural: keep the
                // residue on the drained slot until the Country peer opens.
                if (transferred == 0 &&
                    (cohort_cash_error == "country_economy_operation_gate_closed" ||
                     cohort_cash_error == "country_cohort_cash_treasury_unowned" ||
                     cohort_cash_error == "country_cohort_cash_negative_balance")) {
                    _structural_touched_cells.push_back(cmd.cell);
                    return true;
                }
                error = "country_treasury_residue_transfer_failed";
                return false;
            }
            _structural_funds_to_treasury = saturating_add(
                _structural_funds_to_treasury, residue, _saturation_count);
            population_store().funds.write_scalar(source, 0, market_mutation_sink());
            _filled_owner_jobs = saturating_sub(
                _filled_owner_jobs,
                std::max<int64_t>(0, population_store().owner_employed[source]),
                _saturation_count);
            _filled_employee_jobs = saturating_sub(
                _filled_employee_jobs,
                std::max<int64_t>(0, population_store().employee_employed[source]),
                _saturation_count);
            if (slot_has_merchant_profession(source)) _merchant_ranges_dirty = true;
            population_store().release_slot(source);
            population_store().reclaim_empty_pages(cmd.cell);
        }
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            source_handle, -1, source_pop, source_pop - moved});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT, static_cast<int64_t>(army), signature,
                     cmd.cell, moved, moved_funds, cmd.cell, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        if (moved_out != nullptr) *moved_out = moved;
        defer_reconcile_if_idle();
        return true;
    }

    if (cmd.opcode == STRUCTURAL_ARMY_DISEMBARK) {
        const int32_t row = _army_personnel.find(army);
        if (row == ArmyPersonnelStore::NO_ROW) return true;
        const size_t r = static_cast<size_t>(row);
        const int64_t lane_pop = std::max<int64_t>(0, _army_personnel.population[r]);
        const int64_t moved = std::min(requested, lane_pop);
        if (moved <= 0) return true;
        const int64_t lane_funds = _army_personnel.funds[r];
        const int64_t moved_funds = moved == lane_pop
            ? lane_funds
            : mul_div_sat(lane_funds, moved, lane_pop, _saturation_count);
        const int64_t moved_income = moved == lane_pop
            ? _army_personnel.epoch_income[r]
            : mul_div_sat(_army_personnel.epoch_income[r], moved, lane_pop,
                          _saturation_count);
        const int64_t moved_expense = moved == lane_pop
            ? _army_personnel.epoch_expense[r]
            : mul_div_sat(_army_personnel.epoch_expense[r], moved, lane_pop,
                          _saturation_count);
        const int32_t destination = population_store().allocate_slot(
            cmd.cell, static_cast<uint32_t>(cmd.signature));
        if (destination < 0) {
            error = "structural_disembark_allocation_failed";
            return false;
        }
        const int64_t destination_pop_before = population_store().population[destination];
        const int64_t destination_handle =
            static_cast<int64_t>(population_store().handle_for_slot(destination));
        touch_accounting_slot(destination);
        audit_touch_population_lane(destination);
        if (destination_pop_before == 0 && slot_has_merchant_profession(destination))
            _merchant_ranges_dirty = true;
        const int64_t merged_pop = destination_pop_before + moved;
        population_store().population.write_scalar(
            destination, merged_pop, market_mutation_sink());
        population_store().funds.write_scalar(
            destination,
            saturating_add(population_store().funds[destination], moved_funds,
                           _saturation_count),
            market_mutation_sink());
        population_store().epoch_income.write_scalar(
            destination,
            saturating_add(population_store().epoch_income[destination],
                           moved_income, _saturation_count),
            market_mutation_sink());
        population_store().epoch_expense.write_scalar(
            destination,
            saturating_add(population_store().epoch_expense[destination],
                           moved_expense, _saturation_count),
            market_mutation_sink());
        const auto blend = [&](int64_t destination_value, int64_t incoming_value) {
            if (merged_pop <= 0) return static_cast<uint16_t>(kLaneQ16One - 1);
            const int64_t weighted = saturating_add(
                mul_div_sat(destination_value, destination_pop_before, 1,
                            _saturation_count),
                mul_div_sat(incoming_value, moved, 1, _saturation_count),
                _saturation_count);
            return static_cast<uint16_t>(
                std::clamp<int64_t>(weighted / merged_pop, 0, kLaneQ16One - 1));
        };
        population_store().needs_satisfaction.write_scalar(
            destination,
            blend(population_store().needs_satisfaction[destination],
                  _army_personnel.survival_q16[r]),
            market_mutation_sink());
        population_store().composite_satisfaction.write_scalar(
            destination,
            blend(population_store().composite_satisfaction[destination],
                  _army_personnel.satisfaction_q16[r]),
            market_mutation_sink());

        _army_personnel.population[r] = lane_pop - moved;
        _army_personnel.funds[r] = lane_funds - moved_funds;
        _army_personnel.epoch_income[r] =
            _army_personnel.epoch_income[r] - moved_income;
        _army_personnel.epoch_expense[r] =
            _army_personnel.epoch_expense[r] - moved_expense;
        if (_army_personnel.population[r] <= 0) {
            // Emptied lane: release the row (compacts the SoA and the CSR).
            _army_personnel.population[r] = 0;
            _army_personnel.funds[r] = 0;
            _army_personnel.release(row);
        }
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            destination_handle, -1, destination_pop_before,
                            merged_pop});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT, destination_handle, cmd.signature, cmd.cell,
                     moved, moved_funds, -1, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        if (moved_out != nullptr) *moved_out = moved;
        defer_reconcile_if_idle();
        return true;
    }
    return true;
}

// ───────────────────────── NativeEconomyRuntime: queries ─────────────────────

int64_t NativeEconomyRuntime::military_army_population(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return 0;
    return std::max<int64_t>(0, _army_personnel.population[static_cast<size_t>(row)]);
}

int64_t NativeEconomyRuntime::military_army_funds(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return 0;
    return _army_personnel.funds[static_cast<size_t>(row)];
}

int32_t NativeEconomyRuntime::military_army_cell(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return -1;
    return _army_personnel.cell[static_cast<size_t>(row)];
}

int32_t NativeEconomyRuntime::military_army_satisfaction_q16(uint64_t army_handle) const {
    const int32_t row = _army_personnel.find(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return kLaneQ16One - 1;
    return _army_personnel.satisfaction_q16[static_cast<size_t>(row)];
}

int64_t NativeEconomyRuntime::military_army_lane_population() const {
    return _army_personnel.total_population();
}

bool NativeEconomyRuntime::military_army_lane_split_supported() const {
    // Opcode 33 (COMMAND_ARMY_SPLIT_LANES) is built unconditionally, so this is
    // a constant. The Military bridge needs the probe anyway: it is compiled
    // against an Economy that may predate the opcode, and `army.split` /
    // `army.transfer` must keep the old "the lane stays put" translation (and
    // say so in the report) instead of emitting a command admission will drop.
    return true;
}

bool NativeEconomyRuntime::military_army_lane_pay_supported() const {
    // Opcode 34 (COMMAND_ARMY_LANE_PAY) is built unconditionally, so the opcode is
    // always available (same contract as the split-lane probe: the Military bridge
    // must translate MILITARY_INTENT_ARMY_PAY into a no-op plus a failed receipt
    // rather than an opcode admission would reject).
    //
    // Paying needs a treasury debit that lands in the same epoch as the lane credit.
    // Two shapes provide that: the synchronous fiscal escrow when Country still
    // accepts sync store writes, and the synchronous worker peer cycle when Country
    // is worker-authoritative. Both need the Country runtime to be usable.
    return _country_runtime != nullptr && _country_runtime->economy_available();
}

void NativeEconomyRuntime::set_military_army_ration(uint64_t army_handle,
                                                    int32_t ration_q16) {
    const int32_t row = _army_personnel.ensure(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return;
    _army_personnel.ration_q16[static_cast<size_t>(row)] =
        static_cast<int32_t>(std::clamp<int32_t>(ration_q16, 0, kLaneQ16One));
}

void NativeEconomyRuntime::set_military_army_ration(uint64_t army_handle,
                                                    int32_t ration_q16,
                                                    int32_t cell) {
    const int32_t row = _army_personnel.ensure(army_handle);
    if (row == ArmyPersonnelStore::NO_ROW) return;
    const size_t r = static_cast<size_t>(row);
    _army_personnel.ration_q16[r] =
        static_cast<int32_t>(std::clamp<int32_t>(ration_q16, 0, kLaneQ16One));
    if (cell < 0 || cell >= _cell_count.get()) return;
    if (_army_personnel.cell[r] != cell) {
        _army_personnel.cell[r] = cell;
        if (_army_personnel.population[r] > 0)
            _army_personnel.country_handle[r] = static_cast<uint64_t>(
                army_lane_country_handle(cell));
    }
}

void NativeEconomyRuntime::sum_army_personnel_holdings(int64_t &population,
                                                       int64_t &funds,
                                                       int64_t &saturation_count) const {
    population = saturating_add(population, _army_personnel.total_population(),
                                saturation_count);
    funds = saturating_add(funds, _army_personnel.total_funds(),
                           saturation_count);
}

// ───────────────────────── Guest consumption (§1.3) ──────────────────────────

void NativeEconomyRuntime::run_army_personnel_consumption(int32_t market, MarketResult &result) {
    if (_army_personnel.empty() || _army_personnel.size() <= 0) return;
    if (market < 0 || market >= market_store().market_count.get()) return;
    const int32_t cell_count = _cell_count.get();
    if (cell_count <= 0 ||
        market_store().cell_to_market.size() < static_cast<size_t>(cell_count))
        return;
    const int64_t epoch_days = std::max<int64_t>(1, _epoch_days.get());
    // Market cells are settled on worker threads; use a task-local saturation
    // counter instead of the shared member.
    int64_t sat = 0;
    const bool merchant_ok = market_has_living_merchant(market);
    thread_local std::vector<int32_t> merchants;
    merchants.clear();
    if (merchant_ok) collect_living_merchant_slots(market, merchants);
    if (merchants.empty()) {
        // No living merchant: the lane still records the shortfall below, but
        // there is nobody to pay, so no purchase happens at all.
    }
    const int32_t good_count = market_store().good_count.get();
    if (good_count <= 0) return;
    // Guest consumption removes market stock and pays merchants exactly like a
    // household does, so it must book both into the market result or the goods
    // and money audits fail (goods_conservation_failed at the first embark).
    int64_t lane_consumed = 0;
    int64_t lane_spent = 0;

    for (int32_t row = 0; row < _army_personnel.size(); ++row) {
        const size_t r = static_cast<size_t>(row);
        if (_army_personnel.active[r] == 0) continue;
        const int32_t cell = _army_personnel.cell[r];
        if (cell < 0 || cell >= cell_count) continue;
        if (market_store().cell_to_market[static_cast<size_t>(cell)] != market) continue;
        const int64_t people = std::max<int64_t>(0, _army_personnel.population[r]);
        if (people <= 0) continue;
        const int32_t profession = _army_personnel.profession_id[r];
        const int32_t plan_id = _army_personnel.plan_id[r];
        if (plan_id < 0 || plan_id >= static_cast<int32_t>(_plans.size())) continue;
        const Plan &plan = _plans[static_cast<size_t>(plan_id)];
        // Guest consumption happens only when the army sits on a cell its own
        // country still owns and there is a living merchant to buy from.
        // (Military owns the controller; Economy can only check ownership here.)
        const uint64_t lane_country = _army_personnel.country_handle[r];
        const int64_t cell_country = army_lane_country_handle(cell);
        const bool can_buy = merchant_ok && !merchants.empty() &&
            lane_country != 0 &&
            (cell_country == 0 || static_cast<uint64_t>(cell_country) == lane_country);
        int64_t funds_left = std::max<int64_t>(0, _army_personnel.funds[r]);
        const int64_t funds_before = funds_left;
        int64_t total_desired = 0;
        int64_t total_filled = 0;
        int64_t survival_desired = 0;
        int64_t survival_filled = 0;
        int64_t spent = 0;
        const int32_t ration_q16 = std::clamp<int32_t>(
            _army_personnel.ration_q16[r], 0, kLaneQ16One);
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size()))
                continue;
            const Need &need = _needs[static_cast<size_t>(need_index)];
            int64_t target = saturating_mul(
                saturating_mul(people, std::max<int64_t>(0, need.base_qty_per_person),
                               sat),
                epoch_days, sat);
            if (target <= 0) continue;
            const bool survival_need = need.stable_id >= 0 &&
                static_cast<size_t>(need.stable_id) < _survival_food_need_mask.size() &&
                _survival_food_need_mask[static_cast<size_t>(need.stable_id)] != 0;
            const bool survival_basket = survival_need ||
                (need.stable_id == _survival_clothing_need_stable_id);
            total_desired = saturating_add(total_desired, target, sat);
            if (survival_basket)
                survival_desired = saturating_add(survival_desired, target, sat);
            int64_t filled = 0;
            if (profession_need_is_state_supplied(profession, need.stable_id)) {
                // Ration needs are supplied in kind by Military: no market
                // purchase, the fill ratio is the army's published ration.
                filled = mul_div_sat(target, ration_q16, kLaneQ16One, sat);
            } else if (can_buy) {
                filled = 0;
                // First variant whose components are all in stock; its cost per
                // need unit decides how much of the target the lane can afford.
                for (int32_t v = 0; v < need.variant_count; ++v) {
                    const int32_t variant_id = need.variant_begin + v;
                    if (variant_id < 0 ||
                        variant_id >= static_cast<int32_t>(_variants.size()))
                        continue;
                    const VariantChoice &variant = _variants[static_cast<size_t>(variant_id)];
                    if (variant.component_count <= 0) continue;
                    int64_t unit_cash = 0;
                    int64_t stock_limit = std::numeric_limits<int64_t>::max();
                    bool usable = true;
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const int32_t component_index = variant.component_begin + c;
                        if (component_index < 0 ||
                            component_index >= static_cast<int32_t>(_components.size())) {
                            usable = false;
                            break;
                        }
                        const NeedComponent &component =
                            _components[static_cast<size_t>(component_index)];
                        const int32_t good = component.good_id;
                        if (good < 0 || good >= good_count) {
                            usable = false;
                            break;
                        }
                        const int64_t index = market_store().index(market, good);
                        if (index < 0) {
                            usable = false;
                            break;
                        }
                        const int64_t stock = std::max<int64_t>(
                            0, market_store().stock[static_cast<size_t>(index)]);
                        const int64_t qty = std::max<int64_t>(1, component.qty_per_need);
                        const int64_t price = std::max<int64_t>(
                            0, market_store().price[static_cast<size_t>(index)]);
                        if (stock <= 0) {
                            usable = false;
                            break;
                        }
                        unit_cash = saturating_add(
                            unit_cash, mul_div_sat(qty, price, GOODS_SCALE,
                                                   sat),
                            sat);
                        stock_limit = std::min(
                            stock_limit,
                            mul_div_sat(stock, GOODS_SCALE, qty, sat));
                    }
                    if (!usable || unit_cash <= 0 || stock_limit <= 0) continue;
                    int64_t units = std::min(target, stock_limit);
                    if (funds_left > 0)
                        units = std::min(units, funds_left / unit_cash);
                    else
                        units = 0;
                    if (units <= 0) continue;
                    // Buy the goods, then charge exactly what was handed over.
                    int64_t cash = 0;
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const NeedComponent &component =
                            _components[static_cast<size_t>(
                                variant.component_begin + c)];
                        const int64_t index = market_store().index(market, component.good_id);
                        const int64_t qty = std::max<int64_t>(1, component.qty_per_need);
                        int64_t bought = mul_div_sat(units, qty, GOODS_SCALE,
                                                     sat);
                        if (bought <= 0) bought = 1;
                        const int64_t stock = std::max<int64_t>(
                            0, market_store().stock[static_cast<size_t>(index)]);
                        bought = std::min(bought, stock);
                        if (bought <= 0) continue;
                        audit_touch_market_lane(static_cast<size_t>(index));
                        market_store().stock.write_scalar(
                            index, stock - bought, market_mutation_sink());
                        // The audit's goods expectation is
                        //   opening + explicit delta - consumed - ...
                        // and the incremental shadow already sees this stock
                        // drop (audit_touch_market_lane above), so the removed
                        // units MUST be booked as consumed here or the closing
                        // balance can never equal the expectation
                        // (goods_conservation_failed on the first embark).
                        lane_consumed = saturating_add(lane_consumed, bought, sat);
                        cash = saturating_add(cash, mul_div_sat(
                            bought, std::max<int64_t>(
                                0, market_store().price[static_cast<size_t>(index)]),
                            GOODS_SCALE, sat), sat);
                    }
                    cash = std::min(cash, funds_left);
                    if (cash <= 0) break;
                    funds_left -= cash;
                    spent = saturating_add(spent, cash, sat);
                    filled = units;
                    break;
                }
            }
            filled = std::clamp<int64_t>(filled, 0, target);
            total_filled = saturating_add(total_filled, filled, sat);
            if (survival_basket)
                survival_filled = saturating_add(survival_filled, filled,
                                                 sat);
        }
        // Pay the merchant population proportionally, exactly like the household
        // clearing revenue split. Money is transferred, never minted.
        if (spent > 0 && !merchants.empty()) {
            int64_t merchant_population = 0;
            for (const int32_t slot : merchants)
                merchant_population = saturating_add(
                    merchant_population, std::max<int64_t>(0,
                        population_store().population[slot]), sat);
            if (merchant_population > 0) {
                int64_t prefix = 0;
                int64_t distributed = 0;
                for (const int32_t slot : merchants) {
                    prefix = saturating_add(prefix, std::max<int64_t>(0,
                        population_store().population[slot]), sat);
                    const int64_t next = mul_div_sat(spent, prefix, merchant_population,
                                                     sat);
                    const int64_t share = std::max<int64_t>(0, next - distributed);
                    distributed = next;
                    if (share <= 0) continue;
                    population_store().funds.write_scalar(
                        slot, saturating_add(population_store().funds[slot], share,
                                             sat),
                        market_mutation_sink());
                    population_store().epoch_income.write_scalar(
                        slot, saturating_add(population_store().epoch_income[slot], share,
                                             sat),
                        market_mutation_sink());
                }
                if (distributed < spent) {
                    // Rounding remainder to the first merchant so the transfer
                    // stays exactly equal to the lane's debit.
                    const int32_t slot = merchants.front();
                    population_store().funds.write_scalar(
                        slot, saturating_add(population_store().funds[slot],
                                             spent - distributed, sat),
                        market_mutation_sink());
                    population_store().epoch_income.write_scalar(
                        slot, saturating_add(population_store().epoch_income[slot],
                                             spent - distributed, sat),
                        market_mutation_sink());
                }
            } else {
                // No merchant population to pay: undo the spending by not
                // charging it. Stock was already taken, so give the money back
                // to the lane (conservation beats realism here).
                spent = 0;
            }
        }
        if (spent == 0 && funds_left != funds_before) funds_left = funds_before;
        _army_personnel.funds[r] = funds_left;
        _army_personnel.epoch_expense[r] = saturating_add(
            _army_personnel.epoch_expense[r], spent, sat);
        _army_personnel.satisfaction_q16[r] = total_desired > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                  mul_div_sat(total_filled, kLaneQ16One, total_desired, sat),
                  0, kLaneQ16One - 1))
            : kLaneQ16One - 1;
        lane_spent = saturating_add(lane_spent, spent, sat);
        _army_personnel.survival_q16[r] = survival_desired > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                  mul_div_sat(survival_filled, kLaneQ16One, survival_desired,
                              sat),
                  0, kLaneQ16One - 1))
            : _army_personnel.satisfaction_q16[r];
    }
    result.consumed_goods = saturating_add(result.consumed_goods, lane_consumed, sat);
    result.revenue = saturating_add(result.revenue, lane_spent, sat);
}

} // namespace pk
