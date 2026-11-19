"""Codex calls. Codex writes code; the factory decides what happens next from facts."""

from __future__ import annotations

from pathlib import Path

from common import FACTORY, sh
from ticket import section


def render(name: str, **values: str) -> str:
    text = (FACTORY / "prompts" / f"{name}.md").read_text(encoding="utf-8")
    for key, value in values.items():
        text = text.replace("{" + key + "}", value)
    return text


def codex(cfg: dict, workdir: str, prompt: str, report: str, writable: bool) -> dict:
    a = cfg["agent"]
    args = [cfg["tools"]["codex"], "exec", "-C", workdir, "-m", a["model"],
            "-c", f'model_reasoning_effort="{a["effort"]}"',
            "-s", "workspace-write" if writable else "read-only",
            "--skip-git-repo-check", "-o", report, "-"]
    r = sh(args, stdin=prompt, timeout=a["timeoutMinutes"] * 60, log=report + ".log")
    text = Path(report).read_text(encoding="utf-8") if Path(report).exists() else ""
    return {"ok": r.ok, "code": r.code, "report": text, "log": report + ".log"}


def failure_reason(out: dict) -> str:
    code = out["code"]
    return "Codex timed out (exit 124)" if code == 124 else f"Codex failed (exit {code})"


def parse_disputes(text: str | None, findings: list[dict]) -> list[tuple[str, str]]:
    ids = {str(f["id"]) for f in findings}
    disputes, bad = [], []
    for line in (text or "").splitlines():
        if not line.strip():
            continue
        finding_id, colon, evidence = line[2:].partition(":")
        if (line.startswith("- ") and colon and finding_id in ids
                and evidence.startswith(" ") and evidence.strip()):
            disputes.append((finding_id, evidence.strip()))
        else:
            bad.append(repr(line))
    if bad:
        raise ValueError("invalid lines in .factory-disagree.md: " + ", ".join(bad))
    return disputes


def _items(lines: list[str] | None) -> list[str]:
    out = []
    for line in lines or []:
        s = line.strip().lstrip("-*").strip().strip("`").strip()
        if s and s.lower() not in ("none", "无", "n/a"):
            out.append(s)
    return out


def plan_checks(plan: str) -> list[str]:
    return _items(section(plan, ("checks",)))


def plan_questions(plan: str) -> list[str]:
    return _items(section(plan, ("questions",)))


def plan_complete(plan: str) -> list[str]:
    """Section headings the plan is missing."""
    need = ("fit", "reuse", "affected", "plan", "checks", "questions")
    return [h for h in need if section(plan, (h,)) is None]
