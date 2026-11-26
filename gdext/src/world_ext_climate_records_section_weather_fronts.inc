Dictionary DCWorldExt::run_weather_summary_fronts_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;
    using godot::Vector2;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fronts"] = Array();

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_summary_fronts_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return out; }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── knobs ─────────────────────────────────────────────────────────
    static const char * const required_keys[] = {
        "n_cells", "hex_size", "summary_limit",
        "intensity_enter", "intensity_hold",
        "merge_ratio", "merge_max_rounds",
        "radius_base", "radius_scale",
        "wt_clear", "cell_q_arr", "cell_r_arr",
        "neighbor_indices",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_summary_fronts_pass: missing key '", k, "'");
            return out;
        }
    }

    const int   n_cells          = int(knobs["n_cells"]);
    const float hex_size         = float(knobs["hex_size"]);
    const int   summary_limit    = int(knobs["summary_limit"]);
    const float intensity_enter  = float(knobs["intensity_enter"]);
    const float intensity_hold   = float(knobs["intensity_hold"]);
    const float merge_ratio      = float(knobs["merge_ratio"]);
    const int   merge_max_rounds = int(knobs["merge_max_rounds"]);
    const float radius_base      = float(knobs["radius_base"]);
    const float radius_scale     = float(knobs["radius_scale"]);
    const int   wt_clear         = int(knobs["wt_clear"]);
    PackedInt32Array cell_q = knobs["cell_q_arr"];
    PackedInt32Array cell_r = knobs["cell_r_arr"];

    if (n_cells <= 0) { diag("n_cells <= 0"); return out; }
    if (cell_q.size() != n_cells || cell_r.size() != n_cells) {
        diag("cell_q_arr / cell_r_arr size mismatch");
        return out;
    }

    // ─── SoA slot resolve ──────────────────────────────────────────────
    const int sid_w_intens  = component_id(StringName("cell_weather_intensity"));
    const int sid_w_precip  = component_id(StringName("cell_weather_precip"));
    const int sid_w_type    = component_id(StringName("cell_weather_type"));
    const int sid_w_cloud   = component_id(StringName("cell_weather_cloud"));
    const int sid_w_finit   = component_id(StringName("cell_weather_field_init"));
    const int sid_wind_x    = component_id(StringName("cell_wind_x"));
    const int sid_wind_y    = component_id(StringName("cell_wind_y"));
    const int sid_temp      = component_id(StringName("cell_temp"));
    if (sid_w_intens < 0 || sid_w_precip < 0 || sid_w_type < 0 ||
        sid_w_cloud  < 0 || sid_w_finit  < 0 || sid_wind_x < 0 || sid_wind_y < 0 ||
        sid_temp < 0) {
        diag("missing slot id (weather_*/wind_x/wind_y/cell_temp)");
        return out;
    }
    const Slot &s_w_int   = _slots[sid_w_intens];
    const Slot &s_w_pre   = _slots[sid_w_precip];
    const Slot &s_w_typ   = _slots[sid_w_type];
    const Slot &s_w_cloud = _slots[sid_w_cloud];
    const Slot &s_w_fin   = _slots[sid_w_finit];
    const Slot &s_wind_x  = _slots[sid_wind_x];
    const Slot &s_wind_y  = _slots[sid_wind_y];
    const Slot &s_temp    = _slots[sid_temp];
    if (s_w_int.arr_f32.size()  < n_cells || s_w_pre.arr_f32.size() < n_cells ||
        s_w_typ.arr_u8.size()   < n_cells || s_w_cloud.arr_f32.size() < n_cells ||
        s_w_fin.arr_u8.size()   < n_cells || s_wind_x.arr_f32.size() < n_cells ||
        s_wind_y.arr_f32.size() < n_cells || s_temp.arr_f32.size() < n_cells) {
        diag("SoA size < n_cells");
        return out;
    }
    const float * const __restrict WI    = s_w_int.arr_f32.ptr();
    const float * const __restrict WP    = s_w_pre.arr_f32.ptr();
    const uint8_t * const __restrict WT_ = s_w_typ.arr_u8.ptr();
    const float * const __restrict WCL   = s_w_cloud.arr_f32.ptr();
    const uint8_t * const __restrict WFI = s_w_fin.arr_u8.ptr();
    const float * const __restrict WX    = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY    = s_wind_y.arr_f32.ptr();
    const float * const __restrict T     = s_temp.arr_f32.ptr();

    // ─── neighbor_indices (n_cells*6, -1 = no neighbor) ────────────────
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells*6");
        return out;
    }
    const int32_t * const __restrict NB = nb_arr.ptr();

    // ─── q/r → idx hash (lazy rebuild on size change) ──────────────────
    if (_summary_qr_to_idx_size != n_cells) {
        _summary_qr_to_idx.clear();
        _summary_qr_to_idx.reserve(n_cells * 2);
        for (int i = 0; i < n_cells; ++i) {
            const int64_t key = (int64_t(cell_q[i]) << 32) ^
                                (uint32_t(cell_r[i]) & 0xFFFFFFFFu);
            _summary_qr_to_idx[key] = i;
        }
        _summary_qr_to_idx_size = n_cells;
    }
    auto cube_to_idx = [&](int q, int r) -> int {
        const int64_t key = (int64_t(q) << 32) ^ (uint32_t(r) & 0xFFFFFFFFu);
        auto it = _summary_qr_to_idx.find(key);
        return (it == _summary_qr_to_idx.end()) ? -1 : it->second;
    };
    // Pointy-top hex 屏幕坐标（与 hex_utils.gd 严格同源）
    const double SQRT3 = 1.7320508075688772;
    auto cube_to_world_xy = [&](int q, int r) -> Vector2 {
        const double x = double(hex_size) * SQRT3 * (double(q) + double(r) * 0.5);
        const double y = double(hex_size) * 1.5 * double(r);
        return Vector2(float(x), float(y));
    };
    auto world_to_cube_idx = [&](Vector2 p) -> int {
        const double q_f = (SQRT3 / 3.0 * double(p.x) - 1.0 / 3.0 * double(p.y)) / double(hex_size);
        const double r_f = (2.0 / 3.0 * double(p.y)) / double(hex_size);
        const double s_f = -q_f - r_f;
        // _cube_round
        int rq = int(std::lround(q_f));
        int rr = int(std::lround(r_f));
        int rs = int(std::lround(s_f));
        const double dq = std::abs(double(rq) - q_f);
        const double dr = std::abs(double(rr) - r_f);
        const double ds = std::abs(double(rs) - s_f);
        if (dq > dr && dq > ds) {
            rq = -rr - rs;
        } else if (dr > ds) {
            rr = -rq - rs;
        }
        return cube_to_idx(rq, rr);
    };
    auto neighbor_aligned_idx = [&](int idx, float dir_x, float dir_y) -> int {
        const float len2 = dir_x * dir_x + dir_y * dir_y;
        if (idx < 0 || idx >= n_cells || len2 <= 0.0001f) {
            return -1;
        }
        const float inv_len = 1.0f / std::sqrt(len2);
        const float nx = dir_x * inv_len;
        const float ny = dir_y * inv_len;
        const Vector2 self_wp = cube_to_world_xy(cell_q[idx], cell_r[idx]);
        float best_dot = hex_size * 0.31176915f;
        int best_idx = -1;
        const int32_t *nb_row = NB + idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb = nb_row[d];
            if (nb < 0 || nb >= n_cells) continue;
            const Vector2 nb_wp = cube_to_world_xy(cell_q[nb], cell_r[nb]);
            const Vector2 to_nb = nb_wp - self_wp;
            const float dot = to_nb.x * nx + to_nb.y * ny;
            if (dot > best_dot) {
                best_dot = dot;
                best_idx = nb;
            }
        }
        return best_idx;
    };
    auto front_diag_kind = [](float temp_adv) -> int {
        constexpr float FRONT_TEMP_ADVECTION_THRESHOLD = 0.015f;
        if (temp_adv > FRONT_TEMP_ADVECTION_THRESHOLD) return 1;
        if (temp_adv < -FRONT_TEMP_ADVECTION_THRESHOLD) return 2;
        return 0;
    };

    // ─── opaque state ──────────────────────────────────────────────────
    auto *summary_state = get_or_create_summary_state(_summary_state);
    std::vector<PrevSummarySeed> &prev_seeds = summary_state->prev_seeds;
    std::vector<int32_t> &prev_membership = summary_state->prev_membership;
    if (int(prev_membership.size()) != n_cells) {
        prev_membership.assign(n_cells, -1);
    }

    // ─── 工作结构 ──────────────────────────────────────────────────────
    struct Comp {
        int   type;
        Vector2 sum_pos;       // build 时 / sum_pos*count
        Vector2 sum_axis;
        float sum_cloud;
        float sum_precip;
        float sum_temp_adv;
        float temp_adv_weight;
        float max_intensity;
        float area;            // 用 float 因为 merge 后会聚合权重
        int   inherited_age;   // -1 表示 step 2 新生
        bool  has_inherited_center;
        Vector2 inherited_from_center;
        Vector2 inherited_from_velocity;
    };
    std::vector<Comp> comps;
    comps.reserve(64);

    std::vector<uint8_t> visited(n_cells, 0);
    std::vector<int32_t> new_membership(n_cells, -1);

    auto threshold_for = [&](int idx) -> float {
        return prev_membership[idx] >= 0 ? intensity_hold : intensity_enter;
    };
    auto cell_wt = [&](int idx) -> int {
        return WFI[idx] != 0 ? int(WT_[idx]) : wt_clear;
    };
    auto cell_intensity = [&](int idx) -> float {
        return WFI[idx] != 0 ? WI[idx] : 0.0f;
    };

    // BFS flood-fill：返回新增 component idx，cells 为空则不入。
    std::vector<int32_t> bfs_queue;
    bfs_queue.reserve(256);
    auto flood_fill = [&](int seed, int wt, int cluster_idx) -> bool {
        bfs_queue.clear();
        bfs_queue.push_back(seed);
        visited[seed] = 1;
        Comp comp;
        comp.type = wt;
        comp.sum_pos = Vector2();
        comp.sum_axis = Vector2();
        comp.sum_cloud = 0.0f;
        comp.sum_precip = 0.0f;
        comp.sum_temp_adv = 0.0f;
        comp.temp_adv_weight = 0.0f;
        comp.max_intensity = 0.0f;
        comp.area = 0.0f;
        comp.inherited_age = 0;
        comp.has_inherited_center = false;
        size_t qi = 0;
        while (qi < bfs_queue.size()) {
            int idx = bfs_queue[qi++];
            const int cwt = cell_wt(idx);
            const float ci = cell_intensity(idx);
            const float thresh_self = threshold_for(idx);
            if (cwt != wt || ci < thresh_self) {
                continue;
            }
            // 加入 cluster
            new_membership[idx] = cluster_idx;
            comp.sum_pos += cube_to_world_xy(cell_q[idx], cell_r[idx]);
            comp.sum_axis += Vector2(WX[idx], WY[idx]);
            comp.sum_cloud += WCL[idx];
            comp.sum_precip += WP[idx];
            const float wx = WX[idx];
            const float wy = WY[idx];
            if ((wx * wx + wy * wy) > 0.0001f) {
                const int upstream = neighbor_aligned_idx(idx, -wx, -wy);
                const int downstream = neighbor_aligned_idx(idx, wx, wy);
                if (downstream >= 0) {
                    const float upstream_temp = (upstream >= 0) ? T[upstream] : T[idx];
                    const float local_adv = upstream_temp - T[downstream];
                    comp.sum_temp_adv += local_adv * ci;
                    comp.temp_adv_weight += ci;
                }
            }
            if (ci > comp.max_intensity) comp.max_intensity = ci;
            comp.area += 1.0f;
            // 邻居
            const int32_t *nb_row = NB + idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb = nb_row[d];
                if (nb < 0 || visited[nb]) continue;
                const int nwt = cell_wt(nb);
                const float ni = cell_intensity(nb);
                const float thresh_nb = threshold_for(nb);
                if (nwt == wt && ni >= thresh_nb) {
                    visited[nb] = 1;
                    bfs_queue.push_back(nb);
                }
            }
        }
        if (comp.area <= 0.0f) {
            return false;
        }
        comp.sum_pos = comp.sum_pos / comp.area;
        comp.sum_axis = comp.sum_axis / comp.area;
        comp.sum_cloud /= comp.area;
        comp.sum_precip /= comp.area;
        comp.sum_temp_adv /= std::max(comp.temp_adv_weight, 0.001f);
        comps.push_back(comp);
        return true;
    };

    // ─── Step 1：prev seeds 优先（按 area 降序，与 GDScript 一致）──────
    std::vector<size_t> seed_order(prev_seeds.size());
    for (size_t i = 0; i < seed_order.size(); ++i) seed_order[i] = i;
    std::sort(seed_order.begin(), seed_order.end(), [&](size_t a, size_t b) {
        return prev_seeds[a].area > prev_seeds[b].area;
    });
    auto pick_inheritance_seed = [&](int seed_idx, int prev_type) -> int {
        // 1. seed_idx 本身可用？
        if (!visited[seed_idx]) {
            const int swt = cell_wt(seed_idx);
            const float si = cell_intensity(seed_idx);
            const float s_thresh = threshold_for(seed_idx);
            if (swt == prev_type && si >= s_thresh) return seed_idx;
        }
        // 2. 1-ring 邻居
        const int32_t *nb_row = NB + seed_idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb = nb_row[d];
            if (nb < 0 || visited[nb]) continue;
            const int nwt = cell_wt(nb);
            const float ni = cell_intensity(nb);
            const float thresh_nb = threshold_for(nb);
            if (nwt == prev_type && ni >= thresh_nb) return nb;
        }
        return -1;
    };
    for (size_t k : seed_order) {
        const PrevSummarySeed &ps = prev_seeds[k];
        const int seed_idx = world_to_cube_idx(Vector2(ps.center_x, ps.center_y));
        if (seed_idx < 0) continue;
        const int picked = pick_inheritance_seed(seed_idx, ps.type);
        if (picked < 0) continue;
        const int cluster_idx = int(comps.size());
        if (flood_fill(picked, ps.type, cluster_idx)) {
            Comp &c = comps.back();
            c.inherited_age = ps.age + 1;
            c.has_inherited_center = true;
            c.inherited_from_center = Vector2(ps.center_x, ps.center_y);
            c.inherited_from_velocity = Vector2(ps.velocity_x, ps.velocity_y);
        }
    }

    // ─── Step 2：剩余 cell 自起新 cluster ─────────────────────────────
    for (int i = 0; i < n_cells; ++i) {
        if (visited[i]) continue;
        const int wt = cell_wt(i);
        const float ci = cell_intensity(i);
        const float thresh = threshold_for(i);
        if (ci < thresh || wt == wt_clear) {
            visited[i] = 1;
            continue;
        }
        const int cluster_idx = int(comps.size());
        if (flood_fill(i, wt, cluster_idx)) {
            comps.back().inherited_age = 0;
        }
    }

    // 跨 tick 状态：在 merge 之前记录 cell→cluster 归属（与 GDScript 一致）。
    prev_membership = new_membership;

    // ─── Step 3：merge_nearby_components ───────────────────────────────
    auto eq_radius = [&](float area) -> float {
        return hex_size * std::sqrt(std::max(area, 1.0f)) * radius_scale;
    };
    bool changed = true;
    int rounds = 0;
    while (changed && rounds < merge_max_rounds) {
        changed = false;
        rounds += 1;
        const int n = int(comps.size());
        std::vector<int32_t> merged_into(n, -1);
        for (int i = 0; i < n; ++i) {
            if (merged_into[i] >= 0) continue;
            float ai = comps[i].area;
            float ri = eq_radius(ai);
            Vector2 ci_center = comps[i].sum_pos;
            const int type_i = comps[i].type;
            for (int j = i + 1; j < n; ++j) {
                if (merged_into[j] >= 0) continue;
                if (comps[j].type != type_i) continue;
                const float aj = comps[j].area;
                const float rj = eq_radius(aj);
                const Vector2 cj_center = comps[j].sum_pos;
                const float dist = ci_center.distance_to(cj_center);
                if (dist > (ri + rj) * merge_ratio) continue;
                // merge j → i
                const float total = ai + aj;
                comps[i].sum_pos = (ci_center * ai + cj_center * aj) / total;
                comps[i].sum_axis = (comps[i].sum_axis * ai + comps[j].sum_axis * aj) / total;
                comps[i].sum_cloud = (comps[i].sum_cloud * ai + comps[j].sum_cloud * aj) / total;
                comps[i].sum_precip = (comps[i].sum_precip * ai + comps[j].sum_precip * aj) / total;
                comps[i].sum_temp_adv = (comps[i].sum_temp_adv * ai + comps[j].sum_temp_adv * aj) / total;
                comps[i].max_intensity = std::max(comps[i].max_intensity, comps[j].max_intensity);
                comps[i].area = total;
                comps[i].inherited_age = std::max(comps[i].inherited_age, comps[j].inherited_age);
                // GDScript 用先合的"老" component 保留 inherited_from_*；这里保持 i 的字段不动
                // （与 GDScript 同：i 在前，j 在后，j 被吸收到 i）。
                ai = total;
                ri = eq_radius(ai);
                ci_center = comps[i].sum_pos;
                merged_into[j] = i;
                changed = true;
            }
        }
        if (changed) {
            std::vector<Comp> next;
            next.reserve(comps.size());
            for (int i = 0; i < n; ++i) {
                if (merged_into[i] < 0) next.push_back(std::move(comps[i]));
            }
            comps = std::move(next);
        }
    }

    // ─── Step 4：score 排序 + top-N + build front Dictionary ──────────
    auto score_of = [](const Comp &c) -> float {
        return c.max_intensity * std::sqrt(std::max(c.area, 1.0f));
    };
    std::sort(comps.begin(), comps.end(), [&](const Comp &a, const Comp &b) {
        return score_of(a) > score_of(b);
    });
    const int limit = std::min(summary_limit, int(comps.size()));
    Array fronts_out;
    fronts_out.resize(limit);
    std::vector<PrevSummarySeed> next_seeds;
    next_seeds.reserve(limit);

    // ─── Phase A.1 fronts zero-copy SoA：与 fronts 数组并存输出 ─────
    // 字段命名严格沿用 scripts/data_core/fronts_schema.gd FRONTS_SCHEMA cpp_name
    // 共 23 列：18 F32 + 4 I32 + 1 U8。所有列长度=limit，按 idx 与 fronts_out[i]
    // 1:1 对齐。GDScript 端 _unpack_summary_soa_to_fronts 走列扫描，跨语言
    // Variant entry 从 ~17*N → ~24 ref（与 N 无关），marshalling ~90% 削减。
    PackedFloat32Array soa_center_x;        soa_center_x.resize(limit);
    PackedFloat32Array soa_center_y;        soa_center_y.resize(limit);
    PackedFloat32Array soa_radius;          soa_radius.resize(limit);
    PackedFloat32Array soa_velocity_x;      soa_velocity_x.resize(limit);
    PackedFloat32Array soa_velocity_y;      soa_velocity_y.resize(limit);
    PackedFloat32Array soa_axis_x;          soa_axis_x.resize(limit);
    PackedFloat32Array soa_axis_y;          soa_axis_y.resize(limit);
    PackedFloat32Array soa_stable_axis_x;   soa_stable_axis_x.resize(limit);
    PackedFloat32Array soa_stable_axis_y;   soa_stable_axis_y.resize(limit);
    PackedFloat32Array soa_major_scale;     soa_major_scale.resize(limit);
    PackedFloat32Array soa_minor_scale;     soa_minor_scale.resize(limit);
    PackedFloat32Array soa_edge_seed;       soa_edge_seed.resize(limit);
    PackedFloat32Array soa_intensity;       soa_intensity.resize(limit);
    PackedFloat32Array soa_decay_per_day;   soa_decay_per_day.resize(limit);
    PackedFloat32Array soa_life_progress;   soa_life_progress.resize(limit);
    PackedFloat32Array soa_cloud_amount;    soa_cloud_amount.resize(limit);
    PackedFloat32Array soa_precip_amount;   soa_precip_amount.resize(limit);
    PackedFloat32Array soa_dissolve_amount; soa_dissolve_amount.resize(limit);
    PackedFloat32Array soa_temp_advection;  soa_temp_advection.resize(limit);
    PackedInt32Array   soa_type;            soa_type.resize(limit);
    PackedInt32Array   soa_ttl_days;        soa_ttl_days.resize(limit);
    PackedInt32Array   soa_age_days;        soa_age_days.resize(limit);
    PackedInt32Array   soa_world_idx;       soa_world_idx.resize(limit);
    PackedInt32Array   soa_diag_kind;       soa_diag_kind.resize(limit);
    PackedByteArray    soa_alive;           soa_alive.resize(limit);
    float *p_center_x = soa_center_x.ptrw();
    float *p_center_y = soa_center_y.ptrw();
    float *p_radius = soa_radius.ptrw();
    float *p_velocity_x = soa_velocity_x.ptrw();
    float *p_velocity_y = soa_velocity_y.ptrw();
    float *p_axis_x = soa_axis_x.ptrw();
    float *p_axis_y = soa_axis_y.ptrw();
    float *p_stable_axis_x = soa_stable_axis_x.ptrw();
    float *p_stable_axis_y = soa_stable_axis_y.ptrw();
    float *p_major_scale = soa_major_scale.ptrw();
    float *p_minor_scale = soa_minor_scale.ptrw();
    float *p_edge_seed = soa_edge_seed.ptrw();
    float *p_intensity = soa_intensity.ptrw();
    float *p_decay_per_day = soa_decay_per_day.ptrw();
    float *p_life_progress = soa_life_progress.ptrw();
    float *p_cloud_amount = soa_cloud_amount.ptrw();
    float *p_precip_amount = soa_precip_amount.ptrw();
    float *p_dissolve_amount = soa_dissolve_amount.ptrw();
    float *p_temp_advection = soa_temp_advection.ptrw();
    int32_t *p_type = soa_type.ptrw();
    int32_t *p_ttl_days = soa_ttl_days.ptrw();
    int32_t *p_age_days = soa_age_days.ptrw();
    int32_t *p_world_idx = soa_world_idx.ptrw();
    int32_t *p_diag_kind = soa_diag_kind.ptrw();
    uint8_t *p_alive = soa_alive.ptrw();

    for (int i = 0; i < limit; ++i) {
        const Comp &c = comps[i];
        Dictionary fd;
        fd["type"] = int(c.type);
        fd["center"] = c.sum_pos;
        const float intensity = std::clamp(c.max_intensity, 0.0f, 1.0f);
        fd["intensity"] = intensity;
        const float area = std::max(c.area, 1.0f);
        const float radius = hex_size * (radius_base + std::sqrt(area) * radius_scale);
        fd["radius"] = radius;
        Vector2 axis_v = c.sum_axis;
        if (axis_v.length_squared() <= 0.0001f) {
            axis_v = Vector2(1.0f, 0.0f);
        }
        const Vector2 axis = axis_v.normalized();
        fd["axis"] = axis;
        fd["stable_axis"] = axis;
        // velocity = (inherited 模式) EMA(prev_velocity, observed_drift, 0.5)
        //            (新生 模式)     axis * radius * 0.4
        Vector2 measured_velocity = axis * radius * 0.4f;
        if (c.has_inherited_center) {
            Vector2 observed_drift = c.sum_pos - c.inherited_from_center;
            const float max_drift = radius * 0.6f;
            if (observed_drift.length() > max_drift) {
                observed_drift = observed_drift.normalized() * max_drift;
            }
            measured_velocity = c.inherited_from_velocity.lerp(observed_drift, 0.5f);
        }
        fd["velocity"] = measured_velocity;
        fd["major_scale"] = 1.30f;
        fd["minor_scale"] = 0.85f;
        const int inherited_age = std::max(c.inherited_age, 0);
        fd["age_days"] = inherited_age;
        const int ttl_days_v = std::max(inherited_age * 3 + 12, 12);
        fd["ttl_days"] = ttl_days_v;
        fd["decay_per_day"] = 0.0f;
        // edge_seed = (i+1)*37 + int(center.x)*3 + int(center.y)*5
        const float edge_seed = float((i + 1) * 37 +
                                       int(c.sum_pos.x) * 3 +
                                       int(c.sum_pos.y) * 5);
        fd["edge_seed"] = edge_seed;
        const float cloud_amount = std::clamp(c.sum_cloud, 0.0f, 1.0f);
        const float precip_amount = std::clamp(c.sum_precip, 0.0f, 1.0f);
        fd["cloud_amount"] = cloud_amount;
        fd["precip_amount"] = precip_amount;
        fd["dissolve_amount"] = 0.0f;
        // life_progress = clamp(0.15 + age*0.08, 0.15, 0.45)
        const float life_progress = std::clamp(0.15f + float(inherited_age) * 0.08f, 0.15f, 0.45f);
        fd["life_progress"] = life_progress;
        const float temp_advection = c.sum_temp_adv;
        const int diag_kind = front_diag_kind(temp_advection);
        fd["front_temperature_advection"] = temp_advection;
        fd["front_diagnostic_kind"] = diag_kind;
        fronts_out[i] = fd;

        // ─── SoA 镜像写入（与 fd 同语义/同步序）──
        // alive 与 WeatherFront::is_alive() 等价：intensity > 0.01 && age_days < ttl_days
        p_center_x[i]        = c.sum_pos.x;
        p_center_y[i]        = c.sum_pos.y;
        p_radius[i]          = radius;
        p_velocity_x[i]      = measured_velocity.x;
        p_velocity_y[i]      = measured_velocity.y;
        p_axis_x[i]          = axis.x;
        p_axis_y[i]          = axis.y;
        p_stable_axis_x[i]   = axis.x;
        p_stable_axis_y[i]   = axis.y;
        p_major_scale[i]     = 1.30f;
        p_minor_scale[i]     = 0.85f;
        p_edge_seed[i]       = edge_seed;
        p_intensity[i]       = intensity;
        p_decay_per_day[i]   = 0.0f;
        p_life_progress[i]   = life_progress;
        p_cloud_amount[i]    = cloud_amount;
        p_precip_amount[i]   = precip_amount;
        p_dissolve_amount[i] = 0.0f;
        p_temp_advection[i]  = temp_advection;
        p_type[i]            = int32_t(c.type);
        p_ttl_days[i]        = int32_t(ttl_days_v);
        p_age_days[i]        = int32_t(inherited_age);
        p_world_idx[i]       = -1;  // 由 sync job 后续填写
        p_diag_kind[i]       = int32_t(diag_kind);
        p_alive[i]           = (intensity > 0.01f && inherited_age < ttl_days_v) ? uint8_t(1) : uint8_t(0);

        // next_seeds
        PrevSummarySeed ns;
        ns.type = c.type;
        ns.center_x = c.sum_pos.x;
        ns.center_y = c.sum_pos.y;
        ns.age = inherited_age;
        ns.area = int(area);
        ns.velocity_x = measured_velocity.x;
        ns.velocity_y = measured_velocity.y;
        next_seeds.push_back(ns);
    }
    prev_seeds = std::move(next_seeds);

    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed;
    out["fronts"] = fronts_out;

    // ─── Phase A.1：填 fronts_soa Dictionary 并挂回 out ─────────
    Dictionary soa;
    soa["n_fronts"] = limit;
    soa["front_center_x"]        = soa_center_x;
    soa["front_center_y"]        = soa_center_y;
    soa["front_radius"]          = soa_radius;
    soa["front_velocity_x"]      = soa_velocity_x;
    soa["front_velocity_y"]      = soa_velocity_y;
    soa["front_axis_x"]          = soa_axis_x;
    soa["front_axis_y"]          = soa_axis_y;
    soa["front_stable_axis_x"]   = soa_stable_axis_x;
    soa["front_stable_axis_y"]   = soa_stable_axis_y;
    soa["front_major_scale"]     = soa_major_scale;
    soa["front_minor_scale"]     = soa_minor_scale;
    soa["front_edge_seed"]       = soa_edge_seed;
    soa["front_intensity"]       = soa_intensity;
    soa["front_decay_per_day"]   = soa_decay_per_day;
    soa["front_life_progress"]   = soa_life_progress;
    soa["front_cloud_amount"]    = soa_cloud_amount;
    soa["front_precip_amount"]   = soa_precip_amount;
    soa["front_dissolve_amount"] = soa_dissolve_amount;
    soa["front_temperature_advection"] = soa_temp_advection;
    soa["front_type"]            = soa_type;
    soa["front_ttl_days"]        = soa_ttl_days;
    soa["front_age_days"]        = soa_age_days;
    soa["front_world_idx"]       = soa_world_idx;
    soa["front_diagnostic_kind"] = soa_diag_kind;
    soa["front_alive"]           = soa_alive;
    out["fronts_soa"] = soa;
    return out;
}

void DCWorldExt::reset_weather_summary_state() {
    if (_summary_state == nullptr) {
        return;
    }
    auto *s = static_cast<WeatherSummaryState *>(_summary_state);
    s->prev_seeds.clear();
    s->prev_membership.clear();
}

void DCWorldExt::snapshot_weather_summary_state() {
    auto *src = get_or_create_summary_state(_summary_state);
    auto *dst = get_or_create_summary_state(_summary_state_snapshot);
    dst->prev_seeds = src->prev_seeds;
    dst->prev_membership = src->prev_membership;
}

void DCWorldExt::restore_weather_summary_state() {
    if (_summary_state_snapshot == nullptr) {
        return;
    }
    auto *src = static_cast<WeatherSummaryState *>(_summary_state_snapshot);
    auto *dst = get_or_create_summary_state(_summary_state);
    dst->prev_seeds = src->prev_seeds;
    dst->prev_membership = src->prev_membership;
}
