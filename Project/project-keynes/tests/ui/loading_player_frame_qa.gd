extends SceneTree

var active := false
var last_usec := 0
var gaps: Array[float] = []
var stage := "scene"
var finished := false
var directory := ""
var sample_frames := false
var canvas_pipelines := 0
var sample_index := 0
var next_sample := 0

func _initialize() -> void:
	process_frame.connect(_heartbeat)
	call_deferred("_run")

func _heartbeat() -> void:
	if not active:return
	var now := Time.get_ticks_usec()
	if last_usec>0:
		var gap := float(now-last_usec)/1000.0
		gaps.append(gap)
		if gap>100:print("[player-loading-gap] %.1fms %s canvas=%d process=%.1fms" % [gap,stage,int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS))-canvas_pipelines,Performance.get_monitor(Performance.TIME_PROCESS)*1000.0])
		canvas_pipelines=int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS))
	last_usec=now
	if sample_frames and now>next_sample:
		next_sample=now+100000
		call_deferred("_sample")

func _sample() -> void:
	if not active:return
	root.get_texture().get_image().save_png("%s/frame_%04d.png" % [directory,sample_index])
	sample_index+=1

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1366,768))
	await create_timer(.2).timeout
	directory=OS.get_environment("PK_LOADING_QA_DIR")
	if not directory.is_empty():DirAccess.make_dir_recursive_absolute(directory)
	sample_frames=not directory.is_empty() and DisplayServer.get_name()!="headless"
	var dimensions := OS.get_environment("PK_LOADING_SIZE").split("x")
	var config := NewGameConfig.create_default()
	config.base.initial_seed=20260723
	config.base.map_width=int(dimensions[0]) if dimensions.size()==2 else 60
	config.base.map_height=int(dimensions[1]) if dimensions.size()==2 else 40
	root.get_node("GameFlow").set("_pending_request",{"kind":"new_game","config":config.to_dictionary()})
	# Resource decode precedes the measurement here; GameFlow transition has its
	# own visual overlay and asynchronous scene request.
	var scene: PackedScene=load("res://scenes/player_game.tscn")
	var ext: RefCounted = ClassDB.instantiate("DCWorldExt")
	await LoadingCatalogCache.prepare(ext)
	active=true
	var mark:=Time.get_ticks_usec()
	change_scene_to_packed(scene)
	print("[player-scene-request] %.1fms" % [float(Time.get_ticks_usec()-mark)/1000.0])
	for i in 4:await process_frame
	var player:=current_scene
	if player==null:quit(1);return
	var host:=player.get_node("RuntimeHost") as WorldRuntimeHost
	host.generation_progress.connect(func(name: String,_fraction: float)->void:stage=name)
	host.world_ready.connect(func(_a,_b,_c,_d)->void:finished=true)
	var started:=Time.get_ticks_msec()
	while not finished and Time.get_ticks_msec()-started<180000:
		await process_frame
	for i in 5:await process_frame
	active=false
	gaps.sort()
	var p95:=gaps[int(float(gaps.size()-1)*.95)] if not gaps.is_empty() else 0.0
	var maximum:=gaps[-1] if not gaps.is_empty() else 0.0
	print("[player-loading-frame-report] size=%dx%d ready=%s frames=%d p95_ms=%.1f max_ms=%.1f" % [config.base.map_width,config.base.map_height,finished,gaps.size(),p95,maximum])
	if not directory.is_empty():
		var file:=FileAccess.open(directory+"/frames.json",FileAccess.WRITE)
		file.store_string(JSON.stringify({"p95_ms":p95,"max_ms":maximum,"frames":gaps.size(),"ready":finished}))
	var passed:=finished and p95<=33 and maximum<=100
	current_scene.queue_free()
	await process_frame
	quit(0 if passed else 1)
