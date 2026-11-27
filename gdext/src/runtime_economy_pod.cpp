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

#include "runtime_economy_pod_snapshot_ring.inc"
RuntimeEconomyPodAuthority::RuntimeEconomyPodAuthority() {
    reset();
}

#include "runtime_economy_pod_committed_ledger.inc"
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

#include "runtime_economy_pod_owned_commands.inc"
#include "runtime_economy_pod_daily_epoch.inc"
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
