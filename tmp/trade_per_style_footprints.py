from pathlib import Path
r=Path('Project/project-keynes')
p=r/'scripts/ui/ui_tokens.gd'; s=p.read_text(encoding='utf-8')
s=s.replace('const TRADE_VEHICLE_HEIGHT := 1.0','const TRADE_SHADOW_HEIGHT_RATIO := 0.12').replace('const TRADE_SHADOW_MAX_LENGTH := 1.5','const TRADE_SHADOW_MAX_LENGTH_RATIO := 0.60').replace('const TRADE_SHADOW_FOOTPRINT := Vector2(0.86, 0.48)','const TRADE_SHADOW_FOOTPRINT := Vector2(0.95, 0.90)')
boxes=[(82,87,444,196),(33,81,480,200),(53,49,476,186),(38,52,480,180),(23,30,490,194),(1,0,497,212),(25,28,481,192),(8,41,496,178),(60,41,453,194),(3,37,495,191),(24,43,483,176),(0,31,497,180)]
names=['搬运队','独木舟','马车','木船','篷车','帆船','蒸汽时代货队','蒸汽船','早期货车','机动货船','现代货车','货轮']
meta='''# 图集各格中实际图像的 UV 中心与范围，排除透明留白；与 12 种陆/水外观一一对应。
# 固定美术元数据，只在装配时上传，不在运行时扫描图片。
const TRADE_SHADOW_SHAPES := [\n'''
for (x0,y0,x1,y1),name in zip(boxes,names):
 vals=((x0+x1)/1024,(y0+y1)/512,(x1-x0)/512,(y1-y0)/256)
 meta+='\tVector4('+', '.join(f'{v:.6f}' for v in vals)+f'), # {name}\n'
meta+='''\n]
# 相对高度：人、车与船各自缩放投影长度，避免小对象继承现代货车的高度。
const TRADE_SHADOW_HEIGHTS := [0.45, 0.20, 0.60, 0.35, 0.75, 0.55, 0.65, 0.65, 0.80, 0.65, 1.0, 0.80]
'''
s=s.replace('const TRADE_SHADOW_EDGE_SOFTNESS := 0.35','const TRADE_SHADOW_EDGE_SOFTNESS := 0.35\n'+meta)
p.write_text(s,encoding='utf-8')
p=r/'scripts/rendering/trade_activity_layer.gd'; s=p.read_text(encoding='utf-8').replace('''	_set_parameter("vehicle_height", UITokens.TRADE_VEHICLE_HEIGHT)
	_set_parameter("shadow_max_length", UITokens.TRADE_SHADOW_MAX_LENGTH)''','''	_set_parameter("shadow_height_ratio", UITokens.TRADE_SHADOW_HEIGHT_RATIO)
	_set_parameter("shadow_max_length_ratio", UITokens.TRADE_SHADOW_MAX_LENGTH_RATIO)
	_set_parameter("shadow_shapes", PackedVector4Array(UITokens.TRADE_SHADOW_SHAPES))
	_set_parameter("shadow_heights", PackedFloat32Array(UITokens.TRADE_SHADOW_HEIGHTS))'''); p.write_text(s,encoding='utf-8')
p=r/'shaders/trade_vehicle.gdshader'; s=p.read_text(encoding='utf-8').replace('uniform float vehicle_height = 1.0;','''uniform float shadow_height_ratio = 0.12;
uniform vec4 shadow_shapes[12]; // occupied UV center.xy and size.zw, from UITokens
uniform float shadow_heights[12];''').replace('uniform float shadow_max_length = 1.5;','uniform float shadow_max_length_ratio = 0.60;').replace('uniform vec2 shadow_footprint = vec2(0.86, 0.48);','uniform vec2 shadow_footprint = vec2(0.95, 0.90);')
s=s.replace('''	vec2 scale = vec2(vehicle_size, vehicle_size * 0.5);
	vec2 shift''','''	vec2 scale = vec2(vehicle_size, vehicle_size * 0.5);
	vec2 expanded = vec2(1.0);
	vec2 shift''')
start=s.index('\t\t// A single soft ground ellipse'); end=s.index('\t\tvehicle_alpha *=',start)
s=s[:start]+'''		// Fit THIS sprite's occupied art, not its transparent atlas cell.
		int style = clamp(int(sprite_row), 0, 11);
		vec4 shape = shadow_shapes[style];
		vec2 foot_offset = (shape.xy - vec2(0.5)) * scale;
		center += direction * foot_offset.x + across * foot_offset.y;
		scale *= max(shape.zw * shadow_footprint, vec2(0.01));
		float relative_height = shadow_heights[style];
		float height = vehicle_size * shadow_height_ratio * relative_height;
		shift = -ed.sun_dir.xy / max(ed.sun_dir.z, 0.15) * height;
		float max_shift = vehicle_size * shadow_max_length_ratio * relative_height;
		shift *= min(1.0, max_shift / max(length(shift), 0.001));
		// Low sun still lengthens the ellipse, starting from the fitted footprint.
		vec2 offset_local = vec2(dot(shift, direction), dot(shift, across)) / scale;
		expanded += abs(offset_local);
'''+s[end:]
s=s.replace('vec2 local = VERTEX * scale;','vec2 local = VERTEX * expanded * scale;'); p.write_text(s,encoding='utf-8')
p=r/'tests/trade_activity_lighting_test.gd'; s=p.read_text(encoding='utf-8').replace('''	layer._set_parameter("vehicle_height", 12.0)
	layer._set_parameter("shadow_max_length", 45.0)
''','')
s=s.replace('''		# A north/south route''','''		# Calibrate against people and carts, separately from trucks. Zenith sun
		# isolates footprint size; low-sun stretching is checked independently.
		for style in [0, 2, 4, 10]:
			await _check_style_footprint(style)
		# A north/south route''')
# Preserve the existing preview but add a full style chart on ground, using the real smaller objects.
s=s.replace('''		await _image("ellipse_preview")''','''		await _image("ellipse_preview")
		var overview := _snapshot(true)
		overview.serial = 900
		layer.apply_snapshot(overview)
		layer._wall_time += 3.0
		layer._expire_records()
		await _image("all_objects_preview")''')
s+='''

func _check_style_footprint(style: int) -> void:
	var name: String = {0: "porters", 2: "horse_cart", 4: "covered_wagon", 10: "truck"}[style]
	var sample := _snapshot(false)
	sample.serial = 100 + style
	sample.era_indices[0] = {0: 0, 2: 1, 4: 4, 10: 8}[style]
	layer.apply_snapshot(sample)
	layer.set_daylight_parameters({"day_night_enabled": false, "tod_debug_sun_position_enabled": true,
		"tod_sun_dir": Vector3(0, 0, 1)})
	layer._batch.visible = true
	layer._shadow_batch.visible = false
	var body := _metrics(await _image(name + "_body"))
	layer._batch.visible = false
	layer._shadow_batch.visible = true
	var footprint := _metrics(await _image(name + "_footprint"))
	expect(name + " ellipse fits the actual art without transparent padding", footprint.width <= body.width * 1.10
		and footprint.height <= body.height * 1.10 and footprint.width >= body.width * 0.55
		and footprint.height >= body.height * 0.55)
	layer.set_daylight_parameters({"tod_sun_dir": Vector3(0.96, 0.0, 0.28).normalized()})
	var low_sun := _metrics(await _image(name + "_low_sun"))
	expect(name + " low sun still stretches the shadow", low_sun.width > footprint.width * 1.15)
	layer._batch.visible = true
	layer.set_daylight_parameters({"tod_sun_dir": Vector3(0, 0, 1)})
	root.transparent_bg = false
	RenderingServer.set_default_clear_color(Color(0.50, 0.54, 0.33))
	await _image(name + "_preview")
	root.transparent_bg = true
	print("[trade-footprint] ", {"style": name, "body": body, "footprint": footprint, "low_sun": low_sun})
'''
p.write_text(s,encoding='utf-8')
