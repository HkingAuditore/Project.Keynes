import io, sys

path = r"D:\Godot\ProjectKeynes\Project.Keynes\gdext\src\world_ext_climate.cpp"
with io.open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read()

lines = text.split("\n")

# 1-based line numbers from the read: 5115 .. 5199 inclusive is the main-loop block.
start = 5115 - 1
end = 5199  # exclusive slice bound => keeps line 5200 onward

assert lines[start].strip().startswith("// \u2500\u2500\u2500 Main loop"), lines[start]
assert lines[end - 1].strip() == "run_range(0, n_cells);", lines[end - 1]

new_block = """    // \u2500\u2500\u2500 Main loop \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    // S3\uff1a\u4e0b\u6c89\u5230\u5171\u4eab\u7eaf\u5185\u6838\u3002\u539f\u5148\u8fd9\u91cc\u3001run_climate_feedback_pass_thread\u3001
    // run_stage_b_pass \u2462 \u6bb5\u662f\u4e09\u4efd\u9010\u5b57\u526f\u672c\uff0c\u6f0f\u540c\u6b65\u4efb\u4e00\u4efd\u90fd\u4f1a\u8868\u73b0\u6210\u5206\u53c9\u3002
    pk_async_climate::ClimateFeedbackKnobs fb_knobs;
    fb_knobs.ran = true;
    fb_knobs.soil_gain = soil_gain;
    fb_knobs.veg_gain = veg_gain;
    fb_knobs.scale = scale;
    fb_knobs.per_day_clamp = per_day_clamp;
    fb_knobs.ocean_drift_gain = ocean_drift_gain;
    fb_knobs.base_moisture_gain = base_m_gain;
    fb_knobs.write_weather_veg_pressure = write_weather_veg_pressure;
    fb_knobs.wt_rain_id = wt_rain_id;
    fb_knobs.wt_storm_id = wt_storm_id;
    fb_knobs.wt_monsoon_id = wt_monsoon_id;
    fb_knobs.wt_blizzard_id = wt_blizzard_id;
    fb_knobs.wt_drought_id = wt_drought_id;
    fb_knobs.wt_heatwave_id = wt_heatwave_id;
    record_production_feedback_input(fb_knobs, n_cells, IW, WTT, WTI, WTIN, TTA,
                                     BM, SOIL);
    pk_async_climate::climate_feedback_apply_pure(
        fb_knobs, IW, WTT, WTI, WTIN, NB, TTA, BM, SOIL, VG, 0, n_cells);"""

lines[start:end] = new_block.split("\n")

with io.open(path, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(lines))

print("ok")
