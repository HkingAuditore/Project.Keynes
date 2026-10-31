class_name WebTelemetry
extends RefCounted

## Web 构建 → 本地事件通道。
##
## 页面把 JSON 事件 `POST /_log`，`tools/serve_web.py` 追加到
## `tmp/web_events.jsonl`；agent 侧直接 tail 这个文件就能实时看到加载步骤、
## 日历推进、卡死告警，不需要截图轮询、也不需要固定等待。
##
## 只在 web 上生效（桌面/导出为 no-op），并且完全 fire-and-forget：
## fetch 失败、桥不存在都不会影响游戏。

static var _probed := false
static var _enabled := false
static var _bridge: Object = null
## 待发送队列。主线程被长帧堵住 30 秒时，直接 fetch 会被浏览器丢掉，
## 于是"最该看到的那条事件"正好丢了。改成先入队、下一帧开头统一冲刷。
static var _queue: Array[String] = []
const MAX_QUEUE := 512


static func enabled() -> bool:
	if not _probed:
		_probed = true
		_enabled = OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge")
		if _enabled:
			_bridge = Engine.get_singleton("JavaScriptBridge")
	return _enabled


static func emit(event_name: String, fields: Dictionary = {}) -> void:
	if not enabled():
		return
	var payload: Dictionary = {"e": event_name, "ms": Time.get_ticks_msec()}
	for key in fields.keys():
		payload[String(key)] = fields[key]
	_queue.append(JSON.stringify(payload))
	if _queue.size() > MAX_QUEUE:
		_queue.remove_at(0)


## 把队列里的 JSON 一次性发出去（由 host 每帧开头调用，保证长帧之后也能送达）。
static func flush() -> void:
	if not enabled() or _queue.is_empty():
		return
	var pending := _queue
	_queue = []
	for body in pending:
		# JSON.stringify(body) 把 JSON 文本再编码成 JS 字符串字面量，避免引号/换行问题。
		var js := "try{fetch('/_log',{method:'POST',headers:{'Content-Type':'application/json'},body:%s,keepalive:true}).catch(function(){});}catch(e){}" % JSON.stringify(body)
		_bridge.call("eval", js)


## 监听浏览器侧事件，用来区分"游戏自己崩了"和"页面被重载/上下文丢失"。
## 事件落到同一条 /_log 通道，和服务器的 t_wall 配对即可判定时间线。
static func install_page_hooks() -> void:
	if not enabled():
		return
	var js := """
	(function(){
	  if (window.__pkHooks) return; window.__pkHooks = 1;
	  function post(kind, extra){
	    try{
	      var body = JSON.stringify(Object.assign({e: kind, src: "browser"}, extra||{}));
	      fetch('/_log', {method:'POST', headers:{'Content-Type':'application/json'},
	                      body: body, keepalive: true}).catch(function(){});
	    }catch(e){}
	  }
	  var c = document.querySelector('canvas');
	  if (c) {
	    c.addEventListener('webglcontextlost', function(ev){ post('gl_lost', {reason: String(ev && ev.statusMessage || '')}); }, false);
	    c.addEventListener('webglcontextrestored', function(){ post('gl_restored', {}); }, false);
	  }
	  window.addEventListener('pagehide', function(){ post('page_hide', {}); }, false);
	  window.addEventListener('beforeunload', function(){ post('page_unload', {}); }, false);
	  window.addEventListener('error', function(ev){ post('js_error', {msg: String(ev && ev.message || '')}); }, false);
	  window.addEventListener('unhandledrejection', function(ev){ post('js_rejection', {msg: String(ev && ev.reason || '')}); }, false);
	})();
	"""
	_bridge.call("eval", js)


## wasm 内存（MB）：用来观察一年长跑是否把内存推爆导致上下文丢失。
static func memory_mb() -> int:
	if not enabled():
		return -1
	return int(Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0))


static func clock(day: int, speed: float, paused: bool) -> void:
	emit("clock", {"day": day, "speed": speed, "paused": paused})


## 源码指纹：用来判断"预热编的那份"和"运行期真正要编的那份"是不是同一份。
##
## 背景：WebGL 没有 program binary 缓存，唯一的省法是在菜单期把**完全相同的源码**
## 编一遍让驱动缓存住。前面已经踩过两次「前缀差一个 #define → 驱动缓存不命中 →
## 预热白做、编译还是发生进游戏之后」：
##   - 植被预热硬编码了 `MAP_VISUAL_TILED`，而 web 运行期不是 tiled；
##   - world_map 运行期先编了一份 `quality=`（空档位）的变体，预热里没有这一份。
## 这类错**完全静默**，只能靠指纹对账。长度 + hash 足以区分不同变体，又不至于让
## 事件体积爆掉。
static func code_fingerprint(code: String) -> String:
	return "%d:%d" % [code.length(), code.hash()]


## 运行期第一次创建某个材质变体时调一次（每个 label 只发一次）。
## 和 `warmup_shader` 的 `fp` 对账：运行期出现的 fp 若不在预热集合里，就说明
## "还有一份 shader 会在游戏里编"，这正是要消灭的冻结帧来源。
static var _variant_seen: Dictionary = {}

static func note_variant(label: String, code: String) -> void:
	if not enabled() or _variant_seen.has(label):
		return
	_variant_seen[label] = true
	emit("material_variant", {"label": label, "fp": code_fingerprint(code)})


static func reset_variant_seen() -> void:
	_variant_seen.clear()
