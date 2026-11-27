// DataCore registry, entity, slot, and map binding declarations.

    // ---- bindings: core ----
    // ─── Diag log toggle (Fix #11 second pass, 2026-06-16) ──────────────
    // Mirror of GDScript PKLog.enabled. Pass kernels themselves don't print
    // hot-loop（all hot path are scalar tight loops），but a few startup-time
    // path-decision / commit-diag prints + native fallback warnings respect
    // this flag. Hot kernels never log inside the tight loop regardless.
    void set_diag_logs_enabled(bool v) { _diag_logs_enabled = v; }
    bool get_diag_logs_enabled() const { return _diag_logs_enabled; }
    // ─── Component registry ──────────────────────────────────────────────
    int register_component(const godot::StringName &name, int dtype, int stride = 1, bool track_prev = false);
    int component_id(const godot::StringName &name) const;
    int component_count() const { return _slots.size(); }
    bool has_component(const godot::StringName &name) const { return _slot_by_name.has(name); }
    // ─── Entity / Pool API (mirrors I2.A in GDScript) ────────────────────
    int  create_entities(int count);                 // grow _entity_count, returns first new idx
    int  entity_count() const { return _entity_count; }
    int           create_pool(const godot::StringName &name, int capacity);
    godot::Vector2i pool_range(int pool_id) const;
    int           pool_id(const godot::StringName &name) const;
    int           pool_count() const { return _pools.size(); }
    int           pool_free_count(int pool_id) const;
    // ─── Hot-path data views (READ-ONLY snapshot under DCWorldExt) ───────
    // Under GDExtension the returned PackedArray is a CoW *copy*, not an
    // alias to internal storage. Mutating it does NOT write back. For
    // writes, use write_f32 / write_i32 / write_u8 below.
    //
    // NOTE on naming: `view_f32` is the LEGACY name from the I3.A "zero-
    // acceleration alias" era, when we believed the returned PackedArray
    // could double as a writable view through bind_map_data CoW. The
    // climate Pass-A "all-blue bug" (2026-05-12) proved that contract
    // unreliable across pass boundaries. Under the current "Mode B" charter
    // (data Owned-by-C++, GDScript pulls read-only snapshots) callers
    // SHOULD use `snapshot_f32` instead — same return shape, but the name
    // documents the contract truthfully. `view_f32` remains as a thin
    // alias to keep older call sites compiling.
    godot::PackedFloat32Array view_f32(int comp_id);
    godot::PackedInt32Array   view_i32(int comp_id);
    godot::PackedByteArray    view_u8(int comp_id);
    // ─── Mode-B snapshot API (recommended) ──────────────────────────────
    // Returns a value-copy (Godot PackedArray COW) of `_slots[comp_id].arr_*`.
    // The caller is free to mutate the returned array — those mutations
    // never propagate back into `_slots[]`. Use this whenever GDScript
    // needs to read the latest C++-side numerical state (UI, baker,
    // diagnostics, MapData refresh via flush_to_mapdata).
    //
    // On invalid `comp_id` or dtype mismatch: returns an empty array, no error.
    godot::PackedFloat32Array snapshot_f32(int comp_id);
    // B3b：snapshot_i32 / snapshot_u8 — 与 snapshot_f32 形成完整的 Mode-B
    // 只读快照集合。植被动力学 streak 字段（cell.vitality_low/high_streak）走
    // I32 snapshot；后续序列化 / save / overlay 也需要 U8 snapshot 补齐。
    godot::PackedInt32Array   snapshot_i32(int comp_id);
    godot::PackedByteArray    snapshot_u8(int comp_id);
    // ─── Mode-B per-cell read API（plan/3b-single-read-source）─────────
    // 单元素直读：从 _slots[comp_id].arr_*.ptr() 直接索引，无 Variant 装箱、
    // 无 PackedArray 拷贝。供 HexCell facade 21 个 hot getter 切换 read 源
    // （由 GDScript-DCWorld 改读 C++ slot），结构性消除"C++ flush 与
    // GDScript-DCWorld SoA 脱钩"类 bug（典型表现：cell.sea_ice_frac 冻结
    // 在初始日值）。
    //
    // 越界 / dtype 不匹配 / comp_id 非法 → 返回 0；不 push_error
    // （与 GDScript DCWorld.read_f32 严厉报警不同，hot getter 容忍静默 0，
    //  避免每帧 2400 cell × 21 字段量级的错误风暴）。
    float   read_f32(int comp_id, int idx) const;
    int32_t read_i32(int comp_id, int idx) const;
    int     read_u8 (int comp_id, int idx) const; // 返回 int（与 write_u8 对称）
    // ─── Hot-path writes (replaces `view_xxx(c)[i] = v` pattern) ─────────
    // Single-element writes; bounds-checked, no-op on invalid args.
    void write_f32(int comp_id, int idx, float v);
    void write_i32(int comp_id, int idx, int32_t v);
    void write_u8 (int comp_id, int idx, int v); // accept int from GDScript; clamp to 0..255
    // Bulk writes; copy `src[0..src.size())` into `arr[start..start+src.size())`.
    void write_f32_range(int comp_id, int start, const godot::PackedFloat32Array &src);
    void write_i32_range(int comp_id, int start, const godot::PackedInt32Array   &src);
    void write_u8_range (int comp_id, int start, const godot::PackedByteArray    &src);
    // Sparse / indexed writes; for each k in [0, indices.size()), do
    //   arr[indices[k]] = values[k]
    // Designed for Pass-B / dirty-only systems where the dirty cell list is
    // smaller than the full pool but is *not* contiguous. One trans-boundary
    // call replaces N single-cell write_xxx() calls — on a 2400-cell, 30%-
    // dirty workload this is the difference between ~15ms and ~3ms (see
    // tmp/bench_dots_vs_dict.gd, Case 3/4).
    void write_f32_indexed(int comp_id, const godot::PackedInt32Array &indices, const godot::PackedFloat32Array &values);
    void write_i32_indexed(int comp_id, const godot::PackedInt32Array &indices, const godot::PackedInt32Array   &values);
    void write_u8_indexed (int comp_id, const godot::PackedInt32Array &indices, const godot::PackedByteArray    &values);
    // ─── Bind to MapData (GDScript instance) ─────────────────────────────
    // Reflectively reads the GDScript `MapData` properties (e.g. `temp_arr`)
    // and assigns them into the matching slots. Buffers are shared via COW —
    // no copy. Returns false on any property mismatch / type mismatch.
    bool bind_map_data(godot::Object *map_data);
    bool is_bound() const { return _bound; }
    // GDScript 在 bind_map_data 后注入 DCWorld 句柄。native flush 会对比提交前后
    // 的视觉槽，只把真实变化的 cell 传给 dirty mask；`nullptr` 关闭自动 mark。
    void bind_dirty_world(godot::Object *dirty_world);
    // Top-level native orchestration scaffold. These APIs are intentionally
    // coarse-grained: GDScript configures once after bind_map_data(), then a
    // daily tick passes only scalar clock values. Kernels can be fused behind
    // this surface without changing GDScript orchestration again.
    godot::Dictionary configure_native_world(const godot::Dictionary &knobs);
    bool is_native_daily_visual_commit_pending() const;
    void complete_native_daily_visual_commit();
    // Compatibility alias for callers predating the full visual-snapshot barrier.
    void complete_native_daily_moisture_commit();
    // Native country authority. Only cell.country_slot is mirrored into the
    // DataCore/MapData bridge; identity, technology, treasury, and territory
    // CSR remain native-only.
    godot::Dictionary configure_country(const godot::Dictionary &catalog,
                                        const godot::Dictionary &profile,
                                        int cell_count, int64_t seed);
    // ─── CoW flush / refresh (performance-charter §11.2) ─────────────────
    // After any C++ pass calls ptrw() on a slot, CoW detaches the buffer.
    // flush_slots_to_map() pushes the (possibly-detached) C++ buffer back
    // to the GDScript MapData property via obj->set() — O(1) ref-swap each.
    // refresh_slots_from_map() does the reverse: pulls GDScript-side
    // arrays back into the C++ slots (needed when GDScript code writes
    // map.*_arr between C++ passes).
    void flush_slots_to_map();
    void flush_slots_to_map_keys(const godot::PackedStringArray &slot_names);
    void refresh_slots_from_map();
    void refresh_slots_from_map_keys(const godot::PackedStringArray &slot_names);
    // 把 native flush 累积的精确 dirty indices 一次性 emit 到 _dirty_world。
    // 保留旧方法名以兼容 GDScript 调用点；多次调用幂等。
    void flush_pending_mark_dirty_all();
    // ─── Archetype system (mirrors I2.B in GDScript) ─────────────────────
    int  create_archetype(const godot::StringName &name, const godot::Array &comp_ids);
    void assign_archetype(int idx, int arch_id);
    int  archetype_count() const { return _archetypes.size(); }
    godot::PackedInt32Array entity_archetype_array() const { return _entity_archetype; }
    // Wind heat transport, split to match ClimateDailySystem ordering:
    // air mass writes only cell_air_mass_temp_anomaly; surface reads that
    // anomaly and is the sole wind-air stage that injects heat into cell_temp.
    bool supports_wind_air_slot_temp() { return true; }
