#!/usr/bin/env python3
"""
Build Release - Package skill-version-manager into a distributable zip file.

Usage:
    python build_release.py                    # Build to default output dir
    python build_release.py --output-dir /tmp  # Build to specific directory
    python build_release.py --no-rule          # Exclude bundled rule

Output:
    skill-version-manager-v{VERSION}.zip

The zip contains:
    skill-version-manager-v{VERSION}/
    ├── install.py              <- Run this to install
    ├── manifest.json
    ├── SKILL.md
    ├── references/
    ├── scripts/
    └── bundled-rules/
        └── auto-check-team-skills.mdc
"""

import os
import sys
import json
import zipfile
import argparse
from pathlib import Path
from datetime import datetime


SCRIPT_DIR = Path(__file__).resolve().parent

# Items to EXCLUDE from the zip
EXCLUDE_ITEMS = {
    "build_release.py",    # This script itself
    "__pycache__",
    ".svn",
    ".pyc",
}


def get_version():
    """Read version from manifest.json."""
    manifest = SCRIPT_DIR / "manifest.json"
    if manifest.exists():
        with open(manifest, "r", encoding="utf-8") as f:
            return json.load(f).get("version", "0.0.0")
    return "0.0.0"


def should_exclude(path: Path, no_rule: bool = False):
    """Check if a path should be excluded from the zip."""
    name = path.name

    # Exclude items by name
    if name in EXCLUDE_ITEMS:
        return True

    # Exclude __pycache__ directories and .pyc files
    if name == "__pycache__" or name.endswith(".pyc"):
        return True

    # Exclude .svn directories
    for part in path.parts:
        if part == ".svn" or part == "__pycache__":
            return True

    # Optionally exclude bundled-rules
    if no_rule and "bundled-rules" in path.parts:
        return True

    return False


def build_zip(output_dir: Path, no_rule: bool = False):
    """Build the release zip file."""
    version = get_version()
    zip_name = f"skill-version-manager-v{version}.zip"
    zip_path = output_dir / zip_name

    # The top-level directory name inside the zip
    top_dir = f"skill-version-manager-v{version}"

    print(f"Building {zip_name}...")
    print(f"  Source: {SCRIPT_DIR}")
    print(f"  Output: {zip_path}")
    print()

    file_count = 0
    total_size = 0

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(SCRIPT_DIR):
            root_path = Path(root)

            # Filter out excluded directories (modifying dirs in-place)
            dirs[:] = [
                d for d in dirs
                if not should_exclude(root_path / d, no_rule)
            ]

            for filename in sorted(files):
                file_path = root_path / filename

                if should_exclude(file_path, no_rule):
                    continue

                # Calculate the relative path from SCRIPT_DIR
                rel_path = file_path.relative_to(SCRIPT_DIR)

                # Archive name: top_dir/relative_path
                arcname = f"{top_dir}/{rel_path}"

                zf.write(file_path, arcname)
                file_size = file_path.stat().st_size
                total_size += file_size
                file_count += 1
                print(f"  + {rel_path} ({file_size:,} bytes)")

    zip_size = zip_path.stat().st_size

    print()
    print("=" * 55)
    print(f"  Release built successfully!")
    print(f"  Files: {file_count}")
    print(f"  Uncompressed: {total_size:,} bytes")
    print(f"  Compressed:   {zip_size:,} bytes")
    print(f"  Output: {zip_path}")
    print("=" * 55)
    print()
    print("Distribution instructions:")
    print(f"  1. Share {zip_name} with team members")
    print(f"  2. Recipient unzips and runs:")
    print(f"     cd {top_dir}")
    print(f"     python install.py")
    print(f"  3. Or for silent install:")
    print(f"     python install.py --silent")
    print()

    return zip_path


def main():
    parser = argparse.ArgumentParser(
        description="Build skill-version-manager release zip"
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=str(SCRIPT_DIR.parent),
        help=f"Output directory (default: {SCRIPT_DIR.parent})",
    )
    parser.add_argument(
        "--no-rule",
        action="store_true",
        help="Exclude bundled rule file from the zip",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    build_zip(output_dir, args.no_rule)


if __name__ == "__main__":
    main()
