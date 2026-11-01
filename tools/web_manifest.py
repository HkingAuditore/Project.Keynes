#!/usr/bin/env python3
"""Write / verify `WebBuild/manifest.json` for the Godot Web export.

Why: the export uses fixed filenames (`ProjectKeynes.pck`, `ProjectKeynes.side.wasm`,
...), so a browser cannot tell one build from the next by URL alone. The manifest
records a sha256 per artifact, which gives three things at once:

  * a strong `ETag` for tools/serve_web.py (content-addressed, survives mtime
    changes) — it only trusts an entry while size + mtime still match the file,
    so a rebuild without regenerating the manifest degrades to a stat ETag
    instead of serving a stale-but-valid looking cache;
  * a stable `build_id` (first 12 hex of the combined artifact hashes) that names
    a versioned deploy directory, e.g. `/builds/<build_id>/`, where it is safe to
    serve the same bytes with `Cache-Control: public, max-age=31536000, immutable`
    (`python tools/serve_web.py --immutable`);
  * a cheap post-export drift check (`verify`) for CI and for "did the export
    actually rewrite the pck?" questions.

Usage:
    python tools/web_manifest.py write  --root WebBuild
    python tools/web_manifest.py verify --root WebBuild
    python tools/web_manifest.py id     --root WebBuild
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import time

SCHEMA = 1
MANIFEST_NAME = "manifest.json"

# Artifacts that define "this build". Everything else in the folder (sidecars,
# logs, the pck dump) is ignored so the manifest stays stable across re-runs.
ARTIFACT_SUFFIXES = (".html", ".js", ".pck", ".wasm", ".png", ".json")
IGNORED_NAMES = {MANIFEST_NAME}
IGNORED_SUFFIXES = (".br", ".gz", ".log", ".jsonl")


def iter_artifacts(root: pathlib.Path) -> list[pathlib.Path]:
    out: list[pathlib.Path] = []
    for entry in sorted(root.iterdir()):
        if not entry.is_file():
            continue
        name = entry.name
        if name in IGNORED_NAMES:
            continue
        if name.endswith(IGNORED_SUFFIXES):
            continue
        if not name.endswith(ARTIFACT_SUFFIXES):
            continue
        # `ProjectKeynes.pck.json` is an audit dump, not a runtime artifact.
        if name.endswith(".pck.json") or name.endswith(".wasm.json"):
            continue
        out.append(entry)
    return out


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(root: pathlib.Path) -> dict:
    files: dict[str, dict] = {}
    hasher = hashlib.sha256()
    for entry in iter_artifacts(root):
        st = entry.stat()
        digest = sha256_file(entry)
        files[entry.name] = {"sha256": digest, "size": st.st_size, "mtime_ns": st.st_mtime_ns}
        hasher.update(entry.name.encode())
        hasher.update(digest.encode())
    return {
        "schema": SCHEMA,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "build_id": hasher.hexdigest()[:12],
        "files": files,
    }


def cmd_write(root: pathlib.Path) -> int:
    manifest = build_manifest(root)
    if not manifest["files"]:
        print(f"no artifacts found under {root}", file=sys.stderr)
        return 1
    target = root / MANIFEST_NAME
    target.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n",
                      encoding="utf-8")
    total = sum(item["size"] for item in manifest["files"].values())
    print(f"[manifest] {len(manifest['files'])} artifacts, {total / 1048576:.2f} MB")
    for name, item in sorted(manifest["files"].items(), key=lambda kv: -kv[1]["size"]):
        print(f"  {item['size'] / 1048576:8.2f} MB  {item['sha256'][:12]}  {name}")
    print(f"[manifest] build_id = {manifest['build_id']}")
    print(f"[manifest] wrote {target}")
    return 0


def cmd_verify(root: pathlib.Path) -> int:
    target = root / MANIFEST_NAME
    if not target.exists():
        print(f"missing {target}; run: python tools/web_manifest.py write --root {root}",
              file=sys.stderr)
        return 1
    recorded = json.loads(target.read_text(encoding="utf-8"))
    files = recorded.get("files", {})
    problems: list[str] = []
    present = {entry.name: entry for entry in iter_artifacts(root)}
    for name, item in files.items():
        entry = present.get(name)
        if entry is None:
            problems.append(f"missing: {name}")
            continue
        st = entry.stat()
        if st.st_size != item.get("size"):
            problems.append(f"size changed: {name} {item.get('size')} -> {st.st_size}")
            continue
        if sha256_file(entry) != item.get("sha256"):
            problems.append(f"content changed: {name}")
    for name in sorted(set(present) - set(files)):
        problems.append(f"not in manifest: {name}")
    if problems:
        print("[manifest] DRIFT")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"[manifest] ok ({len(files)} artifacts, build_id {recorded.get('build_id')})")
    return 0


def cmd_id(root: pathlib.Path) -> int:
    target = root / MANIFEST_NAME
    if not target.exists():
        print(build_manifest(root)["build_id"])
        return 0
    print(json.loads(target.read_text(encoding="utf-8")).get("build_id", ""))
    return 0


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("write", "verify", "id"))
    parser.add_argument("--root", default=str(repo_root / "WebBuild"))
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    if not root.is_dir():
        print(f"root directory does not exist: {root}", file=sys.stderr)
        return 1
    if args.command == "write":
        return cmd_write(root)
    if args.command == "verify":
        return cmd_verify(root)
    return cmd_id(root)


if __name__ == "__main__":
    raise SystemExit(main())
