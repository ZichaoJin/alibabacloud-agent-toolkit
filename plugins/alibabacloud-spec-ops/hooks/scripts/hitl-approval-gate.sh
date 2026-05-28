#!/usr/bin/env bash
# HITL Approval Gate - blocks executing-plans until human approval is received.
#
# Trigger: PreToolUse hook, matcher "Skill"
# Target: alibabacloud-spec-ops:alibabacloud-executing-plans

set +e

HITL_BASE_URL="${ALICLOUD_HITL_BASE_URL:-http://localhost:8080}"
HITL_EXPIRY_SECONDS="${ALICLOUD_HITL_EXPIRY_SECONDS:-300}"
HITL_POLL_INTERVAL="${ALICLOUD_HITL_POLL_INTERVAL:-3}"
HITL_MAX_POLL_SECONDS="${ALICLOUD_HITL_MAX_POLL_SECONDS:-300}"

if [ "${ALICLOUD_HITL_ENABLED}" = "false" ]; then
  exit 0
fi

if [ -t 0 ]; then
  exit 0
fi

INPUT="$(cat)"

IS_TARGET="$(printf '%s' "$INPUT" | python3 -c '
import json
import re
import sys

raw = sys.stdin.read()
tool_name = ""
skill_name = ""

try:
    data = json.loads(raw)
    tool_name = data.get("tool_name") or data.get("toolName") or data.get("name") or ""
    tool_input = data.get("tool_input") or data.get("toolInput") or data.get("input") or {}
    if isinstance(tool_input, dict):
        skill_name = tool_input.get("skill") or tool_input.get("skill_name") or ""
    elif isinstance(tool_input, str):
        try:
            skill_name = json.loads(tool_input).get("skill", "")
        except Exception:
            skill_name = tool_input
except Exception:
    tool_match = re.search(r"\"tool_?name\"\s*:\s*\"([^\"]+)\"", raw)
    skill_match = re.search(r"\"skill\"\s*:\s*\"([^\"]+)\"", raw)
    if tool_match:
        tool_name = tool_match.group(1)
    if skill_match:
        skill_name = skill_match.group(1)

if tool_name in ("Skill", "skill") and skill_name == "alibabacloud-spec-ops:alibabacloud-executing-plans":
    print("yes")
else:
    sys.exit(1)
' 2>/dev/null)"

if [ "$IS_TARGET" != "yes" ]; then
  exit 0
fi

DESCRIPTION="$(printf '%s' "$INPUT" | python3 -c '
import json
import sys

default = "Execute Alibaba Cloud infrastructure plan"
try:
    data = json.loads(sys.stdin.read())
    tool_input = data.get("tool_input") or data.get("toolInput") or data.get("input") or {}
    if isinstance(tool_input, dict):
        args = tool_input.get("args") or tool_input.get("description") or ""
        print(str(args)[:512] if args else default)
    else:
        print(default)
except Exception:
    print(default)
' 2>/dev/null)"
DESCRIPTION="${DESCRIPTION:-Execute Alibaba Cloud infrastructure plan}"

ALICLOUD_PK="${ALICLOUD_PK:-1052513758643380}"
REQUESTER_PRINCIPAL_TYPE="${ALICLOUD_REQUESTER_PRINCIPAL_TYPE:-sub}"
REQUESTER_PRINCIPAL_ID="${ALICLOUD_REQUESTER_PRINCIPAL_ID:-1052513758643380}"
export HITL_EXPIRY_SECONDS ALICLOUD_PK REQUESTER_PRINCIPAL_TYPE REQUESTER_PRINCIPAL_ID

CREATE_PAYLOAD="$(DESCRIPTION="$DESCRIPTION" python3 -c '
import json
import os

payload = {
    "Title": "云上高可用架构审批单",
    "Description": "本次执行将部署一套跨可用区高可用博客架构：在 cn-shanghai 创建 VPC、6 个交换机、2 台 ECS、2 个 EIP、公网 ALB、后端服务器组、HTTP 监听、RDS MySQL 8.0 高可用版、数据库和账号，并通过 ALB 将流量转发到双 ECS 后端。",
    "ClientAgentName": "QoderWork",
    "ServerAgentName": "AlibabaCloud HITL",
    "RiskSummary": "本次执行会在阿里云真实创建约 24 个云资源，包括 VPC、交换机、安全组规则、2 台 ECS、2 个 EIP、ALB、RDS MySQL 高可用实例等。资源会产生按量费用，按前期方案估算约 1000 元/月，实际费用以控制台账单为准；若长期保留会持续计费。",
    "ExpirySeconds": int(os.environ.get("HITL_EXPIRY_SECONDS", "300")),
    "AliyunPk": os.environ.get("ALICLOUD_PK", ""),
    "RequesterPrincipalType": os.environ.get("REQUESTER_PRINCIPAL_TYPE", ""),
    "RequesterPrincipalId": os.environ.get("REQUESTER_PRINCIPAL_ID", ""),
    "DefaultAction": "REJECT",
}
print(json.dumps(payload, ensure_ascii=False))
' 2>/dev/null)"

CREATE_RESPONSE="$(curl -s -w '\n%{http_code}' -X POST "${HITL_BASE_URL}/create_bc_approval" \
  -H "Content-Type: application/json" \
  -d "$CREATE_PAYLOAD" 2>/dev/null)"

HTTP_CODE="$(printf '%s\n' "$CREATE_RESPONSE" | tail -1)"
RESPONSE_BODY="$(printf '%s\n' "$CREATE_RESPONSE" | sed '$d')"

if [ "$HTTP_CODE" != "200" ]; then
  export HTTP_CODE
  python3 -c '
import json
import os

http_code = os.environ.get("HTTP_CODE", "000")
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"HITL approval service unavailable (HTTP {http_code}). "
            "Infrastructure execution blocked for safety. Please ensure the approval service is running."
        ),
    }
}, ensure_ascii=False))
' 2>/dev/null
  exit 0
fi

PARSE_RESULT="$(printf '%s' "$RESPONSE_BODY" | python3 -c '
import json
import sys

try:
    data = json.loads(sys.stdin.read())
    code = str(data.get("Code", ""))
    if code not in ("OK", "200"):
        message = data.get("Message", "Unknown error")
        print(f"ERROR:{message}")
    else:
        inner = data.get("Data", data)
        approval_id = inner.get("ApprovalReqId") or data.get("ApprovalReqId") or ""
        interval = inner.get("Interval") or data.get("Interval") or 3
        print(f"{approval_id}|{interval}")
except Exception as exc:
    print(f"ERROR:Failed to parse response: {exc}")
' 2>/dev/null)"

if [[ "$PARSE_RESULT" == ERROR:* ]]; then
  ERROR_MSG="${PARSE_RESULT#ERROR:}"
  ERROR_MSG="$ERROR_MSG" python3 -c '
import json
import os

error_msg = os.environ.get("ERROR_MSG", "unknown")
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"Failed to create approval request: {error_msg}. Infrastructure execution blocked.",
    }
}, ensure_ascii=False))
' 2>/dev/null
  exit 0
fi

APPROVAL_REQ_ID="$(printf '%s' "$PARSE_RESULT" | cut -d'|' -f1)"
POLL_INTERVAL="$(printf '%s' "$PARSE_RESULT" | cut -d'|' -f2)"

if [ -z "$APPROVAL_REQ_ID" ]; then
  python3 -c '
import json

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "Failed to obtain approval request ID. Infrastructure execution blocked.",
    }
}, ensure_ascii=False))
' 2>/dev/null
  exit 0
fi

if [ -n "$POLL_INTERVAL" ] && [ "$POLL_INTERVAL" -gt 0 ] 2>/dev/null; then
  HITL_POLL_INTERVAL="$POLL_INTERVAL"
fi

ELAPSED=0

while [ "$ELAPSED" -lt "$HITL_MAX_POLL_SECONDS" ]; do
  sleep "$HITL_POLL_INTERVAL"
  ELAPSED=$((ELAPSED + HITL_POLL_INTERVAL))

  POLL_RESPONSE="$(curl -s -w '\n%{http_code}' -X POST "${HITL_BASE_URL}/get_approval_status" \
    -H "Content-Type: application/json" \
    -d "{\"ApprovalReqId\":\"${APPROVAL_REQ_ID}\"}" 2>/dev/null)"

  POLL_HTTP_CODE="$(printf '%s\n' "$POLL_RESPONSE" | tail -1)"
  POLL_BODY="$(printf '%s\n' "$POLL_RESPONSE" | sed '$d')"

  if [ "$POLL_HTTP_CODE" != "200" ]; then
    if [ "$POLL_HTTP_CODE" = "429" ]; then
      HITL_POLL_INTERVAL=$((HITL_POLL_INTERVAL * 2))
      [ "$HITL_POLL_INTERVAL" -gt 30 ] && HITL_POLL_INTERVAL=30
    fi
    continue
  fi

  STATUS="$(printf '%s' "$POLL_BODY" | python3 -c '
import json
import sys

try:
    data = json.loads(sys.stdin.read())
    code = str(data.get("Code", ""))
    if code not in ("OK", "200"):
        print("ERROR")
    else:
        print(data.get("Data", {}).get("Status", "UNKNOWN"))
except Exception:
    print("ERROR")
' 2>/dev/null)"

  case "$STATUS" in
    APPROVED)
      APPROVAL_REQ_ID="$APPROVAL_REQ_ID" python3 -c '
import json
import os

approval_id = os.environ.get("APPROVAL_REQ_ID", "")
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": "HITL approval granted",
        "additionalContext": f"[HITL Approval] Human-In-The-Loop approval passed (ApprovalReqId: {approval_id}). Continue executing the infrastructure plan.",
    },
    "systemMessage": "HITL approval passed. Continuing infrastructure execution.",
}, ensure_ascii=False))
' 2>/dev/null
      exit 0
      ;;
    REJECTED)
      python3 -c '
import json

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "Infrastructure execution rejected by approver. The plan will not be applied.",
    },
    "systemMessage": "HITL approval rejected. Infrastructure execution blocked.",
}, ensure_ascii=False))
' 2>/dev/null
      exit 0
      ;;
    EXPIRED)
      python3 -c '
import json

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "Approval request expired. Infrastructure execution blocked by default policy.",
    },
    "systemMessage": "HITL approval expired. Infrastructure execution blocked.",
}, ensure_ascii=False))
' 2>/dev/null
      exit 0
      ;;
    PENDING | ERROR | UNKNOWN | *)
      ;;
  esac
done

export HITL_MAX_POLL_SECONDS
python3 -c '
import json
import os

max_poll_seconds = os.environ.get("HITL_MAX_POLL_SECONDS", "300")
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"HITL approval polling timed out after {max_poll_seconds}s without a terminal response. Infrastructure execution blocked.",
    },
    "systemMessage": "HITL approval polling timed out. Infrastructure execution blocked.",
}, ensure_ascii=False))
' 2>/dev/null
exit 0
