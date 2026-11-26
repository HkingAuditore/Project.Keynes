extends RefCounted


## 创建 archetype，返回 arch_id (int)。
## comp_ids 仅作记录；首版不做"必须 entity 拥有这些 component"强校验。
static func create_archetype(owner: Variant, name: StringName, comp_ids: Array = []) -> int:
	if owner._archetype_by_name.has(name):
		return int(owner._archetype_by_name[name])
	var arch_id: int = owner._archetypes.size()
	owner._archetypes.append({ "name": name, "comp_ids": comp_ids })
	owner._archetype_by_name[name] = arch_id
	# 确保 _entity_archetype 长度 = entity_count，初值 _ARCH_NONE
	if owner._entity_archetype.size() < owner._entity_count:
		var old_size: int = owner._entity_archetype.size()
		owner._entity_archetype.resize(owner._entity_count)
		for i in range(old_size, owner._entity_count):
			owner._entity_archetype[i] = owner._ARCH_NONE
	return arch_id


## 把 entity 分配到 archetype。idx 越界时自动扩容 _entity_archetype。
static func assign_archetype(owner: Variant, idx: int, arch_id: int) -> void:
	if idx < 0:
		return
	if idx >= owner._entity_archetype.size():
		var old: int = owner._entity_archetype.size()
		owner._entity_archetype.resize(idx + 1)
		for i in range(old, idx + 1):
			owner._entity_archetype[i] = owner._ARCH_NONE
	owner._entity_archetype[idx] = arch_id


## 取 entity 当前 archetype id；未赋值返回 _ARCH_NONE。
static func get_archetype(owner: Variant, idx: int) -> int:
	if idx < 0 or idx >= owner._entity_archetype.size():
		return owner._ARCH_NONE
	return owner._entity_archetype[idx]


## archetype "无 / 无效"标记。
static func archetype_none(owner: Variant) -> int:
	return owner._ARCH_NONE


## archetype 数量。
static func archetype_count(owner: Variant) -> int:
	return owner._archetypes.size()


## archetype 名 → id；不存在返回 -1。
static func archetype_id(owner: Variant, name: StringName) -> int:
	return int(owner._archetype_by_name.get(name, -1))
