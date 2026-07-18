#!/bin/bash

set -u

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TOOL_ROOT="$REPO_ROOT/tools/supply-chain-explorer"
SCENARIO="$TOOL_ROOT/scenario.stone_age.example.json"
if [ "$#" -gt 0 ]; then
    SCENARIO="$1"
fi
OUTPUT_ROOT="$REPO_ROOT/tmp/economy-balance"
REPORT_PATH="$OUTPUT_ROOT/balance_report.html"
REPORT_JSON="$OUTPUT_ROOT/balance_report.json"

if ! command -v node >/dev/null 2>&1; then
    echo "Node.js 18 or newer is required."
    read -r -p "Press Enter to close..."
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    echo "Python 3.10 or newer is required."
    read -r -p "Press Enter to close..."
    exit 1
fi

echo "Running Project.Keynes offline economy validator..."
rm -f -- "$REPORT_PATH" "$REPORT_JSON"
"$PYTHON_BIN" "$TOOL_ROOT/balance_validator.py" \
    --scenario "$SCENARIO" \
    --repo-root "$REPO_ROOT" \
    --output-dir "$OUTPUT_ROOT" \
    --node node
VALIDATOR_EXIT=$?

if [ -f "$REPORT_PATH" ]; then
    open "$REPORT_PATH"
else
    echo "Validation failed before a report was generated."
    read -r -p "Press Enter to close..."
    exit 1
fi

exit "$VALIDATOR_EXIT"
