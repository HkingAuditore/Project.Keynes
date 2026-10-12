#pragma once

// CountryAiRuntime owns Country AI memory and the plan/commit staging around
// the Country authority day. It never mutates Country or Economy state itself:
// it only emits typed Country commands (producer COUNTRY_AI_PRODUCER_ID),
// colonization intents for Economy, and frozen founding preferences.
//
// Threading: every public method takes `_mutex`. The worker path calls
// plan/reject/commit from the simulation thread; the main thread calls
// configure, mode, diagnostics and save/restore at safe boundaries.

#include "country_ai_core.h"

#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace pk {

struct CountryAiCommitResult {
    bool committed = false;
    std::vector<CountryAiColonizationIntent> colonization;
    bool family_preferences_changed = false;
    std::vector<CountryAiFamilyPreferenceRow> family_preferences;
};

struct CountryAiReport {
    bool configured = false;
    // False until the excluded (player) handles were set or restored; an
    // unarmed runtime never plans, so a missing player handle cannot hand
    // the player country to the AI.
    bool armed = false;
    CountryAiMode mode = CountryAiMode::OFF;
    uint64_t catalog_hash = 0;
    uint64_t country_catalog_hash = 0;
    int64_t committed_day = -1;
    uint32_t controlled = 0;
    uint32_t excluded = 0;
    uint64_t plans = 0;
    uint64_t plan_days_due = 0;
    uint64_t countries_thought = 0;
    uint64_t commands_emitted = 0;
    uint64_t commands_rejected = 0;
    uint64_t retries = 0;
    uint64_t colonization_intents = 0;
    uint64_t decisions_total = 0;
    uint64_t records_total = 0;
    uint64_t records_dropped = 0;
    uint64_t restores = 0;
    bool restored_catalog_mismatch = false;
    double plan_ms_last = 0.0;
    double plan_ms_max = 0.0;
    double plan_ms_total = 0.0;
    uint64_t state_hash = 0;
    uint64_t command_hash = 0;
};

class CountryAiRuntime {
public:
    static constexpr size_t DECISION_RING_CAPACITY = 2048;
    static constexpr size_t RECORD_RING_CAPACITY = 16384;

    bool configure(const CountryAiCatalog &catalog, std::string &error);
    void set_mode(CountryAiMode mode);
    CountryAiMode mode() const;
    bool active() const;
    void set_excluded_handles(std::vector<uint64_t> handles);
    std::vector<uint64_t> excluded_handles() const;
    void set_topology(std::vector<int32_t> neighbors, std::vector<int32_t> cell_value_q16);

    // Cheap pre-check so non-due days never copy Country state.
    bool due(int64_t day) const;
    // Recomputes `day` from committed memory and stages the result. Returns
    // the commands to queue (empty in PROBE mode).
    bool plan(int64_t day, const RuntimeCountryPodSnapshot &state,
              const RuntimeCountryPodCatalog &catalog,
              const CountryAiEconomyDigest *economy,
              std::vector<CountryAiCommand> &commands);
    // All staged commands of `day` were rejected by Country plan_day.
    void reject_staged(int64_t day, const char *reason);
    CountryAiCommitResult commit(int64_t day);
    void abort(int64_t day);

    static RuntimeCountryCommand to_runtime_command(const CountryAiCommand &command,
                                                    int64_t day, uint32_t index);

    CountryAiReport report() const;
    std::vector<CountryAiDecision> decisions_after(uint64_t after_id, size_t limit) const;
    std::vector<CountryAiRecordRow> drain_records(size_t limit);
    std::vector<CountryAiMemory> memory() const;
    std::vector<CountryAiFamilyPreferenceRow> family_preferences() const;
    const CountryAiCatalog *catalog_unlocked() const { return &_catalog; }
    uint64_t state_hash() const;

    std::vector<uint8_t> encode() const;
    bool restore(const uint8_t *data, size_t size, std::string &error);

private:
    std::vector<CountryAiFamilyPreferenceRow> family_preferences_locked(
        const std::vector<CountryAiMemory> &memory) const;
    uint64_t family_signature_locked(const std::vector<CountryAiMemory> &memory) const;

    mutable std::mutex _mutex;
    CountryAiCatalog _catalog;
    bool _configured = false;
    bool _armed = false;
    CountryAiMode _mode = CountryAiMode::OFF;
    std::vector<uint64_t> _excluded;
    std::vector<int32_t> _neighbors;
    std::vector<int32_t> _cell_value_q16;
    CountryAiTechIndex _tech;
    std::vector<CountryAiMemory> _memory;
    int64_t _committed_day = -1;
    uint64_t _decision_id = 0;
    uint64_t _family_signature = 0;

    bool _staged = false;
    int64_t _staged_day = -1;
    std::vector<CountryAiMemory> _staged_memory;
    CountryAiPlanOutput _staged_out;
    uint64_t _staged_decision_id = 0;
    bool _staged_rejected = false;

    std::deque<CountryAiDecision> _decisions;
    std::deque<CountryAiRecordRow> _records;
    CountryAiReport _report;
};

} // namespace pk
