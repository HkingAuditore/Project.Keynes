#!/usr/bin/env python3
"""
skill-version-manager Offline Installer

Usage:
    python install.py              # Interactive install (skill + rule)
    python install.py --skip-rule  # Install skill only, skip rule
    python install.py --uninstall  # Remove skill and rule

This script:
  1. Copies skill-version-manager to ~/.codebuddy/skills/
  2. Prompts user to install the "auto-check-team-skills" rule to:
     - User-level: ~/.codebuddy/rules/ (applies to ALL workspaces)
     - Project-level: <cwd>/.codebuddy/rules/ (current project only)
     - Skip: don't install rule
  3. Optionally configures the SVN repository URL
"""

import os
import sys
import shutil
import json
import platform
import argparse
from pathlib import Path
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SKILL_NAME = "skill-version-manager"

# Directories inside the release zip (relative to this install.py)
SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_SOURCE_DIR = SCRIPT_DIR  # The zip root IS the skill dir
RULE_SOURCE_DIR = SCRIPT_DIR / "bundled-rules"
RULE_FILENAME = "auto-check-team-skills.mdc"

# Supported IDE directories
KNOWN_IDE_DIRS = [".codebuddy", ".workbuddy", ".cursor"]


def _detect_ide_dir():
    """Auto-detect the IDE dot-directory name."""
    env_ide = os.environ.get("SKILL_MANAGER_IDE_DIR", "").strip().strip("/\\")
    if env_ide:
        return env_ide

    home = Path.home()
    # Prefer the one that already has skills/
    for ide_dir in KNOWN_IDE_DIRS:
        if (home / ide_dir / "skills").is_dir():
            return ide_dir
    # Fallback: first that exists
    for ide_dir in KNOWN_IDE_DIRS:
        if (home / ide_dir).is_dir():
            return ide_dir
    return ".codebuddy"


def get_user_codebuddy_dir():
    """Return ~/.<ide>/ (platform-aware, auto-detects IDE)."""
    return Path.home() / _detect_ide_dir()


def get_skill_install_dir():
    """Return ~/.<ide>/skills/skill-version-manager."""
    return get_user_codebuddy_dir() / "skills" / SKILL_NAME


def get_user_rule_dir():
    """Return ~/.<ide>/rules."""
    return get_user_codebuddy_dir() / "rules"


def get_project_rule_dir():
    """Return <cwd>/.<ide>/rules."""
    return Path.cwd() / _detect_ide_dir() / "rules"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

EXCLUDE_ITEMS = {
    "install.py",
    "build_release.py",
    "bundled-rules",
    "__pycache__",
    ".svn",
}


def print_banner():
    version = "unknown"
    manifest_path = SKILL_SOURCE_DIR / "manifest.json"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                version = data.get("version", version)
        except Exception:
            pass

    print()
    print("=" * 55)
    print(f"  skill-version-manager v{version} - Offline Installer")
    print("=" * 55)
    print()


def confirm(prompt, default=True):
    """Ask y/n question, return bool."""
    suffix = " [Y/n]: " if default else " [y/N]: "
    while True:
        answer = input(prompt + suffix).strip().lower()
        if not answer:
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        print("  Please enter y or n.")


def copy_skill(src, dst):
    """Copy skill files from src to dst, excluding install/build files."""
    dst.mkdir(parents=True, exist_ok=True)

    # Remove old files in dst that came from us
    if dst.exists():
        for item in list(dst.iterdir()):
            if item.name in EXCLUDE_ITEMS:
                continue
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()

    # Copy new files
    for item in src.iterdir():
        if item.name in EXCLUDE_ITEMS:
            continue
        target = dst / item.name
        if item.is_dir():
            shutil.copytree(item, target, dirs_exist_ok=True)
        else:
            shutil.copy2(item, target)


def install_rule(rule_source, rule_target_dir):
    """Copy the rule file to the target rules directory."""
    rule_source_file = rule_source / RULE_FILENAME
    if not rule_source_file.exists():
        print(f"  [WARN] Rule file not found: {rule_source_file}")
        print("  Skipping rule installation.")
        return False

    rule_target_dir.mkdir(parents=True, exist_ok=True)
    target_file = rule_target_dir / RULE_FILENAME

    if target_file.exists():
        print(f"  Rule already exists at: {target_file}")
        if not confirm("  Overwrite existing rule?", default=True):
            print("  Keeping existing rule.")
            return True

    shutil.copy2(rule_source_file, target_file)
    print(f"  [OK] Rule installed to: {target_file}")
    return True


# ---------------------------------------------------------------------------
# Install flow
# ---------------------------------------------------------------------------

def do_install(args):
    """Main install logic."""
    print_banner()

    # --- Step 1: Install skill ---
    print("[1/3] Installing skill-version-manager...")
    dst = get_skill_install_dir()
    print(f"  Target: {dst}")

    if dst.exists():
        print("  Existing installation found.")
        # Read existing version
        old_manifest = dst / "manifest.json"
        old_version = "unknown"
        if old_manifest.exists():
            try:
                with open(old_manifest, "r", encoding="utf-8") as f:
                    old_version = json.load(f).get("version", old_version)
            except Exception:
                pass

        new_manifest = SKILL_SOURCE_DIR / "manifest.json"
        new_version = "unknown"
        if new_manifest.exists():
            try:
                with open(new_manifest, "r", encoding="utf-8") as f:
                    new_version = json.load(f).get("version", new_version)
            except Exception:
                pass

        print(f"  Current version: {old_version}")
        print(f"  Package version: {new_version}")

        if old_version == new_version:
            print("  Versions are the same.")
            if not confirm("  Reinstall anyway?", default=False):
                print("  Skipping skill installation.")
                # Still offer rule installation
                do_rule_install(args)
                return
        else:
            if not confirm(f"  Upgrade {old_version} -> {new_version}?", default=True):
                print("  Skipping skill installation.")
                do_rule_install(args)
                return

    copy_skill(SKILL_SOURCE_DIR, dst)
    print(f"  [OK] skill-version-manager installed to: {dst}")
    print()

    # --- Step 2: Install rule ---
    do_rule_install(args)

    # --- Step 3: SVN configuration hint ---
    print()
    print("[3/3] SVN Repository Configuration")
    print()
    print("  To start using skill-version-manager, you need to configure the")
    print("  SVN repository URL. This will happen automatically when the IDE")
    print("  loads the skill for the first time.")
    print()
    print("  Or you can configure manually:")
    print(f"    python {dst / 'scripts' / 'init_repo.py'} --init \\")
    print(f"      --svn-url <your-svn-url> \\")
    print(f"      --username <your-svn-username>")
    print()

    # If user wants to configure now
    if confirm("  Configure SVN repository now?", default=False):
        svn_url = input("  SVN URL: ").strip()
        username = input(f"  SVN username [{os.environ.get('USERNAME', os.environ.get('USER', ''))}]: ").strip()
        if not username:
            username = os.environ.get("USERNAME", os.environ.get("USER", ""))

        if svn_url and username:
            import subprocess
            cmd = [
                sys.executable,
                str(dst / "scripts" / "init_repo.py"),
                "--init",
                "--svn-url", svn_url,
                "--username", username,
            ]
            print(f"  Running: {' '.join(cmd)}")
            result = subprocess.run(cmd, capture_output=False)
            if result.returncode == 0:
                print("  [OK] SVN repository configured successfully!")
            else:
                print("  [WARN] Configuration failed. You can retry later.")
        else:
            print("  Skipping — you can configure later.")

    print()
    print("=" * 55)
    print("  Installation complete!")
    print()
    print("  Next steps:")
    print("  1. Open your IDE (CodeBuddy / WorkBuddy / Cursor) and start a new conversation")
    print("  2. The rule will automatically trigger skill-version-manager")
    print("     on your first substantive task")
    print("  3. If not configured, it will guide you through SVN setup")
    print("=" * 55)
    print()


def do_rule_install(args):
    """Handle rule installation step."""
    print("[2/3] Installing auto-check-team-skills rule...")
    print()

    if args.skip_rule:
        print("  Skipped (--skip-rule flag).")
        return

    rule_source = RULE_SOURCE_DIR
    if not (rule_source / RULE_FILENAME).exists():
        print("  [WARN] Bundled rule file not found in package.")
        print("  You can manually copy the rule file later.")
        return

    print("  The rule 'auto-check-team-skills' makes the IDE automatically:")
    print("    - Check for team Skills before starting tasks")
    print("    - Auto-update skill-version-manager when new versions exist")
    print("    - Search team catalog for reusable Skills")
    print()
    print("  Where would you like to install the rule?")
    print()
    ide_dir = _detect_ide_dir()
    print(f"    [1] User-level  (~/{ide_dir}/rules/)")
    print(f"        -> Applies to ALL your workspaces")
    print()
    print(f"    [2] Project-level ({ide_dir}/rules/ in current directory)")
    print(f"        -> Only applies to: {Path.cwd()}")
    print()
    print("    [3] Both (user-level + project-level)")
    print()
    print("    [4] Skip — don't install the rule")
    print()

    while True:
        choice = input("  Choose [1/2/3/4] (default: 1): ").strip()
        if not choice:
            choice = "1"
        if choice in ("1", "2", "3", "4"):
            break
        print("  Please enter 1, 2, 3, or 4.")

    if choice == "4":
        print("  Skipping rule installation.")
        print("  You can install it later by copying the rule file from:")
        print(f"    {rule_source / RULE_FILENAME}")
        return

    if choice in ("1", "3"):
        print()
        print("  Installing to user-level rules...")
        install_rule(rule_source, get_user_rule_dir())

    if choice in ("2", "3"):
        print()
        print("  Installing to project-level rules...")
        install_rule(rule_source, get_project_rule_dir())

    print()
    print("  [OK] Rule installation complete.")


# ---------------------------------------------------------------------------
# Uninstall flow
# ---------------------------------------------------------------------------

def do_uninstall():
    """Remove skill and optionally rule."""
    print_banner()
    print("Uninstalling skill-version-manager...")
    print()

    # Remove skill
    skill_dir = get_skill_install_dir()
    if skill_dir.exists():
        print(f"  Found skill at: {skill_dir}")
        if confirm("  Remove skill?", default=True):
            shutil.rmtree(skill_dir)
            print("  [OK] Skill removed.")
        else:
            print("  Keeping skill.")
    else:
        print("  Skill not found (already uninstalled?).")

    # Remove user-level rule
    user_rule = get_user_rule_dir() / RULE_FILENAME
    if user_rule.exists():
        print(f"\n  Found user-level rule at: {user_rule}")
        if confirm("  Remove rule?", default=True):
            user_rule.unlink()
            print("  [OK] User-level rule removed.")
        else:
            print("  Keeping rule.")

    # Remove project-level rule
    project_rule = get_project_rule_dir() / RULE_FILENAME
    if project_rule.exists():
        print(f"\n  Found project-level rule at: {project_rule}")
        if confirm("  Remove rule?", default=True):
            project_rule.unlink()
            print("  [OK] Project-level rule removed.")
        else:
            print("  Keeping rule.")

    print()
    print("  Uninstall complete.")
    print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="skill-version-manager Offline Installer"
    )
    parser.add_argument(
        "--skip-rule",
        action="store_true",
        help="Install skill only, skip rule installation",
    )
    parser.add_argument(
        "--uninstall",
        action="store_true",
        help="Remove skill-version-manager and associated rules",
    )
    parser.add_argument(
        "--silent",
        action="store_true",
        help="Non-interactive install: skill to user-level, rule to user-level",
    )
    args = parser.parse_args()

    if args.uninstall:
        do_uninstall()
        return

    if args.silent:
        # Non-interactive mode: install everything to user-level
        print_banner()
        print("[1/2] Installing skill-version-manager...")
        dst = get_skill_install_dir()
        copy_skill(SKILL_SOURCE_DIR, dst)
        print(f"  [OK] Installed to: {dst}")
        print()

        if not args.skip_rule:
            print("[2/2] Installing rule to user-level...")
            install_rule(RULE_SOURCE_DIR, get_user_rule_dir())
        else:
            print("[2/2] Skipping rule (--skip-rule).")

        print()
        print("  Installation complete (silent mode).")
        print()
        return

    do_install(args)


if __name__ == "__main__":
    main()
