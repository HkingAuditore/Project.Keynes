#!/usr/bin/env python3
"""Guard the reviewed committed read boundaries."""
from pathlib import Path
import argparse
import re
from check_cpp_deps import code_only
ROOT = Path(__file__).resolve().parents[2]

def borrowed_owner(code, owner, owner_type, allow_hash=False):
    # Hash-only diagnostics outside the migrated Effect consumer remain legal.
    if allow_hash:
        code = re.sub(rf"{owner}\s*\.\s*snapshot\s*\(\s*\)\s*\.\s*deterministic_state_hash\b", "", code)
    return bool(re.search(rf"\b{owner}\s*\.\s*(?:snapshot|planned_snapshot)\b|"
                          rf"\b{owner}\b(?!\s*\.)|"
                          rf"\b{owner_type}\s*::\s*(?:snapshot|planned_snapshot)\b", code))

def consumer_body(code, name):
    at = code.find(name + "(")
    if at < 0: return ""
    start = code.find("{", at)
    depth = 1
    end = start + 1
    while end < len(code) and depth:
        depth += (code[end] == "{") - (code[end] == "}")
        end += 1
    return code[start:end]

def published_view_violations(opinion, annual):
    errors = []
    for code, label, factory, cursor, forbidden in [
        (opinion, "Economy opinion -> Ideology", "copy_economy_opinion_view", "_opinion_view_version",
         r"_ideology_opinion_snapshot|_ideology_reference_opinions|pin_ideology_reference_opinion|country_class_opinion_snapshot"),
        (annual, "Ideology -> annual report", "copy_annual_ideology_view", "_annual_ideology_view_version",
         r"ideology_pod_snapshot|_ideology_snapshot|_ideology_pod_authority")]:
        if re.search(r"\b(?:" + forbidden + r")\b", code):
            errors.append(label + " bypasses owned committed view")
        if factory not in code or not re.search(r"assert\s*\([^;]*\.observe\s*\(\s*" + cursor + r"\s*\)", code):
            errors.append(label + " missing generation/day assertion")
    return errors

def country_ai_violations(code):
    errors = []
    if re.search(r"\bcountry_ai_digest\b", code):
        errors.append("Country AI bypasses Economy committed view")
    if "copy_country_ai_economy_view" not in code or "economy_view.observe(_country_ai_economy_view_version)" not in code:
        errors.append("Country AI missing generation/day assertion")
    return errors

def annual_country_violations(code):
    errors=[]
    if re.search(r"\b(?:country_asset_snapshot|_country_snapshot|_country_pod_authority)\b", code): errors.append("annual report bypasses Country view")
    if "copy_annual_country_view" not in code or "country_view.observe(_annual_country_view_version)" not in code: errors.append("annual Country view missing assertion")
    return errors

def lineage_opinion_violations(code):
    errors = []
    if re.search(r"\b(?:country_class_opinion_snapshot|_class_opinion_buffers|_class_opinion_committed_buffer)\b", code):
        errors.append("Family metrics bypass Economy committed opinion")
    if "copy_lineage_opinion_view" not in code or "view.observe(_lineage_opinion_view_version)" not in code:
        errors.append("Family opinion missing generation/day assertion")
    return errors

def violations(root):
    path = root / "gdext/src/native_simulation_stage_economy.cpp"
    code = code_only(path.read_text())
    errors = []
    if re.search(r"\b(?:store|planned_store)\s*\(\s*\)|RuntimeClimateAuthority\s*::\s*(?:store|planned_store)|\b(?:snapshot|snapshot_into)\s*\(", code):
        errors.append("Economy stage bypasses Climate committed view")
    if not re.search(r"assert\s*\(\s*_climate_authority\.observe_economy_view\s*\(climate_view\)\s*\)", code):
        errors.append("missing consumer generation/day assertion")
    if "copy_committed_view" not in code:
        errors.append("missing owned committed projection")
    event_code = code_only((root / "gdext/src/native_simulation_host_trigger.cpp").read_text())
    if re.search(r"\bsnapshot\s*\(|RuntimeEventsAuthority\s*::\s*snapshot\b", event_code):
        errors.append("Trigger forwarding bypasses Events committed view")
    if "copy_committed_view" not in event_code:
        errors.append("missing owned Events projection")
    if not re.search(r"assert\s*\(\s*_events_authority\.observe_trigger_view\s*\(events_view\)\s*\)", event_code):
        errors.append("missing Events generation/day assertion")
    ideology_code = code_only((root / "gdext/src/native_simulation_host_ideology.cpp").read_text())
    if borrowed_owner(ideology_code, "_modifier_pod_authority", "RuntimeModifierPodAuthority"):
        errors.append("Ideology bypasses Modifier committed view")
    if "copy_committed_view" not in ideology_code or not re.search(r"assert\s*\(\s*_modifier_pod_authority\.observe_committed_view", ideology_code):
        errors.append("missing Modifier generation/day assertion")
    modifier_code = code_only((root / "gdext/src/native_simulation_host_modifier.cpp").read_text())
    if borrowed_owner(modifier_code, "_effect_pod_authority", "RuntimeEffectPodAuthority", allow_hash=True):
        errors.append("Modifier bypasses Effect committed view")
    if "copy_committed_view" not in modifier_code or not re.search(r"assert\s*\(\s*_effect_pod_authority\.observe_committed_view", modifier_code):
        errors.append("missing Effect generation/day assertion")
    annual_code = code_only((root / "gdext/src/annual_development_host.cpp").read_text())
    errors += published_view_violations(
        consumer_body(ideology_code, "execute_ideology_worker_stage"),
        consumer_body(annual_code, "commit_annual_worker_day"))
    ai_path = root / "gdext/src/native_simulation_host_country_stage.cpp"
    errors += country_ai_violations(code_only(ai_path.read_text()))
    errors += annual_country_violations(consumer_body(annual_code, "commit_annual_worker_day"))
    family = code_only((root / "gdext/src/economy_runtime_family_buff.cpp").read_text())
    errors += lineage_opinion_violations(consumer_body(family, "refresh_class_opinion_metrics"))
    return errors

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = violations(args.root)
    for error in errors: print(error)
    print(f"committed views: 9 guarded edges, {len(errors)} violations")
    return bool(errors)
if __name__ == "__main__":
    raise SystemExit(main())
