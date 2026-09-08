import io

path = r"D:\Godot\ProjectKeynes\Project.Keynes\gdext\src\world_ext_climate.cpp"
with io.open(path, "r", encoding="utf-8", newline="") as f:
    lines = f.read().split("\n")

start = next(i for i, l in enumerate(lines)
             if l.strip().startswith("// \u2500\u2500\u2500 Main loop\uff08\u4e0e run_climate_feedback_pass"))
# block ends at the line "        }" closing the for loop, right before the blank line
# then "        // \u5199\u56de in/out arrays"
end_marker = next(i for i in range(start, len(lines))
                  if lines[i].strip().startswith("// \u5199\u56de in/out arrays"))
# back off the blank line before the marker
end = end_marker
while lines[end - 1].strip() == "":
    end -= 1
assert lines[end - 1] == "        }", repr(lines[end - 1])

new_block = """        // \u2500\u2500\u2500 Main loop \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
        // S3\uff1a\u4e0e run_climate_feedback_pass \u4e00\u540c\u4e0b\u6c89\u5230\u5171\u4eab\u7eaf kernel\u3002\u8fd9\u91cc\u539f\u5148\u662f\u7b2c\u4e09\u4efd
        // \u9010\u5b57\u526f\u672c\uff0c\u800c\u5b83\u624d\u662f\u751f\u4ea7 native_daily \u8def\u5f84\u4e0a\u771f\u6b63\u8dd1\u7684\u90a3\u4e00\u4efd\u3002
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
        record_production_feedback_input(fb_knobs, n_cells, IW, WTT, WTI, WTIN,
                                        TTA, BM, SOIL);
        pk_async_climate::climate_feedback_apply_pure(
            fb_knobs, IW, WTT, WTI, WTIN, NB, TTA, BM, SOIL, VGP, 0, n_cells);"""

lines[start:end] = new_block.split("\n")

with io.open(path, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(lines))

print("replaced", start + 1, "..", end)
