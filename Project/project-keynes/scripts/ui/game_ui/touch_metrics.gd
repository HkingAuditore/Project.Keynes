extends RefCounted

static func _apply_touch_hud_metrics(host) -> void:
	var settings: Node = host.get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return
	var scaling = settings.call("ui_scaling")
	if scaling == null or not bool(scaling.call("is_touch_profile")):
		return
	for path in ["UIRoot/HUDLayer/PlayerTopBar", "UIRoot/HUDLayer/CountryActionBar"]:
		var bar: Node = host.get_node_or_null(path)
		if bar != null and bar.has_method("apply_touch_metrics"):
			bar.call("apply_touch_metrics", host.TOUCH_MIN_HEIGHT)
	# 面板层：经济卷宗/科技/家族/理念/国家面板/暂停菜单/GM 控制台/殖民规划/年报/store
	# 全部挂在这三层的下面。这里一次性 watch 三层，靠 child_entered_tree 覆盖
	# 「之后才实例化/换页/重建列表」的控件——不用在几十个 .tscn 里各写一遍。
	host._watch_touch_panels()
