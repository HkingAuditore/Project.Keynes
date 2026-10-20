extends RefCounted
class_name AnnualReportTokens

## 年度报告「纸本长卷」版式令牌。
##
## 这里只放版式与节奏，不放业务数据。所有页面的坐标都从同一组函数派生，
## 不允许各组件各写一套 magick number —— 旧版封面「4 条互不对齐的横带」
## 就是这么来的。

# ── 节奏（毫秒换算成秒使用） ────────────────────────────────────────────────
const OPEN_SCRIM := 0.18
const OPEN_SHEET := 0.55
const OPEN_ART := 0.62
const OPEN_WASH := 0.44
const OPEN_TITLE := 0.52
const OPEN_RULE := 0.22
const OPEN_SEAL := 0.28
const OPEN_SEAL_RING := 0.24
const OPEN_GLINT := 0.26
const OPEN_SCORE := 0.40
const OPEN_RULER := 0.50
const OPEN_TOTAL := 2.60
const CHAPTER_TURN := 0.55
const SECTION_PLAY_IN := 0.45
const SECTION_STAGGER := 0.04
const VISIT_INTERVAL := 0.10
const COUNT_UP_SECONDS := 0.45

# ── 间距 ────────────────────────────────────────────────────────────────────
const GAP_PARAGRAPH := 28.0
const GAP_BLOCK := 64.0
const GAP_CHAPTER := 200.0
const GAP_CHAPTER_COMPACT := 132.0
const RUNNING_HEAD_HEIGHT := 44.0
const FOOTER_HEIGHT := 40.0
const RAIL_WIDTH := 116.0

# ── 时代题图版式 ────────────────────────────────────────────────────────────
# 剪纸内部是米色底＋人物，大字直接压上去必糊。wash 控制左侧纸雾强度，
# shift 让主体右移避开标题列，scale 给个别构图更松的图留余地。
const ERA_LAYOUT := [
	{"wash": 0.74, "shift": 0.00, "scale": 1.02}, # stone
	{"wash": 0.70, "shift": 0.00, "scale": 1.02}, # agrarian
	{"wash": 0.72, "shift": 0.00, "scale": 1.02}, # kingdom
	{"wash": 0.70, "shift": 0.00, "scale": 1.02}, # empire
	{"wash": 0.68, "shift": 0.00, "scale": 1.02}, # exploration
	{"wash": 0.68, "shift": 0.00, "scale": 1.02}, # enlightenment
	{"wash": 0.72, "shift": 0.00, "scale": 1.02}, # steam
	{"wash": 0.72, "shift": 0.00, "scale": 1.02}, # electrical
	{"wash": 0.74, "shift": 0.00, "scale": 1.02}, # atomic
	{"wash": 0.68, "shift": 0.00, "scale": 1.02}, # information
	{"wash": 0.66, "shift": 0.00, "scale": 1.02}, # intelligent
]

# ── 派生度量 ────────────────────────────────────────────────────────────────
#
# 版式的第一性事实是「一张纸」，不是「一个视口」。
# 所有正文/图表的宽度都从 `measure()` 派生，纸宽 = 正文栏 + 两倍纸内边距，
# 纸在画面里水平居中、上下出血 —— 玩家看到的是纸的一部分，纸本身比屏幕长得多。
# 旧版把内容铺满整个视口，所以无论字号多大都像 PPT 而不是印刷品。

## 视口高度归一，用来缩放展示级字号。钳制在 0.66–1.5，
## 保证 720 高的小窗不会把标题压到看不清、4K 也不会大到失控。
static func unit(viewport: Vector2) -> float:
	return clampf(viewport.y / 1080.0, 0.66, 1.5)


## 正文栏宽。30–37 个汉字是舒适阅读的区间；旧版 50 字必须收掉。
static func measure(viewport: Vector2) -> float:
	return clampf(viewport.x * 0.36, 300.0, 660.0)


## 纸内边距：纸缘到正文栏。随栏宽走，保证纸的"留白比例"恒定。
static func paper_padding(viewport: Vector2) -> float:
	return clampf(measure(viewport) * 0.145, 26.0, 96.0)


## 长纸宽度。上限 880 ——— 再宽就回到"满屏纸"，纸感消失。
static func paper_width(viewport: Vector2) -> float:
	return minf(measure(viewport) + paper_padding(viewport) * 2.0, 880.0)


## 长纸矩形：水平居中，上下各出血出屏（"太长的纸"，两端都在画面之外）。
static func paper_rect(viewport: Vector2) -> Rect2:
	var width: float = paper_width(viewport)
	return Rect2((viewport.x - width) * 0.5, 0.0, width, viewport.y)


## ── 三个矩形的坐标契约，后面一切 UV 映射都从它们派生 ────────────────────────
##
##   paper_rect    可见纸面（正文 / 页眉 / 封面 / 测试的基准，语义不许动）
##   paper_layer   纸层 ColorRect = paper_rect 左右各扩 tear_pad，给撕口留余量
##   mask_rect     蒙版覆盖的矩形 = paper_layer 再各扩 shadow_spread，给投影留衰减空间

## 撕口留白：纸层比可见纸面宽出的那一圈。撕口从这条线往里咬，所以必须比最深
## 咬入（10px）宽，否则咬口会被纸层矩形硬切。
static func tear_pad(viewport: Vector2) -> float:
	return clampf(paper_width(viewport) * 0.030, 14.0, 32.0)


## 投影衰减带：从纸缘向外多远还有影。独立于 tear_pad，因为它要覆盖更大的跨度。
static func shadow_spread(viewport: Vector2) -> float:
	return maxf(10.0, paper_width(viewport) * 0.055)


## 蒙版矩形：纹理 1:1 铺在这个矩形上，纸层与页眉页脚各自的 UV 子矩形都相对它算。
static func mask_rect(viewport: Vector2) -> Rect2:
	var margin: float = tear_pad(viewport) + shadow_spread(viewport)
	var paper: Rect2 = paper_rect(viewport)
	return Rect2(paper.position.x - margin, 0.0, paper.size.x + margin * 2.0, viewport.y)


## 把任意子矩形映射成蒙版里的 UV 子矩形：xy = 原点比例，zw = 缩放比例。
static func mask_mapping(rect: Rect2, mask: Rect2) -> Vector4:
	return Vector4((rect.position.x - mask.position.x) / mask.size.x,
		(rect.position.y - mask.position.y) / mask.size.y,
		rect.size.x / mask.size.x, rect.size.y / mask.size.y)


## 旧签名保留：页眉 / 首屏内容相对纸缘的缩进。
static func reader_margin(viewport: Vector2) -> float:
	return paper_padding(viewport)


## 图表不破纸：宽度等于正文栏，画在纸的版心内。
static func chart_width(viewport: Vector2) -> float:
	return measure(viewport)


## 封面主标题字号：由纸宽决定，纸越窄标题越小，但永远占纸宽的 55–62%。
static func cover_title_size(paper_width_value: float) -> int:
	return int(clampf(paper_width_value * 0.132, 80.0, 124.0))


static func cover_seal_size(paper_width_value: float) -> float:
	return clampf(paper_width_value * 0.170, 72.0, 168.0)


static func cover_figure_size(paper_width_value: float) -> int:
	return int(clampf(paper_width_value * 0.086, 36.0, 92.0))


static func is_narrow(viewport: Vector2) -> bool:
	return viewport.x < 1024.0


static func era_layout(era: int) -> Dictionary:
	return ERA_LAYOUT[clampi(era, 0, ERA_LAYOUT.size() - 1)]


## 章节间的呼吸。小窗压缩，避免一屏只看到半章。
static func chapter_gap(viewport: Vector2) -> float:
	return GAP_CHAPTER_COMPACT if viewport.y < 800.0 else GAP_CHAPTER


## 章节序号字号：能占满正文栏的 30%，但不超过 168。
static func chapter_number_size(viewport: Vector2) -> int:
	return int(clampf(168.0 * unit(viewport), 96.0, UITokens.CHRONICLE_DISPLAY_MAX))
