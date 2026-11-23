extends RefCounted

## Shared cold configuration body; synchronous callers pass no frame context.
static func configure(context, host, world_ext: DCWorldExt, cell_count: int, seed: int,
		profile, compiled_catalog: Dictionary) -> Dictionary:
	host._world_ext = world_ext
	host._profile = profile
	if host._profile == null:
		host._profile = ResourceLoader.load(host.DEFAULT_PROFILE_PATH, "Resource")
	if host._world_ext == null:
		return {"ok": false, "reason": "DCWorldExt economy API unavailable"}
	if host._profile == null:
		return {"ok": false, "reason": "EconomyProfile unavailable"}
	if context != null:
		host._profile = host._profile.duplicate_deep(Resource.DEEP_DUPLICATE_ALL)
	host._catalog = compiled_catalog.duplicate(true) if not compiled_catalog.is_empty() \
		else host.EconomyCatalogScript.compile_native_catalog() if context == null \
		else await host.EconomyCatalogScript.compile_native_catalog_cooperative(context)
	if not bool(host._catalog.get("ok", false)):
		return host._catalog
	var native_catalog: Dictionary = host._catalog.duplicate()
	native_catalog.erase("ok")
	await host.EconomyFacadeDisplayScript._configure_displays(context, host)
	if context != null:
		if context.canceled:
			return {"ok": false, "reason": "loading_canceled"}
		context.stage("economy_native_install")
	var native_profile: Dictionary = host._profile.to_native_profile()
	host.EconomyFacadeDisplayScript.apply_forced_cadence_env(native_profile)
	var result: Dictionary = host._world_ext.configure_economy(
		native_catalog, native_profile, cell_count, seed)
	host._configured = bool(result.get("ok", false))
	if host._configured:
		var natural: Dictionary = host._world_ext.configure_economy_natural_resources(
			ResourceProfileRegistry.build_pass_knobs())
		if not bool(natural.get("ok", false)):
			host._configured = false
			natural["reason"] = String(natural.get("code", "natural_resource_configuration_failed"))
			return natural
	host._construction_receipt_cursor = 0
	host._colonization_receipt_cursors.clear()
	host._canal_receipt_cursors.clear()
	return result
