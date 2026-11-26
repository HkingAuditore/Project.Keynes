//
// Range sweep over [start_idx, end_idx). Writes 8 cell-level SoA component
// slots in place. Read-side vapor/precip uses the begin-slice snapshots, so
// multiple native slices can safely build one hidden round before commit().
double DCWorldExt::run_weather_field_solve_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedVector2Array;
    using godot::PackedByteArray;
    using godot::Vector2;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_field_solve_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve all 16 slot ids ONCE ───────────────────────────────────
    const int sid_temp        = component_id(StringName("cell_temp"));
    const int sid_moisture    = component_id(StringName("cell_moisture"));
    const int sid_air_anom    = component_id(StringName("cell_air_mass_temp_anomaly"));
    const int sid_wind_x      = component_id(StringName("cell_wind_x"));
    const int sid_wind_y      = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd    = component_id(StringName("cell_wind_speed"));
    const int sid_terrain     = component_id(StringName("cell_terrain"));
    const int sid_has_river   = component_id(StringName("cell_has_river"));
    const int sid_river_q30   = component_id(StringName("cell_river_discharge_30d"));
    const int sid_elev        = component_id(StringName("cell_elevation"));
    const int sid_vegetation  = component_id(StringName("cell_vegetation"));
    const int sid_soil_moisture = component_id(StringName("cell_soil_moisture"));
    const int sid_veg_vitality = component_id(StringName("cell_vegetation_vitality"));
    const int sid_sea_ice     = component_id(StringName("cell_sea_ice_frac"));
    const int sid_w_vapor     = component_id(StringName("cell_weather_vapor"));
    const int sid_w_cloud     = component_id(StringName("cell_weather_cloud"));
    const int sid_w_precip    = component_id(StringName("cell_weather_precip"));
    const int sid_w_inst      = component_id(StringName("cell_weather_instability"));
    const int sid_w_intens    = component_id(StringName("cell_weather_intensity"));
    const int sid_w_conv      = component_id(StringName("cell_weather_convergence"));
    const int sid_w_type      = component_id(StringName("cell_weather_type"));
    const int sid_w_prev_type = component_id(StringName("cell_weather_prev_type"));
    const int sid_w_target_type = component_id(StringName("cell_weather_target_type"));
    const int sid_w_transition_alpha = component_id(StringName("cell_weather_transition_alpha"));
    const int sid_w_finit     = component_id(StringName("cell_weather_field_init"));
    const bool weather_transition_enabled = bool(knobs.get("weather_transition_enabled", false));
    float weather_transition_alpha_rate = float(knobs.get("weather_transition_alpha_rate", 1.0));
    if (weather_transition_alpha_rate < 0.0f) weather_transition_alpha_rate = 0.0f;
    else if (weather_transition_alpha_rate > 1.0f) weather_transition_alpha_rate = 1.0f;
    // [dt-aware transition 2026-06-28] 过渡进度按"游戏天数"推进而非"求解次数"。旧实现 alpha 每次求解
    // 固定 +rate，与 dt 无关→加速档(dt≫1)每次求解推进 ~dt 天却仍只 +rate，需 ~4 次求解≈4·dt 天才完成过渡，
    // 致短暂强天气(STORM/FOG/MONSOON)永远累不满 alpha 被显示为 prev(CLEAR)。改为 alpha += rate·dt_days，
    // 并在目标切换时即把当前求解计入(alpha=rate·dt_days)，使 dt≥~1/rate 时即时切换；dt=1 时退化为原 ~3 次求解平滑。
    float weather_transition_dt_days = float(knobs.get("weather_transition_dt_days", 1.0));
    if (weather_transition_dt_days < 0.0f) weather_transition_dt_days = 0.0f;
    else if (weather_transition_dt_days > 30.0f) weather_transition_dt_days = 30.0f;
    if (sid_temp       < 0 || sid_moisture   < 0 || sid_air_anom    < 0 ||
        sid_wind_x     < 0 || sid_wind_y     < 0 || sid_wind_spd   < 0 ||
        sid_terrain    < 0 ||
        sid_has_river  < 0 || sid_elev       < 0 || sid_vegetation  < 0 ||
        sid_w_vapor    < 0 || sid_w_cloud    < 0 || sid_w_precip    < 0 ||
        sid_w_inst     < 0 || sid_w_intens   < 0 || sid_w_conv      < 0 ||
        sid_w_type     < 0 || sid_w_finit    < 0) {
        diag("missing slot id (some weather component not bound)");
        return -1.0;
    }
    if (weather_transition_enabled &&
        (sid_w_prev_type < 0 || sid_w_target_type < 0 || sid_w_transition_alpha < 0)) {
        diag("weather transition enabled but prev/target/alpha slots are missing");
        return -1.0;
    }

    // ─── Pull scalars + range from knobs ────────────────────────────────
    if (!knobs.has("start_idx")  || !knobs.has("end_idx")  ||
        !knobs.has("n_cells")    || !knobs.has("season_idx") ||
        !knobs.has("climate_anomaly") || !knobs.has("season_phase") ||
        !knobs.has("world_bounds_pos_y") || !knobs.has("world_bounds_size_y") ||
        !knobs.has("refresh_convergence")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   start_idx       = int(knobs["start_idx"]);
    const int   end_idx         = int(knobs["end_idx"]);
    const int   n_cells         = int(knobs["n_cells"]);
    const int   season_idx      = int(knobs["season_idx"]);
    const float climate_anomaly = float(knobs["climate_anomaly"]);
    const float season_phase    = float(knobs["season_phase"]);
    // 去季节化(2026-06-20)/去纬度门：weather 分类不再消费 season_idx/season_phase/world_bounds（纬度回退
    // 路径已删）。保留 knob 读取以维持调用契约（caller 仍传、上方 knobs.has 校验不变），显式吞掉避免 unused 告警。
    (void)season_idx;
    (void)season_phase;
    const float wb_pos_y        = float(knobs["world_bounds_pos_y"]);
    const float wb_size_y       = float(knobs["world_bounds_size_y"]);
    // climate-realism Stage1 (2026-06-23): 「热赤道」纬度(norm)，GDScript begin_slice 按 zonal-max
    // 温度逐 tick 计算并经 knobs 传入；Hadley/Ferrel omega 项消费。镜像 field_solver.gd。
    const float weather_lat_te_norm = knobs.has("weather_lat_te_norm")
                                        ? float(knobs["weather_lat_te_norm"]) : 0.5f;
    // [climate-zone-fix P3] 原 constexpr 0.40 → 导出为 knob（field_omega_ascent_gain），缺 key 仍回退 0.40。
    // 下调弱化静止 ITCZ 雨带锚定，让冷季锋面/层状相对增强（镜像 field_solver.gd OMEGA_ASCENT_GAIN）。
    const float OMEGA_ASCENT_GAIN  = knobs.has("field_omega_ascent_gain")
                                        ? float(knobs["field_omega_ascent_gain"]) : 0.40f;
    constexpr float OMEGA_DESCENT_GAIN = 0.70f; // 副热带下沉带降水抑制
    constexpr float OMEGA_DESCENT_COND = 0.45f; // 副热带下沉抑制凝结→晴空
    // Stage6/6c (2026-06-23): 湿度充放电 + 对流抑制记忆。镜像 field_solver.gd。
    constexpr float VAPOR_DISCHARGE = 0.70f;    // 持续降水更快抽干本格水汽，避免固定雨核永雨
    constexpr float DISCHARGE_SUSTAIN = 0.65f;  // prev_precip 高时加强放电，让雨团下完后进入恢复期
    // Stage6e: 对流抑制=双稳弛豫振子(硬阈)，线性版会停在弱雨稳态→不消散；改硬阈 开/关 循环。镜像 field_solver.gd。
    // Stage6g: 对流抑制=按时长充放电(强度无关)，双稳两段编码于单 float。镜像 field_solver.gd。
    // inhib∈[0,1) 充能期；inhib≥1 不应期(压制降水)。
    constexpr float INHIB_CHARGE = 0.26f;       // Stage7c: 0.18→0.26 雨段≈4tick(~2天)
    constexpr float INHIB_REFRAC = 0.18f;       // Stage7c: 0.55→0.18 不应期≈5-6tick(~3天，晴天真间断)
    constexpr float INHIB_LEAK = 0.88f;         // 充能期干tick泄放
    constexpr float INHIB_STRENGTH = 0.92f;     // 不应期内 precip ×(1-此值)
    constexpr float INHIB_WET = 0.02f;          // 计为降水tick的阈
    // ── Stage7 (2026-06-23): 预报性斜压涡旋场 ψ（涌现的非季节天气变率）。镜像 field_solver.gd。
    // ψ 由"上风平流 + 斜压增长(温度梯度) + 随机种子 + 耗散"演化→自发生成、移动、消亡的过境系统；
    // 耦合进 dynamic_forcing/precip→干季偶有降水、湿季有间断，与季节解耦。可由 knob 关。
    const bool  syn_enabled   = knobs.has("weather_synoptic_enabled") ? bool(knobs["weather_synoptic_enabled"]) : true;
    // Stage13: ψ 演化(平流/增长/种子/扩散/阻尼)的 knob 已移到独立 pass run_synoptic_advance_pass。
    // 本 solve 循环只读 ψ，仅保留下面的【耦合】knob。
    const float syn_supp      = knobs.has("weather_synoptic_supp")      ? float(knobs["weather_synoptic_supp"])      : 0.75f; // Stage14 0.50→0.75 ψ<0(高压)强抑雨→移动的晴空带
    const float syn_enh       = knobs.has("weather_synoptic_enh")       ? float(knobs["weather_synoptic_enh"])       : 0.45f; // Stage14 0.20→0.45 ψ>0(低压)增雨(让降水跟 ψ)
    // Stage9 #5: ψ>0(气旋)在斜压带(锋面/中纬冷季)创造抬升+增雨→冷季锋面雨(地中海/海洋性"雨热不同期")。
    const float syn_front_force=knobs.has("weather_synoptic_front_force")?float(knobs["weather_synoptic_front_force"]): 0.55f; // ψ>0 在锋面加 dynamic_forcing(造雨)
    const float syn_front_enh = knobs.has("weather_synoptic_front_enh") ? float(knobs["weather_synoptic_front_enh"]) : 0.70f; // ψ>0 在锋面额外增雨倍率
    // Stage14「激进推 ψ 主导」：ψ>0(低压)强抬升成为降水主驱动→云雨成片随 ψ 平移。base 大幅提高让移动的
    // ψ 涡旋盖过静止地理强迫(omega/对流/辐合)。代价:过湿+扰动雨热(用户已接受)。
    const float syn_base_lift = knobs.has("weather_synoptic_base_lift") ? float(knobs["weather_synoptic_base_lift"]) : 1.55f;
    // Stage13b ψ 演化 knob（内联全场推进用：见 slot 指针后、主循环前的全场 ψ pass）。
    const int   syn_adv_cells = knobs.has("weather_synoptic_adv_cells") ? int(knobs["weather_synoptic_adv_cells"]) : 3;
    const float syn_baroclinic= knobs.has("weather_synoptic_baroclinic")? float(knobs["weather_synoptic_baroclinic"]): 0.40f;
    const float syn_seed_rate = knobs.has("weather_synoptic_seed_rate") ? float(knobs["weather_synoptic_seed_rate"]) : 0.015f; // 稀疏播种(纯取值平移无损,种子须少否则铺满)
    const float syn_seed_amp  = knobs.has("weather_synoptic_seed_amp")  ? float(knobs["weather_synoptic_seed_amp"])  : 0.42f;
    const float syn_diffuse   = knobs.has("weather_synoptic_diffuse")   ? float(knobs["weather_synoptic_diffuse"])   : 0.05f;  // 弱扩散(强了会铺满)
    const float syn_damp      = knobs.has("weather_synoptic_damp")      ? float(knobs["weather_synoptic_damp"])      : 0.90f;  // 较快衰减→无源区清空保稀疏
    const int   syn_tick      = knobs.has("weather_solve_tick")         ? int(knobs["weather_solve_tick"])           : 0;
    if (syn_enabled && _wx_synoptic.size() != (size_t)n_cells) {
        _wx_synoptic.assign((size_t)n_cells, 0.0f);
        _wx_synoptic_prev.assign((size_t)n_cells, 0.0f);
    }
    const float * const __restrict PSI = syn_enabled ? _wx_synoptic.data() : nullptr;
    (void)wb_pos_y;
    (void)wb_size_y;
    const bool  refresh_convergence = bool(knobs["refresh_convergence"]);
    const bool  apply_convergence_boost = knobs.has("apply_convergence_boost")
                                            ? bool(knobs["apply_convergence_boost"]) : true;

    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (start_idx < 0 || start_idx > n_cells || end_idx < start_idx || end_idx > n_cells) {
        diag("invalid start_idx/end_idx range");
        return -1.0;
    }

    const int   field_advect_steps      = knobs.has("field_advect_steps")
                                            ? int(knobs["field_advect_steps"]) : 3;
    const float field_diffusion         = knobs.has("field_diffusion")
                                            ? float(knobs["field_diffusion"]) : 0.04f;
    const float field_condensation_gain = knobs.has("field_condensation_gain")
                                            ? float(knobs["field_condensation_gain"]) : 0.42f;
    const float field_orographic_lift_gain = knobs.has("field_orographic_lift_gain")
                                            ? float(knobs["field_orographic_lift_gain"]) : 0.22f;
    const float field_convergence_gain  = knobs.has("field_convergence_gain")
                                            ? float(knobs["field_convergence_gain"]) : 0.18f;
    const float field_ocean_evap_gain   = knobs.has("field_ocean_evap_gain")
                                            ? float(knobs["field_ocean_evap_gain"]) : 0.55f;
    // field_precip_decay / field_precip_carryover_max：原 carryover precip_floor 的输入，已被 EMA
    // 惯性(field_precip_inertia)取代，C++ 主路径不再读取(GDScript verify 路径与 ClimateProfile 仍保留)。
    const float field_vapor_precip_sink = knobs.has("field_vapor_precip_sink")
                                            ? float(knobs["field_vapor_precip_sink"]) : 0.85f;
    // 降水惯性 EMA 系数 α(2026-06-20 根因重构)：precip = lerp(prev_precip, target, α)。默认与
    // weather_system._field_precip_inertia / climate_profile.weather_precip_inertia 对齐(0.58)。
    float field_precip_inertia = knobs.has("field_precip_inertia")
                                            ? float(knobs["field_precip_inertia"]) : 0.40f;
    if (field_precip_inertia < 0.05f) field_precip_inertia = 0.05f;
    else if (field_precip_inertia > 1.0f) field_precip_inertia = 1.0f;
    // Stage10 空间平滑强度：最终降水向邻域(上一 tick)均值轻混 → 削单格噪声/棋盘格，保连片风暴。
    const float classify_gate_land = knobs.has("weather_precip_classify_gate_land")
        ? float(knobs["weather_precip_classify_gate_land"]) : 0.040f;
    const float classify_gate_water = knobs.has("weather_precip_classify_gate_water")
        ? float(knobs["weather_precip_classify_gate_water"]) : 0.032f;
    const float classify_anomaly_cap = knobs.has("weather_classify_anomaly_cap")
        ? float(knobs["weather_classify_anomaly_cap"]) : 0.12f;
    float field_precip_spatial_smooth = knobs.has("field_precip_spatial_smooth")
                                            ? float(knobs["field_precip_spatial_smooth"]) : 0.30f;
    if (field_precip_spatial_smooth < 0.0f) field_precip_spatial_smooth = 0.0f;
    else if (field_precip_spatial_smooth > 0.8f) field_precip_spatial_smooth = 0.8f;
    // Stage15 云量时间惯性(EMA)：cloud 向上帧靠拢的比例，越小越平滑(减 shader 闪烁)。
    float field_cloud_inertia = knobs.has("field_cloud_inertia") ? float(knobs["field_cloud_inertia"]) : 0.74f;
    if (field_cloud_inertia < 0.05f) field_cloud_inertia = 0.05f;
    else if (field_cloud_inertia > 1.0f) field_cloud_inertia = 1.0f;
    const float field_vapor_relax_rate = knobs.has("field_vapor_relax_rate")
                                            ? float(knobs["field_vapor_relax_rate"]) : 0.08f;
    const float field_orographic_lift_cap = knobs.has("field_orographic_lift_cap")
                                            ? float(knobs["field_orographic_lift_cap"]) : 0.35f;
    const float hex_size                = knobs.has("hex_size")
                                            ? float(knobs["hex_size"]) : 22.0f;
    float weather_cell_pos_scale = knobs.has("weather_cell_pos_scale")
                                            ? float(knobs["weather_cell_pos_scale"]) : 1.0f;
    if (weather_cell_pos_scale <= 0.001f) weather_cell_pos_scale = 1.0f;
    float weather_wrap_width_x = knobs.has("weather_wrap_width_x")
                                            ? float(knobs["weather_wrap_width_x"]) : 0.0f;
    if (weather_wrap_width_x < 0.0f) weather_wrap_width_x = 0.0f;
    const bool cold_precip_as_blizzard = knobs.has("cold_precip_as_blizzard")
                                            ? bool(knobs["cold_precip_as_blizzard"]) : true;
    float snow_classification_margin = knobs.has("snow_classification_margin")
                                            ? float(knobs["snow_classification_margin"]) : 0.03f;
    if (snow_classification_margin < 0.0f) snow_classification_margin = 0.0f;
    else if (snow_classification_margin > 0.12f) snow_classification_margin = 0.12f;
    float field_wet_terrain_precip_damping = knobs.has("field_wet_terrain_precip_damping")
                                            ? float(knobs["field_wet_terrain_precip_damping"]) : 0.60f;
    float field_lake_precip_damping = knobs.has("field_lake_precip_damping")
                                            ? float(knobs["field_lake_precip_damping"]) : 0.65f;
    float field_lake_evap_scale = knobs.has("field_lake_evap_scale")
                                            ? float(knobs["field_lake_evap_scale"]) : 0.35f;
    float field_extreme_precip_soft_cap = knobs.has("field_extreme_precip_soft_cap")
                                            ? float(knobs["field_extreme_precip_soft_cap"]) : 0.16f;
    float field_extreme_precip_softness = knobs.has("field_extreme_precip_softness")
                                            ? float(knobs["field_extreme_precip_softness"]) : 0.20f;
    float field_land_evapotranspiration_gain = knobs.has("field_land_evapotranspiration_gain")
                                            ? float(knobs["field_land_evapotranspiration_gain"]) : 0.85f;
    float field_precip_rh_threshold = knobs.has("field_precip_rh_threshold")
                                            ? float(knobs["field_precip_rh_threshold"]) : 0.70f;
    float field_ocean_precip_suppression = knobs.has("field_ocean_precip_suppression")
                                            ? float(knobs["field_ocean_precip_suppression"]) : 0.95f;
    float field_frontogenesis_gain = knobs.has("field_frontogenesis_gain")
                                            ? float(knobs["field_frontogenesis_gain"]) : 0.42f;
    float field_rain_shadow_drying = knobs.has("field_rain_shadow_drying")
                                            ? float(knobs["field_rain_shadow_drying"]) : 0.35f;
    float field_vapor_transport_gain = knobs.has("field_vapor_transport_gain")
                                            ? float(knobs["field_vapor_transport_gain"]) : 0.75f;
    if (field_wet_terrain_precip_damping < 0.0f) field_wet_terrain_precip_damping = 0.0f;
    else if (field_wet_terrain_precip_damping > 1.0f) field_wet_terrain_precip_damping = 1.0f;
    if (field_lake_precip_damping < 0.0f) field_lake_precip_damping = 0.0f;
    else if (field_lake_precip_damping > 1.0f) field_lake_precip_damping = 1.0f;
    if (field_lake_evap_scale < 0.0f) field_lake_evap_scale = 0.0f;
    else if (field_lake_evap_scale > 1.0f) field_lake_evap_scale = 1.0f;
    if (field_extreme_precip_soft_cap < 0.0f) field_extreme_precip_soft_cap = 0.0f;
    else if (field_extreme_precip_soft_cap > 1.0f) field_extreme_precip_soft_cap = 1.0f;
    if (field_extreme_precip_softness < 0.0f) field_extreme_precip_softness = 0.0f;
    else if (field_extreme_precip_softness > 1.0f) field_extreme_precip_softness = 1.0f;
    if (field_land_evapotranspiration_gain < 0.0f) field_land_evapotranspiration_gain = 0.0f;
    if (field_precip_rh_threshold < 0.40f) field_precip_rh_threshold = 0.40f;
    else if (field_precip_rh_threshold > 0.95f) field_precip_rh_threshold = 0.95f;
    if (field_ocean_precip_suppression < 0.0f) field_ocean_precip_suppression = 0.0f;
    else if (field_ocean_precip_suppression > 1.0f) field_ocean_precip_suppression = 1.0f;
    if (field_frontogenesis_gain < 0.0f) field_frontogenesis_gain = 0.0f;
    if (field_rain_shadow_drying < 0.0f) field_rain_shadow_drying = 0.0f;
    else if (field_rain_shadow_drying > 1.0f) field_rain_shadow_drying = 1.0f;
    if (field_vapor_transport_gain < 0.0f) field_vapor_transport_gain = 0.0f;
    else if (field_vapor_transport_gain > 1.0f) field_vapor_transport_gain = 1.0f;

    // ─── 平流式湿团模型旋钮 (2026-06-21 重构, 离线 _wx_advect_0621.py 标定定稿默认) ──
    // vapor/cloud_water 作随风平流的守恒物质：蒸发→vapor；凝结 vapor→cw；降水消耗 cw；
    // 干空气 cw→vapor 再蒸发。地形/气候只做弱调制(供给凝结)，不再无条件主导降水。
    // 未注入时用此默认即可让新公式工作；旋钮化接入 climate_profile/KnobsHandle 见后续提交。
    // 2026-06-21 实机迭代：第一轮(rh0.55→0.32 + base0.20→0.50 + auto0.12→0.16)经 205247 复验
    // 适得其反——land_dry 49%→83%、vapor 全面崩塌(内陆 hop4 vapor 0.185→0.085、cw 0.139→0.042)。
    // 根因：降 rh_condense 降低了【全局】凝结门槛 → 整个水汽场被过度凝结+降水抽干，内陆作为水汽
    // 输送末端枯竭最重。教训：靠"多凝结多降水"增雨是零和陷阱(消耗有限水汽，加速循环只让末端更干)。
    // 第二轮：rh_condense 回滚 0.55(止抽干)，仅保留 base_frac 0.50 + autoconv 0.16 提背景 trig
    // (离线验证提 trig 不抽干 vapor)，隔离验证"trig 提升单独是否安全改善内陆"。下一轮若仍不足，
    // 走开源(提 land_evapotranspiration_gain 增内陆本地水汽)而非继续加速循环。
    const float field_advect_vapor     = knobs.has("field_advect_vapor")     ? float(knobs["field_advect_vapor"])     : 0.95f;  // 方案③ 0.82→0.95 vapor 平流主导(水汽随风成河,蒸发源退化为注入点)
    const float field_advect_cloud     = knobs.has("field_advect_cloud")     ? float(knobs["field_advect_cloud"])     : 0.94f;
    const float field_rh_condense      = knobs.has("field_rh_condense")      ? float(knobs["field_rh_condense"])      : 0.55f;
    const float field_static_cond_w    = knobs.has("field_static_cond_w")    ? float(knobs["field_static_cond_w"])    : 1.00f;
    const float field_condense_rate    = knobs.has("field_condense_rate")    ? float(knobs["field_condense_rate"])    : 0.45f;
    const float field_lift_cond_gain   = knobs.has("field_lift_cond_gain")   ? float(knobs["field_lift_cond_gain"])   : 0.80f;
    const float field_conv_cond_gain   = knobs.has("field_conv_cond_gain")   ? float(knobs["field_conv_cond_gain"])   : 1.00f;
    // 热力对流(大陆夏季雷暴)：地表加热+本地水汽驱动凝结/降水，修复内陆 rh<<静力阈的"水汽到了却凝不成雨"死结。
    const float field_thermal_conv_cond   = knobs.has("field_thermal_conv_cond")   ? float(knobs["field_thermal_conv_cond"])   : 1.15f; // 降低静态热力云源，让移动 ψ/平流主导雨云
    const float field_thermal_conv_precip = knobs.has("field_thermal_conv_precip") ? float(knobs["field_thermal_conv_precip"]) : 0.30f; // B1(2026-06-28) 0.45→0.30 进一步削弱温度锚定原地对流雨,降水改由辐合/抬升/地形主导
    const float field_autoconversion   = knobs.has("field_autoconversion")   ? float(knobs["field_autoconversion"])   : 0.16f;
    const float field_precip_base_frac = knobs.has("field_precip_base_frac") ? float(knobs["field_precip_base_frac"]) : 0.08f;
    const float field_lift_precip_gain = knobs.has("field_lift_precip_gain") ? float(knobs["field_lift_precip_gain"]) : 0.45f; // Stage14e 0.25→0.45 迎风坡(山地)致雨增强→不再绕山
    const float field_conv_precip_gain = knobs.has("field_conv_precip_gain") ? float(knobs["field_conv_precip_gain"]) : 1.95f; // B1(2026-06-28) 1.80→1.95 提辐合致雨权重,补温度对流减弱并使 r(precip,conv)↑
    const float field_oro_precip_gain  = knobs.has("field_oro_precip_gain")  ? float(knobs["field_oro_precip_gain"])  : 0.30f;  // Stage14e 0.10→0.30 地形抬升增雨(山地迎风坡)
    // Stage11 层状降水增益：补对流暖门挡死的冷/高/水区降水(地形/锋面/海面层云),0 关闭。
    const float field_stratiform_gain  = knobs.has("field_stratiform_gain")  ? float(knobs["field_stratiform_gain"])  : 1.0f;
    // [climate-zone-fix P3] 冷季蒸发地板：temp_evap=max(floor, smoothstep(0.10,0.78,T))。0=关闭=原行为。
    // 冷季低温下 smoothstep≈0 致无水汽源→冷季锋面/层状无雨；地板给冷季基础水汽(补冬雨/降雪)。镜像 field_solver.gd。
    const float field_cool_season_vapor_floor = knobs.has("field_cool_season_vapor_floor")
                                        ? float(knobs["field_cool_season_vapor_floor"]) : 0.0f;
    const float field_cloud_reevap     = knobs.has("field_cloud_reevap")     ? float(knobs["field_cloud_reevap"])     : 0.28f;
    // 诊断式旧旋钮在平流式路径不再使用(caller 仍注入；显式吞掉避免 unused 告警)。
    (void)field_condensation_gain; (void)field_orographic_lift_gain; (void)field_convergence_gain;
    (void)field_vapor_transport_gain; (void)field_vapor_precip_sink; (void)field_precip_rh_threshold;

    // ─── Pull pre-computed PackedArrays from knobs (zero-copy reads) ────
    if (!knobs.has("cell_pos") || !knobs.has("neighbor_indices") ||
        !knobs.has("prev_vapor") || !knobs.has("prev_precip") ||
        !knobs.has("temp_transport_anomaly")) {
        diag("knobs missing required PackedArray inputs");
        return -1.0;
    }
    PackedVector2Array cell_pos_arr = knobs["cell_pos"];
    PackedInt32Array   nb_arr       = knobs["neighbor_indices"];
    PackedFloat32Array prev_vapor_arr  = knobs["prev_vapor"];
    PackedFloat32Array prev_precip_arr = knobs["prev_precip"];
    PackedFloat32Array temp_anom_arr   = knobs["temp_transport_anomaly"];
    PackedFloat32Array prev_cloud_water_arr;
    PackedFloat32Array temp_read_arr;
    PackedFloat32Array moist_read_arr;
    PackedFloat32Array snow_cover_read_arr;
    PackedFloat32Array out_vapor_arr;
    PackedFloat32Array out_cloud_arr;
    PackedFloat32Array out_cloud_water_arr;
    PackedFloat32Array out_precip_arr;
    PackedFloat32Array out_instability_arr;
    PackedFloat32Array out_intensity_arr;
    PackedFloat32Array out_convergence_arr;
    PackedInt32Array out_type_arr;
    if (knobs.has("prev_cloud_water")) {
        prev_cloud_water_arr = knobs["prev_cloud_water"];
    }
    if (knobs.has("temp_read_arr")) {
        temp_read_arr = knobs["temp_read_arr"];
    }
    if (knobs.has("moisture_read_arr")) {
        moist_read_arr = knobs["moisture_read_arr"];
    }
    if (knobs.has("snow_cover_read_arr")) {
        snow_cover_read_arr = knobs["snow_cover_read_arr"];
    }
    // 涌现式分类(2026-06-20)：温度距平(cell_temp_anomaly → map.temp_anomaly_arr)，热浪门"比常态
    // 显著偏暖"的判据。与 cell_lat_norm 同走 knobs（caller 传同一 GDScript 数组）→ 保证 bit-equal、同源。
    PackedFloat32Array temp_anomaly_cls_arr;
    if (knobs.has("temp_anomaly")) {
        temp_anomaly_cls_arr = knobs["temp_anomaly"];
    }

    if (cell_pos_arr.size() != n_cells) {
        diag("cell_pos size mismatch"); return -1.0;
    }
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells * 6 (pass requires fast_indexed)");
        return -1.0;
    }
    if (prev_vapor_arr.size()  != n_cells ||
        prev_precip_arr.size() != n_cells ||
        temp_anom_arr.size()   != n_cells) {
        diag("prev/temp_anom array size mismatch"); return -1.0;
    }
    if (prev_cloud_water_arr.size() != 0 && prev_cloud_water_arr.size() != n_cells) {
        diag("prev_cloud_water array size mismatch"); return -1.0;
    }
    if (snow_cover_read_arr.size() != 0 && snow_cover_read_arr.size() != n_cells) {
        diag("snow_cover_read_arr size mismatch"); return -1.0;
    }

    const bool use_next_outputs =
        knobs.has("out_vapor") && knobs.has("out_cloud") &&
        knobs.has("out_precip") && knobs.has("out_instability") &&
        knobs.has("out_intensity") && knobs.has("out_convergence") &&
        knobs.has("out_type");
    if (use_next_outputs) {
        out_vapor_arr       = knobs["out_vapor"];
        out_cloud_arr       = knobs["out_cloud"];
        out_precip_arr      = knobs["out_precip"];
        out_instability_arr = knobs["out_instability"];
        out_intensity_arr   = knobs["out_intensity"];
        out_convergence_arr = knobs["out_convergence"];
        out_type_arr        = knobs["out_type"];
        if (knobs.has("out_cloud_water")) {
            out_cloud_water_arr = knobs["out_cloud_water"];
        }
        if (out_vapor_arr.size()       != n_cells ||
            out_cloud_arr.size()       != n_cells ||
            out_precip_arr.size()      != n_cells ||
            out_instability_arr.size() != n_cells ||
            out_intensity_arr.size()   != n_cells ||
            out_convergence_arr.size() != n_cells ||
            out_type_arr.size()        != n_cells) {
            diag("out array size mismatch");
            return -1.0;
        }
        if (out_cloud_water_arr.size() != 0 && out_cloud_water_arr.size() != n_cells) {
            diag("out_cloud_water array size mismatch");
            return -1.0;
        }
    }

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moisture];
    Slot &s_air_anom = _slots.write[sid_air_anom];
    Slot &s_wx       = _slots.write[sid_wind_x];
    Slot &s_wy       = _slots.write[sid_wind_y];
    Slot &s_wspd     = _slots.write[sid_wind_spd];
    Slot &s_terr     = _slots.write[sid_terrain];
    Slot &s_riv      = _slots.write[sid_has_river];
    Slot *s_river_q30 = (sid_river_q30 >= 0) ? &_slots.write[sid_river_q30] : nullptr;
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_veg      = _slots.write[sid_vegetation];
    Slot *s_soil     = (sid_soil_moisture >= 0) ? &_slots.write[sid_soil_moisture] : nullptr;
    Slot *s_vitality = (sid_veg_vitality >= 0) ? &_slots.write[sid_veg_vitality] : nullptr;
    Slot *s_sea_ice  = (sid_sea_ice >= 0) ? &_slots.write[sid_sea_ice] : nullptr;
    Slot &s_wvap     = _slots.write[sid_w_vapor];
    Slot &s_wcld     = _slots.write[sid_w_cloud];
    Slot &s_wpre     = _slots.write[sid_w_precip];
    Slot &s_wins     = _slots.write[sid_w_inst];
    Slot &s_wint     = _slots.write[sid_w_intens];
    Slot &s_wcnv     = _slots.write[sid_w_conv];
    Slot &s_wtyp     = _slots.write[sid_w_type];
    Slot *s_wprev    = (sid_w_prev_type >= 0) ? &_slots.write[sid_w_prev_type] : nullptr;
    Slot *s_wtarget  = (sid_w_target_type >= 0) ? &_slots.write[sid_w_target_type] : nullptr;
    Slot *s_walpha   = (sid_w_transition_alpha >= 0) ? &_slots.write[sid_w_transition_alpha] : nullptr;
    Slot &s_wfin     = _slots.write[sid_w_finit];

    if (s_temp.arr_f32.size()     != n_cells || s_moist.arr_f32.size()  != n_cells ||
        s_air_anom.arr_f32.size() != n_cells || s_wx.arr_f32.size()     != n_cells ||
        s_wy.arr_f32.size()       != n_cells || s_wspd.arr_f32.size()   != n_cells ||
        s_terr.arr_u8.size()      != n_cells ||
        s_riv.arr_u8.size()       != n_cells || s_elev.arr_f32.size()   != n_cells ||
        s_veg.arr_u8.size()       != n_cells ||
        s_wvap.arr_f32.size()     != n_cells || s_wcld.arr_f32.size()   != n_cells ||
        s_wpre.arr_f32.size()     != n_cells || s_wins.arr_f32.size()   != n_cells ||
        s_wint.arr_f32.size()     != n_cells || s_wcnv.arr_f32.size()   != n_cells ||
        s_wtyp.arr_u8.size()      != n_cells || s_wfin.arr_u8.size()    != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }
    if (weather_transition_enabled &&
        (s_wprev == nullptr || s_wtarget == nullptr || s_walpha == nullptr ||
         s_wprev->arr_u8.size() != n_cells || s_wtarget->arr_u8.size() != n_cells ||
         s_walpha->arr_f32.size() != n_cells)) {
        diag("weather transition slot size mismatch");
        return -1.0;
    }
    if (s_river_q30 != nullptr && s_river_q30->arr_f32.size() != n_cells) {
        s_river_q30 = nullptr;
    }
    if (s_soil != nullptr && s_soil->arr_f32.size() != n_cells) {
        s_soil = nullptr;
    }
    if (s_vitality != nullptr && s_vitality->arr_f32.size() != n_cells) {
        s_vitality = nullptr;
    }
    if (s_sea_ice != nullptr && s_sea_ice->arr_f32.size() != n_cells) {
        s_sea_ice = nullptr;
    }

    // ─── Hot pointers ───────────────────────────────────────────────────
    const float   * const __restrict T    = s_temp.arr_f32.ptr();
    const float   * const __restrict M    = s_moist.arr_f32.ptr();
    const float   * const __restrict TR   = (temp_read_arr.size() == n_cells) ? temp_read_arr.ptr() : T;
    const float   * const __restrict MR   = (moist_read_arr.size() == n_cells) ? moist_read_arr.ptr() : M;
    const float   * const __restrict AA   = s_air_anom.arr_f32.ptr();
    const float   * const __restrict WX   = s_wx.arr_f32.ptr();
    const float   * const __restrict WY   = s_wy.arr_f32.ptr();
    const float   * const __restrict WSPD = s_wspd.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const uint8_t * const __restrict RIV  = s_riv.arr_u8.ptr();
    const float   * const __restrict RQ30 = (s_river_q30 != nullptr) ? s_river_q30->arr_f32.ptr() : nullptr;
    const float   * const __restrict ELEV = s_elev.arr_f32.ptr();
    const uint8_t * const __restrict VEG  = s_veg.arr_u8.ptr();
    const float   * const __restrict SOIL = (s_soil != nullptr) ? s_soil->arr_f32.ptr() : nullptr;
    const float   * const __restrict VITA = (s_vitality != nullptr) ? s_vitality->arr_f32.ptr() : nullptr;
    const float   * const __restrict SICE = (s_sea_ice != nullptr) ? s_sea_ice->arr_f32.ptr() : nullptr;

    const Vector2 * const __restrict POS  = cell_pos_arr.ptr();
    const float   * const __restrict TANO = (temp_anomaly_cls_arr.size() == n_cells) ? temp_anomaly_cls_arr.ptr() : nullptr;
    const float   * const __restrict SNOWR = (snow_cover_read_arr.size() == n_cells) ? snow_cover_read_arr.ptr() : nullptr;
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict PV   = prev_vapor_arr.ptr();
    const float   * const __restrict PP   = prev_precip_arr.ptr();
    const float   * const __restrict PCW  = (prev_cloud_water_arr.size() == n_cells) ? prev_cloud_water_arr.ptr() : nullptr;
    const float   * const __restrict TA   = temp_anom_arr.ptr();
    const float   * const __restrict PREV_CNV = s_wcnv.arr_f32.ptr();

    float   * const __restrict OUT_VAP = use_next_outputs ? out_vapor_arr.ptrw() : s_wvap.arr_f32.ptrw();
    float   * const __restrict OUT_CLD = use_next_outputs ? out_cloud_arr.ptrw() : s_wcld.arr_f32.ptrw();
    const float * const __restrict PREV_CLOUD = s_wcld.arr_f32.ptr();  // Stage15 上帧云量(供时间 EMA 平滑→减 shader 闪烁)
    float   * const __restrict OUT_CW  = (use_next_outputs && out_cloud_water_arr.size() == n_cells) ? out_cloud_water_arr.ptrw() : nullptr;
    float   * const __restrict OUT_PRE = use_next_outputs ? out_precip_arr.ptrw() : s_wpre.arr_f32.ptrw();
    float   * const __restrict OUT_INS = use_next_outputs ? out_instability_arr.ptrw() : s_wins.arr_f32.ptrw();
    float   * const __restrict OUT_INT = use_next_outputs ? out_intensity_arr.ptrw() : s_wint.arr_f32.ptrw();
    float   * const __restrict OUT_CNV = use_next_outputs ? out_convergence_arr.ptrw() : s_wcnv.arr_f32.ptrw();
    uint8_t * const __restrict OUT_TYP = use_next_outputs ? nullptr : s_wtyp.arr_u8.ptrw();
    int32_t * const __restrict OUT_TYP_I32 = use_next_outputs ? out_type_arr.ptrw() : nullptr;
    if (_wx_conv_inhib.size() != (size_t)n_cells) _wx_conv_inhib.assign((size_t)n_cells, 0.0f);
    float   * const __restrict INHIB = _wx_conv_inhib.data();  // Stage6c: ext 成员，跨 tick 持久(无 CoW 回传问题)
    uint8_t * const __restrict OUT_PREV_TYP = (!use_next_outputs && weather_transition_enabled && s_wprev != nullptr) ? s_wprev->arr_u8.ptrw() : nullptr;
    uint8_t * const __restrict OUT_TARGET_TYP = (!use_next_outputs && weather_transition_enabled && s_wtarget != nullptr) ? s_wtarget->arr_u8.ptrw() : nullptr;
    float   * const __restrict OUT_ALPHA = (!use_next_outputs && weather_transition_enabled && s_walpha != nullptr) ? s_walpha->arr_f32.ptrw() : nullptr;
    uint8_t * const __restrict OUT_FIN   = use_next_outputs ? nullptr : s_wfin.arr_u8.ptrw();

    if (start_idx == 0) {
        _advance_and_stamp_cyclones(knobs, n_cells, NB, POS, TERR, TR, WX, WY,
                                    WSPD, PV, s_wins.arr_f32.ptr(), nullptr);
    }

    // ─── 计时 (返回给调用方做对账，charter §0 铁律 3) ──────────────────
    auto t0 = std::chrono::high_resolution_clock::now();

    // S3：如实上报"生产这一天跑了 stage 11 WEATHER"。field solve 还没有共享纯内核，
    // 所以 worker 侧不会跑；但把生产跑过这件事记下来，分叉矩阵才能把 WEATHER 那 8 个
    // 字段的分叉归到"worker 缺实现"，而不是与"这天两边都没跑"混在一起。
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;

    // ── Stage13b「让天气移动」：每轮(start_idx==0)在主循环前对全场推进一次 ψ ────────────────
    // 内联进 solve pass → 与 solve 必然一起执行(不依赖 GDScript 调度挂钩、换 DLL 即生效)；全场一次→
    // 不被切片稀释。平滑引导流(风邻域平均)+纯取值半拉格朗日平移→ψ 涡旋成片随风移动。主循环只读 PSI[i]。
    if (start_idx == 0) {
        // cell_pos 的 POD 视图：解交织，逐位无损。共享内核只能吃 float lane。
        if (_wf_pos_x.size() != (size_t)n_cells) {
            _wf_pos_x.assign((size_t)n_cells, 0.0f);
            _wf_pos_y.assign((size_t)n_cells, 0.0f);
        }
        for (int p = 0; p < n_cells; ++p) {
            _wf_pos_x[(size_t)p] = POS[p].x;
            _wf_pos_y[(size_t)p] = POS[p].y;
        }
    }

    if (PSI != nullptr && start_idx == 0) {
        // 斜压门用归一化温度 TR(与主循环一致)；勿用 cell_temp slot(实际量纲→smoothstep 恒1→ψ 指数爆炸饱和)。
        pk_async_climate::SynopticAdvanceKnobs syn;
        syn.baroclinic = syn_baroclinic;
        syn.damp = syn_damp;
        syn.diffuse = syn_diffuse;
        syn.seed_rate = syn_seed_rate;
        syn.seed_amp = syn_seed_amp;
        syn.adv_cells = syn_adv_cells;
        syn.tick = syn_tick;
        syn.cell_pos_scale = weather_cell_pos_scale;
        syn.wrap_width_x = weather_wrap_width_x;
        pk_async_climate::synoptic_advance_pure(
            n_cells, NB, _wf_pos_x.data(), _wf_pos_y.data(), WX, WY, TR, syn,
            _wx_synoptic, _wx_synoptic_prev);
    }

    // ── perf P2: 邻域几何缓存构建（每轮 start_idx==0）──────────────────────
    // self->nb wrapped delta(dx,dy) + inv_dist=1/sqrt(dl2)，供主循环 aligned/
    // upstream/convergence 读取（bit-equal：同 wf_wrapped_delta/Math::sqrt 同序）。
    if (start_idx == 0) {
        const size_t need = (size_t)n_cells * 6;
        if (_wf_nb_dx.size() != need) {
            _wf_nb_dx.assign(need, 0.0f);
            _wf_nb_dy.assign(need, 0.0f);
            _wf_nb_invd.assign(need, 0.0f);
        }
        pk_async_climate::weather_field_geometry_cache_pure(
            n_cells, NB, _wf_pos_x.data(), _wf_pos_y.data(),
            weather_wrap_width_x, _wf_nb_dx.data(), _wf_nb_dy.data(),
            _wf_nb_invd.data());
        _wf_nb_geom_n = n_cells;
        _wf_nb_geom_wrap = weather_wrap_width_x;
    }
    const bool use_geom_cache =
        (_wf_nb_geom_n == n_cells && _wf_nb_geom_wrap == weather_wrap_width_x);
    const float * const __restrict GEOM_DX   = use_geom_cache ? _wf_nb_dx.data()   : nullptr;
    const float * const __restrict GEOM_DY   = use_geom_cache ? _wf_nb_dy.data()   : nullptr;
    const float * const __restrict GEOM_INVD = use_geom_cache ? _wf_nb_invd.data() : nullptr;

    // ─── stage 11 的数值核心已抽成共享纯内核 ────────────────────
    // pk_async_climate::weather_field_solve_pure。这里只做 Godot 侧的装配：
    // 把 Dictionary knob 收成 POD 结构体、把 slot/PackedArray 收成裸指针 lane、
    // 把 DCWorldExt 上那七组跳 tick 状态收成 state。循环体一行数值都不在这里了，
    // 所以 worker 跑的和生产跑的是同一份代码。
    const int32_t *TRAJ_IDX = nullptr;
    const float   *TRAJ_W   = nullptr;
    if (_phys_wind_traj_valid && _phys_wind_traj_consume_enabled
            && int(_phys_wind_traj_idx.size()) == n_cells * 3) {
        if (pk_wind_state_fp(n_cells, WX, WY, WSPD) == _phys_wind_traj_fp) {
            TRAJ_IDX = _phys_wind_traj_idx.data();
            TRAJ_W   = _phys_wind_traj_w.data();
        } else {
            ++_phys_wind_traj_stale_count;
        }
    }

    pk_async_climate::WeatherFieldKnobs wfk;
    wfk.n_cells = n_cells;
    wfk.climate_anomaly = climate_anomaly;
    wfk.refresh_convergence = refresh_convergence;
    wfk.apply_convergence_boost = apply_convergence_boost;
    wfk.use_next_outputs = use_next_outputs;
    wfk.field_advect_steps = field_advect_steps;
    wfk.field_diffusion = field_diffusion;
    wfk.field_ocean_evap_gain = field_ocean_evap_gain;
    wfk.field_precip_inertia = field_precip_inertia;
    wfk.field_precip_spatial_smooth = field_precip_spatial_smooth;
    wfk.classify_gate_land = classify_gate_land;
    wfk.classify_gate_water = classify_gate_water;
    wfk.classify_anomaly_cap = classify_anomaly_cap;
    wfk.field_cloud_inertia = field_cloud_inertia;
    wfk.field_wet_terrain_precip_damping = field_wet_terrain_precip_damping;
    wfk.field_lake_precip_damping = field_lake_precip_damping;
    wfk.field_lake_evap_scale = field_lake_evap_scale;
    wfk.field_extreme_precip_soft_cap = field_extreme_precip_soft_cap;
    wfk.field_extreme_precip_softness = field_extreme_precip_softness;
    wfk.field_land_evapotranspiration_gain = field_land_evapotranspiration_gain;
    wfk.field_ocean_precip_suppression = field_ocean_precip_suppression;
    wfk.field_frontogenesis_gain = field_frontogenesis_gain;
    wfk.field_rain_shadow_drying = field_rain_shadow_drying;
    wfk.field_advect_vapor = field_advect_vapor;
    wfk.field_advect_cloud = field_advect_cloud;
    wfk.field_rh_condense = field_rh_condense;
    wfk.field_static_cond_w = field_static_cond_w;
    wfk.field_condense_rate = field_condense_rate;
    wfk.field_lift_cond_gain = field_lift_cond_gain;
    wfk.field_conv_cond_gain = field_conv_cond_gain;
    wfk.field_thermal_conv_cond = field_thermal_conv_cond;
    wfk.field_thermal_conv_precip = field_thermal_conv_precip;
    wfk.field_autoconversion = field_autoconversion;
    wfk.field_precip_base_frac = field_precip_base_frac;
    wfk.field_lift_precip_gain = field_lift_precip_gain;
    wfk.field_conv_precip_gain = field_conv_precip_gain;
    wfk.field_oro_precip_gain = field_oro_precip_gain;
    wfk.field_stratiform_gain = field_stratiform_gain;
    wfk.field_cool_season_vapor_floor = field_cool_season_vapor_floor;
    wfk.field_cloud_reevap = field_cloud_reevap;
    wfk.weather_cell_pos_scale = weather_cell_pos_scale;
    wfk.weather_wrap_width_x = weather_wrap_width_x;
    wfk.cold_precip_as_blizzard = cold_precip_as_blizzard;
    wfk.snow_classification_margin = snow_classification_margin;
    wfk.weather_lat_te_norm = weather_lat_te_norm;
    wfk.omega_ascent_gain = OMEGA_ASCENT_GAIN;
    wfk.world_bounds_pos_y = wb_pos_y;
    wfk.world_bounds_size_y = wb_size_y;
    wfk.syn_supp = syn_supp;
    wfk.syn_enh = syn_enh;
    wfk.syn_front_force = syn_front_force;
    wfk.syn_front_enh = syn_front_enh;
    wfk.syn_base_lift = syn_base_lift;
    wfk.weather_transition_enabled = weather_transition_enabled;
    wfk.weather_transition_alpha_rate = weather_transition_alpha_rate;
    wfk.weather_transition_dt_days = weather_transition_dt_days;
    // 这两个原来在每 cell 的循环体里各查一次 Dictionary。
    wfk.thermal_monsoon_enabled = bool(knobs.get("thermal_monsoon_enabled",
        _native_runtime_config.get("thermal_monsoon_enabled", false)));
    wfk.cyclone_storm_type_id = uint8_t(
        std::clamp(int(knobs.get("cyclone_storm_type_id", 2)), 0, 255));

    pk_async_climate::WeatherFieldLanes wfl;
    wfl.temp_read = TR;
    wfl.moisture_read = MR;
    wfl.air_anomaly = AA;
    wfl.wind_x = WX;
    wfl.wind_y = WY;
    wfl.wind_speed = WSPD;
    wfl.terrain = TERR;
    wfl.has_river = RIV;
    wfl.river_q30 = RQ30;
    wfl.elevation = ELEV;
    wfl.vegetation = VEG;
    wfl.soil_moisture = SOIL;
    wfl.vitality = VITA;
    wfl.sea_ice = SICE;
    wfl.pos_x = _wf_pos_x.data();
    wfl.pos_y = _wf_pos_y.data();
    wfl.temp_anomaly = TANO;
    wfl.snow_cover = SNOWR;
    wfl.neighbor_indices = NB;
    wfl.prev_vapor = PV;
    wfl.prev_precip = PP;
    wfl.prev_cloud_water = PCW;
    wfl.temp_transport_anomaly = TA;
    wfl.prev_convergence = PREV_CNV;
    wfl.prev_cloud = PREV_CLOUD;
    wfl.out_vapor = OUT_VAP;
    wfl.out_cloud = OUT_CLD;
    wfl.out_cloud_water = OUT_CW;
    wfl.out_precip = OUT_PRE;
    wfl.out_instability = OUT_INS;
    wfl.out_intensity = OUT_INT;
    wfl.out_convergence = OUT_CNV;
    wfl.out_type_u8 = OUT_TYP;
    wfl.out_type_i32 = OUT_TYP_I32;
    wfl.out_prev_type = OUT_PREV_TYP;
    wfl.out_target_type = OUT_TARGET_TYP;
    wfl.out_alpha = OUT_ALPHA;
    wfl.out_field_init = OUT_FIN;

    pk_async_climate::WeatherFieldState wfs;
    wfs.conv_inhib = INHIB;
    wfs.psi = PSI;
    wfs.cyclone_tag = _cyclone_force_tag.empty() ? nullptr : _cyclone_force_tag.data();
    wfs.cyclone_tag_count = int(_cyclone_force_tag.size());
    wfs.cyclone_generation = _cyclone_force_generation;
    wfs.cyclone_lift = _cyclone_force_lift.empty() ? nullptr : _cyclone_force_lift.data();
    wfs.cyclone_x = _cyclone_force_x.empty() ? nullptr : _cyclone_force_x.data();
    wfs.cyclone_y = _cyclone_force_y.empty() ? nullptr : _cyclone_force_y.data();
    wfs.monsoon_thermal = _phys_monsoon_thermal.empty()
        ? nullptr : _phys_monsoon_thermal.data();
    wfs.monsoon_thermal_count = int(_phys_monsoon_thermal.size());
    wfs.traj_idx = TRAJ_IDX;
    wfs.traj_w = TRAJ_W;
    wfs.geom_dx = GEOM_DX;
    wfs.geom_dy = GEOM_DY;
    wfs.geom_invd = GEOM_INVD;

    // 记录给 worker 对拍用的输入。必须在 solve 之前：conv_inhib / ψ / 过渡三条都是
    // in/out，跑完再记就变成记结果。只在 start_idx == 0 那一次记 —— sliced 路径会把
    // 同一天切成多段调用，每段重记一次的话后面几段读到的 conv_inhib 已经是本轮改过
    // 的了。stage bit 同理只置一次。
    if (start_idx == 0) {
        pk_async_climate::SynopticAdvanceKnobs syn_rec;
        if (PSI != nullptr) {
            syn_rec.baroclinic = syn_baroclinic;
            syn_rec.damp = syn_damp;
            syn_rec.diffuse = syn_diffuse;
            syn_rec.seed_rate = syn_seed_rate;
            syn_rec.seed_amp = syn_seed_amp;
            syn_rec.adv_cells = syn_adv_cells;
            syn_rec.tick = syn_tick;
            syn_rec.cell_pos_scale = weather_cell_pos_scale;
            syn_rec.wrap_width_x = weather_wrap_width_x;
        }
        record_production_weather_input(wfk, syn_rec, PSI != nullptr, wfl, wfs,
                                       n_cells, s_wfin.arr_u8.ptr());
        _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
    }

    if (use_next_outputs && (end_idx - start_idx) >= 256) {
        // staged 路径并行（native daily）。区间 [start_idx, end_idx) → 0-based n + 偏移。
        pk::parallel_for_range("pk_weather_field", end_idx - start_idx,
            [&](int b, int e) {
                pk_async_climate::weather_field_solve_pure(
                    wfk, wfl, wfs, start_idx + b, start_idx + e);
            });
    } else {
        pk_async_climate::weather_field_solve_pure(
            wfk, wfl, wfs, start_idx, end_idx);
    }

    // §11.2 flush: push CoW-detached weather output slots back to MapData
    {
        // NS 化 Phase 2 诊断键:轨迹表消费状态进 knobs(两条 return 路径共用)。
        Dictionary &diag_knobs = const_cast<Dictionary &>(knobs);
        diag_knobs["wind_traj_used"] = (TRAJ_IDX != nullptr);
        diag_knobs["wind_traj_stale_count"] = _phys_wind_traj_stale_count;
    }
    if (use_next_outputs) {
        Dictionary &mutable_knobs = const_cast<Dictionary &>(knobs);
        mutable_knobs["out_vapor"] = out_vapor_arr;
        mutable_knobs["out_cloud"] = out_cloud_arr;
        if (out_cloud_water_arr.size() == n_cells) {
            mutable_knobs["out_cloud_water"] = out_cloud_water_arr;
        }
        mutable_knobs["out_precip"] = out_precip_arr;
        mutable_knobs["out_instability"] = out_instability_arr;
        mutable_knobs["out_intensity"] = out_intensity_arr;
        mutable_knobs["out_convergence"] = out_convergence_arr;
        mutable_knobs["out_type"] = out_type_arr;
        mutable_knobs["weather_field_wrote_next"] = true;
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }

    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_w_vapor);
        _flush_slot_to_map(sid_w_cloud);
        _flush_slot_to_map(sid_w_precip);
        _flush_slot_to_map(sid_w_inst);
        _flush_slot_to_map(sid_w_intens);
        _flush_slot_to_map(sid_w_conv);
        _flush_slot_to_map(sid_w_type);
        if (weather_transition_enabled) {
            _flush_slot_to_map(sid_w_prev_type);
            _flush_slot_to_map(sid_w_target_type);
            _flush_slot_to_map(sid_w_transition_alpha);
        }
        _flush_slot_to_map(sid_w_finit);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}
