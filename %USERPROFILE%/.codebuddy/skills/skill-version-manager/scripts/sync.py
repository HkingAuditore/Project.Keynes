#!/usr/bin/env python3
"""
Sync - Synchronize Skills between SVN repository and local workspace.

Operations:
  --preview        Show what would change (dry run).
  --pull           Pull approved Skills from SVN to local.
  --skill-name     Optional: sync only a specific Skill.
"""

import json
import os
import sys
import shutil
import argparse
from pathlib import Path
from datetime import datetime, timezone

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import svn_manager
import config_manager


SKILLS_LOCAL_DIR = None  # Lazy — use config_manager.get_skills_dir()
USER_SKILLS_DIR = config_manager._get_codebuddy_home() / "skills"


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _get_local_skills_dir(workspace=None):
    """Get the local .<ide>/skills/ directory path (project-level)."""
    base = Path(workspace) if workspace else Path(config_manager.resolve_workspace())
    return base / config_manager.get_skills_dir()


def _get_user_skills_dir():
    """Get the user-level ~/.<ide>/skills/ directory path."""
    return USER_SKILLS_DIR


def _get_install_dir(install_scope, workspace=None):
    """Get the appropriate skills directory based on install_scope.
    
    Args:
        install_scope: 'user' for user-level, 'project' (default) for project-level.
        workspace: Workspace root path (used for project-level).
    
    Returns:
        Path to the skills directory.
    """
    if install_scope == "user":
        return _get_user_skills_dir()
    return _get_local_skills_dir(workspace)


def _load_local_manifest(skill_name, workspace=None, install_scope="project"):
    """Load manifest.json from a local Skill directory.
    
    Args:
        skill_name: Name of the skill.
        workspace: Workspace root path.
        install_scope: 'user' or 'project' to determine where to look.
    """
    skills_dir = _get_install_dir(install_scope, workspace)
    manifest_path = skills_dir / skill_name / "manifest.json"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    # Fallback: also check the other scope
    other_dir = _get_install_dir("user" if install_scope == "project" else "project", workspace)
    other_path = other_dir / skill_name / "manifest.json"
    if other_path.exists():
        try:
            with open(other_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return None


def get_approved_skills_from_svn(svn_url, skill_name=None):
    """
    Fetch all approved Skills info from SVN.

    Args:
        svn_url: SVN repository URL.
        skill_name: Optional specific Skill to check.

    Returns:
        Tuple of (success: bool, skills: list[dict] | error: str)
        Each dict contains manifest data plus the SVN URL.
    """
    skills_url = f"{svn_url}/skills"

    if skill_name:
        # Check specific skill
        manifest_url = f"{skills_url}/{skill_name}/manifest.json"
        ok, data = svn_manager.read_json_from_svn(manifest_url)
        if not ok:
            return False, f"Failed to read manifest for '{skill_name}': {data}"
        if data.get("status") == "approved":
            data["_svn_url"] = f"{skills_url}/{skill_name}"
            data.setdefault("install_scope", "project")
            return True, [data]
        else:
            return True, []  # Not approved
    else:
        # List all skills
        success, entries = svn_manager.svn_list(skills_url)
        if not success:
            return False, f"Failed to list skills: {entries}"

        approved = []
        for name in entries:
            manifest_url = f"{skills_url}/{name}/manifest.json"
            ok, data = svn_manager.read_json_from_svn(manifest_url)
            if ok and data.get("status") == "approved":
                data["_svn_url"] = f"{skills_url}/{name}"
                data.setdefault("install_scope", "project")
                approved.append(data)

        return True, approved


def preview_sync(workspace=None, skill_name=None):
    """
    Preview what would change during a sync operation.

    Returns:
        Tuple of (success: bool, summary: dict | error: str)
        summary has keys: 'new', 'update', 'unchanged', 'details'
    """
    workspace = workspace or config_manager.resolve_workspace()
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]

    # Get approved skills from SVN
    success, svn_skills = get_approved_skills_from_svn(svn_url, skill_name)
    if not success:
        return False, svn_skills

    summary = {
        "new": [],
        "update": [],
        "unchanged": [],
        "details": [],
    }

    for svn_skill in svn_skills:
        name = svn_skill.get("skill_name", "")
        svn_version = svn_skill.get("version", "")
        install_scope = svn_skill.get("install_scope", "project")
        local_manifest = _load_local_manifest(name, workspace, install_scope)

        if local_manifest is None:
            # New skill, not present locally
            summary["new"].append(name)
            summary["details"].append({
                "skill_name": name,
                "action": "NEW",
                "svn_version": svn_version,
                "local_version": None,
                "author": svn_skill.get("author", ""),
                "description": svn_skill.get("description", ""),
                "install_scope": install_scope,
            })
        elif local_manifest.get("version") != svn_version:
            # Version differs
            summary["update"].append(name)
            summary["details"].append({
                "skill_name": name,
                "action": "UPDATE",
                "svn_version": svn_version,
                "local_version": local_manifest.get("version", ""),
                "author": svn_skill.get("author", ""),
                "changelog": svn_skill.get("changelog", ""),
                "install_scope": install_scope,
            })
        else:
            summary["unchanged"].append(name)
            summary["details"].append({
                "skill_name": name,
                "action": "UNCHANGED",
                "svn_version": svn_version,
                "local_version": local_manifest.get("version", ""),
                "install_scope": install_scope,
            })

    return True, summary


def format_preview(summary):
    """Format a sync preview summary for display."""
    lines = [
        f"{'='*50}",
        "  SYNC PREVIEW",
        f"{'='*50}",
        "",
    ]

    if summary["new"]:
        lines.append(f"  NEW ({len(summary['new'])}):")
        for d in summary["details"]:
            if d["action"] == "NEW":
                scope_tag = "[user]" if d.get("install_scope") == "user" else "[project]"
                lines.append(f"    + {d['skill_name']} v{d['svn_version']} by {d['author']} {scope_tag}")
                if d.get("description"):
                    lines.append(f"      {d['description'][:60]}")
        lines.append("")

    if summary["update"]:
        lines.append(f"  UPDATE ({len(summary['update'])}):")
        for d in summary["details"]:
            if d["action"] == "UPDATE":
                scope_tag = "[user]" if d.get("install_scope") == "user" else "[project]"
                lines.append(f"    ~ {d['skill_name']} {d['local_version']} -> {d['svn_version']} {scope_tag}")
                if d.get("changelog"):
                    lines.append(f"      Changelog: {d['changelog'][:60]}")
        lines.append("")

    if summary["unchanged"]:
        lines.append(f"  UNCHANGED ({len(summary['unchanged'])}):")
        for d in summary["details"]:
            if d["action"] == "UNCHANGED":
                scope_tag = "[user]" if d.get("install_scope") == "user" else "[project]"
                lines.append(f"    = {d['skill_name']} {scope_tag}")
        lines.append("")

    total_changes = len(summary["new"]) + len(summary["update"])
    lines.append(f"  Total changes: {total_changes} (new: {len(summary['new'])}, update: {len(summary['update'])})")

    return "\n".join(lines)


def pull_skills(workspace=None, skill_name=None):
    """
    Pull approved Skills from SVN to local.

    Args:
        workspace: Workspace root path.
        skill_name: Optional specific Skill to pull.

    Returns:
        Tuple of (success: bool, message: str)
    """
    workspace = workspace or config_manager.resolve_workspace()
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]

    # Get approved skills
    success, svn_skills = get_approved_skills_from_svn(svn_url, skill_name)
    if not success:
        return False, svn_skills

    if not svn_skills:
        return True, "No approved Skills to sync."

    synced = []
    errors = []

    for svn_skill in svn_skills:
        name = svn_skill.get("skill_name", "")
        svn_version = svn_skill.get("version", "")
        skill_svn_url = svn_skill.get("_svn_url", "")
        install_scope = svn_skill.get("install_scope", "project")

        # Determine target directory based on install_scope
        target_skills_dir = _get_install_dir(install_scope, workspace)

        # Check if update needed
        local_manifest = _load_local_manifest(name, workspace, install_scope)
        if local_manifest and local_manifest.get("version") == svn_version:
            continue  # Already up to date

        scope_label = "user" if install_scope == "user" else "project"
        print(f"  Syncing {name} v{svn_version} [{scope_label}]...")

        local_skill_dir = target_skills_dir / name

        # Export from SVN to temp, then move to local
        temp_dir = svn_manager.create_temp_dir("sync_")
        try:
            temp_skill_dir = Path(temp_dir) / name
            ok, stdout, stderr = svn_manager.svn_export(skill_svn_url, str(temp_skill_dir))
            if not ok:
                errors.append(f"  Failed to export {name}: {stderr}")
                continue

            # Ensure target directory exists
            target_skills_dir.mkdir(parents=True, exist_ok=True)

            # Remove old local version if exists
            if local_skill_dir.exists():
                shutil.rmtree(local_skill_dir)

            # Move exported skill to local
            shutil.copytree(temp_skill_dir, local_skill_dir)
            synced.append(f"{name} v{svn_version} [{scope_label}]")

        except Exception as e:
            errors.append(f"  Error syncing {name}: {str(e)}")
        finally:
            svn_manager.cleanup_temp_dir(temp_dir)

    # Update sync time
    config_manager.update_sync_time(workspace)

    # Build result message
    result_parts = []
    if synced:
        result_parts.append(f"Synced {len(synced)} Skill(s):")
        for s in synced:
            result_parts.append(f"  ✓ {s}")
    if errors:
        result_parts.append(f"\nErrors ({len(errors)}):")
        result_parts.extend(errors)
    if not synced and not errors:
        result_parts.append("All Skills are already up to date.")

    return len(errors) == 0, "\n".join(result_parts)


def main():
    parser = argparse.ArgumentParser(description="Sync Skills with SVN")
    parser.add_argument("--workspace", default=config_manager.resolve_workspace(), help="Workspace root")
    parser.add_argument("--skill-name", default=None, help="Specific Skill to sync")

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--preview", action="store_true", help="Preview changes (dry run)")
    group.add_argument("--pull", action="store_true", help="Pull approved Skills from SVN")

    args = parser.parse_args()

    if args.preview:
        success, result = preview_sync(args.workspace, args.skill_name)
        if success:
            print(format_preview(result))
        else:
            print(f"ERROR: {result}")
            sys.exit(1)

    elif args.pull:
        success, message = pull_skills(args.workspace, args.skill_name)
        print(message)
        if not success:
            sys.exit(1)


if __name__ == "__main__":
    main()
