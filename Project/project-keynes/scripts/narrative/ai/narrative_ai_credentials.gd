extends RefCounted

## Text and image credentials are separate even when a provider supports both.
## Explicitly saved empty values clear a key; environment is only an initial default.
static func save_keys(path: String, llm_key: String, image_key: String) -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.set_value("ai", "llm_api_key", llm_key.strip_edges())
	cfg.set_value("ai", "image_api_key", image_key.strip_edges())
	var error := cfg.save(path)
	return {"ok": error == OK, "code": "ok" if error == OK else "credentials_save_failed"}


static func load_keys(path: String, llm_default: String = "", image_default: String = "") -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(path)
	return {
		"llm_api_key": String(cfg.get_value("ai", "llm_api_key", llm_default)).strip_edges(),
		"image_api_key": String(cfg.get_value("ai", "image_api_key", image_default)).strip_edges(),
	}
