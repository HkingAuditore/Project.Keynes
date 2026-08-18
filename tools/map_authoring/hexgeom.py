"""Odd-r hex indexing matching C++ DCWorldExt::index_for_qr."""

from __future__ import annotations

DQ = (1, 1, 0, -1, -1, 0)
DR = (0, -1, -1, 0, 1, 1)


def index_of(col: int, row: int, width: int) -> int:
    return row * width + col


def col_row_of(index: int, width: int) -> tuple[int, int]:
    return index % width, index // width


def cube_of(col: int, row: int) -> tuple[int, int]:
    q = col - ((row - (row & 1)) // 2)
    return q, row


def index_for_qr(q: int, r: int, width: int, height: int) -> int:
    if r < 0 or r >= height:
        return -1
    col = q + ((r - (r & 1)) // 2)
    col %= width
    if col < 0:
        col += width
    return r * width + col


def neighbors(index: int, width: int, height: int) -> list[int]:
    col, row = col_row_of(index, width)
    q, r = cube_of(col, row)
    out: list[int] = []
    for d in range(6):
        ni = index_for_qr(q + DQ[d], r + DR[d], width, height)
        if ni >= 0:
            out.append(ni)
    return out
