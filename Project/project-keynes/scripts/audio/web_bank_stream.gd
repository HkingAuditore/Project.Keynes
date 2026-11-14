extends RefCounted
## [web-era-bank 2026-11-11] Web 上按时代拉取 FMOD bank。
##
## 背景：`Music.bank` 里 98.5% 的 PCM 来自四个 `event:/Music/<Era>/Suite` 事件，而
## 一局只会用到其中一个。拆成四个 bank 后 web 首包只带当前时代那一份
## （实测 49.7 MB -> 8.2~10.3 MB），其余在时代推进时按需拉。
##
## 为什么不能用 `web_music_stream.gd`：那个是 portable 回退路径用的，挂的是
## `music_<era>.pck`（ProjectSettings.load_resource_pack）。bank 不能挂进 res://，
## 必须落成 emscripten FS 上的真实文件，再交给 `StudioSystem.load_bank_file`。
##
## 契约：
##   * 只负责"把文件弄到 /tmp 并回报路径"，不碰 FMOD，也不知道 era 是什么；
##   * 同一个 era 只发一次请求；成功过的缓存路径，失败过的直接放弃（不刷请求）；
##   * 失败一律静音降级：回调收到空字符串，调用方自己决定怎么办。

const FS_DIR := "/tmp"
const MAX_CONCURRENT := 1

var _bridge: Object = null
var _cb: Variant = null
var _js_installed := false

var _url_of := {}       # target_path -> url
var _target_of := {}    # url -> target_path
var _inflight := {}     # url -> true
var _done := {}         # url -> fs path
var _failed := {}       # url -> reason
var _waiters := {}      # url -> Array[Callable]


func _init() -> void:
	if not Engine.has_singleton("JavaScriptBridge"):
		return
	_bridge = Engine.get_singleton("JavaScriptBridge")
	_install_js()


func is_supported() -> bool:
	return _bridge != null


## 幂等。`on_ready` 收到的是 FS 上的绝对路径；失败时收到空字符串。
func ensure(bank_name: String, on_ready: Callable) -> void:
	var url := "%s.bank" % bank_name
	if _done.has(url):
		if on_ready.is_valid():
			on_ready.call(String(_done[url]))
		return
	if _failed.has(url):
		if on_ready.is_valid():
			on_ready.call("")
		return
	var list: Array = _waiters.get(url, [])
	if on_ready.is_valid():
		list.append(on_ready)
	_waiters[url] = list
	if _inflight.has(url):
		return
	if _bridge == null:
		_failed[url] = "no_javascriptbridge"
		_flush(url, "")
		return

	_inflight[url] = true
	var target := "%s/pk_bank_%s" % [FS_DIR, bank_name.to_lower()]
	_url_of[target] = url
	_target_of[url] = target
	print("[audio] era bank fetch: %s -> %s" % [url, target])
	_bridge.call("eval", "window.__pkFetchBank(%s, %s, %s);" % [
		JSON.stringify(url), JSON.stringify(target), "window.__pkBankCb"])


func _flush(url: String, path: String) -> void:
	var list: Array = _waiters.get(url, [])
	_waiters.erase(url)
	for cb: Callable in list:
		if cb.is_valid():
			cb.call(path)


func _install_js() -> void:
	if _js_installed or _bridge == null:
		return
	_js_installed = true
	_cb = JavaScriptBridge.create_callback(_on_fetch_result)
	var window: Object = _bridge.get_interface("window")
	if window != null:
		window.set("__pkBankCb", _cb)
	# 与 web_music_stream.gd 的助手同名会冲突，所以用 __pkFetchBank；两处都带
	# "已存在就直接返回"的守卫，谁先装都一样。
	var js := """
	(function(){
	  if (window.__pkFetchBank) return;
	  window.__pkFetchBank = function(url, target, cbName){
	    try {
	      // 同一会话内不缓存：bank 由构建产出，带 hash 的部署已经由宿主管缓存。
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
	_inflight.erase(url)
	if size <= 0 or not error.is_empty():
		var reason := error if not error.is_empty() else "empty_body"
		_failed[url] = reason
		push_warning("[audio] era bank fetch failed (%s): %s" % [url, reason])
		_flush(url, "")
		return
	var target := String(_target_of.get(url, ""))
	if target.is_empty():
		_failed[url] = "lost_target"
		_flush(url, "")
		return
	_done[url] = target
	_flush(url, target)
