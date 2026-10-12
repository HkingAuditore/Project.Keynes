// vegetation_climate.gdshaderinc
// Climate, vitality and phenology response of vegetation instances.
//
// Everything here depends only on the instance's cell state, so the impostor
// shader evaluates it once per vertex and hands flat colours to the fragment
// stage. The caller declares the climate appearance uniforms used below
// (dry_yellow_strength, vitality_* ...).

#ifndef PK_VEGETATION_CLIMATE_INC
#define PK_VEGETATION_CLIMATE_INC

float veg_vitality_norm(float vitality) {
	float dead_t = min(vitality_dead_threshold, vitality_healthy_threshold - 0.001);
	float healthy_t = max(vitality_healthy_threshold, dead_t + 0.001);
	return clamp((clamp(vitality, 0.0, 1.0) - dead_t) / (healthy_t - dead_t), 0.0, 1.0);
}

struct VegCellState {
	float temp;
	float moisture;
	float snow;      // snow cover incl. cold
	float vitality;
	float dry;
	float wet;
	float cold;
};

VegCellState veg_cell_state(vec4 dyn, vec4 eco, float aquatic) {
	VegCellState c;
	c.temp = dyn.r;
	c.moisture = dyn.g;
	c.vitality = mix(dyn.a, 0.86, aquatic);
	float heat = smoothstep(0.74, 0.96, c.temp);
	c.dry = clamp(max(max((0.34 - c.moisture) * 1.9, heat * 0.78), eco.g), 0.0, 1.0);
	c.wet = clamp((c.moisture - 0.50) * 1.85, 0.0, 1.0) * (1.0 - c.dry);
	c.cold = 1.0 - smoothstep(0.18, 0.42, c.temp);
	c.snow = clamp(max(dyn.b, c.cold * 0.45), 0.0, 1.0);
	return c;
}

// Foliage presence: low vitality, drought, snow and (for deciduous kinds)
// cold all thin the visible leaf mass.
float veg_presence(VegCellState c, vec4 dyn, float phen_resp) {
	float snow_hide = clamp(max(dyn.b, c.cold * 0.72), 0.0, 1.0);
	float presence = pow(veg_vitality_norm(c.vitality), vitality_alpha_power);
	presence *= 1.0 - c.dry * stress_hide_strength;
	presence *= 1.0 - snow_hide * snow_hide_strength;
	presence *= 1.0 - c.cold * stress_hide_strength * 0.42 * phen_resp;
	return clamp(presence, 0.0, 1.0);
}

struct VegPalette {
	vec3 leaf;
	vec3 red_col;
	float red_amt;   // autumn red support; elements pick it up per crown
	float snow_amt;
	float sprouting;
};

VegPalette veg_palette(vec3 base_rgb, VegCellState c, float seed, float phen_resp,
		float phen_dom, float veg_resp, float sat_gain, float val_gain) {
	float temp = c.temp;
	float moisture = c.moisture;
	float vitality_color_n = smoothstep(0.42, 0.84, c.vitality);
	float low_vitality = pow(1.0 - smoothstep(0.28, 0.68, c.vitality), 1.12);
	float heat_visual = smoothstep(0.52, 0.80, temp);
	float cool_visual = 1.0 - smoothstep(0.20, 0.44, temp);
	float dry_visual = 1.0 - smoothstep(0.15, 0.50, moisture);
	float wet_visual = smoothstep(0.50, 0.86, moisture);
	float dry_hot = heat_visual * mix(0.32, 1.0, dry_visual);
	float water_support = clamp(max(wet_visual, c.wet), 0.0, 1.0);
	float dry_pressure = clamp(max(dry_visual * 0.72, c.dry), 0.0, 1.0);
	float green_water_support = smoothstep(0.28, 0.60, moisture) * (1.0 - dry_pressure * 0.90);
	// Phenology follows the current temperature, moisture and vitality; the
	// instance seed only staggers thresholds so a cell does not flip at once.
	float climate_jitter = (fract(seed * 41.3) - 0.5) * 0.08;
	float cool_transition = smoothstep(0.16, 0.34, temp + climate_jitter)
		* (1.0 - smoothstep(0.38, 0.58, temp + climate_jitter));
	float growth_warmth = smoothstep(0.30, 0.56, temp + climate_jitter)
		* (1.0 - smoothstep(0.82, 0.97, temp));
	float growth_moisture = smoothstep(0.30, 0.68, moisture);
	float cold_decline = 1.0 - smoothstep(0.16, 0.38, temp + climate_jitter);
	float sprouting = growth_warmth * growth_moisture
		* (1.0 - smoothstep(0.62, 0.82, temp)) * vitality_color_n;
	float thriving = growth_warmth * mix(0.35, 1.0, growth_moisture)
		* (1.0 - dry_pressure * 0.82) * vitality_color_n;
	float golden = max(cool_transition * mix(0.55, 1.0, growth_moisture),
		dry_pressure * mix(0.42, 0.78, 1.0 - heat_visual));
	float withered = clamp(max(cold_decline, dry_pressure * 0.92) + low_vitality * 0.82, 0.0, 1.0);
	vec4 phenology = vec4(sprouting, thriving, golden, withered);
	phenology /= max(dot(phenology, vec4(1.0)), 0.001);
	float climate_wither_support = clamp(max(cold_decline, dry_pressure * 0.88), 0.0, 1.0);
	vec4 stage_w = vec4(
		phenology.x * vitality_color_n * smoothstep(0.26, 0.54, temp) * (1.0 - dry_pressure * 0.55),
		phenology.y * vitality_color_n * mix(0.58, 1.34, water_support),
		phenology.z * mix(0.88, 1.12, dry_yellow_strength) * (1.0 - low_vitality * 0.24)
			+ dry_pressure * (0.08 + heat_visual * 0.14),
		phenology.w * climate_wither_support + low_vitality * 0.92
			+ dry_pressure * (0.18 + dry_hot * 0.30));
	stage_w = pow(max(stage_w, vec4(0.001)), vec4(1.35));
	stage_w /= dot(stage_w, vec4(1.0));
	float green_gold_sum = max(stage_w.y + stage_w.z, 0.001);
	float green_gold_balance = (stage_w.z - stage_w.y) / green_gold_sum;
	float green_gold_seed = (fract(seed * 71.37 + 0.19) - 0.5) * 0.20;
	float gold_side = smoothstep(-0.04, 0.28, green_gold_balance + green_gold_seed);
	stage_w.y *= mix(1.0, 0.28, gold_side);
	stage_w.z *= mix(0.28, 1.0, gold_side);
	stage_w /= dot(stage_w, vec4(1.0));
	float golden_commit = smoothstep(0.48, 0.82, stage_w.z);

	vec3 rgb = base_rgb;
	float source_luma = dot(base_rgb, vec3(0.299, 0.587, 0.114));
	float canopy_detail = mix(0.78, 1.18, smoothstep(0.055, 0.34, source_luma));
	vec3 phenology_color = vec3(0.30, 0.56, 0.25) * stage_w.x
		+ vec3(0.27, 0.50, 0.24) * stage_w.y
		+ vec3(0.86, 0.66, 0.16) * stage_w.z
		+ vec3(0.58, 0.44, 0.20) * stage_w.w;
	phenology_color *= canopy_detail;
	float phenology_mix = clamp(phen_dom * phen_resp * veg_resp, 0.0, 0.94);
	rgb = mix(rgb, phenology_color, phenology_mix);

	float vitality_curve_power = mix(1.10, 0.62, vitality_color_contrast);
	float vitality_high_w = pow(vitality_color_n, vitality_curve_power) * vitality_high_color_strength;
	float vitality_low_w = pow(1.0 - vitality_color_n, vitality_curve_power) * vitality_low_color_strength;
	float cool_w = cool_visual * temperature_color_strength * 0.58;
	float heat_w = heat_visual * temperature_color_strength * heat_red_strength * 0.54;
	float dry_w = pow(dry_pressure, 1.08) * moisture_color_strength * dry_yellow_strength * 0.58;
	float wet_w = pow(water_support, 0.78) * moisture_color_strength
		* mix(wet_green_strength, lush_green_strength, vitality_color_n) * 0.58
		* green_water_support * (1.0 - golden_commit * 0.78);
	float healthy_w = vitality_high_w * (0.34 + water_support * lush_green_strength * 0.46)
		* green_water_support * (1.0 - golden_commit * 0.78);
	float decline_w = vitality_low_w * (0.48 + dry_pressure * 0.52);
	vec3 climate_target = vec3(0.48, 0.56, 0.58) * cool_w
		+ vec3(0.66, 0.47, 0.26) * heat_w
		+ vec3(0.76, 0.56, 0.18) * dry_w
		+ vec3(0.22, 0.48, 0.30) * wet_w
		+ vec3(0.22, 0.50, 0.24) * healthy_w
		+ vec3(0.58, 0.43, 0.24) * decline_w;
	float climate_total = cool_w + heat_w + dry_w + wet_w + healthy_w + decline_w;
	if (climate_total > 0.001) {
		climate_target /= climate_total;
		float climate_dominant = max(max(max(cool_w, heat_w), max(dry_w, wet_w)),
			max(healthy_w, decline_w));
		float warm_climate = max(heat_visual, dry_hot);
		float climate_mix_cap = mix(0.82, 0.66, warm_climate);
		float climate_mix = min(clamp(climate_dominant * 0.72 * veg_resp, 0.0, 0.82), climate_mix_cap);
		rgb = mix(rgb, climate_target, climate_mix);
	}
	float golden_guard = golden_commit * phen_resp * veg_resp;
	rgb = mix(rgb, vec3(0.86, 0.62, 0.14),
		clamp(golden_guard * (0.26 + dry_yellow_strength * 0.24), 0.0, 0.50));
	rgb = mix(rgb, vec3(0.56, 0.45, 0.29), dry_hot * heat_red_strength * 0.10 * veg_resp);
	rgb = mix(rgb, vec3(0.60, 0.45, 0.20),
		phenology.w * climate_wither_support * 0.14 * phen_resp * veg_resp);

	float grade_luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	float warm_grade_mix = max(heat_visual, dry_hot) * 0.82;
	float effective_saturation_gain = mix(sat_gain, sat_gain * 0.93, clamp(warm_grade_mix, 0.0, 0.86));
	float cold_grade_mix = cool_visual * temperature_color_strength * 0.90;
	effective_saturation_gain = mix(effective_saturation_gain, 0.76, clamp(cold_grade_mix, 0.0, 0.90));
	float green_axis = max(rgb.g - max(rgb.r, rgb.b), 0.0);
	float green_chroma_w = smoothstep(0.07, 0.26, green_axis)
		* clamp(wet_w + healthy_w + stage_w.y, 0.0, 1.0);
	effective_saturation_gain = mix(effective_saturation_gain,
		min(effective_saturation_gain, sat_gain * 0.88), green_chroma_w * 0.90);
	rgb = mix(vec3(grade_luma), rgb, effective_saturation_gain) * val_gain;
	rgb = clamp(rgb, vec3(0.0), vec3(1.0));
	// Keep the palette out of muddy olive: re-home it to a clear green or gold.
	float olive_chroma = smoothstep(0.10, 0.24, min(rgb.r, rgb.g) - rgb.b);
	float olive_rg_close = 1.0 - smoothstep(0.06, 0.18, abs(rgb.r - rgb.g));
	float olive_w = olive_chroma * olive_rg_close * veg_resp;
	float gold_or_dry = max(golden_commit, smoothstep(0.56, 0.80, dry_pressure));
	vec3 palette_hue = mix(vec3(0.24, 0.48, 0.25), vec3(0.78, 0.56, 0.16), gold_or_dry);
	float palette_luma = dot(palette_hue, vec3(0.299, 0.587, 0.114));
	palette_hue *= dot(rgb, vec3(0.299, 0.587, 0.114)) / max(palette_luma, 0.001);
	rgb = mix(rgb, clamp(palette_hue, vec3(0.0), vec3(1.0)), olive_w * 0.82);

	float red_climate_support = smoothstep(0.16, 0.62, cool_transition)
		* smoothstep(0.22, 0.62, growth_moisture)
		* (1.0 - smoothstep(0.68, 0.92, dry_pressure));
	VegPalette pal;
	pal.leaf = rgb;
	pal.red_amt = clamp(golden_commit * red_climate_support * phen_resp * veg_resp
		* autumn_red_strength * 1.12, 0.0, 0.74);
	pal.red_col = mix(vec3(0.74, 0.22, 0.08), vec3(0.52, 0.10, 0.05), fract(seed * 43.71));
	pal.snow_amt = clamp(c.snow * snow_white_strength, 0.0, 1.0);
	pal.sprouting = phenology.x;
	return pal;
}

#endif
