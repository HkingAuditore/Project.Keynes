#!/bin/zsh -l
# launchd invokes this with a login shell so PATH includes the configured tools.
set -eu
: "${KEYNES_REPO:?set KEYNES_REPO to the main Project.Keynes checkout}"
HOME_DIR="${KEYNES_FACTORY_HOME:-$HOME/.keynes-factory}"
REMOTE="${KEYNES_FACTORY_REMOTE:-fork}"
export KEYNES_FACTORY_HOME="$HOME_DIR"

if [ "${1:-}" = "--pr-lane" ]; then
  shift
  runner="$HOME_DIR/pr-runner"
  entry=watch_prs.py
elif [ "$#" -eq 0 ]; then
  runner="$HOME_DIR/runner"
  entry=run.py
  set -- --next
else
  # Preserve targeted and dry PR invocations of the installed script.
  runner="$HOME_DIR/pr-runner"
  entry=watch_prs.py
fi

mkdir -p "$HOME_DIR"
# Also protect the sparse checkout before the Python entry point takes its lane lock.
zmodload zsh/system
touch "$runner.lock"
if ! zsystem flock -t 0 -f runner_lock "$runner.lock"; then
  echo "$entry is already running"
  exit 0
fi

git -C "$KEYNES_REPO" fetch --prune -q "$REMOTE"
ref="$REMOTE/master"
if [ -f "$HOME_DIR/runner-ref" ]; then
  pinned="$(cat "$HOME_DIR/runner-ref")"
  if ! git -C "$KEYNES_REPO" merge-base --is-ancestor "$pinned" "$ref"; then
    ref="$pinned"
  fi
fi
if [ ! -e "$runner/.git" ]; then
  git -C "$KEYNES_REPO" worktree add --no-checkout --detach "$runner" "$ref"
  git -C "$runner" sparse-checkout set --no-cone '/tools/factory/' '/.github/'
fi
git -C "$runner" checkout -q --detach "$ref"
cd "$runner"
if [ ! -f "tools/factory/$entry" ]; then
  factory_entry="$(git ls-tree --name-only HEAD -- tools/factory)"
  if [ -z "$factory_entry" ] && [ ! -d tools/factory ]; then
    echo "$(date -u +%FT%TZ) $ref has no tools/factory/ yet"
    exit 0
  fi
  echo "$(date -u +%FT%TZ) tools/factory/$entry is missing from $runner" >&2
  exit 1
fi
if [ ! -x tools/factory/bin/godot ]; then
  echo "$ref lacks the parallel factory code. Install with --runner-ref or update fork/master." >&2
  exit 1
fi

py="${KEYNES_FACTORY_PYTHON:-python3}"
"$py" "tools/factory/$entry" "$@"
