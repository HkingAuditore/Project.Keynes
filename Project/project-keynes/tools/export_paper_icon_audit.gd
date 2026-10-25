extends SceneTree

func _init() -> void:
	var rows: Array[Dictionary] = []
	var failures: Array[String] = []
	for key in IconCatalog.registered_keys():
		var spec := IconCatalog.spec_for(key)
		var texture := spec.get("texture") as Texture2D
		if texture == null or spec.get("family") != IconCatalog.FAMILY_PAPER or spec.has("glyph") \
				or (not IconCatalog.PAPER_TEXTURES.has(key) and not IconCatalog.PAPER_ALIASES.has(key)):
			failures.append(String(key))
		rows.append({"semantic": String(key), "texture": texture.resource_path if texture != null else "",
			"family": String(spec.get("family", "")), "has_glyph": spec.has("glyph")})
	var report := {"semantic_count": rows.size(), "original_textures": IconCatalog.PAPER_TEXTURES.size(),
		"explicit_aliases": IconCatalog.PAPER_ALIASES.size(), "legacy_or_missing": failures, "icons": rows}
	var path := "res://../../artifacts/paper-icons/full-ui/icon-audit.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("[paper-icon-export] semantics=%d textures=%d aliases=%d missing=%d" % [rows.size(),
		IconCatalog.PAPER_TEXTURES.size(), IconCatalog.PAPER_ALIASES.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
