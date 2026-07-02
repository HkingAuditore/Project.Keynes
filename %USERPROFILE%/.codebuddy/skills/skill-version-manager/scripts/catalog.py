#!/usr/bin/env python3
"""
Catalog - Query the SVN skill catalog for AI auto-discovery.

This script lists all approved Skills from the SVN repository with their
metadata (name, description, version, triggers). The AI uses this catalog
to decide which Skills to auto-download when a user's task matches.

Operations:
  --list           Output JSON array of all approved Skills with metadata.
  --match <query>  Output Skills whose name or description matches the query.
  --check <name>   Check if a specific Skill is available and its local status.
"""

import json
import os
import re
import sys
import argparse
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import svn_manager
import config_manager


SKILLS_LOCAL_DIR = None  # Lazy — use config_manager.get_skills_dir()


def _get_local_skills_dir(workspace=None):
    """Get the local .<ide>/skills/ directory path."""
    base = Path(workspace) if workspace else Path(config_manager.resolve_workspace())
    return base / config_manager.get_skills_dir()


def _load_local_manifest(skill_name, workspace=None):
    """Load manifest.json from a local Skill directory."""
    skills_dir = _get_local_skills_dir(workspace)
    manifest_path = skills_dir / skill_name / "manifest.json"
    if manifest_path.exists():
        try:
            with open(manifest_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return None


def _parse_skill_md_description(skill_md_content):
    """
    Parse the SKILL.md frontmatter to extract the description field.
    This is the field that tells the AI what the skill does and when to trigger it.

    Supports three YAML description formats:
      1. Multi-line block (no indicator):  description:\\n  line1\\n  line2
      2. Folded/literal block (> or |):    description: >\\n  line1\\n  line2
      3. Single-line:                      description: Some text
    """
    if not skill_md_content:
        return None

    # Normalise line endings to \n for consistent regex matching
    content = skill_md_content.replace('\r\n', '\n').replace('\r', '\n')

    # Match YAML frontmatter between --- markers
    match = re.match(r'^---[ \t]*\n(.*?)\n---', content, re.DOTALL)
    if not match:
        return None

    frontmatter = match.group(1)

    # Extract multi-line description (with or without > / | indicator)
    # Key fix: use [ \t]* instead of \s* so the first \n is NOT greedily
    # consumed before we explicitly match it with \n.
    desc_match = re.search(
        r'description:[ \t]*[>|]?[ \t]*\n((?:[ \t]+.+(?:\n|$))*)',
        frontmatter,
    )
    if desc_match:
        raw = desc_match.group(1)
        if raw.strip():
            # Clean up: join lines, strip extra whitespace
            lines = [line.strip() for line in raw.strip().split('\n')]
            return ' '.join(line for line in lines if line)

    # Try single-line description
    desc_match = re.search(r'description:[ \t]+(.+)', frontmatter)
    if desc_match:
        return desc_match.group(1).strip().strip('"').strip("'")

    return None


def get_catalog(workspace=None):
    """
    Get the full catalog of approved Skills from SVN.

    Returns:
        Tuple of (success: bool, catalog: list[dict] | error: str)
        Each dict has: skill_name, version, author, description,
                       skill_md_description (trigger info), local_status
    """
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]
    skills_url = f"{svn_url}/skills"

    # List all skills in SVN
    success, entries = svn_manager.svn_list(skills_url)
    if not success:
        return False, f"Failed to list skills from SVN: {entries}"

    catalog = []
    for name in entries:
        # Read manifest
        manifest_url = f"{skills_url}/{name}/manifest.json"
        ok, manifest = svn_manager.read_json_from_svn(manifest_url)
        if not ok:
            continue
        if manifest.get("status") != "approved":
            continue

        # Try to read SKILL.md frontmatter description (contains trigger phrases)
        skill_md_url = f"{skills_url}/{name}/SKILL.md"
        ok_md, skill_md_content, _ = svn_manager.svn_cat(skill_md_url)
        skill_md_desc = None
        if ok_md:
            skill_md_desc = _parse_skill_md_description(skill_md_content)

        # Check local status
        local_manifest = _load_local_manifest(name, workspace)
        if local_manifest is None:
            local_status = "not_installed"
        elif local_manifest.get("version") == manifest.get("version"):
            local_status = "up_to_date"
        else:
            local_status = "outdated"

        catalog.append({
            "skill_name": name,
            "version": manifest.get("version", ""),
            "author": manifest.get("author", ""),
            "description": manifest.get("description", ""),
            "skill_md_description": skill_md_desc,
            "install_scope": manifest.get("install_scope", "project"),
            "local_status": local_status,
        })

    return True, catalog


def match_skills(query, catalog):
    """
    Filter catalog entries whose name, description, or skill_md_description
    matches any word in the query (case-insensitive).

    Returns list of matching catalog entries.
    """
    if not query:
        return catalog

    query_lower = query.lower()
    query_words = query_lower.split()

    matched = []
    for entry in catalog:
        searchable = " ".join([
            entry.get("skill_name", ""),
            entry.get("description", ""),
            entry.get("skill_md_description", "") or "",
        ]).lower()

        # Match if any query word appears in the searchable text
        if any(word in searchable for word in query_words):
            matched.append(entry)

    return matched


def check_skill(skill_name, workspace=None):
    """
    Check a specific Skill's availability and local status.

    Returns:
        Tuple of (success: bool, info: dict | error: str)
    """
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]
    manifest_url = f"{svn_url}/skills/{skill_name}/manifest.json"

    ok, manifest = svn_manager.read_json_from_svn(manifest_url)
    if not ok:
        return False, f"Skill '{skill_name}' not found in SVN."

    local_manifest = _load_local_manifest(skill_name, workspace)
    if local_manifest is None:
        local_status = "not_installed"
    elif local_manifest.get("version") == manifest.get("version"):
        local_status = "up_to_date"
    else:
        local_status = "outdated"

    return True, {
        "skill_name": skill_name,
        "version": manifest.get("version", ""),
        "status": manifest.get("status", ""),
        "description": manifest.get("description", ""),
        "local_status": local_status,
        "available": manifest.get("status") == "approved",
    }


def main():
    parser = argparse.ArgumentParser(
        description="Query SVN skill catalog for AI auto-discovery"
    )
    parser.add_argument("--workspace", default=config_manager.resolve_workspace(), help="Workspace root")

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true",
                       help="List all approved Skills as JSON")
    group.add_argument("--match", metavar="QUERY",
                       help="Find Skills matching the query keywords")
    group.add_argument("--check", metavar="SKILL_NAME",
                       help="Check a specific Skill's availability")

    args = parser.parse_args()

    if args.list:
        success, result = get_catalog(args.workspace)
        if success:
            print(json.dumps(result, indent=2, ensure_ascii=False))
        else:
            print(json.dumps({"error": result}), file=sys.stderr)
            sys.exit(1)

    elif args.match:
        success, catalog = get_catalog(args.workspace)
        if not success:
            print(json.dumps({"error": catalog}), file=sys.stderr)
            sys.exit(1)
        matched = match_skills(args.match, catalog)
        print(json.dumps(matched, indent=2, ensure_ascii=False))

    elif args.check:
        success, result = check_skill(args.check, args.workspace)
        if success:
            print(json.dumps(result, indent=2, ensure_ascii=False))
        else:
            print(json.dumps({"error": result}), file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
