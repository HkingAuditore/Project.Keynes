"""Build Project.Keynes resource ground-cover, fauna and material art (manifest v3).

Inputs : assets/textures/resource_art/source/{flora,trace,fauna,crown,geology,ground}/<id>.png
         (AI generated, transparent background; prompts recorded in SOURCES).
Outputs: assets/textures/resource_art/
           cover_albedo.png  vertical strip, one 512x512 seamless RGBA tile per layer
           cover_normal.png  vertical strip, RG = tangent normal, B = height, A = AO
           fauna_atlas.png   vertical strip, one 512x256 layer per animal (4x2 cells of 128)
           crown_atlas.png   vertical strip: 4 tree-family layers + 1 hardscape boulder layer
                             (each 4x2 cells of 256)
           crown_normal.png  matching RG normal / B height / A AO derived from the sprites
           resource_material.png
                             two atlas layers: 0 = 8x4 albedo cells, 1 = matching
                             RG normal / B height / A AO, shared by resource props,
                             decals and lens badges
           manifest.json     v3: layer order, prompts, provenance
Godot imports the strips as Texture2DArray (importer "2d_array_texture").

Usage: python tools/resource_art/build.py [--check]
"""
from __future__ import annotations

import argparse
import json
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "assets" / "textures" / "resource_art"
SRC = ART / "source"
TILE = 512
CELL = 128
GENERATED = "2026-11-06"

COMMON = ("Seamless tileable texture, strictly orthographic top-down aerial view, realistic, natural, "
	"slightly desaturated muted colours like a painted strategy-game map, soft diffuse overcast light, "
	"very soft short shadows, gaps fully transparent, no soil, no rows, no text, no border, no perspective.")

# Ground-cover layers. Order is the Texture2DArray layer order (stable contract with the shader LUT).
# tint = gentle species hue target, tall = canopy height used for self shadow / parallax strength.
FLORA = [
	("bio.wheat", "wild emmer / einkorn wheat grass clumps with nodding golden-tan seed heads", 0.55),
	("bio.maize", "teosinte / wild maize: tall broad-leaved star-shaped clumps with small tassels", 0.85),
	("bio.rice", "wild rice marsh tussocks with drooping slender panicles", 0.50),
	("bio.potato", "wild potato mounds of compound leaves with small lilac star flowers", 0.40),
	("bio.cotton", "wild cotton shrubs with lobed leaves and open white bolls", 0.60),
	("bio.flax", "wild flax tufts, fine grey-green stems with small sky-blue flowers", 0.35),
	("bio.spice", "tropical pepper vine and ginger understory with red spikes", 0.65),
	("bio.rubber", "wild Hevea rubber tree canopy, rounded trifoliate crowns", 1.00),
	("bio.silkworm", "wild mulberry crowns with dark fruit and pale silk cocoons", 0.80),
	("bio.reed", "dense Phragmites reed bed with buff plume heads", 0.75),
	("bio.bast_fiber", "wild hemp and ramie thicket, palmate and heart leaves", 0.70),
	("bio.dye_plant", "woad, indigo and madder with yellow woad flowers", 0.45),
	("bio.medicinal_herb", "mixed wild herbs: sage, mint, chamomile, yarrow", 0.30),
]
# Single-tree crowns, top-down with alpha: 4x2 variants per family. Layer order is the
# contract with vegetation_forms.gdshaderinc (0 broadleaf, 1 conifer, 2 palm, 3 shrub).
CROWNS = [
	("broadleaf", "8 temperate broadleaf crowns (oak, beech, maple, linden), lumpy leaf clusters", 0.85),
	("conifer", "8 conifer crowns (spruce, fir, pine), star of layered needle boughs", 1.0),
	("palm", "8 palm crowns (coconut, date, fan palm), radiating fronds", 0.55),
	("shrub", "8 wild shrubs (hazel, juniper, gorse, myrtle), twiggy leaf clumps", 0.6),
]
# The fifth array layer replaces the hard, gem-like procedural hardscape rocks.
# It shares the same 4x2 sprite topology and sampler as the tree crowns.
ROCK_DECOR = {
	"path": "geology/rocks.png",
	"id": "rock.decor",
	"tall": 0.90,
	"prompt": "Eight isolated top-down weathered boulders, rough granite and sandstone, "
		"chipped silhouettes, dark fissures, sparse lichen and tiny loose chips, "
		"muted semi-realistic painted strategy-map style, transparent background",
}
CROWN_CELL = 256
MATERIAL_CELL = 128
MATERIAL_MARGIN = 8
MATERIAL_COLS = 8
MATERIAL_ROWS = 4
# Dark ground materials must stay dark under the terrain's high ambient exposure.
MATERIAL_TONE = {
	"fertile_soil": (0.16, 0.34),
	"oil": (0.06, 0.20),
	# The replacement stone source is deliberately warmer, but still needs to sit
	# at the darker end of the mineral band so it does not read as a pale cutout.
	"stone": (0.24, 0.53),
	"rock.decor": (0.24, 0.60),
}
# Grazing traces share the cover array after the flora layers.
TRACES = [
	("trace.pasture", "trampled animal paths, cropped grass, hoof-trodden dusty spots", 0.05),
	("trace.mud", "wild boar rooting: churned mud, small wallow puddles", 0.05),
	("trace.sand", "camel caravan hoof-print trails on sand", 0.02),
]
# Fauna: 4 poses x 2 coats, heads up. trace = cover layer drawn under the herd.
FAUNA = [
	("bio.horse", "wild horses, bay and dun coats", "trace.pasture"),
	("bio.sheep", "sheep, cream and grey-brown wool", "trace.pasture"),
	("bio.goat", "wild goats (ibex-like), tawny and grey-brown", "trace.pasture"),
	("bio.cattle", "wild cattle (aurochs-like), red-brown and fawn/black", "trace.pasture"),
	("bio.pig", "wild boars and spotted pigs", "trace.mud"),
	("bio.camel", "dromedary and bactrian camels", "trace.sand"),
	("bio.yak", "shaggy wild yaks", "trace.pasture"),
	("freshwater_fish", "carp, trout, pike, perch (dorsal view)", ""),
	("marine_fish", "herring, sardine, mackerel, tuna (dorsal view)", ""),
]

# Resource material atlas. The 8x4 atlas follows ResourceVisualCatalog.RESOURCES order so the
# style LUT can carry the cell id without another ordering table. Fish stay on art_fauna and
# therefore leave two transparent cells unused.
MATERIAL_IDS = [
	"timber", "stone", "fertile_soil", "arable_land", "paddy_land", "plantation_land",
	"pasture", "coal", "oil", "natural_gas", "copper_ore", "iron_ore", "gold_ore",
	"silver_ore", "salt", "saltpeter", "rare_earth", "clay", "wild_game", "",
	"bauxite", "limestone", "silica_sand", "phosphate_rock", "tin_ore", "lead_ore",
	"zinc_ore", "manganese_ore", "sulfur", "flint", "", "",
]

# Each source is a generated 4x2 / 5x2 / 4x3 sheet. `kind` selects the normal derivation:
# solid uses a silhouette dome plus cavity; ground uses the low-relief patch height.
MATERIAL_SOURCES = [
	{
		"path": "geology/stone.png", "cols": 1, "rows": 1, "kind": "solid", "tall": 0.90, "edge_px": 8.0,
		"ids": ["stone"],
		"prompt": "One top-down weathered stone outcrop, compact irregular grey-brown boulders with "
			"dark fissures and gravel, muted semi-realistic painted strategy-map style, transparent background",
	},
	{
		"path": "geology/ores.png", "cols": 4, "rows": 2, "sprite_offset": 1,
		"kind": "solid", "tall": 0.90, "edge_px": 10.0,
		"ids": ["coal", "copper_ore", "iron_ore", "gold_ore", "silver_ore", "tin_ore", "lead_ore"],
		"prompt": "Seven top-down ore outcrops: coal, copper, iron, gold, silver, tin and lead; "
			"realistic mineral texture, transparent background, orthographic, soft overcast light",
	},
	{
		"path": "geology/minerals.png", "cols": 5, "rows": 2, "kind": "solid", "tall": 0.78, "edge_px": 10.0,
		"ids": ["bauxite", "limestone", "phosphate_rock", "manganese_ore", "zinc_ore",
			"rare_earth", "flint", "salt", "saltpeter", "sulfur"],
		"prompt": "Ten top-down industrial mineral deposits: bauxite, limestone, phosphate, manganese, "
			"zinc, rare earth, flint, salt, saltpeter and sulfur; transparent background, orthographic",
	},
	{
		"path": "ground/materials.png", "cols": 4, "rows": 3, "kind": "ground", "tall": 0.22, "edge_px": 20.0,
		"ids": ["fertile_soil", "arable_land", "paddy_land", "plantation_land", "pasture", "clay",
			"silica_sand", "oil", "natural_gas", "wild_game", "timber"],
		"prompt": "Eleven top-down ground resources: fertile soil, arable soil, paddy, plantation "
			"undergrowth, pasture, clay, silica sand, oil seep, gas vent, game trail and cut timber; "
			"transparent background, orthographic, realistic natural texture",
	},
]

# Terrain tone band the vegetation must sit in (sRGB luma of terrain_materials/organic + dry_sand).
LUMA_TARGET = (0.30, 0.48)
# Keep most of the source chroma: the lit map palette is saturated, and a washed-out
# cover reads as a grey film over the terrain.
SAT_SCALE = 0.95
# Optional hue correction toward an earthy target (keeps luma); the mud source reads lavender.
HUE_TARGET = {"trace.mud": ((0.47, 0.38, 0.27), 0.70)}


def load_rgba(path: Path) -> np.ndarray:
	with Image.open(path) as im:
		return np.asarray(im.convert("RGBA"), dtype=np.float32) / 255.0


def square_crop(a: np.ndarray) -> np.ndarray:
	h, w = a.shape[:2]
	s = min(h, w)
	y, x = (h - s) // 2, (w - s) // 2
	return a[y:y + s, x:x + s]


def resize(a: np.ndarray, w: int, h: int) -> np.ndarray:
	# Premultiply so transparent white fringes never bleed into the plants.
	pm = a.copy()
	pm[..., :3] *= pm[..., 3:4]
	im = Image.fromarray((np.clip(pm, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")
	out = np.asarray(im.resize((w, h), Image.LANCZOS), dtype=np.float32) / 255.0
	al = out[..., 3:4]
	out[..., :3] = np.where(al > 1e-3, out[..., :3] / np.maximum(al, 1e-3), 0.0)
	return np.clip(out, 0, 1)


def make_seamless(a: np.ndarray) -> np.ndarray:
	"""Half-offset cross blend: the tile edges become the source interior."""
	n = a.shape[0]
	shifted = np.roll(np.roll(a, n // 2, 0), n // 2, 1)
	t = np.abs(np.linspace(-1.0, 1.0, n, dtype=np.float32))
	# Weight of the shifted copy: 1 at the original borders, 0 in the middle.
	w1 = np.clip((t - 0.55) / 0.40, 0.0, 1.0)
	w = np.maximum(w1[:, None], w1[None, :])
	w = w * w * (3.0 - 2.0 * w)
	pa = a.copy()
	pa[..., :3] *= pa[..., 3:4]
	ps = shifted.copy()
	ps[..., :3] *= ps[..., 3:4]
	out = pa * (1.0 - w[..., None]) + ps * w[..., None]
	al = out[..., 3:4]
	out[..., :3] = np.where(al > 1e-3, out[..., :3] / np.maximum(al, 1e-3), 0.0)
	return np.clip(out, 0, 1)


def luma(rgb: np.ndarray) -> np.ndarray:
	return rgb @ np.array([0.299, 0.587, 0.114], dtype=np.float32)


def hue_correct(a: np.ndarray, tint: tuple[float, float, float], amount: float) -> np.ndarray:
	out = a.copy()
	t = np.array(tint, dtype=np.float32)
	target = luma(a[..., :3])[..., None] * (t / float(luma(t)))
	out[..., :3] = np.clip(a[..., :3] * (1.0 - amount) + target * amount, 0, 1)
	return out


def tone_match(a: np.ndarray, target=LUMA_TARGET, sat=SAT_SCALE) -> np.ndarray:
	"""Pull coverage-weighted luma into the terrain band and soften saturation."""
	out = a.copy()
	al = a[..., 3]
	m = al > 0.5
	if not m.any():
		return out
	l = luma(a[..., :3])
	lo, hi = np.percentile(l[m], [5, 95])
	span = max(hi - lo, 1e-3)
	new_l = target[0] + (np.clip((l - lo) / span, -0.2, 1.2)) * (target[1] - target[0])
	grey = l[..., None]
	chroma = (a[..., :3] - grey) * sat
	out[..., :3] = np.clip(new_l[..., None] + chroma, 0, 1)
	return out


def edge_height_ramp(a: np.ndarray, edge_px: float) -> np.ndarray:
	"""Zero height outside the authored silhouette and ease it in over a few texels."""
	if edge_px <= 0.0:
		return np.ones(a.shape[:2], np.float32)
	distance = ndimage.distance_transform_edt(a[..., 3] > 0.04)
	t = np.clip(distance / max(float(edge_px), 1e-3), 0.0, 1.0)
	return (t * t * (3.0 - 2.0 * t)).astype(np.float32)


def soften_sprite_alpha(a: np.ndarray, ident: str, outward: float, inward: float,
		noise_px: float, noise_sigma: float) -> np.ndarray:
	"""Bake a stable, noisy outward+inward alpha transition into a sprite cell."""
	inside_mask = a[..., 3] > 0.35
	if not inside_mask.any():
		return a
	inside = ndimage.distance_transform_edt(inside_mask)
	outside = ndimage.distance_transform_edt(~inside_mask)
	signed = inside - outside
	rng = np.random.default_rng(zlib.crc32(ident.encode("utf-8")))
	noise = ndimage.gaussian_filter(rng.standard_normal(a.shape[:2]), noise_sigma)
	noise /= max(float(noise.std()), 1e-5)
	t = np.clip((signed + noise * noise_px + outward) / (outward + inward), 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	out = a.copy()
	out[..., 3] = t
	return out


def soften_material_alpha(a: np.ndarray, ident: str, kind: str) -> np.ndarray:
	"""Give generated material silhouettes a noisy, mip-safe alpha feather."""
	if kind == "ground":
		return soften_sprite_alpha(a, ident, outward=5.5, inward=22.0,
			noise_px=3.2, noise_sigma=4.0)
	return soften_sprite_alpha(a, ident, outward=4.0, inward=16.0,
		noise_px=2.4, noise_sigma=3.6)


def soften_rock_alpha(a: np.ndarray, ident: str) -> np.ndarray:
	"""Feather hardscape boulders so their authored silhouettes do not read as cutouts."""
	return soften_sprite_alpha(a, ident, outward=5.5, inward=24.0,
		noise_px=3.2, noise_sigma=4.2)


# A generated ground sheet often hugs the full square cell. Soil-like land patches can
# hide that against terrain, but oil and gas are also drawn over open water, where the
# square silhouette is immediately visible. Give those two cells a deterministic,
# noisy oval envelope before deriving normals.
MATERIAL_BLOB_PATCH = {
	"oil": (0.77, 0.075, 0.16),
	"natural_gas": (0.75, 0.080, 0.085),
}
# Extra-tall edge ramp for oil: its near-black albedo makes a normal-width
# silhouette read as a pasted-on cutout even after the alpha itself is soft.
MATERIAL_EDGE_PX = {
	"oil": 28.0,
}


def shape_ground_patch(a: np.ndarray, ident: str) -> np.ndarray:
	params = MATERIAL_BLOB_PATCH.get(ident)
	if params is None:
		return a
	radius, angular_noise, feather = params
	h, w = a.shape[:2]
	yy, xx = np.mgrid[0:h, 0:w]
	x = (xx.astype(np.float32) + 0.5) / max(float(w), 1.0) * 2.0 - 1.0
	y = (yy.astype(np.float32) + 0.5) / max(float(h), 1.0) * 2.0 - 1.0
	rng = np.random.default_rng(zlib.crc32(("patch:" + ident).encode("utf-8")))
	phase = rng.uniform(0.0, np.pi * 2.0, 3)
	angle = np.arctan2(y, x)
	boundary = radius + angular_noise * (
		0.58 * np.sin(angle * 3.0 + phase[0])
		+ 0.29 * np.sin(angle * 5.0 + phase[1])
		+ 0.13 * np.sin(angle * 9.0 + phase[2]))
	rough = ndimage.gaussian_filter(rng.standard_normal((h, w)).astype(np.float32), 4.0)
	rough /= max(float(rough.std()), 1e-5)
	boundary = boundary + rough * 0.025
	coverage = np.clip((boundary + feather - np.sqrt(x * x + y * y)) / (feather * 2.0), 0.0, 1.0)
	coverage = coverage * coverage * (3.0 - 2.0 * coverage)
	out = a.copy()
	out[..., 3] *= coverage
	return out


def derive_normal(a: np.ndarray, tall: float, tile: bool = True, edge_px: float = 0.0) -> np.ndarray:
	"""Height from coverage + brightness; RG normal, B height, A ambient occlusion."""
	al = a[..., 3]
	mode = "wrap" if tile else "nearest"
	cover = ndimage.gaussian_filter(al, 6.0, mode=mode)
	detail = luma(a[..., :3]) * al
	h = np.clip(0.65 * cover + 0.35 * detail, 0, 1) * (0.35 + 0.65 * tall)
	h *= edge_height_ramp(a, edge_px)
	gy, gx = np.gradient(ndimage.gaussian_filter(h, 1.2, mode=mode))
	strength = 6.0
	n = np.stack([-gx * strength, gy * strength, np.ones_like(h)], -1)
	n /= np.linalg.norm(n, axis=-1, keepdims=True)
	ao = np.clip(1.0 - (ndimage.gaussian_filter(h, 10.0, mode=mode) - h) * 2.5, 0.45, 1.0)
	return np.stack([n[..., 0] * 0.5 + 0.5, n[..., 1] * 0.5 + 0.5, h, ao], -1).astype(np.float32)


def split_sprites(a: np.ndarray, cols: int = 4, rows: int = 2) -> list[np.ndarray]:
	"""Find each animal by connected components on alpha; fall back to the grid."""
	al = a[..., 3] > 0.08
	lab, count = ndimage.label(ndimage.binary_dilation(al, iterations=6))
	boxes = []
	for sl in ndimage.find_objects(lab):
		if sl is None:
			continue
		h, w = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
		if h * w > (a.shape[0] * a.shape[1]) / (cols * rows * 12):
			boxes.append(sl)
	if len(boxes) != cols * rows:
		h, w = a.shape[0] // rows, a.shape[1] // cols
		boxes = [(slice(r * h, (r + 1) * h), slice(c * w, (c + 1) * w)) for r in range(rows) for c in range(cols)]
	else:
		# Row-major: sort by row band then by x.
		boxes.sort(key=lambda s: (round((s[0].start + s[0].stop) / 2 / (a.shape[0] / rows)), s[1].start))
	sprites = []
	for sl in boxes:
		sprites.append(a[sl[0], sl[1]])
	return sprites


def fit_cell(sprite: np.ndarray, size: int = CELL, margin: int = 4) -> np.ndarray:
	al = sprite[..., 3] > 0.04
	ys, xs = np.nonzero(al)
	if ys.size == 0:
		return np.zeros((size, size, 4), np.float32)
	crop = sprite[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
	h, w = crop.shape[:2]
	scale = (size - 2 * margin) / max(h, w)
	nh, nw = max(1, round(h * scale)), max(1, round(w * scale))
	r = resize(crop, nw, nh)
	cell = np.zeros((size, size, 4), np.float32)
	y, x = (size - nh) // 2, (size - nw) // 2
	cell[y:y + nh, x:x + nw] = r
	return cell


def fauna_tone(a: np.ndarray) -> np.ndarray:
	# Animals keep their own colour but share the terrain's soft contrast.
	out = a.copy()
	l = luma(a[..., :3])
	grey = l[..., None]
	out[..., :3] = np.clip(0.06 + grey * 0.86 + (a[..., :3] - grey) * 0.85, 0, 1)
	return out


def to_u8(a: np.ndarray) -> np.ndarray:
	return (np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)


def crown_tone(a: np.ndarray) -> np.ndarray:
	"""Normalise a crown so its opaque mean luma is 0.5; the shader multiplies the climate
	leaf palette by luma*2, so phenology/drought/snow keep working on the bitmap."""
	out = a.copy()
	m = a[..., 3] > 0.5
	if not m.any():
		return out
	l = luma(a[..., :3])
	gain = 0.5 / max(float(l[m].mean()), 1e-3)
	out[..., :3] = np.clip(a[..., :3] * gain, 0, 1)
	return out


def crown_normal(a: np.ndarray, tall: float, edge_px: float = 0.0) -> np.ndarray:
	"""Dome from the silhouette + leaf-clump relief from luma: RG normal, B height, A AO."""
	al = a[..., 3]
	solid = al > 0.35
	dist = ndimage.distance_transform_edt(solid)
	dome = np.sqrt(np.clip(dist / max(float(dist.max()), 1.0), 0, 1))
	l = luma(a[..., :3]) * al
	clumps = ndimage.gaussian_filter(l, 1.5) - ndimage.gaussian_filter(l, 8.0)
	h = np.clip(dome * 0.70 + clumps * 1.6 + 0.15 * al, 0, 1) * al * (0.4 + 0.6 * tall)
	h *= edge_height_ramp(a, edge_px)
	gy, gx = np.gradient(ndimage.gaussian_filter(h, 1.0))
	strength = 9.0
	n = np.stack([-gx * strength, gy * strength, np.ones_like(h)], -1)
	n /= np.linalg.norm(n, axis=-1, keepdims=True)
	cavity = np.clip(1.0 - (ndimage.gaussian_filter(h, 6.0) - h) * 3.0, 0.4, 1.0)
	ao = cavity * (0.55 + 0.45 * dome)
	return np.stack([n[..., 0] * 0.5 + 0.5, n[..., 1] * 0.5 + 0.5, h, ao], -1).astype(np.float32)


def material_tone(a: np.ndarray, kind: str, ident: str) -> np.ndarray:
	"""Keep the generated mineral hue while matching the map's muted value range."""
	target = MATERIAL_TONE.get(ident, (0.27, 0.63) if kind == "solid" else (0.31, 0.53))
	return tone_match(a, target=target, sat=0.90 if kind == "solid" else 0.82)


def material_normal(a: np.ndarray, kind: str, tall: float, edge_px: float) -> np.ndarray:
	if kind == "solid":
		return crown_normal(a, tall, edge_px)
	return derive_normal(a, tall, tile=False, edge_px=edge_px)


def normalize_alpha_backdrop(a: np.ndarray) -> np.ndarray:
	"""Some generated sheets arrive on a uniform 50% white matte instead of alpha=0.

	Border alpha identifies that matte. Remap it below the silhouette while keeping
	the generated antialiased edges so fit_cell/bleed_alpha do not produce white plates.
	"""
	if a.shape[0] < 3 or a.shape[1] < 3:
		return a
	border = np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]])
	bg_alpha = float(np.median(border[:, 3]))
	if not 0.10 < bg_alpha < 0.90:
		return a
	# The generated matte often has a broad translucent halo above the plate.
	# Keep only the solid mineral core, not that translucent papery fringe.
	lo = bg_alpha + 0.22
	hi = min(0.98, bg_alpha + 0.38)
	t = np.clip((a[..., 3] - lo) / max(hi - lo, 1e-3), 0.0, 1.0)
	out = a.copy()
	out[..., 3] = t * t * (3.0 - 2.0 * t)
	return out


def bleed_alpha(a: np.ndarray, tile: bool) -> np.ndarray:
	"""Fill transparent texels with the nearest opaque colour (alpha unchanged).

	Mipmaps and VRAM compression average RGB regardless of alpha; without this, the
	grey colour stored under transparent gaps bleeds into the foliage at map zoom.
	"""
	out = a.copy()
	h, w = a.shape[:2]
	src = np.tile(a, (3, 3, 1)) if tile else a
	solid = src[..., 3] > 0.35
	if not solid.any():
		return out
	_, (iy, ix) = ndimage.distance_transform_edt(~solid, return_indices=True)
	filled = src[iy, ix, :3]
	if tile:
		filled = filled[h:2 * h, w:2 * w]
	# Soft edge texels keep their own colour, fully clear ones take the neighbour's.
	k = np.clip(a[..., 3:4] / 0.35, 0.0, 1.0)
	out[..., :3] = a[..., :3] * k + filled * (1.0 - k)
	return out


def edge_error(tile: np.ndarray) -> float:
	pm = tile[..., :3] * tile[..., 3:4]
	h = np.abs(pm[0] - pm[-1]).mean()
	v = np.abs(pm[:, 0] - pm[:, -1]).mean()
	inner = np.abs(pm[1:] - pm[:-1]).mean()
	return float(max(h, v) / max(inner, 1e-4))


def build(check_only: bool) -> int:
	cover_layers: list[tuple[str, str, float]] = FLORA + TRACES
	albedo, normal, report = [], [], {}
	for ident, prompt, tall in cover_layers:
		kind = "trace" if ident.startswith("trace.") else "flora"
		src = SRC / kind / f"{ident}.png"
		if not src.exists():
			print(f"missing source {src}", file=sys.stderr)
			return 1
		a = resize(square_crop(load_rgba(src)), TILE, TILE)
		a = make_seamless(a)
		a = tone_match(a, target=(0.34, 0.52) if kind == "trace" else LUMA_TARGET,
			sat=0.70 if kind == "trace" else SAT_SCALE)
		if ident in HUE_TARGET:
			a = hue_correct(a, *HUE_TARGET[ident])
		a = bleed_alpha(a, tile=True)
		albedo.append(a)
		normal.append(derive_normal(a, tall))
		m = a[..., 3] > 0.5
		report[ident] = {"edge_error": round(edge_error(a), 3), "coverage": round(float(a[..., 3].mean()), 3),
			"luma": round(float(luma(a[..., :3])[m].mean()) if m.any() else 0.0, 3)}
	fauna = []
	for ident, prompt, _trace in FAUNA:
		src = SRC / "fauna" / f"{ident}.png"
		if not src.exists():
			print(f"missing source {src}", file=sys.stderr)
			return 1
		sprites = split_sprites(load_rgba(src))
		sheet = np.zeros((CELL * 2, CELL * 4, 4), np.float32)
		for i, s in enumerate(sprites[:8]):
			r, c = divmod(i, 4)
			sheet[r * CELL:(r + 1) * CELL, c * CELL:(c + 1) * CELL] = fauna_tone(fit_cell(s))
		fauna.append(bleed_alpha(sheet, tile=False))
		report[ident] = {"sprites": len(sprites)}

	crowns, crown_normals = [], []
	for ident, prompt, tall in CROWNS:
		src = SRC / "crown" / f"{ident}.png"
		if not src.exists():
			print(f"missing source {src}", file=sys.stderr)
			return 1
		sprites = split_sprites(load_rgba(src))
		sheet = np.zeros((CROWN_CELL * 2, CROWN_CELL * 4, 4), np.float32)
		nsheet = np.zeros_like(sheet)
		nsheet[..., :2] = 0.5
		nsheet[..., 2] = 0.0
		nsheet[..., 3] = 1.0
		for i, s in enumerate(sprites[:8]):
			r, c = divmod(i, 4)
			cell = crown_tone(fit_cell(s, CROWN_CELL, 2))
			ys, xs = slice(r * CROWN_CELL, (r + 1) * CROWN_CELL), slice(c * CROWN_CELL, (c + 1) * CROWN_CELL)
			sheet[ys, xs] = cell
			nsheet[ys, xs] = crown_normal(cell, tall)
		crowns.append(bleed_alpha(sheet, tile=False))
		crown_normals.append(nsheet)
		report["crown." + ident] = {"sprites": len(sprites)}

	rock_src = SRC / ROCK_DECOR["path"]
	if not rock_src.exists():
		print(f"missing source {rock_src}", file=sys.stderr)
		return 1
	rock_sprites = split_sprites(load_rgba(rock_src))
	rock_sheet = np.zeros((CROWN_CELL * 2, CROWN_CELL * 4, 4), np.float32)
	rock_normals = np.zeros_like(rock_sheet)
	rock_normals[..., :2] = 0.5
	rock_normals[..., 3] = 1.0
	for i, sprite in enumerate(rock_sprites[:8]):
		r, c = divmod(i, 4)
		cell = fit_cell(normalize_alpha_backdrop(sprite), CROWN_CELL, 2)
		cell = soften_rock_alpha(cell, f"{ROCK_DECOR['id']}:{i}")
		cell = material_tone(cell,
			"solid", str(ROCK_DECOR["id"]))
		ys = slice(r * CROWN_CELL, (r + 1) * CROWN_CELL)
		xs = slice(c * CROWN_CELL, (c + 1) * CROWN_CELL)
		rock_sheet[ys, xs] = cell
		rock_normals[ys, xs] = crown_normal(cell, float(ROCK_DECOR["tall"]), 2.5)
	crowns.append(bleed_alpha(rock_sheet, tile=False))
	crown_normals.append(rock_normals)
	report[str(ROCK_DECOR["id"])] = {"sprites": len(rock_sprites)}

	material_albedo = np.zeros((MATERIAL_ROWS * MATERIAL_CELL, MATERIAL_COLS * MATERIAL_CELL, 4), np.float32)
	material_normals = np.zeros_like(material_albedo)
	material_normals[..., :2] = 0.5
	material_normals[..., 3] = 1.0
	expected_material_ids = {ident for ident in MATERIAL_IDS if ident}
	source_material_ids = [ident for source in MATERIAL_SOURCES for ident in source["ids"]]
	if len(source_material_ids) != len(set(source_material_ids)) or set(source_material_ids) != expected_material_ids:
		print("material source ids must describe every non-empty atlas id exactly once", file=sys.stderr)
		return 1
	material_source_report = []
	for source in MATERIAL_SOURCES:
		src = SRC / source["path"]
		if not src.exists():
			print(f"missing source {src}", file=sys.stderr)
			return 1
		sprites = split_sprites(load_rgba(src), int(source["cols"]), int(source["rows"]))
		sprite_offset = int(source.get("sprite_offset", 0))
		required_sprites = sprite_offset + len(source["ids"])
		if len(sprites) < required_sprites:
			print(f"not enough sprites in {src}: {len(sprites)} < {required_sprites}", file=sys.stderr)
			return 1
		for i, ident in enumerate(source["ids"]):
			sprite_index = i + sprite_offset
			cell = fit_cell(normalize_alpha_backdrop(sprites[sprite_index]), MATERIAL_CELL, MATERIAL_MARGIN)
			cell = soften_material_alpha(cell, ident, source["kind"])
			cell = shape_ground_patch(cell, ident)
			cell = material_tone(cell, source["kind"], ident)
			edge_px = float(MATERIAL_EDGE_PX.get(ident, source["edge_px"]))
			ncell = material_normal(cell, source["kind"], float(source["tall"]), edge_px)
			cell = bleed_alpha(cell, tile=False)
			atlas_index = MATERIAL_IDS.index(ident)
			row, col = divmod(atlas_index, MATERIAL_COLS)
			ys = slice(row * MATERIAL_CELL, (row + 1) * MATERIAL_CELL)
			xs = slice(col * MATERIAL_CELL, (col + 1) * MATERIAL_CELL)
			material_albedo[ys, xs] = cell
			material_normals[ys, xs] = ncell
			m = cell[..., 3] > 0.5
			k = max(8, MATERIAL_CELL // 10)
			corner_coverage = max(
				float(cell[:k, :k, 3].mean()), float(cell[:k, -k:, 3].mean()),
				float(cell[-k:, :k, 3].mean()), float(cell[-k:, -k:, 3].mean()))
			report["material." + ident] = {
				"atlas_index": atlas_index,
				"coverage": round(float(cell[..., 3].mean()), 3),
				"luma": round(float(luma(cell[..., :3])[m].mean()) if m.any() else 0.0, 3),
				"normal_std": round(float(np.sqrt(np.mean((ncell[..., :2] - 0.5) ** 2))), 3),
				"height_outside_alpha": round(float(ncell[cell[..., 3] < 0.01, 2].max()), 3)
					if (cell[..., 3] < 0.01).any() else 0.0,
				"corner_coverage": round(corner_coverage, 3),
				"edge_px": round(edge_px, 1),
			}
		material_source_report.append({
			"path": source["path"], "cols": source["cols"], "rows": source["rows"],
			"sprite_offset": sprite_offset,
			"prompt": source["prompt"], "ids": source["ids"], "sprites": len(sprites),
			"edge_px": source["edge_px"],
		})

	failures = [k for k, v in report.items() if v.get("edge_error", 0.0) > 1.6]
	failures += [k for k, v in report.items() if "sprites" in v and v["sprites"] < 8]
	failures += [k for k, v in report.items()
		if k.startswith("material.") and v.get("normal_std", 0.0) < 0.008]
	failures += [k for k, v in report.items()
		if k.startswith("material.") and v.get("height_outside_alpha", 0.0) > 0.02]
	failures += [k for k, v in report.items()
		if k.startswith("material.") and k[9:] in MATERIAL_BLOB_PATCH
		and v.get("corner_coverage", 0.0) > 0.015]
	for k, v in report.items():
		print(k, v)
	if failures:
		print("QA failed:", failures, file=sys.stderr)
		return 2
	if check_only:
		return 0

	Image.fromarray(to_u8(np.concatenate(albedo, 0)), "RGBA").save(ART / "cover_albedo.png", optimize=True)
	Image.fromarray(to_u8(np.concatenate(normal, 0)), "RGBA").save(ART / "cover_normal.png", optimize=True)
	Image.fromarray(to_u8(np.concatenate(fauna, 0)), "RGBA").save(ART / "fauna_atlas.png", optimize=True)
	Image.fromarray(to_u8(np.concatenate(crowns, 0)), "RGBA").save(ART / "crown_atlas.png", optimize=True)
	Image.fromarray(to_u8(np.concatenate(crown_normals, 0)), "RGBA").save(ART / "crown_normal.png", optimize=True)
	Image.fromarray(to_u8(np.concatenate([material_albedo, material_normals], 0)), "RGBA").save(
		ART / "resource_material.png", optimize=True)
	manifest = {
		"version": 3,
		"generated": GENERATED,
		"provenance": "AI generated with the Codex built-in image generator; post-processed by tools/resource_art/build.py",
		"common_prompt": COMMON,
		"cover": {"tile": TILE, "albedo": "cover_albedo.png", "normal": "cover_normal.png",
			"layers": [{"id": i, "prompt": p, "tall": t, **report[i]} for i, p, t in cover_layers]},
		"fauna": {"file": "fauna_atlas.png", "cell": CELL, "cols": 4, "rows": 2, "count": 8,
			"layers": [{"id": i, "prompt": p, "trace": t} for i, p, t in FAUNA]},
		"crown": {"file": "crown_atlas.png", "normal": "crown_normal.png", "cell": CROWN_CELL,
			"cols": 4, "rows": 2, "count": 8,
			"prompt": "Sprite sheet: 8 individual tree crowns seen strictly from directly above, orthographic, "
				"4x2 grid with wide spacing, realistic photographic detail, soft diffuse overcast light, "
				"no ground, no cast shadows, transparent background",
			"layers": [{"id": i, "prompt": p, "tall": t} for i, p, t in CROWNS]
				+ [{"id": ROCK_DECOR["id"], "prompt": ROCK_DECOR["prompt"],
					"tall": ROCK_DECOR["tall"], "path": ROCK_DECOR["path"]}]},
		"material": {"file": "resource_material.png", "cell": MATERIAL_CELL,
			"cols": MATERIAL_COLS, "rows": MATERIAL_ROWS,
			"layers": {"albedo": 0, "normal": 1}, "ids": MATERIAL_IDS,
			"sources": material_source_report},
	}
	(ART / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
	print("wrote", len(albedo), "cover layers,", len(fauna), "fauna layers and",
		len(crowns), "crown/hardscape layers")
	return 0


if __name__ == "__main__":
	parser = argparse.ArgumentParser()
	parser.add_argument("--check", action="store_true", help="run QA only, do not write outputs")
	sys.exit(build(parser.parse_args().check))
