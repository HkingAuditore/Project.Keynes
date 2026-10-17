class_name TechnologyTreeArt
extends RefCounted

## Papercut / handscroll bitmaps for the technology tree and overview canvases.
## Textures live in res://assets/ui/technology_tree_v1/ (see its README). All
## drawing is immediate-mode on the caller's CanvasItem: no nodes, no shaders,
## no per-frame allocation beyond the cached textures below.

const ROOT := "res://assets/ui/technology_tree_v1/"
const CARD_KNOWN := ROOT + "card_known.png"
const CARD_UNKNOWN := ROOT + "card_unknown.png"
const CARD_SELECTED := ROOT + "card_selected.png"
const CARD_MILESTONE := ROOT + "card_milestone.png"
const ERA_SCROLL := ROOT + "era_scroll.png"
const LANE_RIBBON := ROOT + "lane_ribbon.png"
const LANE_STRIP := ROOT + "lane_strip.png"
const CANVAS_PAPER := ROOT + "canvas_paper.png"
## Horizontal cap widths in texture pixels [left, right]; caps keep their aspect
## when the plate is drawn at a different height, so notches/rollers never smear.
const CAPS := {
	CARD_KNOWN: Vector2(34.0, 34.0),
	CARD_UNKNOWN: Vector2(34.0, 60.0),
	CARD_SELECTED: Vector2(34.0, 34.0),
	CARD_MILESTONE: Vector2(56.0, 56.0),
	ERA_SCROLL: Vector2(52.0, 52.0),
	LANE_RIBBON: Vector2(18.0, 48.0),
}
## Transparent shadow/padding around each plate's paper face, as a fraction of
## the drawn height. Drawing expands by it so the face matches the hit rect.
const BLEED := 0.06

static var _cache := {}


static func texture(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var loaded: Texture2D = null
	if ResourceLoader.exists(path):
		loaded = load(path) as Texture2D
	_cache[path] = loaded
	return loaded


static func domain_emblem(domain_id: String) -> Texture2D:
	return texture(ROOT + "domain_%s.png" % domain_id) if not domain_id.is_empty() else null


## Seal for research states that carry a distinct bitmap (unknown / queued /
## pending / completed). Available and locked keep the icon-font glyph.
static func state_seal(state: int, known: bool = true) -> Texture2D:
	if not known:
		return texture(ROOT + "state_unknown.png")
	match state:
		3: return texture(ROOT + "state_queued.png")
		4: return texture(ROOT + "state_pending.png")
		5: return texture(ROOT + "state_completed.png")
	return null


## Draws a plate into `rect` using height-proportional horizontal caps.
## Returns false when the bitmap is missing so callers can fall back.
static func draw_plate(canvas: CanvasItem, path: String, rect: Rect2,
		modulate: Color = Color.WHITE, bleed: bool = true) -> bool:
	var tex := texture(path)
	if tex == null or rect.size.y <= 0.0:
		return false
	var target := rect.grow(rect.size.y * BLEED) if bleed else rect
	var tex_size := tex.get_size()
	var caps: Vector2 = CAPS.get(path, Vector2(tex_size.y * 0.3, tex_size.y * 0.3))
	var scale := target.size.y / tex_size.y
	var left := caps.x * scale
	var right := caps.y * scale
	# Very narrow plates shrink their caps evenly instead of overlapping.
	var budget := target.size.x * 0.48
	if left > budget or right > budget:
		var shrink := budget / maxf(left, right)
		left *= shrink
		right *= shrink
	var mid := maxf(0.0, target.size.x - left - right)
	var h := target.size.y
	canvas.draw_texture_rect_region(tex, Rect2(target.position, Vector2(left, h)),
		Rect2(Vector2.ZERO, Vector2(caps.x, tex_size.y)), modulate)
	canvas.draw_texture_rect_region(tex,
		Rect2(target.position + Vector2(left, 0.0), Vector2(mid, h)),
		Rect2(Vector2(caps.x, 0.0), Vector2(tex_size.x - caps.x - caps.y, tex_size.y)),
		modulate)
	canvas.draw_texture_rect_region(tex,
		Rect2(target.position + Vector2(left + mid, 0.0), Vector2(right, h)),
		Rect2(Vector2(tex_size.x - caps.y, 0.0), Vector2(caps.y, tex_size.y)), modulate)
	return true


## Tiles the rice-paper backdrop over `rect`, anchored to `origin` so panning
## moves the paper with the content instead of sliding underneath it.
static func draw_backdrop(canvas: CanvasItem, rect: Rect2, origin: Vector2,
		modulate: Color = Color(1.0, 1.0, 1.0, 0.85)) -> bool:
	var tex := texture(CANVAS_PAPER)
	if tex == null:
		return false
	var tile := tex.get_size()
	var start := Vector2(
		origin.x + floorf((rect.position.x - origin.x) / tile.x) * tile.x,
		origin.y + floorf((rect.position.y - origin.y) / tile.y) * tile.y)
	# A handful of 512px quads (typically 6-9) batch into one draw; looping avoids
	# requiring texture_repeat on the CanvasItem, which would bleed into plates.
	var y := start.y
	while y < rect.end.y:
		var x := start.x
		while x < rect.end.x:
			canvas.draw_texture_rect(tex, Rect2(Vector2(x, y), tile), false, modulate)
			x += tile.x
		y += tile.y
	return true


static func draw_icon(canvas: CanvasItem, tex: Texture2D, center: Vector2, diameter: float,
		modulate: Color = Color.WHITE) -> bool:
	if tex == null:
		return false
	var tex_size := tex.get_size()
	var scale := diameter / maxf(tex_size.x, tex_size.y)
	var draw_size := tex_size * scale
	canvas.draw_texture_rect(tex, Rect2(center - draw_size * 0.5, draw_size), false, modulate)
	return true
