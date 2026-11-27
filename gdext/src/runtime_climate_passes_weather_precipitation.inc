        // 降水：autoconversion 消耗 cloud_water。动力(辐合/抬升/不稳定)触发主导，地形弱增强；
        // 背景 base_frac 很小 → 无动力区降水压到 wet 阈值以下 → 只有移动天气系统处成雨 → 雨随系统移动。
        float trig = field_autoconversion * (field_precip_base_frac
                        + lift_pos * field_lift_precip_gain
                        + convergence * field_conv_precip_gain
                        + frontogenesis * 0.85f
                        + instability * 0.30f);
        trig *= (1.0f + lift_pos * field_oro_precip_gain);
        trig += convective * field_thermal_conv_precip;   // 对流雨高效成雨，旁路 autoconv 瓶颈(内陆 cw 少)
        trig += ocean_convective * 0.95f;
        trig += stratiform * 0.80f;   // Stage11 层状降水高效成雨(冷/高/水区,旁路 autoconv)→修 #4湖/#5a雪/#6山
        trig += cyclone_lift * 0.75f;
        trig += psi_lift * 1.50f;     // 方案③+ 1.10→1.50 ψ 致雨主驱动(降水成片随 ψ 平移,盖过静止 lift)
        trig += oro_elev * 0.18f * wf_smoothstep(0.02f, 0.10f, cloud_water);  // 弱化固定地形转化，保留迎风坡但不锁死雨核
        trig *= psi_supp;             // Stage14 ψ<0 压低降水→移动晴空
        if (trig < 0.0f) trig = 0.0f;
        else if (trig > 0.95f) trig = 0.95f;
        float precip_target = cloud_water * trig;
        precip_target *= omega_precip_mult;   // Stage1 omega: ITCZ/风暴轴增雨 + 副热带下沉抑雨(纬向廓线)
        // Stage9 #5 ψ 耦合：ψ<0(高压)强抑雨→湿季间断；ψ>0(低压)增雨——基础弱(syn_enh，热带也仅此)，
        // 斜压带额外强增(syn_front_enh×gate)→冷季锋面雨。这样热带不堆暴雨、中纬冷季出现雨热不同期降水。
        if (PSI != nullptr) {
            float syn_enh_eff = syn_enh + syn_front_enh * baroclinic_gate;
            float syn_mult = 1.0f + (psi < 0.0f ? psi * syn_supp : psi * syn_enh_eff);
            if (syn_mult < 0.0f) syn_mult = 0.0f;
            precip_target *= syn_mult;
        }
        // Stage6e 对流抑制记忆(双稳)：读累积抑制(本 tick 起始)，硬阈压制移到最终降水处(EMA 之后)。
        const float inhib_old = (INHIB != nullptr) ? INHIB[i] : 0.0f;
        if (lift < 0.0f) {
            float shadow = (-lift) * field_rain_shadow_drying;
            if (shadow > 0.85f) shadow = 0.85f;
            precip_target *= (1.0f - shadow);
        }
        if (has_river && river_recycle_lock > 0.0f) {
            const float river_relief = river_recycle_lock
                * (1.0f - wf_smoothstep(0.22f, 0.50f, dynamic_forcing));
            if (river_relief > 0.0f) {
                const float cloud_relief = cloud_water * 0.22f * river_relief;
                cloud_water -= cloud_relief;
                vapor += cloud_relief * 0.60f;
                precip_target *= (1.0f - 0.48f * river_relief);
            }
        }
        // 水面对流抑制(保留动力门控：辐合/锋生/暖流异常 释放降水；instability 仅极端深对流安全阀)。
        float ocean_drive = 0.0f;
        if (on_water) {
            float drv_an = ocean_an / 0.16f;
            if (drv_an < 0.0f) drv_an = 0.0f; else if (drv_an > 1.0f) drv_an = 1.0f;
            float drv_in = (instability - 0.52f) / 0.30f;
            if (drv_in < 0.0f) drv_in = 0.0f; else if (drv_in > 1.0f) drv_in = 1.0f;
            // W3：旧 (0.38,0.16) 是按 p50=0.376 标的；新场用 (p50, p90-p50)=(0.02, 0.44)。
            float drv_cv = (convergence - 0.02f) / 0.44f;
            if (drv_cv < 0.0f) drv_cv = 0.0f; else if (drv_cv > 1.0f) drv_cv = 1.0f;
            float drv_fr = frontogenesis / 0.16f;
            if (drv_fr < 0.0f) drv_fr = 0.0f; else if (drv_fr > 1.0f) drv_fr = 1.0f;
            float drv_mn = coastal_monsoon_flux / 0.18f;
            if (drv_mn < 0.0f) drv_mn = 0.0f; else if (drv_mn > 1.0f) drv_mn = 1.0f;
            float drv_hc = wf_smoothstep(0.47f, 0.69f, relative_humidity)
                * wf_smoothstep(0.040f, 0.105f, cloud_water)
                * wf_smoothstep(0.54f, 0.74f, temp);
            // Stage14e 湖泊不再额外压低 humid-convective 驱动(原 ×0.60 致湖面少雨绕湖)；湖泊像小内海正常对流。
            drv_hc *= 0.68f;
            ocean_drive = drv_an;
            if (drv_in > ocean_drive) ocean_drive = drv_in;
            if (drv_cv > ocean_drive) ocean_drive = drv_cv;
            if (drv_fr > ocean_drive) ocean_drive = drv_fr;
            if (drv_mn > ocean_drive) ocean_drive = drv_mn;
            if (drv_hc > ocean_drive) ocean_drive = drv_hc;
            if (omega_ascent > ocean_drive) ocean_drive = omega_ascent;   // ITCZ/风暴轴释放海面抑制
            float precip_suppression = field_ocean_precip_suppression;
            if (is_lake && precip_suppression > 0.10f) precip_suppression = 0.10f;  // Stage14e 湖泊几乎不抑制(像内陆水体能下雨)→不再绕湖(原0.35仍压制)
            if (!is_lake && precip_suppression > 0.78f) precip_suppression = 0.78f;
            const float ocean_lo = 1.0f - precip_suppression;
            precip_target *= ocean_lo + (1.0f - ocean_lo) * ocean_drive;
            const float marine_relief = post_rain_subsidence
                * (1.0f - wf_smoothstep(0.30f, 0.58f, ocean_drive));
            precip_target *= (1.0f - marine_relief * 0.72f);
        }
        if (precip_target > cloud_water) precip_target = cloud_water;   // 降水不超过现有云水
        if (precip_target < 0.0f) precip_target = 0.0f;
        cloud_water -= precip_target;
        if (cloud_water < 0.0f) cloud_water = 0.0f;
        const float precip_cloud_reserve = precip_target * (0.18f + dynamic_forcing * 0.18f);
        cloud_water += precip_cloud_reserve;
        if (cloud_water > 1.0f) cloud_water = 1.0f;
        const float quiet_core = 1.0f - wf_smoothstep(0.12f, 0.50f, dynamic_forcing);
        if (on_water && !is_lake && ocean_drive < 0.34f) {   // Stage14e 湖泊不刮云水(marine_scour 是海洋机制,会让小湖云存不住→绕湖)
            float marine_scour = cloud_water * (0.036f + (0.34f - ocean_drive) * 0.18f)
                               * (1.0f + post_rain_subsidence * 1.60f);
            if (marine_scour < 0.0f) marine_scour = 0.0f;
            if (marine_scour > cloud_water) marine_scour = cloud_water;
            cloud_water -= marine_scour;
            vapor += marine_scour * 0.55f;
        }

        // 干空气云水再蒸发回 vapor（湿团边缘消散 → 闭合水量收支）。
        float reevap = cloud_water * field_cloud_reevap * (1.0f - relative_humidity)
                     * (1.0f + post_rain_subsidence * 1.75f + quiet_core * 0.75f);
        if (reevap < 0.0f) reevap = 0.0f;
        if (reevap > cloud_water) reevap = cloud_water;
        cloud_water -= reevap;
        vapor += reevap;
        if (on_water) {
            vapor *= (1.0f - post_rain_subsidence
                * (1.0f - wf_smoothstep(0.28f, 0.58f, ocean_drive)) * 0.045f);
        }

        // 降水稳定性(地形阻尼 + 极端 soft cap) + EMA 时间惯性(保留)。
        precip_target = wf_apply_precip_stability(
            TERR[i], precip_target,
            field_wet_terrain_precip_damping,
            field_lake_precip_damping,
            field_extreme_precip_soft_cap,
            field_extreme_precip_softness);
        // Stage10 不应期(inhib≥1)作用于 target(EMA 前)→降水随惯性平滑衰减到近零，不再瞬间砍断(去时间跳变)。镜像 field_solver.gd。
        if (inhib_old >= 1.0f) {
            precip_target *= (1.0f - INHIB_STRENGTH);
        }
        float precip = PP[i] + (precip_target - PP[i]) * field_precip_inertia;
        if (precip_target < PP[i] && dynamic_forcing < 0.20f) {
            precip = precip + (precip_target - precip) * (post_rain_subsidence * 0.55f);
        }
        // Stage10b 空间平滑(非对称)：强填洞(precip<邻域→去棋盘洞+扩雨到干邻格，降永晴)、弱削峰(×0.30→保超级单体暴雨)。镜像 field_solver.gd。
        if (field_precip_spatial_smooth > 0.0f) {
            const float nbr_precip = wf_neighbor_average_vapor_idx(i, NB, PP);
            const float k = (nbr_precip > precip) ? field_precip_spatial_smooth
                                                  : field_precip_spatial_smooth * 0.30f;
            precip += (nbr_precip - precip) * k;
        }
        const float effective_precip_floor = on_water ? 0.014f : 0.018f;
        if (precip < 0.003f) precip = 0.0f;
        const float provisional_cloud = dc_clampf(cloud_water * 1.10f + condensation * 0.25f, 0.0f, 1.0f);
        // W6：分类器温度距平。W6 之前 TANO 在 native daily 路径恒为 nullptr（计划 F13），
        // 所以 DROUGHT/HEATWAVE 两条分支结构性不可达；host 现在会填 lane，这里加钳制。
        float temp_anom_i = (TANO != nullptr) ? TANO[i] : 0.0f;
        {
            const float cap = knobs.classify_anomaly_cap;
            if (temp_anom_i > cap) temp_anom_i = cap;
            else if (temp_anom_i < -cap) temp_anom_i = -cap;
        }
        const float snow_cover_cls = (SNOWR != nullptr) ? SNOWR[i] : 0.0f;
        uint8_t pre_wt = wf_classify_field_weather_at(
            temp, vapor, provisional_cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls,
            knobs.classify_gate_land, knobs.classify_gate_water);
        const bool quiet_non_precip = !wf_is_precip_weather_type(pre_wt) && quiet_core > 0.0f;
        if ((precip < 0.003f || quiet_non_precip) && quiet_core > 0.0f) {
            float clear_cap = 0.065f + dynamic_forcing * 0.12f;
            if (on_water && ocean_drive < 0.20f) {
                const float ocean_cap = 0.070f + ocean_drive * 0.18f;
                if (ocean_cap < clear_cap) clear_cap = ocean_cap;
            }
            if (cloud_water > clear_cap) {
                const float excess_cloud_water = (cloud_water - clear_cap) * quiet_core;
                cloud_water -= excess_cloud_water;
                vapor += excess_cloud_water * 0.75f;
            }
        }
        if (quiet_non_precip && precip < effective_precip_floor) {
            vapor += precip * 0.65f;
            precip = 0.0f;
        }
        if (vapor < 0.0f) vapor = 0.0f;
        else if (vapor > 1.0f) vapor = 1.0f;   // 写回夹 [0,1]：下游(分类/可视/植被)按归一化消费
        float vapor_after_precip = vapor;
        const float rain_core = wf_smoothstep(0.025f, 0.095f, precip);
        const float front_core = wf_smoothstep(0.08f, 0.55f, frontogenesis);
        float cloud_floor = rain_core * (0.14f + rain_core * 0.22f);
        const float front_cloud_floor = front_core * 0.30f;
        if (front_cloud_floor > cloud_floor) cloud_floor = front_cloud_floor;
        if (convective > 0.0f) {
            const float convective_cloud_floor = 0.06f + convective * 0.18f;
            if (convective_cloud_floor > cloud_floor) cloud_floor = convective_cloud_floor;
        }
        if (ocean_convective > 0.0f) {
            const float ocean_cloud_floor = 0.10f + ocean_convective * 0.16f;
            if (ocean_cloud_floor > cloud_floor) cloud_floor = ocean_cloud_floor;
        }
        if (quiet_non_precip) {
            const float fair_humid = wf_smoothstep(0.34f, 0.56f, relative_humidity);
            const float fair_cloud_floor = fair_humid * quiet_core * (0.050f + fair_humid * 0.070f);
            if (fair_cloud_floor > cloud_floor) cloud_floor = fair_cloud_floor;
        }
        float cloud = cloud_water * 1.10f + condensation * 0.25f;
        if (cloud < cloud_floor) cloud = cloud_floor;
        // Stage15 云量时间 EMA(减 shader 闪烁)：cloud 混入瞬时 condensation/cloud_floor(无时间惯性)→在渲染阈值
        // 附近抖动闪烁。用上帧云量做 EMA 平滑(cloud_water 本身已平滑,只需压住瞬时项的抖)。
        const float prev_cloud = PREV_CLOUD[i];
        cloud = prev_cloud + (cloud - prev_cloud) * field_cloud_inertia;
        if (cloud < 0.0f) cloud = 0.0f;
        else if (cloud > 1.0f) cloud = 1.0f;

        // classify + intensity
        uint8_t wt = wf_classify_field_weather_at(
            temp, vapor, cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls,
            knobs.classify_gate_land, knobs.classify_gate_water);
        if (cyclone_lift >= 0.58f && on_water && wf_is_precip_weather_type(wt)) {
            wt = cyclone_storm_type_id;
        }
        if (!wf_is_precip_weather_type(wt) && precip > 0.0f) {
            vapor += precip * 0.65f;
            if (vapor > 1.0f) vapor = 1.0f;
            vapor_after_precip = vapor;
            precip = 0.0f;
        } else if (precip > 0.0f) {
            // Stage6 放电：实际降水抽干本格水汽→自发停雨/消散+随上风水汽移动+海面自生成。镜像 field_solver.gd。
            // Stage6b：持续降水(PP[i])放电翻倍→砍"连下一周"长尾，不动新生短雨段。
            const float discharge_amp = 1.0f + DISCHARGE_SUSTAIN * wf_smoothstep(0.04f, 0.10f, PP[i]);
            vapor_after_precip -= precip * VAPOR_DISCHARGE * discharge_amp;
            if (vapor_after_precip < 0.0f) vapor_after_precip = 0.0f;
        }
        // Stage6g 更新对流抑制(按时长两段)：充能期连续降水累加→满进不应期；不应期衰减→落回清零重启。镜像 field_solver.gd。
        if (INHIB != nullptr) {
            float ni;
            if (inhib_old >= 1.0f) {
                ni = inhib_old - INHIB_REFRAC;
                if (ni < 1.0f) ni = 0.0f;
            } else if (precip > INHIB_WET) {
                ni = inhib_old + INHIB_CHARGE;
                if (ni >= 1.0f) ni = 2.0f;
            } else {
                ni = inhib_old * INHIB_LEAK;
            }
            INHIB[i] = ni;
        }
        float intensity = wf_field_intensity_for_type(
            wt, temp, vapor, cloud, precip, instability, ocean_an);
        if (refresh_convergence && apply_convergence_boost) {
            wf_apply_frontal_convergence_boost_idx(
                i, TR, AA, NB, climate_anomaly, convergence,
                temp, vapor, ocean_an, cloud_water, on_water,
                on_water ? knobs.classify_gate_water : knobs.classify_gate_land,
                cloud, precip, instability, wt, intensity);
        }

        uint8_t display_wt = wt;
        if (weather_transition_enabled && OUT_PREV_TYP != nullptr && OUT_TARGET_TYP != nullptr && OUT_ALPHA != nullptr) {
            const uint8_t current_display = OUT_TYP[i];
            uint8_t prev_type = OUT_PREV_TYP[i];
            uint8_t target_type = OUT_TARGET_TYP[i];
            float alpha = OUT_ALPHA[i];
            if (alpha < 0.0f) alpha = 0.0f;
            else if (alpha > 1.0f) alpha = 1.0f;
            if (target_type != wt) {
                prev_type = current_display;
                target_type = wt;
                alpha = weather_transition_alpha_rate * weather_transition_dt_days; // [dt-aware] 当前求解即计入
                if (alpha > 1.0f) alpha = 1.0f;
            } else if (prev_type == target_type || current_display == target_type) {
                prev_type = target_type;
                alpha = 0.0f;
            } else {
                alpha += weather_transition_alpha_rate * weather_transition_dt_days;
                if (alpha > 1.0f) alpha = 1.0f;
            }
            display_wt = (alpha >= 1.0f) ? target_type : prev_type;
            if (alpha >= 1.0f) {
                prev_type = target_type;
                alpha = 0.0f;
            }
            OUT_PREV_TYP[i] = prev_type;
            OUT_TARGET_TYP[i] = target_type;
            OUT_ALPHA[i] = alpha;
        }
