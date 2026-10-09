"""Port direct indexed market assignments to guarded scalar writes.

Only the four tracked dense columns are eligible. Other C++ expressions are
left untouched; a C++ build checks read/reference escapes after the port.
"""
import argparse
import re
from pathlib import Path

TARGET = re.compile(r"(?:market_store\(\)|[\w.()]+\.market)\.(?:stock|price|demand_ema|last_shortage_q16)\[")


def rewrites(text: str):
    replacements = []
    for match in TARGET.finditer(text):
        bracket = match.end() - 1
        cursor, depth = bracket + 1, 1
        while cursor < len(text) and depth:
            depth += (text[cursor] == "[") - (text[cursor] == "]")
            cursor += 1
        if depth:
            raise ValueError("unclosed market index")
        index = text[bracket + 1:cursor - 1]
        assignment = re.match(r"\s*(\+=|-=|=(?!=))\s*", text[cursor:])
        if not assignment:
            continue
        rhs_begin = cursor + assignment.end()
        semicolon = text.find(";", rhs_begin)
        if semicolon < 0:
            raise ValueError("unclosed market assignment")
        column = text[match.start():bracket]
        rhs = text[rhs_begin:semicolon]
        if assignment.group(1) != "=":
            rhs = f"{column}[{index}] {assignment.group(1)[0]} ({rhs})"
        sink = ", market_mutation_sink()" if column.startswith("market_store()") else ""
        replacement = f"{column}.write_scalar({index}, {rhs}{sink});"
        replacements.append((match.start(), semicolon + 1, replacement))
    return replacements


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[2] / "gdext/src"
    count = 0
    for path in sorted(source.glob("*.cpp")):
        text = path.read_text(encoding="utf-8-sig")
        changes = rewrites(text)
        if not changes:
            continue
        count += len(changes)
        print(f"{path.name}: {len(changes)}")
        if args.apply:
            for start, end, replacement in reversed(changes):
                text = text[:start] + replacement + text[end:]
            # Preserve repository CRLF convention instead of rewriting every line.
            path.write_bytes(text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
    print(f"direct_market_writes={count}")
    if count and not args.apply:
        raise SystemExit(1)
