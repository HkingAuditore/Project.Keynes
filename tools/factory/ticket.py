"""Ticket parsing and the G0 gate: what a ticket must contain before an agent starts."""

from __future__ import annotations

import fnmatch
import re

CRITERION = re.compile(r"^\s*(?:[-*]\s*\[[ xX]\]|\d+[.)])\s+(.+?)\s*$")
HEADING = re.compile(r"^##\s+(.+?)\s*$")
CRITERIA_TITLES = ("acceptance criteria", "验收标准")


def section(body: str, titles: tuple[str, ...]) -> list[str] | None:
    """Lines under the first `## <title>` heading, up to the next `## `. None if absent."""
    lines = (body or "").splitlines()
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if m and m.group(1).strip().lower() in titles:
            out: list[str] = []
            for rest in lines[i + 1:]:
                if HEADING.match(rest):
                    break
                out.append(rest)
            return out
    return None


def criteria(body: str) -> list[str]:
    """Checkbox (`- [ ] x`) or numbered (`1. x`) items under the acceptance-criteria heading."""
    lines = section(body, CRITERIA_TITLES) or []
    return [m.group(1) for m in (CRITERION.match(l) for l in lines) if m]


def gate(title: str, body: str, labels: list[str], skip_labels: list[str]) -> list[str]:
    """G0: reasons the ticket is not ready for an agent. Empty list = ready."""
    errors: list[str] = []
    if not (title or "").strip():
        errors.append("the ticket has no title")
    if section(body, CRITERIA_TITLES) is None:
        errors.append("the ticket has no '## Acceptance criteria' (or '## 验收标准') section")
    elif not criteria(body):
        errors.append("the acceptance-criteria section has no checkbox or numbered items")
    blocked = sorted(set(labels) & set(skip_labels))
    if blocked:
        errors.append("the ticket carries " + ", ".join(blocked))
    return errors


def matches(path: str, pattern: str) -> bool:
    """A pattern ending in '/' is a folder; one with a wildcard is a glob; anything else is exact."""
    if pattern.endswith("/"):
        return path.startswith(pattern)
    if any(c in pattern for c in "*?["):
        return fnmatch.fnmatchcase(path, pattern)
    return path == pattern


def touching(files: list[str], patterns: list[str]) -> list[str]:
    return sorted(f for f in files if any(matches(f, p) for p in patterns))
