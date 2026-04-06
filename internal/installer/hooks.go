package installer

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// CheckHookRegistration reads ~/.claude/settings.json and prints a message
// if the Skill PostToolUse hook is not registered. It does not modify the file.
func CheckHookRegistration(home string) {
	settingsPath := filepath.Join(home, ".claude", "settings.json")

	data, err := os.ReadFile(settingsPath)
	if err != nil {
		// No settings.json — definitely needs the hook.
		printHookSnippet()
		return
	}

	// Simple string check — if the file contains both "Skill" and
	// "steez-skill-analytics" in the hooks section, it's registered.
	content := string(data)
	if strings.Contains(content, `"Skill"`) && strings.Contains(content, "steez-skill-analytics") {
		return
	}

	printHookSnippet()
}

func printHookSnippet() {
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
