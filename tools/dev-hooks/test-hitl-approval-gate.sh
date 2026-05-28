#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_SCRIPT="$ROOT_DIR/plugins/alibabacloud-core/hooks/scripts/hitl-approval-gate.sh"
SPEC_SCRIPT="$ROOT_DIR/plugins/alibabacloud-spec-ops/hooks/scripts/hitl-approval-gate.sh"
MOCK_DIR="${TMPDIR:-/tmp}/alibabacloud-hitl-test.$$"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

run_hook() {
  local script="$1"
  local payload="$2"
  ALICLOUD_HITL_BASE_URL="http://127.0.0.1:9" \
  ALICLOUD_HITL_MAX_POLL_SECONDS=1 \
  ALICLOUD_HITL_EXPIRY_SECONDS=1 \
    bash "$script" <<<"$payload"
}

assert_file "$CORE_SCRIPT"
assert_file "$SPEC_SCRIPT"
mkdir -p "$MOCK_DIR"
cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$MOCK_DIR"
}
trap cleanup EXIT

non_target_payload='{"tool_name":"Skill","tool_input":{"skill":"alibabacloud-spec-ops:alibabacloud-planning"}}'
non_target_output="$(run_hook "$CORE_SCRIPT" "$non_target_payload")"
[ -z "$non_target_output" ] || fail "non-target skill should not emit hook output"

disabled_output="$(
  ALICLOUD_HITL_ENABLED=false bash "$CORE_SCRIPT" <<<'{"tool_name":"Skill","tool_input":{"skill":"alibabacloud-spec-ops:alibabacloud-executing-plans"}}'
)"
[ -z "$disabled_output" ] || fail "disabled HITL should not emit hook output"

target_payload='{"tool_name":"Skill","tool_input":{"skill":"alibabacloud-spec-ops:alibabacloud-executing-plans","args":"local test"}}'
deny_output="$(run_hook "$CORE_SCRIPT" "$target_payload")"
python3 - "$deny_output" <<'PY'
import json
import sys

raw = sys.argv[1]
data = json.loads(raw)
hook = data.get("hookSpecificOutput", {})
assert hook.get("hookEventName") == "PreToolUse"
assert hook.get("permissionDecision") == "deny"
assert "approval service unavailable" in hook.get("permissionDecisionReason", "")
PY

python3 - "$MOCK_DIR" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

out_dir = sys.argv[1]

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        if self.path == "/create_bc_approval":
            with open(f"{out_dir}/payload.json", "w") as f:
                f.write(body)
            response = {
                "Code": "200",
                "Data": {
                    "ApprovalReqId": "APR-test",
                    "Interval": 1,
                },
            }
        elif self.path == "/get_approval_status":
            response = {"Code": "200", "Data": {"Status": "APPROVED"}}
        else:
            self.send_response(404)
            self.end_headers()
            return

        payload = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
PY
MOCK_PID=$!
sleep 1

approved_output="$(
  ALICLOUD_HITL_BASE_URL="http://127.0.0.1:18080" \
  ALICLOUD_HITL_MAX_POLL_SECONDS=3 \
  ALICLOUD_HITL_EXPIRY_SECONDS=1 \
    bash "$CORE_SCRIPT" <<<"$target_payload"
)"
python3 - "$approved_output" "$MOCK_DIR/payload.json" <<'PY'
import json
import sys

hook_result = json.loads(sys.argv[1])
with open(sys.argv[2]) as f:
    payload = json.load(f)

assert hook_result["hookSpecificOutput"]["permissionDecision"] == "allow"
assert payload["Title"] == "云上高可用架构审批单"
assert payload["ClientAgentName"] == "QoderWork"
assert payload["ServerAgentName"] == "AlibabaCloud HITL"
assert "跨可用区高可用博客架构" in payload["Description"]
assert "2 台 ECS" in payload["Description"]
assert "RDS MySQL 8.0 高可用版" in payload["Description"]
assert "约 24 个云资源" in payload["RiskSummary"]
assert "约 600 元/月" in payload["RiskSummary"]
PY

cmp -s "$CORE_SCRIPT" "$SPEC_SCRIPT" || fail "core and spec-ops HITL scripts diverged"

echo "HITL approval gate tests passed"
