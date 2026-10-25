extends SceneTree


const SCRIPT_ROOT := "res://scripts"
const CATALOG_PATH := "res://scripts/ui/icon_catalog.gd"
const ICON_ROOT := "res://assets/icons"
const PROFESSION_ROOT := "res://data/economy/professions"
const BUILDING_ROOT := "res://data/economy/buildings"
const LICENSE_PATHS := [
	"res://assets/fonts/fontawesome/FONT-AWESOME-LICENSE.txt",
	"res://assets/icons/hud/LICENSE.txt",
	"res://assets/icons/lucide/LICENSE.txt",
	"res://assets/icons/tabler/LICENSE.txt",
]

var _failures: Array[String] = []


func _init() -> void:
	_audit_registered_semantics()
	_audit_source_boundaries(SCRIPT_ROOT)
	_audit_assets()
	_audit_shared_implementations()
	_audit_context_mappings()
	_audit_semantic_contracts()
	_audit_paper_controls()
	if _failures.is_empty():
		print("[icon-catalog-audit] PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("[icon-catalog-audit] FAIL: %s" % failure)
	quit(1)


func _audit_registered_semantics() -> void:
	for semantic in IconCatalog.registered_keys():
		if not IconCatalog.PAPER_TEXTURES.has(semantic) and not IconCatalog.PAPER_ALIASES.has(semantic):
			_failures.append("semantic has no explicit paper artwork mapping: %s" % semantic)
		if IconCatalog.resolve_semantic(semantic) != semantic:
			_failures.append("semantic key does not resolve to itself: %s" % semantic)
		var spec := IconCatalog.spec_for(semantic)
		var has_glyph := not String(spec.get("glyph", "")).is_empty()
		var texture := spec.get("texture") as Texture2D
		if has_glyph or texture == null or spec.get("family") != IconCatalog.FAMILY_PAPER:
			_failures.append("all player icons must use paper textures: %s" % semantic)
		if texture != null and not ResourceLoader.exists(texture.resource_path):
			_failures.append("missing texture for %s: %s" % [semantic, texture.resource_path])
		if texture is AtlasTexture and IconCatalog.family_for_key(semantic) == IconCatalog.FAMILY_PAPER:
			var atlas := texture as AtlasTexture
			if not Rect2(Vector2.ZERO, atlas.atlas.get_size()).encloses(atlas.region):
				_failures.append("paper icon extends outside its atlas: %s" % semantic)
			var pixels := atlas.get_image()
			if pixels == null or pixels.is_invisible() or pixels.detect_alpha() == Image.ALPHA_NONE:
				_failures.append("paper icon must contain visible art and transparent cutout: %s" % semantic)
	if IconCatalog.resolve_semantic(&"country.technology") == \
			IconCatalog.resolve_semantic(&"metric.technology"):
		_failures.append("distinct business semantics collapsed during resolution")


func _audit_source_boundaries(root: String) -> void:
	var private_use_pattern := RegEx.create_from_string("\\\\uf[0-8][0-9a-fA-F]{2}")
	for path in _files_recursive(root, ".gd"):
		if path == CATALOG_PATH:
			continue
		var source := FileAccess.get_file_as_string(path)
		if private_use_pattern.search(source) != null:
			_failures.append("private-use glyph outside IconCatalog: %s" % path)
		if source.contains("res://assets/icons/"):
			_failures.append("icon asset path outside IconCatalog: %s" % path)
		if source.contains("IconCatalog.FONT_AWESOME") or source.contains("IconBadge.FA_SOLID_FONT") \
				or source.contains("IconCatalog.glyph_for_key("):
			_failures.append("legacy icon font renderer remains: %s" % path)
	for path in _files_recursive("res://scripts/rendering", ".gd"):
		var source := FileAccess.get_file_as_string(path)
		if source.contains("IconCatalog.FONT_AWESOME") or source.contains("IconCatalog.glyph_for_key("):
			_failures.append("map marker still renders legacy icon glyph: %s" % path)
	for path in _files_recursive("res://scenes", ".tscn"):
		var source := FileAccess.get_file_as_string(path)
		if source.contains(".svg\"") or source.contains("crest_bitmap.tres") \
				or source.contains("prestige_bitmap.tres"):
			_failures.append("scene bypasses the paper icon catalog: %s" % path)


func _audit_assets() -> void:
	for license_path in LICENSE_PATHS:
		if not FileAccess.file_exists(license_path):
			_failures.append("missing icon license: %s" % license_path)
	var hashes := {}
	for path in _files_recursive(ICON_ROOT, ".svg"):
		var digest := FileAccess.get_sha256(path)
		if digest.is_empty():
			_failures.append("could not hash SVG: %s" % path)
			continue
		if not hashes.has(digest):
			hashes[digest] = []
		(hashes[digest] as Array).append(path)
	for digest in hashes:
		var paths := hashes[digest] as Array
		if paths.size() > 1:
			_failures.append("duplicate SVG hash %s: %s" % [digest, ", ".join(paths)])


func _audit_shared_implementations() -> void:
	var usage := IconCatalog.usage_audit()
	var signatures: Array = usage.keys()
	signatures.sort()
	for signature in signatures:
		var semantics := usage[signature] as Array
		semantics.sort()
		print("[icon-catalog-audit] %s <- %d semantic(s): %s" % [
			signature, semantics.size(), ", ".join(semantics)
		])
		if semantics.size() <= 1:
			continue
		var allowed := IconCatalog.ALLOWED_SHARED_IMPLEMENTATIONS.get(signature, []) as Array
		var allowed_sorted := allowed.duplicate()
		allowed_sorted = allowed_sorted.filter(func(key):
			return IconCatalog.implementation_signature(key) == signature)
		allowed_sorted.sort()
		if String(signature).begins_with("project_keynes:"):
			var explicit_paper: Array = []
			for paper_key in IconCatalog.PAPER_TEXTURES:
				if IconCatalog.implementation_signature(paper_key) == signature:
					explicit_paper.append(paper_key)
			for alias in IconCatalog.PAPER_ALIASES:
				if IconCatalog.implementation_signature(alias) == signature:
					explicit_paper.append(alias)
			explicit_paper.sort()
			if semantics == explicit_paper:
				continue
		if semantics != allowed_sorted:
			# Identity catalogs are checked for uniqueness inside their own domain
			# below; cross-domain reuse remains visible in this printed report.
			if semantics.any(func(key): return String(key).begins_with("good.") \
					or String(key).begins_with("profession.")):
				continue
			_failures.append("unregistered shared mapping %s: %s" % [
				signature, ", ".join(semantics)
			])


func _audit_context_mappings() -> void:
	var good_signatures := {}
	for profile in GoodProfileRegistry.ordered():
		var semantic := GoodProfileRegistry.icon_key(profile)
		_audit_unique_identity("good", String(profile.id), semantic, good_signatures)
		if semantic != GoodProfileRegistry.icon_key(String(profile.id)):
			_failures.append("good icon differs by lookup path: %s" % profile.id)
	var profession_signatures := {}
	for path in _files_recursive(PROFESSION_ROOT, ".tres"):
		var profile := ResourceLoader.load(path) as ProfessionProfile
		if profile == null:
			_failures.append("could not load profession profile: %s" % path)
			continue
		var stable_id := String(profile.id)
		var semantic := IconCatalog.profession_semantic(stable_id)
		_audit_unique_identity("profession", stable_id, semantic,
			profession_signatures)
	var resource_signatures := {}
	for profile in ResourceProfileRegistry.ordered():
		var semantic := ResourceProfileRegistry.icon_key(profile)
		_audit_unique_identity("resource", String(profile.id), semantic,
			resource_signatures)
	var view_model := CellInspectorViewModel.new()
	var building_ids := [
		"communal_hearth", "gathering_ground", "merchant_post",
		"freshwater_fishing_camp", "stone_age_hunting_camp",
	]
	var building_signatures := {}
	for building_id in building_ids:
		var semantic: StringName = view_model._building_icon(building_id)
		var signature := IconCatalog.implementation_signature(semantic)
		if building_signatures.has(signature):
			_failures.append("building list repeats %s for %s and %s" % [
				signature, building_signatures[signature], building_id
			])
		building_signatures[signature] = building_id
	_audit_building_catalog()


func _audit_building_catalog() -> void:
	var signature_products := {}
	var audited := 0
	for path in _files_recursive(BUILDING_ROOT, ".tres"):
		var profile := ResourceLoader.load(path) as BuildingProfile
		if profile == null or profile.output_good_ids.is_empty():
			continue
		var primary_good := String(profile.output_good_ids[0])
		var kind := 0 if profile.building_kind == "collector" else (2 \
			if profile.building_kind == "service" else 1)
		var semantic := IconCatalog.building_semantic(
			String(profile.id), primary_good, kind)
		if not IconCatalog.has_icon(semantic):
			_failures.append("building has no product icon: %s" % profile.id)
			continue
		var signature := IconCatalog.implementation_signature(semantic)
		if signature_products.has(signature) \
				and signature_products[signature] != primary_good:
			_failures.append("building icon collision for different products: %s / %s" % [
				signature_products[signature], primary_good])
		signature_products[signature] = primary_good
		audited += 1
	print("[icon-catalog-audit] audited %d product-bound building icon(s)" % audited)


func _audit_semantic_contracts() -> void:
	var copper := IconCatalog.spec_for(&"resource.copper")
	if copper.get("texture") == null or copper.get("family") != IconCatalog.FAMILY_PAPER:
		_failures.append("copper ore must use the generated mineral paper cutout")
	var logs := IconCatalog.spec_for(&"good.logs")
	if logs.get("texture") == null or logs.get("family") != IconCatalog.FAMILY_PAPER:
		_failures.append("logs must use the generated timber paper cutout")
	if IconCatalog.implementation_signature(&"resource.copper") == \
			IconCatalog.implementation_signature(&"good.copper"):
		_failures.append("copper ore and refined copper must remain visually distinct")
	var building_snapshot := {
		"building_output_offsets": PackedInt32Array([0, 1, 2]),
		"building_output_good_ids": PackedInt32Array([0, 1]),
		"good_ids": PackedStringArray(["copper_ore", "copper"]),
		"building_kinds": PackedInt32Array([0, 1]),
	}
	var view_model := CellInspectorViewModel.new()
	var copper_mine := view_model._building_icon(
		"early_copper_mine", building_snapshot, 0)
	var copper_plant := view_model._building_icon(
		"copper_plant", building_snapshot, 1)
	if not String(copper_mine).begins_with("building.collector."):
		_failures.append("building icons must bind the authoritative building kind")
	if IconCatalog.implementation_signature(copper_mine) == \
			IconCatalog.implementation_signature(copper_plant):
		_failures.append("collector and industrial buildings must remain visually distinct")
	var mine_texture := IconCatalog.texture_for_key(copper_mine)
	if mine_texture == null or mine_texture != IconCatalog.texture_for_key(copper_mine):
		_failures.append("building paper composites must be cached across refreshes")
	if mine_texture != null and mine_texture.get_image().get_data() == \
			IconCatalog.texture_for_key(copper_plant).get_image().get_data():
		_failures.append("building kinds must produce visually different composites")


func _audit_unique_identity(domain: String, stable_id: String, semantic: StringName,
		signatures: Dictionary) -> void:
	if not IconCatalog.has_icon(semantic):
		_failures.append("%s has no icon: %s" % [domain, stable_id])
		return
	var signature := IconCatalog.implementation_signature(semantic)
	if signatures.has(signature):
		_failures.append("%s repeats %s for %s and %s" % [
			domain, signature, signatures[signature], stable_id
		])
	signatures[signature] = "%s:%s" % [domain, stable_id]


func _audit_paper_controls() -> void:
	for theme_path in ["res://assets/themes/player_session_theme.tres", "res://assets/themes/menu_atlas_theme.tres"]:
		var theme := load(theme_path) as Theme
		for pair in [["CheckBox", "checked"], ["CheckBox", "unchecked"], ["CheckButton", "checked"],
				["OptionButton", "arrow"], ["SpinBox", "updown"], ["Tree", "arrow"], ["LineEdit", "clear"]]:
			var texture := theme.get_icon(pair[1], pair[0])
			if texture == null or not texture.resource_path.contains("/paper_hud/control_icons/") \
					or texture.get_width() > 32 or texture.get_height() > 24:
				_failures.append("native control must use compact paper artwork: %s/%s" % [pair[0], pair[1]])
	for domain in ["agriculture", "engineering", "science", "society"]:
		if TechnologyTreeArt.domain_emblem(domain) != IconCatalog.texture_for_key(
				IconCatalog.technology_domain_semantic(domain)):
			_failures.append("technology domain bypasses paper catalog: %s" % domain)
	for state in range(6):
		if TechnologyTreeArt.state_seal(state) != IconCatalog.texture_for_key(
				IconCatalog.technology_state_semantic(state)):
			_failures.append("technology state bypasses paper catalog: %d" % state)
	for school in IdeologyArt.SCHOOL_ORDER:
		if IdeologyArt.emblem_for(school) != IconCatalog.texture_for_key(IdeologyArt.SCHOOL_ICONS[school]):
			_failures.append("ideology school bypasses paper catalog: %s" % school)
	var button := Button.new()
	IconButton.apply(button, &"good.grain", 24)
	if button.icon == null or button.get_theme_color("icon_normal_color") != Color.WHITE:
		_failures.append("paper buttons must keep generated color")
	IconButton.apply(button, &"action.close", 16)
	if button.icon != IconCatalog.texture_for_key(&"action.close") or not button.text.is_empty():
		_failures.append("action controls must use generated paper artwork too")
	button.free()
	var label := Label.new()
	IconButton.apply_to_label(label, &"good.grain", 24)
	IconButton.apply_to_label(label, &"good.logs", 24)
	var artwork := label.get_node_or_null("SemanticArtwork") as TextureRect
	if artwork == null or label.get_child_count() != 1 or artwork.texture != \
			IconCatalog.texture_for_key(&"good.logs"):
		_failures.append("label refresh must reuse its paper texture node")
	IconButton.apply_to_label(label, &"", 16)
	if artwork != null and artwork.visible:
		_failures.append("empty label must hide previous paper texture")
	label.free()


func _files_recursive(root: String, suffix: String) -> PackedStringArray:
	var files := PackedStringArray()
	var directory := DirAccess.open(root)
	if directory == null:
		_failures.append("could not open audit directory: %s" % root)
		return files
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		var path := root.path_join(name)
		if directory.current_is_dir():
			files.append_array(_files_recursive(path, suffix))
		elif name.ends_with(suffix):
			files.append(path)
		name = directory.get_next()
	directory.list_dir_end()
	return files
