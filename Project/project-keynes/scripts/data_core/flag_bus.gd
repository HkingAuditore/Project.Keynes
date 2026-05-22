extends Node
class_name DCFlagBus

## Phase 4.4 — Feature Flag Hot-Reload Signal Bus（dots-phase4-followup.md §4.4）。
##
## **当前实现：骨架阶段**——signal 接口与基础 API 已就位；DCWorld._on_flag_changed
## handler 在 Phase 4.4 PR-4.4.1 时连接。当前 caller 代码改 cp.<flag> 之后**手动**
## 调一次 `DCFlagBus.notify_flag_changed(name, new_value)` 触发 hot-reload。
##
## ─── 为什么不放在 DCFeatureFlags ───────────────────────────────────────
##
## DCFeatureFlags extends RefCounted + 全 static API（FLAGS 是 const Array）。
## signal 需要 `extends Object`（或 Node），且需要持久实例。把 signal 放本独立
## 类后：
##   - DCFeatureFlags 保持纯 static 工具风格（is_on / find / validate_against）
##   - DCFlagBus 是 Node singleton（autoload），全局可达
##   - 解耦"flag 元数据查询"与"flag 变更通知"两个职责
##
## ─── 加入 autoload ────────────────────────────────────────────────────
##
## 在 `project.godot` 的 [autoload] 段加一行：
##   DCFlagBus="*res://scripts/data_core/flag_bus.gd"
##
## 加入后任何脚本可：
##   DCFlagBus.flag_changed.connect(self._on_flag_changed)
##   DCFlagBus.notify_flag_changed(&"demo_thermal_gradient_enabled", true)
##
## ─── caller 改 flag 的标准 SOP（Phase 4.4 完成后）────────────────────
##
## 改前：
##   cp.demo_thermal_gradient_enabled = true        # 改了但 DCWorld 不知道，需重启
##
## 改后：
##   cp.demo_thermal_gradient_enabled = true
##   DCFlagBus.notify_flag_changed(&"demo_thermal_gradient_enabled", true)  # 触发 hot-reload

## flag 变更通知信号。
##
## 参数：
##   name       : StringName     — flag 名（DCFeatureFlags.FLAGS 中的 name 字段）
##   new_value  : Variant        — 新值（通常 bool；future enum flag 可能是 int）
##   profile    : Resource/null  — 被改写的 ClimateProfile（多 profile 场景区分用）
##
## listener 应在自身关注的 flag 变化时执行 reload 动作（例如 DCWorld 在
## use_data_core / demo_thermal_gradient_enabled 变化时调 unbind/rebind_map_data）。
signal flag_changed(name: StringName, new_value, profile)


# PR-4.4：单例引用，main.gd 在 _ready() 通过 install(parent) 创建。
static var singleton: DCFlagBus = null

## 已注册的 bind-critical flag 列表——对这些 flag 的变化必须触发 DCWorld 的
## bind_map_data 重 bind（否则 attach 关系不会更新）。其他 flag（hot-loop
## 路径切换之类）不需要 rebind，listener 自行处理。
##
## 历史注：`use_data_core` 曾在此列表（DataCore 主开关 / bind-critical），
## 已在 dots-flag-prune-pr1（2026-05-22）连同 ClimateProfile 字段一并删除——
## DataCore 已恒走单路径，不再有 bind/unbind 切换语义。
const BIND_CRITICAL_FLAGS: Array[StringName] = [
	&"use_world_view_adapter",
	&"demo_thermal_gradient_enabled",
]


## 通知所有 listener flag 已变化。caller 必须**已经**写入 Resource 字段
## 之后再调本方法。
##
## 实现说明：当前阶段仅 emit signal；Phase 4.4 PR-4.4.1 时增加额外的 console
## 日志 / Telemetry overlay 发布。
func notify_flag_changed(name: StringName, new_value, profile = null) -> void:
	flag_changed.emit(name, new_value, profile)
	if OS.is_debug_build():
		print("[DCFlagBus] flag_changed: %s = %s%s" % [
			String(name), str(new_value),
			" (BIND-CRITICAL)" if is_bind_critical(name) else "",
		])


## 是否是 bind-critical flag（变化时必须触发 DCWorld unbind/rebind）。
static func is_bind_critical(name: StringName) -> bool:
	return name in BIND_CRITICAL_FLAGS


# ─── PR-4.4：单步 set_flag 高阶 API ──────────────────────────────


## 写入 flag 到 profile + 立即 emit flag_changed 信号。caller 不需要再手动调
## notify_flag_changed —— 一行搞定。
##
## 用例：
##   DCFlagBus.singleton.set_flag(cp, &"demo_thermal_gradient_enabled", true)
##   →  cp.demo_thermal_gradient_enabled = true
##   →  emit flag_changed(&"demo_thermal_gradient_enabled", true, cp)
##   →  main.gd 监听 → 立即重 bake demo overlay 等 hot-reload 路径
##
## profile 必须是 ClimateProfile 实例（或同等 Resource，含 @export var <name>）。
## 不存在该 property 时 push_error 不 emit。
func set_flag(profile, name: StringName, new_value) -> void:
	if profile == null:
		push_error("[DCFlagBus] set_flag('%s'): profile is null" % String(name))
		return
	var name_str: String = String(name)
	if not name_str in profile:
		push_error("[DCFlagBus] set_flag('%s'): profile has no such property" % name_str)
		return
	# 校验 flag 在 FLAGS 表里有注册（debug build 提示 typo）
	if OS.is_debug_build() and not DCFeatureFlags.is_known(name):
		push_warning("[DCFlagBus] set_flag('%s'): flag not registered in DCFeatureFlags.FLAGS table" % name_str)
	profile.set(name_str, new_value)
	notify_flag_changed(name, new_value, profile)


# ─── PR-4.4：单例 install / uninstall ───────────────────────────────


## main.gd 在 _ready() 调用：
##   var bus: DCFlagBus = DCFlagBus.install(self)
##   bus.flag_changed.connect(_on_flag_changed)
##
## 推荐方式（autoload）见 flag_bus.gd 头部注释；install() 是 autoload 不可用时
## 的备用方案（runtime add_child）。
static func install(parent: Node) -> DCFlagBus:
	if singleton == null:
		singleton = DCFlagBus.new()
		singleton.name = "DCFlagBusSingleton"
		parent.add_child(singleton)
	return singleton


## 拆卸单例（regenerate / 退出场景时调用，避免 stale signal connection）。
static func uninstall() -> void:
	if singleton != null and is_instance_valid(singleton):
		if singleton.is_inside_tree():
			singleton.queue_free()
		singleton = null
