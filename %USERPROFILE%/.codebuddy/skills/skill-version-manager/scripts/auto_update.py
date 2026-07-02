#!/usr/bin/env python3
"""
Auto Update - Check and update installed Skills from SVN.

Update policy:
  - skill-version-manager (self): AUTO-UPDATE silently, no user confirmation.
  - Other Skills: CHECK only, then ASK USER before applying updates.

This ensures the management tool is always up-to-date while giving users
control over which other Skills get updated.

**Self-update**: Downloads new version to a temp directory first, then
replaces local files — so the running script doesn't overwrite itself
mid-execution.

Operations:
  --check          Check for updates (dry run, no changes).
  --update         Check and apply updates (for specified or all Skills).
  --self-update    Only update skill-version-manager itself (auto, no confirm).
  --skill <name>   Only check/update a specific Skill.

Options:
  --quiet          Suppress detailed output, only show summary.
  --force          Force update even if versions match.
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

# Standard skill directories (IDE-aware)
USER_SKILLS_DIR = config_manager._get_codebuddy_home() / "skills"
PROJECT_SKILLS_DIR = config_manager.get_skills_dir()

# Our own skill name
SELF_SKILL_NAME = "skill-version-manager"


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_local_manifest(skill_dir):
    """Load manifest.json from a local Skill directory."""
    manifest_path = skill_dir / "manifest.json"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return None


def _get_svn_manifest(svn_url, skill_name, local_path=None):
    """Read a Skill's manifest.json from SVN.

    First tries to read .svn-source.json from the local install to get the
    exact SVN URL (supports nested directories like skills/shared/unity/xxx).
    Falls back to the flat path: {svn_url}/skills/{skill_name}/manifest.json.
    """
    # Try .svn-source.json for the exact SVN URL
    if local_path:
        source_file = Path(local_path) / ".svn-source.json"
        if source_file.exists():
            try:
                with open(source_file, "r", encoding="utf-8") as f:
                    source_info = json.load(f)
                skill_svn_url = source_info.get("svn_url", "").rstrip("/")
                if skill_svn_url:
                    manifest_url = f"{skill_svn_url}/manifest.json"
                    ok, data = svn_manager.read_json_from_svn(manifest_url)
                    if ok:
                        return data
            except (json.JSONDecodeError, IOError):
                pass

    # Fallback: flat path
    manifest_url = f"{svn_url}/skills/{skill_name}/manifest.json"
    ok, data = svn_manager.read_json_from_svn(manifest_url)
    if ok:
        return data
    return None


def _version_tuple(version_str):
    """Parse version string to tuple for comparison. e.g., '2.1.0' -> (2, 1, 0)."""
    try:
        parts = version_str.strip().split(".")
        return tuple(int(p) for p in parts)
    except (ValueError, AttributeError):
        return (0, 0, 0)


def _is_newer(svn_version, local_version):
    """Check if SVN version is newer than local version."""
    return _version_tuple(svn_version) > _version_tuple(local_version)


# ─── Scan installed Skills ───────────────────────────────────────────


def _has_skill_md(directory):
    """Check if a directory contains a SKILL.md file (case-insensitive)."""
    return any(f.name.lower() == "skill.md" for f in directory.iterdir() if f.is_file())


def scan_installed_skills(workspace=None):
    """
    Scan all locally installed Skills (both user and project level).

    Returns:
        list of dict: Each has 'name', 'path', 'scope', 'version'
    """
    installed = []

    # User-level skills
    if USER_SKILLS_DIR.exists():
        for d in sorted(USER_SKILLS_DIR.iterdir()):
            if d.is_dir() and not d.name.startswith(".") and _has_skill_md(d):
                manifest = _load_local_manifest(d)
                installed.append({
                    "name": d.name,
                    "path": d,
                    "scope": "user",
                    "version": manifest.get("version", "unknown") if manifest else "unknown",
                })

    # Project-level skills
    if workspace:
        project_dir = Path(workspace) / PROJECT_SKILLS_DIR
        if project_dir.exists():
            for d in sorted(project_dir.iterdir()):
                if d.is_dir() and not d.name.startswith(".") and _has_skill_md(d):
                    # Skip if already found at user level (user takes precedence)
                    if any(s["name"] == d.name and s["scope"] == "user" for s in installed):
                        continue
                    manifest = _load_local_manifest(d)
                    installed.append({
                        "name": d.name,
                        "path": d,
                        "scope": "project",
                        "version": manifest.get("version", "unknown") if manifest else "unknown",
                    })

    return installed


# ─── Check for updates ───────────────────────────────────────────────


def check_updates(svn_url, installed_skills, specific_skill=None):
    """
    Check installed Skills against SVN for available updates.

    Args:
        svn_url: SVN repository base URL.
        installed_skills: List from scan_installed_skills().
        specific_skill: Optional name to check only one Skill.

    Returns:
        list of dict: Skills that have updates available.
        Each has: name, path, scope, local_version, svn_version, action
    """
    updates = []

    for skill in installed_skills:
        name = skill["name"]
        if specific_skill and name != specific_skill:
            continue

        svn_manifest = _get_svn_manifest(svn_url, name, local_path=skill.get("path"))
        if not svn_manifest:
            # Skill not in SVN, skip
            continue

        svn_version = svn_manifest.get("version", "unknown")
        local_version = skill["version"]

        if _is_newer(svn_version, local_version):
            updates.append({
                "name": name,
                "path": skill["path"],
                "scope": skill["scope"],
                "local_version": local_version,
                "svn_version": svn_version,
                "changelog": svn_manifest.get("changelog", ""),
                "action": "update",
            })
        elif local_version == "unknown" or svn_version == "unknown":
            # Can't compare properly, flag as potential update
            updates.append({
                "name": name,
                "path": skill["path"],
                "scope": skill["scope"],
                "local_version": local_version,
                "svn_version": svn_version,
                "changelog": svn_manifest.get("changelog", ""),
                "action": "check_needed",
            })

    return updates


# ─── Apply updates ───────────────────────────────────────────────────


def update_skill(svn_url, skill_info, quiet=False):
    """
    Update a single Skill from SVN.

    For skill-version-manager itself, uses a safe two-phase approach:
    1. Export new version to temp directory
    2. Replace local files with temp contents

    Args:
        svn_url: SVN repository base URL.
        skill_info: Dict with name, path, scope, etc.
        quiet: Suppress detailed output.

    Returns:
        Tuple of (success: bool, message: str)
    """
    name = skill_info["name"]
    target_dir = skill_info["path"]

    # Resolve SVN URL: prefer .svn-source.json, fallback to flat path
    skill_svn_url = None
    source_file = Path(target_dir) / ".svn-source.json"
    if source_file.exists():
        try:
            with open(source_file, "r", encoding="utf-8") as f:
                source_info = json.load(f)
            skill_svn_url = source_info.get("svn_url", "").rstrip("/")
        except (json.JSONDecodeError, IOError):
            pass
    if not skill_svn_url:
        skill_svn_url = f"{svn_url}/skills/{name}"

    if not quiet:
        print(f"  Updating {name}: {skill_info['local_version']} -> {skill_info['svn_version']}")

    # Export from SVN to temp
    temp_dir = svn_manager.create_temp_dir(f"update_{name}_")
    try:
        temp_skill_dir = Path(temp_dir) / name
        ok, stdout, stderr = svn_manager.svn_export(skill_svn_url, str(temp_skill_dir))
        if not ok:
            return False, f"SVN export failed for '{name}': {stderr}"

        # Verify the export has SKILL.md
        if not (temp_skill_dir / "SKILL.md").exists():
            return False, f"Downloaded version of '{name}' is invalid (missing SKILL.md)"

        # For self-update (skill-version-manager), be extra careful
        is_self_update = (name == SELF_SKILL_NAME)

        if is_self_update and not quiet:
            print(f"  [Self-update] Replacing {target_dir}")

        # Remove old directory contents
        if target_dir.exists():
            for item in target_dir.iterdir():
                if item.name.startswith("."):
                    continue  # Skip hidden dirs like .svn
                try:
                    if item.is_dir():
                        shutil.rmtree(item)
                    else:
                        item.unlink()
                except PermissionError as e:
                    if not quiet:
                        print(f"  Warning: Could not remove {item}: {e}")

        # Copy new files from temp to target
        target_dir.mkdir(parents=True, exist_ok=True)
        for item in temp_skill_dir.iterdir():
            dst = target_dir / item.name
            try:
                if item.is_dir():
                    shutil.copytree(item, dst)
                else:
                    shutil.copy2(item, dst)
            except PermissionError as e:
                if not quiet:
                    print(f"  Warning: Could not copy {item.name}: {e}")

        return True, (
            f"Updated '{name}': {skill_info['local_version']} -> {skill_info['svn_version']}"
        )

    except Exception as e:
        return False, f"Error updating '{name}': {str(e)}"
    finally:
        svn_manager.cleanup_temp_dir(temp_dir)


def apply_updates(svn_url, updates, quiet=False):
    """
    Apply all available updates.

    Processes self-update (skill-version-manager) LAST to ensure
    other updates use the current version of the update logic.

    Args:
        svn_url: SVN repository base URL.
        updates: List from check_updates().
        quiet: Suppress detailed output.

    Returns:
        Tuple of (success: bool, summary: str)
    """
    if not updates:
        return True, "All installed Skills are up to date."

    # Sort: regular skills first, self-update last
    regular = [u for u in updates if u["name"] != SELF_SKILL_NAME]
    self_updates = [u for u in updates if u["name"] == SELF_SKILL_NAME]
    ordered = regular + self_updates

    succeeded = []
    failed = []

    for skill_info in ordered:
        if skill_info["action"] == "check_needed":
            # Force update when version can't be compared
            skill_info["action"] = "update"

        ok, msg = update_skill(svn_url, skill_info, quiet)
        if ok:
            succeeded.append(msg)
        else:
            failed.append(msg)

    # Build summary
    parts = []
    if succeeded:
        parts.append(f"Updated {len(succeeded)} Skill(s):")
        for msg in succeeded:
            parts.append(f"  + {msg}")
    if failed:
        parts.append(f"Failed {len(failed)}:")
        for msg in failed:
            parts.append(f"  ! {msg}")
    if not failed:
        parts.append("\nAll updates applied successfully.")

    return len(failed) == 0, "\n".join(parts)


# ─── Format output ───────────────────────────────────────────────────


def format_check_result(updates, installed_count):
    """Format update check results for display.

    Output is structured so AI can distinguish:
    - SELF_UPDATE_AVAILABLE: skill-version-manager needs update (auto-apply)
    - OTHER_UPDATES_AVAILABLE: other Skills need update (ask user first)
    """
    lines = []

    if not updates:
        lines.append(f"ALL_UP_TO_DATE: All {installed_count} installed Skill(s) are up to date.")
        return "\n".join(lines)

    # Separate self-updates from other updates
    self_updates = [u for u in updates if u["name"] == SELF_SKILL_NAME]
    other_updates = [u for u in updates if u["name"] != SELF_SKILL_NAME]

    lines.extend([
        f"{'='*55}",
        f"  UPDATES AVAILABLE",
        f"{'='*55}",
        "",
    ])

    # Self-update section
    if self_updates:
        lines.append("SELF_UPDATE_AVAILABLE:")
        for u in self_updates:
            lines.append(
                f"  [AUTO]  {u['name']:<25} "
                f"{u['local_version']:>8} -> {u['svn_version']:<8} "
                f"[{u['scope']}]"
            )
            if u.get("changelog"):
                cl = u["changelog"][:70]
                lines.append(f"           {cl}")
        lines.append("")

    # Other updates section
    if other_updates:
        lines.append("OTHER_UPDATES_AVAILABLE:")
        for u in other_updates:
            status = "UPDATE" if u["action"] == "update" else "CHECK"
            lines.append(
                f"  [{status}]  {u['name']:<25} "
                f"{u['local_version']:>8} -> {u['svn_version']:<8} "
                f"[{u['scope']}]"
            )
            if u.get("changelog"):
                cl = u["changelog"][:70]
                lines.append(f"           {cl}")
        lines.append("")

    # Summary
    summary_parts = []
    if self_updates:
        summary_parts.append(f"{len(self_updates)} self-update (will auto-apply)")
    if other_updates:
        summary_parts.append(f"{len(other_updates)} other Skill update(s) (requires user confirmation)")
    lines.append(f"  {', '.join(summary_parts)} out of {installed_count} installed.")
    lines.append("")

    if self_updates:
        lines.append("  Run with --self-update to auto-apply skill-version-manager update.")
    if other_updates:
        lines.append("  Ask user before running --update to apply other Skill updates.")

    return "\n".join(lines)


# ─── Main entry point ────────────────────────────────────────────────


def auto_check(workspace=None, specific_skill=None):
    """
    Check for available updates. Returns structured data for programmatic use.

    Returns:
        Tuple of (success: bool, result: dict)
        result keys:
          - 'updates' (list): all updates
          - 'self_updates' (list): skill-version-manager updates (auto-apply)
          - 'other_updates' (list): other Skill updates (ask user first)
          - 'installed_count' (int)
          - 'message' (str)
    """
    workspace = workspace or config_manager.resolve_workspace()

    config = config_manager.load_local_config(workspace)
    if not config:
        return False, {
            "updates": [],
            "self_updates": [],
            "other_updates": [],
            "installed_count": 0,
            "message": "Not configured. Run init_repo.py --init first.",
        }

    svn_url = config["svn_url"]

    # Scan installed skills
    installed = scan_installed_skills(workspace)
    if not installed:
        return True, {
            "updates": [],
            "self_updates": [],
            "other_updates": [],
            "installed_count": 0,
            "message": "No Skills installed locally.",
        }

    # Check for updates
    updates = check_updates(svn_url, installed, specific_skill)

    # Serialize paths for JSON output
    for u in updates:
        u["path"] = str(u["path"])

    # Separate self-updates from other updates
    self_updates = [u for u in updates if u["name"] == SELF_SKILL_NAME]
    other_updates = [u for u in updates if u["name"] != SELF_SKILL_NAME]

    return True, {
        "updates": updates,
        "self_updates": self_updates,
        "other_updates": other_updates,
        "installed_count": len(installed),
        "message": format_check_result(updates, len(installed)),
    }


def auto_update(workspace=None, specific_skill=None, quiet=False, force=False):
    """
    Check and apply all available updates.

    Args:
        workspace: Workspace root path.
        specific_skill: Only update this Skill.
        quiet: Suppress detailed output.
        force: Force update even if versions match.

    Returns:
        Tuple of (success: bool, message: str)
    """
    workspace = workspace or config_manager.resolve_workspace()

    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]

    # Scan installed skills
    installed = scan_installed_skills(workspace)
    if not installed:
        return True, "No Skills installed locally."

    if not quiet:
        print(f"Checking {len(installed)} installed Skill(s) for updates...")

    # Check for updates
    updates = check_updates(svn_url, installed, specific_skill)

    # Force mode: also "update" Skills that appear up-to-date
    if force and specific_skill:
        if not updates:
            for skill in installed:
                if skill["name"] == specific_skill:
                    svn_manifest = _get_svn_manifest(svn_url, specific_skill, local_path=skill.get("path"))
                    if svn_manifest:
                        updates.append({
                            "name": specific_skill,
                            "path": skill["path"],
                            "scope": skill["scope"],
                            "local_version": skill["version"],
                            "svn_version": svn_manifest.get("version", "unknown"),
                            "changelog": svn_manifest.get("changelog", ""),
                            "action": "update",
                        })
                    break

    if not updates:
        msg = "All installed Skills are up to date."
        if not quiet:
            print(msg)
        return True, msg

    if not quiet:
        print(f"Found {len(updates)} update(s):\n")

    # Apply updates
    return apply_updates(svn_url, updates, quiet)


def self_update_only(workspace=None, quiet=False, force=False):
    """
    Only update skill-version-manager itself.

    Returns:
        Tuple of (success: bool, message: str)
    """
    return auto_update(
        workspace=workspace,
        specific_skill=SELF_SKILL_NAME,
        quiet=quiet,
        force=force,
    )


# ─── CLI ─────────────────────────────────────────────────────────────


def main():
    # Fix Windows GBK encoding issue
    if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
        import io
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser(
        description="Auto-check and update installed Skills from SVN",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Check for updates (dry run)
  python auto_update.py --check

  # Apply all available updates
  python auto_update.py --update

  # Only update skill-version-manager itself
  python auto_update.py --self-update

  # Check a specific Skill
  python auto_update.py --check --skill my-skill

  # Force update even if version matches
  python auto_update.py --update --skill my-skill --force

  # Quiet mode (only summary)
  python auto_update.py --update --quiet
        """
    )

    parser.add_argument("--workspace", default=config_manager.resolve_workspace(),
                        help="Workspace root path")

    # Actions
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true",
                        help="Check for updates (no changes)")
    action.add_argument("--update", action="store_true",
                        help="Check and apply all updates")
    action.add_argument("--self-update", action="store_true",
                        help="Only update skill-version-manager itself")

    # Options
    parser.add_argument("--skill", default=None,
                        help="Only check/update a specific Skill")
    parser.add_argument("--quiet", "-q", action="store_true",
                        help="Suppress detailed output")
    parser.add_argument("--force", action="store_true",
                        help="Force update even if versions match")

    args = parser.parse_args()

    if args.check:
        ok, result = auto_check(args.workspace, args.skill)
        if ok:
            print(result["message"])
        else:
            print(f"ERROR: {result['message']}")
            sys.exit(1)

        # Output JSON for programmatic use
        if args.quiet and result["updates"]:
            output = {
                "self_updates": result["self_updates"],
                "other_updates": result["other_updates"],
            }
            print(json.dumps(output, indent=2, ensure_ascii=False))

    elif args.update:
        ok, msg = auto_update(
            workspace=args.workspace,
            specific_skill=args.skill,
            quiet=args.quiet,
            force=args.force,
        )
        print(msg)
        if not ok:
            sys.exit(1)

    elif args.self_update:
        ok, msg = self_update_only(
            workspace=args.workspace,
            quiet=args.quiet,
            force=args.force,
        )
        print(msg)
        if not ok:
            sys.exit(1)


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
