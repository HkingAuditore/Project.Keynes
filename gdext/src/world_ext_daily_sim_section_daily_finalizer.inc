// ② finalizer kernel — replicates the per-cell delta-cap + thermal-init loops of
// MapGenerator._native_daily_apply_finalizer in C++ for the production hot path
// (facade ON → no HexCell mirror, heavy_diag OFF → no percentile arrays). It operates
// ONLY on the buffers passed in (the same map.temp_arr / tta / thermal / ema / round-start
// snapshots the GDScript loops read) and returns fresh clamped arrays + the diag scalars.
// No C++ slot reads → bit-equal by construction and immune to the mid-round slot/map
// divergence that reverted the earlier slot-read optimization. GDScript keeps ownership of
// write_dense / buffer cache / map handling and falls back to its own loops on rc!=0 or for
// the heavy_diag / cell-mirror edge cases.
Dictionary DCWorldExt::run_native_daily_finalizer(Dictionary knobs) {
    Dictionary out;
    const int n = (int)(int64_t)knobs.get("cell_count", 0);
    if (n <= 0) { out["rc"] = -1; return out; }
    PackedFloat32Array temp_in = knobs.get("temp", PackedFloat32Array());
    PackedFloat32Array tta_in  = knobs.get("tta", PackedFloat32Array());
    if (temp_in.size() != n || tta_in.size() != n) { out["rc"] = -1; return out; }
    PackedFloat32Array thermal_in = knobs.get("thermal", PackedFloat32Array());
    PackedByteArray    ema_in     = knobs.get("ema", PackedByteArray());
    PackedFloat32Array temp_start = knobs.get("temp_start", PackedFloat32Array());
    PackedFloat32Array tta_start  = knobs.get("tta_start", PackedFloat32Array());
    const bool   temp_cap_enabled = (bool)knobs.get("temp_cap_enabled", true);
    const double temp_cap = (double)knobs.get("temp_cap", 0.15);
    const double tta_cap  = (double)knobs.get("tta_cap", 0.12);
    const bool has_temp_start = temp_start.size() == n;
    const bool has_tta_start  = tta_start.size() == n;

    // 全程 double / 写回时才收窄的约束已下沉到共享内核（见
    // pk_async_climate::FinalizerKnobs 的注释）。worker 的
    // _async_finalizer_kernel_pure 跑同一份实现，不再有第二个 float32 拄本。
    PackedFloat32Array temp_out = temp_in;       // CoW: ptrw() below forks a private buffer
    PackedFloat32Array tta_out = tta_in;
    const bool has_thermal = thermal_in.size() == n;
    PackedFloat32Array thermal_out = thermal_in;

    pk_async_climate::FinalizerKnobs fk;
    fk.n_cells = n;
    fk.temp_cap_enabled = temp_cap_enabled;
    fk.temp_cap = temp_cap;
    fk.tta_cap = tta_cap;
    fk.has_temp_start = has_temp_start;
    fk.has_tta_start = has_tta_start;

    pk_async_climate::FinalizerLanes fl;
    fl.temp_start = has_temp_start ? temp_start.ptr() : nullptr;
    fl.tta_start = has_tta_start ? tta_start.ptr() : nullptr;
    fl.ema = ema_in.size() > 0 ? ema_in.ptr() : nullptr;
    fl.ema_size = int(ema_in.size());
    fl.temp = temp_out.ptrw();
    fl.tta = tta_out.ptrw();
    fl.thermal = has_thermal ? thermal_out.ptrw() : nullptr;

    pk_async_climate::FinalizerStats fs;
    pk_async_climate::finalizer_pure(fk, fl, fs);

    const double max_temp_delta = fs.max_temp_delta;
    const double preclamp_max = fs.preclamp_max_temp_delta;
    const double max_transport = fs.max_transport_anomaly;
    const int gt005 = fs.temp_delta_gt_005;
    const int gt010 = fs.temp_delta_gt_010;
    const int gt020 = fs.temp_delta_gt_020;
    const int clamped = fs.temp_clamped;
    const int tta_clamped = fs.tta_clamped;
    const int thermal_init = fs.thermal_init;
    float *tp = fl.temp;

    out["rc"] = 0;
    out["temp_out"] = temp_out;
    out["tta_out"] = tta_out;
    if (has_thermal) out["thermal_out"] = thermal_out;
    // *_written mirror GDScript's CoW fork-on-write: temp_a is forked whenever the cap loop
    // runs (writes every cell), but tta_a / thermal_a fork ONLY when a cell is actually
    // written (clamped / re-inited). GDScript must adopt the C++ buffer ONLY when its flag is
    // set, otherwise keep the array aliased to map.* — the alias feeds the next round through
    // _gdext_ocean_anomaly_buf_cached, so forking it unconditionally diverges by ~1e-5.
    out["temp_written"] = (temp_cap_enabled && has_temp_start && n > 0);
    out["tta_written"] = (tta_clamped > 0);
    out["thermal_written"] = (thermal_init > 0);
    out["max_temp_delta"] = (double)max_temp_delta;
    out["preclamp_max_temp_delta"] = (double)preclamp_max;
    out["temp_delta_gt_005_count"] = gt005;
    out["temp_delta_gt_010_count"] = gt010;
    out["temp_delta_gt_020_count"] = gt020;
    out["temp_delta_clamped_count"] = clamped;
    out["max_transport_anomaly"] = (double)max_transport;
    out["finalizer_tta_clamped_count"] = tta_clamped;
    out["finalizer_thermal_init_count"] = thermal_init;
    const bool native_publish = (bool)knobs.get("native_publish", false);
    bool native_published = false;
    String native_publish_fail_reason;
    Array native_published_slots;
    double native_write_ms = 0.0;
    if (native_publish) {
        const auto t_native_write0 = std::chrono::high_resolution_clock::now();
        if (!_bound || !_map_data) {
            native_publish_fail_reason = "world_not_bound";
        } else {
            const int sid_temp = component_id(StringName("cell_temp"));
            const int sid_tta = component_id(StringName("cell_temperature_transport_anomaly"));
            const int sid_thermal = component_id(StringName("cell_thermal_energy"));
            auto publish_f32_slot = [&](int sid,
                                        const PackedFloat32Array &arr,
                                        bool written,
                                        const String &slot_name) -> bool {
                if (!written) {
                    return true;
                }
                if (sid < 0 || sid >= _slots.size()) {
                    native_publish_fail_reason = String("missing_slot:") + slot_name;
                    return false;
                }
                Slot &slot = _slots.write[sid];
                if (slot.dtype != SlotDType::F32 || arr.size() != n) {
                    native_publish_fail_reason = String("slot_shape_mismatch:") + slot_name;
                    return false;
                }
                slot.arr_f32 = arr;
                _flush_slot_to_map(sid);
                native_published_slots.push_back(slot_name);
                return true;
            };
            const bool ok = publish_f32_slot(sid_temp, temp_out, bool(out.get("temp_written", false)), String("cell_temp")) &&
                            publish_f32_slot(sid_tta, tta_out, bool(out.get("tta_written", false)), String("cell_temperature_transport_anomaly")) &&
                            publish_f32_slot(sid_thermal, thermal_out, bool(out.get("thermal_written", false)), String("cell_thermal_energy"));
            native_published = ok;
        }
        const auto t_native_write1 = std::chrono::high_resolution_clock::now();
        native_write_ms = std::chrono::duration<double, std::milli>(t_native_write1 - t_native_write0).count();
    }
    out["native_publish_requested"] = native_publish;
    out["native_published"] = native_published;
    out["native_publish_fail_reason"] = native_publish_fail_reason;
    out["native_published_slots"] = native_published_slots;
    out["finalizer_native_write_ms"] = native_write_ms;
    out["finalizer_native_dirty_mark_ms"] = 0.0;
    return out;
}

// ─── B8 P0：canonical Climate stage order 契约测试 ────────────────────────────
//
// worker kernel 的顺序由 runtime_climate_canonical_order 表声明；生产侧的顺序
// 由 NATIVE_DAILY_SLICE_GRAPH 的节点序决定。两者必须一致，否则"改了一侧"只会
// 在数值对拍里表现成算法分叉。这里把两边都读出来逐项核对：
//
//   1. canonical 表本身合法（每个 stage 恰好一次，weather 在 round 之后，
//      stage_b 三段内部顺序 albedo → vegetation → feedback）；
//   2. 生产 graph 里每个 stage 的宿主节点都存在；
//   3. 生产 graph 的无条件执行链顺序与 canonical 表一致：
//        round 8 段 < weather_field < commit < distribute < summary < cyclone
//        < runtime_hydrology < stage_b_after_hydrology；
//   4. 早期 stage_b 宿主（albedo / vegetation_dynamics / climate_feedback /
//      stage_b）被显式标记为"条件宿主"：它们只在 weather 内嵌关闭时非空，
//      不属于 canonical 顺序。
Dictionary DCWorldExt::runtime_climate_stage_order_contract_test() const {
    Dictionary out;
    std::string order_error;
    if (!pk::runtime_climate_stage_order_self_test(order_error)) {
        out["ok"] = false;
        out["code"] = String(order_error.c_str());
        return out;
    }

    // stage → 生产宿主节点名。空串表示该 stage 在生产侧没有独立节点。
    struct StageNode {
        pk::RuntimeClimateStage stage;
        const char *node;
        bool conditional_host;
    };
    static const StageNode STAGE_NODES[] = {
        {pk::RuntimeClimateStage::PASS_A, "climate_pass_a", false},
        {pk::RuntimeClimateStage::PASS_B, "climate_pass_b", false},
        {pk::RuntimeClimateStage::OCEAN_WATER, "ocean_water", false},
        {pk::RuntimeClimateStage::OCEAN_LAND, "ocean_land", false},
        {pk::RuntimeClimateStage::WIND_AIR, "wind_air", false},
        {pk::RuntimeClimateStage::WIND_SURFACE, "wind_surface", false},
        {pk::RuntimeClimateStage::SEA_ICE, "sea_ice", false},
        {pk::RuntimeClimateStage::TRANSPIRATION, "transpiration", false},
        {pk::RuntimeClimateStage::WEATHER, "weather_field", false},
        // 无条件链上的顺序锚点：commit/distribute/summary/cyclone 与
        // runtime_hydrology 都不在 parity stage 枚举里，但在契约里要一并排序。
        {pk::RuntimeClimateStage::RUNTIME_HYDROLOGY, "runtime_hydrology", false},
        {pk::RuntimeClimateStage::ALBEDO, "stage_b_after_hydrology", false},
        {pk::RuntimeClimateStage::VEGETATION_DYNAMICS,
         "stage_b_after_hydrology", false},
        {pk::RuntimeClimateStage::CLIMATE_FEEDBACK,
         "stage_b_after_hydrology", false},
    };
    static const char *ORDER_ANCHORS[] = {
        "climate_pass_a", "climate_pass_b", "ocean_water", "ocean_land",
        "wind_air", "wind_surface", "sea_ice", "transpiration",
        "weather_field", "weather_commit", "weather_distribute",
        "weather_summary", "weather_cyclone", "runtime_hydrology",
        "stage_b_after_hydrology",
    };
    static const char *CONDITIONAL_EARLY_HOSTS[] = {
        "albedo", "vegetation_dynamics", "climate_feedback", "stage_b",
        "weather_stage_b",
    };

    Dictionary positions;
    int previous_index = -1;
    for (const char *name : ORDER_ANCHORS) {
        const int index = native_daily_node_index_by_name(String(name));
        positions[String(name)] = index;
        if (index < 0) {
            out["ok"] = false;
            out["code"] = String("climate_stage_order_missing_production_node:") +
                String(name);
            out["graph_positions"] = positions;
            return out;
        }
        if (index <= previous_index) {
            out["ok"] = false;
            out["code"] =
                String("climate_stage_order_production_node_out_of_order:") +
                String(name);
            out["graph_positions"] = positions;
            return out;
        }
        previous_index = index;
    }

    // 条件宿主只报告位置，不参与顺序判定 —— 它们是否执行由 bundle 的
    // stage_b / weather_stage_b 互斥决定（map_generator._build_native_daily_bundle）。
    Dictionary conditional;
    for (const char *name : CONDITIONAL_EARLY_HOSTS) {
        const int index = native_daily_node_index_by_name(String(name));
        if (index >= 0) conditional[String(name)] = index;
    }

    out["ok"] = true;
    out["code"] = String("ok");
    out["canonical_order"] = String(pk::runtime_climate_canonical_order_names());
    out["canonical_stage_count"] =
        static_cast<int64_t>(pk::RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT);
    out["production_node_count"] =
        static_cast<int64_t>(NATIVE_DAILY_SLICE_GRAPH_SIZE);
    out["graph_positions"] = positions;
    out["conditional_early_hosts"] = conditional;
    // 每个 canonical stage 都能映射到一个生产宿主（或明确报告它没有独立节点）。
    Array stage_hosts;
    for (const StageNode &entry : STAGE_NODES) {
        Dictionary row;
        row["stage"] = String(pk::runtime_climate_stage_name(entry.stage));
        row["canonical_index"] = static_cast<int64_t>(
            pk::runtime_climate_canonical_order_index(entry.stage));
        row["production_node"] = String(entry.node);
        row["production_node_index"] =
            native_daily_node_index_by_name(String(entry.node));
        row["conditional_host"] = entry.conditional_host;
        stage_hosts.push_back(row);
    }
    out["stage_hosts"] = stage_hosts;
    return out;
}
