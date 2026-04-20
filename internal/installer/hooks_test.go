package installer

import (
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
