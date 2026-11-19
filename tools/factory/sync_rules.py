"""Create the Qodo rules in docs/factory/qodo-rules.json that the workspace does not have yet.

Matches by name only. Never edits or deletes an existing rule (change those in the Qodo portal,
then update the JSON to match). Default is a dry run; pass --apply to create.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import load_config, sh  # noqa: E402

RULES = Path(__file__).resolve().parents[2] / "docs" / "factory" / "qodo-rules.json"


def existing(qodo: str, scope: str) -> dict[str, dict]:
    names: dict[str, dict] = {}
    page = 1
    while True:
        args = json.dumps({"scopes": [scope], "page": page, "page_size": 100})
        r = sh([qodo, "read", "rules", "list", "--args", args, "--json"], timeout=120)
        if not r.ok:
            raise SystemExit(f"rules list failed: {(r.err or r.out).strip()[-400:]}")
        data = json.loads(r.out[r.out.find("{"):])
        for rule in data.get("rules") or []:
            names[rule["name"]] = rule
        if page * 100 >= int(data.get("totalCount") or 0):
            return names
        page += 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    qodo = load_config()["tools"]["qodo"]
    spec = json.loads(RULES.read_text(encoding="utf-8"))
    have = existing(qodo, spec["scope"])
    for rule in spec["rules"]:
        name = rule["name"]
        if name in have:
            print(f"exists  {have[name].get('state')}  {name}")
            continue
        if not a.apply:
            print(f"missing {name}")
            continue
        body = {k: rule[k] for k in ("name", "category", "severity", "content", "good_examples", "bad_examples")}
        body["scopes"] = [spec["scope"]]
        key = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:32]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fh:
            json.dump(body, fh, ensure_ascii=False)
        r = sh([qodo, "rules", "create", "--args-file", fh.name, "--idempotency-key", key, "--json"], timeout=120)
        Path(fh.name).unlink(missing_ok=True)
        if not r.ok:
            print(f"FAILED  {name}: {(r.err or r.out).strip()[-300:]}")
            continue
        made = json.loads(r.out[r.out.find("{"):])
        print(f"created {made.get('state')}  {made.get('ruleId')}  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
