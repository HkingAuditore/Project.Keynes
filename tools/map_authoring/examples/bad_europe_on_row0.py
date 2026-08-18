"""Unqualified: Europe painted onto row 0 (the north pole). Do not copy."""


def generate(ctx):
    n = ctx.width * ctx.height
    elevation = [ctx.sea_level - 0.12] * n
    for col in range(ctx.width):
        elevation[ctx.index(col, 0)] = 0.82
    return {"elevation": elevation, "sea_level": ctx.sea_level, "hints": {}}
