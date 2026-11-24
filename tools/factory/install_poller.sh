#!/bin/zsh
# Install the independent Issue and PR launchd jobs.
set -eu
ISSUE_LABEL=dev.keynes.factory
PR_LABEL=dev.keynes.factory.pr
DOMAIN="gui/$(id -u)"
AGENTS="$HOME/Library/LaunchAgents"
if [ "${1:-}" = "--remove" ]; then
  for label in "$ISSUE_LABEL" "$PR_LABEL"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    rm -f "$AGENTS/$label.plist"
    echo "removed $label"
  done
  exit 0
fi
if [ "$#" -ne 0 ] && { [ "$#" -ne 2 ] || [ "$1" != "--runner-ref" ]; }; then
  echo "usage: $0 [--runner-ref <local ref> | --remove]" >&2
  exit 2
fi

FACTORY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$FACTORY_DIR/../.." && git rev-parse --path-format=absolute --git-common-dir)"
REPO="${REPO%/.git}"
HOME_DIR="$HOME/.keynes-factory"
ref=""
if [ "$#" -eq 2 ]; then
  ref="$(git -C "$FACTORY_DIR" rev-parse --verify "$2^{commit}")"
fi
if ! git -C "$REPO" cat-file -e "${ref:-fork/master}:tools/factory/bin/godot" 2>/dev/null; then
  echo "${ref:-fork/master} lacks the parallel factory code. Use --runner-ref with a compatible commit." >&2
  exit 1
fi

mkdir -p "$HOME_DIR" "$AGENTS"
stage="$(mktemp -d "$HOME_DIR/install.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
cp "$FACTORY_DIR/poll.sh" "$stage/poll.sh"
chmod +x "$stage/poll.sh"
python3 - "$FACTORY_DIR" "$stage" "$ISSUE_LABEL" "$PR_LABEL" "$REPO" "$HOME_DIR" <<'PY'
import plistlib
import sys
from pathlib import Path

factory, stage, issue_label, pr_label, repo, factory_home = sys.argv[1:]
sys.path.insert(0, factory)
from common import load_config

for label, args, log in ((issue_label, [], "poll.log"), (pr_label, ["--pr-lane"], "poll-pr.log")):
    with (Path(stage) / f"{label}.plist").open("wb") as plist:
        plistlib.dump({
            "Label": label,
            "ProgramArguments": ["/bin/zsh", "-l", f"{factory_home}/poll.sh", *args],
            "EnvironmentVariables": {"KEYNES_REPO": repo, "KEYNES_FACTORY_PYTHON": load_config()["tools"]["python"]},
            "StartInterval": 600,
            "StandardOutPath": f"{factory_home}/{log}",
            "StandardErrorPath": f"{factory_home}/{log}",
        }, plist)
PY
if [ -n "$ref" ]; then
  printf '%s\n' "$ref" > "$stage/runner-ref"
  mv "$stage/runner-ref" "$HOME_DIR/runner-ref"
else
  rm -f "$HOME_DIR/runner-ref"
fi
mv "$stage/poll.sh" "$HOME_DIR/poll.sh"

for label in "$ISSUE_LABEL" "$PR_LABEL"; do
  plist="$AGENTS/$label.plist"
  if ! cmp -s "$stage/$label.plist" "$plist"; then
    mv "$stage/$label.plist" "$plist"
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  fi
  if ! launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootstrap "$DOMAIN" "$plist"
  fi
  echo "installed $label: every 600s"
  echo "run now: launchctl kickstart $DOMAIN/$label"
done
