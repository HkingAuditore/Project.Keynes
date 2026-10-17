"""Single source of truth for the resource-art production run (51 ids).

Every generated sheet is saved by ImageGen into sources/_inbox with a file name
that starts with the sheet tag (e.g. "bio_rice_"). `ingest.py` moves them to
sources/<id>/<id>_<tag>.png so nothing depends on the generator's naming.

kind:
  flora   side-view upright plants on magenta, 3x3 grid  -> scatter sprites
  fauna   top-down animals on magenta, all heads facing left -> herd sprites
  decal   top-down ground patch / outcrop on magenta       -> ground decal
  tile    seamless top-down ground texture, full frame     -> ground tile
"""

FLORA = {
    # id: english descriptor of the plant (side view, base at bottom)
    "bio.wheat": "WHEAT plants: upright stalks with golden ripe ears at the top, narrow green leaves",
    "bio.maize": "MAIZE plants: straight stalk, broad arching leaves, tassel on top, one ear",
    "bio.rice": "RICE plants: a tuft of slender arching blades, top drooping panicles of golden-green grain",
    "bio.potato": "POTATO plants: bushy upright plant with compound oval leaflets and small white-violet flowers",
    "bio.cotton": "COTTON plants: woody stalk, lobed green leaves, open fluffy white cotton bolls",
    "bio.flax": "FLAX plants: thin slender stems, narrow leaves, small sky-blue flowers at the tips",
    "bio.spice": "CHILI PEPPER plants: bushy, glossy green leaves, hanging red chili pods",
    "bio.rubber": "young RUBBER sapling trees: slender straight trunk, whorls of large glossy oval leaves",
    "bio.silkworm": "young MULBERRY shrubs: broad heart-shaped leaves, a few cream silk cocoons hanging among them",
    "bio.reed": "COMMON REED stands: tall slender blades, feathery brown-grey plumes on top",
    "bio.bast_fiber": "JUTE / RAMIE fibre plants: tall straight slender stalks, lance-shaped serrated leaves",
    "bio.dye_plant": "INDIGO dye plants: bushy, small oval leaves, upright spikes of purple-blue flowers",
    "bio.medicinal_herb": "GINSENG-like medicinal herbs: palmate leaves on a thin stem, cluster of red berries on top",
}

FAUNA = {
    # id: (english name, description, individuals per sheet)
    "bio.cattle": ("cow", "cream and tan patched cattle, short horns", 6),
    "bio.sheep": ("sheep", "woolly off-white sheep, small dark face", 6),
    "bio.goat": ("goat", "tan-brown goats with small horns", 6),
    "bio.pig": ("pig", "pink-brown domestic pigs", 6),
    "bio.horse": ("horse", "chestnut brown horses with dark mane", 6),
    "bio.camel": ("camel", "sand-coloured one-humped camels", 6),
    "bio.yak": ("yak", "dark brown shaggy yaks with long fringe hair", 6),
    "marine_fish": ("sea fish", "silver-blue small sea fish, top view", 9),
    "freshwater_fish": ("river fish", "olive-green carp-like river fish, top view", 9),
}

DECAL = {
    "stone": "grey irregular rock outcrop with loose stones",
    "coal": "black shiny coal seam outcrop with coal chunks",
    "oil": "dark glossy crude-oil seep puddle with iridescent sheen",
    "natural_gas": "pale cracked ground vent with faint bubbling hot patch",
    "copper_ore": "rock with teal-green malachite and copper veins",
    "iron_ore": "rust-red banded iron outcrop with scree",
    "gold_ore": "quartz rock with bright gold flecks and veins",
    "silver_ore": "pale grey rock with bright silvery veins",
    "salt": "white crusted salt flat patch with crystals",
    "saltpeter": "greyish-white powdery efflorescence crust on ground",
    "rare_earth": "dull ochre-brown mineral outcrop with pinkish streaks",
    "clay": "smooth terracotta-orange clay bank with cracked surface",
    "bauxite": "reddish-brown pisolitic bauxite rock rubble",
    "limestone": "pale cream limestone slabs with layered edges",
    "silica_sand": "pale golden fine sand patch with small quartz grains",
    "phosphate_rock": "olive-grey nodular phosphate rock rubble",
    "tin_ore": "dark brown-grey cassiterite rock with metallic glints",
    "lead_ore": "blue-grey heavy galena rock with cubic crystal faces",
    "zinc_ore": "greenish-grey sphalerite rock with brown glints",
    "manganese_ore": "purple-black manganese nodules on rock",
    "sulfur": "bright yellow sulfur crystal crust around a vent",
    "flint": "dark grey-black flint nodules with white cortex",
    "wild_game": "animal footprints and trampled dirt trail with a few tufts",
    "timber": "small pile of cut logs and fallen branches with sawdust",
}

TILE = {
    "fertile_soil": "dark rich brown humus soil with fine crumbs",
    "arable_land": "light brown tilled loam soil with faint small clods",
    "paddy_land": "wet muddy soil with shallow water film, grey-green sheen",
    "plantation_land": "reddish-brown soil with sparse leaf litter",
    "pasture": "short green meadow grass with small clover and soil patches",
}
