#!/usr/bin/env python3
"""
Review - Review pending Skills in the SVN repository.

Admin-only operations (verified via SVN commit signature):
  --list              List all pending Skills for review.
  --approve <name>    Approve a pending Skill.
  --reject <name>     Reject a pending Skill.
"""

import json
import os
import sys
import uuid
import argparse
from pathlib import Path
from datetime import datetime, timezone

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import svn_manager
import config_manager


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def list_pending_skills(workspace=None):
    """
    List all Skills with status='pending' from SVN.

    Returns:
        Tuple of (success: bool, pending_list: list[dict] | error: str)
    """
    config = config_manager.load_local_config(workspace)
    if not config:
        return False, "Not configured. Run init_repo.py --init first."

    svn_url = config["svn_url"]
    skills_url = f"{svn_url}/skills"

    # List all skill directories
    success, entries = svn_manager.svn_list(skills_url)
    if not success:
        return False, f"Failed to list skills: {entries}"

    pending = []
    for skill_name in entries:
        manifest_url = f"{skills_url}/{skill_name}/manifest.json"
        ok, data = svn_manager.read_json_from_svn(manifest_url)
        if ok and data.get("status") == "pending":
            pending.append(data)

    return True, pending


def generate_review_report(pending_skills):
    """Generate a formatted review report from pending Skills."""
    if not pending_skills:
        return "No pending Skills to review."

    lines = [
        f"{'='*60}",
        f"  PENDING SKILLS REVIEW REPORT",
        f"  Generated: {_now_iso()}",
        f"{'='*60}",
        "",
    ]

    for i, skill in enumerate(pending_skills, 1):
        lines.extend([
            f"  [{i}] {skill.get('skill_name', 'unknown')}",
            f"      Version:   {skill.get('version', 'N/A')}",
            f"      Author:    {skill.get('author', 'N/A')}",
            f"      Updated:   {skill.get('updated_at', 'N/A')}",
            f"      Changelog: {skill.get('changelog', 'N/A')}",
            f"      Description: {skill.get('description', 'N/A')[:80]}",
            "",
        ])

    lines.append(f"Total pending: {len(pending_skills)}")
    return "\n".join(lines)


def approve_skill(skill_name, reason="", workspace=None):
    """
    Approve a pending Skill.

    Args:
        skill_name: Name of the Skill to approve.
        reason: Optional approval comment.
        workspace: Workspace root path.

    Returns:
        Tuple of (success: bool, message: str)
    """
    return _review_skill(skill_name, "approved", reason, workspace)


def reject_skill(skill_name, reason, workspace=None):
    """
    Reject a pending Skill.

    Args:
        skill_name: Name of the Skill to reject.
        reason: Required rejection reason.
        workspace: Workspace root path.

    Returns:
        Tuple of (success: bool, message: str)
    """
    if not reason:
        return False, "A reason is required when rejecting a Skill."
    return _review_skill(skill_name, "rejected", reason, workspace)


def _review_skill(skill_name, action, reason, workspace=None):
    """
    Internal: Perform a review action on a Skill.

    Admin identity is verified via SVN commit signature — the user must
    perform a real SVN commit, and the server-authenticated author is
    checked against the admin list in team.json.

    Args:
        skill_name: Skill name.
        action: 'approved' or 'rejected'.
        reason: Review comment/reason.
        workspace: Workspace root path.

    Returns:
        Tuple of (success: bool, message: str)
    """
    workspace = workspace or config_manager.resolve_workspace()

    # Verify admin permission via SVN commit signature
    print("Verifying admin identity via SVN commit signature...")
    is_admin, verified_user, err = config_manager.verify_admin_via_svn_commit(workspace)
    if not is_admin:
        return False, err
    print(f"Identity verified: {verified_user} (admin)")

    config = config_manager.load_local_config(workspace)
    svn_url = config["svn_url"]

    # Checkout the skill directory
    skill_svn_url = f"{svn_url}/skills/{skill_name}"
    if not svn_manager.path_exists_in_svn(skill_svn_url):
        return False, f"Skill '{skill_name}' not found in SVN repository."

    temp_dir = svn_manager.create_temp_dir("review_")
    try:
        # Checkout skill directory
        ok, stdout, stderr = svn_manager.svn_checkout(skill_svn_url, temp_dir)
        if not ok:
            return False, f"Failed to checkout skill: {stderr}"

        # Read manifest
        manifest_path = Path(temp_dir) / "manifest.json"
        if not manifest_path.exists():
            return False, f"manifest.json not found for skill '{skill_name}'."

        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)

        # Verify current status
        current_status = manifest.get("status")
        if current_status != "pending":
            return False, (
                f"Skill '{skill_name}' status is '{current_status}', not 'pending'. "
                f"Only pending Skills can be reviewed."
            )

        # Update manifest
        now = _now_iso()
        manifest["status"] = action
        manifest["reviewed_by"] = verified_user
        manifest["reviewed_at"] = now
        if action == "rejected":
            manifest["reject_reason"] = reason

        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)

        # Commit manifest change
        commit_msg = f"[skill-manager] {action.capitalize()} {skill_name} v{manifest['version']} by {verified_user}"
        ok, stdout, stderr = svn_manager.svn_commit(temp_dir, commit_msg)
        if not ok:
            return False, f"Failed to commit review: {stderr}"

    finally:
        svn_manager.cleanup_temp_dir(temp_dir)

    # Append review record to history/reviews.jsonl
    _append_review_record(
        svn_url=svn_url,
        skill_name=skill_name,
        version=manifest.get("version", ""),
        submitted_by=manifest.get("author", ""),
        reviewed_by=verified_user,
        action=action,
        reason=reason,
    )

    action_text = "Approved" if action == "approved" else "Rejected"
    return True, (
        f"{action_text} skill '{skill_name}' v{manifest['version']}.\n"
        f"Reviewed by: {verified_user} (SVN-verified)\n"
        + (f"Reason: {reason}\n" if reason else "")
    )


def _append_review_record(svn_url, skill_name, version, submitted_by,
                           reviewed_by, action, reason):
    """Append a review record to history/reviews.jsonl in SVN."""
    record = {
        "review_id": str(uuid.uuid4()),
        "skill_name": skill_name,
        "version": version,
        "submitted_by": submitted_by,
        "reviewed_by": reviewed_by,
        "action": action,
        "reason": reason,
        "timestamp": _now_iso(),
    }
    record_line = json.dumps(record, ensure_ascii=False) + "\n"

    history_url = f"{svn_url}/history"
    temp_dir = svn_manager.create_temp_dir("review_hist_")
    try:
        # Checkout history directory
        ok, stdout, stderr = svn_manager.svn_checkout(history_url, temp_dir)
        if not ok:
            print(f"Warning: Failed to update review history: {stderr}")
            return

        reviews_path = Path(temp_dir) / "reviews.jsonl"

        # Append record
        with open(reviews_path, "a", encoding="utf-8") as f:
            f.write(record_line)

        # Commit
        commit_msg = f"[skill-manager] Review record: {action} {skill_name} v{version}"
        ok, stdout, stderr = svn_manager.svn_commit(temp_dir, commit_msg)
        if not ok:
            print(f"Warning: Failed to commit review history: {stderr}")

    except Exception as e:
        print(f"Warning: Failed to update review history: {e}")
    finally:
        svn_manager.cleanup_temp_dir(temp_dir)


def main():
    parser = argparse.ArgumentParser(description="Review pending Skills")
    parser.add_argument("--workspace", default=config_manager.resolve_workspace(), help="Workspace root")

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="List pending Skills")
    group.add_argument("--approve", metavar="SKILL_NAME", help="Approve a Skill")
    group.add_argument("--reject", metavar="SKILL_NAME", help="Reject a Skill")

    parser.add_argument("--reason", default="", help="Review comment/reason (required for reject)")

    args = parser.parse_args()

    if args.list:
        success, result = list_pending_skills(args.workspace)
        if success:
            report = generate_review_report(result)
            print(report)
        else:
            print(f"ERROR: {result}")
            sys.exit(1)

    elif args.approve:
        success, message = approve_skill(args.approve, args.reason, args.workspace)
        print(message)
        if not success:
            sys.exit(1)

    elif args.reject:
        if not args.reason:
            print("ERROR: --reason is required when rejecting a Skill.")
            sys.exit(1)
        success, message = reject_skill(args.reject, args.reason, args.workspace)
        print(message)
        if not success:
            sys.exit(1)


if __name__ == "__main__":
    from self_check import ensure_latest
    ensure_latest()
    main()
