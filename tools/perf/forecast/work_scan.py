"""Construct source-linked intraprocedural graphs without importing the target."""
import ast
import dis
import hashlib
import json
import types
from collections import Counter


def python_graph(source, path):
    code = compile(source, str(path), "exec", dont_inherit=True)
    jumps = set(dis.hasjabs) | set(dis.hasjrel)
    funcs = []

    def visit(c):
        ins = list(dis.get_instructions(c))
        exceptions = list(dis.Bytecode(c).exception_entries)
        starts = {ins[0].offset}
        edges = []
        for index, op in enumerate(ins):
            if op.opcode in jumps:
                starts.add(op.argval)
                edges.append((op.offset, op.argval, "jump"))
            terminal = op.opname in {"RETURN_VALUE", "RETURN_CONST", "RAISE_VARARGS", "RERAISE"}
            jump_only = op.opname.startswith(("JUMP_FORWARD", "JUMP_BACKWARD")) or op.opname == "JUMP"
            if index + 1 < len(ins):
                nxt = ins[index + 1].offset
                if terminal or op.opcode in jumps:
                    starts.add(nxt)
                if not terminal and not jump_only:
                    edges.append((op.offset, nxt, "next"))
        for e in exceptions:
            starts.update((e.start, e.end, e.target))
        by_offset = {}
        blocks = []
        for op in ins:
            if op.offset in starts:
                blocks.append({"id": op.offset, "lines": [], "last_instruction": ""})
            block = blocks[-1]
            by_offset[op.offset] = block["id"]
            line = op.positions.lineno
            if line and line not in block["lines"]:
                block["lines"].append(line)
            block["last_instruction"] = op.opname
        links = {(by_offset[a], by_offset[b], k) for a, b, k in edges
                 if by_offset[a] != by_offset[b] or k == "jump"}
        for e in exceptions:
            for block in blocks:
                if e.start <= block["id"] < e.end:
                    links.add((block["id"], by_offset[e.target], "exception"))
        funcs.append({"name": c.co_qualname, "line": c.co_firstlineno, "entry": blocks[0]["id"],
                      "nodes": blocks, "edges": sorted(links)})
        for inner in c.co_consts:
            if isinstance(inner, types.CodeType):
                visit(inner)
    visit(code)
    calls = [{"line": n.lineno, "target": ast.unparse(n.func)}
             for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Call)]
    return funcs, calls, ["Calls are listed by source expression; runtime targets and other files are not expanded.",
                           "Interpreter blocks describe possible flow; asynchronous scheduling is external."]


def godot_graph(source):
    try:
        from gdtoolkit.parser import parser
        from lark import Tree
    except ImportError as exc:
        raise ValueError("GDScript scanning needs gdtoolkit; run uv run --with gdtoolkit==4.5.0 python work.py scan ...") from exc
    from lark.exceptions import LarkError
    try:
        tree = parser.parse(source, gather_metadata=True)
    except LarkError as exc:
        raise ValueError(f"GDScript parse failed: {exc}") from exc
    funcs, calls = [], []
    for node in tree.iter_subtrees_topdown():
        if node.data in ("getattr_call", "standalone_call"):
            target = node.children[0]
            name = source[target.meta.start_pos:target.meta.end_pos] if isinstance(target, Tree) else str(target)
            calls.append({"line": node.meta.line, "target": name})
        if node.data != "func_def":
            continue
        nodes = [{"id": 0, "lines": [], "statement": "exit"}]
        edges = []

        def add(stmt, label):
            index = len(nodes)
            nodes.append({"id": index, "lines": [stmt.meta.line], "statement": label})
            return index

        def sequence(stmts, successor, break_to=None, continue_to=None):
            for stmt in reversed(stmts):
                kind = str(stmt.data)
                if kind == "if_stmt":
                    otherwise = successor
                    for branch in reversed(stmt.children):
                        if branch.data == "else_branch":
                            otherwise = sequence(branch.children, successor, break_to, continue_to)
                        else:
                            condition, *body = branch.children
                            label = source[condition.meta.start_pos:condition.meta.end_pos]
                            test = add(branch, label)
                            yes = sequence(body, successor, break_to, continue_to)
                            edges.extend([(test, yes, "true"), (test, otherwise, "false")])
                            otherwise = test
                    successor = otherwise
                    continue
                here = add(stmt, kind)
                if kind in ("for_stmt", "while_stmt"):
                    body = [s for s in stmt.children if isinstance(s, Tree) and s.data.endswith("_stmt")]
                    entry = sequence(body, here, successor, here)
                    edges.extend([(here, entry, "iterate"), (here, successor, "done")])
                elif kind in ("break_stmt", "continue_stmt", "return_stmt"):
                    dest = {"break_stmt": break_to, "continue_stmt": continue_to, "return_stmt": 0}[kind]
                    if dest is None:
                        raise ValueError(f"unbound {kind} at {stmt.meta.line}")
                    edges.append((here, dest, kind))
                elif kind in ("func_var_stmt", "expr_stmt", "pass_stmt", "func_const_stmt"):
                    edges.append((here, successor, "next"))
                else:
                    nodes[here]["opaque"] = True
                    edges.append((here, successor, "possible continuation"))
                successor = here
            return successor

        entry = sequence(node.children[1:], 0)
        funcs.append({"name": str(node.children[0].children[0]), "line": node.meta.line,
                      "entry": entry, "nodes": nodes, "edges": edges})
    return funcs, calls, ["Statement-level normal flow. Opaque statements have unexpanded internals.",
                          "Expressions, engine calls, signals and suspension points are not expanded."]


def scan_source(path, function=None, clang_args=()):
    path = path.resolve()
    raw = path.read_bytes()
    source = raw.decode()
    if clang_args and path.suffix not in (".c", ".cc", ".cpp", ".cxx"):
        raise ValueError("clang flags apply only to C/C++")
    if path.suffix == ".py":
        funcs, calls, limits = python_graph(source, path)
    elif path.suffix == ".gd":
        funcs, calls, limits = godot_graph(source)
    elif path.suffix in (".c", ".cc", ".cpp", ".cxx"):
        from work_clang import scan
        funcs, calls, limits = scan(path, clang_args)
    else:
        raise ValueError("built-in static scan supports Python, GDScript and C/C++")
    if function:
        def matches(f):
            if f["name"] == function:
                return True
            if path.suffix in (".c", ".cc", ".cpp", ".cxx"):
                words = f["name"].partition("(")[0].split()
                return bool(words) and words[-1].split("::")[-1] == function
            return False
        funcs = [f for f in funcs if matches(f)]
        if not funcs:
            raise ValueError(f"unknown function {function!r}")
    return {"source": str(path), "source_sha256": hashlib.sha256(raw).hexdigest(),
            "functions": funcs, "file_call_sites": calls, "scope": limits}


def dot(report):
    rows = ["digraph work {"]
    for i, func in enumerate(report["functions"]):
        rows += [f"  subgraph cluster_{i} {{", f'    label={json.dumps(func["name"])};']
        for n in func["nodes"]:
            label = f"{n['lines']} {n.get('statement', n.get('last_instruction', ''))}"
            rows.append(f'    f{i}n{n["id"]} [label={json.dumps(label)}];')
        for a, b, kind in func["edges"]:
            rows.append(f'    f{i}n{a} -> f{i}n{b} [label={json.dumps(kind)}];')
        rows.append("  }")
    return "\n".join(rows + ["}"])


def observed_dot(report, step=None):
    rows = report["steps"]
    if step is not None:
        if not 0 <= step < len(rows):
            raise ValueError("step is outside the scenario")
        rows = [rows[step]]
    ids, labels = {}, {0: "step entry", 1: "step exit"}
    links = Counter()
    for row in rows:
        prev = 0
        for point in row["path"]:
            key = json.dumps(point, sort_keys=True, ensure_ascii=False)
            index = ids.setdefault(key, 2 + len(ids))
            label = point if isinstance(point, str) else key
            if isinstance(point, str) and point in report["locations"]:
                label += f" (line {report['locations'][point]})"
            labels[index] = label
            links[prev, index] += 1
            prev = index
        links[prev, 1] += 1
    result = ["digraph observed {"]
    result.extend(f"  n{i} [label={json.dumps(s)}];" for i, s in labels.items())
    result.extend(f'  n{a} -> n{b} [label="{n}"];' for (a, b), n in links.items())
    return "\n".join(result + ["}"])
