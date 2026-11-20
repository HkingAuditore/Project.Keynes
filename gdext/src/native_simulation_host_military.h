#pragma once

#include "military_bridge.h"

#include <memory>
#include <string>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace pk {

class MilitaryCore;
struct MilitaryCatalog;
class ModifierRuntime;
class DCWorldExt;
class NativeCountryRuntime;
class NativeEconomyRuntime;
class NativeSimulationHost;
struct RuntimeCountryPodSnapshot;
struct RuntimeEnvironmentSnapshot;

struct MilitaryCommandBatch {
    struct Row {
        int64_t index = 0;
        int64_t effective_day = -1;
        MilitaryCommand command;
        std::string error;
        std::string command_name;
        int64_t caller_sequence = 0;
    };
    std::vector<Row> rows;
    int64_t day = -1;
    int64_t committed_at_admission = -1;
    int64_t frozen_at_admission = -1;
    int64_t sequence = 0;
};

// Military -> Country/Economy command rows, built by
// world_ext_military.cpp and submitted through the existing batches with
// effective day D+1. Declared here so the private helpers below can name them.
struct MilitaryCountryCommand {
    int32_t opcode = 0;
    int64_t effective_day = 0;
    int64_t sequence = 0;
    int64_t target_handle = 0;
    int32_t cell = -1;
    int32_t aux = -1;
    int32_t domain = -1;
    int64_t value = 0;
};

struct MilitaryEconomyCommand {
    int32_t opcode = 0;
    int64_t effective_day = 0;
    int64_t sequence = 0;
    int64_t target_handle = 0;
    int32_t i32_0 = 0;
    int32_t i32_1 = 0;
    int64_t i64_0 = 0;
    int64_t i64_1 = 0;
};

// The executor adapter composes the military core with the host’s peer ports.
// On a formal world, the executor is the sole writer after startup.
// The facade uses a published copy for inspection and rendering.
class NativeMilitaryRuntime {
public:
    struct Published {
        std::shared_ptr<const MilitaryCore> view;
        std::vector<uint8_t> archive;
        int64_t state_hash = 0;
        int64_t last_step_day = -1;
        int64_t executor_day = -1;
        int64_t sequence = 0;
        int64_t pending_intents = 0;
        int64_t revision = 0;
        int64_t event_cursor = 0;
        int64_t event_tick = -1;
        int64_t events_forwarded = 0;
        bool lane_supported = false;
        bool lane_pay_supported = false;
        std::vector<int64_t> lane_population;
        std::vector<int64_t> lane_funds;
        godot::Dictionary result;
    };

    NativeMilitaryRuntime();
    ~NativeMilitaryRuntime();

    MilitaryCore &core() noexcept { return *_core; }
    const MilitaryCore &core() const noexcept { return *_core; }
    std::vector<int32_t> vision_sources(int32_t country_slot) const;
    std::vector<int32_t> take_vision_trail(int32_t country_slot);
    void prepare_exploration(int32_t player_slot, const std::vector<uint8_t> &explored,
                             int64_t day, uint64_t revision);

    NativeEconomyRuntime *_economy_runtime = nullptr;
    NativeCountryRuntime *_country_runtime = nullptr;
    ModifierRuntime *_modifier_runtime = nullptr;
    NativeSimulationHost *_runtime_host = nullptr;
    const RuntimeCountryPodSnapshot *country_state = nullptr;
    int64_t _military_last_step_day = -1;
    int64_t _military_last_background_day = -1;
    int64_t _military_render_revision = 0;
    uint64_t _military_pod_request = 1;

    bool should_run(int64_t day) const;
    bool submit(MilitaryCommand command, std::string &error);
    bool stamp_commands(MilitaryCommandBatch &batch) const;
    void admit(MilitaryCommandBatch &batch);
    void resolve_training_units(const godot::Dictionary &source, MilitaryCommand &command) const;
    bool resolve_config_shares(const godot::Dictionary &source, MilitaryCommand &command,
                              std::string &error) const;
    const char *preflight_construction(const RuntimeCountryPodSnapshot &state,
        uint64_t country, int32_t cell, int32_t type, bool demolishing,
        int64_t day, int32_t &building, int32_t &slot) const;
    void commit_construction(int32_t cell, int32_t building, int32_t slot, int64_t day, int64_t ready_day);
    std::vector<MilitaryPlayerCommandRejection> take_player_rejections();
private:
    void queue_player_construction(MilitaryCommandBatch::Row &row);
public:
    bool submit_independence(uint64_t old_owner, uint64_t new_owner, int32_t cell, int64_t day);
    godot::Dictionary run_day(int64_t day);
    std::vector<uint8_t> encode() const;
    godot::Dictionary restore(const godot::PackedByteArray &bytes);
    void publish(godot::Dictionary report);
    std::shared_ptr<const Published> read() const;
    bool forward_events(int64_t day, DCWorldExt *legacy = nullptr);
    const char *prepare_day(const RuntimeEnvironmentSnapshot &environment);
    std::vector<uint8_t> capture_terrain() const;
    bool restore_terrain(const std::vector<uint8_t> &bytes, std::string &error);

    int64_t event_cursor = 0;
    int64_t event_tick = -1;
    int64_t events_forwarded = 0;
    godot::Dictionary last_result;
private:
    std::unique_ptr<MilitaryCore> _core;
    std::shared_ptr<const Published> _published;
public:
    // One submitted intent plus the identity needed to match its receipt on the
    // next military day.
    struct MilitaryPendingIntent {
        uint16_t kind = 0;
        // 0 none, 1 country, 2 economy, 3 bridge-deferred treasury cash spend
        // (SPEND_CASH, applied at the start of military day D+1).
        uint8_t authority = 0;
        // 0 dropped, 1 awaiting authority receipt, 2 resolved ok (emit next
        // fold), 3 resolved failed (emit next fold).
        uint8_t receipt_pending = 0;
        int32_t cell = -1;
        int32_t good = -1;
        uint64_t source_id = 0;
        uint64_t country_handle = 0;
        int64_t count = 0;
        int64_t amount = 0;
        int64_t sequence = 0;       // country/economy command sequence
        int64_t request_id = 0;     // country command request id (0 = none)
        int64_t effective_day = 0;
        // Economy matching identity: target cohort handle (0 for market ops)
        // and, for CHANGE_SIGNATURE, the destination signature id.
        int64_t target_handle = 0;
        int32_t target_signature = -1;
        int32_t opcode = 0;         // economy/country opcode submitted
        // Economy settlement fold state (not saved): epoch id of the
        // COMMAND_SETTLED event (0 = not settled yet) and the applied quantity
        // accumulated from the settlement / structural events.
        int64_t settled_epoch = 0;
        int64_t settled_value = 0;
    };
    // Economy trace cursor for EVENT_COMMAND_SETTLED / EVENT_STRUCTURAL_CHANGE
    // folding (world_ext_economy_military.cpp). Transient; on restore it
    // restarts from the current newest event id.
    int64_t _military_economy_event_cursor = -1;
    // Highest Economy epoch sample_day whose EPOCH_COMMITTED event was folded;
    // a pending Economy row due on or before it that never settled failed.
    int64_t _military_economy_seen_day = -1;
    // Earliest effective day of a command accepted by submit_military_commands
    // that has not been stepped yet; military_should_run is forced true for it
    // so queued commands always apply (-1 = none).
    int64_t _military_forced_run_day = -1;
    // Country command receipt cursor state (pimpl keeps country_core.h out of
    // this header).
    struct MilitaryReceiptCursor {
        int64_t after_request_id = 0;
    };
    // Digest scratch reused across days: sized once per terrain change so the
    // per-day capture does not allocate. Field layout mirrors the dense/sparse
    // lanes of pk::MilitaryWorldDigest.
    struct MilitaryDigestScratch {
        std::vector<int64_t> cell_population;
        std::vector<int64_t> cell_unemployed;
        std::vector<int64_t> cell_soldiers;
        std::vector<uint8_t> cell_has_merchant;
        std::vector<int32_t> market_cell;
        std::vector<int32_t> market_good;
        std::vector<int64_t> market_sellable;
        std::vector<int64_t> market_price;
        std::vector<int64_t> country_cash;
        std::vector<int64_t> country_annual_revenue;
        std::vector<uint64_t> country_unlock_bits;
        std::vector<int32_t> country_stat_q16;
        // State (kind 3) building group lanes, reused across days. Filled from
        // `military_read_state_buildings` only when that read was authoritative;
        // cleared otherwise so a busy ledger never looks like an empty one.
        std::vector<int32_t> state_cell;
        std::vector<int32_t> state_type_id;
        std::vector<int32_t> state_state_role;
        std::vector<int64_t> state_units;
    };
    // Monotone Country/Economy command sequences for military intents. Unique
    // per (day, kind) so both authorities can order them deterministically.
    int64_t                                   _military_sequence       = 0;
    // Country command receipts already folded into MilitaryIntentReceipt rows.
    std::unique_ptr<MilitaryReceiptCursor>    _military_receipts;
    // Military intent rows awaiting their receipt (effective day D+1).
    std::vector<MilitaryPendingIntent>        _military_pending_intents;
    // Scratch reused across days; sized once per terrain.
    MilitaryDigestScratch                     _military_digest_scratch;
    // Dense technology id each catalog unlock bit stands for, captured at
    // configure so the daily digest costs one has_technology() probe per bit.
    std::vector<int32_t>                      _military_unlock_tech_ids;
    void capture_military_digest(MilitaryWorldDigest &digest,
                                 MilitaryDigestScratch &scratch,
                                 const MilitaryCatalog &catalog,
                                 bool *economy_ready);
    // Opens a MilitaryCore country slot for every active Country handle (slot
    // order). Returns the number of active countries seen.
    int32_t ensure_military_country_slots();
    bool submit_military_country_commands(
        const std::vector<MilitaryCountryCommand> &commands,
        std::vector<MilitaryPendingIntent> &pending, std::string &error);
    bool submit_military_economy_commands(
        const std::vector<MilitaryEconomyCommand> &commands,
        std::vector<MilitaryPendingIntent> &pending, std::string &error);
    void collect_military_receipts(int64_t day, std::vector<MilitaryIntentReceipt> &out);
    // Folds Economy command settlements (trace events) into receipts for the
    // authority-2 pending rows (world_ext_economy_military.cpp).
    void collect_military_economy_receipts(int64_t day,
                                           std::vector<MilitaryIntentReceipt> &out);
    // Applies bridge-deferred SPEND_CASH rows (authority 3) due on `day`.
    void apply_military_deferred_cash(int64_t day);
    void translate_military_intent(const MilitaryIntent &intent, int64_t effective_day,
                                   const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryCountryCommand> &country,
                                   std::vector<MilitaryEconomyCommand> &economy,
                                   std::vector<MilitaryPendingIntent> &pending,
                                   int32_t &unsequenced);
    static MilitaryIntentReceipt military_receipt_from(const MilitaryPendingIntent &row,
                                                       bool ok, int64_t committed_count,
                                                       int64_t committed_amount);

};

} // namespace pk
