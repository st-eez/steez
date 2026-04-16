package installer

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type claudeSettings struct {
	Hooks map[string][]claudeHookGroup `json:"hooks"`
}

type claudeHookGroup struct {
	Matcher string       `json:"matcher"`
	Hooks   []claudeHook `json:"hooks"`
}

type claudeHook struct {
	Command string `json:"command"`
}

type codexHooksFile struct {
	Hooks map[string][]claudeHookGroup `json:"hooks"`
}

// CheckHookRegistration reads ~/.claude/settings.json and prints messages
// for any steez-managed hooks that are not registered. It does not modify the file.
func CheckHookRegistration(home string) {
	settingsPath := filepath.Join(home, ".claude", "settings.json")

	data, err := os.ReadFile(settingsPath)
	if err != nil {
		// No settings.json — definitely needs all hooks.
		printPermissionStateHookSnippet()
		printSkillHookSnippet()
		printSessionStartHookSnippet()
		return
	}

	var settings claudeSettings
	if err := json.Unmarshal(data, &settings); err != nil {
		printPermissionStateHookSnippet()
		printSkillHookSnippet()
		printSessionStartHookSnippet()
		return
	}

	const (
		permissionHook = "$HOME/.claude/hooks/steez-permission-state.sh"
		skillHook      = "$HOME/.claude/hooks/steez-skill-analytics.sh"
		sessionHook    = "$HOME/.claude/hooks/steez-session-start.sh"
	)

	if !hasHookRegistration(settings.Hooks["PostToolUse"], "Skill", skillHook) {
		printSkillHookSnippet()
	}

	if !(hasHookRegistration(settings.Hooks["PreToolUse"], "AskUserQuestion", permissionHook) &&
		hasHookRegistration(settings.Hooks["PermissionRequest"], "*", permissionHook) &&
		hasHookRegistration(settings.Hooks["Stop"], "*", permissionHook)) {
		printPermissionStateHookSnippet()
	}

	if !hasHookRegistration(settings.Hooks["SessionStart"], "", sessionHook) {
		printSessionStartHookSnippet()
	}
}

// CheckCodexHookRegistration reads ~/.codex/hooks.json and prints guidance
// when the SessionStart or Stop hooks are not registered.
func CheckCodexHookRegistration(home string) {
	hooksPath := filepath.Join(home, ".codex", "hooks.json")

	data, err := os.ReadFile(hooksPath)
	if err != nil {
		printCodexHookSnippet()
		return
	}

	var hooks codexHooksFile
	if err := json.Unmarshal(data, &hooks); err != nil {
		printCodexHookSnippet()
		return
	}

	const (
		sessionHook = "bash $HOME/.codex/hooks/session-start.sh"
		stopHook    = "bash $HOME/.codex/hooks/codex-stop.sh"
	)

	if hasHookRegistration(hooks.Hooks["SessionStart"], "startup|resume", sessionHook) &&
		hasHookRegistrationAnyMatcher(hooks.Hooks["Stop"], stopHook) {
		return
	}

	printCodexHookSnippet()
}

func hasHookRegistration(groups []claudeHookGroup, matcher, command string) bool {
	for _, group := range groups {
		if group.Matcher != matcher {
			continue
		}
		for _, hook := range group.Hooks {
			if hook.Command == command {
				return true
			}
		}
	}
	return false
}

func hasHookRegistrationAnyMatcher(groups []claudeHookGroup, command string) bool {
	for _, group := range groups {
		for _, hook := range group.Hooks {
			if hook.Command == command {
				return true
			}
		}
	}
	return false
}

func printPermissionStateHookSnippet() {
	fmt.Println()
	fmt.Println("  Hook registration needed. Add steez-permission-state.sh to ~/.claude/settings.json")
	fmt.Println("  under hooks.PreToolUse with matcher AskUserQuestion, then under")
	fmt.Println("  hooks.PermissionRequest and hooks.Stop with matcher *:")
	fmt.Println()
	fmt.Println(`    {`)
	fmt.Println(`      "matcher": "AskUserQuestion",`)
	fmt.Println(`      "hooks": [`)
	fmt.Println(`        {`)
	fmt.Println(`          "type": "command",`)
	fmt.Println(`          "command": "$HOME/.claude/hooks/steez-permission-state.sh",`)
	fmt.Println(`          "timeout": 5`)
	fmt.Println(`        }`)
	fmt.Println(`      ]`)
	fmt.Println(`    }`)
	fmt.Println()
	fmt.Println(`    {`)
	fmt.Println(`      "matcher": "*",`)
	fmt.Println(`      "hooks": [`)
	fmt.Println(`        {`)
	fmt.Println(`          "type": "command",`)
	fmt.Println(`          "command": "$HOME/.claude/hooks/steez-permission-state.sh",`)
	fmt.Println(`          "timeout": 5`)
	fmt.Println(`        }`)
	fmt.Println(`      ]`)
	fmt.Println(`    }`)
}

func printSkillHookSnippet() {
	fmt.Println()
	fmt.Println("  Hook registration needed. Add this to ~/.claude/settings.json")
	fmt.Println("  under hooks.PostToolUse:")
	fmt.Println()
	fmt.Println(`    {`)
	fmt.Println(`      "matcher": "Skill",`)
	fmt.Println(`      "hooks": [`)
	fmt.Println(`        {`)
	fmt.Println(`          "type": "command",`)
	fmt.Println(`          "command": "$HOME/.claude/hooks/steez-skill-analytics.sh",`)
	fmt.Println(`          "timeout": 5`)
	fmt.Println(`        }`)
	fmt.Println(`      ]`)
	fmt.Println(`    }`)
}

func printSessionStartHookSnippet() {
	fmt.Println()
	fmt.Println("  Hook registration needed. Add this to ~/.claude/settings.json")
	fmt.Println("  under hooks.SessionStart:")
	fmt.Println()
	fmt.Println(`    {`)
	fmt.Println(`      "matcher": "",`)
	fmt.Println(`      "hooks": [`)
	fmt.Println(`        {`)
	fmt.Println(`          "type": "command",`)
	fmt.Println(`          "command": "$HOME/.claude/hooks/steez-session-start.sh"`)
	fmt.Println(`        }`)
	fmt.Println(`      ]`)
	fmt.Println(`    }`)
}

func printCodexHookSnippet() {
	fmt.Println()
	fmt.Println("  Codex hook registration needed. Ensure ~/.codex/config.toml has:")
	fmt.Println()
	fmt.Println(`    [features]`)
	fmt.Println(`    codex_hooks = true`)
	fmt.Println()
	fmt.Println("  Then ensure ~/.codex/hooks.json includes these groups under")
	fmt.Println("  hooks.SessionStart and hooks.Stop:")
	fmt.Println()
	fmt.Println(`    {`)
	fmt.Println(`      "matcher": "startup|resume",`)
	fmt.Println(`      "hooks": [`)
	fmt.Println(`        {`)
	fmt.Println(`          "type": "command",`)
	fmt.Println(`          "command": "bash $HOME/.codex/hooks/session-start.sh",`)
	fmt.Println(`          "timeout": 5`)
	fmt.Println(`        }`)
	fmt.Println(`      ]`)
	fmt.Println(`    }`)
	fmt.Println()
	fmt.Println(`    {`)
	fmt.Println(`      "hooks": [`)
	fmt.Println(`        {`)
	fmt.Println(`          "type": "command",`)
	fmt.Println(`          "command": "bash $HOME/.codex/hooks/codex-stop.sh",`)
	fmt.Println(`          "timeout": 5`)
	fmt.Println(`        }`)
	fmt.Println(`      ]`)
	fmt.Println(`    }`)
}
