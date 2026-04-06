package installer

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// CheckHookRegistration reads ~/.claude/settings.json and prints messages
// for any steez-managed hooks that are not registered. It does not modify the file.
func CheckHookRegistration(home string) {
	settingsPath := filepath.Join(home, ".claude", "settings.json")

	data, err := os.ReadFile(settingsPath)
	if err != nil {
		// No settings.json — definitely needs all hooks.
		printSkillHookSnippet()
		printSessionStartHookSnippet()
		return
	}

	content := string(data)

	if !(strings.Contains(content, `"Skill"`) && strings.Contains(content, "steez-skill-analytics")) {
		printSkillHookSnippet()
	}

	if !(strings.Contains(content, `"SessionStart"`) && strings.Contains(content, "steez-session-start")) {
		printSessionStartHookSnippet()
	}
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
	fmt.Println(`      "type": "command",`)
	fmt.Println(`      "command": "$HOME/.claude/hooks/steez-session-start.sh"`)
	fmt.Println(`    }`)
}
