extends RefCounted

const RendererShaderWater = preload("res://scripts/rendering/renderer_shader_water.gd")

## 探针开关（已定案，保留 false）：web 上用 3 行 shader 替换 world_map。
## 结论：换掉后首帧仍然 45s，所以世界材质不是元凶，见 weather_layer 的裁剪变体。
const PK_WEB_TRIVIAL_WORLD_SHADER_PROBE := false
## 探针：web 上跳过 deferred 植被填充（图层仍创建），用来判定长帧是否来自填充。
const PK_WEB_SKIP_DEFERRED_VEG_SEED := false
## Web 天气表现层总闸（只在高画质下绘制）。
## 判定见 `_web_weather_layer_draw_allowed()`：
##   - 玩家设置「高」→ `visual_quality >= 2` → 绘制；
##   - QA 的 `?tier=high`（autotest 把 mobile tier 推到 HIGH）→ 也按高画质处理；
##   - 低 / 中 / auto → 不绘制（对象仍在、所有 set_* 照常、天气**模拟**不受影响）。
## 实测依据：weather_overlay 那套在 ANGLE 上把每帧
## 拖到几十秒，94% 采样卡在 blitOffscreenFramebuffer 的 getParameter（GPU 排队同步）。
## 不绘制后：10x 跑满一年、最大帧间隔 2 秒。
## 落地注意：**不能**只在 `_ready` 里写一次 `visible = false` ——
## `WeatherLayer._refresh_visibility()` 在有 LUT/fronts 时会自己把 visible 置 true
## （setup() 里就会），必须走 `_apply_weather_layer_render_gate()` 把门交给天气层收敛。
## 置 false 是应急总闸：web 上任何画质都不绘制。
const PK_WEB_ENABLE_WEATHER_LAYER := true

## Web 专用：把 9 层植被的 setup 推迟到进世界之后。实测这段在 wasm 里要 4.1 秒，
## 直接压在加载窗口里；植被只是观感层，晚 2-3 秒出现可以接受。
## Web 正式策略：天气层保留对象、只有高画质才绘制（见 PK_WEB_ENABLE_WEATHER_LAYER 注释）。
## PROBE：隐藏地图 quad 本身（隔离"地图绘制/图集上传"是否造成长帧）。
const PK_WEB_HIDE_WORLD_QUAD := false
const PK_WEB_MINIMAL_LAYERS := false
const PK_WEB_LAYER_FOG := true
const PK_WEB_LAYER_BORDER := true
const PK_WEB_LAYER_WEATHER := true
const PK_WEB_LAYER_BUILDING := false
const PK_WEB_DEFER_VEG_LAYERS := true

## [cell-field 2026-11-18] 项目设置侧的解析格界开关（转发给 RendererShaderWater）。
## 与 _init() 的 export 初值走同一个函数，保证「部署期默认值」与「运行期实际行为」
## 读的是同一个设置。注意 v1 它只对桌面 Vulkan / 移动有效（见 terrain_cell_field_enabled
## 与 RendererShaderWater._cell_field_active 的注释）。
static func cell_field_setting_enabled() -> bool:
	return RendererShaderWater.cell_field_setting_enabled()
