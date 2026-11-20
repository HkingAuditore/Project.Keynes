#include "world_ext.h"
#include "country_api.h"
#include "native_simulation_host_military.h"
#include "native_simulation_day_context.h"
#include "runtime_vision.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace pk {

using namespace godot;

namespace {

constexpr int32_t kBaseBudget = 42;
// Mobile military formations contribute a smaller observation budget than a
// city/territory source. Keep the highest military budget below the lowest
// city budget so a unit can never out-see an equivalent urban source.
constexpr int32_t kMilitaryBaseBudget = 24;
constexpr int32_t kMaxViewHeight = 32;
constexpr int32_t kBlurIterations = 2;

} // namespace

namespace {

struct VisionResearchWork : RuntimeVisionFrame {
    const VisionResearchState *state = nullptr;
    std::vector<int32_t> owners, occupancy, military_sources;
    std::vector<uint8_t> previous_visible, previous_explored, previous_fog;
    int32_t player_slot = -1;
    bool remote = false;
    std::vector<uint8_t> eligibility;
    std::vector<int32_t> dirty, resource_visible;
    std::vector<uint64_t> observations;
    bool ok = false;
    void compute() noexcept;
};

template <typename T, typename Packed>
std::vector<T> copy_column(const Packed &values) {
    return values.is_empty() ? std::vector<T>() :
        std::vector<T>(values.ptr(), values.ptr() + values.size());
}

int32_t lowest_bit_index(uint32_t bits) {
    int32_t bit = 0;
    while ((bits & 1u) == 0u) {
        bits >>= 1u;
        ++bit;
    }
    return bit;
}

PackedByteArray packed_u8(const std::vector<uint8_t> &values) {
    PackedByteArray out;
    out.resize(static_cast<int64_t>(values.size()));
    if (!values.empty())
        std::memcpy(out.ptrw(), values.data(), values.size() * sizeof(uint8_t));
    return out;
}

PackedInt32Array packed_i32(const std::vector<int32_t> &values) {
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(values.size()));
    if (!values.empty())
        std::memcpy(out.ptrw(), values.data(), values.size() * sizeof(int32_t));
    return out;
}

void blur_hex(const std::vector<float> &src, std::vector<float> &dst,
              const int32_t *neighbors, int32_t n) {
    dst.resize(static_cast<size_t>(n));
    for (int32_t cell = 0; cell < n; ++cell) {
        float sum = src[static_cast<size_t>(cell)] * 2.0f;
        float weight = 2.0f;
        const int32_t base = cell * 6;
        for (int32_t d = 0; d < 6; ++d) {
            const int32_t next = neighbors[base + d];
            if (next < 0 || next >= n) continue;
            sum += src[static_cast<size_t>(next)];
            weight += 1.0f;
        }
        dst[static_cast<size_t>(cell)] = sum / weight;
    }
}

void append_observation(uint64_t key, std::vector<uint64_t> &keys) {
    keys.push_back(key);
}

void order_observations(std::vector<uint64_t> &keys) {
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
}

void unpack_observations(std::vector<uint64_t> &keys, Dictionary &out) {
    order_observations(keys);
    PackedInt32Array cells;
    PackedInt32Array signals;
    cells.resize(static_cast<int64_t>(keys.size()));
    signals.resize(static_cast<int64_t>(keys.size()));
    int32_t *cell_ptr = cells.ptrw();
    int32_t *signal_ptr = signals.ptrw();
    for (size_t i = 0; i < keys.size(); ++i) {
        signal_ptr[i] = int32_t(keys[i] >> 32u);
        cell_ptr[i] = int32_t(keys[i] & 0xffffffffu);
    }
    out["observation_cells"] = cells;
    out["observation_signals"] = signals;
    out["observation_count"] = static_cast<int64_t>(keys.size());
}

Dictionary vision_frame_to_dictionary(const RuntimeVisionFrame &frame) {
    Dictionary out;
    out["ok"] = true;
    out["available"] = true;
    out["revision"] = static_cast<int64_t>(frame.revision);
    out["day"] = frame.day;
    out["fog_enabled"] = frame.fog_enabled;
    out["physical_visible"] = packed_u8(frame.visible);
    out["explored_arr"] = packed_u8(frame.explored);
    out["fog_k_arr"] = packed_u8(frame.fog);
    out["visible"] = frame.visible_count;
    out["explored"] = frame.explored_count;
    out["sources"] = frame.source_count;
    out["military_sources"] = frame.military_source_count;
    out["cells"] = static_cast<int64_t>(frame.visible.size());
    out["elapsed_ms"] = frame.elapsed_ms;
    return out;
}

} // namespace

Dictionary DCWorldExt::configure_vision_research(const Dictionary &config) {
    Dictionary out;
    out["ok"] = false;
    if (_runtime_host && !_runtime_host->execution_has_stopped()) {
        out["reason"] = "vision_configure_requires_stopped_runtime";
        return out;
    }
    const int32_t n = int32_t(config.get("cell_count", 0));
    const PackedInt32Array neighbors = config.get("neighbor_indices", PackedInt32Array());
    const PackedByteArray height = config.get("view_height", PackedByteArray());
    const PackedByteArray block = config.get("view_block", PackedByteArray());
    const PackedInt32Array offsets = config.get("signal_offsets", PackedInt32Array());
    const PackedInt32Array signal_ids = config.get("signal_ids", PackedInt32Array());
    const PackedInt32Array bio_bits = config.get("bio_bits", PackedInt32Array());
    const PackedInt32Array bio_signals = config.get("bio_signals", PackedInt32Array());
    if (n <= 0 || neighbors.size() != int64_t(n) * 6 || height.size() != n ||
        block.size() != n || offsets.size() != int64_t(n) + 1 ||
        offsets[0] != 0 || offsets[n] != signal_ids.size() ||
        !std::is_sorted(offsets.ptr(), offsets.ptr() + offsets.size()) ||
        bio_bits.size() != bio_signals.size()) {
        out["reason"] = "vision_research_config_shape_invalid";
        return out;
    }
    auto state = std::make_shared<VisionResearchState>();
    state->cell_count = n;
    state->neighbors = copy_column<int32_t>(neighbors);
    state->view_height = copy_column<uint8_t>(height);
    state->view_block = copy_column<uint8_t>(block);
    state->signal_offsets = copy_column<int32_t>(offsets);
    state->signal_ids = copy_column<int32_t>(signal_ids);
    for (int32_t i = 0; i < bio_bits.size(); ++i) {
        const int32_t bit = bio_bits[i];
        if (bit < 0 || bit >= 32 || state->bit_to_signal[size_t(bit)] >= 0) {
            out["reason"] = "vision_research_bio_bit_invalid";
            return out;
        }
        state->bit_to_signal[size_t(bit)] = bio_signals[i];
    }
    state->eligibility.assign(static_cast<size_t>(n), 0u);
    if (config.has("world_day")) {
        const auto *country = static_cast<NativeCountryRuntime *>(_country_runtime);
        CountryEconomySnapshot country_view;
        if (!_runtime_host || !country || !country_api::copy_economy_snapshot(*country, country_view) ||
                country_view.cell_country_slot.size() != size_t(n)) {
            out["reason"] = "vision_country_state_unavailable";
            return out;
        }
        state->owners = std::move(country_view.cell_country_slot);
        const int32_t start = config.get("player_start_cell", -1);
        state->player_slot = start >= 0 && start < n ? state->owners[start] : -1;
        if (state->player_slot >= 0 && size_t(state->player_slot) < country_view.country_handles.size())
            state->player_handle = country_view.country_handles[state->player_slot];
        state->remote_technology = config.get("remote_technology", -1);
        state->remote = state->remote_technology >= 0 &&
            country_api::has_completed_technology(*country, state->player_handle, state->remote_technology);
        state->fog_available = static_cast<bool>(config.get("fog_available", false)) &&
            state->player_handle != 0;
        state->fog_enabled = state->fog_available && static_cast<bool>(config.get("fog_enabled", false));
        state->all_visible.assign(size_t(n), 1);
        if (_military) state->military_sources = _military->vision_sources(state->player_slot);
        VisionResearchWork work;
        work.state = state.get();
        work.owners = state->owners;
        work.player_slot = state->player_slot;
        work.remote = state->remote;
        work.military_sources = state->military_sources;
        work.previous_explored = copy_column<uint8_t>(
            PackedByteArray(config.get("explored", PackedByteArray())));
        work.occupancy = copy_column<int32_t>(
            PackedInt32Array(config.get("occupancy", PackedInt32Array())));
        if (work.previous_explored.size() != size_t(n) || work.occupancy.size() != size_t(n)) {
            out["reason"] = "vision_research_input_shape_invalid";
            return out;
        }
        work.compute();
        if (!work.ok) {
            out["reason"] = "vision_research_compute_failed";
            return out;
        }
        work.day = int64_t(config["world_day"]);
        work.revision = 1;
        work.fog_enabled = state->fog_enabled;
        if (!static_cast<bool>(config.get("restored", false)) && !work.observations.empty()) {
            Dictionary observations;
            unpack_observations(work.observations, observations);
            auto *writer = static_cast<NativeCountryRuntime *>(_country_runtime);
            auto accepted = country_api::submit_observation_batch(*writer, state->player_handle,
                observations["observation_cells"], observations["observation_signals"], work.day + 1);
            if (!static_cast<bool>(accepted.get("ok", false))) return accepted;
        }
        state->eligibility = std::move(work.eligibility);
        state->frame = std::make_shared<RuntimeVisionFrame>(std::move(work));
        _runtime_host->attach_vision(std::move(state));
        _vision_research_state.reset();
        out["ok"] = true;
        return out;
    }
    _vision_research_state = std::move(state);
    out["ok"] = true;
    out["cells"] = n;
    return out;
}

void VisionResearchWork::compute() noexcept {
    const auto started = std::chrono::steady_clock::now();
    try {
        const int32_t n = state->cell_count;
        const int32_t *neighbors = state->neighbors.data();
        const uint8_t *height = state->view_height.data();
        const uint8_t *block = state->view_block.data();
        std::vector<int32_t> best(static_cast<size_t>(n), -1);
        std::vector<std::vector<int32_t>> buckets(size_t(kBaseBudget + kMaxViewHeight + 1));
        for (int32_t cell = 0; cell < n; ++cell) {
            if (player_slot < 0 || owners[cell] != player_slot) continue;
            ++source_count;
            const int32_t budget = std::clamp(kBaseBudget + int32_t(height[cell]),
                                              0, kBaseBudget + kMaxViewHeight);
            if (budget > best[size_t(cell)]) {
                best[size_t(cell)] = budget;
                buckets[size_t(budget)].push_back(cell);
            }
        }
        for (const int32_t cell : military_sources) {
            if (cell < 0 || cell >= n) continue;
            ++military_source_count;
            const int32_t budget = std::clamp(
                kMilitaryBaseBudget + int32_t(height[cell]) / 2,
                0, kBaseBudget + kMaxViewHeight);
            if (budget > best[size_t(cell)]) {
                best[size_t(cell)] = budget;
                buckets[size_t(budget)].push_back(cell);
            }
        }
        visible.assign(static_cast<size_t>(n), 0u);
        for (int32_t budget = kBaseBudget + kMaxViewHeight; budget >= 0; --budget) {
            const std::vector<int32_t> &bucket = buckets[size_t(budget)];
            for (size_t index = 0; index < bucket.size(); ++index) {
                const int32_t cell = bucket[index];
                if (best[size_t(cell)] != budget) continue;
                visible[size_t(cell)] = 1u;
                const int32_t base = cell * 6;
                for (int32_t d = 0; d < 6; ++d) {
                    const int32_t next = neighbors[base + d];
                    if (next < 0 || next >= n) continue;
                    const int32_t next_budget = budget - int32_t(block[next]);
                    if (next_budget < 0 || next_budget <= best[size_t(next)]) continue;
                    best[size_t(next)] = next_budget;
                    buckets[size_t(next_budget)].push_back(next);
                }
            }
        }
        // 领土六邻接必可见：与 VisionSolver._force_territory_ring_visible 对齐。
        // 主修复是 CLAIM 后 sync_country_territory_to_map；这里兜住共边硬状态。
        for (int32_t cell = 0; cell < n; ++cell) {
            if (player_slot < 0 || owners[cell] != player_slot) continue;
            visible[size_t(cell)] = 1u;
            const int32_t base = cell * 6;
            for (int32_t d = 0; d < 6; ++d) {
                const int32_t next = neighbors[base + d];
                if (next < 0 || next >= n) continue;
                visible[size_t(next)] = 1u;
            }
        }

        explored.resize(static_cast<size_t>(n));
        std::vector<float> vis_a(static_cast<size_t>(n));
        std::vector<float> exp_a(static_cast<size_t>(n));
        for (int32_t cell = 0; cell < n; ++cell) {
            explored[size_t(cell)] = previous_explored[cell] != 0 || visible[size_t(cell)] != 0;
            vis_a[size_t(cell)] = visible[size_t(cell)] != 0 ? 1.0f : 0.0f;
            exp_a[size_t(cell)] = explored[size_t(cell)] != 0 ? 1.0f : 0.0f;
            visible_count += visible[size_t(cell)];
            explored_count += explored[size_t(cell)];
        }
        std::vector<float> vis_b;
        std::vector<float> exp_b;
        for (int32_t iteration = 0; iteration < kBlurIterations; ++iteration) {
            blur_hex(vis_a, vis_b, neighbors, n);
            blur_hex(exp_a, exp_b, neighbors, n);
            vis_a.swap(vis_b);
            exp_a.swap(exp_b);
        }
        fog.resize(static_cast<size_t>(n));
        eligibility.resize(static_cast<size_t>(n));
        const int32_t *offsets = state->signal_offsets.data();
        const int32_t *signal_ids = state->signal_ids.data();
        for (int32_t cell = 0; cell < n; ++cell) {
            if (visible[size_t(cell)] != 0 &&
                (previous_visible.size() != n || previous_visible[cell] == 0))
                resource_visible.push_back(cell);
            fog[size_t(cell)] = uint8_t(std::clamp<int32_t>(
                int32_t(std::lround((0.5f * exp_a[size_t(cell)] +
                                     0.5f * vis_a[size_t(cell)]) * 255.0f)), 0, 255));
            if ((previous_visible.size() == n && previous_visible[cell] != visible[size_t(cell)]) ||
                previous_explored[cell] != explored[size_t(cell)] ||
                (previous_fog.size() == n && previous_fog[cell] != fog[size_t(cell)]))
                dirty.push_back(cell);
            const uint8_t eligible = uint8_t(player_slot >= 0 && (
                owners[cell] == player_slot || (remote && visible[size_t(cell)] != 0)));
            if (eligible != 0 && state->eligibility[size_t(cell)] == 0) {
                for (int32_t edge = offsets[cell]; edge < offsets[cell + 1]; ++edge)
                    append_observation((uint64_t(uint32_t(signal_ids[edge])) << 32u) |
                                       uint32_t(cell), observations);
                uint32_t bits = static_cast<uint32_t>(occupancy[cell]);
                while (bits != 0u) {
                    const int32_t bit = lowest_bit_index(bits);
                    bits &= bits - 1u;
                    const int32_t signal = state->bit_to_signal[size_t(bit)];
                    if (signal >= 0)
                        append_observation((uint64_t(uint32_t(signal)) << 32u) |
                                           uint32_t(cell), observations);
                }
            }
            eligibility[size_t(cell)] = eligible;
        }

        ok = true;
    } catch (...) {
        ok = false;
    }
    elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
}

Dictionary DCWorldExt::run_vision_research_pass(const Dictionary &knobs) {
    Dictionary out;
    out["ok"] = false;
    if (!_vision_research_state) {
        out["reason"] = "vision_research_not_configured";
        return out;
    }
    const int32_t n = _vision_research_state->cell_count;
    VisionResearchWork work;
    work.state = _vision_research_state.get();
    work.player_slot = int32_t(knobs.get("player_slot", -1));
    work.remote = bool(knobs.get("remote_observation", false));
    work.owners = copy_column<int32_t>(PackedInt32Array(knobs.get("country_slots", PackedInt32Array())));
    work.previous_visible = copy_column<uint8_t>(PackedByteArray(knobs.get("visible", PackedByteArray())));
    work.previous_explored = copy_column<uint8_t>(PackedByteArray(knobs.get("explored", PackedByteArray())));
    work.previous_fog = copy_column<uint8_t>(PackedByteArray(knobs.get("fog_k", PackedByteArray())));
    work.occupancy = copy_column<int32_t>(PackedInt32Array(knobs.get("bio_occupancy_bits", PackedInt32Array())));
    work.military_sources = copy_column<int32_t>(PackedInt32Array(knobs.get("military_source_cells", PackedInt32Array())));
    if (work.owners.size() != size_t(n) || work.previous_explored.size() != size_t(n) ||
        work.occupancy.size() != size_t(n)) {
        out["reason"] = "vision_research_input_shape_invalid";
        return out;
    }
    work.compute();
    if (!work.ok) {
        out["reason"] = "vision_research_compute_failed";
        return out;
    }
    _vision_research_state->eligibility = std::move(work.eligibility);
    out = vision_frame_to_dictionary(work);
    out["path"] = "gdext";
    out["fog_dirty_indices"] = packed_i32(work.dirty);
    out["resource_visual_visible_cells"] = packed_i32(work.resource_visible);
    unpack_observations(work.observations, out);
    return out;
}

void NativeSimulationHost::attach_vision(std::shared_ptr<VisionResearchState> vision) {
    _executor_vision = std::move(vision);
    // Seed before the first execution. Subsequent frames are part of the same
    // immutable publication as their day, so a reader cannot observe one alone.
    auto initial = std::make_shared<RuntimeCommit>();
    if (const auto previous = std::atomic_load(&_latest_commit))
        initial->header = previous->header;
    auto tail = std::make_shared<RuntimeDayTail>();
    tail->vision = _executor_vision->frame;
    initial->day_tail = std::move(tail);
    std::atomic_store(&_latest_commit, std::shared_ptr<const RuntimeCommit>(std::move(initial)));
}

std::shared_ptr<const RuntimeVisionFrame> NativeSimulationHost::latest_vision() const {
    const auto commit = std::atomic_load_explicit(&_latest_commit, std::memory_order_acquire);
    return commit && commit->day_tail ? commit->day_tail->vision : nullptr;
}

Dictionary DCWorldExt::get_runtime_vision_frame(int64_t after_revision) const {
    const auto &tail = _runtime_display_commit.day_tail;
    const auto frame = tail ? tail->vision : (_runtime_host ? _runtime_host->latest_vision() : nullptr);
    if (frame && static_cast<int64_t>(frame->revision) != after_revision)
        return vision_frame_to_dictionary(*frame);
    Dictionary out;
    out["ok"] = true;
    out["available"] = false;
    return out;
}

bool NativeSimulationHost::submit_fog_command(bool enabled, int64_t &effective_day) {
    if (!vision_executor_active()) return false;
    RuntimeCommandPacket packet;
    packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::VISUAL);
    packet.envelope.opcode = RUNTIME_VISUAL_SET_FOG;
    packet.envelope.request_id = allocate_command_request_id_for_ingress();
    packet.envelope.sequence = packet.envelope.request_id;
    packet.envelope.requested_day = command_seal_day();
    packet.envelope.effective_day = packet.envelope.requested_day;
    packet.envelope.payload_size = 1;
    packet.payload[0] = enabled ? 1u : 0u;
    std::vector<int64_t> days;
    if (!enqueue_batch({packet}, &days)) return false;
    effective_day = days.front();
    return true;
}

Dictionary DCWorldExt::set_runtime_fog_enabled(bool enabled) {
    int64_t day = -1;
    Dictionary out;
    const bool ok = _runtime_host && _runtime_host->submit_fog_command(enabled, day);
    out["ok"] = ok;
    if (ok) out["effective_day"] = day;
    else out["code"] = "vision_fog_command_unavailable";
    return out;
}

void NativeSimulationHost::apply_fog_commands(const std::vector<RuntimeCommandPacket> &commands) {
    if (!_executor_vision) return;
    for (const auto &command : commands) {
        if (command.envelope.domain == static_cast<uint16_t>(RuntimeDomainId::VISUAL) &&
            command.envelope.opcode == RUNTIME_VISUAL_SET_FOG &&
            command.envelope.payload_size == 1 && command.envelope.payload_offset == 0) {
            _executor_vision->fog_enabled = _executor_vision->fog_available && command.payload[0] != 0;
        }
    }
}

bool NativeSimulationHost::submit_vision_observations(
        uint64_t country, int64_t day, std::vector<uint64_t> &observations) {
    if (observations.empty() || country == 0) return true;
    order_observations(observations);
    auto &due = _country_observations[day];
    due.reserve(due.size() + observations.size());
    for (size_t i = 0; i < observations.size(); ++i) {
        RuntimeCountryCommand command;
        // Keep the existing observation producer and request-id stream.
        command.request_id = allocate_command_request_id_for_ingress();
        command.sequence = i == 0 ? allocate_producer_sequence(0) : i;
        command.requested_day = day;
        command.effective_day = day;
        command.opcode = CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL;
        command.target_handle = country;
        command.cell = static_cast<int32_t>(observations[i]);
        command.aux = static_cast<int32_t>(observations[i] >> 32u);
        command.weights_bp.fill(0);
        command.value = 1;

        command.submit_order = _command_submit_order.fetch_add(1u, std::memory_order_relaxed) + 1u;
        due.push_back(command);
    }
    return true;
}

bool NativeSimulationHost::submit_species_observations(
        int64_t day, const std::vector<int32_t> &cells, const std::vector<int32_t> &signals,
        int32_t &submitted) {
    if (!_executor_vision || _executor_vision->player_handle == 0)
        return true;
    const auto &vision = *_executor_vision;
    std::vector<uint64_t> observations;
    for (size_t i = 0; i < cells.size(); ++i) {
        const int32_t cell = cells[i];
        const int32_t signal = signals[i];
        if (cell >= 0 && cell < vision.cell_count && signal >= 0 && vision.eligibility[cell] != 0)
            observations.push_back((uint64_t(uint32_t(signal)) << 32u) | uint32_t(cell));
    }
    if (!submit_vision_observations(vision.player_handle, day + 1, observations))
        return false;
    submitted = static_cast<int32_t>(observations.size());
    return true;
}

const char *NativeSimulationHost::stage_vision(DayExecution &day) {
    if (!_executor_vision || day.commit.completed_domain_mask != RUNTIME_ALL_DOMAIN_MASK)
        return nullptr;
    auto &vision = *_executor_vision;
    const auto *country = _country_pod_authority.borrow_state();
    if (!country || country->cell_country_slot.size() != static_cast<size_t>(vision.cell_count))
        return "vision_country_state_unavailable";
    const int32_t slot = vision.player_slot;
    const int32_t tech = vision.remote_technology;
    const bool remote = slot >= 0 && tech >= 0 && uint32_t(slot) < country->country_count &&
        uint32_t(tech) < country->technology_count &&
        (country->country_technologies[size_t(slot) * country->technology_words + (tech >> 6)] &
         (uint64_t{1} << (tech & 63))) != 0;

    if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
    auto &tail = *_executor_day_tail;
    auto sources = _executor_military ? _executor_military->vision_sources(slot) : std::vector<int32_t>{};
    bool dirty = country->cell_country_slot != vision.owners ||
        remote != vision.remote || sources != vision.military_sources;
    const auto &previous = *vision.frame;
    std::vector<uint8_t> explored;
    if (_executor_military && slot >= 0) {
        const auto trail = _executor_military->take_vision_trail(slot);
        tail.military_trail_cells = static_cast<int32_t>(trail.size());
        if (!trail.empty()) {
            explored = previous.explored;
            for (const int32_t cell : trail)
                if (cell >= 0 && cell < vision.cell_count && explored[cell] == 0) {
                    explored[cell] = 1;
                    dirty = true;
                }
        }
    }

    const auto index = day.plan.context.day;
    if (dirty) {
        if (tail.occupancy.size() != static_cast<size_t>(vision.cell_count))
            return "vision_species_state_unavailable";
        VisionResearchWork work;
        work.state = &vision;
        work.owners = country->cell_country_slot;
        work.military_sources = std::move(sources);
        work.occupancy = tail.occupancy;
        work.previous_explored = explored.empty() ? previous.explored : std::move(explored);
        work.previous_visible = previous.visible;
        work.previous_fog = previous.fog;
        work.player_slot = slot;
        work.remote = remote;
        work.compute();
        if (!work.ok) return "vision_research_compute_failed";
        if (!submit_vision_observations(vision.player_handle, index + 1, work.observations))
            return "vision_observations_rejected";
        tail.vision_observations = static_cast<int32_t>(work.observations.size());
        tail.vision_solved = true;
        vision.owners = std::move(work.owners);
        vision.military_sources = std::move(work.military_sources);
        vision.eligibility = std::move(work.eligibility);
        vision.remote = remote;
        work.day = index;
        work.revision = previous.revision + 1;
        work.fog_enabled = vision.fog_enabled;
        vision.frame = std::make_shared<RuntimeVisionFrame>(std::move(work));
    } else if (vision.fog_enabled != previous.fog_enabled) {
        auto frame = std::make_shared<RuntimeVisionFrame>(previous);
        frame->day = index;
        ++frame->revision;
        frame->fog_enabled = vision.fog_enabled;
        vision.frame = std::move(frame);
    }

    tail.vision = vision.frame;
    return nullptr;
}

Dictionary DCWorldExt::filter_bio_research_observations(
        const PackedInt32Array &cells, const PackedInt32Array &signals) const {
    Dictionary out;
    out["ok"] = false;
    if (_vision_research_state == nullptr || cells.size() != signals.size()) {
        out["reason"] = "vision_research_observation_shape_invalid";
        return out;
    }
    const VisionResearchState *state = _vision_research_state.get();
    std::vector<uint64_t> observations;
    observations.reserve(static_cast<size_t>(cells.size()));
    for (int32_t i = 0; i < cells.size(); ++i) {
        const int32_t cell = cells[i];
        const int32_t signal = signals[i];
        if (cell < 0 || cell >= state->cell_count || signal < 0 ||
            state->eligibility[size_t(cell)] == 0)
            continue;
        observations.push_back((uint64_t(uint32_t(signal)) << 32u) | uint32_t(cell));
    }
    out["ok"] = true;
    unpack_observations(observations, out);
    return out;
}

} // namespace pk
