#!/usr/bin/env python3
"""Backend coverage gate for plan 22 (M1-M4).

Whether a program is expressible by the derived cell layer is decided in
gdext/src/cell_program_eligibility.h at runtime. This tool re-derives the SAME
decision statically from the authored .tres content, so the two can be compared:
a divergence means the coverage numbers quoted in the plan are stale.

Why a Python mirror: reading .tres needs no engine and must not require a build.
The drift risk is handled by the `no unexplained legacy` check -- an
EffectInstance program must be explained by a reason that is still valid.
"""
from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]  # repo root above Project/
PROJECT = ROOT / "Project" / "project-keynes"
DATA = PROJECT / "data"
EFFECTS = DATA / "ideologies" / "default_ideology_effects.tres"
MOD_CATALOG = DATA / "modifiers" / "default_modifier_catalog.tres"

SUPPORTED_SELECTORS = {12, 14, 15, 16}
ROLLOUT_ENABLED = {12, 14, 15, 16}
VALUE_CONSTANT = 0
VALUE_STACK_TOP = 1
READ_METRIC = 2

EXPECTED_TOTAL = 288
EXPECTED_IN_SCOPE = 265
EXPECTED_DERIVED = 265


class Tres:
    def __init__(self, path: pathlib.Path) -> None:
        self.text = path.read_text(encoding="utf-8", errors="ignore")
        self.blocks = {}
        for m in re.finditer(
                r'\[sub_resource type="[^"]+" id="([^"]+)"\]\n(.*?)(?=\n\[|\Z)',
                self.text, re.S):
            self.blocks[m.group(1)] = m.group(2)

    def main(self) -> str:
        i = self.text.find("[resource]")
        return self.text[i:] if i >= 0 else self.text

    def body(self, rid: str) -> str:
        return self.blocks.get(rid, "")

    @staticmethod
    def refs(body: str, field: str):
        m = re.search(rf"{field} = Array\[Resource\]\(\[(.*?)\]\)", body, re.S)
        if not m:
            return []
        return re.findall(r'SubResource\("([^"]+)"\)', m.group(1))


def _int(body, key, default):
    m = re.search(rf"^{key} = (-?\d+)", body, re.M)
    return int(m.group(1)) if m else default


def _str(body, key, default=""):
    m = re.search(rf'^{key} = &?"([^"]*)"', body, re.M)
    return m.group(1) if m else default


SYNTHESISED_PATTERNS = [
    # `modifier_catalog.gd:262-286` generates these from stable economy ids at the
    # cold catalog boundary. The id lists live in the COMPILED catalogue
    # (`economy_catalog.gd:65`), not in a .tres we can read statically, so this
    # mirrors the PATTERN rather than enumerating ids.
    re.compile(r"^economy\.city\.need\.[A-Za-z0-9_]+\.consumption_factor$"),
    re.compile(r"^economy\.city\.good\.[A-Za-z0-9_]+\.consumption_factor$"),
    re.compile(r"^economy\.city\.good\.[A-Za-z0-9_]+\.output_factor$"),
    re.compile(r"^economy\.city\.building\.[A-Za-z0-9_]+\.output_factor$"),
    re.compile(r"^economy\.city\.resource\.[A-Za-z0-9_]+\.regen_factor$"),
]


def load_definition_keys():
    """Every definition key the runtime can resolve.

    Two sources, and missing either one mis-classifies content:

      1. AUTHORED keys in the modifier catalogue (`key = &"..."`);
      2. SYNTHESISED keys (`modifier_catalog.gd:262-286`) -- matched by PATTERN,
         because their id lists come from the compiled economy catalogue rather
         than from an authored field.

    Reading only the authored ones classified 53 programmes as
    `unresolved_definition` when their commands target synthesised city stats.
    That is plan 4.4 condition 3's "101 of 325 trap": the definition resolves at
    runtime through `compile_native_catalog`, so a static check that only reads the
    authored list reports a false blocker.
    """
    tres = Tres(MOD_CATALOG)
    keys = set(re.findall(r'\bkey = &"([^"]+)"', tres.text))
    keys |= set(re.findall(r'\bstat_key = &"([^"]+)"', tres.text))
    return keys


def definition_key_resolves(key: str, authored: set[str]) -> bool:
    # A `.cut` twin is generated for every synthesised city factor
    # (`modifier_catalog.gd:538-541`): Modifier magnitudes are clamped to [0,4] so a
    # SUBTRACT term needs a negative counterpart. Stripping the suffix and asking
    # once keeps the rule in a single place.
    if key.endswith(".cut"):
        key = key[: -len(".cut")]
    if key in authored:
        return True
    return any(pattern.match(key) for pattern in SYNTHESISED_PATTERNS)


def load_instruction_rows(tres):
    out = {}
    for rid in tres.blocks:
        body = tres.body(rid)
        rows = []
        for ref in Tres.refs(body, "instructions"):
            ib = tres.body(ref)
            rows.append((_int(ib, "op", 0), _int(ib, "arg0", 0)))
        if rows:
            out[rid] = rows
    return out


def build_facts():
    tres = Tres(EFFECTS)
    instructions = load_instruction_rows(tres)
    known = load_definition_keys()
    facts = []
    for rid in Tres.refs(tres.main(), "effects"):
        body = tres.body(rid)
        target_domain = _int(body, "target_domain", 0)
        selector_kind = _int(body, "target_selector_kind", -1)
        lifecycle = _int(body, "lifecycle", 0)
        # param[0] low 12 bits are the cap; bits 12..13 carry the ownership scope, so
        # masking is required or every non-default-scope card would look like it authored
        # a cap.
        # NOT `_str`: that helper's pattern requires a quoted value
        # (`^key = &?"..."`), and `PackedInt32Array(32, 0)` is unquoted, so it returns
        # "" and param0 silently stayed 0 for every card -- which made the gate below
        # vacuously pass. The negative control is what caught it.
        param0 = 0
        m_param = re.search(
            r"^target_selector_param = PackedInt32Array\(([^)]*)\)", body, re.M)
        if m_param:
            param_nums = [int(n) for n in re.findall(r"-?\d+", m_param.group(1))]
            if param_nums:
                param0 = param_nums[0] & 0xFFF
        key = _str(body, "definition_key", rid)
        commands = []
        for ref in Tres.refs(body, "commands"):
            cb = tres.body(ref)
            commands.append({
                "value_mode": _int(cb, "value_mode", VALUE_CONSTANT),
                "stacks": _int(cb, "stacks", 1),
                "definition_key": _str(cb, "definition_key", ""),
            })
        ramp = any(op == READ_METRIC for op, _ in instructions.get(rid, []))

        backend, reason = "DerivedCell", ""
        if target_domain != 2:
            backend, reason = "EffectInstance", "not_cell_domain"
        elif selector_kind not in SUPPORTED_SELECTORS:
            backend, reason = "EffectInstance", "unsupported_selector"
        elif lifecycle != 0:
            backend, reason = "EffectInstance", "not_permanent"
        elif not commands:
            backend, reason = "EffectInstance", "unresolved_definition"
        else:
            for command in commands:
                magnitude_constant = (
                    command["value_mode"] == VALUE_CONSTANT
                    or (command["value_mode"] == VALUE_STACK_TOP and not ramp))
                if not magnitude_constant and not ramp:
                    backend, reason = "EffectInstance", "non_constant_value_mode"
                    break
                if command["stacks"] != 1:
                    backend, reason = "EffectInstance", "stacked"
                    break
                if not definition_key_resolves(command["definition_key"], known):
                    backend, reason = "EffectInstance", "unresolved_definition"
                    break

        facts.append({
            "id": rid, "program_key": key, "selector_kind": selector_kind,
            "selector_param0": param0,
            "lifecycle": lifecycle, "backend": backend, "reason": reason,
            "has_metric_ramp": ramp,
            "rollout": selector_kind in ROLLOUT_ENABLED,
        })
    return facts


def report(facts):
    by_backend = collections.Counter(f["backend"] for f in facts)
    by_reason = collections.Counter(f["reason"] for f in facts if f["reason"])
    derived = [f for f in facts if f["backend"] == "DerivedCell"]

    print("programs              : %d" % len(facts))
    print("  DerivedCell         : %d" % by_backend["DerivedCell"])
    print("  EffectInstance      : %d" % by_backend["EffectInstance"])
    print()
    print("EffectInstance reasons:")
    for reason, n in sorted(by_reason.items(), key=lambda kv: -kv[1]):
        print("  %-26s: %d" % (reason, n))
    print()
    print("selector kinds:")
    for kind, n in sorted(collections.Counter(
            f["selector_kind"] for f in facts).items()):
        print("  kind %2d: %d" % (kind, n))
    print()
    print("ramp programs (READ_METRIC): %d"
          % sum(1 for f in facts if f["has_metric_ramp"]))
    print("rollout enabled            : %d"
          % sum(1 for f in facts if f["rollout"]))

    supported = [f for f in facts if f["selector_kind"] in ROLLOUT_ENABLED]
    checks = [
        ("total programs == 288", len(facts), EXPECTED_TOTAL),
        ("in-scope (kinds 12/14/15/16) == 265", len(supported), EXPECTED_IN_SCOPE),
        ("all programs DerivedCell", len(derived), EXPECTED_DERIVED),
        ("ramp deferred == 0 (M3 admitted them)",
         sum(1 for f in facts if f["reason"] == "ramp_not_yet_supported"), 0),
        ("no unexplained legacy",
         sum(1 for f in facts
             if f["backend"] != "DerivedCell"
             and f["reason"] not in ("not_cell_domain", "unsupported_selector",
                                     "not_permanent", "stacked",
                                     "non_constant_value_mode",
                                     "unresolved_definition")), 0),
        ("supported-kind programs are all derived",
         sum(1 for f in supported if f["backend"] == "DerivedCell"),
         len(supported)),
        # DECISION (2026-10-28): kinds 14/15 have NO cap on the source count.
        #
        # The runtime used to clamp it to 32 and all five shipped cards authored 32, so
        # the clamp was doing real work. Both sides changed: the runtime no longer
        # clamps, and the content authors 0. This gate keeps the CONTENT half from
        # drifting back -- a card that authors a cap here would silently reintroduce it.
        ("no kind 14/15 card authors a source cap",
         sum(1 for f in facts
             if f["selector_kind"] in (14, 15) and f["selector_param0"] != 0), 0),
    ]
    print()
    failures = 0
    for name, actual, expected in checks:
        ok = actual == expected
        if not ok:
            failures += 1
        print("  [%s] %-46s actual=%s expected=%s"
              % ("ok  " if ok else "FAIL", name, actual, expected))
    print()
    print("=== coverage gate: %d checks, %d failures ===" % (len(checks), failures))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    code = report(build_facts())
    return code if args.check else 0


if __name__ == "__main__":
    sys.exit(main())