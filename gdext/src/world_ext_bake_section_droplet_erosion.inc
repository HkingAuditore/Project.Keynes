// 用 Ref<RandomNumberGenerator>（同 seed 复刻 baker _rng PCG）。in/out height，内部 clamp。
godot::Dictionary DCWorldExt::run_bake_erosion_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;
    using godot::RandomNumberGenerator;
    using godot::Ref;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");
    PackedFloat32Array src = knobs.get("height_buffer", PackedFloat32Array());
    if (src.size() < n) return fail("height buffer too small");

    const int seed = int(knobs.get("seed", 0));
    const int num_drops = int(knobs.get("num_drops", 0));
    const int max_steps = int(knobs.get("max_steps", 0));
    const double inertia = double(knobs.get("inertia", 0.10));
    const double capacity_factor = double(knobs.get("capacity_factor", 1.5));
    const double min_capacity = double(knobs.get("min_capacity", 0.01));
    const double deposit_speed = double(knobs.get("deposit_speed", 0.30));
    const double erode_speed = double(knobs.get("erode_speed", 0.10));
    const double evaporation = double(knobs.get("evaporation", 0.025));
    const double gravity = double(knobs.get("gravity", 4.0));
    const int brush_radius = int(knobs.get("brush_radius", 2));

    PackedFloat32Array height_out;
    height_out.resize(n);
    {
        const float * const __restrict S = src.ptr();
        float * const __restrict D = height_out.ptrw();
        for (int i = 0; i < n; ++i) D[i] = S[i];
    }
    float * const __restrict HT = height_out.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    if (num_drops > 0) {
        // ── brush kernel（镜像 GDScript 预计算）──
        std::vector<int> brush_dx, brush_dy;
        std::vector<double> brush_w;
        double sum_w = 0.0;
        const int br_sq = brush_radius * brush_radius;
        for (int dy = -brush_radius; dy <= brush_radius; ++dy) {
            for (int dx = -brush_radius; dx <= brush_radius; ++dx) {
                const int d_sq = dx * dx + dy * dy;
                if (d_sq > br_sq) continue;
                const double wv = 1.0 - std::sqrt(double(d_sq)) / double(brush_radius);
                brush_dx.push_back(dx);
                brush_dy.push_back(dy);
                brush_w.push_back(wv);
                sum_w += wv;
            }
        }
        const int brush_count = int(brush_w.size());
        if (sum_w > 0.0) {
            const double inv_sum = 1.0 / sum_w;
            for (int i = 0; i < brush_count; ++i) brush_w[i] *= inv_sum;
        }

        Ref<RandomNumberGenerator> rng;  rng.instantiate();
        if (rng.is_null()) return fail("rng_instantiate_failed");
        rng->set_seed(uint64_t(seed));

        const double W_f = double(w);
        const double H_f = double(h);
        static const double PK_TAU = 6.283185307179586232;

        for (int drop_idx = 0; drop_idx < num_drops; ++drop_idx) {
            double pos_x = rng->randf_range(1.0, W_f - 2.0);
            double pos_y = rng->randf_range(1.0, H_f - 2.0);
            double dir_x = 0.0, dir_y = 0.0;
            double speed = 1.0, water = 1.0, sediment = 0.0;

            for (int step = 0; step < max_steps; ++step) {
                const int node_x = int(std::floor(pos_x));
                const int node_y = int(std::floor(pos_y));
                if (node_x < 0 || node_x >= w - 1 || node_y < 0 || node_y >= h - 1) break;
                const double cell_offset_x = pos_x - double(node_x);
                const double cell_offset_y = pos_y - double(node_y);
                const double one_minus_x = 1.0 - cell_offset_x;
                const double one_minus_y = 1.0 - cell_offset_y;

                const int idx_00 = node_y * w + node_x;
                const int idx_10 = idx_00 + 1;
                const int idx_01 = idx_00 + w;
                const int idx_11 = idx_01 + 1;

                const double h00 = double(HT[idx_00]);
                const double h10 = double(HT[idx_10]);
                const double h01 = double(HT[idx_01]);
                const double h11 = double(HT[idx_11]);

                const double h_old = h00 * one_minus_x * one_minus_y
                        + h10 * cell_offset_x * one_minus_y
                        + h01 * one_minus_x * cell_offset_y
                        + h11 * cell_offset_x * cell_offset_y;
                const double grad_x = (h10 - h00) * one_minus_y + (h11 - h01) * cell_offset_y;
                const double grad_y = (h01 - h00) * one_minus_x + (h11 - h10) * cell_offset_x;

                dir_x = dir_x * inertia - grad_x * (1.0 - inertia);
                dir_y = dir_y * inertia - grad_y * (1.0 - inertia);
                const double dir_len_sq = dir_x * dir_x + dir_y * dir_y;
                if (dir_len_sq < 0.000001) {
                    const double ang = rng->randf_range(0.0, PK_TAU);
                    dir_x = std::cos(ang);
                    dir_y = std::sin(ang);
                } else {
                    const double inv_len = 1.0 / std::sqrt(dir_len_sq);
                    dir_x *= inv_len;
                    dir_y *= inv_len;
                }

                const double new_pos_x = pos_x + dir_x;
                const double new_pos_y = pos_y + dir_y;
                if (new_pos_x < 1.0 || new_pos_x >= W_f - 1.0 || new_pos_y < 1.0 || new_pos_y >= H_f - 1.0) {
                    if (sediment > 0.0) {
                        HT[idx_00] += float(sediment * one_minus_x * one_minus_y);
                        HT[idx_10] += float(sediment * cell_offset_x * one_minus_y);
                        HT[idx_01] += float(sediment * one_minus_x * cell_offset_y);
                        HT[idx_11] += float(sediment * cell_offset_x * cell_offset_y);
                    }
                    break;
                }

                const int nnx = int(std::floor(new_pos_x));
                const int nny = int(std::floor(new_pos_y));
                const double ncx = new_pos_x - double(nnx);
                const double ncy = new_pos_y - double(nny);
                const int nidx00 = nny * w + nnx;
                const double h_new = double(HT[nidx00]) * (1.0 - ncx) * (1.0 - ncy)
                        + double(HT[nidx00 + 1]) * ncx * (1.0 - ncy)
                        + double(HT[nidx00 + w]) * (1.0 - ncx) * ncy
                        + double(HT[nidx00 + w + 1]) * ncx * ncy;
                const double delta_h = h_new - h_old;
                const double capacity = std::max(-delta_h, min_capacity) * speed * water * capacity_factor;

                if (sediment > capacity || delta_h > 0.0) {
                    double deposit_amt;
                    if (delta_h > 0.0) deposit_amt = std::min(delta_h, sediment);
                    else deposit_amt = (sediment - capacity) * deposit_speed;
                    sediment -= deposit_amt;
                    HT[idx_00] += float(deposit_amt * one_minus_x * one_minus_y);
                    HT[idx_10] += float(deposit_amt * cell_offset_x * one_minus_y);
                    HT[idx_01] += float(deposit_amt * one_minus_x * cell_offset_y);
                    HT[idx_11] += float(deposit_amt * cell_offset_x * cell_offset_y);
                } else {
                    const double erode_amt = std::min((capacity - sediment) * erode_speed, -delta_h);
                    for (int i = 0; i < brush_count; ++i) {
                        const int bx = node_x + brush_dx[i];
                        const int by = node_y + brush_dy[i];
                        if (bx < 0 || bx >= w || by < 0 || by >= h) continue;
                        const int bidx = by * w + bx;
                        const double weighted = erode_amt * brush_w[i];
                        const double actual = std::min(double(HT[bidx]), weighted);
                        HT[bidx] -= float(actual);
                        sediment += actual;
                    }
                }

                const double spd_sq = speed * speed + delta_h * gravity;
                speed = std::sqrt(std::max(spd_sq, 0.0));
                water *= (1.0 - evaporation);
                pos_x = new_pos_x;
                pos_y = new_pos_y;
                if (water < 0.001) break;
            }
        }
    }

    // clamp [0,1]（折叠原 _clamp_buffer，省一次 GDScript W*H loop）
    for (int i = 0; i < n; ++i) {
        float v = HT[i];
        if (v < 0.0f) v = 0.0f; else if (v > 1.0f) v = 1.0f;
        HT[i] = v;
    }

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["height_out"] = height_out;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("F32");
    return out;
}
