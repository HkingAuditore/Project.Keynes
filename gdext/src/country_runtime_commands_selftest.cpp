#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_api.h"
#include "country_core_apply.h"

#include <algorithm>

namespace pk {

using namespace godot;

bool NativeCountryRuntime::protocol_contract_self_test(std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF ||
        _command_batch.active || _boundary_seal_active ||
        !_pending_commands.empty() || _peer_async_mode ||
        !_peer_pending_intents.empty() || !_peer_intent_queue.empty() ||
        !_peer_result_cache.empty()) {
        error = "country_protocol_test_requires_idle_runtime";
        return false;
    }
    int32_t slot = -1;
    for (int32_t candidate = 0;
         candidate < static_cast<int32_t>(_countries.active.size());
         ++candidate) {
        if (_countries.active[static_cast<size_t>(candidate)] != 0) {
            slot = candidate;
            break;
        }
    }
    if (slot < 0) {
        error = "country_protocol_test_country_missing";
        return false;
    }
    {
        // Military opcodes run on a detached copy so the live authority,
        // peers and Host are never touched by the annex probe.
        NativeCountryRuntime scratch(*this);
        scratch._simulation_host = nullptr;
        scratch._effect_runtime = nullptr;
        scratch._effect_forwarder = nullptr;
        scratch._effect_runtime_enabled = false;
        scratch._modifier_runtime = nullptr;
        scratch._economy_runtime = nullptr;
        if (!scratch.military_opcode_self_test(error)) return false;
    }
    int32_t owned_cell = -1;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_cell_country_slot[static_cast<size_t>(cell)] == slot) {
            owned_cell = cell;
            break;
        }
    }
    if (owned_cell < 0) {
        error = "country_protocol_test_territory_missing";
        return false;
    }

    CountryCommandReceipt discarded;
    while (poll_typed_receipt(discarded)) {}
    const int64_t day = std::max<int64_t>(0, _last_committed_day + 1);
    const uint64_t handle = make_handle(slot);
    const uint64_t request_base =
        (0x4354525900000000ULL ^ (_session_epoch << 16U) ^
         (_generation << 8U)) & ~0xffULL;
    CountryTypedCommand first;
    first.request_id = request_base | 1ULL;
    first.producer_id = 7;
    first.sequence = 100;
    first.observed_generation = _generation;
    first.effective_day = day;
    first.opcode = COMMAND_RENAME_COUNTRY;
    first.target_handle = handle;
    first.display_name = "protocol.first";
    std::vector<CountryCommandReceipt> receipts;
    if (!submit_typed_commands(&first, 1, receipts, error) ||
        receipts.size() != 1 ||
        receipts[0].code != CountryCommandReceiptCode::ACCEPTED) {
        if (error.empty()) error = "country_protocol_test_first_admission";
        return false;
    }

    CountryBoundarySeal seal;
    const uint64_t explicit_boundary = _next_boundary_id + 100;
    if (!seal_boundary(_session_epoch, explicit_boundary, day, seal, error))
        return false;

    CountryTypedCommand second = first;
    second.request_id = request_base | 2ULL;
    second.sequence = 101;
    second.display_name = "protocol.second";
    if (!submit_typed_commands(&second, 1, receipts, error) ||
        receipts.size() != 1 ||
        receipts[0].code != CountryCommandReceiptCode::ACCEPTED) {
        if (error.empty()) error = "country_protocol_test_second_admission";
        return false;
    }
    const CountryCoreStepResult first_step = run_slice_core(day);
    if (first_step.status != CountryCoreStepStatus::BOUNDARY_COMMITTED ||
        first_step.seal.boundary_id != explicit_boundary ||
        first_step.seal.last_admitted_submit_order != seal.last_admitted_submit_order ||
        _countries.display_name[static_cast<size_t>(slot)] != "protocol.first") {
        error = "country_protocol_test_seal_watermark";
        return false;
    }
    CountryCommandReceipt terminal;
    if (!poll_typed_receipt(terminal) ||
        terminal.request_id != first.request_id ||
        terminal.code != CountryCommandReceiptCode::COMMITTED ||
        poll_typed_receipt(discarded)) {
        error = "country_protocol_test_first_terminal";
        return false;
    }

    const CountryCoreStepResult second_step = run_slice_core(day);
    if (second_step.status != CountryCoreStepStatus::BOUNDARY_COMMITTED ||
        second_step.seal.boundary_id == explicit_boundary ||
        _countries.display_name[static_cast<size_t>(slot)] != "protocol.second" ||
        !poll_typed_receipt(terminal) ||
        terminal.request_id != second.request_id ||
        terminal.code != CountryCommandReceiptCode::COMMITTED) {
        error = "country_protocol_test_second_terminal";
        return false;
    }

    CountryTypedCommand rejected = first;
    rejected.request_id = request_base | 3ULL;
    rejected.sequence = 102;
    rejected.observed_generation = _generation;
    rejected.effective_day = day + 1;
    rejected.opcode = COMMAND_CLAIM_UNOWNED_TERRITORY;
    rejected.cell = owned_cell;
    rejected.display_name.clear();
    if (!submit_typed_commands(&rejected, 1, receipts, error)) return false;
    const uint64_t generation_before_rejection = _generation;
    const CountryCoreStepResult rejected_step = run_slice_core(day + 1);
    if (rejected_step.status != CountryCoreStepStatus::REJECTED ||
        _generation != generation_before_rejection ||
        !poll_typed_receipt(terminal) ||
        terminal.request_id != rejected.request_id ||
        terminal.code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION) {
        error = "country_protocol_test_execution_rejection";
        return false;
    }

    if (!submit_typed_commands(&first, 1, receipts, error) ||
        receipts.size() != 1 ||
        receipts[0].code != CountryCommandReceiptCode::COMMITTED ||
        !_pending_commands.empty()) {
        error = "country_protocol_test_idempotent_replay";
        return false;
    }

    const uint64_t expected_hash = compute_state_hash();
    const uint64_t previous_session = _session_epoch;
    CountryCoreCheckpoint captured;
    if (!capture_core_checkpoint(captured, error)) return false;
    std::vector<uint8_t> encoded;
    if (!encode_country_core_checkpoint(captured, encoded, error)) return false;
    CountryCoreCheckpoint decoded;
    if (!decode_country_core_checkpoint(encoded.data(), encoded.size(),
                                        decoded, error) ||
        decoded.canonical_pkcn != captured.canonical_pkcn ||
        decoded.business_state_hash != expected_hash) {
        if (error.empty()) error = "country_protocol_test_checkpoint_roundtrip";
        return false;
    }
    std::vector<uint8_t> corrupted = encoded;
    corrupted[corrupted.size() / 2u] ^= 0x1u;
    CountryCoreCheckpoint rejected_checkpoint;
    std::string corruption_error;
    if (decode_country_core_checkpoint(corrupted.data(), corrupted.size(),
                                       rejected_checkpoint,
                                       corruption_error)) {
        error = "country_protocol_test_checkpoint_corruption";
        return false;
    }
    CountryCoreCheckpoint mismatched = decoded;
    mismatched.business_state_hash ^= FNV_PRIME;
    const uint64_t rejected_generation = _generation;
    const uint64_t rejected_session = _session_epoch;
    std::string mismatch_error;
    if (restore_core_checkpoint(mismatched, mismatch_error) ||
        mismatch_error != "country_checkpoint_business_state_mismatch" ||
        _generation != rejected_generation ||
        _session_epoch != rejected_session ||
        compute_state_hash() != expected_hash) {
        error = "country_protocol_test_checkpoint_rejection_not_atomic";
        return false;
    }
    std::vector<uint8_t> after_rejection;
    if (!encode_save(after_rejection, error) ||
        after_rejection != captured.canonical_pkcn) {
        if (error.empty())
            error = "country_protocol_test_checkpoint_rejection_mutated_state";
        return false;
    }
    if (!restore_core_checkpoint(decoded, error) ||
        _session_epoch == previous_session ||
        compute_state_hash() != expected_hash ||
        _typed_request_state.size() != decoded.request_states.size() ||
        _next_boundary_id != decoded.next_boundary_id) {
        if (error.empty()) error = "country_protocol_test_checkpoint_restore";
        return false;
    }
    return true;
}

bool NativeCountryRuntime::military_opcode_self_test(std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF ||
        _command_batch.active || _boundary_seal_active ||
        !_pending_commands.empty()) {
        error = "country_military_test_requires_idle_runtime";
        return false;
    }
    int32_t a = -1;
    for (int32_t s = 0; s < static_cast<int32_t>(_countries.active.size()); ++s)
        if (_countries.active[static_cast<size_t>(s)] != 0 &&
            _countries.territory_count[static_cast<size_t>(s)] > 0) { a = s; break; }
    if (a < 0) { error = "country_military_test_country_missing"; return false; }
    // Second country: a neutral land cell, else a spare cell of A.
    int32_t spawn_cell = -1;
    for (int32_t cell = 0; cell < _cell_count && spawn_cell < 0; ++cell)
        if (_is_water[static_cast<size_t>(cell)] == 0 &&
            _cell_country_slot[static_cast<size_t>(cell)] == NEUTRAL_SLOT)
            spawn_cell = cell;
    if (spawn_cell < 0 && _countries.territory_count[static_cast<size_t>(a)] >= 2)
        spawn_cell = _country_cells[static_cast<size_t>(
            _country_cell_offsets[static_cast<size_t>(a) + 1u] - 1)];
    if (spawn_cell < 0) return true; // map cannot host a second country
    CountryCommandReceipt discarded;
    while (poll_typed_receipt(discarded)) {}
    int64_t day = std::max<int64_t>(0, _last_committed_day + 1);
    uint64_t next_request = 0x4d494c0000000000ULL ^ (_generation << 8U);
    std::vector<CountryCommandReceipt> receipts;
    const auto run_batch = [&](std::vector<CountryTypedCommand> commands,
                               CountryCoreStepResult &step) -> bool {
        for (CountryTypedCommand &command : commands) {
            command.request_id = ++next_request;
            command.producer_id = 77;
            command.sequence = static_cast<uint64_t>(next_request & 0xffffU) + 1u;
            command.effective_day = day;
        }
        if (!submit_typed_commands(commands.data(), commands.size(), receipts, error))
            return false;
        step = run_slice_core(day++);
        while (poll_typed_receipt(discarded)) {}
        return true;
    };
    CountryCoreStepResult step;
    CountryTypedCommand create;
    create.opcode = COMMAND_CREATE_COUNTRY;
    create.stable_id = "military.selftest.victim";
    create.display_name = "Military Selftest";
    create.cell = spawn_cell;
    if (!run_batch({create}, step)) return false;
    if (step.status != CountryCoreStepStatus::BOUNDARY_COMMITTED) {
        error = "country_military_test_create_failed:" + step.reason;
        return false;
    }
    const int32_t b = static_cast<int32_t>(_countries.active.size()) - 1;
    const uint64_t handle_a = make_handle(a);
    const uint64_t handle_b = make_handle(b);
    const size_t goods = _good_ids.size();
    // Seed the detached copy's treasuries directly.
    _countries.cash[static_cast<size_t>(a)] = 1000;
    _countries.cash[static_cast<size_t>(b)] = 50;
    if (goods > 0) {
        _country_goods[static_cast<size_t>(a) * goods] = 7;
        _country_goods[static_cast<size_t>(b) * goods] = 3;
    }
    _economy_asset_reserved_cash.assign(_countries.active.size(), 0);
    _economy_asset_reserved_goods.assign(_countries.active.size() * goods, 0);
    _state_hash_cache_valid = false;
    const auto receiver_fields = [](CountryTypedCommand &command, uint64_t receiver) {
        command.cell = static_cast<int32_t>(receiver & 0xffffffffULL);
        command.aux = static_cast<int32_t>(receiver >> 32U);
    };
    const int64_t cash_total_before = total_cash();
    const int64_t good_total_before = goods > 0 ? total_good(0) : 0;
    {
        std::vector<CountryTypedCommand> batch(goods > 0 ? 3 : 2);
        batch[0].opcode = COMMAND_TRANSFER_CASH_BETWEEN_COUNTRIES;
        batch[0].target_handle = handle_a;
        batch[0].value = 400;
        receiver_fields(batch[0], handle_b);
        batch[1].opcode = COMMAND_TRANSFER_CASH_BETWEEN_COUNTRIES;
        batch[1].target_handle = handle_b;
        batch[1].value = 999; // only 450 available -> min(balance, value)
        receiver_fields(batch[1], handle_a);
        if (goods > 0) {
            batch[2].opcode = COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES;
            batch[2].target_handle = handle_a;
            batch[2].domain = 0;
            batch[2].value = 10; // only 7 available
            receiver_fields(batch[2], handle_b);
        }
        if (!run_batch(batch, step)) return false;
    }
    if (step.status != CountryCoreStepStatus::BOUNDARY_COMMITTED ||
        _countries.cash[static_cast<size_t>(a)] != 1050 ||
        _countries.cash[static_cast<size_t>(b)] != 0 ||
        total_cash() != cash_total_before ||
        (goods > 0 && (_country_goods[static_cast<size_t>(a) * goods] != 0 ||
                       _country_goods[static_cast<size_t>(b) * goods] != 10 ||
                       total_good(0) != good_total_before))) {
        error = "country_military_test_transfer_failed:" + step.reason;
        return false;
    }
    {
        // Reserved opcodes are rejected at admission.
        CountryTypedCommand reserved;
        reserved.request_id = ++next_request;
        reserved.opcode = COMMAND_RESERVED_22;
        reserved.target_handle = handle_a;
        reserved.effective_day = day;
        std::string reserved_error;
        if (submit_typed_commands(&reserved, 1, receipts, reserved_error) ||
            reserved_error != "country_command_opcode_unsupported") {
            error = "country_military_test_reserved_opcode_accepted";
            return false;
        }
    }
    // Annex followed by a stale-handle command in the same batch rejects it.
    const uint64_t generation_before_reject = _generation;
    CountryTypedCommand annex;
    annex.opcode = COMMAND_ANNEX_COUNTRY;
    annex.target_handle = handle_b;
    receiver_fields(annex, handle_a);
    CountryTypedCommand stale_rename;
    stale_rename.opcode = COMMAND_RENAME_COUNTRY;
    stale_rename.target_handle = handle_b;
    stale_rename.display_name = "stale";
    if (!run_batch({annex, stale_rename}, step)) return false;
    if (step.status != CountryCoreStepStatus::REJECTED ||
        step.reason != "country_handle_invalid" ||
        _generation != generation_before_reject ||
        _countries.active[static_cast<size_t>(b)] == 0) {
        error = "country_military_test_stale_in_batch_not_rejected";
        return false;
    }
    // Worker kernel parity input: committed state immediately before annex.
    RuntimeCountryPodSnapshot worker;
    RuntimeCountryPodCatalog worker_catalog;
    if (!export_pod_snapshot(worker, error) ||
        !export_pod_catalog(worker_catalog, error)) return false;
    const int32_t territory_a = _countries.territory_count[static_cast<size_t>(a)];
    const int32_t territory_b = _countries.territory_count[static_cast<size_t>(b)];
    const uint32_t generation_b = _countries.generation[static_cast<size_t>(b)];
    // Victim's last cell leaves first in the same batch: the zero-territory
    // check must exempt a victim that is deactivated by the same batch.
    CountryTypedCommand cede;
    cede.opcode = COMMAND_TRANSFER_TERRITORY;
    cede.target_handle = handle_a;
    cede.cell = spawn_cell;
    if (!run_batch({cede, annex}, step)) return false;
    if (step.status != CountryCoreStepStatus::BOUNDARY_COMMITTED ||
        _countries.active[static_cast<size_t>(b)] != 0 ||
        _countries.generation[static_cast<size_t>(b)] != generation_b + 1u ||
        _countries.territory_count[static_cast<size_t>(b)] != 0 ||
        _countries.territory_count[static_cast<size_t>(a)] != territory_a + territory_b ||
        _countries.cash[static_cast<size_t>(b)] != 0 ||
        _countries.cash[static_cast<size_t>(a)] != 1050 ||
        total_cash() != cash_total_before ||
        (goods > 0 && (_country_goods[static_cast<size_t>(b) * goods] != 0 ||
                       total_good(0) != good_total_before)) ||
        _cell_country_slot[static_cast<size_t>(spawn_cell)] != a ||
        _cell_tax_policy_ids[static_cast<size_t>(spawn_cell)] != 0 ||
        valid_handle(static_cast<int64_t>(handle_b))) {
        error = "country_military_test_annex_failed:" + step.reason;
        return false;
    }
    // Same two commands through the worker kernel.
    RuntimeCountryPodPlan plan;
    RuntimeCountryCommand worker_cede;
    worker_cede.request_id = 1; worker_cede.sequence = 1;
    worker_cede.opcode = COMMAND_TRANSFER_TERRITORY;
    worker_cede.target_handle = handle_a;
    worker_cede.cell = spawn_cell;
    RuntimeCountryCommand worker_annex;
    worker_annex.request_id = 2; worker_annex.sequence = 2;
    worker_annex.opcode = COMMAND_ANNEX_COUNTRY;
    worker_annex.target_handle = handle_b;
    worker_annex.cell = annex.cell;
    worker_annex.aux = annex.aux;
    if (!country_core_apply_command(worker, worker_catalog, worker_cede, plan, error) ||
        !country_core_apply_command(worker, worker_catalog, worker_annex, plan, error))
        return false;
    if ((plan.header.dirty_families & RUNTIME_DIRTY_COUNTRY_TERRITORY) == 0) {
        error = "country_military_test_worker_dirty_missing";
        return false;
    }
    country_core_rebuild_territory_csr(worker);
    RuntimeCountryPodSnapshot sync_after;
    if (!export_pod_snapshot(sync_after, error)) return false;
    // Research advances in the sync day after commands; align only the
    // research family so the parity hash compares the command effects.
    worker.last_research_day = sync_after.last_research_day;
    worker.country_technologies = sync_after.country_technologies;
    worker.country_discovered = sync_after.country_discovered;
    worker.research_progress = sync_after.research_progress;
    worker.research_purchased_total = sync_after.research_purchased_total;
    worker.research_consumed_total = sync_after.research_consumed_total;
    worker.research_progress_total = sync_after.research_progress_total;
    worker.research_completed_total = sync_after.research_completed_total;
    worker.research_deferred_points = sync_after.research_deferred_points;
    worker.cell_tax_policies = sync_after.cell_tax_policies;
    if (worker.cell_country_slot != sync_after.cell_country_slot ||
        worker.country_cash != sync_after.country_cash ||
        worker.country_goods != sync_after.country_goods ||
        worker.country_active != sync_after.country_active ||
        worker.country_generation != sync_after.country_generation ||
        worker.territory_count != sync_after.territory_count ||
        worker.cell_tax_policy_ids != sync_after.cell_tax_policy_ids ||
        country_core_hash_business_state(worker) !=
            country_core_hash_business_state(sync_after)) {
        error = "country_military_test_worker_parity_mismatch";
        return false;
    }
    // Worker kernel also rejects the stale handle.
    RuntimeCountryCommand worker_stale = worker_annex;
    std::string worker_error;
    if (country_core_apply_command(worker, worker_catalog, worker_stale, plan,
                                   worker_error) ||
        worker_error != "country_handle_invalid") {
        error = "country_military_test_worker_stale_accepted";
        return false;
    }
    // Later batches holding the stale handle reject country_handle_invalid.
    if (!run_batch({stale_rename}, step)) return false;
    if (step.status != CountryCoreStepStatus::REJECTED ||
        step.reason != "country_handle_invalid") {
        error = "country_military_test_stale_handle_accepted";
        return false;
    }
    // PKCN v15 round-trip with an inactive country record and political regime.
    std::vector<uint8_t> saved;
    if (!encode_save(saved, error)) return false;
    const uint64_t expected_hash = compute_state_hash();
    NativeCountryRuntime restored(*this);
    if (!restored.decode_save(saved, error) ||
        restored.compute_state_hash() != expected_hash ||
        restored._countries.active[static_cast<size_t>(b)] != 0) {
        if (error.empty()) error = "country_military_test_save_roundtrip";
        return false;
    }
    return true;
}

} // namespace pk
