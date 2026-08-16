#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace pk {

class EffectRuntime;

class ModifierRuntime;

// Sole mutable authority for country identity, territory, country technology,
// and treasury state. Godot values are converted at coarse API boundaries;
// graph stages and economy reads use only POD/SoA storage.
class NativeCountryRuntime {
public:
    static constexpr int32_t SCHEMA_VERSION = 11;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int32_t NEUTRAL_SLOT = -1;
    static constexpr int8_t TAX_RATE_INHERIT = 127;

    enum TaxKind : int32_t {
        TAX_INCOME = 0,
        TAX_CONSUMPTION = 1,
        TAX_BUSINESS = 2,
        TAX_IMPORT = 3,
        TAX_EXPORT = 4,
        TAX_KIND_COUNT = 5,
    };

    enum CommandOpcode : int32_t {
        COMMAND_CREATE_COUNTRY = 1,
        COMMAND_RENAME_COUNTRY = 2,
        COMMAND_TRANSFER_TERRITORY = 3,
        COMMAND_GRANT_TECHNOLOGY = 4,
        COMMAND_SET_RESEARCH_WEIGHTS = 5,
        COMMAND_ENQUEUE_RESEARCH = 6,
        COMMAND_REMOVE_RESEARCH = 7,
        COMMAND_MOVE_RESEARCH = 8,
        COMMAND_SET_RESEARCH_BUDGET = 9,
        COMMAND_REVEAL_ALL_TECHNOLOGIES = 10,
        COMMAND_SET_TAX_DEFAULT = 11,
        COMMAND_SET_TAX_OVERRIDE = 12,
        COMMAND_CLEAR_TAX_OVERRIDE = 13,
        // Internal/domain command: static map/event evidence becomes
        // country-owned research knowledge at the country command boundary.
        COMMAND_DISCOVER_COUNTRY_SIGNAL = 14,
        COMMAND_SET_CELL_TAX_DEFAULT = 15,
        COMMAND_CLEAR_CELL_TAX_DEFAULT = 16,
        COMMAND_SET_CELL_TAX_OVERRIDE = 17,
        COMMAND_CLEAR_CELL_TAX_OVERRIDE = 18,
        COMMAND_CLEAR_CELL_TAX_POLICY = 19,
        // Effect-only territorial acquisition used by family expeditions.
        // Unlike TRANSFER_TERRITORY this is compare-and-set: the command is
        // rejected unless the committed/staged owner is still neutral.
        COMMAND_CLAIM_UNOWNED_TERRITORY = 20,
    };

    enum RuntimeMode : int32_t { MODE_OFF = 0, MODE_PROBE = 1, MODE_ACTIVE = 2 };

    // EffectRuntime's country adapter uses this POD ABI.  `payload` is
    // precompiled by the Effect catalog: [cell|aux], [domain|position], four
    // packed int16 research weights, and tax kind/item/rate respectively.
    struct EffectCommand {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value = 0;
        std::array<int64_t, 4> payload{};
        uint64_t idempotency_key = 0;
        const char *stable_id = nullptr;
        const char *display_name = nullptr;
    };

    // Canonical sparse cell policy payload. Policy id 0 is implicit and means
    // complete inheritance; ids are transient runtime implementation details.
    struct CellTaxOverride {
        int32_t kind = -1;
        int32_t item = -1;
        int8_t rate = TAX_RATE_INHERIT;

        bool operator==(const CellTaxOverride &other) const {
            return kind == other.kind && item == other.item && rate == other.rate;
        }
    };

    struct CellTaxPolicy {
        std::array<int8_t, TAX_KIND_COUNT> defaults{
            TAX_RATE_INHERIT, TAX_RATE_INHERIT, TAX_RATE_INHERIT,
            TAX_RATE_INHERIT, TAX_RATE_INHERIT};
        std::vector<CellTaxOverride> overrides;

        bool empty() const {
            return std::all_of(defaults.begin(), defaults.end(),
                               [](int8_t rate) { return rate == TAX_RATE_INHERIT; }) &&
                   overrides.empty();
        }
        bool operator==(const CellTaxPolicy &other) const {
            return defaults == other.defaults && overrides == other.overrides;
        }
    };

    struct EconomySnapshot {
        std::vector<int32_t> cell_country_slot;
        std::vector<uint64_t> country_handles;
        std::vector<uint64_t> country_technologies;
        std::vector<int8_t> income_tax_rates;
        std::vector<int8_t> consumption_tax_rates;
        std::vector<int8_t> business_tax_rates;
        std::vector<int8_t> import_tax_rates;
        std::vector<int8_t> export_tax_rates;
        std::vector<uint32_t> cell_tax_policy_ids;
        std::vector<CellTaxPolicy> cell_tax_policies;
        int32_t country_count = 0;
        int32_t technology_words = 0;
        int32_t profession_count = 0;
        int32_t good_count = 0;
        int32_t building_type_count = 0;
        uint64_t tax_policy_version = 0;
        uint64_t generation = 0;
        uint64_t state_hash = 0;
    };

    // Minimal cross-section authority for an era reward. The complete frozen
    // alternatives remain in PKEF; PKCN stores only this reference/state so a
    // restore can reject orphaned or contradictory offers.
    struct EraRewardReference {
        int64_t plan_id = 0;
        int64_t offer_generation = 0;
        int32_t milestone_technology = -1;
        int32_t status = 0;
    };

    godot::Dictionary configure(const godot::Dictionary &catalog,
                                const godot::Dictionary &profile,
                                int32_t cell_count, int64_t seed);
    godot::Dictionary bootstrap(const godot::Dictionary &packet,
                                const godot::PackedByteArray &is_water);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
    bool submit_effect_commands_pod(const EffectCommand *commands, size_t count,
                                    std::vector<int64_t> &request_ids,
                                    std::string &error);
    bool effect_command_result_pod(int64_t request_id, bool &complete,
                                   bool &ok, std::string &reason) const;
    bool has_pending_effect_commands() const;
    bool should_run(int64_t day_index) const;
    godot::Dictionary run_slice(const godot::Dictionary &ctx);
    godot::Dictionary report() const;
    godot::Dictionary reset(const godot::String &reason);

    godot::Dictionary cell_summary(int32_t cell) const;
    godot::Dictionary country_snapshot(int64_t handle) const;
    godot::Dictionary treasury_snapshot(int64_t handle) const;
    godot::Dictionary research_snapshot(int64_t handle) const;
    godot::Dictionary research_signal_snapshot(int64_t handle) const;
    godot::Dictionary tax_policy_snapshot(int64_t handle) const;
    godot::Dictionary cell_tax_policy_snapshot(int32_t cell) const;
    godot::PackedInt32Array cell_country_snapshot() const;
    int64_t state_hash() const;
    int64_t state_hash_v3_compat() const;
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
    // Native peer runtimes may read this compact fact bitset at their own
    // scheduled boundary.  Research evidence remains Country authority.
    bool has_research_signal(int32_t country_slot, int32_t signal_id) const;
    int32_t research_signal_evidence_count(int32_t country_slot,
                                           int32_t signal_id) const;
    int32_t country_slot_for_cell(int32_t cell) const;
    int64_t country_handle_for_cell(int32_t cell) const;
    bool valid_handle(int64_t handle) const;
    int64_t total_cash() const;
    int64_t cash_for_slot(int32_t country_slot) const;
    int64_t cash_for_handle(int64_t country_handle) const;
    int64_t total_good(int32_t good_id) const;
    // Cumulative research-point goods consumed by the country runtime. The
    // economy uses the value at an epoch boundary to account for research
    // that runs while the market cycle is frozen.
    int64_t research_consumed_total() const;
    int64_t good_for_handle(int64_t country_handle, int32_t good_id) const;
    bool spend_treasury_assets(int64_t country_handle,
                               const int32_t *good_ids,
                               const int64_t *quantities,
                               size_t good_count,
                               int64_t cash);
    int64_t transfer_cash_to_cohort(int64_t country_handle, int64_t requested);
    int64_t transfer_cash_from_cohort(int64_t country_handle, int64_t offered);
    int64_t reserve_fiscal_cash(int64_t country_handle, int64_t requested);
    int64_t return_fiscal_cash(int64_t country_handle, int64_t offered);
    int64_t collect_fiscal_cash(int64_t country_handle, int64_t offered);
    int64_t transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                    int64_t requested);
    int64_t transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                      int64_t offered);
    bool research_procurement_policy(int32_t country_slot, bool &enabled,
                                     int64_t &cash_budget, int64_t &remaining_points) const;
    bool purchase_research_points(int32_t country_slot, int64_t quantity,
                                  int64_t total_cost);
    int32_t technology_points_good_id() const { return _technology_points_good_id; }
    bool economy_available() const { return _configured && _bootstrapped && _mode != MODE_OFF; }
    uint64_t generation() const { return _generation; }
    int32_t good_count() const { return static_cast<int32_t>(_good_ids.size()); }
    int32_t technology_count() const { return static_cast<int32_t>(_technology_ids.size()); }
    int64_t world_seed() const { return _seed; }
    void set_era_reward_reference_pod(int64_t plan_id,
                                      int64_t offer_generation,
                                      int32_t milestone_technology,
                                      int32_t status);
    EraRewardReference era_reward_reference_pod() const {
        return _era_reward_reference;
    }
    void attach_modifier_runtime(ModifierRuntime *runtime) { _modifier_runtime = runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) {
        _effect_runtime = runtime;
        _effect_runtime_enabled = runtime != nullptr;
    }
    void set_effect_runtime_enabled(bool enabled) { _effect_runtime_enabled = enabled; }

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
        int32_t domain = -1;
        int32_t position = -1;
        int32_t weights_bp[4] = {0, 0, 0, 0};
        int32_t tax_kind = -1;
        int32_t tax_item = -1;
        int32_t tax_rate_percent = 0;
        int64_t value = 0;
        std::string stable_id;
        std::string display_name;
        uint64_t submit_order = 0;
        int64_t effect_request_id = 0;
        uint64_t effect_idempotency_key = 0;
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
        int32_t signal_id = -1;
        int32_t signal_source_kind = 0;
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

    struct EffectCommandResult {
        uint8_t complete = 0;
        uint8_t ok = 0;
        std::string reason;
    };

    struct SignalEvidence {
        int32_t signal = -1;
        int32_t count = 0;
        int64_t first_day = -1;
        int64_t last_day = -1;
        int32_t first_cell = -1;
    };

    struct CommandBatchState {
        bool active = false;
        int64_t day = -1;
        size_t cursor = 0;
        double preflight_ms = 0.0;
        CountryStore countries;
        std::vector<uint64_t> technologies;
        std::vector<int64_t> goods;
        std::vector<uint64_t> discovered;
        std::vector<uint64_t> pending;
        std::vector<std::vector<std::pair<int32_t, int64_t>>> progress;
        std::vector<int32_t> research_queues;
        std::vector<uint8_t> research_queue_lengths;
        std::vector<int32_t> research_weights_bp;
        std::vector<uint8_t> research_auto_purchase;
        std::vector<int64_t> research_daily_budgets;
        std::vector<int64_t> research_deferred_points;
        std::vector<uint64_t> signals;
        std::vector<std::vector<uint64_t>> signal_cells;
        std::vector<std::vector<SignalEvidence>> signal_evidence;
        bool stage_technologies = false;
        bool stage_goods = false;
        bool stage_research = false;
        bool stage_signals = false;
        bool stage_tax = false;
        bool stage_cell_tax = false;
        std::vector<int8_t> tax_defaults;
        std::vector<int8_t> income_tax_overrides;
        std::vector<int8_t> consumption_tax_overrides;
        std::vector<int8_t> business_tax_overrides;
        std::vector<int8_t> import_tax_overrides;
        std::vector<int8_t> export_tax_overrides;
        std::unordered_map<int32_t, CellTaxPolicy> cell_tax_updates;
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
    int32_t tax_item_count(int32_t kind) const;
    const std::vector<int8_t> *tax_override_vector(int32_t kind) const;
    std::vector<int8_t> *tax_override_vector(int32_t kind);
    static int8_t resolved_tax_rate(const std::vector<int8_t> &defaults,
                                    const std::vector<int8_t> &overrides,
                                    int32_t country_slot, int32_t kind,
                                    int32_t item, int32_t item_count);
    static uint64_t cell_tax_policy_hash(const CellTaxPolicy &policy);
    uint32_t intern_cell_tax_policy(const CellTaxPolicy &policy);
    void release_cell_tax_policy(uint32_t policy_id);
    void rebuild_cell_tax_policy_intern();
    const CellTaxPolicy &cell_tax_policy(uint32_t policy_id) const;
    const std::vector<std::string> &tax_item_ids(int32_t kind) const;
    int32_t tax_item_index(int32_t kind, const std::string &stable_id) const;
    void rebuild_cell_csr();
    void publish_report(const char *stage, int64_t day, double preflight_ms,
                        double apply_ms, double publish_ms, int32_t changed_cells,
                        int32_t changed_countries, bool published, const std::string &reason = {});
    void push_event(Event event);
    uint64_t catalog_hash() const;
    uint64_t catalog_hash_v3() const;
    uint64_t compute_state_hash() const;
    bool encode_save(std::vector<uint8_t> &out, std::string &error) const;
    bool decode_save(const std::vector<uint8_t> &bytes, std::string &error);
    void initialize_country_research(int32_t slot);
    void refresh_discovery(int32_t slot);
    bool prerequisites_met(int32_t slot, int32_t technology) const;
    bool prerequisites_met(const std::vector<uint64_t> &completed, int32_t slot,
                           int32_t technology) const;
    bool era_entry_met(const std::vector<uint64_t> &completed, int32_t slot,
                       int32_t technology) const;
    bool research_condition_met(int32_t slot, int32_t technology) const;
    bool research_condition_met(const std::vector<uint64_t> &completed,
                                const std::vector<uint64_t> &signals,
                                const std::vector<std::vector<SignalEvidence>> &evidence,
                                int32_t slot, int32_t technology) const;
    bool reveal_condition_met(int32_t slot, int32_t technology) const;
    void refresh_discovery_for_technology(int32_t slot, int32_t technology);
    void refresh_discovery_for_signal(int32_t slot, int32_t signal);
    bool signal_present(const std::vector<uint64_t> &signals, int32_t slot,
                        int32_t signal) const;
    int32_t signal_count(int32_t slot, int32_t signal) const;
    int32_t signal_count(const std::vector<std::vector<SignalEvidence>> &evidence,
                         int32_t slot, int32_t signal) const;
    static SignalEvidence *find_signal_evidence(std::vector<SignalEvidence> &entries,
                                                int32_t signal);
    static const SignalEvidence *find_signal_evidence(
        const std::vector<SignalEvidence> &entries, int32_t signal);
    int64_t progress_for(int32_t slot, int32_t technology) const;
    void set_progress(int32_t slot, int32_t technology, int64_t value);
    int32_t run_research_day(int64_t day_index);

    bool _configured = false;
    bool _bootstrapped = false;
    RuntimeMode _mode = MODE_ACTIVE;
    int32_t _cell_count = 0;
    int64_t _seed = 0;
    int32_t _technology_words = 0;
    int32_t _research_signal_words = 0;
    int32_t _technology_points_good_id = -1;
    uint64_t _technology_catalog_identity_hash = 0;
    uint64_t _technology_content_binding_hash = 0;
    uint64_t _technology_trigger_definition_hash = 0;
    ModifierRuntime *_modifier_runtime = nullptr;
    EffectRuntime *_effect_runtime = nullptr;
    bool _effect_runtime_enabled = false;
    int32_t _starting_country_slot = -1;
    uint64_t _generation = 0;
    uint64_t _submit_order = 0;
    uint64_t _next_event_id = 1;
    int64_t _last_committed_day = -1;
    int32_t _max_commands_per_slice = 65536;

    std::vector<std::string> _good_ids;
    std::vector<std::string> _profession_ids;
    std::vector<std::string> _building_type_ids;
    std::vector<std::string> _technology_ids;
    std::vector<std::string> _technology_era_reward_pool_ids;
    std::vector<std::string> _research_signal_ids;
    std::unordered_map<std::string, int32_t> _good_index;
    std::unordered_map<std::string, int32_t> _technology_index;
    std::vector<int32_t> _starting_technologies;
    std::vector<int32_t> _technology_domains;
    std::vector<int64_t> _technology_costs;
    std::vector<int32_t> _technology_prerequisite_offsets;
    std::vector<int32_t> _technology_prerequisites;
    std::vector<int32_t> _technology_milestone_offsets;
    std::vector<int32_t> _technology_milestone_candidates;
    std::vector<int32_t> _technology_milestone_required_counts;
    // Dense per-technology era gate. -1 denotes the first era. This is kept
    // separate from the authored prerequisite CSR so the graph contains only
    // real knowledge dependencies.
    std::vector<int32_t> _technology_entry_milestone_indices;
    std::vector<int32_t> _technology_flags;
    std::vector<std::string> _technology_modifier_definition_keys;
    std::vector<uint8_t> _research_signal_requires_provenance;
    std::vector<int32_t> _technology_research_condition_offsets;
    std::vector<int32_t> _technology_research_condition_ops;
    std::vector<int32_t> _technology_research_condition_refs;
    std::vector<int64_t> _technology_research_condition_values;
    std::vector<int32_t> _technology_reveal_condition_offsets;
    std::vector<int32_t> _technology_reveal_condition_ops;
    std::vector<int32_t> _technology_reveal_condition_refs;
    std::vector<int64_t> _technology_reveal_condition_values;
    std::vector<int32_t> _technology_reveal_signal_offsets;
    std::vector<int32_t> _technology_reveal_signal_technologies;
    std::vector<uint8_t> _is_water;

    CountryStore _countries;
    std::vector<int32_t> _cell_country_slot;
    std::vector<int32_t> _country_cell_offsets;
    std::vector<int32_t> _country_cells;
    std::vector<uint64_t> _country_technologies;
    std::vector<int64_t> _country_goods;
    std::vector<uint64_t> _country_discovered;
    std::vector<uint64_t> _country_pending_technologies;
    std::vector<uint64_t> _country_research_signals;
    std::vector<std::vector<uint64_t>> _country_research_signal_cells;
    std::vector<std::vector<SignalEvidence>> _country_research_signal_evidence;
    std::vector<std::vector<std::pair<int32_t, int64_t>>> _country_research_progress;
    std::vector<int32_t> _country_research_queues;
    std::vector<uint8_t> _country_research_queue_lengths;
    std::vector<int32_t> _country_research_weights_bp;
    std::vector<uint8_t> _country_research_auto_purchase;
    std::vector<int64_t> _country_research_daily_budgets;
    std::vector<int64_t> _country_research_deferred_points;
    std::vector<int64_t> _country_research_purchased_total;
    std::vector<int64_t> _country_research_consumed_total;
    std::vector<int64_t> _country_research_progress_total;
    std::vector<int64_t> _country_research_completed_total;
    std::vector<int8_t> _country_tax_defaults;
    std::vector<int8_t> _country_income_tax_overrides;
    std::vector<int8_t> _country_consumption_tax_overrides;
    std::vector<int8_t> _country_business_tax_overrides;
    std::vector<int8_t> _country_import_tax_overrides;
    std::vector<int8_t> _country_export_tax_overrides;
    std::vector<uint32_t> _cell_tax_policy_ids;
    std::vector<CellTaxPolicy> _cell_tax_policies;
    std::vector<uint32_t> _cell_tax_policy_refcounts;
    std::vector<uint32_t> _cell_tax_policy_free_ids;
    std::unordered_map<uint64_t, std::vector<uint32_t>> _cell_tax_policy_intern;
    uint64_t _tax_policy_version = 0;
    int64_t _last_research_day = -1;
    std::vector<Command> _pending_commands;
    std::unordered_map<int64_t, EffectCommandResult> _effect_command_results;
    std::unordered_map<uint64_t, int64_t> _effect_command_idempotency;
    int64_t _next_effect_request_id = 1;
    EraRewardReference _era_reward_reference;
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
