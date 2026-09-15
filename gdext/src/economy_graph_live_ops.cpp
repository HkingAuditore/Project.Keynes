#include "economy_graph_live_ops.h"

#include "economy_graph_stage_dispatch.h"
#include "economy_runtime.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace pk {
namespace {

void copy_error(std::string &error, const char *value) {
    error = value != nullptr ? value : "";
}

void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (uint32_t i = 0; i < 8u; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}

bool read_u64(const uint8_t *&p, const uint8_t *end, uint64_t &out) {
    if (p == nullptr || end == nullptr || static_cast<size_t>(end - p) < 8u)
        return false;
    uint64_t value = 0;
    for (uint32_t i = 0; i < 8u; ++i)
        value |= static_cast<uint64_t>(p[i]) << (i * 8u);
    p += 8u;
    out = value;
    return true;
}

void finish_ok(EconomyStageResult &result, const RuntimeEconomyEpochInput &input,
               NativeEconomyRuntime *runtime) {
    result.work_units = input.cell_count;
    result.state_hash = static_cast<uint64_t>(
        std::max<int64_t>(0, runtime->state_hash()));
    result.ok = true;
}

} // namespace

NativeEconomyGraphStageOps::NativeEconomyGraphStageOps(
        NativeEconomyRuntime *runtime, bool mutate)
    : _runtime(runtime), _mutate(mutate) {}

bool NativeEconomyGraphStageOps::bind_view(EconomySoAView &view,
                                           std::string &error) {
    error.clear();
    if (_runtime == nullptr) {
        copy_error(error, "economy_live_ops_runtime_null");
        return false;
    }
    return _runtime->bind_soa_view(view, error);
}

bool NativeEconomyGraphStageOps::run_stage(
        RuntimeEconomyGraphStage stage, EconomyStageCursor &cursor,
        const RuntimeEconomyEpochInput &input, EconomyStageResult &result,
        std::string &error) {
    result.reset();
    error.clear();
    if (_runtime == nullptr) {
        copy_error(error, "economy_live_ops_runtime_null");
        result.ok = false;
        return false;
    }

    EconomySoAView view;
    if (!bind_view(view, error)) {
        result.ok = false;
        return false;
    }

    // SHADOW / parity path: hash + work only (must match sync stage refs).
    // Production ACTIVE attaches mutate=false and uses worker_run_compact_slice.
    if (!_mutate) {
        finish_ok(result, input, _runtime);
        return true;
    }

    // mutate=true: named kernel TUs are the mutate path (dispatch → formulas).
    switch (stage) {
    case RuntimeEconomyGraphStage::BUILDING_PLAN:
        return economy_dispatch_mutate_stage(view, stage, cursor, input,
                                             result, error);
    case RuntimeEconomyGraphStage::TRADE_SETTLE:
        return economy_kernel_trade_settle(view, cursor, input, result, error);
    case RuntimeEconomyGraphStage::LEDGER_APPLY:
        return economy_kernel_ledger(view, cursor, input, result, error);
    case RuntimeEconomyGraphStage::BUILDING_EMPLOYMENT:
        return economy_kernel_building_employment(view, cursor, input, result,
                                                  error);
    case RuntimeEconomyGraphStage::BUILDING_PRODUCTION:
        return economy_kernel_building_production(view, cursor, input, result,
                                                  error);
    case RuntimeEconomyGraphStage::HOUSEHOLD_MARKET:
        return economy_kernel_household_market(view, cursor, input, result,
                                               error);
    case RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT:
        return economy_kernel_research(view, cursor, input, result, error);
    case RuntimeEconomyGraphStage::TRADE_DISPATCH:
        return economy_kernel_trade_dispatch(view, cursor, input, result,
                                             error);
    case RuntimeEconomyGraphStage::STRUCTURAL_COMMIT:
        return economy_kernel_structural(view, cursor, input, result, error);
    case RuntimeEconomyGraphStage::BUILDING_COMMIT:
        return economy_kernel_building_commit(view, cursor, input, result,
                                              error);
    case RuntimeEconomyGraphStage::FAMILY_COMMIT:
        cursor.evaluate_phase = 0;
        return economy_kernel_family_person(view, cursor, input, result, error);
    case RuntimeEconomyGraphStage::PERSON_COMMIT:
        cursor.evaluate_phase = 1;
        return economy_kernel_family_person(view, cursor, input, result, error);
    case RuntimeEconomyGraphStage::AGGREGATE_PUBLISH:
        return economy_kernel_publish(view, cursor, input, result, error);
    case RuntimeEconomyGraphStage::COUNT:
        break;
    }
    copy_error(error, "economy_live_ops_stage_unknown");
    result.ok = false;
    return false;
}

uint64_t NativeEconomyGraphStageOps::state_hash() const {
    if (_runtime == nullptr) return 0;
    return static_cast<uint64_t>(
        std::max<int64_t>(0, _runtime->state_hash()));
}

bool NativeEconomyGraphStageOps::capture_probe(std::vector<uint8_t> &bytes,
                                               std::string &error) const {
    error.clear();
    bytes.clear();
    if (_runtime == nullptr) {
        copy_error(error, "economy_live_ops_runtime_null");
        return false;
    }
    const uint64_t generation = _runtime->_committed_generation;
    const int64_t committed_day = _runtime->_last_committed_day;
    const uint64_t hash = static_cast<uint64_t>(
        std::max<int64_t>(0, _runtime->state_hash()));
    append_u64(bytes, generation);
    append_u64(bytes, static_cast<uint64_t>(committed_day));
    append_u64(bytes, hash);
    return true;
}

bool NativeEconomyGraphStageOps::restore_probe(const uint8_t *bytes, size_t size,
                                               std::string &error) {
    error.clear();
    if (bytes == nullptr || size != 24u) {
        copy_error(error, "economy_live_ops_probe_truncated");
        return false;
    }
    const uint8_t *p = bytes;
    const uint8_t *end = bytes + size;
    uint64_t generation = 0;
    uint64_t day_bits = 0;
    uint64_t hash = 0;
    if (!read_u64(p, end, generation) || !read_u64(p, end, day_bits) ||
        !read_u64(p, end, hash)) {
        copy_error(error, "economy_live_ops_probe_decode_failed");
        return false;
    }
    int64_t committed_day = 0;
    std::memcpy(&committed_day, &day_bits, sizeof(committed_day));
    _probe_generation = generation;
    _probe_committed_day = committed_day;
    _probe_state_hash = hash;
    if (_mutate && _runtime != nullptr) {
        _runtime->_committed_generation = generation;
        _runtime->_last_committed_day = committed_day;
    }
    return true;
}

} // namespace pk
