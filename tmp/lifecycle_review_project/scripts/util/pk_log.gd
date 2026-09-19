extends RefCounted
class_name PKLog

## PKLog — 全局诊断日志开关（class_name 全局访问，无需 autoload）。
##
## Fix #11 second pass (2026-06-16)：mobile 60FPS 调查发现绝大多数稳态 GDScript
## print 站点（每秒 30+ 行）单行 logcat ~5-10ms，自身就占用 mobile frame budget
## 的 15-30%。即使 print() 本身是 cheap，**字符串 `%` 格式化**（Variant box/unbox
## + String interpolation）和 Dictionary lookup 也很贵。
##
## 设计原则：
##   1. **Static var `enabled`** + class_name 让所有脚本直接通过 `PKLog.enabled`
##      访问，无需 instance。Static var 跨 instance 共享，比 Engine.get_meta /
##      ProjectSettings.get_setting 反复 Dictionary lookup 快 ~10×。
##   2. 所有 caller 用 `if PKLog.enabled: print(...)` 守门，false 时 print
##      参数（含 `%` 构造 + Variant 数组）完全 short-circuit 不执行。
##   3. **C++ 镜像**：通过 SusSchedulerExt.set_diag_logs_enabled / DCWorldExt.set_diag_logs_enabled
##      把开关推到 C++ 端（待实现），让原生 print 站点也响应。
##
## 使用：
##   if PKLog.enabled:
##       print("[ocean_currents][RT] phys_slice#%d tick=%d ..." % [...])
##
## 切换：
##   main.gd KEY_L 切换 PKLog.enabled + 镜像到 C++ 端。

# 全局开关。true = 允许 print，false = 守门站点跳过 print 和 % 构造。
# 默认 false：desktop 稳态下 fast-tick WARN（sus>1ms 每 30 帧 ~25-40 行）会持续
# 刷屏触发编辑器 "output overflow"（每帧 100 行硬上限）。需要诊断时按 L /
# GM 面板 Log 按钮临时打开。
static var enabled: bool = false


## 切换开关，可选 push 到 C++ 端（避免 main.gd 重复 if 检查 has_method）。
static func set_enabled(new_enabled: bool, world_ext = null, sus_ext = null) -> void:
	enabled = new_enabled
	# 用户每按一次 F10 必打一行（即使关掉也告知现在状态），所以不走 `if enabled:` 守门。
	print("[PKLog] enabled=%s (toggle via F10)" % str(new_enabled))
	if world_ext != null and world_ext.has_method("set_diag_logs_enabled"):
		world_ext.set_diag_logs_enabled(new_enabled)
	if sus_ext != null and sus_ext.has_method("set_diag_logs_enabled"):
		sus_ext.set_diag_logs_enabled(new_enabled)
