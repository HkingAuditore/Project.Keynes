#!/usr/bin/env python3
"""
SVN Manager - Low-level SVN command wrapper.

Encapsulates all SVN CLI operations (checkout, commit, add, list, info,
export, log, etc.) with unified error handling, output parsing, and
timeout control.
"""

import subprocess
import json
import os
import sys
import tempfile
import shutil
from pathlib import Path


# Default timeout for SVN commands (seconds)
DEFAULT_TIMEOUT = 30
LONG_TIMEOUT = 120  # For export/checkout of large repos


def _run_svn(args, timeout=DEFAULT_TIMEOUT, cwd=None):
    """
    Execute an SVN command and return (success, stdout, stderr).

    Args:
        args: List of SVN command arguments (without 'svn' prefix).
        timeout: Command timeout in seconds.
        cwd: Working directory for the command.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    cmd = ["svn"] + args + ["--non-interactive"]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
            encoding="utf-8",
            errors="replace",
        )
        success = result.returncode == 0
        return success, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "", f"SVN command timed out after {timeout} seconds: svn {' '.join(args)}"
    except FileNotFoundError:
        return False, "", "SVN command not found. Please ensure SVN CLI is installed and in PATH."
    except Exception as e:
        return False, "", f"Error executing SVN command: {str(e)}"


def check_svn_installed():
    """Check if SVN CLI is available on the system."""
    success, stdout, stderr = _run_svn(["--version", "--quiet"])
    if success:
        return True, stdout
    return False, stderr


def check_connection(svn_url):
    """
    Check if the SVN repository URL is reachable.

    Returns:
        Tuple of (reachable: bool, info_dict_or_error: dict|str)
    """
    success, stdout, stderr = _run_svn(["info", svn_url])
    if success:
        info = _parse_svn_info(stdout)
        return True, info
    return False, stderr


def _parse_svn_info(output):
    """Parse 'svn info' output into a dictionary."""
    info = {}
    for line in output.splitlines():
        if ": " in line:
            key, _, value = line.partition(": ")
            info[key.strip()] = value.strip()
    return info


def svn_list(svn_url, timeout=DEFAULT_TIMEOUT):
    """
    List entries at the given SVN URL.

    Returns:
        Tuple of (success: bool, entries: list[str] | error: str)
    """
    success, stdout, stderr = _run_svn(["list", svn_url], timeout=timeout)
    if success:
        entries = [e.rstrip("/") for e in stdout.splitlines() if e.strip()]
        return True, entries
    return False, stderr


def svn_info(svn_url_or_path, timeout=DEFAULT_TIMEOUT):
    """
    Get SVN info for a URL or local working copy path.

    Returns:
        Tuple of (success: bool, info_dict: dict | error: str)
    """
    success, stdout, stderr = _run_svn(["info", svn_url_or_path], timeout=timeout)
    if success:
        return True, _parse_svn_info(stdout)
    return False, stderr


def svn_checkout(svn_url, local_path, depth="infinity", timeout=LONG_TIMEOUT):
    """
    Checkout an SVN URL to a local path.

    Args:
        svn_url: The SVN URL to checkout.
        local_path: Local directory to checkout into.
        depth: Checkout depth ('infinity', 'immediates', 'files', 'empty').
        timeout: Command timeout.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    args = ["checkout", svn_url, str(local_path), "--depth", depth]
    return _run_svn(args, timeout=timeout)


def svn_export(svn_url, local_path, timeout=LONG_TIMEOUT):
    """
    Export (clean copy without .svn metadata) from SVN URL to local path.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    args = ["export", svn_url, str(local_path), "--force"]
    return _run_svn(args, timeout=timeout)


def svn_add(paths, cwd=None):
    """
    Add files/directories to SVN version control.

    Args:
        paths: Single path string or list of paths to add.
        cwd: Working directory.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    if isinstance(paths, str):
        paths = [paths]
    args = ["add"] + [str(p) for p in paths]
    return _run_svn(args, cwd=cwd)


def svn_commit(path, message, timeout=LONG_TIMEOUT):
    """
    Commit changes in the working copy.

    Args:
        path: Path to the working copy (or specific file).
        message: Commit message.
        timeout: Command timeout.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    args = ["commit", str(path), "-m", message]
    return _run_svn(args, timeout=timeout)


def svn_update(path, timeout=LONG_TIMEOUT):
    """
    Update a working copy to latest revision.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    args = ["update", str(path)]
    return _run_svn(args, timeout=timeout)


def svn_log(svn_url_or_path, limit=10, timeout=DEFAULT_TIMEOUT):
    """
    Get SVN log entries.

    Args:
        svn_url_or_path: SVN URL or local working copy path.
        limit: Maximum number of log entries.
        timeout: Command timeout.

    Returns:
        Tuple of (success: bool, log_entries: list[dict] | error: str)
    """
    args = ["log", str(svn_url_or_path), "--limit", str(limit), "--xml"]
    success, stdout, stderr = _run_svn(args, timeout=timeout)
    if success:
        entries = _parse_svn_log_xml(stdout)
        return True, entries
    return False, stderr


def _parse_svn_log_xml(xml_output):
    """Parse SVN log XML output into a list of dicts."""
    import xml.etree.ElementTree as ET

    entries = []
    try:
        root = ET.fromstring(xml_output)
        for logentry in root.findall("logentry"):
            entry = {
                "revision": logentry.get("revision", ""),
                "author": "",
                "date": "",
                "message": "",
            }
            author_elem = logentry.find("author")
            if author_elem is not None and author_elem.text:
                entry["author"] = author_elem.text
            date_elem = logentry.find("date")
            if date_elem is not None and date_elem.text:
                entry["date"] = date_elem.text
            msg_elem = logentry.find("msg")
            if msg_elem is not None and msg_elem.text:
                entry["message"] = msg_elem.text
            entries.append(entry)
    except ET.ParseError:
        pass
    return entries


def svn_cat(svn_url, timeout=DEFAULT_TIMEOUT):
    """
    Read file contents from SVN URL without checking out.

    Returns:
        Tuple of (success: bool, content: str | error: str)
    """
    args = ["cat", svn_url]
    return _run_svn(args, timeout=timeout)


def svn_mkdir_remote(svn_url, message, timeout=DEFAULT_TIMEOUT):
    """
    Create a directory directly in the SVN repository (remote operation).

    Args:
        svn_url: SVN URL of the directory to create.
        message: Commit message.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    args = ["mkdir", svn_url, "-m", message, "--parents"]
    return _run_svn(args, timeout=timeout)


def svn_import(local_path, svn_url, message, timeout=LONG_TIMEOUT):
    """
    Import a local directory tree into SVN repository.

    Args:
        local_path: Local path to import.
        svn_url: Target SVN URL.
        message: Commit message.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    args = ["import", str(local_path), svn_url, "-m", message]
    return _run_svn(args, timeout=timeout)


def svn_status(path, cwd=None):
    """
    Check SVN status of a working copy.

    Returns:
        Tuple of (success: bool, stdout: str, stderr: str)
    """
    args = ["status", str(path)]
    return _run_svn(args, cwd=cwd)


def svn_diff(path_or_url, timeout=DEFAULT_TIMEOUT):
    """
    Show differences in working copy or between revisions.

    Returns:
        Tuple of (success: bool, diff_output: str, stderr: str)
    """
    args = ["diff", str(path_or_url)]
    return _run_svn(args, timeout=timeout)


def create_temp_dir(prefix="svn_skill_"):
    """Create a temporary directory for SVN operations."""
    return tempfile.mkdtemp(prefix=prefix)


def cleanup_temp_dir(temp_dir):
    """Remove a temporary directory and all its contents."""
    try:
        shutil.rmtree(temp_dir, ignore_errors=True)
    except Exception:
        pass


def read_json_from_svn(svn_url, timeout=DEFAULT_TIMEOUT):
    """
    Read and parse a JSON file directly from SVN.

    Returns:
        Tuple of (success: bool, data: dict | error: str)
    """
    success, content, stderr = svn_cat(svn_url, timeout=timeout)
    if not success:
        return False, stderr
    try:
        data = json.loads(content)
        return True, data
    except json.JSONDecodeError as e:
        return False, f"Failed to parse JSON from {svn_url}: {str(e)}"


def path_exists_in_svn(svn_url, timeout=DEFAULT_TIMEOUT):
    """
    Check if a path (file or directory) exists in the SVN repository.

    Returns:
        bool
    """
    success, _, _ = _run_svn(["info", svn_url], timeout=timeout)
    return success


if __name__ == "__main__":
    # Quick self-test: check SVN installation
    installed, version_or_err = check_svn_installed()
    if installed:
        print(f"SVN is installed. Version: {version_or_err}")
    else:
        print(f"SVN is NOT installed or not in PATH: {version_or_err}")
        sys.exit(1)
