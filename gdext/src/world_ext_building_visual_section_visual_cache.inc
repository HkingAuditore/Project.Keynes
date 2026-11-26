namespace {

// web 上一律内联，与有没有 pthreads 无关：
//   * 无 pthreads：std::thread 构造会直接 abort；
//   * 有 pthreads：worker 线程里访问本模块 TLS 上的原子量会 trap
//     （"operation does not support unaligned accesses"，且发生在 worker 内、
//     不会冒到主线程，表现成世界生成卡死）。
// 队列量很小，内联完全够用：非线程路径由 take_ready_chunks / chunks_in_rect
// 带时间预算把队列跑干（见 plan_queued(deadline)），不会卡住主线程。
#if defined(__EMSCRIPTEN__)
constexpr bool kBuildingVisualThreaded = false;
#else
constexpr bool kBuildingVisualThreaded = true;
#endif

// A single cell never needs the chunk fair-share budget.
constexpr int kUnboundedCellCap = 1 << 24;

// Per-cell social bands: settlement tier, living level, rich and poor buckets.
using SocialBands = std::array<uint8_t, 4>;
constexpr SocialBands kUnknownSocial = {kUnknownBand, kUnknownBand, kUnknownBand, kUnknownBand};

// A cell with no buildings is only drawn while people live there.
bool populated(const SocialBands &social) {
    return social[0] >= 1 && social[0] <= 7;
}

struct CachedCell {
    int32_t era = 0;
    uint8_t water = 0;
    SocialBands social = kUnknownSocial;
    bool has_input = false;
    bool queued = false;
    uint64_t input_hash = 0;
    uint32_t input_gen = 0;  // bumped by every accepted change
    uint32_t output_gen = 0; // generation of the committed plan
    std::vector<int32_t> types;
    std::vector<int64_t> counts;
    std::vector<float> body;  // 16 floats per instance
    std::vector<float> decal; // 16 floats per instance
    int lots = 0;
};

uint64_t cell_input_hash(int32_t era, uint8_t water, const SocialBands &social,
        const int32_t *types, const int64_t *counts, int n) {
    uint64_t h = 1469598103934665603ULL;
    auto mix = [&h](uint64_t v) {
        h ^= v;
        h *= 1099511628211ULL;
    };
    mix(static_cast<uint32_t>(era));
    mix(water);
    for (uint8_t band : social) mix(band);
    mix(static_cast<uint64_t>(n));
    for (int e = 0; e < n; ++e) {
        mix(static_cast<uint32_t>(types[e]));
        mix(static_cast<uint64_t>(counts[e]));
    }
    return h;
}

double elapsed_us(std::chrono::steady_clock::time_point since) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - since).count();
}

} // namespace

struct BuildingVisualCacheState {
    // Static configuration: written only while the worker is stopped.
    int cell_count = 0;
    int map_width = 0;
    int chunk_size = 16;
    int chunks_x = 0;
    int chunk_count = 0;
    double hex_size = 22.0;
    int layout_seed = 0;
    double river_threshold = 0.42;
    std::vector<float> pos_x, pos_y; // world units
    std::vector<uint8_t> arch, family, scale, grade;
    std::vector<float> flow;
    int flow_w = 0, flow_h = 0;
    double flow_origin_x = 0.0, flow_origin_y = 0.0;
    double flow_size_x = 0.0, flow_size_y = 0.0, flow_wrap_x = 0.0;
    std::vector<float> chunk_bounds; // min_x, min_y, max_x, max_y per chunk

    // Everything below is guarded by `mutex`.
    mutable std::mutex mutex;
    std::condition_variable work_cv;
    std::condition_variable idle_cv;
    std::thread worker;
    bool stop = false;
    int quality = 1;
    std::unordered_map<int32_t, CachedCell> cells;
    std::deque<int32_t> queue;
    int in_flight = 0;
    std::vector<int32_t> chunk_pending;   // cells whose plan is older than their input
    std::vector<int32_t> chunk_instances; // committed body + decal instances
    std::vector<std::vector<int32_t>> chunk_cells; // sorted cached cells
    std::vector<uint8_t> chunk_ready;
    std::vector<int32_t> ready_list;
    int64_t submitted = 0;
    int64_t skipped = 0;
    int64_t planned = 0;
    int64_t stale = 0;
    double plan_us_total = 0.0;
    double plan_us_max = 0.0;
    double last_submit_us = 0.0;
    double last_build_us = 0.0;
    double max_build_us = 0.0;

    int chunk_of(int32_t cell) const {
        return (cell / map_width / chunk_size) * chunks_x + (cell % map_width) / chunk_size;
    }

    void mark_ready(int chunk) {
        if (chunk_ready[static_cast<size_t>(chunk)] == 0) {
            chunk_ready[static_cast<size_t>(chunk)] = 1;
            ready_list.push_back(chunk);
        }
    }

    void bump(int32_t cell, CachedCell &c) {
        if (c.input_gen == c.output_gen) {
            ++chunk_pending[static_cast<size_t>(chunk_of(cell))];
        }
        ++c.input_gen;
        if (!c.queued) {
            c.queued = true;
            queue.push_back(cell);
        }
    }

    void plan_one(int32_t cell, int32_t era, uint8_t water, const SocialBands &social,
            const std::vector<int32_t> &types,
            const std::vector<int64_t> &counts, int plan_quality, PlanOutputs &po,
            std::vector<float> &body, std::vector<float> &decal, int &lots) const {
        po.bodies.clear();
        po.grounds.clear();
        po.reset_counters();
        const float px = pos_x[static_cast<size_t>(cell)];
        const float py = pos_y[static_cast<size_t>(cell)];
        const int32_t offsets[2] = {0, static_cast<int32_t>(types.size())};
        PlanInputs in;
        in.K = 1;
        in.cells = &cell;
        in.pos_x = &px;
        in.pos_y = &py;
        in.offsets = offsets;
        in.types = types.data();
        in.counts = counts.data();
        in.eras = &era;
        in.water = &water;
        in.arch = arch.data();
        in.type_count = static_cast<int>(arch.size());
        in.family = family.empty() ? nullptr : family.data();
        in.scale = scale.empty() ? nullptr : scale.data();
        in.grade = grade.empty() ? nullptr : grade.data();
        in.tiers = &social[0];
        in.living = &social[1];
        in.rich = &social[2];
        in.poor = &social[3];
        in.quality = plan_quality;
        in.instance_cap = kUnboundedCellCap;
        in.hex_size = hex_size;
        in.cell_count = cell_count;
        in.layout_seed = layout_seed;
        in.river_threshold = river_threshold;
        if (!flow.empty()) {
            in.flow = flow.data();
            in.flow_w = flow_w;
            in.flow_h = flow_h;
            in.flow_origin_x = flow_origin_x;
            in.flow_origin_y = flow_origin_y;
            in.flow_size_x = flow_size_x;
            in.flow_size_y = flow_size_y;
            in.flow_wrap_x = flow_wrap_x;
        }
        plan_cells(in, po);
        const float cell_scale = 1.0f / float(std::max(1, cell_count - 1));
        body.resize(po.bodies.size() * 16U);
        for (size_t n = 0; n < po.bodies.size(); ++n) {
            encode_body(po.bodies[n], cell_scale, body.data() + n * 16U);
        }
        decal.clear();
        if (plan_quality > 0) {
            decal.resize(po.grounds.size() * 16U);
            for (size_t n = 0; n < po.grounds.size(); ++n) {
                encode_ground(po.grounds[n], cell_scale, decal.data() + n * 16U);
            }
        }
        lots = po.lot_total;
    }

    void plan_queued(std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::time_point::max()) {
        PlanOutputs po;
        std::vector<int32_t> types;
        std::vector<int64_t> counts;
        std::vector<float> body;
        std::vector<float> decal;
        for (;;) {
            int32_t cell = -1;
            uint32_t gen = 0;
            int32_t era = 0;
            uint8_t water = 0;
            SocialBands social = kUnknownSocial;
            int plan_quality = 1;
            {
                std::unique_lock<std::mutex> lock(mutex);
                if constexpr (kBuildingVisualThreaded) {
                    work_cv.wait(lock, [this] { return stop || !queue.empty(); });
                } else if (queue.empty() || std::chrono::steady_clock::now() >= deadline) {
                    return;
                }
                if (stop) return;
                cell = queue.front();
                queue.pop_front();
                auto it = cells.find(cell);
                if (it == cells.end()) {
                    continue;
                }
                CachedCell &c = it->second;
                c.queued = false;
                gen = c.input_gen;
                era = c.era;
                water = c.water;
                social = c.social;
                types = c.types;
                counts = c.counts;
                plan_quality = quality;
                ++in_flight;
            }
            const auto begin = std::chrono::steady_clock::now();
            int lots = 0;
            plan_one(cell, era, water, social, types, counts, plan_quality, po, body, decal, lots);
            const double us = elapsed_us(begin);
            {
                std::lock_guard<std::mutex> lock(mutex);
                --in_flight;
                ++planned;
                plan_us_total += us;
                plan_us_max = std::max(plan_us_max, us);
                auto it = cells.find(cell);
                if (it != cells.end() && it->second.input_gen == gen) {
                    CachedCell &c = it->second;
                    const int chunk = chunk_of(cell);
                    const int32_t before = int32_t((c.body.size() + c.decal.size()) / 16U);
                    const int32_t after = int32_t((body.size() + decal.size()) / 16U);
                    chunk_instances[static_cast<size_t>(chunk)] += after - before;
                    c.body.swap(body);
                    c.decal.swap(decal);
                    c.lots = lots;
                    c.output_gen = gen;
                    if (c.types.empty() && !populated(c.social)) {
                        std::vector<int32_t> &list = chunk_cells[static_cast<size_t>(chunk)];
                        auto pos = std::lower_bound(list.begin(), list.end(), cell);
                        if (pos != list.end() && *pos == cell) {
                            list.erase(pos);
                        }
                        cells.erase(it);
                    }
                    if (--chunk_pending[static_cast<size_t>(chunk)] == 0) {
                        mark_ready(chunk);
                    }
                } else {
                    ++stale;
                }
                if (queue.empty() && in_flight == 0) {
                    idle_cv.notify_all();
                }
            }
        }
    }

    void start_worker() {
        stop = false;
        if constexpr (kBuildingVisualThreaded) {
            worker = std::thread([this] { plan_queued(); });
        }
    }

    void stop_worker() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            stop = true;
        }
        work_cv.notify_all();
        if (worker.joinable()) {
            worker.join();
        }
        std::lock_guard<std::mutex> lock(mutex);
        in_flight = 0;
        idle_cv.notify_all();
    }
};

NativeBuildingVisualCache::NativeBuildingVisualCache()
        : _state(std::make_unique<BuildingVisualCacheState>()) {}

NativeBuildingVisualCache::~NativeBuildingVisualCache() {
    shutdown();
}

void NativeBuildingVisualCache::shutdown() {
    if (_state) {
        _state->stop_worker();
    }
}

godot::Dictionary NativeBuildingVisualCache::configure(const godot::Dictionary &config) {
    BuildingVisualCacheState &s = *_state;
    s.stop_worker();
    Dictionary out;
    out["ok"] = false;

    const int cell_count = int(config.get("cell_count", 0));
    const int map_width = int(config.get("map_width", 0));
    const int chunk_size = int(config.get("chunk_size", 16));
    const double hex_size = double(config.get("hex_size", 22.0));
    PackedFloat32Array pos_x = config.get("cell_pos_x", PackedFloat32Array());
    PackedFloat32Array pos_y = config.get("cell_pos_y", PackedFloat32Array());
    PackedByteArray arch = config.get("type_to_archetype", PackedByteArray());
    PackedByteArray family = config.get("type_to_family", PackedByteArray());
    PackedByteArray scale_table = config.get("type_to_scale", PackedByteArray());
    PackedByteArray grade = config.get("type_to_grade", PackedByteArray());
    auto table_ok = [&arch](const PackedByteArray &table) {
        return table.is_empty() || table.size() == arch.size();
    };
    if (cell_count <= 0 || map_width <= 0 || chunk_size <= 0 || hex_size <= 0.0 ||
            pos_x.size() < cell_count || pos_y.size() < cell_count ||
            !table_ok(family) || !table_ok(scale_table) || !table_ok(grade)) {
        out["reason"] = String("building_visual_cache_config_invalid");
        return out;
    }

    std::lock_guard<std::mutex> lock(s.mutex);
    s.cell_count = cell_count;
    s.map_width = map_width;
    s.chunk_size = chunk_size;
    const int map_height = (cell_count + map_width - 1) / map_width;
    s.chunks_x = (map_width + chunk_size - 1) / chunk_size;
    s.chunk_count = s.chunks_x * ((map_height + chunk_size - 1) / chunk_size);
    s.hex_size = hex_size;
    s.layout_seed = int(config.get("layout_seed", 0));
    s.river_threshold = double(config.get("river_clear_threshold", 0.42));
    s.quality = std::max(0, std::min(2, int(config.get("quality", 1))));
    s.pos_x.resize(static_cast<size_t>(cell_count));
    s.pos_y.resize(static_cast<size_t>(cell_count));
    const float scale = float(hex_size);
    for (int i = 0; i < cell_count; ++i) {
        s.pos_x[static_cast<size_t>(i)] = pos_x[i] * scale;
        s.pos_y[static_cast<size_t>(i)] = pos_y[i] * scale;
    }
    s.arch.assign(arch.ptr(), arch.ptr() + arch.size());
    s.family.assign(family.ptr(), family.ptr() + family.size());
    s.scale.assign(scale_table.ptr(), scale_table.ptr() + scale_table.size());
    s.grade.assign(grade.ptr(), grade.ptr() + grade.size());

    PackedFloat32Array flow = config.get("flow_buffer", PackedFloat32Array());
    s.flow_w = int(config.get("flow_w", 0));
    s.flow_h = int(config.get("flow_h", 0));
    s.flow_origin_x = double(config.get("flow_origin_x", 0.0));
    s.flow_origin_y = double(config.get("flow_origin_y", 0.0));
    s.flow_size_x = double(config.get("flow_size_x", 0.0));
    s.flow_size_y = double(config.get("flow_size_y", 0.0));
    s.flow_wrap_x = double(config.get("flow_wrap_period_x", 0.0));
    s.flow.clear();
    if (!flow.is_empty() && s.flow_w > 0 && s.flow_h > 0 &&
            flow.size() >= int64_t(s.flow_w) * int64_t(s.flow_h)) {
        s.flow.assign(flow.ptr(), flow.ptr() + flow.size());
    }

    const float inf = std::numeric_limits<float>::infinity();
    s.chunk_bounds.assign(static_cast<size_t>(s.chunk_count) * 4U, 0.0f);
    for (int c = 0; c < s.chunk_count; ++c) {
        s.chunk_bounds[size_t(c) * 4U + 0] = inf;
        s.chunk_bounds[size_t(c) * 4U + 1] = inf;
        s.chunk_bounds[size_t(c) * 4U + 2] = -inf;
        s.chunk_bounds[size_t(c) * 4U + 3] = -inf;
    }
    for (int i = 0; i < cell_count; ++i) {
        float *b = s.chunk_bounds.data() + size_t(s.chunk_of(i)) * 4U;
        b[0] = std::min(b[0], s.pos_x[size_t(i)]);
        b[1] = std::min(b[1], s.pos_y[size_t(i)]);
        b[2] = std::max(b[2], s.pos_x[size_t(i)]);
        b[3] = std::max(b[3], s.pos_y[size_t(i)]);
    }

    s.cells.clear();
    s.queue.clear();
    s.in_flight = 0;
    s.chunk_pending.assign(static_cast<size_t>(s.chunk_count), 0);
    s.chunk_instances.assign(static_cast<size_t>(s.chunk_count), 0);
    s.chunk_cells.assign(static_cast<size_t>(s.chunk_count), std::vector<int32_t>());
    s.chunk_ready.assign(static_cast<size_t>(s.chunk_count), 0);
    s.ready_list.clear();
    s.submitted = s.skipped = s.planned = s.stale = 0;
    s.plan_us_total = s.plan_us_max = 0.0;
    s.last_submit_us = s.last_build_us = s.max_build_us = 0.0;
    s.start_worker();

    out["ok"] = true;
    out["chunk_count"] = s.chunk_count;
    return out;
}

godot::Dictionary NativeBuildingVisualCache::submit_cells(const godot::Dictionary &rows) {
    const auto begin = std::chrono::steady_clock::now();
    BuildingVisualCacheState &s = *_state;
    Dictionary out;
    out["ok"] = false;
    PackedInt32Array cells = rows.get("cell_indices", PackedInt32Array());
    PackedInt32Array eras = rows.get("era_indices", PackedInt32Array());
    PackedByteArray water = rows.get("is_water", PackedByteArray());
    PackedInt32Array offsets = rows.get("type_offsets", PackedInt32Array());
    PackedInt32Array types = rows.get("type_indices", PackedInt32Array());
    PackedInt64Array counts = rows.get("type_counts", PackedInt64Array());
    const PackedByteArray social_columns[4] = {
        rows.get("settlement_tiers", PackedByteArray()),
        rows.get("living_levels", PackedByteArray()),
        rows.get("rich_buckets", PackedByteArray()),
        rows.get("poor_buckets", PackedByteArray()),
    };
    const int64_t K = cells.size();
    bool social_ok = true;
    for (const PackedByteArray &column : social_columns) {
        social_ok = social_ok && (column.is_empty() || column.size() >= K);
    }
    if (eras.size() < K || water.size() < K || offsets.size() != K + 1 ||
            types.size() != counts.size() || offsets[0] != 0 ||
            offsets[offsets.size() - 1] != types.size() || !social_ok) {
        out["reason"] = String("building_visual_cache_rows_shape_invalid");
        return out;
    }
    const int32_t *OFF = offsets.ptr();
    for (int64_t i = 0; i < K; ++i) {
        if (OFF[i] > OFF[i + 1]) {
            out["reason"] = String("building_visual_cache_offsets_not_monotonic");
            return out;
        }
    }
    const int32_t *TYPES = types.ptr();
    const int64_t *COUNTS = counts.ptr();
    int accepted = 0;
    int unchanged = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.cell_count <= 0) {
            out["reason"] = String("building_visual_cache_not_configured");
            return out;
        }
        for (int64_t i = 0; i < K; ++i) {
            const int32_t cell = cells[i];
            if (cell < 0 || cell >= s.cell_count) {
                continue;
            }
            const int n = OFF[i + 1] - OFF[i];
            const int32_t era = std::max(0, std::min(10, int(eras[i])));
            const uint8_t wet = water[i] != 0 ? 1 : 0;
            SocialBands social = kUnknownSocial;
            for (size_t col = 0; col < social.size(); ++col) {
                if (!social_columns[col].is_empty()) social[col] = social_columns[col][i];
            }
            const uint64_t hash =
                    cell_input_hash(era, wet, social, TYPES + OFF[i], COUNTS + OFF[i], n);
            auto it = s.cells.find(cell);
            if (it == s.cells.end()) {
                if (n == 0 && !populated(social)) {
                    ++unchanged;
                    continue;
                }
                it = s.cells.emplace(cell, CachedCell()).first;
                std::vector<int32_t> &list = s.chunk_cells[static_cast<size_t>(s.chunk_of(cell))];
                list.insert(std::lower_bound(list.begin(), list.end(), cell), cell);
            }
            CachedCell &c = it->second;
            if (c.has_input && c.input_hash == hash) {
                ++unchanged;
                continue;
            }
            c.has_input = true;
            c.input_hash = hash;
            c.era = era;
            c.water = wet;
            c.social = social;
            c.types.assign(TYPES + OFF[i], TYPES + OFF[i + 1]);
            c.counts.assign(COUNTS + OFF[i], COUNTS + OFF[i + 1]);
            s.bump(cell, c);
            ++accepted;
        }
        s.submitted += accepted;
        s.skipped += unchanged;
        s.last_submit_us = elapsed_us(begin);
        out["queued"] = static_cast<int>(s.queue.size());
    }
    if (accepted > 0) {
        s.work_cv.notify_one();
    }
    out["ok"] = true;
    out["accepted"] = accepted;
    out["unchanged"] = unchanged;
    return out;
}

void NativeBuildingVisualCache::set_quality(int quality) {
    BuildingVisualCacheState &s = *_state;
    const int next = std::max(0, std::min(2, quality));
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (next == s.quality) {
            return;
        }
        s.quality = next;
        for (auto &entry : s.cells) {
            s.bump(entry.first, entry.second);
        }
    }
    s.work_cv.notify_one();
}

godot::PackedInt32Array NativeBuildingVisualCache::take_ready_chunks() {
    BuildingVisualCacheState &s = *_state;
    if constexpr (!kBuildingVisualThreaded) {
        s.plan_queued(std::chrono::steady_clock::now() + std::chrono::microseconds(1500));
    }
    PackedInt32Array out;
    std::lock_guard<std::mutex> lock(s.mutex);
    out.resize(static_cast<int64_t>(s.ready_list.size()));
    for (size_t n = 0; n < s.ready_list.size(); ++n) {
        out.set(static_cast<int64_t>(n), s.ready_list[n]);
        s.chunk_ready[static_cast<size_t>(s.ready_list[n])] = 0;
    }
    s.ready_list.clear();
    return out;
}

godot::PackedInt32Array NativeBuildingVisualCache::chunks_in_rect(const godot::Rect2 &rect,
        const godot::Vector2 &center, int limit) const {
    const BuildingVisualCacheState &s = *_state;
    std::vector<std::pair<float, int32_t>> hits;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        const float x0 = rect.position.x;
        const float y0 = rect.position.y;
        const float x1 = x0 + rect.size.x;
        const float y1 = y0 + rect.size.y;
        const float pad = float(s.hex_size);
        for (int c = 0; c < s.chunk_count; ++c) {
            if (s.chunk_instances[static_cast<size_t>(c)] <= 0) {
                continue;
            }
            const float *b = s.chunk_bounds.data() + size_t(c) * 4U;
            if (b[2] + pad < x0 || b[0] - pad > x1 || b[3] + pad < y0 || b[1] - pad > y1) {
                continue;
            }
            const float dx = 0.5f * (b[0] + b[2]) - center.x;
            const float dy = 0.5f * (b[1] + b[3]) - center.y;
            hits.emplace_back(dx * dx + dy * dy, c);
        }
    }
    std::sort(hits.begin(), hits.end());
    const size_t count = std::min(hits.size(), static_cast<size_t>(std::max(0, limit)));
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(count));
    for (size_t n = 0; n < count; ++n) {
        out.set(static_cast<int64_t>(n), hits[n].second);
    }
    return out;
}

godot::Dictionary NativeBuildingVisualCache::build_chunk(int chunk_id, int instance_cap) const {
    const auto begin = std::chrono::steady_clock::now();
    BuildingVisualCacheState &s = *_state;
    Dictionary out;
    PackedFloat32Array buffer;
    PackedFloat32Array decal_buffer;
    int lots = 0;
    int pending = 0;
    int cell_total = 0;
    size_t body_keep = 0;
    size_t decal_keep = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (chunk_id < 0 || chunk_id >= s.chunk_count) {
            out["ok"] = false;
            out["reason"] = String("building_visual_cache_chunk_out_of_range");
            return out;
        }
        const std::vector<int32_t> &list = s.chunk_cells[static_cast<size_t>(chunk_id)];
        std::vector<float> ranks;
        size_t decal_total = 0;
        for (int32_t cell : list) {
            const CachedCell &c = s.cells.at(cell);
            for (size_t n = 11; n < c.body.size(); n += 16U) {
                ranks.push_back(c.body[n]);
            }
            decal_total += c.decal.size() / 16U;
            lots += c.lots;
        }
        std::vector<uint8_t> keep;
        body_keep = building_visual::select_by_rank(ranks, static_cast<size_t>(std::max(0, instance_cap)), keep);
        decal_keep = std::min(decal_total, static_cast<size_t>(std::max(0, instance_cap)) * 2U);
        buffer.resize(static_cast<int64_t>(body_keep) * 16);
        decal_buffer.resize(static_cast<int64_t>(decal_keep) * 16);
        float *BUF = buffer.ptrw();
        float *DECAL = decal_buffer.ptrw();
        size_t body_index = 0;
        size_t body_written = 0;
        size_t decal_written = 0;
        for (int32_t cell : list) {
            const CachedCell &c = s.cells.at(cell);
            const size_t n_body = c.body.size() / 16U;
            for (size_t n = 0; n < n_body; ++n, ++body_index) {
                if (keep[body_index] != 0) {
                    std::copy_n(c.body.data() + n * 16U, 16, BUF + body_written * 16U);
                    ++body_written;
                }
            }
            const size_t n_decal = std::min(c.decal.size() / 16U, decal_keep - decal_written);
            std::copy_n(c.decal.data(), n_decal * 16U, DECAL + decal_written * 16U);
            decal_written += n_decal;
        }
        pending = s.chunk_pending[static_cast<size_t>(chunk_id)];
        cell_total = static_cast<int>(list.size());
        s.last_build_us = elapsed_us(begin);
        s.max_build_us = std::max(s.max_build_us, s.last_build_us);
    }
    out["ok"] = true;
    out["path"] = String("gdext_building_visual_cache");
    out["instance_count"] = static_cast<int>(body_keep);
    out["decal_instance_count"] = static_cast<int>(decal_keep);
    out["buffer"] = buffer;
    out["decal_buffer"] = decal_buffer;
    out["lot_count"] = lots;
    out["cell_count"] = cell_total;
    out["pending_cells"] = pending;
    out["elapsed_ms"] = elapsed_us(begin) / 1000.0;
    return out;
}

bool NativeBuildingVisualCache::wait_idle(int timeout_msec) {
    BuildingVisualCacheState &s = *_state;
    const auto timeout = std::chrono::milliseconds(std::max(0, timeout_msec));
    if constexpr (!kBuildingVisualThreaded) {
        s.plan_queued(std::chrono::steady_clock::now() + timeout);
        return s.queue.empty();
    }
    std::unique_lock<std::mutex> lock(s.mutex);
    return s.idle_cv.wait_for(lock, timeout,
            [&s] { return s.queue.empty() && s.in_flight == 0; });
}

int NativeBuildingVisualCache::pending_cells() const {
    const BuildingVisualCacheState &s = *_state;
    std::lock_guard<std::mutex> lock(s.mutex);
    return static_cast<int>(s.queue.size()) + s.in_flight;
}

godot::Dictionary NativeBuildingVisualCache::diagnostics() const {
    const BuildingVisualCacheState &s = *_state;
    Dictionary out;
    std::lock_guard<std::mutex> lock(s.mutex);
    out["worker_running"] = s.worker.joinable();
    out["cached_cells"] = static_cast<int>(s.cells.size());
    out["queued_cells"] = static_cast<int>(s.queue.size());
    out["in_flight"] = s.in_flight;
    out["submitted_cells"] = s.submitted;
    out["unchanged_cells"] = s.skipped;
    out["planned_cells"] = s.planned;
    out["stale_plans"] = s.stale;
    out["worker_plan_ms_total"] = s.plan_us_total / 1000.0;
    out["worker_plan_us_avg"] = s.planned > 0 ? s.plan_us_total / double(s.planned) : 0.0;
    out["worker_plan_us_max"] = s.plan_us_max;
    out["last_submit_us"] = s.last_submit_us;
    out["last_build_us"] = s.last_build_us;
    out["max_build_us"] = s.max_build_us;
    out["quality"] = s.quality;
    out["chunk_count"] = s.chunk_count;
    return out;
}

void NativeBuildingVisualCache::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "config"), &NativeBuildingVisualCache::configure);
    ClassDB::bind_method(D_METHOD("submit_cells", "rows"), &NativeBuildingVisualCache::submit_cells);
    ClassDB::bind_method(D_METHOD("set_quality", "quality"), &NativeBuildingVisualCache::set_quality);
    ClassDB::bind_method(D_METHOD("take_ready_chunks"), &NativeBuildingVisualCache::take_ready_chunks);
    ClassDB::bind_method(D_METHOD("chunks_in_rect", "rect", "center", "limit"),
            &NativeBuildingVisualCache::chunks_in_rect);
    ClassDB::bind_method(D_METHOD("build_chunk", "chunk_id", "instance_cap"),
            &NativeBuildingVisualCache::build_chunk);
    ClassDB::bind_method(D_METHOD("wait_idle", "timeout_msec"), &NativeBuildingVisualCache::wait_idle);
    ClassDB::bind_method(D_METHOD("pending_cells"), &NativeBuildingVisualCache::pending_cells);
    ClassDB::bind_method(D_METHOD("diagnostics"), &NativeBuildingVisualCache::diagnostics);
    ClassDB::bind_method(D_METHOD("shutdown"), &NativeBuildingVisualCache::shutdown);
}
