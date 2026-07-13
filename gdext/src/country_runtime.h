#pragma once

#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace pk {

// Sole mutable authority for country identity, territory, country technology,
// and treasury state. Godot values are converted at coarse API boundaries;
// graph stages and economy reads use only POD/SoA storage.
class NativeCountryRuntime {
public:
    static constexpr int32_t SCHEMA_VERSION = 1;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int32_t NEUTRAL_SLOT = -1;

    enum CommandOpcode : int32_t {
        COMMAND_CREATE_COUNTRY = 1,
        COMMAND_RENAME_COUNTRY = 2,
        COMMAND_TRANSFER_TERRITORY = 3,
        COMMAND_GRANT_TECHNOLOGY = 4,
    };

    enum RuntimeMode : int32_t { MODE_OFF = 0, MODE_PROBE = 1, MODE_ACTIVE = 2 };

    struct EconomySnapshot {
        std::vector<int32_t> cell_country_slot;
        std::vector<uint64_t> country_technologies;
        int32_t country_count = 0;
        int32_t technology_words = 0;
        uint64_t generation = 0;
        uint64_t state_hash = 0;
    };

    godot::Dictionary configure(const godot::Dictionary &catalog,
                                const godot::Dictionary &profile,
                                int32_t cell_count, int64_t seed);
    godot::Dictionary bootstrap(const godot::Dictionary &packet,
                                const godot::PackedByteArray &is_water);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
    bool should_run(int64_t day_index) const;
    godot::Dictionary run_slice(const godot::Dictionary &ctx);
    godot::Dictionary report() const;
    godot::Dictionary reset(const godot::String &reason);

    godot::Dictionary cell_summary(int32_t cell) const;
    godot::Dictionary country_snapshot(int64_t handle) const;
    godot::Dictionary treasury_snapshot(int64_t handle) const;
    godot::PackedInt32Array cell_country_snapshot() const;
    int64_t state_hash() const;
    void mark_slot_publication(bool published, double publish_ms,
                               const godot::String &reason = {});

    godot::Dictionary begin_save(int32_t chunk_bytes);
    godot::PackedByteArray read_save_chunk(int32_t max_bytes);
    godot::Dictionary end_save();
    godot::Dictionary begin_restore();
    godot::Dictionary feed_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_restore();

    godot::Dictionary poll_events(int64_t after_event_id, int32_t limit) const;

    // Narrow native economy bridge. These methods never allocate and never
    // resolve strings. Frozen cycles use copy_economy_snapshot(); direct
    // transfers validate generation-bearing handles.
    bool copy_economy_snapshot(EconomySnapshot &out) const;
    bool has_technology(int32_t country_slot, int32_t technology_id) const;
    int32_t country_slot_for_cell(int32_t cell) const;
    int64_t country_handle_for_cell(int32_t cell) const;
    bool valid_handle(int64_t handle) const;
    int64_t total_cash() const;
    int64_t total_good(int32_t good_id) const;
    int64_t transfer_cash_to_cohort(int64_t country_handle, int64_t requested);
    int64_t transfer_cash_from_cohort(int64_t country_handle, int64_t offered);
    int64_t transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                    int64_t requested);
    int64_t transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                      int64_t offered);
    bool economy_available() const { return _configured && _bootstrapped && _mode != MODE_OFF; }
    uint64_t generation() const { return _generation; }
    int32_t good_count() const { return static_cast<int32_t>(_good_ids.size()); }
    int32_t technology_count() const { return static_cast<int32_t>(_technology_ids.size()); }

private:
    struct CountryStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<std::string> stable_id;
        std::vector<std::string> display_name;
        std::vector<int32_t> territory_count;
        std::vector<int64_t> cash;
        std::vector<uint64_t> state_version;
    };

    struct Command {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        int32_t cell = -1;
        int32_t aux = -1;
        std::string stable_id;
        std::string display_name;
        uint64_t submit_order = 0;
    };

    struct Event {
        int64_t event_id = 0;
        int64_t day = 0;
        int32_t opcode = 0;
        uint64_t country_handle = 0;
        int32_t cell = -1;
        int32_t old_country_slot = -1;
        int32_t new_country_slot = -1;
        int32_t technology_id = -1;
        std::string stable_id;
        std::string display_name;
    };

    struct SparseCellDelta {
        std::vector<int32_t> keys;
        std::vector<int32_t> values;
        size_t mask = 0;
        size_t count = 0;

        void reserve(size_t expected) {
            size_t capacity = 8;
            while (capacity < expected * 2 + 1) capacity <<= 1U;
            keys.assign(capacity, -1);
            values.assign(capacity, NEUTRAL_SLOT);
            mask = capacity - 1;
            count = 0;
        }
        bool get(int32_t cell, int32_t &value) const {
            if (keys.empty()) return false;
            size_t cursor = (static_cast<uint32_t>(cell) * 2654435761U) & mask;
            while (true) {
                if (keys[cursor] == -1) return false;
                if (keys[cursor] == cell) {
                    value = values[cursor];
                    return true;
                }
                cursor = (cursor + 1) & mask;
            }
        }
        bool set(int32_t cell, int32_t value) {
            size_t cursor = (static_cast<uint32_t>(cell) * 2654435761U) & mask;
            while (keys[cursor] != -1 && keys[cursor] != cell)
                cursor = (cursor + 1) & mask;
            const bool inserted = keys[cursor] == -1;
            if (inserted) { keys[cursor] = cell; ++count; }
            values[cursor] = value;
            return inserted;
        }
        size_t size() const { return count; }
        bool empty() const { return count == 0; }
    };

    struct CommandBatchState {
        bool active = false;
        int64_t day = -1;
        size_t cursor = 0;
        double preflight_ms = 0.0;
        CountryStore countries;
        std::vector<uint64_t> technologies;
        std::vector<int64_t> goods;
        bool stage_technologies = false;
        bool stage_goods = false;
        SparseCellDelta cell_delta;
        std::vector<int32_t> cell_delta_order;
        std::vector<int32_t> direct_cell_owners;
        bool direct_unique_territory = false;
        std::vector<Event> events;
        std::vector<Command> commands;
        std::vector<uint8_t> changed_countries;
    };

    bool validate_handle(uint64_t handle, int32_t &slot) const;
    uint64_t make_handle(int32_t slot) const;
    int32_t append_country(const std::string &stable_id,
                           const std::string &display_name, int64_t cash);
    void rebuild_cell_csr();
    void publish_report(const char *stage, int64_t day, double preflight_ms,
                        double apply_ms, double publish_ms, int32_t changed_cells,
                        int32_t changed_countries, bool published, const std::string &reason = {});
    void push_event(Event event);
    uint64_t catalog_hash() const;
    uint64_t compute_state_hash() const;
    bool encode_save(std::vector<uint8_t> &out, std::string &error) const;
    bool decode_save(const std::vector<uint8_t> &bytes, std::string &error);

    bool _configured = false;
    bool _bootstrapped = false;
    RuntimeMode _mode = MODE_ACTIVE;
    int32_t _cell_count = 0;
    int64_t _seed = 0;
    int32_t _technology_words = 0;
    int32_t _starting_country_slot = -1;
    uint64_t _generation = 0;
    uint64_t _submit_order = 0;
    uint64_t _next_event_id = 1;
    int64_t _last_committed_day = -1;
    int32_t _max_commands_per_slice = 65536;

    std::vector<std::string> _good_ids;
    std::vector<std::string> _technology_ids;
    std::unordered_map<std::string, int32_t> _good_index;
    std::unordered_map<std::string, int32_t> _technology_index;
    std::vector<int32_t> _starting_technologies;
    std::vector<uint8_t> _is_water;

    CountryStore _countries;
    std::vector<int32_t> _cell_country_slot;
    std::vector<int32_t> _country_cell_offsets;
    std::vector<int32_t> _country_cells;
    std::vector<uint64_t> _country_technologies;
    std::vector<int64_t> _country_goods;
    std::vector<Command> _pending_commands;
    std::deque<Event> _events;
    CommandBatchState _command_batch;
    godot::Dictionary _report;

    std::vector<uint8_t> _save_bytes;
    size_t _save_cursor = 0;
    int32_t _save_chunk_bytes = 4 * 1024 * 1024;
    bool _save_active = false;
    std::vector<uint8_t> _restore_bytes;
    bool _restore_active = false;
};

} // namespace pk
