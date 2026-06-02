#!/bin/bash
# alibabacloud-agent-toolkit installer / uninstaller
# Supports: Claude Code, Codex CLI, QoderWork
set -euo pipefail

REPO_URL="https://github.com/acloudlabs-unofficial/alibabacloud-agent-toolkit.git"
MARKETPLACE_NAME="alibabacloud-agent-toolkit"
PLUGIN_NAME="alibabacloud-core"
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
    LOCAL_PLUGINS="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/plugins/${PLUGIN_NAME}"
    if [[ -d "$LOCAL_PLUGINS/.claude-plugin" ]]; then
        PLUGIN_SRC="$LOCAL_PLUGINS"
        info "Using local plugin source: ${PLUGIN_SRC}"
        return
    fi

    # Otherwise clone from GitHub
    info "Downloading plugin from ${REPO_URL} ..."
    TMPDIR_CREATED="$(mktemp -d)"
    git clone --depth 1 --quiet "$REPO_URL" "$TMPDIR_CREATED/repo"
    PLUGIN_SRC="$TMPDIR_CREATED/repo/plugins/${PLUGIN_NAME}"
    if [[ ! -d "$PLUGIN_SRC/.claude-plugin" ]]; then
        err "Plugin not found in cloned repo at plugins/${PLUGIN_NAME}"
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
get_version() {
    python3 -c "import json; print(json.load(open('$PLUGIN_SRC/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "1.0.0"
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

    local version
    version="$(get_version)"
    local dest="${HOME}/.claude/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_NAME}/${version}"

    mkdir -p "$dest"
    info "Copying plugin to ${dest} ..."
    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC/" "$dest/"
    ok "Plugin files copied (v${version})"

    # Register marketplace + plugin so Claude Code discovers hooks and MCP
    info "Registering marketplace..."
    claude plugin marketplace add "$REPO_URL" 2>/dev/null || true

    info "Registering plugin..."
    claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}" 2>/dev/null || true

    # Overwrite again — claude plugin install may have replaced our files with GitHub main
    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC/" "$dest/"

    ok "Claude Code: installed (v${version}). Hooks + MCP configured automatically."
    info "Run 'claude /reload-plugins' or restart Claude Code to activate."
}

install_codex() {
    banner "Codex CLI"

    local version
    version="$(get_version)"
    local dest="${HOME}/.codex/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_NAME}/${version}"

    mkdir -p "$dest"
    info "Copying plugin to ${dest} ..."
    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC/" "$dest/"
    ok "Plugin files copied (v${version})"

    # Enable hooks using the existing script
    local hook_script="$dest/tools/codex/enable-codex-hooks.sh"
    if [[ -f "$hook_script" ]]; then
        info "Enabling hooks..."
        bash "$hook_script"
    else
        warn "Hook enablement script not found at ${hook_script}"
    fi

    ok "Codex: installed. Restart Codex CLI to activate."
}

install_qoderwork() {
    banner "QoderWork"

    local dest="${HOME}/.qoderwork/plugins-custom/${PLUGIN_NAME}"

    mkdir -p "$dest"
    info "Copying plugin to ${dest} ..."
    rsync -a --delete \
        --exclude '__pycache__' \
        --exclude '.DS_Store' \
        "$PLUGIN_SRC/" "$dest/"
    ok "Plugin files copied"

    # Enable hooks using the existing script
    local hook_script="$dest/tools/qoderwork/enable-qoderwork-hooks.sh"
    if [[ -f "$hook_script" ]]; then
        info "Enabling hooks..."
        bash "$hook_script"
    else
        warn "Hook enablement script not found at ${hook_script}"
    fi

    # Configure MCP server in ~/.qoderwork/mcp.json
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

# ─────────────────────────────────────────────────────────────────────
#  UNINSTALL
# ─────────────────────────────────────────────────────────────────────
uninstall_claude() {
    banner "Claude Code — uninstall"

    if ! has_claude; then
        warn "claude CLI not found — skipping."
        return
    fi

    info "Uninstalling plugin..."
    claude plugin uninstall "${PLUGIN_NAME}@${MARKETPLACE_NAME}" 2>/dev/null || true

    # Also uninstall spec-ops if present
    claude plugin uninstall "alibabacloud-spec-ops@${MARKETPLACE_NAME}" 2>/dev/null || true

    # Clean cache directory (claude plugin uninstall only removes the registry entry)
    local cache_dir="${HOME}/.claude/plugins/cache/${MARKETPLACE_NAME}"
    if [[ -d "$cache_dir" ]]; then
        rm -rf "$cache_dir"
        ok "Removed plugin cache: ${cache_dir}"
    fi

    # Remove marketplace
    info "Removing marketplace..."
    claude plugin marketplace remove "${MARKETPLACE_NAME}" 2>/dev/null || true

    ok "Claude Code: fully removed (plugin + cache + marketplace)."
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
    # (hooks trust, plugin registration, MCP tool approvals, marketplace)
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
    # [hooks.state."<marketplace>:hooks/..."]
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

    ok "Codex: fully removed (plugin files + config entries)."
}

uninstall_qoderwork() {
    banner "QoderWork — uninstall"

    local dest="${HOME}/.qoderwork/plugins-custom/${PLUGIN_NAME}"
    if [[ -d "$dest" ]]; then
        rm -rf "$dest"
        ok "Removed ${dest}"
    else
        info "Nothing to remove (not installed)."
    fi

    # Remove hooks from settings.json
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

prefix = "alibabacloud-core/"
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
                        and h["name"].startswith(prefix))]
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

    ok "QoderWork: uninstalled. Restart QoderWork to apply."
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
