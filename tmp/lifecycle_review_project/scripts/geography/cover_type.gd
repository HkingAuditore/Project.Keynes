# cover_type.gd
# Milestone 1：临时/永久覆盖物（Cover）独立轴。
# 与 LandformType / VegetationType 正交：覆盖物盖在地形与植被之上，
# 决定当下能否通行（雪 / 海冰可走，冰川不可），不影响下面真正的植被身份。
#
# 现实对照：
#   SNOW       — 季节性陆地积雪（春夏融，秋冬复）
#   GLACIER    — 永久冰川（不在 refresh_seasonal 内退缩）
#   SEA_ICE    — 季节性海冰（OCEAN/COAST 上面）
#   PERMAFROST — 永久冻土（TUNDRA 下层，不可见但影响排水）
#   FLOODING   — 季节性洪泛（雨季 SWAMP/DELTA）
#   PELAGIC_BLOOM — 深海富营养华、浮游生物大量繁殖（Systemic Ocean Currents）

class_name CoverType

enum CV {
	NONE,
	SNOW,
	GLACIER,
	SEA_ICE,
	PERMAFROST,
	FLOODING,
	PELAGIC_BLOOM,
}

const _NAME_CN: Dictionary = {
	CV.NONE:       "无",
	CV.SNOW:       "积雪",
	CV.GLACIER:    "冰川",
	CV.SEA_ICE:    "海冰",
	CV.PERMAFROST: "永久冻土",
	CV.FLOODING:   "洪泛",
	CV.PELAGIC_BLOOM: "远洋华",
}

# 雪/海冰/冻土上可通行；冰川封冻不可通行；洪泛季节淹没不可通行。
# 远洋华标记仅当视觉 tint，本身仍是海面，通行性与下层水 cell 相同。
const _PASSABLE: Dictionary = {
	CV.NONE:       true,
	CV.SNOW:       true,
	CV.GLACIER:    false,
	CV.SEA_ICE:    true,
	CV.PERMAFROST: true,
	CV.FLOODING:   false,
	CV.PELAGIC_BLOOM: true,
}

static func name_cn(c: CV) -> String:
	return _NAME_CN.get(c, str(c))

static func is_passable(c: CV) -> bool:
	return bool(_PASSABLE.get(c, true))
