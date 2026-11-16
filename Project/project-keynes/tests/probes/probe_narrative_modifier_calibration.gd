extends SceneTree

## 修饰器标定探针：把「卡面百分比」和「原生实际乘数」放到同一张表里。
##
## 叙事事件的两族定义语义不同（见 docs/design/narrative-event-authoring.md §2.2）：
##   economy.city.good/building.*  → ADD 1.0，magnitude 就是幅度；
##   family.city.*                 → MULTIPLY 1.02~1.05，magnitude 只放大那 2~5%。
## 这个探针按现有 catalog 的写法逐条实测，用来核对新写的内容，也用来复查旧内容。
##
## 跑法：
##   Godot --headless --path Project/project-keynes \
##     --script tests/probes/probe_narrative_modifier_calibration.gd

const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[probe] SKIP")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var facade = ModifierFacadeScript.new()
	print("[probe] configured=", facade.configure(ext, 32).get("ok", false))
	var cases := [
		["family.city.agriculture_output_boost", "economy.city.building.agriculture_output_factor", 75366, 2, 1, 2],
		["family.city.production_boost", "economy.city.output_factor", 72090, 2, 1, 3],
		["family.city.trade_output_boost", "economy.city.trade_output_factor", 78643, 2, 1, 4],
		["family.city.birth_cut", "economy.city.birth_factor", 52429, 2, 1, 5],
		["ideology.country.output.knowledge_factor.gain", "country.output.knowledge_factor", 75366, 1, 2, 40],
		["ideology.country.output.extractive_factor.gain", "country.output.extractive_factor", 75366, 1, 2, 41],
	]
	for c in cases:
		var domain: int = c[3]
		var scope: int = c[4]
		var handle: int = c[5]
		facade.queue_apply(StringName(c[0]),
			{"domain": domain, "scope": scope, "entity_handle": handle if scope == 2 else 0,
				"group_handle": handle if scope == 1 else 0},
			{"type": 0x4E415252, "id": handle}, 120, 1, 1, 190, int(c[2]))
		ext.run_modifier_daily(1)
		var actual := float(ext.evaluate_modifier_stat(domain, handle if scope == 2 else 0,
			handle if scope == 1 else 0, c[1], 1.0))
		print("[probe] %s mag=%d -> %s = %.4f (delta %+.1f%%)" % [
			c[0], int(c[2]), c[1], actual, (actual - 1.0) * 100.0])
	quit(0)
