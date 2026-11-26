Dictionary DCWorldExt::native_climate_round_begin(const Dictionary &static_knobs) {
    Dictionary out;
    async_climate_round_register();
    if (!static_knobs.is_empty()) {
        async_climate_round_set_static_knobs(static_knobs);
    }
    out["rc"] = 0;
    out["path"] = String("native_climate_round_begin");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["state"] = get_native_climate_round_state_report();
    return out;
}

Dictionary DCWorldExt::native_climate_round_begin_round(const Dictionary &ctx) {
    using namespace pk_async_climate;
    async_climate_round_register();
    AsyncClimateRoundState *st = _get_or_create_round_state(_async_climate_round_state);
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        st->lifecycle_round_id += 1;
        st->lifecycle_round_active = true;
        st->lifecycle_async_kicked = false;
        st->lifecycle_pass_cursor = int(ctx.get("pass_cursor", 0));
        st->lifecycle_tick_index = (int64_t)ctx.get("tick_index", (int64_t)-1);
        st->lifecycle_poll_attempts = 0;
        st->lifecycle_phase_locked = double(ctx.get("phase_locked", 0.0));
        st->lifecycle_stage = "round_started";
        st->lifecycle_owner = "native_probe_lifecycle";
        st->lifecycle_start_state_intents.clear();
        st->lifecycle_start_state_intents.push_back("set_round_active");
        st->lifecycle_start_state_intents.push_back("set_phase_locked");
        st->lifecycle_start_state_intents.push_back("set_pass_cursor");
        st->lifecycle_start_state_intents.push_back("reset_async_kicked");
        st->lifecycle_start_state_intents.push_back("reset_poll_attempts");
        st->lifecycle_start_state_intents.push_back("record_tick_index");
        st->lifecycle_boundary_intents.clear();
        st->lifecycle_boundary_intents.push_back("sync_runtime_terrain_views");
        st->lifecycle_boundary_intents.push_back("begin_round_pass_state");
        st->lifecycle_boundary_intents.push_back("soa_begin_climate_transaction");
        st->lifecycle_finish_boundary_intents.clear();
        st->lifecycle_finalize_tail_boundary_intents.clear();
    }
    Dictionary out;
    out["rc"] = 0;
    out["path"] = String("native_climate_round_begin_round");
    out["authority"] = String("probe_native_lifecycle");
    out["simulation_authority"] = false;
    out["boundary_intent_owner"] = String("native_probe_lifecycle");
    Dictionary state = get_native_climate_round_state_report();
    out["state"] = state;
    out["start_state_intents"] = state.get("start_state_intents", Array());
    out["start_state_intent_owner"] = state.get("start_state_intent_owner", String("native_probe_lifecycle"));
    out["boundary_intents"] = state.get("boundary_intents", Array());
    return out;
}

Dictionary DCWorldExt::native_climate_round_kick(const Dictionary &input) {
    using namespace pk_async_climate;
    Dictionary out;
    async_climate_round_register();
    const bool kicked = async_climate_round_kick(input);
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (st) {
        std::lock_guard<std::mutex> g(st->state_mtx);
        if (kicked) {
            st->lifecycle_async_kicked = true;
            st->lifecycle_stage = "worker_kicked";
        } else if (st->lifecycle_round_active) {
            st->lifecycle_stage = "worker_busy_or_rejected";
        }
    }
    Dictionary state = get_native_climate_round_state_report();
    out["rc"] = 0;
    out["path"] = String("native_climate_round_kick");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["kicked"] = kicked;
    out["substage"] = kicked ? String("kicked") : String("worker_busy_or_rejected");
    out["state"] = state;
    return out;
}

Dictionary DCWorldExt::native_climate_round_poll() {
    using namespace pk_async_climate;
    Dictionary out;
    Dictionary result = async_climate_round_poll();
    const bool done = !result.is_empty();
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (st) {
        std::lock_guard<std::mutex> g(st->state_mtx);
        if (st->lifecycle_round_active && st->lifecycle_async_kicked) {
            st->lifecycle_poll_attempts += 1;
        }
        st->lifecycle_stage = done ? "poll_done" : "poll_pending";
        if (done) {
            st->lifecycle_finish_boundary_intents.clear();
            st->lifecycle_finish_boundary_intents.push_back("apply_sea_ice_flips");
            st->lifecycle_finish_boundary_intents.push_back("finalize_round");
            st->lifecycle_finish_boundary_intents.push_back("finish_native_lifecycle");
            st->lifecycle_finalize_tail_boundary_intents.clear();
            st->lifecycle_finalize_tail_boundary_intents.push_back(bool(result.get("fin_applied", false)) ? "use_worker_finalizer_diag" : "apply_gdscript_finalizer_fallback");
            st->lifecycle_finalize_tail_boundary_intents.push_back("advance_full_sweep_counter");
            st->lifecycle_finalize_tail_boundary_intents.push_back("publish_climate_breakdown");
            st->lifecycle_finalize_tail_boundary_intents.push_back("annual_log");
            st->lifecycle_finalize_tail_boundary_intents.push_back("soa_noop");
            st->lifecycle_finalize_tail_boundary_intents.push_back("soak_dump");
            st->lifecycle_finalize_tail_boundary_intents.push_back("integrity_check");
            st->lifecycle_finalize_tail_boundary_intents.push_back("finish_active_pass");
            st->lifecycle_finalize_tail_boundary_intents.push_back("reset_transpiration_state");
            st->lifecycle_finalize_tail_boundary_intents.push_back("reset_round_local_state");
            st->lifecycle_finalize_tail_boundary_intents.push_back("flush_pending_mark_dirty_all");
            st->lifecycle_finalize_tail_boundary_intents.push_back("mark_round_slots_stale");
            st->lifecycle_finalize_tail_boundary_intents.push_back("dump_round_slot_stats");
        }
    }
    Dictionary state = get_native_climate_round_state_report();
    out["rc"] = 0;
    out["path"] = String("native_climate_round_poll");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["done"] = done;
    out["result"] = result;
    out["published_slots"] = result.get("published_slots", Array());
    out["published_slot_count"] = result.get("published_slot_count", (int64_t)0);
    out["visual_dirty_intents"] = result.get("visual_dirty_intents", Array());
    out["breakdown"] = result.get("breakdown", Dictionary());
    out["finish_boundary_intents"] = state.get("finish_boundary_intents", Array());
    out["finish_boundary_intent_owner"] = state.get("finish_boundary_intent_owner", String("native_probe_lifecycle"));
    out["finalize_tail_boundary_intents"] = state.get("finalize_tail_boundary_intents", Array());
    out["finalize_tail_boundary_intent_owner"] = state.get("finalize_tail_boundary_intent_owner", String("native_probe_lifecycle"));
    out["worker_total_us"] = result.get("worker_total_us", (int64_t)0);
    out["worker_compute_us"] = result.get("worker_compute_us", (int64_t)0);
    out["finalizer_us"] = result.get("finalizer_us", (int64_t)0);
    out["state"] = state;
    return out;
}

Dictionary DCWorldExt::native_climate_round_finish_round(const Dictionary &ctx) {
    using namespace pk_async_climate;
    Dictionary out;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        out["rc"] = -1;
        out["path"] = String("native_climate_round_finish_round");
        out["fallback_reason"] = String("native_climate_round_state_missing");
        out["authority"] = String("probe_native_lifecycle");
        out["simulation_authority"] = false;
        out["state"] = get_native_climate_round_state_report();
        return out;
    }
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        st->lifecycle_round_active = false;
        st->lifecycle_async_kicked = false;
        st->lifecycle_pass_cursor = int(ctx.get("pass_cursor", st->lifecycle_pass_cursor));
        st->lifecycle_stage = String(ctx.get("stage", String("round_finished"))).utf8().get_data();
    }
    out["rc"] = 0;
    out["path"] = String("native_climate_round_finish_round");
    out["authority"] = String("probe_native_lifecycle");
    out["simulation_authority"] = false;
    out["state"] = get_native_climate_round_state_report();
    return out;
}

Dictionary DCWorldExt::get_native_climate_round_hot_state() {
    using namespace pk_async_climate;
    Dictionary out;
    out["owner"] = String("DCWorldExt.AsyncClimateRoundState");
    out["authority"] = String("native_ready_capsule");
    out["simulation_authority"] = false;
    out["climate_round_authority_ready"] = true;
    out["compact_state_capsule"] = true;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        out["ready"] = false;
        out["round_active"] = false;
        out["pass_cursor"] = 0;
        out["generation"] = int64_t(0);
        out["boundary_intent_mask"] = int64_t(0);
        return out;
    }
    std::lock_guard<std::mutex> g(st->state_mtx);
    int64_t boundary_intent_mask = 0;
    if (!st->lifecycle_start_state_intents.empty())
        boundary_intent_mask |= 1;
    if (!st->lifecycle_boundary_intents.empty())
        boundary_intent_mask |= 2;
    if (!st->lifecycle_finish_boundary_intents.empty())
        boundary_intent_mask |= 4;
    if (!st->lifecycle_finalize_tail_boundary_intents.empty())
        boundary_intent_mask |= 8;
    out["ready"] = st->task != nullptr;
    out["round_active"] = st->lifecycle_round_active;
    out["async_kicked"] = st->lifecycle_async_kicked;
    out["pass_cursor"] = st->lifecycle_pass_cursor;
    out["round_id"] = st->lifecycle_round_id;
    out["generation"] = st->lifecycle_round_id;
    out["tick_index"] = st->lifecycle_tick_index;
    out["phase_locked"] = st->lifecycle_phase_locked;
    out["stage"] = String(st->lifecycle_stage.c_str());
    out["dirty"] = boundary_intent_mask != 0;
    out["boundary_intent_mask"] = boundary_intent_mask;
    return out;
}

Dictionary DCWorldExt::get_native_climate_round_state_report() {
    using namespace pk_async_climate;
    Dictionary out;
    out["owner"] = String("DCWorldExt.AsyncClimateRoundState");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["registered"] = false;
    out["lifecycle_state"] = String("unregistered");
    out["reset_owner"] = String("DCWorldExt.reset_native_climate_round_state");
    out["gdscript_authority_expected"] = false;
    out["climate_round_state_owner_candidate"] = String("DCWorldExt.AsyncClimateRoundState");
    out["climate_round_authority_ready"] = true;
    out["climate_round_authority_phase"] = String("native_ready_probe");
    Array authority_blockers;
    out["climate_round_authority_blockers"] = authority_blockers;
    Array remaining_gdscript_authority;
    remaining_gdscript_authority.push_back(String("should_run_stride_policy"));
    remaining_gdscript_authority.push_back(String("godot_mapdata_boundary_execution"));
    remaining_gdscript_authority.push_back(String("reset_abort_boundary_execution"));
    remaining_gdscript_authority.push_back(String("sync_sliced_fallback"));
    out["remaining_gdscript_authority"] = remaining_gdscript_authority;
    out["remaining_gdscript_simulation_authority"] =
        Array::make(String("should_run_stride_policy"),
                    String("sync_sliced_fallback"));
    out["remaining_godot_boundary_authority"] =
        Array::make(String("godot_mapdata_boundary_execution"),
                    String("reset_abort_boundary_execution"));
    out["native_owned_lifecycle_authority"] =
        Array::make(String("round_active"),
                    String("phase_locked"),
                    String("pass_cursor"),
                    String("async_kick_poll"),
                    String("pass_token"),
                    String("finalizer_source_intent"));

    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        return out;
    }

    std::lock_guard<std::mutex> g(st->state_mtx);
    out["lifecycle_owner"] = String(st->lifecycle_owner.c_str());
    out["lifecycle_round_active"] = st->lifecycle_round_active;
    out["lifecycle_async_kicked"] = st->lifecycle_async_kicked;
    out["lifecycle_pass_cursor"] = st->lifecycle_pass_cursor;
    out["lifecycle_round_id"] = st->lifecycle_round_id;
    out["lifecycle_tick_index"] = st->lifecycle_tick_index;
    out["lifecycle_poll_attempts"] = st->lifecycle_poll_attempts;
    out["phase_locked"] = st->lifecycle_phase_locked;
    out["phase_lock_owner"] = String("native_probe_lifecycle");
    out["lifecycle_stage"] = String(st->lifecycle_stage.c_str());
    Array start_state_intents;
    for (const std::string &intent : st->lifecycle_start_state_intents) {
        start_state_intents.push_back(String(intent.c_str()));
    }
    out["start_state_intents"] = start_state_intents;
    out["start_state_intent_owner"] = String("native_probe_lifecycle");
    Array boundary_intents;
    for (const std::string &intent : st->lifecycle_boundary_intents) {
        boundary_intents.push_back(String(intent.c_str()));
    }
    out["boundary_intents"] = boundary_intents;
    out["boundary_intent_owner"] = String("native_probe_lifecycle");
    Array finish_boundary_intents;
    for (const std::string &intent : st->lifecycle_finish_boundary_intents) {
        finish_boundary_intents.push_back(String(intent.c_str()));
    }
    out["finish_boundary_intents"] = finish_boundary_intents;
    out["finish_boundary_intent_owner"] = String("native_probe_lifecycle");
    Array finalize_tail_boundary_intents;
    for (const std::string &intent : st->lifecycle_finalize_tail_boundary_intents) {
        finalize_tail_boundary_intents.push_back(String(intent.c_str()));
    }
    out["finalize_tail_boundary_intents"] = finalize_tail_boundary_intents;
    out["finalize_tail_boundary_intent_owner"] = String("native_probe_lifecycle");
    if (st->task == nullptr) {
        out["lifecycle_state"] = String("state_allocated_without_task");
        return out;
    }

    AsyncClimateRoundTask *t = st->task.get();
    const bool request_pending = t->request_pending.load(std::memory_order_acquire);
    const bool result_ready = t->result_ready.load(std::memory_order_acquire);
    const bool should_exit = t->should_exit.load(std::memory_order_acquire);
    out["registered"] = true;
    out["request_pending"] = request_pending;
    out["result_ready"] = result_ready;
    out["should_exit"] = should_exit;
    out["lifecycle_state"] = should_exit
        ? String("shutting_down")
        : (request_pending ? String("request_pending")
                           : (result_ready ? String("result_ready") : String("idle")));
    out["total_rounds"] = (int64_t)t->total_rounds.load(std::memory_order_relaxed);
    out["total_reused"] = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    out["error_code"] = t->error_code.load(std::memory_order_relaxed);
    out["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    out["worker_total_us"] = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    out["pass_a_us"] = (int64_t)t->last_pass_a_us.load(std::memory_order_relaxed);
    out["pass_b_us"] = (int64_t)t->last_pass_b_us.load(std::memory_order_relaxed);
    out["ocean_water_us"] = (int64_t)t->last_ocean_water_us.load(std::memory_order_relaxed);
    out["ocean_land_us"] = (int64_t)t->last_ocean_land_us.load(std::memory_order_relaxed);
    out["wind_air_us"] = (int64_t)t->last_wind_air_us.load(std::memory_order_relaxed);
    out["wind_surface_us"] = (int64_t)t->last_wind_surface_us.load(std::memory_order_relaxed);
    out["sea_ice_us"] = (int64_t)t->last_sea_ice_us.load(std::memory_order_relaxed);
    out["transp_us"] = (int64_t)t->last_transp_us.load(std::memory_order_relaxed);
    out["finalizer_us"] = (int64_t)t->last_finalizer_us.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        out["static_n_cells"] = t->static_knobs.n_cells;
        out["input_n_cells"] = t->in_buf.n_cells;
    }
    return out;
}

Dictionary DCWorldExt::reset_native_climate_round_state(const String &reason) {
    Dictionary before = get_native_climate_round_state_report();
    async_climate_round_shutdown();
    Dictionary out;
    out["rc"] = 0;
    out["reason"] = reason;
    out["reset_owner"] = String("DCWorldExt.reset_native_climate_round_state");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["previous_state"] = before;
    out["current_state"] = get_native_climate_round_state_report();
    Array reset_boundary_intents;
    reset_boundary_intents.push_back(String("abort_active_pass"));
    reset_boundary_intents.push_back(String("abort_all_climate_passes"));
    reset_boundary_intents.push_back(String("reset_round_local_state"));
    reset_boundary_intents.push_back(String("reset_async_lifecycle_local_state"));
    reset_boundary_intents.push_back(String("reset_round_timings"));
    reset_boundary_intents.push_back(String("reset_start_snapshots"));
    reset_boundary_intents.push_back(String("reset_last_diagnostics"));
    reset_boundary_intents.push_back(String("reset_transpiration_state"));
    reset_boundary_intents.push_back(String("reset_dirty_season_state"));
    reset_boundary_intents.push_back(String("seed_full_sweep_counter"));
    out["reset_boundary_intents"] = reset_boundary_intents;
    out["reset_boundary_intent_owner"] = String("native_probe_lifecycle");
    return out;
}

void DCWorldExt::async_climate_round_shutdown() {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) return;
    std::unique_ptr<AsyncClimateRoundTask> dead;
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        dead = std::move(st->task);
    }
    if (dead) {
        dead->should_exit.store(true, std::memory_order_release);
        dead->cv.notify_all();
        if (dead->worker.joinable()) dead->worker.join();
    }
    delete st;
    _async_climate_round_state = nullptr;
}
