#!/bin/bash
# Dry-run harness for telemetry hook scripts.
# Usage: dry-run.sh <fixture-stem> | --all
#   - reads test-fixtures/claude-code/<stem>.json (sibling of this script)
#   - runs the canonical handler from plugins/alibabacloud-core/hooks/scripts/lib/
#     (post_handler.py by default; pre_handler.py for "pre-" stems; prompt_handler.py for "prompt-" stems)
#   - normalizes ISO timestamps to <TS>
#   - diffs against test-fixtures/expected/<stem>.txt
# Returns: 0 on PASS, 1 on FAIL.

set -e

stem="$1"
if [ -z "$stem" ]; then
    echo "Usage: $0 <fixture-stem> | --all" >&2
    exit 2
fi

scriptDir="$(cd "$(dirname "$0")" && pwd)"
# Resolve the canonical hooks scripts dir (single source of truth).
HOOKS_DIR="$(cd "$scriptDir/../../plugins/alibabacloud-core/hooks/scripts" && pwd)"
fixturesDir="$scriptDir/test-fixtures/claude-code"
expectedDir="$scriptDir/test-fixtures/expected"

# Per-test timeout. macOS lacks `timeout` by default; use `gtimeout` from
# coreutils if installed, otherwise fall back to no wrapper (the handler's
# 64KB stdin cap already bounds runtime). Set to "timeout 5" / "gtimeout 5"
# / "" depending on availability.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_WRAPPER=(timeout 5)
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_WRAPPER=(gtimeout 5)
else
    TIMEOUT_WRAPPER=()
fi

run_one() {
    local stem="$1"
    local fixture="$fixturesDir/$stem.json"
    local expected="$expectedDir/$stem.txt"

    if [ ! -f "$fixture" ]; then
        echo "FAIL: $stem (no fixture at $fixture)"
        return 1
    fi
    if [ ! -f "$expected" ]; then
        echo "FAIL: $stem (no expected at $expected)"
        return 1
    fi

    local handler
    if [[ "$stem" == pre-* ]]; then
        handler="$HOOKS_DIR/lib/pre_handler.py"
    elif [[ "$stem" == prompt-* ]]; then
        handler="$HOOKS_DIR/lib/prompt_handler.py"
    else
        handler="$HOOKS_DIR/lib/post_handler.py"
    fi

    # Isolated state dir per test
    local stateDir
    stateDir="$(mktemp -d)"
    trap 'rm -rf "$stateDir"' RETURN

    # Pre-populate start marker if companion exists, so post tests have a start_ts.
    # The companion file holds a single epoch-ms integer; we seed it via the
    # lib/state.py CLI so the marker key matches what post_handler.py looks
    # up: tool_use_id (if present in payload) else sanitized tool_name.
    if [ -f "$fixturesDir/$stem.start" ]; then
        FIXTURE_PATH="$fixture" \
        START_SRC="$fixturesDir/$stem.start" \
        STATE_LIB="$HOOKS_DIR/lib/state.py" \
        ALIBABACLOUD_TELEMETRY_STATE_DIR="$stateDir" \
        python3 -c '
import json, os, re, subprocess, sys
with open(os.environ["FIXTURE_PATH"]) as f:
    data = json.load(f)
session = data.get("session_id", "") or ""
tool_use_id = data.get("tool_use_id", "") or ""
tool_name = data.get("tool_name", "") or ""
key = tool_use_id or re.sub(r"[^A-Za-z0-9_-]", "_", tool_name)[:120]
with open(os.environ["START_SRC"]) as f:
    ms = f.read().strip()
subprocess.check_call([
    sys.executable, os.environ["STATE_LIB"], "seed-marker",
    "--client", "claude-code",
    "--session", session,
    "--key", key,
    "--ms", ms,
])
'
    fi

    local timingOnly=0
    if [ "$(cat "$expected")" = "TIMING_ONLY" ]; then
        timingOnly=1
    fi

    # Create opt-in marker so tests run with full fields (matches fixtures).
    local optinDir="$stateDir/.config/alibabacloud"
    mkdir -p "$optinDir"
    touch "$optinDir/telemetry-optin"

    local actual rc=0
    actual=$(HOME="$stateDir" \
             ALIBABACLOUD_TELEMETRY_STATE_DIR="$stateDir" \
             ALIBABACLOUD_TELEMETRY_DRY_RUN=1 \
             "${TIMEOUT_WRAPPER[@]}" python3 "$handler" < "$fixture" 2>/dev/null) || rc=$?

    if [ "$timingOnly" = "1" ]; then
        # Only assert the handler completes within timeout. For
        # TIMING_ONLY fixtures (e.g. truncated huge stdin), the handler
        # may legitimately exit non-zero — that's OK. A timeout exit
        # (124 from `timeout`) is the only thing that matters here.
        if [ "$rc" = "124" ]; then
            echo "FAIL: $stem (timed out)"
            return 1
        fi
        echo "PASS: $stem (timing-only)"
        return 0
    fi

    if [ "$rc" != "0" ]; then
        echo "FAIL: $stem (handler exited non-zero or timed out)"
        return 1
    fi

    # Normalize ISO timestamps to <TS> and random hex span IDs to <SPAN>
    local actualNorm
    actualNorm=$(echo "$actual" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' | sed -E 's/^[0-9a-f]{16}$/<SPAN>/g')

    if diff -u <(cat "$expected") <(echo "$actualNorm") > /dev/null; then
        echo "PASS: $stem"
        return 0
    else
        echo "FAIL: $stem"
        diff -u <(cat "$expected") <(echo "$actualNorm") || true
        return 1
    fi
}

if [ "$stem" = "--all" ]; then
    fail=0
    for f in "$fixturesDir"/*.json; do
        [ -f "$f" ] || continue
        s="$(basename "$f" .json)"
        run_one "$s" || fail=1
    done
    exit $fail
else
    run_one "$stem"
fi
