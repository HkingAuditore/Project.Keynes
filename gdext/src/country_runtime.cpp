#include "country_runtime.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

namespace {
using Clock = std::chrono::steady_clock;
constexpr uint32_t SAVE_MAGIC = 0x4e434b50U; // PKCN
constexpr uint32_t SAVE_END = 0x21444e45U;   // END!
constexpr uint64_t FNV_OFFSET = 1469598103934665603ULL;
constexpr uint64_t FNV_PRIME = 1099511628211ULL;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

std::string to_utf8(const String &value) {
    const CharString bytes = value.utf8();
    return std::string(bytes.get_data(), static_cast<size_t>(bytes.length()));
}

template <typename T>
T dict_num(const Dictionary &d, const char *key, T fallback) {
    const StringName k(key);
    if (!d.has(k)) return fallback;
    const Variant value = d[k];
    if constexpr (std::is_same_v<T, int64_t>) return static_cast<int64_t>(value);
    if constexpr (std::is_same_v<T, int32_t>) return static_cast<int32_t>(static_cast<int64_t>(value));
    if constexpr (std::is_same_v<T, bool>) return static_cast<bool>(value);
    return fallback;
}

std::string dict_string(const Dictionary &d, const char *key,
                        const std::string &fallback = {}) {
    const StringName k(key);
    return d.has(k) ? to_utf8(static_cast<String>(d[k])) : fallback;
}

std::vector<std::string> packed_strings(const Dictionary &d, const char *key) {
    std::vector<std::string> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_STRING_ARRAY) return out;
    const PackedStringArray src = d[k];
    out.reserve(src.size());
    for (int i = 0; i < src.size(); ++i) out.push_back(to_utf8(src[i]));
    return out;
}

std::vector<int32_t> packed_i32(const Dictionary &d, const char *key) {
    std::vector<int32_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_INT32_ARRAY) return out;
    const PackedInt32Array src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int32_t));
    return out;
}

std::vector<int64_t> packed_i64(const Dictionary &d, const char *key) {
    std::vector<int64_t> out;
    const StringName k(key);
    if (!d.has(k) || d[k].get_type() != Variant::PACKED_INT64_ARRAY) return out;
    const PackedInt64Array src = d[k];
    out.resize(src.size());
    if (!out.empty()) std::memcpy(out.data(), src.ptr(), out.size() * sizeof(int64_t));
    return out;
}

void hash_bytes(uint64_t &hash, const void *data, size_t size) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= FNV_PRIME;
    }
}

void hash_string(uint64_t &hash, const std::string &value) {
    hash_bytes(hash, value.data(), value.size());
    const uint8_t zero = 0;
    hash_bytes(hash, &zero, 1);
}

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

Dictionary fail(const std::string &reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = String::utf8(reason.c_str());
    return out;
}
} // namespace

Dictionary NativeCountryRuntime::configure(const Dictionary &catalog,
                                            const Dictionary &profile,
                                            int32_t cell_count, int64_t seed) {
    if (cell_count <= 0) return fail("country_cell_count_invalid");
    const std::vector<std::string> goods = packed_strings(catalog, "good_ids");
    const std::vector<std::string> technologies = packed_strings(catalog, "technology_ids");
    if (goods.empty()) return fail("country_good_catalog_empty");

    std::unordered_set<std::string> unique;
    for (const std::string &id : goods)
        if (id.empty() || !unique.insert(id).second) return fail("country_good_catalog_invalid");
    unique.clear();
    for (const std::string &id : technologies)
        if (id.empty() || !unique.insert(id).second) return fail("country_technology_catalog_invalid");

    std::string mode = dict_string(profile, "country_runtime_mode", "ACTIVE");
    RuntimeMode parsed_mode = MODE_ACTIVE;
    if (mode == "OFF") parsed_mode = MODE_OFF;
    else if (mode == "PROBE") parsed_mode = MODE_PROBE;
    else if (mode != "ACTIVE") return fail("country_runtime_mode_invalid");

    _good_ids = goods;
    _technology_ids = technologies;
    _good_index.clear();
    _technology_index.clear();
    for (int32_t i = 0; i < static_cast<int32_t>(_good_ids.size()); ++i) _good_index[_good_ids[i]] = i;
    for (int32_t i = 0; i < static_cast<int32_t>(_technology_ids.size()); ++i) _technology_index[_technology_ids[i]] = i;
    _starting_technologies.clear();
    for (const std::string &id : packed_strings(profile, "starting_technology_ids")) {
        const auto it = _technology_index.find(id);
        if (it == _technology_index.end()) return fail("country_starting_technology_unknown");
        _starting_technologies.push_back(it->second);
    }
    std::sort(_starting_technologies.begin(), _starting_technologies.end());
    _starting_technologies.erase(std::unique(_starting_technologies.begin(), _starting_technologies.end()),
                                 _starting_technologies.end());

    _cell_count = cell_count;
    _seed = seed;
    _mode = parsed_mode;
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63U) / 64U);
    _max_commands_per_slice = std::max<int32_t>(1, dict_num<int32_t>(profile, "country_max_commands_per_slice", 65536));
    _configured = true;
    _bootstrapped = false;
    _generation = 0;
    _submit_order = 0;
    _next_event_id = 1;
    _last_committed_day = -1;
    _countries = {};
    _cell_country_slot.assign(static_cast<size_t>(_cell_count), NEUTRAL_SLOT);
    _country_cell_offsets.clear();
    _country_cells.clear();
    _country_technologies.clear();
    _country_goods.clear();
    _pending_commands.clear();
    _events.clear();
    _command_batch = {};
    _is_water.clear();
    _report.clear();
    _report["configured"] = true;
    _report["bootstrapped"] = false;
    _report["runtime_mode"] = mode.c_str();
    _report["schema_version"] = SCHEMA_VERSION;

    Dictionary out;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["runtime_mode"] = mode.c_str();
    out["cell_count"] = _cell_count;
    out["good_count"] = static_cast<int64_t>(_good_ids.size());
    out["technology_count"] = static_cast<int64_t>(_technology_ids.size());
    out["catalog_hash"] = static_cast<int64_t>(catalog_hash());
    return out;
}

int32_t NativeCountryRuntime::append_country(const std::string &stable_id,
                                              const std::string &display_name,
                                              int64_t cash) {
    const int32_t slot = static_cast<int32_t>(_countries.active.size());
    _countries.active.push_back(1);
    _countries.generation.push_back(1);
    _countries.stable_id.push_back(stable_id);
    _countries.display_name.push_back(display_name);
    _countries.territory_count.push_back(0);
    _countries.cash.push_back(cash);
    _countries.state_version.push_back(1);
    _country_technologies.resize(static_cast<size_t>(slot + 1) * _technology_words, 0);
    _country_goods.resize(static_cast<size_t>(slot + 1) * _good_ids.size(), 0);
    return slot;
}

Dictionary NativeCountryRuntime::bootstrap(const Dictionary &packet,
                                            const PackedByteArray &is_water) {
    if (!_configured) return fail("country_not_configured");
    if (is_water.size() != _cell_count) return fail("country_water_mask_size_mismatch");
    _is_water.resize(static_cast<size_t>(_cell_count));
    if (_cell_count > 0) std::memcpy(_is_water.data(), is_water.ptr(), static_cast<size_t>(_cell_count));

    const std::vector<std::string> ids = packed_strings(packet, "country_ids");
    const std::vector<std::string> names = packed_strings(packet, "country_names");
    const std::vector<int64_t> cash = packed_i64(packet, "country_cash");
    const std::vector<int32_t> territory_offsets = packed_i32(packet, "territory_offsets");
    const std::vector<int32_t> territory_cells = packed_i32(packet, "territory_cells");
    const std::vector<int32_t> tech_offsets = packed_i32(packet, "technology_offsets");
    const std::vector<int32_t> tech_indices = packed_i32(packet, "technology_indices");
    const std::vector<int32_t> treasury_offsets = packed_i32(packet, "treasury_offsets");
    const std::vector<int32_t> treasury_good_indices = packed_i32(packet, "treasury_good_indices");
    const std::vector<int64_t> treasury_quantities = packed_i64(packet, "treasury_quantities");

    _countries = {};
    std::fill(_cell_country_slot.begin(), _cell_country_slot.end(), NEUTRAL_SLOT);
    _country_technologies.clear();
    _country_goods.clear();
    _pending_commands.clear();
    _events.clear();
    _command_batch = {};

    if (ids.empty()) {
        int32_t land_count = 0;
        for (uint8_t water : _is_water) if (water == 0) ++land_count;
        if (land_count == 0) return fail("country_bootstrap_no_land");
        const int32_t slot = append_country("country.default", "默认国家", 0);
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            if (_is_water[static_cast<size_t>(cell)] != 0) continue;
            _cell_country_slot[static_cast<size_t>(cell)] = slot;
            ++_countries.territory_count[static_cast<size_t>(slot)];
        }
        for (int32_t tech : _starting_technologies)
            _country_technologies[static_cast<size_t>(slot) * _technology_words + tech / 64] |= 1ULL << (tech % 64);
        _starting_country_slot = slot;
    } else {
        if (names.size() != ids.size() || (!cash.empty() && cash.size() != ids.size()) ||
            territory_offsets.size() != ids.size() + 1 || territory_offsets.front() != 0 ||
            territory_offsets.back() != static_cast<int32_t>(territory_cells.size()))
            return fail("country_bootstrap_shape_invalid");
        if ((!tech_offsets.empty() && (tech_offsets.size() != ids.size() + 1 || tech_offsets.front() != 0 ||
             tech_offsets.back() != static_cast<int32_t>(tech_indices.size()))) ||
            (!treasury_offsets.empty() && (treasury_offsets.size() != ids.size() + 1 || treasury_offsets.front() != 0 ||
             treasury_offsets.back() != static_cast<int32_t>(treasury_good_indices.size()) ||
             treasury_good_indices.size() != treasury_quantities.size())))
            return fail("country_bootstrap_csr_invalid");

        std::unordered_set<std::string> stable_ids;
        for (size_t i = 0; i < ids.size(); ++i) {
            if (ids[i].empty() || names[i].empty() || !stable_ids.insert(ids[i]).second)
                return fail("country_bootstrap_identity_invalid");
            if (territory_offsets[i] == territory_offsets[i + 1]) return fail("country_bootstrap_zero_territory");
            append_country(ids[i], names[i], cash.empty() ? 0 : cash[i]);
        }
        for (size_t slot = 0; slot < ids.size(); ++slot) {
            for (int32_t edge = territory_offsets[slot]; edge < territory_offsets[slot + 1]; ++edge) {
                const int32_t cell = territory_cells[static_cast<size_t>(edge)];
                if (cell < 0 || cell >= _cell_count) return fail("country_bootstrap_cell_invalid");
                if (_is_water[static_cast<size_t>(cell)] != 0) return fail("country_bootstrap_water_owned");
                if (_cell_country_slot[static_cast<size_t>(cell)] != NEUTRAL_SLOT)
                    return fail("country_bootstrap_duplicate_territory");
                _cell_country_slot[static_cast<size_t>(cell)] = static_cast<int32_t>(slot);
                ++_countries.territory_count[slot];
            }
            if (tech_offsets.empty()) {
                for (int32_t tech : _starting_technologies)
                    _country_technologies[slot * _technology_words + tech / 64] |= 1ULL << (tech % 64);
            } else {
                for (int32_t edge = tech_offsets[slot]; edge < tech_offsets[slot + 1]; ++edge) {
                    const int32_t tech = tech_indices[static_cast<size_t>(edge)];
                    if (tech < 0 || tech >= static_cast<int32_t>(_technology_ids.size()))
                        return fail("country_bootstrap_technology_invalid");
                    _country_technologies[slot * _technology_words + tech / 64] |= 1ULL << (tech % 64);
                }
            }
            if (!treasury_offsets.empty()) {
                for (int32_t edge = treasury_offsets[slot]; edge < treasury_offsets[slot + 1]; ++edge) {
                    const int32_t good = treasury_good_indices[static_cast<size_t>(edge)];
                    const int64_t quantity = treasury_quantities[static_cast<size_t>(edge)];
                    if (good < 0 || good >= static_cast<int32_t>(_good_ids.size()) || quantity < 0)
                        return fail("country_bootstrap_treasury_invalid");
                    _country_goods[slot * _good_ids.size() + good] = quantity;
                }
            }
        }
        _starting_country_slot = 0;
    }

    rebuild_cell_csr();
    _generation = 1;
    _bootstrapped = true;
    _last_committed_day = -1;
    publish_report("aggregate_publish", -1, 0, 0, 0, _cell_count,
                   static_cast<int32_t>(_countries.active.size()), _mode == MODE_ACTIVE);
    Dictionary out = report();
    out["ok"] = true;
    out["default_bootstrap"] = ids.empty();
    return out;
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
    const std::vector<std::string> stable_ids = packed_strings(batch, "stable_ids");
    const std::vector<std::string> display_names = packed_strings(batch, "display_names");
    const size_t count = opcodes.size();
    if (count == 0) return fail("country_command_batch_empty");
    if (days.size() != count || sequences.size() != count || handles.size() != count ||
        cells.size() != count || aux.size() != count || stable_ids.size() != count ||
        display_names.size() != count)
        return fail("country_command_batch_shape_invalid");
    _pending_commands.reserve(_pending_commands.size() + count);
    for (size_t i = 0; i < count; ++i) {
        if (opcodes[i] < COMMAND_CREATE_COUNTRY || opcodes[i] > COMMAND_GRANT_TECHNOLOGY)
            return fail("country_command_opcode_invalid");
        if (days[i] < 0 || sequences[i] < 0) return fail("country_command_order_invalid");
        Command command;
        command.opcode = opcodes[i];
        command.effective_day = days[i];
        command.sequence = sequences[i];
        command.target_handle = static_cast<uint64_t>(handles[i]);
        command.cell = cells[i];
        command.aux = aux[i];
        command.stable_id = stable_ids[i];
        command.display_name = display_names[i];
        command.submit_order = ++_submit_order;
        _pending_commands.push_back(std::move(command));
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted"] = static_cast<int64_t>(count);
    out["pending"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool NativeCountryRuntime::should_run(int64_t day_index) const {
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) return false;
    if (_command_batch.active) return true;
    for (const Command &command : _pending_commands)
        if (command.effective_day <= day_index) return true;
    return false;
}

bool NativeCountryRuntime::validate_handle(uint64_t handle, int32_t &slot) const {
    slot = static_cast<int32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
    return slot >= 0 && slot < static_cast<int32_t>(_countries.active.size()) &&
           _countries.active[static_cast<size_t>(slot)] != 0 &&
           _countries.generation[static_cast<size_t>(slot)] == generation;
}

uint64_t NativeCountryRuntime::make_handle(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_countries.active.size())) return 0;
    return (static_cast<uint64_t>(_countries.generation[static_cast<size_t>(slot)]) << 32U) |
           static_cast<uint32_t>(slot);
}

Dictionary NativeCountryRuntime::run_slice(const Dictionary &ctx) {
    if (!_configured || !_bootstrapped) return fail("country_not_bootstrapped");
    const int64_t requested_day = dict_num<int64_t>(ctx, "day_index", 0);
    if (_mode == MODE_OFF) {
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["stage"] = "idle";
        out["path"] = "off";
        return out;
    }

    const Clock::time_point start = Clock::now();
    if (!_command_batch.active) {
        const bool all_due = std::all_of(_pending_commands.begin(), _pending_commands.end(),
            [&](const Command &command) { return command.effective_day <= requested_day; });
        if (all_due) {
            _command_batch.commands.swap(_pending_commands);
        } else {
            std::vector<Command> future_commands;
            _command_batch.commands.reserve(_pending_commands.size());
            future_commands.reserve(_pending_commands.size());
            for (Command &command : _pending_commands) {
                if (command.effective_day <= requested_day)
                    _command_batch.commands.push_back(std::move(command));
                else
                    future_commands.push_back(std::move(command));
            }
            _pending_commands.swap(future_commands);
        }
        if (_command_batch.commands.empty()) {
            Dictionary out = report();
            out["ok"] = true;
            out["done"] = true;
            out["stage"] = "idle";
            out["elapsed_ms"] = 0.0;
            return out;
        }
        const auto command_less = [](const Command &lhs, const Command &rhs) {
            if (lhs.effective_day != rhs.effective_day)
                return lhs.effective_day < rhs.effective_day;
            if (lhs.sequence != rhs.sequence) return lhs.sequence < rhs.sequence;
            return lhs.submit_order < rhs.submit_order;
        };
        if (!std::is_sorted(_command_batch.commands.begin(), _command_batch.commands.end(),
                            command_less))
            std::sort(_command_batch.commands.begin(), _command_batch.commands.end(), command_less);
        _command_batch.active = true;
        _command_batch.day = requested_day;
        _command_batch.cursor = 0;
        _command_batch.preflight_ms = 0.0;
        _command_batch.countries = _countries;
        _command_batch.direct_unique_territory = !_command_batch.commands.empty();
        int32_t previous_cell = -1;
        for (const Command &command : _command_batch.commands) {
            if (command.opcode == COMMAND_CREATE_COUNTRY) {
                _command_batch.stage_technologies = true;
                _command_batch.stage_goods = true;
            } else if (command.opcode == COMMAND_GRANT_TECHNOLOGY) {
                _command_batch.stage_technologies = true;
            }
            if (command.opcode != COMMAND_TRANSFER_TERRITORY || command.cell <= previous_cell) {
                _command_batch.direct_unique_territory = false;
            } else {
                previous_cell = command.cell;
            }
        }
        if (_command_batch.stage_technologies)
            _command_batch.technologies = _country_technologies;
        if (_command_batch.stage_goods)
            _command_batch.goods = _country_goods;
        if (!_command_batch.direct_unique_territory)
            _command_batch.cell_delta.reserve(_command_batch.commands.size());
        _command_batch.cell_delta_order.reserve(_command_batch.commands.size());
        if (_command_batch.direct_unique_territory)
            _command_batch.direct_cell_owners.reserve(_command_batch.commands.size());
        // The public ring is capped at 2048 entries. Reserving one Event per
        // territory command made a 100k-cell transfer allocate several MiB of
        // unused string-bearing records on the hot path.
        _command_batch.events.reserve(std::min<size_t>(_command_batch.commands.size(), 2048));
        _command_batch.changed_countries.assign(_countries.active.size(), 0);
    }

    CommandBatchState &batch = _command_batch;
    const int64_t day = batch.day;
    const size_t cursor_start = batch.cursor;
    const size_t cursor_limit = std::min(batch.commands.size(),
        batch.cursor + static_cast<size_t>(_max_commands_per_slice));
    std::string error;

    auto staged_handle = [&](uint64_t handle, int32_t &slot) -> bool {
        slot = static_cast<int32_t>(handle & 0xffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
        return slot >= 0 && slot < static_cast<int32_t>(batch.countries.active.size()) &&
               batch.countries.active[static_cast<size_t>(slot)] != 0 &&
               batch.countries.generation[static_cast<size_t>(slot)] == generation;
    };
    auto owner_of = [&](int32_t cell) -> int32_t {
        int32_t owner = NEUTRAL_SLOT;
        return batch.cell_delta.get(cell, owner)
            ? owner : _cell_country_slot[static_cast<size_t>(cell)];
    };
    auto mark_country = [&](int32_t slot) {
        if (slot < 0) return;
        if (slot >= static_cast<int32_t>(batch.changed_countries.size()))
            batch.changed_countries.resize(static_cast<size_t>(slot + 1), 0);
        batch.changed_countries[static_cast<size_t>(slot)] = 1;
    };

    for (; batch.cursor < cursor_limit; ++batch.cursor) {
        const Command &command = batch.commands[batch.cursor];
        uint64_t event_country_handle = 0;
        int32_t event_old_country_slot = NEUTRAL_SLOT;
        int32_t event_new_country_slot = NEUTRAL_SLOT;

        if (command.opcode == COMMAND_CREATE_COUNTRY) {
            if (command.stable_id.empty() || command.display_name.empty() ||
                std::find(batch.countries.stable_id.begin(), batch.countries.stable_id.end(),
                          command.stable_id) != batch.countries.stable_id.end()) {
                error = "country_create_identity_invalid"; break;
            }
            if (command.cell < 0 || command.cell >= _cell_count || _is_water[static_cast<size_t>(command.cell)] != 0) {
                error = "country_create_territory_invalid"; break;
            }
            const int32_t old_owner = batch.direct_unique_territory
                ? _cell_country_slot[static_cast<size_t>(command.cell)]
                : owner_of(command.cell);
            const int32_t new_slot = static_cast<int32_t>(batch.countries.active.size());
            batch.countries.active.push_back(1);
            batch.countries.generation.push_back(1);
            batch.countries.stable_id.push_back(command.stable_id);
            batch.countries.display_name.push_back(command.display_name);
            batch.countries.territory_count.push_back(1);
            batch.countries.cash.push_back(0);
            batch.countries.state_version.push_back(1);
            batch.technologies.resize(static_cast<size_t>(new_slot + 1) * _technology_words, 0);
            batch.goods.resize(static_cast<size_t>(new_slot + 1) * _good_ids.size(), 0);
            if (old_owner >= 0) {
                --batch.countries.territory_count[static_cast<size_t>(old_owner)];
                for (int32_t word = 0; word < _technology_words; ++word)
                    batch.technologies[static_cast<size_t>(new_slot) * _technology_words + word] =
                        batch.technologies[static_cast<size_t>(old_owner) * _technology_words + word];
                mark_country(old_owner);
            } else {
                for (int32_t tech : _starting_technologies)
                    batch.technologies[static_cast<size_t>(new_slot) * _technology_words + tech / 64] |=
                        1ULL << (tech % 64);
            }
            if (batch.cell_delta.set(command.cell, new_slot))
                batch.cell_delta_order.push_back(command.cell);
            mark_country(new_slot);
            event_country_handle = (1ULL << 32U) | static_cast<uint32_t>(new_slot);
            event_old_country_slot = old_owner;
            event_new_country_slot = new_slot;
        } else if (command.opcode == COMMAND_RENAME_COUNTRY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.display_name.empty()) { error = "country_name_empty"; break; }
            batch.countries.display_name[static_cast<size_t>(slot)] = command.display_name;
            ++batch.countries.state_version[static_cast<size_t>(slot)];
            mark_country(slot);
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY) {
            if (command.cell < 0 || command.cell >= _cell_count || _is_water[static_cast<size_t>(command.cell)] != 0) {
                error = "country_transfer_cell_invalid"; break;
            }
            int32_t target = NEUTRAL_SLOT;
            if (command.target_handle != 0 && !staged_handle(command.target_handle, target)) {
                error = "country_handle_invalid"; break;
            }
            const int32_t old_owner = batch.direct_unique_territory
                ? _cell_country_slot[static_cast<size_t>(command.cell)]
                : owner_of(command.cell);
            if (old_owner == target) continue;
            if (old_owner >= 0) {
                --batch.countries.territory_count[static_cast<size_t>(old_owner)];
                ++batch.countries.state_version[static_cast<size_t>(old_owner)];
                mark_country(old_owner);
            }
            if (target >= 0) {
                ++batch.countries.territory_count[static_cast<size_t>(target)];
                ++batch.countries.state_version[static_cast<size_t>(target)];
                mark_country(target);
            }
            if (batch.direct_unique_territory) {
                batch.cell_delta_order.push_back(command.cell);
                batch.direct_cell_owners.push_back(target);
            } else if (batch.cell_delta.set(command.cell, target)) {
                batch.cell_delta_order.push_back(command.cell);
            }
            event_country_handle = target >= 0 ? ((static_cast<uint64_t>(batch.countries.generation[target]) << 32U) |
                                                   static_cast<uint32_t>(target)) : 0;
            event_old_country_slot = old_owner;
            event_new_country_slot = target;
        } else if (command.opcode == COMMAND_GRANT_TECHNOLOGY) {
            int32_t slot = -1;
            if (!staged_handle(command.target_handle, slot)) { error = "country_handle_invalid"; break; }
            if (command.aux < 0 || command.aux >= static_cast<int32_t>(_technology_ids.size())) {
                error = "country_technology_invalid"; break;
            }
            uint64_t &word = batch.technologies[
                static_cast<size_t>(slot) * _technology_words + command.aux / 64];
            const uint64_t bit = 1ULL << (command.aux % 64);
            if ((word & bit) == 0) {
                word |= bit;
                ++batch.countries.state_version[static_cast<size_t>(slot)];
                mark_country(slot);
            }
            event_country_handle = command.target_handle;
            event_new_country_slot = slot;
        }
        // The public event ring retains at most 2048 records. Avoid staging
        // tens of thousands of events that would be discarded immediately by
        // keeping the deterministic tail of very large atomic batches.
        if (command.opcode != COMMAND_TRANSFER_TERRITORY ||
            batch.commands.size() <= 2048 || batch.cursor + 2048 >= batch.commands.size()) {
            Event event;
            event.day = day;
            event.opcode = command.opcode;
            event.country_handle = event_country_handle;
            event.cell = command.cell;
            event.old_country_slot = event_old_country_slot;
            event.new_country_slot = event_new_country_slot;
            event.technology_id = command.aux;
            event.stable_id = command.stable_id;
            event.display_name = command.display_name;
            batch.events.push_back(std::move(event));
        }
    }
    batch.preflight_ms += elapsed_ms(start);

    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        _command_batch = {};
        publish_report("command_preflight", day, preflight_ms, 0, 0, 0, 0, false, error);
        Dictionary out = report();
        out["ok"] = false;
        out["done"] = true;
        out["fatal_reason"] = error.c_str();
        return out;
    }

    if (batch.cursor < batch.commands.size()) {
        publish_report("command_preflight", day, batch.preflight_ms, 0, 0, 0, 0, false);
        Dictionary out = report();
        out["ok"] = true;
        out["done"] = false;
        out["country_day_barrier"] = true;
        out["cursor_start"] = static_cast<int64_t>(cursor_start);
        out["cursor_end"] = static_cast<int64_t>(batch.cursor);
        out["cursor_total"] = static_cast<int64_t>(batch.commands.size());
        out["progress_ratio"] = static_cast<double>(batch.cursor) /
            static_cast<double>(batch.commands.size());
        out["elapsed_ms"] = batch.preflight_ms;
        return out;
    }

    for (size_t slot = 0; slot < batch.countries.active.size(); ++slot) {
        if (batch.countries.active[slot] != 0 && batch.countries.territory_count[slot] <= 0) {
                error = "country_last_territory_protected";
            break;
        }
    }
    if (!error.empty()) {
        const double preflight_ms = batch.preflight_ms;
        _command_batch = {};
        publish_report("command_preflight", day, preflight_ms, 0, 0, 0, 0, false, error);
        Dictionary out = report();
        out["ok"] = false;
        out["done"] = true;
        out["fatal_reason"] = error.c_str();
        return out;
    }

    const double preflight_ms = batch.preflight_ms;
    const int32_t changed_country_count = static_cast<int32_t>(std::count(
        batch.changed_countries.begin(), batch.changed_countries.end(), uint8_t{1}));
    SparseCellDelta cell_delta = std::move(batch.cell_delta);
    std::vector<int32_t> cell_delta_order = std::move(batch.cell_delta_order);
    std::vector<int32_t> direct_cell_owners = std::move(batch.direct_cell_owners);
    const bool direct_unique_territory = batch.direct_unique_territory;
    std::vector<Event> staged_events = std::move(batch.events);
    CountryStore staged_countries = std::move(batch.countries);
    std::vector<uint64_t> staged_technologies = std::move(batch.technologies);
    std::vector<int64_t> staged_goods = std::move(batch.goods);
    const bool stage_technologies = batch.stage_technologies;
    const bool stage_goods = batch.stage_goods;
    _command_batch = {};

    const Clock::time_point apply_start = Clock::now();
    _countries = std::move(staged_countries);
    if (stage_technologies) _country_technologies = std::move(staged_technologies);
    if (stage_goods) _country_goods = std::move(staged_goods);
    for (size_t i = 0; i < cell_delta_order.size(); ++i) {
        int32_t owner = NEUTRAL_SLOT;
        if (direct_unique_territory || cell_delta.get(cell_delta_order[i], owner)) {
            if (direct_unique_territory) owner = direct_cell_owners[i];
            _cell_country_slot[static_cast<size_t>(cell_delta_order[i])] = owner;
        }
    }
    const double apply_ms = elapsed_ms(apply_start);
    const Clock::time_point publish_start = Clock::now();
    if (!cell_delta_order.empty()) rebuild_cell_csr();
    ++_generation;
    _last_committed_day = day;
    for (Event &event : staged_events) push_event(std::move(event));
    const double aggregate_ms = elapsed_ms(publish_start);
    publish_report("aggregate_publish", day, preflight_ms, apply_ms, aggregate_ms,
                   static_cast<int32_t>(cell_delta_order.size()),
                   changed_country_count, _mode == MODE_ACTIVE);
    Dictionary out = report();
    out["ok"] = true;
    out["done"] = true;
    out["elapsed_ms"] = preflight_ms + apply_ms + aggregate_ms;
    out["cursor_start"] = 0;
    out["cursor_end"] = static_cast<int64_t>(cursor_limit);
    out["cursor_total"] = static_cast<int64_t>(cursor_limit);
    out["progress_ratio"] = 1.0;
    out["country_day_barrier"] = should_run(day);
    if (!cell_delta_order.empty()) {
        if (!std::is_sorted(cell_delta_order.begin(), cell_delta_order.end()))
            std::sort(cell_delta_order.begin(), cell_delta_order.end());
        PackedInt32Array changed_cells;
        PackedInt32Array changed_owners;
        changed_cells.resize(static_cast<int64_t>(cell_delta_order.size()));
        changed_owners.resize(static_cast<int64_t>(cell_delta_order.size()));
        int32_t *cell_ptr = changed_cells.ptrw();
        int32_t *owner_ptr = changed_owners.ptrw();
        for (size_t i = 0; i < cell_delta_order.size(); ++i) {
            cell_ptr[i] = cell_delta_order[i];
            int32_t owner = direct_unique_territory ? direct_cell_owners[i] : NEUTRAL_SLOT;
            if (!direct_unique_territory) cell_delta.get(cell_delta_order[i], owner);
            owner_ptr[i] = owner;
        }
        out["_changed_cell_indices"] = changed_cells;
        out["_changed_cell_owners"] = changed_owners;
    }
    return out;
}

void NativeCountryRuntime::rebuild_cell_csr() {
    const int32_t count = static_cast<int32_t>(_countries.active.size());
    _country_cell_offsets.assign(static_cast<size_t>(count + 1), 0);
    for (int32_t owner : _cell_country_slot)
        if (owner >= 0 && owner < count) ++_country_cell_offsets[static_cast<size_t>(owner + 1)];
    for (int32_t slot = 0; slot < count; ++slot)
        _country_cell_offsets[static_cast<size_t>(slot + 1)] += _country_cell_offsets[static_cast<size_t>(slot)];
    _country_cells.assign(static_cast<size_t>(_country_cell_offsets.back()), -1);
    std::vector<int32_t> cursor = _country_cell_offsets;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t owner = _cell_country_slot[static_cast<size_t>(cell)];
        if (owner >= 0 && owner < count) _country_cells[static_cast<size_t>(cursor[static_cast<size_t>(owner)]++)] = cell;
    }
}

void NativeCountryRuntime::publish_report(const char *stage, int64_t day,
                                          double preflight_ms, double apply_ms,
                                          double publish_ms, int32_t changed_cells,
                                          int32_t changed_countries, bool published,
                                          const std::string &reason) {
    _report.clear();
    _report["configured"] = _configured;
    _report["bootstrapped"] = _bootstrapped;
    _report["schema_version"] = SCHEMA_VERSION;
    _report["runtime_mode"] = _mode == MODE_ACTIVE ? "ACTIVE" : (_mode == MODE_PROBE ? "PROBE" : "OFF");
    _report["path"] = _mode == MODE_ACTIVE ? "native_active" : (_mode == MODE_PROBE ? "native_probe" : "off");
    _report["stage"] = stage;
    _report["day_index"] = day;
    _report["country_count"] = static_cast<int64_t>(_countries.active.size());
    _report["cell_count"] = _cell_count;
    _report["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    _report["cursor_start"] = 0;
    _report["cursor_end"] = changed_cells + changed_countries;
    _report["changed_cells"] = changed_cells;
    _report["changed_countries"] = changed_countries;
    _report["command_preflight_ms"] = preflight_ms;
    _report["command_apply_ms"] = apply_ms;
    _report["aggregate_publish_ms"] = publish_ms;
    _report["native_ms"] = preflight_ms + apply_ms + publish_ms;
    _report["generation"] = static_cast<int64_t>(_generation);
    _report["state_hash"] = state_hash();
    _report["published_to_slot"] = published;
    _report["done"] = true;
    _report["country_day_barrier"] = false;
    _report["last_committed_day"] = _last_committed_day;
    int64_t oldest_due = day;
    for (const Command &command : _pending_commands)
        oldest_due = std::min(oldest_due, command.effective_day);
    _report["pending_latency_days"] = _pending_commands.empty()
        ? 0 : std::max<int64_t>(0, day - oldest_due);
    int64_t memory_bytes =
        static_cast<int64_t>(_countries.active.size() * sizeof(uint8_t) +
        _countries.generation.size() * sizeof(uint32_t) +
        _countries.territory_count.size() * sizeof(int32_t) +
        _countries.cash.size() * sizeof(int64_t) +
        _countries.state_version.size() * sizeof(uint64_t) +
        _cell_country_slot.size() * sizeof(int32_t) +
        _country_cell_offsets.size() * sizeof(int32_t) +
        _country_cells.size() * sizeof(int32_t) +
        _country_technologies.size() * sizeof(uint64_t) +
        _country_goods.size() * sizeof(int64_t));
    for (const std::string &value : _countries.stable_id) memory_bytes += value.capacity() + 1;
    for (const std::string &value : _countries.display_name) memory_bytes += value.capacity() + 1;
    for (const std::string &value : _good_ids) memory_bytes += value.capacity() + 1;
    for (const std::string &value : _technology_ids) memory_bytes += value.capacity() + 1;
    memory_bytes += static_cast<int64_t>(_is_water.capacity() * sizeof(uint8_t) +
        _starting_technologies.capacity() * sizeof(int32_t) +
        _pending_commands.size() * sizeof(Command) + _events.size() * sizeof(Event));
    for (const Command &command : _pending_commands)
        memory_bytes += command.stable_id.capacity() + command.display_name.capacity() + 2;
    // Account conservatively for unordered-map nodes/buckets. Exact allocator
    // overhead is implementation-specific; this estimate intentionally rounds up.
    memory_bytes += static_cast<int64_t>((_good_index.size() + _technology_index.size()) * 64 +
        (_good_index.bucket_count() + _technology_index.bucket_count()) * sizeof(void *));
    _report["memory_bytes"] = memory_bytes;
    if (!reason.empty()) {
        _report["fallback_reason"] = reason.c_str();
        _report["fail_stage"] = stage;
    }
}

Dictionary NativeCountryRuntime::report() const { return _report.duplicate(); }

Dictionary NativeCountryRuntime::reset(const String &reason) {
    _bootstrapped = false;
    _countries = {};
    _cell_country_slot.assign(static_cast<size_t>(std::max(0, _cell_count)), NEUTRAL_SLOT);
    _country_cell_offsets.clear();
    _country_cells.clear();
    _country_technologies.clear();
    _country_goods.clear();
    _pending_commands.clear();
    _events.clear();
    _command_batch = {};
    ++_generation;
    _report.clear();
    _report["configured"] = _configured;
    _report["bootstrapped"] = false;
    _report["reason"] = reason;
    Dictionary out;
    out["ok"] = true;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

Dictionary NativeCountryRuntime::cell_summary(int32_t cell) const {
    if (!_bootstrapped || cell < 0 || cell >= _cell_count) return {};
    Dictionary out;
    out["ok"] = true;
    out["cell"] = cell;
    const int32_t slot = _cell_country_slot[static_cast<size_t>(cell)];
    out["country_slot"] = slot;
    if (slot < 0) {
        out["owned"] = false;
        out["country_name"] = "无主地";
        out["country_handle"] = static_cast<int64_t>(0);
        return out;
    }
    int32_t nonzero_goods = 0;
    for (size_t good = 0; good < _good_ids.size(); ++good)
        if (_country_goods[static_cast<size_t>(slot) * _good_ids.size() + good] != 0) ++nonzero_goods;
    int32_t technologies = 0;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech)) ++technologies;
    out["owned"] = true;
    out["country_handle"] = static_cast<int64_t>(make_handle(slot));
    out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
    out["country_name"] = String::utf8(_countries.display_name[static_cast<size_t>(slot)].c_str());
    out["territory_count"] = _countries.territory_count[static_cast<size_t>(slot)];
    out["cash"] = _countries.cash[static_cast<size_t>(slot)];
    out["nonzero_good_count"] = nonzero_goods;
    out["technology_count"] = technologies;
    out["state_version"] = static_cast<int64_t>(_countries.state_version[static_cast<size_t>(slot)]);
    return out;
}

Dictionary NativeCountryRuntime::country_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedStringArray technology_ids;
    for (int32_t tech = 0; tech < static_cast<int32_t>(_technology_ids.size()); ++tech)
        if (has_technology(slot, tech)) technology_ids.push_back(_technology_ids[static_cast<size_t>(tech)].c_str());
    PackedInt32Array cells;
    if (slot + 1 < static_cast<int32_t>(_country_cell_offsets.size())) {
        const int32_t begin = _country_cell_offsets[static_cast<size_t>(slot)];
        const int32_t end = _country_cell_offsets[static_cast<size_t>(slot + 1)];
        cells.resize(end - begin);
        if (end > begin) std::memcpy(cells.ptrw(), _country_cells.data() + begin, static_cast<size_t>(end - begin) * sizeof(int32_t));
    }
    Dictionary out = cell_summary(cells.is_empty() ? -1 : cells[0]);
    if (out.is_empty()) {
        out["ok"] = true;
        out["country_handle"] = handle;
        out["country_id"] = _countries.stable_id[static_cast<size_t>(slot)].c_str();
        out["country_name"] = String::utf8(_countries.display_name[static_cast<size_t>(slot)].c_str());
    }
    out["technology_ids"] = technology_ids;
    out["territory_cells"] = cells;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

Dictionary NativeCountryRuntime::treasury_snapshot(int64_t handle) const {
    int32_t slot = -1;
    if (!validate_handle(static_cast<uint64_t>(handle), slot)) return fail("country_handle_invalid");
    PackedStringArray good_ids;
    PackedInt64Array quantities;
    for (size_t good = 0; good < _good_ids.size(); ++good) {
        const int64_t quantity = _country_goods[static_cast<size_t>(slot) * _good_ids.size() + good];
        if (quantity == 0) continue;
        good_ids.push_back(_good_ids[good].c_str());
        quantities.push_back(quantity);
    }
    Dictionary out;
    out["ok"] = true;
    out["country_handle"] = handle;
    out["cash"] = _countries.cash[static_cast<size_t>(slot)];
    out["good_ids"] = good_ids;
    out["quantities"] = quantities;
    return out;
}

PackedInt32Array NativeCountryRuntime::cell_country_snapshot() const {
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(_cell_country_slot.size()));
    if (!_cell_country_slot.empty()) std::memcpy(out.ptrw(), _cell_country_slot.data(), _cell_country_slot.size() * sizeof(int32_t));
    return out;
}

bool NativeCountryRuntime::has_technology(int32_t country_slot, int32_t technology_id) const {
    if (country_slot < 0 || country_slot >= static_cast<int32_t>(_countries.active.size()) ||
        technology_id < 0 || technology_id >= static_cast<int32_t>(_technology_ids.size())) return false;
    return (_country_technologies[static_cast<size_t>(country_slot) * _technology_words + technology_id / 64] &
            (1ULL << (technology_id % 64))) != 0;
}

int32_t NativeCountryRuntime::country_slot_for_cell(int32_t cell) const {
    return cell >= 0 && cell < _cell_count ? _cell_country_slot[static_cast<size_t>(cell)] : NEUTRAL_SLOT;
}

int64_t NativeCountryRuntime::country_handle_for_cell(int32_t cell) const {
    const int32_t slot = country_slot_for_cell(cell);
    return slot < 0 ? 0 : static_cast<int64_t>(make_handle(slot));
}

bool NativeCountryRuntime::valid_handle(int64_t handle) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(handle), slot);
}

int64_t NativeCountryRuntime::total_cash() const {
    int64_t total = 0;
    for (size_t i = 0; i < _countries.cash.size(); ++i) {
        if (_countries.active[i] == 0) continue;
        if (_countries.cash[i] > 0 && total > std::numeric_limits<int64_t>::max() - _countries.cash[i])
            return std::numeric_limits<int64_t>::max();
        total += _countries.cash[i];
    }
    return total;
}

int64_t NativeCountryRuntime::total_good(int32_t good_id) const {
    if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size())) return 0;
    int64_t total = 0;
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        if (_countries.active[slot] == 0) continue;
        const int64_t value = _country_goods[slot * _good_ids.size() + static_cast<size_t>(good_id)];
        if (value > 0 && total > std::numeric_limits<int64_t>::max() - value) return std::numeric_limits<int64_t>::max();
        total += value;
    }
    return total;
}

int64_t NativeCountryRuntime::transfer_cash_to_cohort(int64_t country_handle, int64_t requested) {
    int32_t slot = -1;
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t moved = std::min(requested, _countries.cash[static_cast<size_t>(slot)]);
    _countries.cash[static_cast<size_t>(slot)] -= moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

int64_t NativeCountryRuntime::transfer_cash_from_cohort(int64_t country_handle, int64_t offered) {
    int32_t slot = -1;
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t room = std::numeric_limits<int64_t>::max() - _countries.cash[static_cast<size_t>(slot)];
    const int64_t moved = std::min(offered, room);
    _countries.cash[static_cast<size_t>(slot)] += moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

int64_t NativeCountryRuntime::transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                                       int64_t requested) {
    int32_t slot = -1;
    if (requested <= 0 || good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    int64_t &stock = _country_goods[static_cast<size_t>(slot) * _good_ids.size() + static_cast<size_t>(good_id)];
    const int64_t moved = std::min(requested, stock);
    stock -= moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

int64_t NativeCountryRuntime::transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                                         int64_t offered) {
    int32_t slot = -1;
    if (offered <= 0 || good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    int64_t &stock = _country_goods[static_cast<size_t>(slot) * _good_ids.size() + static_cast<size_t>(good_id)];
    const int64_t moved = std::min(offered, std::numeric_limits<int64_t>::max() - stock);
    stock += moved;
    if (moved > 0) { ++_countries.state_version[static_cast<size_t>(slot)]; ++_generation; }
    return moved;
}

bool NativeCountryRuntime::copy_economy_snapshot(EconomySnapshot &out) const {
    if (!economy_available()) return false;
    out.cell_country_slot = _cell_country_slot;
    out.country_technologies = _country_technologies;
    out.country_count = static_cast<int32_t>(_countries.active.size());
    out.technology_words = _technology_words;
    out.generation = _generation;
    out.state_hash = compute_state_hash();
    return true;
}

uint64_t NativeCountryRuntime::catalog_hash() const {
    uint64_t hash = FNV_OFFSET;
    for (const std::string &id : _good_ids) hash_string(hash, id);
    for (const std::string &id : _technology_ids) hash_string(hash, id);
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
    }
    if (!_cell_country_slot.empty()) hash_bytes(hash, _cell_country_slot.data(), _cell_country_slot.size() * sizeof(int32_t));
    if (!_country_technologies.empty()) hash_bytes(hash, _country_technologies.data(), _country_technologies.size() * sizeof(uint64_t));
    if (!_country_goods.empty()) hash_bytes(hash, _country_goods.data(), _country_goods.size() * sizeof(int64_t));
    return hash;
}

int64_t NativeCountryRuntime::state_hash() const { return static_cast<int64_t>(compute_state_hash()); }

void NativeCountryRuntime::mark_slot_publication(bool published, double publish_ms,
                                                  const String &reason) {
    _report["published_to_slot"] = published;
    _report["slot_publish_ms"] = publish_ms;
    _report["aggregate_publish_ms"] =
        static_cast<double>(_report.get("aggregate_publish_ms", 0.0)) + publish_ms;
    _report["native_ms"] = static_cast<double>(_report.get("native_ms", 0.0)) + publish_ms;
    if (!reason.is_empty()) _report["publish_reason"] = reason;
    else _report.erase("publish_reason");
}

void NativeCountryRuntime::push_event(Event event) {
    event.event_id = static_cast<int64_t>(_next_event_id++);
    _events.push_back(std::move(event));
    while (_events.size() > 2048) _events.pop_front();
}

Dictionary NativeCountryRuntime::poll_events(int64_t after_event_id, int32_t limit) const {
    limit = std::clamp(limit, 1, 512);
    PackedInt64Array event_ids, days, handles;
    PackedInt32Array opcodes, cells, old_slots, new_slots, technologies;
    PackedStringArray stable_ids, display_names;
    for (const Event &event : _events) {
        if (event.event_id <= after_event_id || event_ids.size() >= limit) continue;
        event_ids.push_back(event.event_id);
        days.push_back(event.day);
        handles.push_back(static_cast<int64_t>(event.country_handle));
        opcodes.push_back(event.opcode);
        cells.push_back(event.cell);
        old_slots.push_back(event.old_country_slot);
        new_slots.push_back(event.new_country_slot);
        technologies.push_back(event.technology_id);
        stable_ids.push_back(event.stable_id.c_str());
        display_names.push_back(String::utf8(event.display_name.c_str()));
    }
    Dictionary out;
    out["ok"] = true;
    out["event_ids"] = event_ids;
    out["days"] = days;
    out["opcodes"] = opcodes;
    out["country_handles"] = handles;
    out["cells"] = cells;
    out["old_country_slots"] = old_slots;
    out["new_country_slots"] = new_slots;
    out["technology_ids"] = technologies;
    out["stable_ids"] = stable_ids;
    out["display_names"] = display_names;
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

bool NativeCountryRuntime::encode_save(std::vector<uint8_t> &out, std::string &error) const {
    if (!_bootstrapped) { error = "country_save_not_bootstrapped"; return false; }
    if (_command_batch.active) { error = "country_save_requires_idle_command_graph"; return false; }
    if (should_run(_last_committed_day)) { error = "country_save_requires_idle_command_graph"; return false; }
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
    append_le<int32_t>(out, static_cast<int32_t>(_technology_ids.size()));
    append_le<int32_t>(out, _technology_words);
    for (const std::string &id : _good_ids) append_string(out, id);
    for (const std::string &id : _technology_ids) append_string(out, id);
    for (size_t slot = 0; slot < _countries.active.size(); ++slot) {
        append_le<uint8_t>(out, _countries.active[slot]);
        append_le<uint32_t>(out, _countries.generation[slot]);
        append_string(out, _countries.stable_id[slot]);
        append_string(out, _countries.display_name[slot]);
        append_le<int32_t>(out, _countries.territory_count[slot]);
        append_le<int64_t>(out, _countries.cash[slot]);
        append_le<uint64_t>(out, _countries.state_version[slot]);
    }
    append_vector(out, _cell_country_slot);
    append_vector(out, _country_technologies);
    append_vector(out, _country_goods);
    append_le<uint64_t>(out, static_cast<uint64_t>(_pending_commands.size()));
    for (const Command &command : _pending_commands) {
        append_le<int32_t>(out, command.opcode);
        append_le<int64_t>(out, command.effective_day);
        append_le<int64_t>(out, command.sequence);
        append_le<uint64_t>(out, command.target_handle);
        append_le<int32_t>(out, command.cell);
        append_le<int32_t>(out, command.aux);
        append_string(out, command.stable_id);
        append_string(out, command.display_name);
        append_le<uint64_t>(out, command.submit_order);
    }
    append_le<uint32_t>(out, SAVE_END);
    return true;
}

bool NativeCountryRuntime::decode_save(const std::vector<uint8_t> &bytes, std::string &error) {
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, end = 0;
    uint64_t saved_catalog = 0, generation_value = 0, saved_submit_order = 0;
    int64_t committed_day = -1;
    int32_t cell_count = 0, country_count = 0, good_count_value = 0, tech_count = 0, tech_words = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, version)) { error = "country_save_truncated"; return false; }
    if (magic != SAVE_MAGIC) { error = "country_save_magic_invalid"; return false; }
    if (version != SCHEMA_VERSION) { error = "country_save_schema_unsupported"; return false; }
    if (!read_le(bytes, cursor, saved_catalog) || !read_le(bytes, cursor, generation_value) ||
        !read_le(bytes, cursor, committed_day) || !read_le(bytes, cursor, saved_submit_order) ||
        !read_le(bytes, cursor, cell_count) ||
        !read_le(bytes, cursor, country_count) || !read_le(bytes, cursor, good_count_value) ||
        !read_le(bytes, cursor, tech_count) || !read_le(bytes, cursor, tech_words)) {
        error = "country_save_header_truncated"; return false;
    }
    if (saved_catalog != catalog_hash() || cell_count != _cell_count || good_count_value != static_cast<int32_t>(_good_ids.size()) ||
        tech_count != static_cast<int32_t>(_technology_ids.size()) || tech_words != _technology_words ||
        country_count <= 0 || country_count > 1000000) { error = "country_save_catalog_or_shape_mismatch"; return false; }
    std::string id;
    for (const std::string &expected : _good_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "country_save_good_catalog_mismatch"; return false; }
    for (const std::string &expected : _technology_ids)
        if (!read_string(bytes, cursor, id) || id != expected) { error = "country_save_technology_catalog_mismatch"; return false; }

    CountryStore countries;
    countries.active.resize(country_count);
    countries.generation.resize(country_count);
    countries.stable_id.resize(country_count);
    countries.display_name.resize(country_count);
    countries.territory_count.resize(country_count);
    countries.cash.resize(country_count);
    countries.state_version.resize(country_count);
    std::unordered_set<std::string> stable_ids;
    for (int32_t slot = 0; slot < country_count; ++slot) {
        if (!read_le(bytes, cursor, countries.active[slot]) || !read_le(bytes, cursor, countries.generation[slot]) ||
            !read_string(bytes, cursor, countries.stable_id[slot]) || !read_string(bytes, cursor, countries.display_name[slot]) ||
            !read_le(bytes, cursor, countries.territory_count[slot]) || !read_le(bytes, cursor, countries.cash[slot]) ||
            !read_le(bytes, cursor, countries.state_version[slot])) { error = "country_save_country_record_truncated"; return false; }
        if (countries.active[slot] == 0 || countries.generation[slot] == 0 || countries.stable_id[slot].empty() ||
            countries.display_name[slot].empty() || countries.territory_count[slot] <= 0 || countries.cash[slot] < 0 ||
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
        return slot >= 0 && slot < country_count && countries.active[slot] != 0 &&
            countries.generation[slot] == handle_generation;
    };
    for (uint64_t i = 0; i < command_count; ++i) {
        Command command;
        if (!read_le(bytes, cursor, command.opcode) || !read_le(bytes, cursor, command.effective_day) ||
            !read_le(bytes, cursor, command.sequence) || !read_le(bytes, cursor, command.target_handle) ||
            !read_le(bytes, cursor, command.cell) || !read_le(bytes, cursor, command.aux) ||
            !read_string(bytes, cursor, command.stable_id) || !read_string(bytes, cursor, command.display_name) ||
            !read_le(bytes, cursor, command.submit_order)) { error = "country_save_command_truncated"; return false; }
        if (command.opcode < COMMAND_CREATE_COUNTRY ||
            command.opcode > COMMAND_GRANT_TECHNOLOGY || command.effective_day < 0 ||
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
        } else if (command.opcode == COMMAND_TRANSFER_TERRITORY) {
            if (command.cell < 0 || command.cell >= _cell_count ||
                _is_water[static_cast<size_t>(command.cell)] != 0 ||
                (command.target_handle != 0 && !saved_handle_valid(command.target_handle))) {
                error = "country_save_transfer_command_invalid"; return false;
            }
        } else if (!saved_handle_valid(command.target_handle) || command.aux < 0 ||
                   command.aux >= tech_count) {
            error = "country_save_technology_command_invalid"; return false;
        }
        commands.push_back(std::move(command));
        max_submit_order = std::max(max_submit_order, commands.back().submit_order);
    }
    if (!read_le(bytes, cursor, end) || end != SAVE_END || cursor != bytes.size()) { error = "country_save_end_invalid"; return false; }

    _countries = std::move(countries);
    _cell_country_slot = std::move(owners);
    _country_technologies = std::move(technologies);
    _country_goods = std::move(goods);
    _pending_commands = std::move(commands);
    _generation = generation_value;
    _last_committed_day = committed_day;
    _submit_order = std::max(saved_submit_order, max_submit_order);
    _bootstrapped = true;
    rebuild_cell_csr();
    publish_report("aggregate_publish", committed_day, 0, 0, 0, _cell_count, country_count, _mode == MODE_ACTIVE);
    return true;
}

Dictionary NativeCountryRuntime::begin_save(int32_t chunk_bytes) {
    if (_save_active) return fail("country_save_already_active");
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
    Dictionary out;
    out["ok"] = true;
    out["state_hash"] = state_hash();
    out["generation"] = static_cast<int64_t>(_generation);
    return out;
}

} // namespace pk
