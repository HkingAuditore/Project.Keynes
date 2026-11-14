#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "modifier_api.h"
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

namespace {
constexpr uint32_t SAVE_MAGIC = 0x4e434b50U; // PKCN
constexpr uint32_t SAVE_END = 0x21444e45U;   // END!

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

bool NativeCountryRuntime::capture_worker_committed_checkpoint(
        CountryCoreCheckpoint &out, std::string &error) const {
    // Called on the read replica that apply_committed_read_snapshot keeps in
    // step with the worker. Its business state is the worker's committed day,
    // but the command queue, batch/seal flags, peer intents, and the attached
    // Effect/Modifier peers are leftovers of the main-thread copy it was built
    // from: under worker authority they never advance, so encode_save would
    // read them as due work and refuse. The host owns all of that state and
    // merges its own pending commands and receipts into the bundle.
    NativeCountryRuntime committed(*this);
    committed._pending_commands.clear();
    committed._command_batch = {};
    committed._boundary_seal_active = false;
    committed._peer_pending_intents.clear();
    committed._effect_runtime = nullptr;
    committed._modifier_runtime = nullptr;
    committed._economy_runtime = nullptr;
    return committed.capture_core_checkpoint(out, error);
}

bool NativeCountryRuntime::capture_core_checkpoint(
        CountryCoreCheckpoint &out, std::string &error) const {
    CountryCoreCheckpoint checkpoint;
    const CountryPeerProtocolStatus peer_status = peer_protocol_status();
    if (peer_status.pending_intents != 0 || peer_status.queued_intents != 0) {
        error = "country_checkpoint_peer_pending";
        return false;
    }
    if (peer_status.rejected_intents != 0) {
        error = "country_checkpoint_peer_rejected_retry_pending";
        return false;
    }
    if (!encode_save(checkpoint.canonical_pkcn, error)) return false;
    checkpoint.session_epoch = _session_epoch;
    checkpoint.catalog_hash = catalog_hash();
    checkpoint.generation = _generation;
    checkpoint.committed_day = _last_committed_day;
    checkpoint.business_state_hash = compute_state_hash();
    checkpoint.command_watermark = _submit_order;
    checkpoint.next_event_id = _next_event_id;
    checkpoint.next_boundary_id = _next_boundary_id;
    checkpoint.pending_protocol.reserve(_pending_commands.size());
    for (const Command &command : _pending_commands) {
        if (command.request_id == 0) continue;
        checkpoint.pending_protocol.push_back(CountryPendingCommandProtocol{
            command.submit_order, command.request_id, command.producer_id,
            command.observed_generation});
    }
    checkpoint.request_states.reserve(_typed_request_state.size());
    for (const auto &entry : _typed_request_state)
        checkpoint.request_states.push_back(entry.second);
    std::sort(checkpoint.request_states.begin(), checkpoint.request_states.end(),
        [](const CountryCommandReceipt &lhs, const CountryCommandReceipt &rhs) {
            return lhs.request_id < rhs.request_id;
        });
    checkpoint.terminal_receipts.assign(_typed_receipts.begin(),
                                        _typed_receipts.end());
    std::vector<uint8_t> encoded;
    if (!encode_country_core_checkpoint(checkpoint, encoded, error)) return false;
    size_t cursor = encoded.size() - sizeof(uint64_t);
    checkpoint.checkpoint_hash = 0;
    for (uint32_t i = 0; i < sizeof(uint64_t); ++i)
        checkpoint.checkpoint_hash |=
            static_cast<uint64_t>(encoded[cursor + i]) << (i * 8u);
    out = std::move(checkpoint);
    return true;
}

bool NativeCountryRuntime::restore_core_checkpoint(
        const CountryCoreCheckpoint &checkpoint, std::string &error) {
    if (!validate_country_core_checkpoint(checkpoint, error)) return false;
    if (!_configured) {
        error = "country_checkpoint_runtime_unconfigured";
        return false;
    }
    if (checkpoint.catalog_hash != catalog_hash()) {
        error = "country_checkpoint_catalog_mismatch";
        return false;
    }

    NativeCountryRuntime staged(*this);
    auto staged_modifier = _modifier_runtime != nullptr ? modifier_api::copy_runtime(*_modifier_runtime) : decltype(modifier_api::copy_runtime(*_modifier_runtime)){};
    if (_modifier_runtime != nullptr) {
        modifier_api::attach_country_runtime(*staged_modifier, &staged);
        modifier_api::attach_economy_runtime(*staged_modifier, _economy_runtime);
        staged._modifier_runtime = staged_modifier.get();
    }
    if (!staged.restore_core_checkpoint_in_place(checkpoint, error))
        return false;

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

bool NativeCountryRuntime::restore_core_checkpoint_in_place(
        const CountryCoreCheckpoint &checkpoint, std::string &error) {
    if (!decode_save_in_place(checkpoint.canonical_pkcn, error)) return false;

    std::unordered_map<uint64_t, Command *> pending_by_order;
    pending_by_order.reserve(_pending_commands.size());
    for (Command &command : _pending_commands)
        pending_by_order.emplace(command.submit_order, &command);
    for (const CountryPendingCommandProtocol &metadata :
         checkpoint.pending_protocol) {
        const auto found = pending_by_order.find(metadata.submit_order);
        if (found == pending_by_order.end() || found->second->request_id != 0) {
            error = "country_checkpoint_pending_protocol_mismatch";
            return false;
        }
        found->second->request_id = metadata.request_id;
        found->second->producer_id = metadata.producer_id;
        found->second->observed_generation = metadata.observed_generation;
    }
    _typed_request_state.clear();
    for (const CountryCommandReceipt &receipt : checkpoint.request_states)
        _typed_request_state.emplace(receipt.request_id, receipt);
    _typed_receipts.assign(checkpoint.terminal_receipts.begin(),
                           checkpoint.terminal_receipts.end());
    _next_event_id = checkpoint.next_event_id;
    _next_boundary_id = checkpoint.next_boundary_id;
    close_boundary_seal();
    if (checkpoint.session_epoch == std::numeric_limits<uint64_t>::max()) {
        error = "country_checkpoint_session_epoch_exhausted";
        return false;
    }
    _session_epoch = std::max(_session_epoch, checkpoint.session_epoch + 1u);
    if (_generation != checkpoint.generation ||
        _last_committed_day != checkpoint.committed_day ||
        _submit_order != checkpoint.command_watermark ||
        compute_state_hash() != checkpoint.business_state_hash) {
        error = "country_checkpoint_business_state_mismatch";
        return false;
    }
    return true;
}
bool NativeCountryRuntime::copy_technology_domains(
        std::vector<int32_t> &out) const {
    if (!_configured) return false;
    out = _technology_domains;
    return true;
}

uint64_t NativeCountryRuntime::catalog_hash() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_technology_catalog_identity_hash,
               sizeof(_technology_catalog_identity_hash));
    hash_bytes(hash, &_technology_content_binding_hash,
               sizeof(_technology_content_binding_hash));
    hash_bytes(hash, &_technology_trigger_definition_hash,
               sizeof(_technology_trigger_definition_hash));
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _profession_ids) hash_string(hash, id);
    for (const std::string &id : _building_type_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
    for (const std::string &id : _technology_era_reward_pool_ids)
        hash_string(hash, id);
    for (const std::string &id : _research_signal_ids) hash_string(hash, id);
    for (const std::string &id : _political_regime_ids) hash_string(hash, id);
    if (!_political_regime_capability_bits.empty())
        hash_bytes(hash, _political_regime_capability_bits.data(),
                   _political_regime_capability_bits.size() * sizeof(uint32_t));
    if (!_technology_domains.empty())
        hash_bytes(hash, _technology_domains.data(), _technology_domains.size() * sizeof(int32_t));
    if (!_technology_costs.empty())
        hash_bytes(hash, _technology_costs.data(), _technology_costs.size() * sizeof(int64_t));
    if (!_technology_prerequisite_offsets.empty())
        hash_bytes(hash, _technology_prerequisite_offsets.data(),
                   _technology_prerequisite_offsets.size() * sizeof(int32_t));
    if (!_technology_prerequisites.empty())
        hash_bytes(hash, _technology_prerequisites.data(),
                   _technology_prerequisites.size() * sizeof(int32_t));
    if (!_technology_entry_milestone_indices.empty())
        hash_bytes(hash, _technology_entry_milestone_indices.data(),
                   _technology_entry_milestone_indices.size() * sizeof(int32_t));
    if (!_research_signal_requires_provenance.empty())
        hash_bytes(hash, _research_signal_requires_provenance.data(),
                   _research_signal_requires_provenance.size() * sizeof(uint8_t));
    if (!_technology_research_condition_offsets.empty())
        hash_bytes(hash, _technology_research_condition_offsets.data(),
                   _technology_research_condition_offsets.size() * sizeof(int32_t));
    if (!_technology_research_condition_ops.empty())
        hash_bytes(hash, _technology_research_condition_ops.data(),
                   _technology_research_condition_ops.size() * sizeof(int32_t));
    if (!_technology_research_condition_refs.empty())
        hash_bytes(hash, _technology_research_condition_refs.data(),
                   _technology_research_condition_refs.size() * sizeof(int32_t));
    if (!_technology_research_condition_values.empty())
        hash_bytes(hash, _technology_research_condition_values.data(),
                   _technology_research_condition_values.size() * sizeof(int64_t));
    if (!_technology_reveal_condition_offsets.empty())
        hash_bytes(hash, _technology_reveal_condition_offsets.data(),
                   _technology_reveal_condition_offsets.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_ops.empty())
        hash_bytes(hash, _technology_reveal_condition_ops.data(),
                   _technology_reveal_condition_ops.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_refs.empty())
        hash_bytes(hash, _technology_reveal_condition_refs.data(),
                   _technology_reveal_condition_refs.size() * sizeof(int32_t));
    if (!_technology_reveal_condition_values.empty())
        hash_bytes(hash, _technology_reveal_condition_values.data(),
                   _technology_reveal_condition_values.size() * sizeof(int64_t));
    if (!_technology_reveal_signal_offsets.empty())
        hash_bytes(hash, _technology_reveal_signal_offsets.data(),
                   _technology_reveal_signal_offsets.size() * sizeof(int32_t));
    if (!_technology_reveal_signal_technologies.empty())
        hash_bytes(hash, _technology_reveal_signal_technologies.data(),
                   _technology_reveal_signal_technologies.size() * sizeof(int32_t));
    return hash;
}

uint64_t NativeCountryRuntime::compute_state_hash() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_generation, sizeof(_generation));
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        hash_bytes(hash, &_countries.active[slot], sizeof(uint8_t));
        hash_bytes(hash, &_countries.generation[slot], sizeof(uint32_t));
        hash_string(hash, _countries.stable_id[slot]);
        hash_string(hash, _countries.display_name[slot]);
        hash_bytes(hash, &_countries.territory_count[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.cash[slot], sizeof(int64_t));
        hash_bytes(hash, &_countries.state_version[slot], sizeof(uint64_t));
        hash_bytes(hash, &_countries.political_regime_id[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.political_regime_capability_bits[slot], sizeof(uint32_t));
    }
    if (!_cell_country_slot.empty()) hash_bytes(hash, _cell_country_slot.data(), _cell_country_slot.size() * sizeof(int32_t));
    if (!_country_technologies.empty()) hash_bytes(hash, _country_technologies.data(), _country_technologies.size() * sizeof(uint64_t));
    if (!_country_goods.empty()) hash_bytes(hash, _country_goods.data(), _country_goods.size() * sizeof(int64_t));
    if (!_country_discovered.empty()) hash_bytes(hash, _country_discovered.data(), _country_discovered.size() * sizeof(uint64_t));
    if (!_country_pending_technologies.empty()) hash_bytes(hash, _country_pending_technologies.data(), _country_pending_technologies.size() * sizeof(uint64_t));
    if (!_country_research_signals.empty())
        hash_bytes(hash, _country_research_signals.data(),
                   _country_research_signals.size() * sizeof(uint64_t));
    for (const auto &cells : _country_research_signal_cells)
        if (!cells.empty()) hash_bytes(hash, cells.data(), cells.size() * sizeof(uint64_t));
    for (const auto &entries : _country_research_signal_evidence)
        for (const SignalEvidence &entry : entries)
            // Hash fields individually: native struct padding is not stable across
            // construction/restore and must never affect a persisted-state hash.
            hash_bytes(hash, &entry.signal, sizeof(entry.signal)),
            hash_bytes(hash, &entry.count, sizeof(entry.count)),
            hash_bytes(hash, &entry.first_day, sizeof(entry.first_day)),
            hash_bytes(hash, &entry.last_day, sizeof(entry.last_day)),
            hash_bytes(hash, &entry.first_cell, sizeof(entry.first_cell));
    if (!_country_research_queues.empty()) hash_bytes(hash, _country_research_queues.data(), _country_research_queues.size() * sizeof(int32_t));
    if (!_country_research_queue_lengths.empty()) hash_bytes(hash, _country_research_queue_lengths.data(), _country_research_queue_lengths.size() * sizeof(uint8_t));
    if (!_country_research_weights_bp.empty()) hash_bytes(hash, _country_research_weights_bp.data(), _country_research_weights_bp.size() * sizeof(int32_t));
    if (!_country_research_daily_budgets.empty()) hash_bytes(hash, _country_research_daily_budgets.data(), _country_research_daily_budgets.size() * sizeof(int64_t));
    if (!_country_research_deferred_points.empty()) hash_bytes(hash, _country_research_deferred_points.data(), _country_research_deferred_points.size() * sizeof(int64_t));
    if (!_country_tax_defaults.empty())
        hash_bytes(hash, _country_tax_defaults.data(),
                   _country_tax_defaults.size() * sizeof(int32_t));
    if (!_country_tax_default_modes.empty())
        hash_bytes(hash, _country_tax_default_modes.data(),
                   _country_tax_default_modes.size() * sizeof(int32_t));
    if (!_country_income_tax_overrides.empty())
        hash_bytes(hash, _country_income_tax_overrides.data(),
                   _country_income_tax_overrides.size() * sizeof(int32_t));
    if (!_country_income_tax_mode_overrides.empty())
        hash_bytes(hash, _country_income_tax_mode_overrides.data(),
                   _country_income_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_consumption_tax_overrides.empty())
        hash_bytes(hash, _country_consumption_tax_overrides.data(),
                   _country_consumption_tax_overrides.size() * sizeof(int32_t));
    if (!_country_consumption_tax_mode_overrides.empty())
        hash_bytes(hash, _country_consumption_tax_mode_overrides.data(),
                   _country_consumption_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_business_tax_overrides.empty())
        hash_bytes(hash, _country_business_tax_overrides.data(),
                   _country_business_tax_overrides.size() * sizeof(int32_t));
    if (!_country_business_tax_mode_overrides.empty())
        hash_bytes(hash, _country_business_tax_mode_overrides.data(),
                   _country_business_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_import_tax_overrides.empty())
        hash_bytes(hash, _country_import_tax_overrides.data(),
                   _country_import_tax_overrides.size() * sizeof(int32_t));
    if (!_country_import_tax_mode_overrides.empty())
        hash_bytes(hash, _country_import_tax_mode_overrides.data(),
                   _country_import_tax_mode_overrides.size() *
                       sizeof(int32_t));
    if (!_country_export_tax_overrides.empty())
        hash_bytes(hash, _country_export_tax_overrides.data(),
                   _country_export_tax_overrides.size() * sizeof(int32_t));
    if (!_country_export_tax_mode_overrides.empty())
        hash_bytes(hash, _country_export_tax_mode_overrides.data(),
                   _country_export_tax_mode_overrides.size() *
                       sizeof(int32_t));
    uint64_t cell_policy_count = 0;
    for (uint32_t id : _cell_tax_policy_ids)
        if (!cell_tax_policy(id).empty()) ++cell_policy_count;
    hash_bytes(hash, &cell_policy_count, sizeof(cell_policy_count));
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const CellTaxPolicy &policy = cell_tax_policy(
            _cell_tax_policy_ids[static_cast<size_t>(cell)]);
        if (policy.empty()) continue;
        hash_bytes(hash, &cell, sizeof(cell));
        hash_bytes(hash, policy.defaults.data(),
                   policy.defaults.size() * sizeof(int32_t));
        hash_bytes(hash, policy.default_modes.data(),
                   policy.default_modes.size() * sizeof(int32_t));
        const uint64_t entry_count = policy.overrides.size();
        hash_bytes(hash, &entry_count, sizeof(entry_count));
        for (const CellTaxOverride &entry : policy.overrides) {
            hash_bytes(hash, &entry.kind, sizeof(entry.kind));
            hash_string(hash, tax_item_ids(entry.kind)[
                static_cast<size_t>(entry.item)]);
            hash_bytes(hash, &entry.rate, sizeof(entry.rate));
            hash_bytes(hash, &entry.mode, sizeof(entry.mode));
        }
    }
    hash_bytes(hash, &_tax_policy_version, sizeof(_tax_policy_version));
    hash_bytes(hash, &_last_research_day, sizeof(_last_research_day));
    for (const auto &entries : _country_research_progress) {
        for (const auto &entry : entries) {
            hash_bytes(hash, &entry.first, sizeof(entry.first));
            hash_bytes(hash, &entry.second, sizeof(entry.second));
        }
    }
    hash_bytes(hash, &_era_reward_reference.plan_id,
               sizeof(_era_reward_reference.plan_id));
    hash_bytes(hash, &_era_reward_reference.offer_generation,
               sizeof(_era_reward_reference.offer_generation));
    hash_bytes(hash, &_era_reward_reference.milestone_technology,
               sizeof(_era_reward_reference.milestone_technology));
    hash_bytes(hash, &_era_reward_reference.status,
               sizeof(_era_reward_reference.status));
    return hash;
}
uint64_t NativeCountryRuntime::catalog_hash_v3() const {
    uint64_t hash = FNV_OFFSET;
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
    if (!_technology_domains.empty())
        hash_bytes(hash, _technology_domains.data(),
                   _technology_domains.size() * sizeof(int32_t));
    if (!_technology_costs.empty())
        hash_bytes(hash, _technology_costs.data(),
                   _technology_costs.size() * sizeof(int64_t));
    if (!_technology_prerequisite_offsets.empty())
        hash_bytes(hash, _technology_prerequisite_offsets.data(),
                   _technology_prerequisite_offsets.size() *
                       sizeof(int32_t));
    if (!_technology_prerequisites.empty())
        hash_bytes(hash, _technology_prerequisites.data(),
                   _technology_prerequisites.size() * sizeof(int32_t));
    if (!_technology_entry_milestone_indices.empty())
        hash_bytes(hash, _technology_entry_milestone_indices.data(),
                   _technology_entry_milestone_indices.size() * sizeof(int32_t));
    return hash;
}

int64_t NativeCountryRuntime::state_hash_v3_compat() const {
    uint64_t hash = FNV_OFFSET;
    hash_bytes(hash, &_generation, sizeof(_generation));
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        hash_bytes(hash, &_countries.active[slot], sizeof(uint8_t));
        hash_bytes(hash, &_countries.generation[slot], sizeof(uint32_t));
        hash_string(hash, _countries.stable_id[slot]);
        hash_string(hash, _countries.display_name[slot]);
        hash_bytes(hash, &_countries.territory_count[slot], sizeof(int32_t));
        hash_bytes(hash, &_countries.cash[slot], sizeof(int64_t));
        hash_bytes(hash, &_countries.state_version[slot], sizeof(uint64_t));
    }
    if (!_cell_country_slot.empty())
        hash_bytes(hash, _cell_country_slot.data(),
                   _cell_country_slot.size() * sizeof(int32_t));
    if (!_country_technologies.empty())
        hash_bytes(hash, _country_technologies.data(),
                   _country_technologies.size() * sizeof(uint64_t));
    if (!_country_goods.empty())
        hash_bytes(hash, _country_goods.data(),
                   _country_goods.size() * sizeof(int64_t));
    if (!_country_discovered.empty())
        hash_bytes(hash, _country_discovered.data(),
                   _country_discovered.size() * sizeof(uint64_t));
    if (!_country_pending_technologies.empty())
        hash_bytes(hash, _country_pending_technologies.data(),
                   _country_pending_technologies.size() * sizeof(uint64_t));
    if (!_country_research_queues.empty())
        hash_bytes(hash, _country_research_queues.data(),
                   _country_research_queues.size() * sizeof(int32_t));
    if (!_country_research_queue_lengths.empty())
        hash_bytes(hash, _country_research_queue_lengths.data(),
                   _country_research_queue_lengths.size() * sizeof(uint8_t));
    if (!_country_research_weights_bp.empty())
        hash_bytes(hash, _country_research_weights_bp.data(),
                   _country_research_weights_bp.size() * sizeof(int32_t));
    if (!_country_research_daily_budgets.empty())
        hash_bytes(hash, _country_research_daily_budgets.data(),
                   _country_research_daily_budgets.size() * sizeof(int64_t));
    if (!_country_research_deferred_points.empty())
        hash_bytes(hash, _country_research_deferred_points.data(),
                   _country_research_deferred_points.size() * sizeof(int64_t));
    hash_bytes(hash, &_last_research_day, sizeof(_last_research_day));
    for (const auto &entries : _country_research_progress) {
        for (const auto &entry : entries) {
            hash_bytes(hash, &entry.first, sizeof(entry.first));
            hash_bytes(hash, &entry.second, sizeof(entry.second));
        }
    }
    return static_cast<int64_t>(hash);
}

int64_t NativeCountryRuntime::state_hash() const {
    const bool cache_matches = _state_hash_cache_valid &&
        _state_hash_cache_generation == _generation &&
        _state_hash_cache_research_day == _last_research_day &&
        _state_hash_cache_tax_policy_version == _tax_policy_version &&
        _state_hash_cache_era_reward.plan_id == _era_reward_reference.plan_id &&
        _state_hash_cache_era_reward.offer_generation == _era_reward_reference.offer_generation &&
        _state_hash_cache_era_reward.milestone_technology == _era_reward_reference.milestone_technology &&
        _state_hash_cache_era_reward.status == _era_reward_reference.status;
    if (!cache_matches) {
        _state_hash_cache = compute_state_hash();
        _state_hash_cache_generation = _generation;
        _state_hash_cache_research_day = _last_research_day;
        _state_hash_cache_tax_policy_version = _tax_policy_version;
        _state_hash_cache_era_reward = _era_reward_reference;
        _state_hash_cache_valid = true;
    }
    return static_cast<int64_t>(_state_hash_cache);
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
    append_vector(out, _country_research_daily_budgets);
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
    std::string id;
    for (const std::string &expected : _good_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }
    for (const std::string &expected : _profession_ids)
        if (!read_string(bytes, cursor, id) || id != expected) {
            error = "catalog_hash_mismatch";
            return false;
        }
    for (const std::string &expected : _building_type_ids)
        if (!read_string(bytes, cursor, id) || id != expected) {
            error = "catalog_hash_mismatch";
            return false;
        }
    for (const std::string &expected : _technology_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }
    for (const std::string &expected : _research_signal_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "catalog_hash_mismatch"; return false; }

    CountryStore countries;
    countries.active.resize(country_count);
    countries.generation.resize(country_count);
    countries.stable_id.resize(country_count);
    countries.display_name.resize(country_count);
    countries.territory_count.resize(country_count);
    countries.cash.resize(country_count);
    countries.state_version.resize(country_count);
    countries.political_regime_id.resize(country_count, 0);
    countries.political_regime_capability_bits.resize(country_count, 0);
    std::unordered_set<std::string> stable_ids;
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (!read_le(bytes, cursor, countries.active[slot]) || !read_le(bytes, cursor, countries.generation[slot]) ||
            !read_string(bytes, cursor, countries.stable_id[slot]) || !read_string(bytes, cursor, countries.display_name[slot]) ||
            !read_le(bytes, cursor, countries.territory_count[slot]) || !read_le(bytes, cursor, countries.cash[slot]) ||
            !read_le(bytes, cursor, countries.state_version[slot])) { error = "country_save_country_record_truncated"; return false; }
        if (version >= 15) {
            if (!read_le(bytes, cursor, countries.political_regime_id[slot]) ||
                !read_le(bytes, cursor, countries.political_regime_capability_bits[slot])) {
                error = "country_save_country_record_truncated";
                return false;
            }
            if (countries.political_regime_id[slot] < 0 ||
                static_cast<size_t>(countries.political_regime_id[slot]) >= _political_regime_ids.size() ||
                countries.political_regime_capability_bits[slot] !=
                    _political_regime_capability_bits[static_cast<size_t>(countries.political_regime_id[slot])]) {
                error = "country_save_political_regime_invalid";
                return false;
            }
        } else {
            const auto legacy = _political_regime_index.find("local_council");
            countries.political_regime_id[slot] = legacy == _political_regime_index.end() ? 0 : legacy->second;
            countries.political_regime_capability_bits[slot] =
                countries.political_regime_id[slot] >= 0 &&
                static_cast<size_t>(countries.political_regime_id[slot]) < _political_regime_capability_bits.size()
                ? _political_regime_capability_bits[static_cast<size_t>(countries.political_regime_id[slot])] : 0u;
        }
        // v14 admits annexed (inactive) records: they keep their identity and
        // bumped generation, own no territory and hold no treasury.
        const bool inactive_record = countries.active[slot] == 0;
        if ((inactive_record && (version < 14 || countries.territory_count[slot] != 0 ||
                                 countries.cash[slot] != 0)) ||
            countries.active[slot] > 1 ||
            countries.generation[slot] == 0 || countries.stable_id[slot].empty() ||
            countries.display_name[slot].empty() ||
            (!inactive_record && countries.territory_count[slot] <= 0) ||
            countries.cash[slot] < 0 ||
            !stable_ids.insert(countries.stable_id[slot]).second) { error = "country_save_country_record_invalid"; return false; }
    }
    std::vector<int32_t> owners;
    std::vector<uint64_t> technologies;
    std::vector<int64_t> goods;
    if (!read_vector(bytes, cursor, owners, static_cast<uint64_t>(_cell_count)) || owners.size() != static_cast<size_t>(_cell_count) ||
        !read_vector(bytes, cursor, technologies, static_cast<uint64_t>(country_count) * _technology_words) ||
        technologies.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, goods, static_cast<uint64_t>(country_count) * _good_ids.size()) ||
        goods.size() != static_cast<size_t>(country_count) * _good_ids.size()) { error = "country_save_matrix_shape_invalid"; return false; }
    std::vector<uint64_t> discovered, pending, signals;
    std::vector<int32_t> research_queues, research_weights;
    std::vector<uint8_t> research_queue_lengths, auto_purchase;
    std::vector<int64_t> daily_budgets, deferred_points, purchased_total,
        consumed_total, progress_total, completed_total;
    int64_t last_research_day = -1;
    const uint64_t countries_u64 = static_cast<uint64_t>(country_count);
    if (!read_vector(bytes, cursor, discovered, countries_u64 * _technology_words) ||
        discovered.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, pending, countries_u64 * _technology_words) ||
        pending.size() != static_cast<size_t>(country_count) * _technology_words ||
        !read_vector(bytes, cursor, signals, countries_u64 * _research_signal_words) ||
        signals.size() != static_cast<size_t>(country_count) * _research_signal_words) {
        error = "country_save_research_shape_invalid";
        return false;
    }
    uint64_t signal_cell_country_count = 0;
    if (!read_le(bytes, cursor, signal_cell_country_count) ||
        signal_cell_country_count != countries_u64) {
        error = "country_save_signal_cells_shape_invalid";
        return false;
    }
    std::vector<std::vector<uint64_t>> signal_cells(static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (!read_vector(bytes, cursor, signal_cells[static_cast<size_t>(slot)],
                         static_cast<uint64_t>(_cell_count) *
                             std::max<int32_t>(signal_count, 1))) {
            error = "country_save_signal_cells_shape_invalid";
            return false;
        }
        if (!std::is_sorted(signal_cells[static_cast<size_t>(slot)].begin(),
                            signal_cells[static_cast<size_t>(slot)].end()) ||
            std::adjacent_find(signal_cells[static_cast<size_t>(slot)].begin(),
                               signal_cells[static_cast<size_t>(slot)].end()) !=
                signal_cells[static_cast<size_t>(slot)].end()) {
            error = "country_save_signal_cells_invalid";
            return false;
        }
        for (uint64_t key : signal_cells[static_cast<size_t>(slot)]) {
            const int32_t signal = static_cast<int32_t>(key >> 32U);
            const int32_t cell = static_cast<int32_t>(key & 0xffffffffU);
            if (signal < 0 || signal >= signal_count || cell < 0 || cell >= _cell_count) {
                error = "country_save_signal_cells_invalid";
                return false;
            }
        }
    }
    uint64_t signal_evidence_country_count = 0;
    if (!read_le(bytes, cursor, signal_evidence_country_count) ||
        signal_evidence_country_count != countries_u64) {
        error = "country_save_signal_evidence_shape_invalid";
        return false;
    }
    std::vector<std::vector<SignalEvidence>> signal_evidence(
        static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        uint64_t entry_count = 0;
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > static_cast<uint64_t>(signal_count)) {
            error = "country_save_signal_evidence_shape_invalid";
            return false;
        }
        int32_t previous_signal = -1;
        for (uint64_t entry_index = 0; entry_index < entry_count; ++entry_index) {
            SignalEvidence entry;
            if (!read_le(bytes, cursor, entry.signal) || !read_le(bytes, cursor, entry.count) ||
                !read_le(bytes, cursor, entry.first_day) || !read_le(bytes, cursor, entry.last_day) ||
                !read_le(bytes, cursor, entry.first_cell) || entry.signal <= previous_signal ||
                entry.signal < 0 || entry.signal >= signal_count || entry.count <= 0 ||
                entry.first_day < 0 || entry.last_day < entry.first_day ||
                entry.first_cell < 0 || entry.first_cell >= _cell_count) {
                error = "country_save_signal_evidence_invalid";
                return false;
            }
            signal_evidence[static_cast<size_t>(slot)].push_back(entry);
            previous_signal = entry.signal;
        }
    }
    if (!read_vector(bytes, cursor, research_queues, countries_u64 * 32U) ||
        research_queues.size() != static_cast<size_t>(country_count) * 32U ||
        !read_vector(bytes, cursor, research_queue_lengths, countries_u64 * 4U) ||
        research_queue_lengths.size() != static_cast<size_t>(country_count) * 4U ||
        !read_vector(bytes, cursor, research_weights, countries_u64 * 4U) ||
        research_weights.size() != static_cast<size_t>(country_count) * 4U ||
        !read_vector(bytes, cursor, auto_purchase, countries_u64) ||
        auto_purchase.size() != static_cast<size_t>(country_count) ||
        !read_vector(bytes, cursor, daily_budgets, countries_u64) ||
        !read_vector(bytes, cursor, deferred_points, countries_u64) ||
        !read_vector(bytes, cursor, purchased_total, countries_u64) ||
        !read_vector(bytes, cursor, consumed_total, countries_u64) ||
        !read_vector(bytes, cursor, progress_total, countries_u64) ||
        !read_vector(bytes, cursor, completed_total, countries_u64) ||
        daily_budgets.size() != static_cast<size_t>(country_count) ||
        deferred_points.size() != static_cast<size_t>(country_count) ||
        purchased_total.size() != static_cast<size_t>(country_count) ||
        consumed_total.size() != static_cast<size_t>(country_count) ||
        progress_total.size() != static_cast<size_t>(country_count) ||
        completed_total.size() != static_cast<size_t>(country_count) ||
        !read_le(bytes, cursor, last_research_day)) {
        error = "country_save_research_shape_invalid";
        return false;
    }
    uint64_t progress_country_count = 0;
    if (!read_le(bytes, cursor, progress_country_count) ||
        progress_country_count != countries_u64) {
        error = "country_save_research_progress_shape_invalid";
        return false;
    }
    std::vector<std::vector<std::pair<int32_t, int64_t>>> research_progress(
        static_cast<size_t>(country_count));
    for (int32_t slot = 0; slot < country_count; ++slot) {
        uint64_t entry_count = 0;
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > static_cast<uint64_t>(_technology_ids.size())) {
            error = "country_save_research_progress_shape_invalid";
            return false;
        }
        int32_t previous_tech = -1;
        for (uint64_t entry = 0; entry < entry_count; ++entry) {
            int32_t tech = -1;
            int64_t value = 0;
            if (!read_le(bytes, cursor, tech) || !read_le(bytes, cursor, value) ||
                tech <= previous_tech || tech >= tech_count || value <= 0 ||
                value > max_storable_research_progress(tech)) {
                error = "country_save_research_progress_invalid";
                return false;
            }
            research_progress[static_cast<size_t>(slot)].push_back({tech, value});
            previous_tech = tech;
        }
    }
    for (int32_t slot = 0; slot < country_count; ++slot) {
        int32_t weight_total = 0;
        for (int32_t domain = 0; domain < 4; ++domain) {
            const size_t index = static_cast<size_t>(slot) * 4U + domain;
            if (research_queue_lengths[index] > 8 ||
                research_weights[index] < 0 || research_weights[index] > 10000) {
                error = "country_save_research_policy_invalid";
                return false;
            }
            weight_total += research_weights[index];
        }
        if (weight_total != 10000 || auto_purchase[static_cast<size_t>(slot)] > 1 ||
            daily_budgets[static_cast<size_t>(slot)] < 0 ||
            deferred_points[static_cast<size_t>(slot)] < 0) {
            error = "country_save_research_policy_invalid";
            return false;
        }
    }
    std::vector<int32_t> territory_counts(static_cast<size_t>(country_count), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t owner = owners[static_cast<size_t>(cell)];
        if (owner < NEUTRAL_SLOT || owner >= country_count ||
            (owner >= 0 && !_is_water.empty() && _is_water[static_cast<size_t>(cell)] != 0)) {
            error = "country_save_territory_invalid"; return false;
        }
        if (owner >= 0) ++territory_counts[static_cast<size_t>(owner)];
    }
    if (territory_counts != countries.territory_count) { error = "country_save_territory_count_mismatch"; return false; }
    for (int64_t quantity : goods) if (quantity < 0) { error = "country_save_treasury_negative"; return false; }
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (countries.active[static_cast<size_t>(slot)] != 0) continue;
        for (size_t good = 0; good < _good_ids.size(); ++good) {
            if (goods[static_cast<size_t>(slot) * _good_ids.size() + good] != 0) {
                error = "country_save_inactive_country_treasury";
                return false;
            }
        }
    }
    std::vector<int32_t> tax_defaults(
        static_cast<size_t>(country_count) * TAX_KIND_COUNT, 0);
    std::vector<int32_t> income_tax(
        static_cast<size_t>(country_count) * _profession_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> consumption_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> business_tax(
        static_cast<size_t>(country_count) * _building_type_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> import_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> export_tax(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_RATE_INHERIT);
    std::vector<int32_t> tax_default_modes(
        static_cast<size_t>(country_count) * TAX_KIND_COUNT,
        TAX_MODE_PERCENT_BP);
    std::vector<int32_t> income_tax_modes(
        static_cast<size_t>(country_count) * _profession_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> consumption_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> business_tax_modes(
        static_cast<size_t>(country_count) * _building_type_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> import_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    std::vector<int32_t> export_tax_modes(
        static_cast<size_t>(country_count) * _good_ids.size(),
        TAX_MODE_INHERIT);
    uint64_t tax_policy_version = 0;
    {
        bool read_ok = false;
        if (legacy_percent_tax_rates) {
            std::vector<int8_t> old_defaults, old_income, old_consumption;
            std::vector<int8_t> old_business, old_import, old_export;
            read_ok = read_vector(bytes, cursor, old_defaults,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) &&
                read_vector(bytes, cursor, old_income,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) &&
                read_vector(bytes, cursor, old_consumption,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, old_business,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) &&
                read_vector(bytes, cursor, old_import,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, old_export,
                    static_cast<uint64_t>(country_count) * _good_ids.size());
            const auto migrate = [](const std::vector<int8_t> &source,
                                    std::vector<int32_t> &target,
                                    bool allow_inherit) {
                target.resize(source.size());
                for (size_t i = 0; i < source.size(); ++i) {
                    target[i] = allow_inherit && source[i] == 127
                        ? TAX_RATE_INHERIT
                        : static_cast<int32_t>(source[i]) * 100;
                }
            };
            if (read_ok) {
                migrate(old_defaults, tax_defaults, false);
                migrate(old_income, income_tax, true);
                migrate(old_consumption, consumption_tax, true);
                migrate(old_business, business_tax, true);
                migrate(old_import, import_tax, true);
                migrate(old_export, export_tax, true);
            }
        } else {
            read_ok = read_vector(bytes, cursor, tax_defaults,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) &&
                read_vector(bytes, cursor, income_tax,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) &&
                read_vector(bytes, cursor, consumption_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, business_tax,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) &&
                read_vector(bytes, cursor, import_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) &&
                read_vector(bytes, cursor, export_tax,
                    static_cast<uint64_t>(country_count) * _good_ids.size());
        }
        if (!read_ok ||
            tax_defaults.size() !=
                static_cast<size_t>(country_count) * TAX_KIND_COUNT ||
            income_tax.size() != static_cast<size_t>(country_count) *
                _profession_ids.size() ||
            consumption_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size() ||
            business_tax.size() != static_cast<size_t>(country_count) *
                _building_type_ids.size() ||
            import_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size() ||
            export_tax.size() != static_cast<size_t>(country_count) *
                _good_ids.size()) {
            error = "country_save_tax_shape_invalid";
            return false;
        }
        if (has_tax_assessment_modes) {
            if (!read_vector(bytes, cursor, tax_default_modes,
                    static_cast<uint64_t>(country_count) * TAX_KIND_COUNT) ||
                !read_vector(bytes, cursor, income_tax_modes,
                    static_cast<uint64_t>(country_count) *
                        _profession_ids.size()) ||
                !read_vector(bytes, cursor, consumption_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                !read_vector(bytes, cursor, business_tax_modes,
                    static_cast<uint64_t>(country_count) *
                        _building_type_ids.size()) ||
                !read_vector(bytes, cursor, import_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                !read_vector(bytes, cursor, export_tax_modes,
                    static_cast<uint64_t>(country_count) * _good_ids.size()) ||
                tax_default_modes.size() !=
                    static_cast<size_t>(country_count) * TAX_KIND_COUNT ||
                income_tax_modes.size() !=
                    static_cast<size_t>(country_count) *
                        _profession_ids.size() ||
                consumption_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size() ||
                business_tax_modes.size() !=
                    static_cast<size_t>(country_count) *
                        _building_type_ids.size() ||
                import_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size() ||
                export_tax_modes.size() !=
                    static_cast<size_t>(country_count) * _good_ids.size()) {
                error = "country_save_tax_mode_shape_invalid";
                return false;
            }
        } else {
            tax_default_modes.assign(
                static_cast<size_t>(country_count) * TAX_KIND_COUNT,
                TAX_MODE_PERCENT_BP);
            income_tax_modes.assign(
                static_cast<size_t>(country_count) * _profession_ids.size(),
                TAX_MODE_INHERIT);
            consumption_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
            business_tax_modes.assign(
                static_cast<size_t>(country_count) *
                    _building_type_ids.size(),
                TAX_MODE_INHERIT);
            import_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
            export_tax_modes.assign(
                static_cast<size_t>(country_count) * _good_ids.size(),
                TAX_MODE_INHERIT);
        }
        if (!read_le(bytes, cursor, tax_policy_version)) {
            error = "country_save_tax_shape_invalid";
            return false;
        }
        for (size_t i = 0; i < tax_defaults.size(); ++i) {
            if (!tax_assessment_mode_valid(tax_default_modes[i]) ||
                !tax_value_valid(tax_default_modes[i], tax_defaults[i])) {
                error = "country_save_tax_rate_invalid";
                return false;
            }
        }
        const auto override_value_valid =
            [](int32_t mode, int32_t rate, int32_t default_mode) {
                if (rate == TAX_RATE_INHERIT) return mode == TAX_MODE_INHERIT;
                if (mode == TAX_MODE_INHERIT)
                    return tax_assessment_mode_valid(default_mode) &&
                           tax_value_valid(default_mode, rate);
                return tax_assessment_mode_valid(mode) &&
                       tax_value_valid(mode, rate);
            };
        const auto validate_overrides =
            [&](const std::vector<int32_t> &rates,
                const std::vector<int32_t> &modes, int32_t kind,
                int32_t item_count) {
                for (int32_t slot = 0; slot < country_count; ++slot) {
                    const int32_t default_mode = tax_default_modes[
                        static_cast<size_t>(slot) * TAX_KIND_COUNT + kind];
                    for (int32_t item = 0; item < item_count; ++item) {
                        const size_t index =
                            static_cast<size_t>(slot) * item_count + item;
                        if (!override_value_valid(modes[index], rates[index],
                                                  default_mode)) {
                            return false;
                        }
                    }
                }
                return true;
            };
        if (!validate_overrides(income_tax, income_tax_modes, TAX_INCOME,
                                static_cast<int32_t>(_profession_ids.size())) ||
            !validate_overrides(consumption_tax, consumption_tax_modes,
                                TAX_CONSUMPTION,
                                static_cast<int32_t>(_good_ids.size())) ||
            !validate_overrides(
                business_tax, business_tax_modes, TAX_BUSINESS,
                static_cast<int32_t>(_building_type_ids.size())) ||
            !validate_overrides(import_tax, import_tax_modes, TAX_IMPORT,
                                static_cast<int32_t>(_good_ids.size())) ||
            !validate_overrides(export_tax, export_tax_modes, TAX_EXPORT,
                                static_cast<int32_t>(_good_ids.size()))) {
            error = "country_save_tax_rate_invalid";
            return false;
        }
    }
    std::vector<uint32_t> cell_tax_policy_ids(
        static_cast<size_t>(_cell_count), 0);
    std::vector<CellTaxPolicy> cell_tax_policies(1);
    std::unordered_map<uint64_t, std::vector<uint32_t>> local_policy_intern;
    uint64_t saved_cell_policy_count = 0;
    if (!read_le(bytes, cursor, saved_cell_policy_count) ||
        saved_cell_policy_count > static_cast<uint64_t>(_cell_count)) {
        error = "country_save_cell_tax_count_invalid";
        return false;
    }
    int32_t previous_cell_policy = -1;
    for (uint64_t policy_index = 0;
         policy_index < saved_cell_policy_count; ++policy_index) {
        int32_t cell = -1;
        CellTaxPolicy policy;
        if (!read_le(bytes, cursor, cell) || cell <= previous_cell_policy ||
            cell < 0 || cell >= _cell_count ||
            owners[static_cast<size_t>(cell)] < 0) {
            error = "country_save_cell_tax_cell_invalid";
            return false;
        }
        for (int32_t &rate : policy.defaults) {
            if (legacy_percent_tax_rates) {
                int8_t old_rate = 0;
                if (!read_le(bytes, cursor, old_rate)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
                rate = old_rate == 127 ? TAX_RATE_INHERIT
                                       : static_cast<int32_t>(old_rate) * 100;
            } else if (!read_le(bytes, cursor, rate)) {
                error = "country_save_cell_tax_default_invalid";
                return false;
            }
        }
        if (has_tax_assessment_modes) {
            for (int32_t &mode : policy.default_modes) {
                if (!read_le(bytes, cursor, mode)) {
                    error = "country_save_cell_tax_default_mode_invalid";
                    return false;
                }
            }
        } else {
            policy.default_modes.fill(TAX_MODE_INHERIT);
        }
        for (size_t kind = 0; kind < TAX_KIND_COUNT; ++kind) {
            const int32_t rate = policy.defaults[kind];
            const int32_t mode = policy.default_modes[kind];
            if (rate == TAX_RATE_INHERIT) {
                if (mode != TAX_MODE_INHERIT &&
                    !tax_assessment_mode_valid(mode)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
            } else if (mode == TAX_MODE_INHERIT) {
                // Value inherits country assessment mode at resolve time;
                // accept either absolute or percent bounds.
                if (!tax_value_valid(TAX_MODE_PERCENT_BP, rate) &&
                    !tax_value_valid(TAX_MODE_ABSOLUTE, rate)) {
                    error = "country_save_cell_tax_default_invalid";
                    return false;
                }
            } else if (!tax_assessment_mode_valid(mode) ||
                       !tax_value_valid(mode, rate)) {
                error = "country_save_cell_tax_default_invalid";
                return false;
            }
        }
        uint64_t entry_count = 0;
        const uint64_t max_entries = static_cast<uint64_t>(
            _profession_ids.size() + _building_type_ids.size() +
            _good_ids.size() * 3U);
        if (!read_le(bytes, cursor, entry_count) ||
            entry_count > max_entries) {
            error = "country_save_cell_tax_entries_invalid";
            return false;
        }
        int32_t previous_kind = -1;
        int32_t previous_item = -1;
        for (uint64_t entry_index = 0; entry_index < entry_count;
             ++entry_index) {
            CellTaxOverride entry;
            std::string item_id;
            if (!read_le(bytes, cursor, entry.kind) ||
                !read_string(bytes, cursor, item_id)) {
                error = "country_save_cell_tax_entry_truncated";
                return false;
            }
            if (legacy_percent_tax_rates) {
                int8_t old_rate = 0;
                if (!read_le(bytes, cursor, old_rate)) {
                    error = "country_save_cell_tax_entry_truncated";
                    return false;
                }
                entry.rate = static_cast<int32_t>(old_rate) * 100;
            } else if (!read_le(bytes, cursor, entry.rate)) {
                error = "country_save_cell_tax_entry_truncated";
                return false;
            }
            if (has_tax_assessment_modes) {
                if (!read_le(bytes, cursor, entry.mode)) {
                    error = "country_save_cell_tax_entry_truncated";
                    return false;
                }
            } else {
                entry.mode = TAX_MODE_INHERIT;
            }
            entry.item = tax_item_index(entry.kind, item_id);
            const bool mode_ok =
                entry.mode == TAX_MODE_INHERIT ||
                tax_assessment_mode_valid(entry.mode);
            const bool rate_ok =
                entry.mode == TAX_MODE_INHERIT
                    ? (tax_value_valid(TAX_MODE_PERCENT_BP, entry.rate) ||
                       tax_value_valid(TAX_MODE_ABSOLUTE, entry.rate))
                    : tax_value_valid(entry.mode, entry.rate);
            if (entry.kind < 0 || entry.kind >= TAX_KIND_COUNT ||
                entry.item < 0 || !mode_ok || !rate_ok ||
                entry.kind < previous_kind ||
                (entry.kind == previous_kind && entry.item <= previous_item)) {
                error = "country_save_cell_tax_entry_invalid";
                return false;
            }
            policy.overrides.push_back(entry);
            previous_kind = entry.kind;
            previous_item = entry.item;
        }
        if (policy.empty()) {
            error = "country_save_cell_tax_empty_policy";
            return false;
        }
        const uint64_t hash = cell_tax_policy_hash(policy);
        uint32_t id_value = 0;
        auto &candidates = local_policy_intern[hash];
        for (uint32_t candidate : candidates) {
            if (cell_tax_policies[candidate] == policy) {
                id_value = candidate;
                break;
            }
        }
        if (id_value == 0) {
            id_value = static_cast<uint32_t>(cell_tax_policies.size());
            cell_tax_policies.push_back(std::move(policy));
            candidates.push_back(id_value);
        }
        cell_tax_policy_ids[static_cast<size_t>(cell)] = id_value;
        previous_cell_policy = cell;
    }
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
    _country_research_daily_budgets = std::move(daily_budgets);
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
        _effect_command_results.emplace(command.effect_request_id, EffectCommandResult{});
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
