#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_api.h"
#include "country_core_apply.h"
#include "country_host_port.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

bool NativeCountryRuntime::validate_admission_command(
        const Command &command, std::string &error) const {
    if (command.opcode < COMMAND_CREATE_COUNTRY ||
        command.opcode > COMMAND_OPCODE_MAX) {
        error = "country_command_opcode_invalid";
        return false;
    }
    if (command_opcode_reserved(command.opcode)) {
        error = "country_command_opcode_unsupported";
        return false;
    }
    if (command.opcode == COMMAND_TRANSFER_CASH_BETWEEN_COUNTRIES ||
        command.opcode == COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES ||
        command.opcode == COMMAND_ANNEX_COUNTRY) {
        const uint64_t receiver =
            receiver_handle_from_payload(command.cell, command.aux);
        if (command.target_handle == 0 || command.cell < 0 ||
            command.aux <= 0 || receiver == command.target_handle) {
            error = command.opcode == COMMAND_ANNEX_COUNTRY
                ? "country_annex_command_invalid"
                : "country_transfer_between_command_invalid";
            return false;
        }
        if (command.opcode != COMMAND_ANNEX_COUNTRY && command.value <= 0) {
            error = "country_transfer_between_command_invalid";
            return false;
        }
        if (command.opcode == COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES &&
            (command.domain < 0 ||
             command.domain >= static_cast<int32_t>(_good_ids.size()))) {
            error = "country_transfer_between_command_invalid";
            return false;
        }
    }
    if (command.effective_day < 0 || command.sequence < 0) {
        error = "country_command_order_invalid";
        return false;
    }
    if (command.opcode == COMMAND_SET_POLITICAL_REGIME) {
        if (command.stable_id.empty() ||
            _political_regime_index.find(command.stable_id) ==
                _political_regime_index.end()) {
            error = "political_regime_invalid";
            return false;
        }
    }
    if (command.observed_generation != 0 &&
        command.observed_generation != _generation) {
        error = "stale_command_generation";
        return false;
    }
    if (command.opcode == COMMAND_SET_RESEARCH_WEIGHTS) {
        const std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> weights{{
            command.weights_bp[0], command.weights_bp[1],
            command.weights_bp[2], command.weights_bp[3]}};
        if (!runtime_country_research_weights_valid(weights)) {
            error = "country_research_weight_policy_invalid";
            return false;
        }
    }
    if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
        command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE) {
        const bool needs_value =
            command.opcode != COMMAND_CLEAR_TAX_OVERRIDE;
        if (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
            (needs_value &&
             (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
              !tax_value_valid(command.tax_assessment_mode,
                               command.tax_rate_basis_points))) ||
            (command.opcode != COMMAND_SET_TAX_DEFAULT &&
             (command.tax_item < 0 ||
              command.tax_item >= tax_item_count(command.tax_kind)))) {
            error = "country_tax_command_invalid";
            return false;
        }
    }
    if (command.opcode >= COMMAND_SET_CELL_TAX_DEFAULT &&
        command.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY) {
        const bool has_kind =
            command.opcode != COMMAND_CLEAR_CELL_TAX_POLICY;
        const bool has_item =
            command.opcode == COMMAND_SET_CELL_TAX_OVERRIDE ||
            command.opcode == COMMAND_CLEAR_CELL_TAX_OVERRIDE;
        const bool has_rate =
            command.opcode == COMMAND_SET_CELL_TAX_DEFAULT ||
            command.opcode == COMMAND_SET_CELL_TAX_OVERRIDE;
        if (command.cell < 0 || command.cell >= _cell_count ||
            _is_water[static_cast<size_t>(command.cell)] != 0 ||
            (has_kind && (command.tax_kind < 0 ||
                          command.tax_kind >= TAX_KIND_COUNT)) ||
            (has_item && (command.tax_item < 0 ||
                          command.tax_item >=
                              tax_item_count(command.tax_kind))) ||
            (has_rate &&
             (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
              !tax_value_valid(command.tax_assessment_mode,
                               command.tax_rate_basis_points)))) {
            error = "country_cell_tax_command_invalid";
            return false;
        }
    }
    if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY &&
        (command.cell < 0 || command.cell >= _cell_count ||
         _is_water[static_cast<size_t>(command.cell)] != 0)) {
        error = "country_claim_target_invalid";
        return false;
    }
    if (command.opcode == COMMAND_CONSUME_TREASURY_GOODS &&
        (command.aux < 0 ||
         command.aux >= static_cast<int32_t>(_good_ids.size()) ||
         command.value <= 0)) {
        error = "country_treasury_goods_command_invalid";
        return false;
    }
    return true;
}
bool NativeCountryRuntime::submit_typed_commands(
        const CountryTypedCommand *commands, size_t count,
        std::vector<CountryCommandReceipt> &receipts, std::string &error) {
    receipts.clear();
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_runtime_unavailable";
        return false;
    }
    if (commands == nullptr || count == 0) {
        error = "country_command_batch_empty";
        return false;
    }
    std::vector<Command> staged;
    staged.reserve(count);
    std::unordered_set<uint64_t> new_request_ids;
    uint64_t next_submit_order = _submit_order;
    for (size_t i = 0; i < count; ++i) {
        const CountryTypedCommand &source = commands[i];
        if (source.request_id == 0) {
            error = "country_request_id_invalid";
            break;
        }
        const auto existing = _typed_request_state.find(source.request_id);
        if (existing != _typed_request_state.end()) continue;
        if (!new_request_ids.insert(source.request_id).second) {
            error = "country_request_id_duplicate";
            break;
        }
        if (source.sequence >
            static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
            error = "country_command_order_invalid";
            break;
        }
        Command command;
        command.request_id = source.request_id;
        command.producer_id = source.producer_id;
        command.observed_generation = source.observed_generation;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = static_cast<int64_t>(source.sequence);
        command.target_handle = source.target_handle;
        command.cell = source.cell;
        command.aux = source.aux;
        command.domain = source.domain;
        command.position = source.position;
        std::copy(std::begin(source.weights_bp), std::end(source.weights_bp),
                  std::begin(command.weights_bp));
        command.tax_kind = source.tax_kind;
        command.tax_item = source.tax_item;
        command.tax_rate_basis_points = source.tax_rate_basis_points;
        command.tax_assessment_mode = source.tax_assessment_mode;
        command.value = source.value;
        command.stable_id = source.stable_id;
        command.display_name = source.display_name;
        command.submit_order = ++next_submit_order;
        if (!validate_admission_command(command, error)) break;
        staged.push_back(std::move(command));
    }
    if (!error.empty()) {
        receipts.reserve(count);
        for (size_t i = 0; i < count; ++i) {
            const auto existing = _typed_request_state.find(commands[i].request_id);
            if (existing != _typed_request_state.end()) {
                receipts.push_back(existing->second);
                continue;
            }
            CountryCommandReceipt receipt;
            receipt.request_id = commands[i].request_id;
            receipt.producer_id = commands[i].producer_id;
            receipt.sequence = commands[i].sequence;
            receipt.effective_day = commands[i].effective_day;
            receipt.generation = _generation;
            receipt.code = CountryCommandReceiptCode::ADMISSION_REJECTED;
            receipt.reason = error;
            receipts.push_back(std::move(receipt));
        }
        return false;
    }

    _pending_commands.reserve(_pending_commands.size() + staged.size());
    _pending_commands.insert(_pending_commands.end(),
        std::make_move_iterator(staged.begin()),
        std::make_move_iterator(staged.end()));
    _submit_order = next_submit_order;
    receipts.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const auto existing = _typed_request_state.find(commands[i].request_id);
        if (existing != _typed_request_state.end()) {
            receipts.push_back(existing->second);
            continue;
        }
        CountryCommandReceipt receipt;
        receipt.request_id = commands[i].request_id;
        receipt.producer_id = commands[i].producer_id;
        receipt.sequence = commands[i].sequence;
        receipt.effective_day = commands[i].effective_day;
        receipt.generation = _generation;
        receipt.code = CountryCommandReceiptCode::ACCEPTED;
        _typed_request_state.emplace(receipt.request_id, receipt);
        receipts.push_back(std::move(receipt));
    }
    return true;
}

bool NativeCountryRuntime::poll_typed_receipt(CountryCommandReceipt &out) {
    if (_typed_receipts.empty()) return false;
    out = std::move(_typed_receipts.front());
    _typed_receipts.pop_front();
    return true;
}

CountryBoundarySeal NativeCountryRuntime::open_implicit_boundary(int64_t day) {
    CountryBoundarySeal seal;
    seal.session_epoch = _session_epoch;
    seal.boundary_id = _next_boundary_id++;
    seal.day = day;
    seal.last_admitted_submit_order = _submit_order;
    seal.expected_base_generation = _generation;
    seal.catalog_hash = catalog_hash();
    _boundary_seal = seal;
    _boundary_seal_active = true;
    return seal;
}

bool NativeCountryRuntime::seal_boundary(
        uint64_t session_epoch, uint64_t boundary_id, int64_t day,
        CountryBoundarySeal &out, std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_runtime_unavailable";
        return false;
    }
    if (session_epoch == 0 || session_epoch != _session_epoch) {
        error = "country_boundary_session_mismatch";
        return false;
    }
    if (boundary_id == 0 || day < 0) {
        error = "country_boundary_invalid";
        return false;
    }
    if (_command_batch.active) {
        error = "country_boundary_in_progress";
        return false;
    }
    if (_boundary_seal_active) {
        if (_boundary_seal.session_epoch == session_epoch &&
            _boundary_seal.boundary_id == boundary_id &&
            _boundary_seal.day == day) {
            out = _boundary_seal;
            return true;
        }
        error = "country_boundary_already_sealed";
        return false;
    }
    _boundary_seal.session_epoch = session_epoch;
    _boundary_seal.boundary_id = boundary_id;
    _boundary_seal.day = day;
    _boundary_seal.last_admitted_submit_order = _submit_order;
    _boundary_seal.expected_base_generation = _generation;
    _boundary_seal.catalog_hash = catalog_hash();
    _boundary_seal_active = true;
    _next_boundary_id = std::max(_next_boundary_id, boundary_id + 1);
    out = _boundary_seal;
    return true;
}

void NativeCountryRuntime::close_boundary_seal() {
    _boundary_seal = {};
    _boundary_seal_active = false;
}

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

void NativeCountryRuntime::push_typed_receipt(
        const Command &command, CountryCommandReceiptCode code,
        const std::string &reason) {
    if (command.request_id == 0) return;
    CountryCommandReceipt receipt;
    receipt.request_id = command.request_id;
    receipt.producer_id = command.producer_id;
    receipt.sequence = static_cast<uint64_t>(command.sequence);
    receipt.effective_day = command.effective_day;
    receipt.generation = _generation;
    receipt.code = code;
    receipt.reason = reason;
    _typed_request_state[receipt.request_id] = receipt;
    _typed_receipts.push_back(std::move(receipt));
}

Dictionary NativeCountryRuntime::submit_commands(const Dictionary &batch) {
    if (!_configured || !_bootstrapped) return fail("country_not_bootstrapped");
    if (_mode == MODE_OFF) return fail("country_runtime_off");
    const std::vector<int32_t> opcodes = packed_i32(batch, "opcodes");
    const std::vector<int64_t> days = packed_i64(batch, "effective_days");
    const std::vector<int64_t> sequences = packed_i64(batch, "sequences");
    const std::vector<int64_t> handles = packed_i64(batch, "target_handles");
    const std::vector<int32_t> cells = packed_i32(batch, "cell_indices");
    const std::vector<int32_t> aux = packed_i32(batch, "aux_i32");
    const std::vector<int32_t> domains = packed_i32(batch, "domain_i32");
    const std::vector<int32_t> positions = packed_i32(batch, "position_i32");
    const std::vector<int32_t> weights0 = packed_i32(batch, "weight0_bp");
    const std::vector<int32_t> weights1 = packed_i32(batch, "weight1_bp");
    const std::vector<int32_t> weights2 = packed_i32(batch, "weight2_bp");
    const std::vector<int32_t> weights3 = packed_i32(batch, "weight3_bp");
    const std::vector<int64_t> values = packed_i64(batch, "value_i64");
    std::vector<int32_t> tax_kinds = packed_i32(batch, "tax_kinds");
    std::vector<int32_t> tax_items = packed_i32(batch, "tax_item_indices");
    std::vector<int32_t> tax_rates = packed_i32(
        batch, "tax_rate_basis_points");
    std::vector<int32_t> tax_modes = packed_i32(
        batch, "tax_assessment_modes");
    if (tax_rates.empty()) {
        tax_rates = packed_i32(batch, "tax_rate_percent");
        for (int32_t &rate : tax_rates) {
            rate = static_cast<int32_t>(std::clamp<int64_t>(
                static_cast<int64_t>(rate) * 100,
                TAX_RATE_MIN_BP, TAX_RATE_MAX_BP));
        }
    }
    const std::vector<std::string> stable_ids = packed_strings(batch, "stable_ids");
    const std::vector<std::string> display_names = packed_strings(batch, "display_names");
    const size_t count = opcodes.size();
    if (count == 0) return fail("country_command_batch_empty");
    if (tax_kinds.empty()) tax_kinds.assign(count, -1);
    if (tax_items.empty()) tax_items.assign(count, -1);
    if (tax_rates.empty()) tax_rates.assign(count, 0);
    if (tax_modes.empty()) tax_modes.assign(count, TAX_MODE_PERCENT_BP);
    if (days.size() != count || sequences.size() != count || handles.size() != count ||
        cells.size() != count || aux.size() != count || domains.size() != count ||
        positions.size() != count || weights0.size() != count || weights1.size() != count ||
        weights2.size() != count || weights3.size() != count || values.size() != count ||
        tax_kinds.size() != count || tax_items.size() != count ||
        tax_rates.size() != count || tax_modes.size() != count ||
        stable_ids.size() != count ||
        display_names.size() != count)
        return fail("country_command_batch_shape_invalid");

    std::vector<Command> staged_commands;
    staged_commands.reserve(count);
    uint64_t next_submit_order = _submit_order;
    for (size_t i = 0; i < count; ++i) {
        Command command;
        command.opcode = opcodes[i];
        command.effective_day = days[i];
        command.sequence = sequences[i];
        command.target_handle = static_cast<uint64_t>(handles[i]);
        command.cell = cells[i];
        command.aux = aux[i];
        command.domain = domains[i];
        command.position = positions[i];
        command.weights_bp[0] = weights0[i];
        command.weights_bp[1] = weights1[i];
        command.weights_bp[2] = weights2[i];
        command.weights_bp[3] = weights3[i];
        command.tax_kind = tax_kinds[i];
        command.tax_item = tax_items[i];
        command.tax_rate_basis_points = tax_rates[i];
        command.tax_assessment_mode = tax_modes[i];
        command.value = values[i];
        command.stable_id = stable_ids[i];
        command.display_name = display_names[i];
        command.submit_order = ++next_submit_order;
        std::string admission_error;
        if (!validate_admission_command(command, admission_error))
            return fail(admission_error);
        staged_commands.push_back(std::move(command));
    }
    _pending_commands.reserve(_pending_commands.size() + count);
    _pending_commands.insert(_pending_commands.end(),
        std::make_move_iterator(staged_commands.begin()),
        std::make_move_iterator(staged_commands.end()));
    _submit_order = next_submit_order;
    Dictionary out;
    out["ok"] = true;
    out["submitted"] = static_cast<int64_t>(count);
    out["pending"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool NativeCountryRuntime::submit_effect_commands_pod(
        const CountryEffectCommand *commands, size_t count, std::vector<int64_t> &request_ids,
        std::string &error) {
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_runtime_unavailable";
        return false;
    }
    if (commands == nullptr || count == 0) { error = "country_effect_command_empty"; return false; }
    request_ids.clear();
    request_ids.reserve(count);
    std::vector<Command> staged;
    staged.reserve(count);
    auto lo_i32 = [](int64_t value) { return static_cast<int32_t>(static_cast<uint32_t>(value)); };
    auto hi_i32 = [](int64_t value) { return static_cast<int32_t>(static_cast<uint64_t>(value) >> 32U); };
    auto u16 = [](int64_t value, int32_t shift) {
        return static_cast<int32_t>((static_cast<uint64_t>(value) >> shift) & 0xffffULL);
    };
    for (size_t i = 0; i < count; ++i) {
        const CountryEffectCommand &source = commands[i];
        if (source.opcode < COMMAND_CREATE_COUNTRY || source.opcode > COMMAND_CLAIM_UNOWNED_TERRITORY ||
            source.effective_day < 0 || source.sequence < 0 || source.idempotency_key == 0) {
            error = "country_effect_command_invalid";
            return false;
        }
        const auto duplicate = _effect_command_idempotency.find(source.idempotency_key);
        if (duplicate != _effect_command_idempotency.end()) {
            request_ids.push_back(duplicate->second);
            continue;
        }
        if (source.opcode != COMMAND_CREATE_COUNTRY && source.target_handle != 0 &&
            static_cast<uint32_t>(source.target_handle >> 32U) != source.target_generation) {
            error = "country_effect_target_generation_invalid";
            return false;
        }
        Command command;
        command.opcode = source.opcode;
        command.effective_day = source.effective_day;
        command.sequence = source.sequence;
        command.target_handle = source.target_handle;
        command.cell = lo_i32(source.payload[0]);
        command.aux = hi_i32(source.payload[0]);
        command.domain = lo_i32(source.payload[1]);
        command.position = hi_i32(source.payload[1]);
        command.weights_bp[0] = u16(source.payload[2], 0);
        command.weights_bp[1] = u16(source.payload[2], 16);
        command.weights_bp[2] = u16(source.payload[2], 32);
        command.weights_bp[3] = u16(source.payload[2], 48);
        command.tax_kind = lo_i32(source.payload[3]);
        command.tax_item = static_cast<int32_t>(static_cast<int16_t>(u16(source.payload[3], 32)));
        // The effect ABI uses `value` for full-width basis points. Catalogs
        // compiled before PKCN v12 keep their signed whole-percent payload.
        // Effect tax packing has no assessment-mode lane yet; default percent.
        command.tax_rate_basis_points =
            source.opcode >= COMMAND_SET_TAX_DEFAULT &&
                    source.opcode <= COMMAND_CLEAR_CELL_TAX_POLICY &&
                    source.value >= TAX_RATE_MIN_BP &&
                    source.value <= TAX_RATE_MAX_BP
                ? static_cast<int32_t>(source.value)
                : static_cast<int32_t>(
                    static_cast<int16_t>(u16(source.payload[3], 48))) * 100;
        command.tax_assessment_mode = TAX_MODE_PERCENT_BP;
        command.value = source.value;
        command.stable_id = source.stable_id == nullptr ? "" : source.stable_id;
        command.display_name = source.display_name == nullptr ? "" : source.display_name;
        command.submit_order = ++_submit_order;
        command.effect_request_id = _next_effect_request_id++;
        command.effect_idempotency_key = source.idempotency_key;
        _effect_command_results.emplace(command.effect_request_id, EffectCommandResult{});
        _effect_command_idempotency[source.idempotency_key] = command.effect_request_id;
        request_ids.push_back(command.effect_request_id);
        staged.push_back(std::move(command));
    }
    // Always mirror Effect commands into the Host Country queue when the POD
    // worker is live. Under worker authority the sync facade must not keep a
    // local pending copy (should_run is false), so the Host path is the only
    // way those commands can commit and complete Effect ACK.
    const bool worker_owns_writes = _sync_store_writes_forbidden;
    if (_simulation_host != nullptr &&
        _simulation_host->country_pod_configured()) {
        const RuntimeWorkerState host_state = _simulation_host->state();
        const bool host_live = host_state != RuntimeWorkerState::STOPPED &&
            host_state != RuntimeWorkerState::FAULTED;
        if (host_live) {
            std::vector<RuntimeCommandPacket> packets;
            packets.reserve(staged.size());
            const auto copy_fixed = [](auto &destination,
                                       const std::string &source) {
                size_t i = 0;
                for (; i + 1u < destination.size() && i < source.size(); ++i)
                    destination[i] = source[i];
                destination[i] = '\0';
            };
            for (const Command &command : staged) {
                RuntimeCountryCommand mirrored;
                mirrored.request_id =
                    _simulation_host->allocate_command_request_id();
                mirrored.producer_id = 0;
                mirrored.sequence = command.sequence > 0
                    ? static_cast<uint64_t>(command.sequence)
                    : _simulation_host->allocate_producer_sequence(0);
                mirrored.requested_day = command.effective_day;
                mirrored.effective_day = command.effective_day;
                mirrored.opcode = static_cast<uint16_t>(command.opcode);
                mirrored.target_handle = command.target_handle;
                mirrored.cell = command.cell;
                mirrored.aux = command.aux;
                mirrored.domain = command.domain;
                mirrored.position = command.position;
                for (size_t domain = 0; domain < mirrored.weights_bp.size();
                     ++domain) {
                    mirrored.weights_bp[domain] = command.weights_bp[domain];
                }
                mirrored.tax_kind = command.tax_kind;
                mirrored.tax_item = command.tax_item;
                mirrored.tax_rate_basis_points =
                    command.tax_rate_basis_points;
                mirrored.tax_assessment_mode =
                    command.tax_assessment_mode;
                mirrored.value = command.value;
                copy_fixed(mirrored.stable_id, command.stable_id);
                copy_fixed(mirrored.display_name, command.display_name);
                RuntimeCommandPacket packet;
                packet.envelope.request_id = mirrored.request_id;
                packet.envelope.producer_id = mirrored.producer_id;
                packet.envelope.sequence = mirrored.sequence;
                packet.envelope.requested_day = mirrored.requested_day;
                packet.envelope.effective_day = mirrored.effective_day;
                packet.envelope.domain = static_cast<uint16_t>(
                    RuntimeDomainId::COUNTRY);
                packet.envelope.opcode = mirrored.opcode;
                packet.envelope.payload_size = sizeof(RuntimeCountryCommand);
                std::memcpy(packet.payload.data(), &mirrored,
                            sizeof(RuntimeCountryCommand));
                packets.push_back(packet);
                // Always remember the Host request id. Effect may submit while
                // the sync facade still owns writes (mask not granted yet) and
                // Country can flip to worker authority before the local pending
                // queue is applied — without this map the Host receipt cannot
                // complete the PREFLIGHTED ACK and hard_ack=effect pins forever.
                _effect_host_request_map[mirrored.request_id] =
                    command.effect_request_id;
            }
            if (!packets.empty() &&
                !_simulation_host->enqueue_batch(std::move(packets))) {
                error = "country_effect_shadow_mirror_capacity_exceeded";
                for (const Command &command : staged)
                    _effect_command_results.erase(command.effect_request_id);
                _effect_host_request_map.clear();
                return false;
            }
        } else if (worker_owns_writes) {
            error = "country_worker_unavailable_for_effect";
            return false;
        }
    } else if (worker_owns_writes) {
        error = "country_worker_unavailable_for_effect";
        return false;
    }
    if (!worker_owns_writes) {
        _pending_commands.insert(_pending_commands.end(),
            std::make_move_iterator(staged.begin()),
            std::make_move_iterator(staged.end()));
    }
    return true;
}

void NativeCountryRuntime::drain_effect_host_command_receipts() {
    // Drain whenever Host-mirrored Effect commands are outstanding. Do not
    // gate on sync_store_writes_forbidden: submissions made before the Country
    // grant still need their receipts after the facade is suppressed.
    //
    // Look up each mapped Host request_id directly. A cursor poll over all
    // Country terminals advances past unrelated research/tax commits and then
    // permanently skips lower-id Effect terminals — hard_ack=effect pins.
    if (_simulation_host == nullptr || _effect_host_request_map.empty()) {
        return;
    }
    std::vector<uint64_t> host_request_ids;
    host_request_ids.reserve(_effect_host_request_map.size());
    for (const auto &entry : _effect_host_request_map) {
        host_request_ids.push_back(entry.first);
    }
    for (const uint64_t host_request_id : host_request_ids) {
        const auto mapped = _effect_host_request_map.find(host_request_id);
        if (mapped == _effect_host_request_map.end()) continue;
        CountryCommandReceipt receipt;
        if (!_simulation_host->try_country_command_terminal(
                host_request_id, receipt)) {
            continue;
        }
        // Terminals are COMMITTED / REJECTED only. ACCEPTED lives in the
        // non-terminal admission map and must keep Effect waiting.
        const bool committed =
            receipt.code == CountryCommandReceiptCode::COMMITTED;
        const bool rejected =
            receipt.code == CountryCommandReceiptCode::REJECTED_AT_EXECUTION ||
            receipt.code == CountryCommandReceiptCode::ADMISSION_REJECTED;
        if (!committed && !rejected) continue;
        EffectCommandResult &result =
            _effect_command_results[mapped->second];
        result.complete = 1;
        result.ok = committed ? 1 : 0;
        result.reason = committed ? std::string{} :
            (receipt.reason.empty()
                ? "country_effect_host_rejected" : receipt.reason);
        _effect_host_request_map.erase(mapped);
        if (host_request_id > _effect_host_receipt_cursor) {
            _effect_host_receipt_cursor = host_request_id;
        }
    }
}

bool NativeCountryRuntime::effect_command_result_pod(int64_t request_id, bool &complete,
        bool &ok, std::string &reason) const {
    const auto found = _effect_command_results.find(request_id);
    if (found == _effect_command_results.end()) {
        complete = true; ok = false; reason = "country_effect_request_unknown"; return false;
    }
    complete = found->second.complete != 0;
    ok = found->second.ok != 0;
    reason = found->second.reason;
    return true;
}

bool NativeCountryRuntime::has_pending_effect_commands() const {
    for (const auto &entry : _effect_command_results)
        if (entry.second.complete == 0) return true;
    return false;
}

} // namespace pk
