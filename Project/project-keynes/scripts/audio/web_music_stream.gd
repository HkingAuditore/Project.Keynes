extends Node
## [web-music-defer 2026-11-01] Web 上按时代拉取音乐包。
##
## 背景：`assets/audio/native/music/` 的 17.7 MB ogg 原本整包进 boot pck，而一次
## 会话只会用到当前时代那一首（外加偶发的过场）。Web 外壳只会自动下 `GODOT_CONFIG.pck`
## 一个包，所以这里自己拉：
##     fetch(music_<era>.pck)  ->  engine.rtenv.copyToFS('/tmp/x.pck', bytes)
##     ->  ProjectSettings.load_resource_pack('/tmp/x.pck', true)
## 这两步在真浏览器里实测过（88 MB / 50 ms，见 tmp/web_copytofs_probe.py）。
##
## 契约：
##   * 失败一律静音降级（没有音乐，但绝不弹窗/不卡加载），只发一条 WebTelemetry；
##   * 同一个时代失败一次就不再重试（避免坏网络下无限刷请求）；
##   * 挂载成功后调用注册的回调，由 `native_audio_backend` 重放"上次没放成"的请求。

const PACK_URL_FMT := "music_%s.pck"
const MOUNT_PATH_FMT := "/tmp/pk_music_%s.pck"
const ERAS := [&"stone", &"agrarian", &"kingdom", &"empire"]

## 挂载成功的包名（"stone" / "trans" ...）。
var _mounted: Dictionary = {}
## 正在拉的包名 -> true。
var _inflight: Dictionary = {}
## 拉失败过的包名 -> 错误串。
var _failed: Dictionary = {}
## 包名 -> [Callable...]（挂载完成后要做的重试）。
var _waiters: Dictionary = {}

var _bridge: Object = null
var _fetch_cb: Variant = null
var _js_installed := false
var _defer := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.has_feature("web"):
		set_process(false)
		return
	if not Engine.has_singleton("JavaScriptBridge"):
		set_process(false)
		return
	_bridge = Engine.get_singleton("JavaScriptBridge")
	_defer = _defer_enabled()
	_install_js()
	WebTelemetry.emit("music_defer_ready", {"defer": _defer})


## 是否延后到进世界之后才拉。默认开；`?music=inline` 或项目设置关掉即"启动就拉"。
func _defer_enabled() -> bool:
	var forced := ""
	if _bridge != null:
		var raw: Variant = _bridge.call("eval",
			"(function(){try{return String(new URLSearchParams(location.search).get('music')||'');}catch(e){return '';}})()")
		if raw != null:
			forced = String(raw).strip_edges().to_lower()
	if forced == "inline":
		return false
	if forced == "defer":
		return true
	return bool(ProjectSettings.get_setting("audio/web_defer_music", true))


func era_pack_name(era: int) -> String:
	var index := clampi(era, 0, ERAS.size() - 1)
	return String(ERAS[index])


func is_mounted(pack_name: String) -> bool:
	return _mounted.has(pack_name)


## 幂等：已挂载就立刻回调；正在拉就排队；失败过就直接放弃（静音）。
func ensure_pack(pack_name: String, on_ready: Callable) -> void:
	if _mounted.has(pack_name):
		if on_ready.is_valid():
			on_ready.call()
		return
	if _failed.has(pack_name):
		return
	var waiters: Array = _waiters.get(pack_name, [])
	if on_ready.is_valid():
		waiters.append(on_ready)
	_waiters[pack_name] = waiters
	if _inflight.has(pack_name):
		return
	_inflight[pack_name] = true
	var url := PACK_URL_FMT % pack_name
	WebTelemetry.emit("music_pack_begin", {"pack": pack_name, "url": url})
	var target := MOUNT_PATH_FMT % pack_name
	_bridge.call("eval", "window.__pkFetchPck(%s, %s, %s);" % [
		JSON.stringify(url), JSON.stringify(target), "window.__pkPckCb"])


func _install_js() -> void:
	if _js_installed or _bridge == null:
		return
	_js_installed = true
	_fetch_cb = JavaScriptBridge.create_callback(_on_fetch_result)
	var window: Object = _bridge.get_interface("window")
	if window != null:
		window.set("__pkPckCb", _fetch_cb)
	var js := """
	(function(){
	  if (window.__pkFetchPck) return;
	  window.__pkFetchPck = function(url, target, cbName){
	    try {
	      fetch(url, {cache:'no-store'}).then(function(resp){
	        if (!resp.ok) { window[cbName](url, 0, 'http_' + resp.status); return null; }
	        return resp.arrayBuffer().then(function(buf){
	          try {
	            if (!engine || !engine.rtenv || !engine.rtenv.copyToFS) {
	              window[cbName](url, 0, 'no_copyToFS'); return;
	            }
	            engine.rtenv.copyToFS(target, new Uint8Array(buf));
	            window[cbName](url, buf.byteLength, '');
	          } catch (e) { window[cbName](url, 0, String(e)); }
	        });
	      }).catch(function(e){ window[cbName](url, 0, String(e)); });
	    } catch (e) { try { window[cbName](url, 0, String(e)); } catch(_){} }
	  };
	})();
	"""
	_bridge.call("eval", js)


## JS 回调：`args = [url, bytes, error]`。
func _on_fetch_result(args: Array) -> void:
	if args.size() < 3:
		return
	var url := String(args[0])
	var size := int(args[1])
	var error := String(args[2])
	var pack_name := url.get_file().trim_prefix("music_").trim_suffix(".pck")
	_inflight.erase(pack_name)
	if size <= 0 or not error.is_empty():
		_failed[pack_name] = error if not error.is_empty() else "empty_body"
		_waiters.erase(pack_name)
		push_warning("[music] pack fetch failed (%s): %s" % [pack_name, _failed[pack_name]])
		WebTelemetry.emit("music_pack_fail", {"pack": pack_name, "error": _failed[pack_name]})
		return
	var target := MOUNT_PATH_FMT % pack_name
	var mounted := ProjectSettings.load_resource_pack(target, true)
	if not mounted:
		_failed[pack_name] = "load_resource_pack_false"
		_waiters.erase(pack_name)
		push_warning("[music] load_resource_pack failed: " + target)
		WebTelemetry.emit("music_pack_fail", {"pack": pack_name, "error": "mount_false"})
		return
	_mounted[pack_name] = true
	WebTelemetry.emit("music_pack_done", {"pack": pack_name, "bytes": size})
	var waiters: Array = _waiters.get(pack_name, [])
	_waiters.erase(pack_name)
	for callback: Callable in waiters:
		if callback.is_valid():
			callback.call()
