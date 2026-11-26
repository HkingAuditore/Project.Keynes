    // ── climate_stage_knobs：ACTIVE 下 worker 自己到不了的那几个 stage ─────
    //
    // 这些 stage 不在 climate round 里 —— 它们跑在 native daily graph 的 stage_b 段、
    // 各有自己的 stride，输入也不全在 environment 快照里（catalog 查表、跨 tick 缓存、
    // 生产 builder 里的硬编码阈值）。SHADOW 下它们的输入来自生产的 reference publish，
    // 所以 GDScript 只在 worker 权威时才填这个字典（见
    // map_generator.gd::_build_runtime_climate_stage_knobs）；字典非空本身就等于
    // "今天 weather 轮到期"。
    if (inputs.has("climate_stage_knobs") &&
        inputs["climate_stage_knobs"].get_type() == Variant::DICTIONARY) {
        const Dictionary stage_knobs = inputs["climate_stage_knobs"];
        // stage 11 后半段 weather distribute —— snow_cover / snowpack /
        // water_balance_30d 的当日最后一个写者。缺了它这三条恒为 0，而 sea_ice 与
        // albedo 都读 snow_cover，缺口会一路往下游传。
        //
        // 键名口径必须与生产 run_weather_distribute_pass（world_ext_weather.cpp）
        // 逐一对应：GDScript 那侧的 build_distribute_knobs_for_worker 是生产同一个
        // builder 的薄包装，两边对同一个键取不同值就是一次静默分叉。默认值同理，
        // 那几个 snowpack / snowline 阈值在生产侧也是 has() 三元的形式。
        if (stage_knobs.has("stage_distribute") &&
            stage_knobs["stage_distribute"].get_type() == Variant::DICTIONARY) {
            const Dictionary d = stage_knobs["stage_distribute"];
            auto wd = std::make_shared<pk_async_climate::WeatherDistributeInput>();
            wd->n_cells = static_cast<int>(cells);
            wd->ran = true;
            // 两条积雪计数在 ACTIVE 下由 worker 跨天自持：它们是 HexCell 的 AoS
            // 字段、没有 SoA 镜像，既不在快照里也不经回灌回到 MapData，而生产
            // distribute 正是被抑制的那一方 —— 每天拿它那份不再推进的缓存播种会让
            // snow_accum_days_req 永远攒不满，snow_cover 于是恒为 0。
            wd->own_snow_state = true;
            const auto kf = [&d](const char *key, float fallback) {
                return d.has(key) ? float(d[key]) : fallback;
            };
            const auto ki = [&d](const char *key, int fallback) {
                return d.has(key) ? int(d[key]) : fallback;
            };
            auto &k = wd->knobs;
            k.n_cells = static_cast<int>(cells);
            k.snow_min_intensity = kf("snow_min_intensity", 0.0f);
            k.snow_freeze_t = kf("snow_freeze_t", 0.0f);
            k.snow_melt_t = kf("snow_melt_t", 0.0f);
            k.snow_intensity_snow = kf("snow_intensity_for_snowing", 0.0f);
            k.snow_accum_days_req = ki("snow_accum_days_req", 0);
            k.flood_heavy_int = kf("flood_heavy_intensity", 0.0f);
            k.flood_heavy_pre = kf("flood_heavy_precip", 0.0f);
            k.flood_low_int = kf("flood_lowland_intensity", 0.0f);
            k.flood_low_elev = kf("flood_lowland_elev", 0.0f);
            k.flood_low_moist = kf("flood_lowland_moisture", 0.0f);
            k.wt_clear = ki("wt_clear", 0);
            k.cv_snow = ki("cv_snow", 0);
            k.cv_none = ki("cv_none", 0);
            k.cv_flooding = ki("cv_flooding", 0);
            k.snowpack_accum_gain = kf("snowpack_accum_gain", 0.10f);
            k.snowpack_melt_temp_gain = kf("snowpack_melt_temp_gain", 0.22f);
            k.snowpack_melt_sun_gain = kf("snowpack_melt_sun_gain", 0.12f);
            k.snowpack_cover_low = kf("snowpack_cover_low", 0.05f);
            k.snowpack_cover_full = kf("snowpack_cover_full", 0.32f);
            k.snowline_temp_threshold = kf("snowline_temp_threshold", 0.24f);
            k.snowline_band = kf("snowline_band", 0.22f);
            float anomaly_cap = kf("weather_temp_anomaly_cap", 0.025f);
            if (anomaly_cap < 0.0f) anomaly_cap = 0.0f;
            else if (anomaly_cap > 0.10f) anomaly_cap = 0.10f;
            k.weather_temp_anomaly_cap = anomaly_cap;
            k.direct_moisture_enabled =
                bool(d.get("weather_direct_moisture_enabled", false));
            // 四张 WeatherType 剖面表都是定长 8。长度不对就整份不发：内核对它们
            // 只按 wt id 索引、不做范围检查。
            bool tables_ok = true;
            const auto table_f32 = [&d, &tables_ok](const char *key, float *out_tab) {
                const Variant raw = d.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedFloat32Array v = raw;
                if (v.size() != 8) {
                    tables_ok = false;
                    return;
                }
                std::memcpy(out_tab, v.ptr(), 8 * sizeof(float));
            };
            const auto table_u8 = [&d, &tables_ok](const char *key, uint8_t *out_tab) {
                const Variant raw = d.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_BYTE_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedByteArray v = raw;
                if (v.size() != 8) {
                    tables_ok = false;
                    return;
                }
                std::memcpy(out_tab, v.ptr(), 8);
            };
            table_f32("temp_delta_arr", k.temp_delta);
            table_f32("moisture_delta_arr", k.moist_delta);
            table_u8("can_form_snow_arr", k.can_form_snow);
            table_u8("can_form_flood_arr", k.can_form_flood);
            // 读 lane 走 environment 快照（与生产读 _slots 同一份数据）。temp /
            // moisture / snow_cover / snowpack / water_balance_30d 与 weather 四条
            // 不在这里：内核用 worker 自己 store 那一份，见 runtime_climate_kernel.cpp
            // 里 shared_distribute_ran 那一段。守卫仍要求它们齐长，所以照填。
            wd->heat = snapshot.cell_heat_input;
            wd->elevation = snapshot.cell_elevation;
            wd->landform = snapshot.landform;
            wd->terrain = snapshot.terrain;
            wd->weather_intensity = snapshot.cell_weather_intensity;
            wd->weather_precip = snapshot.cell_weather_precip;
            wd->weather_type = snapshot.cell_weather_type;
            wd->cover = snapshot.cover;
            wd->soil_moisture = snapshot.cell_soil_moisture;
            // weather_field_init 没有快照 lane。worker 侧的 field solve 总走 direct
            // 语义（一定写 field_init=1），内核也用自己的 scratch 覆盖它 —— 这里
            // 只是把守卫喂饱。
            wd->weather_field_init.assign(cells, 1u);
            const auto lane_i32 = [&d, cells](const char *key,
                                              std::vector<int32_t> &out_vec) {
                const Variant raw = d.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_INT32_ARRAY) return;
                const PackedInt32Array v = raw;
                if (static_cast<size_t>(v.size()) != cells) return;
                out_vec.assign(v.ptr(), v.ptr() + v.size());
            };
            lane_i32("accumulated_snow_days", wd->accumulated_snow_days);
            lane_i32("pre_snow_cover", wd->pre_snow_cover);
            // own_snow_state 下这两条只用于首日播种，缺席时从零起算即可 —— 但长度
            // 必须齐，否则整个 stage 撞守卫静默跳过。
            if (wd->accumulated_snow_days.size() != cells) {
                wd->accumulated_snow_days.assign(cells, 0);
            }
            if (wd->pre_snow_cover.size() != cells) {
                wd->pre_snow_cover.assign(cells, 0);
            }
                if (tables_ok) {
                    snapshot.climate_weather_distribute = wd;
                }
            }

            // ── stage 11 前半段 weather field solve ──────────────────────
            //
            // vapor / cloud_water / precip 这条降水循环的驱动。缺了它 moisture 只
            // 被 distribute 的 moist_delta 和 feedback 零散推一下，表现是跳变而不是
            // 连续演化 —— 而且 distribute 读的 weather 四条也就一直是 field solve
            // 没写过的值。
            //
            // 键名口径对生产 run_weather_field_solve_pass（world_ext_weather.cpp:299
            // 起解析、:792 起收进 wfk）。默认值与 clamp 都要照抄：ClimateProfile 给
            // 越界值时只有 clamp 能让两侧落在同一个数上，而少一次 clamp 不会有任何
            // 人报错。
        if (stage_knobs.has("stage_weather") &&
            stage_knobs["stage_weather"].get_type() == Variant::DICTIONARY) {
                const Dictionary d = stage_knobs["stage_weather"];
                auto wx = std::make_shared<pk_async_climate::WeatherFieldInput>();
                wx->n_cells = static_cast<int>(cells);
                wx->ran = true;
                // conv_inhib / field_init 跨天由 worker 自持：ACTIVE 下生产的对流
                // 抑制不再推进，每天拿它那份重置等于把这条记忆抹平，对流会一直从
                // "无抑制"起步；field_init 被覆盖则水汽循环整场起不来（见
                // runtime_climate_kernel.cpp:1048 起的两段注释）。
                wx->own_field_state = true;

                const auto kf = [&d](const char *key, float fallback) {
                    return d.has(key) ? float(d[key]) : fallback;
                };
                const auto ki = [&d](const char *key, int fallback) {
                    return d.has(key) ? int(d[key]) : fallback;
                };
                const auto kb = [&d](const char *key, bool fallback) {
                    return d.has(key) ? bool(d[key]) : fallback;
                };
                const auto lo = [](float v, float min_v) {
                    return v < min_v ? min_v : v;
                };
                const auto clamp_f = [](float v, float min_v, float max_v) {
                    return v < min_v ? min_v : (v > max_v ? max_v : v);
                };

                auto &k = wx->knobs;
                k.n_cells = static_cast<int>(cells);
                k.climate_anomaly = kf("climate_anomaly", 0.0f);
                k.refresh_convergence = kb("refresh_convergence", false);
                k.apply_convergence_boost = kb("apply_convergence_boost", true);
                // staged 语义：内核把 prev_* 复制到独立缓冲后再解算（kernel:1042），
                // 与生产 staged 路径一致。
                k.use_next_outputs = true;
                k.field_advect_steps = ki("field_advect_steps", 3);
                k.classify_anomaly_cap =
                    clamp_f(kf("weather_classify_anomaly_cap", 0.12f), 0.0f, 0.5f);
                k.classify_gate_land = clamp_f(
                    kf("weather_precip_classify_gate_land", 0.040f), 0.0f, 0.5f);
                k.classify_gate_water = clamp_f(
                    kf("weather_precip_classify_gate_water", 0.032f), 0.0f, 0.5f);
                k.field_diffusion = kf("field_diffusion", 0.04f);
                k.field_ocean_evap_gain = kf("field_ocean_evap_gain", 0.55f);
                k.field_precip_inertia =
                    clamp_f(kf("field_precip_inertia", 0.40f), 0.05f, 1.0f);
                k.field_precip_spatial_smooth =
                    clamp_f(kf("field_precip_spatial_smooth", 0.30f), 0.0f, 0.8f);
                k.field_cloud_inertia =
                    clamp_f(kf("field_cloud_inertia", 0.74f), 0.05f, 1.0f);
                k.field_wet_terrain_precip_damping = clamp_f(
                    kf("field_wet_terrain_precip_damping", 0.60f), 0.0f, 1.0f);
                k.field_lake_precip_damping =
                    clamp_f(kf("field_lake_precip_damping", 0.65f), 0.0f, 1.0f);
                k.field_lake_evap_scale =
                    clamp_f(kf("field_lake_evap_scale", 0.35f), 0.0f, 1.0f);
                k.field_extreme_precip_soft_cap =
                    clamp_f(kf("field_extreme_precip_soft_cap", 0.16f), 0.0f, 1.0f);
                k.field_extreme_precip_softness =
                    clamp_f(kf("field_extreme_precip_softness", 0.20f), 0.0f, 1.0f);
                k.field_land_evapotranspiration_gain =
                    lo(kf("field_land_evapotranspiration_gain", 0.85f), 0.0f);
                k.field_ocean_precip_suppression = clamp_f(
                    kf("field_ocean_precip_suppression", 0.95f), 0.0f, 1.0f);
                k.field_frontogenesis_gain =
                    lo(kf("field_frontogenesis_gain", 0.42f), 0.0f);
                k.field_rain_shadow_drying =
                    clamp_f(kf("field_rain_shadow_drying", 0.35f), 0.0f, 1.0f);
                k.field_advect_vapor = kf("field_advect_vapor", 0.95f);
                k.field_advect_cloud = kf("field_advect_cloud", 0.94f);
                k.field_rh_condense = kf("field_rh_condense", 0.55f);
                k.field_static_cond_w = kf("field_static_cond_w", 1.00f);
                k.field_condense_rate = kf("field_condense_rate", 0.45f);
                k.field_lift_cond_gain = kf("field_lift_cond_gain", 0.80f);
                k.field_conv_cond_gain = kf("field_conv_cond_gain", 1.00f);
                k.field_thermal_conv_cond = kf("field_thermal_conv_cond", 1.15f);
                k.field_thermal_conv_precip =
                    kf("field_thermal_conv_precip", 0.30f);
                k.field_autoconversion = kf("field_autoconversion", 0.16f);
                k.field_precip_base_frac = kf("field_precip_base_frac", 0.08f);
                k.field_lift_precip_gain = kf("field_lift_precip_gain", 0.45f);
                k.field_conv_precip_gain = kf("field_conv_precip_gain", 1.95f);
                k.field_oro_precip_gain = kf("field_oro_precip_gain", 0.30f);
                k.field_stratiform_gain = kf("field_stratiform_gain", 1.0f);
                k.field_cool_season_vapor_floor =
                    kf("field_cool_season_vapor_floor", 0.0f);
                k.field_cloud_reevap = kf("field_cloud_reevap", 0.28f);
                float pos_scale = kf("weather_cell_pos_scale", 1.0f);
                if (pos_scale <= 0.001f) pos_scale = 1.0f;
                k.weather_cell_pos_scale = pos_scale;
                k.weather_wrap_width_x =
                    lo(kf("weather_wrap_width_x", 0.0f), 0.0f);
                k.cold_precip_as_blizzard = kb("cold_precip_as_blizzard", true);
                k.snow_classification_margin =
                    clamp_f(kf("snow_classification_margin", 0.03f), 0.0f, 0.12f);
                k.weather_lat_te_norm = kf("weather_lat_te_norm", 0.5f);
                if (d.has("thermal_equator_capture_bounds")) {
                    const Rect2 bounds = d["thermal_equator_capture_bounds"];
                    const PackedFloat32Array temp = d["temp_read_arr"];
                    const PackedVector2Array positions = d["cell_pos"];
                    if (!std::isfinite(bounds.position.y) || !std::isfinite(bounds.size.y)) {
                        out["ok"] = false;
                        out["code"] = "runtime_weather_equator_bounds_invalid";
                        return out;
                    }
                    // If the original slice lacked a complete sample it used 0.5.
                    if (bounds.size.y > 0.001 && cells > 0 &&
                        static_cast<size_t>(temp.size()) == cells &&
                        static_cast<size_t>(positions.size()) == cells) {
                        auto sample = std::make_shared<pk_async_climate::WeatherThermalEquatorInput>();
                        sample->bounds_y = bounds.position.y;
                        sample->bounds_height = bounds.size.y;
                        sample->temperature.assign(temp.ptr(), temp.ptr() + cells);
                        sample->pos_y.resize(cells);
                        const Vector2 *pos = positions.ptr();
                        for (size_t i = 0; i < cells; ++i) {
                            if (!std::isfinite(pos[i].y)) {
                                out["ok"] = false;
                                out["code"] = "runtime_weather_equator_position_invalid";
                                return out;
                            }
                            sample->pos_y[i] = pos[i].y;
                        }
                        wx->captured_thermal_equator = std::move(sample);
                    }
                }
                // 键名例外：struct 叫 omega_ascent_gain，字典键带 field_ 前缀。
                k.omega_ascent_gain = kf("field_omega_ascent_gain", 0.40f);
                k.world_bounds_pos_y = kf("world_bounds_pos_y", 0.0f);
                k.world_bounds_size_y = kf("world_bounds_size_y", 0.0f);
                // 五个 syn_* 的字典键是 weather_synoptic_* —— 这五条是 ψ 的耦合
                // 强度（不是 ψ 的演化参数，那些在 SynopticAdvanceKnobs 里）。
                k.syn_supp = kf("weather_synoptic_supp", 0.75f);
                k.syn_enh = kf("weather_synoptic_enh", 0.45f);
                k.syn_front_force = kf("weather_synoptic_front_force", 0.55f);
                k.syn_front_enh = kf("weather_synoptic_front_enh", 0.70f);
                k.syn_base_lift = kf("weather_synoptic_base_lift", 1.55f);
                k.weather_transition_enabled =
                    kb("weather_transition_enabled", false);
                k.weather_transition_alpha_rate =
                    clamp_f(kf("weather_transition_alpha_rate", 1.0f), 0.0f, 1.0f);
                k.weather_transition_dt_days =
                    clamp_f(kf("weather_transition_dt_days", 1.0f), 0.0f, 30.0f);
                k.thermal_monsoon_enabled = kb("thermal_monsoon_enabled", false);
                int storm_id = ki("cyclone_storm_type_id", 2);
                if (storm_id < 0) storm_id = 0;
                else if (storm_id > 255) storm_id = 255;
                k.cyclone_storm_type_id = static_cast<uint8_t>(storm_id);

                // ψ 的演化参数。synoptic_enabled 的生产默认是 true。
                wx->synoptic_enabled = kb("weather_synoptic_enabled", true);
                auto &s = wx->synoptic;
                s.baroclinic = kf("weather_synoptic_baroclinic", 0.40f);
                s.damp = kf("weather_synoptic_damp", 0.90f);
                s.diffuse = kf("weather_synoptic_diffuse", 0.05f);
                s.seed_rate = kf("weather_synoptic_seed_rate", 0.015f);
                s.seed_amp = kf("weather_synoptic_seed_amp", 0.42f);
                s.adv_cells = ki("weather_synoptic_adv_cells", 3);
                s.tick = ki("weather_solve_tick", 0);
                s.cell_pos_scale = pos_scale;
                s.wrap_width_x = k.weather_wrap_width_x;

                // 守卫要求齐长的 13 条 lane（kernel:993 起）。少一条整段静默跳过，
                // 而它与 distribute 共用 stage 11 的 bit，所以 stage-days 上看不出来。
                wx->temp_read = snapshot.cell_temp;
                // W6：分类温度距平 = temp − temp_30d。此前从未赋值 ⇒ TANO 恒 nullptr ⇒
                // DROUGHT/HEATWAVE 不可达（计划 F13）。冷启动 30d 缺失时退回 0。
                if (snapshot.cell_temp_30d.size() == cells) {
                    wx->temp_anomaly.resize(cells);
                    for (size_t i = 0; i < cells; ++i) {
                        wx->temp_anomaly[i] = snapshot.cell_temp[i] - snapshot.cell_temp_30d[i];
                    }
                }
                wx->moisture_read = snapshot.cell_moisture;
                wx->air_anomaly = snapshot.cell_air_mass_temp_anomaly;
                wx->wind_x = snapshot.cell_wind_x;
                wx->wind_y = snapshot.cell_wind_y;
                wx->wind_speed = snapshot.cell_wind_speed;
                // B8 P2：把 weather field solve 的另外两条直接输入接上。
                // traj 已通过生产的指纹/资格校验（capture 直接调用同一个 accessor），
                // 为空就是"这一次不该消费"，worker 走 hopping。monsoon 是主线程
                // 物理求解的派生量，求解器迁走之前它仍是输入而不是 worker 的状态。
                wx->traj_idx = snapshot.cell_wind_traj_idx;
                wx->traj_w = snapshot.cell_wind_traj_w;
                wx->monsoon_thermal = snapshot.cell_monsoon_thermal;
                // B8-2：cyclone 冷启动种子 + 推进参数。genesis 仍在主线程，所以
                // 这里搬的是"当前活跃条目"，worker 接管后自行推进/衰减/stamp。
                snapshot.cyclone_seed_blob = runtime_cyclone_state_blob();
                snapshot.cyclone_enabled =
                    kb("native_tropical_cyclone_enabled", false);
                snapshot.cyclone_dt_days = kf("weather_transition_dt_days", 1.0f);
                snapshot.cyclone_max_radius_cells =
                    ki("tropical_cyclone_max_radius_cells", 5);
                snapshot.cyclone_world_bounds_pos_y =
                    kf("world_bounds_pos_y", 0.0f);
                snapshot.cyclone_world_bounds_size_y =
                    kf("world_bounds_size_y", 1.0f);
                snapshot.cyclone_wrap_width_x =
                    kf("weather_wrap_width_x", 0.0f);
                snapshot.cyclone_storm_type_id = ki("cyclone_storm_type_id", -1);
                snapshot.cyclone_capacity =
                    ki("tropical_cyclone_capacity", 24);
                snapshot.cyclone_births_per_commit =
                    ki("tropical_cyclone_births_per_commit", 2);
                snapshot.cyclone_min_temp =
                    kf("tropical_cyclone_min_temp", 0.58f);
                snapshot.cyclone_min_instability =
                    kf("tropical_cyclone_min_instability", 0.40f);
                snapshot.cyclone_max_shear =
                    kf("tropical_cyclone_max_shear", 0.42f);
                snapshot.cyclone_min_lat =
                    kf("tropical_cyclone_min_lat", 0.06f);
                snapshot.cyclone_max_lat =
                    kf("tropical_cyclone_max_lat", 0.40f);
                snapshot.cyclone_wake_days =
                    kf("cyclone_wake_days", 32.0f);
                wx->elevation = snapshot.cell_elevation;
                wx->pos_x = snapshot.cell_pos_x;
                wx->pos_y = snapshot.cell_pos_y;
                wx->temp_transport_anomaly =
                    snapshot.cell_temperature_transport_anomaly;
                wx->terrain = snapshot.terrain;
                wx->has_river = snapshot.has_river;
                wx->vegetation = snapshot.vegetation;
                // 可选 lane：内核对它们各有无值分支。
                wx->river_q30 = snapshot.cell_river_discharge_30d;
                wx->soil_moisture = snapshot.cell_soil_moisture;
                wx->vitality = snapshot.cell_vegetation_vitality;
                wx->sea_ice = snapshot.cell_sea_ice_frac_prev;
                wx->snow_cover = snapshot.cell_snow_cover;
                // B8-2：synoptic ψ 现在由 worker 自持。这里只把生产当天 solve 读到
                // 的 ψ 作为**冷启动种子**传过去（worker 第一次见到该 lane 时播种，
                // 之后自己推进）。风场仍是输入：物理环流求解器还在主线程（P2），
                // 所以这不是"worker 缺状态"，而是"worker 用当天风场推进自己的 ψ"。
                //
                // cyclone / monsoon / traj 仍留空：cyclone 的跨天扰动表在生产成员
                // 里，monsoon/traj 的写者还没迁；它们的待办见台账
                // tools/runtime/climate_field_ownership.json 的 extra_policy_fields。
                if (wx->synoptic_enabled && _wx_synoptic.size() == cells) {
                    wx->psi = _wx_synoptic;
                    if (_wx_synoptic_prev.size() == cells) {
                        wx->psi_prev = _wx_synoptic_prev;
                    }
                } else {
                    wx->psi.clear();
                    wx->psi_prev.clear();
                }

                snapshot.climate_weather = wx;

                // 邻居表：weather 与 feedback 的守卫都读 static knobs 那一份，而它在
                // environment 走 CSR 形式时会被上面的长度守卫清空。字典这份是生产
                // 校验过的定长 6N，正好补上。
                if (snapshot.climate_round_static_knobs.neighbor_indices.size() !=
                        cells * 6u) {
                    const Variant raw = d.get("neighbor_indices", Variant());
                    if (raw.get_type() == Variant::PACKED_INT32_ARRAY) {
                        const PackedInt32Array nb = raw;
                        if (static_cast<size_t>(nb.size()) == cells * 6u) {
                            snapshot.climate_round_static_knobs.neighbor_indices
                                .assign(nb.ptr(), nb.ptr() + nb.size());
                        }
                    }
                }
            }

        // stage_b 段的三个 stage（albedo / vegetation_dynamics / climate_feedback）
        // 共用一份 knobs 字典 —— 生产那侧就是 run_stage_b_pass(knobs) 一次吃三段，
        // 各自由 run_* 标志按自己的 stride 开合。GDScript 侧复用了生产同一个
        // builder（_build_native_daily_stage_b_knobs），所以这里的键名与
        // run_stage_b_pass 逐一对应。
        const Dictionary stage_b =
            (stage_knobs.has("stage_b") &&
             stage_knobs["stage_b"].get_type() == Variant::DICTIONARY)
                ? Dictionary(stage_knobs["stage_b"]) : Dictionary();

        // stage 8 albedo —— temp 的日内最后一个写者。它是内联结构而不是 shared_ptr：
        // 只有五个标量，albedo_table 本身是 round 不变量、走 static knobs。
        // run_albedo 为假就是"这个 stride 今天没到期"，ran 留 false 让 worker 也不跑。
        if (bool(stage_b.get("run_albedo", false))) {
            auto &alb = snapshot.climate_albedo;
            alb.ran = true;
            alb.reference_albedo = stage_b.has("reference_albedo")
                ? float(stage_b["reference_albedo"]) : 0.0f;
            alb.temp_gain = stage_b.has("albedo_temp_gain")
                ? float(stage_b["albedo_temp_gain"]) : 0.0f;
            alb.snow_cover_albedo = stage_b.has("snow_cover_albedo")
                ? float(stage_b["snow_cover_albedo"]) : 0.75f;
            alb.cover_snow_id =
                static_cast<uint8_t>(int(stage_b.get("cover_snow_id", 1)));
            alb.cover_glacier_id =
                static_cast<uint8_t>(int(stage_b.get("cover_glacier_id", 2)));
        }

        // stage 10 climate_feedback —— vegetation_growth_pressure 的写者之一。它还
        // 写 base_moisture 与 soil_moisture，但那两条没有 worker store 成员，内核用
        // scratch 承接初值后丢弃，所以这里记的是生产口径的初值。
        //
        // 六个 weather 枚举 id 在生产侧是必填（缺一个就整段拒跑），这里同样：没被
        // 记录时 knobs 默认的 -1 与任何真实 weather_type 都不相等，效果是这段白跑。
        if (bool(stage_b.get("run_feedback", false))) {
            auto fb = std::make_shared<pk_async_climate::ClimateFeedbackInput>();
            fb->n_cells = static_cast<int>(cells);
            auto &k = fb->knobs;
            k.ran = true;
            const auto bf = [&stage_b](const char *key, float fallback) {
                return stage_b.has(key) ? float(stage_b[key]) : fallback;
            };
            const auto bi = [&stage_b](const char *key, int fallback) {
                return stage_b.has(key) ? int(stage_b[key]) : fallback;
            };
            k.soil_gain = bf("soil_gain", 0.0f);
            k.veg_gain = bf("veg_gain", 0.0f);
            k.scale = bf("scale", 1.0f);
            k.per_day_clamp = bf("per_day_clamp", 0.0f);
            k.ocean_drift_gain = bf("ocean_drift_gain", 0.0f);
            k.base_moisture_gain = bf("weather_to_base_moisture_gain", 0.0f);
            k.write_weather_veg_pressure =
                bool(stage_b.get("write_weather_veg_pressure", true));
            k.wt_rain_id = bi("wt_rain_id", -1);
            k.wt_storm_id = bi("wt_storm_id", -1);
            k.wt_monsoon_id = bi("wt_monsoon_id", -1);
            k.wt_blizzard_id = bi("wt_blizzard_id", -1);
            k.wt_drought_id = bi("wt_drought_id", -1);
            k.wt_heatwave_id = bi("wt_heatwave_id", -1);

            fb->is_water = snapshot.is_water;
            fb->weather_type = snapshot.cell_weather_type;
            fb->weather_intensity = snapshot.cell_weather_intensity;
            fb->temp_transport_anomaly =
                snapshot.cell_temperature_transport_anomaly;
            fb->base_moisture = snapshot.cell_base_moisture;
            fb->soil_moisture = snapshot.cell_soil_moisture;
            // 与 distribute 同一条：weather_field_init 没有快照 lane，而 worker 侧
            // field solve 总走 direct 语义（一定写 1）。
            fb->weather_field_init.assign(cells, 1u);
            snapshot.climate_feedback = fb;
        }

        // stage 9 vegetation_dynamics —— vegetation_growth_pressure 的另一个写者，
        // 也是 plant_available_water / vitality / 两条 streak 的写者。它要的八张查表
        // 来自 GDScript 的 vegetation catalog，worker 侧没有任何获取途径，只能整份
        // 随字典过来（好在它们是 round 不变量，builder 每次给的是同一份）。
        if (bool(stage_b.get("run_veg_dyn", false))) {
            auto vd = std::make_shared<pk_async_climate::VegetationDynamicsInput>();
            vd->n_cells = static_cast<int>(cells);
            auto &k = vd->knobs;
            k.ran = true;
            const auto bf = [&stage_b](const char *key, float fallback) {
                return stage_b.has(key) ? float(stage_b[key]) : fallback;
            };
            const auto bi = [&stage_b](const char *key, int fallback) {
                return stage_b.has(key) ? int(stage_b[key]) : fallback;
            };
            // day_scale 先过 max(1.0) 再存，与生产同一口径。
            const float day_scale_raw = bf("day_scale", 1.0f);
            k.scale = day_scale_raw < 1.0f ? 1.0f : day_scale_raw;
            k.streak_days = bi("streak_days", 0);
            k.vitality_change_rate = bf("vitality_change_rate", 0.0f);
            k.compat_harshness = bf("compat_harshness", 1.0f);
            k.low_threshold = bf("low_threshold", 0.0f);
            k.high_threshold = bf("high_threshold", 1.0f);
            k.succession_degrade_days = bi("succession_degrade_days", 0);
            k.succession_upgrade_days = bi("succession_upgrade_days", 0);
            k.n_wt = bi("n_wt", 0);
            k.wt_clear_id = bi("wt_clear_id", 0);
            k.veg_none_id = static_cast<uint8_t>(bi("veg_none_id", 0));
            k.weather_penalty_scale = bf("weather_penalty_scale", 1.0f);
            k.plant_water_balance_weight = bf("plant_water_balance_weight", 0.0f);
            k.plant_soil_buffer_weight = bf("plant_soil_buffer_weight", 0.0f);
            k.plant_drought_penalty = bf("plant_drought_penalty", 0.0f);
            k.succession_min_compat_gain = bf("succession_min_compat_gain", 0.0f);
            k.low_vitality_damping_threshold =
                bf("vegetation_low_vitality_damping_threshold", 0.40f);
            k.succession_cooldown_days =
                bi("vegetation_succession_cooldown_days", 30);
            k.degrade_reset_target =
                bf("vegetation_degrade_reset_target", 0.75f);
            k.stress_enabled = bool(stage_b.get("vegetation_stress_enabled", false));
            // stress_blend 生产侧算好再存，两侧各做一次除法会差 ULP。
            float memory_days = bf("vegetation_stress_memory_days", 30.0f);
            if (memory_days < 1.0f) memory_days = 1.0f;
            float blend = k.scale / memory_days;
            if (blend < 0.0f) blend = 0.0f;
            else if (blend > 1.0f) blend = 1.0f;
            k.stress_blend = blend;
            k.wt_blizzard_id = bi("wt_blizzard_id", 3);
            k.wt_drought_id = bi("wt_drought_id", 4);
            k.wt_heatwave_id = bi("wt_heatwave_id", 6);

            bool tables_ok = k.n_wt > 0;
            const auto table_f32 = [&stage_b, &tables_ok](
                    const char *key, std::vector<float> &out_vec) {
                const Variant raw = stage_b.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedFloat32Array v = raw;
                if (v.size() <= 0) {
                    tables_ok = false;
                    return;
                }
                out_vec.assign(v.ptr(), v.ptr() + v.size());
            };
            const auto table_u8 = [&stage_b, &tables_ok](
                    const char *key, std::vector<uint8_t> &out_vec) {
                const Variant raw = stage_b.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_BYTE_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedByteArray v = raw;
                if (v.size() <= 0) {
                    tables_ok = false;
                    return;
                }
                out_vec.assign(v.ptr(), v.ptr() + v.size());
            };
            table_f32("ideal_temp_table", vd->ideal_temp);
            table_f32("ideal_moist_table", vd->ideal_moist);
            table_f32("temp_tol_table", vd->temp_tol);
            table_f32("moist_tol_table", vd->moist_tol);
            table_f32("weather_penalty_table", vd->weather_penalty);
            table_f32("resistance_table", vd->resistance);
            table_u8("next_up_table", vd->next_up);
            table_u8("next_down_table", vd->next_down);
            // 表维度由表长决定（生产也是这么推的）：n_veg 看 ideal_temp，
            // wt_pen_size 可以大于 n_wt。
            k.n_veg = static_cast<int32_t>(vd->ideal_temp.size());
            k.wt_pen_size = static_cast<int32_t>(vd->weather_penalty.size());
            if (k.n_veg <= 0 ||
                static_cast<size_t>(k.n_veg) * static_cast<size_t>(k.n_wt) >
                    vd->resistance.size()) {
                tables_ok = false;
            }

            vd->is_water = snapshot.is_water;
            vd->terrain = snapshot.terrain;
            vd->landform = snapshot.landform;
            vd->vegetation = snapshot.vegetation;
            vd->temp_30d = snapshot.cell_temp_30d;
            vd->moisture = snapshot.cell_moisture;
            vd->water_balance_30d = snapshot.cell_water_balance_30d;
            vd->soil_moisture = snapshot.cell_soil_moisture;
            vd->has_soil_moisture = vd->soil_moisture.size() == cells;
            vd->weather_type = snapshot.cell_weather_type;
            vd->weather_intensity = snapshot.cell_weather_intensity;
            vd->weather_field_init.assign(cells, 1u);
            vd->has_growth_pressure = true;
            // regen_score 没有 store 成员也没有快照 lane，内核用 scratch 承接初值后
            // 丢弃。stress_enabled 时守卫要求它齐长，所以从零起算 —— 与生产读到的
            // 初值有一次性差异，但这条量不参与任何跨天累积。
            if (k.stress_enabled) {
                vd->regen_score.assign(cells, 0.0f);
            }

            if (tables_ok) {
                snapshot.climate_vegetation = vd;
            }
        }
    }
