extends Control
## 四大时代（石器 / 农耕 / 王国 / 帝国）交互式配乐 & 时代升级礼乐 实机试听台 (FMOD Studio)。
##
## v3 音频管线（tools/audio/generate_grand_strategy_music_elevenlabs.py）：每个时代一首十段式组曲，
## 段落间有调性、拍号、速度感与力度的对比；Base_Core + Pop_Rhythm + Pop_Chorus 三层相加 = 完整母带。
##   • 石器 180s (18 + 3x54) · 农耕 172s (16 + 3x52) · 王国 166s (16 + 3x50) · 帝国 165s (15 + 3x50)
##   • 时代升级礼乐各 15s（6s 过渡 + 9s 新时代主调号角）

@export var initial_era: StringName = &"agrarian"

const ERA_CONFIG := {
	&"stone": {
		"window_title": "ProjectKeynes - 石器时代交互式配乐实机试听台 (FMOD Studio)",
		"title": "🪨 时代 I：石器时代 (Stone Age) · 交互式配乐实机试听台",
		"subtitle": "75 BPM · D Dorian  │  v3 十段式组曲：主题陈述→对位→聚落舞→狩猎(A Phrygian)→哀歌→篝火摇篮曲(F)→祖灵合唱  │  人口叠加：律动/合唱分层(三层相加=完整母带)  │  镜头：篝火近景 ↔ 荒原长风",
		"duration": 180.0,
		"intro_end": 18.0,
		"loop_b": 72.0,
		"loop_c": 126.0,
		"markers": "0.0s [引子:荒原破晓] ──► 18.0s [A:主题陈述→大提琴对位→聚落舞] ──► 72.0s [B:狩猎→狩猎高潮→余烬哀歌] ──► 126.0s [C:篝火摇篮曲→祖灵合唱→尾声回到主题] ──► 180.0s 回环",
		"btn_a": "🎵 循环 A · 主题陈述 / 对位 / 聚落舞 (木笛·竖琴·陶埙)",
		"btn_b": "🎵 循环 B · 狩猎 / 高潮 / 哀歌 (原木鼓·兽角·独奏大提琴)",
		"btn_c": "🎵 循环 C · 摇篮曲 / 祖灵合唱 / 尾声 (F 大调→D Dorian)",
		"btn_p0": "🌿 零散采集 (80 人 | 仅核心旋律层)",
		"btn_p1": "⛺ 聚落初成 · 第一阈值 (480 人 | +打击/拨奏律动层)",
		"btn_p2": "🔥 氏族繁盛 · 第二阈值 (1000 人 | +合唱与全合奏声场 = 完整母带)",
		"pop_presets": [80, 480, 1000],
		"pop_max": 1200,
		"tier_labels": [
			"Tier 0 · 零散采集 (<300人)",
			"Tier 1 · 聚落初成 (≥300人，退出阈值 <240人)",
			"Tier 2 · 氏族繁盛 (≥800人，回退阈值 <680人)",
		],
		"btn_z_in": "🔍 拉近地图 · 微观聚落近景 (0.00 | +篝火噼啪/燧石打制/陶罐手鼓/高频提亮)",
		"btn_z_mid": "⚖️ 标准中景视角 (0.50 | 史前室内乐均衡混音)",
		"btn_z_out": "🌍 拉远地图 · 宏观大陆远景 (1.00 | +高空苍穹风声/远古泛音云层/远景柔化)",
		"region_names": [
			"【引子 · 荒原破晓】 自由节拍木笛呼唤与山谷回声，雨棍与心跳框鼓渐入",
			"【A · 旷野主题】 木笛主题陈述 → 大提琴低八度+陶埙对位 → 6/8 聚落手鼓舞",
			"【B · 狩猎】 A Phrygian 倍速追逐 → 兽角与全打击乐高潮 → 骤停后独奏大提琴哀歌",
			"【C · 星火】 F 大调 3/4 篝火摇篮曲 → 祖灵无词合唱扩张主题 → 木笛回到 D Dorian 尾声",
		],
		"track_1": "常驻核心轨 (旋律主体：木笛/陶埙/竖琴/大提琴 + 低音与打击乐的基础份额)",
		"track_2_on": "已激活 (打击乐/拨奏/断奏的律动层 + 低音推进)",
		"track_2_off": "静默待命 (需人口 ≥300 或 Population ≥0.22)",
		"track_3_on": "已激活 (人声合唱 + 合奏声场宽度与厅堂绽放)",
		"track_3_off": "静默待命 (需人口 ≥800 或 Population ≥0.56)",
		"track_4_on": "已激活 (篝火木柴噼啪/燧石打制石器/近场陶罐指击)",
		"track_5_on": "已激活 (苍穹高空风声/远古泛音云层/大陆地平线低音)",
	},
	&"agrarian": {
		"window_title": "ProjectKeynes - 农耕时代交互式配乐实机试听台 (FMOD Studio)",
		"title": "🌾 时代 II：农耕时代 (Agrarian Age) · 交互式配乐实机试听台",
		"subtitle": "80 BPM · G 五声  │  v3 十段式组曲：笛子主题→二胡对答→丰收舞(转D)→村社节庆 6/8→洪旱危机(Em)→月夜(C)→祈年合唱  │  人口叠加：律动/合唱分层  │  镜头：水车石磨 ↔ 麦浪长风",
		"duration": 172.0,
		"intro_end": 16.0,
		"loop_b": 68.0,
		"loop_c": 120.0,
		"markers": "0.0s [引子:晨钟] ──► 16.0s [A:春播主题→二胡对答→丰收舞] ──► 68.0s [B:村社节庆→节庆高潮→洪旱危机] ──► 120.0s [C:月夜田野→祈年合唱→归家尾声] ──► 172.0s 回环",
		"btn_a": "🎵 循环 A · 春播 / 二胡对答 / 丰收舞 (笛子·古筝·二胡)",
		"btn_b": "🎵 循环 B · 节庆 / 高潮 / 洪旱危机 (琵琶轮指·太鼓·E 小调)",
		"btn_c": "🎵 循环 C · 月夜 / 祈年合唱 / 归家 (箫·古琴泛音·合唱)",
		"btn_p0": "🌱 初始农庄 (180 人 | 仅核心旋律层)",
		"btn_p1": "🏡 灌溉村落 · 第一阈值 (950 人 | +打击/拨奏律动层)",
		"btn_p2": "🏛️ 宗族城邑 · 第二阈值 (2000 人 | +合唱与全合奏声场 = 完整母带)",
		"pop_presets": [180, 950, 2000],
		"pop_max": 2400,
		"tier_labels": [
			"Tier 0 · 初始农庄 (<600人)",
			"Tier 1 · 灌溉村落 (≥600人，退出阈值 <480人)",
			"Tier 2 · 宗族城邑 (≥1600人，回退阈值 <1360人)",
		],
		"btn_z_in": "🔍 拉近地图 · 微观水田近景 (0.00 | +水渠潺潺/石磨碾谷/田间晨鸟/高频提亮)",
		"btn_z_mid": "⚖️ 标准中景视角 (0.50 | 丝竹田园均衡混音)",
		"btn_z_out": "🌍 拉远地图 · 宏观九州远景 (1.00 | +沃野季风麦浪/历法星穹泛音/远景柔化)",
		"region_names": [
			"【引子 · 晨钟】 青铜钟一声，古筝刮奏，自由节拍笛子引子",
			"【A · 春播】 笛子五声主题 → 二胡对位与室内弦乐 → 全奏丰收舞并转 D 大调",
			"【B · 节庆与危机】 6/8 村社节庆 → 鼓与镲的节庆高潮 → E 小调洪旱危机",
			"【C · 月夜祈年】 箫与古琴泛音的 C 大调夜曲 → 祈年合唱 → 笛子回到 G 大调尾声",
		],
		"track_1": "常驻核心轨 (旋律主体：笛子/古筝/二胡/室内弦乐 + 基础低音与打击)",
		"track_2_on": "已激活 (拨奏/鼓/断奏律动层 + 低音推进)",
		"track_2_off": "静默待命 (需人口 ≥600 或 Population ≥0.22)",
		"track_3_on": "已激活 (合唱 + 合奏声场宽度与厅堂绽放)",
		"track_3_off": "静默待命 (需人口 ≥1600 或 Population ≥0.56)",
		"track_4_on": "已激活 (灌溉水渠潺潺流水/石磨碾谷连枷/田间晨鸟啼鸣)",
		"track_5_on": "已激活 (沃野季风麦浪/天文历法星穹泛音/黄土地脉共鸣)",
	},
	&"kingdom": {
		"window_title": "ProjectKeynes - 王国时代交互式配乐实机试听台 (FMOD Studio)",
		"title": "👑 时代 III：王国时代 (Kingdom Age) · 交互式配乐实机试听台",
		"subtitle": "86 BPM · C 大调  │  v3 十段式组曲：宫廷帕凡舞→模仿复调→仪仗进行曲→宫闱暗涌(Am)→军议(Dm)→战争代价→圣咏(F)→加冕  │  人口叠加：律动/合唱分层  │  镜头：市集 ↔ 关隘旌旗",
		"duration": 166.0,
		"intro_end": 16.0,
		"loop_b": 66.0,
		"loop_c": 116.0,
		"markers": "0.0s [引子:仪仗将至] ──► 16.0s [A:帕凡舞→复调→仪仗进行曲] ──► 66.0s [B:宫闱暗涌→军议→战争代价] ──► 116.0s [C:圣咏→加冕→太平尾声] ──► 166.0s 回环",
		"btn_a": "🎵 循环 A · 帕凡舞 / 复调 / 进行曲 (双簧管·鲁特琴·圆号)",
		"btn_b": "🎵 循环 B · 宫闱 / 军议 / 战争代价 (羽管键琴·战鼓·中提琴)",
		"btn_c": "🎵 循环 C · 圣咏 / 加冕 / 尾声 (管风琴·合唱·钟声)",
		"btn_p0": "🏯 初封城邦 (600 人 | 仅核心旋律层)",
		"btn_p1": "🛡️ 筑城首府 · 第一阈值 (2200 人 | +打击/拨奏律动层)",
		"btn_p2": "👑 王畿盛世 · 第二阈值 (4800 人 | +合唱与全合奏声场 = 完整母带)",
		"pop_presets": [600, 2200, 4800],
		"pop_max": 6000,
		"tier_labels": [
			"Tier 0 · 初封城邦 (<1500人)",
			"Tier 1 · 筑城首府 (≥1500人，退出阈值 <1200人)",
			"Tier 2 · 王畿盛世 (≥4000人，回退阈值 <3400人)",
		],
		"btn_z_in": "🔍 拉近地图 · 微观王城百工 (0.00 | +铁匠铺锻铁铁砧/石工凿石筑城/市井铜钱碰撞)",
		"btn_z_mid": "⚖️ 标准中景视角 (0.50 | 金石丝竹宫廷雅乐混音)",
		"btn_z_out": "🌍 拉远地图 · 宏观列国疆域 (1.00 | +关隘旌旗长风/青铜编钟泛音云层/王土大地共鸣)",
		"region_names": [
			"【引子 · 仪仗将至】 钟声、低音铜管众赞歌与定音鼓滚奏",
			"【A · 宫廷】 双簧管帕凡舞主题 → 弦乐与圆号模仿复调 → 小号定音鼓仪仗进行曲",
			"【B · 权谋与战争】 A 小调宫闱暗涌 → D 小调军议战鼓 → 独奏中提琴哀歌",
			"【C · 加冕】 F 大调管风琴圣咏 → 全奏合唱钟声加冕 → 鲁特琴与竖笛回到主题",
		],
		"track_1": "常驻核心轨 (旋律主体：双簧管/鲁特琴/竖琴/弦乐/圆号)",
		"track_2_on": "已激活 (拨奏/断奏/定音鼓与军鼓律动层)",
		"track_2_off": "静默待命 (需人口 ≥1500 或 Population ≥0.22)",
		"track_3_on": "已激活 (合唱 + 弦乐铜管声场宽度与大厅绽放)",
		"track_3_off": "静默待命 (需人口 ≥4000 或 Population ≥0.56)",
		"track_4_on": "已激活 (冶铁锻砧锤击/石工砌筑城墙凿石/市井铜钱清脆碰撞)",
		"track_5_on": "已激活 (关隘猎猎旌旗长风/青铜编钟泛音云层/C2王土大地共鸣)",
	},
	&"empire": {
		"window_title": "ProjectKeynes - 帝国时代交互式配乐实机试听台 (FMOD Studio)",
		"title": "🏛️ 时代 IV：帝国时代 (Empire Age) · 交互式配乐实机试听台",
		"subtitle": "92 BPM · F 大调  │  v3 十段式组曲：大提琴钢琴主题→华尔兹→舞厅→工业 2/4 固定音型(Dm)→帝国进行曲(Bb)→小提琴哀歌(Gm)→沙龙夜曲(Db)→凯旋  │  人口叠加：律动/合唱分层  │  镜头：港城街巷 ↔ 大洋长风",
		"duration": 165.0,
		"intro_end": 15.0,
		"loop_b": 65.0,
		"loop_c": 115.0,
		"markers": "0.0s [引子:时代黎明] ──► 15.0s [A:主题→华尔兹→舞厅] ──► 65.0s [B:工业→扩张进行曲→帝国代价] ──► 115.0s [C:沙龙夜曲→凯旋→暮色尾声] ──► 165.0s 回环",
		"btn_a": "🎵 循环 A · 主题 / 华尔兹 / 舞厅 (大提琴·钢琴·弦乐)",
		"btn_b": "🎵 循环 B · 工业 / 进行曲 / 代价 (固定音型·铜管·独奏小提琴)",
		"btn_c": "🎵 循环 C · 夜曲 / 凯旋 / 暮色 (钢琴·单簧管·合唱)",
		"btn_p0": "🏙️ 帝国州郡 (1800 人 | 仅核心旋律层)",
		"btn_p1": "🥁 繁华都护 · 第一阈值 (6000 人 | +打击/拨奏律动层)",
		"btn_p2": "🌟 盛世帝京 · 第二阈值 (12000 人 | +合唱与全合奏声场 = 完整母带)",
		"pop_presets": [1800, 6000, 12000],
		"pop_max": 15000,
		"tier_labels": [
			"Tier 0 · 帝国州郡 (<4000人)",
			"Tier 1 · 繁华都护 (≥4000人，退出阈值 <3200人)",
			"Tier 2 · 盛世帝京 (≥10000人，回退阈值 <8500人)",
		],
		"btn_z_in": "🔍 拉近地图 · 微观帝京工坊 (0.00 | +水力机械大水车/高炉炼钢鼓风/活字雕版印刷)",
		"btn_z_mid": "⚖️ 标准中景视角 (0.50 | 盛世燕乐管弦交响混音)",
		"btn_z_out": "🌍 拉远地图 · 宏观四海疆域 (1.00 | +万里大陆远洋贸易季风/星穹泛音天幕/帝国低音)",
		"region_names": [
			"【引子 · 时代黎明】 钢琴琶音与远处圆号呼唤",
			"【A · 帝国主题】 大提琴与钢琴陈述主题 → 弦乐 3/4 华尔兹 → 木管圆号大舞厅",
			"【B · 工业与扩张】 D 小调 2/4 机械固定音型 → 降 B 大调铜管进行曲 → G 小调小提琴哀歌",
			"【C · 荣光】 降 D 大调钢琴沙龙夜曲 → 全奏合唱凯旋 → 圆号与钢琴暮色尾声",
		],
		"track_1": "常驻核心轨 (旋律主体：钢琴/独奏大提琴/弦乐/木管/圆号)",
		"track_2_on": "已激活 (拨奏/断奏/定音鼓与军鼓律动层)",
		"track_2_off": "静默待命 (需人口 ≥4000 或 Population ≥0.22)",
		"track_3_on": "已激活 (合唱 + 交响声场宽度与音乐厅绽放)",
		"track_3_off": "静默待命 (需人口 ≥10000 或 Population ≥0.56)",
		"track_4_on": "已激活 (水力机械水车运转/高炉风箱炼钢/活字雕版刷印工坊)",
		"track_5_on": "已激活 (万里山河与远洋贸易季风/盛世星穹泛音天幕/F1帝国大地低音)",
	},
}

var _audio: Node
var _settings_before: Dictionary = {}
var _current_era: StringName = &"agrarian"
var _title_label: Label
var _subtitle_label: Label
var _markers_hint: Label
var _status_label: Label
var _layers_label: Label
var _timeline_bar: ProgressBar
var _timeline_caption: Label
var _btn_intro: Button
var _btn_all: Button
var _btn_a: Button
var _btn_b: Button
var _btn_c: Button
var _btn_p0: Button
var _btn_p1: Button
var _btn_p2: Button
var _btn_z_in: Button
var _btn_z_mid: Button
var _btn_z_out: Button
var _pop_count_slider: HSlider
var _pop_count_label: Label
var _pop_param_slider: HSlider
var _pop_param_label: Label
var _zoom_slider: HSlider
var _zoom_label: Label
var _syncing_ui := false
var _simulated_pop := 180
var _last_action := "初始化完成"


func _ready() -> void:
	_current_era = initial_era
	_settings_before = GameSettings.values()
	GameSettings.update({
		"window_mode": "windowed",
		"resolution_width": 1180,
		"resolution_height": 840,
		"master_muted": false,
	}, false)
	_audio = get_node("/root/GameAudio")

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	scroll.add_child(margin)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 9)
	margin.add_child(box)

	# --- 顶部行 1：四大时代直接切换栏 ---
	var era_row := HBoxContainer.new()
	era_row.add_theme_constant_override("separation", 8)
	box.add_child(era_row)

	var era_tag := Label.new()
	era_tag.text = "【四大时代直接切换】:"
	era_tag.add_theme_font_size_override("font_size", 14)
	era_row.add_child(era_tag)

	var b_stone := _make_button("🪨 I. 石器时代 (75 BPM D Dorian)")
	b_stone.pressed.connect(_on_switch_era.bind(&"stone"))
	era_row.add_child(b_stone)

	var b_agr := _make_button("🌾 II. 农耕时代 (80 BPM G 五声田园)")
	b_agr.pressed.connect(_on_switch_era.bind(&"agrarian"))
	era_row.add_child(b_agr)

	var b_kng := _make_button("👑 III. 王国时代 (85.7 BPM C 雅乐金石)")
	b_kng.pressed.connect(_on_switch_era.bind(&"kingdom"))
	era_row.add_child(b_kng)

	var b_emp := _make_button("🏛️ IV. 帝国时代 (92.3 BPM F 盛世交响)")
	b_emp.pressed.connect(_on_switch_era.bind(&"empire"))
	era_row.add_child(b_emp)

	# --- 顶部行 2：时代升级演出 & 过渡礼乐试听栏 ---
	var trans_row := HBoxContainer.new()
	trans_row.add_theme_constant_override("separation", 8)
	box.add_child(trans_row)

	var trans_tag := Label.new()
	trans_tag.text = "【时代升级礼乐演出】:"
	trans_tag.add_theme_font_size_override("font_size", 14)
	trans_row.add_child(trans_tag)

	var b_up_1 := _make_button("🌟 升级 I：石器 ──► 农耕《破晓定居》(D→G)")
	b_up_1.pressed.connect(_on_era_advance.bind(&"stone_to_agrarian"))
	trans_row.add_child(b_up_1)

	var b_up_2 := _make_button("🌟 升级 II：农耕 ──► 王国《铸鼎立邦》(G→C)")
	b_up_2.pressed.connect(_on_era_advance.bind(&"agrarian_to_kingdom"))
	trans_row.add_child(b_up_2)

	var b_up_3 := _make_button("🌟 升级 III：王国 ──► 帝国《四海一统》(C→F)")
	b_up_3.pressed.connect(_on_era_advance.bind(&"kingdom_to_empire"))
	trans_row.add_child(b_up_3)

	var b_only_t := _make_button("🎺 仅播放当前时代升级曲 (9.6s)")
	b_only_t.pressed.connect(_on_play_current_transition_only)
	trans_row.add_child(b_only_t)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 22)
	box.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_subtitle_label)

	# --- 时间轴与当前段落指示 ---
	var tl_box := VBoxContainer.new()
	tl_box.add_theme_constant_override("separation", 4)
	box.add_child(tl_box)

	_timeline_caption = Label.new()
	_timeline_caption.add_theme_font_size_override("font_size", 15)
	tl_box.add_child(_timeline_caption)

	_timeline_bar = ProgressBar.new()
	_timeline_bar.min_value = 0.0
	_timeline_bar.max_value = 57.0
	_timeline_bar.step = 0.05
	_timeline_bar.show_percentage = false
	_timeline_bar.custom_minimum_size.y = 18
	tl_box.add_child(_timeline_bar)

	_markers_hint = Label.new()
	_markers_hint.add_theme_font_size_override("font_size", 12)
	tl_box.add_child(_markers_hint)

	# --- 1 & 2. 刚进入游戏 + 常态循环控制 ---
	box.add_child(_section_header("一 & 二、刚进入游戏 (Intro) 与 常态循环组 (Base Loops)"))
	var row_loop := HBoxContainer.new()
	row_loop.add_theme_constant_override("separation", 8)
	box.add_child(row_loop)

	_btn_intro = _make_button("▶ 1. 刚进入游戏 (从 0.0s 引子起播)")
	_btn_intro.pressed.connect(_on_play_intro)
	row_loop.add_child(_btn_intro)

	_btn_all = _make_button("🔁 2. 三段循环自动轮转 (A→B→C)")
	_btn_all.pressed.connect(_on_select_loop_section.bind(0, false))
	row_loop.add_child(_btn_all)

	_btn_a = _make_button("🎵 循环 A")
	_btn_a.pressed.connect(_on_select_loop_section.bind(1, true))
	row_loop.add_child(_btn_a)

	_btn_b = _make_button("🎵 循环 B")
	_btn_b.pressed.connect(_on_select_loop_section.bind(2, true))
	row_loop.add_child(_btn_b)

	_btn_c = _make_button("🎵 循环 C")
	_btn_c.pressed.connect(_on_select_loop_section.bind(3, true))
	row_loop.add_child(_btn_c)

	# --- 3. 人口到达阈值后的变体 / 配器 ---
	box.add_child(_section_header("三、人口到达阈值后的变体 / 配器叠加 (Vertical Layering + 滞回防抖)"))
	var row_pop_presets := HBoxContainer.new()
	row_pop_presets.add_theme_constant_override("separation", 8)
	box.add_child(row_pop_presets)

	_btn_p0 = _make_button("Tier 0")
	_btn_p0.pressed.connect(func() -> void:
		var presets: Array = ERA_CONFIG[_current_era]["pop_presets"]
		_on_set_simulated_pop(int(presets[0])))
	row_pop_presets.add_child(_btn_p0)

	_btn_p1 = _make_button("Tier 1")
	_btn_p1.pressed.connect(func() -> void:
		var presets: Array = ERA_CONFIG[_current_era]["pop_presets"]
		_on_set_simulated_pop(int(presets[1])))
	row_pop_presets.add_child(_btn_p1)

	_btn_p2 = _make_button("Tier 2")
	_btn_p2.pressed.connect(func() -> void:
		var presets: Array = ERA_CONFIG[_current_era]["pop_presets"]
		_on_set_simulated_pop(int(presets[2])))
	row_pop_presets.add_child(_btn_p2)

	_pop_count_label = Label.new()
	box.add_child(_pop_count_label)

	_pop_count_slider = HSlider.new()
	_pop_count_slider.min_value = 0
	_pop_count_slider.max_value = 2400
	_pop_count_slider.step = 10
	_pop_count_slider.value = _simulated_pop
	_pop_count_slider.value_changed.connect(_on_pop_count_slider_changed)
	box.add_child(_pop_count_slider)

	_pop_param_label = Label.new()
	box.add_child(_pop_param_label)

	_pop_param_slider = HSlider.new()
	_pop_param_slider.min_value = 0.0
	_pop_param_slider.max_value = 1.0
	_pop_param_slider.step = 0.01
	_pop_param_slider.value = 0.04
	_pop_param_slider.value_changed.connect(_on_pop_param_slider_changed)
	box.add_child(_pop_param_slider)

	# --- 4. 拉近地图和拉远地图的变体 ---
	box.add_child(_section_header("四、拉近地图与拉远地图的变体 (CameraZoom 音轨 + 实时 ThreeEQ 滤波)"))
	var row_zoom_presets := HBoxContainer.new()
	row_zoom_presets.add_theme_constant_override("separation", 8)
	box.add_child(row_zoom_presets)

	_btn_z_in = _make_button("🔍 拉近地图 (0.00)")
	_btn_z_in.pressed.connect(_on_set_zoom.bind(0.0))
	row_zoom_presets.add_child(_btn_z_in)

	_btn_z_mid = _make_button("⚖️ 标准中景视角 (0.50)")
	_btn_z_mid.pressed.connect(_on_set_zoom.bind(0.5))
	row_zoom_presets.add_child(_btn_z_mid)

	_btn_z_out = _make_button("🌍 拉远地图 (1.00)")
	_btn_z_out.pressed.connect(_on_set_zoom.bind(1.0))
	row_zoom_presets.add_child(_btn_z_out)

	_zoom_label = Label.new()
	box.add_child(_zoom_label)

	_zoom_slider = HSlider.new()
	_zoom_slider.min_value = 0.0
	_zoom_slider.max_value = 1.0
	_zoom_slider.step = 0.01
	_zoom_slider.value = 0.5
	_zoom_slider.value_changed.connect(_on_zoom_slider_changed)
	box.add_child(_zoom_slider)

	# --- 分轨实时状态与主音量控制 ---
	box.add_child(_section_header("五、实时分轨激活监测 & 总线控制"))
	_layers_label = Label.new()
	_layers_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_layers_label)

	var ctrl_row := HBoxContainer.new()
	ctrl_row.add_theme_constant_override("separation", 12)
	box.add_child(ctrl_row)

	var stop_btn := _make_button("⏹ 停止音乐")
	stop_btn.pressed.connect(_on_stop)
	ctrl_row.add_child(stop_btn)

	var vol_lbl := Label.new()
	vol_lbl.text = "主音量:"
	ctrl_row.add_child(vol_lbl)

	var vol_slider := HSlider.new()
	vol_slider.min_value = 0.0
	vol_slider.max_value = 1.0
	vol_slider.step = 0.01
	vol_slider.value = float(GameSettings.values().get("master_volume", 0.8))
	vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol_slider.value_changed.connect(func(v: float) -> void:
		GameSettings.update({"master_volume": v}, false)
		_refresh())
	ctrl_row.add_child(vol_slider)

	var mute_btn := CheckButton.new()
	mute_btn.text = "静音主总线"
	mute_btn.button_pressed = bool(GameSettings.values().get("master_muted", false))
	mute_btn.toggled.connect(func(v: bool) -> void:
		GameSettings.update({"master_muted": v}, false)
		_refresh())
	ctrl_row.add_child(mute_btn)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status_label)

	_apply_era_static_ui(_current_era, true)

	if OS.get_environment("PK_FMOD_CAPTURE") != "":
		_capture_preview.call_deferred()


func _section_header(title_text: String) -> Label:
	var lbl := Label.new()
	lbl.text = title_text
	lbl.add_theme_font_size_override("font_size", 15)
	return lbl


func _make_button(caption: String) -> Button:
	var b := Button.new()
	b.text = caption
	b.custom_minimum_size.y = 33
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


func _on_switch_era(era_id: StringName) -> void:
	_current_era = era_id
	_apply_era_static_ui(era_id, true)


func _apply_era_static_ui(era_id: StringName, start_playback: bool) -> void:
	var cfg: Dictionary = ERA_CONFIG.get(era_id, ERA_CONFIG[&"agrarian"])
	DisplayServer.window_set_title(String(cfg["window_title"]))
	_title_label.text = String(cfg["title"])
	_subtitle_label.text = String(cfg["subtitle"])
	_timeline_bar.max_value = float(cfg["duration"])
	_markers_hint.text = String(cfg["markers"])
	_btn_a.text = String(cfg["btn_a"])
	_btn_b.text = String(cfg["btn_b"])
	_btn_c.text = String(cfg["btn_c"])
	_btn_p0.text = String(cfg["btn_p0"])
	_btn_p1.text = String(cfg["btn_p1"])
	_btn_p2.text = String(cfg["btn_p2"])
	_btn_z_in.text = String(cfg["btn_z_in"])
	_btn_z_mid.text = String(cfg["btn_z_mid"])
	_btn_z_out.text = String(cfg["btn_z_out"])
	_pop_count_slider.max_value = float(cfg["pop_max"])
	var presets: Array = cfg["pop_presets"]
	if start_playback:
		_start_era_suite(era_id, true, 0.04, _zoom_slider.value, 0)
		_on_set_simulated_pop(int(presets[0]))
		_last_action = "已切换至 %s 并从 0.0s 开局引子起播" % String(cfg["title"])
	_refresh()


func _start_era_suite(era_id: StringName, from_intro: bool, pop_ratio: float, zoom_ratio: float, section: int) -> void:
	match era_id:
		&"stone":
			_audio.play_stone_age_suite(from_intro, pop_ratio, zoom_ratio, section)
		&"agrarian":
			_audio.play_agrarian_age_suite(from_intro, pop_ratio, zoom_ratio, section)
		&"kingdom":
			_audio.play_kingdom_age_suite(from_intro, pop_ratio, zoom_ratio, section)
		&"empire":
			_audio.play_empire_age_suite(from_intro, pop_ratio, zoom_ratio, section)


func _on_era_advance(kind: StringName) -> void:
	match kind:
		&"stone_to_agrarian":
			_current_era = &"agrarian"
			_apply_era_static_ui(&"agrarian", false)
			var r1: float = _audio.update_agrarian_age_population_count(950)
			_sync_pop_sliders(950, r1)
			_audio.advance_stone_to_agrarian_suite(r1, _zoom_slider.value, false)
			_last_action = "🌟 时代升级 I【石器 ──► 农耕】：奏响 9.6s《破晓定居》(骨角石磬 → 古瑟青铜铃 D→G 解决) 并切入农耕时代！"
		&"agrarian_to_kingdom":
			_current_era = &"kingdom"
			_apply_era_static_ui(&"kingdom", false)
			var r2: float = _audio.update_kingdom_age_population_count(2200)
			_sync_pop_sliders(2200, r2)
			_audio.advance_agrarian_to_kingdom_suite(r2, _zoom_slider.value, false)
			_last_action = "🌟 时代升级 II【农耕 ──► 王国】：奏响 9.6s《铸鼎立邦》(田园竹笛 → 镈钟与曾侯乙编钟玉磬 G→C 雅乐解决) 并切入王国时代！"
		&"kingdom_to_empire":
			_current_era = &"empire"
			_apply_era_static_ui(&"empire", false)
			var r3: float = _audio.update_empire_age_population_count(6000)
			_sync_pop_sliders(6000, r3)
			_audio.advance_kingdom_to_empire_suite(r3, _zoom_slider.value, false)
			_last_action = "🌟 时代升级 III【王国 ──► 帝国】：奏响 9.6s《四海一统》(青铜编钟 → 琵琶云锣与盛世弦乐铜管合唱 C→F 解决) 并切入帝国时代！"
	_refresh()


func _sync_pop_sliders(pop_count: int, ratio: float) -> void:
	_simulated_pop = pop_count
	_syncing_ui = true
	_pop_count_slider.value = pop_count
	_pop_param_slider.value = ratio
	_syncing_ui = false


func _on_play_current_transition_only() -> void:
	_audio.stop_music()
	match _current_era:
		&"stone", &"agrarian":
			_audio.play_stone_to_agrarian_transition()
			_last_action = "🎺 正在单独播放 9.6s 时代升级礼乐 I《破晓定居 · 迈入农耕》(石器 D 调 → 农耕 G 调)"
		&"kingdom":
			_audio.play_agrarian_to_kingdom_transition()
			_last_action = "🎺 正在单独播放 9.6s 时代升级礼乐 II《铸鼎立邦 · 礼乐初成》(农耕 G 调 → 王国 C 雅乐宫调)"
		&"empire":
			_audio.play_kingdom_to_empire_transition()
			_last_action = "🎺 正在单独播放 9.6s 时代升级礼乐 III《四海一统 · 万邦来朝》(王国 C 调 → 帝国 F 盛世交响调)"
	_refresh()


func _on_play_intro() -> void:
	_start_era_suite(_current_era, true, _pop_param_slider.value, _zoom_slider.value, 0)
	_last_action = "已切回 0.0s「1. 刚进入游戏」开局引子（播完无缝滑入常态循环）"
	_refresh()


func _on_select_loop_section(section: int, jump_now: bool) -> void:
	var cfg: Dictionary = ERA_CONFIG[_current_era]
	var intro_ms := int(round(float(cfg["intro_end"]) * 1000.0))
	match _current_era:
		&"stone":
			if _audio.diagnostics().get("music_key", &"") != &"stone_age_suite":
				_audio.play_stone_age_suite(false, _pop_param_slider.value, _zoom_slider.value, section)
			else:
				_audio.set_stone_age_loop_section(section, jump_now)
				if section == 0 and int(_audio.diagnostics().get("timeline_ms", 0)) < intro_ms:
					_audio.jump_stone_age_timeline_ms(intro_ms)
		&"agrarian":
			if _audio.diagnostics().get("music_key", &"") != &"agrarian_age_suite":
				_audio.play_agrarian_age_suite(false, _pop_param_slider.value, _zoom_slider.value, section)
			else:
				_audio.set_agrarian_age_loop_section(section, jump_now)
				if section == 0 and int(_audio.diagnostics().get("timeline_ms", 0)) < intro_ms:
					_audio.jump_agrarian_age_timeline_ms(intro_ms)
		&"kingdom":
			if _audio.diagnostics().get("music_key", &"") != &"kingdom_age_suite":
				_audio.play_kingdom_age_suite(false, _pop_param_slider.value, _zoom_slider.value, section)
			else:
				_audio.set_kingdom_age_loop_section(section, jump_now)
				if section == 0 and int(_audio.diagnostics().get("timeline_ms", 0)) < intro_ms:
					_audio.jump_kingdom_age_timeline_ms(intro_ms)
		&"empire":
			if _audio.diagnostics().get("music_key", &"") != &"empire_age_suite":
				_audio.play_empire_age_suite(false, _pop_param_slider.value, _zoom_slider.value, section)
			else:
				_audio.set_empire_age_loop_section(section, jump_now)
				if section == 0 and int(_audio.diagnostics().get("timeline_ms", 0)) < intro_ms:
					_audio.jump_empire_age_timeline_ms(intro_ms)
	_last_action = "常态循环切换 → LoopSection=%d" % section
	_refresh()


func _on_set_simulated_pop(pop_count: int) -> void:
	var ratio := 0.0
	match _current_era:
		&"stone":
			ratio = _audio.update_stone_age_population_count(pop_count)
		&"agrarian":
			ratio = _audio.update_agrarian_age_population_count(pop_count)
		&"kingdom":
			ratio = _audio.update_kingdom_age_population_count(pop_count)
		&"empire":
			ratio = _audio.update_empire_age_population_count(pop_count)
	_sync_pop_sliders(pop_count, ratio)
	_last_action = "模拟人口设为 %d 人 → FMOD Population 参数平滑过渡至 %.2f" % [pop_count, ratio]
	_refresh()


func _on_pop_count_slider_changed(val: float) -> void:
	if _syncing_ui:
		return
	_on_set_simulated_pop(int(round(val)))


func _on_pop_param_slider_changed(val: float) -> void:
	if _syncing_ui:
		return
	match _current_era:
		&"stone":
			_audio.set_stone_age_population(val, false)
		&"agrarian":
			_audio.set_agrarian_age_population(val, false)
		&"kingdom":
			_audio.set_kingdom_age_population(val, false)
		&"empire":
			_audio.set_empire_age_population(val, false)
	_last_action = "手动拖动 Population 参数 → %.2f" % val
	_refresh()


func _on_set_zoom(zoom_val: float) -> void:
	_syncing_ui = true
	_zoom_slider.value = zoom_val
	_syncing_ui = false
	_apply_zoom(zoom_val)


func _on_zoom_slider_changed(val: float) -> void:
	if _syncing_ui:
		return
	_apply_zoom(val)


func _apply_zoom(zoom_val: float) -> void:
	match _current_era:
		&"stone":
			_audio.set_stone_age_camera_zoom(zoom_val, false)
		&"agrarian":
			_audio.set_agrarian_age_camera_zoom(zoom_val, false)
		&"kingdom":
			_audio.set_kingdom_age_camera_zoom(zoom_val, false)
		&"empire":
			_audio.set_empire_age_camera_zoom(zoom_val, false)
	_last_action = "镜头缩放 CameraZoom → %.2f" % zoom_val
	_refresh()


func _on_stop() -> void:
	_audio.stop_music()
	_last_action = "已停止播放"
	_refresh()


func _describe_timeline_region(sec: float, loop_sec: int) -> String:
	var cfg: Dictionary = ERA_CONFIG[_current_era]
	var dur := float(cfg["duration"])
	var regions: Array = cfg["region_names"]
	var mode_str := "全曲自动轮转 A→B→C" if loop_sec == 0 else ("单段锁定: 循环 %s" % ["A", "B", "C"][clampi(loop_sec - 1, 0, 2)])
	var r_idx := 0
	if sec >= float(cfg["loop_c"]):
		r_idx = 3
	elif sec >= float(cfg["loop_b"]):
		r_idx = 2
	elif sec >= float(cfg["intro_end"]):
		r_idx = 1
	return "当前时间轴: %05.2fs / %05.2fs  │  %s  │  %s" % [sec, dur, String(regions[r_idx]), mode_str]


func _refresh() -> void:
	if _audio == null:
		return
	var cfg: Dictionary = ERA_CONFIG[_current_era]
	var info: Dictionary = _audio.diagnostics()
	var ms := int(info.get("timeline_ms", 0))
	var sec := float(ms) / 1000.0
	var pop_val := float(info.get("population", _pop_param_slider.value))
	var zoom_val := float(info.get("camera_zoom", _zoom_slider.value))
	var loop_sec := int(info.get("loop_section", 0))
	var pop_tier := clampi(int(info.get("pop_tier", 0)), 0, 2)

	_timeline_bar.value = clampf(sec, 0.0, float(cfg["duration"]))
	_timeline_caption.text = _describe_timeline_region(sec, loop_sec)

	var tier_labels: Array = cfg["tier_labels"]
	_pop_count_label.text = "模拟人口: %d 人   [当前滞回档位: %s]" % [_simulated_pop, String(tier_labels[pop_tier])]
	_pop_param_label.text = "FMOD Population 参数值: %.2f   (0.20~0.50 推起 Tier 1 律动轨；0.55~0.85 推起 Tier 2 盛世合唱与华彩轨)" % pop_val

	var zoom_desc := "标准中景均衡混音"
	if zoom_val < 0.35:
		zoom_desc = "拉近地图 · 微观近景特写 (%s + 高频提亮)" % String(cfg["track_4_on"])
	elif zoom_val > 0.65:
		zoom_desc = "拉远地图 · 宏观战略远景 (%s + 远景柔化滤波)" % String(cfg["track_5_on"])
	_zoom_label.text = "FMOD CameraZoom 参数值: %.2f   [%s]" % [zoom_val, zoom_desc]

	var rhythm_active := ("🟢 " + String(cfg["track_2_on"])) if pop_val >= 0.22 else ("⚪ " + String(cfg["track_2_off"]))
	var chorus_active := ("🟢 " + String(cfg["track_3_on"])) if pop_val >= 0.56 else ("⚪ " + String(cfg["track_3_off"]))
	var close_active := ("🟢 " + String(cfg["track_4_on"])) if zoom_val <= 0.45 else "⚪ 静默待命 (需拉近镜头 CameraZoom ≤0.45)"
	var far_active := ("🟢 " + String(cfg["track_5_on"])) if zoom_val >= 0.55 else "⚪ 静默待命 (需拉远镜头 CameraZoom ≥0.55)"

	_layers_label.text = "\n".join([
		"• [Track 1 · Base_Core]  🟢 %s" % String(cfg["track_1"]),
		"• [Track 2 · Pop_Rhythm] %s" % rhythm_active,
		"• [Track 3 · Pop_Chorus] %s" % chorus_active,
		"• [Track 4 · Zoom_Close] %s" % close_active,
		"• [Track 5 · Zoom_Far]   %s" % far_active,
	])

	_status_label.text = "后端: %s  │  banks=%d  │  在播=%s (%s)  │  主音量=%.2f  │  静音=%s\n最近操作: %s" % [
		String(_audio.status),
		int(info.get("banks", 0)),
		"是" if bool(info.get("music_playing", false)) else "否",
		String(info.get("music_key", &"")),
		float(info.get("master_volume", -1.0)),
		"是" if bool(info.get("master_muted", false)) else "否",
		_last_action,
	]


func _process(_delta: float) -> void:
	if _audio != null and Engine.get_process_frames() % 10 == 0:
		_refresh()


func _capture_preview() -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("PK_FMOD_CAPTURE"))
	get_tree().quit()


func _exit_tree() -> void:
	if _audio != null:
		_audio.stop_music()
	GameSettings.update(_settings_before, false)
