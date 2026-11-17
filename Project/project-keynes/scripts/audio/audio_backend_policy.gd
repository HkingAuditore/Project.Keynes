extends RefCounted

static func native_backend_reason_for(platform: String, _is_web: bool, is_android: bool,
		forced: bool) -> String:
	if forced:
		return "forced"
	# Android 走 FMOD。设备实测（emulator-5554）证明扩展能在 Android 上加载，
	# 卡点是 FMOD 的 JNI：`JNI_OnLoad` 会 FindClass("org.fmod.FMOD")，缺这个 Java 类
	# 时 JNI 直接 abort 整个进程（"JNI DETECTED ERROR ... ClassNotFoundException:
	# org.fmod.FMOD"）。现在由三件事兜住：
	#   - addons/0_fmod_bootstrap 在加载扩展前执行 JNI_OnLoad /
	#     FMOD_Android_JNI_Init；
	#   - org.fmod.* 由 tools/fmod_java_stub 提供（secondary dex 注入 APK）；
	#   - prime() 先探测类、失败返回非 0，_ready() 见到非 0 就显式失败。
	# Android 不接受 portable fallback；PK_AUDIO_FORCE_NATIVE 仅用于桌面/Web 调试。
	if is_android or platform == "Android":
		return ""
	return ""


static func fmod_platform_supported(platform: String, is_web: bool) -> bool:
	# Web 用 FMOD HTML5 side module（gdext/fmod_godot 从 SDK 源码编译）。
	if is_web:
		return true
	if platform == "Android" or OS.has_feature("android"):
		return true
	return platform == "Windows"
