extends ColorRect
class_name WorldLoadingOverlay

const STAGE_LABELS := {
	"preparing": "正在建立世界生成参数",
	"continents": "正在塑造大陆与海盆",
	"climate": "正在校准纬度、气候与海冰",
	"terrain": "正在烘焙地形与水文图层",
	"physical": "正在求解风带与海洋环流",
	"atlas": "正在整理生态与地块索引",
	"encode": "正在编码地图材质与图集",
	"ecology": "正在建立资源与生态档案",
	"simulation": "正在装配国家、经济与模拟系统",
	"done": "世界测绘完成",
}

var _card: PanelContainer
var _title_label: Label
var _stage_label: Label
var _percent_label: Label
var _progress: ProgressBar
var _active_tween: Tween
var _last_stage: String = ""
var _last_fraction: float = 0.0


func _ready() -> void:
	if _card != null:
		return
	_card = get_node_or_null("Center/Card") as PanelContainer
	_title_label = get_node_or_null("Center/Card/Content/Title") as Label
	_stage_label = get_node_or_null("Center/Card/Content/StageRow/Stage") as Label
	_percent_label = get_node_or_null("Center/Card/Content/StageRow/Percent") as Label
	_progress = get_node_or_null("Center/Card/Content/Progress") as ProgressBar
	var icon := get_node_or_null("Center/Card/Content/StageRow/Icon") as IconBadge
	if _card == null or _title_label == null or _stage_label == null \
			or _percent_label == null or _progress == null or icon == null:
		push_error("WorldLoadingOverlay 必须通过 world_loading_overlay.tscn 实例化。")
		return
	icon.set_semantic(&"country.world", UITokens.ACCENT)


func show_message(message: String) -> void:
	if _card == null:
		_ready()
	_kill_tween()
	visible = true
	modulate = Color.WHITE
	_card.modulate = Color.WHITE
	_title_label.text = message
	_stage_label.text = "正在准备地图运行时"
	_percent_label.text = "0%"
	_progress.value = 0.0
	_last_stage = ""
	_last_fraction = 0.0


func set_progress(stage: String, fraction: float) -> void:
	if _card == null:
		_ready()
	_last_fraction = maxf(_last_fraction, clampf(fraction, 0.0, 1.0))
	var percent := clampi(int(round(_last_fraction * 100.0)), 0, 100)
	_title_label.text = "正在生成世界"
	_percent_label.text = "%d%%" % percent
	_progress.value = percent
	if stage != _last_stage:
		_last_stage = stage
		_stage_label.text = String(STAGE_LABELS.get(stage, stage))


func hide_completed() -> void:
	if not visible:
		return
	_kill_tween()
	_title_label.text = "世界测绘完成"
	_stage_label.text = "档案已就绪，正在揭示地图"
	_percent_label.text = "100%"
	_progress.value = 100.0
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_active_tween.tween_property(_card, "modulate", Color(1.08, 1.04, 0.92, 1.0), 0.12)
	_active_tween.tween_interval(0.10)
	_active_tween.parallel().tween_property(self, "modulate:a", 0.0, UITokens.ANIM_SLOW)
	_active_tween.parallel().tween_property(_card, "scale", Vector2(0.985, 0.985), UITokens.ANIM_SLOW)
	_active_tween.tween_callback(func() -> void:
		visible = false
		modulate = Color.WHITE
		_card.modulate = Color.WHITE
		_card.scale = Vector2.ONE
	)


func _kill_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
