extends SceneTree

## 年度纪事探针：用当前 prompt 打一次真模型，看它写成什么样。
##
##   <godot_console> --headless --path . --script tools/annual_chronicle_probe.gd
##
## **会联网、会消耗额度**。样本是一份手工构造的年度报告 model（九章取四章），
## 数值口径与 ViewModel 一致（kpis 的 current 已是格式化字符串）。
## 与真正的年度报告相比少了图表与账簿，但 brief 只读 kpis / grade / chapter.details，
## 这三样都在样本里，因此足以判断文风。

const ScribeScript = preload("res://scripts/annual/annual_chronicle_scribe.gd")
const AiClient = preload("res://scripts/narrative/ai/narrative_ai_client.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var model := {
		"available": true, "id": 1, "year": 12, "country_name": "临漳",
		"era_name": "帝国与封建时代", "grade": "乙上", "score_value": 78.5,
		"kpis": [
			{"label": "全年 GDP", "current": "十二万八千五百"},
			{"label": "年末人口", "current": "四十六"},
			{"label": "全年平均满意度", "current": "六成二"},
			{"label": "新增科技", "current": "三"},
		],
		"chapters": [
			{"title": "年度总述", "details": ["本年新建聚落一处，升格一处。"]},
			{"title": "人口与民生", "details": [
				"佃农：人口二十八，综合满意度六成二，资金三千。",
				"自然增长二十七；迁移及领土调整的净影响为负。",
			]},
			{"title": "产业与建设", "details": [
				"铁匠铺：增加值二万一千，实付工资八千。",
				"本年完工十二处，在建三处。",
			]},
			{"title": "资源与年度问题", "details": [
				"本年提取陶土五十二万，最近记录剩余十六万。",
				"本国市场最大缺货比例一成四。",
			]},
		],
	}
	var messages := ScribeScript.build_messages(model)
	print("========== system ==========")
	print(String((messages[0] as Dictionary).get("content", "")))
	print("========== user ==========")
	print(String((messages[1] as Dictionary).get("content", "")))

	var keys := AiClient.load_api_keys()
	if String(keys.get("llm_api_key", "")).is_empty():
		print("[probe] 没有可用的 LLM key")
		quit()
		return
	var endpoint := "https://api.deepseek.com/v1/chat/completions"
	var name := "deepseek-chat"
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		endpoint = String(cfg.get_value("settings", "ai_llm_base_url", endpoint))
		name = String(cfg.get_value("settings", "ai_llm_model", name))
	endpoint = AiClient.normalize_llm_endpoint(endpoint)

	var http := HTTPRequest.new()
	root.add_child(http)
	http.timeout = 60.0
	var body := JSON.stringify({
		"model": name, "messages": messages, "temperature": 0.9,
	})
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % String(keys.get("llm_api_key", "")),
	])
	if http.request(endpoint, headers, HTTPClient.METHOD_POST, body) != OK:
		print("[probe] 请求发起失败")
		quit()
		return
	var res: Array = await http.request_completed
	http.queue_free()
	var http_code := int(res[1])
	var payload := (res[3] as PackedByteArray).get_string_from_utf8()
	print("[probe] http=%d" % http_code)
	if http_code < 200 or http_code >= 300:
		print(payload.left(600))
		quit()
		return
	var text := AiClient.extract_chat_content(payload)
	print("---------- 纪事（%d 字） ----------" % text.length())
	print(text)
	print("---------- 清洗后（%d 字） ----------" % ScribeScript._sanitize(text).length())
	print(ScribeScript._sanitize(text))
	quit()
