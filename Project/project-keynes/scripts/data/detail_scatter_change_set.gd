class_name DetailScatterChangeSet
extends RefCounted

## 植被散布的结构化变更集。只携带会改变实例拓扑的离散轴；温湿、天气、
## 积雪与 vitality 继续由 dyn/eco LUT 在 shader 中消费，不进入本结构。

const AXIS_VEGETATION: int = 1 << 0
const AXIS_LANDFORM: int = 1 << 1
const AXIS_COVER: int = 1 << 2
const AXIS_UNKNOWN: int = 1 << 7

var cell_indices: PackedInt32Array = PackedInt32Array()
var axis_masks: PackedByteArray = PackedByteArray()
var old_vegetation: PackedByteArray = PackedByteArray()
var new_vegetation: PackedByteArray = PackedByteArray()
var old_landform: PackedByteArray = PackedByteArray()
var new_landform: PackedByteArray = PackedByteArray()
var old_cover: PackedByteArray = PackedByteArray()
var new_cover: PackedByteArray = PackedByteArray()
var generation: int = 0


func is_empty() -> bool:
	return cell_indices.is_empty()


func size() -> int:
	return cell_indices.size()


func is_well_formed() -> bool:
	var n := cell_indices.size()
	return axis_masks.size() == n \
		and old_vegetation.size() == n and new_vegetation.size() == n \
		and old_landform.size() == n and new_landform.size() == n \
		and old_cover.size() == n and new_cover.size() == n


func append_change(
		cell_index: int,
		axis_mask: int,
		old_veg: int,
		new_veg: int,
		old_lf: int,
		new_lf: int,
		old_cv: int,
		new_cv: int
) -> void:
	if cell_index < 0:
		return
	cell_indices.append(cell_index)
	axis_masks.append(axis_mask & 0xFF)
	old_vegetation.append(old_veg & 0xFF)
	new_vegetation.append(new_veg & 0xFF)
	old_landform.append(old_lf & 0xFF)
	new_landform.append(new_lf & 0xFF)
	old_cover.append(old_cv & 0xFF)
	new_cover.append(new_cv & 0xFF)


func duplicate_set():
	var out = get_script().new()
	out.cell_indices = cell_indices.duplicate()
	out.axis_masks = axis_masks.duplicate()
	out.old_vegetation = old_vegetation.duplicate()
	out.new_vegetation = new_vegetation.duplicate()
	out.old_landform = old_landform.duplicate()
	out.new_landform = new_landform.duplicate()
	out.old_cover = old_cover.duplicate()
	out.new_cover = new_cover.duplicate()
	out.generation = generation
	return out
