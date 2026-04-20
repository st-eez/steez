package installer

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// requiredHook is one steez-managed hook group that must exist in a
// Claude or Codex hooks config.
//
// event is the top-level key inside "hooks" (PreToolUse, Stop, ...).
// matcher is the group matcher. An empty string means "no matcher key" and is
// the shape Claude/Codex expect for events that don't branch on a matcher
// (UserPromptSubmit and Codex Stop).
// matcherRequired is true when the registration must live under that exact
// matcher; false when any matcher is acceptable (we still emit with the
// canonical matcher value for new writes).
type requiredHook struct {
	event           string
	matcher         string
	matcherRequired bool
	command         string
	timeout         int
}

func claudeRequiredHooks() []requiredHook {
	const permission = "$HOME/.claude/hooks/steez-permission-state.sh"
	const skill = "$HOME/.claude/hooks/steez-skill-analytics.sh"
	const session = "$HOME/.claude/hooks/steez-session-start.sh"
	return []requiredHook{
		{event: "PreToolUse", matcher: "AskUserQuestion", matcherRequired: true, command: permission, timeout: 5},
		{event: "PermissionRequest", matcher: "*", matcherRequired: true, command: permission, timeout: 5},
		{event: "Stop", matcher: "*", matcherRequired: true, command: permission, timeout: 5},
		{event: "UserPromptSubmit", matcher: "", matcherRequired: false, command: permission, timeout: 5},
		{event: "PostToolUse", matcher: "Skill", matcherRequired: true, command: skill, timeout: 5},
		{event: "SessionStart", matcher: "", matcherRequired: true, command: session},
	}
}

func codexRequiredHooks() []requiredHook {
	const sessionStart = "bash $HOME/.codex/hooks/session-start.sh"
	const stop = "bash $HOME/.codex/hooks/codex-stop.sh"
	return []requiredHook{
		{event: "SessionStart", matcher: "startup|resume", matcherRequired: true, command: sessionStart, timeout: 5},
		{event: "Stop", matcher: "", matcherRequired: false, command: stop, timeout: 5},
		{event: "UserPromptSubmit", matcher: "", matcherRequired: false, command: stop, timeout: 5},
	}
}

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
		hasHookRegistration(settings.Hooks["Stop"], "*", permissionHook) &&
		hasHookRegistrationAnyMatcher(settings.Hooks["UserPromptSubmit"], permissionHook)) {
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
		hasHookRegistrationAnyMatcher(hooks.Hooks["Stop"], stopHook) &&
		hasHookRegistrationAnyMatcher(hooks.Hooks["UserPromptSubmit"], stopHook) {
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
	fmt.Println("  under hooks.PreToolUse with matcher AskUserQuestion, under")
	fmt.Println("  hooks.PermissionRequest and hooks.Stop with matcher *, and under")
	fmt.Println("  hooks.UserPromptSubmit:")
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
	fmt.Println()
	fmt.Println(`    {`)
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

// EnsureHookRegistration edits ~/.claude/settings.json in place so every
// steez-managed Claude hook group is registered. Existing hook groups and
// unknown top-level keys are preserved. Returns changed=true only when the
// file content was rewritten.
func EnsureHookRegistration(home string) (bool, error) {
	path := filepath.Join(home, ".claude", "settings.json")
	return ensureHookFile(path, claudeRequiredHooks())
}

// EnsureCodexHookRegistration does the same for ~/.codex/hooks.json.
func EnsureCodexHookRegistration(home string) (bool, error) {
	path := filepath.Join(home, ".codex", "hooks.json")
	return ensureHookFile(path, codexRequiredHooks())
}

func ensureHookFile(path string, required []requiredHook) (bool, error) {
	root, err := readHookRoot(path)
	if err != nil {
		return false, err
	}

	hooks := rootHooksMap(root)
	changed := false
	for _, req := range required {
		if ensureHookGroup(hooks, req) {
			changed = true
		}
	}

	if !changed {
		return false, nil
	}

	root["hooks"] = hooks

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return false, fmt.Errorf("create hook config dir: %w", err)
	}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(root); err != nil {
		return false, fmt.Errorf("encode hook config: %w", err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		return false, fmt.Errorf("write hook config: %w", err)
	}
	return true, nil
}

func readHookRoot(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{}, nil
		}
		return nil, fmt.Errorf("read hook config: %w", err)
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return map[string]any{}, nil
	}
	var root map[string]any
	if err := json.Unmarshal(data, &root); err != nil {
		return nil, fmt.Errorf("parse hook config %s: %w", path, err)
	}
	if root == nil {
		root = map[string]any{}
	}
	return root, nil
}

func rootHooksMap(root map[string]any) map[string]any {
	raw, ok := root["hooks"]
	if !ok || raw == nil {
		return map[string]any{}
	}
	if m, ok := raw.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

func ensureHookGroup(hooks map[string]any, req requiredHook) bool {
	groupsRaw, ok := hooks[req.event].([]any)
	if !ok {
		groupsRaw = nil
	}

	if hookGroupsContain(groupsRaw, req) {
		return false
	}

	newGroup := map[string]any{
		"hooks": []any{newHookEntry(req)},
	}
	if req.matcher != "" || req.matcherRequired {
		newGroup["matcher"] = req.matcher
	}

	groupsRaw = append(groupsRaw, newGroup)
	hooks[req.event] = groupsRaw
	return true
}

func hookGroupsContain(groups []any, req requiredHook) bool {
	for _, g := range groups {
		group, ok := g.(map[string]any)
		if !ok {
			continue
		}
		if req.matcherRequired {
			m, _ := group["matcher"].(string)
			if m != req.matcher {
				continue
			}
		}
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
			if cmd == req.command {
				return true
			}
		}
	}
	return false
}

func newHookEntry(req requiredHook) map[string]any {
	entry := map[string]any{
		"type":    "command",
		"command": req.command,
	}
	if req.timeout > 0 {
		entry["timeout"] = req.timeout
	}
	return entry
}

func printCodexHookSnippet() {
	fmt.Println()
	fmt.Println("  Codex hook registration needed. Ensure ~/.codex/config.toml has:")
	fmt.Println()
	fmt.Println(`    [features]`)
	fmt.Println(`    codex_hooks = true`)
	fmt.Println()
	fmt.Println("  Then ensure ~/.codex/hooks.json includes these groups under")
	fmt.Println("  hooks.SessionStart, hooks.Stop, and hooks.UserPromptSubmit:")
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
	fmt.Println()
	fmt.Println("  The same codex-stop.sh command must appear under both hooks.Stop and")
	fmt.Println("  hooks.UserPromptSubmit so the hook can publish the working lease and")
	fmt.Println("  the idle clear onto the pane.")
}
