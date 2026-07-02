#!/usr/bin/env python3
"""
Sync All — Batch sync CodeBuddy assets from SVN to local directories.

Supports 4 asset types: skills, agents, commands, rules.
This is a pure CLI tool. No AI involvement, no token consumption.

Usage:
  python sync_all.py                          # Sync all approved skills
  python sync_all.py --type all               # Sync ALL asset types
  python sync_all.py --type agents            # Sync agents only
  python sync_all.py --type rules --role art  # Sync art-related rules
  python sync_all.py --role art               # Only sync art-related skills
  python sync_all.py --role ta                # Sync TA + art + shared
  python sync_all.py --role dev               # Sync dev + shared
  python sync_all.py --names a b c            # Only sync named assets
  python sync_all.py --dry-run                # Preview without executing
  python sync_all.py --svn-url <url>          # Override SVN URL
"""

import argparse
import io
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

# ============================================================
# Fix Windows console encoding (GBK → UTF-8)
# ============================================================
if sys.stdout and hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
if sys.stderr and hasattr(sys.stderr, "reconfigure"):
    try:
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

# ============================================================
# Configuration
# ============================================================

# Default SVN URL — points to trunk/ (contains skills/, agents/, commands/, rules/)
DEFAULT_SVN_URL = "https://svn.woa.com/UGameArt/CodeBuddySkill/trunk"

# Base user directory — auto-detect IDE (codebuddy / workbuddy / cursor)
_IDE_DIR_NAME = None


def _detect_ide_dir():
    """Detect the IDE dot-directory name from script location or filesystem."""
    global _IDE_DIR_NAME
    if _IDE_DIR_NAME is not None:
        return _IDE_DIR_NAME

    # Env override
    env_ide = os.environ.get("SKILL_MANAGER_IDE_DIR", "").strip().strip("/\\")
    if env_ide:
        _IDE_DIR_NAME = env_ide
        return _IDE_DIR_NAME

    _home = Path(os.environ.get("USERPROFILE", str(Path.home()))) \
        if platform.system() == "Windows" else Path.home()

    known = [".codebuddy", ".workbuddy", ".cursor"]

    # Detect from own path
    script_path = Path(__file__).resolve()
    for part in script_path.parts:
        if part in known:
            _IDE_DIR_NAME = part
            return _IDE_DIR_NAME

    # Check which exists with skills/
    for ide_dir in known:
        if (_home / ide_dir / "skills").is_dir():
            _IDE_DIR_NAME = ide_dir
            return _IDE_DIR_NAME

    _IDE_DIR_NAME = ".codebuddy"
    return _IDE_DIR_NAME


def _get_ide_home():
    """Return ~/.<ide>/ path."""
    ide_dir = _detect_ide_dir()
    if platform.system() == "Windows":
        return Path(os.environ.get("USERPROFILE", str(Path.home()))) / ide_dir
    return Path.home() / ide_dir


_CODEBUDDY_HOME = _get_ide_home()

# Supported asset types: maps type name → SVN subdir and local subdir
ASSET_TYPES = {
    "skills":   {"svn_subdir": "skills",   "local_subdir": "skills"},
    "agents":   {"svn_subdir": "agents",   "local_subdir": "agents"},
    "commands": {"svn_subdir": "commands", "local_subdir": "commands"},
    "rules":    {"svn_subdir": "rules",    "local_subdir": "rules"},
}

# Role → allowed SVN subdirectories mapping
ROLE_DIRS = {
    "art":  ["shared", "art", "user"],
    "ta":   ["shared", "art", "ta", "user"],
    "dev":  ["shared", "dev", "user"],
    "all":  None,  # None = sync everything
}

SCRIPT_DIR = Path(__file__).resolve().parent

# Workspace root for "project" scope installs.
# Resolved in main() from: --workspace CLI arg > CODEBUDDY_WORKSPACE env > Path.cwd()
_WORKSPACE = None


def _resolve_workspace(cli_workspace=None):
    """Determine the workspace root directory, independent of cwd.

    Resolution order:
      1. Explicit --workspace CLI arg
      2. *_WORKSPACE environment variable (checks CODEBUDDY_, WORKBUDDY_, CURSOR_)
      3. Path.cwd() — but ONLY if cwd is outside ~/.<ide>/
         (If cwd is inside ~/.<ide>/, it usually means an AI agent
          cd'd into the scripts dir to run this file.  In that case we
          fall back to *_PROJECT_ROOT or raise an error so the
          caller notices the misconfiguration instead of silently
          installing project-scope assets into the wrong place.)
    """
    if cli_workspace:
        return Path(cli_workspace).resolve()

    for prefix in ("CODEBUDDY", "WORKBUDDY", "CURSOR"):
        env_ws = os.environ.get(f"{prefix}_WORKSPACE")
        if env_ws:
            return Path(env_ws).resolve()

    cwd = Path.cwd().resolve()
    codebuddy_home = _CODEBUDDY_HOME.resolve()

    # Guard: reject cwd when it sits inside the global ~/.<ide>/ tree.
    if _is_subpath(cwd, codebuddy_home):
        for prefix in ("CODEBUDDY", "WORKBUDDY", "CURSOR"):
            project_root = os.environ.get(f"{prefix}_PROJECT_ROOT")
            if project_root:
                return Path(project_root).resolve()
        ide_dir = _detect_ide_dir()
        print(
            f"  [WARN] cwd is inside ~/{ide_dir}/ — refusing to use it as "
            "workspace.\n"
            "         Please pass --workspace <project_dir> or set the "
            f"{ide_dir.strip('.').upper()}_WORKSPACE env var.",
            file=sys.stderr,
        )
        sys.exit(1)

    return cwd


def _is_subpath(child: Path, parent: Path) -> bool:
    """Return True if *child* is equal to or inside *parent*."""
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def _get_config_path():
    """Get the canonical config.json path. Auto-creates parent dir if needed."""
    p = _CODEBUDDY_HOME / "skills" / ".svn-skill-manager" / "config.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def _load_config():
    """Load config.json. Returns dict or empty dict if not found."""
    p = _get_config_path()
    if p.exists():
        try:
            with open(p, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def _save_config(cfg):
    """Save config.json."""
    p = _get_config_path()
    with open(p, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)


def get_user_asset_dir(asset_type="skills"):
    """Get the user-level install directory for an asset type."""
    info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
    return _CODEBUDDY_HOME / info["local_subdir"]


# ============================================================
# SVN helpers
# ============================================================

def _run(cmd, check=True, timeout=60):
    """Run a command and return stdout, or None on failure."""
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout,
        )
        if check and r.returncode != 0:
            err = r.stderr.strip()
            if err:
                print(f"  [ERR] {err}")
            return None
        return r.stdout.strip()
    except subprocess.TimeoutExpired:
        print(f"  [ERR] Command timed out: {' '.join(cmd[:4])}...")
        return None
    except FileNotFoundError:
        print("  [ERR] svn not found. Please install SVN CLI.")
        sys.exit(1)


def svn_list(url):
    """List immediate children of an SVN directory (names only, no trailing slash)."""
    out = _run(["svn", "list", url, "--non-interactive"])
    if out is None:
        return []
    return [e.rstrip("/") for e in out.splitlines() if e.strip()]


def svn_list_dirs(url):
    """List only subdirectory names of an SVN directory (excludes files)."""
    out = _run(["svn", "list", url, "--non-interactive"])
    if out is None:
        return []
    return [e.rstrip("/") for e in out.splitlines() if e.strip() and e.endswith("/")]


def svn_export(url, dest):
    """Export (clean copy) from SVN to local path."""
    p = Path(dest)
    if p.exists():
        if p.is_dir():
            shutil.rmtree(dest)
        else:
            p.unlink()
    out = _run(
        ["svn", "export", "--force", "--non-interactive", url, str(dest)],
        timeout=120,
    )
    return out is not None


def svn_cat_json(url):
    """Read a JSON file from SVN, return dict or None."""
    out = _run(["svn", "cat", url, "--non-interactive"], check=False)
    if out is None:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


# ============================================================
# Config resolution
# ============================================================

def resolve_svn_url(cli_url=None):
    """Determine SVN URL from: CLI arg > local config > default."""
    if cli_url:
        return cli_url.rstrip("/")

    cfg = _load_config()
    url = cfg.get("svn_url", "").rstrip("/")
    if url:
        return url

    return DEFAULT_SVN_URL


# ============================================================
# Core sync logic
# ============================================================

def _is_asset_dir(dir_url, asset_type="skills"):
    """
    Check whether an SVN directory is an actual asset (not an intermediate grouping dir).
    An asset has manifest.json, SKILL.md, or (for rules) an .mdc file.
    """
    if asset_type == "skills":
        manifest = svn_cat_json(f"{dir_url}/manifest.json")
        if manifest is not None:
            return True
        # Check for SKILL.md (case-insensitive: SKILL.md, skill.md, Skill.md, etc.)
        entries = svn_list(dir_url)
        return any(e.lower() == "skill.md" for e in entries)
    elif asset_type == "rules":
        entries = svn_list(dir_url)
        return any(e.endswith(".mdc") for e in entries)
    else:
        manifest = svn_cat_json(f"{dir_url}/manifest.json")
        return manifest is not None


def _scan_dir_recursive(dir_url, group, asset_type, assets, max_depth=3, _depth=0):
    """
    Recursively scan an SVN directory for assets.
    - Scans subdirectories for directory-based assets (skills, etc.).
    - Also picks up loose single-file assets: .mdc (rules), .md (agents).
    - If a subdirectory is an asset, add it to the list.
    - If it's an intermediate directory (no manifest/SKILL.md), recurse into it.
    - max_depth prevents infinite recursion.
    """
    if _depth >= max_depth:
        return

    # Use svn_list_dirs to only get subdirectories, skipping loose files
    entries = svn_list_dirs(dir_url)

    # Check for loose single-file assets:
    #   - rules: .mdc files
    #   - agents: .md files
    _single_file_extensions = {}
    if asset_type == "rules":
        _single_file_extensions[".mdc"] = True
    elif asset_type == "agents":
        _single_file_extensions[".md"] = True

    if _single_file_extensions:
        all_entries = svn_list(dir_url)
        for entry_name in all_entries:
            if entry_name.startswith("_") or entry_name.startswith("."):
                continue
            if any(entry_name.endswith(ext) for ext in _single_file_extensions):
                effective_scope = "user" if group == "user" else "project"
                assets.append({
                    "name": entry_name,
                    "group": group,
                    "svn_url": f"{dir_url}/{entry_name}",
                    "version": "?",
                    "install_scope": effective_scope,
                    "roles": [],
                    "asset_type": asset_type,
                })

    for entry_name in entries:
        if entry_name.startswith("_") or entry_name.startswith("."):
            continue

        entry_url = f"{dir_url}/{entry_name}"
        manifest_url = f"{entry_url}/manifest.json"
        manifest = svn_cat_json(manifest_url)

        if manifest is not None:
            if manifest.get("status") == "rejected":
                continue
            version = manifest.get("version", "?")
            roles = manifest.get("roles", [])
            manifest_scope = manifest.get("install_scope")
        elif _is_asset_dir(entry_url, asset_type):
            version = "?"
            roles = []
            manifest_scope = None
        else:
            _scan_dir_recursive(entry_url, group, asset_type, assets, max_depth, _depth + 1)
            continue

        if manifest_scope:
            effective_scope = manifest_scope
        elif group == "user":
            effective_scope = "user"
        else:
            effective_scope = "project"

        assets.append({
            "name": entry_name,
            "group": group,
            "svn_url": entry_url,
            "version": version,
            "install_scope": effective_scope,
            "roles": roles,
            "asset_type": asset_type,
        })


def get_remote_assets(svn_url, asset_type="skills"):
    """
    Fetch the list of approved assets from SVN for a given asset type.
    Supports nested directory structures (e.g. skills/shared/unity/my-skill).
    Returns list of dicts with: name, version, install_scope, roles, group, svn_url, asset_type.
    """
    info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
    asset_url = f"{svn_url}/{info['svn_subdir']}"
    entries = svn_list(asset_url)

    assets = []
    for name in entries:
        if name.startswith("_") or name.startswith("."):
            continue

        entry_url = f"{asset_url}/{name}"
        manifest_url = f"{entry_url}/manifest.json"
        manifest = svn_cat_json(manifest_url)

        if manifest is not None:
            if manifest.get("status") == "rejected":
                continue
            assets.append({
                "name": name,
                "group": None,
                "svn_url": entry_url,
                "version": manifest.get("version", "?"),
                "install_scope": manifest.get("install_scope", "project"),
                "roles": manifest.get("roles", []),
                "asset_type": asset_type,
            })
            continue

        # No manifest at top level — this is a group directory (shared/, art/, etc.)
        # Recursively scan for assets within it
        _scan_dir_recursive(entry_url, name, asset_type, assets, max_depth=3, _depth=0)

    return assets


def filter_assets(assets, role=None, names=None):
    """Filter assets by role or explicit names."""
    if names:
        name_set = set(names)
        return [s for s in assets if s["name"] in name_set]

    if not role or role == "all":
        return assets

    allowed_groups = ROLE_DIRS.get(role)

    filtered = []
    for s in assets:
        if s["group"] and allowed_groups and s["group"] in allowed_groups:
            filtered.append(s)
        elif s.get("roles") and role in s["roles"]:
            filtered.append(s)
        elif not s["group"] and not s.get("roles"):
            filtered.append(s)

    return filtered


def get_local_version(asset_name, install_scope="user", asset_type="skills"):
    """Read the local installed version of an asset."""
    user_dir = get_user_asset_dir(asset_type)
    if install_scope == "user":
        manifest_path = user_dir / asset_name / "manifest.json"
    else:
        info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
        manifest_path = _WORKSPACE / _detect_ide_dir() / info["local_subdir"] / asset_name / "manifest.json"

    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                return json.load(f).get("version")
        except Exception:
            pass
    return None


def sync_asset(asset):
    """Sync a single asset from SVN to local. Returns (success, message)."""
    name = asset["name"]
    remote_ver = asset["version"]
    scope = asset["install_scope"]
    asset_type = asset.get("asset_type", "skills")

    local_ver = get_local_version(name, scope, asset_type)
    if local_ver == remote_ver:
        return True, f"{name} v{remote_ver} — already up to date"

    user_dir = get_user_asset_dir(asset_type)
    if scope == "user":
        dest = user_dir / name
    else:
        info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
        dest = _WORKSPACE / _detect_ide_dir() / info["local_subdir"] / name

    dest.parent.mkdir(parents=True, exist_ok=True)

    ok = svn_export(asset["svn_url"], str(dest))
    if ok:
        # Write SVN source info for auto_update.py to locate the remote manifest
        # Only for directory-based assets, not single files (e.g. .mdc rules)
        if dest.is_dir():
            try:
                source_info = {
                    "svn_url": asset["svn_url"],
                    "group": asset.get("group"),
                    "asset_type": asset_type,
                    "install_scope": scope,
                }
                with open(dest / ".svn-source.json", "w", encoding="utf-8") as f:
                    json.dump(source_info, f, indent=2, ensure_ascii=False)
            except Exception:
                pass  # Non-critical, don't fail the sync

        action = "updated" if local_ver else "installed"
        ver_info = f"{local_ver} → {remote_ver}" if local_ver else f"v{remote_ver}"
        scope_tag = "[user]" if scope == "user" else "[project]"
        return True, f"{name} {ver_info} — {action} {scope_tag}"
    else:
        return False, f"{name} — export failed"


# ============================================================
# Main
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description="Sync team assets (skills/agents/commands/rules) from SVN to local CodeBuddy directories",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--type", choices=list(ASSET_TYPES.keys()) + ["all"], default="skills",
                        help="Asset type to sync (default: skills). Use 'all' to sync every type.")
    parser.add_argument("--role", choices=["art", "ta", "dev", "all"], default=None,
                        help="Filter by role. If not specified, reads from saved config. Use 'all' to sync everything.")
    parser.add_argument("--set-role", choices=["art", "ta", "dev", "all"], default=None,
                        help="Save your role to config for future syncs (e.g. --set-role ta)")
    parser.add_argument("--names", nargs="+", metavar="NAME",
                        help="Only sync specific assets by name")
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview mode — no actual sync")
    parser.add_argument("--svn-url", default=None,
                        help="Override SVN repository URL")
    parser.add_argument("--install-dir", default=None,
                        help="Override install directory (user-level base)")
    parser.add_argument("--workspace", default=None,
                        help="Project workspace root for 'project' scope installs "
                             "(default: CODEBUDDY_WORKSPACE env or cwd)")
    args = parser.parse_args()

    global _CODEBUDDY_HOME, _WORKSPACE
    if args.install_dir:
        _CODEBUDDY_HOME = Path(args.install_dir)

    # Resolve workspace early — all project-scope paths depend on this
    _WORKSPACE = _resolve_workspace(args.workspace)

    # Handle --set-role: save and use
    if args.set_role:
        cfg = _load_config()
        cfg["role"] = args.set_role
        # Also ensure svn_url is populated if missing
        if not cfg.get("svn_url"):
            cfg["svn_url"] = DEFAULT_SVN_URL
        if not cfg.get("initialized"):
            cfg["initialized"] = True
        _save_config(cfg)
        print(f"Role saved: {args.set_role}")
        # Use the newly set role for this sync if --role not explicitly given
        if args.role is None:
            args.role = args.set_role

    # Resolve role: CLI arg > config file > default 'all'
    if args.role is None:
        cfg = _load_config()
        saved_role = cfg.get("role")
        if saved_role:
            args.role = saved_role
            print(f"Using saved role: {args.role} (override with --role)")
        else:
            args.role = "all"

    svn_url = resolve_svn_url(args.svn_url)

    # Determine which asset types to sync
    if args.type == "all":
        types_to_sync = list(ASSET_TYPES.keys())
    else:
        types_to_sync = [args.type]

    print(f"=== Asset Sync ===")
    print(f"SVN:       {svn_url}")
    print(f"Workspace: {_WORKSPACE}")
    print(f"Types:     {', '.join(types_to_sync)}")
    if args.role != "all":
        print(f"Role:  {args.role}")
    print()

    total_success = 0
    total_fail = 0

    for asset_type in types_to_sync:
        user_dir = get_user_asset_dir(asset_type)
        info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
        project_dir = _WORKSPACE / _detect_ide_dir() / info["local_subdir"]
        print(f"--- {asset_type} (user → {user_dir} | project → {project_dir}) ---")

        # 1. Fetch remote assets
        all_assets = get_remote_assets(svn_url, asset_type)
        if not all_assets:
            print(f"  No approved {asset_type} found.\n")
            continue
        print(f"  Found {len(all_assets)} approved {asset_type}")

        # 2. Filter
        targets = filter_assets(all_assets, role=args.role, names=args.names)
        if not targets:
            print(f"  No {asset_type} match the filter.\n")
            continue
        if args.role != "all" or args.names:
            print(f"  After filtering: {len(targets)}")

        # 3. Preview / Sync
        if args.dry_run:
            for s in targets:
                group_tag = f" [{s['group']}]" if s["group"] else ""
                print(f"  - {s['name']} v{s['version']}{group_tag}")
        else:
            for asset in targets:
                ok, msg = sync_asset(asset)
                symbol = "✓" if ok else "✗"
                print(f"  {symbol} {msg}")
                if ok:
                    total_success += 1
                else:
                    total_fail += 1
        print()

    if args.dry_run:
        print(f"[dry-run] Done. No changes made.")
    else:
        print(f"=== Done: {total_success} synced, {total_fail} failed ===")


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
