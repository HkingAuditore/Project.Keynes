from pathlib import Path
p=Path('Project/project-keynes/shaders/trade_vehicle.gdshader'); s=p.read_text(encoding='utf-8').replace('uniform float vehicle_height = 3.0;','uniform float vehicle_height = 1.0;').replace('uniform float shadow_max_length = 15.0;','uniform float shadow_max_length = 1.5;').replace('uniform vec2 shadow_footprint = vec2(0.9, 0.65);','uniform vec2 shadow_footprint = vec2(0.86, 0.48);')
s=s.replace('\tvec2 expanded = vec2(1.0);\n','')
s=s.replace('''		shift *= min(1.0, shadow_max_length / max(length(shift), 0.001));
		vec2 offset_local = vec2(dot(shift, direction), dot(shift, across)) / scale;
		expanded += abs(offset_local);''','''		// A compact contact shadow: keep the ellipse near the vehicle footprint,
		// even at low sun or when the sprite is capped in screen space.
		float max_shift = min(shadow_max_length, vehicle_size * 0.06);
		shift *= min(1.0, max_shift / max(length(shift), 0.001));''')
s=s.replace('vec2 local = VERTEX * expanded * scale;', 'vec2 local = VERTEX * scale;')
p.write_text(s,encoding='utf-8')
p=Path('Project/project-keynes/scripts/ui/ui_tokens.gd'); s=p.read_text(encoding='utf-8').replace('const TRADE_VEHICLE_HEIGHT := 3.0','const TRADE_VEHICLE_HEIGHT := 1.0').replace('const TRADE_SHADOW_MAX_LENGTH := 15.0','const TRADE_SHADOW_MAX_LENGTH := 1.5').replace('const TRADE_SHADOW_FOOTPRINT := Vector2(0.9, 0.65)','const TRADE_SHADOW_FOOTPRINT := Vector2(0.86, 0.48)'); p.write_text(s,encoding='utf-8')
p=Path('docs/cpp-dots-runtime/trade-visual-runtime.md'); s=p.read_text(encoding='utf-8').replace('根据当地太阳方向和高度偏移、伸长，长度有上限。','椭圆长宽贴近载具占地，不随太阳高度继续放大；仅按太阳方向小幅偏移，\n投影向量上限取 1.5 世界单位与载具长度 6% 中的较小值。'); p.write_text(s,encoding='utf-8')
