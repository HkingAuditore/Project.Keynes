class_name NarrativeAiClient
extends Node

## Asynchronous non-blocking client for LLM event generation and text-to-image
## illustration generation. Never blocks the simulation clock or main thread.
## Supports injectable mock responders for deterministic headless testing.

signal event_generated(request_id: int, result: Dictionary)
signal image_generated(event_id: StringName, image_path: String, texture: Texture2D)

const NarrativeAiPromptBuilderScript = preload("res://scripts/narrative/ai/narrative_ai_prompt_builder.gd")
const NarrativeAiValidatorScript = preload("res://scripts/narrative/ai/narrative_ai_validator.gd")
const NarrativeEventDefinitionScript = preload("res://scripts/narrative/narrative_event_definition.gd")

const CredentialsScript = preload("res://scripts/narrative/ai/narrative_ai_credentials.gd")
const CREDENTIALS_PATH := "user://ai_credentials.cfg"
const CACHE_DIR := "user://narrative_cache/images"
const LLM_TIMEOUT_SEC := 18.0
const IMAGE_TIMEOUT_SEC := 25.0

var _next_request_id: int = 1
var _mock_responder: Callable = Callable()
var _mock_llm_responder: Callable = Callable()
var _mock_image_responder: Callable = Callable()
var _texture_cache: Dictionary = {}


func set_mock_responder(responder: Callable) -> void:
	_mock_responder = responder


func set_mock_llm_responder(responder: Callable) -> void:
	_mock_llm_responder = responder


func set_mock_image_responder(responder: Callable) -> void:
	_mock_image_responder = responder


func clear_mock_responders() -> void:
	_mock_responder = Callable()
	_mock_llm_responder = Callable()
	_mock_image_responder = Callable()


static func save_api_keys(llm_key: String, image_key: String = "") -> Dictionary:
	return CredentialsScript.save_keys(CREDENTIALS_PATH, llm_key, image_key)


static func load_api_keys() -> Dictionary:
	return CredentialsScript.load_keys(CREDENTIALS_PATH,
		OS.get_environment("PK_AI_LLM_API_KEY"), OS.get_environment("PK_AI_IMAGE_API_KEY"))


static func get_llm_api_key() -> String:
	return String(load_api_keys().get("llm_api_key", ""))


static func get_image_api_key() -> String:
	return String(load_api_keys().get("image_api_key", ""))


static func has_llm_api_key() -> bool:
	return not get_llm_api_key().is_empty()


static func has_image_api_key() -> bool:
	return not get_image_api_key().is_empty()


func _read_settings() -> Dictionary:
	var settings_node := get_node_or_null("/root/GameSettings") if is_inside_tree() else null
	if settings_node == null:
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			settings_node = tree.root.get_node_or_null("GameSettings")
	if settings_node != null and settings_node.has_method("values"):
		var vals = settings_node.values()
		if vals is Dictionary:
			return vals
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		return {
			"ai_narrative_enabled": bool(cfg.get_value("settings", "ai_narrative_enabled", false)),
			"ai_llm_base_url": String(cfg.get_value("settings", "ai_llm_base_url", "https://api.deepseek.com/v1/chat/completions")),
			"ai_llm_model": String(cfg.get_value("settings", "ai_llm_model", "deepseek-chat")),
			"ai_image_enabled": bool(cfg.get_value("settings", "ai_image_enabled", false)),
			"ai_image_base_url": String(cfg.get_value("settings", "ai_image_base_url", "https://api.openai.com/v1/images/generations")),
			"ai_image_model": String(cfg.get_value("settings", "ai_image_model", "dall-e-3")),
		}
	return {}


func request_event_generation(
		request_spec: Dictionary,
		on_complete: Callable = Callable()
) -> int:
	var req_id := _next_request_id
	_next_request_id += 1

	var cell_ctx: Dictionary = request_spec.get("cell_ctx", request_spec)
	var chronicle: Array = request_spec.get("recent_chronicle", [])
	var chain_hint := String(request_spec.get("ai_prompt_hint", request_spec.get("chain_hint", "")))
	var allowed_goods: PackedStringArray = request_spec.get("allowed_goods", PackedStringArray())
	var allowed_buildings: PackedStringArray = request_spec.get("allowed_buildings", PackedStringArray())
	var messages := NarrativeAiPromptBuilderScript.build_messages(
		cell_ctx, chronicle, chain_hint, allowed_goods, allowed_buildings
	)
	var custom_event_id := "evt.ai.%d_%d" % [int(request_spec.get("day", cell_ctx.get("day", 1))), req_id]

	# Test / Mock path
	var active_mock := _mock_llm_responder if _mock_llm_responder.is_valid() else _mock_responder
	if active_mock.is_valid():
		var raw_reply: Variant = active_mock.call(request_spec, messages)
		var validated := NarrativeAiValidatorScript.validate_and_sanitize(
			raw_reply, cell_ctx, allowed_goods, custom_event_id
		)
		if bool(validated.get("ok", false)):
			validated["definition"] = NarrativeEventDefinitionScript.from_dict(validated.get("event_dict", {}))
		validated["request_id"] = req_id
		validated["cell_idx"] = int(request_spec.get("cell_idx", cell_ctx.get("cell_idx", -1)))
		validated["chain_id"] = String(request_spec.get("chain_id", ""))
		if on_complete.is_valid():
			on_complete.call(validated)
		event_generated.emit(req_id, validated)
		return req_id

	var keys := load_api_keys()
	var api_key := String(keys.get("llm_api_key", ""))
	if api_key.is_empty() or not is_inside_tree():
		var fail := {
			"ok": false,
			"code": "ai_key_missing",
			"reason": "未配置 AI API Key，已自动回退至内置静态事件库。",
			"request_id": req_id,
		}
		if on_complete.is_valid():
			on_complete.call(fail)
		event_generated.emit(req_id, fail)
		return req_id

	var vals := _read_settings()
	var endpoint := String(vals.get("ai_llm_base_url", "https://api.deepseek.com/v1/chat/completions")).strip_edges()
	var model := String(vals.get("ai_llm_model", "deepseek-chat")).strip_edges()

	var http := HTTPRequest.new()
	http.timeout = LLM_TIMEOUT_SEC
	add_child(http)

	var body := JSON.stringify({
		"model": model,
		"messages": messages,
		"temperature": 0.75,
		"response_format": {"type": "json_object"},
	})
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key,
	])

	http.request_completed.connect(func(result_code: int, response_code: int, _headers: PackedStringArray, body_bytes: PackedByteArray) -> void:
		http.queue_free()
		if result_code != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
			var http_fail := {
				"ok": false,
				"code": "ai_http_error",
				"reason": "LLM 请求失败 (HTTP %d)" % response_code,
				"request_id": req_id,
			}
			if on_complete.is_valid():
				on_complete.call(http_fail)
			event_generated.emit(req_id, http_fail)
			return

		var text := body_bytes.get_string_from_utf8()
		var envelope := JSON.new()
		var content_str := text
		if envelope.parse(text) == OK and envelope.data is Dictionary:
			var choices: Variant = (envelope.data as Dictionary).get("choices", [])
			if choices is Array and not (choices as Array).is_empty() and choices[0] is Dictionary:
				var msg: Variant = (choices[0] as Dictionary).get("message", {})
				if msg is Dictionary:
					content_str = String((msg as Dictionary).get("content", ""))

		var validated := NarrativeAiValidatorScript.validate_and_sanitize(
			content_str, cell_ctx, allowed_goods, custom_event_id
		)
		if bool(validated.get("ok", false)):
			validated["definition"] = NarrativeEventDefinitionScript.from_dict(validated.get("event_dict", {}))
		validated["request_id"] = req_id
		validated["cell_idx"] = int(request_spec.get("cell_idx", cell_ctx.get("cell_idx", -1)))
		validated["chain_id"] = String(request_spec.get("chain_id", ""))
		if on_complete.is_valid():
			on_complete.call(validated)
		event_generated.emit(req_id, validated)
	)

	var req_err := http.request(endpoint, headers, HTTPClient.METHOD_POST, body)
	if req_err != OK:
		http.queue_free()
		var start_fail := {
			"ok": false,
			"code": "ai_request_start_failed",
			"reason": "无法发起 HTTP 请求。",
			"request_id": req_id,
		}
		if on_complete.is_valid():
			on_complete.call(start_fail)
		event_generated.emit(req_id, start_fail)
	return req_id


func request_event_illustration(
		event_id: String,
		raw_visual_prompt: String,
		on_complete: Callable = Callable(),
		era_index: int = 0,
		cell_ctx: Dictionary = {}
) -> void:
	var cache_path := _cache_file_path_for(event_id)
	var active_img_mock := _mock_image_responder if _mock_image_responder.is_valid() else _mock_responder
	if not active_img_mock.is_valid():
		var cached_tex := load_cached_texture(cache_path)
		if cached_tex != null:
			var hit := {"ok": true, "cached": true, "image_path": cache_path, "texture": cached_tex}
			if on_complete.is_valid():
				on_complete.call(hit)
			image_generated.emit(StringName(event_id), cache_path, cached_tex)
			return

	var full_prompt := NarrativeAiPromptBuilderScript.build_era_image_prompt(
		era_index, raw_visual_prompt, cell_ctx
	)

	if active_img_mock.is_valid():
		var raw_mock_out: Variant = active_img_mock.call(event_id, full_prompt)
		var img_bytes := _coerce_to_image_bytes(raw_mock_out)
		var saved_tex := _save_and_create_texture(cache_path, img_bytes)
		var mock_res := {
			"ok": saved_tex != null,
			"image_path": cache_path if saved_tex != null else "",
			"texture": saved_tex,
		}
		if on_complete.is_valid():
			on_complete.call(mock_res)
		if saved_tex != null:
			image_generated.emit(StringName(event_id), cache_path, saved_tex)
		return

	var vals := _read_settings()
	if not bool(vals.get("ai_image_enabled", false)) or not is_inside_tree():
		if on_complete.is_valid():
			on_complete.call({"ok": false, "code": "ai_image_disabled"})
		return

	var keys := load_api_keys()
	var img_key := String(keys.get("image_api_key", ""))
	if img_key.is_empty():
		if on_complete.is_valid():
			on_complete.call({"ok": false, "code": "ai_image_key_missing"})
		return

	var endpoint := String(vals.get("ai_image_base_url", "https://api.openai.com/v1/images/generations")).strip_edges()
	var model := String(vals.get("ai_image_model", "dall-e-3")).strip_edges()

	var http := HTTPRequest.new()
	http.timeout = IMAGE_TIMEOUT_SEC
	add_child(http)
	var body := JSON.stringify({
		"model": model,
		"prompt": full_prompt,
		"n": 1,
		"size": "1024x1024",
		"response_format": "b64_json",
	})
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % img_key,
	])

	http.request_completed.connect(func(result_code: int, response_code: int, _headers: PackedStringArray, body_bytes: PackedByteArray) -> void:
		http.queue_free()
		if result_code != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
			if on_complete.is_valid():
				on_complete.call({"ok": false, "code": "ai_image_http_error"})
			return
		var parsed := JSON.new()
		if parsed.parse(body_bytes.get_string_from_utf8()) == OK and parsed.data is Dictionary:
			var data_arr: Variant = (parsed.data as Dictionary).get("data", [])
			if data_arr is Array and not (data_arr as Array).is_empty() and data_arr[0] is Dictionary:
				var b64 := String((data_arr[0] as Dictionary).get("b64_json", ""))
				if not b64.is_empty():
					var raw_img := Marshalls.base64_to_raw(b64)
					var tex := _save_and_create_texture(cache_path, raw_img)
					if tex != null:
						if on_complete.is_valid():
							on_complete.call({"ok": true, "image_path": cache_path, "texture": tex})
						image_generated.emit(StringName(event_id), cache_path, tex)
						return
		if on_complete.is_valid():
			on_complete.call({"ok": false, "code": "ai_image_decode_failed"})
	)
	if http.request(endpoint, headers, HTTPClient.METHOD_POST, body) != OK:
		http.queue_free()
		if on_complete.is_valid():
			on_complete.call({"ok": false, "code": "ai_image_request_failed"})


func _coerce_to_image_bytes(raw_val: Variant) -> PackedByteArray:
	if raw_val is PackedByteArray:
		return raw_val as PackedByteArray
	if raw_val is Image:
		return (raw_val as Image).save_png_to_buffer()
	if raw_val is Dictionary:
		var d: Dictionary = raw_val as Dictionary
		if d.has("bytes") and d["bytes"] is PackedByteArray:
			return d["bytes"] as PackedByteArray
		if d.has("b64_json"):
			return Marshalls.base64_to_raw(String(d["b64_json"]))
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.35, 0.28, 0.2, 1.0))
	return img.save_png_to_buffer()


func _save_and_create_texture(cache_path: String, img_bytes: PackedByteArray) -> Texture2D:
	if img_bytes.is_empty():
		return null
	var img := Image.new()
	var err := img.load_png_from_buffer(img_bytes)
	if err != OK:
		err = img.load_webp_from_buffer(img_bytes)
	if err != OK:
		err = img.load_jpg_from_buffer(img_bytes)
	if err != OK or img.is_empty():
		return null

	var abs_dir := ProjectSettings.globalize_path(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	img.save_png(cache_path)
	var tex := ImageTexture.create_from_image(img)
	_texture_cache[cache_path] = tex
	return tex


static func load_cached_texture(image_path: String) -> Texture2D:
	var clean := image_path.strip_edges()
	if clean.is_empty() or not FileAccess.file_exists(clean):
		return null
	var bytes := FileAccess.get_file_as_bytes(clean)
	if bytes.is_empty():
		return null
	var img := Image.new()
	var err := img.load_png_from_buffer(bytes)
	if err != OK:
		err = img.load_webp_from_buffer(bytes)
	if err != OK:
		err = img.load_jpg_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


static func _cache_file_path_for(event_id: String) -> String:
	var safe := ""
	for i in range(event_id.length()):
		var c := event_id.unicode_at(i)
		if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95:
			safe += char(c)
		else:
			safe += "_"
	if safe.is_empty():
		safe = "event_img"
	return "%s/%s.png" % [CACHE_DIR, safe]
