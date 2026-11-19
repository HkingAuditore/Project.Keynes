#!/bin/zsh -l
# One poll: refresh the runner worktree to the fork's master, then run the factory once.
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
exec ~/.local/bin/python3 tools/factory/run.py "$@"
