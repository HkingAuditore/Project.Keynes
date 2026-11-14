"""粗粒度 GDScript 括号/引号平衡检查（不是解析器，只抓手写时的硬伤）。

用法： python tests/tools/gdscript_balance_check.py <file> [<file>...]
退出码 0 = 全部平衡；1 = 有文件不平衡（打印行号）。
"""
import sys


def check(path: str) -> list[str]:
    problems: list[str] = []
    stack: list[tuple[str, int]] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    line = 1
    i = 0
    n = len(text)
    quote = ""
    triple = False
    in_comment = False
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            in_comment = False
            i += 1
            continue
        if in_comment:
            i += 1
            continue
        if quote:
            if ch == "\\":
                i += 2
                continue
            if triple:
                if text.startswith(quote * 3, i):
                    quote = ""
                    triple = False
                    i += 3
                    continue
                i += 1
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch == "#":
            in_comment = True
            i += 1
            continue
        if ch in ("'", '"'):
            if text.startswith(ch * 3, i):
                quote = ch
                triple = True
                i += 3
                continue
            quote = ch
            i += 1
            continue
        if ch in "([{":
            stack.append((ch, line))
            i += 1
            continue
        if ch in ")]}":
            if not stack:
                problems.append(f"{path}:{line}: 多余的 '{ch}'")
                i += 1
                continue
            opener, opened_at = stack.pop()
            if opener != pairs[ch]:
                problems.append(
                    f"{path}:{line}: '{ch}' 与 {opened_at} 行的 '{opener}' 不匹配")
            i += 1
            continue
        i += 1
    if quote:
        problems.append(f"{path}: 文件结尾仍有未闭合的引号 {quote!r}（起点附近）")
    for opener, opened_at in stack:
        problems.append(f"{path}:{opened_at}: '{opener}' 未闭合")
    return problems


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    total = 0
    for path in argv:
        problems = check(path)
        for problem in problems:
            print(problem)
        total += len(problems)
    print(f"[gd-balance] files={len(argv)} problems={total}")
    return 0 if total == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
