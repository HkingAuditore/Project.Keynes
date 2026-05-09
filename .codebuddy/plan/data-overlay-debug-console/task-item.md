# 实施计划：Data Overlay + Debug 控制台

> 依赖文档：[requirements.md](./requirements.md)
> 总体策略：**新增独立的 `DataOverlayLayer`（Node2D + 独立 shader + 独立数据纹理）叠在 `WorldQuad` 之上**，与现有 `hex_renderer._shader_mat` 解耦；Debug 控制台作为独立 `CanvasLayer` 场景挂载到 `UI`，不改动 `TopBar / RightPanel` 结构。

---

- [ ] 1. 搭建 Overlay 模式枚举与基础数据纹理烘焙入口
  - 在 `scripts/rendering/` 下新增 `overlay_mode.gd`（`class_name OverlayMode`），定义 `enum MODE { NONE, TEMPERATURE, PRECIPITATION, CLIMATE_ZONE, HUMIDITY, WEATHER, VEGETATION_VITALITY }` 及各档位中文显示名表。
  - 在 `HexRenderer` 或新文件 `scripts/rendering/data_overlay_baker.gd` 中实现 `bake_overlay_data(map: MapData, mode: int) -> ImageTexture`：按 mode 逐 cell 采样字段并写入 RG8 或 RGBA8 纹理（分辨率与 `enum_atlas` 相同，NEAREST 采样）；NaN/Inf 写入保留 alpha=0 作为无效标记。
  - _需求：1.1、1.3、2.1、2.2、2.3、2.4、2.5、2.6、6.2_

- [ ] 2. 编写 Overlay shader 与 DataOverlayLayer 节点
  - 新增 `shaders/data_overlay.gdshader`：全屏 quad 采样 `overlay_tex`，按 `uniform int overlay_mode` 分支走不同的色带（连续色带在 shader 内构造 ramp；离散通道 `CLIMATE_ZONE / WEATHER` 读离散 palette）。`alpha = 0` 的无效 cell 输出中性灰。
  - 新增 `scripts/rendering/data_overlay_layer.gd`（`class_name DataOverlayLayer extends Node2D`），维护一个 MeshInstance2D + ShaderMaterial，提供 `set_mode(mode)` / `set_alpha(v)` / `update_data_texture(tex)` / `set_bounds(rect)` 接口，z_index 高于 `WorldQuad` 但低于 `WeatherOverlay`。
  - 在 `main.tscn` 的 `WorldRoot` 下挂载 `DataOverlayLayer` 节点，不影响现有节点。
  - _需求：1.2、1.3、1.4、6.2、6.5_

- [ ] 3. 接入 main.gd：overlay 状态机与每日数据刷新
  - 在 `main.gd` 增加 `_overlay_mode: int = OverlayMode.MODE.NONE` / `_overlay_alpha: float = 0.7` / `_overlay_dirty: bool` 状态，加 `_apply_overlay_mode()` 与 `_refresh_overlay_data()`。
  - 在现有 `_on_day_changed` 钩子末尾：若 `_overlay_mode != NONE`，调用 `DataOverlayBaker.bake_overlay_data` 并推送给 `DataOverlayLayer`（保证每日更新，对 NONE 模式零额外开销，验收 1.3 / 2.7）。
  - 在 `regenerate`（R 键）完成后**保留** `_overlay_mode`，只重新烘焙数据纹理（验收 1.5）。
  - 加一段 try/except 风格的 guard：overlay 烘焙或 shader 参数写入失败时自动回退到 `NONE` 并 push_warning（验收 6.5）。
  - _需求：1.1、1.4、1.5、2.7、6.5_

- [ ] 4. 实现 Debug 控制台场景与基础挂载
  - 新增 `scenes/debug_console.tscn` + `scripts/ui/debug_console.gd`（`class_name DebugConsole extends PanelContainer`）：宽度 360，`mouse_filter = STOP`，使用 `ScrollContainer + VBoxContainer` 布局，默认 `visible = false`，停靠在 TopBar 下方左侧。
  - 在 `main.tscn/UI` 下以 `[instance ExtResource]` 方式挂入 `DebugConsole`（不改 TopBar / RightPanel 节点）。
  - 在 `main.gd._unhandled_input` 新增 `KEY_QUOTELEFT` 与 `KEY_F1` 分支，切换 `DebugConsole.visible`；保证 UI 点击不会穿透到地块选中（验收 4.6）。
  - _需求：4.1、4.2、4.6、6.1_

- [ ] 5. Debug 控制台：Overlay 分组（模式切换 + alpha 滑条）
  - 在 `debug_console.gd` 内用 `OptionButton` 或 `VBox of Button` 列出 `OverlayMode` 7 档，点击后 `emit_signal("overlay_mode_changed", mode)`。
  - 加 `HSlider` 控制 overlay alpha（0.0 ~ 1.0，默认 0.7），`emit_signal("overlay_alpha_changed", v)`。
  - `main.gd` 连接这两个 signal 到 `_apply_overlay_mode` / `DataOverlayLayer.set_alpha`，并做快速切换防抖（验收 6.4）。
  - _需求：1.2、1.4、4.3（Overlay 组）、4.4、6.4_

- [ ] 6. Debug 控制台：模拟开关 & 视觉开关 & 诊断动作分组
  - **模拟开关**分组：5 个 CheckBox 绑定 `ClimateProfile.emergent_season_enabled` / `enable_local_climate_coupling` / `emergent_weather_coupling` / `fast_slow_layering_enabled` / `true_insolation_enabled`，toggled 时复用 `main.gd` 里 F8 的完整同步逻辑（`_weather_system.configure_emergent_coupling` + `_renderer.set_true_insolation_enabled`）。
  - **视觉开关**分组：6 个 CheckBox 绑定 `day_night_enabled` / `water_effect_enabled` / `ocean_current_enabled` / `ocean_current_debug` / `extreme_weather_ground_effect_enabled` / `perf_sampler_enabled`，toggled 时调用 `_renderer` 对应的 setter。
  - **诊断动作**分组：3 个 Button—"打印洋流热输运摘要（F7 等价）"/"打印选中地块温度分解"/"清空选中"，调用 `main.gd` 内已有逻辑（抽成小函数复用）。
  - _需求：4.3、4.4、4.5_

- [ ] 7. Debug 控制台：Telemetry 实时面板 + 1Hz 刷新
  - 在 `debug_console.gd` 增加 `TelemetryBox`（VBox 里几个 Label）+ 一个 `Timer`（1Hz，`one_shot=false`）。
  - Timer 回调收集并显示：`fast_tick #N: Xms`（读 `main._fast_tick_count` 与最新 tick 耗时）、SUS/render/ui 三段耗时（当 `perf_log_daily_breakdown` 开启时）、overlay min/max/mean/median（复用任务 1 的采样结果顺便算一遍，结果缓存到 `main._overlay_stats`）。
  - 离散通道（`CLIMATE_ZONE`/`WEATHER`）显示每档 cell 计数；NaN 计数以黄色文字显示 `invalid cells: N`（验收 6.2）。
  - 暂停状态下冻结最后一次快照不更新（验收 5.3）。
  - _需求：5.1、5.2、5.3、5.4、6.2_

- [ ] 8. Overlay 图例（Legend）面板
  - 新增 `scenes/overlay_legend.tscn` + `scripts/ui/overlay_legend.gd`：`PanelContainer` 停靠在屏幕左下（`UI` CanvasLayer 下），内部含 "通道名" Label + 色带 `TextureRect`（连续模式预生成 64×1 色带 Texture；离散模式改为列出色块+文字的 VBox）+ 两端数值 Label + 可选"当前选中指针"（`ColorRect` 三角形）。
  - `main.gd` 在 `_apply_overlay_mode` 结束时调用 `OverlayLegend.update_for_mode(mode)`；`_on_cell_selected` 钩子中调用 `OverlayLegend.update_pointer(value)`（用当前 cell 的对应字段值），未选中时隐藏指针。
  - 当 `_overlay_mode == NONE` 时整个 Legend 隐藏（验收 3.3）。
  - _需求：3.1、3.2、3.3、3.4_

- [ ] 9. 控制台状态双向同步 & 未生成地图兜底
  - 在 `debug_console.gd._on_visibility_changed` 与 1Hz Timer 里调用 `refresh_from_state()`，从 `ClimateProfile` / `HexRenderer` / `main._current_map` 读回当前开关真值并刷新所有 CheckBox/滑条，避免 F6/F8 修改后 UI 脱节（验收 4.7）。
  - `main._current_map == null` 时把"诊断动作"按钮与 Overlay 切换按钮置灰，并在置灰的 tooltip 显示"请先生成地图"（验收 6.1）。
  - Overlay shader 加载失败 / bake 报错时：`_overlay_mode` 强制回退 NONE、DebugConsole 在 Overlay 分组上方插入一行红色 Label "overlay disabled: <err>"（验收 6.5）。
  - _需求：4.7、6.1、6.5_

- [ ] 10. 手动 QA 清单 + 性能回归验证
  - 在 `.codebuddy/plan/data-overlay-debug-console/` 目录下新增 `qa-checklist.md`，按需求编号逐条列出手动验证步骤（每个 overlay 通道一截图、快捷键切换、pause 冻结 Telemetry、R 重生成保留模式、快速连切 overlay 无残影等）。
  - 复用现有 `perf_sampler` 做对比：关闭/开启 Debug 控制台 + Overlay=NONE 两种状态下，用 `DebugConsole` 里的 Telemetry 记录 30 秒平均 `fast_tick` 毫秒，写入 QA 文档确认偏差 ≤ 0.3ms（成功标准 3）。
  - 对每个 overlay 通道跑一轮"生成地图 → 切换通道 → 暂停 → 查看色带 & Telemetry 数值合理性"闭环。
  - _需求：成功标准全量、1.3、6.4_

---

## 执行顺序建议

- 1 → 2 → 3 形成 **Overlay 渲染骨架**，可以独立 demo 一个 TEMPERATURE 通道。
- 4 → 5 → 6 → 7 形成 **Debug 控制台骨架**，逐步填充分组。
- 8、9 为**周边与健壮性**，可在骨架跑通后补。
- 10 为**验收**，在其它任务都完成后执行。
