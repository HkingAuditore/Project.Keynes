#include "runtime_resolve_contract.h"
#include "economy_cost_probe.h"
#include "runtime_economy_pod.h"
#include "economy_hash.h"
#include "runtime_economy_pod_save_internal.h"
#include "economy_runtime.h"
#include "runtime_economy_population_store.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <iterator>
#include <type_traits>

namespace pk {
namespace {

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

// Every rule an owned import enforces before touching any state. `verify_digest`
// re-hashes the ledger and requires a digest; only a ledger the caller captured
// from live state on this thread may skip it, and it may carry no digest yet.
bool validate_owned_ledger(const RuntimeEconomyLedgerState &ledger,
                           bool verify_digest, std::string &error) {
    if (verify_digest) {
        if (!ledger.valid()) {
            error = ledger.ledger_hash != 0 && ledger.computed_hash() != ledger.ledger_hash
                ? "economy_pod_ledger_hash_invalid" : "economy_pod_ledger_shape_invalid";
            return false;
        }
    } else if (!ledger.validate_shape_and_values()) {
        error = "economy_pod_ledger_shape_invalid";
        return false;
    }
    if (ledger.market_count <= 0 || ledger.good_count <= 0) {
        error = "economy_pod_ledger_dimensions_invalid";
        return false;
    }
    if (verify_digest && ledger.ledger_hash == 0) {
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

    return true;
}

// Requires validate_owned_ledger(). Builds into a scratch store so a failed
// restore never leaves the destination half written.
bool restore_population_from_ledger(const RuntimeEconomyLedgerState &ledger,
                                    RuntimeEconomyPopulationStore &population,
                                    std::string &error) {
    const size_t lanes = ledger.cohort_active.size();
    constexpr size_t page_size =
        static_cast<size_t>(RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE);
    const size_t page_count = lanes / page_size;
    population.clear(ledger.market_count);
    for (size_t page = 0; page < page_count; ++page) {
        const int32_t cell = ledger.cohort_cell[page * page_size];
        if (!population.restore_page_at(
                static_cast<int32_t>(page), cell)) {
            error = "economy_pod_population_page_restore_failed";
            return false;
        }
    }

    int64_t active_count = 0;
    for (size_t slot = 0; slot < lanes; ++slot) {
        if (ledger.cohort_active[slot] == 0) continue;
        const int32_t cell = ledger.cohort_cell[slot];
        if (population.restore_slot_at(
                static_cast<int32_t>(slot), cell,
                ledger.cohort_signature_id[slot]) < 0) {
            error = "economy_pod_population_slot_restore_failed";
            return false;
        }
        ++active_count;
    }

    population.active = ledger.cohort_active;
    population.signature_id = ledger.cohort_signature_id;
    if (!ledger.cohort_generation.empty())
        population.generation = ledger.cohort_generation;
    if (!ledger.cohort_reserved.empty())
        population.reserved = ledger.cohort_reserved;
    if (!ledger.cohort_reservation_owner.empty())
        population.reservation_owner = ledger.cohort_reservation_owner;
    population.population = ledger.cohort_population;
    population.funds = ledger.cohort_funds;
    population.epoch_income = ledger.cohort_epoch_income;
    population.epoch_expense = ledger.cohort_epoch_expense;
    if (!ledger.cohort_needs_satisfaction.empty())
        population.needs_satisfaction = ledger.cohort_needs_satisfaction;
    if (!ledger.cohort_composite_satisfaction.empty())
        population.composite_satisfaction = ledger.cohort_composite_satisfaction;
    if (!ledger.cohort_owner_employed.empty())
        population.owner_employed = ledger.cohort_owner_employed;
    if (!ledger.cohort_employee_employed.empty())
        population.employee_employed = ledger.cohort_employee_employed;
    population.active_count = active_count;
    return true;
}

// Requires `state.market` freshly cleared to the ledger's dimensions.
void assign_market_from_ledger(const RuntimeEconomyLedgerState &ledger,
                               RuntimeEconomyMarketStore &market) {
    market.stock = ledger.market_stock;
    market.price = ledger.market_price;
    market.demand_ema = ledger.market_demand_ema;
    if (!ledger.market_last_shortage_q16.empty())
        market.last_shortage_q16 = ledger.market_last_shortage_q16;
    if (!ledger.market_cell_to_market.empty()) {
        market.cell_to_market = ledger.market_cell_to_market;
    } else if (market.cell_to_market.size() !=
            static_cast<size_t>(std::max(0, ledger.market_count))) {
        // The ledger did not carry the cell→market column, so rebuild it from the
        // identity mapping `RuntimeEconomyMarketStore::clear()` uses.
        //
        // Leaving it empty is not benign: `NativeEconomyRuntime::begin_save` gates on
        // `market_store().cell_to_market.size() != cells` and answers
        // `economy_save_state_shape_invalid`. That gate runs when
        // `apply_ecp2_authority` takes its pre-apply ROLLBACK BACKUP, so a restored POD
        // state could not be restarted at all -- `start_runtime_worker` died with
        // `ecp2_atomic_backup_failed`, and production hits that on every load
        // (`world_runtime_host.gd:804` restores the bundle and then starts the worker).
        //
        // Measured before this: `[save-shape] market_cell_to_market actual=0
        // expected=192`.
        const size_t markets = static_cast<size_t>(std::max(0, ledger.market_count));
        market.cell_to_market.resize(markets);
        for (size_t cell = 0; cell < markets; ++cell)
            market.cell_to_market.write_scalar(cell, static_cast<int32_t>(cell));
    }
}

template<class T>
void overwrite_lanes(EconomyTrackedColumn<T> &column, const std::vector<T> &source) {
    column.write_values(0, source.data(), source.size());
}

// Same result as clear() + assign_market_from_ledger(), but only lanes whose
// value changed are written, so the change registry (and the POD hash pages
// fed from it) see the real daily delta instead of a full reshape.
bool overwrite_market_from_ledger(const RuntimeEconomyLedgerState &ledger,
                                  RuntimeEconomyMarketStore &market) {
    const size_t markets = static_cast<size_t>(ledger.market_count);
    const size_t lanes = markets * static_cast<size_t>(ledger.good_count);
    if (market.market_count.get() != ledger.market_count ||
        market.good_count.get() != ledger.good_count ||
        ledger.market_stock.size() != lanes || ledger.market_price.size() != lanes ||
        ledger.market_demand_ema.size() != lanes ||
        ledger.market_last_shortage_q16.size() != lanes ||
        ledger.market_cell_to_market.size() != markets ||
        market.stock.size() != lanes || market.price.size() != lanes ||
        market.demand_ema.size() != lanes || market.last_shortage_q16.size() != lanes ||
        market.cell_to_market.size() != markets) {
        return false;
    }
    overwrite_lanes(market.stock, ledger.market_stock);
    overwrite_lanes(market.price, ledger.market_price);
    overwrite_lanes(market.demand_ema, ledger.market_demand_ema);
    overwrite_lanes(market.last_shortage_q16, ledger.market_last_shortage_q16);
    overwrite_lanes(market.cell_to_market, ledger.market_cell_to_market);
    if (market.price_ceilings.size() != markets) {
        market.price_ceilings.clear();
        market.price_ceilings.resize(markets);
    } else {
        for (size_t row = 0; row < markets; ++row) {
            if (!market.price_ceilings[row].empty())
                market.price_ceilings.write_record(row, {});
        }
    }
    return true;
}

// The committed ledger is published separately as _committed_ledger_state;
// `state.committed` is left cleared rather than holding a third copy of it.
void assign_owned_blocks_from_ledger(const RuntimeEconomyLedgerState &ledger,
                                     RuntimeEconomyOwnedState &state) {
    state.state_generation = ledger.generation;
    state.committed_day = ledger.committed_day;
    state.building = ledger.building;
    if (ledger.building.captured)
        state.buildings = ledger.building.store;
    state.trade_escrow = ledger.trade_escrow;
    if (ledger.trade_escrow.captured)
        state.trade_orders = ledger.trade_escrow.store;
    state.family = ledger.family;
    if (ledger.family.captured)
        state.families = ledger.family.store;
    state.resource = ledger.resource;
    if (ledger.resource.captured)
        state.resources = ledger.resource.store;
    state.epoch_cursor = ledger.epoch_cursor;
    if (ledger.epoch_cursor.captured)
        state.epoch_cursors = ledger.epoch_cursor.store;
    // Preserve exactly the validated archive's captured blocks. Older ABIs may
    // omit family/resource/cursors; inventing those captures falsely promotes
    // incomplete state and makes the next save claim data it never restored.
}

} // namespace

namespace economy_pod_internal {

bool build_owned_state_from_ledger(const RuntimeEconomyLedgerState &ledger,
                                   RuntimeEconomyOwnedState &restored,
                                   std::string &error) {
    if (!validate_owned_ledger(ledger, true, error)) return false;
    RuntimeEconomyPopulationStore population;
    if (!restore_population_from_ledger(ledger, population, error)) return false;
    RuntimeEconomyOwnedState candidate;
    candidate.clear(ledger.market_count, ledger.good_count);
    candidate.population = std::move(population);
    assign_market_from_ledger(ledger, candidate.market);
    assign_owned_blocks_from_ledger(ledger, candidate);
    restored = std::move(candidate);
    return true;
}

} // namespace economy_pod_internal

using economy_pod_internal::build_owned_state_from_ledger;

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
    if (runtime_chunk_hash_enabled()) {
        mix(RuntimeChunkHash::VERSION);
        mix(_state.market_hash_pages[0].update(_state.market.stock, 1, 1));
        mix(_state.market_hash_pages[1].update(_state.market.price, 1, 2));
        mix(_state.market_hash_pages[2].update(_state.market.demand_ema, 1, 3));
        mix(_state.market_hash_pages[3].update(_state.market.last_shortage_q16, 1, 4));
    } else {
        for (size_t i = 0; i < _state.market.stock.size(); ++i) {
            mix(static_cast<uint64_t>(_state.market.stock[i]));
            mix(static_cast<uint64_t>(_state.market.price[i]));
            mix(static_cast<uint64_t>(_state.market.demand_ema[i]));
            mix(_state.market.last_shortage_q16[i]);
        }
    }
    return hash;
}

bool RuntimeEconomyPodAuthority::import_committed_ledger(
        const RuntimeEconomyLedgerState &ledger, std::string &error) {
    error.clear();
    RuntimeEconomyOwnedState restored;
    if (!build_owned_state_from_ledger(ledger, restored, error)) return false;
    // Replacing the contents of a store a formula owner is bound to does not
    // disown it: the owner keeps the same object. Carry the ownership flag over
    // so a later protocol reset still knows not to zero the lanes.
    restored.formula_owner_bound = _state.formula_owner_bound;
    _state = std::move(restored);
    _market_export_warmup = 0;
    return true;
}

bool RuntimeEconomyPodAuthority::import_and_publish_committed_ledger(
        RuntimeEconomyLedgerState &&ledger, std::string &error) {
    error.clear();
    RuntimeEconomyOwnedState restored;
    // Validate all shapes and hashes once, before changing either publication.
    // No producer can mutate this local ledger between validation and move.
    if (!build_owned_state_from_ledger(ledger, restored, error)) return false;
    restored.formula_owner_bound = _state.formula_owner_bound;
    _state = std::move(restored);
    _committed_ledger_state = std::move(ledger);
    _market_export_warmup = 0;
    publish_mirror_features();
    return true;
}

bool RuntimeEconomyPodAuthority::import_and_publish_captured_ledger(
        RuntimeEconomyLedgerState &ledger, std::string &error) {
    error.clear();
    const int64_t probe_day = ledger.committed_day;
    auto probe_started = std::chrono::steady_clock::now();
    const auto probe_lap = [&](const char *name) {
        const auto now = std::chrono::steady_clock::now();
        EconomyCostProbe::record(name, probe_day,
            std::chrono::duration<double, std::milli>(now - probe_started).count());
        probe_started = now;
    };
    if (!validate_owned_ledger(ledger, false, error)) return false;
    RuntimeEconomyPopulationStore population;
    if (!restore_population_from_ledger(ledger, population, error)) return false;
    probe_lap("mirror.import.validate");
    // Nothing below can fail: the ledger is fully validated and the population
    // already restored, so `_state` is never left half written.
    const bool in_place = state_initialized() &&
        overwrite_market_from_ledger(ledger, _state.market);
    if (in_place) {
        _state.clear_except_market(ledger.market_count);
    } else {
        _state.clear(ledger.market_count, ledger.good_count);
        assign_market_from_ledger(ledger, _state.market);
    }
    _state.population = std::move(population);
    probe_lap(in_place ? "mirror.import.market_in_place" : "mirror.import.market_rebuild");
    assign_owned_blocks_from_ledger(ledger, _state);
    // The caller gets the previous publication back as its next capture buffer.
    std::swap(_committed_ledger_state, ledger);
    _market_export_warmup = 0;
    publish_mirror_features();
    probe_lap("mirror.import.blocks");
    static const bool verify = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MIRROR_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (verify) {
        RuntimeEconomyLedgerState roundtrip;
        std::string verify_error;
        const uint64_t published_hash = _committed_ledger_state.ledger_hash != 0
            ? _committed_ledger_state.ledger_hash
            : _committed_ledger_state.computed_hash();
        if (!export_committed_ledger(roundtrip, verify_error) ||
            roundtrip.ledger_hash != published_hash) {
            std::fprintf(stderr,
                "economy_mirror_import_mismatch day=%lld in_place=%d error=%s\n",
                static_cast<long long>(probe_day), in_place ? 1 : 0,
                verify_error.c_str());
            std::abort();
        }
    }
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
    // Published undigested like the captured mirror; readers hash on demand.
    const char *full_market = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MARKET_PUBLISH_FULL);
    const bool incremental_market = !(full_market && std::strcmp(full_market, "1") == 0);
    if (!export_committed_ledger_internal(ledger, error, false, incremental_market)) return false;
    const char *verify = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MIRROR_VERIFY);
    if (verify && std::strcmp(verify, "1") == 0) {
        RuntimeEconomyLedgerState reference;
        if (!export_committed_ledger(reference, error, false) ||
            reference.computed_hash() != ledger.computed_hash()) {
            if (error.empty()) error = "economy_incremental_market_publish_mismatch";
            _market_export_warmup = 0;
            return false;
        }
    }
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
        RuntimeEconomyLedgerState &ledger, std::string &error,
        bool compute_hash) const {
    return export_committed_ledger_internal(ledger, error, compute_hash, false);
}

bool RuntimeEconomyPodAuthority::export_committed_ledger_internal(
        RuntimeEconomyLedgerState &ledger, std::string &error,
        bool compute_hash, bool incremental_market) const {
    error.clear();
    const bool reuse_market = incremental_market && _market_export_warmup >= 2 &&
        ledger.market_count == _state.market.market_count.get() &&
        ledger.good_count == _state.market.good_count.get();
    if (!incremental_market) ledger.clear();
    // 以下字段全部重新赋值；增量路径只保留私有缓冲中的市场列容量和数值。
    ledger.source_state_hash = 0;
    ledger.ledger_hash = 0;
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
    uint64_t market_copied_bytes = 0;
    uint64_t market_dense_bytes = 0;
    const auto copy_market_column = [&](auto &target, const auto &column, size_t index) {
        using Value = typename std::decay_t<decltype(column)>::value_type;
        market_dense_bytes += column.size() * sizeof(Value);
        std::vector<uint64_t> changed;
        if (incremental_market)
            changed = column.take_change_pages(EconomyChangeConsumer::Publish);
        if (!reuse_market || target.size() != column.size()) {
            target = column.values();
            market_copied_bytes += column.size() * sizeof(Value);
        } else {
            // scratch 比当前发布落后两代，必须合并前一代与本代脏页。
            const auto &previous = _market_export_previous_pages[index];
            std::vector<uint64_t> pages;
            pages.reserve(previous.size() + changed.size());
            std::set_union(previous.begin(), previous.end(), changed.begin(), changed.end(),
                std::back_inserter(pages));
            constexpr size_t lanes_per_page = 4096 / sizeof(Value);
            for (uint64_t page : pages) {
                const size_t first = static_cast<size_t>(page) * lanes_per_page;
                if (first >= column.size()) continue;
                const size_t count = std::min(lanes_per_page, column.size() - first);
                std::copy_n(column.data() + first, count, target.data() + first);
                market_copied_bytes += count * sizeof(Value);
            }
        }
        if (incremental_market) _market_export_previous_pages[index] = std::move(changed);
    };
    copy_market_column(ledger.market_stock, _state.market.stock, 0);
    copy_market_column(ledger.market_price, _state.market.price, 1);
    copy_market_column(ledger.market_demand_ema, _state.market.demand_ema, 2);
    copy_market_column(ledger.market_last_shortage_q16, _state.market.last_shortage_q16, 3);
    copy_market_column(ledger.market_cell_to_market, _state.market.cell_to_market, 4);
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
    if (!ledger.validate_shape_and_values(&validation_reason)) {
        if (incremental_market) _market_export_warmup = 0;
        error = std::string("economy_pod_ledger_export_invalid:") +
            (validation_reason != nullptr ? validation_reason : "unknown");
        return false;
    }
    const auto hash_started = std::chrono::steady_clock::now();
    if (compute_hash) ledger.recompute_hash();
    if (incremental_market) _market_export_warmup = std::min<uint32_t>(2u, _market_export_warmup + 1u);
    EconomyCostProbe::record("ledger_export.market_copied_bytes", ledger.committed_day,
        0.0, market_copied_bytes);
    EconomyCostProbe::record("ledger_export.market_dense_bytes", ledger.committed_day,
        0.0, market_dense_bytes);
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
    _market_export_warmup = 0;
    for (auto &pages : _market_export_previous_pages) pages.clear();
    // The dense population/market lanes belong to whichever formula owner is
    // bound to them, not to this protocol object. Zeroing them while a writer
    // still holds the pointer is what killed every restarted worker lifetime on
    // its first Economy day: `start()` resets this authority for the new
    // lifetime, the bound NativeEconomyRuntime kept `_formula_owned` pointing at
    // this store, and the next day's first market read asked for
    // `market.stock[51]` in a matrix whose size was 0 (measured:
    // `[economy-tracking-range] reason=economy_column_read_range_invalid
    // field=market.stock index=51 size=0`, then `unhandled_worker_exception`).
    // Leaving the lanes intact is safe because everything below still clears the
    // protocol state that decides whether a mirror may be published.
    if (!_state.formula_owner_bound) {
        _state.clear(0, 0);
    }
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
    _market_export_warmup = 0;
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
        population.funds.write_scalar(static_cast<size_t>(slot), sat_add(
            population.funds[static_cast<size_t>(slot)], amount));
        population.epoch_income.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_income[static_cast<size_t>(slot)], amount));
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
        population.funds.write_scalar(static_cast<size_t>(slot), sat_add(
            population.funds[static_cast<size_t>(slot)], command.payload0));
        population.epoch_income.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_income[static_cast<size_t>(slot)],
            command.payload0));
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
        population.funds.write_scalar(static_cast<size_t>(slot), funds - amount);
        population.epoch_expense.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_expense[static_cast<size_t>(slot)], amount));
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
        market.stock.write_scalar(static_cast<size_t>(idx),
            sat_add(before, command.payload0));
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
        market.stock.write_scalar(static_cast<size_t>(idx), stock - amount);
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
        population.population.write_scalar(static_cast<size_t>(slot), after);
        population.owner_employed.write_scalar(static_cast<size_t>(slot), std::clamp<int64_t>(
                population.owner_employed[static_cast<size_t>(slot)], 0,
                after));
        population.employee_employed.write_scalar(static_cast<size_t>(slot), std::clamp<int64_t>(
                population.employee_employed[static_cast<size_t>(slot)], 0,
                after - population.owner_employed[static_cast<size_t>(slot)]));
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
    case NativeEconomyRuntime::COMMAND_MILITARY_CONVERT_COHORT: {
        // B: state-directed conversion inside one cell. payload0 = heads,
        // target_country = destination signature, payload1 = source signature,
        // target_cell = the cell. Both cohorts are resolved in THIS store, so
        // no slot id crosses an execution boundary and the move is conserved
        // inside the same cell.
        const int32_t conv_cell = command.target_cell;
        const int32_t dest_signature = static_cast<int32_t>(command.target_country);
        const int32_t source_signature = static_cast<int32_t>(command.payload1);
        if (conv_cell < 0 || dest_signature < 0 || source_signature < 0) {
            error = "military_convert_target_invalid";
            return false;
        }
        int32_t src = population.find_signature(conv_cell,
            static_cast<uint32_t>(source_signature));
        if (src < 0 || population.active[static_cast<size_t>(src)] == 0) {
            error = "military_convert_source_missing";
            return false;
        }
        const int64_t want = std::max<int64_t>(0, command.payload0);
        const int64_t available = std::max<int64_t>(0, population.population[static_cast<size_t>(src)]);
        const int64_t moved = std::min(want, available);
        if (moved <= 0) {
            error = "military_convert_source_empty";
            return false;
        }
        int32_t dst = population.find_signature(conv_cell,
            static_cast<uint32_t>(dest_signature));
        if (dst < 0) {
            dst = population.allocate_slot(conv_cell, static_cast<uint32_t>(dest_signature));
            if (dst < 0) {
                error = "military_convert_allocation_failed";
                return false;
            }
        }
        population.population.write_scalar(static_cast<size_t>(src),
            available - moved);
        population.population.write_scalar(static_cast<size_t>(dst),
            std::max<int64_t>(0, population.population[static_cast<size_t>(dst)]) + moved);
        settled_out = moved;
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
        // CHANGE_SIGNATURE's destination signature rides payload1. The
        // project-wide target_country / target_cell lanes already carry the
        // market id, good id and destination cell, so putting a signature there
        // turned the cell into a signature and failed commit validation.
        int32_t destination_signature =
            static_cast<int32_t>(population.signature_id[static_cast<size_t>(slot)]);
        if (command.opcode == NativeEconomyRuntime::COMMAND_CHANGE_SIGNATURE) {
            destination_signature = command.payload1 > 0
                ? static_cast<int32_t>(command.payload1)
                : static_cast<int32_t>(command.target_country);
        }
        structural.signature = destination_signature;
        // The POD mirror and the live runtime do not share cohort slot ids, so
        // the source is re-resolved at commit time from (cell, source signature).
        // The funds lane is unused for a signature move and carries that id.
        structural.funds = command.opcode == NativeEconomyRuntime::COMMAND_CHANGE_SIGNATURE
            ? static_cast<int64_t>(population.signature_id[static_cast<size_t>(slot)])
            : 0;
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
        population.funds.write_scalar(static_cast<size_t>(slot), funds - amount);
        population.epoch_expense.write_scalar(static_cast<size_t>(slot), sat_add(
            population.epoch_expense[static_cast<size_t>(slot)], amount));
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
        buildings.group_units.write_scalar(static_cast<size_t>(group_id), buildings.group_units[static_cast<size_t>(group_id)] - (count));
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
        market.stock.write_scalar(static_cast<size_t>(idx),
            sat_add(before, command.payload0));
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
        market.stock.write_scalar(static_cast<size_t>(idx), stock - amount);
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
        const uint32_t resume = _stage_ops->resume_stage_index();
        if (resume >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) {
            error = "economy_pod_resume_stage_invalid";
            return false;
        }
        _scratch.stage_index = resume;
        _stage_cursor.stage_index = resume;
        // Earlier stages are already complete in the surviving formula owner.
        // Their old timings/hashes are unavailable; never replay their mutations.
        _completed_stage_mask = (1u << resume) - 1u;
        _replay.completed_stage_mask = _completed_stage_mask;
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
    _replay.stage_ms[index] += ms;
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
            const size_t index = static_cast<size_t>(stage);
            if (index < RuntimeEconomyPodReplayReport::STAGE_COUNT) {
                _replay.stage_ms[index] += elapsed_ms(begin);
            }
            // Peer parks must not poison the epoch. commit_epoch treats any
            // replay fatal as economy_pod_fatal even if the slice later retries.
            const bool peer_park =
                error == "country_research_peer_results" ||
                error == "fiscal_settlement_peer_pending" ||
                error == "fiscal_reserve_peer_results" ||
                error == "fiscal_peer_results" ||
                runtime_country_asset_pending_reason(error);
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
    if (const auto *receipt = resolve_find_receipt(_terminal_receipts, command.request_id)) {
        const auto copy = *receipt; _receipts.push_back(copy); return true;
    }
    if (const auto *receipt = resolve_find_receipt(_receipts, command.request_id)) {
        const auto copy = *receipt; _receipts.push_back(copy); return true;
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
    // Phase 4: admit the legacy opcodes 1..23 plus the military cohort-convert
    // opcode (24), which carries no cohort slot id and is applied inside this
    // store by the plan stage. The army personnel lane (contract §1.2 and
    // contract 2 §1.1) admits 30/31/32/33 on the same terms: they name the army
    // by Military handle and the cohort by (cell, signature), never by a slot id.
    // Army pay (34, army-pay contract §1.3) rides the same lane: it names the
    // army by handle and moves treasury cash only, so it is admitted here too.
    const bool military_convert =
        command.opcode == NativeEconomyRuntime::COMMAND_MILITARY_CONVERT_COHORT;
    const bool army_personnel_lane =
        command.opcode == NativeEconomyRuntime::COMMAND_ARMY_EMBARK ||
        command.opcode == NativeEconomyRuntime::COMMAND_ARMY_DISEMBARK ||
        command.opcode == NativeEconomyRuntime::COMMAND_ARMY_MERGE_LANES ||
        command.opcode == NativeEconomyRuntime::COMMAND_ARMY_SPLIT_LANES ||
        command.opcode == NativeEconomyRuntime::COMMAND_ARMY_LANE_PAY;
    if (!military_convert && !army_personnel_lane && command.opcode != NativeEconomyRuntime::COMMAND_MILITARY_PROCUREMENT_DEMAND &&
        command.opcode != NativeEconomyRuntime::COMMAND_MILITARY_PURCHASE &&
        command.opcode != NativeEconomyRuntime::COMMAND_MILITARY_PURCHASE_ACK && command.opcode != NativeEconomyRuntime::COMMAND_TREASURY_SPONSORED_DEMOLISH &&
        (command.opcode < 1 || command.opcode > 23)) {
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
    const auto admission = resolve_enqueue<ResolveFlow::EconomyCommand>(
        _commands, command, RUNTIME_ECONOMY_COMMAND_CAPACITY);
    if (admission != ResolveResult::Accepted) return reject_admission(resolve_reason(admission));
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

const RuntimeEconomyPodReceipt *RuntimeEconomyPodAuthority::terminal_receipt(uint64_t request) const {
    const auto result = std::find_if(_terminal_receipts.rbegin(), _terminal_receipts.rend(),
        [request](const auto &row) { return row.request_id == request; });
    return result != _terminal_receipts.rend() ? &*result : nullptr;
}

bool RuntimeEconomyPodAuthority::poll_receipt(
        RuntimeEconomyPodReceipt &out) noexcept {
    if (_receipts.empty()) return false;
    out = _receipts.front();
    _receipts.erase(_receipts.begin());
    return true;
}

} // namespace pk
