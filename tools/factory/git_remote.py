"""Serialize factory operations that write linked worktrees' shared Git refs."""

import fcntl
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def lock_remote_refs(repo: str):
    command = ["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"could not locate shared Git refs for {repo}: {result.stderr.strip()}")
    lock_path = Path(result.stdout.rstrip("\n")) / "keynes-factory-remote.lock"
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def main() -> int:
    repo, *args = sys.argv[1:]
    try:
        with lock_remote_refs(repo):
            return subprocess.call(["git", "-C", repo, *args])
    except (OSError, RuntimeError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
