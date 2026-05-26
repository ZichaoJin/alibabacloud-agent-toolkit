#!/bin/bash
# Enable QoderWork plugin hooks for alibabacloud-core (idempotent).
#
# Merges this plugin's hook definitions into ~/.qoderwork/settings.json.
# Substitutes the __PLUGIN_ROOT__ placeholder with the absolute plugin path
# at install time (QoderWork does not inject env vars into hook scripts —
# everything must be an absolute path).
#
# Re-runs are safe: any hook entry whose `name` starts with the prefix
# "alibabacloud-core/" is removed before fresh entries are appended, so
# repeated invocations never duplicate hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_JSON="$PLUGIN_ROOT/hooks/qoderwork-hooks.json"
SETTINGS="${HOME}/.qoderwork/settings.json"
NAME_PREFIX="alibabacloud-core/"

if [ ! -f "$HOOKS_JSON" ]; then
    echo "FAIL: $HOOKS_JSON not found" >&2
    exit 2
fi

mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
    ts=$(date +%s).$$
    cp "$SETTINGS" "$SETTINGS.bak.$ts"
    echo "Backup: $SETTINGS.bak.$ts"
else
    echo '{}' > "$SETTINGS"
    echo "Created: $SETTINGS"
fi

python3 - "$SETTINGS" "$HOOKS_JSON" "$PLUGIN_ROOT" "$NAME_PREFIX" <<'PY'
import json, sys
settings_path, hooks_path, plugin_root, name_prefix = sys.argv[1:]

with open(settings_path) as f:
    text = f.read().strip() or "{}"
try:
    settings = json.loads(text)
except json.JSONDecodeError as e:
    print(f"FAIL: {settings_path} is not valid JSON: {e}", file=sys.stderr)
    sys.exit(2)
if not isinstance(settings, dict):
    print(f"FAIL: {settings_path} root must be a JSON object", file=sys.stderr)
    sys.exit(2)

with open(hooks_path) as f:
    template = json.load(f)
template_str = json.dumps(template).replace("__PLUGIN_ROOT__", plugin_root)
template = json.loads(template_str)

settings.setdefault("hooks", {})
hooks_root = settings["hooks"]
if not isinstance(hooks_root, dict):
    print(f"FAIL: settings.hooks must be a JSON object", file=sys.stderr)
    sys.exit(2)

owned = lambda h: isinstance(h, dict) and isinstance(h.get("name"), str) \
    and h["name"].startswith(name_prefix)

for event, new_groups in template.get("hooks", {}).items():
    existing = hooks_root.get(event)
    if not isinstance(existing, list):
        existing = []
    pruned = []
    for grp in existing:
        if not isinstance(grp, dict):
            pruned.append(grp); continue
        inner = grp.get("hooks") or []
        kept = [h for h in inner if not owned(h)]
        if kept:
            new_grp = dict(grp)
            new_grp["hooks"] = kept
            pruned.append(new_grp)
        # else: drop the empty group entirely
    pruned.extend(new_groups)
    hooks_root[event] = pruned

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("Updated:", settings_path)
PY

echo "Done. Restart QoderWork for changes to take effect."
