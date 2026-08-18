"""Unqualified: east-west cliff. Noise must be cylindrical; col 0 and width-1 must match."""


def generate(ctx):
    n = ctx.width * ctx.height
    elevation = [0.0] * n
    for row, col, i in ctx.cells():
        if col < ctx.width // 2:
            elevation[i] = 0.78
        else:
            elevation[i] = 0.22
    return {"elevation": elevation, "sea_level": ctx.sea_level, "hints": {}}
