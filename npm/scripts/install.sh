#!/bin/bash
# alibabacloud-agent-toolkit installer / uninstaller
# Supports: Claude Code, Codex CLI, QoderWork
set -euo pipefail

REPO_URL="https://github.com/acloudlabs-unofficial/alibabacloud-agent-toolkit.git"
MARKETPLACE_NAME="alibabacloud-agent-toolkit"
PLUGIN_CORE="alibabacloud-core"
PLUGIN_SPECOPS="alibabacloud-spec-ops"
MCP_SERVER_CMD="uvx"
MCP_SERVER_ARGS='["alibabacloud.mcp-proxy@latest"]'

# ─── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
banner() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# ─── Parse args ───────────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

WANT_CLAUDE=false
WANT_CODEX=false
WANT_QODERWORK=false
EXPLICIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --claude)     WANT_CLAUDE=true; EXPLICIT=true ;;
        --codex)      WANT_CODEX=true;  EXPLICIT=true ;;
        --qoderwork)  WANT_QODERWORK=true; EXPLICIT=true ;;
        *) err "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

if [[ "$COMMAND" != "install" && "$COMMAND" != "uninstall" ]]; then
    err "Usage: alibabacloud-agent-toolkit <install|uninstall> [--claude] [--codex] [--qoderwork]"
    exit 1
fi

# ─── Detect clients ──────────────────────────────────────────────────
has_claude()     { command -v claude >/dev/null 2>&1; }
has_codex()      { [[ -d "${HOME}/.codex" ]]; }
has_qoderwork()  { [[ -d "${HOME}/.qoderwork" ]]; }

if [[ "$EXPLICIT" == "false" ]]; then
    has_claude    && WANT_CLAUDE=true
    has_codex     && WANT_CODEX=true
    has_qoderwork && WANT_QODERWORK=true
fi

if [[ "$WANT_CLAUDE" == "false" && "$WANT_CODEX" == "false" && "$WANT_QODERWORK" == "false" ]]; then
    err "No supported AI coding client detected (Claude Code, Codex, QoderWork)."
    err "Install at least one, or specify --claude / --codex / --qoderwork."
    exit 1
fi

banner "alibabacloud-agent-toolkit ${COMMAND}"
info "Targets: $(
    [[ "$WANT_CLAUDE" == "true" ]]    && printf 'Claude Code  '
    [[ "$WANT_CODEX" == "true" ]]     && printf 'Codex  '
    [[ "$WANT_QODERWORK" == "true" ]] && printf 'QoderWork'
)"

# ─── Get plugin source ───────────────────────────────────────────────
PLUGIN_SRC=""
TMPDIR_CREATED=""

get_plugin_source() {
    # If running from within the cloned repo (dev mode), use it directly
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOCAL_REPO="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
    if [[ -d "$LOCAL_REPO/plugins/${PLUGIN_CORE}/.claude-plugin" ]]; then
        PLUGIN_SRC_CORE="$LOCAL_REPO/plugins/${PLUGIN_CORE}"
        PLUGIN_SRC_SPECOPS="$LOCAL_REPO/plugins/${PLUGIN_SPECOPS}"
        info "Using local plugin source: ${LOCAL_REPO}/plugins/"
        return
    fi

    # Otherwise clone from GitHub
    info "Downloading plugin from ${REPO_URL} ..."
    TMPDIR_CREATED="$(mktemp -d)"
    git clone --depth 1 --quiet "$REPO_URL" "$TMPDIR_CREATED/repo"
    PLUGIN_SRC_CORE="$TMPDIR_CREATED/repo/plugins/${PLUGIN_CORE}"
    PLUGIN_SRC_SPECOPS="$TMPDIR_CREATED/repo/plugins/${PLUGIN_SPECOPS}"
    if [[ ! -d "$PLUGIN_SRC_CORE/.claude-plugin" ]]; then
        err "Plugin not found in cloned repo at plugins/${PLUGIN_CORE}"
        exit 1
    fi
    ok "Downloaded to ${TMPDIR_CREATED}/repo"
}

cleanup_tmp() {
    if [[ -n "$TMPDIR_CREATED" && -d "$TMPDIR_CREATED" ]]; then
        rm -rf "$TMPDIR_CREATED"
    fi
}
trap cleanup_tmp EXIT

# Read version from plugin.json
get_version_core() {
    python3 -c "import json; print(json.load(open('$PLUGIN_SRC_CORE/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "1.0.0"
}
get_version_specops() {
    python3 -c "import json; print(json.load(open('$PLUGIN_SRC_SPECOPS/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "0.1.0"
}

# ─────────────────────────────────────────────────────────────────────
#  INSTALL
# ─────────────────────────────────────────────────────────────────────
install_claude() {
    banner "Claude Code"

    if ! has_claude; then
        warn "claude CLI not found — skipping. Install Claude Code first."
        return
    fi

    # Register marketplace (shared by both plugins)
    info "Registering marketplace..."
    claude plugin marketplace add "$REPO_URL" 2>/dev/null || true

    # --- Install core ---
    local version_core
    version_core="$(get_version_core)"
    local dest_core="${HOME}/.claude/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_CORE}/${version_core}"

    mkdir -p "$dest_core"
    info "Copying ${PLUGIN_CORE} to ${dest_core} ..."
    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC_CORE/" "$dest_core/"

    info "Registering ${PLUGIN_CORE}..."
    claude plugin install "${PLUGIN_CORE}@${MARKETPLACE_NAME}" 2>/dev/null || true

    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC_CORE/" "$dest_core/"
    ok "${PLUGIN_CORE} installed (v${version_core})"

    # --- Install spec-ops ---
    if [[ -d "$PLUGIN_SRC_SPECOPS/.claude-plugin" ]]; then
        local version_specops
        version_specops="$(get_version_specops)"
        local dest_specops="${HOME}/.claude/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_SPECOPS}/${version_specops}"

        mkdir -p "$dest_specops"
        info "Copying ${PLUGIN_SPECOPS} to ${dest_specops} ..."
        rsync -a --delete \
            --exclude '__pycache__' \
            --exclude '.DS_Store' \
            "$PLUGIN_SRC_SPECOPS/" "$dest_specops/"

        info "Registering ${PLUGIN_SPECOPS}..."
        claude plugin install "${PLUGIN_SPECOPS}@${MARKETPLACE_NAME}" 2>/dev/null || true

        rsync -a --delete \
            --exclude '__pycache__' \
            --exclude '.DS_Store' \
            "$PLUGIN_SRC_SPECOPS/" "$dest_specops/"
        ok "${PLUGIN_SPECOPS} installed (v${version_specops})"
    fi

    ok "Claude Code: done. Hooks + MCP configured automatically."
    info "Run 'claude /reload-plugins' or restart Claude Code to activate."
}

install_codex() {
    banner "Codex CLI"

    # --- Install core ---
    local version_core
    version_core="$(get_version_core)"
    local dest_core="${HOME}/.codex/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_CORE}/${version_core}"

    mkdir -p "$dest_core"
    info "Copying ${PLUGIN_CORE} to ${dest_core} ..."
    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC_CORE/" "$dest_core/"
    ok "${PLUGIN_CORE} files copied (v${version_core})"

    local hook_script="$dest_core/tools/codex/enable-codex-hooks.sh"
    if [[ -f "$hook_script" ]]; then
        info "Enabling ${PLUGIN_CORE} hooks..."
        bash "$hook_script"
    else
        warn "Hook enablement script not found at ${hook_script}"
    fi

    # --- Install spec-ops (files only, no hook registration) ---
    # spec-ops telemetry hooks are identical to core's; registering both causes
    # duplicate events.  Only core's hooks are registered in Codex config.
    if [[ -d "$PLUGIN_SRC_SPECOPS/.claude-plugin" ]]; then
        local version_specops
        version_specops="$(get_version_specops)"
        local dest_specops="${HOME}/.codex/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_SPECOPS}/${version_specops}"

        mkdir -p "$dest_specops"
        info "Copying ${PLUGIN_SPECOPS} to ${dest_specops} ..."
        rsync -a --delete \
            --exclude '__pycache__' \
            --exclude '.DS_Store' \
            "$PLUGIN_SRC_SPECOPS/" "$dest_specops/"
        ok "${PLUGIN_SPECOPS} files copied (v${version_specops}, hooks provided by ${PLUGIN_CORE})"
    fi

    ok "Codex: installed. Restart Codex CLI to activate."
}

# Helper: register a spec-ops plugin in Codex config.toml (when no enable script exists)
_codex_register_plugin() {
    local plugin_dir="$1" plugin_name="$2"
    local config="${HOME}/.codex/config.toml"
    local hooks_json="$plugin_dir/hooks/codex-hooks.json"

    [[ -f "$hooks_json" ]] || return 0

    python3 - "$config" "$hooks_json" "$MARKETPLACE_NAME" "$plugin_name" <<'PY'
import hashlib, json, re, sys
config_path, hooks_path, marketplace, plugin_name = sys.argv[1:]

text = open(config_path).read() if __import__('os').path.isfile(config_path) else ""

# Ensure plugin registration
def upsert_section(text, header, kv_pairs):
    pat = re.compile(rf'(\[{re.escape(header)}\][ \t]*\n)(.*?)(?=\n\[|\Z)', re.S)
    m = pat.search(text)
    if m:
        body = m.group(2)
        for k, _ in kv_pairs:
            body = re.sub(rf'(?m)^{re.escape(k)}\s*=.*\n?', '', body)
        body = body.rstrip()
        addition = "".join(f"{k} = {v}\n" for k, v in kv_pairs)
        new_body = (body + "\n" if body else "") + addition
        return text[:m.start(2)] + new_body + text[m.end(2):]
    sep = "" if text.endswith("\n") or text == "" else "\n"
    body = "".join(f"{k} = {v}\n" for k, v in kv_pairs)
    return text + f"{sep}[{header}]\n{body}"

# Register plugin
section = f'plugins."{plugin_name}@{marketplace}"'
text = upsert_section(text, section, [("enabled", "true")])

# Trust hashes for hooks
EVENT_MAP = {
    "PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use",
    "UserPromptSubmit": "user_prompt_submit", "Stop": "stop",
}
hooks = json.load(open(hooks_path))
for evt_name, groups in hooks.get("hooks", {}).items():
    snake = EVENT_MAP.get(evt_name, evt_name.lower())
    for i, group in enumerate(groups or []):
        for j, h in enumerate(group.get("hooks") or []):
            cmd = h.get("command", "")
            if not cmd:
                continue
            digest = "sha256:" + hashlib.sha256(cmd.encode("utf-8")).hexdigest()
            sec = f'hooks.state."{marketplace}:hooks/codex-hooks.json:{snake}:{i}:{j}"'
            text = upsert_section(text, sec, [
                ("enabled", "true"),
                ("trusted_hash", f'"{digest}"'),
            ])

open(config_path, "w").write(text)
print(f"Registered {plugin_name} in {config_path}")
PY
}

install_qoderwork() {
    banner "QoderWork"

    # --- Install core ---
    local dest_core="${HOME}/.qoderwork/plugins-custom/${PLUGIN_CORE}"

    mkdir -p "$dest_core"
    info "Copying ${PLUGIN_CORE} to ${dest_core} ..."
    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC_CORE/" "$dest_core/"
    ok "${PLUGIN_CORE} files copied"

    local hook_script="$dest_core/tools/qoderwork/enable-qoderwork-hooks.sh"
    if [[ -f "$hook_script" ]]; then
        info "Enabling ${PLUGIN_CORE} hooks..."
        bash "$hook_script"
    else
        warn "Hook enablement script not found at ${hook_script}"
    fi

    # --- Install spec-ops (files only, no hook registration) ---
    # spec-ops telemetry hooks are identical to core's; registering both causes
    # duplicate events and race conditions on shared session state.  Only core's
    # hooks are registered — spec-ops value is in its skills/agents, not hooks.
    if [[ -d "$PLUGIN_SRC_SPECOPS/.claude-plugin" ]]; then
        local dest_specops="${HOME}/.qoderwork/plugins-custom/${PLUGIN_SPECOPS}"

        mkdir -p "$dest_specops"
        info "Copying ${PLUGIN_SPECOPS} to ${dest_specops} ..."
        rsync -a --delete \
            --exclude '__pycache__' \
            --exclude '.DS_Store' \
            "$PLUGIN_SRC_SPECOPS/" "$dest_specops/"
        ok "${PLUGIN_SPECOPS} files copied (hooks provided by ${PLUGIN_CORE})"
    fi

    # Configure MCP server in ~/.qoderwork/mcp.json (shared by both plugins)
    local mcp_config="${HOME}/.qoderwork/mcp.json"
    info "Configuring MCP server..."
    python3 - "$mcp_config" "$MCP_SERVER_CMD" "$MCP_SERVER_ARGS" <<'PYEOF'
import json, sys, os

mcp_path, cmd, args_json = sys.argv[1:]
args = json.loads(args_json)

if os.path.isfile(mcp_path):
    with open(mcp_path) as f:
        config = json.load(f)
else:
    config = {"mcpServers": {}}

config.setdefault("mcpServers", {})
config["mcpServers"]["alibabacloud-core"] = {
    "command": cmd,
    "args": args,
}

with open(mcp_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
print(f"Updated: {mcp_path}")
PYEOF

    ok "QoderWork: installed. Restart QoderWork to activate."
}

# Helper: register spec-ops hooks into QoderWork settings.json (when no enable script exists)
_qoderwork_register_hooks() {
    local plugin_dir="$1" plugin_name="$2"
    local settings="${HOME}/.qoderwork/settings.json"
    local hooks_json="$plugin_dir/hooks/qoderwork-hooks.json"

    [[ -f "$hooks_json" ]] || return 0

    python3 - "$settings" "$hooks_json" "$plugin_dir" "$plugin_name" <<'PY'
import json, sys, os

settings_path, hooks_path, plugin_dir, plugin_name = sys.argv[1:]

# Read current settings
if os.path.isfile(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

settings.setdefault("hooks", {})

# Read hooks definition
with open(hooks_path) as f:
    hooks_def = json.load(f)

prefix = f"{plugin_name}/"

# For each event, merge hooks (deduplicated by name prefix)
for event, groups in hooks_def.get("hooks", {}).items():
    existing = settings["hooks"].get(event, [])
    # Remove old entries with same prefix
    pruned = []
    for grp in existing:
        if not isinstance(grp, dict):
            pruned.append(grp)
            continue
        inner = grp.get("hooks") or []
        kept = [h for h in inner
                if not (isinstance(h, dict) and isinstance(h.get("name"), str)
                        and h["name"].startswith(prefix))]
        if kept:
            new_grp = dict(grp)
            new_grp["hooks"] = kept
            pruned.append(new_grp)

    # Replace __PLUGIN_ROOT__ with actual path and add new hooks
    for grp in (groups or []):
        new_grp = json.loads(json.dumps(grp).replace("__PLUGIN_ROOT__", plugin_dir))
        pruned.append(new_grp)

    settings["hooks"][event] = pruned

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"Registered {plugin_name} hooks in {settings_path}")
PY
}

# ─────────────────────────────────────────────────────────────────────
#  UNINSTALL
# ─────────────────────────────────────────────────────────────────────
uninstall_claude() {
    banner "Claude Code — uninstall"

    if ! has_claude; then
        warn "claude CLI not found — skipping."
        return
    fi

    info "Uninstalling plugins..."
    claude plugin uninstall "${PLUGIN_CORE}@${MARKETPLACE_NAME}" 2>/dev/null || true
    claude plugin uninstall "${PLUGIN_SPECOPS}@${MARKETPLACE_NAME}" 2>/dev/null || true

    # Clean cache directory (claude plugin uninstall only removes the registry entry)
    local cache_dir="${HOME}/.claude/plugins/cache/${MARKETPLACE_NAME}"
    if [[ -d "$cache_dir" ]]; then
        rm -rf "$cache_dir"
        ok "Removed plugin cache: ${cache_dir}"
    fi

    # Remove marketplace
    info "Removing marketplace..."
    claude plugin marketplace remove "${MARKETPLACE_NAME}" 2>/dev/null || true

    ok "Claude Code: fully removed (core + spec-ops + cache + marketplace)."
}

uninstall_codex() {
    banner "Codex CLI — uninstall"

    local cache_dir="${HOME}/.codex/plugins/cache/${MARKETPLACE_NAME}"
    if [[ -d "$cache_dir" ]]; then
        rm -rf "$cache_dir"
        ok "Removed ${cache_dir}"
    else
        info "Plugin files not found (not installed)."
    fi

    # Remove all alibabacloud entries from config.toml
    # (hooks trust for both core and spec-ops, plugin registration, MCP tool approvals, marketplace)
    local config="${HOME}/.codex/config.toml"
    if [[ -f "$config" ]]; then
        info "Cleaning config.toml..."
        python3 - "$config" "$MARKETPLACE_NAME" <<'PYEOF'
import re, sys

path, marketplace = sys.argv[1:]
with open(path) as f:
    text = f.read()

esc = re.escape(marketplace)
# Each pattern matches a [section.header] + its body lines (until next [ or EOF)
patterns = [
    # [hooks.state."<marketplace>:hooks/..."] — covers both core and spec-ops
    rf'\[hooks\.state\."(?:[^"]*@)?{esc}:hooks/[^"]*"\]\s*\n(?:(?!\[)[^\n]*\n)*',
    # [plugins."<plugin>@<marketplace>"] and sub-sections like .mcp_servers.*
    rf'\[plugins\."[^"]*@{esc}"[^\]]*\]\s*\n(?:(?!\[)[^\n]*\n)*',
    # [marketplaces.<marketplace>]
    rf'\[marketplaces\.{esc}\]\s*\n(?:(?!\[)[^\n]*\n)*',
]

original = text
for pat in patterns:
    text = re.sub(pat, '', text)

text = re.sub(r'\n{3,}', '\n\n', text)

if text != original:
    with open(path, 'w') as f:
        f.write(text)
    print(f"Updated: {path}")
else:
    print("No entries to remove.")
PYEOF
    fi

    ok "Codex: fully removed (core + spec-ops files + config entries)."
}

uninstall_qoderwork() {
    banner "QoderWork — uninstall"

    # Remove both plugin directories
    local dest_core="${HOME}/.qoderwork/plugins-custom/${PLUGIN_CORE}"
    local dest_specops="${HOME}/.qoderwork/plugins-custom/${PLUGIN_SPECOPS}"

    if [[ -d "$dest_core" ]]; then
        rm -rf "$dest_core"
        ok "Removed ${dest_core}"
    fi
    if [[ -d "$dest_specops" ]]; then
        rm -rf "$dest_specops"
        ok "Removed ${dest_specops}"
    fi
    if [[ ! -d "$dest_core" && ! -d "$dest_specops" ]]; then
        info "Nothing to remove (not installed)."
    fi

    # Remove hooks from settings.json (both core and spec-ops prefixes)
    local settings="${HOME}/.qoderwork/settings.json"
    if [[ -f "$settings" ]]; then
        info "Removing hooks from settings.json..."
        python3 - "$settings" <<'PYEOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
if not isinstance(hooks, dict):
    sys.exit(0)

prefixes = ("alibabacloud-core/", "alibabacloud-spec-ops/")
changed = False
for event, groups in list(hooks.items()):
    if not isinstance(groups, list):
        continue
    pruned = []
    for grp in groups:
        if not isinstance(grp, dict):
            pruned.append(grp)
            continue
        inner = grp.get("hooks") or []
        kept = [h for h in inner
                if not (isinstance(h, dict) and isinstance(h.get("name"), str)
                        and any(h["name"].startswith(p) for p in prefixes))]
        if kept:
            new_grp = dict(grp)
            new_grp["hooks"] = kept
            pruned.append(new_grp)
        else:
            changed = True
    if pruned != groups:
        changed = True
    if pruned:
        hooks[event] = pruned
    else:
        del hooks[event]
        changed = True

if changed:
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"Updated: {path}")
else:
    print("No hooks to remove.")
PYEOF
    fi

    # Remove MCP server entry
    local mcp_config="${HOME}/.qoderwork/mcp.json"
    if [[ -f "$mcp_config" ]]; then
        info "Removing MCP server entry..."
        python3 - "$mcp_config" <<'PYEOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    config = json.load(f)

servers = config.get("mcpServers", {})
if "alibabacloud-core" in servers:
    del servers["alibabacloud-core"]
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"Removed alibabacloud-core from {path}")
else:
    print("No MCP entry to remove.")
PYEOF
    fi

    ok "QoderWork: uninstalled (core + spec-ops). Restart QoderWork to apply."
}

# ─────────────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────────────
if [[ "$COMMAND" == "install" ]]; then
    get_plugin_source

    [[ "$WANT_CLAUDE" == "true" ]]    && install_claude
    [[ "$WANT_CODEX" == "true" ]]     && install_codex
    [[ "$WANT_QODERWORK" == "true" ]] && install_qoderwork

    banner "Done"
    ok "Installation complete. Restart your coding agent to activate."

elif [[ "$COMMAND" == "uninstall" ]]; then
    [[ "$WANT_CLAUDE" == "true" ]]    && uninstall_claude
    [[ "$WANT_CODEX" == "true" ]]     && uninstall_codex
    [[ "$WANT_QODERWORK" == "true" ]] && uninstall_qoderwork

    banner "Done"
    ok "Uninstallation complete."
fi
