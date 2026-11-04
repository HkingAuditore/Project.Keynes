extends SceneTree

const Store = preload("res://scripts/narrative/ai/narrative_ai_credentials.gd")
const PATH := "user://test_narrative_credentials.cfg"
var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	var keys := Store.load_keys(PATH, "text-test-key")
	_expect("text environment key never supplies image authentication", keys.llm_api_key == "text-test-key" and keys.image_api_key.is_empty())
	_expect("independent environment image key is supported", Store.load_keys(PATH, "text", "image").image_api_key == "image")
	_expect("save succeeds", bool(Store.save_keys(PATH, " text-only ", "").ok))
	keys = Store.load_keys(PATH, "env-text", "env-image")
	_expect("saved values override initial defaults including explicit empty", keys.llm_api_key == "text-only" and keys.image_api_key.is_empty())
	Store.save_keys(PATH, "text-key", "image-key")
	_expect("distinct keys round trip independently", Store.load_keys(PATH) == {"llm_api_key": "text-key", "image_api_key": "image-key"})
	Store.save_keys(PATH, "text-key", "")
	_expect("image key can be cleared without losing text key", Store.load_keys(PATH) == {"llm_api_key": "text-key", "image_api_key": ""})
	Store.save_keys(PATH, "", "")
	_expect("both credentials can be cleared", Store.load_keys(PATH, "env-text", "env-image") == {"llm_api_key": "", "image_api_key": ""})
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	print("narrative credentials: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
