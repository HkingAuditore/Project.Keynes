#!/usr/bin/env python3
"""
Config Manager - Handles local and team configuration.

Manages:
- Local config.json (SVN URL, username, last sync time)
- Team team.json (admins list)
- Team settings.json (global settings)
- Admin verification via SVN commit signature

Security model:
- Anyone with SVN repository access can publish, pull, sync, view status.
- Admin-only actions (review, manage admins) require SVN commit signature
  verification: the user must perform a real SVN commit, and the commit's
  author (authenticated by the SVN server) is checked against the admin list.
  This prevents local config forgery from bypassing admin checks.
"""

import json
import os
import sys
import uuid
from pathlib import Path
from datetime import datetime, timezone

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import svn_manager


def _detect_ide_dir_name():
    """Auto-detect the current IDE's dot-directory name.

    Detection order:
      1. SKILL_MANAGER_IDE_DIR env var (explicit override, e.g. ".cursor")
      2. Walk up from this script's own path to find which IDE dir we live in.
         e.g. ~/.codebuddy/skills/skill-version-manager/scripts/ → ".codebuddy"
      3. Check which IDE home directories exist on disk (prefer the one with
         a skills/ subdirectory already set up).
      4. Fallback to ".codebuddy".

    Supported IDE dirs: .codebuddy, .workbuddy, .cursor
    """
    # 1. Explicit env override
    env_ide = os.environ.get("SKILL_MANAGER_IDE_DIR", "").strip().strip("/\\")
    if env_ide:
        return env_ide

    _home = Path(os.environ.get("USERPROFILE", str(Path.home()))) \
        if __import__("platform").system() == "Windows" else Path.home()

    known_ide_dirs = [".codebuddy", ".workbuddy", ".cursor"]

    # 2. Detect from own install path
    #    e.g. /home/user/.codebuddy/skills/skill-version-manager/scripts/config_manager.py
    script_path = Path(__file__).resolve()
    for part in script_path.parts:
        if part in known_ide_dirs:
            return part

    # 3. Check which IDE homes exist and have skills/
    for ide_dir in known_ide_dirs:
        candidate = _home / ide_dir / "skills"
        if candidate.is_dir():
            return ide_dir

    # 4. Fallback
    return ".codebuddy"


# Module-level cache so detection runs only once per process
_IDE_DIR_NAME = None


def get_ide_dir_name():
    """Return the detected IDE dot-directory name (cached). e.g. '.codebuddy'."""
    global _IDE_DIR_NAME
    if _IDE_DIR_NAME is None:
        _IDE_DIR_NAME = _detect_ide_dir_name()
    return _IDE_DIR_NAME


def _get_codebuddy_home():
    """Return the global ~/.<ide>/ directory path (auto-detects IDE)."""
    import platform as _plat
    ide_dir = get_ide_dir_name()
    if _plat.system() == "Windows":
        return Path(os.environ.get("USERPROFILE", str(Path.home()))) / ide_dir
    return Path.home() / ide_dir


def _is_subpath(child: Path, parent: Path) -> bool:
    """Return True if *child* is equal to or inside *parent*."""
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def resolve_workspace(cli_workspace=None):
    """
    Determine the workspace root directory.

    Priority: cli_workspace arg > *_WORKSPACE env > *_PROJECT_ROOT env > os.getcwd().
    Checks env vars for all known IDE variants (CODEBUDDY_, WORKBUDDY_, CURSOR_).

    Guard: If cwd is inside ~/.<ide>/ (e.g. an AI agent cd'd into the
    scripts directory), we refuse to use it as workspace to prevent
    project-scope assets from being installed into the wrong location.
    """
    if cli_workspace:
        return str(Path(cli_workspace).resolve())

    # Try workspace env vars for all known IDE prefixes
    for prefix in ("CODEBUDDY", "WORKBUDDY", "CURSOR"):
        env_ws = os.environ.get(f"{prefix}_WORKSPACE")
        if env_ws:
            return str(Path(env_ws).resolve())

    cwd = Path(os.getcwd()).resolve()
    ide_home = _get_codebuddy_home().resolve()

    if _is_subpath(cwd, ide_home):
        # cwd is inside ~/.<ide>/ — likely an AI agent cd'd here
        for prefix in ("CODEBUDDY", "WORKBUDDY", "CURSOR"):
            project_root = os.environ.get(f"{prefix}_PROJECT_ROOT")
            if project_root:
                return str(Path(project_root).resolve())
        ide_dir = get_ide_dir_name()
        print(
            f"  [WARN] cwd is inside ~/{ide_dir}/ — refusing to use it as "
            "workspace.\n"
            "         Please pass --workspace <project_dir> or set the "
            f"{ide_dir.strip('.').upper()}_WORKSPACE env var.",
            file=sys.stderr,
        )
        sys.exit(1)

    return str(cwd)


# Default paths relative to workspace
LOCAL_CONFIG_DIR = ".svn-skill-manager"
LOCAL_CONFIG_FILE = "config.json"


def _get_skills_dir_name():
    """Return the relative path like '.codebuddy/skills' using detected IDE dir."""
    return f"{get_ide_dir_name()}/skills"


SKILLS_DIR = None  # Lazy — use get_skills_dir() below


def get_skills_dir():
    """Return the IDE-aware relative path, e.g. '.codebuddy/skills'."""
    return _get_skills_dir_name()

# SVN repo paths
TEAM_CONFIG_PATH = "config/team.json"
SETTINGS_PATH = "config/settings.json"


def _get_skills_base_dir(workspace=None):
    """Get the base .<ide>/skills/ directory path."""
    skills_dir = get_skills_dir()
    if workspace:
        return Path(workspace) / skills_dir
    return Path(skills_dir)


def _get_local_config_dir(workspace=None):
    """Get the local config directory path."""
    return _get_skills_base_dir(workspace) / LOCAL_CONFIG_DIR


def _get_local_config_path(workspace=None):
    """Get the local config.json file path."""
    return _get_local_config_dir(workspace) / LOCAL_CONFIG_FILE


def _now_iso():
    """Get current time in ISO 8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def derive_team_name(svn_url):
    """
    Derive team name from the last segment of the SVN URL.

    e.g. https://svn.woa.com/UGameArt/CodeBuddySkill/trunk/skills -> 'skills'
    """
    url = svn_url.rstrip("/")
    return url.rsplit("/", 1)[-1] if "/" in url else url


# ── Local Config Management ──────────────────────────────────────────


def load_local_config(workspace=None):
    """
    Load local configuration.

    Lookup order:
      1. {workspace}/.<ide>/skills/.svn-skill-manager/config.json
      2. ~/.<ide>/skills/.svn-skill-manager/config.json   (same IDE home)
      3. ~/.<other-ide>/skills/.svn-skill-manager/config.json for every other
         known IDE dir — handles the "installed under .cursor but config was
         created under .codebuddy (or vice-versa)" migration case. The first
         hit is auto-mirrored into the current IDE home so subsequent writes
         (last_sync_time, etc.) stay consistent.

    Returns:
        dict or None if not configured.
    """
    config_path = _get_local_config_path(workspace)
    cfg = _try_load_json(config_path)
    if cfg is not None:
        return cfg

    global_config_path = _get_codebuddy_home() / "skills" / LOCAL_CONFIG_DIR / LOCAL_CONFIG_FILE
    cfg = _try_load_json(global_config_path)
    if cfg is not None:
        return cfg

    return _load_config_from_other_ide_homes()


def _load_config_from_other_ide_homes():
    """Probe other known IDE home dirs for a config and auto-mirror it.

    When a user previously configured the manager under one IDE (e.g.
    ``~/.codebuddy/``) and now runs it under another (``~/.cursor/``), the
    standard lookups miss the existing config. We search the remaining known
    IDE homes, copy the first hit into the current IDE home so further writes
    (``save_local_config``) stay consistent, and return the loaded dict.
    """
    import platform as _plat
    import shutil

    home = Path(os.environ.get("USERPROFILE", str(Path.home()))) \
        if _plat.system() == "Windows" else Path.home()
    current_ide = get_ide_dir_name()
    known_ide_dirs = [".codebuddy", ".workbuddy", ".cursor"]

    for ide_dir in known_ide_dirs:
        if ide_dir == current_ide:
            continue
        candidate = home / ide_dir / "skills" / LOCAL_CONFIG_DIR / LOCAL_CONFIG_FILE
        cfg = _try_load_json(candidate)
        if cfg is None:
            continue

        # Auto-mirror into the current IDE home so writes don't diverge.
        try:
            target_dir = home / current_ide / "skills" / LOCAL_CONFIG_DIR
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / LOCAL_CONFIG_FILE
            if not target.exists():
                shutil.copy2(candidate, target)
                print(
                    f"  [INFO] Mirrored config from ~/{ide_dir}/ to "
                    f"~/{current_ide}/ (first run under this IDE).",
                    file=sys.stderr,
                )
        except OSError as exc:
            print(
                f"  [WARN] Found config in ~/{ide_dir}/ but failed to mirror "
                f"to ~/{current_ide}/: {exc}",
                file=sys.stderr,
            )
        return cfg

    return None


def _try_load_json(path: Path):
    """Try to load a JSON file, return dict or None."""
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return None


def save_local_config(config, workspace=None):
    """
    Save local configuration.

    Args:
        config: Configuration dictionary.
        workspace: Workspace root path.
    """
    config_dir = _get_local_config_dir(workspace)
    config_dir.mkdir(parents=True, exist_ok=True)
    config_path = config_dir / LOCAL_CONFIG_FILE

    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


def create_local_config(svn_url, username, workspace=None, role=None):
    """
    Create a new local configuration.

    Args:
        svn_url: SVN repository URL.
        username: Local SVN username.
        workspace: Workspace root path.
        role: User role (art/ta/dev/all). Optional.

    Returns:
        The created config dictionary.
    """
    config = {
        "svn_url": svn_url.rstrip("/"),
        "username": username,
        "role": role,
        "last_sync_time": None,
        "initialized": True,
    }
    save_local_config(config, workspace)
    return config


def update_sync_time(workspace=None):
    """Update the last_sync_time in local config to now."""
    config = load_local_config(workspace)
    if config:
        config["last_sync_time"] = _now_iso()
        save_local_config(config, workspace)


def is_configured(workspace=None):
    """Check if local configuration exists and is valid."""
    config = load_local_config(workspace)
    return config is not None and config.get("initialized", False)


def get_svn_url(workspace=None):
    """Get the configured SVN URL."""
    config = load_local_config(workspace)
    if config:
        return config.get("svn_url")
    return None


def get_username(workspace=None):
    """Get the configured local username."""
    config = load_local_config(workspace)
    if config:
        return config.get("username")
    return None


def get_role(workspace=None):
    """Get the configured user role (art/ta/dev/all). Returns None if not set."""
    config = load_local_config(workspace)
    if config:
        return config.get("role")
    return None


def set_role(role, workspace=None):
    """
    Set the user's role in local config.

    Args:
        role: One of 'art', 'ta', 'dev', 'all'.
        workspace: Workspace root path.
    """
    config = load_local_config(workspace)
    if config:
        config["role"] = role
        save_local_config(config, workspace)


# ── Team Config Management ───────────────────────────────────────────


def create_default_team_json(svn_url, admin_username):
    """
    Create a default team.json structure.

    Team name is automatically derived from the SVN URL's last path segment.

    Args:
        svn_url: SVN repository URL (team name derived from last segment).
        admin_username: SVN username of the initial admin.

    Returns:
        dict: team.json structure.
    """
    team_name = derive_team_name(svn_url)

    return {
        "team_name": team_name,
        "created_at": _now_iso(),
        "admins": [admin_username],
    }


def create_default_settings():
    """Create default settings.json structure."""
    return {
        "auto_approve": False,
        "require_changelog": True,
        "max_skill_size_mb": 50,
        "default_install_scope": "project",
        "created_at": _now_iso(),
    }


def get_default_install_scope(workspace=None):
    """
    Get the default install_scope from team settings.

    Returns 'project' if not configured or on error.
    """
    ok, settings = load_settings_from_svn(workspace)
    if ok and isinstance(settings, dict):
        return settings.get("default_install_scope", "project")
    return "project"


def load_team_config_from_svn(workspace=None):
    """
    Load team.json from SVN repository.

    Returns:
        Tuple of (success: bool, team_data: dict | error: str)
    """
    config = load_local_config(workspace)
    if not config:
        return False, "Local config not found. Run init first."

    svn_url = config["svn_url"]
    team_url = f"{svn_url}/{TEAM_CONFIG_PATH}"

    return svn_manager.read_json_from_svn(team_url)


def load_settings_from_svn(workspace=None):
    """
    Load settings.json from SVN repository.

    Returns:
        Tuple of (success: bool, settings: dict | error: str)
    """
    config = load_local_config(workspace)
    if not config:
        return False, "Local config not found. Run init first."

    svn_url = config["svn_url"]
    settings_url = f"{svn_url}/{SETTINGS_PATH}"

    return svn_manager.read_json_from_svn(settings_url)


# ── Admin Verification via SVN Commit Signature ──────────────────────


def is_admin_in_team(username, team_data):
    """Check if a username is in the admin list."""
    return username in team_data.get("admins", [])


def verify_admin_via_svn_commit(workspace=None):
    """
    Verify that the current user is an admin by performing a real SVN commit
    and checking the commit author against the admin list.

    Security: The SVN server authenticates the committer. By reading back the
    commit's author from 'svn log', we get a server-verified identity that
    cannot be forged by editing local config files.

    Process:
    1. Checkout config/ directory
    2. Write a nonce file (.admin-verify) with a random UUID
    3. Commit it — SVN server records the authenticated author
    4. Read the latest commit's author via 'svn log'
    5. Check author against team.json admins list
    6. Clean up the nonce file

    Returns:
        Tuple of (is_admin: bool, verified_username: str, error_msg: str)
    """
    config = load_local_config(workspace)
    if not config:
        return False, "", "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]

    # Load team config to get admin list
    team_url = f"{svn_url}/{TEAM_CONFIG_PATH}"
    success, team_data = svn_manager.read_json_from_svn(team_url)
    if not success:
        return False, "", f"Failed to load team config: {team_data}"

    # Perform SVN commit to verify identity
    nonce = str(uuid.uuid4())[:8]
    temp_dir = svn_manager.create_temp_dir("admin_verify_")
    try:
        config_url = f"{svn_url}/config"
        ok, stdout, stderr = svn_manager.svn_checkout(config_url, temp_dir)
        if not ok:
            return False, "", f"Failed to checkout config: {stderr}"

        # Write nonce file
        verify_file = Path(temp_dir) / ".admin-verify"
        verify_existed = verify_file.exists()
        with open(verify_file, "w", encoding="utf-8") as f:
            f.write(json.dumps({
                "nonce": nonce,
                "timestamp": _now_iso(),
                "purpose": "admin identity verification",
            }, indent=2))

        if not verify_existed:
            svn_manager.svn_add(str(verify_file), cwd=temp_dir)

        # Commit the nonce
        commit_msg = f"[skill-manager] admin-verify nonce={nonce}"
        ok, stdout, stderr = svn_manager.svn_commit(temp_dir, commit_msg)
        if not ok:
            return False, "", f"SVN commit failed (authentication issue?): {stderr}"

        # Read back the commit author from svn log
        ok, log_entries = svn_manager.svn_log(f"{config_url}/.admin-verify", limit=1)
        if not ok or not log_entries:
            return False, "", "Failed to read commit log for verification."

        verified_author = log_entries[0].get("author", "")
        commit_message = log_entries[0].get("message", "")

        # Verify the nonce matches (prevent replay)
        if nonce not in commit_message:
            return False, verified_author, "Nonce mismatch. Verification failed."

        # Check if the verified author is an admin
        if not is_admin_in_team(verified_author, team_data):
            return False, verified_author, (
                f"Permission denied. SVN-verified user '{verified_author}' "
                f"is not in the admin list."
            )

        return True, verified_author, ""

    finally:
        svn_manager.cleanup_temp_dir(temp_dir)


# ── Admin Management ─────────────────────────────────────────────────


def add_admin(team_data, username):
    """
    Add a new admin to team data (in-memory).

    Returns:
        Tuple of (success: bool, message: str)
    """
    admins = team_data.get("admins", [])
    if username in admins:
        return False, f"User '{username}' is already an admin."
    admins.append(username)
    team_data["admins"] = admins
    return True, f"Added '{username}' as admin."


def remove_admin(team_data, username):
    """
    Remove an admin from team data (in-memory).

    Returns:
        Tuple of (success: bool, message: str)
    """
    admins = team_data.get("admins", [])
    if username not in admins:
        return False, f"User '{username}' is not an admin."
    if len(admins) <= 1:
        return False, "Cannot remove the last admin. At least one admin must remain."
    admins.remove(username)
    team_data["admins"] = admins
    return True, f"Removed '{username}' from admins."


# ── CLI Interface ────────────────────────────────────────────────────


def main():
    """CLI entry point for config management."""
    import argparse

    parser = argparse.ArgumentParser(description="Team config manager")
    parser.add_argument("--workspace", default=resolve_workspace(), help="Workspace root path")

    # Action flags (mutually exclusive)
    action_group = parser.add_mutually_exclusive_group(required=True)
    action_group.add_argument("--list-admins", action="store_true",
                              help="List team admins")
    action_group.add_argument("--add-admin", action="store_true",
                              help="Add a team admin (requires SVN commit verification)")
    action_group.add_argument("--remove-admin", action="store_true",
                              help="Remove a team admin (requires SVN commit verification)")

    # Shared arguments
    parser.add_argument("--username", default=None,
                        help="SVN username of the target admin")

    args = parser.parse_args()
    workspace = args.workspace

    # Load config
    config = load_local_config(workspace)
    if not config:
        print("ERROR: Not configured. Run init_repo.py first.")
        sys.exit(1)

    # Load team config from SVN
    success, team_data = load_team_config_from_svn(workspace)
    if not success:
        print(f"ERROR: Failed to load team config: {team_data}")
        sys.exit(1)

    if args.list_admins:
        team_name = team_data.get("team_name", "Unknown")
        admins = team_data.get("admins", [])
        print(f"Team: {team_name}")
        print(f"Admins ({len(admins)}):")
        for admin in admins:
            print(f"  - {admin}")
        return

    # Admin-only actions below — verify via SVN commit signature
    print("Verifying admin identity via SVN commit signature...")
    is_verified, verified_user, err = verify_admin_via_svn_commit(workspace)
    if not is_verified:
        print(f"ERROR: {err}")
        sys.exit(1)
    print(f"Identity verified: {verified_user} (admin)")

    # Determine action name for commit message
    action_name = None

    if args.add_admin:
        if not args.username:
            print("ERROR: --username is required for --add-admin.")
            sys.exit(1)
        success, msg = add_admin(team_data, args.username)
        if not success:
            print(f"ERROR: {msg}")
            sys.exit(1)
        print(msg)
        action_name = "add-admin"

    elif args.remove_admin:
        if not args.username:
            print("ERROR: --username is required for --remove-admin.")
            sys.exit(1)
        success, msg = remove_admin(team_data, args.username)
        if not success:
            print(f"ERROR: {msg}")
            sys.exit(1)
        print(msg)
        action_name = "remove-admin"

    # Write updated team.json back to SVN
    svn_url = config["svn_url"]
    temp_dir = svn_manager.create_temp_dir("team_config_")
    try:
        # Checkout config directory
        config_url = f"{svn_url}/config"
        ok, stdout, stderr = svn_manager.svn_checkout(config_url, temp_dir)
        if not ok:
            print(f"ERROR: Failed to checkout config: {stderr}")
            sys.exit(1)

        # Write updated team.json
        team_path = Path(temp_dir) / "team.json"
        with open(team_path, "w", encoding="utf-8") as f:
            json.dump(team_data, f, indent=2, ensure_ascii=False)

        # Commit
        ok, stdout, stderr = svn_manager.svn_commit(
            temp_dir, f"[skill-manager] {action_name}: {args.username} (verified by {verified_user})"
        )
        if not ok:
            print(f"ERROR: Failed to commit team config: {stderr}")
            sys.exit(1)

        print("Team configuration updated and committed to SVN.")
    finally:
        svn_manager.cleanup_temp_dir(temp_dir)


if __name__ == "__main__":
    main()
