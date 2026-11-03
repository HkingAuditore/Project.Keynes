# Military formation v4 image prompts

Generated from `tools/military/formation_v4_prompts.py`.
The v4 contract fixes the frame registration instead of the body silhouette,
so adjacent frames may show large pose changes without breaking atlas cells.

## foot / idle

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

IDLE beat sequence: 1 grounded rest; 2 one shoulder lifts with an inhale; 3 the nearest shield settles outward; 4 the rear spearman checks east with a small shield tilt; 5 shoulders compress on the exhale; 6 the lead spear tip lifts; 7 the shield rank settles; 8 a half-breath pose offset from frame 1 for a clean loop.
```

## foot / move

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

MOVE beat sequence: 1 contact with the lead shield thrust east; 2 low compression and tight shield overlap; 3 rear rank swings outward and dust trails southwest; 4 lead rank surges east with a wide spear-point wedge; 5 opposite contact with the front spear fully extended; 6 the squad springs apart and shields separate; 7 rear rank closes while dust curls west; 8 half-step pre-contact offset from frame 1.
```

## foot / attack

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

ATTACK beat sequence: 1 already braced with shields locked and spears drawn west; 2 maximum coil and compression; 3 explosive east lunge with dust kick; 4 every spear reaches maximum east extension; 5 impact hold with stretched formation and wide shields; 6 rebound west with shields bouncing apart; 7 dust trails west and the squad reforms; 8 neutral guard.
```

## foot / hit

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

HIT beat sequence: 1 braced guard at contact; 2 rear shield slams inward and a spear jerks upward; 3 the wall buckles west with an east-edge dust burst; 4 maximum stagger with shields splayed; 5 spears swing back down; 6 the rear rank reforms first; 7 the front shield locks back into line; 8 restored neutral guard.
```

## mounted / idle

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

IDLE beat sequence: 1 grounded guard; 2 one horse shifts left while a rider shield tilts; 3 tails and mane swing west; 4 lance tops lean east; 5 the other horse settles and its rider checks east; 6 tack compresses and shields rotate; 7 tails settle; 8 nearly frame 1 for a clean loop.
```

## mounted / move

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

MOVE beat sequence: 1 contact with one horse stretched and one compressed; 2 deepest compression with riders pitched forward and dust west; 3 both horse backs surge east and the pair lengthens; 4 airborne extension with tails whipping west; 5 opposite contact with horse spacing swapped; 6 compression with overlapping shields; 7 second surge; 8 half-step pre-contact pose for a continuous gallop.
```

## mounted / attack

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

ATTACK beat sequence: 1 charge-ready with lances drawn west; 2 maximum coil with horses bunched and riders crouched; 3 explosive east lunge; 4 full lance extension with stretching horses and a west dust burst; 5 maximum impact hold with riders leaning far forward; 6 west rebound with lance tips lifting; 7 dust dissipates and formation reforms; 8 near-neutral return guard.
```

## mounted / hit

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

HIT beat sequence: 1 compressed guard at contact; 2 horses recoil west and riders duck; 3 horses splay diagonally, shields swing edge-on, lances jerk upward and dust bursts east; 4 uneven west stagger with tails flung; 5 counter-bounce with one lance crossed over the formation; 6 rear horse reforms first; 7 front horse settles; 8 restored guard.
```

## artillery / idle

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact paired antique field-cannon token with two carriages and crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings, hat crowns and shoulder tops. Never show carriage side walls or upright bodies.

IDLE beat sequence: 1 neutral ready; 2 left wheel settles and a crew shoulder shifts; 3 the right carriage rocks opposite; 4 a barrel top rises while rope and linstock sway; 5 crew turns toward east; 6 wheel spokes rotate visibly; 7 carriages settle; 8 nearly frame 1 for a clean loop.
```

## artillery / move

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact paired antique field-cannon token with two carriages and crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings, hat crowns and shoulder tops. Never show carriage side walls or upright bodies.

MOVE beat sequence: 1 wheels contact ground; 2 carriages pitch down and crew bunch; 3 wheels surge east with strong spoke rotation and west dust; 4 maximum rocking with one carriage leading; 5 opposite wheel contact and barrel counter-sway; 6 second push with stronger dust; 7 crew repositions; 8 half-step pre-contact pose.
```

## artillery / attack

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact paired antique field-cannon token with two carriages and crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings, hat crowns and shoulder tops. Never show carriage side walls or upright bodies.

ATTACK beat sequence: 1 braced with touch-hole smoke and crew crouched; 2 maximum coil with barrels pulled west; 3 first cannon fires with east muzzle flash and carriage recoil; 4 second cannon joins with both barrels recoiled; 5 maximum east smoke cloud and carriage shock; 6 residual smoke and crew rebound; 7 smoke clears while wheels reset; 8 near-neutral idle.
```

## artillery / hit

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact paired antique field-cannon token with two carriages and crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings, hat crowns and shoulder tops. Never show carriage side walls or upright bodies.

HIT beat sequence: 1 braced; 2 impact compresses the lead carriage; 3 carriage skews west, one wheel lifts, a barrel veers east, crew ducks and wood splinters; 4 deeper recoil jolts the second carriage; 5 loose equipment swings on rebound; 6 one crew side recovers; 7 wheels and barrel realign; 8 restored neutral guard.
```

## armored / idle

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

IDLE beat sequence: 1 neutral engine idle; 2 one turret checks slightly north while an antenna sways; 3 suspension settles and track texture shifts; 4 the second turret scans east; 5 engine tremble compresses the hull roof; 6 antennas swing back; 7 turrets settle neutral; 8 nearly frame 1 for a clean loop.
```

## armored / move

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

MOVE beat sequence: 1 tracks contact and hulls pitch down; 2 suspension compresses with dust starting west; 3 strong east surge with long west dust plumes; 4 one tank visibly leads and yaws 2-4 degrees; 5 opposite track contact with turrets counter-swaying; 6 second surge and larger dust; 7 hulls level; 8 half-step pre-contact pose.
```

## armored / attack

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

ATTACK beat sequence: 1 braced with guns laid east; 2 turrets and hulls coil slightly west; 3 first cannon fires with a bright east flash and visible recoil; 4 second cannon joins with both barrels recoiled; 5 maximum east smoke cloud and hull shock; 6 residual smoke with turrets rebounding; 7 barrels return east; 8 near-neutral ready pose.
```

## armored / hit

```text
Use case: image-to-image production game sprite action sheet.
Reference role: reference image A locks the unit identity, material treatment, hand-painted scissor-cut paper miniature finish and strict top-down camera. Do NOT copy its near-static poses.

Create a genuinely transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, eight sequential frames read left-to-right across the top row, then left-to-right across the bottom row.

Camera: strict 90-degree vertical orthographic overhead/zenith map camera looking straight down. North is up. EAST IS RIGHT. No perspective, no side view, no three-quarter view, no horizon. All bodies, weapons and effects remain flat in the horizontal map plane.

Animation contract: pose-to-pose animation at 8 fps, not subtle micro-motion. Keep one FIXED FRAME REGISTRATION and one stable overall unit scale. The body, chassis, weapons and effects may visibly travel, compress, stretch, yaw, recoil, separate and reform inside a centered 80 percent safe area. Do not recenter or rescale individual frames. At 48-64 px, neighboring frames must be distinguishable by silhouette alone. Use three strong beats: preparation, action peak, and recovery.

Framing: leave a large fully transparent gutter around every cell and around the complete sheet. No body, weapon, dust, flash or effect may touch or cross a cell boundary. The union of all eight frames must stay within about 1.30x the neutral silhouette envelope. Keep enough transparent perimeter for fixed-cell cropping.

Readability: make the pose delta roughly 2-3 times the reference. Use large changes in whole-body spacing, stance, facing details, weapon projection, wheels, recoil, dust and smoke. Do not count a tiny breathing shift or a changed highlight as a new frame.

Background: genuine RGBA transparency, no floor, no ground plane, no scenery, no baked cast shadow.

Avoid: copied or near-identical frames, subtle idle-like motion, perspective, side view, three-quarter view, visible faces, vertical jump, oblique cast shadow, SVG/vector-flat icon style, pixel art, low-poly 3D, glossy plastic, letters, numbers, borders, grid lines, watermark, checkerboard.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

HIT beat sequence: 1 braced hull pair; 2 impact compresses one tank and throws sparks; 3 maximum break with west hull shift, 3-5 degree yaw, one turret knocked off east and track dust; 4 second tank absorbs the rebound; 5 antennas and loose gear swing; 6 rear tank realigns first; 7 barrel and turret return east; 8 restored neutral guard.
```
