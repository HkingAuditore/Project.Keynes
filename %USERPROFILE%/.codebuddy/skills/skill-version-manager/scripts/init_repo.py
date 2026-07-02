#!/usr/bin/env python3
"""
Init Repo - Initialize or check SVN repository for skill management.

Operations:
  --check       Check if local config exists and SVN repo is reachable.
  --init        Initialize SVN repo structure + local config.
  --reconfig    Update local SVN URL configuration.

Team name is automatically derived from the SVN URL's last path segment.
No --team-name parameter needed.
"""

import json
import os
import sys
import argparse
from pathlib import Path
from datetime import datetime, timezone

# Add parent directory to path for relative imports when run as script
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import svn_manager
import config_manager


def _now_iso():
    """Get current UTC time in ISO 8601 format."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def check_status(workspace=None):
    """
    Check current configuration and SVN connectivity status.

    Prints 'configured' or 'not_configured' as the first line (for machine parsing),
    followed by human-readable details.
    """
    config = config_manager.load_local_config(workspace)

    if not config or not config.get("initialized"):
        print("not_configured")
        print("Local configuration not found. Run --init to set up.")
        return False

    svn_url = config.get("svn_url", "")
    username = config.get("username", "")
    last_sync = config.get("last_sync_time", "Never")

    print("configured")
    print(f"SVN URL:    {svn_url}")
    print(f"Username:   {username}")
    print(f"Team:       {config_manager.derive_team_name(svn_url)}")
    print(f"Last Sync:  {last_sync or 'Never'}")

    # Check SVN connectivity
    print("\nChecking SVN connection...")
    reachable, info_or_err = svn_manager.check_connection(svn_url)
    if reachable:
        print("SVN connection: OK")
        rev = info_or_err.get("Revision", "unknown")
        print(f"Repository revision: {rev}")
    else:
        print(f"SVN connection: FAILED - {info_or_err}")

    # Check repo structure
    print("\nChecking repository structure...")
    required_dirs = ["config", "history", "skills", "agents", "commands", "rules"]
    all_ok = True
    for d in required_dirs:
        exists = svn_manager.path_exists_in_svn(f"{svn_url}/{d}")
        status = "OK" if exists else "MISSING"
        print(f"  {d}/: {status}")
        if not exists:
            all_ok = False

    if all_ok:
        print("\nRepository structure is complete.")
    else:
        print("\nRepository structure is incomplete. Run --init to fix.")

    return True


def init_repo(svn_url, username, workspace=None):
    """
    Initialize the SVN repository structure and local configuration.

    Team name is automatically derived from the SVN URL's last path segment.

    Steps:
    1. Check SVN CLI is installed
    2. Check SVN URL is reachable
    3. Create repository directory structure if missing
    4. Create team.json and settings.json if missing
    5. Create local config.json

    Args:
        svn_url: SVN repository URL.
        username: Local SVN username.
        workspace: Workspace root path.
    """
    svn_url = svn_url.rstrip("/")
    team_name = config_manager.derive_team_name(svn_url)

    # Step 1: Check SVN installation
    print("Checking SVN installation...")
    installed, version = svn_manager.check_svn_installed()
    if not installed:
        print(f"ERROR: SVN CLI not found. Please install SVN and ensure it's in PATH.")
        print(f"Detail: {version}")
        return False

    print(f"SVN version: {version}")

    # Step 2: Check SVN URL connectivity
    print(f"\nChecking SVN URL: {svn_url}")
    reachable, info_or_err = svn_manager.check_connection(svn_url)
    if not reachable:
        # URL might not exist yet — try parent
        parent_url = svn_url.rsplit("/", 1)[0] if "/" in svn_url else svn_url
        parent_reachable, _ = svn_manager.check_connection(parent_url)
        if not parent_reachable:
            print(f"ERROR: Cannot reach SVN server. Check URL and network.")
            print(f"Detail: {info_or_err}")
            return False
        print(f"Target path doesn't exist yet. Will create it.")
    else:
        print("SVN connection: OK")

    # Step 3: Create repository directories if missing
    print("\nSetting up repository structure...")
    # Core dirs
    core_dirs = ["config", "history"]
    # Asset type dirs with role partitions
    asset_types = ["skills", "agents", "commands", "rules"]
    role_groups = ["shared", "art", "ta", "dev", "user"]

    all_dirs = core_dirs[:]
    for asset_type in asset_types:
        all_dirs.append(asset_type)
        for group in role_groups:
            all_dirs.append(f"{asset_type}/{group}")

    for d in all_dirs:
        dir_url = f"{svn_url}/{d}"
        if svn_manager.path_exists_in_svn(dir_url):
            print(f"  {d}/ : already exists")
        else:
            print(f"  {d}/ : creating...")
            ok, stdout, stderr = svn_manager.svn_mkdir_remote(
                dir_url, f"[skill-manager] Initialize {d}/ directory"
            )
            if ok:
                print(f"  {d}/ : created")
            else:
                print(f"  {d}/ : FAILED - {stderr}")
                # Non-critical for sub-dirs, continue
                if d in core_dirs or d in asset_types:
                    return False

    # Step 4: Create config files if missing
    print("\nSetting up configuration files...")

    # team.json
    team_url = f"{svn_url}/{config_manager.TEAM_CONFIG_PATH}"
    if svn_manager.path_exists_in_svn(team_url):
        print("  team.json: already exists")
    else:
        print("  team.json: creating (with you as admin)...")
        team_data = config_manager.create_default_team_json(svn_url, username)
        ok = _upload_json_to_svn(
            team_data, team_url,
            f"[skill-manager] Initialize team config for '{team_name}'"
        )
        if ok:
            print("  team.json: created")
        else:
            print("  team.json: FAILED to create")
            return False

    # settings.json
    settings_url = f"{svn_url}/{config_manager.SETTINGS_PATH}"
    if svn_manager.path_exists_in_svn(settings_url):
        print("  settings.json: already exists")
    else:
        print("  settings.json: creating...")
        settings_data = config_manager.create_default_settings()
        ok = _upload_json_to_svn(
            settings_data, settings_url,
            "[skill-manager] Initialize default settings"
        )
        if ok:
            print("  settings.json: created")
        else:
            print("  settings.json: FAILED to create")
            return False

    # reviews.jsonl (empty file)
    reviews_url = f"{svn_url}/history/reviews.jsonl"
    if svn_manager.path_exists_in_svn(reviews_url):
        print("  reviews.jsonl: already exists")
    else:
        print("  reviews.jsonl: creating...")
        ok = _upload_text_to_svn(
            "", reviews_url,
            "[skill-manager] Initialize reviews log"
        )
        if ok:
            print("  reviews.jsonl: created")
        else:
            # Non-critical, can be created later
            print("  reviews.jsonl: skipped (will be created on first review)")

    # Step 5: Create local config
    print("\nSaving local configuration...")
    config_manager.create_local_config(svn_url, username, workspace)
    print("Local configuration saved.")

    print(f"\n{'='*50}")
    print("Initialization complete!")
    print(f"  SVN URL:    {svn_url}")
    print(f"  Username:   {username}")
    print(f"  Team:       {team_name} (auto-derived from URL)")
    print(f"{'='*50}")
    return True


def _upload_json_to_svn(data, svn_url, message):
    """Upload a JSON object as a file to SVN using import."""
    import tempfile
    import shutil

    temp_dir = tempfile.mkdtemp(prefix="svn_init_")
    try:
        # Write JSON to temp file
        temp_file = Path(temp_dir) / Path(svn_url).name
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

        # SVN import
        ok, stdout, stderr = svn_manager.svn_import(str(temp_file), svn_url, message)
        return ok
    except Exception as e:
        print(f"  Error: {e}")
        return False
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def _upload_text_to_svn(text, svn_url, message):
    """Upload text content as a file to SVN using import."""
    import tempfile
    import shutil

    temp_dir = tempfile.mkdtemp(prefix="svn_init_")
    try:
        temp_file = Path(temp_dir) / Path(svn_url).name
        with open(temp_file, "w", encoding="utf-8") as f:
            f.write(text)

        ok, stdout, stderr = svn_manager.svn_import(str(temp_file), svn_url, message)
        return ok
    except Exception as e:
        print(f"  Error: {e}")
        return False
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def reconfig(svn_url=None, username=None, workspace=None):
    """Update existing local configuration."""
    config = config_manager.load_local_config(workspace)
    if not config:
        print("ERROR: No existing configuration. Use --init instead.")
        return False

    if svn_url:
        config["svn_url"] = svn_url.rstrip("/")
    if username:
        config["username"] = username

    config_manager.save_local_config(config, workspace)
    print("Configuration updated:")
    print(f"  SVN URL:  {config['svn_url']}")
    print(f"  Username: {config['username']}")
    print(f"  Team:     {config_manager.derive_team_name(config['svn_url'])}")
    return True


def main():
    parser = argparse.ArgumentParser(description="SVN Skill Repository Initializer")
    parser.add_argument("--workspace", default=config_manager.resolve_workspace(),
                        help="Workspace root path")

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true",
                       help="Check configuration status")
    group.add_argument("--init", action="store_true",
                       help="Initialize repository and local config")
    group.add_argument("--reconfig", action="store_true",
                       help="Update existing configuration")

    parser.add_argument("--svn-url", help="SVN repository URL")
    parser.add_argument("--username", help="SVN username")

    args = parser.parse_args()

    if args.check:
        check_status(args.workspace)

    elif args.init:
        if not args.svn_url:
            print("ERROR: --svn-url is required for --init")
            sys.exit(1)
        if not args.username:
            print("ERROR: --username is required for --init")
            sys.exit(1)

        success = init_repo(args.svn_url, args.username, args.workspace)
        if not success:
            sys.exit(1)

    elif args.reconfig:
        if not args.svn_url and not args.username:
            print("ERROR: Provide --svn-url and/or --username to update")
            sys.exit(1)
        success = reconfig(args.svn_url, args.username, args.workspace)
        if not success:
            sys.exit(1)


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
