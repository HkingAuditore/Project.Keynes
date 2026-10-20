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
## 块与块之间的空气。这一版把节奏压紧，让一屏里落得下数字带 + 图表 + 账簿。
const GAP_BLOCK := 44.0
const GAP_CHAPTER := 160.0
const GAP_CHAPTER_COMPACT := 108.0
const RUNNING_HEAD_HEIGHT := 44.0
const FOOTER_HEIGHT := 40.0
const RAIL_WIDTH := 116.0

# ── 撕口蒙版的几何契约 ──────────────────────────────────────────────────────
#
# 蒙版位图（assets/ui/annual_chronicle/paper_tear_mask.png）烘的是**四边都撕开**
# 的一张纸：上 96 行是源图真实的上撕口，中间是可周期化的左右两道撕口，下 96 行
# 是真实的下撕口。着色器要靠这三个数把纸层行号切成「头 / 中段 / 尾」三段，
# 所以它们必须与 tools/ui/build_paper_tear_mask.py 顶部的常数逐个相同。
#
# 这三个数是**手工镜像**的常数，是下一次漂移的种子 —— 所以不靠人记：
# tests/annual_report_ui_test.gd 的 "mask geometry contract" 直接从 PNG 像素
# 反推纸面名义上沿与最深咬口，对不上就红。
const MASK_CAP_ROWS := 96.0  # 构建脚本 CAP_ROWS：上下两端各占的行数
const MASK_EDGE_ROWS := 72.0  # 构建脚本 CAP_FAR：顶行到纸面名义上沿的行数
const MASK_FAR_PX := 64.0  # 构建脚本 FAR_PX：G 通道的满量程（纸外侧距离）

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
# 所有正文/图表的宽度都从 `measure()` 派生，纸宽 = 正文栏 + 两倍纸内边距。
#
# 纸是**有限高的一件实物**：它不是铺满视口的背景板，而是跟着滚动位移一起上下
# 移动的一张纸。卷首看得见纸的上沿，卷末看得见纸的下沿，中段纸边的位置随着
# 滚动一起走 —— 这是"在读一张纸"与"在看一屏文字"的全部区别。
# 旧版把纸钉死在视口上（y 恒 0、高度恒等于视口高）并且上下出血出屏，所以无论
# 滚到哪儿，看到的都是同一张静止的纸；纸的两端永远在画面之外，读者永远不知道
# 这份报告从哪里开始、到哪里结束。

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


## 卷首桌面：纸的上沿之上留出的桌面高度。
## 它同时决定页眉那条浮层的落点 —— 纸还没滚到，页眉就该待在桌上。
static func sheet_head_gap(viewport: Vector2) -> float:
	return maxf(RUNNING_HEAD_HEIGHT + 18.0, clampf(viewport.y * 0.074, 50.0, 112.0))


## 卷末桌面：纸的下沿之下留出的桌面高度。至少要够让页脚那条浮层落回桌面。
static func sheet_foot_gap(viewport: Vector2) -> float:
	return maxf(FOOTER_HEIGHT + 22.0, clampf(viewport.y * 0.062, 46.0, 104.0))


## 纸的版心列：水平居中、宽度 = paper_width。高度没有意义（返回 0）。
## 滚动面 / 页眉页脚浮层 / 刻度轨只需要这条竖列的横向范围；
## 纵向归 `sheet_rect` 管，它要的是正文总高，令牌算不出来。
static func paper_column(viewport: Vector2) -> Rect2:
	var width: float = paper_width(viewport)
	return Rect2((viewport.x - width) * 0.5, 0.0, width, 0.0)


## 纸的可见矩形。`height` 由编排名按正文实际高度给 —— 令牌不知道正文有多长。
static func sheet_rect(viewport: Vector2, height: float) -> Rect2:
	var column: Rect2 = paper_column(viewport)
	return Rect2(column.position.x, sheet_head_gap(viewport), column.size.x, maxf(1.0, height))


## ── 四个矩形的坐标契约，后面一切 UV 映射都从它们派生 ────────────────────────
##
##   paper_column  纸的竖列（只有 x / 宽有意义）
##   sheet_rect    可见纸面 = 竖列 + 上下两端各让出桌面（高度随正文变）
##   layer_rect    纸层 ColorRect = sheet 左右扩 tear_pad、上下扩 cap_pad
##   shadow_rect   投影层 = layer 再各扩 shadow_spread，给投影留衰减空间

## 左右撕口留白：纸层比可见纸面宽出的那一圈。撕口从这条线往里咬，所以必须比最深
## 咬入（10px）宽，否则咬口会被纸层矩形硬切。
static func tear_pad(viewport: Vector2) -> float:
	return clampf(paper_width(viewport) * 0.030, 14.0, 32.0)


## 上下撕口的最深咬入。与左右同量级 —— 手撕纸不会"两头撕得比两侧狠"。
static func cap_depth(viewport: Vector2) -> float:
	return tear_pad(viewport) * 0.72


## 上下撕口留白：纸层在可见纸面之外多留的一圈，等于最深咬入 + 抗锯齿余量。
static func cap_pad(viewport: Vector2) -> float:
	return cap_depth(viewport) + 8.0


## 投影衰减带：从纸缘向外多远还有影。独立于 tear_pad，因为它要覆盖更大的跨度。
static func shadow_spread(viewport: Vector2) -> float:
	return maxf(10.0, paper_width(viewport) * 0.055)


## 纸层矩形：可见纸面四边各扩一圈撕口余量。着色器在这圈余量里把 alpha 咬掉。
static func layer_rect(viewport: Vector2, sheet_height: float) -> Rect2:
	var sheet: Rect2 = sheet_rect(viewport, sheet_height)
	var side: float = tear_pad(viewport)
	var cap: float = cap_pad(viewport)
	return Rect2(sheet.position - Vector2(side, cap),
		sheet.size + Vector2(side * 2.0, cap * 2.0))


## 投影矩形：纸层四边各扩 shadow_spread。蒙版的纸外侧距离在这里刚好衰减到 0，
## 所以阴影矩形的边界天然看不见 —— 只铺到纸层那么宽的话，撕口外会露出一圈方影。
static func shadow_rect(viewport: Vector2, sheet_height: float) -> Rect2:
	var layer: Rect2 = layer_rect(viewport, sheet_height)
	var spread: float = shadow_spread(viewport)
	return Rect2(layer.position - Vector2(spread, spread),
		layer.size + Vector2(spread, spread) * 2.0)


## 蒙版列：纸面左右各扩 margin（撕口 + 投影衰减）。
## **只有横向有意义** —— 纵向不靠它：蒙版上下两端是源图真实的上/下撕口，
## 由着色器按纸层行号 1:1 取头部与尾部、中段镜像平铺
## （见 shaders/include/annual_sheet_tear.gdshaderinc）。
##
## 这条列宽正好等于 shadow_rect 的宽度，左边缘也正好重合 —— 所以投影直接用
## mask_mapping(shadow_rect, mask_rect) 得到 (0, *, 1, *)，UV.x 就是蒙版的 u。
## 用纸层的 mapping 顶替会把衰减带整体压窄、往里挪，纸缘外会空出一道没影的缝。
static func mask_rect(viewport: Vector2) -> Rect2:
	var margin: float = tear_pad(viewport) + shadow_spread(viewport)
	var column: Rect2 = paper_column(viewport)
	return Rect2(column.position.x - margin, 0.0, column.size.x + margin * 2.0, viewport.y)


## 把任意子矩形映射成蒙版里的 UV 子矩形：xy = 原点比例，zw = 缩放比例。
## 纸场只用 x/z（纵向由镜像平铺的相位决定），投影用 x/z（纵向同理）。
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
