class_name AnnualChronicleScribe
extends Node

## 年度纪事：把一份年度报告写成一段史笔文字。
##
## 定位：**AI 只写文字，不碰任何数值**。报告本身由 native 结算、由 ViewModel 组装，
## 这里拿到的已经是定稿的 model；写出来的东西只作为报告末章的一段正文附加，
## 失败时报告原样呈现，玩家不会察觉少了什么。
##
## 时序：报告就绪时预生成一次，按年份落盘缓存；开卷时同步读缓存。
## 之所以能这么做——年度报告需要玩家主动打开，从 ready 到打开通常隔几秒到几天，
## 异步请求几乎总能在开卷前写完。若真没写完，本次不显示，下次开卷自然就有。

signal chronicle_ready(report_id: int, text: String)

const AiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")
const CACHE_DIR := "user://annual_chronicle"
## 内容口径变了就加一：旧缓存的文件名随之变化，自然失效，不用写迁移。
const PROMPT_VERSION := 1
const MAX_DETAILS_PER_CHAPTER := 3

var _client = null
var _pending: Dictionary = {}
var _memory: Dictionary = {}


func configure(client) -> void:
	_client = client


func cached_text(report_id: int) -> String:
	if report_id <= 0:
		return ""
	if _memory.has(report_id):
		return String(_memory[report_id])
	var path := _cache_path(report_id)
	if not FileAccess.file_exists(path):
		return ""
	var text := FileAccess.get_file_as_string(path).strip_edges()
	if not text.is_empty():
		_memory[report_id] = text
	return text


## 发起一次生成。已有缓存或在途时直接返回 false，不会重复花钱。
func request(model: Dictionary) -> bool:
	var report_id := int(model.get("id", 0))
	if report_id <= 0 or _client == null:
		return false
	if not cached_text(report_id).is_empty():
		return false
	if _pending.has(report_id):
		return false
	if not bool(model.get("available", false)):
		return false
	_pending[report_id] = true
	var messages := build_messages(model)
	_client.request_text(messages, {"report_id": report_id}, 0.9, 40.0,
		func(result: Dictionary) -> void:
			_pending.erase(report_id)
			if not bool(result.get("ok", false)):
				return
			var text := String(result.get("text", "")).strip_edges()
			var cleaned := _sanitize(text)
			if cleaned.length() < 40:
				# 太短说明模型跑偏或只回了一句废话，宁可不要，也不要在报告里留半截。
				return
			_memory[report_id] = cleaned
			_save(report_id, cleaned)
			chronicle_ready.emit(report_id, cleaned))
	return true


## 提示词：史官口吻，只写两三件要紧事。数字被刻意做成定性描述（见 build_brief），
## 模型手上没有可抄的阿拉伯数字——这比「禁止抄数字」的禁令更可靠。
static func build_messages(model: Dictionary) -> Array:
	var brief := build_brief(model)
	var system_content := "\n".join(PackedStringArray([
		"你是《Project.Keynes》的史官，替一部编年史写某一年的条目。",
		"下面给你这一年的年度报告摘要。把它写成一段史笔文字，一百五十到二百四十字。",
		"",
		"【写法】",
		"1. 只写这一年最要紧的两三件事：什么变了、谁受了影响、留下了什么。",
		"   **不要逐章罗列。**摘要里有几章就写几段，是最典型的败笔——宁可只写透渠和粮，也不要顺带提一句陶土。",
		"2. 不写评价与总结。不出现「这体现了」「由此可见」「可见国势」这类判断句。",
		"3. 不出现任何阿拉伯数字与百分号，也不写年份数字。时间用「是年」「开春」「入冬」「岁末」。",
		"4. 不写具体人名、族名、国名、城名。指代人用身份：管仓的、粮行的、营里的、接生的、押车的。",
		"   也不要复述考评等级或分数——评语是衙门的话，不是史官的话。",
		"5. 摘要里的数目只用来判断轻重，不要照抄。知道「丁口添了不少」就写「添了不少丁口」。",
		"6. 至少要有一样具体的东西：一辆车、一仓粮、一本册子、一段渠、一张告示。",
		"7. 句子要短。用当时的器物与时令，不用现代词汇。",
		"",
		"【范例（学密度与句法，不要照抄内容）】",
		"是年春，渠成，水自西来，浑黄，推着草根走。渠边的地原先白花花的，翻了土，种下麦。",
		"民夫蹲在渠边看水，也看工头的脸色——工钱还没发。有人把手伸进水里，捞出一把泥，搓了搓，又扔回去。",
		"入冬，仓里添了两成粮，管仓的把新册子压在旧册子上面。旧册子的边角还留着去年的指印。",
		"",
		"只输出这一段文字。不要标题，不要分条，不要解释。",
	]))
	var user_content := "【%s · 第 %d 年 · %s】\n%s" % [
		String(model.get("country_name", "本国")),
		int(model.get("year", 1)),
		String(model.get("era_name", "当代")),
		brief,
	]
	return [
		{"role": "system", "content": system_content},
		{"role": "user", "content": user_content},
	]


## 把 model 压成「史官简报」。
##
## 刻意不给整份 full_text：那里面有一整段原始账目（1/10000 货币、Q16 比例），
## 模型读到裸数字只会照抄或算错。这里只给已格式化的句子，且每章最多三条。
static func build_brief(model: Dictionary) -> String:
	var lines := PackedStringArray()
	var kpis: Array = model.get("kpis", [])
	if not kpis.is_empty():
		var kpi_parts := PackedStringArray()
		for raw in kpis:
			if not (raw is Dictionary):
				continue
			var row: Dictionary = raw
			kpi_parts.append("%s %s" % [
				String(row.get("label", "")), String(row.get("current", ""))])
		if not kpi_parts.is_empty():
			lines.append("全年总量：" + "；".join(kpi_parts))
	var grade := String(model.get("grade", ""))
	if not grade.is_empty() and grade != "—":
		lines.append("岁末考评：%s" % grade)
	for raw_chapter in model.get("chapters", []):
		if not (raw_chapter is Dictionary):
			continue
		var chapter: Dictionary = raw_chapter
		var details: Array = chapter.get("details", [])
		if details.is_empty():
			continue
		var picked := PackedStringArray()
		for i in range(mini(details.size(), MAX_DETAILS_PER_CHAPTER)):
			picked.append(String(details[i]))
		lines.append("%s：%s" % [String(chapter.get("title", "")), " ".join(picked)])
	return "\n".join(lines)


## 模型偶尔会带 Markdown 或引号。清掉包裹层，但不动正文——正文怎么称呼是它的事。
static func _sanitize(raw: String) -> String:
	var text := raw.strip_edges()
	for fence in ["```", "~~~"]:
		if text.begins_with(fence):
			text = text.substr(fence.length()).strip_edges()
		if text.ends_with(fence):
			text = text.substr(0, text.length() - fence.length()).strip_edges()
	if text.begins_with("\"") and text.ends_with("\"") and text.length() > 2:
		text = text.substr(1, text.length() - 2).strip_edges()
	# 提示词要求不写标题；模型仍可能加一行「第 X 年 · 纪事」。只砍首行的书名号式标题。
	var first_break := text.find("\n")
	if first_break > 0 and first_break < 24:
		var head := text.substr(0, first_break)
		if head.contains("纪事") or head.contains("编年"):
			text = text.substr(first_break + 1).strip_edges()
	return text


func _save(report_id: int, text: String) -> void:
	var abs_dir := ProjectSettings.globalize_path(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var file := FileAccess.open(_cache_path(report_id), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _cache_path(report_id: int) -> String:
	return "%s/v%d_%04d.txt" % [CACHE_DIR, PROMPT_VERSION, report_id]
