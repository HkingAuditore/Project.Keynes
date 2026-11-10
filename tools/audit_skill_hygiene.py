#!/usr/bin/env python3
"""Audit every skill tree in this repository for leaked credentials and
non-portable personal paths, and report drift between the per-IDE copies.

Why this exists
---------------
The same skills are mirrored into several agent/IDE homes (``.agents``,
``.claude``, ``.codebuddy``, ``.codex``, ``.cursor``, ``.dsh`` and the
workspace-level ``.workbuddy`` / ``.cursor``). A secret or a personal path
written into one copy silently multiplies across the others and lands in git.
Run this before committing anything under any ``skills/`` directory.

Usage
-----
    python tools/audit_skill_hygiene.py                # secrets + drift
    python tools/audit_skill_hygiene.py --secrets-only  # only the security pass
    python tools/audit_skill_hygiene.py --drift-only    # only the mirror diff
    python tools/audit_skill_hygiene.py --strict        # drift counts as failure

Exit status is 1 when a hard finding (credential or personal path) is present,
so it can be wired into a pre-commit hook:

    python tools/audit_skill_hygiene.py --secrets-only || exit 1

Only text files are inspected; binaries (``*.pyc``, images) are skipped.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from collections import defaultdict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TEXT_EXT = {
    ".md", ".mdc", ".py", ".json", ".yaml", ".yml", ".txt", ".sh", ".ps1",
    ".bat", ".toml", ".ini", ".cfg", ".gd", ".ts", ".js", ".xml", ".svg", "",
}

SKIP_DIR_PARTS = {
    ".git", "node_modules", ".godot", "__pycache__", ".venv", ".venv-build",
    ".venv-economy-validator", "emsdk", "fmod-studio", "godot-cpp", "godot-cpp-win64",
}

# (label, regex, severity, placeholder-allowlist)
RULES = [
    ("private_key_block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "critical", ()),
    ("aws_access_key_id", re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "critical", ()),
    ("openai_style_key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}"), "critical", ()),
    ("elevenlabs_key", re.compile(r"\bsk_[A-Za-z0-9]{24,}"), "critical", ()),
    ("github_token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"), "critical", ()),
    ("slack_token", re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"), "critical", ()),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b"), "critical", ()),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), "critical", ()),
    ("bearer_token", re.compile(r"[Bb]earer\s+[A-Za-z0-9\-._~+/]{20,}=*"), "critical", ()),
    ("url_with_credentials", re.compile(r"(?i)\b[a-z][a-z0-9+.\-]*://[^/\s:@]{1,40}:[^/\s@]{1,40}@"), "critical", ()),
    ("svn_url_with_credentials", re.compile(r"(?i)svn(\+\w+)?://[^/\s:@]+:[^/\s@]+@"), "critical", ()),
    ("secret_assignment", re.compile(
        r"(?i)\b(api[_\-]?key|apikey|secret[_\-]?key|client[_\-]?secret|access[_\-]?token"
        r"|auth[_\-]?token|password|passwd|pwd|license[_\-]?key)\b\s*[:=]\s*[\"']?([^\s\"',;)\]}]{8,})"),
     "high", ()),
]

PLACEHOLDER_VALUES = {
    "none", "null", "true", "false", "your_key", "your_key_here", "xxx", "***",
    "<token>", "<key>", "value", "string", "env", "optional", "required",
    "changeme", "placeholder", "sk_...", "sk-...",
}
PLACEHOLDER_PREFIXES = ("$", "{", "%", "<", "os.environ", "process.env", "env.")

# Personal / non-portable paths: C:\Users\<name>, /home/<name>, /Users/<name>
PERSONAL_PATH = re.compile(
    r"(?i)(?:\b[A-Z]:[\\/]{1,2}Users[\\/]|/home/|/Users/)"
    r"(?!user\b|username\b|public\b|shared\b|all users\b)([A-Za-z0-9._\-]{2,})")
PERSONAL_PATH_ALLOW = {"user", "username", "public", "shared", "runner", "you", "name", "your_name"}

INTERNAL_HOST = re.compile(r"(?i)\b[a-z0-9.\-]+\.(?:woa\.com|oa\.com|tencent\.com)\b")


def discover_skill_roots() -> list[str]:
    """Every directory named ``skills`` within a few levels of the repo root."""
    roots: list[str] = []
    base_depth = REPO_ROOT.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, _ in os.walk(REPO_ROOT):
        depth = dirpath.count(os.sep) - base_depth
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_DIR_PARTS and not d.startswith(".venv")
        ]
        if depth > 4:
            dirnames[:] = []
            continue
        if os.path.basename(dirpath) == "skills":
            roots.append(dirpath)
            dirnames[:] = []
    parent = os.path.dirname(REPO_ROOT)
    for extra in (".workbuddy/skills", ".cursor/skills"):
        candidate = os.path.join(parent, *extra.split("/"))
        if os.path.isdir(candidate) and candidate not in roots:
            roots.append(candidate)
    return sorted(roots)


def git_tracked_paths() -> set[str]:
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z"], cwd=REPO_ROOT,
            capture_output=True, check=False,
        ).stdout
    except OSError:
        return set()
    return {
        os.path.normcase(os.path.join(REPO_ROOT, p.decode("utf-8", "replace")))
        for p in out.split(b"\x00") if p
    }


def iter_text_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PARTS]
        for name in filenames:
            if os.path.splitext(name)[1].lower() not in TEXT_EXT:
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.path.getsize(path) > 2 * 1024 * 1024:
                    continue
                with open(path, "rb") as fh:
                    head = fh.read(2048)
                if b"\x00" in head:
                    continue
                with open(path, encoding="utf-8", errors="replace") as fh:
                    yield path, fh.read()
            except OSError:
                continue


def scan_secrets(roots, tracked) -> list[tuple]:
    findings = []
    for root in roots:
        for path, text in iter_text_files(root):
            rel = os.path.relpath(path, REPO_ROOT).replace("\\", "/")
            is_tracked = os.path.normcase(path) in tracked
            for lineno, line in enumerate(text.splitlines(), 1):
                for label, rx, severity, _ in RULES:
                    for match in rx.finditer(line):
                        if label == "secret_assignment":
                            value = (match.group(2) or "").strip()
                            low = value.lower()
                            if low in PLACEHOLDER_VALUES or value.startswith(PLACEHOLDER_PREFIXES):
                                continue
                        findings.append((severity, label, rel, lineno, line.strip()[:200], is_tracked))
                for match in PERSONAL_PATH.finditer(line):
                    name = match.group(1)
                    if name.lower() in PERSONAL_PATH_ALLOW:
                        continue
                    findings.append(("high", "personal_path", rel, lineno, line.strip()[:200], is_tracked))
                for match in INTERNAL_HOST.finditer(line):
                    findings.append(("medium", "internal_host", rel, lineno, line.strip()[:200], is_tracked))
    return findings


def file_digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def scan_drift(roots) -> dict[str, dict[str, dict[str, str]]]:
    """skill name -> root label -> {relative path: digest}"""
    table: dict[str, dict[str, dict[str, str]]] = defaultdict(dict)
    for root in roots:
        try:
            label = os.path.relpath(os.path.dirname(root), REPO_ROOT).replace("\\", "/")
        except ValueError:
            label = os.path.dirname(root)
        if label.startswith(".."):
            label = os.path.join("workspace-root", os.path.basename(os.path.dirname(root)))
        for skill in sorted(os.listdir(root)):
            skill_dir = os.path.join(root, skill)
            if not os.path.isdir(skill_dir):
                continue
            files = {}
            for dirpath, dirnames, filenames in os.walk(skill_dir):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PARTS]
                for name in filenames:
                    path = os.path.join(dirpath, name)
                    rel = os.path.relpath(path, skill_dir).replace("\\", "/")
                    try:
                        files[rel] = file_digest(path)
                    except OSError:
                        continue
            table[skill][label] = files
    return table


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--secrets-only", action="store_true", help="skip the mirror-drift report")
    parser.add_argument("--drift-only", action="store_true", help="skip the credential scan")
    parser.add_argument("--strict", action="store_true", help="drift counts as a failure")
    args = parser.parse_args()

    roots = discover_skill_roots()
    tracked = git_tracked_paths()
    print(f"repo       : {REPO_ROOT}")
    print(f"skill roots: {len(roots)}")
    for root in roots:
        rel = os.path.relpath(root, REPO_ROOT).replace("\\", "/")
        count = sum(1 for _ in iter_text_files(root))
        print(f"  - {rel}  ({count} text files)")

    hard = 0
    if not args.drift_only:
        findings = scan_secrets(roots, tracked)
        print("\n== credential / path scan ==")
        if not findings:
            print("  clean: no credential, personal path or internal host found")
        else:
            order = {"critical": 0, "high": 1, "medium": 2}
            findings.sort(key=lambda f: (order.get(f[0], 9), f[1], f[2], f[3]))
            for severity, label, rel, lineno, text, is_tracked in findings:
                tag = "TRACKED" if is_tracked else "local  "
                print(f"  [{severity:8}] {tag} {label}  {rel}:{lineno}")
                print(f"             {text}")
            hard = sum(1 for f in findings if f[0] in ("critical", "high"))
        print(f"  total findings: {len(findings)}  (blocking: {hard})")

    drift_fail = 0
    if not args.secrets_only:
        table = scan_drift(roots)
        print("\n== mirror drift ==")
        for skill in sorted(table):
            copies = table[skill]
            if len(copies) < 2:
                continue
            labels = sorted(copies)
            reference = labels[0]
            diffs = []
            for label in labels[1:]:
                a, b = copies[reference], copies[label]
                only_a = sorted(set(a) - set(b))
                only_b = sorted(set(b) - set(a))
                changed = sorted(p for p in set(a) & set(b) if a[p] != b[p])
                if only_a or only_b or changed:
                    diffs.append((label, only_a, only_b, changed))
            if not diffs:
                continue
            drift_fail += 1
            print(f"  {skill}  ({len(copies)} copies, base={reference})")
            for label, only_a, only_b, changed in diffs:
                parts = []
                if only_a:
                    parts.append(f"missing here: {', '.join(only_a[:3])}")
                if only_b:
                    parts.append(f"extra here: {', '.join(only_b[:3])}")
                if changed:
                    parts.append(f"differs: {', '.join(changed[:3])}")
                print(f"    vs {label}: {'; '.join(parts)}")
        if not drift_fail:
            print("  all mirrored copies are identical")

    print("\n== summary ==")
    print(f"  blocking findings: {hard}")
    print(f"  skills with drift: {drift_fail}")
    if hard or (args.strict and drift_fail):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
