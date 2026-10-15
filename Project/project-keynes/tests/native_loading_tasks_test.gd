extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func expect(label: String, condition: bool) -> void:
	if not condition: failures.append(label)

func _run() -> void:
	var ext: RefCounted = ClassDB.instantiate("DCWorldExt")
	var other: RefCounted = ClassDB.instantiate("DCWorldExt")
	var generator := MapGenerator.new()
	var cfg := MapConfig.make(60,40)
	cfg.seed = 20260723
	var input := {"seed":cfg.seed,"cfg":generator._native_generation_cfg_dict(cfg),"profile":generator._native_generation_profile_dict()}
	var reference: Dictionary = ext.run_native_world_generate_full_pass(input.seed,input.cfg,input.profile)
	var async_result: Dictionary = await NativeLoadingTasks.compute(ext,"generate",input)
	for key in reference:
		if typeof(reference[key]) in [TYPE_PACKED_FLOAT32_ARRAY,TYPE_PACKED_BYTE_ARRAY,TYPE_PACKED_INT32_ARRAY]:
			expect("generation array parity: "+key,reference[key]==async_result.get(key))
	var canceled: int = ext.begin_loading_task("generate",input)
	expect("other owner cannot consume a task",other.take_loading_task(canceled).is_empty())
	ext.cancel_loading_task(canceled)
	expect("canceled result cannot be consumed",ext.take_loading_task(canceled).is_empty())
	var rejected_object := Node.new()
	expect("object inputs rejected",ext.begin_loading_task("geometry",{"object":rejected_object})==0)
	rejected_object.free()
	var height := PackedFloat32Array([0,.0001,.5,.999,1])
	var flow := PackedFloat32Array([0,.25,.7,.9,1])
	var packed: Dictionary = await NativeLoadingTasks.compute(ext,"height_flow",{"height_buffer":height,"flow_buffer":flow,"width":5,"height":1})
	var old_height: Dictionary = ext.encode_bake_height_tex_data({"buffer":height,"width":5,"height":1})
	var old_flow: Dictionary = ext.encode_bake_flow_tex_data({"buffer":flow,"width":5,"height":1})
	for i in height.size():
		expect("RGBA height/flow parity %d" % i,packed.data[i*4]==old_height.data[i*2] and packed.data[i*4+1]==old_height.data[i*2+1] and packed.data[i*4+2]==old_flow.data[i] and packed.data[i*4+3]==0)
	var baker := MapBaker.new()
	baker._init_noise(cfg.seed)
	var detail: Dictionary = await NativeLoadingTasks.compute(ext,"terrain_detail",{"width":32,"height":24,"seed":cfg.seed,"origin_x":-20.0,"origin_y":-20.0,"size_x":160.0,"size_y":100.0,"wrap_period_x":150.0,"hex_size":10.0,"min_detail":.7,"max_detail":1.3})
	for y in 24:
		for x in 32:
			var value := DCTerrainBaker.terrain_detail_bake_scalar(baker._detail_noise,baker._ridge_noise,-20.0+(float(x)+.5)*5.0,-20.0+(float(y)+.5)*(100.0/24.0),150.0,10.0,.7,1.3)
			expect("detail parity %d,%d" % [x,y],detail.data[y*32+x]==DCTerrainBaker.terrain_detail_to_byte(value,.7,1.3))
	LoadingCatalogCache.invalidate()
	var economy := EconomyCatalog.compile_native_catalog()
	var effect: Dictionary = EffectDomainCatalog.build().compile_native_catalog()
	await LoadingCatalogCache.prepare(ext)
	expect("catalog snapshot matches source compiler",economy==LoadingCatalogCache.economy_catalog())
	var cached_effect := LoadingCatalogCache.effect_catalog()
	expect("effect extension IR survives serialization",cached_effect != null and effect==cached_effect.compile_native_catalog())
	for failure in failures: push_error(failure)
	print("[native-loading-tasks] %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
