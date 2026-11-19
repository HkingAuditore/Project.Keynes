#!/bin/zsh
# Install (or with --remove, uninstall) the launchd job that polls for ready-for-agent tickets.
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
REPO="$(cd "$(dirname "$0")/../.." && git rev-parse --path-format=absolute --git-common-dir)"
REPO="${REPO%/.git}"
HOME_DIR="$HOME/.keynes-factory"
mkdir -p "$HOME_DIR" "$HOME/Library/LaunchAgents"
cp "$(dirname "$0")/poll.sh" "$HOME_DIR/poll.sh"
chmod +x "$HOME_DIR/poll.sh"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>-l</string><string>$HOME_DIR/poll.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>KEYNES_REPO</key><string>$REPO</string></dict>
  <key>StartInterval</key><integer>600</integer>
  <key>StandardOutPath</key><string>$HOME_DIR/poll.log</string>
  <key>StandardErrorPath</key><string>$HOME_DIR/poll.log</string>
</dict></plist>
EOF
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $LABEL: every 600s, repo $REPO, log $HOME_DIR/poll.log"
echo "run now: launchctl kickstart $DOMAIN/$LABEL"
