package installer

import (
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()

	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stdout: %v", err)
	}

	os.Stdout = w
	defer func() {
		os.Stdout = oldStdout
	}()

	fn()

	if err := w.Close(); err != nil {
		t.Fatalf("close write pipe: %v", err)
	}

	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read stdout: %v", err)
	}

	return string(out)
}

func writeSettings(t *testing.T, home string, body string) {
	t.Helper()

	settingsPath := filepath.Join(home, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(settingsPath), 0o755); err != nil {
		t.Fatalf("mkdir settings dir: %v", err)
	}
	if err := os.WriteFile(settingsPath, []byte(body), 0o644); err != nil {
		t.Fatalf("write settings: %v", err)
	}
}

func writeCodexHooks(t *testing.T, home string, body string) {
	t.Helper()

	hooksPath := filepath.Join(home, ".codex", "hooks.json")
	if err := os.MkdirAll(filepath.Dir(hooksPath), 0o755); err != nil {
		t.Fatalf("mkdir codex hooks dir: %v", err)
	}
	if err := os.WriteFile(hooksPath, []byte(body), 0o644); err != nil {
		t.Fatalf("write codex hooks: %v", err)
	}
}

func TestCheckCodexHookRegistration_WarnsWhenStopHookMissing(t *testing.T) {
	home := t.TempDir()
	writeCodexHooks(t, home, `{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/session-start.sh", "timeout": 5}
        ]
      }
    ]
  }
}`)

	out := captureStdout(t, func() {
		CheckCodexHookRegistration(home)
	})

	if !strings.Contains(out, "codex-stop.sh") {
		t.Fatalf("expected codex stop hook guidance, got %q", out)
	}
	if !strings.Contains(out, "hooks.Stop") {
		t.Fatalf("expected hooks.Stop guidance, got %q", out)
	}
}

func TestCheckCodexHookRegistration_SilencesGuidanceWhenSessionStartStopAndUserPromptSubmitAreWired(t *testing.T) {
	home := t.TempDir()
	writeCodexHooks(t, home, `{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/session-start.sh", "timeout": 5}
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/codex-stop.sh", "timeout": 5}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/codex-stop.sh", "timeout": 5}
        ]
      }
    ]
  }
}`)

	out := captureStdout(t, func() {
		CheckCodexHookRegistration(home)
	})

	if strings.Contains(out, "codex-stop.sh") || strings.Contains(out, "session-start.sh") {
		t.Fatalf("did not expect codex hook guidance, got %q", out)
	}
}

func TestCheckCodexHookRegistration_WarnsWhenUserPromptSubmitHookMissing(t *testing.T) {
	home := t.TempDir()
	writeCodexHooks(t, home, `{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/session-start.sh", "timeout": 5}
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/codex-stop.sh", "timeout": 5}
        ]
      }
    ]
  }
}`)

	out := captureStdout(t, func() {
		CheckCodexHookRegistration(home)
	})

	if !strings.Contains(out, "codex-stop.sh") {
		t.Fatalf("expected codex hook guidance when UserPromptSubmit is missing, got %q", out)
	}
	if !strings.Contains(out, "hooks.UserPromptSubmit") {
		t.Fatalf("expected UserPromptSubmit-specific guidance, got %q", out)
	}
}

func TestCodexStopHook_EmitsJSONAndDispatchesEvidence(t *testing.T) {
	home := t.TempDir()
	repoPath := findRepoRoot(t)

	binDir := filepath.Join(home, ".steez", "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir bin dir: %v", err)
	}

	recorder := filepath.Join(home, "agent-eventsd.log")
	stub := filepath.Join(binDir, "agent-eventsd")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" >> \""+recorder+"\"\n"), 0o755); err != nil {
		t.Fatalf("write stub agent-eventsd: %v", err)
	}

	transcript := filepath.Join(home, "session.jsonl")
	if err := os.WriteFile(transcript, []byte("DONE\n"), 0o644); err != nil {
		t.Fatalf("write transcript: %v", err)
	}

	cmd := exec.Command(filepath.Join(repoPath, "shared", "steez", "hooks", "codex-stop.sh"))
	cmd.Env = append(os.Environ(),
		"HOME="+home,
		"TMUX_PANE=%42",
	)
	cmd.Stdin = strings.NewReader(`{"transcript_path":"` + transcript + `"}`)

	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("run codex-stop hook: %v", err)
	}
	if strings.TrimSpace(string(out)) != `{"continue":true}` {
		t.Fatalf("stdout = %q, want JSON continue:true", string(out))
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		data, err := os.ReadFile(recorder)
		if err == nil && strings.Contains(string(data), "--state\nidle") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("agent-eventsd stub never recorded idle evidence: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
func TestCheckHookRegistration_WarnsWhenAskUserQuestionHookMissing(t *testing.T) {
	home := t.TempDir()
	writeSettings(t, home, `{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-skill-analytics.sh", "timeout": 5}
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-session-start.sh"}
        ]
      }
    ]
  }
}`)

	out := captureStdout(t, func() {
		CheckHookRegistration(home)
	})

	if !strings.Contains(out, "steez-permission-state.sh") {
		t.Fatalf("expected permission hook guidance, got %q", out)
	}
	if !strings.Contains(out, "AskUserQuestion") {
		t.Fatalf("expected AskUserQuestion matcher guidance, got %q", out)
	}
	if !strings.Contains(out, "hooks.PermissionRequest and hooks.Stop") {
		t.Fatalf("expected reduced hook guidance, got %q", out)
	}
	if !strings.Contains(out, "hooks.UserPromptSubmit") {
		t.Fatalf("expected UserPromptSubmit registration guidance, got %q", out)
	}
	if strings.Contains(out, "PostToolUseFailure") || strings.Contains(out, "SessionEnd") {
		t.Fatalf("did not expect legacy clear-hook guidance, got %q", out)
	}
}

func TestCheckHookRegistration_WarnsWhenUserPromptSubmitHookMissing(t *testing.T) {
	home := t.TempDir()
	writeSettings(t, home, `{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-skill-analytics.sh", "timeout": 5}
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-session-start.sh"}
        ]
      }
    ]
  }
}`)

	out := captureStdout(t, func() {
		CheckHookRegistration(home)
	})

	if !strings.Contains(out, "steez-permission-state.sh") {
		t.Fatalf("expected permission hook guidance when UserPromptSubmit is missing, got %q", out)
	}
	if !strings.Contains(out, "hooks.UserPromptSubmit") {
		t.Fatalf("expected UserPromptSubmit-specific guidance, got %q", out)
	}
}

func readClaudeSettings(t *testing.T, home string) map[string]any {
	t.Helper()

	data, err := os.ReadFile(filepath.Join(home, ".claude", "settings.json"))
	if err != nil {
		t.Fatalf("read settings.json: %v", err)
	}
	var out map[string]any
	if err := jsonUnmarshal(data, &out); err != nil {
		t.Fatalf("parse settings.json: %v\n%s", err, data)
	}
	return out
}

func readCodexHooks(t *testing.T, home string) map[string]any {
	t.Helper()

	data, err := os.ReadFile(filepath.Join(home, ".codex", "hooks.json"))
	if err != nil {
		t.Fatalf("read codex hooks.json: %v", err)
	}
	var out map[string]any
	if err := jsonUnmarshal(data, &out); err != nil {
		t.Fatalf("parse codex hooks.json: %v\n%s", err, data)
	}
	return out
}

func claudeHookCommands(t *testing.T, settings map[string]any, event string) []string {
	t.Helper()
	return collectHookCommands(t, settings, event)
}

func collectHookCommands(t *testing.T, root map[string]any, event string) []string {
	t.Helper()

	hooksRaw, ok := root["hooks"].(map[string]any)
	if !ok {
		return nil
	}
	arr, ok := hooksRaw[event].([]any)
	if !ok {
		return nil
	}
	var out []string
	for _, g := range arr {
		group, ok := g.(map[string]any)
		if !ok {
			continue
		}
		matcher, _ := group["matcher"].(string)
		inner, ok := group["hooks"].([]any)
		if !ok {
			continue
		}
		for _, h := range inner {
			hook, ok := h.(map[string]any)
			if !ok {
				continue
			}
			cmd, _ := hook["command"].(string)
			out = append(out, matcher+"|"+cmd)
		}
	}
	return out
}

func jsonUnmarshal(data []byte, v any) error {
	return json.Unmarshal(data, v)
}

func TestEnsureHookRegistration_CreatesFileWithAllGroupsWhenMissing(t *testing.T) {
	home := t.TempDir()

	changed, err := EnsureHookRegistration(home)
	if err != nil {
		t.Fatalf("EnsureHookRegistration: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true for fresh install")
	}

	settings := readClaudeSettings(t, home)

	wantCommands := map[string][]string{
		"PreToolUse":        {"AskUserQuestion|$HOME/.claude/hooks/steez-permission-state.sh"},
		"PermissionRequest": {"*|$HOME/.claude/hooks/steez-permission-state.sh"},
		"Stop":              {"*|$HOME/.claude/hooks/steez-permission-state.sh"},
		"UserPromptSubmit":  {"|$HOME/.claude/hooks/steez-permission-state.sh"},
		"PostToolUse":       {"Skill|$HOME/.claude/hooks/steez-skill-analytics.sh"},
		"SessionStart":      {"|$HOME/.claude/hooks/steez-session-start.sh"},
	}
	for event, want := range wantCommands {
		got := claudeHookCommands(t, settings, event)
		if len(got) != len(want) {
			t.Fatalf("event %s: got %v, want %v", event, got, want)
		}
		for i, w := range want {
			if got[i] != w {
				t.Fatalf("event %s[%d]: got %q, want %q", event, i, got[i], w)
			}
		}
	}
}

func TestEnsureHookRegistration_IsIdempotent(t *testing.T) {
	home := t.TempDir()

	if _, err := EnsureHookRegistration(home); err != nil {
		t.Fatalf("first EnsureHookRegistration: %v", err)
	}
	firstData, err := os.ReadFile(filepath.Join(home, ".claude", "settings.json"))
	if err != nil {
		t.Fatalf("read after first: %v", err)
	}

	changed, err := EnsureHookRegistration(home)
	if err != nil {
		t.Fatalf("second EnsureHookRegistration: %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false on second run")
	}
	secondData, err := os.ReadFile(filepath.Join(home, ".claude", "settings.json"))
	if err != nil {
		t.Fatalf("read after second: %v", err)
	}
	if string(firstData) != string(secondData) {
		t.Fatalf("file content changed on idempotent run.\nfirst=%s\nsecond=%s", firstData, secondData)
	}
}

func TestEnsureHookRegistration_PreservesExistingUserHooksAndAddsMissing(t *testing.T) {
	home := t.TempDir()
	writeSettings(t, home, `{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/user-bash-guard.sh", "timeout": 10}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-skill-analytics.sh", "timeout": 5}
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-session-start.sh"}
        ]
      }
    ]
  },
  "customKey": "keep-me"
}`)

	changed, err := EnsureHookRegistration(home)
	if err != nil {
		t.Fatalf("EnsureHookRegistration: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true when groups were missing")
	}

	settings := readClaudeSettings(t, home)

	if settings["customKey"] != "keep-me" {
		t.Fatalf("customKey lost: %+v", settings)
	}

	pre := claudeHookCommands(t, settings, "PreToolUse")
	wantPre := []string{
		"Bash|$HOME/.claude/hooks/user-bash-guard.sh",
		"AskUserQuestion|$HOME/.claude/hooks/steez-permission-state.sh",
	}
	if len(pre) != len(wantPre) {
		t.Fatalf("PreToolUse got %v, want %v", pre, wantPre)
	}
	for i, w := range wantPre {
		if pre[i] != w {
			t.Fatalf("PreToolUse[%d]: got %q, want %q", i, pre[i], w)
		}
	}

	post := claudeHookCommands(t, settings, "PostToolUse")
	if len(post) != 1 || post[0] != "Skill|$HOME/.claude/hooks/steez-skill-analytics.sh" {
		t.Fatalf("PostToolUse duplicated or mutated: %v", post)
	}

	for _, event := range []string{"PermissionRequest", "Stop", "UserPromptSubmit"} {
		if got := claudeHookCommands(t, settings, event); len(got) == 0 {
			t.Fatalf("%s missing after ensure", event)
		}
	}
}

func TestEnsureCodexHookRegistration_CreatesFileWithAllGroupsWhenMissing(t *testing.T) {
	home := t.TempDir()

	changed, err := EnsureCodexHookRegistration(home)
	if err != nil {
		t.Fatalf("EnsureCodexHookRegistration: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true for fresh install")
	}

	hooks := readCodexHooks(t, home)

	wantCommands := map[string][]string{
		"SessionStart":     {"startup|resume|bash $HOME/.codex/hooks/session-start.sh"},
		"Stop":             {"|bash $HOME/.codex/hooks/codex-stop.sh"},
		"UserPromptSubmit": {"|bash $HOME/.codex/hooks/codex-stop.sh"},
	}
	for event, want := range wantCommands {
		got := collectHookCommands(t, hooks, event)
		if len(got) != len(want) {
			t.Fatalf("event %s: got %v, want %v", event, got, want)
		}
		for i, w := range want {
			if got[i] != w {
				t.Fatalf("event %s[%d]: got %q, want %q", event, i, got[i], w)
			}
		}
	}
}

func TestEnsureCodexHookRegistration_IsIdempotent(t *testing.T) {
	home := t.TempDir()

	if _, err := EnsureCodexHookRegistration(home); err != nil {
		t.Fatalf("first EnsureCodexHookRegistration: %v", err)
	}
	firstData, err := os.ReadFile(filepath.Join(home, ".codex", "hooks.json"))
	if err != nil {
		t.Fatalf("read after first: %v", err)
	}

	changed, err := EnsureCodexHookRegistration(home)
	if err != nil {
		t.Fatalf("second EnsureCodexHookRegistration: %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false on second run")
	}
	secondData, err := os.ReadFile(filepath.Join(home, ".codex", "hooks.json"))
	if err != nil {
		t.Fatalf("read after second: %v", err)
	}
	if string(firstData) != string(secondData) {
		t.Fatalf("file content changed on idempotent run.\nfirst=%s\nsecond=%s", firstData, secondData)
	}
}

func TestEnsureCodexHookRegistration_PreservesExistingAndAddsMissing(t *testing.T) {
	home := t.TempDir()
	writeCodexHooks(t, home, `{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/session-start.sh", "timeout": 5}
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "bash $HOME/.codex/hooks/user-custom.sh", "timeout": 5}
        ]
      }
    ]
  }
}`)

	changed, err := EnsureCodexHookRegistration(home)
	if err != nil {
		t.Fatalf("EnsureCodexHookRegistration: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true when groups were missing")
	}

	hooks := readCodexHooks(t, home)

	// SessionStart: already present, should not be duplicated.
	ss := collectHookCommands(t, hooks, "SessionStart")
	if len(ss) != 1 || ss[0] != "startup|resume|bash $HOME/.codex/hooks/session-start.sh" {
		t.Fatalf("SessionStart duplicated or mutated: %v", ss)
	}

	// Stop: user hook stays, steez hook is added.
	stop := collectHookCommands(t, hooks, "Stop")
	wantStop := []string{
		"|bash $HOME/.codex/hooks/user-custom.sh",
		"|bash $HOME/.codex/hooks/codex-stop.sh",
	}
	if len(stop) != len(wantStop) {
		t.Fatalf("Stop got %v, want %v", stop, wantStop)
	}
	for i, w := range wantStop {
		if stop[i] != w {
			t.Fatalf("Stop[%d]: got %q, want %q", i, stop[i], w)
		}
	}

	// UserPromptSubmit: added from scratch.
	ups := collectHookCommands(t, hooks, "UserPromptSubmit")
	if len(ups) != 1 || ups[0] != "|bash $HOME/.codex/hooks/codex-stop.sh" {
		t.Fatalf("UserPromptSubmit missing or wrong: %v", ups)
	}
}

func TestCheckHookRegistration_SilencesPermissionGuidanceWhenMinimalStateHooksAreWired(t *testing.T) {
	home := t.TempDir()
	writeSettings(t, home, `{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Skill",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-skill-analytics.sh", "timeout": 5}
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-session-start.sh"}
        ]
      }
    ]
  }
}`)

	out := captureStdout(t, func() {
		CheckHookRegistration(home)
	})

	if strings.Contains(out, "steez-permission-state.sh") {
		t.Fatalf("did not expect permission hook guidance, got %q", out)
	}
}
