extends SceneTree

## Parse probe for the new politics scripts. It compiles the scripts and their
## preloaded dependencies (not the whole game scene, which needs imported art).

const StratumRebellionContentScript = preload(
	"res://scripts/politics/stratum_rebellion_content.gd")


func _init() -> void:
	var def = StratumRebellionContentScript.build(
		1, "农户", "测试城", [0], {0: PackedInt32Array([40000, 25536])}, [50])
	var soldier = StratumRebellionContentScript.build(
		1, "军士", "测试城", [0], {0: PackedInt32Array([40000, 25536])}, [50],
		"soldier")
	var merchant = StratumRebellionContentScript.build(
		1, "商人", "测试城", [0], {0: PackedInt32Array([40000, 25536])}, [50],
		"merchant")
	var ok: bool = def != null and def.options.size() == 1 \
		and String(soldier.body_text).contains("营") \
		and String(merchant.body_text).contains("厘金")
	print("politics parse: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
