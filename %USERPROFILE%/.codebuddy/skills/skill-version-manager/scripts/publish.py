#!/usr/bin/env python3
"""
Publish - Publish a local Skill to the SVN repository.

Validates the local Skill format, generates/updates manifest.json,
and commits the Skill to SVN with status='pending'.
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


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _get_local_skill_path(skill_name, workspace=None):
    """Get the local path to a Skill directory."""
    base = Path(workspace) if workspace else Path(config_manager.resolve_workspace())
    return base / config_manager.get_skills_dir() / skill_name


def validate_skill(skill_path):
    """
    Validate that a local Skill directory has required structure.

    Args:
        skill_path: Path to the Skill directory.

    Returns:
        Tuple of (valid: bool, errors: list[str])
    """
    errors = []
    skill_path = Path(skill_path)

    if not skill_path.exists():
        return False, [f"Skill directory not found: {skill_path}"]

    if not skill_path.is_dir():
        return False, [f"Not a directory: {skill_path}"]

    # Must have SKILL.md
    skill_md = skill_path / "SKILL.md"
    if not skill_md.exists():
        errors.append("Missing required file: SKILL.md")
    elif skill_md.stat().st_size == 0:
        errors.append("SKILL.md is empty")

    # Skill name should match directory name
    skill_name = skill_path.name

    # Skip internal directories
    if skill_name.startswith("."):
        errors.append(f"Skill name cannot start with '.': {skill_name}")

    return len(errors) == 0, errors


def _bump_version(current_version):
    """Auto-increment the PATCH version."""
    parts = current_version.split(".")
    if len(parts) == 3:
        try:
            parts[2] = str(int(parts[2]) + 1)
            return ".".join(parts)
        except ValueError:
            pass
    return current_version


def _load_existing_manifest(svn_url, skill_name):
    """
    Load existing manifest.json from SVN if it exists.

    Returns:
        dict or None
    """
    manifest_url = f"{svn_url}/skills/{skill_name}/manifest.json"
    if svn_manager.path_exists_in_svn(manifest_url):
        success, data = svn_manager.read_json_from_svn(manifest_url)
        if success:
            return data
    return None


def generate_manifest(skill_name, author, changelog, existing_manifest=None, description=None, workspace=None):
    """
    Generate or update a manifest.json for a Skill.

    Args:
        skill_name: Name of the Skill.
        author: SVN username of the publisher.
        changelog: Description of changes.
        existing_manifest: Existing manifest dict for version bumping.
        description: Skill description (extracted from SKILL.md if not provided).
        workspace: Workspace root path (for reading team settings).

    Returns:
        dict: manifest.json data.
    """
    now = _now_iso()

    if existing_manifest:
        # Update existing
        new_version = _bump_version(existing_manifest.get("version", "1.0.0"))
        manifest = existing_manifest.copy()
        manifest.update({
            "version": new_version,
            "author": author,
            "updated_at": now,
            "changelog": changelog,
            "status": "pending",
            "reviewed_by": None,
            "reviewed_at": None,
            "reject_reason": None,
        })
    else:
        # New manifest - use default_install_scope from team settings
        default_scope = config_manager.get_default_install_scope(workspace)
        manifest = {
            "skill_name": skill_name,
            "version": "1.0.0",
            "author": author,
            "description": description or "",
            "created_at": now,
            "updated_at": now,
            "changelog": changelog,
            "status": "pending",
            "reviewed_by": None,
            "reviewed_at": None,
            "reject_reason": None,
            "dependencies": [],
            "install_scope": default_scope,
        }

    return manifest


def _extract_description_from_skill_md(skill_md_path):
    """Extract description from SKILL.md YAML frontmatter."""
    try:
        with open(skill_md_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Simple YAML frontmatter parsing
        if content.startswith("---"):
            end_idx = content.find("---", 3)
            if end_idx > 0:
                frontmatter = content[3:end_idx]
                for line in frontmatter.splitlines():
                    line = line.strip()
                    if line.startswith("description:"):
                        desc = line[len("description:"):].strip()
                        # Handle multi-line description
                        if desc.startswith(">"):
                            desc = desc[1:].strip()
                        return desc.strip("'\"")
    except Exception:
        pass
    return ""


def publish_skill(skill_name, changelog, workspace=None, version=None):
    """
    Publish a local Skill to the SVN repository.

    Args:
        skill_name: Name of the Skill to publish.
        changelog: Changelog message for this version.
        workspace: Workspace root path.
        version: Optional explicit version override.

    Returns:
        Tuple of (success: bool, message: str)
    """
    workspace = workspace or config_manager.resolve_workspace()

    # Load local config
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]
    username = config["username"]

    # Validate local Skill
    skill_path = _get_local_skill_path(skill_name, workspace)
    valid, errors = validate_skill(skill_path)
    if not valid:
        return False, f"Skill validation failed:\n" + "\n".join(f"  - {e}" for e in errors)

    # Check if this is a new or existing Skill in SVN
    existing_manifest = _load_existing_manifest(svn_url, skill_name)
    is_update = existing_manifest is not None

    # Extract description from SKILL.md
    description = _extract_description_from_skill_md(skill_path / "SKILL.md")

    # Generate manifest
    manifest = generate_manifest(
        skill_name, username, changelog,
        existing_manifest=existing_manifest,
        description=description,
        workspace=workspace,
    )
    if version:
        manifest["version"] = version

    action = "Update" if is_update else "New"
    print(f"Publishing Skill: {skill_name} (v{manifest['version']}) [{action}]")
    print(f"Author: {username}")
    print(f"Changelog: {changelog}")
    print(f"Status will be set to: pending (awaiting admin review)")

    # Create temp working directory
    temp_dir = svn_manager.create_temp_dir("publish_")
    try:
        skills_url = f"{svn_url}/skills"

        if is_update:
            # Checkout the existing Skill directory
            skill_svn_url = f"{skills_url}/{skill_name}"
            ok, stdout, stderr = svn_manager.svn_checkout(skill_svn_url, temp_dir)
            if not ok:
                return False, f"Failed to checkout existing Skill: {stderr}"

            # Clear old contents (keep .svn)
            for item in Path(temp_dir).iterdir():
                if item.name == ".svn":
                    continue
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()

            # Copy new contents
            _copy_skill_contents(skill_path, Path(temp_dir))

            # Write manifest.json
            manifest_path = Path(temp_dir) / "manifest.json"
            with open(manifest_path, "w", encoding="utf-8") as f:
                json.dump(manifest, f, indent=2, ensure_ascii=False)

            # Add any new files
            ok, stdout, stderr = svn_manager.svn_add(".", cwd=temp_dir)
            # svn add may fail if files already versioned — that's OK

            # Commit
            commit_msg = f"[skill-manager] Update {skill_name} v{manifest['version']}: {changelog}"
            ok, stdout, stderr = svn_manager.svn_commit(temp_dir, commit_msg)
            if not ok:
                if "nothing to commit" in stderr.lower() or "no changes" in stderr.lower():
                    return True, f"No changes detected for {skill_name}. Already up to date."
                return False, f"Failed to commit: {stderr}"

        else:
            # New Skill: checkout skills/ directory at depth=empty, then add new dir
            ok, stdout, stderr = svn_manager.svn_checkout(skills_url, temp_dir, depth="empty")
            if not ok:
                return False, f"Failed to checkout skills/: {stderr}"

            # Create Skill directory
            new_skill_dir = Path(temp_dir) / skill_name
            new_skill_dir.mkdir(parents=True)

            # Copy contents
            _copy_skill_contents(skill_path, new_skill_dir)

            # Write manifest.json
            manifest_path = new_skill_dir / "manifest.json"
            with open(manifest_path, "w", encoding="utf-8") as f:
                json.dump(manifest, f, indent=2, ensure_ascii=False)

            # SVN add
            ok, stdout, stderr = svn_manager.svn_add(str(new_skill_dir), cwd=temp_dir)
            if not ok:
                return False, f"Failed to svn add: {stderr}"

            # Commit
            commit_msg = f"[skill-manager] Publish new skill {skill_name} v{manifest['version']}: {changelog}"
            ok, stdout, stderr = svn_manager.svn_commit(temp_dir, commit_msg)
            if not ok:
                return False, f"Failed to commit: {stderr}"

        return True, (
            f"Successfully published {skill_name} v{manifest['version']}.\n"
            f"Status: pending (awaiting admin review)\n"
            f"An admin needs to review and approve this Skill before it can be synced by team members."
        )

    finally:
        svn_manager.cleanup_temp_dir(temp_dir)


def _copy_skill_contents(src_path, dst_path):
    """
    Copy Skill contents from source to destination, excluding internal files.

    Skips: .svn, .git, __pycache__, .pyc, manifest.json (we generate our own)
    """
    src_path = Path(src_path)
    dst_path = Path(dst_path)

    skip_names = {".svn", ".git", "__pycache__", ".svn-skill-manager"}
    skip_extensions = {".pyc"}

    for item in src_path.iterdir():
        if item.name in skip_names:
            continue
        if item.suffix in skip_extensions:
            continue
        if item.name == "manifest.json":
            continue  # We generate our own

        dst_item = dst_path / item.name
        if item.is_dir():
            shutil.copytree(item, dst_item, ignore=shutil.ignore_patterns(
                ".svn", ".git", "__pycache__", "*.pyc"
            ))
        else:
            shutil.copy2(item, dst_item)


def main():
    parser = argparse.ArgumentParser(description="Publish a Skill to SVN")
    parser.add_argument("--skill-name", required=True, help="Name of the Skill to publish")
    parser.add_argument("--changelog", required=True, help="Changelog message")
    parser.add_argument("--workspace", default=config_manager.resolve_workspace(), help="Workspace root")
    parser.add_argument("--version", default=None, help="Explicit version override")

    args = parser.parse_args()

    success, message = publish_skill(
        args.skill_name, args.changelog, args.workspace, args.version
    )
    print(f"\n{message}")

    if not success:
        sys.exit(1)


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
