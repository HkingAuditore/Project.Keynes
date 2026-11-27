Dictionary DCWorldExt::native_ocean_physical_begin(const Dictionary &ctx) {
    Dictionary state = _native_ocean_physical_state.duplicate(true);
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["simulation_authority"] = bool(ctx.get("simulation_authority", false));
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String("round_active");
    state["physical_round_active"] = true;
    state["physical_round_id"] = int(ctx.get("physical_round_id", int(state.get("physical_round_id", 0)) + 1));
    state["physical_phase_locked"] = double(ctx.get("phase_locked", ctx.get("physical_phase_locked", 0.0)));
    state["physical_need_visual"] = bool(ctx.get("physical_need_visual", false));
    state["physical_run_ocean"] = bool(ctx.get("physical_run_ocean", true));
    state["stage"] = int(ctx.get("stage", 0));
    state["stage_name"] = String(ctx.get("stage_name", "begin"));
    state["tick_index"] = int(ctx.get("tick_index", 0));
    state["day_index"] = int(ctx.get("day_index", 0));
    state["start_state_intents"] = Array::make(String("set_physical_round_active"),
                                                String("set_phase_locked"),
                                                String("set_stage_cursor"),
                                                String("record_round_id"));
    state["remaining_gdscript_authority"] = Array::make(String("visual_raster_boundary_execution"),
                                                         String("texture_commit_boundary_execution"));
    state["native_owned_lifecycle_authority"] = Array::make(String("physical_round_active"),
                                                             String("physical_round_id"),
                                                             String("phase_locked"),
                                                             String("physical_stage"),
                                                             String("physical_stage_cursor"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::native_ocean_physical_step(const Dictionary &ctx) {
    Dictionary state = _native_ocean_physical_state.duplicate(true);
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String(ctx.get("lifecycle_state", "step"));
    state["physical_round_active"] = bool(ctx.get("physical_round_active", state.get("physical_round_active", false)));
    state["phys_solve_done"] = bool(ctx.get("phys_solve_done", state.get("phys_solve_done", false)));
    state["stage"] = int(ctx.get("stage", state.get("stage", 0)));
    state["stage_name"] = String(ctx.get("stage_name", state.get("stage_name", "step")));
    state["next_stage"] = ctx.get("next_stage", state.get("next_stage", Variant()));
    state["next_stage_name"] = ctx.get("next_stage_name", state.get("next_stage_name", Variant()));
    state["path"] = String(ctx.get("path", state.get("path", "")));
    state["tick_index"] = int(ctx.get("tick_index", state.get("tick_index", 0)));
    state["day_index"] = int(ctx.get("day_index", state.get("day_index", 0)));
    state["last_step_report"] = ctx.duplicate(true);
    state["step_boundary_intents"] = Array::make(String("advance_physical_stage"),
                                                  String("publish_native_stage_report"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::native_ocean_physical_finish(const Dictionary &ctx) {
    Dictionary state = _native_ocean_physical_state.duplicate(true);
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String("round_finished");
    state["physical_round_active"] = false;
    state["phys_solve_done"] = false;
    state["last_physical_complete_tick"] = int(ctx.get("tick_index", state.get("tick_index", 0)));
    state["finish_report"] = ctx.duplicate(true);
    state["finish_boundary_intents"] = Array::make(String("publish_physical_completion"),
                                                    String("enqueue_visual_boundary_if_needed"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::reset_native_ocean_physical_state(String reason) {
    Dictionary state;
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["simulation_authority"] = false;
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String("reset");
    state["reset_reason"] = reason;
    state["physical_round_active"] = false;
    state["physical_round_id"] = 0;
    state["stage"] = 0;
    state["stage_name"] = String("reset");
    state["reset_boundary_intents"] = Array::make(String("reset_physical_round"),
                                                   String("reset_visual_round_boundary"),
                                                   String("discard_ocean_buffers"));
    state["remaining_gdscript_authority"] = Array::make(String("visual_raster_boundary_execution"),
                                                         String("texture_commit_boundary_execution"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::get_native_ocean_physical_state_report() const {
    Dictionary out = _native_ocean_physical_state.duplicate(true);
    if (out.is_empty()) {
        out["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
        out["authority"] = String("native_ready_lifecycle");
        out["simulation_authority"] = false;
        out["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
        out["lifecycle_state"] = String("uninitialized");
        out["physical_round_active"] = false;
        out["remaining_gdscript_authority"] = Array::make(String("visual_raster_boundary_execution"),
                                                           String("texture_commit_boundary_execution"));
    }
    return out;
}

Dictionary DCWorldExt::get_native_ocean_physical_hot_state() const {
    const Dictionary &state = _native_ocean_physical_state;
    Dictionary out;
    out["owner"] = state.get(
        "owner", String("DCWorldExt.NativeOceanPhysicalLifecycle"));
    out["authority"] = String("native_ready_capsule");
    out["simulation_authority"] =
        bool(state.get("simulation_authority", false));
    out["compact_state_capsule"] = true;
    out["ready"] = !state.is_empty();
    out["physical_round_active"] =
        bool(state.get("physical_round_active", false));
    out["physical_round_id"] = int64_t(
        state.get("physical_round_id", 0));
    out["generation"] = int64_t(
        state.get("physical_round_id", 0));
    out["phase_locked"] = double(
        state.get("physical_phase_locked", 0.0));
    out["stage"] = int64_t(state.get("stage", 0));
    out["stage_name"] = state.get("stage_name", String("uninitialized"));
    out["phys_solve_done"] = bool(state.get("phys_solve_done", false));
    int64_t boundary_intent_mask = 0;
    if (state.has("start_state_intents")) boundary_intent_mask |= 1;
    if (state.has("step_boundary_intents")) boundary_intent_mask |= 2;
    if (state.has("finish_boundary_intents")) boundary_intent_mask |= 4;
    if (state.has("reset_boundary_intents")) boundary_intent_mask |= 8;
    out["boundary_intent_mask"] = boundary_intent_mask;
    out["dirty"] = boundary_intent_mask != 0;
    return out;
}

Dictionary DCWorldExt::get_native_dirty_report() const {
    return _native_dirty_report.duplicate();
}
