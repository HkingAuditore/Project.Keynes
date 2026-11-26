// Asynchronous climate request and continuation declarations.

    // ───────────────────────────────────────────────────────────────────
    // EXPERIMENTAL: D-async — long-lived worker thread + double buffering
    // ───────────────────────────────────────────────────────────────────
    // Goal: probe whether a "request → background compute → poll" pattern
    // gives the main thread sub-50µs dispatch cost while keeping the
    // demo_complex algorithm bit-equivalent to the synchronous path.
    //
    // Contract (CRITICAL — read before touching any of these methods):
    //   1. Worker threads NEVER call any Godot API (no Variant, no
    //      push_warning, no Object::get/set). They only read/write their
    //      own std::vector<float> buffers.
    //   2. Inputs (temp / elev) are SNAPSHOT-COPIED into worker-private
    //      buffers in `async_climate_set_inputs` — caller-side mutation
    //      after the call cannot race with the worker.
    //   3. Outputs land in a worker-private std::vector<float>; the main
    //      thread copies them into _slots[CELL_DEMO_THERMAL_GRADIENT] only
    //      inside `async_climate_poll()` (which returns true on success).
    //   4. `async_climate_shutdown_*` joins the worker(s); ~DCWorldExt
    //      calls shutdown_all() defensively.
    //   5. NEVER share an AsyncTask across DCWorldExt instances.
    //
    // Output slot: re-uses "cell_demo_thermal_gradient" so existing data
    // overlay machinery / GDScript snapshot code keeps working unchanged.
    //
    // See `.codebuddy/plan/cpp-async-experiment/requirements.md` for the
    // experiment design and 7-criteria success matrix.
    void async_climate_register_task(int task_id, int n_workers);
    void async_climate_set_inputs(int task_id,
                                  const godot::PackedFloat32Array &temp,
                                  const godot::PackedFloat32Array &elev);
    void async_climate_request(int task_id,
                               int grid_w, int grid_h,
                               int iterations, int kernel_radius,
                               float coriolis_strength,
                               float terrain_drag,
                               float elevation_gain,
                               float normalize_k);
    bool async_climate_poll(int task_id);
    godot::Dictionary async_climate_stats(int task_id);
    void async_climate_shutdown_task(int task_id);
    // 注册并启动 worker thread。重复调用是幂等的（已 register 直接 return）。
    void async_climate_round_register();
    // 在 bind_map_data 之后 / 第一次 kick 之前调一次。把 round-invariant 的
    // 静态数据（neighbor_indices / donor_table / foliage_table）从 GDScript
    // 提取到 worker buffer。round 间复用，不在每次 kick 时重序列化。
    void async_climate_round_set_static_knobs(const godot::Dictionary &knobs);
    // 主线程入口：把当前 _slots[] 内容快照到 input_buf，传入 round-level
    // scalars（season_phase / cp 字段），唤醒 worker。返回 false 表示
    // worker 还没消费上一次 request（total_reused++），主线程应继续用
    // 上一次 result_buf。
    bool async_climate_round_kick(const godot::Dictionary &input);
    // 主线程出口：检查 worker 是否完成；完成则把 output_buf 反序列化回
    // _slots[]，并调 _flush_slot_to_map 系列推到 MapData。返回包含
    // sea_ice flip events / dirty_count / per-pass timing 的报告。
    // result_ready=false 时返回 {} 空字典。
    godot::Dictionary async_climate_round_poll();
    // 调试 / 验收用：返回 worker 计数 + 上次耗时。
    godot::Dictionary async_climate_round_stats();
    // Thin native facade over register/static/kick/poll. GDScript still owns
    // production scheduling state; these methods centralize native worker
    // lifecycle and return a structured state report.
    godot::Dictionary native_climate_round_begin(const godot::Dictionary &static_knobs);
    godot::Dictionary native_climate_round_begin_round(const godot::Dictionary &ctx);
    godot::Dictionary native_climate_round_kick(const godot::Dictionary &input);
    godot::Dictionary native_climate_round_poll();
    godot::Dictionary native_climate_round_finish_round(const godot::Dictionary &ctx);
    // Native climate round state report/reset scaffold. This is not production
    // authority yet; it exposes the native worker lifecycle so GDScript can
    // compare against its retained _round_active/_pass_cursor state.
    godot::Dictionary get_native_climate_round_state_report();
    godot::Dictionary get_native_climate_round_hot_state();
    godot::Dictionary reset_native_climate_round_state(const godot::String &reason = godot::String());
    // 析构 hook + GDScript 主动调用入口。安全 join worker。
    void async_climate_round_shutdown();
