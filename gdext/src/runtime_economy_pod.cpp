#include "economy_cost_probe.h"
#include "runtime_economy_pod.h"
#include "economy_hash.h"
#include "economy_runtime.h"
#include "runtime_economy_ecp2.h"
#include "runtime_economy_population_store.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <limits>

namespace pk {
namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

void copy_reason(char *dst, size_t capacity, const char *reason) {
    if (capacity == 0) return;
    size_t i = 0;
    if (reason != nullptr) {
        for (; i + 1 < capacity && reason[i] != '\0'; ++i) dst[i] = reason[i];
    }
    dst[i] = '\0';
}

double elapsed_ms(std::chrono::steady_clock::time_point begin) {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
}

void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xffu));
}

void append_u16(std::vector<uint8_t> &out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xffu));
}

void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (8 * i)) & 0xffu));
}

void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u64(out, static_cast<uint64_t>(value));
}

void append_i32(std::vector<uint8_t> &out, int32_t value) {
    append_u32(out, static_cast<uint32_t>(value));
}

bool read_u32(const uint8_t *&p, const uint8_t *end, uint32_t &value) {
    if (end - p < 4) return false;
    value = static_cast<uint32_t>(p[0]) |
        (static_cast<uint32_t>(p[1]) << 8) |
        (static_cast<uint32_t>(p[2]) << 16) |
        (static_cast<uint32_t>(p[3]) << 24);
    p += 4;
    return true;
}

bool read_u16(const uint8_t *&p, const uint8_t *end, uint16_t &value) {
    if (end - p < 2) return false;
    value = static_cast<uint16_t>(p[0]) |
        (static_cast<uint16_t>(p[1]) << 8);
    p += 2;
    return true;
}

bool read_u64(const uint8_t *&p, const uint8_t *end, uint64_t &value) {
    if (end - p < 8) return false;
    value = 0;
    for (int i = 0; i < 8; ++i)
        value |= static_cast<uint64_t>(p[i]) << (8 * i);
    p += 8;
    return true;
}

bool read_i64(const uint8_t *&p, const uint8_t *end, int64_t &value) {
    uint64_t raw = 0;
    if (!read_u64(p, end, raw)) return false;
    value = static_cast<int64_t>(raw);
    return true;
}

bool read_i32(const uint8_t *&p, const uint8_t *end, int32_t &value) {
    uint32_t raw = 0;
    if (!read_u32(p, end, raw)) return false;
    value = static_cast<int32_t>(raw);
    return true;
}

constexpr int64_t Q16_ONE = 65536;

int32_t find_owned_building_group(const RuntimeEconomyBuildingStore &store,
                                  int32_t cell, int32_t type_id,
                                  int32_t signature) {
    for (size_t i = 0; i < store.cell.size(); ++i) {
        if (store.cell[i] == cell && store.type_id[i] == type_id &&
            store.owner_signature_id[i] == signature)
            return static_cast<int32_t>(i);
    }
    return -1;
}

bool owned_valid_family_handle(const RuntimeEconomyFamilyStore &store,
                               uint64_t handle, int32_t &index_out) {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= store.family_active.size() || store.family_active[index] == 0 ||
        store.family_generation[index] != gen)
        return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

bool owned_valid_influence_handle(const RuntimeEconomyFamilyStore &store,
                                  uint64_t handle, int32_t &index_out) {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= store.influence_active.size() ||
        store.influence_active[index] == 0 ||
        store.influence_generation[index] != gen)
        return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

void apply_owned_family_split_policy_flags(RuntimeEconomyFamilyStore &families,
                                           int32_t family_index, uint16_t policy,
                                           uint8_t weight_q8) {
    if (family_index < 0 ||
        family_index >= static_cast<int32_t>(families.family_flags.size()) ||
        family_index >= static_cast<int32_t>(families.family_active.size()) ||
        families.family_active[static_cast<size_t>(family_index)] == 0)
        return;
    uint16_t flags =
        families.family_flags[static_cast<size_t>(family_index)];
    flags &= static_cast<uint16_t>(
        ~(NativeEconomyRuntime::FAMILY_FLAG_SPLIT_POLICY_MASK |
          (0xFFu << NativeEconomyRuntime::FAMILY_FLAG_SPLIT_WEIGHT_SHIFT)));
    const uint16_t selected =
        policy & NativeEconomyRuntime::FAMILY_FLAG_SPLIT_POLICY_MASK;
    const uint16_t mode =
        selected & NativeEconomyRuntime::FAMILY_FLAG_SPLIT_MODE_MASK;
    const uint16_t gifts =
        selected & (NativeEconomyRuntime::FAMILY_FLAG_SPLIT_GIFT_BUILDING |
                    NativeEconomyRuntime::FAMILY_FLAG_SPLIT_GIFT_POPULATION);
    if (mode == NativeEconomyRuntime::FAMILY_FLAG_SPLIT_RETAIN_ONLY ||
        mode == NativeEconomyRuntime::FAMILY_FLAG_SPLIT_BONUS_WEIGHT ||
        mode == NativeEconomyRuntime::FAMILY_FLAG_SPLIT_REPLACE)
        flags |= mode;
    if (mode == NativeEconomyRuntime::FAMILY_FLAG_SPLIT_BONUS_WEIGHT)
        flags |= static_cast<uint16_t>(weight_q8)
                 << NativeEconomyRuntime::FAMILY_FLAG_SPLIT_WEIGHT_SHIFT;
    flags |= gifts;
    families.family_flags[static_cast<size_t>(family_index)] = flags;
}

void ensure_owned_family_purchase_factors(RuntimeEconomyFamilyStore &families) {
    const size_t n = families.family_active.size();
    if (families.purchase_factor_q16.size() < n)
        families.purchase_factor_q16.resize(n, static_cast<int32_t>(Q16_ONE));
}

uint64_t fnv1a(const uint8_t *data, size_t size) noexcept {
    uint64_t hash = FNV_OFFSET;
    for (size_t i = 0; i < size; ++i) {
        hash ^= data[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

bool build_owned_state_from_ledger(const RuntimeEconomyLedgerState &ledger,
                                   RuntimeEconomyOwnedState &restored,
                                   std::string &error) {
    if (!ledger.valid()) {
        error = ledger.ledger_hash != 0 && ledger.computed_hash() != ledger.ledger_hash
            ? "economy_pod_ledger_hash_invalid" : "economy_pod_ledger_shape_invalid";
        return false;
    }
    if (ledger.market_count <= 0 || ledger.good_count <= 0) {
        error = "economy_pod_ledger_dimensions_invalid";
        return false;
    }
    if (ledger.ledger_hash == 0) {
        error = "economy_pod_ledger_hash_invalid";
        return false;
    }

    const size_t lanes = ledger.cohort_active.size();
    constexpr size_t page_size =
        static_cast<size_t>(RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE);
    if (lanes > static_cast<size_t>(std::numeric_limits<int32_t>::max()) ||
        lanes % page_size != 0) {
        error = "economy_pod_population_page_shape_invalid";
        return false;
    }
    for (size_t slot = 0; slot < lanes; ++slot) {
        if (ledger.cohort_active[slot] > 1) {
            error = "economy_pod_population_active_invalid";
            return false;
        }
        if (ledger.cohort_slot[slot] != static_cast<int32_t>(slot)) {
            error = "economy_pod_population_slot_order_invalid";
            return false;
        }
    }

    const size_t page_count = lanes / page_size;
    for (size_t page = 0; page < page_count; ++page) {
        const size_t base = page * page_size;
        const int32_t cell = ledger.cohort_cell[base];
        if (cell < -1 || cell >= ledger.market_count) {
            error = "economy_pod_population_page_cell_invalid";
            return false;
        }
        for (size_t lane = 0; lane < page_size; ++lane) {
            const size_t slot = base + lane;
            if (ledger.cohort_cell[slot] != cell) {
                error = "economy_pod_population_page_cell_mismatch";
                return false;
            }
            if (cell < 0 && ledger.cohort_active[slot] != 0) {
                error = "economy_pod_population_free_page_active";
                return false;
            }
        }
    }

    RuntimeEconomyOwnedState candidate;
    candidate.clear(ledger.market_count, ledger.good_count);
    for (size_t page = 0; page < page_count; ++page) {
        const int32_t cell = ledger.cohort_cell[page * page_size];
        if (!candidate.population.restore_page_at(
                static_cast<int32_t>(page), cell)) {
            error = "economy_pod_population_page_restore_failed";
            return false;
        }
    }

    int64_t active_count = 0;
    for (size_t slot = 0; slot < lanes; ++slot) {
        if (ledger.cohort_active[slot] == 0) continue;
        const int32_t cell = ledger.cohort_cell[slot];
        if (candidate.population.restore_slot_at(
                static_cast<int32_t>(slot), cell,
                ledger.cohort_signature_id[slot]) < 0) {
            error = "economy_pod_population_slot_restore_failed";
            return false;
        }
        ++active_count;
    }

    candidate.population.active = ledger.cohort_active;
    candidate.population.signature_id = ledger.cohort_signature_id;
    if (!ledger.cohort_generation.empty())
        candidate.population.generation = ledger.cohort_generation;
    if (!ledger.cohort_reserved.empty())
        candidate.population.reserved = ledger.cohort_reserved;
    if (!ledger.cohort_reservation_owner.empty())
        candidate.population.reservation_owner = ledger.cohort_reservation_owner;
    candidate.population.population = ledger.cohort_population;
    candidate.population.funds = ledger.cohort_funds;
    candidate.population.epoch_income = ledger.cohort_epoch_income;
    candidate.population.epoch_expense = ledger.cohort_epoch_expense;
    if (!ledger.cohort_needs_satisfaction.empty())
        candidate.population.needs_satisfaction = ledger.cohort_needs_satisfaction;
    if (!ledger.cohort_composite_satisfaction.empty()) {
        candidate.population.composite_satisfaction =
            ledger.cohort_composite_satisfaction;
    }
    if (!ledger.cohort_owner_employed.empty())
        candidate.population.owner_employed = ledger.cohort_owner_employed;
    if (!ledger.cohort_employee_employed.empty())
        candidate.population.employee_employed = ledger.cohort_employee_employed;
    candidate.population.active_count = active_count;
    candidate.market.stock = ledger.market_stock;
    candidate.market.price = ledger.market_price;
    candidate.market.demand_ema = ledger.market_demand_ema;
    if (!ledger.market_last_shortage_q16.empty())
        candidate.market.last_shortage_q16 = ledger.market_last_shortage_q16;
    if (!ledger.market_cell_to_market.empty())
        candidate.market.cell_to_market = ledger.market_cell_to_market;
    candidate.state_generation = ledger.generation;
    candidate.committed_day = ledger.committed_day;
    candidate.committed = ledger;
    candidate.building = ledger.building;
    if (ledger.building.captured)
        candidate.buildings = ledger.building.store;
    candidate.trade_escrow = ledger.trade_escrow;
    if (ledger.trade_escrow.captured)
        candidate.trade_orders = ledger.trade_escrow.store;
    candidate.family = ledger.family;
    if (ledger.family.captured)
        candidate.families = ledger.family.store;
    candidate.resource = ledger.resource;
    if (ledger.resource.captured)
        candidate.resources = ledger.resource.store;
    candidate.epoch_cursor = ledger.epoch_cursor;
    if (ledger.epoch_cursor.captured)
        candidate.epoch_cursors = ledger.epoch_cursor.store;
    restored = std::move(candidate);
    return true;
}

} // namespace

bool RuntimeEconomySnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = FREE;
        if (_states[i].compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel)) {
            index = i;
            return true;
        }
    }
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = READY;
        if (_states[i].compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel)) {
            index = i;
            _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
            return true;
        }
    }
    return false;
}

void RuntimeEconomySnapshotRing::publish(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    _states[index].store(READY, std::memory_order_release);
    _published_index.store(index, std::memory_order_release);
}

bool RuntimeEconomySnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                    uint32_t &index) {
    const uint32_t published =
        _published_index.load(std::memory_order_acquire);
    if (published >= RUNTIME_SNAPSHOT_RING_SIZE) return false;
    uint8_t expected = READY;
    if (!_states[published].compare_exchange_strong(
            expected, READING, std::memory_order_acq_rel)) {
        return false;
    }
    if (_buffers[published].header.generation <= after_generation) {
        _states[published].store(READY, std::memory_order_release);
        return false;
    }
    index = published;
    return true;
}

void RuntimeEconomySnapshotRing::release(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    _states[index].store(READY, std::memory_order_release);
}

void RuntimeEconomySnapshotRing::reset() {
    for (auto &state : _states) state.store(FREE, std::memory_order_release);
    _published_index.store(0, std::memory_order_release);
    _publish_drop_count.store(0, std::memory_order_release);
    _buffers = {};
}

bool RuntimeEconomySnapshotRing::self_test() {
    RuntimeEconomySnapshotRing ring;
    uint32_t index = 0;
    if (!ring.try_begin_write(index)) return false;
    ring.write_buffer(index).header.generation = 7;
    ring.write_buffer(index).header.committed = true;
    ring.publish(index);
    uint32_t read_index = 0;
    if (!ring.try_acquire_latest(0, read_index)) return false;
    if (ring.read_buffer(read_index).header.generation != 7) return false;
    ring.release(read_index);
    return true;
}

RuntimeEconomyPodAuthority::RuntimeEconomyPodAuthority() {
    reset();
}

uint64_t RuntimeEconomyPodAuthority::state_hash() const noexcept {
    EconomyCostProbe probe("pod_hash", _state.committed_day, _state.market.stock.size());
    uint64_t hash = FNV_OFFSET;
    auto mix = [&hash](uint64_t value) {
        hash = economy_hash_u64(hash, value);
    };
    mix(_state.state_generation);
    mix(static_cast<uint64_t>(_state.sample_day));
    mix(static_cast<uint64_t>(_state.committed_day));
    mix(static_cast<uint64_t>(_state.market.market_count));
    mix(static_cast<uint64_t>(_state.market.good_count));
    for (size_t i = 0; i < _state.population.active.size(); ++i) {
        mix(_state.population.active[i]);
        mix(_state.population.signature_id[i]);
        mix(_state.population.generation[i]);
        mix(static_cast<uint64_t>(_state.population.population[i]));
        mix(static_cast<uint64_t>(_state.population.funds[i]));
    }
    for (size_t i = 0; i < _state.market.stock.size(); ++i) {
        mix(static_cast<uint64_t>(_state.market.stock[i]));
        mix(static_cast<uint64_t>(_state.market.price[i]));
        mix(static_cast<uint64_t>(_state.market.demand_ema[i]));
        mix(_state.market.last_shortage_q16[i]);
    }
    return hash;
}

bool RuntimeEconomyPodAuthority::import_committed_ledger(
        const RuntimeEconomyLedgerState &ledger, std::string &error) {
    error.clear();
    RuntimeEconomyOwnedState restored;
    if (!build_owned_state_from_ledger(ledger, restored, error)) return false;
    _state = std::move(restored);
    return true;
}

bool RuntimeEconomyPodAuthority::import_and_publish_committed_ledger(
        RuntimeEconomyLedgerState &&ledger, std::string &error) {
    error.clear();
    RuntimeEconomyOwnedState restored;
    // Validate all shapes and hashes once, before changing either publication.
    // No producer can mutate this local ledger between validation and move.
    if (!build_owned_state_from_ledger(ledger, restored, error)) return false;
    _state = std::move(restored);
    _committed_ledger_state = std::move(ledger);
    publish_mirror_features();
    return true;
}

bool RuntimeEconomyPodAuthority::publish_owned_committed_mirror(
        uint64_t generation, int64_t committed_day, std::string &error) {
    error.clear();
    if (!state_initialized()) {
        error = "economy_pod_owned_mirror_state_uninitialized";
        return false;
    }
    EconomyCostProbe probe("ledger_export", committed_day, _state.market.stock.size());
    RuntimeEconomyLedgerState &ledger = _export_ledger_scratch;
    // Stamp identity before the export so `valid()` sees a nonzero generation
    // and a committed day even on the very first publish.
    _state.state_generation = std::max(generation, _state.state_generation);
    if (committed_day >= 0) _state.committed_day = committed_day;
    if (!export_committed_ledger(ledger, error)) return false;
    // The caller refreshed the committed blocks; export_committed_ledger()
    // validated them. Keeping a second full copy in _state.committed here
    // only duplicated all population/market vectors before the move below;
    // export's fallback blocks are used only when a block is genuinely absent.
    // The complete validated ledger remains the single published copy.
    std::swap(_committed_ledger_state, ledger);
    publish_mirror_features();
    return true;
}

bool RuntimeEconomyPodAuthority::export_committed_ledger(
        RuntimeEconomyLedgerState &ledger, std::string &error) const {
    error.clear();
    ledger.clear();
    const auto copy_started = std::chrono::steady_clock::now();
    ledger.generation = _state.state_generation;
    ledger.committed_day = _state.committed_day;
    ledger.market_count = _state.market.market_count;
    ledger.good_count = _state.market.good_count;
    ledger.cohort_active = _state.population.active;
    ledger.cohort_cell.assign(_state.population.active.size(), -1);
    ledger.cohort_slot.resize(_state.population.active.size());
    for (size_t i = 0; i < ledger.cohort_slot.size(); ++i) ledger.cohort_slot[i] = static_cast<int32_t>(i);
    for (size_t page = 0; page < _state.population.page_cell.size(); ++page) {
        const size_t base = page * RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE && base + static_cast<size_t>(lane) < ledger.cohort_cell.size(); ++lane) ledger.cohort_cell[base + static_cast<size_t>(lane)] = _state.population.page_cell[page];
    }
    ledger.cohort_signature_id = _state.population.signature_id;
    ledger.cohort_generation = _state.population.generation;
    ledger.cohort_reserved = _state.population.reserved;
    ledger.cohort_reservation_owner = _state.population.reservation_owner;
    ledger.cohort_population = _state.population.population;
    ledger.cohort_funds = _state.population.funds;
    ledger.cohort_epoch_income = _state.population.epoch_income;
    ledger.cohort_epoch_expense = _state.population.epoch_expense;
    ledger.cohort_needs_satisfaction = _state.population.needs_satisfaction;
    ledger.cohort_composite_satisfaction =
        _state.population.composite_satisfaction;
    ledger.cohort_owner_employed = _state.population.owner_employed;
    ledger.cohort_employee_employed = _state.population.employee_employed;
    const auto population_finished = std::chrono::steady_clock::now();
    ledger.market_stock = _state.market.stock;
    ledger.market_price = _state.market.price;
    ledger.market_demand_ema = _state.market.demand_ema;
    ledger.market_last_shortage_q16 = _state.market.last_shortage_q16;
    ledger.market_cell_to_market = _state.market.cell_to_market;
    const auto market_finished = std::chrono::steady_clock::now();
    ledger.building = _state.building;
    ledger.trade_escrow = _state.trade_escrow;
    ledger.family = _state.family;
    ledger.resource = _state.resource;
    ledger.epoch_cursor = _state.epoch_cursor;
    if (!ledger.building.captured && _state.committed.building.captured)
        ledger.building = _state.committed.building;
    if (!ledger.trade_escrow.captured && _state.committed.trade_escrow.captured)
        ledger.trade_escrow = _state.committed.trade_escrow;
    if (!ledger.family.captured && _state.committed.family.captured)
        ledger.family = _state.committed.family;
    if (!ledger.resource.captured && _state.committed.resource.captured)
        ledger.resource = _state.committed.resource;
    if (!ledger.epoch_cursor.captured && _state.committed.epoch_cursor.captured)
        ledger.epoch_cursor = _state.committed.epoch_cursor;
    const auto blocks_finished = std::chrono::steady_clock::now();
    const auto validation_started = std::chrono::steady_clock::now();
    const char *validation_reason = nullptr;
    if (!ledger.valid(&validation_reason)) {
        error = std::string("economy_pod_ledger_export_invalid:") +
            (validation_reason != nullptr ? validation_reason : "unknown");
        return false;
    }
    const auto hash_started = std::chrono::steady_clock::now();
    ledger.recompute_hash();
    EconomyCostProbe::record("ledger_export.population", ledger.committed_day,
        std::chrono::duration<double, std::milli>(population_finished - copy_started).count());
    EconomyCostProbe::record("ledger_export.market", ledger.committed_day,
        std::chrono::duration<double, std::milli>(market_finished - population_finished).count());
    EconomyCostProbe::record("ledger_export.blocks", ledger.committed_day,
        std::chrono::duration<double, std::milli>(blocks_finished - market_finished).count());
    EconomyCostProbe::record("ledger_export.validate", ledger.committed_day,
        std::chrono::duration<double, std::milli>(hash_started - validation_started).count());
    EconomyCostProbe::record("ledger_export.hash", ledger.committed_day,
        elapsed_ms(hash_started));
    if (ledger.committed_day > 0 && ledger.committed_day % 100 == 0) {
        std::fprintf(stderr, "[economy-ledger-cost] day=%lld copy_ms=%.3f validate_ms=%.3f hash_ms=%.3f cohorts=%zu markets=%zu\n",
            static_cast<long long>(ledger.committed_day),
            std::chrono::duration<double, std::milli>(validation_started - copy_started).count(),
            std::chrono::duration<double, std::milli>(hash_started - validation_started).count(),
            elapsed_ms(hash_started), ledger.cohort_active.size(), ledger.market_stock.size());
    }
    return true;
}

void RuntimeEconomyPodAuthority::reset() noexcept {
    _state.clear(0, 0);
    _input = RuntimeEconomyEpochInput{};
    _scratch = RuntimeEconomyWorkerScratch{};
    _replay = RuntimeEconomyPodReplayReport{};
    _committed = RuntimeEconomyCommittedSnapshot{};
    _snapshot_ring.reset();
    _stage_cursor = EconomyStageCursor{};
    _view = EconomySoAView{};
    _outbox = {};
    _inbox = {};
    _reference_hash = {};
    _reference_work = {};
    _reference_present = {};
    _commands.clear();
    _receipts.clear();
    _terminal_receipts.clear();
    _commands.reserve(RUNTIME_ECONOMY_COMMAND_CAPACITY);
    _receipts.reserve(RUNTIME_ECONOMY_RECEIPT_CAPACITY);
    _terminal_receipts.reserve(RUNTIME_ECONOMY_RECEIPT_CAPACITY);
    _outbox_count = 0;
    _inbox_count = 0;
    _completed_stage_mask = 0;
    _parity_ready_mask = 0;
    _operation_gate_mask = 0;
    _authority_mode = RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    _generation = 0;
    _authority_ready = false;
    _summary_population = 0;
    _summary_funds = 0;
    _summary_markets = 0;
    _summary_buildings = 0;
    _summary_cohorts = 0;
    _summary_families = 0;
    _committed_ledger_state.clear();
    _export_ledger_scratch = RuntimeEconomyLedgerState{};
    _published_mirror_features.store(0, std::memory_order_release);
    _ecp2 = RuntimeEconomyEcp2State{};
    // Keep _stage_ops / _command_executor: Host re-attaches identity separately.
}

bool RuntimeEconomyPodAuthority::capture_committed_ledger_state(
        RuntimeEconomyLedgerState &&state) noexcept {
    if (!state.valid()) return false;
    if (state.ledger_hash == 0) state.recompute_hash();
    _committed_ledger_state = std::move(state);
    publish_mirror_features();
    return true;
}

void RuntimeEconomyPodAuthority::publish_mirror_features() noexcept {
    // 调用方已完整验证；此处只发布形状标签，不重复扫描账本。
    uint32_t mask =
        ECONOMY_POD_MIRROR_COHORT_CORE | ECONOMY_POD_MIRROR_MARKET_CORE;
    if (_committed_ledger_state.has_extended_columns()) {
        mask |= ECONOMY_POD_MIRROR_COHORT_GENERATION |
                ECONOMY_POD_MIRROR_MARKET_SIGNALS;
    }
    if (_committed_ledger_state.has_diagnostics_columns()) {
        mask |= ECONOMY_POD_MIRROR_RESERVATIONS |
                ECONOMY_POD_MIRROR_POPULATION_DIAGNOSTICS;
    }
    if (_committed_ledger_state.has_building_columns())
        mask |= ECONOMY_POD_MIRROR_BUILDING;
    if (_committed_ledger_state.has_trade_escrow_columns())
        mask |= ECONOMY_POD_MIRROR_TRADE_ESCROW;
    if (_committed_ledger_state.has_family_columns())
        mask |= ECONOMY_POD_MIRROR_FAMILY;
    if (_committed_ledger_state.has_resource_columns())
        mask |= ECONOMY_POD_MIRROR_RESOURCE;
    if (_committed_ledger_state.has_epoch_cursor_columns())
        mask |= ECONOMY_POD_MIRROR_EPOCH_CURSOR;
    _published_mirror_features.store(mask, std::memory_order_release);
}

void RuntimeEconomyPodAuthority::sync_identity(uint64_t session_epoch,
                                                 uint64_t generation) noexcept {
    if (session_epoch != 0) _input.session_epoch = session_epoch;
    _generation = generation;
    if (generation != 0) _input.economy_generation = generation;
}

bool RuntimeEconomyPodAuthority::is_owned_core_opcode(
        int32_t opcode) noexcept {
    return opcode >= NativeEconomyRuntime::COMMAND_TRANSFER_TO_COHORT &&
        opcode <= NativeEconomyRuntime::COMMAND_FAMILY_SET_SPLIT_POLICY;
}

bool RuntimeEconomyPodAuthority::is_owned_heavy_pod_opcode(
        int32_t opcode) noexcept {
    return opcode == NativeEconomyRuntime::COMMAND_BUILD ||
        (opcode >= NativeEconomyRuntime::COMMAND_FAMILY_FREE_BUILDING &&
         opcode <= NativeEconomyRuntime::COMMAND_SETTLE_FAMILY_EXPEDITION) ||
        opcode == NativeEconomyRuntime::COMMAND_BUILD_CANAL ||
        opcode == NativeEconomyRuntime::COMMAND_FAMILY_ABSORB_ANONYMOUS;
}

bool RuntimeEconomyPodAuthority::try_apply_owned_core_command(
        const RuntimeEconomyPodCommand &command, std::string &error,
        int64_t &settled_out) noexcept {
    error.clear();
    settled_out = 0;
    if (!is_owned_core_opcode(command.opcode)) {
        error = "economy_pod_owned_core_opcode_unsupported";
        return false;
    }
    if (!state_initialized()) {
        error = "economy_pod_owned_core_state_uninitialized";
        return false;
    }
    if (is_owned_heavy_pod_opcode(command.opcode)) {
        settled_out = 0;
        return true;
    }
    auto sat_add = [](int64_t a, int64_t b) -> int64_t {
        if (b > 0 && a > std::numeric_limits<int64_t>::max() - b)
            return std::numeric_limits<int64_t>::max();
        if (b < 0 && a < std::numeric_limits<int64_t>::min() - b)
            return std::numeric_limits<int64_t>::min();
        return a + b;
    };
    RuntimeEconomyPopulationStore &population = _state.population;
    RuntimeEconomyMarketStore &market = _state.market;
    RuntimeEconomyFamilyStore &families = _state.families;
    RuntimeEconomyBuildingStore &buildings = _state.buildings;
    const uint64_t target_handle = command.target_cohort != 0
                                         ? command.target_cohort
                                         : command.target_building;
    switch (command.opcode) {
    case NativeEconomyRuntime::COMMAND_TRANSFER_TO_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_ledger";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_income.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int64_t amount = std::max<int64_t>(0, command.payload0);
        population.funds[static_cast<size_t>(slot)] = sat_add(
            population.funds[static_cast<size_t>(slot)], amount);
        population.epoch_income[static_cast<size_t>(slot)] = sat_add(
            population.epoch_income[static_cast<size_t>(slot)], amount);
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_MINT_TO_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_mint";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_income.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        population.funds[static_cast<size_t>(slot)] = sat_add(
            population.funds[static_cast<size_t>(slot)], command.payload0);
        population.epoch_income[static_cast<size_t>(slot)] = sat_add(
            population.epoch_income[static_cast<size_t>(slot)],
            command.payload0);
        settled_out = command.payload0;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_BURN_FROM_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_burn";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_expense.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int64_t funds =
            population.funds[static_cast<size_t>(slot)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, funds));
        population.funds[static_cast<size_t>(slot)] = funds - amount;
        population.epoch_expense[static_cast<size_t>(slot)] = sat_add(
            population.epoch_expense[static_cast<size_t>(slot)], amount);
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_ADD_STOCK: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t before = market.stock[static_cast<size_t>(idx)];
        market.stock[static_cast<size_t>(idx)] =
            sat_add(before, command.payload0);
        settled_out = market.stock[static_cast<size_t>(idx)] - before;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_REMOVE_STOCK: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t stock = market.stock[static_cast<size_t>(idx)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, stock));
        market.stock[static_cast<size_t>(idx)] = stock - amount;
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_ADD_POPULATION: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_population_adjust";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.population.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int32_t page = slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        if (page < 0 ||
            static_cast<size_t>(page) >= population.page_cell.size()) {
            error = "economy_pod_owned_core_page_oob";
            return false;
        }
        const int32_t event_cell = population.page_cell[static_cast<size_t>(page)];
        const int64_t before = population.population[static_cast<size_t>(slot)];
        const int64_t after =
            std::max<int64_t>(0, sat_add(before, command.payload0));
        const int64_t actual_delta = after - before;
        population.population[static_cast<size_t>(slot)] = after;
        settled_out = actual_delta;
        _state.external_population_delta =
            sat_add(_state.external_population_delta, actual_delta);
        if (after == 0) {
            RuntimeEconomyOwnedStructuralCommand structural{};
            structural.opcode = 0;
            structural.source_slot = slot;
            structural.cell = event_cell;
            if (static_cast<size_t>(slot) < population.signature_id.size())
                structural.signature = static_cast<int32_t>(
                    population.signature_id[static_cast<size_t>(slot)]);
            structural.sequence =
                static_cast<int64_t>(command.submit_order);
            _state.structural_commands.push_back(structural);
        }
        return true;
    }
    case NativeEconomyRuntime::COMMAND_MOVE_POPULATION:
    case NativeEconomyRuntime::COMMAND_CHANGE_SIGNATURE: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_structure_queue";
            return false;
        }
        const int32_t page = slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        if (page < 0 ||
            static_cast<size_t>(page) >= population.page_cell.size()) {
            error = "economy_pod_owned_core_page_oob";
            return false;
        }
        const int64_t requested =
            command.payload0 <= 0
                ? population.population[static_cast<size_t>(slot)]
                : command.payload0;
        RuntimeEconomyOwnedStructuralCommand structural{};
        structural.opcode = command.opcode;
        structural.source_slot = slot;
        structural.cell =
            command.opcode == NativeEconomyRuntime::COMMAND_MOVE_POPULATION
                ? command.target_cell
                : population.page_cell[static_cast<size_t>(page)];
        structural.signature =
            command.opcode == NativeEconomyRuntime::COMMAND_CHANGE_SIGNATURE
                ? static_cast<int32_t>(command.target_country)
                : static_cast<int32_t>(
                      population.signature_id[static_cast<size_t>(slot)]);
        structural.population = requested;
        structural.sequence = static_cast<int64_t>(command.submit_order);
        _state.structural_commands.push_back(structural);
        settled_out = requested;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_TRANSFER_FROM_COHORT: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_transfer";
            return false;
        }
        if (slot < 0 ||
            static_cast<size_t>(slot) >= population.funds.size() ||
            static_cast<size_t>(slot) >= population.epoch_expense.size()) {
            error = "economy_pod_owned_core_slot_oob";
            return false;
        }
        const int64_t funds =
            population.funds[static_cast<size_t>(slot)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, funds));
        population.funds[static_cast<size_t>(slot)] = funds - amount;
        population.epoch_expense[static_cast<size_t>(slot)] = sat_add(
            population.epoch_expense[static_cast<size_t>(slot)], amount);
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_DEMOLISH: {
        int32_t slot = -1;
        if (!population.valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_demolish";
            return false;
        }
        const int32_t cell = command.target_cell;
        const int32_t type_id = static_cast<int32_t>(command.target_country);
        const int64_t count = command.payload0;
        const int32_t page = slot / RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        if (cell < 0 || cell >= market.market_count || type_id < 0 || count <= 0 ||
            page < 0 || static_cast<size_t>(page) >= population.page_cell.size() ||
            population.page_cell[static_cast<size_t>(page)] != cell) {
            error = "demolish_target_invalid";
            return false;
        }
        const int32_t signature = static_cast<int32_t>(
            population.signature_id[static_cast<size_t>(slot)]);
        const int32_t group_id =
            find_owned_building_group(buildings, cell, type_id, signature);
        if (group_id < 0 ||
            static_cast<size_t>(group_id) >= buildings.group_units.size() ||
            buildings.group_units[static_cast<size_t>(group_id)] < count) {
            error = "demolish_owned_count_insufficient";
            return false;
        }
        buildings.group_units[static_cast<size_t>(group_id)] -= count;
        settled_out = count;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_COUNTRY_GOOD_TO_MARKET: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t before = market.stock[static_cast<size_t>(idx)];
        market.stock[static_cast<size_t>(idx)] =
            sat_add(before, command.payload0);
        settled_out = market.stock[static_cast<size_t>(idx)] - before;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_MARKET_GOOD_TO_COUNTRY: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        if (market.market_count <= 0 || market.good_count <= 0 ||
            market_id < 0 || market_id >= market.market_count || good_id < 0 ||
            good_id >= market.good_count) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t idx = market.index(market_id, good_id);
        if (idx < 0 || static_cast<size_t>(idx) >= market.stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t stock = market.stock[static_cast<size_t>(idx)];
        const int64_t amount =
            std::min(command.payload0, std::max<int64_t>(0, stock));
        market.stock[static_cast<size_t>(idx)] = stock - amount;
        settled_out = amount;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_FAMILY_PURCHASE_DISCOUNT: {
        int32_t branch = -1;
        if (!owned_valid_influence_handle(families, target_handle, branch)) {
            error = "family_purchase_discount_target_invalid";
            return false;
        }
        int32_t family = -1;
        if (branch < 0 ||
            static_cast<size_t>(branch) >=
                families.influence_family_handle.size() ||
            !owned_valid_family_handle(
                families, families.influence_family_handle[static_cast<size_t>(
                                branch)],
                family)) {
            error = "family_purchase_discount_target_invalid";
            return false;
        }
        ensure_owned_family_purchase_factors(families);
        families.purchase_factor_q16[static_cast<size_t>(family)] =
            static_cast<int32_t>(
                std::clamp<int64_t>(command.payload0, 0, Q16_ONE));
        settled_out = command.payload0;
        return true;
    }
    case NativeEconomyRuntime::COMMAND_FAMILY_SET_SPLIT_POLICY: {
        int32_t family = -1;
        int32_t branch = -1;
        if (owned_valid_family_handle(families, target_handle, family)) {
        } else if (owned_valid_influence_handle(families, target_handle,
                                                branch)) {
            if (branch < 0 ||
                static_cast<size_t>(branch) >=
                    families.influence_family_handle.size() ||
                !owned_valid_family_handle(
                    families,
                    families.influence_family_handle[static_cast<size_t>(
                        branch)],
                    family)) {
                error = "family_split_policy_target_invalid";
                return false;
            }
        } else {
            error = "family_split_policy_target_invalid";
            return false;
        }
        const uint16_t policy = static_cast<uint16_t>(command.target_cell) &
            NativeEconomyRuntime::FAMILY_FLAG_SPLIT_POLICY_MASK;
        const uint8_t weight = static_cast<uint8_t>(
            std::clamp<int64_t>(command.payload0, 0, 255));
        apply_owned_family_split_policy_flags(families, family, policy, weight);
        settled_out = command.payload0;
        return true;
    }
    default:
        error = "economy_pod_owned_core_opcode_unsupported";
        return false;
    }
}

uint64_t RuntimeEconomyPodAuthority::hash_mix(uint64_t current,
                                              uint64_t value) noexcept {
    current ^= value;
    current *= FNV_PRIME;
    return current;
}

uint64_t RuntimeEconomyPodAuthority::hash_input(
        const RuntimeEconomyEpochInput &input) noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = hash_mix(hash, static_cast<uint64_t>(input.sample_day));
    hash = hash_mix(hash, input.session_epoch);
    hash = hash_mix(hash, input.economy_generation);
    hash = hash_mix(hash, input.input_generation);
    hash = hash_mix(hash, input.country_generation);
    hash = hash_mix(hash, input.catalog_hash);
    hash = hash_mix(hash, input.policy_hash);
    hash = hash_mix(hash, input.environment_shape_hash);
    hash = hash_mix(hash, input.cell_count);
    return hash;
}

bool RuntimeEconomyPodAuthority::plan_epoch(const RuntimeEconomyEpochInput &input,
                                            std::string &error) {
    error.clear();
    if (!input.valid || input.sample_day < 0 || input.cell_count == 0 ||
        input.input_generation == 0) {
        error = "economy_pod_epoch_input_invalid";
        return false;
    }
    if (_scratch.epoch_active || _scratch.waiting_for_peer) {
        error = "economy_pod_epoch_busy";
        return false;
    }
    _input = input;
    _scratch = RuntimeEconomyWorkerScratch{};
    _scratch.epoch_active = true;
    _scratch.plan_ready = true;
    _stage_cursor = EconomyStageCursor{};
    _completed_stage_mask = 0;
    _parity_ready_mask = 0;
    _authority_ready = false;
    _replay = RuntimeEconomyPodReplayReport{};
    _replay.input_hash = hash_input(input);
    _replay.base_hash = hash_mix(FNV_OFFSET, _generation);
    _replay.input_captured = 1;
    if (_stage_ops != nullptr) {
        std::string bind_error;
        if (!_stage_ops->bind_view(_view, bind_error)) {
            error = bind_error.empty() ? "economy_pod_bind_view_failed"
                                       : bind_error;
            return false;
        }
    }
    return true;
}

void RuntimeEconomyPodAuthority::publish_replay_stage(
        RuntimeEconomyGraphStage stage, uint64_t work, uint64_t stage_hash,
        double ms) noexcept {
    const size_t index = static_cast<size_t>(stage);
    if (index >= RuntimeEconomyPodReplayReport::STAGE_COUNT) return;
    _replay.stage_work[index] = work;
    _replay.stage_hash[index] = stage_hash;
    _replay.stage_ms[index] = ms;
    _replay.completed_stage_mask |= runtime_economy_graph_stage_bit(stage);
    _replay.stage_cursor = static_cast<uint32_t>(
        std::max<uint64_t>(_replay.stage_cursor, work));
    _completed_stage_mask = _replay.completed_stage_mask;
    _replay.next_hash = stage_hash;

    if (_reference_present[index] != 0 &&
        (_input.stage_hashes_enabled || stage == RuntimeEconomyGraphStage::AGGREGATE_PUBLISH)) {
        _replay.reference_captured = 1;
        _replay.reference_hash = _reference_hash[index];
        _replay.parity_compared = 1;
        const bool matched =
            _reference_hash[index] == stage_hash &&
            _reference_work[index] == work;
        _replay.parity_matched = matched ? 1 : 0;
        if (matched && _stage_ops != nullptr) {
            _parity_ready_mask |= runtime_economy_graph_stage_bit(stage);
        }
        _replay.parity_ready_mask = _parity_ready_mask;
        _replay.parity_ready =
            (_parity_ready_mask == RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) ? 1 : 0;
    }
}

bool RuntimeEconomyPodAuthority::run_bound_stage(RuntimeEconomyGraphStage stage,
                                                 std::string &error) {
    error.clear();
    const auto begin = std::chrono::steady_clock::now();
    EconomyStageResult result;
    if (_stage_ops != nullptr) {
        if (!economy_kernel_run_stage(*_stage_ops, stage, _stage_cursor, _input,
                                      result, error)) {
            // Peer parks must not poison the epoch. commit_epoch treats any
            // replay fatal as economy_pod_fatal even if the slice later retries.
            const bool peer_park =
                error == "country_research_peer_results" ||
                error == "fiscal_settlement_peer_pending" ||
                error == "fiscal_reserve_peer_results" ||
                error == "fiscal_peer_results" ||
                error == "country_economy_asset_host_pending" ||
                error == "country_economy_asset_results_pending" ||
                error == "country_economy_asset_rejection_retry_pending" ||
                error == "country_economy_asset_completion_retry_pending" ||
                error == "country_economy_fiscal_terminal_retry_pending";
            if (result.fatal && !peer_park) {
                _replay.fatal = 1;
                copy_reason(_replay.fatal_reason, sizeof(_replay.fatal_reason),
                            result.fatal_reason[0] != '\0' ? result.fatal_reason
                                                          : error.c_str());
            }
            return false;
        }
        publish_replay_stage(stage, result.work_units, result.state_hash,
                             elapsed_ms(begin));
        _scratch.stage_cursor = static_cast<uint32_t>(result.work_units);
        return true;
    }

    // Hash-boundary fallback when StageOps is not attached (diagnostic only).
    const uint64_t work = _input.cell_count;
    uint64_t stage_hash = hash_mix(
        _replay.next_hash != 0 ? _replay.next_hash : _replay.input_hash,
        runtime_economy_graph_stage_bit(stage));
    stage_hash = hash_mix(stage_hash, work);
    stage_hash = hash_mix(stage_hash, _input.catalog_hash);
    publish_replay_stage(stage, work, stage_hash, elapsed_ms(begin));
    _scratch.stage_cursor = static_cast<uint32_t>(work);
    return true;
}

bool RuntimeEconomyPodAuthority::advance_stage(std::string &error) {
    error.clear();
    if (!_scratch.epoch_active || !_scratch.plan_ready) {
        error = "economy_pod_epoch_not_planned";
        return false;
    }
    if (_scratch.waiting_for_peer) {
        error = "economy_pod_waiting_for_peer";
        return false;
    }
    if (_scratch.stage_index >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) {
        error = "economy_pod_stages_exhausted";
        return false;
    }
    const auto stage =
        static_cast<RuntimeEconomyGraphStage>(_scratch.stage_index);
    if (!run_bound_stage(stage, error)) {
        copy_reason(_replay.fallback_reason, sizeof(_replay.fallback_reason),
                    error.c_str());
        return false;
    }
    ++_scratch.stage_index;
    _stage_cursor.stage_index = _scratch.stage_index;
    return true;
}

bool RuntimeEconomyPodAuthority::commit_epoch(std::string &error) {
    error.clear();
    if (!_scratch.epoch_active || !_scratch.plan_ready) {
        error = "economy_pod_epoch_not_planned";
        return false;
    }
    if (_scratch.stage_index != RUNTIME_ECONOMY_GRAPH_STAGE_COUNT ||
        _completed_stage_mask != RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) {
        error = "economy_pod_stages_incomplete";
        return false;
    }
    if (_outbox_count != 0 || _inbox_count != 0 || _scratch.waiting_for_peer) {
        error = "economy_pod_peer_queues_busy";
        return false;
    }
    if (_replay.fatal != 0) {
        error = "economy_pod_fatal";
        return false;
    }
    ++_generation;
    _committed = RuntimeEconomyCommittedSnapshot{};
    _committed.session_epoch = _input.session_epoch;
    _committed.generation = _generation;
    _committed.committed_day = _input.sample_day;
    _committed.from_day = _input.sample_day > 0 ? _input.sample_day - 1 : -1;
    _committed.epoch_sample_day = _input.sample_day;
    _committed.input_generation = _input.input_generation;
    _committed.country_generation = _input.country_generation;
    _committed.completed_stage_mask = _completed_stage_mask;
    _committed.pending_outbox = 0;
    _committed.pending_inbox = 0;
    _committed.operation_gate_mask = _operation_gate_mask;
    _committed.committed = true;
    _committed.authority_ready =
        _parity_ready_mask == RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    _committed.state_hash = hash_mix(_replay.next_hash, _generation);
    _committed.state_hash = hash_mix(_committed.state_hash,
        static_cast<uint64_t>(_committed.committed_day));
    _committed.state_hash = hash_mix(_committed.state_hash,
        _committed.completed_stage_mask);
    _committed.population_error = 0;
    _committed.money_error = 0;
    _committed.goods_error = 0;

    uint32_t ring_index = 0;
    if (_snapshot_ring.try_begin_write(ring_index)) {
        RuntimeEconomySnapshotPayload &payload =
            _snapshot_ring.write_buffer(ring_index);
        payload = RuntimeEconomySnapshotPayload{};
        payload.header = _committed;
        payload.catalog_hash = _input.catalog_hash;
        payload.operation_gate_mask = _operation_gate_mask;
        payload.pending_receipts = static_cast<uint32_t>(_receipts.size());
        _snapshot_ring.publish(ring_index);
    }

    // ACTIVE 无命令时不构造即将被 Host 再次刷新的投影；有命令仍保留
    // 执行前投影及执行后最终导出，不能让命令读到上一代 domain 数据。
    if (!_commands.empty() && !_input.stage_hashes_enabled &&
        _stage_ops != nullptr && _view.runtime_hook != nullptr) {
        auto *runtime = static_cast<NativeEconomyRuntime *>(_view.runtime_hook);
        if (runtime->formula_owned_bound())
            runtime->flush_formula_owned_domain_mirrors();
    }
    // Promote pending receipts that reached the committed boundary.
    commit_pending_commands();

    _replay.committed = 1;
    _replay.next_hash = _committed.state_hash;
    _replay.parity_ready_mask = _parity_ready_mask;
    _replay.parity_ready =
        (_parity_ready_mask == RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) ? 1 : 0;
    _scratch.epoch_active = false;
    _scratch.plan_ready = false;
    _authority_ready = _committed.authority_ready;
    return true;
}

void RuntimeEconomyPodAuthority::discard() noexcept {
    _scratch = RuntimeEconomyWorkerScratch{};
    _completed_stage_mask = 0;
    _authority_ready = false;
    copy_reason(_replay.fallback_reason, sizeof(_replay.fallback_reason),
                "economy_pod_discarded");
}

void RuntimeEconomyPodAuthority::set_stage_reference(
        RuntimeEconomyGraphStage stage, int64_t day, uint64_t generation,
        uint64_t state_hash, uint64_t work_units) noexcept {
    const size_t index = static_cast<size_t>(stage);
    if (index >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) return;
    _reference_present[index] = 1;
    _reference_hash[index] = state_hash;
    _reference_work[index] = work_units;
    _replay.reference_day = day;
    _replay.reference_generation = generation;
    _replay.reference_hash = state_hash;
    _replay.reference_captured = 1;
}

bool RuntimeEconomyPodAuthority::snapshot(RuntimeEconomyCommittedSnapshot &out,
                                          std::string &error) const {
    error.clear();
    if (!_committed.committed || _scratch.epoch_active) {
        error = "economy_pod_snapshot_not_committed";
        return false;
    }
    out = _committed;
    out.pending_outbox = _outbox_count;
    out.pending_inbox = _inbox_count;
    return true;
}

bool RuntimeEconomyPodAuthority::push_outbox(const RuntimeEconomyPeerSlot &slot,
                                             std::string &error) {
    error.clear();
    if (_outbox_count >= RUNTIME_ECONOMY_OUTBOX_CAPACITY) {
        error = "economy_pod_outbox_full";
        return false;
    }
    if (slot.request_id == 0) {
        error = "economy_pod_outbox_identity_invalid";
        return false;
    }
    _outbox[_outbox_count++] = slot;
    _outbox[_outbox_count - 1u].occupied = 1;
    return true;
}

bool RuntimeEconomyPodAuthority::push_inbox(const RuntimeEconomyPeerSlot &slot,
                                            std::string &error) {
    error.clear();
    if (_inbox_count >= RUNTIME_ECONOMY_INBOX_CAPACITY) {
        error = "economy_pod_inbox_full";
        return false;
    }
    if (slot.request_id == 0) {
        error = "economy_pod_inbox_identity_invalid";
        return false;
    }
    _inbox[_inbox_count++] = slot;
    _inbox[_inbox_count - 1u].occupied = 1;
    return true;
}

bool RuntimeEconomyPodAuthority::queue_command(
        const RuntimeEconomyPodCommand &command, std::string &error) {
    error.clear();
    if (command.request_id == 0) {
        error = "economy_pod_command_identity_invalid";
        return false;
    }
    for (const RuntimeEconomyPodReceipt &terminal : _terminal_receipts) {
        if (terminal.request_id == command.request_id) {
            _receipts.push_back(terminal);
            return true;
        }
    }
    for (const RuntimeEconomyPodReceipt &pending : _receipts) {
        if (pending.request_id == command.request_id) {
            _receipts.push_back(pending);
            return true;
        }
    }
    auto reject_admission = [&](const char *reason) {
        RuntimeEconomyPodReceipt rejected;
        rejected.request_id = command.request_id;
        rejected.transaction_id = command.transaction_id;
        rejected.session_epoch = command.session_epoch;
        rejected.economy_generation = command.economy_generation;
        rejected.opcode = command.opcode;
        rejected.code = RuntimeEconomyCommandReceiptCode::RejectedAtAdmission;
        copy_reason(rejected.reason, sizeof(rejected.reason), reason);
        _receipts.push_back(rejected);
        _terminal_receipts.push_back(rejected);
        return true;
    };
    // Phase 4: admit only legacy opcodes 1..23.
    if (command.opcode < 1 || command.opcode > 23) {
        return reject_admission("economy_command_opcode_out_of_range");
    }
    if (command.session_epoch != 0 && _input.session_epoch != 0 &&
        command.session_epoch != _input.session_epoch) {
        return reject_admission("economy_command_session_mismatch");
    }
    if (_generation != 0 && command.economy_generation != 0 &&
        command.economy_generation != _generation) {
        return reject_admission("economy_command_generation_mismatch");
    }
    if (_commands.size() >= RUNTIME_ECONOMY_COMMAND_CAPACITY) {
        // Queue pressure is a terminal admission outcome. Returning only a
        // boolean used to strand the caller without a request-level receipt,
        // which made retry/idempotency indistinguishable from packet loss.
        return reject_admission("economy_pod_command_queue_full");
    }
    _commands.push_back(command);
    RuntimeEconomyPodReceipt accepted;
    accepted.request_id = command.request_id;
    accepted.transaction_id = command.transaction_id;
    accepted.session_epoch = command.session_epoch;
    accepted.economy_generation = command.economy_generation;
    accepted.opcode = command.opcode;
    accepted.code = RuntimeEconomyCommandReceiptCode::Accepted;
    copy_reason(accepted.reason, sizeof(accepted.reason), "accepted");
    _receipts.push_back(accepted);
    return true;
}

uint32_t RuntimeEconomyPodAuthority::commit_pending_commands() noexcept {
    std::vector<RuntimeEconomyPodReceipt> committed_now;
    committed_now.reserve(_commands.size());
    uint32_t mutated = 0;
    for (const RuntimeEconomyPodCommand &command : _commands) {
        RuntimeEconomyPodReceipt *existing = nullptr;
        for (RuntimeEconomyPodReceipt &terminal : _terminal_receipts) {
            if (terminal.request_id == command.request_id) {
                existing = &terminal;
                break;
            }
        }
        if (existing != nullptr) {
            committed_now.push_back(*existing);
            continue;
        }

        RuntimeEconomyPodReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.transaction_id = command.transaction_id;
        receipt.session_epoch = command.session_epoch;
        receipt.economy_generation = command.economy_generation;
        receipt.opcode = command.opcode;
        // Opcode 20 = COMMAND_BUILD_CANAL: requires a quote token in payload0.
        if (command.opcode == 20 && command.payload0 == 0) {
            receipt.code = RuntimeEconomyCommandReceiptCode::RejectedAtExecution;
            copy_reason(receipt.reason, sizeof(receipt.reason),
                        "economy_command_build_canal_token_missing");
        } else if (_command_executor != nullptr) {
            std::string apply_error;
            if (_command_executor->apply(command, apply_error)) {
                receipt.code = RuntimeEconomyCommandReceiptCode::Committed;
                copy_reason(receipt.reason, sizeof(receipt.reason), "committed");
                ++mutated;
            } else {
                receipt.code =
                    RuntimeEconomyCommandReceiptCode::RejectedAtExecution;
                copy_reason(receipt.reason, sizeof(receipt.reason),
                            apply_error.empty()
                                ? "economy_command_apply_failed"
                                : apply_error.c_str());
            }
        } else if (_authority_mode == RuntimeEconomyAuthorityMode::POD_ACTIVE) {
            // Phase-2.6.2: POD_ACTIVE forbids silent Committed-without-mutate.
            receipt.code = RuntimeEconomyCommandReceiptCode::RejectedAtExecution;
            copy_reason(receipt.reason, sizeof(receipt.reason),
                        "economy_pod_active_executor_required");
        } else {
            // No executor: SHADOW / parity self_test keeps Committed-without-mutate.
            receipt.code = RuntimeEconomyCommandReceiptCode::Committed;
            copy_reason(receipt.reason, sizeof(receipt.reason), "committed");
        }
        _terminal_receipts.push_back(receipt);
        committed_now.push_back(receipt);
    }
    _commands.clear();
    // Replace admission receipts with terminal outcomes for this commit.
    _receipts = std::move(committed_now);
    return mutated;
}

bool RuntimeEconomyPodAuthority::poll_receipt(
        RuntimeEconomyPodReceipt &out) noexcept {
    if (_receipts.empty()) return false;
    out = _receipts.front();
    _receipts.erase(_receipts.begin());
    return true;
}

bool RuntimeEconomyPodAuthority::encode_ecp1(std::vector<uint8_t> &out,
                                             std::string &error) const {
    error.clear();
    if (!_committed.committed || _scratch.epoch_active ||
        _outbox_count != 0 || _inbox_count != 0) {
        error = "economy_pod_ecp1_save_blocked";
        return false;
    }
    const bool has_committed_ledger = _committed_ledger_state.valid();
    if (has_committed_ledger &&
        (_committed_ledger_state.ledger_hash == 0 ||
         _committed_ledger_state.computed_hash() !=
             _committed_ledger_state.ledger_hash)) {
        error = "economy_pod_ecp1_ledger_hash_invalid";
        return false;
    }
    out.clear();
    append_u32(out, RUNTIME_ECONOMY_POD_SECTION_MARKER);
    // Phase-2.3.3: ABI9 when resource+cursor are present; ABI8 when family is
    // present; ABI7 when building+trade are present; ABI6 when diagnostics are
    // present; ABI5 for generation/signals; ABI4 for core; ABI3 when no
    // committed ledger is captured yet.
    const uint32_t ledger_abi =
        !has_committed_ledger ? 3u
        : (_committed_ledger_state.has_resource_columns() &&
                   _committed_ledger_state.has_epoch_cursor_columns()
               ? 9u
               : (_committed_ledger_state.has_family_columns()
                      ? 8u
                      : (_committed_ledger_state.has_building_columns() &&
                                 _committed_ledger_state.has_trade_escrow_columns()
                             ? 7u
                             : (_committed_ledger_state.has_diagnostics_columns()
                                    ? 6u
                                    : (_committed_ledger_state.has_extended_columns()
                                           ? 5u
                                           : 4u)))));
    append_u32(out, ledger_abi);
    const size_t size_at = out.size();
    append_u32(out, 0u);
    append_u64(out, _committed.session_epoch);
    append_u64(out, _committed.generation);
    append_u64(out, _committed.state_hash);
    append_u64(out, static_cast<uint64_t>(_committed.committed_day));
    append_u64(out, _input.catalog_hash);
    append_u32(out, _operation_gate_mask);
    append_u32(out, _parity_ready_mask);
    append_u32(out, static_cast<uint32_t>(_terminal_receipts.size()));
    append_u32(out, static_cast<uint32_t>(_authority_mode));
    append_i64(out, _committed.population_error);
    append_i64(out, _committed.money_error);
    append_i64(out, _committed.goods_error);
    append_i64(out, _summary_population);
    append_i64(out, _summary_funds);
    append_i32(out, _summary_markets);
    append_i32(out, _summary_buildings);
    append_i32(out, _summary_cohorts);
    append_i32(out, _summary_families);
    if (has_committed_ledger) {
        const auto &ledger = _committed_ledger_state;
        append_u64(out, ledger.source_state_hash);
        append_u64(out, ledger.ledger_hash);
        append_u64(out, ledger.generation);
        append_i64(out, ledger.committed_day);
        append_i32(out, ledger.market_count);
        append_i32(out, ledger.good_count);
        append_u32(out, static_cast<uint32_t>(ledger.cohort_active.size()));
        for (uint8_t value : ledger.cohort_active) out.push_back(value);
        for (int32_t value : ledger.cohort_cell) append_i32(out, value);
        for (int32_t value : ledger.cohort_slot) append_i32(out, value);
        for (uint32_t value : ledger.cohort_signature_id) append_u32(out, value);
        for (int64_t value : ledger.cohort_population) append_i64(out, value);
        for (int64_t value : ledger.cohort_funds) append_i64(out, value);
        for (int64_t value : ledger.cohort_epoch_income) append_i64(out, value);
        for (int64_t value : ledger.cohort_epoch_expense) append_i64(out, value);
        append_u32(out, static_cast<uint32_t>(ledger.market_stock.size()));
        for (int64_t value : ledger.market_stock) append_i64(out, value);
        for (int32_t value : ledger.market_price) append_i32(out, value);
        for (int64_t value : ledger.market_demand_ema) append_i64(out, value);
        if (ledger_abi >= 5u) {
            for (uint32_t value : ledger.cohort_generation) append_u32(out, value);
            for (uint16_t value : ledger.market_last_shortage_q16)
                append_u16(out, value);
            for (int32_t value : ledger.market_cell_to_market)
                append_i32(out, value);
        }
        if (ledger_abi >= 6u) {
            for (uint8_t value : ledger.cohort_reserved) out.push_back(value);
            for (uint64_t value : ledger.cohort_reservation_owner)
                append_u64(out, value);
            for (uint16_t value : ledger.cohort_needs_satisfaction)
                append_u16(out, value);
            for (uint16_t value : ledger.cohort_composite_satisfaction)
                append_u16(out, value);
            for (int64_t value : ledger.cohort_owner_employed)
                append_i64(out, value);
            for (int64_t value : ledger.cohort_employee_employed)
                append_i64(out, value);
        }
        if (ledger_abi >= 7u) {
            append_u64(out, ledger.building.catalog_hash);
            append_u64(out, ledger.building.content_hash);
            append_u32(out, ledger.building.group_count);
            append_u32(out, ledger.building.pending_count);
            append_u32(out, ledger.building.role_lane_count);
            std::vector<uint8_t> building_wire;
            ledger.building.store.append_wire(building_wire);
            append_u32(out, static_cast<uint32_t>(building_wire.size()));
            out.insert(out.end(), building_wire.begin(), building_wire.end());
            append_u64(out, ledger.trade_escrow.country_trade_revision);
            append_i64(out, ledger.trade_escrow.next_id);
            append_u32(out, ledger.trade_escrow.order_count);
            append_u64(out, ledger.trade_escrow.content_hash);
            std::vector<uint8_t> trade_wire;
            ledger.trade_escrow.store.append_wire(trade_wire);
            append_u32(out, static_cast<uint32_t>(trade_wire.size()));
            out.insert(out.end(), trade_wire.begin(), trade_wire.end());
        }
        if (ledger_abi >= 8u) {
            append_u64(out, ledger.family.catalog_hash);
            append_u64(out, ledger.family.person_catalog_hash);
            append_u64(out, ledger.family.trait_catalog_hash);
            append_i32(out, ledger.family.runtime_mode);
            append_i32(out, ledger.family.person_runtime_mode);
            append_u32(out, ledger.family.family_count);
            append_u32(out, ledger.family.membership_count);
            append_u32(out, ledger.family.ownership_count);
            append_u32(out, ledger.family.person_count);
            append_u32(out, ledger.family.person_need_count);
            append_u32(out, ledger.family.trait_count);
            append_u32(out, ledger.family.influence_count);
            append_u32(out, ledger.family.trait_command_count);
            append_u32(out, ledger.family.expedition_count);
            append_i64(out, ledger.family.next_expedition_stable_id);
            append_u64(out, ledger.family.content_hash);
            std::vector<uint8_t> family_wire;
            ledger.family.store.append_wire(family_wire);
            append_u32(out, static_cast<uint32_t>(family_wire.size()));
            out.insert(out.end(), family_wire.begin(), family_wire.end());
        }
        if (ledger_abi >= 9u) {
            append_u64(out, ledger.resource.catalog_hash);
            append_u64(out, ledger.resource.environment_hash);
            append_i64(out, ledger.resource.context_day);
            append_i32(out, ledger.resource.resource_count);
            append_i32(out, ledger.resource.cell_count);
            append_u32(out, ledger.resource.lane_count);
            append_i32(out, ledger.resource.min_reserve_q16);
            append_i32(out, ledger.resource.safe_harvest_q16);
            append_i32(out, ledger.resource.min_horizon_days);
            append_u64(out, ledger.resource.content_hash);
            std::vector<uint8_t> resource_wire;
            ledger.resource.store.append_wire(resource_wire);
            append_u32(out, static_cast<uint32_t>(resource_wire.size()));
            out.insert(out.end(), resource_wire.begin(), resource_wire.end());
            append_i64(out, ledger.epoch_cursor.sample_day);
            append_i64(out, ledger.epoch_cursor.current_day);
            append_i64(out, ledger.epoch_cursor.last_committed_day);
            append_i64(out, ledger.epoch_cursor.epoch_id);
            append_i32(out, ledger.epoch_cursor.epoch_days);
            out.push_back(ledger.epoch_cursor.epoch_active);
            append_i32(out, ledger.epoch_cursor.native_stage);
            append_u32(out, ledger.epoch_cursor.graph_completed_mask);
            append_u64(out, ledger.epoch_cursor.content_hash);
            std::vector<uint8_t> cursor_wire;
            ledger.epoch_cursor.store.append_wire(cursor_wire);
            append_u32(out, static_cast<uint32_t>(cursor_wire.size()));
            out.insert(out.end(), cursor_wire.begin(), cursor_wire.end());
        }
    }
    for (const RuntimeEconomyPodReceipt &receipt : _terminal_receipts) {
        append_u64(out, receipt.request_id);
        append_u64(out, receipt.transaction_id);
        append_u32(out, static_cast<uint32_t>(receipt.opcode));
        append_u32(out, static_cast<uint32_t>(receipt.code));
    }
    const uint32_t payload_size =
        static_cast<uint32_t>(out.size() - size_at - 4u);
    out[size_at] = static_cast<uint8_t>(payload_size & 0xffu);
    out[size_at + 1] = static_cast<uint8_t>((payload_size >> 8) & 0xffu);
    out[size_at + 2] = static_cast<uint8_t>((payload_size >> 16) & 0xffu);
    out[size_at + 3] = static_cast<uint8_t>((payload_size >> 24) & 0xffu);
    append_u64(out, fnv1a(out.data(), out.size()));
    return true;
}

bool RuntimeEconomyPodAuthority::restore_ecp1(const uint8_t *data, size_t size,
                                              std::string &error) {
    error.clear();
    if (data == nullptr || size < 24) {
        error = "economy_pod_ecp1_truncated";
        return false;
    }
    const uint64_t expected = fnv1a(data, size - 8);
    uint64_t actual = 0;
    const uint8_t *tail = data + size - 8;
    if (!read_u64(tail, data + size, actual) || actual != expected) {
        error = "economy_pod_ecp1_checksum";
        return false;
    }
    const uint8_t *p = data;
    const uint8_t *end = data + size - 8;
    uint32_t marker = 0, abi = 0, payload_size = 0;
    if (!read_u32(p, end, marker) || marker != RUNTIME_ECONOMY_POD_SECTION_MARKER ||
        !read_u32(p, end, abi) ||
        (abi != 1u && abi != 2u && abi != 3u && abi != 4u && abi != 5u &&
         abi != 6u && abi != 7u && abi != 8u && abi != 9u) ||
        !read_u32(p, end, payload_size)) {
        error = "economy_pod_ecp1_header_invalid";
        return false;
    }
    uint64_t session = 0, generation = 0, state_hash = 0, day = 0, catalog = 0;
    if (payload_size != static_cast<size_t>(end - p)) {
        error = "economy_pod_ecp1_payload_size_mismatch";
        return false;
    }
    uint32_t gate = 0, parity = 0, receipt_count = 0, authority_mode = 0;
    if (!read_u64(p, end, session) || !read_u64(p, end, generation) ||
        !read_u64(p, end, state_hash) || !read_u64(p, end, day) ||
        !read_u64(p, end, catalog) || !read_u32(p, end, gate) ||
        !read_u32(p, end, parity) || !read_u32(p, end, receipt_count)) {
        error = "economy_pod_ecp1_payload_invalid";
        return false;
    }
    if (abi >= 3u && !read_u32(p, end, authority_mode)) {
        error = "economy_pod_ecp1_authority_mode_missing";
        return false;
    }
    int64_t pop_err = 0, money_err = 0, goods_err = 0;
    int64_t summary_population = 0, summary_funds = 0;
    int32_t summary_markets = 0, summary_buildings = 0;
    int32_t summary_cohorts = 0, summary_families = 0;
    if (abi >= 2u) {
        if (!read_i64(p, end, pop_err) || !read_i64(p, end, money_err) ||
            !read_i64(p, end, goods_err) ||
            !read_i64(p, end, summary_population) ||
            !read_i64(p, end, summary_funds) ||
            !read_i32(p, end, summary_markets) ||
            !read_i32(p, end, summary_buildings) ||
            !read_i32(p, end, summary_cohorts) ||
            !read_i32(p, end, summary_families)) {
            error = "economy_pod_ecp1_abi2_truncated";
            return false;
        }
    }
    RuntimeEconomyLedgerState restored_ledger;
    if (abi >= 4u) {
        uint64_t ledger_source_hash = 0, ledger_hash = 0;
        uint64_t ledger_generation = 0;
        int64_t ledger_committed_day = -1;
        int32_t market_count = 0, good_count = 0;
        uint32_t cohort_count = 0, market_lanes = 0;
        if (!read_u64(p, end, ledger_source_hash) ||
            !read_u64(p, end, ledger_hash) ||
            !read_u64(p, end, ledger_generation) ||
            !read_i64(p, end, ledger_committed_day) ||
            !read_i32(p, end, market_count) || !read_i32(p, end, good_count) ||
            !read_u32(p, end, cohort_count) || market_count < 0 || good_count < 0 ||
            cohort_count > 10000000u) {
            error = "economy_pod_ecp1_ledger_header_invalid";
            return false;
        }
        restored_ledger.source_state_hash = ledger_source_hash;
        restored_ledger.ledger_hash = ledger_hash;
        restored_ledger.generation = ledger_generation;
        restored_ledger.committed_day = ledger_committed_day;
        restored_ledger.market_count = market_count;
        restored_ledger.good_count = good_count;
        restored_ledger.cohort_active.resize(cohort_count);
        restored_ledger.cohort_cell.resize(cohort_count);
        restored_ledger.cohort_slot.resize(cohort_count);
        restored_ledger.cohort_signature_id.resize(cohort_count);
        restored_ledger.cohort_population.resize(cohort_count);
        restored_ledger.cohort_funds.resize(cohort_count);
        restored_ledger.cohort_epoch_income.resize(cohort_count);
        restored_ledger.cohort_epoch_expense.resize(cohort_count);
        for (uint8_t &value : restored_ledger.cohort_active) {
            if (p >= end) {
                error = "economy_pod_ecp1_ledger_truncated";
                return false;
            }
            value = *p++;
        }
        const auto ledger_truncated = [&error]() {
            error = "economy_pod_ecp1_ledger_truncated";
            return false;
        };
        for (int32_t &value : restored_ledger.cohort_cell)
            if (!read_i32(p, end, value)) return ledger_truncated();
        for (int32_t &value : restored_ledger.cohort_slot)
            if (!read_i32(p, end, value)) return ledger_truncated();
        for (uint32_t &value : restored_ledger.cohort_signature_id)
            if (!read_u32(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_population)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_funds)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_epoch_income)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_epoch_expense)
            if (!read_i64(p, end, value)) return ledger_truncated();
        if (!read_u32(p, end, market_lanes) ||
            market_lanes != static_cast<uint64_t>(market_count) * static_cast<uint64_t>(good_count)) {
            error = "economy_pod_ecp1_ledger_market_shape_invalid";
            return false;
        }
        restored_ledger.market_stock.resize(market_lanes);
        restored_ledger.market_price.resize(market_lanes);
        restored_ledger.market_demand_ema.resize(market_lanes);
        for (int64_t &value : restored_ledger.market_stock)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int32_t &value : restored_ledger.market_price)
            if (!read_i32(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.market_demand_ema)
            if (!read_i64(p, end, value)) return ledger_truncated();
        if (abi >= 5u) {
            restored_ledger.cohort_generation.resize(cohort_count);
            restored_ledger.market_last_shortage_q16.resize(market_lanes);
            restored_ledger.market_cell_to_market.resize(
                static_cast<size_t>(market_count));
            for (uint32_t &value : restored_ledger.cohort_generation)
                if (!read_u32(p, end, value)) return ledger_truncated();
            for (uint16_t &value : restored_ledger.market_last_shortage_q16)
                if (!read_u16(p, end, value)) return ledger_truncated();
            for (int32_t &value : restored_ledger.market_cell_to_market)
                if (!read_i32(p, end, value)) return ledger_truncated();
        }
        if (abi >= 6u) {
            restored_ledger.cohort_reserved.resize(cohort_count);
            restored_ledger.cohort_reservation_owner.resize(cohort_count);
            restored_ledger.cohort_needs_satisfaction.resize(cohort_count);
            restored_ledger.cohort_composite_satisfaction.resize(cohort_count);
            restored_ledger.cohort_owner_employed.resize(cohort_count);
            restored_ledger.cohort_employee_employed.resize(cohort_count);
            for (uint8_t &value : restored_ledger.cohort_reserved) {
                if (p >= end) return ledger_truncated();
                value = *p++;
            }
            for (uint64_t &value : restored_ledger.cohort_reservation_owner)
                if (!read_u64(p, end, value)) return ledger_truncated();
            for (uint16_t &value : restored_ledger.cohort_needs_satisfaction)
                if (!read_u16(p, end, value)) return ledger_truncated();
            for (uint16_t &value : restored_ledger.cohort_composite_satisfaction)
                if (!read_u16(p, end, value)) return ledger_truncated();
            for (int64_t &value : restored_ledger.cohort_owner_employed)
                if (!read_i64(p, end, value)) return ledger_truncated();
            for (int64_t &value : restored_ledger.cohort_employee_employed)
                if (!read_i64(p, end, value)) return ledger_truncated();
        }
        if (abi >= 7u) {
            uint32_t building_payload_size = 0;
            uint32_t trade_payload_size = 0;
            if (!read_u64(p, end, restored_ledger.building.catalog_hash) ||
                !read_u64(p, end, restored_ledger.building.content_hash) ||
                !read_u32(p, end, restored_ledger.building.group_count) ||
                !read_u32(p, end, restored_ledger.building.pending_count) ||
                !read_u32(p, end, restored_ledger.building.role_lane_count) ||
                !read_u32(p, end, building_payload_size) ||
                static_cast<size_t>(end - p) < building_payload_size) {
                error = "economy_pod_ecp1_building_truncated";
                return false;
            }
            if (!restored_ledger.building.store.load_wire(
                    p, building_payload_size,
                    restored_ledger.building.group_count,
                    restored_ledger.building.pending_count,
                    restored_ledger.building.role_lane_count)) {
                error = "economy_pod_ecp1_building_payload_shape";
                return false;
            }
            p += building_payload_size;
            restored_ledger.building.captured = true;
            if (restored_ledger.building.content_hash !=
                restored_ledger.building.store.wire_content_hash()) {
                error = "economy_pod_ecp1_building_content_hash";
                return false;
            }
            if (!read_u64(p, end,
                          restored_ledger.trade_escrow.country_trade_revision) ||
                !read_i64(p, end, restored_ledger.trade_escrow.next_id) ||
                !read_u32(p, end, restored_ledger.trade_escrow.order_count) ||
                !read_u64(p, end, restored_ledger.trade_escrow.content_hash) ||
                !read_u32(p, end, trade_payload_size) ||
                static_cast<size_t>(end - p) < trade_payload_size) {
                error = "economy_pod_ecp1_trade_escrow_truncated";
                return false;
            }
            if (!restored_ledger.trade_escrow.store.load_wire(
                    p, trade_payload_size,
                    restored_ledger.trade_escrow.order_count)) {
                error = "economy_pod_ecp1_trade_escrow_payload_shape";
                return false;
            }
            p += trade_payload_size;
            restored_ledger.trade_escrow.captured = true;
            if (restored_ledger.trade_escrow.content_hash !=
                restored_ledger.trade_escrow.store.wire_content_hash()) {
                error = "economy_pod_ecp1_trade_escrow_content_hash";
                return false;
            }
        }
        if (abi >= 8u) {
            uint32_t family_payload_size = 0;
            if (!read_u64(p, end, restored_ledger.family.catalog_hash) ||
                !read_u64(p, end, restored_ledger.family.person_catalog_hash) ||
                !read_u64(p, end, restored_ledger.family.trait_catalog_hash) ||
                !read_i32(p, end, restored_ledger.family.runtime_mode) ||
                !read_i32(p, end, restored_ledger.family.person_runtime_mode) ||
                !read_u32(p, end, restored_ledger.family.family_count) ||
                !read_u32(p, end, restored_ledger.family.membership_count) ||
                !read_u32(p, end, restored_ledger.family.ownership_count) ||
                !read_u32(p, end, restored_ledger.family.person_count) ||
                !read_u32(p, end, restored_ledger.family.person_need_count) ||
                !read_u32(p, end, restored_ledger.family.trait_count) ||
                !read_u32(p, end, restored_ledger.family.influence_count) ||
                !read_u32(p, end, restored_ledger.family.trait_command_count) ||
                !read_u32(p, end, restored_ledger.family.expedition_count) ||
                !read_i64(p, end,
                          restored_ledger.family.next_expedition_stable_id) ||
                !read_u64(p, end, restored_ledger.family.content_hash) ||
                !read_u32(p, end, family_payload_size) ||
                static_cast<size_t>(end - p) < family_payload_size) {
                error = "economy_pod_ecp1_family_truncated";
                return false;
            }
            if (!restored_ledger.family.store.load_wire(
                    p, family_payload_size, restored_ledger.family.family_count,
                    restored_ledger.family.membership_count,
                    restored_ledger.family.ownership_count,
                    restored_ledger.family.person_count,
                    restored_ledger.family.person_need_count,
                    restored_ledger.family.trait_count,
                    restored_ledger.family.influence_count,
                    restored_ledger.family.trait_command_count,
                    restored_ledger.family.expedition_count)) {
                error = "economy_pod_ecp1_family_payload_shape";
                return false;
            }
            p += family_payload_size;
            restored_ledger.family.captured = true;
            if (restored_ledger.family.content_hash !=
                restored_ledger.family.store.wire_content_hash()) {
                error = "economy_pod_ecp1_family_content_hash";
                return false;
            }
        }
        if (abi >= 9u) {
            uint32_t resource_payload_size = 0;
            uint32_t cursor_payload_size = 0;
            if (!read_u64(p, end, restored_ledger.resource.catalog_hash) ||
                !read_u64(p, end, restored_ledger.resource.environment_hash) ||
                !read_i64(p, end, restored_ledger.resource.context_day) ||
                !read_i32(p, end, restored_ledger.resource.resource_count) ||
                !read_i32(p, end, restored_ledger.resource.cell_count) ||
                !read_u32(p, end, restored_ledger.resource.lane_count) ||
                !read_i32(p, end, restored_ledger.resource.min_reserve_q16) ||
                !read_i32(p, end, restored_ledger.resource.safe_harvest_q16) ||
                !read_i32(p, end, restored_ledger.resource.min_horizon_days) ||
                !read_u64(p, end, restored_ledger.resource.content_hash) ||
                !read_u32(p, end, resource_payload_size) ||
                static_cast<size_t>(end - p) < resource_payload_size) {
                error = "economy_pod_ecp1_resource_truncated";
                return false;
            }
            restored_ledger.resource.store.resource_count =
                restored_ledger.resource.resource_count;
            restored_ledger.resource.store.cell_count =
                restored_ledger.resource.cell_count;
            if (!restored_ledger.resource.store.load_wire(
                    p, resource_payload_size,
                    restored_ledger.resource.lane_count)) {
                error = "economy_pod_ecp1_resource_payload_shape";
                return false;
            }
            p += resource_payload_size;
            restored_ledger.resource.captured = true;
            if (restored_ledger.resource.content_hash !=
                restored_ledger.resource.store.wire_content_hash()) {
                error = "economy_pod_ecp1_resource_content_hash";
                return false;
            }
            if (!read_i64(p, end, restored_ledger.epoch_cursor.sample_day) ||
                !read_i64(p, end, restored_ledger.epoch_cursor.current_day) ||
                !read_i64(p, end,
                          restored_ledger.epoch_cursor.last_committed_day) ||
                !read_i64(p, end, restored_ledger.epoch_cursor.epoch_id) ||
                !read_i32(p, end, restored_ledger.epoch_cursor.epoch_days) ||
                p >= end) {
                error = "economy_pod_ecp1_epoch_cursor_truncated";
                return false;
            }
            restored_ledger.epoch_cursor.epoch_active = *p++;
            if (!read_i32(p, end, restored_ledger.epoch_cursor.native_stage) ||
                !read_u32(p, end,
                          restored_ledger.epoch_cursor.graph_completed_mask) ||
                !read_u64(p, end, restored_ledger.epoch_cursor.content_hash) ||
                !read_u32(p, end, cursor_payload_size) ||
                static_cast<size_t>(end - p) < cursor_payload_size) {
                error = "economy_pod_ecp1_epoch_cursor_truncated";
                return false;
            }
            if (!restored_ledger.epoch_cursor.store.load_wire(
                    p, cursor_payload_size)) {
                error = "economy_pod_ecp1_epoch_cursor_payload_shape";
                return false;
            }
            p += cursor_payload_size;
            restored_ledger.epoch_cursor.captured = true;
            if (restored_ledger.epoch_cursor.content_hash !=
                restored_ledger.epoch_cursor.store.wire_content_hash()) {
                error = "economy_pod_ecp1_epoch_cursor_content_hash";
                return false;
            }
        }
        if (!restored_ledger.valid()) {
            error = "economy_pod_ecp1_ledger_invalid";
            return false;
        }
    }
    constexpr size_t receipt_wire_size = 24;
    if (receipt_count != static_cast<size_t>(end - p) / receipt_wire_size ||
        static_cast<size_t>(end - p) % receipt_wire_size != 0) {
        error = "economy_pod_ecp1_receipt_size_mismatch";
        return false;
    }
    std::vector<RuntimeEconomyPodReceipt> restored_receipts;
    restored_receipts.reserve(receipt_count);
    for (uint32_t i = 0; i < receipt_count; ++i) {
        RuntimeEconomyPodReceipt receipt;
        uint32_t opcode = 0, code = 0;
        if (!read_u64(p, end, receipt.request_id) ||
            !read_u64(p, end, receipt.transaction_id) ||
            !read_u32(p, end, opcode) || !read_u32(p, end, code)) {
            error = "economy_pod_ecp1_receipt_truncated";
            return false;
        }
        receipt.opcode = static_cast<int32_t>(opcode);
        receipt.code = static_cast<RuntimeEconomyCommandReceiptCode>(code);
        restored_receipts.push_back(receipt);
    }
    RuntimeEconomyOwnedState restored_state;
    if (abi >= 4u) {
        if (!build_owned_state_from_ledger(
                restored_ledger, restored_state, error)) {
            return false;
        }
    } else {
        restored_state.clear(0, 0);
    }

    // Commit only after every wire, topology and ledger-hash check succeeds.
    _state = std::move(restored_state);
    _committed_ledger_state = std::move(restored_ledger);
    if (abi >= 4u) publish_mirror_features();
    else _published_mirror_features.store(0, std::memory_order_release);
    _terminal_receipts = std::move(restored_receipts);
    _committed = RuntimeEconomyCommittedSnapshot{};
    _committed.session_epoch = session;
    _committed.generation = generation;
    _committed.state_hash = state_hash;
    _committed.committed_day = static_cast<int64_t>(day);
    _committed.committed = true;
    _committed.completed_stage_mask = RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    _committed.population_error = pop_err;
    _committed.money_error = money_err;
    _committed.goods_error = goods_err;
    _operation_gate_mask = gate;
    _authority_mode = abi >= 3u && authority_mode <=
            static_cast<uint32_t>(RuntimeEconomyAuthorityMode::POD_ACTIVE)
        ? static_cast<RuntimeEconomyAuthorityMode>(authority_mode)
        : RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    _parity_ready_mask = parity;
    _generation = generation;
    _input.catalog_hash = catalog;
    _input.session_epoch = session;
    _scratch = RuntimeEconomyWorkerScratch{};
    _summary_population = summary_population;
    _summary_funds = summary_funds;
    _summary_markets = summary_markets;
    _summary_buildings = summary_buildings;
    _summary_cohorts = summary_cohorts;
    _summary_families = summary_families;
    // Preserve abi2 summaries into the snapshot ring for round-trip observers.
    if (abi >= 2u) {
        uint32_t ring_index = 0;
        if (_snapshot_ring.try_begin_write(ring_index)) {
            RuntimeEconomySnapshotPayload &payload =
                _snapshot_ring.write_buffer(ring_index);
            payload = RuntimeEconomySnapshotPayload{};
            payload.header = _committed;
            payload.catalog_hash = catalog;
            payload.operation_gate_mask = gate;
            payload.population_error = pop_err;
            payload.money_error = money_err;
            payload.goods_error = goods_err;
            payload.summary_population = summary_population;
            payload.summary_funds = summary_funds;
            payload.summary_markets = summary_markets;
            payload.summary_buildings = summary_buildings;
            payload.summary_cohorts = summary_cohorts;
            payload.summary_families = summary_families;
            _snapshot_ring.publish(ring_index);
        }
    }
    return true;
}

bool RuntimeEconomyPodAuthority::encode_ecp2(
        const RuntimeEconomyEcp2State &state, std::vector<uint8_t> &out,
        std::string &error) const {
    return pk::encode_ecp2(state, out, error);
}

bool RuntimeEconomyPodAuthority::encode_ecp2(std::vector<uint8_t> &out,
                                             std::string &error) const {
    if (_ecp2.authority_domain_mask == 0) {
        error = "economy_pod_ecp2_state_empty";
        return false;
    }
    return pk::encode_ecp2(_ecp2, out, error);
}

bool RuntimeEconomyPodAuthority::restore_ecp2(const uint8_t *data, size_t size,
                                              std::string &error) {
    error.clear();
    RuntimeEconomyEcp2State decoded;
    if (!pk::decode_ecp2(data, size, decoded, error)) return false;
    _ecp2 = std::move(decoded);
    return true;
}

bool RuntimeEconomyPodAuthority::capture_ecp2_from_runtime(
        NativeEconomyRuntime &runtime, uint32_t flags, std::string &error) {
    error.clear();
    RuntimeEconomyEcp2State captured;
    if (!runtime.capture_ecp2_authority(captured, error, flags)) return false;
    _ecp2 = std::move(captured);
    return true;
}

bool RuntimeEconomyPodAuthority::self_test(std::string &error) {
    error.clear();
    if (!runtime_economy_ecp2_self_test(error)) return false;
    RuntimeEconomyPopulationStore population;
    population.clear(2);
    const int32_t reserved = population.reserve_slot(0, 7, 99);
    const int32_t slot = population.claim_reserved_slot(reserved, 0, 7, 99);
    if (slot < 0 || population.active_count != 1 ||
        population.allocate_slot(0, 7) != slot) {
        error = "economy_population_reservation_contract_failed";
        return false;
    }
    const uint64_t handle = population.handle_for_slot(slot);
    int32_t resolved = -1;
    if (!population.valid_handle(handle, resolved) || resolved != slot) {
        error = "economy_population_handle_contract_failed";
        return false;
    }
    population.release_slot(slot);
    population.reclaim_empty_pages(0);
    const int32_t reused = population.allocate_slot(1, 8);
    if (reused != slot || population.valid_handle(handle, resolved) ||
        population.find_signature(0, 7) != -1 ||
        population.find_signature(1, 8) != reused ||
        population.satisfaction_dims.size() !=
            population.active.size() * RuntimeEconomyPopulationStore::SAT_DIM_COUNT) {
        error = "economy_population_page_reuse_contract_failed";
        return false;
    }
    if (!economy_graph_kernels_self_test(error)) return false;
    if (!RuntimeEconomySnapshotRing::self_test()) {
        error = "economy_snapshot_ring_self_test_failed";
        return false;
    }

    RuntimeEconomyPodAuthority authority;
    RuntimeEconomyEpochInput input;
    input.sample_day = 3;
    input.session_epoch = 1;
    input.economy_generation = 7;
    input.input_generation = 11;
    input.country_generation = 13;
    input.catalog_hash = 17;
    input.policy_hash = 19;
    input.environment_shape_hash = 23;
    input.cell_count = 4;
    input.market_cycle_days = 5;
    input.production_cycle_days = 10;
    input.investment_cycle_days = 20;
    input.valid = true;
    if (!authority.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        authority.set_stage_reference(
            static_cast<RuntimeEconomyGraphStage>(i), 3, 7,
            0, // will not match unless ops attached; Phase2 hash-boundary ok
            4);
        if (!authority.advance_stage(error)) return false;
    }
    if (authority.completed_stage_mask() != RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) {
        error = "economy_pod_stage_contract_failed";
        return false;
    }
    RuntimeEconomyPodCommand command;
    command.request_id = 99;
    command.opcode = 1;
    command.session_epoch = 1;
    if (!authority.queue_command(command, error)) return false;
    if (!authority.commit_epoch(error)) return false;
    RuntimeEconomyPodReceipt committed;
    if (!authority.poll_receipt(committed) ||
        committed.code != RuntimeEconomyCommandReceiptCode::Committed ||
        committed.request_id != 99) {
        error = "economy_pod_commit_receipt_missing";
        return false;
    }
    // Duplicate request_id must return the prior terminal.
    if (!authority.queue_command(command, error)) return false;
    RuntimeEconomyPodReceipt duplicate;
    if (!authority.poll_receipt(duplicate) ||
        duplicate.code != RuntimeEconomyCommandReceiptCode::Committed ||
        duplicate.request_id != 99) {
        error = "economy_pod_duplicate_request_id_failed";
        return false;
    }

    // Opcode admission coverage (fresh authority after commit).
    RuntimeEconomyPodAuthority admit;
    RuntimeEconomyEpochInput admit_input = input;
    admit_input.economy_generation = 1;
    if (!admit.plan_epoch(admit_input, error)) return false;
    // Force a non-zero generation for mismatch checks without full commit.
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        admit.set_stage_reference(static_cast<RuntimeEconomyGraphStage>(i), 3, 1,
                                  0, 4);
        if (!admit.advance_stage(error)) return false;
    }
    if (!admit.commit_epoch(error)) return false;
    const uint64_t live_generation = admit.epoch_input().economy_generation;
    (void)live_generation;

    RuntimeEconomyPodCommand bad_opcode;
    bad_opcode.request_id = 1000;
    bad_opcode.opcode = 0;
    bad_opcode.session_epoch = 1;
    if (!admit.queue_command(bad_opcode, error)) return false;
    RuntimeEconomyPodReceipt rejected;
    if (!admit.poll_receipt(rejected) ||
        rejected.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtAdmission) {
        error = "economy_pod_opcode_zero_should_reject";
        return false;
    }

    RuntimeEconomyPodCommand session_mismatch;
    session_mismatch.request_id = 1001;
    session_mismatch.opcode = 1;
    session_mismatch.session_epoch = 999;
    if (!admit.queue_command(session_mismatch, error)) return false;
    if (!admit.poll_receipt(rejected) ||
        rejected.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtAdmission) {
        error = "economy_pod_session_mismatch_should_reject";
        return false;
    }

    RuntimeEconomyPodCommand gen_mismatch;
    gen_mismatch.request_id = 1002;
    gen_mismatch.opcode = 1;
    gen_mismatch.session_epoch = 1;
    gen_mismatch.economy_generation = 999999;
    if (!admit.queue_command(gen_mismatch, error)) return false;
    if (!admit.poll_receipt(rejected) ||
        rejected.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtAdmission) {
        error = "economy_pod_generation_mismatch_should_reject";
        return false;
    }

    for (int32_t opcode = 1; opcode <= 23; ++opcode) {
        RuntimeEconomyPodCommand batch;
        batch.request_id = 2000 + static_cast<uint64_t>(opcode);
        batch.opcode = opcode;
        batch.session_epoch = 1;
        batch.economy_generation = 0; // wildcard
        if (opcode == 20) batch.payload0 = 1; // canal token present
        if (!admit.queue_command(batch, error)) return false;
    }
    for (int32_t opcode = 1; opcode <= 23; ++opcode) {
        RuntimeEconomyPodReceipt accepted;
        if (!admit.poll_receipt(accepted) ||
            accepted.code != RuntimeEconomyCommandReceiptCode::Accepted) {
            error = "economy_pod_opcode_batch_admit_failed";
            return false;
        }
    }

    // BUILD_CANAL without token rejects at execution on commit.
    RuntimeEconomyPodAuthority canal;
    if (!canal.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        canal.set_stage_reference(static_cast<RuntimeEconomyGraphStage>(i), 3, 7,
                                  0, 4);
        if (!canal.advance_stage(error)) return false;
    }
    RuntimeEconomyPodCommand canal_cmd;
    canal_cmd.request_id = 3000;
    canal_cmd.opcode = 20;
    canal_cmd.session_epoch = 1;
    canal_cmd.payload0 = 0;
    if (!canal.queue_command(canal_cmd, error)) return false;
    if (!canal.commit_epoch(error)) return false;
    RuntimeEconomyPodReceipt canal_receipt;
    if (!canal.poll_receipt(canal_receipt) ||
        canal_receipt.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtExecution) {
        error = "economy_pod_build_canal_token_reject_failed";
        return false;
    }

    // Executor apply failure → RejectedAtExecution (ACTIVE Host always attaches).
    class FailingEconomyPodExecutor final : public EconomyPodCommandExecutor {
    public:
        bool apply(const RuntimeEconomyPodCommand &,
                   std::string &apply_error) override {
            apply_error = "economy_pod_test_apply_failed";
            return false;
        }
    };
    RuntimeEconomyPodAuthority apply_fail;
    if (!apply_fail.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        apply_fail.set_stage_reference(
            static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
        if (!apply_fail.advance_stage(error)) return false;
    }
    FailingEconomyPodExecutor failing;
    apply_fail.attach_command_executor(&failing);
    RuntimeEconomyPodCommand fail_cmd;
    fail_cmd.request_id = 4000;
    fail_cmd.opcode = 1;
    fail_cmd.session_epoch = 1;
    if (!apply_fail.queue_command(fail_cmd, error)) return false;
    if (!apply_fail.commit_epoch(error)) return false;
    RuntimeEconomyPodReceipt fail_receipt;
    if (!apply_fail.poll_receipt(fail_receipt) ||
        fail_receipt.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtExecution) {
        error = "economy_pod_apply_failure_reject_failed";
        return false;
    }

    // Phase-2.6.2: POD_ACTIVE without executor must reject, not fake-commit.
    RuntimeEconomyPodAuthority active_no_exec;
    if (!active_no_exec.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        active_no_exec.set_stage_reference(
            static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
        if (!active_no_exec.advance_stage(error)) return false;
    }
    active_no_exec.set_authority_mode(RuntimeEconomyAuthorityMode::POD_ACTIVE);
    active_no_exec.attach_command_executor(nullptr);
    RuntimeEconomyPodCommand active_cmd;
    active_cmd.request_id = 4100;
    active_cmd.opcode = 1;
    active_cmd.session_epoch = 1;
    if (!active_no_exec.queue_command(active_cmd, error)) return false;
    if (!active_no_exec.commit_epoch(error)) return false;
    RuntimeEconomyPodReceipt active_receipt;
    if (!active_no_exec.poll_receipt(active_receipt) ||
        active_receipt.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtExecution ||
        std::strstr(active_receipt.reason,
                    "economy_pod_active_executor_required") == nullptr) {
        error = "economy_pod_active_executor_required_failed";
        return false;
    }

    // Phase-2.6.3: OwnedState-first mint under POD_ACTIVE.
    {
        RuntimeEconomyPodAuthority owned;
        owned.initialize_state(2, 3);
        RuntimeEconomyPopulationStore &pop = owned.state().population;
        const int32_t slot = pop.allocate_slot(0, 7);
        if (slot < 0) {
            error = "economy_pod_owned_core_allocate_failed";
            return false;
        }
        const uint64_t handle = pop.handle_for_slot(slot);
        pop.funds[static_cast<size_t>(slot)] = 10;
        pop.epoch_income[static_cast<size_t>(slot)] = 0;
        owned.set_authority_mode(RuntimeEconomyAuthorityMode::POD_ACTIVE);
        RuntimeEconomyPodCommand mint;
        mint.opcode = 2;
        mint.target_cohort = handle;
        mint.payload0 = 5;
        int64_t settled = 0;
        if (!owned.try_apply_owned_core_command(mint, error, settled) ||
            settled != 5 ||
            pop.funds[static_cast<size_t>(slot)] != 15 ||
            pop.epoch_income[static_cast<size_t>(slot)] != 5) {
            if (error.empty()) error = "economy_pod_owned_core_mint_failed";
            return false;
        }
        RuntimeEconomyPodCommand burn;
        burn.opcode = 3;
        burn.target_cohort = handle;
        burn.payload0 = 100;
        if (!owned.try_apply_owned_core_command(burn, error, settled) ||
            settled != 15 ||
            pop.funds[static_cast<size_t>(slot)] != 0) {
            if (error.empty()) error = "economy_pod_owned_core_burn_failed";
            return false;
        }
        owned.state().market.stock[0] = 8;
        RuntimeEconomyPodCommand add_stock;
        add_stock.opcode = 4;
        add_stock.target_cell = 0;
        add_stock.target_country = 0;
        add_stock.payload0 = 4;
        if (!owned.try_apply_owned_core_command(add_stock, error, settled) ||
            settled != 4 || owned.state().market.stock[0] != 12) {
            if (error.empty()) error = "economy_pod_owned_core_add_stock_failed";
            return false;
        }
        pop.population[static_cast<size_t>(slot)] = 100;
        RuntimeEconomyPodCommand add_pop;
        add_pop.opcode = NativeEconomyRuntime::COMMAND_ADD_POPULATION;
        add_pop.target_cohort = handle;
        add_pop.payload0 = 25;
        if (!owned.try_apply_owned_core_command(add_pop, error, settled) ||
            settled != 25 ||
            pop.population[static_cast<size_t>(slot)] != 125 ||
            owned.state().external_population_delta != 25) {
            if (error.empty())
                error = "economy_pod_owned_core_add_population_failed";
            return false;
        }
    }

    authority.set_authority_mode(
        RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY);
    authority.set_business_summary(0, 0, 0, 123, 456, 4, 5, 6, 7);
    if (authority.state_initialized()) {
        error = "economy_pod_reset_state_should_be_uninitialized";
        return false;
    }
    authority.initialize_state(2, 3);
    RuntimeEconomyPopulationStore &fixture_population =
        authority.state().population;
    const int32_t pod_slot = fixture_population.allocate_slot(0, 42);
    const int32_t inactive_page = fixture_population.allocate_page(1);
    const int32_t second_cell_zero_page = fixture_population.allocate_page(0);
    const int32_t pod_slot_two = fixture_population.restore_slot_at(
        second_cell_zero_page * RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE,
        0, 84);
    const int32_t free_page = fixture_population.allocate_page(0);
    fixture_population.reclaim_empty_pages(0);
    if (pod_slot != 0 || inactive_page != 1 || second_cell_zero_page != 2 ||
        pod_slot_two != 2 * RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE ||
        free_page != 3 || fixture_population.page_cell !=
            std::vector<int32_t>({0, 1, 0, -1})) {
        error = "economy_pod_state_fixture_topology_failed";
        return false;
    }
    fixture_population.signature_id[
        RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE] = 77;
    fixture_population.population[pod_slot] = 17;
    fixture_population.funds[pod_slot] = 2300;
    fixture_population.epoch_income[pod_slot] = 91;
    fixture_population.epoch_expense[pod_slot] = 12;
    fixture_population.generation[pod_slot] = 5;
    fixture_population.reserved[pod_slot] = 0;
    fixture_population.reservation_owner[pod_slot] = 0;
    fixture_population.needs_satisfaction[pod_slot] = 40000;
    fixture_population.composite_satisfaction[pod_slot] = 42000;
    fixture_population.owner_employed[pod_slot] = 3;
    fixture_population.employee_employed[pod_slot] = 11;
    fixture_population.population[pod_slot_two] = 29;
    fixture_population.funds[pod_slot_two] = 4100;
    fixture_population.epoch_income[pod_slot_two] = 101;
    fixture_population.epoch_expense[pod_slot_two] = 22;
    fixture_population.generation[pod_slot_two] = 9;
    fixture_population.reserved[pod_slot_two] = 1;
    fixture_population.reservation_owner[pod_slot_two] = 99;
    fixture_population.needs_satisfaction[pod_slot_two] = 50000;
    fixture_population.composite_satisfaction[pod_slot_two] = 51000;
    fixture_population.owner_employed[pod_slot_two] = 1;
    fixture_population.employee_employed[pod_slot_two] = 4;
    authority.state().market.stock[4] = 77;
    authority.state().market.price[4] = 19;
    authority.state().market.demand_ema[4] = 31;
    authority.state().market.last_shortage_q16[4] = 1024;
    authority.state().market.cell_to_market[0] = 0;
    authority.state().market.cell_to_market[1] = 1;
    authority.state().building.captured = true;
    authority.state().building.catalog_hash = 0xB17D;
    authority.state().building.store.clear();
    authority.state().building.sync_counts_from_store();
    authority.state().building.recompute_content_hash();
    authority.state().buildings = authority.state().building.store;
    authority.state().trade_escrow.captured = true;
    authority.state().trade_escrow.country_trade_revision = 3;
    authority.state().trade_escrow.next_id = 11;
    authority.state().trade_escrow.store.clear();
    authority.state().trade_escrow.sync_counts_from_store();
    authority.state().trade_escrow.recompute_content_hash();
    authority.state().trade_orders = authority.state().trade_escrow.store;
    authority.state().family.captured = true;
    authority.state().family.catalog_hash = 0xF001ull;
    authority.state().family.person_catalog_hash = 0xF002ull;
    authority.state().family.trait_catalog_hash = 0xF003ull;
    authority.state().family.runtime_mode = 1;
    authority.state().family.person_runtime_mode = 1;
    authority.state().family.next_expedition_stable_id = 42;
    authority.state().family.store.clear();
    authority.state().family.sync_counts_from_store();
    authority.state().family.recompute_content_hash();
    authority.state().families = authority.state().family.store;
    authority.state().resource.captured = true;
    authority.state().resource.catalog_hash = 0xC001ull;
    authority.state().resource.environment_hash = 0xE001ull;
    authority.state().resource.context_day = 3;
    authority.state().resource.min_reserve_q16 = 22938;
    authority.state().resource.safe_harvest_q16 = 0;
    authority.state().resource.min_horizon_days = 3650;
    // Empty snapshot + two zero generation stamps for cell_count=2.
    authority.state().resource.store.resource_count = 0;
    authority.state().resource.store.cell_count = 2;
    authority.state().resource.store.stock.clear();
    authority.state().resource.store.cell_generation.assign(2, 0);
    authority.state().resource.sync_counts_from_store();
    authority.state().resource.recompute_content_hash();
    authority.state().resources = authority.state().resource.store;
    authority.state().epoch_cursor.captured = true;
    authority.state().epoch_cursor.sample_day = 3;
    authority.state().epoch_cursor.current_day = 3;
    authority.state().epoch_cursor.last_committed_day = 3;
    authority.state().epoch_cursor.epoch_id = 9;
    authority.state().epoch_cursor.epoch_days = 1;
    authority.state().epoch_cursor.epoch_active = 0;
    authority.state().epoch_cursor.native_stage = 0;
    authority.state().epoch_cursor.graph_completed_mask =
        RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    authority.state().epoch_cursor.store.idle_marker = 0;
    authority.state().epoch_cursor.recompute_content_hash();
    authority.state().epoch_cursors = authority.state().epoch_cursor.store;
    authority.state().state_generation = 7;
    authority.state().committed_day = 3;
    RuntimeEconomyLedgerState fixture_ledger;
    if (!authority.export_committed_ledger(fixture_ledger, error)) return false;
    auto wire_hash_matches = [](const auto &store) {
        std::vector<uint8_t> wire;
        store.append_wire(wire);
        uint64_t expected = FNV_OFFSET;
        uint64_t mixed = (uint64_t{0x123456789abcdef0} ^ wire.size()) * FNV_PRIME;
        for (uint8_t byte : wire) {
            expected = (expected ^ byte) * FNV_PRIME;
            mixed = (mixed ^ byte) * FNV_PRIME;
        }
        return expected == store.wire_content_hash() &&
            mixed == store.mix_wire_hash(0x123456789abcdef0);
    };
    if (!wire_hash_matches(authority.state().building.store) ||
        !wire_hash_matches(authority.state().family.store) ||
        !wire_hash_matches(authority.state().trade_escrow.store) ||
        !wire_hash_matches(RuntimeEconomyBuildingStore{}) ||
        !wire_hash_matches(RuntimeEconomyFamilyStore{}) ||
        !wire_hash_matches(RuntimeEconomyTradeEscrowStore{})) {
        error = "economy_streaming_wire_hash_mismatch";
        return false;
    }
    if (!authority.capture_committed_ledger_state(
            RuntimeEconomyLedgerState(fixture_ledger))) {
        error = "economy_pod_state_fixture_ledger_failed";
        return false;
    }
    std::vector<uint8_t> encoded;
    if (!authority.encode_ecp1(encoded, error) || encoded.size() < 24) {
        if (error.empty()) error = "economy_pod_ecp1_encode_failed";
        return false;
    }
    RuntimeEconomyPodAuthority restored;
    if (!restored.restore_ecp1(encoded.data(), encoded.size(), error))
        return false;
    if (restored.authority_mode() != authority.authority_mode()) {
        error = "economy_pod_ecp4_authority_mode_mismatch";
        return false;
    }
    if (restored._summary_population != 123 ||
        restored._summary_funds != 456 || restored._summary_families != 7) {
        error = "economy_pod_ecp4_summary_mismatch";
        return false;
    }
    if (restored._terminal_receipts.size() !=
        authority._terminal_receipts.size()) {
        error = "economy_pod_ecp4_receipt_mismatch";
        return false;
    }
    if (!restored.state_initialized()) {
        error = "economy_pod_ecp4_state_not_initialized";
        return false;
    }
    if (restored.state_hash() != authority.state_hash()) {
        error = "economy_pod_ecp4_state_hash_mismatch";
        return false;
    }
    const RuntimeEconomyPopulationStore &restored_population =
        restored.state().population;
    if (restored_population.page_cell != std::vector<int32_t>({0, 1, 0, -1}) ||
        restored_population.cell_first_page != std::vector<int32_t>({0, 1}) ||
        restored_population.page_next != std::vector<int32_t>({2, -1, -1, -1}) ||
        restored_population.free_pages != std::vector<int32_t>({3})) {
        error = "economy_pod_ecp4_page_topology_mismatch";
        return false;
    }
    const auto ledgers_equal = [](const RuntimeEconomyLedgerState &left,
                                  const RuntimeEconomyLedgerState &right) {
        return left.source_state_hash == right.source_state_hash &&
            left.ledger_hash == right.ledger_hash &&
            left.generation == right.generation &&
            left.committed_day == right.committed_day &&
            left.market_count == right.market_count &&
            left.good_count == right.good_count &&
            left.cohort_active == right.cohort_active &&
            left.cohort_cell == right.cohort_cell &&
            left.cohort_slot == right.cohort_slot &&
            left.cohort_signature_id == right.cohort_signature_id &&
            left.cohort_generation == right.cohort_generation &&
            left.cohort_reserved == right.cohort_reserved &&
            left.cohort_reservation_owner == right.cohort_reservation_owner &&
            left.cohort_population == right.cohort_population &&
            left.cohort_funds == right.cohort_funds &&
            left.cohort_epoch_income == right.cohort_epoch_income &&
            left.cohort_epoch_expense == right.cohort_epoch_expense &&
            left.cohort_needs_satisfaction == right.cohort_needs_satisfaction &&
            left.cohort_composite_satisfaction ==
                right.cohort_composite_satisfaction &&
            left.cohort_owner_employed == right.cohort_owner_employed &&
            left.cohort_employee_employed == right.cohort_employee_employed &&
            left.market_stock == right.market_stock &&
            left.market_price == right.market_price &&
            left.market_demand_ema == right.market_demand_ema &&
            left.market_last_shortage_q16 == right.market_last_shortage_q16 &&
            left.market_cell_to_market == right.market_cell_to_market &&
            left.building.captured == right.building.captured &&
            left.building.catalog_hash == right.building.catalog_hash &&
            left.building.content_hash == right.building.content_hash &&
            left.building.group_count == right.building.group_count &&
            left.building.store.cell == right.building.store.cell &&
            left.building.store.role_filled == right.building.store.role_filled &&
            left.building.store.pending_cell ==
                right.building.store.pending_cell &&
            left.trade_escrow.captured == right.trade_escrow.captured &&
            left.trade_escrow.country_trade_revision ==
                right.trade_escrow.country_trade_revision &&
            left.trade_escrow.next_id == right.trade_escrow.next_id &&
            left.trade_escrow.content_hash == right.trade_escrow.content_hash &&
            left.trade_escrow.store.ids == right.trade_escrow.store.ids &&
            left.trade_escrow.store.line_goods ==
                right.trade_escrow.store.line_goods &&
            left.trade_escrow.store.seller_handles ==
                right.trade_escrow.store.seller_handles &&
            left.family.captured == right.family.captured &&
            left.family.catalog_hash == right.family.catalog_hash &&
            left.family.person_catalog_hash == right.family.person_catalog_hash &&
            left.family.trait_catalog_hash == right.family.trait_catalog_hash &&
            left.family.next_expedition_stable_id ==
                right.family.next_expedition_stable_id &&
            left.family.content_hash == right.family.content_hash &&
            left.family.store.family_slot == right.family.store.family_slot &&
            left.family.store.person_slot == right.family.store.person_slot &&
            left.family.store.expedition_slot ==
                right.family.store.expedition_slot &&
            left.family.store.membership_family_handle ==
                right.family.store.membership_family_handle &&
            left.resource.captured == right.resource.captured &&
            left.resource.catalog_hash == right.resource.catalog_hash &&
            left.resource.environment_hash == right.resource.environment_hash &&
            left.resource.context_day == right.resource.context_day &&
            left.resource.content_hash == right.resource.content_hash &&
            left.resource.store.stock == right.resource.store.stock &&
            left.resource.store.cell_generation ==
                right.resource.store.cell_generation &&
            left.epoch_cursor.captured == right.epoch_cursor.captured &&
            left.epoch_cursor.sample_day == right.epoch_cursor.sample_day &&
            left.epoch_cursor.last_committed_day ==
                right.epoch_cursor.last_committed_day &&
            left.epoch_cursor.epoch_id == right.epoch_cursor.epoch_id &&
            left.epoch_cursor.content_hash == right.epoch_cursor.content_hash &&
            left.epoch_cursor.store.idle_marker ==
                right.epoch_cursor.store.idle_marker;
    };
    RuntimeEconomyLedgerState restored_ledger;
    if (!restored.export_committed_ledger(restored_ledger, error)) return false;
    if (!ledgers_equal(restored_ledger, fixture_ledger)) {
        error = "economy_pod_ecp9_ledger_mismatch";
        return false;
    }
    if (restored.state().population.generation[pod_slot] != 5 ||
        restored.state().population.generation[pod_slot_two] != 9 ||
        restored.state().market.last_shortage_q16[4] != 1024 ||
        restored.state().population.reserved[pod_slot_two] != 1 ||
        restored.state().population.reservation_owner[pod_slot_two] != 99 ||
        restored.state().population.needs_satisfaction[pod_slot] != 40000 ||
        restored.state().population.owner_employed[pod_slot] != 3 ||
        !restored.state().building.captured ||
        restored.state().building.catalog_hash != 0xB17D ||
        restored.state().buildings.num_groups() != 0 ||
        !restored.state().trade_escrow.captured ||
        restored.state().trade_escrow.next_id != 11 ||
        restored.state().trade_orders.num_orders() != 0 ||
        !restored.state().family.captured ||
        restored.state().family.catalog_hash != 0xF001ull ||
        restored.state().family.next_expedition_stable_id != 42 ||
        restored.state().families.num_families() != 0 ||
        !restored.state().resource.captured ||
        restored.state().resource.catalog_hash != 0xC001ull ||
        restored.state().resource.cell_count != 2 ||
        restored.state().resources.cell_count != 2 ||
        restored.state().resources.cell_generation.size() != 2 ||
        !restored.state().epoch_cursor.captured ||
        restored.state().epoch_cursor.epoch_id != 9) {
        error = "economy_pod_ecp9_extended_columns_mismatch";
        return false;
    }
    if (!fixture_ledger.has_extended_columns() ||
        !fixture_ledger.has_diagnostics_columns() ||
        !fixture_ledger.has_building_columns() ||
        !fixture_ledger.has_trade_escrow_columns() ||
        !fixture_ledger.has_family_columns() ||
        !fixture_ledger.has_resource_columns() ||
        !fixture_ledger.has_epoch_cursor_columns()) {
        error = "economy_pod_ecp9_fixture_missing_extended";
        return false;
    }
    if ((authority.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE233) !=
            ECONOMY_POD_MIRROR_PHASE233 ||
        !authority.pod_active_ready() ||
        authority.committed_ledger_abi() != 9u ||
        restored.committed_ledger_abi() != 9u ||
        (restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE233) !=
            ECONOMY_POD_MIRROR_PHASE233 ||
        !restored.pod_active_ready()) {
        error = "economy_pod_ecp9_mirror_mask_unexpected";
        return false;
    }

    // ABI8 remains writable when resource/cursor blocks are absent.
    {
        RuntimeEconomyLedgerState abi8_ledger = fixture_ledger;
        abi8_ledger.resource.clear();
        abi8_ledger.epoch_cursor.clear();
        abi8_ledger.recompute_hash();
        RuntimeEconomyPodAuthority abi8_authority;
        if (!abi8_authority.plan_epoch(input, error)) return false;
        for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
            abi8_authority.set_stage_reference(
                static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
            if (!abi8_authority.advance_stage(error)) return false;
        }
        if (!abi8_authority.commit_epoch(error)) return false;
        abi8_authority.set_authority_mode(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY);
        abi8_authority.set_business_summary(0, 0, 0, 123, 456, 4, 5, 6, 7);
        if (!abi8_authority.import_committed_ledger(abi8_ledger, error) ||
            !abi8_authority.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(abi8_ledger))) {
            return false;
        }
        std::vector<uint8_t> abi8_encoded;
        if (!abi8_authority.encode_ecp1(abi8_encoded, error)) return false;
        RuntimeEconomyPodAuthority abi8_restored;
        if (!abi8_restored.restore_ecp1(abi8_encoded.data(), abi8_encoded.size(),
                                        error)) {
            return false;
        }
        if (abi8_authority.committed_ledger_abi() != 8u ||
            abi8_restored.committed_ledger_abi() != 8u ||
            abi8_restored.state().resource.captured ||
            abi8_restored.state().epoch_cursor.captured ||
            abi8_restored.pod_active_ready() ||
            (abi8_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE232) !=
                ECONOMY_POD_MIRROR_PHASE232) {
            error = "economy_pod_ecp8_backward_compat_failed";
            return false;
        }
    }

    // ABI7 remains writable when family block is absent.
    {
        RuntimeEconomyLedgerState abi7_ledger = fixture_ledger;
        abi7_ledger.family.clear();
        abi7_ledger.resource.clear();
        abi7_ledger.epoch_cursor.clear();
        abi7_ledger.recompute_hash();
        RuntimeEconomyPodAuthority abi7_authority;
        if (!abi7_authority.plan_epoch(input, error)) return false;
        for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
            abi7_authority.set_stage_reference(
                static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
            if (!abi7_authority.advance_stage(error)) return false;
        }
        if (!abi7_authority.commit_epoch(error)) return false;
        abi7_authority.set_authority_mode(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY);
        abi7_authority.set_business_summary(0, 0, 0, 123, 456, 4, 5, 6, 7);
        if (!abi7_authority.import_committed_ledger(abi7_ledger, error) ||
            !abi7_authority.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(abi7_ledger))) {
            return false;
        }
        std::vector<uint8_t> abi7_encoded;
        if (!abi7_authority.encode_ecp1(abi7_encoded, error)) return false;
        RuntimeEconomyPodAuthority abi7_restored;
        if (!abi7_restored.restore_ecp1(abi7_encoded.data(), abi7_encoded.size(),
                                        error)) {
            return false;
        }
        if (abi7_authority.committed_ledger_abi() != 7u ||
            abi7_restored.committed_ledger_abi() != 7u ||
            abi7_restored.state().family.captured ||
            (abi7_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE23) !=
                ECONOMY_POD_MIRROR_PHASE23 ||
            (abi7_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_FAMILY) !=
                0u) {
            error = "economy_pod_ecp7_backward_compat_failed";
            return false;
        }
    }

    // ABI6 remains writable when building/trade blocks are absent.
    {
        RuntimeEconomyLedgerState abi6_ledger = fixture_ledger;
        abi6_ledger.building.clear();
        abi6_ledger.trade_escrow.clear();
        abi6_ledger.family.clear();
        abi6_ledger.resource.clear();
        abi6_ledger.epoch_cursor.clear();
        abi6_ledger.recompute_hash();
        RuntimeEconomyPodAuthority abi6_authority;
        if (!abi6_authority.plan_epoch(input, error)) return false;
        for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
            abi6_authority.set_stage_reference(
                static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
            if (!abi6_authority.advance_stage(error)) return false;
        }
        if (!abi6_authority.commit_epoch(error)) return false;
        abi6_authority.set_authority_mode(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY);
        abi6_authority.set_business_summary(0, 0, 0, 123, 456, 4, 5, 6, 7);
        if (!abi6_authority.import_committed_ledger(abi6_ledger, error) ||
            !abi6_authority.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(abi6_ledger))) {
            return false;
        }
        std::vector<uint8_t> abi6_encoded;
        if (!abi6_authority.encode_ecp1(abi6_encoded, error)) return false;
        RuntimeEconomyPodAuthority abi6_restored;
        if (!abi6_restored.restore_ecp1(abi6_encoded.data(), abi6_encoded.size(),
                                        error)) {
            return false;
        }
        if (abi6_authority.committed_ledger_abi() != 6u ||
            abi6_restored.committed_ledger_abi() != 6u ||
            abi6_restored.state().building.captured ||
            abi6_restored.state().trade_escrow.captured ||
            (abi6_restored.mirror_feature_mask() & ECONOMY_POD_MIRROR_PHASE22) !=
                ECONOMY_POD_MIRROR_PHASE22 ||
            (abi6_restored.mirror_feature_mask() &
             (ECONOMY_POD_MIRROR_BUILDING | ECONOMY_POD_MIRROR_TRADE_ESCROW)) !=
                0u) {
            error = "economy_pod_ecp6_backward_compat_failed";
            return false;
        }
    }

    // Historical headers end at byte 64. ABI2 adds 56 summary bytes;
    // ABI3 inserts a four-byte authority mode before those summaries. ABI4
    // appends the committed ledger after the summary block at byte 124.
    // ABI5/ABI6/ABI7/ABI8/ABI9 append extended/.../resource-cursor.
    auto write_u32_at = [](std::vector<uint8_t> &bytes, size_t offset,
                           uint32_t value) {
        for (size_t i = 0; i < 4; ++i)
            bytes[offset + i] = static_cast<uint8_t>(value >> (8 * i));
    };
    auto write_u64_at = [](std::vector<uint8_t> &bytes, size_t offset,
                           uint64_t value) {
        for (size_t i = 0; i < 8; ++i)
            bytes[offset + i] = static_cast<uint8_t>(value >> (8 * i));
    };
    auto reseal = [](std::vector<uint8_t> &bytes) {
        const uint32_t payload = static_cast<uint32_t>(bytes.size() - 12);
        for (size_t i = 0; i < 4; ++i)
            bytes[8 + i] = static_cast<uint8_t>(payload >> (8 * i));
        append_u64(bytes, fnv1a(bytes.data(), bytes.size()));
    };
    constexpr size_t abi4_ledger_offset = 124;
    constexpr size_t receipt_wire_size = 24;
    const size_t receipt_bytes =
        authority._terminal_receipts.size() * receipt_wire_size;
    std::vector<uint8_t> abi3_bytes(encoded.begin(), encoded.end() - 8);
    if (abi3_bytes.size() < abi4_ledger_offset + receipt_bytes) {
        error = "economy_pod_ecp4_fixture_layout_invalid";
        return false;
    }
    const size_t receipt_offset = abi3_bytes.size() - receipt_bytes;
    abi3_bytes.erase(abi3_bytes.begin() + abi4_ledger_offset,
                     abi3_bytes.begin() + receipt_offset);
    for (uint32_t old_abi = 1; old_abi <= 3; ++old_abi) {
        std::vector<uint8_t> old_bytes = abi3_bytes;
        if (old_abi < 3)
            old_bytes.erase(old_bytes.begin() + 64, old_bytes.begin() + 68);
        if (old_abi < 2)
            old_bytes.erase(old_bytes.begin() + 64, old_bytes.begin() + 120);
        write_u32_at(old_bytes, 4, old_abi);
        reseal(old_bytes);
        RuntimeEconomyPodAuthority old_restored;
        if (!old_restored.import_committed_ledger(fixture_ledger, error) ||
            !old_restored.capture_committed_ledger_state(
                RuntimeEconomyLedgerState(fixture_ledger))) {
            return false;
        }
        if (!old_restored.restore_ecp1(old_bytes.data(), old_bytes.size(), error))
            return false;
        const RuntimeEconomyAuthorityMode expected_mode = old_abi >= 3
            ? RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY
            : RuntimeEconomyAuthorityMode::LEGACY_SYNC;
        if (old_restored.authority_mode() != expected_mode ||
            old_restored._summary_population != (old_abi >= 2 ? 123 : 0) ||
            old_restored._terminal_receipts.size() !=
                authority._terminal_receipts.size() ||
            old_restored.state_initialized() ||
            old_restored._committed_ledger_state.valid()) {
            error = "economy_pod_legacy_restore_mismatch";
            return false;
        }
    }

    const auto receipts_equal = [](const std::vector<RuntimeEconomyPodReceipt> &left,
                                   const std::vector<RuntimeEconomyPodReceipt> &right) {
        if (left.size() != right.size()) return false;
        for (size_t i = 0; i < left.size(); ++i) {
            if (left[i].request_id != right[i].request_id ||
                left[i].transaction_id != right[i].transaction_id ||
                left[i].opcode != right[i].opcode ||
                left[i].code != right[i].code) {
                return false;
            }
        }
        return true;
    };
    const uint64_t state_hash_before_reject = restored.state_hash();
    const RuntimeEconomyCommittedSnapshot committed_before_reject =
        restored._committed;
    const RuntimeEconomyAuthorityMode mode_before_reject =
        restored._authority_mode;
    const std::vector<RuntimeEconomyPodReceipt> receipts_before_reject =
        restored._terminal_receipts;
    const int64_t summary_population_before_reject =
        restored._summary_population;
    RuntimeEconomyLedgerState ledger_before_reject;
    if (!restored.export_committed_ledger(ledger_before_reject, error))
        return false;

    std::vector<uint8_t> malformed(encoded.begin(), encoded.end() - 8);
    constexpr size_t abi4_ledger_metadata_size = 32;
    const size_t cohort_cells_offset = abi4_ledger_offset +
        abi4_ledger_metadata_size + 12 +
        fixture_ledger.cohort_active.size();
    if (cohort_cells_offset + 8 > malformed.size()) {
        error = "economy_pod_malformed_fixture_layout_invalid";
        return false;
    }
    RuntimeEconomyLedgerState malformed_ledger = fixture_ledger;
    malformed_ledger.cohort_cell[1] = 1;
    malformed_ledger.recompute_hash();
    write_u64_at(malformed, abi4_ledger_offset + 8,
                 malformed_ledger.ledger_hash);
    write_u32_at(malformed, cohort_cells_offset + 4, 1);
    reseal(malformed);
    std::string rejected_error;
    RuntimeEconomyLedgerState ledger_after_reject;
    if (restored.restore_ecp1(malformed.data(), malformed.size(), rejected_error) ||
        rejected_error != "economy_pod_population_page_cell_mismatch" ||
        restored.state_hash() != state_hash_before_reject ||
        restored._committed.generation != committed_before_reject.generation ||
        restored._committed.state_hash != committed_before_reject.state_hash ||
        restored._authority_mode != mode_before_reject ||
        restored._summary_population != summary_population_before_reject ||
        !receipts_equal(restored._terminal_receipts, receipts_before_reject) ||
        !restored.export_committed_ledger(ledger_after_reject, error) ||
        !ledgers_equal(ledger_after_reject, ledger_before_reject)) {
        error = "economy_pod_failed_restore_mutated_state";
        return false;
    }

    RuntimeEconomyLedgerState bad_hash = fixture_ledger;
    bad_hash.ledger_hash ^= 1u;
    if (restored.import_committed_ledger(bad_hash, rejected_error) ||
        rejected_error != "economy_pod_ledger_hash_invalid" ||
        restored.state_hash() != state_hash_before_reject) {
        error = "economy_pod_failed_import_mutated_state";
        return false;
    }
    const uint64_t mirror_hash_before = restored._committed_ledger_state.ledger_hash;
    if (restored.import_and_publish_committed_ledger(std::move(bad_hash), rejected_error) ||
        rejected_error != "economy_pod_ledger_hash_invalid" ||
        restored.state_hash() != state_hash_before_reject ||
        restored._committed_ledger_state.ledger_hash != mirror_hash_before) {
        error = "economy_pod_failed_combined_import_mutated_state";
        return false;
    }
    RuntimeEconomyLedgerState combined_fixture = fixture_ledger;
    if (!restored.import_and_publish_committed_ledger(std::move(combined_fixture), error) ||
        !ledgers_equal(restored._committed_ledger_state, fixture_ledger)) {
        error = "economy_pod_combined_import_mirror_mismatch";
        return false;
    }
    // 反复交换导出缓冲后，失败发布仍必须保留最后一个完整账本。
    for (int pass = 0; pass < 3; ++pass) {
        if (!restored.publish_owned_committed_mirror(
                fixture_ledger.generation, fixture_ledger.committed_day, error) ||
            !ledgers_equal(restored._committed_ledger_state, fixture_ledger)) {
            error = "economy_owned_reused_export_mismatch";
            return false;
        }
    }
    const auto published_hash = restored._committed_ledger_state.ledger_hash;
    restored.state().building.content_hash ^= 1u;
    if (restored.publish_owned_committed_mirror(
            fixture_ledger.generation, fixture_ledger.committed_day, rejected_error) ||
        restored._committed_ledger_state.ledger_hash != published_hash) {
        error = "economy_owned_failed_export_changed_published_ledger";
        return false;
    }
    restored.state().building.content_hash ^= 1u;
    if (!restored.publish_owned_committed_mirror(
            fixture_ledger.generation, fixture_ledger.committed_day, error) ||
        !ledgers_equal(restored._committed_ledger_state, fixture_ledger)) return false;
    return true;
}

} // namespace pk
