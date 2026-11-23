#include "runtime_economy_pod.h"
#include "economy_runtime.h"
#include "runtime_economy_pod_save_internal.h"
#include "runtime_economy_ecp2.h"
#include "economy_hash.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <type_traits>
#include <utility>

namespace pk {

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
        pop.funds.write_scalar(static_cast<size_t>(slot), 10);
        pop.epoch_income.write_scalar(static_cast<size_t>(slot), 0);
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
        owned.state().market.stock.write_scalar(0, 8);
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
        pop.population.write_scalar(static_cast<size_t>(slot), 100);
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
    fixture_population.signature_id.write_scalar(
        RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE, 77);
    fixture_population.population.write_scalar(pod_slot, 17);
    fixture_population.funds.write_scalar(pod_slot, 2300);
    fixture_population.epoch_income.write_scalar(pod_slot, 91);
    fixture_population.epoch_expense.write_scalar(pod_slot, 12);
    fixture_population.generation.write_scalar(pod_slot, 5);
    fixture_population.reserved.write_scalar(pod_slot, 0);
    fixture_population.reservation_owner.write_scalar(pod_slot, 0);
    fixture_population.needs_satisfaction.write_scalar(pod_slot, 40000);
    fixture_population.composite_satisfaction.write_scalar(pod_slot, 42000);
    fixture_population.owner_employed.write_scalar(pod_slot, 3);
    fixture_population.employee_employed.write_scalar(pod_slot, 11);
    fixture_population.population.write_scalar(pod_slot_two, 29);
    fixture_population.funds.write_scalar(pod_slot_two, 4100);
    fixture_population.epoch_income.write_scalar(pod_slot_two, 101);
    fixture_population.epoch_expense.write_scalar(pod_slot_two, 22);
    fixture_population.generation.write_scalar(pod_slot_two, 9);
    fixture_population.reserved.write_scalar(pod_slot_two, 1);
    fixture_population.reservation_owner.write_scalar(pod_slot_two, 99);
    fixture_population.needs_satisfaction.write_scalar(pod_slot_two, 50000);
    fixture_population.composite_satisfaction.write_scalar(pod_slot_two, 51000);
    fixture_population.owner_employed.write_scalar(pod_slot_two, 1);
    fixture_population.employee_employed.write_scalar(pod_slot_two, 4);
    authority.state().market.stock.write_scalar(4, 77);
    authority.state().market.price.write_scalar(4, 19);
    authority.state().market.demand_ema.write_scalar(4, 31);
    authority.state().market.last_shortage_q16.write_scalar(4, 1024);
    authority.state().market.cell_to_market.write_scalar(0, 0);
    authority.state().market.cell_to_market.write_scalar(1, 1);
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
    {
        auto resource_hash_matches = [](const RuntimeEconomyResourceStore &store) {
            std::vector<uint8_t> wire;
            store.append_wire(wire);
            uint64_t expected = FNV_OFFSET;
            for (uint8_t byte : wire) expected = (expected ^ byte) * FNV_PRIME;
            return store.wire_content_hash() == expected && store.wire_content_hash() == expected;
        };
        RuntimeEconomyResourceStore resource;
        resource.resize(2, 3);
        if (!resource_hash_matches(resource)) return false;
        for (size_t i = 0; i < resource.stock.size(); ++i) {
            resource.stock.write_scalar(i, static_cast<int64_t>(i + 1) * 12345);
            if (!resource_hash_matches(resource)) {
                error = "resource_wire_cache_stock_invalidation";
                return false;
            }
        }
        resource.cell_generation.write_scalar(1, 99);
        RuntimeEconomyResourceStore copy = resource;
        if (!resource_hash_matches(resource) || !resource_hash_matches(copy)) return false;
        copy.stock.write_scalar(0, 42);
        resource = copy;
        if (!resource_hash_matches(resource)) return false;
        copy.resize(0, 2);
        resource = std::move(copy);
        if (!resource_hash_matches(resource)) return false;
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
    // Published mirrors may be undigested (ledger_hash 0).
    const auto effective_hash = [](const RuntimeEconomyLedgerState &ledger) {
        return ledger.ledger_hash != 0 ? ledger.ledger_hash : ledger.computed_hash();
    };
    const auto ledgers_equal = [&effective_hash](const RuntimeEconomyLedgerState &left,
                                  const RuntimeEconomyLedgerState &right) {
        return left.source_state_hash == right.source_state_hash &&
            effective_hash(left) == effective_hash(right) &&
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
    {
        RuntimeEconomyPodAuthority incremental;
        if (!incremental.import_committed_ledger(fixture_ledger, error)) return false;
        for (uint64_t step = 0; step < 6; ++step) {
            if (step == 2) incremental._state.market.stock.write_scalar(0,
                incremental._state.market.stock[0] + 7);
            if (step == 3) incremental._state.market.price.write_scalar(1,
                incremental._state.market.price[1] + 5);
            if (step == 4) incremental._state.market.stock.write_scalar(0,
                incremental._state.market.stock[0] - 7);
            (void)incremental.state_hash(); // Hash 的消费不得清掉 Publish 的脏页。
            if (!incremental.publish_owned_committed_mirror(
                    fixture_ledger.generation + step, fixture_ledger.committed_day, error)) return false;
            RuntimeEconomyLedgerState reference;
            if (!incremental.export_committed_ledger(reference, error, false) ||
                !ledgers_equal(incremental._committed_ledger_state, reference)) {
                error = "economy_incremental_market_two_buffer_gap";
                return false;
            }
        }
        const uint64_t previous = effective_hash(incremental._committed_ledger_state);
        const int32_t mapping = incremental._state.market.cell_to_market[0];
        incremental._state.market.cell_to_market.write_scalar(0,
            incremental._state.market.market_count.get() + 1);
        if (incremental.publish_owned_committed_mirror(
                fixture_ledger.generation + 6, fixture_ledger.committed_day, error) ||
            effective_hash(incremental._committed_ledger_state) != previous) {
            error = "economy_incremental_market_failed_publish_changed_snapshot";
            return false;
        }
        incremental._state.market.cell_to_market.write_scalar(0, mapping);
        RuntimeEconomyLedgerState reference;
        if (!incremental.publish_owned_committed_mirror(
                fixture_ledger.generation + 7, fixture_ledger.committed_day, error) ||
            !incremental.export_committed_ledger(reference, error, false) ||
            !ledgers_equal(incremental._committed_ledger_state, reference)) {
            error = "economy_incremental_market_retry_lost_dirty_pages";
            return false;
        }
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
    const uint64_t mirror_hash_before = effective_hash(restored._committed_ledger_state);
    if (restored.import_and_publish_committed_ledger(std::move(bad_hash), rejected_error) ||
        rejected_error != "economy_pod_ledger_hash_invalid" ||
        restored.state_hash() != state_hash_before_reject ||
        effective_hash(restored._committed_ledger_state) != mirror_hash_before) {
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
    const auto published_hash = effective_hash(restored._committed_ledger_state);
    restored.state().building.content_hash ^= 1u;
    if (restored.publish_owned_committed_mirror(
            fixture_ledger.generation, fixture_ledger.committed_day, rejected_error) ||
        effective_hash(restored._committed_ledger_state) != published_hash) {
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
