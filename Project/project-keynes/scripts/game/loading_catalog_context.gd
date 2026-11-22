extends RefCounted

## One generation owns this object. No products survive into another request;
## source resources and their explicit overrides remain on the main thread.
# Catalog preparation shares frames with the loading screen and world tasks.
# This is a cooperative work budget, never an abort/skip or test threshold.
const ResourceRequest = preload("res://scripts/game/loading_resource_request.gd")
const WORK_SLICE_USEC := 4000
const META_KEY := &"loading_catalog_context"
var frame_gate
var canceled: bool:
	get:
		return frame_gate != null and frame_gate.canceled
var _slice_started := Time.get_ticks_usec()
var _products := {}
var _resources := {}
var compile_counts := {}
var cache_hits := {}
var yielded_frames := 0

func _init(gate = null) -> void:
	frame_gate = gate

static func for_generator(generator):
	var context = generator.get_meta(META_KEY) if generator.has_meta(META_KEY) else null
	if context == null or context.frame_gate != generator._loading_frames:
		context = (load("res://scripts/game/loading_catalog_context.gd") as Script).new(generator._loading_frames)
		generator.set_meta(META_KEY, context)
	return context

static func release_generator(generator) -> void:
	if generator.has_meta(META_KEY):
		var context = generator.get_meta(META_KEY)
		print("[loading-catalog-report] %s" % context.report())
		context._products.clear()
		context._resources.clear()
		generator.remove_meta(META_KEY)

func resource(path: String) -> Resource:
	if canceled:
		return null
	if _resources.has(path):
		return _resources[path]
	# Keep large authored resources alive for this request. Repeated load_default
	# calls otherwise parse the same resource again after local owners expire.
	var request := ResourceRequest.new(path)
	while not request.finished:
		if frame_gate != null:
			await frame_gate.next_frame()
		else:
			await (Engine.get_main_loop() as SceneTree).process_frame
		if canceled:
			# The independent collector still consumes the completed request.
			return null
	if request.result != null:
		_resources[path] = request.result
	return request.result

## Thread the I/O, then preserve the default loader's catalog/profile hooks.
## The held Resource keeps ResourceLoader's cache alive during loader.call().
func default_resource(path: String, loader: Callable) -> Resource:
	var held: Resource = await resource(path)
	return loader.call() if held != null and not canceled else null

func stage(label: String) -> void:
	Engine.set_meta(&"loading_step", "catalog / " + label)

## Returns whether the request may continue after this checkpoint.
func checkpoint(label: String) -> bool:
	if canceled:
		return false
	var elapsed := Time.get_ticks_usec() - _slice_started
	if elapsed < WORK_SLICE_USEC:
		return true
	stage(label)
	var tree := Engine.get_main_loop() as SceneTree
	if frame_gate != null:
		await frame_gate.next_frame()
	elif tree != null:
		await tree.process_frame
	yielded_frames += 1
	_slice_started = Time.get_ticks_usec()
	return not canceled

func dictionary(kind: String, inputs: Array, compiler: Callable,
		arguments: Array) -> Dictionary:
	if canceled:
		return {"ok": false, "reason": "loading_canceled"}
	# Freeze explicit Resource inputs before a compiler can yield. A second call
	# with the same Resource after an edit gets a different content key; object
	# identity alone is not a cache identity.
	stage(kind + "_input_snapshot")
	var frozen_inputs: Array = []
	var replacements := {}
	for input in inputs:
		# Current compiler inputs are Resource overrides or null defaults only.
		if input != null and not input is Resource:
			return {"ok": false, "reason": "loading_catalog_input_type_unsupported"}
		var frozen = input.duplicate_deep(Resource.DEEP_DUPLICATE_ALL) if input is Resource else input
		frozen_inputs.append(frozen)
		if input is Resource:
			replacements[input.get_instance_id()] = frozen
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	await _hash_value(frozen_inputs, digest, {})
	if canceled:
		return {"ok": false, "reason": "loading_canceled"}
	var key := kind + ":" + digest.finish().hex_encode()
	stage(kind + "_compile")
	if _products.has(key):
		cache_hits[kind] = int(cache_hits.get(kind, 0)) + 1
		return (_products[key] as Dictionary).duplicate(true)
	var args := [self]
	for argument in arguments:
		args.append(replacements.get(argument.get_instance_id(), argument)
			if argument is Resource else argument)
	var owner := compiler.get_object()
	if owner is Resource and replacements.has(owner.get_instance_id()):
		compiler = Callable(replacements[owner.get_instance_id()], compiler.get_method())
	var result: Dictionary = await compiler.callv(args)
	if canceled:
		return {"ok": false, "reason": "loading_canceled"}
	compile_counts[kind] = int(compile_counts.get(kind, 0)) + 1
	if bool(result.get("ok", false)):
		_products[key] = result.duplicate(true)
	return result

func report() -> Dictionary:
	return {"compile_counts": compile_counts.duplicate(),
		"cache_hits": cache_hits.duplicate(), "yielded_frames": yielded_frames,
		"canceled": canceled}

## Encode stored properties, including nested authored Resources. Script paths
## identify types; instance IDs and ResourceLoader cache identity do not.
func _hash_value(value, digest: HashingContext, seen: Dictionary) -> void:
	await checkpoint("catalog_input")
	if canceled:
		return
	digest.update(var_to_bytes(typeof(value)))
	if value is Resource:
		var identity: int = value.get_instance_id()
		if seen.has(identity):
			digest.update(var_to_bytes(["reference", seen[identity]]))
			return
		seen[identity] = seen.size()
		var script: Script = value.get_script()
		digest.update(var_to_bytes(script.resource_path if script != null else value.get_class()))
		var properties: Array = value.get_property_list()
		properties.sort_custom(func(a, b): return String(a.name) < String(b.name))
		for property in properties:
			if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0 or property.name == "script":
				continue
			digest.update(var_to_bytes(property.name))
			await _hash_value(value.get(property.name), digest, seen)
	elif value is Array:
		digest.update(var_to_bytes(value.size()))
		for item in value:
			await _hash_value(item, digest, seen)
	elif value is Dictionary:
		var keys: Array = value.keys()
		# Keep insertion order: a compiler may consume authored dictionaries in order.
		digest.update(var_to_bytes(keys.size()))
		for key in keys:
			await _hash_value(key, digest, seen)
			await _hash_value(value[key], digest, seen)
	else:
		digest.update(var_to_bytes(value))
