# 地图 VFX 位图

两张位图均由内置 imagegen 工具生成，2026-10-18。保留生成原图；不依赖用户目录。
项目导入限制为 512px 并开启 mipmap，细节在缩小时平滑降级；PNG 源图保留原分辨率。
图标另复用现有 Font Awesome 字体。

## settlement_dust.png（透明 RGBA）

最终提示词：

> Use case: stylized-concept. Asset type: production game VFX texture, square, transparent RGBA cutout. A single isolated soft radial puff of warm ivory and muted antique gold dust, seen from directly above, wispy irregular translucent edges and a few tiny dust flecks, delicate painterly volumetric smoke with luminous scattered brass dust grains, historical strategy atlas aesthetic, brighter center but no solid disc. Centered with generous transparent padding on all four sides. No environment, no ground, no frame, no symbols, no text, no objects, no hard outlines, no dark background, no explosion or fire. Must be genuinely transparent, with soft alpha fading to zero. Intended to render at 40 to 100 pixels across over terrain, understated natural warm earth dust.

## frontier_grain.png（不透明灰度材质）

最终提示词：

> Use case: stylized-concept. Asset type: seamless grayscale tileable game material texture, square. A flat orthographic scanned texture of finely weathered engraved cartographic ink and brushed mineral pigment on rough paper: very fine irregular stipple grains, subtle longitudinal dry-brush scratches, faint granular worn flecks. Neutral medium gray base with restrained charcoal and ivory microtexture, low contrast, uniform lighting, visually even density. No objects, no borders, no text, no symbols, no shadows, no directional lighting, no folds, no decorative ornament, no large stains. Perfectly seamless on all four edges. This will be recolored and lit in a strategy game's political frontier ribbon shader; prioritize readable fine grain even at small scale.
