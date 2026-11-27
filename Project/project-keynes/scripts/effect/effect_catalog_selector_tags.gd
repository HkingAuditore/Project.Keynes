extends RefCounted

## Compiles authored and rewritten effect targets into catalog selector tags.

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologyEffectParameterScript = preload(
	"res://scripts/ideology/ideology_effect_parameter.gd")
const IdeologySynergyDefinitionScript = preload(
	"res://scripts/ideology/ideology_synergy_definition.gd")
const TargetTagDictionaryScript = preload("res://scripts/effect/target_tag_dictionary.gd")


## Collect every distinct TAG rewrite replacement and append its union to the
## shared dictionary. Returns "" on success or a fully-qualified rejection.
##
## The scan is driven by the default ideology catalog, not by the compiled
## catalog, because compilation resolves override targets and route membership.
## It deliberately tolerates a missing catalog (bare effect tests) and does not
## mutate anything it cannot validate.
static func _append_ideology_rewrite_tags(tag_list: Array, tag_ids: Dictionary,
		ideology_catalog: Resource = null) -> String:
	if tag_list.is_empty() or tag_ids.is_empty():
		return ""
	if ideology_catalog == null:
		ideology_catalog = IdeologyCatalogScript.load_default()
	if ideology_catalog == null or not ideology_catalog is IdeologyCatalogScript:
		return ""
	var expressions := PackedStringArray()
	for synergy in ideology_catalog.synergies:
		if synergy == null or not synergy is IdeologySynergyDefinitionScript:
			continue
		for override in synergy.overrides:
			if override == null or not override is IdeologyEffectParameterScript:
				continue
			if int(override.field) != IdeologyEffectParameterScript.Field.TAG:
				continue
			var expression: String = override.tag_union_name()
			if not expression.is_empty() and not expressions.has(expression):
				expressions.append(expression)
	if expressions.is_empty():
		return ""
	for expression in expressions:
		if tag_ids.has(expression):
			continue
		var members := PackedStringArray(expression.split("|", false))
		for member in members:
			if not tag_ids.has(member):
				return "effect_catalog_target_selector_tag_unknown:%s" % member
		var union_error := _materialize_tag_union(members, tag_list, tag_ids)
		if not union_error.is_empty():
			return union_error
		if not tag_ids.has(expression):
			return "effect_catalog_target_tag_union_invalid:%s" % expression
	return ""


## Append a deterministic union tag for the requested member names. Names already
## present need no work; every missing name must be a real atom/composite in the
## dictionary, so a typo fails here rather than becoming a never-matching row.
static func _materialize_tag_union(names: PackedStringArray, tag_list: Array,
		tag_ids: Dictionary) -> String:
	# Canonicalize the FULL member list, not only the names that happen to be
	# missing. `coast|delta` needs a synthetic OR even when both atoms exist;
	# otherwise the rewrite names an expression that no dictionary id owns.
	var canonical := PackedStringArray()
	for name in names:
		if not canonical.has(name):
			canonical.append(name)
	canonical.sort()
	if canonical.is_empty():
		return "effect_catalog_target_tag_union_invalid"
	var combined_name := "|".join(canonical)
	if tag_ids.has(combined_name):
		return ""
	# Every member is validated by union(): only names already in the dictionary
	# can be members. A replacement like `a|b` is materialized as one synthetic
	# entry so downstream cards still reference one stable id.
	var merged: Dictionary = TargetTagDictionaryScript.union(canonical, tag_list)
	if not bool(merged.get("ok", false)):
		return "effect_catalog_target_tag_union_invalid:%s" % String(
			merged.get("reason", ""))
	var composite := String(merged.get("name", ""))
	if composite.is_empty():
		return "effect_catalog_target_tag_union_invalid"
	if not tag_ids.has(composite):
		if tag_list.size() >= TargetTagDictionaryScript.MAX_TAGS:
			return "effect_catalog_target_tag_table_over_capacity:%d" % (
				tag_list.size() + 1)
		tag_list.append({"name": composite, "rows": merged["rows"]})
		tag_ids[composite] = tag_list.size()
	return ""


## Resolve a TAG rewrite expression to the id of its concrete dictionary entry.
## Single names use the existing tag; `a|b` uses the sorted synthetic union
## appended above. The caller has already validated every member.
static func resolve_rewrite_tag_id(expression: String, tag_ids: Dictionary) -> int:
	var canonical := PackedStringArray()
	for part in expression.split("|", false):
		var name := String(part).strip_edges()
		if not name.is_empty() and not canonical.has(name):
			canonical.append(name)
	canonical.sort()
	if canonical.is_empty():
		return 0
	var name := "|".join(canonical)
	return int(tag_ids.get(name, 0))


## Resolve a card's authored tag name into the raw 1-based id stored in
## `target_selector_param[1]`, in place on `program`.
##
## Returns "" on success, or a fully-qualified rejection reason. Split out of
## the compile loop so the id contract can be tested without a card file: the
## interesting cases (unknown name, empty dictionary, param array shorter than
## two slots) are all cheap to stage here and expensive to stage in .tres.
static func _apply_selector_tag(program: Resource, tag_name: StringName,
		tag_ids: Dictionary) -> String:
	if tag_name == &"":
		return ""
	var expression := String(tag_name)
	var members := PackedStringArray(expression.split("|", false))
	for index in range(members.size()):
		members[index] = members[index].strip_edges()
	if members.size() > 1:
		var canonical := PackedStringArray()
		for member in members:
			if member.is_empty():
				continue
			if not canonical.has(member):
				canonical.append(member)
		canonical.sort()
		expression = "|".join(canonical)
	var resolved := int(tag_ids.get(expression, 0))
	if resolved <= 0:
		# Distinguish "no dictionary at all" from "typo": when the economy
		# catalog failed to compile, every name looks unknown and the error
		# would send the next reader hunting for a bad tag.
		var reason := "effect_catalog_target_selector_tag_unknown" \
			if not tag_ids.is_empty() \
			else "effect_catalog_target_selector_tag_no_dictionary"
		return "%s:%s:%s" % [reason, String(program.key), expression]
	return _write_selector_tag_id(program, resolved)


## The multi-name form of the above: fold N tag names into one synthetic tag
## and point `param[1]` at it.
##
## This is what makes a 3+-tag AND authorable at all. The dictionary ships a
## fixed menu of *pairwise* composites (`build()` pre-bakes scale × sector,
## market × landform, ...), so without this a card wanting "边地的粮作农业地块"
## would need a hand-written dictionary entry. Here the card just lists the
## three names and the compiler assembles the clause product.
##
## `tag_list` / `tag_ids` are the build's own tables and are mutated: a new
## synthetic tag is **appended**, because tag ids are array indexes — inserting
## would shift every id below it and silently retarget cards that never changed.
static func _apply_selector_tags(program: Resource, names: PackedStringArray,
		tag_list: Array, tag_ids: Dictionary) -> String:
	if names.is_empty():
		return ""
	var selector_kind := int(program.target_selector_kind)
	if selector_kind <= 0 or selector_kind > EffectCatalogScript.POD_MAX_SELECTOR_KIND:
		return ""
	if names.size() == 1:
		var union_members := PackedStringArray()
		for part in String(names[0]).split("|", false):
			var member := String(part).strip_edges()
			if not member.is_empty() and not union_members.has(member):
				union_members.append(member)
		union_members.sort()
		if union_members.size() > 1:
			if tag_ids.is_empty():
				return "effect_catalog_target_selector_tag_no_dictionary:%s:%s" % [
					String(program.key), String(names[0])]
			for member in union_members:
				if int(tag_ids.get(member, 0)) <= 0:
					return "effect_catalog_target_selector_tag_unknown:%s:%s" % [
						String(program.key), member]
			var union_error := _materialize_tag_union(
				union_members, tag_list, tag_ids)
			if not union_error.is_empty():
				return "%s:%s" % [union_error, String(program.key)]
			var resolved := int(tag_ids.get("|".join(union_members), 0))
			if resolved <= 0:
				return "effect_catalog_target_tag_union_invalid:%s" % String(
					program.key)
			return _write_selector_tag_id(program, resolved)
		return _apply_selector_tag(program, StringName(names[0]), tag_ids)
	if tag_ids.is_empty():
		return "effect_catalog_target_selector_tag_no_dictionary:%s:%s" % [
			String(program.key), "&".join(names)]
	# Check membership before folding so an unknown name reports the same
	# `tag_unknown` invariant the single-name path reports, rather than a
	# budget/duplicate reason that points the reader at the wrong thing.
	var selector_names := PackedStringArray()
	for name in names:
		var members := PackedStringArray()
		for part in String(name).split("|", false):
			var member := String(part).strip_edges()
			if not member.is_empty() and not members.has(member):
				members.append(member)
		members.sort()
		for member in members:
			if int(tag_ids.get(member, 0)) <= 0:
				return "effect_catalog_target_selector_tag_unknown:%s:%s" % [
					String(program.key), member]
		if members.size() > 1:
			var union_error := _materialize_tag_union(members, tag_list, tag_ids)
			if not union_error.is_empty():
				return "%s:%s" % [union_error, String(program.key)]
		else:
			members = PackedStringArray([String(name)])
		var resolved_name := "|".join(members)
		if int(tag_ids.get(resolved_name, 0)) <= 0:
			return "effect_catalog_target_selector_tag_unknown:%s:%s" % [
				String(program.key), String(name)]
		selector_names.append(resolved_name)
	var merged: Dictionary = TargetTagDictionaryScript.intersection(
		selector_names, tag_list)
	if not bool(merged.get("ok", false)):
		return "effect_catalog_target_selector_intersection:%s:%s" % [
			String(program.key), String(merged.get("reason", ""))]
	var composite := String(merged["name"])
	var resolved := int(tag_ids.get(composite, 0))
	if resolved <= 0:
		if tag_list.size() >= TargetTagDictionaryScript.MAX_TAGS:
			return "effect_catalog_target_tag_table_over_capacity:%s:%d" % [
				String(program.key), tag_list.size() + 1]
		tag_list.append({"name": composite, "rows": merged["rows"]})
		resolved = tag_list.size()
		tag_ids[composite] = resolved
	return _write_selector_tag_id(program, resolved)


## Single writer for `param[1]`, shared by both forms. Keeping it in one place
## is the point: `param[0]` is the cell cap and must survive untouched, and a
## second copy of this resize dance is how it stops surviving.
static func _write_selector_tag_id(program: Resource, resolved: int) -> String:
	var params: PackedInt32Array = program.target_selector_param
	if params.size() < 2:
		# param[0] is the cell cap and stays 0 (= take the runtime default).
		params.resize(2)
	params[1] = resolved
	program.target_selector_param = params
	return ""
