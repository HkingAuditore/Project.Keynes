extends RefCounted

const Snapshot = preload("res://scripts/game/loading_catalog_snapshot.gd")
const Economy = preload("res://scripts/economy/economy_catalog.gd")
const Effects = preload("res://scripts/effect/effect_domain_catalog.gd")
const Cache = preload("res://scripts/game/loading_catalog_cache.gd")
const Facade = preload("res://scripts/economy/economy_facade.gd")
const Technology = preload("res://scripts/economy/technology_catalog.gd")

## 临时诊断入口（PK_PREBAKE_DIAG=1 时由插件在编辑器上下文调用）。
static func diagnose() -> void:
	print("[diag] editor_feature=%s editor_hint=%s" % [str(OS.has_feature("editor")), str(Engine.is_editor_hint())])
	var script_path := "res://scripts/data/need_profile.gd"
	var need_path := "res://data/economy/needs/clothing.tres"
	var s1 = load(script_path)
	print("[diag] load() script id=%d can_instantiate=%s" % [
		s1.get_instance_id(), str(s1.can_instantiate())])
	var fresh = s1.new()
	print("[diag] new() use_tags_type=%d" % typeof(fresh.get("use_tags")))
	var first = ResourceLoader.load(need_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var s2 = first.get_script()
	print("[diag] res script id=%d same_as_load=%s can_instantiate=%s path=%s" % [
		s2.get_instance_id(), str(s1 == s2), str(s2.can_instantiate()), s2.resource_path])
	var reload_err = s2.reload()
	print("[diag] reload err=%s can_instantiate=%s" % [
		error_string(reload_err), str(s2.can_instantiate())])
	var third = ResourceLoader.load(need_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	print("[diag] replace-mode use_tags_type=%d value=%s can_instantiate=%s" % [
		typeof(third.get("use_tags")), str(third.get("use_tags")),
		str((third.get_script() as GDScript).can_instantiate())])
	var needs: Array = Economy._load_resources(Economy.NEED_DIR)
	print("[diag] needs_loaded=%d first_type=%d" % [needs.size(), typeof(needs[0].get("use_tags"))])
	var tree := Engine.get_main_loop() as SceneTree
	for i in range(30):
		await tree.process_frame
	var needs_later: Array = Economy._load_resources(Economy.NEED_DIR)
	print("[diag] after_30_frames first_type=%d" % typeof(needs_later[0].get("use_tags")))
	var t := Time.get_ticks_usec()
	var eco := Economy.compile_native_catalog()
	print("[diag] compile ms=%.1f ok=%s keys=%d reason=%s" % [
		(Time.get_ticks_usec() - t) / 1000.0, str(eco.get("ok", false)), eco.size(), str(eco.get("reason", ""))])

static func bake() -> Error:
	Cache.invalidate()
	DirAccess.make_dir_recursive_absolute(Cache.DIRECTORY)
	var snapshot := Snapshot.new()
	snapshot.columns = Economy.compile_native_catalog()
	if not bool(snapshot.columns.get("ok",false)):
		return ERR_INVALID_DATA
	var effect: Resource = Effects.build()
	if effect == null:
		return ERR_INVALID_DATA
	var err := ResourceSaver.save(snapshot,Cache.DIRECTORY+"economy.res",ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		return err
	err = ResourceSaver.save(effect,Cache.DIRECTORY+"effect.res",ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		return err
	var visual := Facade.new()
	visual._profession_display_names = Facade._load_display_names(Economy.PROFESSION_DIR)
	visual._ethnicity_display_names = Facade._load_display_names(Economy.ETHNICITY_DIR)
	visual._building_display_names = Facade._load_display_names(Economy.BUILDING_DIR)
	visual._need_display_names = Economy.need_display_names()
	visual._good_display_names = Facade._load_display_names(Facade.GOOD_PROFILE_DIR)
	visual._load_family_effect_displays()
	var display := Snapshot.new()
	for field in ["_profession_display_names","_ethnicity_display_names","_building_display_names","_need_display_names","_good_display_names","_family_trait_descriptions","_family_trait_copy","_family_trait_effect_keys","_family_effect_displays","_family_modifier_displays","_family_trigger_displays"]:
		display.columns[field] = visual.get(field)
	err = ResourceSaver.save(display,Cache.DIRECTORY+"display.res",ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		return err
	var files: Dictionary = {}
	var extensions := Snapshot.new()
	extensions.columns = effect.get("native_extensions")
	err = ResourceSaver.save(extensions,Cache.DIRECTORY+"effect_extensions.res",ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		return err
	var technology := Snapshot.new()
	technology.columns = Technology.compile_native_catalog()
	err = ResourceSaver.save(technology,Cache.DIRECTORY+"technology.res",ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		return err
	var research := Snapshot.new()
	research.columns = ResearchSignalCatalog.compile_native_catalog()
	err = ResourceSaver.save(research,Cache.DIRECTORY+"research.res",ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		return err
	for dir in ["res://scripts/research", "res://data", "res://scripts/economy", "res://scripts/family", "res://scripts/effect", "res://scripts/ideology", "res://scripts/modifier", "res://scripts/trigger", "res://scripts/data", "res://scripts/country"]:
		_collect_sources(dir,files)
	var file := FileAccess.open(Cache.DIRECTORY+"sources.json",FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(files,"\t",true))
	print("[loading-catalog] rebuilt %d source fingerprints" % files.size())
	return OK

static func _collect_sources(directory: String, files: Dictionary) -> void:
	if directory == Cache.DIRECTORY.trim_suffix("/"):
		return
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	for name in dir.get_files():
		if name.get_extension() in ["gd","tres","json","csv"]:
			var path := directory+"/"+name
			files[path] = FileAccess.get_sha256(path)
	for name in dir.get_directories():
		_collect_sources(directory+"/"+name,files)
