#!/usr/bin/env python3
"""
Self-Check Module — Ensures skill-version-manager is up-to-date before executing.

Usage (add to any script's __main__ block, BEFORE main()):

    from self_check import ensure_latest
    if __name__ == "__main__":
        ensure_latest()   # auto-updates & re-execs if newer version found
        main()

Behavior:
  1. Reads local manifest.json to get current version.
  2. Reads SVN manifest.json to get remote version.
  3. If remote is newer → svn export to temp → replace local files → re-exec.
  4. If network fails, SVN error, or any exception → silently skip, never block.
  5. Uses a lock file to prevent infinite re-exec loops.
  6. Skips entirely if --no-self-check flag is present in sys.argv.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# skill-version-manager's own directory (one level up from scripts/)
_SKILL_DIR = Path(__file__).resolve().parent.parent
_MANIFEST_PATH = _SKILL_DIR / "manifest.json"
_LOCK_FILE = _SKILL_DIR / ".self-check-lock"

# SVN path is derived from .svn-source.json or fallback
_DEFAULT_SVN_URL = "https://svn.woa.com/UGameArt/CodeBuddySkill/trunk/skills/user/skill-version-manager"


def _read_local_version():
    """Read local manifest version. Returns version string or None."""
    try:
        with open(_MANIFEST_PATH, "r", encoding="utf-8") as f:
            return json.load(f).get("version")
    except Exception:
        return None


def _get_svn_url():
    """Get the SVN URL for skill-version-manager."""
    source_file = _SKILL_DIR / ".svn-source.json"
    if source_file.exists():
        try:
            with open(source_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            url = data.get("svn_url", "").rstrip("/")
            if url:
                return url
        except Exception:
            pass
    return _DEFAULT_SVN_URL


def _read_svn_version(svn_url):
    """Read remote manifest version from SVN. Returns version string or None."""
    manifest_url = f"{svn_url}/manifest.json"
    try:
        r = subprocess.run(
            ["svn", "cat", manifest_url, "--non-interactive"],
            capture_output=True, text=True,
            encoding="utf-8", errors="replace",
            timeout=15,
        )
        if r.returncode != 0:
            return None
        data = json.loads(r.stdout)
        return data.get("version")
    except Exception:
        return None


def _version_tuple(version_str):
    """Parse '1.2.3' → (1, 2, 3). Returns (0,0,0) on failure."""
    try:
        return tuple(int(p) for p in version_str.strip().split("."))
    except (ValueError, AttributeError):
        return (0, 0, 0)


def _is_newer(remote_ver, local_ver):
    return _version_tuple(remote_ver) > _version_tuple(local_ver)


def _do_self_update(svn_url):
    """
    Download new version to temp dir, then replace local files.
    Returns True on success, False on failure.
    """
    temp_dir = tempfile.mkdtemp(prefix="svm_selfupdate_")
    temp_dest = Path(temp_dir) / "skill-version-manager"
    try:
        r = subprocess.run(
            ["svn", "export", "--force", "--non-interactive", svn_url, str(temp_dest)],
            capture_output=True, text=True,
            encoding="utf-8", errors="replace",
            timeout=60,
        )
        if r.returncode != 0:
            return False

        # Verify the export is valid
        if not (temp_dest / "manifest.json").exists():
            return False

        # Replace local files (preserve hidden files like .svn-source.json)
        for item in _SKILL_DIR.iterdir():
            if item.name.startswith("."):
                continue
            try:
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
            except Exception:
                pass

        for item in temp_dest.iterdir():
            dst = _SKILL_DIR / item.name
            try:
                if item.is_dir():
                    shutil.copytree(item, dst)
                else:
                    shutil.copy2(item, dst)
            except Exception:
                pass

        return True
    except Exception:
        return False
    finally:
        try:
            shutil.rmtree(temp_dir)
        except Exception:
            pass


def ensure_latest():
    """
    Check if skill-version-manager is up-to-date. If not, self-update and re-exec.

    Safe-guards:
    - --no-self-check flag skips entirely (used on re-exec to prevent loops)
    - Lock file prevents concurrent/recursive updates
    - All exceptions caught — never blocks normal execution
    """
    # Skip if explicitly disabled
    if "--no-self-check" in sys.argv:
        # Remove the flag so it doesn't confuse argparse
        sys.argv.remove("--no-self-check")
        return

    try:
        # Lock to prevent infinite re-exec loop
        if _LOCK_FILE.exists():
            try:
                _LOCK_FILE.unlink()
            except Exception:
                pass
            return

        local_ver = _read_local_version()
        if not local_ver:
            return

        svn_url = _get_svn_url()
        remote_ver = _read_svn_version(svn_url)
        if not remote_ver:
            return

        if not _is_newer(remote_ver, local_ver):
            return

        # Create lock before updating
        try:
            _LOCK_FILE.touch()
        except Exception:
            return

        print(f"[self-check] Updating skill-version-manager: {local_ver} → {remote_ver} ...")

        if _do_self_update(svn_url):
            print(f"[self-check] Updated to {remote_ver}. Re-executing with new version...")
            # Re-exec the same command with --no-self-check to prevent loop
            new_args = [sys.executable] + sys.argv + ["--no-self-check"]
            try:
                os.execv(sys.executable, new_args)
            except Exception:
                # execv failed, continue with old code
                pass
        else:
            print("[self-check] Update failed, continuing with current version.")

    except Exception:
        # Never block normal execution
        pass
    finally:
        # Clean up lock file
        try:
            if _LOCK_FILE.exists():
                _LOCK_FILE.unlink()
        except Exception:
            pass
