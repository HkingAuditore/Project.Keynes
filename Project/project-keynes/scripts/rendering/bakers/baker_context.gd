extends RefCounted
class_name DCBakerContext

## Phase B.2 / dots-migration-roadmap §4.2 0.3：map_baker.gd 拆分共享 context。
##
## map_baker.gd 2583 行将按职责拆为 5 个子 baker（terrain / climate / weather /
## overlay / atlas_encoders）+ 本 BakerContext。所有子 baker 接受一个
## DCBakerContext 实例，从中拿 MapData / WorldData / ViewAdapter / dirty mask
## 等共享状态，子 baker 不直接持有 MapData / WorldData 弱引用——避免拆分后
## 子 baker 之间互相耦合。
##
## 现状（2026-05-13）：拆分骨架已就位但函数还在 map_baker.gd 里。后续 PR 按
## bakers/<name>_baker.gd 顶部 TODO 列表逐个迁移。
##
## **本类零侵入**：在 map_baker.gd 完成完整拆分之前，BakerContext 只是 facade
## 工具——map_baker.gd 既有调用路径不强制走 context，新代码（含子 baker）才
## 必须走。

# 共享数据
var map: MapData = null
var world: WorldData = null  # WorldData 类型在 geography/world_data.gd
var hex_size: float = 0.0

# Phase B.2：所有读侧消费者通过 ViewAdapter 取 schema-mirrored 字段
# （CellViewAdapter 默认实现，与 cell.<field> 完全等价）。子 baker 读 cell
# 字段必须走 adapter；非 schema 字段（passable_sea / vegetation_vitality 等）
# 仍可直读 cell。Phase II 切换到 WorldViewAdapter 时 baker 一行不动。
var adapter: DCViewAdapter = null

# Atlas / dirty mask 池（partial atlas upload 等优化用）。后续从 map_baker.gd
# 既有 _atlas_dirty_rows_*  / _pending_*_buf 字段迁移过来。
var dirty_rows_terrain:  PackedByteArray = PackedByteArray()
var dirty_rows_climate:  PackedByteArray = PackedByteArray()
var dirty_rows_weather:  PackedByteArray = PackedByteArray()
var dirty_rows_overlay:  PackedByteArray = PackedByteArray()


func _init(map_data: MapData = null, world_data = null, hex_sz: float = 0.0) -> void:
	map = map_data
	world = world_data
	hex_size = hex_sz
	if map_data != null:
		adapter = DCViewAdapter.Cell.new(map_data.iter_cells())


## 重新构造 ViewAdapter（map 重新 generate / regenerate 后调用）。
func rebuild_adapter() -> void:
	if map == null:
		adapter = null
		return
	adapter = DCViewAdapter.Cell.new(map.iter_cells())


## 标记某行 terrain 区段 dirty（partial atlas upload 用，未来子 baker 消费）。
func mark_terrain_row_dirty(row: int) -> void:
	if row >= 0 and row < dirty_rows_terrain.size():
		dirty_rows_terrain[row] = 1


## 调试摘要。
func describe() -> String:
	return "DCBakerContext(map=%s adapter=%s)" % [
		"yes" if map != null else "no",
		adapter.describe() if adapter != null else "(null)",
	]
