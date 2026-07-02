#!/usr/bin/env python3
"""
SVN Transfer - Generic upload/download for CodeBuddy assets to/from SVN.

Supports 4 asset types: skills, agents, commands, rules.
Each type can be organized into role groups: shared, art, ta, dev, user.

Unlike publish.py (which enforces pending review) and sync.py (which only
pulls approved Skills), this script provides **direct** SVN transfer:

  Upload: local directory  →  SVN {type}/{group}/{name}/
  Download: SVN {type}/{group}/{name}/  →  local directory

Operations:
  --upload   <name>       Upload a local asset to SVN (overwrite if exists).
  --download <name>       Download an asset from SVN to local.
  --upload-all            Upload all local assets of given type to SVN.
  --list                  List all assets in SVN with basic info.

Options:
  --type <type>           Asset type: skills|agents|commands|rules (default: skills)
  --group <group>         Role group: shared|art|ta|dev|user (upload target subdir)
  --local-path <path>     Explicit local path (overrides auto-detection).
  --scope user|project    Where to look for / install the asset.
  --message <msg>         Custom commit message for upload.
  --force                 Overwrite local directory on download without asking.
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


# ─── Asset type configuration ────────────────────────────────────────

ASSET_TYPES = {
    "skills":   {"svn_subdir": "skills",   "local_subdir": "skills"},
    "agents":   {"svn_subdir": "agents",   "local_subdir": "agents"},
    "commands": {"svn_subdir": "commands", "local_subdir": "commands"},
    "rules":    {"svn_subdir": "rules",    "local_subdir": "rules"},
}

ROLE_GROUPS = ["shared", "art", "ta", "dev", "user"]


def _get_user_asset_dir(asset_type="skills"):
    """Get user-level ~/.<ide>/{type}/ directory."""
    info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
    return config_manager._get_codebuddy_home() / info["local_subdir"]


def _get_project_asset_dir(asset_type="skills", workspace=None):
    """Get project-level .<ide>/{type}/ directory."""
    info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
    base = Path(workspace) if workspace else Path(config_manager.resolve_workspace())
    return base / config_manager.get_ide_dir_name() / info["local_subdir"]


def _get_svn_asset_url(svn_url, asset_type="skills", group=None):
    """Build SVN URL for an asset type, optionally with a group subdirectory."""
    info = ASSET_TYPES.get(asset_type, ASSET_TYPES["skills"])
    url = f"{svn_url}/{info['svn_subdir']}"
    if group:
        url = f"{url}/{group}"
    return url


# ─── Shared helpers (unchanged from original) ────────────────────────

SKIP_NAMES = {".svn", ".git", "__pycache__", ".svn-skill-manager", ".DS_Store",
              ".codebuddy", ".workbuddy", ".cursor"}
SKIP_EXTENSIONS = {".pyc", ".pyo"}


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _resolve_local_path(asset_name, local_path=None, scope="user", workspace=None, asset_type="skills"):
    if local_path:
        return Path(local_path)
    if scope == "user":
        return _get_user_asset_dir(asset_type) / asset_name
    else:
        return _get_project_asset_dir(asset_type, workspace) / asset_name


def _find_asset_local(asset_name, local_path=None, scope=None, workspace=None, asset_type="skills"):
    if local_path:
        p = Path(local_path)
        return p if p.exists() else None

    if scope:
        p = _resolve_local_path(asset_name, scope=scope, workspace=workspace, asset_type=asset_type)
        return p if p.exists() else None

    user_path = _get_user_asset_dir(asset_type) / asset_name
    if user_path.exists():
        return user_path

    project_path = _get_project_asset_dir(asset_type, workspace) / asset_name
    if project_path.exists():
        return project_path

    return None


def _should_skip(item):
    if item.name in SKIP_NAMES:
        return True
    if item.suffix in SKIP_EXTENSIONS:
        return True
    return False


def _copy_asset_to_dir(src, dst):
    src = Path(src)
    dst = Path(dst)

    if dst.exists():
        for item in dst.iterdir():
            if item.name == ".svn":
                continue
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()

    dst.mkdir(parents=True, exist_ok=True)

    for item in src.iterdir():
        if _should_skip(item):
            continue
        dst_item = dst / item.name
        if item.is_dir():
            shutil.copytree(item, dst_item, ignore=shutil.ignore_patterns(
                ".svn", ".git", "__pycache__", "*.pyc", "*.pyo", ".DS_Store"
            ))
        else:
            shutil.copy2(item, dst_item)


def _svn_add_new_files(work_dir):
    ok, stdout, stderr = svn_manager.svn_status(work_dir)
    if not ok:
        return
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        status_char = line[0]
        file_path = line[7:].strip() if len(line) > 7 else line[1:].strip()
        if status_char == "?":
            svn_manager._run_svn(["add", file_path], cwd=work_dir)
        elif status_char == "!":
            svn_manager._run_svn(["delete", file_path], cwd=work_dir)


# ─── SVN Search & Recommend ───────────────────────────────────────────


def _find_asset_in_svn(svn_url, asset_name, asset_type="skills"):
    """
    Search for an asset across top-level and all ROLE_GROUPS in SVN.

    Returns:
        (found: bool, group: str | None, svn_url: str | None)
        - found=True: group is the group name (None if top-level), svn_url is the full path
        - found=False: group=None, svn_url=None
    """
    # Check top-level first
    top_url = f"{_get_svn_asset_url(svn_url, asset_type)}/{asset_name}"
    if svn_manager.path_exists_in_svn(top_url):
        return True, None, top_url

    # Check each role group
    for g in ROLE_GROUPS:
        candidate = f"{_get_svn_asset_url(svn_url, asset_type, g)}/{asset_name}"
        if svn_manager.path_exists_in_svn(candidate):
            return True, g, candidate

    return False, None, None


def _recommend_group(found_path, asset_type="skills"):
    """
    Recommend an SVN group based on local asset content.

    Priority:
    1. manifest.json install_scope == "user" → "user"
    2. SKILL.md / description keyword matching → art/dev/ta
    3. Default → "shared"

    Returns:
        (recommended_group: str, reason: str)
    """
    found_path = Path(found_path)

    # 1. Check manifest install_scope
    manifest_path = found_path / "manifest.json"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                manifest = json.load(f)
            if manifest.get("install_scope") == "user":
                return "user", "manifest.json install_scope is 'user'"
        except (json.JSONDecodeError, IOError):
            pass

    # 2. Keyword matching from SKILL.md description or manifest description
    text_to_scan = ""

    skill_md = found_path / "SKILL.md"
    if skill_md.exists():
        try:
            with open(skill_md, "r", encoding="utf-8") as f:
                text_to_scan += f.read(2000).lower()
        except IOError:
            pass

    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                manifest = json.load(f)
            text_to_scan += " " + manifest.get("description", "").lower()
        except (json.JSONDecodeError, IOError):
            pass

    # Keyword → group mapping
    art_keywords = ["art", "美术", "资源规范", "模型", "贴图", "材质", "shader",
                    "prefab", "动画", "特效", "mesh", "texture", "fbx",
                    "folder-convention", "model-import"]
    ta_keywords = ["ta", "技术美术", "render", "渲染", "pipeline", "光照",
                   "profiler", "性能", "lightprofiler"]
    dev_keywords = ["dev", "开发", "代码", "typescript", "c#", "框架",
                    "framework", "debug", "编译", "compile"]

    if any(kw in text_to_scan for kw in art_keywords):
        return "art", "content matches art-related keywords"
    if any(kw in text_to_scan for kw in ta_keywords):
        return "ta", "content matches TA-related keywords"
    if any(kw in text_to_scan for kw in dev_keywords):
        return "dev", "content matches dev-related keywords"

    # 3. Default
    return "shared", "no specific group detected, defaulting to shared"


# ─── Upload ──────────────────────────────────────────────────────────


def upload_asset(asset_name, local_path=None, scope=None, workspace=None,
                 message=None, asset_type="skills", group=None):
    """
    Upload a local asset to the SVN repository.

    Smart upload flow:
    1. Search SVN across all groups to find if asset already exists
    2. If exists: update in-place (ignore --group if it conflicts, with warning)
    3. If not exists + --group specified: create in the specified group
    4. If not exists + no --group: return GROUP_REQUIRED with recommendation

    Args:
        asset_name: Name of the asset.
        local_path: Explicit local path to the asset directory.
        scope: 'user' or 'project' (auto-detect if None).
        workspace: Workspace root path.
        message: Custom commit message.
        asset_type: One of skills/agents/commands/rules.
        group: Role group subdirectory (shared/art/ta/dev/user). None = auto-detect.

    Returns:
        Tuple of (success: bool, message: str)
        Special: returns (None, json_str) when group confirmation is needed (exit code 2).
    """
    workspace = workspace or config_manager.resolve_workspace()

    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]

    # Find local asset
    found_path = _find_asset_local(asset_name, local_path, scope, workspace, asset_type)
    if not found_path:
        search_locations = []
        if local_path:
            search_locations.append(str(local_path))
        else:
            search_locations.append(str(_get_user_asset_dir(asset_type) / asset_name))
            search_locations.append(str(_get_project_asset_dir(asset_type, workspace) / asset_name))
        return False, (
            f"Asset '{asset_name}' ({asset_type}) not found locally.\n"
            f"Searched:\n" + "\n".join(f"  - {p}" for p in search_locations)
        )

    print(f"Found {asset_type} at: {found_path}")

    # Read manifest for version info (if exists)
    manifest_path = found_path / "manifest.json"
    version = "unknown"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                manifest = json.load(f)
            version = manifest.get("version", "unknown")
            if "install_scope" not in manifest:
                default_scope = config_manager.get_default_install_scope(workspace)
                manifest["install_scope"] = default_scope
                with open(manifest_path, "w", encoding="utf-8") as f:
                    json.dump(manifest, f, indent=2, ensure_ascii=False)
                print(f"Set default install_scope: {default_scope}")
        except (json.JSONDecodeError, IOError):
            pass

    # ── Phase 1: Search SVN for existing asset ──
    print(f"\nSearching SVN for '{asset_name}' ({asset_type})...")
    svn_found, svn_group, svn_asset_url = _find_asset_in_svn(svn_url, asset_name, asset_type)

    if svn_found:
        # Asset exists in SVN — update in-place
        if group and group != svn_group:
            print(f"WARNING: Asset already exists in [{svn_group or 'top-level'}], "
                  f"ignoring --group {group}. Updating in existing location.")
        actual_group = svn_group
        asset_svn_url = svn_asset_url
        asset_base_url = _get_svn_asset_url(svn_url, asset_type, actual_group)
        action = "Update"
        print(f"Found in SVN: {asset_svn_url} (group: {actual_group or 'top-level'})")
    else:
        # Asset does not exist in SVN
        if not group:
            # No --group specified → recommend and request confirmation
            rec_group, rec_reason = _recommend_group(found_path, asset_type)
            group_required_info = {
                "action": "GROUP_REQUIRED",
                "asset_name": asset_name,
                "asset_type": asset_type,
                "version": version,
                "local_path": str(found_path),
                "recommended_group": rec_group,
                "recommendation_reason": rec_reason,
                "available_groups": ROLE_GROUPS,
                "message": (
                    f"Asset '{asset_name}' is new (not found in SVN). "
                    f"Recommended group: '{rec_group}' ({rec_reason}). "
                    f"Please confirm or choose a different group from: {ROLE_GROUPS}"
                ),
            }
            return None, json.dumps(group_required_info, ensure_ascii=False, indent=2)

        # --group specified → create new
        actual_group = group
        asset_base_url = _get_svn_asset_url(svn_url, asset_type, actual_group)
        asset_svn_url = f"{asset_base_url}/{asset_name}"
        action = "New"
        print(f"Asset not found in SVN. Will create new in group: {actual_group}")

    group_label = f" [{actual_group}]" if actual_group else ""
    commit_msg = message or f"[skill-manager] {action} {asset_type}/{actual_group or ''}/{asset_name} v{version}"

    print(f"Type:   {asset_type}{group_label}")
    print(f"Action: {action}")
    print(f"Version: {version}")
    print(f"SVN:    {asset_svn_url}")

    # ── Phase 2: Perform SVN operations ──
    temp_dir = svn_manager.create_temp_dir("upload_")
    try:
        if action == "Update":
            ok, stdout, stderr = svn_manager.svn_checkout(asset_svn_url, temp_dir)
            if not ok:
                return False, f"SVN checkout failed: {stderr}"
            _copy_asset_to_dir(found_path, Path(temp_dir))
            _svn_add_new_files(temp_dir)
        else:
            # Ensure parent group dir exists in SVN
            if actual_group and not svn_manager.path_exists_in_svn(asset_base_url):
                ok, _, stderr = svn_manager.svn_mkdir_remote(
                    asset_base_url, f"[skill-manager] Create {asset_type}/{actual_group}/ directory"
                )
                if not ok:
                    return False, f"Failed to create SVN directory {asset_base_url}: {stderr}"

            ok, stdout, stderr = svn_manager.svn_checkout(asset_base_url, temp_dir, depth="empty")
            if not ok:
                return False, f"SVN checkout failed: {stderr}"

            asset_dir = Path(temp_dir) / asset_name
            asset_dir.mkdir(parents=True)
            _copy_asset_to_dir(found_path, asset_dir)

            ok, stdout, stderr = svn_manager.svn_add(str(asset_dir), cwd=temp_dir)
            if not ok:
                return False, f"SVN add failed: {stderr}"

        ok, status_out, _ = svn_manager.svn_status(temp_dir)
        if ok and status_out.strip():
            print(f"\nChanges to commit:")
            for line in status_out.splitlines():
                print(f"  {line.strip()}")
        elif ok:
            return True, f"No changes detected for '{asset_name}'. Already up to date."

        ok, stdout, stderr = svn_manager.svn_commit(temp_dir, commit_msg)
        if not ok:
            if "nothing to commit" in stderr.lower() or "no changes" in stderr.lower():
                return True, f"No changes detected for '{asset_name}'. Already up to date."
            return False, f"SVN commit failed: {stderr}"

        revision = "?"
        for line in stdout.splitlines():
            if "Committed revision" in line:
                revision = line.split("revision")[1].strip().rstrip(".")
                break

        return True, (
            f"Successfully uploaded '{asset_name}' v{version} to SVN.\n"
            f"Type: {asset_type}{group_label}\n"
            f"Revision: {revision}\n"
            f"Source: {found_path}"
        )

    finally:
        svn_manager.cleanup_temp_dir(temp_dir)


# ─── Download ────────────────────────────────────────────────────────


def download_asset(asset_name, local_path=None, scope=None, workspace=None,
                   force=False, asset_type="skills", group=None):
    """
    Download an asset from SVN to local.

    If group is specified, downloads from {type}/{group}/{name}.
    Otherwise searches {type}/{name} and all group subdirectories.

    Install scope is determined by group:
      - user/ group → user scope (~/.codebuddy/{type}/)
      - other groups (shared/art/ta/dev) → project scope (.codebuddy/{type}/)
      - explicit --scope overrides this default
    """
    workspace = workspace or config_manager.resolve_workspace()

    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]

    # Find the asset in SVN (reuse shared search function)
    if group:
        asset_svn_url = f"{_get_svn_asset_url(svn_url, asset_type, group)}/{asset_name}"
        if not svn_manager.path_exists_in_svn(asset_svn_url):
            return False, f"Asset '{asset_name}' ({asset_type}/{group}) not found in SVN."
    else:
        found, found_group, found_url = _find_asset_in_svn(svn_url, asset_name, asset_type)
        if found:
            asset_svn_url = found_url
            group = found_group
            if group:
                print(f"Found in group: {group}")
        else:
            return False, f"Asset '{asset_name}' ({asset_type}) not found in SVN."

    # Determine install scope: explicit --scope > group-based default
    if scope is None:
        scope = "user" if group == "user" else "project"

    target_dir = _resolve_local_path(asset_name, local_path, scope, workspace, asset_type)

    if target_dir.exists():
        if not force:
            local_version = "unknown"
            local_manifest = target_dir / "manifest.json"
            if local_manifest.exists():
                try:
                    with open(local_manifest, "r", encoding="utf-8") as f:
                        local_version = json.load(f).get("version", "unknown")
                except (json.JSONDecodeError, IOError):
                    pass

            svn_version = "unknown"
            ok, svn_data = svn_manager.read_json_from_svn(f"{asset_svn_url}/manifest.json")
            if ok:
                svn_version = svn_data.get("version", "unknown")

            print(f"Local version: {local_version}")
            print(f"SVN version:   {svn_version}")

            if local_version == svn_version:
                return True, f"Asset '{asset_name}' is already up to date (v{svn_version})."

        print(f"Removing existing: {target_dir}")
        shutil.rmtree(target_dir)

    print(f"Downloading '{asset_name}' to: {target_dir}")
    target_dir.parent.mkdir(parents=True, exist_ok=True)

    ok, stdout, stderr = svn_manager.svn_export(asset_svn_url, str(target_dir))
    if not ok:
        return False, f"SVN export failed: {stderr}"

    version = "unknown"
    manifest_path = target_dir / "manifest.json"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                version = json.load(f).get("version", "unknown")
        except (json.JSONDecodeError, IOError):
            pass

    return True, (
        f"Successfully downloaded '{asset_name}' v{version}.\n"
        f"Location: {target_dir}"
    )


# ─── List ────────────────────────────────────────────────────────────


def _svn_list_raw(url):
    """List SVN entries preserving trailing slash (directories end with '/')."""
    success, stdout, stderr = svn_manager._run_svn(["list", url])
    if not success:
        return False, []
    return True, [e.strip() for e in stdout.splitlines() if e.strip()]


def _svn_list_dirs_only(url):
    """List only subdirectory names from an SVN URL (excludes files)."""
    ok, raw_entries = _svn_list_raw(url)
    if not ok:
        return False, []
    dirs = [e.rstrip("/") for e in raw_entries if e.endswith("/")]
    return True, dirs


def _scan_svn_dir_for_list(dir_url, group, asset_type, assets, workspace, max_depth=3, _depth=0):
    """Recursively scan an SVN directory for assets to list. Only iterates subdirectories."""
    if _depth >= max_depth:
        return

    # Only iterate subdirectories to avoid treating .md files as directories
    success, dir_entries = _svn_list_dirs_only(dir_url)
    if not success:
        return

    # Also check for loose .mdc files in rules directories
    if asset_type == "rules":
        all_ok, all_raw = _svn_list_raw(dir_url)
        if all_ok:
            for raw_entry in all_raw:
                name = raw_entry.rstrip("/")
                if not raw_entry.endswith("/") and name.endswith(".mdc") and not name.startswith("_") and not name.startswith("."):
                    info = {"asset_name": name, "group": group, "asset_type": asset_type}
                    info.update({"version": "?", "status": "?", "author": "?", "description": ""})
                    local = _find_asset_local(name, workspace=workspace, asset_type=asset_type)
                    info["local"] = str(local) if local else None
                    assets.append(info)

    for entry_name in dir_entries:
        if entry_name.startswith("_") or entry_name.startswith("."):
            continue

        entry_url = f"{dir_url}/{entry_name}"
        manifest_url = f"{entry_url}/manifest.json"
        ok, data = svn_manager.read_json_from_svn(manifest_url)

        if ok:
            info = {"asset_name": entry_name, "group": group, "asset_type": asset_type}
            info.update({
                "version": data.get("version", "?"),
                "status": data.get("status", "?"),
                "author": data.get("author", "?"),
                "description": data.get("description", "")[:60],
            })
            local = _find_asset_local(entry_name, workspace=workspace, asset_type=asset_type)
            info["local"] = str(local) if local else None
            assets.append(info)
        else:
            # Check if this is an asset without manifest (e.g. has SKILL.md/skill.md)
            child_success, child_entries = svn_manager.svn_list(entry_url)
            if child_success:
                has_skill_md = any(e.lower() == "skill.md" for e in child_entries)
                has_mdc = any(e.endswith(".mdc") for e in child_entries) if asset_type == "rules" else False

                if has_skill_md or has_mdc:
                    info = {"asset_name": entry_name, "group": group, "asset_type": asset_type}
                    info.update({"version": "?", "status": "?", "author": "?", "description": ""})
                    local = _find_asset_local(entry_name, workspace=workspace, asset_type=asset_type)
                    info["local"] = str(local) if local else None
                    assets.append(info)
                else:
                    # Intermediate directory, recurse
                    _scan_svn_dir_for_list(entry_url, group, asset_type, assets, workspace, max_depth, _depth + 1)


def list_svn_assets(workspace=None, asset_type="skills"):
    """
    List all assets of a given type in SVN repository.
    Supports nested directory structures (e.g. skills/shared/unity/my-skill).
    """
    workspace = workspace or config_manager.resolve_workspace()

    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]
    asset_url = _get_svn_asset_url(svn_url, asset_type)

    success, entries = svn_manager.svn_list(asset_url)
    if not success:
        return False, f"Failed to list {asset_type}: {entries}"

    assets = []
    for name in entries:
        if name.startswith("_") or name.startswith("."):
            continue

        entry_url = f"{asset_url}/{name}"
        manifest_url = f"{entry_url}/manifest.json"
        ok, data = svn_manager.read_json_from_svn(manifest_url)

        if ok:
            info = {"asset_name": name, "group": None, "asset_type": asset_type}
            info.update({
                "version": data.get("version", "?"),
                "status": data.get("status", "?"),
                "author": data.get("author", "?"),
                "description": data.get("description", "")[:60],
            })
            local = _find_asset_local(name, workspace=workspace, asset_type=asset_type)
            info["local"] = str(local) if local else None
            assets.append(info)
            continue

        # No manifest at top level — this is a group directory, recursively scan
        _scan_svn_dir_for_list(entry_url, name, asset_type, assets, workspace, max_depth=3, _depth=0)

    return True, assets


def format_asset_list(assets, asset_type="skills"):
    if not assets:
        return f"No {asset_type} found in SVN repository."

    lines = [
        f"{'='*80}",
        f"  SVN {asset_type.upper()} REPOSITORY",
        f"{'='*80}",
        "",
        f"  {'Name':<25} {'Group':<8} {'Version':<10} {'Status':<10} {'Author':<15} {'Local'}",
        f"  {'-'*75}",
    ]

    for s in assets:
        local_tag = "✓" if s.get("local") else "-"
        group_tag = s.get("group", "-") or "-"
        lines.append(
            f"  {s['asset_name']:<25} "
            f"{group_tag:<8} "
            f"{s['version']:<10} "
            f"{s['status']:<10} "
            f"{s['author']:<15} "
            f"{local_tag}"
        )

    lines.extend(["", f"  Total: {len(assets)} {asset_type}"])
    return "\n".join(lines)


# ─── Batch Upload ────────────────────────────────────────────────────


def upload_all_local(scope="user", workspace=None, message=None, asset_type="skills", group=None):
    workspace = workspace or config_manager.resolve_workspace()

    if scope == "user":
        asset_dir = _get_user_asset_dir(asset_type)
    else:
        asset_dir = _get_project_asset_dir(asset_type, workspace)

    if not asset_dir.exists():
        return False, f"Asset directory not found: {asset_dir}"

    asset_dirs = [d for d in asset_dir.iterdir()
                  if d.is_dir() and not d.name.startswith(".")]

    if not asset_dirs:
        return False, f"No valid {asset_type} found in {asset_dir}"

    results = []
    errors = []

    for d in sorted(asset_dirs):
        name = d.name
        print(f"\n{'─'*40}")
        print(f"Uploading: {name} ({asset_type})")
        print(f"{'─'*40}")

        ok, msg = upload_asset(
            name, local_path=str(d), workspace=workspace,
            message=message, asset_type=asset_type, group=group,
        )
        if ok:
            results.append(f"  ✓ {name}: {msg.splitlines()[0]}")
        else:
            errors.append(f"  ✗ {name}: {msg}")

    summary_parts = [
        f"\n{'='*50}",
        f"  UPLOAD SUMMARY ({asset_type})",
        f"{'='*50}",
    ]
    if results:
        summary_parts.append(f"\nSucceeded ({len(results)}):")
        summary_parts.extend(results)
    if errors:
        summary_parts.append(f"\nFailed ({len(errors)}):")
        summary_parts.extend(errors)
    summary_parts.append(f"\nTotal: {len(results)} succeeded, {len(errors)} failed out of {len(asset_dirs)}")

    return len(errors) == 0, "\n".join(summary_parts)


# ─── CLI ─────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Generic SVN upload/download for CodeBuddy assets (skills/agents/commands/rules)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Upload a skill to the user group
  python svn_transfer.py --upload skill-version-manager --type skills --group user

  # Upload with explicit path
  python svn_transfer.py --upload my-skill --local-path /path/to/my-skill --type skills

  # Upload all user-level skills
  python svn_transfer.py --upload-all --scope user --type skills

  # Download a skill
  python svn_transfer.py --download my-skill --type skills --scope user

  # List all agents
  python svn_transfer.py --list --type agents

  # Upload a rule to art group
  python svn_transfer.py --upload my-rule --type rules --group art
        """
    )

    parser.add_argument("--workspace", default=config_manager.resolve_workspace(),
                        help="Workspace root path")

    # Actions
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--upload", metavar="NAME",
                        help="Upload an asset to SVN")
    action.add_argument("--download", metavar="NAME",
                        help="Download an asset from SVN")
    action.add_argument("--upload-all", action="store_true",
                        help="Upload all local assets of given type to SVN")
    action.add_argument("--list", action="store_true",
                        help="List all assets in SVN")

    # Asset type & group
    parser.add_argument("--type", choices=list(ASSET_TYPES.keys()), default="skills",
                        help="Asset type (default: skills)")
    parser.add_argument("--group", choices=ROLE_GROUPS, default=None,
                        help="Role group subdirectory (shared/art/ta/dev/user)")

    # Options
    parser.add_argument("--local-path", default=None,
                        help="Explicit local path for the asset directory")
    parser.add_argument("--scope", choices=["user", "project"], default=None,
                        help="Asset scope: 'user' (~/.codebuddy/{type}/) "
                             "or 'project' (.codebuddy/{type}/)")
    parser.add_argument("--message", "-m", default=None,
                        help="Custom commit message for upload")
    parser.add_argument("--force", action="store_true",
                        help="Force overwrite on download")

    args = parser.parse_args()

    if args.upload:
        ok, msg = upload_asset(
            args.upload,
            local_path=args.local_path,
            scope=args.scope,
            workspace=args.workspace,
            message=args.message,
            asset_type=args.type,
            group=args.group,
        )
        if ok is None:
            # GROUP_REQUIRED: asset is new and no --group specified
            # Output JSON for AI to parse, exit with code 2
            print(f"\n{msg}")
            sys.exit(2)
        print(f"\n{msg}")
        if not ok:
            sys.exit(1)

    elif args.download:
        ok, msg = download_asset(
            args.download,
            local_path=args.local_path,
            scope=args.scope,  # None if not specified → auto-detect by group
            workspace=args.workspace,
            force=args.force,
            asset_type=args.type,
            group=args.group,
        )
        print(f"\n{msg}")
        if not ok:
            sys.exit(1)

    elif args.upload_all:
        scope = args.scope or "user"
        ok, msg = upload_all_local(
            scope=scope,
            workspace=args.workspace,
            message=args.message,
            asset_type=args.type,
            group=args.group,
        )
        print(msg)
        if not ok:
            sys.exit(1)

    elif args.list:
        ok, result = list_svn_assets(args.workspace, args.type)
        if ok:
            print(format_asset_list(result, args.type))
        else:
            print(f"ERROR: {result}")
            sys.exit(1)


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
