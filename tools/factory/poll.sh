#!/bin/zsh -l
# One poll: refresh the runner worktree to the fork's master, then look at the open PRs once.
# launchd starts this through `/bin/zsh -l` so PATH has gh, git, codex and node.
set -eu
: "${KEYNES_REPO:?set KEYNES_REPO to the main Project.Keynes checkout}"
HOME_DIR="${KEYNES_FACTORY_HOME:-$HOME/.keynes-factory}"
RUNNER="$HOME_DIR/runner"
REMOTE="${KEYNES_FACTORY_REMOTE:-fork}"
mkdir -p "$HOME_DIR"
git -C "$KEYNES_REPO" fetch --prune -q "$REMOTE"
if [ ! -e "$RUNNER/.git" ]; then
  git -C "$KEYNES_REPO" worktree add --no-checkout --detach "$RUNNER" "$REMOTE/master"
  git -C "$RUNNER" sparse-checkout set --no-cone '/tools/factory/' '/.github/'
fi
git -C "$RUNNER" checkout -q --detach "$REMOTE/master"
cd "$RUNNER"
if [ ! -f tools/factory/watch_prs.py ]; then
  factory_entry="$(git ls-tree --name-only HEAD -- tools/factory)"
  if [ -z "$factory_entry" ] && [ ! -d tools/factory ]; then
    echo "$(date -u +%FT%TZ) $REMOTE/master has no tools/factory/ yet"
    exit 0
  fi
  echo "$(date -u +%FT%TZ) tools/factory/watch_prs.py is missing from $RUNNER" >&2
  exit 1
fi
exec "${KEYNES_FACTORY_PYTHON:-python3}" tools/factory/watch_prs.py "$@"
