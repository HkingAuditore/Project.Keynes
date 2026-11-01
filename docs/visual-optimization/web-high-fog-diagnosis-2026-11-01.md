# Web 高画质战争迷雾“表现很差”诊断报告（2026-11-01）

结论先行：**你看到的不是当前代码的迷雾，而是 `serve_web.bat` 默认服务的旧 release 包
`WebBuild/`（2026-10-31 23:57 构建）。该包里的 `fog_of_war.gdshader` 还是修复前版本：
web 的编译期档被钉死为 `MOBILE_QUALITY_LOW` 时 `effective_fog_quality()` 直接返回 0，
所以即使玩家选“高画质”，迷雾仍然只渲染 q0 的纯色平板；而同一帧里的地形已经走
PC-HIGH 程序。高精度地形 + 一块死板的灰蓝平板，就是“表现很差”的来源。**

修复已经在工作树里（未提交）+ `WebBuildDebug`（13:43）里，但**一直没进 release 包**。
本次已重新出包并顺手修掉两个 web 高画质迷雾的真实缺陷。

---

## 1. 证据链

### 1.1 你那次会话的遥测指纹 = 旧 shader

`tmp/web_events.jsonl`（2026-11-01 13:50 的浏览器会话）里的 shader 预热记录：

```
label=fog_of_war  len=34594
head=#define MOBILE_QUALITY_LOW|#define PK_SHADER_TIER_LOW|shader_type canvas_item;|render_mode blend
```

`34594 = 34540 + 54`，其中 34540 字符是 **git HEAD 版** `fog_of_war.gdshader`
（不含 `PK_WEB_FOG_RUNTIME` 分支），54 是旧 `FOG_PREFIX`。**逐字符吻合**。

当前工作树 shader 是 35203 字符（含 web 修复与本次边沿修复），预热前缀 81 字符，
对应 `len=35284`。两者不可能是同一份源码。

### 1.2 用同一个浏览器脚本重放两个包（headless Edge + Selenium，deterministic seed）

| 包 | `WebBuild/`（旧 release, 10-31 23:57） | `WebBuildDebug/`（13:43, 含修复） |
| --- | --- | --- |
| fog 预热 head | `#define MOBILE_QUALITY_LOW\|#define PK_SHADER_TIER_LOW\|shader_type ...`（无 web 宏） | `#define MOBILE_QUALITY_LOW\|#define PK_SHADER_TIER_LOW\|#define PK_WEB_FOG_RUNTIME\|shader_type ...` |
| fog 预热 len | **34594**（= 13:50 会话同值） | 34748 |
| 实际效果 | 未探索区 = 均匀灰蓝平板（q0） | 未探索区 = 有体积的云海（q2） |
| 截图 | `tmp2/fog_lead/live_shots/old_web_release_high.png` | `tmp2/fog_lead/live_shots/new_web_debug_high.png` |

URL 都是 `?autotest=1&quality=high&fog=on&seed=20260101&size=60x40&speed=1`，
同一台机器、同一 ANGLE/D3D11 路径、全新浏览器 profile。**旧包逐拍复现了你看到的平板迷雾。**

### 1.3 旧包为什么高画质还是 q0

`player_game._shader_quality_define_from_setting()` 在 web 上返回固定的
`MOBILE_QUALITY_LOW`（编译期档换档 = 换 program = 换驱动缓存，只能钉死一档）。
旧 `fog_of_war.gdshader`：

```glsl
int effective_fog_quality() {
#if defined(MOBILE_QUALITY_LOW)
    return 0;                 // ← web 永远走这里：运行时 visual_quality 完全被忽略
...
```

工作树修复（`PK_WEB_FOG_RUNTIME`）让 web 忽略编译期档、按运行期 uniform 夹到 q2：

```glsl
#if defined(PK_WEB_FOG_RUNTIME)
    return min(fog_quality, 2);   // visual_quality=2 → q2
```

同一份修复也补进了 `web_shader_warmup.gd` 的预编译条目，避免进世界后再编译一次。

---

## 2. 本次完成的工作

### 2.1 重新构建 release Web 包（部署根因）

`Build-Web.cmd`（release：native release 重建 → catalog 预烘焙 → 贴图/字体 web 压缩 →
export）已成功重出 `WebBuild/`，pck 126.35 MB。实测：

```
fog_of_war warmup fp=35284:1945552621
head=#define MOBILE_QUALITY_LOW|#define PK_SHADER_TIER_LOW|#define PK_WEB_FOG_RUNTIME|shader_type can
```

即 **预热 = 运行期**，高画质迷雾渲染 q2 云海。截图：
`tmp2/fog_lead/live_shots/rebuilt_release_high.png`。

### 2.2 修掉 web 高画质迷雾边缘的两个“mobile 档泄漏”（本次新增）

web 的编译期档固定 LOW，于是 `shader_quality.gdshaderinc` 定义的 `PK_MOBILE_ANY`
让 q2 迷雾仍走手机优化路径：

1. 边缘过渡用 **8×8 Bayer dither 选格**（屏幕门棋盘格），而不是桌面档的平滑双采样；
2. 边宽按 `MOBILE_QUALITY_LOW` 的 **0.58**，比桌面 q2 的 0.92 窄三分之一。

修改（`shaders/fog_of_war.gdshader`）：

- dither 分支加 `&& !defined(PK_WEB_FOG_RUNTIME)` → web 走平滑双采样；
- 新增 `PK_WEB_FOG_RUNTIME` 分支，按运行时 q 取 `0.68/0.82/0.92/1.0` 边宽。

真实渲染器 A/B 验证（Godot 4.6.2 Compatibility/GLES3，逐字节同前缀、同 uniform）：

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| web q2 fog vs desktop q2 像素差 | 0.110649（可见棋盘） | **0.000000（逐像素相同）** |
| 边界观感 | 8×8 方块 dither | 平滑渐变 |

对比图：`tmp2/fog_lead/live_shots/compare_fog_rim_before_after.png`。

### 2.3 修掉 GDScript 与 shader 的质量档不一致（潜在地形早退死斑）

`FogOfWarLayer.effective_quality()` 原来仍按编译期 tier 夹：web 返回
`min(3, cap=0)=0`，但 shader 实际画 q2。`supports_terrain_early_out()` 因此为 true ——
一旦 `fog_early_out_enabled` 被打开，主地形会用早退常量色画未探索区，而迷雾实际是
半透明云缘，会露成死斑。现在 web 侧 cap=2，与 shader 逐档一致。

### 2.4 总对比图

`tmp2/fog_lead/live_shots/compare_fog_before_after.png`（左：旧包平板；右：重出包云海）。

---

## 3. 怎么验证 / 使用

1. 直接重跑 `serve_web.bat`（默认 root = `WebBuild/`，端口 8060），**强制刷新**
   （Ctrl+F5 或清缓存；旧包 pck 315 MB → 新包 126 MB，缓存命中旧 pck 就会看到旧画面）。
2. 画质设置选“高”；若要 PC-HIGH 完整地形，用 `?quality=high` URL 启动（boot 期决定）。
3. 验收指纹（页面遥测 `warmup_plan`，或看 `tmp/web_events.jsonl`）：

   - 正常：`fog_of_war len=35284`，head 含 `#define PK_WEB_FOG_RUNTIME`
   - 仍旧包 / 缓存：`len=34594`，head 无该宏

## 4. 未处理但相关的相邻问题（与迷雾无关）

高画质（`?quality=high`）在 web 上进入世界时仍有一次 **24–42 s 的主线程冻结**：
植被的 `FAR_ONLY + DETAIL_FAMILY_BATCH` 家族/阴影变体没有进 web 预热清单
（运行期 `veg_family` fp=370:2203317790、`veg_shadow` fp=315:3269185564 均不在
`warmup_plan` 里），ANGLE 首次编译即冻帧。建议后续把这两个变体补进
`ShrubLayer.web_warmup_shader_codes()` / `WebShaderWarmup`，或收敛 HIGH 档植被变体组合。

## 5. 涉及文件

- 修复：`Project/project-keynes/shaders/fog_of_war.gdshader`（+21/−6 行，含此前未提交的 `PK_WEB_FOG_RUNTIME` 分支）
- 修复：`Project/project-keynes/scripts/rendering/fog_of_war_layer.gd`（`effective_quality()` 与 shader 对齐）
- 此前未提交、本次一并出包的修复：`web_shader_warmup.gd` 的 fog 预热前缀、`fog_of_war_layer.gd` 的 `PK_WEB_FOG_RUNTIME` 注入
- 构建产物：`WebBuild/`（release，已重出）；`WebBuildDebug/`（13:43 debug，已含修复）

### 证据与产物路径

| 内容 | 路径 |
| --- | --- |
| 旧包 vs 新包迷雾对比 | `tmp2/fog_lead/live_shots/compare_fog_before_after.png` |
| 边沿 dither 修复前后 | `tmp2/fog_lead/live_shots/compare_fog_rim_before_after.png` |
| 旧包实拍（平板） | `tmp2/fog_lead/live_shots/old_web_release_high.png` |
| 重出包实拍（云海） | `tmp2/fog_lead/live_shots/rebuilt_release_high.png` |
| live 遥测对照 | `tmp2/fog_lead/live_compare_result.json`、`verify_rebuilt_result.json` |
| 渲染器 A/B 探针源码 | `Project/project-keynes/tmp/fog_rim_ab.gd`；输出 `fog_probe_out/fog_rim_ab_{before,after}.png` |
| 独立复核（原生 Compatibility 逐字节注入 web 前缀） | `tmp2/fog_diag/REPORT.md` + `shots/` |
| 着色器路径静态审计 | `tmp/fog_audit/REPORT.md` |
