class_name DecorationManifest
extends Resource

# 数据驱动的"植被 / 点缀"清单。
# hex_renderer 按本清单生成 N 个 DetailScatterLayer（每个 entry = 一层 MultiMesh）。
# 新增一种点缀 = 在 layers 数组里追加一个 ShrubVisualProfile(.tres)，无需改渲染器代码。
#
# 留空 / 未配置时，hex_renderer 回退到旧的 grass/shrub/tree 三个 @export profile，
# 行为与历史完全一致（阶段 A 默认即此回退路径，保证 1:1）。
#
# 排序即绘制顺序的辅助参考；真正的层叠由各 profile.render_z_index 决定。

@export var layers: Array[ShrubVisualProfile] = []


func valid_layers() -> Array:
	var out: Array = []
	for p in layers:
		if p != null:
			out.append(p)
	return out
