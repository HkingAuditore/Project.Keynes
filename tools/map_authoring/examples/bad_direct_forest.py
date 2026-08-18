"""Unqualified: assigning a final FOREST enum. Author scripts cannot write vegetation."""

# FOREST = 4 in TerrainType. This key is ignored; post_base owns vegetation.


def generate(ctx):
    n = ctx.width * ctx.height
    elevation = [0.55] * n
    vegetation = [4] * n
    return {
        "elevation": elevation,
        "sea_level": ctx.sea_level,
        "vegetation": vegetation,
        "hints": {},
    }
