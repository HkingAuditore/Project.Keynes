# 理念界面分层纸材 · 2026-10-26

本组使用内置 imagegen 生成。源 PNG 保留原始透明度；不包含 UI 文字、游戏数值或烘焙投影。

| 图层 | 用途 |
|---|---|
| `ivory_sheet.png` | 单张浅象牙色纸面；Godot 导入最长边 512px，`IdeologyArt` 取 `(8,16,496,309)` 区域，用 12px 对称九切片适配面板与卡片 |
| `edge_jade.png` | 珍稀卡的青绿压线边饰；中心透明，独立覆盖纸面 |
| `edge_cinnabar_gold.png` | 传世卡的朱砂／旧金边饰；中心透明，独立覆盖纸面 |
| `shaders/ui/ideology_paper_shadow.gdshader` | Godot 实时柔边圆角纸影，按卡片实际尺寸计算，单独绘制在纸面后方 |

寻常卡保留自然纸边；珍稀与传世卡使用不同的独立边饰、纸色及文字标签。
卡片底部的当前境界另读 native level，避免把稀有度与成长境界混为一谈。
边饰通过 Godot 导入器限制最长边为 512，保留原图以便再次导入。
纸面也使用 512px 导入尺度，避免原图纸边在固定九切片边距中形成过密锯齿。
StyleBox 直接读取原纹理的 region_rect，两个轴均为 stretch；不对 AtlasTexture 再做区域采样。
流派图案复用已有素材。纸面、边饰、阴影、图案、文字、动作按钮、进度条分别由引擎组合。
禁止用有不透明深色背景的整张卡图模拟投影，也不要把内容矩形当作纸影轮廓。

## 生成提示词

`ivory_sheet.png`:

> Create a single reusable blank paper texture asset for a historical grand strategy game's layered papercut UI. Landscape rectangle 3:2 aspect ratio, straight-on orthographic, perfectly flat, centered, filling 96% width and height, transparent outside. Warm light ivory handmade cotton paper, extremely subtle quiet fine fiber texture, uniformly light and readable across entire blank surface. Very restrained irregular hand-cut deckle edge only within outer 1.5% of sheet; corners near square with tiny natural paper cuts. Single paper layer ONLY, no baked cast shadow, no other objects, no border frame, no ornaments, no gold, no ribbons, no text, no glyphs, no lines, no stains, no folds, no gradient vignette, no burnt edges. This will be a nine-sliced Godot UI material: maintain even light tone and straight long edges, empty center must be quiet, all decoration assembled separately by engine. Crisp tactile Chinese cut-paper game art, matte, premium understated material. Output genuine alpha transparency outside the sheet.

`edge_jade.png`:

> A single isolated transparent FRAME OVERLAY asset for a premium historical papercut strategy game card, portrait 3:4 proportions. This is only a very slender jade-green letterpress ink border on fine cut ivory paper strips, with gently rounded near-square corners and a second fine incomplete rule just inside. Extremely understated tactile pressed ink, faint real paper fiber only in the narrow strips. Elegant crafted edition, visible material hierarchy over an ordinary blank paper card. Frame occupies outermost 4% of the portrait rectangle. The whole center (at least 88% of width, 90% of height) is completely alpha transparent, and everything outside frame is alpha transparent. No sheet filling the center, no cast shadow, no background color, no text, no numbers, no gems, no stars, no icons, no illustrations, no ribbons, no large decorative corners, no metal hardware, no black lines. Front orthographic, flat, straight rectangular aligned silhouette, fills about 94% of canvas. This overlay will be independently composited over an existing plain ivory paper face and a real-time soft shadow; the center MUST be genuinely empty transparent.

`edge_cinnabar_gold.png`:

> A single isolated transparent FRAME OVERLAY asset for a premium historical papercut strategy game card, portrait 3:4 proportions. Only a slender cinnabar-red printed paper edging with very fine irregular muted warm gold-leaf accents and tiny layered folded-paper corner joins. A precious archival edition, handcrafted quiet refinement, absolutely restrained rather than ornate fantasy. Delicately embossed fibers and physically plausible rubbed gold speckles confined to the narrow border; near-square gently rounded corners. Frame occupies only the outermost 4% of the portrait rectangle. Whole center (at least 88% width and 90% height) is completely alpha transparent; outside frame also completely alpha transparent. No central sheet, no cast shadow, no background, no text or numbers, no stars, no gemstones, no icons, no illustration, no ribbons, no big ornamental flourishes, no brass hardware, no black outline. Front orthographic flat aligned rectangle, fills about 94% of canvas. This will be a separate independently composited border layer on existing light ivory paper with a real-time blurred shadow. The center MUST be genuinely empty transparent.
