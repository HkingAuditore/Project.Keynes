#include "country_runtime_persistence_includes.inc"

namespace pk {

using namespace godot;

namespace {
constexpr uint32_t SAVE_MAGIC = 0x4e434b50U; // PKCN
constexpr uint32_t SAVE_END = 0x21444e45U;   // END!
constexpr uint32_t EFFECT_ADAPTER_MARKER = 0x31584643U; // CFX1

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using U = std::make_unsigned_t<T>;
    const U bits = static_cast<U>(value);
    for (size_t i = 0; i < sizeof(T); ++i)
        out.push_back(static_cast<uint8_t>((bits >> (i * 8)) & static_cast<U>(0xff)));
}

template <typename T>
bool read_le(const std::vector<uint8_t> &in, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > in.size()) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        bits |= static_cast<U>(in[cursor++]) << (i * 8);
    value = static_cast<T>(bits);
    return true;
}

void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

bool read_string(const std::vector<uint8_t> &in, size_t &cursor, std::string &value) {
    uint32_t length = 0;
    if (!read_le(in, cursor, length) || cursor + length > in.size()) return false;
    value.assign(reinterpret_cast<const char *>(in.data() + cursor), length);
    cursor += length;
    return true;
}

template <typename T>
void append_vector(std::vector<uint8_t> &out, const std::vector<T> &values) {
    append_le<uint64_t>(out, static_cast<uint64_t>(values.size()));
    for (const T &value : values) append_le<T>(out, value);
}

template <typename T>
bool read_vector(const std::vector<uint8_t> &in, size_t &cursor,
                 std::vector<T> &values, uint64_t max_count) {
    uint64_t count = 0;
    if (!read_le(in, cursor, count) || count > max_count) return false;
    values.resize(static_cast<size_t>(count));
    for (T &value : values) if (!read_le(in, cursor, value)) return false;
    return true;
}
} // namespace

std::vector<uint8_t> NativeCountryRuntime::capture_effect_adapter() const {
    if (_effect_command_idempotency.empty()) return {};
    // Host packets and terminal receipts are already in PKSR/CPD2. Only
    // store the correlation and the local results Effect may ask for again.
    std::vector<std::pair<uint64_t, int64_t>> entries(
        _effect_command_idempotency.begin(), _effect_command_idempotency.end());
    std::sort(entries.begin(), entries.end());
    std::unordered_map<int64_t, uint64_t> host_requests;
    for (const auto &[host_request, effect_request] : _effect_host_request_map)
        host_requests.emplace(effect_request, host_request);
    std::vector<uint8_t> bytes;
    append_le(bytes, EFFECT_ADAPTER_MARKER);
    append_le(bytes, _next_effect_request_id);
    append_le(bytes, static_cast<uint32_t>(entries.size()));
    for (const auto &[key, request] : entries) {
        const auto host = host_requests.find(request);
        const auto result = _effect_command_results.find(request);
        const CountryEffectCommandResult absent{1, 0, "country_effect_request_unknown"};
        const auto &receipt = result != _effect_command_results.end() ? result->second : absent;
        append_le(bytes, key);
        append_le(bytes, request);
        append_le(bytes, host != host_requests.end() ? host->second : uint64_t{0});
        append_le(bytes, receipt.complete);
        append_le(bytes, receipt.ok);
        append_string(bytes, receipt.reason);
    }
    return bytes;
}

void NativeCountryRuntime::restore_effect_adapter(const std::vector<uint8_t> &bytes) {
    size_t cursor = 0;
    uint32_t marker = 0;
    int64_t next_request = 1;
    uint32_t count = 0;
    if (!read_le(bytes, cursor, marker) || marker != EFFECT_ADAPTER_MARKER ||
        !read_le(bytes, cursor, next_request) || !read_le(bytes, cursor, count) ||
        count > (bytes.size() - cursor) / 30u) return;
    decltype(_effect_command_idempotency) idempotency;
    decltype(_effect_command_results) results;
    decltype(_effect_host_request_map) host_requests;
    for (uint32_t row = 0; row < count; ++row) {
        uint64_t key = 0;
        int64_t request = 0;
        uint64_t host_request = 0;
        CountryEffectCommandResult receipt;
        if (!read_le(bytes, cursor, key) || !read_le(bytes, cursor, request) ||
            !read_le(bytes, cursor, host_request) ||
            !read_le(bytes, cursor, receipt.complete) ||
            !read_le(bytes, cursor, receipt.ok) ||
            !read_string(bytes, cursor, receipt.reason)) return;
        idempotency.emplace(key, request);
        results.emplace(request, std::move(receipt));
        if (host_request != 0) host_requests.emplace(host_request, request);
    }
    if (cursor != bytes.size()) return;
    _effect_command_idempotency = std::move(idempotency);
    _effect_command_results = std::move(results);
    _effect_host_request_map = std::move(host_requests);
    _next_effect_request_id = next_request;
}

bool NativeCountryRuntime::encode_save(std::vector<uint8_t> &out, std::string &error) const {
    if (!_bootstrapped) { error = "country_save_not_bootstrapped"; return false; }
    if (_command_batch.active || _boundary_seal_active) {
        error = "country_save_requires_idle_command_graph";
        return false;
    }
    if (std::any_of(_pending_commands.begin(), _pending_commands.end(),
            [&](const Command &command) {
                return command.effective_day <= _last_committed_day;
            }) || ack_chain_due(_last_committed_day)) {
        error = "country_save_requires_idle_command_graph";
        return false;
    }
    out.clear();
    append_le<uint32_t>(out, SAVE_MAGIC);
    append_le<uint32_t>(out, SCHEMA_VERSION);
    append_le<uint64_t>(out, catalog_hash());
    append_le<uint64_t>(out, _generation);
    append_le<int64_t>(out, _last_committed_day);
    append_le<uint64_t>(out, _submit_order);
    append_le<int32_t>(out, _cell_count);
    append_le<int32_t>(out, static_cast<int32_t>(_countries.active.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_good_ids.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_profession_ids.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_building_type_ids.size()));
    append_le<int32_t>(out, static_cast<int32_t>(_technology_ids.size()));
    append_le<int32_t>(out, _technology_words);
    append_le<int32_t>(out, static_cast<int32_t>(_research_signal_ids.size()));
    append_le<int32_t>(out, _research_signal_words);
    for (const std::string &id : _good_ids) append_string(out, id);
    for (const std::string &id : _profession_ids) append_string(out, id);
    for (const std::string &id : _building_type_ids) append_string(out, id);
    for (const std::string &id : _technology_ids) append_string(out, id);
    for (const std::string &id : _research_signal_ids) append_string(out, id);
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        append_le<uint8_t>(out, _countries.active[slot]);
        append_le<uint32_t>(out, _countries.generation[slot]);
        append_string(out, _countries.stable_id[slot]);
        append_string(out, _countries.display_name[slot]);
        append_le<int32_t>(out, _countries.territory_count[slot]);
        append_le<int64_t>(out, _countries.cash[slot]);
        append_le<uint64_t>(out, _countries.state_version[slot]);
        append_le<int32_t>(out, _countries.political_regime_id[slot]);
        append_le<uint32_t>(out, _countries.political_regime_capability_bits[slot]);
        append_le<int32_t>(out, static_cast<size_t>(slot) < _countries.capital_cell.size()
            ? _countries.capital_cell[slot] : -1);
    }
    append_vector(out, _cell_country_slot);
    append_vector(out, _country_technologies);
    append_vector(out, _country_goods);
    append_vector(out, _country_discovered);
    append_vector(out, _country_pending_technologies);
    append_vector(out, _country_research_signals);
    append_le<uint64_t>(out, static_cast<uint64_t>(_country_research_signal_cells.size()));
    for (const auto &cells : _country_research_signal_cells)
        append_vector(out, cells);
    append_le<uint64_t>(out, static_cast<uint64_t>(_country_research_signal_evidence.size()));
    for (const auto &entries : _country_research_signal_evidence) {
        append_le<uint64_t>(out, static_cast<uint64_t>(entries.size()));
        for (const SignalEvidence &entry : entries) {
            append_le<int32_t>(out, entry.signal);
            append_le<int32_t>(out, entry.count);
            append_le<int64_t>(out, entry.first_day);
            append_le<int64_t>(out, entry.last_day);
            append_le<int32_t>(out, entry.first_cell);
        }
    }
    append_vector(out, _country_research_queues);
    append_vector(out, _country_research_queue_lengths);
    append_vector(out, _country_research_weights_bp);
    append_vector(out, _country_research_auto_purchase);
    append_vector(out, _country_research_deferred_points);
    append_vector(out, _country_research_purchased_total);
    append_vector(out, _country_research_consumed_total);
    append_vector(out, _country_research_progress_total);
    append_vector(out, _country_research_completed_total);
    append_le<int64_t>(out, _last_research_day);
    append_le<uint64_t>(out, static_cast<uint64_t>(_country_research_progress.size()));
    for (const auto &entries : _country_research_progress) {
        append_le<uint64_t>(out, static_cast<uint64_t>(entries.size()));
        for (const auto &entry : entries) {
            append_le<int32_t>(out, entry.first);
            append_le<int64_t>(out, entry.second);
        }
    }
    append_vector(out, _country_tax_defaults);
    append_vector(out, _country_income_tax_overrides);
    append_vector(out, _country_consumption_tax_overrides);
    append_vector(out, _country_business_tax_overrides);
    append_vector(out, _country_import_tax_overrides);
    append_vector(out, _country_export_tax_overrides);
    append_vector(out, _country_tax_default_modes);
    append_vector(out, _country_income_tax_mode_overrides);
    append_vector(out, _country_consumption_tax_mode_overrides);
    append_vector(out, _country_business_tax_mode_overrides);
    append_vector(out, _country_import_tax_mode_overrides);
    append_vector(out, _country_export_tax_mode_overrides);
    append_le<uint64_t>(out, _tax_policy_version);
    uint64_t saved_cell_policy_count = 0;
    for (uint32_t id : _cell_tax_policy_ids)
        if (!cell_tax_policy(id).empty()) ++saved_cell_policy_count;
    append_le<uint64_t>(out, saved_cell_policy_count);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const CellTaxPolicy &policy = cell_tax_policy(
            _cell_tax_policy_ids[static_cast<size_t>(cell)]);
        if (policy.empty()) continue;
        append_le<int32_t>(out, cell);
        for (int32_t rate : policy.defaults) append_le<int32_t>(out, rate);
        for (int32_t mode : policy.default_modes) append_le<int32_t>(out, mode);
        append_le<uint64_t>(out,
            static_cast<uint64_t>(policy.overrides.size()));
        for (const CellTaxOverride &entry : policy.overrides) {
            append_le<int32_t>(out, entry.kind);
            append_string(out, tax_item_ids(entry.kind)[
                static_cast<size_t>(entry.item)]);
            append_le<int32_t>(out, entry.rate);
            append_le<int32_t>(out, entry.mode);
        }
    }
    append_le<uint64_t>(out, static_cast<uint64_t>(_pending_commands.size()));
    for (const Command &command : _pending_commands) {
        append_le<int32_t>(out, command.opcode);
        append_le<int64_t>(out, command.effective_day);
        append_le<int64_t>(out, command.sequence);
        append_le<uint64_t>(out, command.target_handle);
        append_le<int32_t>(out, command.cell);
        append_le<int32_t>(out, command.aux);
        append_le<int32_t>(out, command.domain);
        append_le<int32_t>(out, command.position);
        for (int32_t weight : command.weights_bp) append_le<int32_t>(out, weight);
        append_le<int32_t>(out, command.tax_kind);
        append_le<int32_t>(out, command.tax_item);
        append_le<int32_t>(out, command.tax_rate_basis_points);
        append_le<int32_t>(out, command.tax_assessment_mode);
        append_le<int64_t>(out, command.value);
        append_string(out, command.stable_id);
        append_string(out, command.display_name);
        append_le<uint64_t>(out, command.submit_order);
        append_le<int64_t>(out, command.effect_request_id);
        append_le<uint64_t>(out, command.effect_idempotency_key);
    }
    append_le<int64_t>(out, _era_reward_reference.plan_id);
    append_le<int64_t>(out, _era_reward_reference.offer_generation);
    append_le<int32_t>(out, _era_reward_reference.milestone_technology);
    append_le<int32_t>(out, _era_reward_reference.status);
    std::vector<uint8_t> modifier_bytes;
    if (_modifier_runtime != nullptr &&
        !modifier_api::serialize_domain(*_modifier_runtime, ModifierApi::COUNTRY,
                                              modifier_bytes, error)) {
        return false;
    }
    append_le<uint64_t>(out, static_cast<uint64_t>(modifier_bytes.size()));
    out.insert(out.end(), modifier_bytes.begin(), modifier_bytes.end());
    append_le<uint32_t>(out, SAVE_END);
    return true;
}

bool NativeCountryRuntime::decode_save(const std::vector<uint8_t> &bytes, std::string &error) {
    NativeCountryRuntime staged(*this);
    auto staged_modifier = _modifier_runtime != nullptr ? modifier_api::copy_runtime(*_modifier_runtime) : decltype(modifier_api::copy_runtime(*_modifier_runtime)){};
    if (_modifier_runtime != nullptr) {
        modifier_api::attach_country_runtime(*staged_modifier, &staged);
        modifier_api::attach_economy_runtime(*staged_modifier, _economy_runtime);
        staged._modifier_runtime = staged_modifier.get();
    }
    if (!staged.decode_save_in_place(bytes, error)) return false;

    ModifierRuntime *live_modifier = _modifier_runtime;
    NativeEconomyRuntime *live_economy = _economy_runtime;
    EffectRuntime *live_effect = _effect_runtime;
    *this = std::move(staged);
    _modifier_runtime = live_modifier;
    _economy_runtime = live_economy;
    _effect_runtime = live_effect;
    if (live_modifier != nullptr) {
        modifier_api::replace_runtime(*live_modifier, std::move(*staged_modifier));
        modifier_api::attach_country_runtime(*live_modifier, this);
        modifier_api::attach_economy_runtime(*live_modifier, live_economy);
    }
    return true;
}

bool NativeCountryRuntime::decode_save_in_place(
        const std::vector<uint8_t> &bytes, std::string &error) {
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, end = 0;
    uint64_t saved_catalog = 0, generation_value = 0, saved_submit_order = 0;
    int64_t committed_day = -1;
    int32_t cell_count = 0, country_count = 0, good_count_value = 0;
    int32_t profession_count = 0, building_count = 0;
    int32_t tech_count = 0, tech_words = 0, signal_count = 0, signal_words = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, version)) { error = "country_save_truncated"; return false; }
    if (magic != SAVE_MAGIC) { error = "country_save_magic_invalid"; return false; }
    if (version != SCHEMA_VERSION && version != 14 && version != 13 && version != 12 && version != 11) {
        error = "catalog_hash_mismatch";
        return false;
    }
    const bool legacy_percent_tax_rates = version == 11;
    const bool has_tax_assessment_modes = version >= 13;
    if (!read_le(bytes, cursor, saved_catalog) || !read_le(bytes, cursor, generation_value) ||
        !read_le(bytes, cursor, committed_day) || !read_le(bytes, cursor, saved_submit_order) ||
        !read_le(bytes, cursor, cell_count) ||
        !read_le(bytes, cursor, country_count) ||
        !read_le(bytes, cursor, good_count_value)) {
        error = "country_save_header_truncated"; return false;
    }
    if (!read_le(bytes, cursor, profession_count) ||
        !read_le(bytes, cursor, building_count)) {
        error = "country_save_header_truncated";
        return false;
    }
    if (!read_le(bytes, cursor, tech_count) ||
        !read_le(bytes, cursor, tech_words) ||
        !read_le(bytes, cursor, signal_count) ||
        !read_le(bytes, cursor, signal_words)) {
        error = "country_save_header_truncated";
        return false;
    }
    const uint64_t expected_catalog = catalog_hash();
    if (saved_catalog != expected_catalog ||
        cell_count != _cell_count ||
        good_count_value != static_cast<int32_t>(_good_ids.size()) ||
        profession_count != static_cast<int32_t>(_profession_ids.size()) ||
        building_count != static_cast<int32_t>(_building_type_ids.size()) ||
        tech_count != static_cast<int32_t>(_technology_ids.size()) || tech_words != _technology_words ||
        signal_count != static_cast<int32_t>(_research_signal_ids.size()) ||
        signal_words != _research_signal_words) {
        error = "catalog_hash_mismatch";
        return false;
    }
    if (country_count <= 0 || country_count > 1000000) {
        error = "country_save_shape_invalid";
        return false;
    }
#include "country_runtime_persistence_decode_country_rows.inc"
#include "country_runtime_persistence_decode_tax_policy.inc"
    uint64_t command_count = 0;
    if (!read_le(bytes, cursor, command_count) || command_count > 10000000ULL) { error = "country_save_command_count_invalid"; return false; }
    std::vector<Command> commands;
    commands.reserve(static_cast<size_t>(command_count));
    uint64_t max_submit_order = 0;
    std::unordered_set<uint64_t> command_submit_orders;
    std::unordered_set<std::string> pending_stable_ids = stable_ids;
    auto saved_handle_valid = [&](uint64_t handle) {
        const int32_t slot = static_cast<int32_t>(handle & 0xffffffffULL);
        const uint32_t handle_generation = static_cast<uint32_t>(handle >> 32U);
        if (slot < 0 || slot >= country_count || handle_generation == 0) return false;
        // A command admitted before an annexation keeps its (now stale)
        // handle; execution rejects it as country_handle_invalid.
        if (countries.active[slot] == 0)
            return handle_generation < countries.generation[slot];
        return countries.generation[slot] == handle_generation;
    };
    for (uint64_t i = 0; i < command_count; ++i) {
        Command command;
        if (!read_le(bytes, cursor, command.opcode) || !read_le(bytes, cursor, command.effective_day) ||
            !read_le(bytes, cursor, command.sequence) || !read_le(bytes, cursor, command.target_handle) ||
            !read_le(bytes, cursor, command.cell) || !read_le(bytes, cursor, command.aux) ||
            !read_le(bytes, cursor, command.domain) || !read_le(bytes, cursor, command.position) ||
            !read_le(bytes, cursor, command.weights_bp[0]) ||
            !read_le(bytes, cursor, command.weights_bp[1]) ||
            !read_le(bytes, cursor, command.weights_bp[2]) ||
            !read_le(bytes, cursor, command.weights_bp[3])) {
            error = "country_save_command_truncated";
            return false;
        }
        if (!read_le(bytes, cursor, command.tax_kind) ||
            !read_le(bytes, cursor, command.tax_item) ||
            !read_le(bytes, cursor, command.tax_rate_basis_points)) {
            error = "country_save_command_truncated";
            return false;
        }
        if (legacy_percent_tax_rates)
            command.tax_rate_basis_points *= 100;
        if (has_tax_assessment_modes) {
            if (!read_le(bytes, cursor, command.tax_assessment_mode)) {
                error = "country_save_command_truncated";
                return false;
            }
        } else {
            command.tax_assessment_mode = TAX_MODE_PERCENT_BP;
        }
        if (!read_le(bytes, cursor, command.value) ||
            !read_string(bytes, cursor, command.stable_id) || !read_string(bytes, cursor, command.display_name) ||
            !read_le(bytes, cursor, command.submit_order) ||
            !read_le(bytes, cursor, command.effect_request_id) ||
            !read_le(bytes, cursor, command.effect_idempotency_key)) { error = "country_save_command_truncated"; return false; }
        if (command.opcode < COMMAND_CREATE_COUNTRY ||
            command.opcode > COMMAND_OPCODE_MAX ||
            command_opcode_reserved(command.opcode) ||
            command.effective_day < 0 ||
            command.sequence < 0 || command.submit_order == 0 ||
            !command_submit_orders.insert(command.submit_order).second) {
            error = "country_save_command_invalid"; return false;
        }
        if (command.opcode == COMMAND_CREATE_COUNTRY) {
            if (command.stable_id.empty() || command.display_name.empty() ||
                command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                !pending_stable_ids.insert(command.stable_id).second) {
                error = "country_save_create_command_invalid"; return false;
            }
        } else if (command.opcode == COMMAND_RENAME_COUNTRY) {
            if (!saved_handle_valid(command.target_handle) || command.display_name.empty()) {
                error = "country_save_rename_command_invalid"; return false;
            }
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY ||
                   command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY) {
            if (command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                (command.target_handle != 0 && !saved_handle_valid(command.target_handle))) {
                error = "country_save_transfer_command_invalid"; return false;
            }
        } else if (command.opcode == COMMAND_TRANSFER_CASH_BETWEEN_COUNTRIES ||
                   command.opcode == COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES ||
                   command.opcode == COMMAND_ANNEX_COUNTRY) {
            // Pending handles may legitimately go stale before execution
            // (e.g. annexed earlier); only the shape is validated here and the
            // execution path rejects stale handles as country_handle_invalid.
            const uint64_t receiver =
                receiver_handle_from_payload(command.cell, command.aux);
            const int32_t payer_slot =
                static_cast<int32_t>(command.target_handle & 0xffffffffULL);
            if (command.target_handle == 0 || command.cell < 0 ||
                command.cell >= country_count || command.aux <= 0 ||
                payer_slot < 0 || payer_slot >= country_count ||
                receiver == command.target_handle ||
                (command.opcode != COMMAND_ANNEX_COUNTRY && command.value <= 0) ||
                (command.opcode == COMMAND_TRANSFER_GOODS_BETWEEN_COUNTRIES &&
                 (command.domain < 0 ||
                  command.domain >= static_cast<int32_t>(_good_ids.size())))) {
                error = "country_save_transfer_between_command_invalid"; return false;
            }
        } else if (!saved_handle_valid(command.target_handle) ||
                   ((command.opcode == COMMAND_GRANT_TECHNOLOGY ||
                     command.opcode == COMMAND_ENQUEUE_RESEARCH ||
                     command.opcode == COMMAND_REMOVE_RESEARCH ||
                     command.opcode == COMMAND_MOVE_RESEARCH) &&
                    (command.aux < 0 || command.aux >= tech_count))) {
            error = "country_save_technology_command_invalid"; return false;
        }
        if (command.opcode == COMMAND_DISCOVER_COUNTRY_SIGNAL &&
            (command.aux < 0 || command.aux >= signal_count || command.cell < 0 ||
             command.cell >= _cell_count)) {
            error = "country_save_signal_command_invalid";
            return false;
        }
        if (command.opcode >= COMMAND_SET_TAX_DEFAULT &&
            command.opcode <= COMMAND_CLEAR_TAX_OVERRIDE &&
            (command.tax_kind < 0 || command.tax_kind >= TAX_KIND_COUNT ||
             (command.opcode != COMMAND_CLEAR_TAX_OVERRIDE &&
              (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
               !tax_value_valid(command.tax_assessment_mode,
                               command.tax_rate_basis_points))) ||
             (command.opcode != COMMAND_SET_TAX_DEFAULT &&
              (command.tax_item < 0 ||
               command.tax_item >= tax_item_count(command.tax_kind))))) {
            error = "country_save_tax_command_invalid";
            return false;
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
            if (!saved_handle_valid(command.target_handle) ||
                command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                (has_kind && (command.tax_kind < 0 ||
                              command.tax_kind >= TAX_KIND_COUNT)) ||
                (has_item && (command.tax_item < 0 ||
                              command.tax_item >= tax_item_count(
                                  command.tax_kind))) ||
                (has_item && !command.stable_id.empty() &&
                 tax_item_ids(command.tax_kind)[
                     static_cast<size_t>(command.tax_item)] !=
                     command.stable_id) ||
                (has_rate &&
                 (!tax_assessment_mode_valid(command.tax_assessment_mode) ||
                  !tax_value_valid(command.tax_assessment_mode,
                                  command.tax_rate_basis_points)))) {
                error = "country_save_cell_tax_command_invalid";
                return false;
            }
        }
        commands.push_back(std::move(command));
        max_submit_order = std::max(max_submit_order, commands.back().submit_order);
    }
    EraRewardReference era_reward_reference;
    if (!read_le(bytes, cursor, era_reward_reference.plan_id) ||
        !read_le(bytes, cursor, era_reward_reference.offer_generation) ||
        !read_le(bytes, cursor, era_reward_reference.milestone_technology) ||
        !read_le(bytes, cursor, era_reward_reference.status) ||
        era_reward_reference.status < 0 || era_reward_reference.status > 4 ||
        (era_reward_reference.status == 0 &&
         (era_reward_reference.plan_id != 0 ||
          era_reward_reference.offer_generation != 0)) ||
        (era_reward_reference.status != 0 &&
         (era_reward_reference.plan_id <= 0 ||
          era_reward_reference.offer_generation <= 0 ||
          era_reward_reference.milestone_technology < 0 ||
          era_reward_reference.milestone_technology >= tech_count))) {
        error = "country_save_era_reward_reference_invalid";
        return false;
    }
    std::vector<uint8_t> modifier_bytes;
    {
        uint64_t modifier_size = 0;
        if (!read_le(bytes, cursor, modifier_size) ||
            modifier_size > static_cast<uint64_t>(bytes.size() - cursor) ||
            modifier_size > 256ULL * 1024ULL * 1024ULL) {
            error = "country_save_modifier_payload_invalid";
            return false;
        }
        modifier_bytes.assign(bytes.begin() + static_cast<ptrdiff_t>(cursor),
                              bytes.begin() + static_cast<ptrdiff_t>(cursor + modifier_size));
        cursor += static_cast<size_t>(modifier_size);
    }
    if (!read_le(bytes, cursor, end) || end != SAVE_END || cursor != bytes.size()) { error = "country_save_end_invalid"; return false; }

    if (!modifier_bytes.empty()) {
        if (_modifier_runtime == nullptr) {
            error = "country_restore_modifier_runtime_unavailable";
            return false;
        }
        if (!modifier_api::restore_domain(*_modifier_runtime, ModifierApi::COUNTRY,
                                               modifier_bytes, error,
                                               version == 3)) {
            error = "country_restore_modifier_failed:" + error;
            return false;
        }
    } else if (_modifier_runtime != nullptr) {
        modifier_api::clear_domain(*_modifier_runtime, ModifierApi::COUNTRY);
    }

    _countries = std::move(countries);
    // Both bootstrap forms put the starting country in the first stable slot.
    // PKCN preserves that slot ordering (including inactive/annexed records).
    // A cold load skips bootstrap, so rebuild this derived identity here.
    _starting_country_slot = _countries.active.empty() ? -1 : 0;
    _cell_country_slot = std::move(owners);
    _country_technologies = std::move(technologies);
    _country_goods = std::move(goods);
    _country_discovered = std::move(discovered);
    _country_pending_technologies = std::move(pending);
    _pending_activation_index_dirty = true;
    _country_research_signals = std::move(signals);
    _country_research_signal_cells = std::move(signal_cells);
    _country_research_signal_evidence = std::move(signal_evidence);
    _country_research_progress = std::move(research_progress);
    _country_research_queues = std::move(research_queues);
    _country_research_queue_lengths = std::move(research_queue_lengths);
    _country_research_weights_bp = std::move(research_weights);
    _country_research_auto_purchase = std::move(auto_purchase);
    _country_research_deferred_points = std::move(deferred_points);
    _country_research_purchased_total = std::move(purchased_total);
    _country_research_consumed_total = std::move(consumed_total);
    _country_research_progress_total = std::move(progress_total);
    _country_research_completed_total = std::move(completed_total);
    _country_tax_defaults = std::move(tax_defaults);
    _country_tax_default_modes = std::move(tax_default_modes);
    _country_income_tax_overrides = std::move(income_tax);
    _country_consumption_tax_overrides = std::move(consumption_tax);
    _country_business_tax_overrides = std::move(business_tax);
    _country_import_tax_overrides = std::move(import_tax);
    _country_export_tax_overrides = std::move(export_tax);
    _country_income_tax_mode_overrides = std::move(income_tax_modes);
    _country_consumption_tax_mode_overrides = std::move(consumption_tax_modes);
    _country_business_tax_mode_overrides = std::move(business_tax_modes);
    _country_import_tax_mode_overrides = std::move(import_tax_modes);
    _country_export_tax_mode_overrides = std::move(export_tax_modes);
    _cell_tax_policy_ids = std::move(cell_tax_policy_ids);
    _cell_tax_policies = std::move(cell_tax_policies);
    rebuild_cell_tax_policy_intern();
    _tax_policy_version = tax_policy_version;
    _last_research_day = last_research_day;
    _pending_commands = std::move(commands);
    clear_peer_protocol_state();
    _effect_command_results.clear();
    _effect_command_idempotency.clear();
    _effect_host_request_map.clear();
    _effect_host_receipt_cursor = 0;
    _next_effect_request_id = 1;
    _era_reward_reference = era_reward_reference;
    for (const Command &command : _pending_commands) {
        if (command.effect_request_id <= 0) continue;
        if (command.effect_idempotency_key == 0 ||
            !_effect_command_idempotency.emplace(command.effect_idempotency_key,
                command.effect_request_id).second) {
            error = "country_save_effect_command_invalid";
            return false;
        }
        _effect_command_results.emplace(command.effect_request_id, CountryEffectCommandResult{});
        _next_effect_request_id = std::max(_next_effect_request_id,
            command.effect_request_id + 1);
    }
    _generation = generation_value;
    _territory_generation = generation_value > 0 ? 1 : 0;
    _research_generation = generation_value > 0 ? 1 : 0;
    _last_committed_day = committed_day;
    _submit_order = std::max(saved_submit_order, max_submit_order);
    _bootstrapped = true;
    _events.clear();
    _next_event_id = 1;
    _typed_receipts.clear();
    _typed_request_state.clear();
    close_boundary_seal();
    _next_boundary_id = 1;
    if (++_session_epoch == 0) _session_epoch = 1;
    _current_visual_era.resize(_countries.active.size(), -1);
    for (int32_t slot = 0;
         slot < static_cast<int32_t>(_countries.active.size()); ++slot)
        _current_visual_era[static_cast<size_t>(slot)] =
            visual_era_index_for_slot(slot);
    _visual_era_dirty_slots.clear();
    _research_modifier_cache.clear();
    _research_modifier_cache.resize(_countries.active.size());
    // PKCN is written at a committed boundary with no Economy asset
    // transaction in flight, so every reservation is zero on restore. The
    // lanes still have to match the restored country count: restore used to
    // leave them at the empty size reset() gave them, and the first fiscal
    // commit after a load wrote through a null vector base (0xC0000005 in
    // commit_economy_asset_transaction).
    _economy_asset_transactions_in_flight.clear();
    _economy_asset_reserved_cash.assign(_countries.active.size(), 0);
    _economy_asset_reserved_goods.assign(
        _countries.active.size() * _good_ids.size(), 0);
    _economy_asset_reserved_research_points.assign(
        _countries.active.size(), 0);
    rebuild_research_active_index();
    _state_hash_cache_valid = false;
    rebuild_cell_csr();
    publish_report("aggregate_publish", committed_day, 0, 0, 0, _cell_count, country_count, _mode == MODE_ACTIVE);
    return true;
}

Dictionary NativeCountryRuntime::begin_save(int32_t chunk_bytes) {
    if (_save_active) return fail("country_save_already_active");
    if (_simulation_host != nullptr &&
        _simulation_host->country_authority_handoff_prepare_pending()) {
        return fail("country_authority_handoff_pending");
    }
    if (!_economy_asset_transactions_in_flight.empty()) {
        Dictionary out = fail("country_save_economy_asset_transaction_pending");
        out["in_flight"] = static_cast<int64_t>(
            _economy_asset_transactions_in_flight.size());
        int64_t reserved_cash = 0;
        int64_t reserved_goods = 0;
        for (const int64_t value : _economy_asset_reserved_cash)
            if (value > 0 && reserved_cash <=
                    std::numeric_limits<int64_t>::max() - value)
                reserved_cash += value;
        for (const int64_t value : _economy_asset_reserved_goods)
            if (value > 0 && reserved_goods <=
                    std::numeric_limits<int64_t>::max() - value)
                reserved_goods += value;
        int64_t reserved_research_points = 0;
        for (const int64_t value : _economy_asset_reserved_research_points)
            if (value > 0 && reserved_research_points <=
                    std::numeric_limits<int64_t>::max() - value)
                reserved_research_points += value;
        out["reserved_cash"] = reserved_cash;
        out["reserved_goods"] = reserved_goods;
        out["reserved_research_points"] = reserved_research_points;
        return out;
    }
    std::string error;
    if (!encode_save(_save_bytes, error)) return fail(error);
    _save_chunk_bytes = std::clamp(chunk_bytes, 4096, 16 * 1024 * 1024);
    _save_cursor = 0;
    _save_active = true;
    Dictionary out;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["bytes"] = static_cast<int64_t>(_save_bytes.size());
    out["state_hash"] = state_hash();
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

PackedByteArray NativeCountryRuntime::read_save_chunk(int32_t max_bytes) {
    PackedByteArray out;
    if (!_save_active || _save_cursor >= _save_bytes.size()) return out;
    const size_t take = std::min(_save_bytes.size() - _save_cursor,
                                 static_cast<size_t>(std::clamp(max_bytes, 1, _save_chunk_bytes)));
    out.resize(static_cast<int64_t>(take));
    std::memcpy(out.ptrw(), _save_bytes.data() + _save_cursor, take);
    _save_cursor += take;
    return out;
}

Dictionary NativeCountryRuntime::end_save() {
    if (!_save_active) return fail("country_save_not_active");
    const bool complete = _save_cursor == _save_bytes.size();
    _save_active = false;
    _save_bytes.clear();
    _save_cursor = 0;
    Dictionary out;
    out["ok"] = complete;
    out["reason"] = complete ? "" : "country_save_not_fully_read";
    return out;
}

Dictionary NativeCountryRuntime::begin_restore() {
    if (!_configured) return fail("country_not_configured");
    if (_restore_active) return fail("country_restore_already_active");
    _restore_bytes.clear();
    _restore_active = true;
    Dictionary out;
    out["ok"] = true;
    return out;
}

Dictionary NativeCountryRuntime::feed_restore_chunk(const PackedByteArray &chunk) {
    if (!_restore_active) return fail("country_restore_not_active");
    if (chunk.is_empty()) return fail("country_restore_empty_chunk");
    const size_t old_size = _restore_bytes.size();
    _restore_bytes.resize(old_size + static_cast<size_t>(chunk.size()));
    std::memcpy(_restore_bytes.data() + old_size, chunk.ptr(), static_cast<size_t>(chunk.size()));
    Dictionary out;
    out["ok"] = true;
    out["bytes_received"] = static_cast<int64_t>(_restore_bytes.size());
    return out;
}

Dictionary NativeCountryRuntime::end_restore() {
    if (!_restore_active) return fail("country_restore_not_active");
    std::string error;
    const bool ok = decode_save(_restore_bytes, error);
    _restore_active = false;
    _restore_bytes.clear();
    if (!ok) return fail(error);
    begin_reference_boundary(_last_committed_day);
    record_reference_frame("restore", _last_committed_day, true, false);
    Dictionary out;
    out["ok"] = true;
    out["state_hash"] = state_hash();
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

} // namespace pk
