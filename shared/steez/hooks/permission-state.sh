#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
INPUT_JSON="$input" python3 - "$HOME/.steez/agent-state/claude" <<'PYEOF'
import json
import os
import sys
import tempfile
import time

state_dir = sys.argv[1]

try:
    payload = json.loads(os.environ["INPUT_JSON"])
except Exception:
    raise SystemExit(0)

session_id = payload.get("session_id") or ""
hook_event_name = payload.get("hook_event_name") or ""
tool_name = payload.get("tool_name") or ""

if not session_id or not hook_event_name:
    raise SystemExit(0)

state_path = os.path.join(state_dir, f"{session_id}.json")

if hook_event_name in {"PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "SessionEnd"}:
    try:
        os.remove(state_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

blocked_state = ""
if hook_event_name == "PermissionRequest":
    blocked_state = "blocked:question" if tool_name == "AskUserQuestion" else "blocked:permission"
elif hook_event_name == "PreToolUse" and tool_name == "AskUserQuestion":
    blocked_state = "blocked:question"
else:
    raise SystemExit(0)

os.makedirs(state_dir, exist_ok=True)
fd, tmp_path = tempfile.mkstemp(prefix=f".{session_id}.", dir=state_dir)
os.close(fd)

state = {
    "session_id": session_id,
    "transcript_path": payload.get("transcript_path"),
    "cwd": payload.get("cwd"),
    "permission_mode": payload.get("permission_mode"),
    "hook_event_name": hook_event_name,
    "blocked_state": blocked_state,
    "tool_name": tool_name,
    "tool_input": payload.get("tool_input"),
    "requested_at": time.time(),
}

try:
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    os.replace(tmp_path, state_path)
finally:
    if os.path.exists(tmp_path):
        os.remove(tmp_path)
PYEOF
