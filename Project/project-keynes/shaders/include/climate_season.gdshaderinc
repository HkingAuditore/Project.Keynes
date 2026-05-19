// climate_season.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：季节相位、insolation 派生温度偏移、当前实时温度——所有"日历→温度"映射。
//        与 GDScript 端 map_generator._compute_temperature / _alt_penalty
//        以及 WorldClock 季节相位 SAME_SOURCE：改动必须同步 CPU 公式。
// 调用方：fragment() 顶部统一计算 eff_phase / season_offset / current_temp；
//        间接被 vegetation.gdshaderinc / snow_cover.gdshaderinc 等下游消费。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：season_phase / climate_anomaly / season_temp_amp /
//     true_insolation_enabled / axial_tilt_rad / insolation_daylen_amp /
//     insolation_season_gain / sea_level
// 性能（PERF）：纯 ALU，无纹理采样；单像素调用一次。
// ─────────────────────────────────────────────────────────────────────────

// ─── Phase 1：季节相位辅助 ───────────────────────────────────────────────

// Plan B：hemi_phase() 把日历 season_phase（phase=0 = 1 月）映射成
// "本地季节语义"（0=本地春, 1=本地夏, 2=本地秋, 3=本地冬），供
// vegetation_seasonal_tint 等纯视觉函数使用。
//   北半球（lat_signed < 0）: 本地春 = 4 月(sp=1) → eff = sp - 1
//   南半球（lat_signed > 0）: 本地春 = 10 月(sp=3) → eff = sp + 1
// 温度偏移走 season_temp_offset_legacy(lat_signed, phase)，不再经过本函数。
float hemi_phase(float phase, float lat_signed) {
	return (lat_signed < 0.0) ? mod(phase + 3.0, 4.0) : mod(phase + 1.0, 4.0);
}

// 季节温度偏移（Plan B 日历对齐）：cos((phase - 2) × π/2) × amp × hemi_sign
// phase=0(1月) 北半球: -amp（冬）；phase=2(7月) 北半球: +amp（夏）
// 【Legacy / 回退路径】：仅在 true_insolation_enabled == false 时使用。
float season_temp_offset(float phase) {
	return cos((phase - 2.0) * 1.5707963) * season_temp_amp;
}

float season_temp_offset_legacy(float lat_signed, float phase) {
	float hemi_sign = (lat_signed < 0.0) ? 1.0 : ((lat_signed > 0.0) ? -1.0 : 0.0);
	return cos((phase - 2.0) * 1.5707963) * season_temp_amp * hemi_sign;
}

// ─── True Insolation-Driven（Phase F）: CPU/GPU 同源公式 ────────────────
// CPU 端 _compute_insolation / _insolation_season_offset 的 GLSL 镜像。
// 为了单像素可接受的性能，年均 insolation 采用解析近似：
//   insol_annual_mean(lat) ≈ cos(lat) · (1 − ε²/4)
// 非极区误差 < 5%，极区稍大但视觉上不会被玩家察觉；真正的物理权威仍在 CPU。
float compute_insolation_shader(float lat_rad, float phase) {
	float year_progress = mod(phase, 4.0) / 4.0;
	// Plan B：phase=0(1月) → +tilt（南向 subsolar，北半球冬至）；phase=2(7月) → -tilt。
	float subsolar = axial_tilt_rad * cos(6.2831853 * year_progress);
	float cos_zenith = max(cos(lat_rad - subsolar), 0.0);
	float lat_sign = (lat_rad > 0.0) ? 1.0 : ((lat_rad < 0.0) ? -1.0 : 0.0);
	// 2026-05-19 BUGFIX：与 climate_math.gd::compute_insolation 同步——原 '1 - amp...'
	// 符号写反，导致南北半球季节响应反转（北半球夏天结冰）。修正为 '1 + amp...'。
	// 验证：7月 北纬45° (lat_sign=-1, cos=-1) → 1 + 0.35·(-1)·(-1) = 1.35（夏季昼长） ✓
	float daylen = 1.0 + insolation_daylen_amp * cos(6.2831853 * year_progress) * lat_sign;
	return clamp(cos_zenith * daylen, 0.0, 1.0);
}

float insolation_annual_mean_shader(float lat_rad) {
	// cos(lat) × (1 − ε²/4) 的解析近似
	float c = max(cos(lat_rad), 0.0);
	return c * (1.0 - axial_tilt_rad * axial_tilt_rad * 0.25);
}

float insolation_season_offset_shader(float lat_signed, float phase) {
	// lat_signed ∈ [-1, 1] → lat_rad ∈ [-π/2, π/2]
	float lat_rad = lat_signed * 1.5707963;
	float now_val = compute_insolation_shader(lat_rad, phase);
	float mean_val = max(insolation_annual_mean_shader(lat_rad), 1e-4);
	float dev = clamp((now_val - mean_val) / mean_val, -1.0, 1.5);
	return insolation_season_gain * dev * season_temp_amp;
}

// 统一入口：true_insolation_enabled 打开时走 insolation 派生；
// 关闭时走 legacy 日历对齐后的 cos 公式，保持旧画面完全一致。
float season_offset_unified(float lat_signed, float phase) {
	if (true_insolation_enabled) {
		return insolation_season_offset_shader(lat_signed, phase);
	}
	return season_temp_offset_legacy(lat_signed, phase);
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
