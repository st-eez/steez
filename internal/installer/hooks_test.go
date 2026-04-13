package installer

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
      },
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
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
    "SessionEnd": [
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
}

func TestCheckHookRegistration_SilencesPermissionGuidanceWhenFullyWired(t *testing.T) {
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
      },
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "$HOME/.claude/hooks/steez-permission-state.sh", "timeout": 5}
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
    "SessionEnd": [
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

	if strings.Contains(out, "steez-permission-state.sh") {
		t.Fatalf("did not expect permission hook guidance, got %q", out)
	}
}
