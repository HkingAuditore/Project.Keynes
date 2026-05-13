extends RefCounted
class_name DCWeatherFrontAdvect

## Phase E.2 / dots-full-migration §Phase E.2：weather front 推进抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`weather_system.gd`](./weather_system.gd) 待按"逐函数搬迁清单"移过来。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## 主入口（在 weather_system.tick_one_day 内联，无独立 _advance_fronts 函数；
## 搬迁时需提取为独立方法）：
##   - tick_one_day 中 "advance fronts" 段（约 line 200-280）：
##     for front in _active_fronts:
##         front.position += front.velocity * dt
##         front.intensity *= front.decay_rate
##         front.age += 1
##         if front.intensity < THRESHOLD or front 出界:
##             移除
##
## 配套 helper：
##   - cyclone wake 扰动 `_tick_cyclone_wake(map)`  — line 2052 (~80 行)
##   - 边界/出界判定（搜 `_world_bounds`）
##   - WeatherFront 字段访问（pos / vel / intensity / age / decay_rate）
##
## ─── F.6 C++ 化前置条件 ──────────────────────────────────────────
##
## F.6 weather front advect → C++ 化时本类必须先完成抽出。C++ 端 pass 签名：
##   `run_weather_front_advect_pass(n_fronts: int, dt: float)`
## 读 / 写 FRONT_POS_X/Y/VEL_X/Y/AGE/INTENSITY 6 个 component（已注册到
## DCComponentIds，但目前是镜像；F.6 升为权威）。
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 接受 weather_system owner，从中拿 _active_fronts pool / _world_bounds /
##    _hex_size 等配置；
## 2. 读 cell.wind_vector / has_river 走 ViewAdapter 或 weather_refresh_job
##    的 data_core_views()；
## 3. F.6 之后 fronts 数据从 GDScript Array[WeatherFront] 升级为 World 的 FRONT_*
##    component pool（即真正 entity）。

var _weather_system

func _init(weather_system) -> void:
	_weather_system = weather_system

## 主入口：tick fronts（搬迁后填实现）。
## 当前为 stub；E.2 后由 weather_system.tick_one_day 切换为调用本方法。
func tick(_dt: float) -> void:
	pass

## 取活跃 fronts 列表（owner 仍持权威；F.6 后改读 World pool）。
func active_fronts() -> Array:
	if _weather_system == null:
		return []
	# Future: 提供与 weather_system._active_fronts 相同的语义
	return []

func describe() -> String:
	return "DCWeatherFrontAdvect(owner=%s)" % ("ws" if _weather_system != null else "(null)")
