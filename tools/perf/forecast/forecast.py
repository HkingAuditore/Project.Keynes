"""Evaluate a performance model across paired scenarios. Python 3.10+, no packages."""
import argparse
import ast
import itertools
import json
import math
import operator
import sys
from fractions import Fraction
from pathlib import Path


ROOT = Path(__file__).resolve().parent
OPERATORS = {ast.Add: operator.add, ast.Sub: operator.sub,
             ast.Mult: operator.mul, ast.Div: operator.truediv}


def number(value):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f"expected a finite number, got {value!r}")
    return value


def calculate(node, inputs):
    if isinstance(node, ast.Constant):
        return Fraction(str(number(node.value)))
    if isinstance(node, ast.Name) and node.id in inputs:
        return inputs[node.id]
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return -calculate(node.operand, inputs)
    if isinstance(node, ast.BinOp) and type(node.op) in OPERATORS:
        return OPERATORS[type(node.op)](calculate(node.left, inputs),
                                        calculate(node.right, inputs))
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            and node.func.id in ("min", "max") and node.args and not node.keywords):
        operation = min if node.func.id == "min" else max
        return operation(calculate(arg, inputs) for arg in node.args)
    raise ValueError(f"unknown variable or unsupported expression: {ast.unparse(node)}")


def result_number(value):
    return number(value.numerator if value.denominator == 1 else float(value))


def read_json(path):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate key: {key}")
            result[key] = value
        return result
    raw = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    return json.loads(raw, object_pairs_hook=unique_keys)


def load_model(selection):
    if isinstance(selection, dict):
        return selection
    if selection not in ("cache", "gate", "repeat"):
        raise ValueError("model must be cache, gate, repeat, or an inline model")
    return read_json(ROOT / "models" / f"{selection}.json")


def check_inputs(spec, supplied):
    if not isinstance(supplied, dict) or not isinstance(spec, dict):
        raise ValueError("inputs and model parameters must be JSON objects")
    if set(supplied) != set(spec):
        raise ValueError(f"expected inputs {list(spec)}, received {list(supplied)}")
    choices = {}
    for name, domain in spec.items():
        values = supplied[name]
        if not isinstance(values, list):
            values = [values]
        if not values or domain not in ("number", "nonnegative", "positive", "positive_int"):
            raise ValueError(f"invalid domain or empty choices for {name}")
        for v in values:
            number(v)
            if ((domain == "nonnegative" and v < 0)
                    or (domain in ("positive", "positive_int") and v <= 0)
                    or (domain == "positive_int" and v != int(v))):
                raise ValueError(f"{name} requires {domain}, got {v}")
        choices[name] = list(dict.fromkeys(values))
    return choices


def predict(request):
    if not isinstance(request, dict):
        raise ValueError("request must be a JSON object")
    unexpected = set(request) - {"model", "inputs", "basis", "target"}
    if unexpected:
        raise ValueError(f"unknown request fields: {sorted(unexpected)}")
    model = load_model(request["model"])
    direction = model["better"]
    kind = model["kind"]
    if direction not in ("lower", "higher") or kind not in ("estimate", "upper_bound"):
        raise ValueError("invalid model direction or kind")
    if kind == "upper_bound" and direction != "higher":
        raise ValueError("upper_bound models require a higher-is-better metric")
    choices = check_inputs(model["parameters"], request["inputs"])
    expressions = {k: ast.parse(model[k], mode="eval").body for k in ("before", "after")}
    basis = request.get("basis", {})
    if (not isinstance(basis, dict) or set(basis) - set(choices)
            or any(not isinstance(note, str) for note in basis.values())):
        raise ValueError("basis must be keyed by input name")
    target = number(request["target"]) if "target" in request else None
    exact_target = Fraction(str(target)) if target is not None else None
    rows = []
    decisions = {key: {} for key in choices}
    for values in itertools.product(*choices.values()):
        inputs = dict(zip(choices, values))
        # Evaluate decimal inputs exactly so rounding cannot manufacture or erase a gain.
        exact_inputs = {name: Fraction(str(value)) for name, value in inputs.items()}
        before, after = (calculate(tree, exact_inputs) for tree in expressions.values())
        gain = result_number(after - before if direction == "higher" else before - after)
        trend = "better" if gain > 0 else "worse" if gain < 0 else "equal"
        row = {"inputs": inputs, "before": result_number(before), "after": result_number(after),
               "improvement": gain, "trend": trend}
        if request["model"] == "cache":
            # For N >= 2, (N - 1) * (direct - read) must exceed one build.
            direct, read, build = (exact_inputs[k] for k in ("direct_ms", "read_ms", "build_ms"))
            row["first_profitable_stable_frames"] = (
                2 + build // (direct - read) if direct > read else None)
        if exact_target is not None:
            passes = after >= exact_target if direction == "higher" else after <= exact_target
            if kind == "upper_bound":
                row["target"] = "not_ruled_out" if passes else "ruled_out"
            else:
                row["target"] = "predicted_met" if passes else "predicted_missed"
        rows.append(row)
        for name, groups in decisions.items():
            if len(choices[name]) == 1:
                continue
            other_values = tuple(v for k, v in inputs.items() if k != name)
            groups.setdefault(other_values, set()).add((trend, row.get("target")))
    gains = [r["improvement"] for r in rows]
    return {"metric": model["metric"], "kind": kind, "better": direction,
            "formula": {k: model[k] for k in expressions}, "basis": basis,
            "unsourced_inputs": [k for k in choices if not basis.get(k)],
            "target": target, "improvement_range": [min(gains), max(gains)],
            "decision_sensitive_inputs": [name for name, groups in decisions.items()
                                          if any(len(outcomes) > 1 for outcomes in groups.values())],
            "scenarios": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("request", help="JSON request file, or - for stdin")
    args = parser.parse_args()
    try:
        result = predict(read_json(args.request))
        print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
    except (ValueError, TypeError, KeyError, ArithmeticError, SyntaxError, OSError) as exc:
        parser.exit(2, f"forecast: {exc}\n")


if __name__ == "__main__":
    main()
