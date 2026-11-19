#!/bin/zsh
# Install (or with --remove, uninstall) the launchd job that watches open PRs.
set -eu
LABEL=dev.keynes.factory
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
if [ "${1:-}" = "--remove" ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed $LABEL"
  exit 0
fi
FACTORY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$FACTORY_DIR/../.." && git rev-parse --path-format=absolute --git-common-dir)"
REPO="${REPO%/.git}"
HOME_DIR="$HOME/.keynes-factory"
mkdir -p "$HOME_DIR" "$HOME/Library/LaunchAgents"
cp "$FACTORY_DIR/poll.sh" "$HOME_DIR/poll.sh"
chmod +x "$HOME_DIR/poll.sh"
python3 - "$FACTORY_DIR" "$PLIST" "$LABEL" "$REPO" "$HOME_DIR" <<'PY'
import plistlib
import sys

factory, path, label, repo, factory_home = sys.argv[1:]
sys.path.insert(0, factory)
from common import load_config

with open(path, "wb") as plist:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": ["/bin/zsh", "-l", f"{factory_home}/poll.sh"],
        "EnvironmentVariables": {"KEYNES_REPO": repo, "KEYNES_FACTORY_PYTHON": load_config()["tools"]["python"]},
        "StartInterval": 600,
        "StandardOutPath": f"{factory_home}/poll.log",
        "StandardErrorPath": f"{factory_home}/poll.log",
    }, plist)
PY
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $LABEL: every 600s, repo $REPO, log $HOME_DIR/poll.log"
echo "run now: launchctl kickstart $DOMAIN/$LABEL"
