extends SceneTree

## [popup-deferral 2026-11-20] 「玩家窗口」清单只在 GameUIManager.is_player_workspace_open()
## 里维护，叙事流程靠它决定静置还是弹窗。这里守住清单本身和关窗回调的接线：
## 方法名/清单写错要在本用例里报出来，否则要等真机第一次关窗才发现（事件永远不弹）。
## 完整「开着卷宗跑日」的集成路径在 player_country_ui_smoke_test.gd；该用例在本机无头
## 环境会在世界启动后崩（HEAD 同样崩，与本次改动无关），所以接线单独测。

const ManagerScript = preload("res://scripts/ui/game_ui_manager.gd")
const CountryPanelScript = preload("res://scripts/ui/components/country_panel.gd")

var checks := 0
var failures := 0

class ControllerStub extends Node:
	var rechecks := 0
	func recheck_narrative_popup() -> void:
		rechecks += 1

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _run() -> void:
	# 不进树：只要组件实例与清单，不要让 _ready 去建整层 UI。
	# 注意本用例有 await，必须不带 --quit 运行（--quit 只跑第一帧）。
	var ui = ManagerScript.new()
	var panel = CountryPanelScript.new()
	panel.visible = false
	ui.set("_country_panel", panel)
	_expect("bare manager reports no open workspace", not ui.is_player_workspace_open())
	panel.visible = true
	_expect("country dossier counts as a player workspace", ui.is_player_workspace_open())
	panel.visible = false
	_expect("closing the dossier releases the gate", not ui.is_player_workspace_open())

	var controller := ControllerStub.new()
	controller.name = "PlayerControllerStub"
	ui.set("_player_controller", controller)
	ui.notify_workspace_closed()
	_expect("close notification never re-enters synchronously", controller.rechecks == 0)
	await process_frame
	await process_frame
	_expect("close notification reaches the narrative recheck once", controller.rechecks == 1)

	controller.free()
	panel.free()
	ui.free()
	print("narrative_workspace_gate_test: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
