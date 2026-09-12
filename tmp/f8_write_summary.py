# -*- coding: utf-8 -*-
import json
from pathlib import Path

root = Path("artifacts/runtime/authority-effect-f8-20260912")
summary = {}
for name in ("active-22", "off-22"):
    log = (root / name / "soak.log").read_text(encoding="utf-8", errors="replace")
    js = json.loads((root / name / "soak.json").read_text(encoding="utf-8"))
    lines = [ln for ln in log.splitlines() if "[soak/effect-report]" in ln]
    out = {
        "first_bad_tick": js.get("first_bad_tick"),
        "writeback_drop_count": js.get("writeback_drop_count"),
        "delivery_mask": js.get("delivery", {}).get("authoritative_domain_mask"),
    }
    if lines:
        payload = lines[-1].split("[soak/effect-report]", 1)[1].strip()
        for part in payload.split(", "):
            if "=" in part:
                k, v = part.split("=", 1)
                out[k] = v
    summary[name] = out

(root / "f8-soak-effect-summary.json").write_text(
    json.dumps(summary, indent=2) + "\n", encoding="utf-8"
)
print(json.dumps(summary, indent=2))
