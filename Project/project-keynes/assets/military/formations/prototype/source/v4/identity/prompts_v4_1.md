# Military formation v4.1 identity-board prompts

Reference A for every prompt is the matching canonical eight-cell
identity board generated from one model-created unit master.

## foot / idle

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

Facing contract: Preserve the east-facing canonical formation while changing weight, shield angles, horse stance, wheel tremor, turret scan or antenna sway. Frame 8 is a half-breath pose near frame 1, not an identical copy.

IDLE beat sequence: 1 grounded rest; 2 one shoulder lifts with an inhale; 3 the nearest shield settles outward; 4 the rear spearman checks east with a small shield tilt; 5 shoulders compress on the exhale; 6 the lead spear tip lifts; 7 the shield rank settles; 8 a half-breath pose offset from frame 1 for a clean loop.
```

## foot / move

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

Facing contract: All members travel east but remain inside their cell anchor. Show a large contact-compression-extension-contact cycle using legs, bodies, hulls, tracks, wheels and formation spacing. Do not translate the whole unit across the cell. Frame 8 closes the gait cycle near frame 1.

MOVE beat sequence: 1 contact with the lead shield thrust east; 2 low compression and tight shield overlap; 3 rear rank swings outward and dust trails southwest; 4 lead rank surges east with a wide spear-point wedge; 5 opposite contact with the front spear fully extended; 6 the squad springs apart and shields separate; 7 rear rank closes while dust curls west; 8 half-step pre-contact offset from frame 1.
```

## foot / attack

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

Facing contract: The formation coils west, strikes or fires east, reaches a strong action peak, recoils, and returns to a neutral east-facing guard. No unit may spin away from east. Keep all effects inside the cell. Frame 8 is near-neutral.

ATTACK beat sequence: 1 already braced with shields locked and spears drawn west; 2 maximum coil and compression; 3 explosive east lunge with dust kick; 4 every spear reaches maximum east extension; 5 impact hold with stretched formation and wide shields; 6 rebound west with shields bouncing apart; 7 dust trails west and the squad reforms; 8 neutral guard.
```

## foot / hit

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact three-soldier ancient infantry squad with round shields and spears, bronze/deep-teal/warm-parchment materials. Show only helmet crowns, shoulder tops, round shield tops, spear shafts and hand tips. No visible faces.

Facing contract: The formation takes one impact from the east: compress, buckle west, stagger with at most an 8-degree local yaw, then reform east-facing. Do not flip or mirror the unit. Keep detached gear connected or inside the central safe area. Frame 8 is near-neutral.

HIT beat sequence: 1 braced guard at contact; 2 rear shield slams inward and a spear jerks upward; 3 the wall buckles west with an east-edge dust burst; 4 maximum stagger with shields splayed; 5 spears swing back down; 6 the rear rank reforms first; 7 the front shield locks back into line; 8 restored neutral guard.
```

## mounted / idle

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

Facing contract: Preserve the east-facing canonical formation while changing weight, shield angles, horse stance, wheel tremor, turret scan or antenna sway. Frame 8 is a half-breath pose near frame 1, not an identical copy.

IDLE beat sequence: 1 grounded guard; 2 one horse shifts left while a rider shield tilts; 3 tails and mane swing west; 4 lance tops lean east; 5 the other horse settles and its rider checks east; 6 tack compresses and shields rotate; 7 tails settle; 8 nearly frame 1 for a clean loop.
```

## mounted / move

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

Facing contract: All members travel east but remain inside their cell anchor. Show a large contact-compression-extension-contact cycle using legs, bodies, hulls, tracks, wheels and formation spacing. Do not translate the whole unit across the cell. Frame 8 closes the gait cycle near frame 1.

MOVE beat sequence: 1 contact with one horse stretched and one compressed; 2 deepest compression with riders pitched forward and dust west; 3 both horse backs surge east and the pair lengthens; 4 airborne extension with tails whipping west; 5 opposite contact with horse spacing swapped; 6 compression with overlapping shields; 7 second surge; 8 half-step pre-contact pose for a continuous gallop.
```

## mounted / attack

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

Facing contract: The formation coils west, strikes or fires east, reaches a strong action peak, recoils, and returns to a neutral east-facing guard. No unit may spin away from east. Keep all effects inside the cell. Frame 8 is near-neutral.

ATTACK beat sequence: 1 charge-ready with lances drawn west; 2 maximum coil with horses bunched and riders crouched; 3 explosive east lunge; 4 full lance extension with stretching horses and a west dust burst; 5 maximum impact hold with riders leaning far forward; 6 west rebound with lance tips lifting; 7 dust dissipates and formation reforms; 8 near-neutral return guard.
```

## mounted / hit

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-armored-horse cavalry squad with rider shields and lances, leather/rust/bronze/warm-parchment materials. Show only horse backs, hindquarters, manes, ears, tails, saddle tops, rider helmet crowns, shoulder tops, shield discs and lance tops. Never show a horse face profile or rider face.

Facing contract: The formation takes one impact from the east: compress, buckle west, stagger with at most an 8-degree local yaw, then reform east-facing. Do not flip or mirror the unit. Keep detached gear connected or inside the central safe area. Frame 8 is near-neutral.

HIT beat sequence: 1 compressed guard at contact; 2 horses recoil west and riders duck; 3 horses splay diagonally, shields swing edge-on, lances jerk upward and dust bursts east; 4 uneven west stagger with tails flung; 5 counter-bounce with one lance crossed over the formation; 6 rear horse reforms first; 7 front horse settles; 8 restored guard.
```

## artillery / idle

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact paired antique field-cannon token with two carriages and no visible crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings and breech hardware. Do not draw any gunner, soldier, person, head, helmet, hat, plume, shoulder, limb or red-white mascot-like figure. Keep the entire east side of both muzzles clear. Never show carriage side walls or upright bodies.

Facing contract: Preserve the east-facing canonical formation while changing weight, shield angles, horse stance, wheel tremor, turret scan or antenna sway. Frame 8 is a half-breath pose near frame 1, not an identical copy.

IDLE beat sequence: 1 grounded ready with both muzzles dark; 2 left wheel indexes one spoke while both carriage centers stay locked; 3 right wheel rotates and the rope trembles; 4 a tiny synchronized suspension dip moves both barrel tops together; 5 left wheel counter-rotates in place; 6 right wheel indexes the opposite way; 7 both pairs of spokes settle; 8 a half-notch wheel pose offset from frame 1 for a clean loop. Never fire: no muzzle flash, smoke, sparks, recoil or shell.

Critical artillery idle lock. This is a non-combat mechanical idle, not an attack or firing cycle. Keep both cannons present in every cell with exactly the same top/bottom order, horizontal and vertical spacing, shared scale and east-facing heading. Their carriage centers must not jump, slide, cross, swap or independently recenter between frames. Both muzzles and the entire east side of the sheet remain dark and clean: absolutely no muzzle flash, smoke, spark, shell, recoil or gun crew. Animate only wheel-spoke rotation, a tiny suspension rock in place, slack rope sway and top-surface highlight/compression. For this idle row these constraints supersede the generic large pose-change instruction: the sheet may contain mechanically distinct wheel poses while the paired formation remains visually locked.
```

## artillery / move

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact paired antique field-cannon token with two carriages and no visible crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings and breech hardware. Do not draw any gunner, soldier, person, head, helmet, hat, plume, shoulder, limb or red-white mascot-like figure. Keep the entire east side of both muzzles clear. Never show carriage side walls or upright bodies.

Facing contract: All members travel east but remain inside their cell anchor. Show a large contact-compression-extension-contact cycle using legs, bodies, hulls, tracks, wheels and formation spacing. Do not translate the whole unit across the cell. Frame 8 closes the gait cycle near frame 1.

MOVE beat sequence: 1 wheels contact ground; 2 carriages pitch down together; 3 wheels surge east with strong spoke rotation and west dust; 4 maximum rocking with one carriage leading; 5 opposite wheel contact and barrel counter-sway; 6 second push with stronger dust; 7 carriages realign; 8 half-step pre-contact pose.
```

## artillery / attack

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact paired antique field-cannon token with two carriages and no visible crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings and breech hardware. Do not draw any gunner, soldier, person, head, helmet, hat, plume, shoulder, limb or red-white mascot-like figure. Keep the entire east side of both muzzles clear. Never show carriage side walls or upright bodies.

Facing contract: The formation coils west, strikes or fires east, reaches a strong action peak, recoils, and returns to a neutral east-facing guard. No unit may spin away from east. Keep all effects inside the cell. Frame 8 is near-neutral.

ATTACK beat sequence: 1 braced with touch-hole smoke; 2 maximum coil with barrels pulled west; 3 first cannon fires with east muzzle flash and carriage recoil; 4 second cannon joins with both barrels recoiled; 5 maximum east smoke cloud and carriage shock; 6 residual smoke and carriage rebound; 7 smoke clears while wheels reset; 8 near-neutral idle.
```

## artillery / hit

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact paired antique field-cannon token with two carriages and no visible crew, dark-iron/bronze/ochre/warm-parchment materials. Show only barrel tops, timber carriage tops, wheel rings and breech hardware. Do not draw any gunner, soldier, person, head, helmet, hat, plume, shoulder, limb or red-white mascot-like figure. Keep the entire east side of both muzzles clear. Never show carriage side walls or upright bodies.

Facing contract: The formation takes one impact from the east: compress, buckle west, stagger with at most an 8-degree local yaw, then reform east-facing. Do not flip or mirror the unit. Keep detached gear connected or inside the central safe area. Frame 8 is near-neutral.

HIT beat sequence: 1 braced; 2 impact compresses the lead carriage; 3 carriage skews west, one wheel lifts, a barrel veers east and wood splinters; 4 deeper recoil jolts the second carriage; 5 loose equipment swings on rebound; 6 lead carriage recovers; 7 wheels and barrel realign; 8 restored neutral guard.
```

## armored / idle

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

Facing contract: Preserve the east-facing canonical formation while changing weight, shield angles, horse stance, wheel tremor, turret scan or antenna sway. Frame 8 is a half-breath pose near frame 1, not an identical copy.

IDLE beat sequence: 1 neutral engine idle; 2 one turret checks slightly north while an antenna sways; 3 suspension settles and track texture shifts; 4 the second turret scans east; 5 engine tremble compresses the hull roof; 6 antennas swing back; 7 turrets settle neutral; 8 nearly frame 1 for a clean loop.
```

## armored / move

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

Facing contract: All members travel east but remain inside their cell anchor. Show a large contact-compression-extension-contact cycle using legs, bodies, hulls, tracks, wheels and formation spacing. Do not translate the whole unit across the cell. Frame 8 closes the gait cycle near frame 1.

MOVE beat sequence: 1 tracks contact and hulls pitch down; 2 suspension compresses with dust starting west; 3 strong east surge with long west dust plumes; 4 one tank visibly leads and yaws 2-4 degrees; 5 opposite track contact with turrets counter-swaying; 6 second surge and larger dust; 7 hulls level; 8 half-step pre-contact pose.
```

## armored / attack

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

Facing contract: The formation coils west, strikes or fires east, reaches a strong action peak, recoils, and returns to a neutral east-facing guard. No unit may spin away from east. Keep all effects inside the cell. Frame 8 is near-neutral.

ATTACK beat sequence: 1 braced with guns laid east; 2 turrets and hulls coil slightly west; 3 first cannon fires with a bright east flash and visible recoil; 4 second cannon joins with both barrels recoiled; 5 maximum east smoke cloud and hull shock; 6 residual smoke with turrets rebounding; 7 barrels return east; 8 near-neutral ready pose.
```

## armored / hit

```text
Use case: image-to-image production game animation sheet edit.
Reference A is the AUTHORITATIVE identity-and-registration board. It contains exactly eight copies of the same unit in a 4-column by 2-row grid. Preserve every unit's species, member count, equipment, materials, scale and strict 90-degree vertical orthographic overhead camera. North is up. EAST IS RIGHT.

Do not redesign the unit. Do not create a different camera. Do not rotate the whole unit to another facing. All shield faces, horse heads, lances, gun barrels and vehicle noses remain east/right. Small action yaw is allowed only where the requested beat explicitly says so, and must never exceed 8 degrees. The first and second rows must use the same cell-relative anchor, scale and facing; no row offset.

Produce one transparent-background RGBA action sheet with EXACTLY 4 equal columns by 2 equal rows, read left-to-right across the top row, then left-to-right across the bottom row. Each cell is an isolated stage. Keep a large fully transparent dead band around every cell and around the whole sheet. Long weapons, wheels, tracks, smoke, dust, sparks and flashes must remain inside their own cell and must never touch or cross a cell line.

Animation is pose-to-pose at 8 fps. This is not micro-motion. Keep the same unit centered on the same fixed cell origin, but visibly change stance, compression, extension, recoil, weapon projection, horse leg spacing, wheel rotation, track pitch or formation width. At 48-64 px the eight silhouette poses must be distinguishable without relying on smoke or muzzle flash. Do not translate the complete unit across the cell, do not recenter individual frames by their alpha bounds, and do not rescale individual frames.

Use three strong beats: preparation, action peak, recovery. The final frame must return to a neutral guard that is safe to blend back to idle. Do not mirror the unit, do not turn it 90 or 180 degrees, and do not invent a second unit type.

Background: genuine RGBA transparency, no checkerboard, no floor, no scenery, no baked cast shadow, no grid lines.

Avoid: random orientation changes, mirrored horses or vehicles, side view, three-quarter view, perspective, detached body parts outside the safe area, duplicate frames, tiny breathing-only changes, effects crossing cell boundaries, letters, numbers, borders, watermark.

Subject: the compact two-tank armored token with riveted hulls, turrets, long gun barrels and top-facing tracks, gunmetal/soot/slate-blue materials. Show only hull roofs, turret roofs, engine decks, top-facing tracks, hatch discs, antennas and gun-barrel tops. Never show side walls, track side profiles or an isometric silhouette.

Facing contract: The formation takes one impact from the east: compress, buckle west, stagger with at most an 8-degree local yaw, then reform east-facing. Do not flip or mirror the unit. Keep detached gear connected or inside the central safe area. Frame 8 is near-neutral.

HIT beat sequence: 1 braced hull pair; 2 impact compresses one tank and throws sparks; 3 maximum break with west hull shift, 3-5 degree yaw, one turret knocked off east and track dust; 4 second tank absorbs the rebound; 5 antennas and loose gear swing; 6 rear tank realigns first; 7 barrel and turret return east; 8 restored neutral guard.
```
