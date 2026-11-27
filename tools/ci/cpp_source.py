"""Read a C++ scope and its same-directory source fragments."""
from pathlib import Path
import re


COMMENTS = re.compile(
    r'//[^\n]*|/\*[\s\S]*?\*/|R"([^ ()\\\t\r\n]{0,16})\([\s\S]*?\)\1"|'
    r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
)
FRAGMENT_INCLUDE = re.compile(
    r'^[ \t]*#[ \t]*include[ \t]*"([a-zA-Z0-9_][a-zA-Z0-9_.-]*\.inc)"[ \t]*$',
    re.MULTILINE,
)


def read_cpp_source(path: Path) -> str:
    return _read_source(path, ())


def _read_source(path: Path, parents: tuple[Path, ...]) -> str:
    if path in parents:
        chain = " -> ".join(str(source) for source in (*parents, path))
        raise ValueError(f"Circular C++ source fragment inclusion: {chain}")
    source = path.read_text(encoding="utf-8")
    if path.suffix not in {".cpp", ".h", ".inc"}:
        return source
    # A commented-out include or one printed by a raw string does not
    # contribute source to the containing scope.
    hidden = [m for m in COMMENTS.finditer(source)
              if not (m.group().startswith('"') and "\n" not in m.group())]
    parts = []
    cursor = 0
    for match in FRAGMENT_INCLUDE.finditer(source):
        if any(span.start() <= match.start() < span.end() for span in hidden):
            continue
        parts.append(source[cursor:match.start()])
        parts.append(_read_source(path.with_name(match[1]), (*parents, path)))
        cursor = match.end()
    parts.append(source[cursor:])
    return "".join(parts)
