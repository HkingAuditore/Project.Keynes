#!/usr/bin/env python3
"""Freeze cross-module DCWorldExt access in production GDScript.

Each call or exact binding-name string is one candidate. Count it only when its
receiver is world-like (a), or no production script defines that method (b).
This is a lexical guard, not GDScript type/alias inference. --audit shows the
precision breakdown and samples; --report shows the migration backlog.
--write-baseline creates the initial baseline or tightens an existing one.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

import world_ext_bindings as inventory

PROJECT = "Project/project-keynes"
BASELINE = "tools/ci/script_native_access_baseline.json"
EXCLUDED = {"tests", "tmp", "addons", ".godot"}
WORLD_NAME = re.compile(r"(?:^|_)(?:data_core_)?world_ext$|^_?ext$|^ext_obj$|^world$|^dc$")
# A single lexer keeps comments and quoted code out of call/func recognition.
LEX = re.compile(
    r'''(?P<comment>\#[^\n]*)|(?P<string>"""(?:\\.|(?!""")[\s\S])*"""|'''
    r"'''(?:\\.|(?!''')[\s\S])*'''|"
    r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?P<id>[A-Za-z_]\w*)|(?P<punct>[^\s])''')
REFLECTIVE = {"has_method", "call", "callv", "call_deferred"}


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    offset: int


@dataclass(frozen=True)
class Reference:
    file: str
    line: int
    name: str
    module: str
    kind: str
    receiver: str | None
    a: bool
    b: bool
    outside: bool
    source: str

    @property
    def counted(self) -> bool:
        return self.a or self.b


def tokenize(source: str) -> list[Token]:
    tokens = []
    for match in LEX.finditer(source):
        kind, value = match.lastgroup, match[0]
        if kind == "comment":
            continue
        if kind == "string":
            width = 3 if value.startswith(('"""', "'''")) else 1
            value = value[width:-width]
        tokens.append(Token(kind, value, match.start()))
    return tokens


def script_files(root: Path) -> list[Path]:
    project = root / PROJECT
    return sorted(p for p in project.rglob("*.gd")
                  if not EXCLUDED.intersection(p.relative_to(project).parts[:-1]))


def world_variables(tokens: list[Token]) -> set[str]:
    result = set()
    for i, token in enumerate(tokens):
        if token.kind != "id":
            continue
        # Declarations and function parameters, including self/member uses later.
        if [(t.kind, t.value) for t in tokens[i + 1:i + 3]] == [("punct", ":"), ("id", "DCWorldExt")]:
            result.add(token.value)
        j = i + 1
        if j < len(tokens) and tokens[j].value == ":":
            j += 1
            if j < len(tokens) and tokens[j].kind == "id":
                j += 1  # : Object =, : RefCounted =, or : DCWorldExt =
        if j >= len(tokens) or tokens[j].value != "=":
            continue
        rhs = tokens[j + 1:j + 6]
        if [(t.kind, t.value) for t in rhs] == [
                ("id", "ClassDB"), ("punct", "."), ("id", "instantiate"),
                ("punct", "("), ("string", "DCWorldExt")]:
            result.add(token.value)
    return result


def receiver(tokens: list[Token], start: int, end: int) -> str | None:
    """Terminal variable in a plain dotted path; never treat a call result as one."""
    part = tokens[start:end]
    if not part or any(t.kind != ("id" if i % 2 == 0 else "punct")
                       or (i % 2 and t.value != ".") for i, t in enumerate(part)):
        return None
    return part[-1].value if len(part) % 2 else None


def dot_receiver(tokens: list[Token], dot: int) -> str | None:
    start = dot - 1
    if start < 0 or tokens[start].kind != "id":
        return None
    while start >= 2 and tokens[start - 1].value == "." and tokens[start - 2].kind == "id":
        start -= 2
    return receiver(tokens, start, dot)


def candidates(tokens: list[Token], bindings: dict[str, str]):
    # Stack entries: opening token, first argument start, argument number, first comma.
    stack: list[list[int]] = []
    for i, token in enumerate(tokens):
        if token.kind == "id" and token.value in bindings and i and i + 1 < len(tokens):
            if tokens[i - 1].value == "." and tokens[i + 1].value == "(":
                yield token, "call", dot_receiver(tokens, i - 1)
        if token.kind == "string" and token.value in bindings:
            target = None
            if stack and tokens[stack[-1][0]].value == "(":
                opening, first, arg, first_comma = stack[-1]
                function = tokens[opening - 1].value if opening else ""
                if function in REFLECTIVE and arg == 0 and opening >= 2 and tokens[opening - 2].value == ".":
                    target = dot_receiver(tokens, opening - 2)
                elif function == "Callable" and arg == 1:
                    target = receiver(tokens, first, first_comma)
            yield token, "string", target
        if token.kind != "punct":
            continue
        if token.value in ("(", "[", "{"):
            stack.append([i, i + 1, 0, i + 1])
        elif token.value in (")", "]", "}") and stack:
            stack.pop()
        elif token.value == "," and stack:
            if stack[-1][2] == 0:
                stack[-1][3] = i  # Callable's receiver ends at its first comma.
            stack[-1][2] += 1


def directory_errors(root: Path, table: dict) -> list[str]:
    dirs = table.get("script_dirs", {})
    problems = []
    for module in sorted(set(table["modules"]) | set(dirs)):
        entries = dirs.get(module)
        if module not in table["modules"] or not isinstance(entries, list) or not entries:
            problems.append(f"script_dirs: module {module} must have a nonempty path list and exist in modules")
            continue
        for entry in entries:
            path = PurePosixPath(entry)
            if path.is_absolute() or not path.parts or ".." in path.parts or entry != path.as_posix():
                problems.append(f"script_dirs: {module}: invalid project-relative path {entry}")
            elif not (root / PROJECT / entry).exists():
                problems.append(f"script_dirs: {module}: missing path {entry}")
    return problems


def allowed(file: str, module: str, dirs: dict[str, list[str]]) -> bool:
    path = PurePosixPath(file)
    matches = [(len(PurePosixPath(entry).parts), owner)
               for owner, entries in dirs.items() for entry in entries
               if path == PurePosixPath(entry) or PurePosixPath(entry) in path.parents]
    if not file.endswith("_facade.gd"):
        return any(owner == module for _, owner in matches)
    # Facades belong to the deepest registered directory, so bakers cannot inherit
    # visual's parent-directory permission. Shared directories require a module prefix.
    deepest = max((depth for depth, _ in matches), default=0)
    owners = {owner for depth, owner in matches if depth == deepest}
    if len(owners) > 1:
        owners = {owner for owner in owners if path.name.startswith(owner + "_")}
    return module in owners


def inspect(root: Path) -> tuple[list[Reference], list[str], int]:
    rows, problems = inventory.inventory(root)  # Single source of binding names/modules.
    table = inventory.load_table(root)
    problems.extend(directory_errors(root, table))
    if problems:
        return [], problems, 0
    bindings = {b["name"]: b["module"] for b in rows}
    sources = [(p, p.read_text(encoding="utf-8")) for p in script_files(root)]
    parsed = [(p, source, tokenize(source)) for p, source in sources]
    functions = {tokens[i + 1].value for _, _, tokens in parsed
                 for i, t in enumerate(tokens[:-2]) if t.kind == "id" and t.value == "func"
                 and tokens[i + 1].kind == "id" and tokens[i + 2].value == "("}
    refs = []
    for path, source, tokens in parsed:
        world = world_variables(tokens)
        lines = source.splitlines()
        project_file = path.relative_to(root / PROJECT).as_posix()
        for token, kind, target in candidates(tokens, bindings):
            line = source.count("\n", 0, token.offset) + 1
            a = target is not None and (target in world or bool(WORLD_NAME.search(target)))
            b = token.value not in functions
            refs.append(Reference(path.relative_to(root).as_posix(), line, token.value,
                                  bindings[token.value], kind, target, a, b,
                                  not allowed(project_file, bindings[token.value], table["script_dirs"]),
                                  lines[line - 1].strip()))
    return refs, [], len(sources)


def measure(refs: list[Reference]) -> dict[str, dict[str, int]]:
    counts: dict[str, Counter] = defaultdict(Counter)
    for ref in refs:
        if ref.counted and ref.outside:
            counts[ref.file][ref.module] += 1
    return {file: dict(sorted(counts[file].items())) for file in sorted(counts)}


def baseline_errors(baseline: dict) -> list[str]:
    if not isinstance(baseline, dict):
        return ["baseline: expected a file/module/count map"]
    problems = []
    for file, modules in baseline.items():
        if not isinstance(modules, dict) or not modules:
            problems.append(f"baseline: {file}: expected nonempty module/count map")
            continue
        for module, count in modules.items():
            if type(count) is not int or count <= 0:
                problems.append(f"baseline: {file}/{module}: expected positive integer")
    return problems


def violations(current: dict, baseline: dict) -> list[str]:
    return [f"{file}: {module}: {count} > baseline {baseline.get(file, {}).get(module, 0)}"
            for file, modules in current.items() for module, count in modules.items()
            if count > baseline.get(file, {}).get(module, 0)]


def reductions(current: dict, baseline: dict) -> list[str]:
    return [f"{file}: {module}: {count} -> {current.get(file, {}).get(module, 0)}"
            for file, modules in baseline.items() for module, count in modules.items()
            if current.get(file, {}).get(module, 0) < count]


def report(current: dict, modules: dict) -> None:
    print("script native access report (cross-module references):")
    for module in modules:
        files = [(file, counts[module]) for file, counts in current.items() if module in counts]
        print(f"{module}: {len(files)} files, {sum(count for _, count in files)} references")
        for file, count in sorted(files, key=lambda row: (-row[1], row[0]))[:5]:
            print(f"  {count:4} {file}")


def audit(refs: list[Reference]) -> None:
    counts = Counter((r.a, r.b) for r in refs)
    print(f"precision: {len(refs)} candidates; a=yes {sum(r.a for r in refs)}, a=no {sum(not r.a for r in refs)}; "
          f"b=yes {sum(r.b for r in refs)}, b=no {sum(not r.b for r in refs)}")
    print(f"counted: a-only {counts[True, False]}, b-only {counts[False, True]}, "
          f"both {counts[True, True]}; excluded: neither {counts[False, False]}")
    # Round-robin by decision/receiver/module/kind gives diverse, reproducible samples.
    for counted, title in ((True, "counted"), (False, "excluded")):
        buckets: dict[tuple, list[Reference]] = defaultdict(list)
        for ref in refs:
            if ref.counted == counted:
                buckets[(ref.a, ref.b, ref.receiver or "", ref.module, ref.kind)].append(ref)
        sample = []
        while buckets and len(sample) < 10:
            for decision in ((True, False), (False, True), (True, True), (False, False)):
                key = next((key for key in buckets if key[:2] == decision), None)
                if key is not None:
                    rows = buckets.pop(key)
                    sample.append(rows.pop(0))
                    if rows:
                        buckets[key] = rows
                    if len(sample) == 10:
                        break
        print(f"{title} samples ({len(sample)}):")
        for ref in sample:
            print(f"  {ref.file}:{ref.line} [{ref.module}/{ref.kind}; receiver={ref.receiver}; "
                  f"a={int(ref.a)} b={int(ref.b)}; outside={int(ref.outside)}] {ref.source}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=inventory.ROOT)
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--audit", action="store_true")
    parser.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args()
    try:
        refs, problems, files = inspect(args.root)
        current = measure(refs)
        path = args.root / BASELINE
        if path.exists():
            baseline = json.loads(path.read_text(encoding="utf-8"))
            problems.extend(baseline_errors(baseline))
        elif args.write_baseline:
            baseline = {}
        else:
            baseline = {}
            problems.append(f"missing {BASELINE}; use --write-baseline for initial capture")
        if not problems:
            if path.exists() or not args.write_baseline:
                problems.extend(violations(current, baseline))
            if not problems and args.write_baseline:
                path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
                print(f"wrote {BASELINE} (initial capture or tightening only)")
            elif not args.write_baseline:
                for reduction in reductions(current, baseline):
                    print(f"can tighten baseline: {reduction}")
        if args.report:
            report(current, inventory.load_table(args.root)["modules"])
        if args.audit:
            audit(refs)
        for problem in problems:
            print(problem, file=sys.stderr)
        print(f"script native access guard: {files} scripts; {sum(r.counted for r in refs)} native references; "
              f"{len(current)} files / {sum(map(len, current.values()))} file-module pairs / "
              f"{sum(sum(m.values()) for m in current.values())} cross-module references; {len(problems)} problems")
        return int(bool(problems))
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"script native access guard: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
