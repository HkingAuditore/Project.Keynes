"""Evaluate data and count calls in a closed, synchronous Python source subset."""
import ast
import operator
from pathlib import Path


class Returned(Exception):
    def __init__(self, value):
        self.value = value


OPS = {ast.Add: operator.add, ast.Mult: operator.mul, ast.Sub: operator.sub,
       ast.FloorDiv: operator.floordiv, ast.Mod: operator.mod, ast.Div: operator.truediv}
COMPARE = {ast.Eq: operator.eq, ast.NotEq: operator.ne, ast.Lt: operator.lt, ast.LtE: operator.le,
           ast.Gt: operator.gt, ast.GtE: operator.ge}
BUILTINS = {"len": len, "sum": sum, "range": range}


def unsupported(node, why=None):
    raise ValueError(f"source-only analysis unresolved at line {node.lineno}: {why or type(node).__name__}")


class Counter:
    def __init__(self, source, options):
        module = compile(source, "<target>", "exec", dont_inherit=True)
        self.local_names = {c.co_name: set(c.co_varnames) | set(c.co_cellvars) for c in module.co_consts
                            if hasattr(c, "co_varnames")}
        self.active_function = None
        self.funcs = {}
        self.metrics = {}
        self.locations = {}
        for fn in ast.parse(source).body:
            if isinstance(fn, ast.Expr) and isinstance(fn.value, ast.Constant):
                continue
            if not isinstance(fn, ast.FunctionDef) or fn.name in self.funcs or fn.decorator_list:
                unsupported(fn, "requires plain, uniquely named functions at module scope")
            if any(isinstance(n, (ast.Yield, ast.YieldFrom, ast.Global, ast.Nonlocal)) for n in ast.walk(fn)):
                unsupported(fn, "generator or nonlocal state")
            if getattr(fn, "type_params", []):
                unsupported(fn, "generic type parameters")
            args = fn.args
            if (args.defaults or args.kw_defaults or args.vararg or args.kwarg or args.posonlyargs
                    or fn.returns or any(a.annotation for a in args.args)):
                unsupported(fn, "requires plain positional-or-keyword parameters without annotations or defaults")
            self.funcs[fn.name] = fn
        self.entry = options["entry"]
        if self.entry not in self.funcs:
            raise ValueError(f"missing entry function {self.entry}")
        for label, spec in options["observe"].items():
            if set(spec) != {"function"} or spec["function"] not in self.funcs:
                raise ValueError("source-only count requires probes on defined functions' entries")
            self.metrics.setdefault(spec["function"], []).append(label)
            self.locations[label] = self.funcs[spec["function"]].lineno

    def expression(self, n, env):
        sub = lambda child: self.expression(child, env)
        if isinstance(n, ast.Constant) and type(n.value) in (int, float, str, bool, type(None)):
            return n.value
        if isinstance(n, ast.Name):
            if n.id not in env:
                unsupported(n, f"unknown input {n.id}")
            return env[n.id]
        if isinstance(n, ast.List):
            return [sub(e) for e in n.elts]
        if isinstance(n, ast.Subscript):
            return sub(n.value)[sub(n.slice)]
        if isinstance(n, ast.BinOp) and type(n.op) in OPS:
            return OPS[type(n.op)](sub(n.left), sub(n.right))
        if isinstance(n, ast.UnaryOp) and isinstance(n.op, (ast.Not, ast.USub)):
            value = sub(n.operand)
            return not value if isinstance(n.op, ast.Not) else -value
        if isinstance(n, ast.Compare):
            value = sub(n.left)
            for op, rhs in zip(n.ops, n.comparators):
                if type(op) not in COMPARE:
                    unsupported(n, "comparison operator")
                other = sub(rhs)
                if not COMPARE[type(op)](value, other):
                    return False
                value = other
            return True
        if isinstance(n, ast.ListComp):
            return list(self.items(n, env))
        if isinstance(n, ast.IfExp):
            return sub(n.body if sub(n.test) else n.orelse)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and not n.keywords:
            name = n.func.id
            if name in env or name in self.local_names[self.active_function]:
                unsupported(n, "indirect or locally shadowed call")
            if name == "sum" and name not in self.funcs and len(n.args) == 1 and isinstance(n.args[0], ast.GeneratorExp):
                return sum(self.items(n.args[0], env))
            args = [sub(a) for a in n.args]
            if name in self.funcs:
                params = [a.arg for a in self.funcs[name].args.args]
                if len(args) != len(params):
                    unsupported(n, "argument count")
                return self.call(name, dict(zip(params, args)))
            if name in BUILTINS:
                return BUILTINS[name](*args)
            unsupported(n, f"unknown call {name}")
        unsupported(n)

    def items(self, n, env):
        if len(n.generators) != 1 or n.generators[0].is_async or not isinstance(n.generators[0].target, ast.Name):
            unsupported(n, "comprehension shape")
        g = n.generators[0]
        local = env.copy()
        for value in self.expression(g.iter, env):
            local[g.target.id] = value
            if all(self.expression(test, local) for test in g.ifs):
                yield self.expression(n.elt, local)

    def body(self, statements, env, name):
        for n in statements:
            self.path.append([name, n.lineno])
            if isinstance(n, ast.Return):
                raise Returned(self.expression(n.value, env) if n.value else None)
            if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                env[n.targets[0].id] = self.expression(n.value, env)
            elif isinstance(n, ast.AugAssign) and isinstance(n.target, ast.Name) and type(n.op) in OPS:
                a = env[n.target.id]
                if type(a) not in (int, float):
                    unsupported(n, "in-place updates of mutable or nonnumeric values")
                env[n.target.id] = OPS[type(n.op)](a, self.expression(n.value, env))
            elif isinstance(n, ast.If):
                self.body(n.body if self.expression(n.test, env) else n.orelse, env, name)
            elif isinstance(n, ast.For) and isinstance(n.target, ast.Name):
                for value in self.expression(n.iter, env):
                    env[n.target.id] = value
                    self.body(n.body, env, name)
                self.body(n.orelse, env, name)
            elif isinstance(n, ast.Expr):
                self.expression(n.value, env)
            elif not isinstance(n, ast.Pass):
                unsupported(n)

    def call(self, name, env):
        for metric in self.metrics.get(name, []):
            self.counts[metric] += 1
        previous = self.active_function
        self.active_function = name
        try:
            self.body(self.funcs[name].body, env, name)
        except Returned as ret:
            return ret.value
        finally:
            self.active_function = previous

    def record(self, steps):
        expected = {a.arg for a in self.funcs[self.entry].args.args}
        rows = []
        for step in steps:
            if not isinstance(step, dict) or set(step) != expected:
                raise ValueError(f"expected scenario fields {sorted(expected)}")
            self.counts = dict.fromkeys(self.locations, 0)
            self.path = []
            value = self.call(self.entry, step.copy())
            if isinstance(value, range):
                raise ValueError("target returns a range, not a JSON output")
            rows.append({"output": value, "counts": self.counts, "path": self.path})
        return {"steps": rows, "locations": self.locations}


def analyze(request):
    source = Path(request["source"]).read_text(encoding="utf-8")
    return Counter(source, request["options"]).record(request["steps"])
