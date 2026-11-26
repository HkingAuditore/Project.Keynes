#include "economy_runtime.h"
// Army pay's worker route drives the Country economy-asset peer synchronously
// (prepare -> service -> finish in one epoch), which needs the host's concrete
// type, exactly like economy_runtime.cpp.

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

} // namespace pk
