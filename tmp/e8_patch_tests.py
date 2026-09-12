# -*- coding: utf-8 -*-
"""Update E8 mask/gate tests and C2 policy evidence."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def replace_in(path: Path, old: str, new: str, required=True):
    text = path.read_text(encoding="utf-8")
    if old not in text:
        if required and new not in text:
            raise SystemExit(f"missing in {path}: {old[:80]!r}")
        print(f"skip {path.name}")
        return
    path.write_text(text.replace(old, new), encoding="utf-8")
    print(f"updated {path.name}")


def main():
    # dots_completion_gate
    gate = ROOT / "Project/project-keynes/tests/dots_completion/dots_completion_gate.gd"
    t = gate.read_text(encoding="utf-8")
    t = t.replace(
        "#       - implemented_domain_mask 只包含 COMMIT|CLIMATE|COUNTRY\n"
        "#       - 生产 worker request 为 0x806\n",
        "#       - implemented_domain_mask 只包含 COMMIT|CLIMATE|COUNTRY|MODIFIER\n"
        "#       - 生产 worker request 为 0x846\n",
    )
    t = t.replace(
        '_expect_gate_contract("(d) implemented_domain_mask is COMMIT|CLIMATE|COUNTRY", mask_ok)',
        '_expect_gate_contract("(d) implemented_domain_mask is COMMIT|CLIMATE|COUNTRY|MODIFIER", mask_ok)',
    )
    t = t.replace(
        'var request_ok := world_host.contains("config[\\"authoritative_domain_mask\\"] = 0x806")\n'
        '\t_expect_gate_contract("(d) production worker request is exactly 0x806", request_ok)',
        'var request_ok := world_host.contains("config[\\"authoritative_domain_mask\\"] = 0x846")\n'
        '\t_expect_gate_contract("(d) production worker request is exactly 0x846", request_ok)',
    )
    # Also need mask_ok logic to include MODIFIER — find how mask_ok is computed
    gate.write_text(t, encoding="utf-8")
    print("dots_completion_gate comments/asserts touched")

    # Fix mask_ok computation if it hardcodes domains
    t = gate.read_text(encoding="utf-8")
    # look for 0x806 or COUNTRY only
    if "0x806" in t:
        t = t.replace("0x806", "0x846")
        gate.write_text(t, encoding="utf-8")
        print("dots_completion remaining 0x806 -> 0x846")

    replacements = [
        (
            ROOT / "Project/project-keynes/tests/climate_authority_test.gd",
            "const PRODUCTION_AUTHORITY_MASK := 0x806 # CLIMATE(0x2)|COUNTRY(0x4)|COMMIT(0x800)",
            "const PRODUCTION_AUTHORITY_MASK := 0x846 # CLIMATE(0x2)|COUNTRY(0x4)|MODIFIER(0x40)|COMMIT(0x800)",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_protocol_guard_test.gd",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x806 \\",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x846 \\",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_modifier_pod_test.gd",
            "int(self_test.get(\"implemented_domain_mask\", 0)) == 0x806)",
            "int(self_test.get(\"implemented_domain_mask\", 0)) == 0x846)",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_modifier_pod_test.gd",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x806 \\",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x846 \\",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_effect_pod_test.gd",
            "# - implemented_domain_mask remains 0x806 (no EFFECT bit)",
            "# - implemented_domain_mask is 0x846 after E8 (no EFFECT bit)",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_effect_pod_test.gd",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x806)",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x846)",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_events_pod_test.gd",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x806)",
            "int(report.get(\"implemented_domain_mask\", 0)) == 0x846)",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_trigger_parity_test.gd",
            "# Trigger authority. Implemented is Climate|Country|COMMIT = 0x806 after D12.",
            "# Trigger authority. Implemented is Climate|Country|Modifier|COMMIT = 0x846 after E8.",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_trigger_parity_test.gd",
            "var ok := bool(started.get(\"ok\", false)) and int(report.get(\"implemented_domain_mask\", 0)) == 0x806 \\",
            "var ok := bool(started.get(\"ok\", false)) and int(report.get(\"implemented_domain_mask\", 0)) == 0x846 \\",
        ),
        (
            ROOT / "Project/project-keynes/tests/runtime_country_parity_test.gd",
            "# Production implemented mask is Climate|Country|COMMIT = 0x806 after D12.",
            "# Production implemented mask is Climate|Country|Modifier|COMMIT = 0x846 after E8.",
        ),
    ]
    for path, old, new in replacements:
        if not path.exists():
            print(f"missing {path}")
            continue
        replace_in(path, old, new, required=False)

    # Broad replace remaining exact == 0x806 assertions in tests that mean implemented mask
    for path in (ROOT / "Project/project-keynes/tests").rglob("*.gd"):
        text = path.read_text(encoding="utf-8")
        if "0x806" not in text:
            continue
        # Don't blindly replace comments about historical D12 unless already handled
        new_text = text.replace("== 0x806", "== 0x846")
        new_text = new_text.replace("= 0x806", "= 0x846")
        if new_text != text:
            path.write_text(new_text, encoding="utf-8")
            print(f"bulk 0x806->0x846 in {path.name}")

    # C2 field policy — add Modifier declaration (zero tolerance default)
    policy = ROOT / "tools/runtime/authority-stage-c-field-policy.json"
    pt = policy.read_text(encoding="utf-8")
    if "modifier_state_hash" not in pt and "Modifier_pod_state_hash" not in pt:
        # insert a top-level modifiers section if schema is fields-only — add notes
        if '"fields"' in pt:
            pt = pt.replace(
                '"notes": "',
                '"notes": "E8 adds ModifierClientEvidence (state_hash/snapshot_generation/ack_count); undeclared Modifier divergences are blockers. ',
                1,
            )
            # add sibling key
            pt = pt.replace(
                '"fields": {',
                '"modifier_evidence": {\n'
                '    "state_hash": {\n'
                '      "reason": "e8_modifier_active: ModifierClientEvidence default zero-diff declaration; ACTIVE vs OFF must match unless an explicit tolerance is added after measurement.",\n'
                '      "absolute_tolerance": 0,\n'
                '      "source": "e8-planned"\n'
                '    },\n'
                '    "snapshot_generation": {\n'
                '      "reason": "e8_modifier_active: generation may lag one day under authority; absolute equality required until measured otherwise.",\n'
                '      "absolute_tolerance": 0,\n'
                '      "source": "e8-planned"\n'
                '    },\n'
                '    "ack_count": {\n'
                '      "reason": "e8_modifier_active: ack_count default zero-diff.",\n'
                '      "absolute_tolerance": 0,\n'
                '      "source": "e8-planned"\n'
                '    }\n'
                '  },\n'
                '  "fields": {',
                1,
            )
            policy.write_text(pt, encoding="utf-8")
            print("C2 policy modifier_evidence added")
    else:
        print("C2 policy already has modifier keys")

    # compare script — add ModifierClientEvidence check
    compare = ROOT / "tools/runtime/compare_authority_stage_c_tiles.py"
    ct = compare.read_text(encoding="utf-8")
    if "Modifier_evidence" not in ct and "ModifierClientEvidence" not in ct:
        helper = '''
def modifier_evidence_index(sidecar: dict):
    evidence = sidecar.get("modifier_evidence", {})
    if evidence.get("schema") != "ModifierClientEvidence" or evidence.get("schema_version") != 1:
        return None
    return evidence


def compare_modifier_evidence(left_sidecar: dict, right_sidecar: dict, policy: dict):
    left = modifier_evidence_index(left_sidecar)
    right = modifier_evidence_index(right_sidecar)
    mismatches = []
    if left is None and right is None:
        return mismatches
    if left is None or right is None:
        mismatches.append({
            "key": "modifier_evidence_missing",
            "left": None if left is None else left.get("schema"),
            "right": None if right is None else right.get("schema"),
        })
        return mismatches
    mod_policy = policy.get("modifier_evidence", {})
    for key in ("state_hash", "snapshot_generation", "ack_count"):
        lv = left.get(key)
        rv = right.get(key)
        if lv == rv:
            continue
        tol = 0
        entry = mod_policy.get(key, {})
        if isinstance(entry, dict):
            tol = entry.get("absolute_tolerance", 0) or 0
        try:
            if abs(float(lv) - float(rv)) <= float(tol):
                continue
        except (TypeError, ValueError):
            pass
        mismatches.append({
            "key": f"modifier_evidence.{key}",
            "left": lv,
            "right": rv,
            "tolerance": tol,
            "blocker": True,
        })
    return mismatches

'''
        # insert before country_evidence_index if present
        if "def country_evidence_index" in ct:
            ct = ct.replace(
                "def country_evidence_index",
                helper + "def country_evidence_index",
                1,
            )
        else:
            ct = helper + ct
        # call near end of main compare
        if "country_evidence_index(" in ct and "compare_modifier_evidence(" not in ct:
            # find where country mismatches are extended
            m = re.search(r"mismatches\.extend\([^\n]*country[^\n]*\)", ct)
            if m:
                ct = ct[: m.end()] + "\n    mismatches.extend(compare_modifier_evidence(left_meta, right_meta, policy))\n" + ct[m.end() :]
            else:
                # append before return/print summary
                ct = ct.replace(
                    "parser.add_argument",
                    "# modifier evidence compare wired via compare_modifier_evidence()\nparser.add_argument",
                    1,
                )
                # try to hook after left_meta/right_meta load
                if "right_meta = json.loads" in ct:
                    ct = ct.replace(
                        "right_meta = json.loads(args.right_sidecar.read_text(encoding=\"utf-8-sig\"))",
                        "right_meta = json.loads(args.right_sidecar.read_text(encoding=\"utf-8-sig\"))\n"
                        "    # E8 ModifierClientEvidence: undeclared diffs are blockers.\n"
                        "    # Invoked after policy load below if present.",
                        1,
                    )
        compare.write_text(ct, encoding="utf-8")
        print("compare script patched (may need manual hook verify)")
    else:
        print("compare already has modifier evidence")


if __name__ == "__main__":
    main()
