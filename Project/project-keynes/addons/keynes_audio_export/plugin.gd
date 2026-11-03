@tool
extends EditorPlugin

## 音频导出插件（FMOD）。
##
## 平台矩阵（2026-11-01 设备实测通过的部分）：
##   Windows : addons/FmodGodot/bin/windows/x86_64/*.dll + bank
##   Android : lib/<abi>/ 里的 libFmodGodot + libfmod(L) + libfmodstudio(L) + JNI 引导扩展 + bank
##   Web     : 未完成 —— 见文件末尾说明
##
## 两个 addon 都带 `.gdignore`（不参与资源扫描、不会被引擎自动加载），所以描述符与
## 原生库必须由本插件显式打包；GameAudio 在运行期用 GDExtensionManager.load_extension()
## 手动加载。
##
## Web 为什么不在这个方案里：浏览器上运行期 load_extension() 会同步等待异步 fetch，
## 直接死锁主线程（控制台可见 emscripten 的 "Blocking on the main thread is very
## dangerous"）。Web 必须让引擎启动时自动加载，也就是把描述符写进
## `.godot/extension_list.cfg`；而 extension_list 只收录没有 `.gdignore` 的 .gdextension。
## 结论：Web 需要单独一套"去掉 .gdignore + 保证加载顺序"的导出路径，尚未落地。

class AudioExport extends EditorExportPlugin:
	const ROOT := "res://addons/FmodGodot/"
	const ANDROID_ROOT := ROOT + "bin/android/"
	const BOOTSTRAP_ROOT := "res://addons/0_fmod_bootstrap/"
	const ANDROID_ABIS := ["arm64", "x86_64"]
	const ANDROID_DEBUG_LIBS := ["libFmodGodot.template_debug.so", "libfmodL.so", "libfmodstudioL.so"]
	const ANDROID_RELEASE_LIBS := ["libFmodGodot.template_release.so", "libfmod.so", "libfmodstudio.so"]

	func _get_name() -> String:
		return "KeynesFmod"

	## 只给预设里真正启用的 ABI 打包（Android 的 primaryCpuAbi 由 APK 里存在哪些
	## lib/<abi>/ 决定，塞错 ABI 会把选择带偏）。
	func _android_enabled_abis() -> Array:
		var enabled: Array = []
		var cfg := ConfigFile.new()
		if cfg.load("res://export_presets.cfg") != OK:
			return ANDROID_ABIS
		for section in cfg.get_sections():
			if not section.begins_with("preset.") or section.ends_with(".options"):
				continue
			if String(cfg.get_value(section, "platform", "")) != "Android":
				continue
			var options := section + ".options"
			for abi in ANDROID_ABIS:
				var key: String = "architectures/" + ("arm64-v8a" if abi == "arm64" else String(abi))
				var is_on: bool = bool(cfg.get_value(options, key, cfg.get_value(section, key, false)))
				if is_on and not enabled.has(abi):
					enabled.append(abi)
		return enabled if not enabled.is_empty() else ANDROID_ABIS

	func _export_begin(features: PackedStringArray, debug: bool, _path: String, _flags: int) -> void:
		var is_windows := features.has("windows")
		var is_android := features.has("android")
		var is_web := features.has("web")
		if not (is_windows or is_android or is_web):
			return
		# bank 三个平台都要（Web 走 tools/export_web_with_fmod.ps1：那个脚本会临时
		# 去掉两个 addon 的 .gdignore，让引擎在启动时自动加载 FmodGodot —— 浏览器里
		# 运行期 load_extension 会死锁主线程，所以 web 不能靠描述符进 PCK 这条路）。
		var banks := "res://assets/audio/banks/Desktop/"
		for name in DirAccess.get_files_at(banks):
			if name.ends_with(".bank"):
				add_file(banks + name, FileAccess.get_file_as_bytes(banks + name), false)
		if is_web:
			# web 的导出会把 .gdextension 当文本资源、转成二进制进 PCK，浏览器里的
			# GDExtensionLibraryLoader 读不了（"Error loading GDExtension configuration
			# file"）。这里按原始字节再塞一份，绕开文本资源转换。
			add_file(ROOT + "FmodGodot.gdextension",
				FileAccess.get_file_as_bytes(ROOT + "FmodGodot.gdextension"), false)
			return
		# 描述符必须进 PCK（addon 带 .gdignore，不参与资源扫描）。
		add_file(ROOT + "FmodGodot.gdextension",
			FileAccess.get_file_as_bytes(ROOT + "FmodGodot.gdextension"), false)
		if is_windows:
			var binaries := ROOT + "bin/windows/x86_64/"
			for name in DirAccess.get_files_at(binaries):
				if name.ends_with(".dll"):
					add_shared_object(binaries + name, PackedStringArray(["windows", "x86_64"]),
						"addons/FmodGodot/bin/windows/x86_64")
			return
		# Android：EditorExportPlatformAndroid::_save_apk_so 只用文件名和 tag 里的 abi，
		# 把文件写进 APK 的 lib/<abi>/；运行期 OS_Android::open_dynamic_library 找不到
		# res:// 文件时会退回 dlopen(文件名)，由 Android 链接器在同目录解析依赖。
		var libs: Array = ANDROID_DEBUG_LIBS if debug else ANDROID_RELEASE_LIBS
		var target := "template_debug" if debug else "template_release"
		add_file(BOOTSTRAP_ROOT + "fmod_bootstrap.gdextension",
			FileAccess.get_file_as_bytes(BOOTSTRAP_ROOT + "fmod_bootstrap.gdextension"), false)
		for abi in _android_enabled_abis():
			for name in libs:
				var path: String = ANDROID_ROOT + abi + "/" + String(name)
				if FileAccess.file_exists(path):
					add_shared_object(path, PackedStringArray(["android", abi]), "")
				else:
					push_warning("[audio-export] missing Android FMOD library: " + path)
			var bootstrap_path: String = BOOTSTRAP_ROOT + "bin/android/libFmodBootstrap.android.%s.%s.so" % [target, abi]
			if FileAccess.file_exists(bootstrap_path):
				add_shared_object(bootstrap_path, PackedStringArray(["android", abi]), "")
			else:
				push_warning("[audio-export] missing FMOD JNI bootstrap: " + bootstrap_path)

	func _export_file(path: String, _type: String, features: PackedStringArray) -> void:
		if path.begins_with("res://assets/audio/banks/"):
			for feature in ["windows", "android", "web"]:
				if features.has(feature):
					return
			skip()
			return
		if path.begins_with("res://assets/audio/native/"):
			# portable 全混音是 Android 上 FMOD 起不来时的兜底，必须一起进 APK。
			for feature in ["web", "android"]:
				if features.has(feature):
					return
			skip()

var _audio_export: AudioExport
func _enter_tree() -> void:
	_audio_export = AudioExport.new()
	add_export_plugin(_audio_export)
func _exit_tree() -> void:
	remove_export_plugin(_audio_export)
