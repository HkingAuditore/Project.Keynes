# 建筑视觉图集资产

正俯视、扁平几何纯色。与 `ShrubLayer` 的程序化植被造型同一套视觉语言：低多边形轮廓、
少量纯色色阶、不写实、无渐变厚涂。

## 目录

- `source/` — 72 个作者 SVG（`<era_band>_<archetype>_v<variant>.svg`）。美术可直接替换。
- `generated/` — `building_albedo.png` 与 `building_surface.png` 两张 12×6 图集。
- `building_visual_manifest.json` — 图集几何、通道语义、时代带映射、源与输出 sha256。

## 硬约束

1. **不要在资产里烘焙阴影。** 假阴影属于 `building_shadow` 解析 pass。manifest 的
   `baked_shadow` 必须是 `false`，`tests/building_visual_atlas_test.gd` 会检查画面内是否
   出现低 alpha 暗色裙边。
2. **朝向固定。** 正俯视，地基贴在图标下沿，屋脊是水平线（前后坡各一条扁平色带）。
   运行时不做随机旋转。
3. **保持扁平。** 每格只用调色板里的少量纯色，不要渐变或噪声。测试会用
   distinct tone ratio < 0.06 拦住写实化。
4. **索引不可变。** `index = art_era_band * 18 + archetype * 3 + variant`，
   `column = index % 12`、`row = index / 12`。C++ baker、GDScript fallback 与
   `building_compound.gdshader` 三处共享这个公式。
5. **同一时代带内 18 个轮廓必须互相可区分**，不能靠时代配色蒙混过关。
6. **四个时代带之间也要有几何差异**（early 0–1 / masonry 2–5 / industrial 6–7 /
   modern 8–10）。断点与 `_style_palette` 一致；只换配色等于没做区分。
7. **远景可读性优先。** 建筑在战略镜头下只有 30–40px，同心圆一类图形会读成靶心。
   优先用横向色带、明确轮廓和打破对称的元素（坡道、烟囱、附属体）。

## surface 通道语义

| 通道 | 含义 |
| --- | --- |
| R | 朝上表面的积雪接受度（屋顶高、墙面接近 0） |
| G | 湿润响应 |
| B | 窗光自发光 |
| A | 环境遮蔽 / 占位辅助 |

## 重新生成

```powershell
python tools\building_visuals\author_building_atlas.py
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --headless --path Project\project-keynes --import
& 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' --headless --path Project\project-keynes --script res://tests/building_visual_atlas_test.gd
```

手改 SVG 后用 `--from-svg` 走 Inkscape 光栅化（缺少 Inkscape CLI 会直接失败，不静默退化）。

生成的 PNG 需要 `mipmaps/generate=true`：建筑在远景会缩到很小，没有 mipmap 会闪烁。
