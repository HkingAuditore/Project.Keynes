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
    const bool trigger_delivery = commands[0].trigger_delivery;
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
        _effect_command_results.emplace(command.effect_request_id, CountryEffectCommandResult{});
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
                mirrored.request_id = trigger_delivery
                    ? _simulation_host->allocate_command_request_id_for_ingress()
                    : _simulation_host->allocate_command_request_id();
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
                packets.push_back(encode_country_packet(mirrored));
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
        CountryEffectCommandResult &result =
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
