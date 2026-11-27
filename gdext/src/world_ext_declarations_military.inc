// Military bindings, cell metrics, and Economy bridge declarations.

    // ---- bindings: military ----
    // ---- Military
    // Main-thread synchronous military runtime (contract §0.1). DCWorldExt owns
    // a pk::MilitaryCore; the Godot-facing surface is exactly contract §2. All
    // Country/Economy mutations go through their existing command batch entry
    // points with effective day D+1, so Military only ever writes its own store.
    godot::Dictionary configure_military(const godot::Dictionary &catalog, int64_t seed);
    godot::Dictionary set_military_terrain(const godot::Dictionary &terrain);
    godot::Dictionary submit_military_commands(const godot::Array &batch);
    bool military_should_run(int64_t day) const;
    godot::Dictionary run_military_daily(const godot::Dictionary &ctx);
    godot::Dictionary run_military_catch_up(const godot::Dictionary &ctx);
    godot::Dictionary get_military_report();
    godot::Dictionary get_military_daily_result() const;
    godot::PackedInt64Array capture_military_event_progress() const;
    bool restore_military_event_progress(const godot::PackedInt64Array &progress);
    godot::Dictionary get_military_country_snapshot(int64_t country) const;
    // Physical maintenance read-only view (design §4 / D7). One row per live
    // maintenance object, packed as parallel arrays so the panel pays for one
    // poll instead of one call per building.
    godot::Dictionary get_military_maintenance_snapshot(int64_t country) const;
    godot::Array get_military_armies(int64_t country) const;
    godot::Dictionary get_military_army(int64_t army);
    godot::Dictionary get_military_cell_snapshot(int64_t cell, int64_t observer) const;
    godot::Dictionary get_military_render_snapshot(int64_t after_revision);
    // Render selection: the snapshot returns this army's area / path cells.
    godot::Dictionary set_military_render_selection(int64_t army);
    godot::Dictionary get_military_control_snapshot() const;
    godot::Array poll_military_events(int64_t after_id, int64_t limit = 256) const;
    godot::Dictionary preview_military_path(int64_t army, int64_t cell);
    godot::Dictionary evaluate_military_peace(int64_t war_id, int64_t proposer,
                                              const godot::Array &terms) const;
    godot::Dictionary get_military_catalog_view() const;
    godot::PackedByteArray encode_military_state() const;
    godot::Dictionary restore_military_state(const godot::PackedByteArray &bytes);
    godot::Dictionary runtime_military_self_test();
    godot::Dictionary run_military_bench(const godot::Dictionary &cfg);
    // AI arming: every country whose handle is not in `player_handles` runs the
    // military agenda. Contract §2 does not list it; the facade probes for it
    // and falls back to per-slot arming.
    godot::Dictionary set_military_ai_player_handles(const godot::PackedInt64Array &handles);
    godot::Dictionary set_military_ai_country(int64_t slot, int64_t ai);
    // ---- Military cell stats
    // Feed for the ideology channel A/C cards (design §17.1). Military owns the
    // facts; these entry points PUBLISH them so the existing tag dictionary and
    // derived cell layer can read them. They never write another domain:
    //   * country metrics feed trigger conditions (`country.at_war`),
    //   * cell tags feed OWN_TERRITORY / TAG_SOURCE_COUNT selectors,
    //   * the q16 reader reports what a `military.cell.*` stat resolved to.
    // Implementation: gdext/src/world_ext_military_cell_stats.cpp.
    //
    // `rows` = [{handle:int, slot:int, at_war:int, soldier_share_q16:int}].
    godot::Dictionary set_military_country_metrics(const godot::Array &rows);
    // `tags` = [{name:String, bit:int, cells:PackedInt32Array, country:int,
    //            owner:PackedInt32Array}] (owner only for the occupation bits).
    godot::Dictionary set_military_cell_tags(const godot::Array &tags);
    godot::Dictionary get_military_cell_tag_cells(int64_t tag) const;
    godot::Dictionary get_military_country_metrics(int64_t handle) const;
    godot::Dictionary get_military_cell_stats_report() const;
    godot::Dictionary clear_military_cell_stats();
    // `cell_key` is a `military.cell.*` Modifier stat key; `cell` is the
    // ECONOMY group handle (every per-cell reader passes the cell there).
    godot::Dictionary get_military_cell_stat_q16(const godot::String &cell_key,
                                                 int64_t cell,
                                                 int64_t entity_handle,
                                                 int64_t base_value_q16) const;
    // ---- Economy military hooks ----
    // Military v1 (design §5.1). Publishes the per-cell ration satisfaction
    // Military owns. Needs listed in a profession's state_supplied_need_ids are
    // never purchased on the market; their satisfaction is read from here, so a
    // ration shortfall hits the survival dimension (and thus morale and
    // starvation deaths). Cells absent from `cells` keep their previous value;
    // the initial value is 1.0, so a world without soldiers is unchanged.
    // Returns {ok, written, reason?}.
    godot::Dictionary set_military_ration_satisfaction(
        const godot::PackedInt32Array &cells,
        const godot::PackedInt32Array &q16);
