#include "country_ai_runtime.h"

#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {

namespace {

constexpr uint32_t PKAI_MAGIC = 0x49414b50u; // "PKAI"
constexpr uint32_t PKAI_VERSION = 2u;
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

struct Writer {
    std::vector<uint8_t> bytes;
    void u8(uint8_t v) { bytes.push_back(v); }
    void u32(uint32_t v) { for (int i = 0; i < 4; ++i) bytes.push_back(static_cast<uint8_t>(v >> (i * 8))); }
    void u64(uint64_t v) { for (int i = 0; i < 8; ++i) bytes.push_back(static_cast<uint8_t>(v >> (i * 8))); }
    void i32(int32_t v) { u32(static_cast<uint32_t>(v)); }
    void i64(int64_t v) { u64(static_cast<uint64_t>(v)); }
};

struct Reader {
    const uint8_t *data;
    size_t size;
    size_t at = 0;
    bool ok = true;
    bool need(size_t n) {
        if (!ok || size - at < n) { ok = false; return false; }
        return true;
    }
    uint8_t u8() { if (!need(1)) return 0; return data[at++]; }
    uint32_t u32() {
        if (!need(4)) return 0;
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= static_cast<uint32_t>(data[at++]) << (i * 8);
        return v;
    }
    uint64_t u64() {
        if (!need(8)) return 0;
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) v |= static_cast<uint64_t>(data[at++]) << (i * 8);
        return v;
    }
    int32_t i32() { return static_cast<int32_t>(u32()); }
    int64_t i64() { return static_cast<int64_t>(u64()); }
};

void write_memory(Writer &w, const CountryAiMemory &m) {
    w.u64(m.handle); w.u8(m.controlled); w.u8(m.personality); w.u8(m.agenda);
    w.u8(m.initialized); w.i64(m.agenda_since_day); w.i64(m.last_think_day);
    w.i64(m.last_strategy_day); w.i64(m.last_research_day); w.i64(m.last_tax_day);
    w.i64(m.last_colonize_day); w.i64(m.colonize_cooldown_until); w.i64(m.last_cash);
    w.i64(m.last_cash_day); w.i64(m.cash_delta_ema); w.i32(m.satisfaction_ema_q16);
    w.i32(m.goal_milestone); w.i32(m.milestone_gap); w.i32(m.completed_milestones);
    w.i32(m.tax_pressure); w.u32(m.colonize_failures_seen); w.u32(m.colonize_started_seen);
    w.u32(m.commands_emitted); w.u32(m.commands_rejected); w.u32(m.colonize_intents);
    w.i32(m.colonize_last_target); w.u32(m.colonize_bad_cursor);
    for (const int32_t cell : m.colonize_bad_targets) w.i32(cell);
}

CountryAiMemory read_memory(Reader &r) {
    CountryAiMemory m;
    m.handle = r.u64(); m.controlled = r.u8(); m.personality = r.u8(); m.agenda = r.u8();
    m.initialized = r.u8(); m.agenda_since_day = r.i64(); m.last_think_day = r.i64();
    m.last_strategy_day = r.i64(); m.last_research_day = r.i64(); m.last_tax_day = r.i64();
    m.last_colonize_day = r.i64(); m.colonize_cooldown_until = r.i64(); m.last_cash = r.i64();
    m.last_cash_day = r.i64(); m.cash_delta_ema = r.i64(); m.satisfaction_ema_q16 = r.i32();
    m.goal_milestone = r.i32(); m.milestone_gap = r.i32(); m.completed_milestones = r.i32();
    m.tax_pressure = r.i32(); m.colonize_failures_seen = r.u32(); m.colonize_started_seen = r.u32();
    m.commands_emitted = r.u32(); m.commands_rejected = r.u32(); m.colonize_intents = r.u32();
    m.colonize_last_target = r.i32(); m.colonize_bad_cursor = r.u32();
    for (int32_t &cell : m.colonize_bad_targets) cell = r.i32();
    return m;
}

uint64_t hash_command(uint64_t h, const CountryAiCommand &c, int64_t day) {
    const uint64_t fields[] = {
        static_cast<uint64_t>(day), c.opcode, c.target_handle,
        static_cast<uint64_t>(static_cast<int64_t>(c.aux)),
        static_cast<uint64_t>(static_cast<int64_t>(c.domain)),
        static_cast<uint64_t>(static_cast<int64_t>(c.position)),
        static_cast<uint64_t>(static_cast<int64_t>(c.weights_bp[0])),
        static_cast<uint64_t>(static_cast<int64_t>(c.weights_bp[1])),
        static_cast<uint64_t>(static_cast<int64_t>(c.weights_bp[2])),
        static_cast<uint64_t>(static_cast<int64_t>(c.weights_bp[3])),
        static_cast<uint64_t>(static_cast<int64_t>(c.tax_kind)),
        static_cast<uint64_t>(static_cast<int64_t>(c.tax_rate_bp)),
        static_cast<uint64_t>(c.value),
        static_cast<uint64_t>(static_cast<int64_t>(c.tax_item))};
    for (const uint64_t f : fields) {
        for (int i = 0; i < 8; ++i) {
            h ^= (f >> (i * 8)) & 0xffu;
            h *= FNV_PRIME;
        }
    }
    return h;
}

} // namespace

bool CountryAiRuntime::configure(const CountryAiCatalog &catalog, std::string &error) {
    if (!country_ai_validate_catalog(catalog, error)) return false;
    std::lock_guard<std::mutex> lock(_mutex);
    _catalog = catalog;
    _catalog.catalog_hash = country_ai_catalog_hash(_catalog);
    _configured = true;
    _armed = false;
    _memory.clear();
    _committed_day = -1;
    _decision_id = 0;
    _family_signature = 0;
    _staged = false;
    _staged_memory.clear();
    _staged_out = CountryAiPlanOutput{};
    _decisions.clear();
    _records.clear();
    _tech = CountryAiTechIndex{};
    const CountryAiMode mode = _mode;
    _report = CountryAiReport{};
    _report.mode = mode;
    _report.configured = true;
    _report.catalog_hash = _catalog.catalog_hash;
    return true;
}

void CountryAiRuntime::set_mode(CountryAiMode mode) {
    std::lock_guard<std::mutex> lock(_mutex);
    _mode = mode;
    _report.mode = mode;
}

CountryAiMode CountryAiRuntime::mode() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _mode;
}

bool CountryAiRuntime::active() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _configured && _mode != CountryAiMode::OFF;
}

void CountryAiRuntime::set_excluded_handles(std::vector<uint64_t> handles) {
    std::sort(handles.begin(), handles.end());
    handles.erase(std::unique(handles.begin(), handles.end()), handles.end());
    std::lock_guard<std::mutex> lock(_mutex);
    _excluded = std::move(handles);
    _armed = true;
    for (CountryAiMemory &m : _memory)
        m.controlled = m.handle != 0 &&
            !std::binary_search(_excluded.begin(), _excluded.end(), m.handle) ? 1 : 0;
}

std::vector<uint64_t> CountryAiRuntime::excluded_handles() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _excluded;
}

void CountryAiRuntime::set_topology(std::vector<int32_t> neighbors,
                                    std::vector<int32_t> cell_value_q16) {
    std::lock_guard<std::mutex> lock(_mutex);
    _neighbors = std::move(neighbors);
    _cell_value_q16 = std::move(cell_value_q16);
}

bool CountryAiRuntime::due(int64_t day) const {
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_configured || !_armed || _mode == CountryAiMode::OFF || day <= _committed_day)
        return false;
    // Before the first plan the memory has no rows yet; uninitialised slots
    // think immediately.
    if (_memory.empty()) return true;
    return country_ai_due(_catalog, _memory, day);
}

bool CountryAiRuntime::plan(int64_t day, const RuntimeCountryPodSnapshot &state,
                            const RuntimeCountryPodCatalog &catalog,
                            const CountryAiEconomyDigest *economy,
                            std::vector<CountryAiCommand> &commands) {
    commands.clear();
    const auto started = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(_mutex);
    _staged = false;
    if (!_configured || !_armed || _mode == CountryAiMode::OFF || day <= _committed_day)
        return false;
    if (_tech.catalog_hash != catalog.catalog_hash || _tech.technology_count != catalog.technology_count) {
        if (!_tech.build(catalog)) return false;
    }
    _staged_memory = _memory;
    country_ai_sync_memory(_catalog, state, _excluded, _staged_memory);
    if (!country_ai_due(_catalog, _staged_memory, day)) return false;
    _staged_out = CountryAiPlanOutput{};
    _staged_decision_id = _decision_id;
    CountryAiPlanInput input;
    input.day = day;
    input.state = &state;
    input.catalog = &catalog;
    input.tech = &_tech;
    input.economy = economy;
    input.neighbors = _neighbors.size() == static_cast<size_t>(state.cell_count) * 6u &&
        !_neighbors.empty() ? &_neighbors : nullptr;
    input.cell_value_q16 = _cell_value_q16.size() == state.cell_count && !_cell_value_q16.empty()
        ? &_cell_value_q16 : nullptr;
    country_ai_plan(_catalog, input, _staged_memory, _staged_decision_id, _staged_out);
    if (_mode == CountryAiMode::PROBE) {
        for (CountryAiDecision &d : _staged_out.decisions)
            if (d.outcome == COUNTRY_AI_OUTCOME_EMITTED) d.outcome = COUNTRY_AI_OUTCOME_PROBE;
        _staged_out.commands.clear();
        _staged_out.colonization.clear();
    }
    commands = _staged_out.commands;
    _staged = true;
    _staged_day = day;
    _staged_rejected = false;
    const double ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    _report.plan_ms_last = ms;
    _report.plan_ms_max = std::max(_report.plan_ms_max, ms);
    _report.plan_ms_total += ms;
    ++_report.plan_days_due;
    _report.country_catalog_hash = catalog.catalog_hash;
    return true;
}

void CountryAiRuntime::reject_staged(int64_t day, const char *reason) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_staged || _staged_day != day || _staged_out.commands.empty()) return;
    _staged_rejected = true;
    for (const CountryAiCommand &c : _staged_out.commands) {
        if (c.slot >= 0 && static_cast<size_t>(c.slot) < _staged_memory.size()) {
            CountryAiMemory &m = _staged_memory[static_cast<size_t>(c.slot)];
            ++m.commands_rejected;
            if (m.commands_emitted > 0) --m.commands_emitted;
        }
    }
    for (CountryAiDecision &d : _staged_out.decisions) {
        if (d.outcome != COUNTRY_AI_OUTCOME_EMITTED || d.module == COUNTRY_AI_MODULE_STRATEGY ||
            d.module == COUNTRY_AI_MODULE_COLONIZE)
            continue;
        d.outcome = COUNTRY_AI_OUTCOME_REJECTED;
        if (reason != nullptr) {
            std::strncpy(d.reason.data(), reason, d.reason.size() - 1);
            d.reason[d.reason.size() - 1] = '\0';
        }
    }
    _report.commands_rejected += _staged_out.commands.size();
    ++_report.retries;
    _staged_out.commands.clear();
}

CountryAiCommitResult CountryAiRuntime::commit(int64_t day) {
    CountryAiCommitResult result;
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_staged || _staged_day != day) {
        // Nothing planned for this day; just advance the cursor so a stale
        // stage can never be committed later.
        if (_configured && day > _committed_day) _committed_day = day;
        _staged = false;
        return result;
    }
    _memory.swap(_staged_memory);
    _decision_id = _staged_decision_id;
    _committed_day = day;
    _staged = false;
    ++_report.plans;
    _report.countries_thought += _staged_out.countries_thought;
    _report.commands_emitted += _staged_out.commands.size();
    _report.colonization_intents += _staged_out.colonization.size();
    for (const CountryAiCommand &c : _staged_out.commands)
        _report.command_hash = hash_command(_report.command_hash == 0 ? FNV_OFFSET
                                                                      : _report.command_hash, c, day);
    for (CountryAiDecision &d : _staged_out.decisions) {
        _decisions.push_back(d);
        ++_report.decisions_total;
    }
    while (_decisions.size() > DECISION_RING_CAPACITY) _decisions.pop_front();
    for (const CountryAiRecordRow &row : _staged_out.records) {
        _records.push_back(row);
        ++_report.records_total;
    }
    while (_records.size() > RECORD_RING_CAPACITY) {
        _records.pop_front();
        ++_report.records_dropped;
    }
    result.committed = true;
    result.colonization = std::move(_staged_out.colonization);
    const uint64_t signature = family_signature_locked(_memory);
    if (signature != _family_signature) {
        _family_signature = signature;
        result.family_preferences_changed = true;
        result.family_preferences = family_preferences_locked(_memory);
    }
    _staged_out = CountryAiPlanOutput{};
    return result;
}

void CountryAiRuntime::abort(int64_t day) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_staged && _staged_day == day) {
        _staged = false;
        _staged_out = CountryAiPlanOutput{};
    }
}

RuntimeCountryCommand CountryAiRuntime::to_runtime_command(const CountryAiCommand &c,
                                                           int64_t day, uint32_t index) {
    RuntimeCountryCommand command;
    command.producer_id = COUNTRY_AI_PRODUCER_ID;
    // Day-major sequence: unique within a day and independent of any host
    // counter, so retries and save/load reproduce identical ordering.
    command.sequence = (static_cast<uint64_t>(day) << 16u) | (index & 0xffffu);
    command.observed_generation = 0;
    command.requested_day = day;
    command.effective_day = day;
    command.opcode = c.opcode;
    command.target_handle = c.target_handle;
    command.aux = c.aux;
    command.domain = c.domain;
    command.position = c.position;
    command.weights_bp = c.weights_bp;
    command.tax_kind = c.tax_kind;
    command.tax_item = c.tax_item;
    command.tax_rate_basis_points = c.tax_rate_bp;
    command.tax_assessment_mode = c.tax_mode;
    command.value = c.value;
    return command;
}

CountryAiReport CountryAiRuntime::report() const {
    std::lock_guard<std::mutex> lock(_mutex);
    CountryAiReport out = _report;
    out.configured = _configured;
    out.armed = _armed;
    out.mode = _mode;
    out.committed_day = _committed_day;
    out.excluded = static_cast<uint32_t>(_excluded.size());
    out.controlled = 0;
    for (const CountryAiMemory &m : _memory) out.controlled += m.controlled;
    out.state_hash = country_ai_hash_memory(_memory);
    return out;
}

std::vector<CountryAiDecision> CountryAiRuntime::decisions_after(uint64_t after_id,
                                                                 size_t limit) const {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<CountryAiDecision> out;
    for (const CountryAiDecision &d : _decisions) {
        if (d.id <= after_id) continue;
        out.push_back(d);
        if (out.size() >= limit) break;
    }
    return out;
}

std::vector<CountryAiRecordRow> CountryAiRuntime::drain_records(size_t limit) {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<CountryAiRecordRow> out;
    while (!_records.empty() && out.size() < limit) {
        out.push_back(_records.front());
        _records.pop_front();
    }
    return out;
}

std::vector<CountryAiMemory> CountryAiRuntime::memory() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _memory;
}

std::vector<CountryAiFamilyPreferenceRow> CountryAiRuntime::family_preferences() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return family_preferences_locked(_memory);
}

std::vector<CountryAiFamilyPreferenceRow> CountryAiRuntime::family_preferences_locked(
        const std::vector<CountryAiMemory> &memory) const {
    std::vector<CountryAiFamilyPreferenceRow> rows;
    if (!_configured || !_armed || _mode != CountryAiMode::ACTIVE || _catalog.personalities.empty())
        return rows;
    for (const CountryAiMemory &m : memory) {
        if (m.controlled == 0 || m.handle == 0) continue;
        CountryAiFamilyPreferenceRow row;
        row.country_handle = m.handle;
        row.weights = _catalog.personalities[std::min<size_t>(m.personality,
            _catalog.personalities.size() - 1)].family_pref;
        rows.push_back(row);
    }
    std::sort(rows.begin(), rows.end(), [](const auto &l, const auto &r) {
        return l.country_handle < r.country_handle;
    });
    return rows;
}

uint64_t CountryAiRuntime::family_signature_locked(
        const std::vector<CountryAiMemory> &memory) const {
    uint64_t h = FNV_OFFSET ^ static_cast<uint64_t>(_mode);
    for (const CountryAiMemory &m : memory) {
        if (m.controlled == 0) continue;
        h = (h ^ m.handle) * FNV_PRIME;
        h = (h ^ m.personality) * FNV_PRIME;
    }
    return h == 0 ? 1 : h;
}

uint64_t CountryAiRuntime::state_hash() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return country_ai_hash_memory(_memory);
}

std::vector<uint8_t> CountryAiRuntime::encode() const {
    std::lock_guard<std::mutex> lock(_mutex);
    Writer w;
    w.u32(PKAI_MAGIC);
    w.u32(PKAI_VERSION);
    w.u64(_catalog.catalog_hash);
    w.i64(_committed_day);
    w.u64(_decision_id);
    w.u32(static_cast<uint32_t>(_excluded.size()));
    for (const uint64_t h : _excluded) w.u64(h);
    w.u32(static_cast<uint32_t>(_memory.size()));
    for (const CountryAiMemory &m : _memory) write_memory(w, m);
    w.u64(country_ai_hash_memory(_memory));
    return std::move(w.bytes);
}

bool CountryAiRuntime::restore(const uint8_t *data, size_t size, std::string &error) {
    Reader r{data, size};
    if (r.u32() != PKAI_MAGIC) { error = "pkai_magic_invalid"; return false; }
    if (r.u32() != PKAI_VERSION) { error = "pkai_version_unsupported"; return false; }
    const uint64_t catalog_hash = r.u64();
    const int64_t committed_day = r.i64();
    const uint64_t decision_id = r.u64();
    const uint32_t excluded_count = r.u32();
    if (!r.ok || excluded_count > 4096) { error = "pkai_excluded_invalid"; return false; }
    std::vector<uint64_t> excluded(excluded_count);
    for (uint64_t &h : excluded) h = r.u64();
    const uint32_t memory_count = r.u32();
    if (!r.ok || memory_count > 65536) { error = "pkai_memory_invalid"; return false; }
    std::vector<CountryAiMemory> memory(memory_count);
    for (CountryAiMemory &m : memory) m = read_memory(r);
    const uint64_t hash = r.u64();
    if (!r.ok || r.at != size) { error = "pkai_truncated"; return false; }
    if (hash != country_ai_hash_memory(memory)) { error = "pkai_hash_mismatch"; return false; }
    std::sort(excluded.begin(), excluded.end());
    std::lock_guard<std::mutex> lock(_mutex);
    if (!_configured) { error = "country_ai_not_configured"; return false; }
    if (catalog_hash != _catalog.catalog_hash) {
        _report.restored_catalog_mismatch = true;
        error = "catalog_hash_mismatch";
        return false;
    }
    _excluded = std::move(excluded);
    _armed = true;
    _memory = std::move(memory);
    _committed_day = committed_day;
    _decision_id = decision_id;
    _family_signature = 0;
    _staged = false;
    _staged_out = CountryAiPlanOutput{};
    _decisions.clear();
    _records.clear();
    ++_report.restores;
    _report.restored_catalog_mismatch = false;
    return true;
}

} // namespace pk
