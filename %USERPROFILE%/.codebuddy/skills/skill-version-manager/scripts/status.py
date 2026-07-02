#!/usr/bin/env python3
"""
Status - View team Skills status, history, and diffs.

Operations:
  --list              List all team Skills with review status.
  --detail <name>     Show detailed info for a specific Skill.
  --history <name>    Show SVN change history for a Skill.
  --diff <name>       Compare local vs SVN version.
"""

import json
import os
import sys
import argparse
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import svn_manager
import config_manager


SKILLS_LOCAL_DIR = None  # Lazy — use config_manager.get_skills_dir()

# Status display symbols
STATUS_SYMBOLS = {
    "approved": "✅",
    "pending": "⏳",
    "rejected": "❌",
}


def _get_local_skills_dir(workspace=None):
    base = Path(workspace) if workspace else Path(config_manager.resolve_workspace())
    return base / config_manager.get_skills_dir()


def _load_local_manifest(skill_name, workspace=None):
    skills_dir = _get_local_skills_dir(workspace)
    manifest_path = skills_dir / skill_name / "manifest.json"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return None


def list_all_skills(workspace=None):
    """
    List all team Skills from SVN with their status.

    Returns:
        Tuple of (success: bool, skills: list[dict] | error: str)
    """
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]
    skills_url = f"{svn_url}/skills"

    success, entries = svn_manager.svn_list(skills_url)
    if not success:
        return False, f"Failed to list skills: {entries}"

    skills = []
    for name in entries:
        manifest_url = f"{skills_url}/{name}/manifest.json"
        ok, data = svn_manager.read_json_from_svn(manifest_url)
        if ok:
            # Check if we have a local version
            local_manifest = _load_local_manifest(name, workspace)
            data["_local_version"] = local_manifest.get("version") if local_manifest else None
            skills.append(data)
        else:
            skills.append({
                "skill_name": name,
                "version": "?",
                "status": "unknown",
                "author": "?",
                "_local_version": None,
            })

    return True, skills


def format_skills_list(skills):
    """Format the skills list for display."""
    if not skills:
        return "No Skills found in the repository."

    lines = [
        f"{'='*70}",
        f"  TEAM SKILLS OVERVIEW",
        f"{'='*70}",
        "",
        f"  {'Status':<8} {'Skill Name':<25} {'Version':<10} {'Local':<10} {'Author'}",
        f"  {'-'*65}",
    ]

    # Sort: pending first, then approved, then rejected
    status_order = {"pending": 0, "approved": 1, "rejected": 2, "unknown": 3}
    sorted_skills = sorted(skills, key=lambda s: status_order.get(s.get("status", ""), 3))

    counts = {"pending": 0, "approved": 0, "rejected": 0}

    for skill in sorted_skills:
        status = skill.get("status", "unknown")
        symbol = STATUS_SYMBOLS.get(status, "?")
        name = skill.get("skill_name", "unknown")
        version = skill.get("version", "?")
        local_ver = skill.get("_local_version", "-")
        author = skill.get("author", "?")

        lines.append(f"  {symbol:<8} {name:<25} {version:<10} {local_ver or '-':<10} {author}")

        if status in counts:
            counts[status] += 1

    lines.extend([
        "",
        f"  Total: {len(skills)} | "
        f"Approved: {counts['approved']} | "
        f"Pending: {counts['pending']} | "
        f"Rejected: {counts['rejected']}",
    ])

    return "\n".join(lines)


def get_skill_detail(skill_name, workspace=None):
    """
    Get detailed information for a specific Skill.

    Returns:
        Tuple of (success: bool, detail: dict | error: str)
    """
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured."

    svn_url = config["svn_url"]
    manifest_url = f"{svn_url}/skills/{skill_name}/manifest.json"

    ok, data = svn_manager.read_json_from_svn(manifest_url)
    if not ok:
        return False, f"Skill '{skill_name}' not found: {data}"

    # Add local info
    local_manifest = _load_local_manifest(skill_name, workspace)
    data["_local_version"] = local_manifest.get("version") if local_manifest else None
    data["_local_exists"] = local_manifest is not None

    return True, data


def format_skill_detail(detail):
    """Format skill detail for display."""
    lines = [
        f"{'='*50}",
        f"  SKILL DETAIL: {detail.get('skill_name', 'unknown')}",
        f"{'='*50}",
        "",
        f"  Status:       {STATUS_SYMBOLS.get(detail.get('status'), '?')} {detail.get('status', 'unknown')}",
        f"  Version:      {detail.get('version', 'N/A')}",
        f"  Author:       {detail.get('author', 'N/A')}",
        f"  Description:  {detail.get('description', 'N/A')}",
        f"  Created:      {detail.get('created_at', 'N/A')}",
        f"  Updated:      {detail.get('updated_at', 'N/A')}",
        f"  Changelog:    {detail.get('changelog', 'N/A')}",
    ]

    if detail.get("reviewed_by"):
        lines.append(f"  Reviewed By:  {detail['reviewed_by']}")
        lines.append(f"  Reviewed At:  {detail.get('reviewed_at', 'N/A')}")

    if detail.get("reject_reason"):
        lines.append(f"  Reject Reason: {detail['reject_reason']}")

    deps = detail.get("dependencies", [])
    if deps:
        lines.append(f"  Dependencies: {', '.join(deps)}")

    lines.append("")
    local_ver = detail.get("_local_version")
    if detail.get("_local_exists"):
        lines.append(f"  Local Version: {local_ver}")
        if local_ver == detail.get("version"):
            lines.append("  Local Status: Up to date")
        else:
            lines.append(f"  Local Status: Outdated (local: {local_ver}, SVN: {detail.get('version')})")
    else:
        lines.append("  Local Status: Not installed")

    return "\n".join(lines)


def get_skill_history(skill_name, limit=10, workspace=None):
    """
    Get SVN change history for a specific Skill.

    Returns:
        Tuple of (success: bool, entries: list[dict] | error: str)
    """
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured."

    svn_url = config["svn_url"]
    skill_url = f"{svn_url}/skills/{skill_name}"

    if not svn_manager.path_exists_in_svn(skill_url):
        return False, f"Skill '{skill_name}' not found in SVN."

    success, entries = svn_manager.svn_log(skill_url, limit=limit)
    if not success:
        return False, f"Failed to get history: {entries}"

    return True, entries


def format_history(skill_name, entries):
    """Format SVN history entries for display."""
    if not entries:
        return f"No history found for '{skill_name}'."

    lines = [
        f"{'='*60}",
        f"  SVN HISTORY: {skill_name}",
        f"{'='*60}",
        "",
    ]

    for entry in entries:
        lines.extend([
            f"  r{entry.get('revision', '?')} | {entry.get('author', '?')} | {entry.get('date', '?')}",
            f"    {entry.get('message', '(no message)')}",
            "",
        ])

    return "\n".join(lines)


def diff_skill(skill_name, workspace=None):
    """
    Compare local vs SVN version of a Skill.

    Returns:
        Tuple of (success: bool, diff_info: dict | error: str)
    """
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured."

    svn_url = config["svn_url"]
    manifest_url = f"{svn_url}/skills/{skill_name}/manifest.json"

    # Get SVN manifest
    ok, svn_manifest = svn_manager.read_json_from_svn(manifest_url)
    if not ok:
        return False, f"Skill '{skill_name}' not found in SVN: {svn_manifest}"

    # Get local manifest
    local_manifest = _load_local_manifest(skill_name, workspace)

    diff_info = {
        "skill_name": skill_name,
        "svn_version": svn_manifest.get("version", "?"),
        "svn_status": svn_manifest.get("status", "?"),
        "local_version": local_manifest.get("version", "?") if local_manifest else None,
        "local_exists": local_manifest is not None,
        "in_sync": False,
    }

    if local_manifest and local_manifest.get("version") == svn_manifest.get("version"):
        diff_info["in_sync"] = True

    return True, diff_info


def format_diff(diff_info):
    """Format diff info for display."""
    lines = [
        f"{'='*50}",
        f"  VERSION COMPARISON: {diff_info['skill_name']}",
        f"{'='*50}",
        "",
        f"  SVN Version:   {diff_info['svn_version']}",
        f"  SVN Status:    {diff_info['svn_status']}",
    ]

    if diff_info["local_exists"]:
        lines.append(f"  Local Version: {diff_info['local_version']}")
        if diff_info["in_sync"]:
            lines.append("  Result: IN SYNC (versions match)")
        else:
            lines.append(f"  Result: OUT OF SYNC (local: {diff_info['local_version']}, SVN: {diff_info['svn_version']})")
    else:
        lines.append("  Local Version: (not installed)")
        lines.append("  Result: NOT INSTALLED locally")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="View Skills status and history")
    parser.add_argument("--workspace", default=config_manager.resolve_workspace(), help="Workspace root")

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="List all team Skills")
    group.add_argument("--detail", metavar="SKILL_NAME", help="Show Skill detail")
    group.add_argument("--history", metavar="SKILL_NAME", help="Show SVN history")
    group.add_argument("--diff", metavar="SKILL_NAME", help="Compare local vs SVN")

    parser.add_argument("--limit", type=int, default=10, help="History entry limit")

    args = parser.parse_args()

    if args.list:
        success, result = list_all_skills(args.workspace)
        if success:
            print(format_skills_list(result))
        else:
            print(f"ERROR: {result}")
            sys.exit(1)

    elif args.detail:
        success, result = get_skill_detail(args.detail, args.workspace)
        if success:
            print(format_skill_detail(result))
        else:
            print(f"ERROR: {result}")
            sys.exit(1)

    elif args.history:
        success, result = get_skill_history(args.history, args.limit, args.workspace)
        if success:
            print(format_history(args.history, result))
        else:
            print(f"ERROR: {result}")
            sys.exit(1)

    elif args.diff:
        success, result = diff_skill(args.diff, args.workspace)
        if success:
            print(format_diff(result))
        else:
            print(f"ERROR: {result}")
            sys.exit(1)


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
