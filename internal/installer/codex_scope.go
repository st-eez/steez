package installer

// InstallsGloballyInCodex returns whether a skill should be installed into
// ~/.codex/skills in addition to ~/.claude/skills.
func InstallsGloballyInCodex(name string) bool {
	return name == "spawn-agent" || name == "spec" || name == "tdd"
}
