# Web 拆包 / 懒加载（`#3`）

状态：**POC 已通过**（Godot 侧机制实测可行，浏览器侧那一步有引擎源码依据但还没在真浏览器里跑过）。
本文记录机制、实测数据、候选切分和落地步骤，避免下次重新摸一遍。

---

## 1. 为什么必须拆

Web 外壳只会自动下载 `GODOT_CONFIG.pck` 里那一个包：

```
const GODOT_CONFIG = {..."pck":"ProjectKeynes.pck"...}
engine.startGame({ onProgress: ... })
```

`ProjectKeynes.html` 里连 `fileSizes` 都写死了 `ProjectKeynes.pck: 92445516`，
所以**整包下完才开始跑第一帧**。当前 release 包（2026-10-31 构建）首屏要下：

| 文件 | 字节 | 占比 |
|---|---|---|
| `ProjectKeynes.pck` | 88.16 MB | 60% |
| `ProjectKeynes.side.wasm` | 38.47 MB | 26% |
| `libdots_ext.web.template_release.wasm32.wasm` | 12.61 MB | 9% |
| `ProjectKeynes.js` | 5.46 MB | 4% |
| `ProjectKeynes.wasm` | 1.53 MB | 1% |
| 合计 | **146.23 MB** | |

引擎/GDExtension 那 52 MB 是固定的（能做的只有压缩，见 `#1`）。能"不下"的只有 pck 里的内容。

## 2. 机制：第二个 pck 怎么在运行时挂上来

引擎 js 里已经给了一条现成的桥（`ProjectKeynes.js`，拖拽文件用的就是它）：

```js
Module["copyToFS"] = GodotFS.copy_to_fs;   // engine.rtenv.copyToFS(path, buffer)
```

拖拽路径用的也是 `/tmp/...` 绝对路径，说明 **Godot 的 FileAccess 在 web 上能读 wasm 虚拟
文件系统里的绝对路径**。所以内容包的加载是三步：

```js
// 1. 浏览器里把 content.pck 下下来（fetch / XMLHttpRequest / Streams 都行）
const buf = await (await fetch('ProjectKeynes.content.pck?br')).arrayBuffer();
// 2. 写进 wasm 的虚拟 FS
engine.rtenv.copyToFS('/tmp/ProjectKeynes.content.pck', new Uint8Array(buf));
```

```gdscript
# 3. GDScript 侧挂上去，之后 res:// 里的资源按普通方式 load() 即可
if not ProjectSettings.load_resource_pack("/tmp/ProjectKeynes.content.pck", true):
    push_warning("content pck 挂载失败，走回退路径")
```

### POC 验证了什么（headless，可复现）

`tools/web_pack_split_probe.gd` 用 `PCKPacker` 打一个含 `res://pk_content_probe/marker.tres`
的小包，挂载前 `ResourceLoader.exists()` 为 false，挂载后为 true 且 `load()` 拿得到资源：

```
python 无关；直接跑：
Godot_v4.6.2-stable_win64_console.exe --headless --path Project/project-keynes \
    --script res://tools/web_pack_split_probe.gd
```

输出（2026-11-01 实跑，exit=0）：

```
[poc] content pck written: user://pk_content_probe.pck (328 bytes)
[poc] before mount: ResourceLoader.exists(res://pk_content_probe/marker.tres) = false
[poc] ProjectSettings.load_resource_pack -> true
[poc] after mount:  ResourceLoader.exists(res://pk_content_probe/marker.tres) = true
[poc] load(res://pk_content_probe/marker.tres) -> ...:<Gradient#...>
[poc] PASS: 内容包可以运行时挂载，包内资源直接 load() 可用
```

**踩过的坑**：包内素材必须是**不需要 import** 的资源（`.tres`/`.tscn`）。第一次用
`icon.svg` 验证时挂载成功但 `ResourceLoader.exists()` 仍为 false —— 因为 `res://icon.svg`
是靠 `.import` 重映射才可加载的，裸 svg 进包不等于可加载。拆包选素材时要记住这条：
**被拆走的原始导入源（png/ogg/ttf）在内容包里同样需要 `.import` + 引入产物一起带上**，
而 `.godot/imported/*` 本身是可加载的产物，搬过去没问题。

**已验证（2026-11-01，selenium + Chrome 156，`tmp/web_copytofs_probe.py`）**：

```
[browser] engine.rtenv.copyToFS available: True
[browser] result: {"bytes": 92445516, "copyMs": 50, "fetchMs": 6821, "head": [71,68,80,67,...], "heapMB": 286}
[browser] expected 92445516 bytes, magic GDPC -> PASS
```

也就是说 88 MB 的 pck 走 `copyToFS` 进 wasm FS 只要 **50 ms**，堆 286 MB 没炸。
**结论：不需要为了性能把 content 包硬切成 ≤8 MB 的小包**（按功能拆仍然值得，理由是"按需下载"，
不是"单包太大"）。剩下的 6.8 s 是本地 fetch 的下载时间，也就是将来 content 包本身的下载时间。

## 3. 切分预算（`tmp/web_split_budget.py` 按路径规则算出来的）

今天在发的那个 88.16 MB 包：

| | 字节 | 条目 | 占比 |
|---|---|---|---|
| boot（加载屏 / 菜单 / 第一帧世界就要） | 52.19 MB | 3522 | 59.5% |
| content（进菜单后按需） | 35.56 MB | 472 | 40.5% |

content 侧大头：`resource_art` 的 4 张图集引入产物 22.76 MB、编年史 3.44 MB、物品图标 1.56 MB、
贸易车辆 1.10 MB、菜单英雄图集 0.88 MB、HUD 图集 0.80 MB、收藏卡框 0.78 MB……

按当前资产集（含今天的无损探测包）算：boot 167.66 MB / content 97.12 MB（36.7%）。

**结论**：把 content 拆出去，首屏 pck 从 79.7 MB（`#1/#4/#5` 之后）掉到约 **44–46 MB**，
再叠 brotli 大约 **35–38 MB** 上线路由。这是 5 项里唯一"能不下"的收益。

## 4. 候选切分（按优先级）

1. **音乐（今天的资产集里新出现，18.16 MB / 29 条 `.oggvorbisstr`）** —— 最该拆：进游戏前
   一首都不需要，且天然可以按时代懒加载。`assets/audio/native/music/` 四首实测
   stone 180s@214kbps、agrarian 172s@205kbps、kingdom 166s@195kbps、empire 165s@188kbps
   （各 3.7–4.6 MB）。目标"每首 ≤2 MB"需要 ~90 kbps，必须**从母带重编**；但仓库里
   `Audio/Sources/` 只有 UI/events/kenney/starninjas，`Audio/*.wav` 是 FMOD 的
   `stem_*`（每首 5 track × 20 MB），**没有逐曲成品母带** → 按"没有母带就别二次编码"，
   现阶段**只做延迟加载，不动编码**。真要压：用 5 条 stem 混一版静态母带再用
   `ffmpeg -c:a libvorbis -q:a 3`（本机 ffmpeg 可用），这是内容决策。
2. **`assets/textures/resource_art/*`（22.76 MB）** —— 16 层地表 + 树冠 + 动物图集，
   世界第一帧的理想状态要它，但可以先给一版低分辨率占位（或用 `#4` 的降档版本）再异步补高清。
3. **编年史 / 意识形态 / 菜单英雄 / 卡牌（合计约 8 MB）** —— 开面板才用，100% 可拆。
4. **加载屏材质** 不进 content（加载屏自己要显示），已在 `#5` 处理成 1.33 MB。

## 5. 落地步骤（还没做，建议排期）

1. **加一个 Web "content" 导出预设**：`export_filter=all_resources` +
   `exclude_filter` 把 content 规则（见 `tmp/web_split_budget.py` 的 `RULES`）反过来写；
   boot 预设则排除 content 路径。两个预设共用同一套 native/字体/纹理钩子。
2. **构建脚本**：导出 boot 包后，用 `godot --headless --export-pack "WebContent" <path>` 出
   `ProjectKeynes.content.pck`，再用 `tools/serve_web.py --precompress` 一起压。
3. **运行时**：`scripts/game/` 里加一个 `content_pack_loader.gd`：
   - 菜单出现后 `await` 一次 fetch（带 `?_log` 事件，见 `scripts/game/web_telemetry.gd`，
     事件名建议 `content_pack_begin/done/fail`，这样 `tmp/web_events.jsonl` 还能看出阶段）；
   - `engine.rtenv.copyToFS('/tmp/ProjectKeynes.content.pck', bytes)`；
   - `ProjectSettings.load_resource_pack(...)`；
   - **失败回退**：拿不到就保持现有行为（相关面板显示"资源未就绪"或退回低清占位），
     绝不能因为内容包缺失而卡住主循环。
4. **验收**：`tools/serve_web_selftest.py` 之外，再加一条"boot 包里不应出现 content 路径"
   的断言（用 `tmp/pck_report.py` + `tmp/web_split_budget.py` 交叉检查）。

## 6. 风险

- `copyToFS` 是**引擎内部 API**（`Module["copyToFS"]`），Godot 升级可能改名；用
  `if (!engine.rtenv.copyToFS) { fallback }` 包一层。
- 内容包与 boot 包必须**同一次构建产出**：`res://` 里的脚本/资源 UID 一旦错位，
  `load()` 会安静地返回 null。manifest（`tools/web_manifest.py`）里应记录两个包的
  build_id 并要求一致。
- 拆包会让"资源缺失"从编译期问题变成运行期问题，必须有回退路径。
