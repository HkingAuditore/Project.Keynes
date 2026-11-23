#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

int32_t NativeEconomyRuntime::family_membership_index(
        uint64_t family_handle, uint64_t cohort_handle) const {
    int32_t slot = -1;
    if (population_store().valid_handle(cohort_handle, slot) &&
        _family_cohort_offsets.size() == population_store().active.size() + 1) {
        for (int32_t p = _family_cohort_offsets[slot];
             p < _family_cohort_offsets[slot + 1]; ++p) {
            const int32_t edge_index = _family_cohort_edge_indices[p];
            if (family_memberships()[edge_index].family_handle == family_handle)
                return edge_index;
        }
    }
    ++_scan_calls_membership_fallback;
    for (int32_t i = 0; i < static_cast<int32_t>(family_memberships().size()); ++i)
        if (family_memberships()[i].family_handle == family_handle &&
            family_memberships()[i].cohort_handle == cohort_handle) {
            _scan_steps_membership_fallback += i + 1;
            note_scan_steps(i + 1);
            return i;
        }
    _scan_steps_membership_fallback +=
        static_cast<int64_t>(family_memberships().size());
    note_scan_steps(static_cast<int64_t>(family_memberships().size()));
    return -1;
}

void NativeEconomyRuntime::rebuild_person_indices() {
    const auto needs_started = Clock::now();
    if (!_person_needs_normalized || _person_needs_orphaned ||
        _person_need_offsets.size() != persons_store().active.size() + 1)
        normalize_person_needs();
    _rebuild_person_needs_ms += elapsed_ms(needs_started);
    const auto count_started = Clock::now();
    const size_t person_slots = persons_store().active.size();
    _person_family_offsets.assign(families_store().active.size() + 1, 0);
    _person_cohort_offsets.assign(population_store().active.size() + 1, 0);
    _person_cell_offsets.assign(static_cast<size_t>(_cell_count.get()) + 1, 0);
    _person_building_offsets.assign(building_count() + 1, 0);
    auto &building_index = _person_index_building_scratch;
    building_index.assign(person_slots, -1);
    for (int32_t i = 0; i < static_cast<int32_t>(person_slots); ++i) {
        if (persons_store().active[i] == 0) continue;
        int32_t family = -1, slot = -1;
        if (families_store().valid_handle(persons_store().family_handle[i], family))
            ++_person_family_offsets[static_cast<size_t>(family) + 1];
        if (population_store().valid_handle(persons_store().cohort_handle[i], slot)) {
            ++_person_cohort_offsets[static_cast<size_t>(slot) + 1];
            const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            if (cell >= 0 && cell < _cell_count.get())
                ++_person_cell_offsets[static_cast<size_t>(cell) + 1];
        }
        const int32_t building = building_index_for_handle(
            persons_store().building_handle[i]);
        building_index[i] = building;
        if (building >= 0)
            ++_person_building_offsets[static_cast<size_t>(building) + 1];
    }
    const auto prefix = [](std::vector<int32_t> &offsets) {
        for (size_t i = 0; i + 1 < offsets.size(); ++i)
            offsets[i + 1] += offsets[i];
    };
    prefix(_person_family_offsets); prefix(_person_cohort_offsets);
    prefix(_person_cell_offsets); prefix(_person_building_offsets);
    _rebuild_person_count_ms += elapsed_ms(count_started);
    const auto fill_started = Clock::now();
    _person_family_indices.assign(persons_store().active_count, -1);
    _person_cohort_indices.assign(persons_store().active_count, -1);
    _person_cell_indices.assign(persons_store().active_count, -1);
    _person_building_indices.assign(persons_store().active_count, -1);
    auto &fc = _person_index_family_scratch;
    fc.assign(_person_family_offsets.begin(),
        _person_family_offsets.empty() ? _person_family_offsets.end()
            : _person_family_offsets.end() - 1);
    auto &cc = _person_index_cohort_scratch;
    cc.assign(_person_cohort_offsets.begin(),
        _person_cohort_offsets.empty() ? _person_cohort_offsets.end()
            : _person_cohort_offsets.end() - 1);
    auto &xc = _person_index_cell_scratch;
    xc.assign(_person_cell_offsets.begin(),
        _person_cell_offsets.empty() ? _person_cell_offsets.end()
            : _person_cell_offsets.end() - 1);
    auto &bc = _person_index_building_cursor_scratch;
    bc.assign(_person_building_offsets.begin(),
        _person_building_offsets.empty() ? _person_building_offsets.end()
            : _person_building_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(person_slots); ++i) {
        if (persons_store().active[i] == 0) continue;
        int32_t family = -1, slot = -1;
        if (families_store().valid_handle(persons_store().family_handle[i], family))
            _person_family_indices[fc[family]++] = i;
        if (population_store().valid_handle(persons_store().cohort_handle[i], slot)) {
            _person_cohort_indices[cc[slot]++] = i;
            const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            if (cell >= 0 && cell < _cell_count.get())
                _person_cell_indices[xc[cell]++] = i;
        }
        if (building_index[i] >= 0)
            _person_building_indices[bc[building_index[i]]++] = i;
    }
    _rebuild_person_fill_ms += elapsed_ms(fill_started);
    const auto sort_started = Clock::now();
    const auto by_stable = [&](int32_t a, int32_t b) {
        return std::tie(persons_store().stable_id[a], a) <
            std::tie(persons_store().stable_id[b], b);
    };
    // Most buckets hold zero or one person, so the size guard removes tens of
    // thousands of std::sort calls that could never reorder anything.
    for (int32_t family = 0; family + 1 < static_cast<int32_t>(
            _person_family_offsets.size()); ++family)
        if (_person_family_offsets[family + 1] - _person_family_offsets[family] > 1)
            std::sort(_person_family_indices.begin() + _person_family_offsets[family],
                      _person_family_indices.begin() + _person_family_offsets[family + 1],
                      by_stable);
    for (int32_t slot = 0; slot + 1 < static_cast<int32_t>(
            _person_cohort_offsets.size()); ++slot)
        if (_person_cohort_offsets[slot + 1] - _person_cohort_offsets[slot] > 1)
            std::sort(_person_cohort_indices.begin() + _person_cohort_offsets[slot],
                      _person_cohort_indices.begin() + _person_cohort_offsets[slot + 1],
                      by_stable);
    _rebuild_person_sort_ms += elapsed_ms(sort_started);
    _person_cohort_migrations.clear();
    _person_family_migrations.clear();
    _person_indices_dirty = false;
}

void NativeEconomyRuntime::normalize_person_needs() {
    const size_t person_slots = persons_store().active.size();
    _person_need_owner_scratch.clear();
    _person_need_owner_scratch.reserve(person_needs().size());
    size_t kept = 0;
    for (size_t i = 0; i < person_needs().size(); ++i) {
        const PersonNeedState state = person_needs()[i];
        int32_t person = -1;
        if (!persons_store().valid_handle(state.person_handle, person) ||
            state.stable_need_id < 0 ||
            state.stable_need_id >= static_cast<int32_t>(_need_ids.size()))
            continue;
        if (kept != i) person_needs().write_record(kept, state, market_mutation_sink());
        _person_need_owner_scratch.push_back(person);
        ++kept;
    }
    person_needs().resize(kept);

    _person_need_offsets.assign(person_slots + 1, 0);
    for (const int32_t owner : _person_need_owner_scratch)
        ++_person_need_offsets[static_cast<size_t>(owner) + 1];
    for (size_t i = 0; i + 1 < _person_need_offsets.size(); ++i)
        _person_need_offsets[i + 1] += _person_need_offsets[i];
    _person_need_scratch.resize(kept);
    _person_need_cursor_scratch.assign(_person_need_offsets.begin(),
                                       _person_need_offsets.end() - 1);
    for (size_t i = 0; i < kept; ++i)
        _person_need_scratch[static_cast<size_t>(
            _person_need_cursor_scratch[_person_need_owner_scratch[i]]++)] =
            person_needs()[i];
    person_needs().swap(_person_need_scratch);

    // Each slot holds only a handful of rows, so ordering inside a block and
    // dropping duplicates is cheap. Compaction always moves left, so the write
    // cursor can never overtake the block being read.
    size_t write = 0;
    for (size_t p = 0; p < person_slots; ++p) {
        const size_t begin = static_cast<size_t>(_person_need_offsets[p]);
        const size_t end = static_cast<size_t>(_person_need_offsets[p + 1]);
        const size_t block_start = write;
        _person_need_offsets[p] = static_cast<int32_t>(write);
        if (end - begin > 1)
            person_needs().sort_range(begin, end - begin,
                [](const PersonNeedState &a, const PersonNeedState &b) {
                    return a.stable_need_id < b.stable_need_id;
                });
        for (size_t i = begin; i < end; ++i) {
            if (write > block_start && person_needs()[write - 1].stable_need_id ==
                    person_needs()[i].stable_need_id) continue;
            if (write != i) person_needs().write_record(write, person_needs()[i], market_mutation_sink());
            ++write;
        }
    }
    person_needs().resize(write);
    _person_need_offsets[person_slots] = static_cast<int32_t>(write);
    _person_needs_orphaned = false;
    _person_needs_normalized = true;
}

void NativeEconomyRuntime::compact_person_needs() {
    if (!_person_needs_orphaned && _person_needs_normalized &&
        _person_need_offsets.size() == persons_store().active.size() + 1) return;
    normalize_person_needs();
}

void NativeEconomyRuntime::review_person_promotions() {
    if (_person_runtime_mode.get() != 2) return;
    for (int32_t family = 0; family < static_cast<int32_t>(
            families_store().active.size()); ++family) {
        if (families_store().active[family] == 0) continue;
        const int32_t count = _person_family_offsets.size() ==
                families_store().active.size() + 1
            ? _person_family_offsets[family + 1] - _person_family_offsets[family] : 0;
        const int64_t phase = (families_store().stable_id[family] % _family_review_days.get() +
            _family_review_days.get()) % _family_review_days.get();
        const bool due = ((_current_day.get() % _family_review_days.get() +
            _family_review_days.get()) % _family_review_days.get()) == phase;
        if (count == 0 || due) promote_person_for_family(family);
    }
}

void NativeEconomyRuntime::update_person_equity_shares() {
    persons_store().family_equity_share_q32.fill_range(0,
        persons_store().family_equity_share_q32.size(), 0, market_mutation_sink());
    for (int32_t family = 0; family < static_cast<int32_t>(
            families_store().active.size()); ++family) {
        if (families_store().active[family] == 0) continue;
        int64_t total_filled = 0;
        for (int32_t p = _family_owned_offsets[family];
             p < _family_owned_offsets[family + 1]; ++p)
            total_filled += std::max<int64_t>(0,
                family_ownerships().read_at(_family_owned_edge_indices[p], __FILE__, __LINE__).filled_owner);
        if (total_filled <= 0) continue;
        for (int32_t p = _person_family_offsets[family];
             p < _person_family_offsets[family + 1]; ++p) {
            const int32_t person = _person_family_indices[p];
            if (persons_store().job_kind[person] == 1)
                persons_store().family_equity_share_q32.write_scalar(person, Q32_ONE / total_filled, market_mutation_sink());
        }
    }
}

bool NativeEconomyRuntime::run_person_commit_slice(int64_t &work_done,
                                                    std::string &error) {
    error.clear();
    // Phase-2.4.3.3 fail-closed: do not start person while family is pending.
    if (_stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT) {
        error = "person_commit_prior_incomplete";
        return false;
    }
    if (_stage != Stage::PERSON_COMMIT) {
        return true;
    }
    if (_person_commit_phase == 0) {
        _person_retire_call_ms = 0.0;
        _person_retire_calls = 0;
        _person_commit_retire_ms = 0.0;
        _person_commit_index_ms = 0.0;
        _person_commit_bind_jobs_ms = 0.0;
        _person_commit_claims_ms = 0.0;
        _person_commit_equity_ms = 0.0;
        _person_commit_promote_ms = 0.0;
        _rebuild_person_needs_ms = 0.0;
        _rebuild_person_count_ms = 0.0;
        _rebuild_person_fill_ms = 0.0;
        _rebuild_person_sort_ms = 0.0;
        _rebuild_person_needoffsets_ms = 0.0;
        if (_person_runtime_mode.get() == 0 && persons_store().active_count == 0) {
            _stage = Stage::AGGREGATE_PUBLISH; ++work_done; return true;
        }
        {
            EconomyCostProbe probe("person.epoch_swap", _current_day.get(),
                _person_epoch_needs.size());
            person_needs().swap(_person_epoch_needs);
            _person_epoch_needs.clear();
        }
        _person_needs_normalized = false;
        _person_commit_cursor = 0;
        _person_commit_phase = 1;
        ++work_done;
        return true;
    }
    if (_person_commit_phase == 1) {
        // Family dissolution and invalid structural references retire the
        // overlay only; they never remove aggregate population.
        const auto retire_started = Clock::now();
        const int32_t begin = _person_commit_cursor;
        const int32_t end = std::min<int32_t>(persons_store().active.size(),
            begin + _person_records_per_slice.get());
        for (; _person_commit_cursor < end; ++_person_commit_cursor) {
            const int32_t i = _person_commit_cursor;
            if (persons_store().active[i] == 0) continue;
            register_person_effect(i);
            int32_t family = -1, slot = -1;
            if (!families_store().valid_handle(persons_store().family_handle[i], family) ||
                !population_store().valid_handle(persons_store().cohort_handle[i], slot) ||
                family_membership_index(persons_store().family_handle[i],
                    persons_store().cohort_handle[i]) < 0) retire_person(i);
        }
        work_done += end - begin;
        _person_commit_retire_ms += elapsed_ms(retire_started);
        if (_person_commit_cursor < static_cast<int32_t>(persons_store().active.size()))
            return true;
        const auto index_started = Clock::now();
        rebuild_person_indices();
        _person_commit_index_ms += elapsed_ms(index_started);
        const auto bind_started = Clock::now();
        bind_notable_person_jobs();
        _person_commit_bind_jobs_ms += elapsed_ms(bind_started);
        _person_commit_cursor = 0;
        _person_commit_phase = 2;
        ++work_done;
        return true;
    }
    if (_person_commit_phase == 2) {
        const auto claims_started = Clock::now();
        reconcile_person_claims();
        _person_commit_claims_ms += elapsed_ms(claims_started);
        const auto equity_started = Clock::now();
        update_person_equity_shares();
        _person_commit_equity_ms += elapsed_ms(equity_started);
        _person_commit_cursor = 0;
        _person_commit_phase = 3;
        ++work_done;
        return true;
    }
    if (_person_commit_phase == 3) {
        const auto promote_started = Clock::now();
        const int32_t begin = _person_commit_cursor;
        const int32_t end = std::min<int32_t>(families_store().active.size(),
            begin + _person_records_per_slice.get());
        if (_person_runtime_mode.get() == 2) {
            for (; _person_commit_cursor < end; ++_person_commit_cursor) {
                const int32_t family = _person_commit_cursor;
                if (families_store().active[family] == 0) continue;
                const int32_t count = _person_family_offsets.size() ==
                        families_store().active.size() + 1
                    ? _person_family_offsets[family + 1] -
                        _person_family_offsets[family] : 0;
                const int64_t phase = (families_store().stable_id[family] %
                    _family_review_days.get() + _family_review_days.get()) %
                    _family_review_days.get();
                const bool due = ((_current_day.get() % _family_review_days.get() +
                    _family_review_days.get()) % _family_review_days.get()) == phase;
                if (count == 0 || due) promote_person_for_family(family);
            }
        } else {
            _person_commit_cursor = end;
        }
        work_done += end - begin;
        _person_commit_promote_ms += elapsed_ms(promote_started);
        if (_person_commit_cursor < static_cast<int32_t>(families_store().active.size()))
            return true;
        _person_commit_phase = 4;
        return true;
    }
    const auto final_index_started = Clock::now();
    // Phase 3 only dirties the indices when it actually promoted someone, so
    // most epochs can keep the CSR that phase 1 already built.
    if (_person_indices_dirty || _person_needs_orphaned) rebuild_person_indices();
    _person_commit_index_ms += elapsed_ms(final_index_started);
    _person_need_edges_processed += static_cast<int64_t>(person_needs().size());
    _person_commit_phase = 0; _person_commit_cursor = 0;
    _stage = Stage::AGGREGATE_PUBLISH; ++work_done;
    return true;
}

bool NativeEconomyRuntime::run_person_commit_drain(int64_t &work_done,
                                                    std::string &error) {
    struct DiagGuard { NativeEconomyRuntime *r; ~DiagGuard() { r->diag_stage_money_probe("person_commit"); } } diag_guard{this};
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT) {
        error = "person_commit_prior_incomplete";
        return false;
    }
    if (_stage != Stage::PERSON_COMMIT) {
        return true;
    }
    constexpr int kMaxPhaseChunks = 1 << 20;
    for (int guard = 0;
         guard < kMaxPhaseChunks && _stage == Stage::PERSON_COMMIT && !_fatal;
         ++guard) {
        if (!run_person_commit_slice(work_done, error)) {
            return false;
        }
    }
    if (_fatal) {
        error = error.empty() ? "person_commit_fatal" : error;
        return false;
    }
    if (_stage == Stage::PERSON_COMMIT) {
        error = "person_commit_phase_guard_exhausted";
        fail(error);
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::run_aggregate_publish_drain(int64_t &work_done,
                                                       std::string &error) {
    diag_stage_money_probe("publish_entry");
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT ||
        _stage == Stage::PERSON_COMMIT) {
        error = "aggregate_publish_prior_incomplete";
        return false;
    }
    if (_stage != Stage::AGGREGATE_PUBLISH) {
        return true;
    }
    constexpr int kMaxPhaseChunks = 1 << 20;
    for (int guard = 0; guard < kMaxPhaseChunks && _epoch_active && !_fatal &&
                        _stage == Stage::AGGREGATE_PUBLISH;
         ++guard) {
        if (!publish_epoch_slice(work_done, error)) {
            fail(error.empty() ? "aggregate_publish_failed" : error);
            return false;
        }
    }
    if (_fatal) {
        error = error.empty() ? "aggregate_publish_fatal" : error;
        return false;
    }
    if (_epoch_active && _stage == Stage::AGGREGATE_PUBLISH) {
        error = "aggregate_publish_phase_guard_exhausted";
        fail(error);
        return false;
    }
    return true;
}

void NativeEconomyRuntime::move_notable_people(
        uint64_t source_cohort_handle, uint64_t destination_cohort_handle,
        uint64_t family_handle, int64_t family_people_before,
        int64_t moved_family_people) {
    if (_person_runtime_mode.get() != 2 || moved_family_people <= 0 ||
        family_people_before <= 0) return;
    const size_t person_slots = persons_store().active.size();
    if (_person_candidate_stamp.size() < person_slots)
        _person_candidate_stamp.resize(person_slots, 0);
    if (++_person_candidate_generation == 0) {
        std::fill(_person_candidate_stamp.begin(),
                  _person_candidate_stamp.end(), 0);
        _person_candidate_generation = 1;
    }
    std::vector<int32_t> candidates;
    const auto consider = [&](int32_t i) {
        if (i < 0 || i >= static_cast<int32_t>(person_slots)) return;
        if (persons_store().active[i] == 0 ||
            persons_store().cohort_handle[i] != source_cohort_handle ||
            persons_store().family_handle[i] != family_handle) return;
        if (_person_candidate_stamp[static_cast<size_t>(i)] ==
            _person_candidate_generation) return;
        _person_candidate_stamp[static_cast<size_t>(i)] =
            _person_candidate_generation;
        candidates.push_back(i);
    };
    int32_t source_slot = -1;
    // The population store keeps allocating slots mid-epoch, so the CSR is
    // routinely shorter than the slot table. A slot past its end simply has no
    // indexed persons; anything that reached the cohort since the last rebuild
    // is in the migration map either way.
    if (population_store().valid_handle(source_cohort_handle, source_slot)) {
        const int32_t indexed_slots =
            static_cast<int32_t>(_person_cohort_offsets.size()) - 1;
        if (source_slot < indexed_slots) {
            const int32_t begin = _person_cohort_offsets[source_slot];
            const int32_t end = _person_cohort_offsets[source_slot + 1];
            _scan_steps_person_linear += end - begin;
            note_scan_steps(end - begin);
            for (int32_t p = begin; p < end; ++p)
                consider(_person_cohort_indices[p]);
        }
        const auto migrated = _person_cohort_migrations.find(source_cohort_handle);
        if (migrated != _person_cohort_migrations.end()) {
            _scan_steps_person_linear +=
                static_cast<int64_t>(migrated->second.size());
            note_scan_steps(static_cast<int64_t>(migrated->second.size()));
            for (const int32_t person : migrated->second) consider(person);
        }
    } else {
        _scan_steps_person_linear += static_cast<int64_t>(person_slots);
        note_scan_steps(static_cast<int64_t>(person_slots));
        for (int32_t i = 0; i < static_cast<int32_t>(person_slots); ++i)
            consider(i);
    }
    std::sort(candidates.begin(), candidates.end(), [&](int32_t a, int32_t b) {
        return std::tie(persons_store().stable_id[a], a) <
            std::tie(persons_store().stable_id[b], b);
    });
    int64_t remaining_people = family_people_before;
    int64_t remaining_moved = std::min(moved_family_people, family_people_before);
    for (int32_t person : candidates) {
        if (remaining_people <= 0 || remaining_moved <= 0) break;
        uint64_t hash = 1469598103934665603ULL;
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_epoch_id.get()));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(persons_store().stable_id[person]));
        hash = trace_hash_mix(hash, destination_cohort_handle);
        if (static_cast<int64_t>(hash % static_cast<uint64_t>(remaining_people)) <
                remaining_moved) {
            persons_store().cohort_handle.write_scalar(person, destination_cohort_handle, market_mutation_sink());
            _person_cohort_migrations[destination_cohort_handle].push_back(person);
            persons_store().building_handle.write_scalar(person, 0, market_mutation_sink());
            persons_store().job_kind.write_scalar(person, 0, market_mutation_sink());
            persons_store().employee_role_index.write_scalar(person, -1, market_mutation_sink());
            --remaining_moved; ++_persons_migrated;
        }
        --remaining_people;
    }
    _person_indices_dirty = true;
}

void NativeEconomyRuntime::record_person_demography(
        int32_t cohort_slot, int64_t population_before, int64_t deaths) {
    if (_person_runtime_mode.get() != 2 || deaths <= 0 || population_before <= 0 ||
        cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            population_store().active.size()) ||
        _person_cohort_offsets.size() != population_store().active.size() + 1) return;
    std::vector<int32_t> candidates;
    for (int32_t p = _person_cohort_offsets[cohort_slot];
         p < _person_cohort_offsets[cohort_slot + 1]; ++p) {
        const int32_t person = _person_cohort_indices[p];
        if (persons_store().active[person] != 0) candidates.push_back(person);
    }
    std::sort(candidates.begin(), candidates.end(), [&](int32_t a, int32_t b) {
        return std::tie(persons_store().stable_id[a], a) <
            std::tie(persons_store().stable_id[b], b);
    });
    int64_t remaining_population = population_before;
    int64_t remaining_deaths = std::min(deaths, population_before);
    for (int32_t person : candidates) {
        if (remaining_population <= 0 || remaining_deaths <= 0) break;
        uint64_t hash = 1469598103934665603ULL;
        hash = trace_hash_mix(hash, 0x504445415448ULL); // "PDEATH"
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_epoch_id.get()));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(persons_store().stable_id[person]));
        if (static_cast<int64_t>(hash % static_cast<uint64_t>(remaining_population)) <
                remaining_deaths) {
            retire_person(person);
            --remaining_deaths; ++_persons_died;
        }
        --remaining_population;
    }
}

const char *NativeEconomyRuntime::stage_name() const {
    return stage_name(_stage);
}

const char *NativeEconomyRuntime::stage_name(Stage stage) const {
    switch (stage) {
        case Stage::IDLE: return "idle";
        case Stage::EPOCH_BEGIN: return "epoch_begin";
        case Stage::LEDGER_APPLY: return "ledger_apply";
        case Stage::HOUSEHOLD_MARKET: return "household_market";
        case Stage::STRUCTURAL_COMMIT: return "structural_commit";
        case Stage::WAIT_COMMIT: return "wait_commit";
        case Stage::BUILDING_EMPLOYMENT: return "building_employment";
        case Stage::BUILDING_PRODUCTION: return "building_production";
        case Stage::BUILDING_COMMIT: return "building_commit";
        case Stage::AGGREGATE_PUBLISH: return "aggregate_publish";
        case Stage::FATAL: return "fatal";
        case Stage::TRADE_SETTLE: return "trade_settle";
        case Stage::TRADE_DISPATCH: return "trade_dispatch";
        case Stage::TRADE_PLANNING: return "trade_planning";
        case Stage::BUILDING_PLAN: return "building_plan";
        case Stage::GOVERNMENT_RESEARCH_PROCUREMENT:
            return "government_research_procurement";
        case Stage::FAMILY_COMMIT: return "family_commit";
        case Stage::PERSON_COMMIT: return "person_commit";
        case Stage::FISCAL_SETTLEMENT: return "fiscal_settlement";
    }
    return "unknown";
}

const char *NativeEconomyRuntime::publish_phase_name(PublishPhase phase) const {
    switch (phase) {
        case PublishPhase::PREPARE: return "prepare";
        case PublishPhase::AUDIT_POPULATION: return "audit_population";
        case PublishPhase::AUDIT_MARKET: return "audit_market";
        case PublishPhase::AUDIT_TRANSIT: return "audit_transit";
        case PublishPhase::AUDIT_ESCROW: return "audit_escrow";
        case PublishPhase::AUDIT_COUNTRY: return "audit_country";
        case PublishPhase::VERIFY: return "verify";
        case PublishPhase::WATERMARK: return "watermark";
        case PublishPhase::TRADE_FLOW: return "trade_flow";
        case PublishPhase::TRADE_DIAGNOSTICS: return "trade_diagnostics";
        case PublishPhase::TRADE_INIT: return "trade_init";
        case PublishPhase::COMMIT: return "commit";
        case PublishPhase::DONE: return "done";
        case PublishPhase::COUNT: break;
    }
    return "unknown";
}

const char *NativeEconomyRuntime::trade_plan_init_phase_name(
        TradePlanInitPhase phase) const {
    switch (phase) {
        case TradePlanInitPhase::IDLE: return "idle";
        case TradePlanInitPhase::COMPONENT_PREPARE: return "component_prepare";
        case TradePlanInitPhase::COMPONENT_CLEAR: return "component_clear";
        case TradePlanInitPhase::COMPONENT_BUILD: return "component_build";
        case TradePlanInitPhase::PREPARE: return "prepare";
        case TradePlanInitPhase::INFLIGHT_BUILD: return "inflight_build";
        case TradePlanInitPhase::INFLIGHT_SORT: return "inflight_sort";
        case TradePlanInitPhase::PRUNE: return "prune";
        case TradePlanInitPhase::INBOUND_BUILD: return "inbound_build";
        case TradePlanInitPhase::ROTATE: return "rotate";
        case TradePlanInitPhase::WORKSPACE_CLEAR: return "workspace_clear";
        case TradePlanInitPhase::FINALIZE: return "finalize";
        case TradePlanInitPhase::DONE: return "done";
    }
    return "unknown";
}


Dictionary NativeEconomyRuntime::production_climate_math_probe(
        const Dictionary &vectors) const {
    Dictionary out;
    const std::vector<int32_t> temperature = packed_i32(vectors, "temperature_q16");
    const std::vector<int32_t> temperature_opt = packed_i32(
        vectors, "temperature_opt_q16");
    const std::vector<int32_t> temperature_tolerance = packed_i32(
        vectors, "temperature_tolerance_q16");
    const std::vector<int32_t> water = packed_i32(vectors, "water_q16");
    const std::vector<int32_t> water_opt = packed_i32(vectors, "water_opt_q16");
    const std::vector<int32_t> water_tolerance = packed_i32(
        vectors, "water_tolerance_q16");
    const std::vector<int32_t> exposure = packed_i32(vectors, "exposure_q16");
    const std::vector<int32_t> floor = packed_i32(vectors, "floor_q16");
    const std::vector<int32_t> enabled = packed_i32(vectors, "enabled");
    const size_t count = temperature.size();
    if (temperature_opt.size() != count || temperature_tolerance.size() != count ||
        water.size() != count || water_opt.size() != count ||
        water_tolerance.size() != count || exposure.size() != count ||
        floor.size() != count || (!enabled.empty() && enabled.size() != count)) {
        out["ok"] = false;
        out["reason"] = "production_climate_math_vector_size_mismatch";
        return out;
    }
    PackedInt64Array temperature_fit;
    PackedInt64Array water_fit;
    PackedInt64Array capacity;
    temperature_fit.resize(static_cast<int64_t>(count));
    water_fit.resize(static_cast<int64_t>(count));
    capacity.resize(static_cast<int64_t>(count));
    int64_t saturation_count = 0;
    for (size_t i = 0; i < count; ++i) {
        if (temperature[i] < 0 || temperature[i] > Q16_ONE ||
            temperature_opt[i] < 0 || temperature_opt[i] > Q16_ONE ||
            temperature_tolerance[i] <= 0 || temperature_tolerance[i] > Q16_ONE ||
            water[i] < 0 || water[i] > Q16_ONE ||
            water_opt[i] < 0 || water_opt[i] > Q16_ONE ||
            water_tolerance[i] <= 0 || water_tolerance[i] > Q16_ONE ||
            exposure[i] < 0 || exposure[i] > Q16_ONE ||
            floor[i] < 0 || floor[i] > Q16_ONE) {
            out["ok"] = false;
            out["reason"] = "production_climate_math_vector_invalid";
            return out;
        }
        if (!enabled.empty() && enabled[i] == 0) {
            temperature_fit.set(static_cast<int64_t>(i), Q16_ONE);
            water_fit.set(static_cast<int64_t>(i), Q16_ONE);
            capacity.set(static_cast<int64_t>(i), Q16_ONE);
            continue;
        }
        const int64_t temp_delta = std::llabs(
            static_cast<int64_t>(temperature[i]) - temperature_opt[i]);
        const int64_t water_delta = std::llabs(
            static_cast<int64_t>(water[i]) - water_opt[i]);
        const int64_t temp_fit = std::clamp<int64_t>(Q16_ONE - mul_div_sat(
            temp_delta, Q16_ONE, temperature_tolerance[i], saturation_count),
            0, Q16_ONE);
        const int64_t moist_fit = std::clamp<int64_t>(Q16_ONE - mul_div_sat(
            water_delta, Q16_ONE, water_tolerance[i], saturation_count),
            0, Q16_ONE);
        const int64_t raw = std::min(temp_fit, moist_fit);
        const int64_t bounded = std::max<int64_t>(floor[i], raw);
        const int64_t climate_capacity = std::clamp<int64_t>(
            Q16_ONE - mul_div_sat(exposure[i], Q16_ONE - bounded,
                Q16_ONE, saturation_count), 0, Q16_ONE);
        temperature_fit.set(static_cast<int64_t>(i), temp_fit);
        water_fit.set(static_cast<int64_t>(i), moist_fit);
        capacity.set(static_cast<int64_t>(i), climate_capacity);
    }
    out["ok"] = true;
    out["temperature_fit_q16"] = temperature_fit;
    out["water_fit_q16"] = water_fit;
    out["capacity_q16"] = capacity;
    out["saturation_count"] = saturation_count;
    return out;
}

} // namespace pk
