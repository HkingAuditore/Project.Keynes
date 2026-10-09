// climate_season.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：轨道相位、insolation 派生温度偏移、当前实时温度——所有"日历→太阳→温度"映射。
//        与 GDScript 端 map_generator._compute_temperature / _alt_penalty
//        以及 WorldClock 季节相位 SAME_SOURCE：改动必须同步 CPU 公式。
// 调用方：fragment() 顶部统一计算 eff_phase / season_offset / current_temp；
//        间接被 vegetation.gdshaderinc / snow_cover.gdshaderinc 等下游消费。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：season_phase / climate_anomaly / season_temp_amp /
//     true_insolation_enabled(兼容字段) / axial_tilt_rad /
//     insolation_daylen_amp(兼容字段) / insolation_season_gain / sea_level
// 性能（PERF）：纯 ALU，无纹理采样；单像素调用一次。
// ─────────────────────────────────────────────────────────────────────────

// ─── Phase 1：季节相位辅助 ───────────────────────────────────────────────

// Plan B：hemi_phase() 把日历 season_phase（phase=0 = 1 月）映射成
// "本地季节语义"（0=本地春, 1=本地夏, 2=本地秋, 3=本地冬），供
// vegetation_seasonal_tint 等纯视觉函数使用。
//   北半球（lat_signed < 0）: 本地春 = 4 月(sp=1) → eff = sp - 1
//   南半球（lat_signed > 0）: 本地春 = 10 月(sp=3) → eff = sp + 1
// 温度偏移只走 insolation_season_offset_shader(lat_signed, phase)，不再经过本函数。
float hemi_phase(float phase, float lat_signed) {
	return (lat_signed < 0.0) ? mod(phase + 3.0, 4.0) : mod(phase + 1.0, 4.0);
}

// ─── True Insolation-Driven（Phase F）: CPU/GPU 同源公式 ────────────────
// CPU/C++ 端 DCClimateMath / dc_insolation_* 的 GLSL 镜像。season_phase 只作为
// 年内轨道相位进入太阳直射点、日照积分与昼长；不作为独立季节温度项。
float sunset_hour_angle_shader(float lat_rad, float decl_rad) {
	if (abs(decl_rad) <= 0.000001) {
		return 1.5707963;
	}
	float polar_test = -tan(lat_rad) * tan(decl_rad);
	if (polar_test <= -1.0) {
		return 3.1415927;
	}
	if (polar_test >= 1.0) {
		return 0.0;
	}
	return acos(polar_test);
}

float compute_insolation_shader(float lat_rad, float phase) {
	float year_progress = mod(phase, 4.0) / 4.0;
	// phase=0(1月) → +tilt（南向 subsolar，北半球冬至）；phase=2(7月) → -tilt。
	float subsolar = axial_tilt_rad * cos(6.2831853 * year_progress);
	float h0 = sunset_hour_angle_shader(lat_rad, subsolar);
	if (h0 <= 0.000001) {
		return 0.0;
	}
	float daily = h0 * sin(lat_rad) * sin(subsolar)
		+ cos(lat_rad) * cos(subsolar) * sin(h0);
	return clamp(daily, 0.0, 1.0);
}

float insolation_annual_mean_shader(float lat_rad) {
	float acc = 0.0;
	for (int s = 0; s < 16; s++) {
		float sample_phase = (float(s) + 0.5) * 0.25;
		acc += compute_insolation_shader(lat_rad, sample_phase);
	}
	return acc * 0.0625;
}

float insolation_season_offset_shader(float lat_signed, float phase) {
	// lat_signed ∈ [-1, 1] → lat_rad ∈ [-π/2, π/2]
	float lat_rad = lat_signed * 1.5707963;
	float now_val = compute_insolation_shader(lat_rad, phase);
	float mean_val = insolation_annual_mean_shader(lat_rad);
	float dev_abs = now_val - mean_val;
	float dev_rel = clamp(dev_abs / max(mean_val, 0.18), -1.0, 1.0);
	float polar_w = smoothstep(0.55, 0.90, abs(lat_signed)) * 0.55;
	float dev = dev_abs + (dev_rel - dev_abs) * polar_w;
	return insolation_season_gain * dev * season_temp_amp;
}

// 统一入口：无条件走 insolation 派生。true_insolation_enabled 只保留给旧材质
// 参数兼容，不能再切回独立余弦季节温度项。
float season_offset_unified(float lat_signed, float phase) {
	return insolation_season_offset_shader(lat_signed, phase);
}

// 当前实时温度：[0, 1]。和 map_generator._compute_temperature 同公式：
// lat_temp = pow(cos(lat_signed * π/2), 1.2) - alt_penalty(elev)
// 然后叠 + season_offset + climate_anomaly
// 2026-05-18 雪线修正：alt_penalty 改双段式，与 GDScript _alt_penalty 严格 SAME_SOURCE。
//   lin = elev * 0.55；hi = smoothstep(0.45, 1.0, elev) * 0.30
//   高山顶（elev=0.85）总扣减 ≈ 0.467 + 0.198 ≈ 0.665（vs 旧 0.425），
//   赤道高山温度从 ≈ 0.575 跌到 ≈ 0.335，立刻进入雪线分支。
float compute_current_temp(float elev, float lat_signed, float season_offset) {
	float lat_temp = pow(max(cos(lat_signed * 1.5707963), 0.0), 1.2);
	float alt_pen_lin = elev * 0.55;
	float alt_pen_hi = smoothstep(0.45, 1.0, elev) * 0.30;
	float alt_penalty = alt_pen_lin + alt_pen_hi;
	return clamp(lat_temp + season_offset + climate_anomaly - alt_penalty, 0.0, 1.0);
}
